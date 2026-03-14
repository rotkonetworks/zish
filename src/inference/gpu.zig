// GPU compute service — Vulkan compute for AMD RDNA2/3
//
// Server as a Function: GpuContext is a service that exposes composable operations.
// Each operation is a function: input → output. The model forward pass composes them.
// The GPU service is a drop-in replacement for CPU math — same interface, different backend.
//
// Bandwidth-first design:
//   Inference is memory-bound. The goal is reading weights from VRAM (183 GB/s dGPU,
//   50 GB/s iGPU) instead of system RAM. Compute is secondary.
//   Minimize data movement: weights live permanently on GPU, only small input/output
//   vectors cross the PCIe bus (~4KB per matmul dispatch).
//
// Model-agnostic: dimensions are push constants, not compiled into shaders.
// Works for any model: Qwen2.5-0.5B, Qwen3.5-2B, future models.
// Shader workgroup size (256) is the only RDNA-specific constant.
//
// Operations (composable functions):
//   matvec:      (f16[R×C], f32[C]) → f32[R]     — backbone projections, CTM c_proj
//   superlinear: (f32[M,O,N], f32[N,M]) → f32[N,O] — CTM NLM per-neuron einsum
//   (future: batch_matvec for SynapseUNET cascade)
//
// Small ops stay on CPU (not worth GPU dispatch overhead):
//   RMSNorm, LayerNorm, SiLU/GLU, sync accumulators, trace shifts, RoPE, softmax

const std = @import("std");

const Allocator = std.mem.Allocator;

// dlopen/dlsym/dlclose via std.c (requires libc linking)

// ============================================================
// Vulkan types — opaque handles + C ABI structs
// ============================================================

const VkInstance = ?*opaque {};
const VkPhysicalDevice = ?*opaque {};
const VkDevice = ?*opaque {};
const VkQueue = ?*opaque {};
const VkCommandPool = ?*opaque {};
const VkCommandBuffer = ?*opaque {};
const VkBuffer = ?*opaque {};
const VkDeviceMemory = ?*opaque {};
const VkShaderModule = ?*opaque {};
const VkPipeline = ?*opaque {};
const VkPipelineLayout = ?*opaque {};
const VkDescriptorSetLayout = ?*opaque {};
const VkDescriptorPool = ?*opaque {};
const VkDescriptorSet = ?*opaque {};
const VkFence = ?*opaque {};

// Constants
const VK_SUCCESS: i32 = 0;
const VK_QUEUE_COMPUTE_BIT: u32 = 0x00000002;
const VK_SHARING_MODE_EXCLUSIVE: u32 = 0;
const VK_PIPELINE_BIND_POINT_COMPUTE: u32 = 1;
const VK_COMMAND_BUFFER_LEVEL_PRIMARY: u32 = 0;
const VK_SHADER_STAGE_COMPUTE_BIT: u32 = 0x00000020;
const VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT: u32 = 0x00000001;

// Buffer usage flags
const VK_BUFFER_USAGE_TRANSFER_SRC: u32 = 0x00000001;
const VK_BUFFER_USAGE_TRANSFER_DST: u32 = 0x00000002;
const VK_BUFFER_USAGE_STORAGE_BUFFER: u32 = 0x00000020;

// Memory property flags
const VK_MEMORY_PROPERTY_DEVICE_LOCAL: u32 = 0x00000001;
const VK_MEMORY_PROPERTY_HOST_VISIBLE: u32 = 0x00000002;
const VK_MEMORY_PROPERTY_HOST_COHERENT: u32 = 0x00000004;

// Structure types
const STYPE_INSTANCE_CI: u32 = 1;
const STYPE_DEVICE_QUEUE_CI: u32 = 2;
const STYPE_DEVICE_CI: u32 = 3;
const STYPE_SUBMIT_INFO: u32 = 4;
const STYPE_MEMORY_AI: u32 = 5;
const STYPE_FENCE_CI: u32 = 8;
const STYPE_BUFFER_CI: u32 = 12;
const STYPE_SHADER_MODULE_CI: u32 = 15;
const STYPE_COMPUTE_PIPELINE_CI: u32 = 29;
const STYPE_PIPELINE_LAYOUT_CI: u32 = 30;
const STYPE_DESC_SET_LAYOUT_CI: u32 = 32;
const STYPE_DESC_POOL_CI: u32 = 33;
const STYPE_DESC_SET_AI: u32 = 34;
const STYPE_WRITE_DESC_SET: u32 = 35;
const STYPE_CMD_POOL_CI: u32 = 39;
const STYPE_CMD_BUF_AI: u32 = 40;
const STYPE_CMD_BUF_BEGIN: u32 = 42;
const STYPE_BUFFER_BARRIER: u32 = 44;

// Pipeline stages
const STAGE_COMPUTE: u32 = 0x00000800;
const STAGE_TRANSFER: u32 = 0x00001000;

// Access masks
const ACCESS_SHADER_READ: u32 = 0x00000020;
const ACCESS_SHADER_WRITE: u32 = 0x00000040;
const ACCESS_TRANSFER_READ: u32 = 0x00004000;
const ACCESS_TRANSFER_WRITE: u32 = 0x00002000;

const VK_WHOLE_SIZE: u64 = 0xFFFFFFFFFFFFFFFF;
const VK_QUEUE_FAMILY_IGNORED: u32 = 0xFFFFFFFF;

const VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU: u32 = 1;
const VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU: u32 = 2;

const VK_DESCRIPTOR_TYPE_STORAGE_BUFFER: u32 = 7;

// ============================================================
// Vulkan C ABI structs (only what we need)
// ============================================================

const VkPhysicalDeviceProperties = extern struct {
    apiVersion: u32 = 0,
    driverVersion: u32 = 0,
    vendorID: u32 = 0,
    deviceID: u32 = 0,
    deviceType: u32 = 0,
    deviceName: [256]u8 = [_]u8{0} ** 256,
    pipelineCacheUUID: [16]u8 = [_]u8{0} ** 16,
    // limits(504) + sparse(20) + alignment = 528 bytes
    // Total struct: 20 + 256 + 16 + 4(pad) + 504 + 20 + 4(pad) = 824
    _pad: [532]u8 = [_]u8{0} ** 532,
};

const VkMemoryType = extern struct {
    propertyFlags: u32 = 0,
    heapIndex: u32 = 0,
};

const VkMemoryHeap = extern struct {
    size: u64 = 0,
    flags: u32 = 0,
    _pad: u32 = 0,
};

const VkPhysicalDeviceMemoryProperties = extern struct {
    memoryTypeCount: u32 = 0,
    memoryTypes: [32]VkMemoryType = [_]VkMemoryType{.{}} ** 32,
    memoryHeapCount: u32 = 0,
    memoryHeaps: [16]VkMemoryHeap = [_]VkMemoryHeap{.{}} ** 16,
};

const VkQueueFamilyProperties = extern struct {
    queueFlags: u32 = 0,
    queueCount: u32 = 0,
    timestampValidBits: u32 = 0,
    minImageTransferGranularity: [3]u32 = .{ 0, 0, 0 },
};

const VkBufferCreateInfo = extern struct {
    sType: u32 = STYPE_BUFFER_CI,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    size: u64 = 0,
    usage: u32 = 0,
    sharingMode: u32 = 0,
    queueFamilyIndexCount: u32 = 0,
    pQueueFamilyIndices: ?[*]const u32 = null,
};

const VkMemoryRequirements = extern struct {
    size: u64 = 0,
    alignment: u64 = 0,
    memoryTypeBits: u32 = 0,
};

const VkMemoryAllocateInfo = extern struct {
    sType: u32 = STYPE_MEMORY_AI,
    pNext: ?*const anyopaque = null,
    allocationSize: u64 = 0,
    memoryTypeIndex: u32 = 0,
};

const VkDescriptorBufferInfo = extern struct {
    buffer: VkBuffer = null,
    offset: u64 = 0,
    range: u64 = 0,
};

const VkBufferCopy = extern struct {
    srcOffset: u64 = 0,
    dstOffset: u64 = 0,
    size: u64 = 0,
};

const VkBufferMemoryBarrier = extern struct {
    sType: u32 = STYPE_BUFFER_BARRIER,
    pNext: ?*const anyopaque = null,
    srcAccessMask: u32 = 0,
    dstAccessMask: u32 = 0,
    srcQueueFamilyIndex: u32 = VK_QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex: u32 = VK_QUEUE_FAMILY_IGNORED,
    buffer: VkBuffer = null,
    offset: u64 = 0,
    size: u64 = VK_WHOLE_SIZE,
};

