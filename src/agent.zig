// agent.zig - LLM agent thread for zish
// Runs in background, communicates via lock-free queues.
// Supports Anthropic API, Ollama, and any OpenAI-compatible endpoint.

const std = @import("std");
const q = @import("agent_queue.zig");
const log_mod = @import("agent_log.zig");

pub const AgentQueues = q.AgentQueues;
pub const SessionLog = log_mod.SessionLog;
pub const AgentConfig = log_mod.AgentConfig;

// ============================================================
// Configuration
// ============================================================

pub const Provider = enum { anthropic, ollama, openai_compat };

pub const Config = struct {
    provider: Provider = .anthropic,
    model: []const u8 = "claude-opus-4-6",
    api_key: []const u8 = "",
    base_url: []const u8 = "https://api.anthropic.com",
    max_tokens: u32 = 8192,
    max_tool_iterations: u32 = 10,

    pub fn fromAgentConfig(ac: log_mod.AgentConfig) Config {
        var cfg = Config{
            .model = ac.model,
            .api_key = ac.api_key,
            .base_url = ac.base_url,
            .max_tokens = ac.max_tokens,
            .max_tool_iterations = ac.max_tool_iterations,
        };

        // determine provider enum from string
        if (std.mem.eql(u8, ac.provider, "ollama")) {
            cfg.provider = .ollama;
        } else if (std.mem.eql(u8, ac.provider, "openai")) {
            cfg.provider = .openai_compat;
        } else {
            cfg.provider = .anthropic;
        }

        // ollama defaults
        if (cfg.provider == .ollama) {
            if (cfg.base_url.len == 0 or std.mem.eql(u8, cfg.base_url, "https://api.anthropic.com")) {
                cfg.base_url = "http://localhost:11434";
            }
            if (std.mem.eql(u8, cfg.model, "claude-opus-4-6")) {
                cfg.model = "llama3.2";
            }
        }

        return cfg;
    }

    pub fn fromEnv(allocator: std.mem.Allocator) Config {
        return Config.fromAgentConfig(log_mod.AgentConfig.load(allocator));
    }

    pub fn providerStr(self: *const Config) []const u8 {
        return switch (self.provider) {
            .anthropic => "anthropic",
            .ollama => "ollama",
            .openai_compat => "openai",
        };
    }
};

// ============================================================
// Conversation history
// ============================================================

const MAX_HISTORY = 20;
const MAX_CONTENT_LEN = 65536;

const Role = enum { user, assistant };
const MsgKindH = enum { text, tool_use_response, tool_result };

const Message = struct {
    role: Role,
    kind: MsgKindH,
    content: []u8, // for text: raw text; for tool_use_response: pre-built JSON content array; for tool_result: pre-built JSON content array
    content_len: usize,
    alloc_len: usize, // actual allocation size for freeing
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
            self.allocator.free(self.messages[i].content[0..self.messages[i].alloc_len]);
        }
    }

    fn add(self: *ConversationHistory, role: Role, content: []const u8) !void {
        return self.addKind(role, .text, content);
    }

    fn addKind(self: *ConversationHistory, role: Role, kind: MsgKindH, content: []const u8) !void {
        if (self.count >= MAX_HISTORY) {
            // drop oldest two (user+assistant pair)
            const n = 2;
            self.allocator.free(self.messages[0].content[0..self.messages[0].alloc_len]);
            self.allocator.free(self.messages[1].content[0..self.messages[1].alloc_len]);
            std.mem.copyForwards(Message, self.messages[0..self.count - n], self.messages[n..self.count]);
            self.count -= n;
        }
        const alloc_size = @max(content.len, 1);
        const buf = try self.allocator.alloc(u8, alloc_size);
        @memcpy(buf[0..content.len], content);
        self.messages[self.count] = .{
            .role = role,
            .kind = kind,
            .content = buf,
            .content_len = content.len,
            .alloc_len = alloc_size,
        };
        self.count += 1;
    }

    fn clear(self: *ConversationHistory) void {
        for (0..self.count) |i| {
            self.allocator.free(self.messages[i].content[0..self.messages[i].alloc_len]);
        }
        self.count = 0;
    }
};

