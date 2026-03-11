// agent.zig - LLM agent thread for zish
// Runs in background, communicates via lock-free queues.
// Supports Anthropic API, Ollama, and any OpenAI-compatible endpoint.

const std = @import("std");
const q = @import("agent_queue.zig");

pub const AgentQueues = q.AgentQueues;

// ============================================================
// Configuration
// ============================================================

pub const Provider = enum { anthropic, ollama, openai_compat };

pub const Config = struct {
    provider: Provider = .anthropic,
    model: []const u8 = "claude-opus-4-6-20251101",
    api_key: []const u8 = "",
    base_url: []const u8 = "https://api.anthropic.com",
    max_tokens: u32 = 8192,

    pub fn fromEnv(allocator: std.mem.Allocator) Config {
        var cfg = Config{};

        // provider
        if (std.process.getEnvVarOwned(allocator, "ZISH_AGENT_PROVIDER") catch null) |p| {
            defer allocator.free(p);
            if (std.mem.eql(u8, p, "ollama")) cfg.provider = .ollama
            else if (std.mem.eql(u8, p, "openai")) cfg.provider = .openai_compat;
        }

        // api key - try ZISH_AGENT_KEY then ANTHROPIC_API_KEY
        const key = (std.process.getEnvVarOwned(allocator, "ZISH_AGENT_KEY") catch null)
            orelse (std.process.getEnvVarOwned(allocator, "ANTHROPIC_API_KEY") catch null);
        if (key) |k| cfg.api_key = k; // NOTE: leaked on purpose (static lifetime for thread)

        // base url
        const url = std.process.getEnvVarOwned(allocator, "ZISH_AGENT_URL") catch null;
        if (url) |u| cfg.base_url = u;

        // model
        const model = std.process.getEnvVarOwned(allocator, "ZISH_AGENT_MODEL") catch null;
        if (model) |m| cfg.model = m;

        // ollama defaults
        if (cfg.provider == .ollama) {
            if (cfg.base_url.len == 0 or std.mem.eql(u8, cfg.base_url, "https://api.anthropic.com")) {
                cfg.base_url = "http://localhost:11434";
            }
            if (std.mem.eql(u8, cfg.model, "claude-opus-4-6-20251101")) {
                cfg.model = "llama3.2";
            }
        }

        return cfg;
    }
};

// ============================================================
// Conversation history
// ============================================================

const MAX_HISTORY = 20;
const MAX_CONTENT_LEN = 65536;

const Role = enum { user, assistant };

const Message = struct {
    role: Role,
    content: []u8,
    content_len: usize,
};

const ConversationHistory = struct {
    messages: [MAX_HISTORY]Message = undefined,
    count: usize = 0,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) ConversationHistory {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *ConversationHistory) void {
        for (0..self.count) |i| {
            self.allocator.free(self.messages[i].content[0..MAX_CONTENT_LEN]);
        }
    }

    fn add(self: *ConversationHistory, role: Role, content: []const u8) !void {
        if (self.count >= MAX_HISTORY) {
            // drop oldest two (user+assistant pair)
            const n = 2;
            self.allocator.free(self.messages[0].content[0..MAX_CONTENT_LEN]);
            self.allocator.free(self.messages[1].content[0..MAX_CONTENT_LEN]);
            std.mem.copyForwards(Message, self.messages[0..self.count - n], self.messages[n..self.count]);
            self.count -= n;
        }
        const buf = try self.allocator.alloc(u8, MAX_CONTENT_LEN);
        const n = @min(content.len, MAX_CONTENT_LEN);
        @memcpy(buf[0..n], content[0..n]);
        self.messages[self.count] = .{ .role = role, .content = buf, .content_len = n };
        self.count += 1;
    }

    fn clear(self: *ConversationHistory) void {
        for (0..self.count) |i| {
            self.allocator.free(self.messages[i].content[0..MAX_CONTENT_LEN]);
        }
        self.count = 0;
    }
};

// ============================================================
// Tool definitions
// ============================================================

const SYSTEM_PROMPT =
    \\You are a helpful shell assistant running inside zish shell.
    \\You can run bash commands to help the user.
    \\Be concise. When running commands, explain briefly what you're doing.
    \\The user's working directory is provided in the query context.
    \\
