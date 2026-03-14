// Transformer model for inference
// Supports LLaMA-family architectures (LLaMA, Qwen2, Mistral, etc.)
// These all share: RoPE, SwiGLU MLP, RMSNorm, GQA attention
// Optional CTM (Continuous Thought Machine) blocks replace MLP in selected layers.

const std = @import("std");
const gguf = @import("gguf.zig");
const gpu = @import("gpu.zig");
const math = @import("math.zig");
const ctm = @import("ctm.zig");

const Allocator = std.mem.Allocator;

pub const Config = struct {
    dim: usize,
    hidden_dim: usize,
    n_layers: usize,
    n_heads: usize,
    n_kv_heads: usize,
    vocab_size: usize,
    max_seq_length: usize,
    rope_theta: f32 = 10000.0,
    rms_norm_eps: f32 = 1e-6,
    arch: []const u8 = "llama",
    /// Sliding window attention size (0 = full context, >0 = attend only to last N tokens).
    /// Mistral models use this to reduce O(T²) attention to O(T×W).
    sliding_window: usize = 0,
    /// Post-QK-norm scaling factor (q,k *= qk_scale after RMS norm). Sharpens attention.
    qk_scale: f32 = 1.0,
    /// Logit softcap: logits = softcap * tanh(logits / softcap). 0 = disabled.
    /// Prevents extreme logits, stabilizes output distribution.
    logit_softcap: f32 = 0,
    /// Number of input channels for VE gate linear projection (default 32).
    ve_gate_channels: usize = 32,

    pub fn fromGGUF(file: *const gguf.GGUFFile) Config {
        const arch = file.getString("general.architecture") orelse "llama";
        const ctx_len = @min(file.getU32(archKey(arch, "context_length")) orelse 2048, 2048);
        return .{
            .dim = file.getU32(archKey(arch, "embedding_length")) orelse 512,
            .hidden_dim = file.getU32(archKey(arch, "feed_forward_length")) orelse 1536,
            .n_layers = file.getU32(archKey(arch, "block_count")) orelse 24,
            .n_heads = file.getU32(archKey(arch, "attention.head_count")) orelse 8,
            .n_kv_heads = file.getU32(archKey(arch, "attention.head_count_kv")) orelse 4,
            .vocab_size = if (file.getValue("tokenizer.ggml.tokens")) |v| @intCast(v.array.len) else file.getU32(archKey(arch, "vocab_size")) orelse 32000,
            .max_seq_length = ctx_len,
            .rope_theta = file.getF32(archKey(arch, "rope.freq_base")) orelse 10000.0,
            .rms_norm_eps = file.getF32(archKey(arch, "attention.layer_norm_rms_epsilon")) orelse 1e-6,
            .arch = arch,
            .sliding_window = file.getU32(archKey(arch, "attention.sliding_window")) orelse 0,
            .qk_scale = file.getF32(archKey(arch, "attention.qk_scale")) orelse 1.0,
            .logit_softcap = file.getF32(archKey(arch, "logit_softcap")) orelse 0,
            .ve_gate_channels = file.getU32(archKey(arch, "ve_gate_channels")) orelse 32,
        };
    }
};

// We need runtime key construction. Use a thread-local buffer.
threadlocal var key_buf: [128]u8 = undefined;

fn archKey(arch: []const u8, suffix: []const u8) []const u8 {
    const result = std.fmt.bufPrint(&key_buf, "{s}.{s}", .{ arch, suffix }) catch return suffix;
    return result;
}

/// Weights for a single transformer layer.
const Layer = struct {
    // Attention
    attn_norm: ?[]const f32 = null, // optional — nanochat has no layer norms
    wq: TensorRef,
    wk: TensorRef,
    wv: TensorRef,
    wo: TensorRef,
    // Attention biases (optional — Qwen2 has Q/K biases)
    bq: ?[]const f32 = null,
    bk: ?[]const f32 = null,
    bv: ?[]const f32 = null,
    // MLP (standard SwiGLU) — always present
    ffn_norm: ?[]const f32 = null, // optional — nanochat has no layer norms
    w1: ?TensorRef = null, // gate
    w2: ?TensorRef = null, // down
    w3: ?TensorRef = null, // up
    // CTM block (gated, additive on top of MLP)
    ctm_block: ?*ctm.CTMBlock = null,
    // Learned gate scalar: output = MLP(x) + sigmoid(ctm_gate) * CTM(x)
    // Initialized negative so sigmoid ≈ 0 at start — CTM doesn't disrupt backbone.
    ctm_gate: f32 = -4.0, // sigmoid(-4) ≈ 0.018
    // Value Embedding gate: Linear(ve_gate_channels, n_kv_head) — only for alternating layers
    // gate = 3 * sigmoid(ve_gate(x[:32])), applied to value embeddings in attention
    ve_gate: ?[]const f32 = null, // (n_kv_head × ve_gate_channels) row-major
    // Value embedding: per-token embedding table (vocab_size × kv_dim)
    // ResFormer-style: v += gate * value_embed[token]
    value_embed: ?TensorRef = null,
};

