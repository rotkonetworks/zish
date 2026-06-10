// Autonomic nervous system for CTM inference.
//
// Inspired by tower::Service and "Your Server as a Function" (Marius Eriksen, 2013).
//
// Core abstraction: Service(Req, Res) — a function from request to response
// with backpressure (ready()) and composable middleware (Layer).
//
// The autonomic controller routes between two pipelines:
//   INHALE (sympathetic): perceive → think → dopamine → replay
//   EXHALE (parasympathetic): consolidate → dream → persist
//
// The system self-regulates: inhale when input arrives, exhale when idle.
// Each stage is a composable Service. Middleware wraps inner services:
//   DopamineLayer: tracks surprise, modulates sync accumulation
//   HomeostasisLayer: clamps weight norms after plasticity
//   ReplayLayer: stores surprising experiences for consolidation
//
// Zero-cost composition via comptime generics — no vtables, no allocations.
// The pipeline compiles down to a single function call chain.

const std = @import("std");
const compat = @import("../compat.zig");
const ctm = @import("ctm.zig");
const model_mod = @import("model.zig");
const tokenizer_mod = @import("tokenizer.zig");

const Token = tokenizer_mod.Token;

// ============================================================
// Signal: the universal message type flowing through pipelines
// ============================================================
// "Your Server as a Function" insight: unify all inter-stage
// communication into a single sum type. Each stage pattern-matches
// on what it can process, passes through what it can't.

pub const Signal = union(enum) {
    /// Raw token input (from user or self-feeding)
    tokens: TokenSignal,
    /// Forward pass result (logits + state snapshot)
    activation: ActivationSignal,
    /// Sampled token with surprise measurement
    perception: PerceptionSignal,
    /// Plasticity update result
    plasticity: ctm.PlasticityStats,
    /// Dream convergence diagnostics
    dream: DreamSignal,
    /// Persistence checkpoint completed
    checkpoint: CheckpointSignal,
    /// Nothing to do / pass-through
    idle,
    /// Error
    err: []const u8,

    pub const TokenSignal = struct {
        tokens: []const Token,
        is_query: bool = false, // true = external input, false = self-feeding
    };

    pub const ActivationSignal = struct {
        logits: []f32,
        pos: usize,
        token: Token,
    };

    pub const PerceptionSignal = struct {
        token: Token,
        surprise: f32,
        logits: []f32,
    };

    pub const DreamSignal = struct {
        deltas: []f32, // per-tick convergence
        mean_delta: f32,
        converged_at: ?usize, // tick where delta < threshold, if any
    };

    pub const CheckpointSignal = struct {
        sync_saved: bool,
        weights_saved: bool,
        replay_saved: bool,
    };
};

// ============================================================
// Service: the core abstraction
// ============================================================
// Like tower::Service<Req>:
//   fn ready(&self) -> bool      (backpressure)
//   fn call(&self, req) -> res   (the function)
//
// In Zig: comptime generic, zero-cost. Each concrete service is a
// struct with call() and ready() methods. Composition happens at
// comptime — the compiler inlines everything.

pub fn Service(comptime Ctx: type) type {
    return struct {
        callFn: *const fn (*Ctx, Signal) Signal,
        readyFn: *const fn (*Ctx) bool,
        ctx: *Ctx,

        const Self = @This();

        pub fn call(self: Self, signal: Signal) Signal {
            return self.callFn(self.ctx, signal);
        }

        pub fn ready(self: Self) bool {
            return self.readyFn(self.ctx);
        }
    };
}

// ============================================================
// AutonomicContext: shared state for all services
// ============================================================
// This is the "world" that all services operate on.
// Owned by the autonomic controller, borrowed by services.