// ============================================================
// Function pointer table — loaded via dlopen + vkGetInstanceProcAddr
// ============================================================

const PFN_vkGetInstanceProcAddr = *const fn (VkInstance, [*:0]const u8) callconv(.c) ?*const fn () callconv(.c) void;

const VkFns = struct {
    // Instance level
    createInstance: *const fn (*const anyopaque, ?*const anyopaque, *VkInstance) callconv(.c) i32 = undefined,
    destroyInstance: *const fn (VkInstance, ?*const anyopaque) callconv(.c) void = undefined,
    enumeratePhysicalDevices: *const fn (VkInstance, *u32, ?[*]VkPhysicalDevice) callconv(.c) i32 = undefined,
    getPhysicalDeviceProperties: *const fn (VkPhysicalDevice, *VkPhysicalDeviceProperties) callconv(.c) void = undefined,
    getPhysicalDeviceMemoryProperties: *const fn (VkPhysicalDevice, *VkPhysicalDeviceMemoryProperties) callconv(.c) void = undefined,
    getPhysicalDeviceQueueFamilyProperties: *const fn (VkPhysicalDevice, *u32, ?[*]VkQueueFamilyProperties) callconv(.c) void = undefined,
    // Device level
    createDevice: *const fn (VkPhysicalDevice, *const anyopaque, ?*const anyopaque, *VkDevice) callconv(.c) i32 = undefined,
    destroyDevice: *const fn (VkDevice, ?*const anyopaque) callconv(.c) void = undefined,
    getDeviceQueue: *const fn (VkDevice, u32, u32, *VkQueue) callconv(.c) void = undefined,
    createBuffer: *const fn (VkDevice, *const VkBufferCreateInfo, ?*const anyopaque, *VkBuffer) callconv(.c) i32 = undefined,
    destroyBuffer: *const fn (VkDevice, VkBuffer, ?*const anyopaque) callconv(.c) void = undefined,
    getBufferMemoryRequirements: *const fn (VkDevice, VkBuffer, *VkMemoryRequirements) callconv(.c) void = undefined,
    allocateMemory: *const fn (VkDevice, *const VkMemoryAllocateInfo, ?*const anyopaque, *VkDeviceMemory) callconv(.c) i32 = undefined,
    freeMemory: *const fn (VkDevice, VkDeviceMemory, ?*const anyopaque) callconv(.c) void = undefined,
    bindBufferMemory: *const fn (VkDevice, VkBuffer, VkDeviceMemory, u64) callconv(.c) i32 = undefined,
    mapMemory: *const fn (VkDevice, VkDeviceMemory, u64, u64, u32, *?*anyopaque) callconv(.c) i32 = undefined,
    unmapMemory: *const fn (VkDevice, VkDeviceMemory) callconv(.c) void = undefined,
    createShaderModule: *const fn (VkDevice, *const anyopaque, ?*const anyopaque, *VkShaderModule) callconv(.c) i32 = undefined,
    destroyShaderModule: *const fn (VkDevice, VkShaderModule, ?*const anyopaque) callconv(.c) void = undefined,
    createDescriptorSetLayout: *const fn (VkDevice, *const anyopaque, ?*const anyopaque, *VkDescriptorSetLayout) callconv(.c) i32 = undefined,
    destroyDescriptorSetLayout: *const fn (VkDevice, VkDescriptorSetLayout, ?*const anyopaque) callconv(.c) void = undefined,
    createPipelineLayout: *const fn (VkDevice, *const anyopaque, ?*const anyopaque, *VkPipelineLayout) callconv(.c) i32 = undefined,
    destroyPipelineLayout: *const fn (VkDevice, VkPipelineLayout, ?*const anyopaque) callconv(.c) void = undefined,
    createComputePipelines: *const fn (VkDevice, ?*anyopaque, u32, *const anyopaque, ?*const anyopaque, *VkPipeline) callconv(.c) i32 = undefined,
    destroyPipeline: *const fn (VkDevice, VkPipeline, ?*const anyopaque) callconv(.c) void = undefined,
    createDescriptorPool: *const fn (VkDevice, *const anyopaque, ?*const anyopaque, *VkDescriptorPool) callconv(.c) i32 = undefined,
    destroyDescriptorPool: *const fn (VkDevice, VkDescriptorPool, ?*const anyopaque) callconv(.c) void = undefined,
    allocateDescriptorSets: *const fn (VkDevice, *const anyopaque, *VkDescriptorSet) callconv(.c) i32 = undefined,
    updateDescriptorSets: *const fn (VkDevice, u32, *const anyopaque, u32, ?*const anyopaque) callconv(.c) void = undefined,
    createCommandPool: *const fn (VkDevice, *const anyopaque, ?*const anyopaque, *VkCommandPool) callconv(.c) i32 = undefined,
    destroyCommandPool: *const fn (VkDevice, VkCommandPool, ?*const anyopaque) callconv(.c) void = undefined,
    allocateCommandBuffers: *const fn (VkDevice, *const anyopaque, *VkCommandBuffer) callconv(.c) i32 = undefined,
    beginCommandBuffer: *const fn (VkCommandBuffer, *const anyopaque) callconv(.c) i32 = undefined,
    endCommandBuffer: *const fn (VkCommandBuffer) callconv(.c) i32 = undefined,
    resetCommandBuffer: *const fn (VkCommandBuffer, u32) callconv(.c) i32 = undefined,
    cmdBindPipeline: *const fn (VkCommandBuffer, u32, VkPipeline) callconv(.c) void = undefined,
    cmdBindDescriptorSets: *const fn (VkCommandBuffer, u32, VkPipelineLayout, u32, u32, *const VkDescriptorSet, u32, ?*const u32) callconv(.c) void = undefined,
    cmdPushConstants: *const fn (VkCommandBuffer, VkPipelineLayout, u32, u32, u32, *const anyopaque) callconv(.c) void = undefined,
    cmdDispatch: *const fn (VkCommandBuffer, u32, u32, u32) callconv(.c) void = undefined,
    cmdCopyBuffer: *const fn (VkCommandBuffer, VkBuffer, VkBuffer, u32, *const VkBufferCopy) callconv(.c) void = undefined,
    cmdPipelineBarrier: *const fn (VkCommandBuffer, u32, u32, u32, u32, ?*const anyopaque, u32, ?*const VkBufferMemoryBarrier, u32, ?*const anyopaque) callconv(.c) void = undefined,
    queueSubmit: *const fn (VkQueue, u32, *const anyopaque, VkFence) callconv(.c) i32 = undefined,
    createFence: *const fn (VkDevice, *const anyopaque, ?*const anyopaque, *VkFence) callconv(.c) i32 = undefined,
    destroyFence: *const fn (VkDevice, VkFence, ?*const anyopaque) callconv(.c) void = undefined,
    waitForFences: *const fn (VkDevice, u32, *const VkFence, u32, u64) callconv(.c) i32 = undefined,
    resetFences: *const fn (VkDevice, u32, *const VkFence) callconv(.c) i32 = undefined,
    deviceWaitIdle: *const fn (VkDevice) callconv(.c) i32 = undefined,
};

// ============================================================
// GPU Buffer: VRAM or staging allocation
// ============================================================

const GpuBuffer = struct {
    buffer: VkBuffer = null,
    memory: VkDeviceMemory = null,
    size: u64 = 0,
};

// ============================================================
// WeightSlot: a view into the weight buffer
// ============================================================

/// References a contiguous region of model weights on GPU.
/// Returned by uploadWeights, consumed by matvec/superlinear.
pub const WeightSlot = struct {
    /// Byte offset into the GPU weight buffer
    offset: u64,
    /// Dimensions of the weight matrix
    rows: u32,
    cols: u32,
};

// ============================================================
// Push constants — parameterize shaders at dispatch time
// ============================================================

/// Matvec: out[dst_offset + R] = W_f16[R×C] · x_f32[src_offset + C]
/// src_offset/dst_offset enable batched ops: multiple dispatches share one submit.
const MatvecPC = extern struct {
    rows: u32,
    cols: u32,
    weight_offset: u32, // f16 element offset into weight buffer
    src_offset: u32 = 0, // f32 element offset into input buffer
    dst_offset: u32 = 0, // f32 element offset into output buffer
};

/// SuperLinear: out[N,O] = einsum('NM, MON -> NO', x[N,M], w[M,O,N])
const SuperlinearPC = extern struct {
    n_neurons: u32, // N
    in_dims: u32, // M
    out_dims: u32, // O
    weight_offset: u32, // f32 element offset
};