;

const TOOLS_JSON =
    \\[{"name":"Bash","description":"Run a shell command and get its output","input_schema":{"type":"object","properties":{"command":{"type":"string","description":"The shell command to run"}},"required":["command"]}}]
;

// ============================================================
// HTTP + SSE streaming
// ============================================================

const AgentThread = struct {
    allocator: std.mem.Allocator,
    queues: *AgentQueues,
    config: Config,
    history: ConversationHistory,

    fn init(allocator: std.mem.Allocator, queues: *AgentQueues, config: Config) AgentThread {
        return .{
            .allocator = allocator,
            .queues = queues,
            .config = config,
            .history = ConversationHistory.init(allocator),
        };
    }

    fn deinit(self: *AgentThread) void {
        self.history.deinit();
    }

    /// Main agent loop: process requests from main thread
    fn run(self: *AgentThread) void {
        var req_msg: q.Msg = undefined;
        while (true) {
            // poll for new request
            if (!self.queues.request.pop(&req_msg)) {
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            }

            if (req_msg.kind == .cancel) break; // shutdown

            const query = req_msg.slice();
            self.queues.clearCancel();
            self.queues.setBusy(true);

            self.processQuery(query) catch |err| {
                var errbuf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&errbuf, "agent error: {}", .{err}) catch "agent error";
                _ = self.queues.output.push(.error_msg, msg);
            };

            self.queues.setBusy(false);
            _ = self.queues.output.push(.done, "");
        }
    }

    fn processQuery(self: *AgentThread, query: []const u8) !void {
        // add user message to history
        try self.history.add(.user, query);

        // tool loop: keep calling API until no more tool_use
        var iteration: usize = 0;
        while (iteration < 10) : (iteration += 1) {
            if (self.queues.checkCancel()) return;

            const response = try self.callAPI();
            defer self.allocator.free(response.text);

            // add assistant response to history
            if (response.text.len > 0) {
                try self.history.add(.assistant, response.text);
            }

            if (!response.has_tool_call) break; // done

            // execute tool
            if (self.queues.checkCancel()) return;
            const tool_output = try self.executeBash(response.tool_command);
            defer self.allocator.free(tool_output);

            // add tool result to history as user message
            const result_buf = try self.allocator.alloc(u8, tool_output.len + 64);
            defer self.allocator.free(result_buf);
            const result_msg = std.fmt.bufPrint(result_buf,
                "[tool result]\n{s}", .{tool_output}) catch tool_output;
            try self.history.add(.user, result_msg);
        }
    }

    const APIResponse = struct {
        text: []u8,           // owned by caller
        has_tool_call: bool,
        tool_command: []const u8, // slice into text or static
        tool_name: []const u8,
    };

    fn callAPI(self: *AgentThread) !APIResponse {
        return switch (self.config.provider) {
            .anthropic => self.callAnthropic(),
            .ollama, .openai_compat => self.callOpenAICompat(),
        };
    }

    fn buildMessagesJSON(self: *AgentThread, buf: []u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        try w.writeByte('[');
        for (0..self.history.count) |i| {
            if (i > 0) try w.writeByte(',');
            const msg = &self.history.messages[i];
            const role_str = if (msg.role == .user) "user" else "assistant";
            const content = msg.content[0..msg.content_len];
            try w.print("{{\"role\":\"{s}\",\"content\":", .{role_str});
            try writeJSONString(w, content);
            try w.writeByte('}');
        }
        try w.writeByte(']');
        return buf[0..fbs.pos];
    }

    fn callAnthropic(self: *AgentThread) !APIResponse {
        // Build request body
        var body_buf: [MAX_CONTENT_LEN * 4]u8 = undefined;
        var msg_buf: [MAX_CONTENT_LEN * 3]u8 = undefined;
        const messages_json = try self.buildMessagesJSON(&msg_buf);

        const body = std.fmt.bufPrint(&body_buf,
            \\{{"model":"{s}","max_tokens":{d},"stream":true,"system":"{s}","messages":{s},"tools":{s}}}
            , .{
                self.config.model,
                self.config.max_tokens,
                SYSTEM_PROMPT,
                messages_json,
                TOOLS_JSON,
            }) catch return error.BodyTooLarge;

        // Build URL
        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/v1/messages", .{self.config.base_url})
            catch return error.URLTooLong;

        return self.doStreamRequest(url, body, .anthropic);
    }

    fn callOpenAICompat(self: *AgentThread) !APIResponse {
        var body_buf: [MAX_CONTENT_LEN * 4]u8 = undefined;
        var msg_buf: [MAX_CONTENT_LEN * 3]u8 = undefined;
        const messages_json = try self.buildMessagesJSON(&msg_buf);

        const body = std.fmt.bufPrint(&body_buf,
            \\{{"model":"{s}","stream":true,"messages":{s}}}
            , .{ self.config.model, messages_json })
            catch return error.BodyTooLarge;

        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/v1/chat/completions", .{self.config.base_url})
            catch return error.URLTooLong;

        return self.doStreamRequest(url, body, .openai_compat);
    }

    fn doStreamRequest(self: *AgentThread, url: []const u8, body: []const u8, provider: Provider) !APIResponse {
        // Output accumulator
        var text_buf = try self.allocator.alloc(u8, MAX_CONTENT_LEN);
        var text_len: usize = 0;
        var tool_cmd_buf: [4096]u8 = undefined;
        var tool_cmd_len: usize = 0;
        var tool_name_buf: [64]u8 = undefined;
        var tool_name_len: usize = 0;
        var has_tool_call = false;

        // HTTP client
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        const uri = std.Uri.parse(url) catch return error.InvalidURL;

        // Build extra headers for auth
        var extra_headers: [3]std.http.Header = undefined;
        var header_count: usize = 0;
        var auth_buf: [512]u8 = undefined; // lives until request headers are sent

        switch (provider) {
            .anthropic => {
                extra_headers[header_count] = .{ .name = "x-api-key", .value = self.config.api_key };
                header_count += 1;
                extra_headers[header_count] = .{ .name = "anthropic-version", .value = "2023-06-01" };
                header_count += 1;
                extra_headers[header_count] = .{ .name = "anthropic-beta", .value = "tools-2024-04-04" };
                header_count += 1;
            },
            .ollama, .openai_compat => {
                if (self.config.api_key.len > 0) {
                    const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{self.config.api_key}) catch self.config.api_key;
                    extra_headers[header_count] = .{ .name = "Authorization", .value = auth };
                    header_count += 1;
                }
            },
        }

        var req = try client.request(.POST, uri, .{
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .extra_headers = extra_headers[0..header_count],
            .redirect_behavior = .unhandled,
        });
        defer req.deinit();

        // Send body
        req.transfer_encoding = .{ .content_length = body.len };
        var bw = try req.sendBodyUnflushed(&.{});
        try bw.writer.writeAll(body);
        try bw.end();
        try req.connection.?.flush();

        // Receive response head
        var response = try req.receiveHead(&.{});

        if (response.head.status != .ok) {
            _ = self.queues.output.push(.error_msg, "HTTP error from API");
            self.allocator.free(text_buf);
            return error.HTTPError;
        }

        // Stream SSE response via body reader
        var transfer_buf: [64]u8 = undefined;
        const body_reader = response.reader(&transfer_buf);
        var sse_buf: [8192]u8 = undefined;
        var sse_pos: usize = 0;

        outer: while (true) {
            if (self.queues.checkCancel()) {
                self.allocator.free(text_buf);
                return error.Cancelled;
            }

            // Read more data
            var bufs: [1][]u8 = .{sse_buf[sse_pos..]};
            const n = body_reader.readVec(&bufs) catch break;
            if (n == 0) break;
            sse_pos += n;

            // Process complete lines
            var scan: usize = 0;
            while (scan < sse_pos) {
                const line_end = std.mem.indexOfScalarPos(u8, sse_buf[0..sse_pos], scan, '\n') orelse break;
                const line = std.mem.trimRight(u8, sse_buf[scan..line_end], "\r");
                scan = line_end + 1;

                if (!std.mem.startsWith(u8, line, "data: ")) continue;
                const data = line[6..];
                if (std.mem.eql(u8, data, "[DONE]")) break :outer;

                // Parse JSON delta based on provider
                switch (provider) {
                    .anthropic => {
                        parseAnthropicDelta(data, &text_buf, &text_len,
                            &tool_cmd_buf, &tool_cmd_len,
                            &tool_name_buf, &tool_name_len,
                            &has_tool_call, self.queues);
                    },
                    .ollama, .openai_compat => {
                        parseOpenAIDelta(data, &text_buf, &text_len, self.queues);
                    },
                }
            }

            // Shift remaining data
            if (scan < sse_pos) {
                std.mem.copyForwards(u8, sse_buf[0..], sse_buf[scan..sse_pos]);
                sse_pos -= scan;
            } else {
                sse_pos = 0;
            }
        }

        return APIResponse{
            .text = text_buf[0..text_len],
            .has_tool_call = has_tool_call,
            .tool_command = tool_cmd_buf[0..tool_cmd_len],
            .tool_name = tool_name_buf[0..tool_name_len],
        };
    }

    fn executeBash(self: *AgentThread, command: []const u8) ![]u8 {
        // notify main thread
        var notif_buf: [512]u8 = undefined;
        const notif = std.fmt.bufPrint(&notif_buf, "$ {s}", .{command}) catch command;
        _ = self.queues.output.push(.tool_call, notif);

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "/bin/sh", "-c", command },
            .max_output_bytes = 65536,
        }) catch |err| {
            var errbuf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&errbuf, "exec failed: {}", .{err}) catch "exec failed";
            return self.allocator.dupe(u8, msg);
        };
        defer self.allocator.free(result.stderr);

        // send tool output to main thread for display
        _ = self.queues.output.push(.tool_done, result.stdout);

        return result.stdout; // caller frees
    }
};