pub const AutonomicContext = struct {
    // Model state
    transformer: *const model_mod.Transformer,
    state: *model_mod.State,
    tok: *const tokenizer_mod.Tokenizer,

    // Position tracking
    pos: usize = 0,
    recent_ring: [64]Token = [_]Token{-1} ** 64,
    recent_count: usize = 0,
    current_tok: Token = 0,

    // CTM layer info
    ctm_layer_idx: usize = 0,

    // Plasticity
    replay_buf: ctm.ReplayBuffer = .{},
    exhale_counter: u64 = 0,

    // Persistence paths (null-terminated slices into path_storage)
    state_path: ?[]const u8 = null,
    weight_path: ?[]const u8 = null,
    replay_path: ?[]const u8 = null,
    path_storage: [1536]u8 = undefined,

    // Configuration
    config: AutonomicConfig = .{},

    // Stats
    total_inhales: u64 = 0,
    total_exhales: u64 = 0,
    total_compacts: u64 = 0,
    total_persists: u64 = 0,
    last_novelty: f32 = 0,
    last_surprise: f32 = 0,

    pub fn init(
        transformer: *const model_mod.Transformer,
        state: *model_mod.State,
        tok: *const tokenizer_mod.Tokenizer,
        model_path: []const u8,
        ctm_layer_idx: usize,
    ) AutonomicContext {
        var ctx = AutonomicContext{
            .transformer = transformer,
            .state = state,
            .tok = tok,
            .current_tok = tok.bos_id,
            .ctm_layer_idx = ctm_layer_idx,
        };

        // Derive persistence paths
        var off: usize = 0;
        ctx.state_path = derivePathInto(ctx.path_storage[off..], model_path, ".ctmstate", &off);
        ctx.weight_path = derivePathInto(ctx.path_storage[off..], model_path, ".plastic", &off);
        ctx.replay_path = derivePathInto(ctx.path_storage[off..], model_path, ".replay", &off);

        return ctx;
    }

    fn derivePathInto(buf: []u8, base: []const u8, suffix: []const u8, off: *usize) ?[]const u8 {
        // Find last '.'
        var dot: usize = base.len;
        var i: usize = base.len;
        while (i > 0) {
            i -= 1;
            if (base[i] == '.') { dot = i; break; }
            if (base[i] == '/') break;
        }
        const total = dot + suffix.len;
        if (total > buf.len) return null;
        @memcpy(buf[0..dot], base[0..dot]);
        @memcpy(buf[dot..total], suffix);
        off.* += total;
        return buf[0..total];
    }

    /// Get CTM block (mutable for plasticity operations)
    pub fn ctmBlock(self: *AutonomicContext) ?*ctm.CTMBlock {
        const blk = self.transformer.layers[self.ctm_layer_idx].ctm_block orelse return null;
        return @constCast(blk);
    }

    /// Get CTM state
    pub fn ctmState(self: *AutonomicContext) ?*ctm.CTMState {
        return self.state.ctm_state;
    }

    /// Track a token in the recent ring
    pub fn trackToken(self: *AutonomicContext, tok: Token) void {
        self.recent_ring[self.recent_count % 64] = tok;
        self.recent_count += 1;
    }
};

pub const AutonomicConfig = struct {
    /// How many idle steps between compactMemory calls
    exhale_interval: u64 = 100,
    /// How many idle steps between disk persistence
    save_interval: u64 = 1000,
    /// Minimum surprise to store in replay buffer
    surprise_threshold: f32 = 1.5,
    /// Learning rate for Hebbian weight updates
    plasticity_lr: f32 = 1e-5,
    /// Temperature for self-feeding thinking
    think_temperature: f32 = 0.7,
    /// Dream convergence threshold (delta below this = converged)
    dream_threshold: f32 = 0.01,
    /// Max age for replay entries before pruning (seconds)
    replay_max_age: i64 = 3600,
    /// Surprise below which old entries get pruned
    replay_decay_threshold: f32 = 1.0,
};

// ============================================================
// Concrete Services (the pipeline stages)
// ============================================================

