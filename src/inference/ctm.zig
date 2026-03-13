// Continuous Thought Machine (CTM) module for inference
// Implements the CTMBlock that replaces MLP in transformer layers.
// Adapted from nanochat/gpt.py CTMBlock.
//
// Key components:
//   - SuperLinear: per-neuron parallel MLPs (einsum BNM,MON->BNO)
//   - SynapseUNET: U-NET skip-connection network (down path + up path)
//   - Dual synchronisation: pairwise products with exponential decay
//   - Cross-attention: sync-driven query re-observes input at each tick

const std = @import("std");
const math = @import("math.zig");

const Allocator = std.mem.Allocator;

// ============================================================
// CTM Configuration (loaded from GGUF metadata)
// ============================================================

pub const CTMConfig = struct {
    dim: usize, // D: model dimension
    iterations: usize = 4, // K: thinking ticks per token
    memory_length: usize = 16, // M: trace history depth
    n_synch: usize = 384, // pairwise sync dimension
    memory_hidden: usize = 32, // NLM hidden dim
    n_attn_heads: usize = 1, // cross-attention heads
    synapse_depth: usize = 32, // U-NET depth (even)
    adaptive_k: bool = false, // sqrt (false) vs mean (true)
    bottleneck: usize = 16, // U-NET bottleneck width
};

// ============================================================
// SuperLinear: N independent linear transforms in parallel
// ============================================================
// Input:  (N, M) where N = num neurons, M = history length
// Output: (N, O) where O = output dims
// Weight: (M, O, N) — einsum 'NM, MON -> NO'

pub const SuperLinear = struct {
    w: []const f32, // (M, O, N) flattened row-major
    b: []const f32, // (N, O) flattened row-major
    in_dims: usize, // M
    out_dims: usize, // O
    n_neurons: usize, // N

    /// Compute: out[n, o] = sum_m(x[n, m] * w[m, o, n]) + b[n, o]
    pub fn forward(self: *const SuperLinear, x: []const f32, out: []f32) void {
        const M = self.in_dims;
        const O = self.out_dims;
        const N = self.n_neurons;

        for (0..N) |n| {
            for (0..O) |o| {
                var sum: f32 = self.b[n * O + o];
                for (0..M) |m| {
                    // w is (M, O, N) row-major: w[m][o][n] = w[(m * O + o) * N + n]
                    sum += x[n * M + m] * self.w[(m * O + o) * N + n];
                }
                out[n * O + o] = sum;
            }
        }
    }
};

// ============================================================
// GLU activation: split in half, sigmoid gate
// ============================================================

/// GLU along last dim: x[..., :half] * sigmoid(x[..., half:])
fn glu(data: []f32, count: usize, dim: usize) void {
    const half = dim / 2;
    for (0..count) |i| {
        const base = i * dim;
        for (0..half) |j| {
            const gate = data[base + half + j];
            const sig = 1.0 / (1.0 + std.math.exp(-gate));
            data[base + j] *= sig;
        }
    }
}

// ============================================================
// LayerNorm (for SynapseUNET skip connections)
// ============================================================

fn layerNorm(out: []f32, x: []const f32, weight: []const f32, bias: []const f32, dim: usize) void {
    // Compute mean
    var mean: f32 = 0;
    for (x[0..dim]) |v| mean += v;
    mean /= @as(f32, @floatFromInt(dim));

    // Compute variance
    var variance: f32 = 0;
    for (x[0..dim]) |v| {
        const d = v - mean;
        variance += d * d;
    }
    variance /= @as(f32, @floatFromInt(dim));

    const inv_std = 1.0 / std.math.sqrt(variance + 1e-5);

    for (0..dim) |i| {
        out[i] = (x[i] - mean) * inv_std * weight[i] + bias[i];
    }
}

// ============================================================
// SynapseUNET: U-NET with skip connections
// ============================================================

pub const SynapseUNET = struct {
    // Down path: half_k linear layers
    down_weights: []const []const f32, // each (in_w, out_w) flattened
    down_in_dims: []const usize,
    down_out_dims: []const usize,
    // Up path: half_k linear layers + layer norms
    up_weights: []const []const f32,
    up_in_dims: []const usize,
    up_out_dims: []const usize,
    up_ln_weight: []const []const f32,
    up_ln_bias: []const []const f32,
    half_k: usize,

    /// Forward pass: x (2*D) -> out (D)
    /// scratch must be large enough for intermediate activations
    pub fn forward(self: *const SynapseUNET, x: []const f32, out: []f32, scratch: []f32) void {
        // We need skip connection storage. Use regions of scratch buffer.
        // scratch layout: [down_activations...] [work_a] [work_b]
        const max_dim = self.down_in_dims[0]; // input dim is largest
        const skip_total = blk: {
            var total: usize = 0;
            for (self.down_out_dims) |d| total += d;
            break :blk total;
        };

        // down activations stored contiguously in scratch[0..skip_total]
        // work buffers after that
        // max_dim must accommodate concat: prev_out + skip for up path
        const concat_max = blk: {
            var m = max_dim;
            for (0..self.half_k) |i| {
                if (i > 0) {
                    const prev = self.up_out_dims[i - 1];
                    const skip = self.down_out_dims[self.half_k - 1 - i];
                    if (prev + skip > m) m = prev + skip;
                }
            }
            break :blk m;
        };
        const work_a = scratch[skip_total..][0..concat_max];
        const work_b = scratch[skip_total + concat_max ..][0..concat_max];

        // Copy input to work_a
        @memcpy(work_a[0..x.len], x);

        // Down path (max 32 skip layers)
        if (self.half_k > 32) return; // safety: skip_offsets is fixed-size
        var skip_offsets: [32]usize = undefined;
        var skip_off: usize = 0;
        for (0..self.half_k) |i| {
            const in_d = self.down_in_dims[i];
            const out_d = self.down_out_dims[i];
            const w = self.down_weights[i];

            // Linear: work_b[j] = sum_k(work_a[k] * w[j * in_d + k])
            linearForward(work_b[0..out_d], work_a[0..in_d], w, out_d, in_d);

            // SiLU activation
            for (work_b[0..out_d]) |*v| {
                v.* = v.* / (1.0 + std.math.exp(-v.*));
            }

            // Save skip connection
            skip_offsets[i] = skip_off;
            @memcpy(scratch[skip_off..][0..out_d], work_b[0..out_d]);
            skip_off += out_d;

            // Swap for next iteration
            @memcpy(work_a[0..out_d], work_b[0..out_d]);
        }

        // Up path
        // Start from bottleneck (last skip)
        const last_skip = self.half_k - 1;
        const bot_dim = self.down_out_dims[last_skip];
        @memcpy(work_a[0..bot_dim], scratch[skip_offsets[last_skip]..][0..bot_dim]);

        for (0..self.half_k) |i| {
            const out_d = self.up_out_dims[i];

            if (i > 0) {
                // Concat with skip from matched down layer
                const skip_idx = self.half_k - 1 - i;
                const skip_dim = self.down_out_dims[skip_idx];
                const prev_dim = self.up_out_dims[i - 1];
                // work_a already has prev output in [0..prev_dim]
                // Append skip to make [prev_dim..prev_dim+skip_dim]
                @memcpy(work_a[prev_dim..][0..skip_dim], scratch[skip_offsets[skip_idx]..][0..skip_dim]);
            }

            const in_d = self.up_in_dims[i];
            const w = self.up_weights[i];

            // Linear
            linearForward(work_b[0..out_d], work_a[0..in_d], w, out_d, in_d);

            // SiLU
            for (work_b[0..out_d]) |*v| {
                v.* = v.* / (1.0 + std.math.exp(-v.*));
            }

            // LayerNorm
            layerNorm(work_a[0..out_d], work_b[0..out_d], self.up_ln_weight[i], self.up_ln_bias[i], out_d);
        }

        // Output is in work_a[0..output_dim]
        const out_dim = self.up_out_dims[self.half_k - 1];
        @memcpy(out[0..out_dim], work_a[0..out_dim]);
    }
};