// ============================================================
// SSE/JSON parsing (zero-alloc, grep-style extraction)
// ============================================================

fn parseAnthropicDelta(
    data: []const u8,
    text_buf: *[]u8,
    text_len: *usize,
    tool_cmd_buf: *[4096]u8,
    tool_cmd_len: *usize,
    tool_name_buf: *[64]u8,
    tool_name_len: *usize,
    has_tool_call: *bool,
    queues: *AgentQueues,
) void {
    // Extract "type" field
    const type_val = jsonGetStr(data, "type") orelse return;

    if (std.mem.eql(u8, type_val, "content_block_start")) {
        // Check if it's a tool_use block
        const block_type = jsonGetStr(data, "type") orelse "";
        _ = block_type;
        if (std.mem.indexOf(u8, data, "\"tool_use\"") != null) {
            has_tool_call.* = true;
            // extract tool name
            if (jsonGetStr(data, "name")) |name| {
                const n = @min(name.len, 64);
                @memcpy(tool_name_buf[0..n], name[0..n]);
                tool_name_len.* = n;
            }
        }
        return;
    }

    if (std.mem.eql(u8, type_val, "content_block_delta")) {
        // text delta
        if (std.mem.indexOf(u8, data, "\"text_delta\"") != null) {
            if (jsonGetStr(data, "text")) |text| {
                const decoded = unescapeJSON(text, text_buf.*[text_len.*..]) orelse text;
                text_len.* += decoded.len;
                if (text_len.* > text_buf.len) text_len.* = text_buf.len;
                _ = queues.output.push(.text_delta, decoded);
            }
            return;
        }
        // input_json_delta (tool arguments)
        if (std.mem.indexOf(u8, data, "\"input_json_delta\"") != null) {
            if (jsonGetStr(data, "partial_json")) |chunk| {
                const n = @min(chunk.len, 4096 - tool_cmd_len.*);
                @memcpy(tool_cmd_buf[tool_cmd_len.*..][0..n], chunk[0..n]);
                tool_cmd_len.* += n;
            }
        }
    }
}

