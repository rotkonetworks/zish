// Audio encoder: mel features → hidden representations
//
// Whisper-style transformer encoder. Same building blocks as the decoder
// (attention, norms, linear projections, SIMD matmul) but different wiring:
// - Full bidirectional attention (no causal mask)
// - GELU activation (not SwiGLU)
// - Conv1D frontend (not token embedding)
// - No KV cache (processes entire utterance at once)
// - Sinusoidal position encoding (not RoPE)
//
// The encoder is a pure function: mel_features → audio_embeddings.
// No state, no side effects. isis would approve.

const std = @import("std");
const gguf = @import("gguf.zig");
const math = @import("math.zig");

const Allocator = std.mem.Allocator;
const TensorRef = @import("model.zig").TensorRef;

// Reuse model.zig helpers
const getF32Tensor = @import("model.zig").getF32Tensor;
const tryGetF32Tensor = @import("model.zig").tryGetF32Tensor;
const getTensorRef = @import("model.zig").getTensorRef;
const tryGetTensorRef = @import("model.zig").tryGetTensorRef;
const fmtBuf = @import("model.zig").fmtBuf;

pub const EncoderConfig = struct {
    d_model: usize, // 896
    n_layers: usize, // 18
    n_heads: usize, // 14
    ffn_dim: usize, // 3584
    n_mel_bins: usize, // 128
    conv_channels: usize, // 480 (2D conv output channels)
    max_source_positions: usize, // 1500
    output_dim: usize, // 1024 (decoder dim)
    conv_chunksize: usize, // 500

    pub fn fromGGUF(file: *const gguf.GGUFFile) EncoderConfig {
        return .{
            .d_model = file.getU32("encoder.embedding_length") orelse 896,
            .n_layers = file.getU32("encoder.block_count") orelse 18,
            .n_heads = file.getU32("encoder.attention.head_count") orelse 14,
            .ffn_dim = file.getU32("encoder.feed_forward_length") orelse 3584,
            .n_mel_bins = file.getU32("encoder.mel_bins") orelse 128,
            .conv_channels = file.getU32("encoder.conv_channels") orelse 480,
            .max_source_positions = file.getU32("encoder.max_source_positions") orelse 1500,
            .output_dim = file.getU32("encoder.output_dim") orelse 1024,
            .conv_chunksize = file.getU32("encoder.conv_chunksize") orelse 500,
        };
    }
};

/// Weights for one encoder layer.
const EncoderLayer = struct {
    // Self-attention
    attn_norm_w: []const f32,
    attn_norm_b: ?[]const f32,
    wq: TensorRef,
    wk: TensorRef,
    wv: TensorRef,
    wo: TensorRef,
    bq: ?[]const f32 = null,
    bk: ?[]const f32 = null,
    bv: ?[]const f32 = null,
    bo: ?[]const f32 = null,
    // FFN (GELU, not SwiGLU — two linears not three)
    ffn_norm_w: []const f32,
    ffn_norm_b: ?[]const f32,
    ffn_up: TensorRef, // (ffn_dim, d_model)
    ffn_down: TensorRef, // (d_model, ffn_dim)
    ffn_up_bias: ?[]const f32 = null,
    ffn_down_bias: ?[]const f32 = null,
};