/// Simple matrix-vector multiply: out[i] = sum_j(x[j] * w[i * cols + j])
fn linearForward(out: []f32, x: []const f32, w: []const f32, rows: usize, cols: usize) void {
    for (0..rows) |i| {
        var sum: f32 = 0;
        for (0..cols) |j| {
            sum += x[j] * w[i * cols + j];
        }
        out[i] = sum;
    }
}

// ============================================================
// QK Normalization (RMSNorm without learnable weight)
// ============================================================

fn qkNorm(out: []f32, x: []const f32, dim: usize) void {
    var sum_sq: f32 = 0;
    for (x[0..dim]) |v| sum_sq += v * v;
    const rms = std.math.sqrt(sum_sq / @as(f32, @floatFromInt(dim)) + 1e-6);
    for (0..dim) |i| out[i] = x[i] / rms;
}

// ============================================================
// CTM Persistent State (carried across tokens)
// ============================================================

pub const CTMState = struct {
    // Per-layer persistent state (sync accumulators — WHERE memory lives)
    alpha_out: []f32, // (n_synch)
    beta_out: []f32, // (n_synch)
    alpha_act: []f32, // (n_synch)
    beta_act: []f32, // (n_synch)
    initialized: bool = false,

    // Dopamine: per-token neuromodulatory signal, set by caller.
    // Scales how strongly each token's pairwise products contribute to sync.
    // During training always 1.0. At inference clamped to [0.5, 1.0].
    // > 1.0 causes positive feedback: garbage → surprise → harder accumulation of garbage.
    dopamine: f32 = 1.0,

    // Surprise EMA for dopamine computation
    surprise_ema: ?f32 = null,

    // Last forward pass state capture (for compact_memory input)
    last_state: ?[]f32 = null, // (D) — neuron activations after K ticks

    // Metadata for serialization
    n_layers: usize = 0,
    n_synch: usize = 0,

    arena: std.heap.ArenaAllocator,

    pub fn init(alloc: Allocator, n_layers: usize, n_synch: usize) !CTMState {
        var arena = std.heap.ArenaAllocator.init(alloc);
        const a = arena.allocator();
        const total = n_layers * n_synch;
        return .{
            .alpha_out = try a.alloc(f32, total),
            .beta_out = try a.alloc(f32, total),
            .alpha_act = try a.alloc(f32, total),
            .beta_act = try a.alloc(f32, total),
            .n_layers = n_layers,
            .n_synch = n_synch,
            .arena = arena,
        };
    }

    pub fn deinit(self: *CTMState) void {
        self.arena.deinit();
    }

    pub fn layerSlice(self: *CTMState, layer: usize, n_synch: usize) struct {
        alpha_out: []f32,
        beta_out: []f32,
        alpha_act: []f32,
        beta_act: []f32,
    } {
        const off = layer * n_synch;
        return .{
            .alpha_out = self.alpha_out[off..][0..n_synch],
            .beta_out = self.beta_out[off..][0..n_synch],
            .alpha_act = self.alpha_act[off..][0..n_synch],
            .beta_act = self.beta_act[off..][0..n_synch],
        };
    }

    /// Compute dopamine from prediction surprise.
    /// surprise = -log(p(sampled_token)). Call after sampling each token.
    /// Dopamine is clamped to [0.5, 1.0] to prevent positive feedback loops.
    pub fn updateDopamine(self: *CTMState, surprise: f32) void {
        const DOPA_MIN: f32 = 0.5;
        const DOPA_MAX: f32 = 1.0;

        if (self.surprise_ema) |ema| {
            self.surprise_ema = 0.9 * ema + 0.1 * surprise;
        } else {
            self.surprise_ema = surprise;
        }

        // raw signal: tanh(surprise - ema) in [-1, 1]
        const raw = std.math.tanh(surprise - self.surprise_ema.?);
        // map [-1, 1] -> [DOPA_MIN, DOPA_MAX]
        const dopa = DOPA_MIN + (DOPA_MAX - DOPA_MIN) * (raw + 1.0) / 2.0;
        self.dopamine = std.math.clamp(dopa, DOPA_MIN, DOPA_MAX);
    }

    // ============================================================
    // Persistence: save/load sync state to disk
    // ============================================================

    const MAGIC: u32 = 0x43544D53; // "CTMS"
    const VERSION: u32 = 1;

    /// Save sync state to file. Preserves sync accumulators + dopamine EMA.
    pub fn save(self: *const CTMState, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        // Header: magic(4) + version(4) + n_layers(4) + n_synch(4) + initialized(1) + ema(4) = 21 bytes
        var hdr: [21]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], MAGIC, .little);
        std.mem.writeInt(u32, hdr[4..8], VERSION, .little);
        std.mem.writeInt(u32, hdr[8..12], @intCast(self.n_layers), .little);
        std.mem.writeInt(u32, hdr[12..16], @intCast(self.n_synch), .little);
        hdr[16] = if (self.initialized) 1 else 0;
        const ema_val: f32 = self.surprise_ema orelse std.math.nan(f32);
        @memcpy(hdr[17..21], std.mem.asBytes(&ema_val));
        try file.writeAll(&hdr);

        // Sync arrays
        const total = self.n_layers * self.n_synch;
        try file.writeAll(std.mem.sliceAsBytes(self.alpha_out[0..total]));
        try file.writeAll(std.mem.sliceAsBytes(self.beta_out[0..total]));
        try file.writeAll(std.mem.sliceAsBytes(self.alpha_act[0..total]));
        try file.writeAll(std.mem.sliceAsBytes(self.beta_act[0..total]));
    }

    /// Load sync state from file. Returns false if file doesn't exist or is incompatible.
    pub fn load(self: *CTMState, path: []const u8) bool {
        const file = std.fs.cwd().openFile(path, .{}) catch return false;
        defer file.close();

        // Read header
        var hdr: [21]u8 = undefined;
        _ = file.readAll(&hdr) catch return false;

        const magic = std.mem.readInt(u32, hdr[0..4], .little);
        const version = std.mem.readInt(u32, hdr[4..8], .little);
        const n_layers = std.mem.readInt(u32, hdr[8..12], .little);
        const n_synch = std.mem.readInt(u32, hdr[12..16], .little);
        const init_byte = hdr[16];

        if (magic != MAGIC or version != VERSION) return false;
        if (n_layers != self.n_layers or n_synch != self.n_synch) return false;

        // Surprise EMA
        var ema_val: f32 = undefined;
        @memcpy(std.mem.asBytes(&ema_val), hdr[17..21]);
        self.surprise_ema = if (std.math.isNan(ema_val)) null else ema_val;
        self.initialized = init_byte != 0;

        // Sync arrays
        const total = self.n_layers * self.n_synch;
        _ = file.readAll(std.mem.sliceAsBytes(self.alpha_out[0..total])) catch return false;
        _ = file.readAll(std.mem.sliceAsBytes(self.beta_out[0..total])) catch return false;
        _ = file.readAll(std.mem.sliceAsBytes(self.alpha_act[0..total])) catch return false;
        _ = file.readAll(std.mem.sliceAsBytes(self.beta_act[0..total])) catch return false;

        return true;
    }
};