fn parseOpenAIDelta(
    data: []const u8,
    text_buf: *[]u8,
    text_len: *usize,
    queues: *AgentQueues,
) void {
    // Extract delta.content from OpenAI streaming format
    if (jsonGetStr(data, "content")) |text| {
        const decoded = unescapeJSON(text, text_buf.*[text_len.*..]) orelse text;
        text_len.* += decoded.len;
        if (text_len.* > text_buf.len) text_len.* = text_buf.len;
        _ = queues.output.push(.text_delta, decoded);
    }
}

/// Extract string value from JSON by key (no allocation, returns raw escaped slice)
fn jsonGetStr(json: []const u8, key: []const u8) ?[]const u8 {
    var key_buf: [128]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&key_buf, "\"{s}\":", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, json, quoted_key) orelse return null;
    const after = json[idx + quoted_key.len..];
    const trimmed = std.mem.trimLeft(u8, after, " \t");
    if (trimmed.len == 0 or trimmed[0] != '"') return null;
    // find closing quote (handle \")
    var i: usize = 1;
    while (i < trimmed.len) : (i += 1) {
        if (trimmed[i] == '\\') { i += 1; continue; }
        if (trimmed[i] == '"') return trimmed[1..i];
    }
    return null;
}

/// Unescape JSON string escapes (\n, \t, \\, \") into dest buffer
/// Returns slice of dest on success, null if dest too small
fn unescapeJSON(src: []const u8, dest: []u8) ?[]const u8 {
    var di: usize = 0;
    var si: usize = 0;
    while (si < src.len) {
        if (di >= dest.len) return null;
        if (src[si] == '\\' and si + 1 < src.len) {
            si += 1;
            const c: u8 = switch (src[si]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '"' => '"',
                '\\' => '\\',
                else => src[si],
            };
            dest[di] = c;
        } else {
            dest[di] = src[si];
        }
        di += 1;
        si += 1;
    }
    return dest[0..di];
}