/// Working buffers for encoder forward pass.
pub const EncoderState = struct {
    arena: std.heap.ArenaAllocator,
    config: EncoderConfig,

    // Sequence buffers (allocated for max_source_positions)
    // Layout: [T, d_model] row-major
    x: []f32, // current hidden state
    work: []f32, // scratch (max of d_model, d_model*2 for conv flatten)
    conv_buf: []f32, // conv2d intermediate [T, conv_channels, freq]
    q: []f32, // query projections [T, d_model]
    k: []f32, // key projections [T, d_model]
    v: []f32, // value projections [T, d_model]
    attn: []f32, // attention weights [n_heads, T, T]
    ffn_hidden: []f32, // FFN intermediate [T, ffn_dim]
    out: []f32, // output after projection [T, output_dim]

    n_threads: usize,

    pub fn init(alloc: Allocator, config: EncoderConfig) !EncoderState {
        var arena = std.heap.ArenaAllocator.init(alloc);
        const a = arena.allocator();
        const T = config.max_source_positions;
        const d = config.d_model;
        const conv_flat = config.conv_channels * (config.n_mel_bins / 8); // 480 * 16 = 7680

        return .{
            .arena = arena,
            .config = config,
            .x = try a.alloc(f32, T * d),
            .work = try a.alloc(f32, @max(T * d, conv_flat)),
            .conv_buf = try a.alloc(f32, T * conv_flat),
            .q = try a.alloc(f32, T * d),
            .k = try a.alloc(f32, T * d),
            .v = try a.alloc(f32, T * d),
            .attn = try a.alloc(f32, config.n_heads * T * T),
            .ffn_hidden = try a.alloc(f32, T * config.ffn_dim),
            .out = try a.alloc(f32, T * config.output_dim),
            .n_threads = @min(math.cpuCount(), 16),
        };
    }

    pub fn deinit(self: *EncoderState) void {
        self.arena.deinit();
    }
};