// ============================================================
// CTMBlock: weights for one CTM layer
// ============================================================

pub const CTMBlock = struct {
    config: CTMConfig,

    // Cross-attention projections
    attn_q_proj_w: []const f32, // (D, n_synch) — maps sync to query
    attn_k_proj_w: []const f32, // (D, D)
    attn_v_proj_w: []const f32, // (D, D)

    // U-NET synapse
    synapses: SynapseUNET,

    // NLMs (SuperLinear)
    nlm1: SuperLinear, // (M, 2*hidden, D)
    nlm2: SuperLinear, // (hidden, 2, D)

    // Learnable initial states
    start_state: []const f32, // (D)
    start_trace: []const f32, // (D, M)

    // Sync neuron index buffers
    synch_out_left: []const u32, // (n_synch) indices into [0..D)
    synch_out_right: []const u32,
    synch_act_left: []const u32,
    synch_act_right: []const u32,

    // Decay parameters
    decay_out: []const f32, // (n_synch)
    decay_act: []const f32, // (n_synch)

    // Tick embeddings
    tick_embed: []const f32, // (K, D)

    // Output projection
    c_proj_w: []const f32, // (D, n_synch)

    // Mutable copies of plastic weights (null until makePlastic is called)
    mutable_c_proj_w: ?[]f32 = null,
    mutable_last_up_w: ?[]f32 = null,

    // Homeostasis base norms (set by makePlastic)
    c_proj_base_norm: f32 = 0,
    up_base_norm: f32 = 0,

    /// Run CTM forward pass for one token.
    /// Input: x (D-dim vector from attention output)
    /// Output: written to out (D-dim)
    /// ctm_state: persistent sync accumulators (modified in place)
    pub fn forward(
        self: *const CTMBlock,
        x: []const f32,
        out: []f32,
        ctm_state: *CTMState,
        layer_idx: usize,
        scratch: []f32,
    ) void {
        const cfg = self.config;
        const D = cfg.dim;
        const K = cfg.iterations;
        const M = cfg.memory_length;
        const n_synch = cfg.n_synch;
        const hidden = cfg.memory_hidden;

        // Get persistent sync state for this layer
        var sync = ctm_state.layerSlice(layer_idx, n_synch);

        // Initialize state and trace from learned start params
        // (inference mode: always reset state/trace, carry only sync)
        const state = scratch[0..D];
        const trace = scratch[D..][0 .. D * M];
        @memcpy(state, self.start_state);
        @memcpy(trace, self.start_trace);

        // If not initialized, seed sync from start_state
        if (!ctm_state.initialized) {
            for (0..n_synch) |s| {
                const li = self.synch_out_left[s];
                const ri = self.synch_out_right[s];
                const pp = state[li] * state[ri];
                sync.alpha_out[s] = pp;
                sync.beta_out[s] = 1.0;
            }
            for (0..n_synch) |s| {
                const li = self.synch_act_left[s];
                const ri = self.synch_act_right[s];
                const pp = state[li] * state[ri];
                sync.alpha_act[s] = pp;
                sync.beta_act[s] = 1.0;
            }
            ctm_state.initialized = true;
        }

        // Precompute decay factors: r = exp(-clamp(decay, 0, 15))
        const r_out = scratch[D + D * M ..][0..n_synch];
        const r_act = scratch[D + D * M + n_synch ..][0..n_synch];
        for (0..n_synch) |s| {
            r_out[s] = std.math.exp(-std.math.clamp(self.decay_out[s], 0, 15));
            r_act[s] = std.math.exp(-std.math.clamp(self.decay_act[s], 0, 15));
        }

        // Scratch regions for intermediate computations
        const scratch_offset = D + D * M + 2 * n_synch;
        const synch_readout = scratch[scratch_offset..][0..n_synch];
        const attn_q = scratch[scratch_offset + n_synch ..][0..D];
        const attn_q_norm = scratch[scratch_offset + n_synch + D ..][0..D];
        const attn_k = scratch[scratch_offset + n_synch + 2 * D ..][0..D];
        const attn_k_norm = scratch[scratch_offset + n_synch + 3 * D ..][0..D];
        const attn_v = scratch[scratch_offset + n_synch + 4 * D ..][0..D];
        const obs = scratch[scratch_offset + n_synch + 5 * D ..][0..D];
        const synapse_in = scratch[scratch_offset + n_synch + 6 * D ..][0 .. 2 * D];
        const synapse_out = scratch[scratch_offset + n_synch + 8 * D ..][0..D];
        const nlm1_out_buf = scratch[scratch_offset + n_synch + 9 * D ..][0 .. D * 2 * hidden];
        const nlm2_out_buf = scratch[scratch_offset + n_synch + 9 * D + D * 2 * hidden ..][0 .. D * 2];
        // SynapseUNET needs its own scratch
        const unet_scratch_off = scratch_offset + n_synch + 9 * D + D * 2 * hidden + D * 2;
        const unet_scratch = scratch[unet_scratch_off..];

        // Precompute keys and values from input (constant across ticks)
        linearForward(attn_k, x, self.attn_k_proj_w, D, D);
        qkNorm(attn_k_norm, attn_k, D);
        linearForward(attn_v, x, self.attn_v_proj_w, D, D);

        // K thinking iterations
        for (0..K) |k| {
            // 1. Compute S_action readout
            for (0..n_synch) |s| {
                const denom = std.math.sqrt(sync.beta_act[s]);
                synch_readout[s] = if (denom > 1e-8) sync.alpha_act[s] / denom else 0;
            }

            // 2. Cross-attention: query from sync, key/value from input
            linearForward(attn_q, synch_readout, self.attn_q_proj_w, D, n_synch);
            qkNorm(attn_q_norm, attn_q, D);

            // Simplified single-head attention (dot product + scale)
            // For single-token inference: attention is just dot(q, k) * v
            const head_size = D / cfg.n_attn_heads;
            const scale = std.math.sqrt(@as(f32, @floatFromInt(head_size)));
            for (0..D) |i| {
                const score = attn_q_norm[i] * attn_k_norm[i] / scale;
                obs[i] = score * attn_v[i];
            }

            if (debug_ctm) {
                var obs_nan: usize = 0;
                var obs_max: f32 = 0;
                for (obs[0..D]) |v| {
                    if (std.math.isNan(v)) obs_nan += 1;
                    const av = @abs(v);
                    if (av > obs_max and !std.math.isNan(av)) obs_max = av;
                }
                if (obs_nan > 0 or k < 2 or k == K - 1) {
                    std.debug.print("  [CTM k={d}] obs: nan={d} max={e}\n", .{ k, obs_nan, obs_max });
                }
            }

            // 3. U-NET synapse: concat(obs, state + tick_embed) -> residual
            const tick_emb = self.tick_embed[k * D ..][0..D];
            for (0..D) |i| {
                synapse_in[i] = obs[i];
                synapse_in[D + i] = state[i] + tick_emb[i];
            }
            self.synapses.forward(synapse_in, synapse_out, unet_scratch);

            if (debug_ctm) {
                var syn_nan: usize = 0;
                var syn_max: f32 = 0;
                for (synapse_out[0..D]) |v| {
                    if (std.math.isNan(v)) syn_nan += 1;
                    const av = @abs(v);
                    if (av > syn_max and !std.math.isNan(av)) syn_max = av;
                }
                if (syn_nan > 0 or k < 2 or k == K - 1) {
                    std.debug.print("  [CTM k={d}] syn_out: nan={d} max={e}\n", .{ k, syn_nan, syn_max });
                }
            }

            // Residual: state = state + synapse_out
            for (0..D) |i| state[i] += synapse_out[i];

            // 4. Update trace: drop oldest, append new state
            // trace is (D, M) row-major: trace[d*M..d*M+M]
            for (0..D) |d| {
                const row = trace[d * M ..][0..M];
                // Shift left by 1
                for (0..M - 1) |m| row[m] = row[m + 1];
                row[M - 1] = state[d];
            }

            // 5. NLM1: trace (D, M) -> GLU -> (D, hidden)
            self.nlm1.forward(trace, nlm1_out_buf);
            glu(nlm1_out_buf, D, 2 * hidden);

            // (nlm1 debug removed for brevity)

            // 6. NLM2: (D, hidden) -> GLU -> (D, 1) -> squeeze -> (D)
            self.nlm2.forward(nlm1_out_buf[0 .. D * hidden], nlm2_out_buf);
            glu(nlm2_out_buf, D, 2);
            for (0..D) |d| state[d] = nlm2_out_buf[d * 2];

            if (debug_ctm) {
                var state_nan: usize = 0;
                var state_max: f32 = 0;
                for (state[0..D]) |v| {
                    if (std.math.isNan(v)) { state_nan += 1; }
                    const av = @abs(v);
                    if (av > state_max and !std.math.isNan(av)) state_max = av;
                }
                if (state_nan > 0 or k < 2 or k == K - 1) {
                    std.debug.print("  [CTM k={d}] state: nan={d}/{d} max={e}\n", .{ k, state_nan, D, state_max });
                }
            }

            // 7. Update sync accumulators (dopamine-gated)
            // dopamine scales contribution: high surprise → normal accumulation,
            // boring/predictable → dampened accumulation. Clamped to [0.5, 1.0].
            const dopamine = ctm_state.dopamine;
            for (0..n_synch) |s| {
                const li_out = self.synch_out_left[s];
                const ri_out = self.synch_out_right[s];
                const pp_out = state[li_out] * state[ri_out] * dopamine;
                sync.alpha_out[s] = r_out[s] * sync.alpha_out[s] + pp_out;
                sync.beta_out[s] = r_out[s] * sync.beta_out[s] + dopamine;

                const li_act = self.synch_act_left[s];
                const ri_act = self.synch_act_right[s];
                const pp_act = state[li_act] * state[ri_act] * dopamine;
                sync.alpha_act[s] = r_act[s] * sync.alpha_act[s] + pp_act;
                sync.beta_act[s] = r_act[s] * sync.beta_act[s] + dopamine;
            }
        }

        // Capture last state for compact_memory (if buffer provided)
        if (ctm_state.last_state) |ls| {
            if (ls.len >= D) @memcpy(ls[0..D], state);
        }

        // Final readout: S_out sync -> c_proj -> output
        for (0..n_synch) |s| {
            const denom = std.math.sqrt(sync.beta_out[s]);
            synch_readout[s] = if (denom > 1e-8) sync.alpha_out[s] / denom else 0;
        }
        linearForward(out, synch_readout, self.c_proj_w, D, n_synch);

        // Debug: check for NaN/inf in output
        if (debug_ctm) {
            var nan_count: usize = 0;
            var inf_count: usize = 0;
            var max_abs: f32 = 0;
            for (out[0..D]) |v| {
                if (std.math.isNan(v)) nan_count += 1;
                if (std.math.isInf(v)) inf_count += 1;
                const abs_v = @abs(v);
                if (abs_v > max_abs and !std.math.isNan(abs_v) and !std.math.isInf(abs_v)) max_abs = abs_v;
            }
            // Also check state
            var state_nan: usize = 0;
            for (state[0..D]) |v| if (std.math.isNan(v)) { state_nan += 1; };
            // Check synch readout
            var sync_nan: usize = 0;
            var sync_max: f32 = 0;
            for (synch_readout[0..n_synch]) |v| {
                if (std.math.isNan(v)) sync_nan += 1;
                const abs_v = @abs(v);
                if (abs_v > sync_max and !std.math.isNan(abs_v)) sync_max = abs_v;
            }
            if (nan_count > 0 or inf_count > 0 or max_abs > 1e6) {
                std.debug.print("  [CTM] out: nan={d} inf={d} max={e} | state_nan={d} | sync: nan={d} max={e}\n", .{
                    nan_count, inf_count, max_abs, state_nan, sync_nan, sync_max,
                });
            }
        }
    }

    pub var debug_ctm: bool = false;

    /// Calculate scratch buffer size needed for forward pass.
    pub fn scratchSize(cfg: CTMConfig) usize {
        const D = cfg.dim;
        const M = cfg.memory_length;
        const n_synch = cfg.n_synch;
        const hidden = cfg.memory_hidden;
        const base = D + D * M + 2 * n_synch + n_synch + 9 * D + D * 2 * hidden + D * 2;
        // U-NET scratch: skip storage + 2 work buffers (with room for concat)
        // concat_max could be up to 3*D in worst case; use 4*D as generous upper bound
        const unet_scratch = 2 * D * cfg.synapse_depth + 8 * D;
        return base + unet_scratch;
    }

    // ============================================================
    // Dream: convergence diagnostics forward pass
    // ============================================================

    /// Run forward pass and return per-tick state deltas (L2 norm of state change).
    /// Useful for adaptive K: ticks where delta → 0 indicate convergence.
    /// Does NOT modify sync accumulators (read-only diagnostic).
    pub fn dream(
        self: *const CTMBlock,
        x: []const f32,
        ctm_state: *CTMState,
        layer_idx: usize,
        scratch: []f32,
        deltas: []f32, // output: K floats, one per tick
    ) void {
        const cfg = self.config;
        const D = cfg.dim;
        const K = cfg.iterations;
        const M = cfg.memory_length;
        const n_synch = cfg.n_synch;
        const hidden = cfg.memory_hidden;

        // Read-only copy of sync (don't modify accumulators during dream)
        const sync = ctm_state.layerSlice(layer_idx, n_synch);

        // Same scratch layout as forward
        const state = scratch[0..D];
        const trace = scratch[D..][0 .. D * M];
        @memcpy(state, self.start_state);
        @memcpy(trace, self.start_trace);

        const r_out = scratch[D + D * M ..][0..n_synch];
        const r_act = scratch[D + D * M + n_synch ..][0..n_synch];
        for (0..n_synch) |s| {
            r_out[s] = std.math.exp(-std.math.clamp(self.decay_out[s], 0, 15));
            r_act[s] = std.math.exp(-std.math.clamp(self.decay_act[s], 0, 15));
        }

        const scratch_offset = D + D * M + 2 * n_synch;
        const synch_readout = scratch[scratch_offset..][0..n_synch];
        const attn_q = scratch[scratch_offset + n_synch ..][0..D];
        const attn_q_norm = scratch[scratch_offset + n_synch + D ..][0..D];
        const attn_k = scratch[scratch_offset + n_synch + 2 * D ..][0..D];
        const attn_k_norm = scratch[scratch_offset + n_synch + 3 * D ..][0..D];
        const attn_v = scratch[scratch_offset + n_synch + 4 * D ..][0..D];
        const obs = scratch[scratch_offset + n_synch + 5 * D ..][0..D];
        const synapse_in = scratch[scratch_offset + n_synch + 6 * D ..][0 .. 2 * D];
        const synapse_out = scratch[scratch_offset + n_synch + 8 * D ..][0..D];
        const nlm1_out_buf = scratch[scratch_offset + n_synch + 9 * D ..][0 .. D * 2 * hidden];
        const nlm2_out_buf = scratch[scratch_offset + n_synch + 9 * D + D * 2 * hidden ..][0 .. D * 2];
        const unet_scratch_off = scratch_offset + n_synch + 9 * D + D * 2 * hidden + D * 2;
        const unet_scratch = scratch[unet_scratch_off..];

        // Use temporary sync copies (don't mutate real sync during dream)
        // We just read the current sync values for attention queries
        linearForward(attn_k, x, self.attn_k_proj_w, D, D);
        qkNorm(attn_k_norm, attn_k, D);
        linearForward(attn_v, x, self.attn_v_proj_w, D, D);

        // Track previous state for delta computation
        // We'll use a region after unet_scratch for prev_state
        const prev_state = scratch[unet_scratch_off + 2 * D * cfg.synapse_depth + 8 * D ..][0..D];

        for (0..K) |k| {
            // Save previous state
            @memcpy(prev_state, state);

            // 1. S_action readout
            for (0..n_synch) |s| {
                const denom = std.math.sqrt(sync.beta_act[s]);
                synch_readout[s] = if (denom > 1e-8) sync.alpha_act[s] / denom else 0;
            }

            // 2. Cross-attention
            linearForward(attn_q, synch_readout, self.attn_q_proj_w, D, n_synch);
            qkNorm(attn_q_norm, attn_q, D);

            const head_size = D / cfg.n_attn_heads;
            const scale = std.math.sqrt(@as(f32, @floatFromInt(head_size)));
            for (0..D) |i| {
                const score = attn_q_norm[i] * attn_k_norm[i] / scale;
                obs[i] = score * attn_v[i];
            }

            // 3. Synapse
            const tick_emb = self.tick_embed[k * D ..][0..D];
            for (0..D) |i| {
                synapse_in[i] = obs[i];
                synapse_in[D + i] = state[i] + tick_emb[i];
            }
            self.synapses.forward(synapse_in, synapse_out, unet_scratch);
            for (0..D) |i| state[i] += synapse_out[i];

            // 4-6. Trace + NLM (same as forward)
            for (0..D) |d| {
                const row = trace[d * M ..][0..M];
                for (0..M - 1) |m| row[m] = row[m + 1];
                row[M - 1] = state[d];
            }
            self.nlm1.forward(trace, nlm1_out_buf);
            glu(nlm1_out_buf, D, 2 * hidden);
            self.nlm2.forward(nlm1_out_buf[0 .. D * hidden], nlm2_out_buf);
            glu(nlm2_out_buf, D, 2);
            for (0..D) |d| state[d] = nlm2_out_buf[d * 2];

            // Compute delta: L2 norm of state change
            var delta_sq: f32 = 0;
            for (0..D) |i| {
                const diff = state[i] - prev_state[i];
                delta_sq += diff * diff;
            }
            deltas[k] = std.math.sqrt(delta_sq);
        }
    }

    // ============================================================
    // Compact Memory: gradient-free Hebbian weight updates
    // ============================================================
    // Writes accumulated sync patterns into permanent synapse weights.
    // Brain analog: hippocampal → cortical memory transfer.
    //
    // Three mechanisms:
    // 1. Sync-driven Hebbian update: accumulated S_out encodes pairwise co-activation
    // 2. Novelty gating: only update where sync diverged from baseline
    // 3. Homeostasis: clamp weight norms to prevent unbounded drift

    /// Compact CTMState sync patterns into permanent c_proj weights.
    /// Requires mutable_c_proj_w to be set (call makePlastic first).
    /// Returns mean novelty score (0 = nothing learned, >0 = patterns consolidated).
    pub fn compactMemory(
        self: *CTMBlock,
        ctm_state: *const CTMState,
        layer_idx: usize,
        lr: f32,
    ) f32 {
        const cfg = self.config;
        const D = cfg.dim;
        const K = cfg.iterations;
        const n_synch = cfg.n_synch;

        const c_proj = self.mutable_c_proj_w orelse return 0;

        const sync = @constCast(ctm_state).layerSlice(layer_idx, n_synch);

        // 1. Compute accumulated sync signal
        // synch_accumulated[s] = alpha_out[s] / sqrt(beta_out[s])
        var synch_accum: [1024]f32 = undefined; // max n_synch
        if (n_synch > 1024) return 0;
        for (0..n_synch) |s| {
            const denom = std.math.sqrt(sync.beta_out[s]);
            synch_accum[s] = if (denom > 1e-8) sync.alpha_out[s] / denom else 0;
        }

        // 2. Compute baseline sync from start_state
        // For K iterations with constant pp and decay r:
        //   geo_sum = (1 - r^K) / (1 - r + eps)
        //   beta_baseline = r^K + geo_sum
        //   synch_baseline = pp * sqrt(beta_baseline)
        var synch_baseline: [1024]f32 = undefined;
        for (0..n_synch) |s| {
            const r = std.math.exp(-std.math.clamp(self.decay_out[s], 0, 15));
            const pp = self.start_state[self.synch_out_left[s]] *
                self.start_state[self.synch_out_right[s]];
            const r_k = std.math.pow(f32, r, @floatFromInt(K));
            const geo_sum = (1.0 - r_k) / (1.0 - r + 1e-8);
            const beta_base = r_k + geo_sum;
            synch_baseline[s] = pp * std.math.sqrt(beta_base);
        }

        // 3. Novelty: how much did sync diverge from baseline?
        var novelty: [1024]f32 = undefined;
        var novelty_sum: f32 = 0;
        for (0..n_synch) |s| {
            novelty[s] = @abs(synch_accum[s] - synch_baseline[s]);
            novelty_sum += novelty[s];
        }
        const mean_novelty = novelty_sum / @as(f32, @floatFromInt(n_synch));

        // Find median novelty for gating threshold
        // Use approximate: mean as threshold (simpler than full sort, similar effect)
        const novelty_threshold = mean_novelty;

        // 4. Compute gated sync delta
        var gated_delta: [1024]f32 = undefined;
        for (0..n_synch) |s| {
            const delta = synch_accum[s] - synch_baseline[s];
            gated_delta[s] = if (novelty[s] > novelty_threshold) delta else 0;
        }

        // 5. Compute state scale (use last_state if available, else start_state)
        var state_scale: f32 = 0;
        const ref_state = if (ctm_state.last_state) |ls| ls[0..D] else self.start_state;
        for (ref_state) |v| state_scale += @abs(v);
        state_scale /= @as(f32, @floatFromInt(D));

        // Capture base norm before update (for homeostasis)
        var base_norm: f32 = 0;
        for (c_proj[0 .. D * n_synch]) |v| base_norm += v * v;
        base_norm = std.math.sqrt(base_norm);

        // 6. Apply Hebbian update to c_proj: c_proj[d, s] += lr * gated_delta[s] * state_scale
        for (0..D) |d| {
            for (0..n_synch) |s| {
                c_proj[d * n_synch + s] += lr * gated_delta[s] * state_scale;
            }
        }

        // 7. Homeostasis: clamp weight norm to at most 1% growth
        var current_norm: f32 = 0;
        for (c_proj[0 .. D * n_synch]) |v| current_norm += v * v;
        current_norm = std.math.sqrt(current_norm);

        const max_norm = base_norm * 1.01;
        if (current_norm > max_norm) {
            const scale = max_norm / current_norm;
            for (c_proj[0 .. D * n_synch]) |*v| v.* *= scale;
        }

        // Update the const pointer to point to our mutable buffer
        self.c_proj_w = c_proj;

        return mean_novelty;
    }

    /// Make all plastic weights mutable by copying to owned buffers.
    /// Must be called before compactMemory/consolidate. Allocator should be long-lived.
    /// Makes c_proj and last synapse up-layer weights mutable.
    pub fn makePlastic(self: *CTMBlock, alloc: Allocator) !void {
        const D = self.config.dim;
        const n_synch = self.config.n_synch;

        // c_proj: (D, n_synch)
        const c_size = D * n_synch;
        const c_buf = try alloc.alloc(f32, c_size);
        @memcpy(c_buf, self.c_proj_w[0..c_size]);
        self.mutable_c_proj_w = c_buf;
        self.c_proj_w = c_buf;

        // Last synapse up-layer: the final projection back to D-dim
        if (self.synapses.half_k > 0) {
            const last = self.synapses.half_k - 1;
            const up_w = self.synapses.up_weights[last];
            const up_size = self.synapses.up_in_dims[last] * self.synapses.up_out_dims[last];
            const up_buf = try alloc.alloc(f32, up_size);
            @memcpy(up_buf, up_w[0..up_size]);
            self.mutable_last_up_w = up_buf;
            // Update the slice in synapses
            @constCast(self.synapses.up_weights)[last] = up_buf;
        }

        // Initialize plasticity base norms
        self.c_proj_base_norm = vecNorm(c_buf[0..c_size]);
        if (self.mutable_last_up_w) |uw| {
            const last = self.synapses.half_k - 1;
            const up_size = self.synapses.up_in_dims[last] * self.synapses.up_out_dims[last];
            self.up_base_norm = vecNorm(uw[0..up_size]);
        }
    }

    /// Compact CTMState sync into c_proj AND last synapse up-layer.
    /// Full Hebbian plasticity with novelty gating and homeostasis.
    /// Returns PlasticityStats.
    pub fn compactMemoryFull(
        self: *CTMBlock,
        ctm_state: *const CTMState,
        layer_idx: usize,
        lr: f32,
    ) PlasticityStats {
        var stats = PlasticityStats{};
        const novelty = self.compactMemory(ctm_state, layer_idx, lr);
        stats.mean_novelty = novelty;
        stats.c_proj_updated = self.mutable_c_proj_w != null;

        // Also update last synapse up-layer using state delta
        const up_w = self.mutable_last_up_w orelse return stats;
        const cfg = self.config;
        const D = cfg.dim;
        const n_synch = cfg.n_synch;

        // State delta from baseline
        const ref_state = if (ctm_state.last_state) |ls| ls[0..D] else self.start_state;
        var state_delta: [2048]f32 = undefined;
        if (D > 2048) return stats;
        for (0..D) |i| {
            state_delta[i] = ref_state[i] - self.start_state[i];
        }
        var state_delta_norm: f32 = 0;
        for (state_delta[0..D]) |v| state_delta_norm += v * v;
        stats.state_delta_norm = std.math.sqrt(state_delta_norm);

        // Rank-1 update: Δw = lr * state_delta[:D_out] ⊗ mean(w, dim=0)
        const last = self.synapses.half_k - 1;
        const D_out = self.synapses.up_out_dims[last];
        const D_in = self.synapses.up_in_dims[last];

        // Compute input approximation: mean of each column
        var input_approx: [2048]f32 = undefined;
        if (D_in > 2048) return stats;
        for (0..D_in) |j| {
            var col_sum: f32 = 0;
            for (0..D_out) |i| {
                col_sum += up_w[i * D_in + j];
            }
            input_approx[j] = col_sum / @as(f32, @floatFromInt(D_out));
        }

        // Apply rank-1 update
        const base_norm = self.up_base_norm;
        for (0..@min(D_out, D)) |i| {
            for (0..D_in) |j| {
                up_w[i * D_in + j] += lr * state_delta[i] * input_approx[j];
            }
        }

        // Homeostasis on up layer
        const up_size = D_out * D_in;
        var current_norm = vecNorm(up_w[0..up_size]);
        const max_norm = base_norm * 1.01;
        if (current_norm > max_norm) {
            const scale = max_norm / current_norm;
            for (up_w[0..up_size]) |*v| v.* *= scale;
            current_norm = max_norm;
        }
        self.up_base_norm = current_norm;
        stats.synapse_updated = true;

        // Compute gated fraction for stats
        var gated_count: f32 = 0;
        for (0..n_synch) |s| {
            const r = std.math.exp(-std.math.clamp(self.decay_out[s], 0, 15));
            const pp = self.start_state[self.synch_out_left[s]] *
                self.start_state[self.synch_out_right[s]];
            const r_k = std.math.pow(f32, r, @floatFromInt(cfg.iterations));
            const geo_sum = (1.0 - r_k) / (1.0 - r + 1e-8);
            const beta_base = r_k + geo_sum;
            const baseline = pp * std.math.sqrt(beta_base);

            const sync = @constCast(ctm_state).layerSlice(layer_idx, n_synch);
            const denom = std.math.sqrt(sync.beta_out[s]);
            const accum = if (denom > 1e-8) sync.alpha_out[s] / denom else 0;
            if (@abs(accum - baseline) > novelty) gated_count += 1;
        }
        stats.gated_fraction = gated_count / @as(f32, @floatFromInt(n_synch));

        return stats;
    }

    /// Save all plastic weights to an overlay file.
    /// Format: [magic(4)][version(4)][c_proj_size(4)][c_proj_data][up_size(4)][up_data]
    pub fn savePlasticWeights(self: *const CTMBlock, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        var hdr: [12]u8 = undefined;
        const PLASTIC_MAGIC: u32 = 0x50435457; // "PCTW"
        std.mem.writeInt(u32, hdr[0..4], PLASTIC_MAGIC, .little);
        std.mem.writeInt(u32, hdr[4..8], 1, .little); // version

        // c_proj
        if (self.mutable_c_proj_w) |cp| {
            const D = self.config.dim;
            const n_synch = self.config.n_synch;
            const size = D * n_synch;
            std.mem.writeInt(u32, hdr[8..12], @intCast(size), .little);
            try file.writeAll(&hdr);
            try file.writeAll(std.mem.sliceAsBytes(cp[0..size]));
        } else {
            std.mem.writeInt(u32, hdr[8..12], 0, .little);
            try file.writeAll(&hdr);
        }

        // last synapse up
        var sz_buf: [4]u8 = undefined;
        if (self.mutable_last_up_w) |uw| {
            const last = self.synapses.half_k - 1;
            const size = self.synapses.up_in_dims[last] * self.synapses.up_out_dims[last];
            std.mem.writeInt(u32, &sz_buf, @intCast(size), .little);
            try file.writeAll(&sz_buf);
            try file.writeAll(std.mem.sliceAsBytes(uw[0..size]));
        } else {
            std.mem.writeInt(u32, &sz_buf, 0, .little);
            try file.writeAll(&sz_buf);
        }
    }

    /// Load plastic weight overlay from file. Returns true if loaded successfully.
    pub fn loadPlasticWeights(self: *CTMBlock, path: []const u8) bool {
        const file = std.fs.cwd().openFile(path, .{}) catch return false;
        defer file.close();

        var hdr: [12]u8 = undefined;
        _ = file.readAll(&hdr) catch return false;

        const magic = std.mem.readInt(u32, hdr[0..4], .little);
        const version = std.mem.readInt(u32, hdr[4..8], .little);
        if (magic != 0x50435457 or version != 1) return false;

        // c_proj
        const c_size = std.mem.readInt(u32, hdr[8..12], .little);
        if (c_size > 0) {
            if (self.mutable_c_proj_w) |cp| {
                if (cp.len == c_size) {
                    _ = file.readAll(std.mem.sliceAsBytes(cp)) catch return false;
                    self.c_proj_w = cp;
                    self.c_proj_base_norm = vecNorm(cp);
                } else return false;
            } else return false;
        }

        // last synapse up
        var sz_buf: [4]u8 = undefined;
        _ = file.readAll(&sz_buf) catch return false;
        const up_size = std.mem.readInt(u32, &sz_buf, .little);
        if (up_size > 0) {
            if (self.mutable_last_up_w) |uw| {
                if (uw.len == up_size) {
                    _ = file.readAll(std.mem.sliceAsBytes(uw)) catch return false;
                    const last = self.synapses.half_k - 1;
                    @constCast(self.synapses.up_weights)[last] = uw;
                    self.up_base_norm = vecNorm(uw);
                } else return false;
            } else return false;
        }

        return true;
    }

};

