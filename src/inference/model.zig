// Transformer model for inference
// Supports LLaMA-family architectures (LLaMA, Qwen2, Mistral, etc.)
// These all share: RoPE, SwiGLU MLP, RMSNorm, GQA attention
// Optional CTM (Continuous Thought Machine) blocks replace MLP in selected layers.

const std = @import("std");
const gguf = @import("gguf.zig");
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

    pub fn fromGGUF(file: *const gguf.GGUFFile) Config {
        const arch = file.getString("general.architecture") orelse "llama";
        const ctx_len = @min(file.getU32(archKey(arch, "context_length")) orelse 2048, 2048);
        return .{
            .dim = file.getU32(archKey(arch, "embedding_length")) orelse 512,
            .hidden_dim = file.getU32(archKey(arch, "feed_forward_length")) orelse 1536,
            .n_layers = file.getU32(archKey(arch, "block_count")) orelse 24,
            .n_heads = file.getU32(archKey(arch, "attention.head_count")) orelse 8,
            .n_kv_heads = file.getU32(archKey(arch, "attention.head_count_kv")) orelse 4,
            .vocab_size = if (file.getValue("tokenizer.ggml.tokens")) |v| @intCast(v.array.len) else 32000,
            .max_seq_length = ctx_len,
            .rope_theta = file.getF32(archKey(arch, "rope.freq_base")) orelse 10000.0,
            .rms_norm_eps = file.getF32(archKey(arch, "attention.layer_norm_rms_epsilon")) orelse 1e-6,
            .arch = arch,
            .sliding_window = file.getU32(archKey(arch, "attention.sliding_window")) orelse 0,
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
    attn_norm: []const f32,
    wq: TensorRef,
    wk: TensorRef,
    wv: TensorRef,
    wo: TensorRef,
    // Attention biases (optional — Qwen2 has Q/K biases)
    bq: ?[]const f32 = null,
    bk: ?[]const f32 = null,
    bv: ?[]const f32 = null,
    // MLP (standard SwiGLU) or CTM block
    ffn_norm: []const f32,
    w1: ?TensorRef = null, // gate (null when CTM replaces MLP)
    w2: ?TensorRef = null, // down
    w3: ?TensorRef = null, // up
    // CTM block (replaces MLP when present)
    ctm_block: ?*ctm.CTMBlock = null,
};

/// Reference to quantized or float tensor data in mmap'd file.
const TensorRef = union(enum) {
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

    // F16 dequantization scratch (only needed for f16 weight matrices)
    dequant_buf: []f32,

    // Q8_0 quantization scratch for matmul
    quant_vec: []math.Q80Block,

    // Thread count for parallel matmul
    n_threads: usize,

    // CTM persistent state (sync accumulators across tokens)
    ctm_state: ?*ctm.CTMState = null,
    // CTM scratch buffer for forward pass
    ctm_scratch: []f32 = &.{},

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
            // F16 scratch: only need one row at a time (max_dim * max_dim for full matrix)
            // With fused Q4_K/Q6_K dot products, we no longer need massive dequant buffers.
            // F16 still needs dequant — allocate enough for the largest weight matrix.
            .dequant_buf = try a.alloc(f32, max_dim * max_dim),
            .quant_vec = try a.alloc(math.Q80Block, max_dim / 32),
            .n_threads = @min(math.cpuCount(), 8),
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
    norm: []const f32, // output RMS norm weights
    classifier: TensorRef, // output projection (lm_head)

    arena: std.heap.ArenaAllocator,

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
                .attn_norm = getF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.attn_norm.weight", .{i})),
                .wq = getTensorRef(file, td, fmtBuf(&name_buf, "blk.{d}.attn_q.weight", .{i})),
                .wk = getTensorRef(file, td, fmtBuf(&name_buf, "blk.{d}.attn_k.weight", .{i})),
                .wv = getTensorRef(file, td, fmtBuf(&name_buf, "blk.{d}.attn_v.weight", .{i})),
                .wo = getTensorRef(file, td, fmtBuf(&name_buf, "blk.{d}.attn_output.weight", .{i})),
                .bq = tryGetF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.attn_q.bias", .{i})),
                .bk = tryGetF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.attn_k.bias", .{i})),
                .bv = tryGetF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.attn_v.bias", .{i})),
                .ffn_norm = getF32Tensor(file, td, fmtBuf(&name_buf, "blk.{d}.ffn_norm.weight", .{i})),
                .w1 = tryGetTensorRef(file, td, fmtBuf(&name_buf, "blk.{d}.ffn_gate.weight", .{i})),
                .w2 = tryGetTensorRef(file, td, fmtBuf(&name_buf, "blk.{d}.ffn_down.weight", .{i})),
                .w3 = tryGetTensorRef(file, td, fmtBuf(&name_buf, "blk.{d}.ffn_up.weight", .{i})),
            };
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
        }

        // Load embedding and output weights
        const token_embed = getTensorRef(file, td, "token_embd.weight");
        const norm_weights = getF32Tensor(file, td, "output_norm.weight");
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

        for (0..c.n_layers) |i| {
            const layer_offset = i * c.max_seq_length * kv_dim;
            const layer = self.layers[i];

            // Attention norm
            math.rmsNorm(state.work, state.input, layer.attn_norm);

            // QKV projections
            self.matmulTensor(state.q, layer.wq, state.work, dim, dim, state);
            self.matmulTensor(state.k, layer.wk, state.work, kv_dim, dim, state);
            self.matmulTensor(state.v, layer.wv, state.work, kv_dim, dim, state);

            // Attention biases (Qwen2)
            if (layer.bq) |bq| math.add(state.q, state.q, bq);
            if (layer.bk) |bk| math.add(state.k, state.k, bk);
            if (layer.bv) |bv| math.add(state.v, state.v, bv);

            // RoPE
            applyRoPE(state.q, state.sin, state.cos, c.n_heads, head_size, n_tok);
            applyRoPE(state.k, state.sin, state.cos, c.n_kv_heads, head_size, n_tok);

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

            // FFN norm
            math.rmsNorm(state.work, state.input, layer.ffn_norm);

            if (layer.ctm_block) |ctm_block| {
                // CTM block replaces MLP: K thinking iterations with sync
                ctm_block.forward(
                    state.work,
                    state.work2,
                    state.ctm_state.?,
                    i,
                    state.ctm_scratch,
                );
                // Residual
                math.add(state.input, state.input, state.work2);
            } else if (layer.w1 != null and layer.w2 != null and layer.w3 != null) {
                // Standard MLP: SwiGLU(w1(x)) * w3(x), then w2
                self.matmulTensor(state.hidden1, layer.w1.?, state.work, c.hidden_dim, dim, state);
                self.matmulTensor(state.hidden2, layer.w3.?, state.work, c.hidden_dim, dim, state);

                math.swiglu(state.hidden1);
                math.elementProduct(state.hidden1, state.hidden1, state.hidden2);

                self.matmulTensor(state.work, layer.w2.?, state.hidden1, dim, c.hidden_dim, state);

                // Residual
                math.add(state.input, state.input, state.work);
            }
            // else: CTM layer with no MLP and no loaded CTM block — skip (identity residual)
        }

        // Final norm
        math.rmsNorm(state.input, state.input, self.norm);

        // Classifier projection
        self.matmulTensor(state.output, self.classifier, state.input, c.vocab_size, dim, state);

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
    /// Q4_K/Q6_K use fused dot products (no intermediate dequant buffer).
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
        _ = self;
        const n_threads = state.n_threads;
        switch (weights) {
            .f32 => |data| {
                const ctx = math.F32MatmulCtx{ .data = data, .x = x, .cols = cols };
                math.matmulParallel(out, rows, math.F32MatmulCtx, ctx, n_threads);
            },
            .f16 => |data| {
                // Dequantize to scratch, then matmul
                for (0..data.len) |i| state.dequant_buf[i] = @floatCast(data[i]);
                const ctx = math.F32MatmulCtx{ .data = state.dequant_buf[0 .. rows * cols], .x = x, .cols = cols };
                math.matmulParallel(out, rows, math.F32MatmulCtx, ctx, n_threads);
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

fn fmtBuf(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch unreachable;
}

fn getF32Tensor(file: *const gguf.GGUFFile, td: [*]const u8, name: []const u8) []const f32 {
    const ti = file.getTensorInfo(name) orelse @panic("Missing tensor");
    const ptr: [*]const f32 = @ptrCast(@alignCast(ti.getData(td)));
    return ptr[0..ti.numElements()];
}

fn tryGetF32Tensor(file: *const gguf.GGUFFile, td: [*]const u8, name: []const u8) ?[]const f32 {
    const ti = file.getTensorInfo(name) orelse return null;
    const ptr: [*]const f32 = @ptrCast(@alignCast(ti.getData(td)));
    return ptr[0..ti.numElements()];
}

fn getTensorRef(file: *const gguf.GGUFFile, td: [*]const u8, name: []const u8) TensorRef {
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

fn tryGetTensorRef(file: *const gguf.GGUFFile, td: [*]const u8, name: []const u8) ?TensorRef {
    const ti = file.getTensorInfo(name) orelse return null;
    return TensorRef.fromTensor(ti, td);
}
