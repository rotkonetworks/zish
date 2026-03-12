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
        @setFloatMode(.optimized);
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
        @setFloatMode(.optimized);
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
    // Per-layer persistent state
    alpha_out: []f32, // (n_synch)
    beta_out: []f32, // (n_synch)
    alpha_act: []f32, // (n_synch)
    beta_act: []f32, // (n_synch)
    initialized: bool = false,

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
        @setFloatMode(.optimized);
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

            // 3. U-NET synapse: concat(obs, state + tick_embed) -> residual
            const tick_emb = self.tick_embed[k * D ..][0..D];
            for (0..D) |i| {
                synapse_in[i] = obs[i];
                synapse_in[D + i] = state[i] + tick_emb[i];
            }
            self.synapses.forward(synapse_in, synapse_out, unet_scratch);

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

            // 6. NLM2: (D, hidden) -> GLU -> (D, 1) -> squeeze -> (D)
            self.nlm2.forward(nlm1_out_buf[0 .. D * hidden], nlm2_out_buf);
            glu(nlm2_out_buf, D, 2);
            for (0..D) |d| state[d] = nlm2_out_buf[d * 2];

            // 7. Update sync accumulators
            for (0..n_synch) |s| {
                const li_out = self.synch_out_left[s];
                const ri_out = self.synch_out_right[s];
                const pp_out = state[li_out] * state[ri_out];
                sync.alpha_out[s] = r_out[s] * sync.alpha_out[s] + pp_out;
                sync.beta_out[s] = r_out[s] * sync.beta_out[s] + 1.0;

                const li_act = self.synch_act_left[s];
                const ri_act = self.synch_act_right[s];
                const pp_act = state[li_act] * state[ri_act];
                sync.alpha_act[s] = r_act[s] * sync.alpha_act[s] + pp_act;
                sync.beta_act[s] = r_act[s] * sync.beta_act[s] + 1.0;
            }
        }

        // Final readout: S_out sync -> c_proj -> output
        for (0..n_synch) |s| {
            const denom = std.math.sqrt(sync.beta_out[s]);
            synch_readout[s] = if (denom > 1e-8) sync.alpha_out[s] / denom else 0;
        }
        linearForward(out, synch_readout, self.c_proj_w, D, n_synch);
    }

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
};