pub const AudioEncoder = struct {
    config: EncoderConfig,

    // Conv2D frontend: 3× Conv2D(3×3) with 480 channels
    // Treats mel spectrogram as 2D image: [1, T, 128]
    // After 3 convs with stride 2 in freq: 128 → 64 → 32 → 16
    // conv_out projects flattened [480 × 16 = 7680] → d_model
    conv2d1_w: TensorRef, // [480, 1, 3, 3]
    conv2d1_b: []const f32, // [480]
    conv2d2_w: TensorRef, // [480, 480, 3, 3]
    conv2d2_b: []const f32, // [480]
    conv2d3_w: TensorRef, // [480, 480, 3, 3]
    conv2d3_b: []const f32, // [480]
    conv_out_w: TensorRef, // [896, 7680]

    // Sinusoidal position embeddings (precomputed)
    pos_embed: []f32, // [max_source_positions, d_model]

    // Transformer layers
    layers: []EncoderLayer,

    // Output norm + projection chain: d_model → d_model → output_dim
    ln_post_w: []const f32,
    ln_post_b: ?[]const f32,
    proj1_w: TensorRef, // [896, 896]
    proj1_b: ?[]const f32, // [896]
    proj2_w: TensorRef, // [1024, 896]
    proj2_b: ?[]const f32, // [1024]

    arena: std.heap.ArenaAllocator,

    pub fn initFromGGUF(file: *const gguf.GGUFFile, alloc: Allocator) !AudioEncoder {
        const config = EncoderConfig.fromGGUF(file);
        const td = file.tensorData();

        var arena = std.heap.ArenaAllocator.init(alloc);
        const a = arena.allocator();

        // Precompute sinusoidal position embeddings
        const pos_embed = try precomputeSinusoidal(a, config.max_source_positions, config.d_model);

        // Load layers
        var layers = try a.alloc(EncoderLayer, config.n_layers);
        var name_buf: [128]u8 = undefined;
        for (0..config.n_layers) |i| {
            layers[i] = .{
                .attn_norm_w = getF32Tensor(file, td, fmtBuf(&name_buf, "encoder.blk.{d}.attn_norm.weight", .{i})),
                .attn_norm_b = tryGetF32Tensor(file, td, fmtBuf(&name_buf, "encoder.blk.{d}.attn_norm.bias", .{i})),
                .wq = getTensorRef(file, td, fmtBuf(&name_buf, "encoder.blk.{d}.attn_q.weight", .{i})),
                .wk = getTensorRef(file, td, fmtBuf(&name_buf, "encoder.blk.{d}.attn_k.weight", .{i})),
                .wv = getTensorRef(file, td, fmtBuf(&name_buf, "encoder.blk.{d}.attn_v.weight", .{i})),
                .wo = getTensorRef(file, td, fmtBuf(&name_buf, "encoder.blk.{d}.attn_output.weight", .{i})),
                .bq = tryGetF32Tensor(file, td, fmtBuf(&name_buf, "encoder.blk.{d}.attn_q.bias", .{i})),
                .bk = tryGetF32Tensor(file, td, fmtBuf(&name_buf, "encoder.blk.{d}.attn_k.bias", .{i})),
                .bv = tryGetF32Tensor(file, td, fmtBuf(&name_buf, "encoder.blk.{d}.attn_v.bias", .{i})),
                .bo = tryGetF32Tensor(file, td, fmtBuf(&name_buf, "encoder.blk.{d}.attn_output.bias", .{i})),
                .ffn_norm_w = getF32Tensor(file, td, fmtBuf(&name_buf, "encoder.blk.{d}.ffn_norm.weight", .{i})),
                .ffn_norm_b = tryGetF32Tensor(file, td, fmtBuf(&name_buf, "encoder.blk.{d}.ffn_norm.bias", .{i})),
                .ffn_up = getTensorRef(file, td, fmtBuf(&name_buf, "encoder.blk.{d}.ffn_up.weight", .{i})),
                .ffn_down = getTensorRef(file, td, fmtBuf(&name_buf, "encoder.blk.{d}.ffn_down.weight", .{i})),
                .ffn_up_bias = tryGetF32Tensor(file, td, fmtBuf(&name_buf, "encoder.blk.{d}.ffn_up.bias", .{i})),
                .ffn_down_bias = tryGetF32Tensor(file, td, fmtBuf(&name_buf, "encoder.blk.{d}.ffn_down.bias", .{i})),
            };
        }

        return .{
            .config = config,
            .conv2d1_w = getTensorRef(file, td, "encoder.conv2d1.weight"),
            .conv2d1_b = getF32Tensor(file, td, "encoder.conv2d1.bias"),
            .conv2d2_w = getTensorRef(file, td, "encoder.conv2d2.weight"),
            .conv2d2_b = getF32Tensor(file, td, "encoder.conv2d2.bias"),
            .conv2d3_w = getTensorRef(file, td, "encoder.conv2d3.weight"),
            .conv2d3_b = getF32Tensor(file, td, "encoder.conv2d3.bias"),
            .conv_out_w = getTensorRef(file, td, "encoder.conv_out.weight"),
            .pos_embed = pos_embed,
            .layers = layers,
            .ln_post_w = getF32Tensor(file, td, "encoder.ln_post.weight"),
            .ln_post_b = tryGetF32Tensor(file, td, "encoder.ln_post.bias"),
            .proj1_w = getTensorRef(file, td, "encoder.proj1.weight"),
            .proj1_b = tryGetF32Tensor(file, td, "encoder.proj1.bias"),
            .proj2_w = getTensorRef(file, td, "encoder.proj2.weight"),
            .proj2_b = tryGetF32Tensor(file, td, "encoder.proj2.bias"),
            .arena = arena,
        };
    }

    pub fn deinit(self: *AudioEncoder) void {
        self.arena.deinit();
    }

    /// Forward pass: mel features → projected audio embeddings.
    /// mel: [n_frames, n_mel_bins] row-major (f32)
    /// Returns slice into state.out: [seq_len, output_dim]
    pub fn forward(
        self: *const AudioEncoder,
        state: *EncoderState,
        mel: []const f32,
        n_frames: usize,
    ) []f32 {
        const d = self.config.d_model;
        const ch = self.config.conv_channels; // 480
        const n_mels = self.config.n_mel_bins; // 128

        // 1. Conv2D frontend
        // Input: mel [n_frames, 128] → treat as [n_frames, 128, 1] (H=time, W=freq, C=1)
        // Conv2D(1→480, 3×3, stride=(1,2)) → [T, 64, 480]
        // Conv2D(480→480, 3×3, stride=(1,2)) → [T, 32, 480]
        // Conv2D(480→480, 3×3, stride=(1,2)) → [T, 16, 480]
        // Flatten: [T, 16*480=7680]
        // Linear conv_out: [T, 7680] → [T, 896]

        // Input as channels-last: [n_frames, 128, 1]
        // We need to reshape mel from [n_frames, 128] to [n_frames, 128, 1]
        // Since channel dim is 1, the data is the same — just interpret differently

        // Conv2d1: [480, 1, 3, 3], stride=(1,2) in (time, freq)
        const freq1 = (n_mels + 2 * 1 - 3) / 2 + 1; // 64 with pad=1
        const time1 = n_frames; // stride 1 in time
        doConv2d(state.conv_buf[0 .. time1 * freq1 * ch], mel, self.conv2d1_w,
            self.conv2d1_b, n_frames, n_mels, 1, ch, 3, 3, 1, 2);
        math.gelu(state.conv_buf[0 .. time1 * freq1 * ch]);

        // Conv2d2: [480, 480, 3, 3], stride=(1,2)
        const freq2 = (freq1 + 2 * 1 - 3) / 2 + 1; // 32
        const time2 = time1;
        doConv2d(state.work[0 .. time2 * freq2 * ch], state.conv_buf[0 .. time1 * freq1 * ch],
            self.conv2d2_w, self.conv2d2_b, time1, freq1, ch, ch, 3, 3, 1, 2);
        math.gelu(state.work[0 .. time2 * freq2 * ch]);

        // Conv2d3: [480, 480, 3, 3], stride=(1,2)
        const freq3 = (freq2 + 2 * 1 - 3) / 2 + 1; // 16
        const time3 = time2;
        doConv2d(state.conv_buf[0 .. time3 * freq3 * ch], state.work[0 .. time2 * freq2 * ch],
            self.conv2d3_w, self.conv2d3_b, time2, freq2, ch, ch, 3, 3, 1, 2);
        math.gelu(state.conv_buf[0 .. time3 * freq3 * ch]);

        // Flatten [T, 16, 480] → [T, 7680] — already in that layout (channels last)
        const flat_dim = freq3 * ch; // 16 * 480 = 7680
        const seq_len = time3;

        // Linear projection: conv_out [896, 7680] @ flat → [T, 896]
        for (0..seq_len) |t| {
            matmulTensor(
                state.x[t * d ..][0..d],
                self.conv_out_w,
                state.conv_buf[t * flat_dim ..][0..flat_dim],
                d,
                flat_dim,
            );
        }

        // 2. Add sinusoidal position embeddings
        for (0..seq_len) |t| {
            math.add(
                state.x[t * d ..][0..d],
                state.x[t * d ..][0..d],
                self.pos_embed[t * d ..][0..d],
            );
        }

        // 3. Transformer layers
        for (self.layers) |*layer| {
            self.encoderLayer(state, layer, seq_len);
        }

        // 4. Post-norm
        for (0..seq_len) |t| {
            math.layerNorm(
                state.x[t * d ..][0..d],
                state.x[t * d ..][0..d],
                self.ln_post_w,
                self.ln_post_b,
                1e-6,
            );
        }

        // 5. Projection chain: d_model → d_model → output_dim
        const out_dim = self.config.output_dim;
        for (0..seq_len) |t| {
            // proj1: [896, 896] @ x → work
            matmulTensor(state.work[0..d], self.proj1_w, state.x[t * d ..][0..d], d, d);
            if (self.proj1_b) |b| math.add(state.work[0..d], state.work[0..d], b);
            math.gelu(state.work[0..d]);

            // proj2: [1024, 896] @ work → out
            matmulTensor(
                state.out[t * out_dim ..][0..out_dim],
                self.proj2_w,
                state.work[0..d],
                out_dim,
                d,
            );
            if (self.proj2_b) |b| {
                math.add(
                    state.out[t * out_dim ..][0..out_dim],
                    state.out[t * out_dim ..][0..out_dim],
                    b,
                );
            }
        }

        return state.out[0 .. seq_len * out_dim];
    }

    /// One encoder layer: LayerNorm → MultiHeadAttention → residual → LayerNorm → FFN → residual
    fn encoderLayer(
        self: *const AudioEncoder,
        state: *EncoderState,
        layer: *const EncoderLayer,
        seq_len: usize,
    ) void {
        const d = self.config.d_model;
        const n_heads = self.config.n_heads;
        const head_dim = d / n_heads;

        // Pre-attention norm
        for (0..seq_len) |t| {
            math.layerNorm(
                state.work[t * d ..][0..d],
                state.x[t * d ..][0..d],
                layer.attn_norm_w,
                layer.attn_norm_b,
                1e-6,
            );
        }

        // QKV projections for all positions
        for (0..seq_len) |t| {
            const src = state.work[t * d ..][0..d];
            matmulTensor(state.q[t * d ..][0..d], layer.wq, src, d, d);
            matmulTensor(state.k[t * d ..][0..d], layer.wk, src, d, d);
            matmulTensor(state.v[t * d ..][0..d], layer.wv, src, d, d);

            // Add biases
            if (layer.bq) |b| math.add(state.q[t * d ..][0..d], state.q[t * d ..][0..d], b);
            if (layer.bk) |b| math.add(state.k[t * d ..][0..d], state.k[t * d ..][0..d], b);
            if (layer.bv) |b| math.add(state.v[t * d ..][0..d], state.v[t * d ..][0..d], b);
        }

        // Multi-head full attention (not causal — every position sees every other)
        const scale = 1.0 / std.math.sqrt(@as(f32, @floatFromInt(head_dim)));
        for (0..n_heads) |h| {
            // For each query position
            for (0..seq_len) |qi| {
                // Compute attention scores: q[qi] · k[kj] for all kj
                const attn_row = state.attn[h * seq_len * seq_len + qi * seq_len ..][0..seq_len];
                for (0..seq_len) |kj| {
                    var dot: f32 = 0;
                    for (0..head_dim) |hd| {
                        dot += state.q[qi * d + h * head_dim + hd] *
                            state.k[kj * d + h * head_dim + hd];
                    }
                    attn_row[kj] = dot * scale;
                }
                // Softmax
                math.softMax(attn_row);

                // Weighted sum of values → overwrite work[qi] for this head
                for (0..head_dim) |hd| {
                    var sum: f32 = 0;
                    for (0..seq_len) |vj| {
                        sum += attn_row[vj] * state.v[vj * d + h * head_dim + hd];
                    }
                    // Write back to work buffer at head position
                    state.work[qi * d + h * head_dim + hd] = sum;
                }
            }
        }

        // Output projection + residual
        for (0..seq_len) |t| {
            var attn_out: [4096]f32 = undefined; // max d_model
            matmulTensor(attn_out[0..d], layer.wo, state.work[t * d ..][0..d], d, d);
            if (layer.bo) |b| math.add(attn_out[0..d], attn_out[0..d], b);
            math.add(state.x[t * d ..][0..d], state.x[t * d ..][0..d], attn_out[0..d]);
        }

        // Pre-FFN norm
        for (0..seq_len) |t| {
            math.layerNorm(
                state.work[t * d ..][0..d],
                state.x[t * d ..][0..d],
                layer.ffn_norm_w,
                layer.ffn_norm_b,
                1e-6,
            );
        }

        // FFN: up → GELU → down (not SwiGLU — no gate)
        const ffn_dim = self.config.ffn_dim;
        for (0..seq_len) |t| {
            // Up projection
            matmulTensor(
                state.ffn_hidden[t * ffn_dim ..][0..ffn_dim],
                layer.ffn_up,
                state.work[t * d ..][0..d],
                ffn_dim,
                d,
            );
            if (layer.ffn_up_bias) |b| {
                math.add(
                    state.ffn_hidden[t * ffn_dim ..][0..ffn_dim],
                    state.ffn_hidden[t * ffn_dim ..][0..ffn_dim],
                    b,
                );
            }
            // GELU
            math.gelu(state.ffn_hidden[t * ffn_dim ..][0..ffn_dim]);
            // Down projection
            var ffn_out: [4096]f32 = undefined;
            matmulTensor(
                ffn_out[0..d],
                layer.ffn_down,
                state.ffn_hidden[t * ffn_dim ..][0..ffn_dim],
                d,
                ffn_dim,
            );
            if (layer.ffn_down_bias) |b| math.add(ffn_out[0..d], ffn_out[0..d], b);
            // Residual
            math.add(state.x[t * d ..][0..d], state.x[t * d ..][0..d], ffn_out[0..d]);
        }
    }
};