fn writeJSONString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

// ============================================================
// Public API — thread entry point
// ============================================================

pub const AgentContext = struct {
    queues: AgentQueues = .{},
    thread: ?std.Thread = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AgentContext {
        return .{ .allocator = allocator };
    }

    pub fn start(self: *AgentContext) !void {
        if (self.thread != null) return;
        self.thread = try std.Thread.spawn(.{}, agentThreadFn, .{ self.allocator, &self.queues });
    }

    pub fn stop(self: *AgentContext) void {
        if (self.thread) |t| {
            _ = self.queues.request.push(.cancel, "");
            t.join();
            self.thread = null;
        }
    }

    /// Send a query to the agent. Returns false if agent is busy.
    pub fn query(self: *AgentContext, text: []const u8) bool {
        if (self.queues.isBusy()) return false;
        return self.queues.request.push(.text_delta, text);
    }

    pub fn cancel(self: *AgentContext) void {
        self.queues.requestCancel();
    }

    pub fn isBusy(self: *const AgentContext) bool {
        return self.queues.isBusy();
    }

    /// Drain output queue into a write buffer. Returns true if anything was written.
    pub fn drainOutput(self: *AgentContext, writer: anytype) !bool {
        var msg: q.Msg = undefined;
        var wrote = false;
        while (self.queues.output.pop(&msg)) {
            wrote = true;
            switch (msg.kind) {
                .text_delta => try writer.writeAll(msg.slice()),
                .tool_call => {
                    try writer.writeAll("\x1b[90m"); // dim gray
                    try writer.writeAll(msg.slice());
                    try writer.writeAll("\x1b[0m\n");
                },
                .tool_done => {
                    try writer.writeAll("\x1b[90m");
                    try writer.writeAll(msg.slice());
                    try writer.writeAll("\x1b[0m\n");
                },
                .error_msg => {
                    try writer.writeAll("\x1b[31m"); // red
                    try writer.writeAll("agent: ");
                    try writer.writeAll(msg.slice());
                    try writer.writeAll("\x1b[0m\n");
                },
                .done => {
                    try writer.writeByte('\n');
                },
                .cancel => {},
            }
        }
        return wrote;
    }
};

fn agentThreadFn(allocator: std.mem.Allocator, queues: *AgentQueues) void {
    const config = Config.fromEnv(allocator);
    var agent = AgentThread.init(allocator, queues, config);
    defer agent.deinit();
    agent.run();
}