/// Reference to quantized or float tensor data in mmap'd file.
pub const TensorRef = union(enum) {
    f32: []const f32,
    f16: []const f16,
    q8_0: []const math.Q80Block,
    q4_k: []const math.Q4KBlock,
    q6_k: []const math.Q6KBlock,

    fn fromTensor(ti: gguf.TensorInfo, data: [*]const u8) TensorRef {
        const ptr = ti.getData(data);
        const n = ti.numElements();
        switch (ti.ggml_type) {
            .F32 => {
                const p: [*]const f32 = @ptrCast(@alignCast(ptr));
                return .{ .f32 = p[0..n] };
            },
            .F16 => {
                const p: [*]const f16 = @ptrCast(@alignCast(ptr));
                return .{ .f16 = p[0..n] };
            },
            .Q8_0 => {
                const p: [*]const math.Q80Block = @ptrCast(@alignCast(ptr));
                return .{ .q8_0 = p[0 .. n / 32] };
            },
            .Q4_K => {
                const p: [*]const math.Q4KBlock = @ptrCast(@alignCast(ptr));
                return .{ .q4_k = p[0 .. n / math.QK_K] };
            },
            .Q6_K => {
                const p: [*]const math.Q6KBlock = @ptrCast(@alignCast(ptr));
                return .{ .q6_k = p[0 .. n / math.QK_K] };
            },
            else => @panic("Unsupported tensor quantization"),
        }
    }
};

/// Inference state — working buffers for forward pass.
pub const State = struct {
    arena: std.heap.ArenaAllocator,

    // Precomputed RoPE
    sin: []f32,
    cos: []f32,

    // Working buffers
    input: []f32,
    work: []f32,
    work2: []f32,
    hidden1: []f32,
    hidden2: []f32,

    q: []f32,
    k: []f32,
    v: []f32,

    attention: []f32,
    output: []f32, // logits

    // KV cache
    k_cache: []f32,
    v_cache: []f32,

    // Q8_0 quantization scratch for matmul
    quant_vec: []math.Q80Block,

    // Thread count for parallel matmul
    n_threads: usize,

    // x0: normalized token embedding saved at start of forward pass.
    // Used for resid_lambdas/x0_lambdas residual scaling.
    x0: []f32 = &.{},

    // CTM persistent state (sync accumulators across tokens)
    ctm_state: ?*ctm.CTMState = null,
    // CTM scratch buffer for forward pass
    ctm_scratch: []f32 = &.{},

    // VE gate scratch buffer: holds gate values per kv_head
    ve_gate_out: []f32 = &.{},

    pub fn init(alloc: Allocator, config: Config) !State {
        var arena = std.heap.ArenaAllocator.init(alloc);
        const a = arena.allocator();

        const kv_dim = config.dim * config.n_kv_heads / config.n_heads;
        const head_size = config.dim / config.n_heads;
        const max_dim = @max(config.dim, config.hidden_dim);

        const sin, const cos = try precomputeFrequencies(
            head_size,
            config.max_seq_length,
            config.rope_theta,
            a,
        );

        return .{
            .arena = arena,
            .sin = sin,
            .cos = cos,
            .input = try a.alloc(f32, config.dim),
            .work = try a.alloc(f32, config.dim),
            .work2 = try a.alloc(f32, config.dim),
            .hidden1 = try a.alloc(f32, config.hidden_dim),
            .hidden2 = try a.alloc(f32, config.hidden_dim),
            .q = try a.alloc(f32, config.dim),
            .k = try a.alloc(f32, kv_dim),
            .v = try a.alloc(f32, kv_dim),
            .attention = try a.alloc(f32, config.n_heads * config.max_seq_length),
            .output = try a.alloc(f32, config.vocab_size),
            .k_cache = try a.alloc(f32, config.n_layers * config.max_seq_length * kv_dim),
            .v_cache = try a.alloc(f32, config.n_layers * config.max_seq_length * kv_dim),
            .quant_vec = try a.alloc(math.Q80Block, max_dim / 32),
            .n_threads = @min(math.cpuCount(), 32),
            .x0 = try a.alloc(f32, config.dim),
            .ve_gate_out = try a.alloc(f32, config.n_kv_heads),
        };
    }

    pub fn deinit(self: *State) void {
        self.arena.deinit();
    }
};

fn precomputeFrequencies(
    head_size: usize,
    seq_len: usize,
    theta: f32,
    alloc: Allocator,
) !struct { []f32, []f32 } {
    const half_head = head_size / 2;
    const compute_len = seq_len * half_head;

    const sin = try alloc.alloc(f32, compute_len);
    const cos = try alloc.alloc(f32, compute_len);

    const hs_f: f32 = @floatFromInt(head_size);
    for (0..seq_len) |m| {
        const m_f: f32 = @floatFromInt(m);
        for (0..half_head) |hd| {
            const h_f: f32 = @floatFromInt(hd * 2);
            const freq = std.math.pow(f32, theta, -1.0 * h_f / hs_f);
            const angle = m_f * freq;
            const idx = half_head * m + hd;
            sin[idx] = std.math.sin(angle);
            cos[idx] = std.math.cos(angle);
        }
    }
    return .{ sin, cos };
}