// ============================================================
// Tool definitions
// ============================================================

const SYSTEM_PROMPT_PREFIX =
    \\You are a shell assistant inside zish. Be concise.
    \\When modifying files, explain briefly what and why.
    \\Do NOT run destructive commands (rm -rf, git push --force, DROP TABLE, etc.) without warning the user.
    \\Prefer Read/Glob/Grep tools over Bash for file operations — they are faster and safer.
    \\
;

const TOOLS_JSON =
    \\[
    \\{"name":"Bash","description":"Run a shell command","input_schema":{"type":"object","properties":{"command":{"type":"string","description":"Shell command to run"},"description":{"type":"string","description":"What this command does"}},"required":["command"]}},
    \\{"name":"Read","description":"Read a file's contents","input_schema":{"type":"object","properties":{"file_path":{"type":"string","description":"Absolute path to the file"}},"required":["file_path"]}},
    \\{"name":"Write","description":"Write content to a file (creates or overwrites)","input_schema":{"type":"object","properties":{"file_path":{"type":"string","description":"Absolute path"},"content":{"type":"string","description":"File content to write"}},"required":["file_path","content"]}},
    \\{"name":"Glob","description":"Find files matching a glob pattern","input_schema":{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern (e.g. **/*.zig, src/*.rs)"},"path":{"type":"string","description":"Directory to search in (default: cwd)"}},"required":["pattern"]}},
    \\{"name":"Grep","description":"Search file contents with regex","input_schema":{"type":"object","properties":{"pattern":{"type":"string","description":"Regex pattern to search for"},"path":{"type":"string","description":"File or directory to search"},"glob":{"type":"string","description":"Filter files by glob (e.g. *.zig)"}},"required":["pattern"]}}
    \\]
;

// ============================================================
// HTTP + SSE streaming
// ============================================================

fn getGitBranch(buf: []u8) ![]const u8 {
    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &[_][]const u8{ "git", "rev-parse", "--abbrev-ref", "HEAD" },
        .max_output_bytes = 256,
    }) catch return error.GitFailed;
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);
    const trimmed = std.mem.trimRight(u8, result.stdout, "\n\r ");
    if (trimmed.len == 0) return error.GitFailed;
    const n = @min(trimmed.len, buf.len);
    @memcpy(buf[0..n], trimmed[0..n]);
    return buf[0..n];
}

const AgentThread = struct {
    allocator: std.mem.Allocator,
    queues: *AgentQueues,
    config: Config,
    history: ConversationHistory,
    session_log: ?SessionLog,
    cwd: [256]u8,
    cwd_len: u16,
    git_branch: [64]u8,
    git_branch_len: u8,
    system_prompt_buf: [2048]u8,
    system_prompt_len: u16,

    fn init(allocator: std.mem.Allocator, queues: *AgentQueues, config: Config) AgentThread {
        var self = AgentThread{
            .allocator = allocator,
            .queues = queues,
            .config = config,
            .history = ConversationHistory.init(allocator),
            .session_log = undefined,
            .cwd = undefined,
            .cwd_len = 0,
            .git_branch = undefined,
            .git_branch_len = 0,
            .system_prompt_buf = undefined,
            .system_prompt_len = 0,
        };

        // get cwd
        const cwd = std.process.getCwd(&self.cwd) catch "/";
        self.cwd_len = @intCast(cwd.len);

        // get git branch
        const branch = getGitBranch(&self.git_branch) catch "unknown";
        self.git_branch_len = @intCast(branch.len);

        // build system prompt with context
        self.buildSystemPrompt();

        // create session log
        self.session_log = SessionLog.create(allocator, self.cwdSlice(), self.branchSlice(), config.providerStr(), config.model) catch null;

        return self;
    }

    fn cwdSlice(self: *const AgentThread) []const u8 {
        return self.cwd[0..self.cwd_len];
    }

    fn branchSlice(self: *const AgentThread) []const u8 {
        return self.git_branch[0..self.git_branch_len];
    }

    fn buildSystemPrompt(self: *AgentThread) void {
        var fbs = std.io.fixedBufferStream(&self.system_prompt_buf);
        const w = fbs.writer();
        w.writeAll(SYSTEM_PROMPT_PREFIX) catch return;
        w.print("\\nWorking directory: {s}\\n", .{self.cwdSlice()}) catch return;
        w.print("Git branch: {s}\\n", .{self.branchSlice()}) catch return;

        // try to list top-level files for project context
        if (std.fs.cwd().openDir(self.cwdSlice(), .{ .iterate = true })) |dir_handle| {
            var dir = dir_handle;
            defer dir.close();
            w.writeAll("\\nProject files: ") catch return;
            var count: usize = 0;
            var iter = dir.iterate();
            while (iter.next() catch null) |entry| {
                if (count > 0) w.writeAll(", ") catch return;
                w.writeAll(entry.name) catch return;
                count += 1;
                if (count >= 20) {
                    w.writeAll(", ...") catch return;
                    break;
                }
            }
            w.writeAll("\\n") catch return;
        } else |_| {}

        self.system_prompt_len = @intCast(fbs.pos);
    }

    fn systemPrompt(self: *const AgentThread) []const u8 {
        return self.system_prompt_buf[0..self.system_prompt_len];
    }

    fn deinit(self: *AgentThread) void {
        if (self.session_log) |*sl| sl.close();
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
                if (self.session_log) |*sl| sl.logError(msg) catch {};
            };

            self.queues.setBusy(false);
            _ = self.queues.output.push(.done, "");
        }
    }

    fn processQuery(self: *AgentThread, query: []const u8) !void {
        // add user message to history
        try self.history.add(.user, query);
        if (self.session_log) |*sl| sl.logUser(query) catch {};

        // tool loop: keep calling API until no more tool_use
        var iteration: usize = 0;
        const max_iter = self.config.max_tool_iterations;
        while (iteration < max_iter) : (iteration += 1) {
            if (self.queues.checkCancel()) return;

            const response = try self.callAPI();
            defer self.allocator.free(response.text_alloc);

            if (!response.has_tool_call) {
                // plain text response — add to history and done
                if (response.text.len > 0) {
                    try self.history.add(.assistant, response.text);
                    if (self.session_log) |*sl| sl.logAssistant(response.text) catch {};
                }
                break;
            }

            // tool use response — build proper assistant content with tool_use block
            const tool_name = response.tool_name;
            const tool_input = response.tool_command;
            const tool_id = response.tool_use_id;

            // Build assistant message with content blocks: [text (if any), tool_use]
            var assist_buf: [MAX_CONTENT_LEN]u8 = undefined;
            var assist_fbs = std.io.fixedBufferStream(&assist_buf);
            const aw = assist_fbs.writer();
            aw.writeByte('[') catch {};
            if (response.text.len > 0) {
                aw.writeAll("{\"type\":\"text\",\"text\":") catch {};
                writeJSONString(aw, response.text) catch {};
                aw.writeAll("},") catch {};
                if (self.session_log) |*sl| sl.logAssistant(response.text) catch {};
            }
            aw.print("{{\"type\":\"tool_use\",\"id\":\"{s}\",\"name\":\"{s}\",\"input\":{s}}}", .{
                tool_id, tool_name, tool_input,
            }) catch {};
            aw.writeByte(']') catch {};
            try self.history.addKind(.assistant, .tool_use_response, assist_buf[0..assist_fbs.pos]);

            // Notify user about tool call
            var notify_buf: [256]u8 = undefined;
            const notify = std.fmt.bufPrint(&notify_buf, "Tool: {s}", .{tool_name}) catch "Tool call";
            _ = self.queues.output.push(.tool_call, notify);

            if (self.session_log) |*sl| sl.logToolCall(tool_name, tool_input) catch {};

            // dispatch tool
            if (self.queues.checkCancel()) return;
            const tool_output = self.dispatchTool(tool_name, tool_input) catch |err| blk: {
                var errbuf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&errbuf, "tool error: {}", .{err}) catch "tool error";
                break :blk try self.allocator.dupe(u8, msg);
            };
            defer self.allocator.free(tool_output);

            if (self.session_log) |*sl| sl.logToolResult(tool_name, tool_output, 0) catch {};

            // Build tool_result user message
            var result_json_buf = try self.allocator.alloc(u8, tool_output.len + 256);
            defer self.allocator.free(result_json_buf);
            var result_fbs = std.io.fixedBufferStream(result_json_buf);
            const rw = result_fbs.writer();
            rw.print("[{{\"type\":\"tool_result\",\"tool_use_id\":\"{s}\",\"content\":", .{tool_id}) catch {};
            writeJSONString(rw, tool_output) catch {};
            rw.writeAll("}]") catch {};
            try self.history.addKind(.user, .tool_result, result_json_buf[0..result_fbs.pos]);
        }

        if (self.session_log) |*sl| sl.logDone() catch {};
    }

    fn dispatchTool(self: *AgentThread, tool_name: []const u8, tool_input: []const u8) ![]u8 {
        if (std.mem.eql(u8, tool_name, "Bash")) {
            const cmd = extractJsonField(tool_input, "command") orelse return error.MissingCommand;
            return self.executeBash(cmd);
        }
        if (std.mem.eql(u8, tool_name, "Read")) {
            const path = extractJsonField(tool_input, "file_path") orelse return error.MissingPath;
            return self.executeRead(path);
        }
        if (std.mem.eql(u8, tool_name, "Write")) {
            const path = extractJsonField(tool_input, "file_path") orelse return error.MissingPath;
            const content = extractJsonField(tool_input, "content") orelse return error.MissingContent;
            return self.executeWrite(path, content);
        }
        if (std.mem.eql(u8, tool_name, "Glob")) {
            const pattern = extractJsonField(tool_input, "pattern") orelse return error.MissingPattern;
            const path = extractJsonField(tool_input, "path");
            return self.executeGlob(pattern, path);
        }
        if (std.mem.eql(u8, tool_name, "Grep")) {
            const pattern = extractJsonField(tool_input, "pattern") orelse return error.MissingPattern;
            const path = extractJsonField(tool_input, "path");
            const file_glob = extractJsonField(tool_input, "glob");
            return self.executeGrep(pattern, path, file_glob);
        }
        return error.UnknownTool;
    }

    /// Extract a field value from tool input JSON, unescaping JSON strings
    fn extractJsonField(json: []const u8, key: []const u8) ?[]const u8 {
        return jsonGetStr(json, key);
    }

    const APIResponse = struct {
        text: []u8,           // sub-slice of text_alloc (the actual content)
        text_alloc: []u8,     // full allocation — caller must free this
        has_tool_call: bool,
        tool_command: []const u8, // raw JSON input for the tool
        tool_name: []const u8,
        tool_use_id: []const u8, // Anthropic tool_use block id
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
            switch (msg.kind) {
                .text => {
                    try w.print("{{\"role\":\"{s}\",\"content\":", .{role_str});
                    try writeJSONString(w, content);
                    try w.writeByte('}');
                },
                .tool_use_response, .tool_result => {
                    // content is pre-built JSON content array
                    try w.print("{{\"role\":\"{s}\",\"content\":{s}}}", .{ role_str, content });
                },
            }
        }
        try w.writeByte(']');
        return buf[0..fbs.pos];
    }

    fn callAnthropic(self: *AgentThread) !APIResponse {
        // Build request body with proper JSON escaping
        var body_buf: [MAX_CONTENT_LEN * 4]u8 = undefined;
        var msg_buf: [MAX_CONTENT_LEN * 3]u8 = undefined;
        const messages_json = try self.buildMessagesJSON(&msg_buf);

        var fbs = std.io.fixedBufferStream(&body_buf);
        const w = fbs.writer();
        w.print("{{\"model\":\"{s}\",\"max_tokens\":{d},\"stream\":true,\"system\":", .{
            self.config.model,
            self.config.max_tokens,
        }) catch return error.BodyTooLarge;
        writeJSONString(w, self.systemPrompt()) catch return error.BodyTooLarge;
        w.print(",\"messages\":{s},\"tools\":{s}}}", .{
            messages_json,
            TOOLS_JSON,
        }) catch return error.BodyTooLarge;

        const body = body_buf[0..fbs.pos];

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
        var tool_id_buf: [64]u8 = undefined;
        var tool_id_len: usize = 0;
        var has_tool_call = false;

        // Build curl command with headers
        var argv_buf: [30][]const u8 = undefined;
        var argc: usize = 0;

        argv_buf[argc] = "curl";
        argc += 1;
        argv_buf[argc] = "-sS"; // silent but show errors
        argc += 1;
        argv_buf[argc] = "-N"; // no-buffer (for streaming)
        argc += 1;
        argv_buf[argc] = "--max-time";
        argc += 1;
        argv_buf[argc] = "120";
        argc += 1;
        argv_buf[argc] = "-X";
        argc += 1;
        argv_buf[argc] = "POST";
        argc += 1;
        argv_buf[argc] = "-H";
        argc += 1;
        argv_buf[argc] = "Content-Type: application/json";
        argc += 1;

        // Provider-specific headers
        var header_bufs: [7][512]u8 = undefined;
        var hdr_idx: usize = 0;

        switch (provider) {
            .anthropic => {
                // API key
                const h0 = std.fmt.bufPrint(&header_bufs[hdr_idx], "x-api-key: {s}", .{self.config.api_key}) catch "";
                argv_buf[argc] = "-H";
                argc += 1;
                argv_buf[argc] = h0;
                argc += 1;
                hdr_idx += 1;

                argv_buf[argc] = "-H";
                argc += 1;
                argv_buf[argc] = "anthropic-version: 2023-06-01";
                argc += 1;

                // Claude Code identification headers
                argv_buf[argc] = "-H";
                argc += 1;
                argv_buf[argc] = "User-Agent: Anthropic/JS 0.74.0";
                argc += 1;
                argv_buf[argc] = "-H";
                argc += 1;
                argv_buf[argc] = "x-service-name: claude-code";
                argc += 1;
            },
            .ollama, .openai_compat => {
                if (self.config.api_key.len > 0) {
                    const h0 = std.fmt.bufPrint(&header_bufs[hdr_idx], "Authorization: Bearer {s}", .{self.config.api_key}) catch "";
                    argv_buf[argc] = "-H";
                    argc += 1;
                    argv_buf[argc] = h0;
                    argc += 1;
                    hdr_idx += 1;
                }
            },
        }

        // URL and body via stdin
        argv_buf[argc] = "-d";
        argc += 1;
        argv_buf[argc] = "@-"; // read body from stdin
        argc += 1;
        argv_buf[argc] = url;
        argc += 1;

        // Spawn curl process
        var child = std.process.Child.init(argv_buf[0..argc], self.allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.spawn() catch return error.CurlFailed;
        errdefer _ = child.wait() catch {};

        // Write body to curl stdin
        if (child.stdin) |*stdin_pipe| {
            stdin_pipe.writeAll(body) catch {};
            stdin_pipe.close();
            child.stdin = null;
        }

        // Read streaming SSE output from curl stdout
        const stdout_file = child.stdout.?;
        var sse_buf: [16384]u8 = undefined;
        var sse_pos: usize = 0;

        outer: while (true) {
            if (self.queues.checkCancel()) {
                _ = child.kill() catch {};
                _ = child.wait() catch {};
                self.allocator.free(text_buf);
                return error.Cancelled;
            }

            const n = stdout_file.read(sse_buf[sse_pos..]) catch break;
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
                            &tool_id_buf, &tool_id_len,
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

        // Check for curl errors
        if (child.stderr) |*stderr_pipe| {
            var err_out: [1024]u8 = undefined;
            const err_n = stderr_pipe.read(&err_out) catch 0;
            if (err_n > 0) {
                _ = self.queues.output.push(.error_msg, err_out[0..err_n]);
            }
        }

        _ = child.wait() catch {};

        // If no text was received but no tool call, check if response was an error
        if (text_len == 0 and !has_tool_call) {
            // The response might have been a non-streaming error JSON
            if (sse_pos > 0) {
                const remaining = sse_buf[0..sse_pos];
                if (std.mem.indexOf(u8, remaining, "\"error\"")) |_| {
                    _ = self.queues.output.push(.error_msg, remaining);
                    self.allocator.free(text_buf);
                    return error.HTTPError;
                }
            }
        }

        return APIResponse{
            .text = text_buf[0..text_len],
            .text_alloc = text_buf,
            .has_tool_call = has_tool_call,
            .tool_command = tool_cmd_buf[0..tool_cmd_len],
            .tool_name = tool_name_buf[0..tool_name_len],
            .tool_use_id = tool_id_buf[0..tool_id_len],
        };
    }

    fn executeBash(self: *AgentThread, command: []const u8) ![]u8 {
        // unescape JSON string escapes in the command
        var cmd_buf: [8192]u8 = undefined;
        const cmd = unescapeJSON(command, &cmd_buf) orelse command;

        // notify main thread
        var notif_buf: [512]u8 = undefined;
        const notif = std.fmt.bufPrint(&notif_buf, "$ {s}", .{cmd}) catch cmd;
        _ = self.queues.output.push(.tool_call, notif);

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "/bin/sh", "-c", cmd },
            .max_output_bytes = 65536,
        }) catch |err| {
            var errbuf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&errbuf, "exec failed: {}", .{err}) catch "exec failed";
            return self.allocator.dupe(u8, msg);
        };
        defer self.allocator.free(result.stderr);

        _ = self.queues.output.push(.tool_done, result.stdout);
        return result.stdout;
    }

    fn executeRead(self: *AgentThread, path: []const u8) ![]u8 {
        var path_buf: [512]u8 = undefined;
        const real_path = unescapeJSON(path, &path_buf) orelse path;

        var notif_buf: [512]u8 = undefined;
        const notif = std.fmt.bufPrint(&notif_buf, "Read {s}", .{real_path}) catch real_path;
        _ = self.queues.output.push(.tool_call, notif);

        const content = std.fs.cwd().readFileAlloc(self.allocator, real_path, 512 * 1024) catch |err| {
            var errbuf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&errbuf, "read error: {s}: {}", .{ real_path, err }) catch "read error";
            return self.allocator.dupe(u8, msg);
        };
        return content;
    }

    fn executeWrite(self: *AgentThread, path: []const u8, content: []const u8) ![]u8 {
        var path_buf: [512]u8 = undefined;
        const real_path = unescapeJSON(path, &path_buf) orelse path;

        // unescape content
        const content_buf = try self.allocator.alloc(u8, content.len);
        defer self.allocator.free(content_buf);
        const real_content = unescapeJSON(content, content_buf) orelse content;

        var notif_buf: [512]u8 = undefined;
        const notif = std.fmt.bufPrint(&notif_buf, "Write {s} ({d} bytes)", .{ real_path, real_content.len }) catch real_path;
        _ = self.queues.output.push(.tool_call, notif);

        // backup existing file before overwriting
        if (self.session_log) |*sl| sl.backupFile(real_path) catch {};

        const file = std.fs.cwd().createFile(real_path, .{}) catch |err| {
            var errbuf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&errbuf, "write error: {s}: {}", .{ real_path, err }) catch "write error";
            return self.allocator.dupe(u8, msg);
        };
        defer file.close();
        file.writeAll(real_content) catch |err| {
            var errbuf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&errbuf, "write error: {}", .{err}) catch "write error";
            return self.allocator.dupe(u8, msg);
        };

        var result_buf: [128]u8 = undefined;
        const result = std.fmt.bufPrint(&result_buf, "Wrote {d} bytes to {s}", .{ real_content.len, real_path }) catch "ok";
        return self.allocator.dupe(u8, result);
    }

    fn executeGlob(self: *AgentThread, pattern: []const u8, search_path: ?[]const u8) ![]u8 {
        var pattern_buf: [256]u8 = undefined;
        const real_pattern = unescapeJSON(pattern, &pattern_buf) orelse pattern;

        var notif_buf: [512]u8 = undefined;
        if (search_path) |p| {
            const notif = std.fmt.bufPrint(&notif_buf, "Glob {s} in {s}", .{ real_pattern, p }) catch real_pattern;
            _ = self.queues.output.push(.tool_call, notif);
        } else {
            const notif = std.fmt.bufPrint(&notif_buf, "Glob {s}", .{real_pattern}) catch real_pattern;
            _ = self.queues.output.push(.tool_call, notif);
        }

        // use find command as backend (simple, works everywhere)
        var cmd_buf: [1024]u8 = undefined;
        const dir = if (search_path) |p| blk: {
            var p_buf: [256]u8 = undefined;
            break :blk unescapeJSON(p, &p_buf) orelse p;
        } else ".";
        const cmd = std.fmt.bufPrint(&cmd_buf, "find {s} -name '{s}' -type f 2>/dev/null | head -100 | sort", .{ dir, real_pattern }) catch return error.PatternTooLong;

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "/bin/sh", "-c", cmd },
            .max_output_bytes = 65536,
        }) catch |err| {
            var errbuf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&errbuf, "glob error: {}", .{err}) catch "glob error";
            return self.allocator.dupe(u8, msg);
        };
        defer self.allocator.free(result.stderr);
        return result.stdout;
    }

    fn executeGrep(self: *AgentThread, pattern: []const u8, search_path: ?[]const u8, file_glob: ?[]const u8) ![]u8 {
        var pattern_buf: [256]u8 = undefined;
        const real_pattern = unescapeJSON(pattern, &pattern_buf) orelse pattern;

        var notif_buf: [512]u8 = undefined;
        const notif = std.fmt.bufPrint(&notif_buf, "Grep '{s}'", .{real_pattern}) catch real_pattern;
        _ = self.queues.output.push(.tool_call, notif);

        // build grep/rg command
        var cmd_buf: [1024]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&cmd_buf);
        const w = fbs.writer();
        w.writeAll("grep -rn --include='*'") catch return error.CmdTooLong;
        if (file_glob) |g| {
            var g_buf: [128]u8 = undefined;
            const real_g = unescapeJSON(g, &g_buf) orelse g;
            w.print(" --include='{s}'", .{real_g}) catch {};
        }
        w.writeAll(" -- ") catch {};
        // escape pattern for shell
        w.writeByte('\'') catch {};
        for (real_pattern) |c| {
            if (c == '\'') {
                w.writeAll("'\\''") catch {};
            } else {
                w.writeByte(c) catch {};
            }
        }
        w.writeByte('\'') catch {};

        if (search_path) |p| {
            var p_buf: [256]u8 = undefined;
            const real_p = unescapeJSON(p, &p_buf) orelse p;
            w.print(" {s}", .{real_p}) catch {};
        } else {
            w.writeAll(" .") catch {};
        }
        w.writeAll(" 2>/dev/null | head -100") catch {};

        const cmd = cmd_buf[0..fbs.pos];

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "/bin/sh", "-c", cmd },
            .max_output_bytes = 65536,
        }) catch |err| {
            var errbuf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&errbuf, "grep error: {}", .{err}) catch "grep error";
            return self.allocator.dupe(u8, msg);
        };
        defer self.allocator.free(result.stderr);
        return result.stdout;
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
    tool_id_buf: *[64]u8,
    tool_id_len: *usize,
    has_tool_call: *bool,
    queues: *AgentQueues,
) void {
    // Extract "type" field
    const type_val = jsonGetStr(data, "type") orelse return;

    if (std.mem.eql(u8, type_val, "content_block_start")) {
        if (std.mem.indexOf(u8, data, "\"tool_use\"") != null) {
            has_tool_call.* = true;
            // extract tool name
            if (jsonGetStr(data, "name")) |name| {
                const n = @min(name.len, 64);
                @memcpy(tool_name_buf[0..n], name[0..n]);
                tool_name_len.* = n;
            }
            // extract tool_use id
            if (jsonGetStr(data, "id")) |id| {
                const n = @min(id.len, 64);
                @memcpy(tool_id_buf[0..n], id[0..n]);
                tool_id_len.* = n;
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
                // partial_json is a JSON string value — unescape it to get raw JSON fragment
                var unescape_buf: [4096]u8 = undefined;
                const unescaped = unescapeJSON(chunk, &unescape_buf) orelse chunk;
                const n = @min(unescaped.len, 4096 - tool_cmd_len.*);
                @memcpy(tool_cmd_buf[tool_cmd_len.*..][0..n], unescaped[0..n]);
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
        // auto-start agent thread if not running (e.g. in -c mode)
        if (self.thread == null) self.start() catch return false;
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
