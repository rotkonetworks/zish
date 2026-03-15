// Ghost text inference pipeline — composable SaaF stages.
//
// Same pattern as autonomic.zig: chain(f, g) composes signal-processing functions.
// Each stage is fn(*GhostCtx, GhostSignal) GhostSignal — pure transformation.
//
// Pipeline: stalenessGuard >> promptBuilder >> inference >> sanitizer
//
// The polling/debounce loop lives OUTSIDE the pipeline (in ghostInferThread).
// Stages are pure: no timing, no I/O except the inference stage.

const std = @import("std");
const inference = @import("inference/root.zig");

// ============================================================
// Signal: flows through the pipeline stages
// ============================================================

pub const GhostSignal = union(enum) {
    /// Raw editor input: command text + sequence number
    input: InputSignal,
    /// Assembled prompt with history context
    prompt: PromptSignal,
    /// Raw model output (may contain junk)
    raw_result: RawResult,
    /// Clean completion ready for display
    completion: Completion,
    /// Input changed during processing — discard
    stale,
    /// Nothing to produce
    idle,

    pub const InputSignal = struct {
        text: []const u8,
        seq: u32,
    };

    pub const PromptSignal = struct {
        buf: *[2048]u8,
        len: usize,
        seq: u32,
    };

    pub const RawResult = struct {
        data: []const u8,
        seq: u32,
    };

    pub const Completion = struct {
        buf: *[512]u8,
        len: u32,
        seq: u32,
    };
};

// ============================================================
// Context: shared mutable state for pipeline stages
// ============================================================

pub const GhostCtx = struct {
    /// Current seq from editor (atomic, read-only by pipeline)
    current_seq: *const std.atomic.Value(u32),
    /// Inference backend
    server: *inference.ForkServer,
    model_path: []const u8,
    /// Last history command (for context building)
    last_cmd: []const u8,
    /// Working buffers (reused across invocations)
    prompt_buf: [2048]u8,
    result_buf: [512]u8,
    /// Allocator for generate() results
    allocator: std.mem.Allocator,
};

// ============================================================
// Composition: chain(f, g) = g(f(x))
// ============================================================

pub fn chain(
    comptime first: fn (*GhostCtx, GhostSignal) GhostSignal,
    comptime second: fn (*GhostCtx, GhostSignal) GhostSignal,
) fn (*GhostCtx, GhostSignal) GhostSignal {
    return struct {
        fn call(ctx: *GhostCtx, signal: GhostSignal) GhostSignal {
            const mid = first(ctx, signal);
            return switch (mid) {
                .stale, .idle => mid, // short-circuit: don't run second stage
                else => second(ctx, mid),
            };
        }
    }.call;
}

// ============================================================
// Stage 1: Staleness guard — reject if input changed
// ============================================================

pub fn stalenessGuard(ctx: *GhostCtx, signal: GhostSignal) GhostSignal {
    return switch (signal) {
        .input => |inp| {
            if (ctx.current_seq.load(.monotonic) != inp.seq) return .stale;
            return signal;
        },
        else => signal,
    };
}

// ============================================================
// Stage 2: Prompt builder — input → prompt with history context
// ============================================================

pub fn promptBuilder(ctx: *GhostCtx, signal: GhostSignal) GhostSignal {
    return switch (signal) {
        .input => |inp| {
            var ppos: usize = 0;

            // Add last history command for context
            if (ctx.last_cmd.len > 0 and ctx.last_cmd.len < 60) {
                const clen = @min(ctx.last_cmd.len, 50);
                ctx.prompt_buf[ppos] = '$';
                ctx.prompt_buf[ppos + 1] = ' ';
                ppos += 2;
                @memcpy(ctx.prompt_buf[ppos..][0..clen], ctx.last_cmd[0..clen]);
                ppos += clen;
                ctx.prompt_buf[ppos] = '\n';
                ppos += 1;
            }

            // Add current input
            if (ppos + inp.text.len + 3 < ctx.prompt_buf.len) {
                ctx.prompt_buf[ppos] = '$';
                ctx.prompt_buf[ppos + 1] = ' ';
                ppos += 2;
                @memcpy(ctx.prompt_buf[ppos..][0..inp.text.len], inp.text);
                ppos += inp.text.len;
            }

            return .{ .prompt = .{
                .buf = &ctx.prompt_buf,
                .len = ppos,
                .seq = inp.seq,
            } };
        },
        else => signal,
    };
}

// ============================================================
// Stage 3: Inference — prompt → raw model output
// ============================================================

pub fn infer(ctx: *GhostCtx, signal: GhostSignal) GhostSignal {
    return switch (signal) {
        .prompt => |p| {
            // Pre-inference staleness check (cheap, avoids wasted GPU time)
            if (ctx.current_seq.load(.monotonic) != p.seq) return .stale;

            // Ensure server alive
            if (!ctx.server.isAlive()) {
                ctx.server.* = inference.ForkServer.spawn(ctx.model_path) catch return .idle;
            }

            const prompt = p.buf[0..p.len];
            const result = ctx.server.generate(prompt, 8, 0.0, ctx.allocator) catch return .idle;

            return .{ .raw_result = .{
                .data = result,
                .seq = p.seq,
            } };
        },
        else => signal,
    };
}

// ============================================================
// Stage 4: Sanitizer — strip non-printable, truncate at newline
// ============================================================

pub fn sanitizer(ctx: *GhostCtx, signal: GhostSignal) GhostSignal {
    return switch (signal) {
        .raw_result => |raw| {
            defer ctx.allocator.free(raw.data);

            var clean_len: u32 = 0;
            var junk_run: u8 = 0;

            for (raw.data) |c| {
                if (c == '\n' or c == '\r') break;
                if (c >= 0x20 and c <= 0x7E) {
                    if (clean_len < 512) {
                        ctx.result_buf[clean_len] = c;
                        clean_len += 1;
                    }
                    junk_run = 0;
                } else {
                    junk_run += 1;
                    if (junk_run > 2) break;
                }
            }

            if (clean_len == 0) return .idle;

            return .{ .completion = .{
                .buf = &ctx.result_buf,
                .len = clean_len,
                .seq = raw.seq,
            } };
        },
        else => signal,
    };
}

// ============================================================
// Composed pipeline: staleness >> prompt >> infer >> sanitize
// ============================================================

pub const pipeline = chain(stalenessGuard, chain(promptBuilder, chain(infer, sanitizer)));
