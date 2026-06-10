// agent_filters.zig — Comptime filter types for the agent pipeline.
// Each filter wraps an inner service, adding a single concern.
// Filters are composed via agent_service.Stack() at comptime.

const std = @import("std");
const compat = @import("compat.zig");
const svc = @import("agent_service.zig");
const router_mod = @import("agent_router.zig");
const log_mod = @import("agent_log.zig");

const Request = svc.Request;
const Response = svc.Response;
const AgentCtx = svc.AgentCtx;

// ============================================================
// RetryFilter — exponential backoff on transient errors
// ============================================================

/// Wraps inner.serve() with retry + exponential backoff.
/// Extracted from callAPI retry loop (agent.zig lines 1220-1243).
pub fn RetryFilter(comptime Inner: type) type {
    comptime svc.assertService(Inner);

    return struct {
        inner: Inner,
        max_retries: u8 = 3,

        const Self = @This();

        pub fn init(inner: Inner) Self {
            return .{ .inner = inner };
        }

        pub fn serve(self: *Self, ctx: *AgentCtx, req: *Request) Response {
            var attempt: u8 = 0;
            while (true) {
                const resp = self.inner.serve(ctx, req);
                if (resp.status != .error_msg) return resp;

                attempt += 1;
                if (attempt >= self.max_retries) return resp;
                if (ctx.queues.checkCancel()) return .{ .status = .cancelled };

                // Notify user about retry
                var retry_buf: [128]u8 = undefined;
                const retry_msg = std.fmt.bufPrint(&retry_buf, "API error, retrying ({d}/{d})...", .{
                    attempt, self.max_retries,
                }) catch "Retrying...";
                _ = ctx.queues.output.push(.tool_call, retry_msg);

                // Exponential backoff: 2s, 4s
                const delay_ms: u64 = @as(u64, 2000) * (@as(u64, 1) << @intCast(attempt - 1));
                compat.sleep(delay_ms * std.time.ns_per_ms);
            }
        }
    };
}

// ============================================================
// TokenTrackingFilter — accumulate tokens, push usage_info
// ============================================================

/// Accumulates input/output tokens from the response and pushes
/// a usage_info message to the output queue with cost/token summary.
/// Extracted from processQuery lines 1007-1031.
pub fn TokenTrackingFilter(comptime Inner: type) type {
    comptime svc.assertService(Inner);

    return struct {
        inner: Inner,

        const Self = @This();

        pub fn init(inner: Inner) Self {
            return .{ .inner = inner };
        }

        pub fn serve(self: *Self, ctx: *AgentCtx, req: *Request) Response {
            const resp = self.inner.serve(ctx, req);
            if (resp.status == .cancelled) return resp;

            // Accumulate into session-lifetime counters
            ctx.total_input_tokens.* += resp.input_tokens;
            ctx.total_output_tokens.* += resp.output_tokens;
            // Update shared atomic for live status bar display
            ctx.queues.shared_input_tokens.store(ctx.total_input_tokens.*, .monotonic);

            if (resp.input_tokens > 0 or resp.output_tokens > 0) {
                var usage_buf: [256]u8 = undefined;
                const is_free = std.mem.startsWith(u8, ctx.config.api_key, "sk-ant-oat");
                const usage_msg = if (is_free)
                    std.fmt.bufPrint(&usage_buf, "tokens: {d}\xe2\x86\x91 {d}\xe2\x86\x93 | total: {d}\xe2\x86\x91 {d}\xe2\x86\x93 (free)", .{
                        resp.input_tokens,  resp.output_tokens,
                        ctx.total_input_tokens.*, ctx.total_output_tokens.*,
                    }) catch "usage unavailable"
                else blk: {
                    const input_cost = @as(f64, @floatFromInt(ctx.total_input_tokens.*)) * 3.0 / 1_000_000.0;
                    const output_cost = @as(f64, @floatFromInt(ctx.total_output_tokens.*)) * 15.0 / 1_000_000.0;
                    const total_cost = input_cost + output_cost;
                    break :blk std.fmt.bufPrint(&usage_buf, "tokens: {d}\xe2\x86\x91 {d}\xe2\x86\x93 | total: {d}\xe2\x86\x91 {d}\xe2\x86\x93 (${d:.4})", .{
                        resp.input_tokens,  resp.output_tokens,
                        ctx.total_input_tokens.*, ctx.total_output_tokens.*,
                        total_cost,
                    }) catch "usage unavailable";
                };
                _ = ctx.queues.output.push(.usage_info, usage_msg);
            }

            return resp;
        }
    };
}