/// PERCEIVE: run forward pass, compute surprise.
/// Input: tokens or idle → Output: perception (logits + surprise)
pub const Perceive = struct {
    pub fn call(ctx: *AutonomicContext, signal: Signal) Signal {
        switch (signal) {
            .tokens => |ts| {
                // Prefill all tokens
                var total_surprise: f32 = 0;
                var last_logits: []f32 = ctx.state.output;
                var last_tok: Token = ctx.current_tok;

                for (ts.tokens) |t| {
                    last_logits = ctx.transformer.forward(ctx.state, t, ctx.pos);
                    ctx.pos += 1;
                    ctx.trackToken(t);
                    last_tok = t;

                    const surprise = computeSurprise(last_logits, t);
                    total_surprise += surprise;
                }

                const n: f32 = @floatFromInt(@max(ts.tokens.len, 1));
                return .{ .perception = .{
                    .token = last_tok,
                    .surprise = total_surprise / n,
                    .logits = last_logits,
                } };
            },
            .idle => {
                // Self-feeding forward pass (thinking)
                const logits = ctx.transformer.forward(ctx.state, ctx.current_tok, ctx.pos);
                ctx.pos += 1;
                ctx.trackToken(ctx.current_tok);

                const surprise = computeSurprise(logits, ctx.current_tok);
                return .{ .perception = .{
                    .token = ctx.current_tok,
                    .surprise = surprise,
                    .logits = logits,
                } };
            },
            else => return signal, // pass through
        }
    }

    pub fn ready(_: *AutonomicContext) bool {
        return true; // always ready to perceive
    }
};

/// DOPAMINE: modulate sync accumulation based on surprise.
/// Input: perception → Output: perception (with dopamine set)
pub const Dopamine = struct {
    pub fn call(ctx: *AutonomicContext, signal: Signal) Signal {
        switch (signal) {
            .perception => |p| {
                if (ctx.ctmState()) |cs| {
                    cs.updateDopamine(p.surprise);
                    ctx.last_surprise = p.surprise;
                }
                return signal;
            },
            else => return signal,
        }
    }

    pub fn ready(_: *AutonomicContext) bool {
        return true;
    }
};

/// REPLAY: store surprising experiences in the replay buffer.
/// Input: perception → Output: perception (pass-through, side-effects buffer)
pub const Replay = struct {
    pub fn call(ctx: *AutonomicContext, signal: Signal) Signal {
        switch (signal) {
            .perception => |p| {
                // Store single-token surprise (the buffer aggregates)
                const tok_slice = @as(*const [1]Token, &p.token);
                ctx.replay_buf.push(tok_slice, p.surprise, ctx.config.surprise_threshold);
                return signal;
            },
            else => return signal,
        }
    }

    pub fn ready(_: *AutonomicContext) bool {
        return true;
    }
};

/// CONSOLIDATE: compact sync patterns into permanent weights.
/// Input: idle → Output: plasticity stats
pub const Consolidate = struct {
    pub fn call(ctx: *AutonomicContext, signal: Signal) Signal {
        switch (signal) {
            .idle => {
                const cs = ctx.ctmState() orelse return signal;
                const blk = ctx.ctmBlock() orelse return signal;

                ctx.exhale_counter += 1;

                if (ctx.exhale_counter % ctx.config.exhale_interval == 0) {
                    const stats = blk.compactMemoryFull(cs, ctx.ctm_layer_idx, ctx.config.plasticity_lr);
                    ctx.total_compacts += 1;
                    ctx.last_novelty = stats.mean_novelty;
                    return .{ .plasticity = stats };
                }

                return signal;
            },
            else => return signal,
        }
    }

    pub fn ready(ctx: *AutonomicContext) bool {
        return ctx.ctmState() != null;
    }
};

/// DREAM: run diagnostic forward pass to check convergence.
/// Input: plasticity → Output: dream diagnostics
pub const Dream = struct {
    pub fn call(ctx: *AutonomicContext, signal: Signal) Signal {
        switch (signal) {
            .plasticity => {
                const cs = ctx.ctmState() orelse return signal;
                const blk = ctx.ctmBlock() orelse return signal;

                const K = blk.config.iterations;
                var deltas: [128]f32 = undefined; // max K
                const k = @min(K, 128);

                // Dream on current activation state
                blk.dream(
                    ctx.state.work,
                    cs,
                    ctx.ctm_layer_idx,
                    ctx.state.ctm_scratch,
                    deltas[0..k],
                );

                // Find convergence point
                var converged_at: ?usize = null;
                var mean_delta: f32 = 0;
                for (0..k) |i| {
                    mean_delta += deltas[i];
                    if (converged_at == null and deltas[i] < ctx.config.dream_threshold) {
                        converged_at = i;
                    }
                }
                mean_delta /= @as(f32, @floatFromInt(k));

                return .{ .dream = .{
                    .deltas = deltas[0..k],
                    .mean_delta = mean_delta,
                    .converged_at = converged_at,
                } };
            },
            else => return signal,
        }
    }

    pub fn ready(ctx: *AutonomicContext) bool {
        return ctx.ctmState() != null;
    }
};