// ============================================================
// Helpers
// ============================================================

/// Dispatch Conv2D on TensorRef weight type (f32 or f16).
fn doConv2d(
    out: []f32,
    input: []const f32,
    weight: TensorRef,
    bias: []const f32,
    in_h: usize,
    in_w: usize,
    in_ch: usize,
    out_ch: usize,
    kh: usize,
    kw: usize,
    stride_h: usize,
    stride_w: usize,
) void {
    switch (weight) {
        .f32 => |data| math.conv2d(out, input, data, bias, in_h, in_w, in_ch, out_ch, kh, kw, stride_h, stride_w),
        .f16 => |data| math.conv2dF16(out, input, data, bias, in_h, in_w, in_ch, out_ch, kh, kw, stride_h, stride_w),
        else => @panic("Conv2D: unsupported weight type"),
    }
}

/// Sinusoidal position embeddings (Vaswani et al. 2017).
/// pe[pos, 2i] = sin(pos / 10000^(2i/d_model))
/// pe[pos, 2i+1] = cos(pos / 10000^(2i/d_model))
fn precomputeSinusoidal(alloc: Allocator, max_len: usize, d_model: usize) ![]f32 {
    const pe = try alloc.alloc(f32, max_len * d_model);
    const d_f: f32 = @floatFromInt(d_model);

    for (0..max_len) |pos| {
        const pos_f: f32 = @floatFromInt(pos);
        for (0..d_model / 2) |i| {
            const i_f: f32 = @floatFromInt(i * 2);
            const freq = pos_f / std.math.pow(f32, 10000.0, i_f / d_f);
            pe[pos * d_model + i * 2] = @sin(freq);
            pe[pos * d_model + i * 2 + 1] = @cos(freq);
        }
    }
    return pe;
}