// ============================================================
// LoggingFilter — session log for user queries and responses
// ============================================================

/// Logs user query (before inner) and done marker (after inner) to session log.
/// Extracted from scattered `if (self.session_log)` calls in processQuery.
pub fn LoggingFilter(comptime Inner: type) type {
    comptime svc.assertService(Inner);

    return struct {
        inner: Inner,

        const Self = @This();

        pub fn init(inner: Inner) Self {
            return .{ .inner = inner };
        }

        pub fn serve(self: *Self, ctx: *AgentCtx, req: *Request) Response {
            // Log the user query before processing
            if (ctx.session_log) |sl| {
                sl.logUser(req.query) catch {};
            }

            const resp = self.inner.serve(ctx, req);

            // Log completion
            if (ctx.session_log) |sl| {
                sl.logDone() catch {};
            }

            return resp;
        }
    };
}

// ============================================================
// RouterFilter — classify query, set route, handle shell action
// ============================================================

/// Classifies the query via local patterns / local GGUF / API model,
/// sets req.route, and short-circuits shell actions (req.handled = true).
/// Extracted from processQuery routing phase (lines 832-897).
pub fn RouterFilter(comptime Inner: type) type {
    comptime svc.assertService(Inner);

    return struct {
        inner: Inner,

        const Self = @This();

        pub fn init(inner: Inner) Self {
            return .{ .inner = inner };
        }

        pub fn serve(self: *Self, ctx: *AgentCtx, req: *Request) Response {
            // Save original model, restore on return
            const saved_model = ctx.config.model;
            defer ctx.config.model = saved_model;

            // Fast path: translate queries always use haiku
            if (std.mem.startsWith(u8, req.query, "Translate this to a shell command")) {
                req.is_translate = true;
                ctx.config.model = ctx.router_config.resolveModel(.small);
            }

            // Routing phase
            if (ctx.router_config.enabled and !req.is_translate) {
                // Try local classification first (zero cost)
                req.route = router_mod.classifyLocalWithConfig(req.query, ctx.router_config);

                // If ambiguous, try local GGUF inference
                if (req.route == null and ctx.router_config.local_model_len > 0) {
                    req.route = router_mod.classifyWithLocalModel(
                        ctx.allocator,
                        req.query,
                        ctx.router_config,
                    );
                }

                // If still ambiguous, call the router model via API
                if (req.route == null and ctx.router_config.api_enabled) {
                    req.route = router_mod.classifyWithModel(
                        ctx.allocator,
                        req.query,
                        ctx.context_summary,
                        ctx.router_config,
                        ctx.config.api_key,
                    );
                }

                // Handle routing decision
                if (req.route) |*rd| {
                    logRouterDecision(req.query, rd.*);
                    // Apply: set model based on routed tier
                    ctx.config.model = ctx.router_config.resolveModel(rd.model_tier);
                    // Push route info to display
                    var sum_buf: [256]u8 = undefined;
                    _ = ctx.queues.output.push(.router_info, rd.summary(&sum_buf));
                }

                // Log unclassified queries
                if (req.route == null) {
                    var default_rd = router_mod.RouteDecision{
                        .action = .agent,
                        .model_tier = .large,
                        .cost = .high,
                    };
                    default_rd.setReason("default: large");
                    logRouterDecision(req.query, default_rd);
                }
            }

            // Not handled by router — pass through to inner service
            return self.inner.serve(ctx, req);
        }

        /// Log routing decision to ~/.zish/router_log.jsonl for training data.
        fn logRouterDecision(query: []const u8, rd: router_mod.RouteDecision) void {
            if (query.len == 0 or query.len > 2048) return;

            const alloc = std.heap.page_allocator;
            var path_buf: [512]u8 = undefined;
            const home = compat.getEnvVarOwned(alloc, "HOME") catch return;
            defer alloc.free(home);

            const path = std.fmt.bufPrint(&path_buf, "{s}/.zish/router_log.jsonl", .{home}) catch return;
            const file = std.Io.Dir.cwd().openFile(compat.io(), path, .{ .mode = .write_only }) catch |e| switch (e) {
                error.FileNotFound => std.Io.Dir.cwd().createFile(compat.io(), path, .{}) catch return,
                else => return,
            };
            defer file.close(compat.io());
            const file_end = file.length(compat.io()) catch return;

            const action_str: []const u8 = switch (rd.action) {
                .agent => "agent",
                .fan_out => "fan_out",
            };
            const tier_str: []const u8 = switch (rd.model_tier) {
                .small => "small",
                .medium => "medium",
                .large => "large",
            };

            const ts: u64 = @bitCast(compat.timestamp());
            var buf: [4096]u8 = undefined;
            var pos: usize = 0;
            const prefix = "{\"q\":\"";
            @memcpy(buf[pos..][0..prefix.len], prefix);
            pos += prefix.len;
            for (query) |c| {
                if (pos + 6 >= buf.len) break;
                switch (c) {
                    '"' => { @memcpy(buf[pos..][0..2], "\\\""); pos += 2; },
                    '\\' => { @memcpy(buf[pos..][0..2], "\\\\"); pos += 2; },
                    '\n' => { @memcpy(buf[pos..][0..2], "\\n"); pos += 2; },
                    '\r' => {},
                    '\t' => { @memcpy(buf[pos..][0..2], "\\t"); pos += 2; },
                    else => { buf[pos] = c; pos += 1; },
                }
            }
            const mid = std.fmt.bufPrint(buf[pos..], "\",\"action\":\"{s}\",\"tier\":\"{s}\",\"reason\":\"{s}\",\"ts\":{d}}}\n", .{
                action_str, tier_str, rd.reason(), ts,
            }) catch return;
            pos += mid.len;
            file.writePositionalAll(compat.io(), buf[0..pos], file_end) catch {};
        }
    };
}