/// PERSIST: save state to disk periodically.
/// Input: any → Output: checkpoint signal (on interval) or pass-through
pub const Persist = struct {
    pub fn call(ctx: *AutonomicContext, signal: Signal) Signal {
        // Only persist on interval
        if (ctx.exhale_counter % ctx.config.save_interval != 0) return signal;

        var sync_ok = false;
        var weights_ok = false;
        var replay_ok = false;

        if (ctx.ctmState()) |cs| {
            if (ctx.state_path) |sp| {
                cs.save(sp) catch {};
                sync_ok = true;
            }
        }
        if (ctx.ctmBlock()) |blk| {
            if (ctx.weight_path) |wp| {
                blk.savePlasticWeights(wp) catch {};
                weights_ok = true;
            }
        }
        if (ctx.replay_path) |rp| {
            ctx.replay_buf.save(rp) catch {};
            replay_ok = true;
        }

        // Prune old memories
        ctx.replay_buf.prune(ctx.config.replay_max_age, ctx.config.replay_decay_threshold);

        ctx.total_persists += 1;

        return .{ .checkpoint = .{
            .sync_saved = sync_ok,
            .weights_saved = weights_ok,
            .replay_saved = replay_ok,
        } };
    }

    pub fn ready(_: *AutonomicContext) bool {
        return true;
    }
};

// ============================================================
// Pipeline: compose services into chains
// ============================================================
// "Your Server as a Function" key insight: services compose.
// A pipeline is itself a service. Pipelines compose into pipelines.
// Turtles all the way down.

/// Chain two service call functions together: a.andThen(b)
/// Output of first feeds into second.
pub fn chain(
    comptime first: fn (*AutonomicContext, Signal) Signal,
    comptime second: fn (*AutonomicContext, Signal) Signal,
) fn (*AutonomicContext, Signal) Signal {
    return struct {
        fn call(ctx: *AutonomicContext, signal: Signal) Signal {
            return second(ctx, first(ctx, signal));
        }
    }.call;
}

/// The INHALE pipeline: perceive → dopamine → replay
pub const inhale = chain(Perceive.call, chain(Dopamine.call, Replay.call));

/// The EXHALE pipeline: consolidate → dream → persist
pub const exhale = chain(Consolidate.call, chain(Dream.call, Persist.call));

// ============================================================
// Autonomic Controller: the breathing loop
// ============================================================
// Routes between inhale and exhale based on whether input is available.
// This IS the main loop. The controller is itself a Service.