/// Generic matrix-vector multiply dispatching on TensorRef quantization type.
/// Same as model.zig matmulTensor but importable.
fn matmulTensor(out: []f32, w: TensorRef, x: []const f32, rows: usize, cols: usize) void {
    switch (w) {
        .f32 => |data| math.matmul(out, data, x, rows, cols),
        .f16 => |data| {
            const ctx = math.F16MatmulCtx{ .data = data, .x = x, .cols = cols };
            for (0..rows) |i| out[i] = ctx.computeRow(i);
        },
        .q8_0 => |data| {
            // Need quantized input vector
            const block_size = 32;
            const n_blocks = cols / block_size;
            var x_blocks: [256]math.Q80Block = undefined; // max cols/32
            math.quantizeQ80(x, x_blocks[0..n_blocks]);
            const ctx = math.Q80MatmulCtx{ .data = data, .x_quant = x_blocks[0..n_blocks], .cols = cols };
            for (0..rows) |i| out[i] = ctx.computeRow(i);
        },
        .q4_k => |data| {
            const ctx = math.Q4KMatmulCtx{ .data = data, .x = x, .cols = cols };
            for (0..rows) |i| out[i] = ctx.computeRow(i);
        },
        .q6_k => |data| {
            const ctx = math.Q6KMatmulCtx{ .data = data, .x = x, .cols = cols };
            for (0..rows) |i| out[i] = ctx.computeRow(i);
        },
    }
}
