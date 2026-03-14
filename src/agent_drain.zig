// agent_drain.zig - Unified message drain system using comptime interfaces.
//
// Deduplicates the drain switch(msg.kind) logic that was previously repeated in:
// - builtins.zig agentCmd() (non-interactive)
// - builtins.zig agentInteractive() (interactive TUI)
// - Shell.zig drainAgentOutput() (inline shell)

const std = @import("std");
const q = @import("agent_queue.zig");
const agent_mod = @import("agent.zig");

pub const MsgKind = q.MsgKind;
pub const Msg = q.Msg;
pub const AgentQueues = q.AgentQueues;
pub const MarkdownRenderer = agent_mod.MarkdownRenderer;

/// Pop messages from the output queue and dispatch to handler methods.
///
/// The Handler type must implement any subset of these methods (all optional):
///   fn onTextDelta(h, data: []const u8) !void
///   fn onToolCall(h, data: []const u8) !void
///   fn onToolDone(h, data: []const u8) !void
///   fn onError(h, data: []const u8) !void
///   fn onDone(h) !void
///   fn onCancel(h) !void
///   fn onUsage(h, data: []const u8) !void
///   fn onRouterInfo(h, data: []const u8) !void
///   fn onConfirmRequest(h, data: []const u8) !void
///   fn onAgentStatus(h, data: []const u8) !void
///
/// Returns true if any messages were drained.
pub fn drain(comptime Handler: type, handler: *Handler, queues: *AgentQueues) !bool {
    var msg: Msg = undefined;
    var got_any = false;

    while (queues.output.pop(&msg)) {
        got_any = true;
        const data = msg.slice();

        switch (msg.kind) {
            .text_delta => {
                if (comptime hasMethod(Handler, "onTextDelta")) {
                    try handler.onTextDelta(data);
                }
            },
            .tool_call => {
                if (comptime hasMethod(Handler, "onToolCall")) {
                    try handler.onToolCall(data);
                }
            },
            .tool_done => {
                if (comptime hasMethod(Handler, "onToolDone")) {
                    try handler.onToolDone(data);
                }
            },
            .error_msg => {
                if (comptime hasMethod(Handler, "onError")) {
                    try handler.onError(data);
                }
            },
            .done => {
                if (comptime hasMethod(Handler, "onDone")) {
                    try handler.onDone();
                }
            },
            .cancel => {
                if (comptime hasMethod(Handler, "onCancel")) {
                    try handler.onCancel();
                }
            },
            .usage_info => {
                if (comptime hasMethod(Handler, "onUsage")) {
                    try handler.onUsage(data);
                }
            },
            .router_info => {
                if (comptime hasMethod(Handler, "onRouterInfo")) {
                    try handler.onRouterInfo(data);
                }
            },
            .confirm_request => {
                if (comptime hasMethod(Handler, "onConfirmRequest")) {
                    try handler.onConfirmRequest(data);
                }
            },
            .agent_status => {
                if (comptime hasMethod(Handler, "onAgentStatus")) {
                    try handler.onAgentStatus(data);
                }
            },
            .agent_tree_node => {
                if (comptime hasMethod(Handler, "onTreeNode")) {
                    try handler.onTreeNode(data);
                }
            },
            .agent_result => {
                if (comptime hasMethod(Handler, "onAgentResult")) {
                    try handler.onAgentResult(data);
                }
            },
            // Request-side messages — not expected on output queue
            .confirm_response, .add_task, .spawn_worker, .agent_status_req,
            .agent_tree_req, .agent_result_req => {},
        }
    }

    return got_any;
}

fn hasMethod(comptime T: type, comptime name: []const u8) bool {
    return @hasDecl(T, name);
}