// ============================================================
// GpuContext — the Vulkan compute service
// ============================================================

pub const GpuContext = struct {
    // Vulkan state
    vk: VkFns = .{},
    lib: ?*anyopaque = null,
    instance: VkInstance = null,
    physical_device: VkPhysicalDevice = null,
    device: VkDevice = null,
    queue: VkQueue = null,
    queue_family: u32 = 0,
    cmd_pool: VkCommandPool = null,
    cmd_buf: VkCommandBuffer = null,
    fence: VkFence = null,

    // Device info
    device_name: [256]u8 = [_]u8{0} ** 256,
    device_type: u32 = 0,
    vram_bytes: u64 = 0,

    // Buffers
    weight_buf: GpuBuffer = .{}, // all model weights, device-local
    staging_buf: GpuBuffer = .{}, // host-visible, persistently mapped
    staging_ptr: ?[*]u8 = null,
    staging_size: u64 = 0,
    input_buf: GpuBuffer = .{}, // device-local, input vector
    output_buf: GpuBuffer = .{}, // device-local, output vector

    // Pipelines (one per operation type)
    matvec_pipeline: VkPipeline = null,
    matvec_layout: VkPipelineLayout = null,
    matvec_f32_pipeline: VkPipeline = null, // f32 weights (CTM)
    matvec_silu_f32_pipeline: VkPipeline = null, // fused matmul+SiLU for cascade
    superlinear_pipeline: VkPipeline = null,
    superlinear_layout: VkPipelineLayout = null,

    // Descriptors
    desc_pool: VkDescriptorPool = null,
    desc_layout: VkDescriptorSetLayout = null,
    desc_set: VkDescriptorSet = null,

    ready: bool = false,
    allocator: Allocator = undefined,

    // Batch state: record multiple dispatches, one submit
    batch_recording: bool = false,
    batch_output_cursor: u32 = 0, // f32 elements written to output_buf so far
    batch_input_bytes: u64 = 0, // bytes of input currently in input_buf

    // ── Service lifecycle ─────────────────────────────────────

    /// Try to create GPU compute service. Returns null if Vulkan unavailable.
    /// prefer_igpu: select integrated GPU (shared memory, lower latency for small ops)
    pub fn init(alloc: Allocator, prefer_igpu: bool) ?GpuContext {
        // Allow disabling GPU for benchmarking/debugging
        if (std.posix.getenv("ZISH_NO_GPU")) |_| return null;

        var self = GpuContext{ .allocator = alloc };

        // Load Vulkan shared library via dlopen (requires libc linking)
        self.lib = std.c.dlopen("libvulkan.so.1", .{ .LAZY = true }) orelse
            std.c.dlopen("libvulkan.so", .{ .LAZY = true }) orelse return null;

        const getAddr: PFN_vkGetInstanceProcAddr = @ptrCast(
            std.c.dlsym(self.lib.?, "vkGetInstanceProcAddr") orelse return null,
        );

        self.vk.createInstance = @ptrCast(getAddr(null, "vkCreateInstance") orelse return null);

        // Create instance
        const app_info = extern struct {
            sType: u32 = 0,
            pNext: ?*const anyopaque = null,
            pApplicationName: [*:0]const u8 = "zish",
            applicationVersion: u32 = 1,
            pEngineName: [*:0]const u8 = "zish",
            engineVersion: u32 = 1,
            apiVersion: u32 = (1 << 22) | (3 << 12), // 1.3
        }{};
        const inst_ci = extern struct {
            sType: u32 = STYPE_INSTANCE_CI,
            pNext: ?*const anyopaque = null,
            flags: u32 = 0,
            pApplicationInfo: *const anyopaque,
            enabledLayerCount: u32 = 0,
            ppEnabledLayerNames: ?*const anyopaque = null,
            enabledExtensionCount: u32 = 0,
            ppEnabledExtensionNames: ?*const anyopaque = null,
        }{ .pApplicationInfo = &app_info };

        if (self.vk.createInstance(&inst_ci, null, &self.instance) != VK_SUCCESS) return null;

        // Load all function pointers
        self.loadFunctions(getAddr);

        // Pick physical device
        if (!self.pickDevice(prefer_igpu)) {
            self.deinit();
            return null;
        }

        // Create logical device + queue
        if (!self.createDeviceAndQueue()) {
            self.deinit();
            return null;
        }

        // Command pool + buffer + fence
        if (!self.createCommandInfra()) {
            self.deinit();
            return null;
        }

        // Staging buffer: 512KB covers any vector (vocab_size * 4 bytes for classifier)
        self.staging_size = 1024 * 1024;
        if (!self.allocBuffer(self.staging_size, VK_BUFFER_USAGE_TRANSFER_SRC | VK_BUFFER_USAGE_TRANSFER_DST, VK_MEMORY_PROPERTY_HOST_VISIBLE | VK_MEMORY_PROPERTY_HOST_COHERENT, &self.staging_buf)) {
            self.deinit();
            return null;
        }

        // Persistently map staging
        var ptr: ?*anyopaque = null;
        if (self.vk.mapMemory(self.device, self.staging_buf.memory, 0, self.staging_size, 0, &ptr) != VK_SUCCESS) {
            self.deinit();
            return null;
        }
        self.staging_ptr = @ptrCast(ptr);

        self.ready = true;
        return self;
    }

    /// Upload raw weight data to VRAM. Call once at model load time.
    /// Returns true on success. After this, use WeightSlots to reference regions.
    pub fn uploadWeights(self: *GpuContext, data: []const u8) bool {
        if (!self.ready) return false;

        const size: u64 = @intCast(data.len);

        // Allocate device-local weight buffer
        if (!self.allocBuffer(size, VK_BUFFER_USAGE_STORAGE_BUFFER | VK_BUFFER_USAGE_TRANSFER_DST, VK_MEMORY_PROPERTY_DEVICE_LOCAL, &self.weight_buf)) {
            return false;
        }

        // Allocate device-local IO buffers — both need transfer src+dst for cascade ping-pong
        if (!self.allocBuffer(512 * 1024, VK_BUFFER_USAGE_STORAGE_BUFFER | VK_BUFFER_USAGE_TRANSFER_DST | VK_BUFFER_USAGE_TRANSFER_SRC, VK_MEMORY_PROPERTY_DEVICE_LOCAL, &self.input_buf)) return false;
        if (!self.allocBuffer(1024 * 1024, VK_BUFFER_USAGE_STORAGE_BUFFER | VK_BUFFER_USAGE_TRANSFER_SRC | VK_BUFFER_USAGE_TRANSFER_DST, VK_MEMORY_PROPERTY_DEVICE_LOCAL, &self.output_buf)) return false;

        // Upload in chunks via staging
        var offset: u64 = 0;
        while (offset < size) {
            const chunk = @min(size - offset, self.staging_size);
            const src = data[@intCast(offset)..][0..@intCast(chunk)];
            @memcpy(self.staging_ptr.?[0..@intCast(chunk)], src);

            if (!self.copyBuffer(self.staging_buf.buffer, self.weight_buf.buffer, 0, offset, chunk)) {
                return false;
            }
            offset += chunk;
        }

        // Build pipelines + descriptors
        return self.createPipelines();
    }

    // ── Operations (composable functions) ─────────────────────

    /// Mat-vec multiply: output[rows] = weights_f16[rows × cols] × input[cols]
    /// This is the primary operation — covers ~90% of inference FLOPS.
    pub fn matvec(self: *GpuContext, input: []const f32, output: []f32, slot: WeightSlot) bool {
        if (!self.ready or self.matvec_pipeline == null) return false;

        const rows = slot.rows;
        const cols = slot.cols;
        const input_bytes: u64 = @intCast(cols * @sizeOf(f32));
        const output_bytes: u64 = @intCast(rows * @sizeOf(f32));

        if (input_bytes + output_bytes > self.staging_size) return false;

        // Write input to staging[0..input_bytes]
        @memcpy(self.staging_ptr.?[0..@intCast(input_bytes)], std.mem.sliceAsBytes(input[0..cols]));

        // Record commands
        if (!self.beginCmd()) return false;

        // staging → input_buf
        self.cmdCopy(self.staging_buf.buffer, self.input_buf.buffer, 0, 0, input_bytes);
        self.cmdBarrier(self.input_buf.buffer, ACCESS_TRANSFER_WRITE, ACCESS_SHADER_READ, STAGE_TRANSFER, STAGE_COMPUTE);

        // Dispatch matvec
        self.vk.cmdBindPipeline(self.cmd_buf, VK_PIPELINE_BIND_POINT_COMPUTE, self.matvec_pipeline);
        self.vk.cmdBindDescriptorSets(self.cmd_buf, VK_PIPELINE_BIND_POINT_COMPUTE, self.matvec_layout, 0, 1, &self.desc_set, 0, null);

        const pc = MatvecPC{
            .rows = rows,
            .cols = cols,
            .weight_offset = @intCast(slot.offset / 2), // byte offset → f16 element offset
        };
        self.vk.cmdPushConstants(self.cmd_buf, self.matvec_layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(MatvecPC), &pc);

        // One workgroup per 2 output rows (NUM_ROWS=2 in shader), 256 threads
        self.vk.cmdDispatch(self.cmd_buf, (rows + 1) / 2, 1, 1);

        // output_buf → staging
        self.cmdBarrier(self.output_buf.buffer, ACCESS_SHADER_WRITE, ACCESS_TRANSFER_READ, STAGE_COMPUTE, STAGE_TRANSFER);
        self.cmdCopy(self.output_buf.buffer, self.staging_buf.buffer, 0, input_bytes, output_bytes);

        if (!self.endAndSubmit()) return false;

        // Read output from staging[input_bytes..]
        const out_ptr: [*]const f32 = @ptrCast(@alignCast(self.staging_ptr.? + @as(usize, @intCast(input_bytes))));
        @memcpy(output[0..rows], out_ptr[0..rows]);

        return true;
    }

    /// Mat-vec with f32 weights: output[rows] = weights_f32[rows × cols] × input[cols]
    /// Used for CTM operations (cross-attention projections, c_proj).
    pub fn matvecF32(self: *GpuContext, input: []const f32, output: []f32, slot: WeightSlot) bool {
        if (!self.ready or self.matvec_f32_pipeline == null) return false;

        const rows = slot.rows;
        const cols = slot.cols;
        const input_bytes: u64 = @intCast(cols * @sizeOf(f32));
        const output_bytes: u64 = @intCast(rows * @sizeOf(f32));

        if (input_bytes + output_bytes > self.staging_size) return false;

        @memcpy(self.staging_ptr.?[0..@intCast(input_bytes)], std.mem.sliceAsBytes(input[0..cols]));

        if (!self.beginCmd()) return false;

        self.cmdCopy(self.staging_buf.buffer, self.input_buf.buffer, 0, 0, input_bytes);
        self.cmdBarrier(self.input_buf.buffer, ACCESS_TRANSFER_WRITE, ACCESS_SHADER_READ, STAGE_TRANSFER, STAGE_COMPUTE);

        self.vk.cmdBindPipeline(self.cmd_buf, VK_PIPELINE_BIND_POINT_COMPUTE, self.matvec_f32_pipeline);
        self.vk.cmdBindDescriptorSets(self.cmd_buf, VK_PIPELINE_BIND_POINT_COMPUTE, self.matvec_layout, 0, 1, &self.desc_set, 0, null);

        const pc = MatvecPC{
            .rows = rows,
            .cols = cols,
            .weight_offset = @intCast(slot.offset / 4), // byte offset → f32 element offset
        };
        self.vk.cmdPushConstants(self.cmd_buf, self.matvec_layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(MatvecPC), &pc);
        self.vk.cmdDispatch(self.cmd_buf, (rows + 1) / 2, 1, 1);

        self.cmdBarrier(self.output_buf.buffer, ACCESS_SHADER_WRITE, ACCESS_TRANSFER_READ, STAGE_COMPUTE, STAGE_TRANSFER);
        self.cmdCopy(self.output_buf.buffer, self.staging_buf.buffer, 0, input_bytes, output_bytes);

        if (!self.endAndSubmit()) return false;

        const out_ptr: [*]const f32 = @ptrCast(@alignCast(self.staging_ptr.? + @as(usize, @intCast(input_bytes))));
        @memcpy(output[0..rows], out_ptr[0..rows]);

        return true;
    }

    /// Batched f32 matvec: beginPass → recordMatvecF32 → endPass
    pub fn beginPassF32(self: *GpuContext, input: []const f32) bool {
        if (!self.ready or self.matvec_f32_pipeline == null) return false;

        const input_bytes: u64 = @intCast(input.len * @sizeOf(f32));
        if (input_bytes > self.staging_size) return false;

        @memcpy(self.staging_ptr.?[0..@intCast(input_bytes)], std.mem.sliceAsBytes(input));

        if (!self.beginCmd()) return false;

        self.cmdCopy(self.staging_buf.buffer, self.input_buf.buffer, 0, 0, input_bytes);
        self.cmdBarrier(self.input_buf.buffer, ACCESS_TRANSFER_WRITE, ACCESS_SHADER_READ, STAGE_TRANSFER, STAGE_COMPUTE);

        self.vk.cmdBindPipeline(self.cmd_buf, VK_PIPELINE_BIND_POINT_COMPUTE, self.matvec_f32_pipeline);
        self.vk.cmdBindDescriptorSets(self.cmd_buf, VK_PIPELINE_BIND_POINT_COMPUTE, self.matvec_layout, 0, 1, &self.desc_set, 0, null);

        self.batch_recording = true;
        self.batch_output_cursor = 0;
        self.batch_input_bytes = input_bytes;
        return true;
    }

    /// Record f32 matvec into current batch. Weight offset in BYTES (divided by 4 internally).
    pub fn recordMatvecF32(self: *GpuContext, slot: WeightSlot) ?u32 {
        if (!self.batch_recording) return null;

        const rows = slot.rows;
        const dst_offset = self.batch_output_cursor;
        const output_end: u64 = @intCast((dst_offset + rows) * @sizeOf(f32));
        if (output_end > 1024 * 1024) return null;

        if (dst_offset > 0) {
            self.cmdBarrier(self.output_buf.buffer, ACCESS_SHADER_WRITE, ACCESS_SHADER_WRITE, STAGE_COMPUTE, STAGE_COMPUTE);
        }

        const pc = MatvecPC{
            .rows = rows,
            .cols = slot.cols,
            .weight_offset = @intCast(slot.offset / 4), // byte → f32 element
            .src_offset = 0,
            .dst_offset = dst_offset,
        };
        self.vk.cmdPushConstants(self.cmd_buf, self.matvec_layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(MatvecPC), &pc);
        self.vk.cmdDispatch(self.cmd_buf, (rows + 1) / 2, 1, 1);

        self.batch_output_cursor = dst_offset + rows;
        return dst_offset;
    }

    /// SuperLinear: per-neuron independent mat-vec (CTM NLM layers)
    /// out[N×O] = einsum('NM, MON -> NO', x[N×M], w[M×O×N])
    /// Weight slot points to w[M,O,N] in f32 format on GPU.
    pub fn superlinear(
        self: *GpuContext,
        input: []const f32, // N*M f32s
        output: []f32, // N*O f32s
        bias: []const f32, // N*O f32s
        n_neurons: u32,
        in_dims: u32,
        out_dims: u32,
        slot: WeightSlot,
    ) bool {
        if (!self.ready or self.superlinear_pipeline == null) return false;

        const input_bytes: u64 = @intCast(n_neurons * in_dims * @sizeOf(f32));
        const output_bytes: u64 = @intCast(n_neurons * out_dims * @sizeOf(f32));
        const bias_bytes: u64 = @intCast(bias.len * @sizeOf(f32));

        if (input_bytes + output_bytes + bias_bytes > self.staging_size) return false;

        // Pack staging: [input | bias]
        @memcpy(self.staging_ptr.?[0..@intCast(input_bytes)], std.mem.sliceAsBytes(input[0 .. n_neurons * in_dims]));
        @memcpy(self.staging_ptr.?[@intCast(input_bytes)..][0..@intCast(bias_bytes)], std.mem.sliceAsBytes(bias));

        if (!self.beginCmd()) return false;

        // Upload input + bias
        self.cmdCopy(self.staging_buf.buffer, self.input_buf.buffer, 0, 0, input_bytes + bias_bytes);
        self.cmdBarrier(self.input_buf.buffer, ACCESS_TRANSFER_WRITE, ACCESS_SHADER_READ, STAGE_TRANSFER, STAGE_COMPUTE);

        self.vk.cmdBindPipeline(self.cmd_buf, VK_PIPELINE_BIND_POINT_COMPUTE, self.superlinear_pipeline);
        self.vk.cmdBindDescriptorSets(self.cmd_buf, VK_PIPELINE_BIND_POINT_COMPUTE, self.superlinear_layout, 0, 1, &self.desc_set, 0, null);

        const pc = SuperlinearPC{
            .n_neurons = n_neurons,
            .in_dims = in_dims,
            .out_dims = out_dims,
            .weight_offset = @intCast(slot.offset / 4), // byte → f32 element
        };
        self.vk.cmdPushConstants(self.cmd_buf, self.superlinear_layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(SuperlinearPC), &pc);

        // One workgroup per neuron
        self.vk.cmdDispatch(self.cmd_buf, n_neurons, 1, 1);

        self.cmdBarrier(self.output_buf.buffer, ACCESS_SHADER_WRITE, ACCESS_TRANSFER_READ, STAGE_COMPUTE, STAGE_TRANSFER);
        self.cmdCopy(self.output_buf.buffer, self.staging_buf.buffer, 0, 0, output_bytes);

        if (!self.endAndSubmit()) return false;

        const out_ptr: [*]const f32 = @ptrCast(@alignCast(self.staging_ptr.?));
        @memcpy(output[0 .. n_neurons * out_dims], out_ptr[0 .. n_neurons * out_dims]);

        return true;
    }

    /// Batched mat-vec: run multiple independent mat-vecs in a single dispatch.
    /// Useful for SynapseUNET cascade (many small mat-vecs) or QKV projections.
    /// Each batch item has its own weight slot and output region.
    pub fn batchMatvec(
        self: *GpuContext,
        input: []const f32,
        outputs: [][]f32,
        slots: []const WeightSlot,
    ) bool {
        // For now, sequential fallback. When we have the batch shader, this
        // becomes a single dispatch with batch_id in push constants.
        for (slots, 0..) |slot, i| {
            if (!self.matvec(input, outputs[i], slot)) return false;
        }
        return true;
    }

    /// Device name as printable string.
    pub fn deviceNameSlice(self: *const GpuContext) []const u8 {
        for (self.device_name, 0..) |c, i| {
            if (c == 0) return self.device_name[0..i];
        }
        return &self.device_name;
    }

    /// Returns true if this is a discrete GPU (dedicated VRAM).
    pub fn isDiscrete(self: *const GpuContext) bool {
        return self.device_type == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU;
    }

    // ── Batch API: multiple dispatches, one submit ─────────────
    //
    // Server as a Function: compose GPU operations into a single pass.
    // Instead of N fence-waits per layer, batch all matmuls → one submit.
    //
    // Usage:
    //   gpu.beginPass(input_vec)          — upload input, begin recording
    //   gpu.recordMatvec(slot, rows)      — append dispatch (no sync)
    //   gpu.recordMatvec(slot2, rows2)    — append another dispatch
    //   gpu.endPass(outputs)              — one submit, one fence, read all results

    /// Begin a batched pass. Uploads the shared input vector to VRAM.
    /// All subsequent recordMatvec calls share this input.
    pub fn beginPass(self: *GpuContext, input: []const f32) bool {
        if (!self.ready or self.matvec_pipeline == null) return false;

        const input_bytes: u64 = @intCast(input.len * @sizeOf(f32));
        if (input_bytes > self.staging_size) return false;

        // Upload input to staging
        @memcpy(self.staging_ptr.?[0..@intCast(input_bytes)], std.mem.sliceAsBytes(input));

        if (!self.beginCmd()) return false;

        // staging → input_buf
        self.cmdCopy(self.staging_buf.buffer, self.input_buf.buffer, 0, 0, input_bytes);
        self.cmdBarrier(self.input_buf.buffer, ACCESS_TRANSFER_WRITE, ACCESS_SHADER_READ, STAGE_TRANSFER, STAGE_COMPUTE);

        // Bind pipeline + descriptors once for all dispatches
        self.vk.cmdBindPipeline(self.cmd_buf, VK_PIPELINE_BIND_POINT_COMPUTE, self.matvec_pipeline);
        self.vk.cmdBindDescriptorSets(self.cmd_buf, VK_PIPELINE_BIND_POINT_COMPUTE, self.matvec_layout, 0, 1, &self.desc_set, 0, null);

        self.batch_recording = true;
        self.batch_output_cursor = 0;
        self.batch_input_bytes = input_bytes;
        return true;
    }

    /// Record a matvec dispatch into the current batch.
    /// Output is appended to output_buf at the current cursor position.
    /// Returns the dst_offset (f32 elements) where results will be written,
    /// or null if the dispatch couldn't be recorded.
    pub fn recordMatvec(self: *GpuContext, slot: WeightSlot) ?u32 {
        if (!self.batch_recording) return null;

        const rows = slot.rows;
        const cols = slot.cols;
        const dst_offset = self.batch_output_cursor;
        const output_end: u64 = @intCast((dst_offset + rows) * @sizeOf(f32));
        if (output_end > 1024 * 1024) return null; // exceeds output_buf

        // Compute → compute barrier (previous dispatch may have written to output_buf)
        if (dst_offset > 0) {
            self.cmdBarrier(self.output_buf.buffer, ACCESS_SHADER_WRITE, ACCESS_SHADER_WRITE, STAGE_COMPUTE, STAGE_COMPUTE);
        }

        const pc = MatvecPC{
            .rows = rows,
            .cols = cols,
            .weight_offset = @intCast(slot.offset / 2),
            .src_offset = 0, // input always at start of input_buf
            .dst_offset = dst_offset,
        };
        self.vk.cmdPushConstants(self.cmd_buf, self.matvec_layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(MatvecPC), &pc);
        self.vk.cmdDispatch(self.cmd_buf, (rows + 1) / 2, 1, 1);

        self.batch_output_cursor = dst_offset + rows;
        return dst_offset;
    }

    /// End the batch: submit all recorded dispatches, fence-wait, read results.
    /// Copies the full output region back to staging for readback.
    pub fn endPass(self: *GpuContext) bool {
        if (!self.batch_recording) return false;
        self.batch_recording = false;

        if (self.batch_output_cursor == 0) {
            // No dispatches recorded — just end the command buffer
            _ = self.vk.endCommandBuffer(self.cmd_buf);
            return true;
        }

        const output_bytes: u64 = @intCast(self.batch_output_cursor * @sizeOf(f32));

        // output_buf → staging (after input region)
        self.cmdBarrier(self.output_buf.buffer, ACCESS_SHADER_WRITE, ACCESS_TRANSFER_READ, STAGE_COMPUTE, STAGE_TRANSFER);
        self.cmdCopy(self.output_buf.buffer, self.staging_buf.buffer, 0, self.batch_input_bytes, output_bytes);

        return self.endAndSubmit();
    }

    /// Read a result from the last completed batch.
    /// offset/count are in f32 elements, matching the dst_offset from recordMatvec.
    pub fn readBatchOutput(self: *GpuContext, offset: u32, dest: []f32) void {
        const byte_start = self.batch_input_bytes + @as(u64, offset) * @sizeOf(f32);
        const out_ptr: [*]const f32 = @ptrCast(@alignCast(self.staging_ptr.? + @as(usize, @intCast(byte_start))));
        @memcpy(dest, out_ptr[0..dest.len]);
    }

    // ── Cascade API: sequential fused matmul+SiLU, one submit ──
    //
    // For SynapseUNET down-path: each layer's activated output feeds the next.
    // One command buffer records all dispatches with output→input copies between.
    // Result: one fence wait instead of N, all data stays in VRAM.
    // Skip connections accumulate in output_buf at increasing offsets for
    // bulk readback.

    /// A single step in a cascade: fused matmul+SiLU from weight at byte offset.
    pub const CascadeStep = struct {
        weight_byte_offset: u64,
        rows: u32, // output dimension
        cols: u32, // input dimension
        silu: bool = true, // apply SiLU activation (false for final layer)
    };

    /// Execute a cascade of f32 fused matmul+SiLU operations.
    /// Each step: input_buf[0..cols] × W → SiLU → output_buf, then copy back to input_buf.
    /// All skip connection outputs are packed into output_buf at increasing offsets.
    /// After endAndSubmit, call readCascadeSkip to read individual skip outputs.
    /// Returns true on success, writing final step output to `result`.
    pub fn cascadeF32(
        self: *GpuContext,
        input: []const f32,
        result: []f32,
        steps: []const CascadeStep,
        skip_outputs: ?[][]f32, // if non-null, reads back each step's output into these slices
    ) bool {
        if (!self.ready or steps.len == 0) return false;
        const silu_pipe = self.matvec_silu_f32_pipeline orelse return false;
        const plain_pipe = self.matvec_f32_pipeline orelse return false;

        const input_bytes: u64 = @intCast(input.len * @sizeOf(f32));
        if (input_bytes > 512 * 1024) return false;

        // Upload input to staging → input_buf
        @memcpy(self.staging_ptr.?[0..@intCast(input_bytes)], std.mem.sliceAsBytes(input));
        if (!self.beginCmd()) return false;

        self.cmdCopy(self.staging_buf.buffer, self.input_buf.buffer, 0, 0, input_bytes);
        self.cmdBarrier(self.input_buf.buffer, ACCESS_TRANSFER_WRITE, ACCESS_SHADER_READ, STAGE_TRANSFER, STAGE_COMPUTE);

        // Track where skip outputs accumulate in output_buf
        var skip_cursor: u64 = 0; // byte offset into output_buf for skip storage

        self.vk.cmdBindDescriptorSets(self.cmd_buf, VK_PIPELINE_BIND_POINT_COMPUTE, self.matvec_layout, 0, 1, &self.desc_set, 0, null);

        var last_pipe_is_silu = false;
        for (steps) |step| {
            // Select pipeline: fused matmul+SiLU or plain matmul
            const pipe = if (step.silu) silu_pipe else plain_pipe;
            if (step.silu != last_pipe_is_silu or step.silu == steps[0].silu) {
                self.vk.cmdBindPipeline(self.cmd_buf, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
                last_pipe_is_silu = step.silu;
            }

            const pc = MatvecPC{
                .rows = step.rows,
                .cols = step.cols,
                .weight_offset = @intCast(step.weight_byte_offset / 4),
                .src_offset = 0,
                .dst_offset = 0,
            };
            self.vk.cmdPushConstants(self.cmd_buf, self.matvec_layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(MatvecPC), &pc);
            self.vk.cmdDispatch(self.cmd_buf, (step.rows + 1) / 2, 1, 1);

            const out_bytes: u64 = @intCast(step.rows * @sizeOf(f32));

            // Barrier: compute write → transfer read
            self.cmdBarrier(self.output_buf.buffer, ACCESS_SHADER_WRITE, ACCESS_TRANSFER_READ, STAGE_COMPUTE, STAGE_TRANSFER);

            // If we need skip outputs, copy to staging at accumulating offset
            if (skip_outputs != null) {
                self.cmdCopy(self.output_buf.buffer, self.staging_buf.buffer, 0, skip_cursor, out_bytes);
                skip_cursor += out_bytes;
            }

            // Copy output → input for next step
            self.cmdCopy(self.output_buf.buffer, self.input_buf.buffer, 0, 0, out_bytes);
            self.cmdBarrier(self.input_buf.buffer, ACCESS_TRANSFER_WRITE, ACCESS_SHADER_READ, STAGE_TRANSFER, STAGE_COMPUTE);
        }

        // If no skip outputs requested, copy final result to staging
        if (skip_outputs == null) {
            const last_bytes: u64 = @intCast(steps[steps.len - 1].rows * @sizeOf(f32));
            self.cmdBarrier(self.output_buf.buffer, ACCESS_TRANSFER_READ, ACCESS_TRANSFER_READ, STAGE_TRANSFER, STAGE_TRANSFER);
            self.cmdCopy(self.output_buf.buffer, self.staging_buf.buffer, 0, 0, last_bytes);
        }

        if (!self.endAndSubmit()) return false;

        // Read results from staging
        if (skip_outputs) |skips| {
            var off: usize = 0;
            for (skips, 0..) |skip, i| {
                const n = steps[i].rows;
                const ptr: [*]const f32 = @ptrCast(@alignCast(self.staging_ptr.? + off));
                @memcpy(skip[0..n], ptr[0..n]);
                off += n * @sizeOf(f32);
            }
            // Final result is the last skip
            @memcpy(result, skips[skips.len - 1][0..steps[steps.len - 1].rows]);
        } else {
            const ptr: [*]const f32 = @ptrCast(@alignCast(self.staging_ptr.?));
            const n = steps[steps.len - 1].rows;
            @memcpy(result[0..n], ptr[0..n]);
        }
        return true;
    }

    // ── Internal: device selection ────────────────────────────

    fn loadFunctions(self: *GpuContext, getAddr: PFN_vkGetInstanceProcAddr) void {
        // Load all VkFns fields via vkGetInstanceProcAddr
        // Field names map to Vulkan function names: camelCase → vkCamelCase
        inline for (@typeInfo(VkFns).@"struct".fields) |field| {
            if (comptime !std.mem.eql(u8, field.name, "createInstance")) {
                const vk_name = comptime blk: {
                    var buf: [64:0]u8 = [_:0]u8{0} ** 64;
                    buf[0] = 'v';
                    buf[1] = 'k';
                    buf[2] = std.ascii.toUpper(field.name[0]);
                    for (field.name[1..], 0..) |c, i| buf[3 + i] = c;
                    break :blk buf;
                };
                if (getAddr(self.instance, &vk_name)) |fp| {
                    @field(self.vk, field.name) = @ptrCast(fp);
                }
            }
        }
    }

    fn pickDevice(self: *GpuContext, prefer_igpu: bool) bool {
        var count: u32 = 0;
        if (self.vk.enumeratePhysicalDevices(self.instance, &count, null) != VK_SUCCESS or count == 0)
            return false;

        var devs: [8]VkPhysicalDevice = [_]VkPhysicalDevice{null} ** 8;
        var n: u32 = @min(count, 8);
        if (self.vk.enumeratePhysicalDevices(self.instance, &n, &devs) != VK_SUCCESS)
            return false;

        const target: u32 = if (prefer_igpu) VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU else VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU;
        var best: ?VkPhysicalDevice = null;
        var best_props: VkPhysicalDeviceProperties = .{};

        for (devs[0..n]) |dev| {
            if (dev == null) continue;
            var props: VkPhysicalDeviceProperties = .{};
            self.vk.getPhysicalDeviceProperties(dev, &props);

            // AMD vendor ID: 0x1002
            if (props.deviceType == target) {
                best = dev;
                best_props = props;
                break;
            }
            if (best == null) {
                best = dev;
                best_props = props;
            }
        }

        self.physical_device = best orelse return false;
        self.device_name = best_props.deviceName;
        self.device_type = best_props.deviceType;

        // Get VRAM size
        var mem_props: VkPhysicalDeviceMemoryProperties = .{};
        self.vk.getPhysicalDeviceMemoryProperties(self.physical_device, &mem_props);
        for (mem_props.memoryHeaps[0..mem_props.memoryHeapCount]) |heap| {
            if (heap.size > self.vram_bytes) self.vram_bytes = heap.size;
        }

        return true;
    }

    fn createDeviceAndQueue(self: *GpuContext) bool {
        // Find compute queue family
        var qf_count: u32 = 0;
        self.vk.getPhysicalDeviceQueueFamilyProperties(self.physical_device, &qf_count, null);
        var qf: [8]VkQueueFamilyProperties = [_]VkQueueFamilyProperties{.{}} ** 8;
        var qf_n: u32 = @min(qf_count, 8);
        self.vk.getPhysicalDeviceQueueFamilyProperties(self.physical_device, &qf_n, &qf);

        var found = false;
        for (qf[0..qf_n], 0..) |q, i| {
            if (q.queueFlags & VK_QUEUE_COMPUTE_BIT != 0) {
                self.queue_family = @intCast(i);
                found = true;
                break;
            }
        }
        if (!found) return false;

        const priority: f32 = 1.0;
        const queue_ci = extern struct {
            sType: u32 = STYPE_DEVICE_QUEUE_CI,
            pNext: ?*const anyopaque = null,
            flags: u32 = 0,
            queueFamilyIndex: u32,
            queueCount: u32 = 1,
            pQueuePriorities: *const f32,
        }{ .queueFamilyIndex = self.queue_family, .pQueuePriorities = &priority };

        const dev_ci = extern struct {
            sType: u32 = STYPE_DEVICE_CI,
            pNext: ?*const anyopaque = null,
            flags: u32 = 0,
            queueCreateInfoCount: u32 = 1,
            pQueueCreateInfos: *const anyopaque,
            enabledLayerCount: u32 = 0,
            ppEnabledLayerNames: ?*const anyopaque = null,
            enabledExtensionCount: u32 = 0,
            ppEnabledExtensionNames: ?*const anyopaque = null,
            pEnabledFeatures: ?*const anyopaque = null,
        }{ .pQueueCreateInfos = &queue_ci };

        if (self.vk.createDevice(self.physical_device, &dev_ci, null, &self.device) != VK_SUCCESS)
            return false;

        self.vk.getDeviceQueue(self.device, self.queue_family, 0, &self.queue);
        return true;
    }

    fn createCommandInfra(self: *GpuContext) bool {
        const pool_ci = extern struct {
            sType: u32 = STYPE_CMD_POOL_CI,
            pNext: ?*const anyopaque = null,
            flags: u32 = 0x00000002, // RESET_COMMAND_BUFFER
            queueFamilyIndex: u32,
        }{ .queueFamilyIndex = self.queue_family };

        if (self.vk.createCommandPool(self.device, &pool_ci, null, &self.cmd_pool) != VK_SUCCESS)
            return false;

        const cb_ai = extern struct {
            sType: u32 = STYPE_CMD_BUF_AI,
            pNext: ?*const anyopaque = null,
            commandPool: VkCommandPool,
            level: u32 = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            commandBufferCount: u32 = 1,
        }{ .commandPool = self.cmd_pool };

        if (self.vk.allocateCommandBuffers(self.device, &cb_ai, &self.cmd_buf) != VK_SUCCESS)
            return false;

        const fence_ci = extern struct {
            sType: u32 = STYPE_FENCE_CI,
            pNext: ?*const anyopaque = null,
            flags: u32 = 0,
        }{};
        return self.vk.createFence(self.device, &fence_ci, null, &self.fence) == VK_SUCCESS;
    }

    // ── Internal: buffer management ───────────────────────────

    fn allocBuffer(self: *GpuContext, size: u64, usage: u32, mem_flags: u32, out: *GpuBuffer) bool {
        const ci = VkBufferCreateInfo{ .size = size, .usage = usage, .sharingMode = VK_SHARING_MODE_EXCLUSIVE };
        if (self.vk.createBuffer(self.device, &ci, null, &out.buffer) != VK_SUCCESS) return false;

        var req: VkMemoryRequirements = .{};
        self.vk.getBufferMemoryRequirements(self.device, out.buffer, &req);

        var mem_props: VkPhysicalDeviceMemoryProperties = .{};
        self.vk.getPhysicalDeviceMemoryProperties(self.physical_device, &mem_props);

        const mem_type = findMemType(mem_props, req.memoryTypeBits, mem_flags) orelse return false;
        const ai = VkMemoryAllocateInfo{ .allocationSize = req.size, .memoryTypeIndex = mem_type };
        if (self.vk.allocateMemory(self.device, &ai, null, &out.memory) != VK_SUCCESS) return false;
        if (self.vk.bindBufferMemory(self.device, out.buffer, out.memory, 0) != VK_SUCCESS) return false;
        out.size = size;
        return true;
    }

    fn findMemType(props: VkPhysicalDeviceMemoryProperties, type_bits: u32, required: u32) ?u32 {
        for (0..props.memoryTypeCount) |i| {
            if (type_bits & (@as(u32, 1) << @intCast(i)) != 0 and
                props.memoryTypes[i].propertyFlags & required == required)
                return @intCast(i);
        }
        return null;
    }

    // ── Internal: command recording helpers ───────────────────

    fn beginCmd(self: *GpuContext) bool {
        _ = self.vk.resetCommandBuffer(self.cmd_buf, 0);
        const bi = extern struct {
            sType: u32 = STYPE_CMD_BUF_BEGIN,
            pNext: ?*const anyopaque = null,
            flags: u32 = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            pInheritanceInfo: ?*const anyopaque = null,
        }{};
        return self.vk.beginCommandBuffer(self.cmd_buf, &bi) == VK_SUCCESS;
    }

    fn cmdCopy(self: *GpuContext, src: VkBuffer, dst: VkBuffer, src_off: u64, dst_off: u64, size: u64) void {
        const region = VkBufferCopy{ .srcOffset = src_off, .dstOffset = dst_off, .size = size };
        self.vk.cmdCopyBuffer(self.cmd_buf, src, dst, 1, &region);
    }

    fn cmdBarrier(self: *GpuContext, buf: VkBuffer, src_access: u32, dst_access: u32, src_stage: u32, dst_stage: u32) void {
        const barrier = VkBufferMemoryBarrier{
            .srcAccessMask = src_access,
            .dstAccessMask = dst_access,
            .buffer = buf,
        };
        self.vk.cmdPipelineBarrier(self.cmd_buf, src_stage, dst_stage, 0, 0, null, 1, &barrier, 0, null);
    }

    fn endAndSubmit(self: *GpuContext) bool {
        if (self.vk.endCommandBuffer(self.cmd_buf) != VK_SUCCESS) return false;

        _ = self.vk.resetFences(self.device, 1, &self.fence);
        const si = extern struct {
            sType: u32 = STYPE_SUBMIT_INFO,
            pNext: ?*const anyopaque = null,
            waitSemaphoreCount: u32 = 0,
            pWaitSemaphores: ?*const anyopaque = null,
            pWaitDstStageMask: ?*const anyopaque = null,
            commandBufferCount: u32 = 1,
            pCommandBuffers: *const VkCommandBuffer,
            signalSemaphoreCount: u32 = 0,
            pSignalSemaphores: ?*const anyopaque = null,
        }{ .pCommandBuffers = &self.cmd_buf };

        if (self.vk.queueSubmit(self.queue, 1, &si, self.fence) != VK_SUCCESS) return false;
        return self.vk.waitForFences(self.device, 1, &self.fence, 1, 5_000_000_000) == VK_SUCCESS;
    }

    fn copyBuffer(self: *GpuContext, src: VkBuffer, dst: VkBuffer, src_off: u64, dst_off: u64, size: u64) bool {
        if (!self.beginCmd()) return false;
        self.cmdCopy(src, dst, src_off, dst_off, size);
        return self.endAndSubmit();
    }

    // ── Internal: pipeline creation ───────────────────────────

    fn createPipelines(self: *GpuContext) bool {
        // Descriptor set layout: 3 storage buffers (weights, input, output)
        const bindings = [3]extern struct {
            binding: u32,
            descriptorType: u32 = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            descriptorCount: u32 = 1,
            stageFlags: u32 = VK_SHADER_STAGE_COMPUTE_BIT,
            pImmutableSamplers: ?*const anyopaque = null,
        }{
            .{ .binding = 0 },
            .{ .binding = 1 },
            .{ .binding = 2 },
        };

        const dsl_ci = extern struct {
            sType: u32 = STYPE_DESC_SET_LAYOUT_CI,
            pNext: ?*const anyopaque = null,
            flags: u32 = 0,
            bindingCount: u32 = 3,
            pBindings: *const anyopaque,
        }{ .pBindings = &bindings };

        if (self.vk.createDescriptorSetLayout(self.device, &dsl_ci, null, &self.desc_layout) != VK_SUCCESS)
            return false;

        // Descriptor pool
        const pool_size = extern struct {
            type_: u32 = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            descriptorCount: u32 = 3,
        }{};
        const dp_ci = extern struct {
            sType: u32 = STYPE_DESC_POOL_CI,
            pNext: ?*const anyopaque = null,
            flags: u32 = 0,
            maxSets: u32 = 1,
            poolSizeCount: u32 = 1,
            pPoolSizes: *const anyopaque,
        }{ .pPoolSizes = &pool_size };

        if (self.vk.createDescriptorPool(self.device, &dp_ci, null, &self.desc_pool) != VK_SUCCESS)
            return false;

        // Allocate descriptor set
        const ds_ai = extern struct {
            sType: u32 = STYPE_DESC_SET_AI,
            pNext: ?*const anyopaque = null,
            descriptorPool: VkDescriptorPool,
            descriptorSetCount: u32 = 1,
            pSetLayouts: *const VkDescriptorSetLayout,
        }{ .descriptorPool = self.desc_pool, .pSetLayouts = &self.desc_layout };

        if (self.vk.allocateDescriptorSets(self.device, &ds_ai, &self.desc_set) != VK_SUCCESS)
            return false;

        // Write descriptor set: bind buffers
        const buf_infos = [3]VkDescriptorBufferInfo{
            .{ .buffer = self.weight_buf.buffer, .offset = 0, .range = VK_WHOLE_SIZE },
            .{ .buffer = self.input_buf.buffer, .offset = 0, .range = VK_WHOLE_SIZE },
            .{ .buffer = self.output_buf.buffer, .offset = 0, .range = VK_WHOLE_SIZE },
        };

        var writes: [3]extern struct {
            sType: u32 = STYPE_WRITE_DESC_SET,
            pNext: ?*const anyopaque = null,
            dstSet: VkDescriptorSet,
            dstBinding: u32,
            dstArrayElement: u32 = 0,
            descriptorCount: u32 = 1,
            descriptorType: u32 = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            pImageInfo: ?*const anyopaque = null,
            pBufferInfo: *const VkDescriptorBufferInfo,
            pTexelBufferView: ?*const anyopaque = null,
        } = undefined;

        for (0..3) |i| {
            writes[i] = .{
                .dstSet = self.desc_set,
                .dstBinding = @intCast(i),
                .pBufferInfo = &buf_infos[i],
            };
        }
        self.vk.updateDescriptorSets(self.device, 3, &writes, 0, null);

        // Create pipeline layouts with push constants
        // Matvec: 16 bytes push constants
        const matvec_pcr = extern struct {
            stageFlags: u32 = VK_SHADER_STAGE_COMPUTE_BIT,
            offset: u32 = 0,
            size: u32 = @sizeOf(MatvecPC),
        }{};
        const matvec_pl_ci = extern struct {
            sType: u32 = STYPE_PIPELINE_LAYOUT_CI,
            pNext: ?*const anyopaque = null,
            flags: u32 = 0,
            setLayoutCount: u32 = 1,
            pSetLayouts: *const VkDescriptorSetLayout,
            pushConstantRangeCount: u32 = 1,
            pPushConstantRanges: *const anyopaque,
        }{ .pSetLayouts = &self.desc_layout, .pPushConstantRanges = &matvec_pcr };

        if (self.vk.createPipelineLayout(self.device, &matvec_pl_ci, null, &self.matvec_layout) != VK_SUCCESS)
            return false;

        // SuperLinear: 16 bytes push constants
        const sl_pcr = extern struct {
            stageFlags: u32 = VK_SHADER_STAGE_COMPUTE_BIT,
            offset: u32 = 0,
            size: u32 = @sizeOf(SuperlinearPC),
        }{};
        const sl_pl_ci = extern struct {
            sType: u32 = STYPE_PIPELINE_LAYOUT_CI,
            pNext: ?*const anyopaque = null,
            flags: u32 = 0,
            setLayoutCount: u32 = 1,
            pSetLayouts: *const VkDescriptorSetLayout,
            pushConstantRangeCount: u32 = 1,
            pPushConstantRanges: *const anyopaque,
        }{ .pSetLayouts = &self.desc_layout, .pPushConstantRanges = &sl_pcr };

        if (self.vk.createPipelineLayout(self.device, &sl_pl_ci, null, &self.superlinear_layout) != VK_SUCCESS)
            return false;

        // Load SPIR-V shaders from ~/.zish/shaders/
        if (loadShaderFile(self.allocator, "matvec")) |spv| {
            defer self.allocator.free(spv);
            self.matvec_pipeline = self.createComputePipeline(spv, self.matvec_layout);
        }

        // f32 matvec shares the same layout (same push constants)
        if (loadShaderFile(self.allocator, "matvec_f32")) |spv| {
            defer self.allocator.free(spv);
            self.matvec_f32_pipeline = self.createComputePipeline(spv, self.matvec_layout);
        }

        // Fused matmul+SiLU for cascade (same layout)
        if (loadShaderFile(self.allocator, "matvec_silu_f32")) |spv| {
            defer self.allocator.free(spv);
            self.matvec_silu_f32_pipeline = self.createComputePipeline(spv, self.matvec_layout);
        }

        if (loadShaderFile(self.allocator, "superlinear")) |spv| {
            defer self.allocator.free(spv);
            self.superlinear_pipeline = self.createComputePipeline(spv, self.superlinear_layout);
        }

        // OK even if shaders not found — operations will fall back to CPU
        return true;
    }

    fn createComputePipeline(self: *GpuContext, spirv: []align(4) const u8, layout: VkPipelineLayout) VkPipeline {
        // Create shader module
        const sm_ci = extern struct {
            sType: u32 = STYPE_SHADER_MODULE_CI,
            pNext: ?*const anyopaque = null,
            flags: u32 = 0,
            codeSize: usize,
            pCode: [*]align(4) const u8,
        }{ .codeSize = spirv.len, .pCode = spirv.ptr };

        var shader_module: VkShaderModule = null;
        if (self.vk.createShaderModule(self.device, &sm_ci, null, &shader_module) != VK_SUCCESS)
            return null;
        defer self.vk.destroyShaderModule(self.device, shader_module, null);

        // Create compute pipeline
        const stage = extern struct {
            sType: u32 = 18, // VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
            pNext: ?*const anyopaque = null,
            flags: u32 = 0,
            stage: u32 = VK_SHADER_STAGE_COMPUTE_BIT,
            module: VkShaderModule,
            pName: [*:0]const u8 = "main",
            pSpecializationInfo: ?*const anyopaque = null,
        }{ .module = shader_module };

        const cp_ci = extern struct {
            sType: u32 = STYPE_COMPUTE_PIPELINE_CI,
            pNext: ?*const anyopaque = null,
            flags: u32 = 0,
            stage: @TypeOf(stage),
            layout: VkPipelineLayout,
            basePipelineHandle: ?*anyopaque = null,
            basePipelineIndex: i32 = -1,
        }{ .stage = stage, .layout = layout };

        var pipeline: VkPipeline = null;
        if (self.vk.createComputePipelines(self.device, null, 1, &cp_ci, null, &pipeline) != VK_SUCCESS)
            return null;

        return pipeline;
    }

    // ── Cleanup ───────────────────────────────────────────────

    fn freeBuffer(self: *GpuContext, buf: *GpuBuffer) void {
        if (buf.buffer != null) self.vk.destroyBuffer(self.device, buf.buffer, null);
        if (buf.memory != null) self.vk.freeMemory(self.device, buf.memory, null);
        buf.* = .{};
    }

    pub fn deinit(self: *GpuContext) void {
        if (self.device != null) {
            _ = self.vk.deviceWaitIdle(self.device);

            if (self.staging_ptr != null and self.staging_buf.memory != null) {
                self.vk.unmapMemory(self.device, self.staging_buf.memory);
                self.staging_ptr = null;
            }

            self.freeBuffer(&self.weight_buf);
            self.freeBuffer(&self.staging_buf);
            self.freeBuffer(&self.input_buf);
            self.freeBuffer(&self.output_buf);

            if (self.matvec_pipeline != null) self.vk.destroyPipeline(self.device, self.matvec_pipeline, null);
            if (self.matvec_f32_pipeline != null) self.vk.destroyPipeline(self.device, self.matvec_f32_pipeline, null);
            if (self.matvec_silu_f32_pipeline != null) self.vk.destroyPipeline(self.device, self.matvec_silu_f32_pipeline, null);
            if (self.matvec_layout != null) self.vk.destroyPipelineLayout(self.device, self.matvec_layout, null);
            if (self.superlinear_pipeline != null) self.vk.destroyPipeline(self.device, self.superlinear_pipeline, null);
            if (self.superlinear_layout != null) self.vk.destroyPipelineLayout(self.device, self.superlinear_layout, null);
            if (self.desc_layout != null) self.vk.destroyDescriptorSetLayout(self.device, self.desc_layout, null);
            if (self.desc_pool != null) self.vk.destroyDescriptorPool(self.device, self.desc_pool, null);
            if (self.fence != null) self.vk.destroyFence(self.device, self.fence, null);
            if (self.cmd_pool != null) self.vk.destroyCommandPool(self.device, self.cmd_pool, null);

            self.vk.destroyDevice(self.device, null);
        }
        if (self.instance != null) self.vk.destroyInstance(self.instance, null);
        if (self.lib) |lib| _ = std.c.dlclose(lib);
        self.* = .{};
    }
};

// ============================================================
// Shader loading
// ============================================================

/// Load pre-compiled SPIR-V from ~/.zish/shaders/<name>.spv
pub fn loadShaderFile(alloc: Allocator, name: []const u8) ?[]align(4) const u8 {
    var path_buf: [256]u8 = undefined;
    const home = std.posix.getenv("HOME") orelse return null;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.zish/shaders/{s}.spv", .{ home, name }) catch return null;

    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();

    const stat = file.stat() catch return null;
    if (stat.size == 0 or stat.size > 1024 * 1024) return null;

    const buf = alloc.alignedAlloc(u8, .@"4", stat.size) catch return null;
    const n = file.readAll(buf) catch {
        alloc.free(buf);
        return null;
    };
    if (n != stat.size) {
        alloc.free(buf);
        return null;
    }
    return buf[0..n];
}