// ============================================================
// Tests
// ============================================================

test "RetryFilter compiles with mock service" {
    const Mock = struct {
        call_count: u8 = 0,
        pub fn serve(self: *@This(), _: *AgentCtx, _: *Request) Response {
            self.call_count += 1;
            return .{ .status = .ok };
        }
    };
    const Filtered = RetryFilter(Mock);
    _ = Filtered;
}

test "TokenTrackingFilter compiles with mock service" {
    const Mock = struct {
        pub fn serve(_: *@This(), _: *AgentCtx, _: *Request) Response {
            return .{ .status = .ok, .input_tokens = 100, .output_tokens = 50 };
        }
    };
    const Filtered = TokenTrackingFilter(Mock);
    _ = Filtered;
}

test "LoggingFilter compiles with mock service" {
    const Mock = struct {
        pub fn serve(_: *@This(), _: *AgentCtx, _: *Request) Response {
            return .{ .status = .ok };
        }
    };
    const Filtered = LoggingFilter(Mock);
    _ = Filtered;
}

test "RouterFilter compiles with mock service" {
    const Mock = struct {
        pub fn serve(_: *@This(), _: *AgentCtx, _: *Request) Response {
            return .{ .status = .ok };
        }
    };
    const Filtered = RouterFilter(Mock);
    _ = Filtered;
}

test "Stack composes filters" {
    const Mock = struct {
        pub fn serve(_: *@This(), _: *AgentCtx, _: *Request) Response {
            return .{ .status = .ok };
        }
    };
    const Pipeline = svc.Stack(Mock, .{
        RetryFilter,
        TokenTrackingFilter,
        LoggingFilter,
        RouterFilter,
    });
    _ = Pipeline;
}