/// SimpleHandler — for non-interactive (pipe/script) mode.
/// Renders markdown text, shows tool calls/results, auto-denies confirms.
/// Uses *std.Io.Writer (vtable writer interface) matching Shell.stdout().
pub const SimpleHandler = struct {
    writer: *std.Io.Writer,
    md: MarkdownRenderer = .{},
    request_queue: *q.Queue(q.QUEUE_CAPACITY),
    done: bool = false,

    pub fn init(writer: *std.Io.Writer, request_queue: *q.Queue(q.QUEUE_CAPACITY)) SimpleHandler {
        return .{
            .writer = writer,
            .request_queue = request_queue,
        };
    }

    pub fn flush(self: *SimpleHandler) !void {
        try self.writer.flush();
    }

    pub fn isDone(self: *const SimpleHandler) bool {
        return self.done;
    }

    pub fn onTextDelta(self: *SimpleHandler, data: []const u8) !void {
        try self.md.render(self.writer, data);
    }

    pub fn onToolCall(self: *SimpleHandler, data: []const u8) !void {
        try self.md.flush(self.writer);
        try self.writer.writeAll("\x1b[0m");
        self.md.reset();
        try self.writer.writeAll("\x1b[90m\xe2\x9a\xa1 "); // ⚡
        try self.writer.writeAll(data);
        try self.writer.writeAll("\x1b[0m\n");
    }

    pub fn onToolDone(self: *SimpleHandler, data: []const u8) !void {
        if (data.len > 0) {
            // Check for ANSI colors (edit diff)
            const has_ansi = std.mem.indexOf(u8, data, "\x1b[3") != null;
            if (has_ansi) {
                // Show colored output inline
                try self.writer.writeAll("  ");
                try self.writer.writeAll(data);
                try self.writer.writeAll("\x1b[0m\n");
            } else {
                // Count lines
                var lc: usize = 1;
                for (data) |dc| { if (dc == '\n') lc += 1; }
                if (lc <= 8) {
                    // Short: show inline
                    var ls: usize = 0;
                    for (data, 0..) |dc, di| {
                        if (dc == '\n' or di == data.len - 1) {
                            const end = if (dc == '\n') di else di + 1;
                            try self.writer.writeAll("  \x1b[90m");
                            try self.writer.writeAll(data[ls..end]);
                            try self.writer.writeAll("\x1b[0m\n");
                            ls = di + 1;
                        }
                    }
                } else {
                    // Long: compact
                    var fmt_buf: [64]u8 = undefined;
                    const msg = std.fmt.bufPrint(&fmt_buf, "  \x1b[32m\xe2\x9c\x93\x1b[90m {d} lines\x1b[0m\n", .{lc}) catch "  \x1b[32m\xe2\x9c\x93\x1b[0m\n";
                    try self.writer.writeAll(msg);
                }
            }
        } else {
            try self.writer.writeAll("  \x1b[32m\xe2\x9c\x93\x1b[0m\n");
        }
    }

    pub fn onError(self: *SimpleHandler, data: []const u8) !void {
        try self.writer.writeAll("\x1b[31m");
        try self.writer.writeAll("agent: ");
        try self.writer.writeAll(data);
        try self.writer.writeAll("\x1b[0m\n");
    }

    pub fn onDone(self: *SimpleHandler) !void {
        try self.md.flush(self.writer);
        try self.writer.writeAll("\x1b[0m\n");
        self.md.reset();
        self.done = true;
    }

    pub fn onCancel(self: *SimpleHandler) !void {
        try self.md.flush(self.writer);
        try self.writer.writeAll("\x1b[0m\n");
        self.md.reset();
        self.done = true;
    }

    pub fn onUsage(self: *SimpleHandler, data: []const u8) !void {
        try self.writer.writeAll("\x1b[90m");
        try self.writer.writeAll(data);
        try self.writer.writeAll("\x1b[0m\n");
    }

    pub fn onRouterInfo(self: *SimpleHandler, data: []const u8) !void {
        // Suppress router info in output (matches interactive mode)
        _ = self;
        _ = data;
    }

    pub fn onConfirmRequest(self: *SimpleHandler, _: []const u8) !void {
        // Auto-deny in non-interactive mode
        _ = self.request_queue.push(.confirm_response, "n");
    }
};