pub const Transformer = struct {
    config: Config,
    layers: []Layer,
    token_embed: TensorRef,
    norm: ?[]const f32 = null, // output RMS norm weights (optional for nanochat)
    classifier: TensorRef, // output projection (lm_head)
    // Per-layer residual scaling: x = resid_lambdas[i] * x + x0_lambdas[i] * x0
    // Defaults: resid=1.0 (identity), x0=0.0 (no skip). Null = disabled.
    resid_lambdas: ?[]const f32 = null,
    x0_lambdas: ?[]const f32 = null,

    arena: std.heap.ArenaAllocator,

    // GPU compute service (optional — nil means CPU-only)
    gpu_ctx: ?*gpu.GpuContext = null,
    // Base pointer of tensor data in mmap — used to compute GPU buffer offsets
    tensor_data_base: ?[*]const u8 = null,

    /// Propagate GPU context to all sub-components (CTM blocks, etc.)
    pub fn setGpu(self: *Transformer, g: *gpu.GpuContext, base: [*]const u8) void {
        self.gpu_ctx = g;
        self.tensor_data_base = base;
        // Wire GPU into CTM blocks + their SynapseUNET
        for (self.layers) |*layer| {
            if (layer.ctm_block) |blk| {
                const mb = @constCast(blk);
                mb.gpu_ctx = g;
                mb.tensor_data_base = base;
                mb.synapses.gpu_ctx = g;
                mb.synapses.tensor_data_base = base;
            }
        }
    }

    pub fn initFromGGUF(file: *const gguf.GGUFFile, alloc: Allocator) !Transformer {
        const real_config = Config.fromGGUF(file);
        const arch = file.getString("general.architecture") orelse "llama";

        const td = file.tensorData();

        var arena = std.heap.ArenaAllocator.init(alloc);
        const a = arena.allocator();

        // Load layers
        var layers = try a.alloc(Layer, real_config.n_layers);
        var name_buf: [128]u8 = undefined;
        for (0..real_config.n_layers) |i| {
            layers[i] = .{
                .attn_norm = tryGetF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.attn_norm.weight", .{i})),
                .wq = getTensorRef(file, td, fmtBuf(&name_buf, "blk.{d}.attn_q.weight", .{i})),
                .wk = getTensorRef(file, td, fmtBuf(&name_buf, "blk.{d}.attn_k.weight", .{i})),
                .wv = getTensorRef(file, td, fmtBuf(&name_buf, "blk.{d}.attn_v.weight", .{i})),
                .wo = getTensorRef(file, td, fmtBuf(&name_buf, "blk.{d}.attn_output.weight", .{i})),
                .bq = tryGetF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.attn_q.bias", .{i})),
                .bk = tryGetF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.attn_k.bias", .{i})),
                .bv = tryGetF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.attn_v.bias", .{i})),
                .ffn_norm = tryGetF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.ffn_norm.weight", .{i})),
                .w1 = tryGetTensorRef(file, td, fmtBuf(&name_buf, "blk.{d}.ffn_gate.weight", .{i})),
                .w2 = tryGetTensorRef(file, td, fmtBuf(&name_buf, "blk.{d}.ffn_down.weight", .{i})),
                .w3 = tryGetTensorRef(file, td, fmtBuf(&name_buf, "blk.{d}.ffn_up.weight", .{i})),
            };
        }

        // Load Value Embedding gates and embeddings for alternating layers
        // Pattern: has_ve(i) = i % 2 == (n_layer-1) % 2
        const ve_parity = (real_config.n_layers - 1) % 2;
        for (0..real_config.n_layers) |i| {
            if (i % 2 != ve_parity) continue;
            // VE gate weight: (n_kv_head, ve_gate_channels)
            layers[i].ve_gate = tryGetF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.ve_gate.weight", .{i}));
            // Value embedding: (vocab_size, kv_dim)
            layers[i].value_embed = tryGetTensorRef(file, td, fmtBuf(&name_buf, "blk.{d}.value_embed.weight", .{i}));
        }

        // Load CTM blocks from GGUF if present
        const ctm_enabled = file.getU32(archKey(arch, "ctm.enabled")) orelse 0;
        if (ctm_enabled != 0) {
            const ctm_layers_str = file.getString(archKey(arch, "ctm.layers")) orelse "last";
            const ctm_layer_idx = if (file.getU32(archKey(arch, "ctm.layer_idx"))) |idx|
                idx
            else if (std.mem.eql(u8, ctm_layers_str, "last"))
                real_config.n_layers - 1
            else
                real_config.n_layers - 1;

            const cfg = ctm.CTMConfig{
                .dim = real_config.dim,
                .iterations = file.getU32(archKey(arch, "ctm.iterations")) orelse 4,
                .memory_length = file.getU32(archKey(arch, "ctm.memory_length")) orelse 16,
                .n_synch = file.getU32(archKey(arch, "ctm.n_synch")) orelse real_config.dim / 2,
                .memory_hidden = file.getU32(archKey(arch, "ctm.memory_hidden")) orelse 32,
                .n_attn_heads = 1,
                .synapse_depth = file.getU32(archKey(arch, "ctm.synapse_depth")) orelse 32,
            };
            const half_k = cfg.synapse_depth / 2;

            const block = try a.create(ctm.CTMBlock);
            block.* = .{
                .config = cfg,
                .attn_q_proj_w = getF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.ctm_attn_q.weight", .{ctm_layer_idx})),
                .attn_k_proj_w = getF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.ctm_attn_k.weight", .{ctm_layer_idx})),
                .attn_v_proj_w = getF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.ctm_attn_v.weight", .{ctm_layer_idx})),
                .c_proj_w = getF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.ctm_c_proj.weight", .{ctm_layer_idx})),
                .nlm1 = .{
                    .w = getF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.ctm_nlm1.weight", .{ctm_layer_idx})),
                    .b = getF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.ctm_nlm1.bias", .{ctm_layer_idx})),
                    .in_dims = cfg.memory_length,
                    .out_dims = cfg.memory_hidden * 2,
                    .n_neurons = cfg.dim,
                },
                .nlm2 = .{
                    .w = getF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.ctm_nlm2.weight", .{ctm_layer_idx})),
                    .b = getF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.ctm_nlm2.bias", .{ctm_layer_idx})),
                    .in_dims = cfg.memory_hidden,
                    .out_dims = 2,
                    .n_neurons = cfg.dim,
                },
                .start_state = getF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.ctm_start_state", .{ctm_layer_idx})),
                .start_trace = getF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.ctm_start_trace", .{ctm_layer_idx})),
                .tick_embed = getF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.ctm_tick_embed", .{ctm_layer_idx})),
                .decay_out = getF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.ctm_decay_out", .{ctm_layer_idx})),
                .decay_act = getF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.ctm_decay_act", .{ctm_layer_idx})),
                // Sync indices stored as f32 in GGUF, convert to u32 indices
                .synch_out_left = try f32ToU32Indices(a, getF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.ctm_synch_out_left", .{ctm_layer_idx}))),
                .synch_out_right = try f32ToU32Indices(a, getF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.ctm_synch_out_right", .{ctm_layer_idx}))),
                .synch_act_left = try f32ToU32Indices(a, getF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.ctm_synch_act_left", .{ctm_layer_idx}))),
                .synch_act_right = try f32ToU32Indices(a, getF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.ctm_synch_act_right", .{ctm_layer_idx}))),
                .synapses = undefined, // loaded below
            };

            // Load SynapseUNET
            var down_weights = try a.alloc([]const f32, half_k);
            var down_in_dims = try a.alloc(usize, half_k);
            var down_out_dims = try a.alloc(usize, half_k);
            var up_weights = try a.alloc([]const f32, half_k);
            var up_in_dims = try a.alloc(usize, half_k);
            var up_out_dims = try a.alloc(usize, half_k);
            var up_ln_weight = try a.alloc([]const f32, half_k);
            var up_ln_bias = try a.alloc([]const f32, half_k);

            for (0..half_k) |j| {
                const dw = getF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.ctm_synapse_down.{d}.weight", .{ ctm_layer_idx, j }));
                down_weights[j] = dw;
                // Tensor is (out_dim, in_dim) row-major
                if (file.getTensorInfo(fmtBuf(&name_buf, "blk.{d}.ctm_synapse_down.{d}.weight", .{ ctm_layer_idx, j }))) |ti| {
                    down_out_dims[j] = ti.dimensions[0];
                    down_in_dims[j] = ti.dimensions[1];
                }

                const uw = getF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.ctm_synapse_up.{d}.weight", .{ ctm_layer_idx, j }));
                up_weights[j] = uw;
                if (file.getTensorInfo(fmtBuf(&name_buf, "blk.{d}.ctm_synapse_up.{d}.weight", .{ ctm_layer_idx, j }))) |ti| {
                    up_out_dims[j] = ti.dimensions[0];
                    up_in_dims[j] = ti.dimensions[1];
                }

                up_ln_weight[j] = getF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.ctm_synapse_up_ln.{d}.weight", .{ ctm_layer_idx, j }));
                up_ln_bias[j] = getF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.ctm_synapse_up_ln.{d}.bias", .{ ctm_layer_idx, j }));
            }

            block.synapses = .{
                .down_weights = down_weights,
                .down_in_dims = down_in_dims,
                .down_out_dims = down_out_dims,
                .up_weights = up_weights,
                .up_in_dims = up_in_dims,
                .up_out_dims = up_out_dims,
                .up_ln_weight = up_ln_weight,
                .up_ln_bias = up_ln_bias,
                .half_k = half_k,
            };

            // Validate sync indices are within bounds
            if (!validateSyncIndices(block.synch_out_left, cfg.dim) or
                !validateSyncIndices(block.synch_out_right, cfg.dim) or
                !validateSyncIndices(block.synch_act_left, cfg.dim) or
                !validateSyncIndices(block.synch_act_right, cfg.dim))
            {
                return error.InvalidCTMSyncIndices;
            }

            layers[ctm_layer_idx].ctm_block = block;

            // Load gate scalar from GGUF (or default to -4.0 → sigmoid ≈ 0.018)
            if (file.getF32(archKey(arch, "ctm.gate_init"))) |gate_val| {
                layers[ctm_layer_idx].ctm_gate = gate_val;
            }
            // Also check for a per-tensor gate value
            if (tryGetF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.ctm_gate", .{ctm_layer_idx}))) |gate_tensor| {
                layers[ctm_layer_idx].ctm_gate = gate_tensor[0];
            }
        }

        // Load embedding and output weights
        const token_embed = getTensorRef(file, td, "token_embd.weight");
        const norm_weights = tryGetF32Tensor(file, td, "output_norm.weight");
        const classifier = if (file.getTensorInfo("output.weight")) |_|
            getTensorRef(file, td, "output.weight")
        else
            token_embed; // shared classifier

        return .{
            .config = real_config,
            .layers = layers,
            .token_embed = token_embed,
            .norm = norm_weights,
            .classifier = classifier,
            .resid_lambdas = tryGetF32Tensor(file, td, "resid_lambdas"),
            .x0_lambdas = tryGetF32Tensor(file, td, "x0_lambdas"),
            .arena = arena,
        };
    }

    pub fn deinit(self: *Transformer) void {
        self.arena.deinit();
    }

    /// Run a forward pass for token at position n_tok. Returns logits slice.
    pub fn forward(self: *const Transformer, state: *State, tok: i64, n_tok: usize) []f32 {
        @setFloatMode(.optimized);

        const c = self.config;
        const dim = c.dim;
        const kv_dim = (c.dim * c.n_kv_heads) / c.n_heads;
        const head_size = c.dim / c.n_heads;

        // Token embedding
        self.applyEmbedding(state.input, tok);

        // Save x0 for resid_lambdas/x0_lambdas residual scaling
        if (self.resid_lambdas != null or self.x0_lambdas != null) {
            @memcpy(state.x0[0..dim], state.input[0..dim]);
        }

        for (0..c.n_layers) |i| {
            const layer_offset = i * c.max_seq_length * kv_dim;
            const layer = self.layers[i];

            // Residual scaling: x = resid_lambdas[i] * x + x0_lambdas[i] * x0
            if (self.resid_lambdas) |rl| {
                const x0l = self.x0_lambdas orelse &[_]f32{};
                const r = rl[i];
                const x0_w: f32 = if (i < x0l.len) x0l[i] else 0.0;
                for (0..dim) |d| {
                    state.input[d] = r * state.input[d] + x0_w * state.x0[d];
                }
            }

            // Attention norm (skip if not present — nanochat models)
            if (layer.attn_norm) |norm| {
                math.rmsNorm(state.work, state.input, norm);
            } else {
                @memcpy(state.work[0..dim], state.input[0..dim]);
            }

            // QKV projections — batched: 3 matmuls, 1 GPU submit
            if (!self.batchMatvecGpu(
                state.work[0..dim],
                &.{ state.q[0..dim], state.k[0..kv_dim], state.v[0..kv_dim] },
                &.{ layer.wq, layer.wk, layer.wv },
                &.{ dim, kv_dim, kv_dim },
                dim,
            )) {
                // CPU fallback
                self.matmulTensor(state.q, layer.wq, state.work, dim, dim, state);
                self.matmulTensor(state.k, layer.wk, state.work, kv_dim, dim, state);
                self.matmulTensor(state.v, layer.wv, state.work, kv_dim, dim, state);
            }

            // Attention biases (Qwen2)
            if (layer.bq) |bq| math.add(state.q, state.q, bq);
            if (layer.bk) |bk| math.add(state.k, state.k, bk);
            if (layer.bv) |bv| math.add(state.v, state.v, bv);

            // Value Embedding gate (ResFormer): v += gate * value_embed[token]
            if (layer.ve_gate) |ve_gate_w| {
                if (layer.value_embed) |ve_ref| {
                    // Compute gate: Linear(ve_gate_channels, n_kv_head) on first channels of input
                    const n_kv = c.n_kv_heads;
                    const ve_ch = c.ve_gate_channels;
                    const gate_out = state.ve_gate_out[0..n_kv];
                    for (0..n_kv) |h| {
                        var sum: f32 = 0;
                        const row = ve_gate_w[h * ve_ch ..][0..ve_ch];
                        for (0..ve_ch) |ch| sum += row[ch] * state.work[ch];
                        // gate = 3 * sigmoid(sum)
                        gate_out[h] = 3.0 / (1.0 + std.math.exp(-sum));
                    }
                    // Lookup value embedding for this token
                    const ve_head_dim = kv_dim / n_kv;
                    const ve_offset: usize = @intCast(tok * @as(i64, @intCast(kv_dim)));
                    switch (ve_ref) {
                        .f32 => |data| {
                            const ve = data[ve_offset..][0..kv_dim];
                            for (0..n_kv) |h| {
                                const g = gate_out[h];
                                const base = h * ve_head_dim;
                                for (0..ve_head_dim) |j| state.v[base + j] += g * ve[base + j];
                            }
                        },
                        .f16 => |data| {
                            const ve = data[ve_offset..][0..kv_dim];
                            for (0..n_kv) |h| {
                                const g = gate_out[h];
                                const base = h * ve_head_dim;
                                for (0..ve_head_dim) |j| state.v[base + j] += g * @as(f32, @floatCast(ve[base + j]));
                            }
                        },
                        else => {}, // VE embeddings should be f32 or f16
                    }
                }
            }

            // RoPE
            applyRoPE(state.q, state.sin, state.cos, c.n_heads, head_size, n_tok);
            applyRoPE(state.k, state.sin, state.cos, c.n_kv_heads, head_size, n_tok);

            // Post-QK-norm scaling: sharpens attention patterns
            if (c.qk_scale != 1.0) {
                for (state.q[0..dim]) |*v| v.* *= c.qk_scale;
                for (state.k[0..kv_dim]) |*v| v.* *= c.qk_scale;
            }

            // Update KV cache (wrap position for continuous inference)
            const cache_pos = n_tok % c.max_seq_length;
            const cache_start = layer_offset + cache_pos * kv_dim;
            @memcpy(state.k_cache[cache_start..][0..kv_dim], state.k);
            @memcpy(state.v_cache[cache_start..][0..kv_dim], state.v);

            // Multi-head attention
            self.doAttention(state, i, n_tok);

            // wo projection
            self.matmulTensor(state.work2, layer.wo, state.work, dim, dim, state);

            // Residual connection
            math.add(state.input, state.input, state.work2);

            // FFN norm (skip if not present — nanochat models)
            if (layer.ffn_norm) |norm| {
                math.rmsNorm(state.work, state.input, norm);
            } else {
                @memcpy(state.work[0..dim], state.input[0..dim]);
            }

            if (layer.ctm_block) |ctm_block| {
                // GATED INTERPOLATION: output = (1-g)*MLP(x) + g*CTM(x)
                // Gate starts near 0 → pure MLP. As CTM trains, gate opens
                // and CTM can OVERRIDE the MLP, not just add a correction.
                // This gives CTM gradient pressure to actually contribute.
                const gate = 1.0 / (1.0 + std.math.exp(-layer.ctm_gate));

                // Run MLP
                if (layer.w2 != null and (layer.w1 != null or layer.w3 != null)) {
                    if (layer.w1 != null and layer.w3 != null) {
                        // SwiGLU: gate (w1) + up (w3), silu(gate) * up, down (w2)
                        if (!self.batchMatvecGpu(
                            state.work[0..dim],
                            &.{ state.hidden1[0..c.hidden_dim], state.hidden2[0..c.hidden_dim] },
                            &.{ layer.w1.?, layer.w3.? },
                            &.{ c.hidden_dim, c.hidden_dim },
                            dim,
                        )) {
                            self.matmulTensor(state.hidden1, layer.w1.?, state.work, c.hidden_dim, dim, state);
                            self.matmulTensor(state.hidden2, layer.w3.?, state.work, c.hidden_dim, dim, state);
                        }
                        math.swiglu(state.hidden1);
                        math.elementProduct(state.hidden1, state.hidden1, state.hidden2);
                    } else {
                        // ReLU² or plain FFN: up (w3), relu²(up), down (w2)
                        const up = layer.w3 orelse layer.w1.?;
                        self.matmulTensor(state.hidden1, up, state.work, c.hidden_dim, dim, state);
                        // ReLU²: relu(x)²
                        for (state.hidden1[0..c.hidden_dim]) |*v| {
                            const r = @max(v.*, 0);
                            v.* = r * r;
                        }
                    }

                    self.matmulTensor(state.work2, layer.w2.?, state.hidden1, dim, c.hidden_dim, state);

                    // Scale MLP output by (1 - gate)
                    const mlp_scale = 1.0 - gate;
                    for (state.work2[0..dim]) |*v| v.* *= mlp_scale;

                    // MLP residual
                    math.add(state.input, state.input, state.work2);
                }

                // Run CTM on the same pre-norm input (state.work still holds it)
                var ctm_timer = std.time.Timer.start() catch null;
                ctm_block.forward(
                    state.work,
                    state.work2,
                    state.ctm_state.?,
                    i,
                    state.ctm_scratch,
                );
                if (ctm_timer) |*t| {
                    const ms = @as(f64, @floatFromInt(t.read())) / 1e6;
                    if (n_tok < 2) std.debug.print("[fwd] layer {d} CTM: {d:.1}ms (gate={d:.3})\n", .{ i, ms, gate });
                }

                // Scale CTM output by gate
                for (state.work2[0..dim]) |*v| v.* *= gate;

                // CTM residual
                math.add(state.input, state.input, state.work2);
            } else if (layer.w1 != null and layer.w2 != null and layer.w3 != null) {
                // Standard MLP (no CTM): SwiGLU(w1(x)) * w3(x), then w2
                // Batch gate+up: 2 matmuls, 1 GPU submit
                if (!self.batchMatvecGpu(
                    state.work[0..dim],
                    &.{ state.hidden1[0..c.hidden_dim], state.hidden2[0..c.hidden_dim] },
                    &.{ layer.w1.?, layer.w3.? },
                    &.{ c.hidden_dim, c.hidden_dim },
                    dim,
                )) {
                    self.matmulTensor(state.hidden1, layer.w1.?, state.work, c.hidden_dim, dim, state);
                    self.matmulTensor(state.hidden2, layer.w3.?, state.work, c.hidden_dim, dim, state);
                }

                math.swiglu(state.hidden1);
                math.elementProduct(state.hidden1, state.hidden1, state.hidden2);

                self.matmulTensor(state.work, layer.w2.?, state.hidden1, dim, c.hidden_dim, state);

                // Residual
                math.add(state.input, state.input, state.work);
            }
        }

        // Final norm (skip if not present — nanochat models)
        if (self.norm) |norm| {
            math.rmsNorm(state.input, state.input, norm);
        }

        // Classifier projection
        self.matmulTensor(state.output, self.classifier, state.input, c.vocab_size, dim, state);

        // Logit softcap: logits = cap * tanh(logits / cap)
        // Prevents extreme logits, stabilizes output distribution.
        if (c.logit_softcap > 0) {
            const cap = c.logit_softcap;
            const inv_cap = 1.0 / cap;
            for (state.output[0..c.vocab_size]) |*v| {
                v.* = cap * std.math.tanh(v.* * inv_cap);
            }
        }

        return state.output;
    }

    fn applyEmbedding(self: *const Transformer, out: []f32, tok: i64) void {
        const dim = self.config.dim;
        const offset: usize = @intCast(tok * @as(i64, @intCast(dim)));

        switch (self.token_embed) {
            .f32 => |data| @memcpy(out, data[offset..][0..dim]),
            .f16 => |data| {
                for (0..dim) |i| {
                    out[i] = @as(f32, @floatCast(data[offset + i]));
                }
            },
            .q8_0 => |data| {
                const block_offset = offset / 32;
                const n_blocks = dim / 32;
                math.dequantizeQ80(data[block_offset..][0..n_blocks], out);
            },
            .q4_k => |data| {
                const block_offset = offset / math.QK_K;
                const n_blocks = dim / math.QK_K;
                math.dequantizeQ4K(data[block_offset..][0..n_blocks], out);
            },
            .q6_k => |data| {
                const block_offset = offset / math.QK_K;
                const n_blocks = dim / math.QK_K;
                math.dequantizeQ6K(data[block_offset..][0..n_blocks], out);
            },
        }
    }

    /// Matrix-vector multiply handling different quantization formats.
    /// F16 weights dispatch to GPU when available (VRAM bandwidth >> system RAM).
    /// Q4_K/Q6_K use fused CPU dot products (no intermediate dequant buffer).
    /// Large matmuls are parallelized across CPU cores.
    fn matmulTensor(
        self: *const Transformer,
        out: []f32,
        weights: TensorRef,
        x: []const f32,
        rows: usize,
        cols: usize,
        state: *State,
    ) void {
        const n_threads = state.n_threads;
        switch (weights) {
            .f32 => |data| {
                const ctx = math.F32MatmulCtx{ .data = data, .x = x, .cols = cols };
                math.matmulParallel(out, rows, math.F32MatmulCtx, ctx, n_threads);
            },
            .f16 => |data| {
                // Try GPU path: F16 weights live in VRAM at known offset
                if (self.gpu_ctx) |g| {
                    if (self.tensor_data_base) |base| {
                        const data_ptr: [*]const u8 = @ptrCast(data.ptr);
                        const byte_offset = @intFromPtr(data_ptr) - @intFromPtr(base);
                        const slot = gpu.WeightSlot{
                            .offset = byte_offset,
                            .rows = @intCast(rows),
                            .cols = @intCast(cols),
                        };
                        if (g.matvec(x, out, slot)) return;
                    }
                }
                // CPU fallback
                const ctx = math.F16MatmulCtx{ .data = data, .x = x, .cols = cols };
                math.matmulParallel(out, rows, math.F16MatmulCtx, ctx, n_threads);
            },
            .q8_0 => |data| {
                // Quantize input vector to Q8_0, then SIMD matmul
                const n_blocks = cols / 32;
                math.quantizeQ80(x, state.quant_vec[0..n_blocks]);
                const ctx = math.Q80MatmulCtx{ .data = data, .x_quant = state.quant_vec[0..n_blocks], .cols = cols };
                math.matmulParallel(out, rows, math.Q80MatmulCtx, ctx, n_threads);
            },
            .q4_k => |data| {
                // Fused dot product: no dequant buffer needed
                const ctx = math.Q4KMatmulCtx{ .data = data, .x = x, .cols = cols };
                math.matmulParallel(out, rows, math.Q4KMatmulCtx, ctx, n_threads);
            },
            .q6_k => |data| {
                const ctx = math.Q6KMatmulCtx{ .data = data, .x = x, .cols = cols };
                math.matmulParallel(out, rows, math.Q6KMatmulCtx, ctx, n_threads);
            },
        }
    }

    /// Batch multiple F16 matmuls sharing the same input into one GPU submit.
    /// Returns true if GPU batch was used, false if caller should fall back to individual calls.
    fn batchMatvecGpu(
        self: *const Transformer,
        input: []const f32,
        outputs: []const []f32,
        weights: []const TensorRef,
        rows_list: []const usize,
        cols: usize,
    ) bool {
        const g = self.gpu_ctx orelse return false;
        const base = self.tensor_data_base orelse return false;

        // All weights must be F16 for GPU batch
        for (weights) |w| {
            switch (w) {
                .f16 => {},
                else => return false,
            }
        }

        if (!g.beginPass(input)) return false;

        // Record all dispatches
        var offsets: [8]u32 = undefined;
        for (weights, 0..) |w, i| {
            const data = switch (w) {
                .f16 => |d| d,
                else => unreachable,
            };
            const data_ptr: [*]const u8 = @ptrCast(data.ptr);
            const byte_offset = @intFromPtr(data_ptr) - @intFromPtr(base);
            const slot = gpu.WeightSlot{
                .offset = byte_offset,
                .rows = @intCast(rows_list[i]),
                .cols = @intCast(cols),
            };
            offsets[i] = g.recordMatvec(slot) orelse {
                // Abort batch
                _ = g.endPass();
                return false;
            };
        }

        if (!g.endPass()) return false;

        // Read all results
        for (outputs, 0..) |out, i| {
            g.readBatchOutput(offsets[i], out[0..rows_list[i]]);
        }
        return true;
    }

    fn doAttention(self: *const Transformer, state: *State, layer_idx: usize, n_token: usize) void {
        const c = self.config;
        const head_size = c.dim / c.n_heads;
        const kv_dim = (c.dim * c.n_kv_heads) / c.n_heads;
        const kv_mul = c.n_heads / c.n_kv_heads;
        const layer_offset = layer_idx * c.max_seq_length * kv_dim;
        const scale = std.math.sqrt(@as(f32, @floatFromInt(head_size)));

        // Sliding window: only attend to last W tokens (Mistral pattern).
        // Reduces O(T²) to O(T×W). window=0 means full context.
        // Also clamp to max_seq_length for continuous inference (cache wraps).
        const effective_window = if (c.sliding_window > 0)
            @min(c.sliding_window, c.max_seq_length)
        else
            c.max_seq_length;
        const window_start: usize = if (n_token + 1 > effective_window)
            n_token + 1 - effective_window
        else
            0;
        const att_len = n_token + 1 - window_start;

        for (0..c.n_heads) |head| {
            const query = state.q[head * head_size ..][0..head_size];
            const att = state.attention[head * c.max_seq_length ..][0..att_len];

            const base = layer_offset + (head / kv_mul) * head_size;
            for (window_start..n_token + 1) |tok| {
                const cache_pos = tok % c.max_seq_length;
                const key = state.k_cache[base + cache_pos * kv_dim ..][0..head_size];
                att[tok - window_start] = math.dotProduct(query, key) / scale;
            }

            math.softMax(att);

            const attn_out = state.work[head * head_size ..][0..head_size];
            @memset(attn_out, 0);
            for (window_start..n_token + 1) |tok| {
                const cache_pos = tok % c.max_seq_length;
                const value = state.v_cache[base + cache_pos * kv_dim ..][0..head_size];
                const a = att[tok - window_start];
                for (0..head_size) |j| attn_out[j] += a * value[j];
            }
        }
    }
};

fn applyRoPE(
    vector: []f32,
    sin: []const f32,
    cos: []const f32,
    n_heads: usize,
    head_size: usize,
    n: usize,
) void {
    const base = n * head_size / 2;
    for (0..n_heads) |hi| {
        var hd: usize = 0;
        while (hd < head_size) : (hd += 2) {
            const ii = base + (hd / 2);
            const vi = hi * head_size + hd;
            const v0 = vector[vi];
            const v1 = vector[vi + 1];
            const m_cos = cos[ii];
            const m_sin = sin[ii];
            vector[vi] = v0 * m_cos - v1 * m_sin;
            vector[vi + 1] = v0 * m_sin + v1 * m_cos;
        }
    }
}

pub fn fmtBuf(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch unreachable;
}

pub fn getF32Tensor(file: *const gguf.GGUFFile, td: [*]const u8, name: []const u8) []const f32 {
    const ti = file.getTensorInfo(name) orelse @panic("Missing tensor");
    const ptr: [*]const f32 = @ptrCast(@alignCast(ti.getData(td)));
    return ptr[0..ti.numElements()];
}

pub fn tryGetF32Tensor(file: *const gguf.GGUFFile, td: [*]const u8, name: []const u8) ?[]const f32 {
    const ti = file.getTensorInfo(name) orelse return null;
    const ptr: [*]const f32 = @ptrCast(@alignCast(ti.getData(td)));
    return ptr[0..ti.numElements()];
}

pub fn getTensorRef(file: *const gguf.GGUFFile, td: [*]const u8, name: []const u8) TensorRef {
    const ti = file.getTensorInfo(name) orelse @panic("Missing tensor");
    return TensorRef.fromTensor(ti, td);
}

/// Convert f32 tensor values to u32 indices (for sync neuron indices stored as float in GGUF).
fn f32ToU32Indices(alloc: Allocator, f32_data: []const f32) ![]const u32 {
    const result = try alloc.alloc(u32, f32_data.len);
    for (f32_data, 0..) |v, i| {
        const idx: u32 = @intFromFloat(v);
        result[i] = idx;
    }
    return result;
}

/// Validate sync indices are all < dim (prevents OOB in CTMBlock.forward)
fn validateSyncIndices(indices: []const u32, dim: usize) bool {
    for (indices) |idx| {
        if (idx >= dim) return false;
    }
    return true;
}

pub fn tryGetTensorRef(file: *const gguf.GGUFFile, td: [*]const u8, name: []const u8) ?TensorRef {
    const ti = file.getTensorInfo(name) orelse return null;
    return TensorRef.fromTensor(ti, td);
}
