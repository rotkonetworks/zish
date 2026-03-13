// agent_service.zig — Comptime service/filter composition types for the agent pipeline.
// These types define the request/response protocol and shared context that filters
// operate on. Filters wrap an inner service, adding cross-cutting concerns
// (retry, logging, token tracking, routing) without tangling them together.

const std = @import("std");
const q = @import("agent_queue.zig");
const log_mod = @import("agent_log.zig");
const router_mod = @import("agent_router.zig");

pub const AgentQueues = q.AgentQueues;
pub const SessionLog = log_mod.SessionLog;
pub const AgentConfig = log_mod.AgentConfig;

/// Inbound request flowing through the filter pipeline.
pub const Request = struct {
    query: []const u8,
    route: ?router_mod.RouteDecision = null,
    is_translate: bool = false,
    /// Set by RouterFilter when query is handled directly (shell action).
    handled: bool = false,
};

/// Outbound response flowing back through the filter pipeline.
pub const Response = struct {
    status: Status = .ok,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,

    pub const Status = enum {
        ok,
        error_msg,
        cancelled,
    };
};

/// Shared mutable context threaded through all filters and the core service.
/// Holds references to the agent's owned state — filters never own this data.
pub const AgentCtx = struct {
    allocator: std.mem.Allocator,
    queues: *AgentQueues,
    config: *@import("agent.zig").Config,
    router_config: *router_mod.RouterConfig,
    session_log: ?*SessionLog,
    /// Cumulative token counters (lifetime of session, not per-query).
    total_input_tokens: *u32,
    total_output_tokens: *u32,
    /// Context summary for router (conversation topic hint).
    context_summary: []const u8 = "",
};

/// Type constraint: any valid service must have `fn serve(*Self, *AgentCtx, *Request) Response`.
/// This is checked at comptime by filters that wrap an Inner type.
pub fn assertService(comptime T: type) void {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("Service must be a struct");
    if (!@hasDecl(T, "serve")) @compileError("Service must have a serve() method");
}

/// Convenience: build a fully composed pipeline type at comptime.
/// Usage:
///   const Pipeline = agent_service.Stack(CoreService, .{
///       agent_filters.RetryFilter,
///       agent_filters.TokenTrackingFilter,
///       agent_filters.LoggingFilter,
///       agent_filters.RouterFilter,
///   });
/// Outermost filter is last in the tuple (RouterFilter wraps LoggingFilter wraps ... wraps CoreService).
pub fn Stack(comptime Core: type, comptime filters: anytype) type {
    comptime {
        var T = Core;
        for (filters) |Filter| {
            T = Filter(T);
        }
        return T;
    }
}