pub const Controller = struct {
    ctx: AutonomicContext,

    pub fn init(
        transformer: *const model_mod.Transformer,
        state: *model_mod.State,
        tok: *const tokenizer_mod.Tokenizer,
        model_path: []const u8,
        ctm_layer_idx: usize,
    ) Controller {
        return .{
            .ctx = AutonomicContext.init(transformer, state, tok, model_path, ctm_layer_idx),
        };
    }

    /// Load persisted state from previous sessions.
    pub fn restore(self: *Controller) void {
        if (self.ctx.ctmState()) |cs| {
            if (self.ctx.state_path) |sp| _ = cs.load(sp);
        }
        if (self.ctx.ctmBlock()) |blk| {
            if (self.ctx.weight_path) |wp| _ = blk.loadPlasticWeights(wp);
        }
        if (self.ctx.replay_path) |rp| _ = self.ctx.replay_buf.load(rp);
    }

    /// Process external input (INHALE).
    /// Returns the signal that emerged from the pipeline.
    pub fn processInput(self: *Controller, tokens: []const Token) Signal {
        self.ctx.total_inhales += 1;
        self.ctx.exhale_counter = 0; // reset — we just did real work
        return inhale(&self.ctx, .{ .tokens = .{
            .tokens = tokens,
            .is_query = true,
        } });
    }

    /// One autonomous breathing cycle (EXHALE if idle).
    /// Call this in the main loop when no input is available.
    pub fn tick(self: *Controller) Signal {
        self.ctx.total_exhales += 1;

        // First: think (self-feeding forward pass)
        const perception = inhale(&self.ctx, .idle);

        // Sample next thinking token from perception
        switch (perception) {
            .perception => |p| {
                const lookback = @min(self.ctx.recent_count, 64);
                self.ctx.current_tok = sampleFromLogits(
                    p.logits,
                    self.ctx.config.think_temperature,
                    self.ctx.recent_ring[0..lookback],
                );
                if (self.ctx.current_tok == self.ctx.tok.eos_id) {
                    self.ctx.current_tok = self.ctx.tok.bos_id;
                }
            },
            else => {},
        }

        // Then: exhale (consolidate + dream + persist)
        return exhale(&self.ctx, .idle);
    }

    /// Get diagnostic summary.
    pub fn stats(self: *const Controller) Stats {
        return .{
            .total_inhales = self.ctx.total_inhales,
            .total_exhales = self.ctx.total_exhales,
            .total_compacts = self.ctx.total_compacts,
            .total_persists = self.ctx.total_persists,
            .last_novelty = self.ctx.last_novelty,
            .last_surprise = self.ctx.last_surprise,
            .replay_count = self.ctx.replay_buf.count,
            .pos = self.ctx.pos,
        };
    }

    pub const Stats = struct {
        total_inhales: u64,
        total_exhales: u64,
        total_compacts: u64,
        total_persists: u64,
        last_novelty: f32,
        last_surprise: f32,
        replay_count: usize,
        pos: usize,
    };
};

// ============================================================
// Helpers
// ============================================================

fn computeSurprise(logits: []f32, token: Token) f32 {
    if (token < 0 or @as(usize, @intCast(token)) >= logits.len) return 0;

    var max_logit: f32 = logits[0];
    for (logits[1..]) |l| {
        if (l > max_logit) max_logit = l;
    }

    var sum_exp: f32 = 0;
    for (logits) |l| {
        sum_exp += std.math.exp(l - max_logit);
    }
    if (sum_exp <= 0) return 0; // all -inf logits → no surprise

    const target_logit = logits[@intCast(token)];
    const log_prob = (target_logit - max_logit) - @log(sum_exp);
    return -log_prob;
}

/// Minimal token sampling (imported from root.zig pattern).
fn sampleFromLogits(logits: []f32, temperature: f32, recent: []const Token) Token {
    // Apply repetition penalty
    for (recent) |tok| {
        const idx: usize = @intCast(tok);
        if (idx >= logits.len) continue;
        if (logits[idx] > 0) logits[idx] /= 1.1 else logits[idx] *= 1.1;
    }

    if (temperature <= 0) {
        // Greedy
        var best: usize = 0;
        for (1..logits.len) |i| {
            if (logits[i] > logits[best]) best = i;
        }
        return @intCast(best);
    }

    // Temperature + top-k(40) + softmax + multinomial
    for (logits) |*l| l.* /= temperature;

    // Find top-40 threshold
    var top_vals: [40]f32 = [_]f32{-std.math.inf(f32)} ** 40;
    for (logits) |l| {
        if (l > top_vals[39]) {
            top_vals[39] = l;
            // Bubble up
            var j: usize = 39;
            while (j > 0 and top_vals[j] > top_vals[j - 1]) {
                const tmp = top_vals[j - 1];
                top_vals[j - 1] = top_vals[j];
                top_vals[j] = tmp;
                j -= 1;
            }
        }
    }
    const threshold = top_vals[39];

    // Softmax only over top-k
    var sum: f32 = 0;
    for (logits) |*l| {
        if (l.* < threshold) {
            l.* = 0;
        } else {
            l.* = std.math.exp(l.* - top_vals[0]);
            sum += l.*;
        }
    }
    if (sum > 0) for (logits) |*l| { l.* /= sum; };

    // Multinomial
    var rng = std.Random.DefaultPrng.init(@intCast(compat.nanoTimestamp()));
    const r = rng.random().float(f32);
    var cumulative: f32 = 0;
    for (0..logits.len) |i| {
        cumulative += logits[i];
        if (cumulative >= r) return @intCast(i);
    }
    return @intCast(logits.len - 1);
}