// ============================================================
// Plasticity Stats
// ============================================================

pub const PlasticityStats = struct {
    mean_novelty: f32 = 0,
    state_delta_norm: f32 = 0,
    gated_fraction: f32 = 0,
    c_proj_updated: bool = false,
    synapse_updated: bool = false,
};

// ============================================================
// Replay Buffer: ring buffer of recent token sequences
// ============================================================

pub const ReplayBuffer = struct {
    const MAX_ENTRIES = 64;
    const MAX_SEQ_LEN = 256;

    /// Each entry: a sequence of tokens + surprise score
    entries: [MAX_ENTRIES]ReplayEntry = [1]ReplayEntry{.{}} ** MAX_ENTRIES,
    count: usize = 0,
    write_pos: usize = 0,

    pub const ReplayEntry = struct {
        tokens: [MAX_SEQ_LEN]i64 = [_]i64{0} ** MAX_SEQ_LEN,
        len: usize = 0,
        surprise: f32 = 0, // mean surprise over the sequence
        timestamp: i64 = 0,
    };

    /// Add a sequence to the replay buffer. Only stores if surprise > threshold.
    pub fn push(self: *ReplayBuffer, tokens: []const i64, mean_surprise: f32, threshold: f32) void {
        if (mean_surprise < threshold) return;
        if (tokens.len == 0) return;

        const entry = &self.entries[self.write_pos % MAX_ENTRIES];
        const copy_len = @min(tokens.len, MAX_SEQ_LEN);
        @memcpy(entry.tokens[0..copy_len], tokens[0..copy_len]);
        entry.len = copy_len;
        entry.surprise = mean_surprise;
        entry.timestamp = std.time.timestamp();

        self.write_pos += 1;
        if (self.count < MAX_ENTRIES) self.count += 1;
    }

    /// Get entry at index (wrapping). Returns null if index >= count.
    pub fn get(self: *const ReplayBuffer, idx: usize) ?*const ReplayEntry {
        if (idx >= self.count) return null;
        // Read from oldest to newest
        const start = if (self.count == MAX_ENTRIES)
            self.write_pos % MAX_ENTRIES
        else
            0;
        const actual = (start + idx) % MAX_ENTRIES;
        return &self.entries[actual];
    }

    /// Prune entries with low surprise (decay over time).
    /// Entries older than max_age_seconds with surprise below decay_threshold are cleared.
    pub fn prune(self: *ReplayBuffer, max_age_seconds: i64, decay_threshold: f32) void {
        const now = std.time.timestamp();
        // Clear expired entries (old + low surprise) by zeroing their length.
        // The ring buffer naturally overwrites, but this frees them for inspection.
        for (0..MAX_ENTRIES) |i| {
            const entry = &self.entries[i];
            if (entry.len == 0) continue;
            const age = now - entry.timestamp;
            if (age > max_age_seconds and entry.surprise < decay_threshold) {
                entry.len = 0;
            }
        }
    }

    // Persistence
    const REPLAY_MAGIC: u32 = 0x52504C42; // "RPLB"

    pub fn save(self: *const ReplayBuffer, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        var hdr: [12]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], REPLAY_MAGIC, .little);
        std.mem.writeInt(u32, hdr[4..8], @intCast(self.count), .little);
        std.mem.writeInt(u32, hdr[8..12], @intCast(self.write_pos), .little);
        try file.writeAll(&hdr);

        for (0..MAX_ENTRIES) |i| {
            const entry = &self.entries[i];
            var entry_hdr: [16]u8 = undefined;
            std.mem.writeInt(u32, entry_hdr[0..4], @intCast(entry.len), .little);
            @memcpy(entry_hdr[4..8], std.mem.asBytes(&entry.surprise));
            @memcpy(entry_hdr[8..16], std.mem.asBytes(&entry.timestamp));
            try file.writeAll(&entry_hdr);
            try file.writeAll(std.mem.sliceAsBytes(entry.tokens[0..MAX_SEQ_LEN]));
        }
    }

    pub fn load(self: *ReplayBuffer, path: []const u8) bool {
        const file = std.fs.cwd().openFile(path, .{}) catch return false;
        defer file.close();

        var hdr: [12]u8 = undefined;
        _ = file.readAll(&hdr) catch return false;

        const magic = std.mem.readInt(u32, hdr[0..4], .little);
        if (magic != REPLAY_MAGIC) return false;
        self.count = @intCast(std.mem.readInt(u32, hdr[4..8], .little));
        self.write_pos = @intCast(std.mem.readInt(u32, hdr[8..12], .little));

        for (0..MAX_ENTRIES) |i| {
            const entry = &self.entries[i];
            var entry_hdr: [16]u8 = undefined;
            _ = file.readAll(&entry_hdr) catch return false;
            entry.len = @intCast(std.mem.readInt(u32, entry_hdr[0..4], .little));
            @memcpy(std.mem.asBytes(&entry.surprise), entry_hdr[4..8]);
            @memcpy(std.mem.asBytes(&entry.timestamp), entry_hdr[8..16]);
            _ = file.readAll(std.mem.sliceAsBytes(entry.tokens[0..MAX_SEQ_LEN])) catch return false;
        }
        return true;
    }
};

// ============================================================
// Helper: L2 norm of a float slice
// ============================================================

fn vecNorm(v: []const f32) f32 {
    var sum: f32 = 0;
    for (v) |x| sum += x * x;
    return std.math.sqrt(sum);
}
