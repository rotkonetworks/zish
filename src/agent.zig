// agent.zig - LLM agent thread for zish
// Runs in background, communicates via lock-free queues.
// Supports Anthropic API, Ollama, and any OpenAI-compatible endpoint.

const std = @import("std");
const q = @import("agent_queue.zig");
const log_mod = @import("agent_log.zig");
const router_mod = @import("agent_router.zig");

pub const AgentQueues = q.AgentQueues;
pub const SessionLog = log_mod.SessionLog;
pub const AgentConfig = log_mod.AgentConfig;

// ============================================================
// Configuration
// ============================================================

pub const Provider = enum { anthropic, ollama, openai_compat };

pub const Config = struct {
    provider: Provider = .anthropic,
    model: []const u8 = "claude-sonnet-4-6",
    api_key: []const u8 = "",
    base_url: []const u8 = "https://api.anthropic.com",
    max_tokens: u32 = 8192,
    max_tool_iterations: u32 = 10,
    auto_allow: bool = false,

    pub fn fromAgentConfig(ac: log_mod.AgentConfig) Config {
        var cfg = Config{
            .model = ac.model,
            .api_key = ac.api_key,
            .base_url = ac.base_url,
            .max_tokens = ac.max_tokens,
            .max_tool_iterations = ac.max_tool_iterations,
            .auto_allow = ac.auto_allow,
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
            if (std.mem.eql(u8, cfg.model, "claude-sonnet-4-6")) {
                cfg.model = "llama3.2";
            }
        }

        return cfg;
    }

    pub fn buildRouterConfig(ac: log_mod.AgentConfig) router_mod.RouterConfig {
        var rc = router_mod.RouterConfig.init();
        rc.enabled = ac.router_enabled;
        rc.api_enabled = !ac.router_local_only; // local_only disables API calls to router model
        if (ac.router_model.len > 0) {
            router_mod.RouterConfig.setField(&rc.model, &rc.model_len, ac.router_model);
        }
        if (ac.router_base_url.len > 0) {
            const n = @min(ac.router_base_url.len, 256);
            @memcpy(rc.base_url[0..n], ac.router_base_url[0..n]);
            rc.base_url_len = @intCast(n);
        }
        // Provider
        if (ac.router_provider.len > 0) {
            if (std.mem.eql(u8, ac.router_provider, "ollama")) {
                rc.provider = .ollama;
            } else if (std.mem.eql(u8, ac.router_provider, "openai")) {
                rc.provider = .openai_compat;
            } else {
                rc.provider = .anthropic;
            }
        }
        // Model tier names
        if (ac.haiku_model.len > 0) router_mod.RouterConfig.setField(&rc.haiku_model, &rc.haiku_len, ac.haiku_model);
        if (ac.sonnet_model.len > 0) router_mod.RouterConfig.setField(&rc.sonnet_model, &rc.sonnet_len, ac.sonnet_model);
        if (ac.opus_model.len > 0) router_mod.RouterConfig.setField(&rc.opus_model, &rc.opus_len, ac.opus_model);
        // Local GGUF model path for pure-Zig inference
        if (ac.router_local_model.len > 0) {
            router_mod.RouterConfig.setFieldLong(&rc.local_model_path, &rc.local_model_len, ac.router_local_model);
        }
        return rc;
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
// Plugin tools — loaded from ~/.zish/agent-tools.json
// ============================================================

const MAX_PLUGIN_TOOLS = 16;
const MAX_PLUGIN_PARAMS = 8;

const PluginParam = struct {
    name_buf: [64]u8 = undefined,
    name_len: u8 = 0,
    type_buf: [16]u8 = undefined,
    type_len: u8 = 0,
    desc_buf: [256]u8 = undefined,
    desc_len: u16 = 0,

    fn name(self: *const PluginParam) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    fn desc(self: *const PluginParam) []const u8 {
        return self.desc_buf[0..self.desc_len];
    }
    fn paramType(self: *const PluginParam) []const u8 {
        if (self.type_len == 0) return "string";
        return self.type_buf[0..self.type_len];
    }
};

const PluginTool = struct {
    name_buf: [64]u8 = undefined,
    name_len: u8 = 0,
    desc_buf: [512]u8 = undefined,
    desc_len: u16 = 0,
    cmd_buf: [512]u8 = undefined,
    cmd_len: u16 = 0,
    confirm: bool = false,
    params: [MAX_PLUGIN_PARAMS]PluginParam = [_]PluginParam{.{}} ** MAX_PLUGIN_PARAMS,
    param_count: u8 = 0,
    required_mask: u8 = 0, // bitmask of required params

    fn name(self: *const PluginTool) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    fn desc(self: *const PluginTool) []const u8 {
        return self.desc_buf[0..self.desc_len];
    }
    fn command(self: *const PluginTool) []const u8 {
        return self.cmd_buf[0..self.cmd_len];
    }
};

/// Load plugin tools from ~/.zish/agent-tools.json
/// Format: [{"name":"...", "description":"...", "command":"...", "confirm":true,
///           "parameters":{"param":{"type":"string","description":"..."}},
///           "required":["param"]}]
fn loadPluginTools(tools: *[MAX_PLUGIN_TOOLS]PluginTool) u8 {
    const home = std.process.getEnvVarOwned(std.heap.page_allocator, "HOME") catch return 0;
    defer std.heap.page_allocator.free(home);
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.zish/agent-tools.json", .{home}) catch return 0;
    const content = std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, 32768) catch return 0;
    defer std.heap.page_allocator.free(content);

    var count: u8 = 0;

    // Simple JSON array parser: find each top-level object { ... }
    var depth: i32 = 0;
    var obj_start: ?usize = null;
    var in_string = false;
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        if (content[i] == '\\' and in_string) {
            i += 1; // skip escaped char
            continue;
        }
        if (content[i] == '"') {
            in_string = !in_string;
            continue;
        }
        if (in_string) continue;

        if (content[i] == '{') {
            depth += 1;
            if (depth == 1 and obj_start == null) obj_start = i;
        } else if (content[i] == '}') {
            depth -= 1;
            if (depth == 0) {
                if (obj_start) |start| {
                    if (count < MAX_PLUGIN_TOOLS) {
                        parsePluginTool(content[start .. i + 1], &tools[count]);
                        if (tools[count].name_len > 0) count += 1;
                    }
                    obj_start = null;
                }
            }
        }
    }
    return count;
}

fn parsePluginTool(json: []const u8, tool: *PluginTool) void {
    // Extract simple fields
    if (jsonGetStr(json, "name")) |v| {
        const n = @min(v.len, 64);
        @memcpy(tool.name_buf[0..n], v[0..n]);
        tool.name_len = @intCast(n);
    }
    if (jsonGetStr(json, "description")) |v| {
        const n = @min(v.len, 512);
        @memcpy(tool.desc_buf[0..n], v[0..n]);
        tool.desc_len = @intCast(n);
    }
    if (jsonGetStr(json, "command")) |v| {
        const n = @min(v.len, 512);
        @memcpy(tool.cmd_buf[0..n], v[0..n]);
        tool.cmd_len = @intCast(n);
    }
    // Check "confirm":true
    if (std.mem.indexOf(u8, json, "\"confirm\"")) |idx| {
        const after = json[@min(idx + 9, json.len)..];
        const trimmed = std.mem.trimLeft(u8, after, " \t\n\r:");
        tool.confirm = std.mem.startsWith(u8, trimmed, "true");
    }

    // Parse parameters object: "parameters": { "name": {"type":"...", "description":"..."}, ... }
    if (std.mem.indexOf(u8, json, "\"parameters\"")) |param_idx| {
        const after_key = json[@min(param_idx + 12, json.len)..];
        const trimmed = std.mem.trimLeft(u8, after_key, " \t\n\r:");
        if (trimmed.len > 0 and trimmed[0] == '{') {
            // Find matching closing brace
            var pdepth: i32 = 0;
            var pi: usize = 0;
            var pin_string = false;
            while (pi < trimmed.len) : (pi += 1) {
                if (trimmed[pi] == '\\' and pin_string) {
                    pi += 1;
                    continue;
                }
                if (trimmed[pi] == '"') {
                    pin_string = !pin_string;
                    continue;
                }
                if (pin_string) continue;
                if (trimmed[pi] == '{') pdepth += 1;
                if (trimmed[pi] == '}') {
                    pdepth -= 1;
                    if (pdepth == 0) break;
                }
            }
            if (pdepth == 0) {
                parsePluginParams(trimmed[1..pi], tool);
            }
        }
    }

    // Parse required array
    if (std.mem.indexOf(u8, json, "\"required\"")) |req_idx| {
        const after_key = json[@min(req_idx + 10, json.len)..];
        const trimmed = std.mem.trimLeft(u8, after_key, " \t\n\r:");
        if (trimmed.len > 0 and trimmed[0] == '[') {
            const end = std.mem.indexOfScalar(u8, trimmed, ']') orelse trimmed.len;
            const arr = trimmed[1..end];
            // Find each quoted string and match against param names
            var si: usize = 0;
            while (si < arr.len) : (si += 1) {
                if (arr[si] == '"') {
                    const str_end = std.mem.indexOfScalarPos(u8, arr, si + 1, '"') orelse break;
                    const req_name = arr[si + 1 .. str_end];
                    // mark matching param as required
                    for (0..tool.param_count) |pi| {
                        if (std.mem.eql(u8, tool.params[pi].name(), req_name)) {
                            tool.required_mask |= @as(u8, 1) << @intCast(pi);
                        }
                    }
                    si = str_end;
                }
            }
        }
    }
}

fn parsePluginParams(params_json: []const u8, tool: *PluginTool) void {
    // Parse: "name": {"type":"...", "description":"..."}, "name2": ...
    var pos: usize = 0;
    while (pos < params_json.len and tool.param_count < MAX_PLUGIN_PARAMS) {
        // Find next quoted key
        const key_start = std.mem.indexOfScalarPos(u8, params_json, pos, '"') orelse break;
        const key_end = std.mem.indexOfScalarPos(u8, params_json, key_start + 1, '"') orelse break;
        const param_name = params_json[key_start + 1 .. key_end];

        // Find the value object { ... }
        const obj_start = std.mem.indexOfScalarPos(u8, params_json, key_end + 1, '{') orelse break;
        var depth: i32 = 0;
        var oi: usize = obj_start;
        var oin_string = false;
        while (oi < params_json.len) : (oi += 1) {
            if (params_json[oi] == '\\' and oin_string) {
                oi += 1;
                continue;
            }
            if (params_json[oi] == '"') {
                oin_string = !oin_string;
                continue;
            }
            if (oin_string) continue;
            if (params_json[oi] == '{') depth += 1;
            if (params_json[oi] == '}') {
                depth -= 1;
                if (depth == 0) break;
            }
        }

        const pi = tool.param_count;
        const n = @min(param_name.len, 64);
        @memcpy(tool.params[pi].name_buf[0..n], param_name[0..n]);
        tool.params[pi].name_len = @intCast(n);

        const obj = params_json[obj_start .. oi + 1];
        if (jsonGetStr(obj, "type")) |t| {
            const tn = @min(t.len, 16);
            @memcpy(tool.params[pi].type_buf[0..tn], t[0..tn]);
            tool.params[pi].type_len = @intCast(tn);
        }
        if (jsonGetStr(obj, "description")) |d| {
            const dn = @min(d.len, 256);
            @memcpy(tool.params[pi].desc_buf[0..dn], d[0..dn]);
            tool.params[pi].desc_len = @intCast(dn);
        }

        tool.param_count += 1;
        pos = oi + 1;
    }
}

/// Build Anthropic tools JSON array including built-in + plugin tools
fn buildToolsJson(plugins: []const PluginTool, count: u8, buf: []u8) u16 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    // Start with built-in tools (strip outer [] from TOOLS_JSON)
    w.writeByte('[') catch return 0;
    // TOOLS_JSON starts with [ and ends with ], skip them
    const inner = std.mem.trim(u8, TOOLS_JSON, " \n\r\t");
    if (inner.len > 2) {
        w.writeAll(inner[1 .. inner.len - 1]) catch return 0;
    }

    // Append plugin tools
    for (plugins[0..count]) |*pt| {
        w.writeAll(",{\"name\":\"") catch return 0;
        w.writeAll(pt.name()) catch return 0;
        w.writeAll("\",\"description\":\"") catch return 0;
        // escape description for JSON
        for (pt.desc()) |c| {
            switch (c) {
                '"' => w.writeAll("\\\"") catch return 0,
                '\\' => w.writeAll("\\\\") catch return 0,
                '\n' => w.writeAll("\\n") catch return 0,
                else => w.writeByte(c) catch return 0,
            }
        }
        w.writeAll("\",\"input_schema\":{\"type\":\"object\",\"properties\":{") catch return 0;

        for (0..pt.param_count) |pi| {
            if (pi > 0) w.writeByte(',') catch return 0;
            w.writeByte('"') catch return 0;
            w.writeAll(pt.params[pi].name()) catch return 0;
            w.writeAll("\":{\"type\":\"") catch return 0;
            w.writeAll(pt.params[pi].paramType()) catch return 0;
            w.writeAll("\",\"description\":\"") catch return 0;
            for (pt.params[pi].desc()) |c| {
                switch (c) {
                    '"' => w.writeAll("\\\"") catch return 0,
                    '\\' => w.writeAll("\\\\") catch return 0,
                    '\n' => w.writeAll("\\n") catch return 0,
                    else => w.writeByte(c) catch return 0,
                }
            }
            w.writeAll("\"}") catch return 0;
        }

        w.writeAll("}") catch return 0; // close properties

        // required array
        if (pt.required_mask != 0) {
            w.writeAll(",\"required\":[") catch return 0;
            var first = true;
            for (0..pt.param_count) |pi| {
                if (pt.required_mask & (@as(u8, 1) << @intCast(pi)) != 0) {
                    if (!first) w.writeByte(',') catch return 0;
                    w.writeByte('"') catch return 0;
                    w.writeAll(pt.params[pi].name()) catch return 0;
                    w.writeByte('"') catch return 0;
                    first = false;
                }
            }
            w.writeByte(']') catch return 0;
        }

        w.writeAll("}}") catch return 0; // close input_schema and tool object
    }

    w.writeByte(']') catch return 0;
    return @intCast(fbs.pos);
}

/// Shell-escape a value for safe inclusion in a command
fn shellEscape(value: []const u8, buf: []u8) ?[]const u8 {
    var i: usize = 0;
    if (i >= buf.len) return null;
    buf[i] = '\'';
    i += 1;
    for (value) |c| {
        if (c == '\'') {
            if (i + 4 > buf.len) return null;
            buf[i] = '\'';
            buf[i + 1] = '\\';
            buf[i + 2] = '\'';
            buf[i + 3] = '\'';
            i += 4;
        } else {
            if (i >= buf.len) return null;
            buf[i] = c;
            i += 1;
        }
    }
    if (i >= buf.len) return null;
    buf[i] = '\'';
    i += 1;
    return buf[0..i];
}

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
    \\You are a coding assistant embedded in zish shell. Be concise and direct.
    \\
    \\IMPORTANT RULES:
    \\- Always Read a file before editing it. Use Edit (not Write) to modify existing files.
    \\- Prefer Read/Glob/Grep over Bash for file operations — they are faster and safer.
    \\- Do NOT run destructive commands (rm -rf, git push --force, DROP TABLE) without explicit user approval.
    \\- When writing code, prioritize correctness and simplicity. Don't over-engineer.
    \\- Explain changes briefly. Lead with actions, not explanations.
    \\- For multi-step tasks, proceed autonomously using tools — don't ask permission for each step.
    \\
;

const TOOLS_JSON =
    \\[
    \\{"name":"Bash","description":"Run a shell command. Use for system operations, git, builds, installs.","input_schema":{"type":"object","properties":{"command":{"type":"string","description":"Shell command to run"},"description":{"type":"string","description":"Brief description of what this does"}},"required":["command"]}},
    \\{"name":"Read","description":"Read a file. Always read before editing. Returns file contents with line numbers.","input_schema":{"type":"object","properties":{"file_path":{"type":"string","description":"Absolute path to the file"},"offset":{"type":"integer","description":"Line number to start from (1-based, optional)"},"limit":{"type":"integer","description":"Max lines to read (optional)"}},"required":["file_path"]}},
    \\{"name":"Edit","description":"Make exact string replacements in a file. Must Read the file first. The old_string must appear exactly once in the file (or use replace_all).","input_schema":{"type":"object","properties":{"file_path":{"type":"string","description":"Absolute path to the file"},"old_string":{"type":"string","description":"Exact text to find and replace"},"new_string":{"type":"string","description":"Replacement text"},"replace_all":{"type":"boolean","description":"Replace all occurrences (default: false)"}},"required":["file_path","old_string","new_string"]}},
    \\{"name":"Write","description":"Create a new file or completely overwrite an existing one. For modifying existing files, prefer Edit.","input_schema":{"type":"object","properties":{"file_path":{"type":"string","description":"Absolute path"},"content":{"type":"string","description":"Complete file content"}},"required":["file_path","content"]}},
    \\{"name":"Glob","description":"Find files matching a glob pattern. Returns matching file paths.","input_schema":{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern (e.g. **/*.zig, src/*.rs)"},"path":{"type":"string","description":"Directory to search in (default: cwd)"}},"required":["pattern"]}},
    \\{"name":"Grep","description":"Search file contents with regex. Returns matching lines with file:line format.","input_schema":{"type":"object","properties":{"pattern":{"type":"string","description":"Regex pattern to search for"},"path":{"type":"string","description":"File or directory to search"},"glob":{"type":"string","description":"Filter files by glob (e.g. *.zig)"}},"required":["pattern"]}},
    \\{"name":"Agent","description":"Spawn a subagent to handle a task autonomously in the background. Use for research, exploration, or parallel work. The subagent has Read/Glob/Grep/Bash tools. Launch multiple agents concurrently for independent tasks.","input_schema":{"type":"object","properties":{"prompt":{"type":"string","description":"Detailed task description for the subagent"},"description":{"type":"string","description":"Short 3-5 word summary of the task"}},"required":["prompt","description"]}},
    \\{"name":"WebFetch","description":"Fetch a URL and return its content. HTML is converted to plain text. Use for reading web pages, APIs, documentation.","input_schema":{"type":"object","properties":{"url":{"type":"string","description":"URL to fetch"},"max_bytes":{"type":"integer","description":"Max bytes to return (default: 32768)"}},"required":["url"]}},
    \\{"name":"WebSearch","description":"Search the web using DuckDuckGo. Returns titles, URLs and snippets. Use when you need current information.","input_schema":{"type":"object","properties":{"query":{"type":"string","description":"Search query"},"max_results":{"type":"integer","description":"Max results to return (default: 8)"}},"required":["query"]}}
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

// ============================================================
// SubAgent — lightweight agent thread for parallel tasks
// ============================================================

const MAX_SUBAGENTS = 8;
const SUBAGENT_RESULT_MAX = 32768;

const SubAgentStatus = enum(u8) { running, done, failed };

const SubAgent = struct {
    thread: ?std.Thread = null,
    status: SubAgentStatus = .running,
    // Result buffer — subagent writes here, main agent reads when done
    result_buf: [SUBAGENT_RESULT_MAX]u8 = undefined,
    result_len: u32 = 0,
    // ID and description for tracking
    id_buf: [16]u8 = undefined,
    id_len: u8 = 0,
    desc_buf: [128]u8 = undefined,
    desc_len: u8 = 0,
    // Cancellation
    cancel_requested: bool = false,

    fn id(self: *const SubAgent) []const u8 {
        return self.id_buf[0..self.id_len];
    }

    fn desc(self: *const SubAgent) []const u8 {
        return self.desc_buf[0..self.desc_len];
    }

    fn result(self: *const SubAgent) []const u8 {
        return self.result_buf[0..self.result_len];
    }

    fn requestCancel(self: *SubAgent) void {
        @atomicStore(bool, &self.cancel_requested, true, .release);
    }

    fn checkCancel(self: *SubAgent) bool {
        return @atomicLoad(bool, &self.cancel_requested, .acquire);
    }

    fn isDone(self: *const SubAgent) bool {
        return @atomicLoad(SubAgentStatus, &@constCast(self).status, .acquire) != .running;
    }

    fn setResult(self: *SubAgent, text: []const u8, status: SubAgentStatus) void {
        const n = @min(text.len, SUBAGENT_RESULT_MAX);
        @memcpy(self.result_buf[0..n], text[0..n]);
        self.result_len = @intCast(n);
        @atomicStore(SubAgentStatus, &self.status, status, .release);
    }
};

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
    system_prompt_buf: [8192]u8,
    system_prompt_len: u16,
    // Token usage tracking (cumulative for session)
    total_input_tokens: u32 = 0,
    total_output_tokens: u32 = 0,
    compact_in_progress: bool = false,
    plugin_tools: [MAX_PLUGIN_TOOLS]PluginTool,
    plugin_count: u8,
    all_tools_json: [16384]u8,
    all_tools_json_len: u16,
    // Session-level "always allow" flags
    allow_bash: bool = false,
    allow_edit: bool = false,
    allow_write: bool = false,
    allow_plugins: u16 = 0, // bitmask for plugin tools
    // Router for query classification
    router_config: router_mod.RouterConfig = router_mod.RouterConfig.init(),
    // Subagent pool
    subagents: [MAX_SUBAGENTS]SubAgent = [_]SubAgent{.{}} ** MAX_SUBAGENTS,
    subagent_count: u8 = 0,
    next_subagent_id: u16 = 1,

    fn init(allocator: std.mem.Allocator, queues: *AgentQueues, config: Config, rc: router_mod.RouterConfig) AgentThread {
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
            .plugin_tools = [_]PluginTool{.{}} ** MAX_PLUGIN_TOOLS,
            .plugin_count = 0,
            .all_tools_json = undefined,
            .all_tools_json_len = 0,
            .router_config = rc,
        };

        // get cwd
        const cwd = std.process.getCwd(&self.cwd) catch "/";
        self.cwd_len = @intCast(cwd.len);

        // get git branch
        const branch = getGitBranch(&self.git_branch) catch "unknown";
        self.git_branch_len = @intCast(branch.len);

        // build system prompt with context
        self.buildSystemPrompt();

        // load plugin tools
        self.plugin_count = loadPluginTools(&self.plugin_tools);
        self.all_tools_json_len = buildToolsJson(&self.plugin_tools, self.plugin_count, &self.all_tools_json);

        // auto-allow all tools if configured
        if (config.auto_allow) {
            self.allow_bash = true;
            self.allow_edit = true;
            self.allow_write = true;
            self.allow_plugins = 0xFFFF;
        }

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
        w.print("\nWorking directory: {s}\n", .{self.cwdSlice()}) catch return;
        w.print("Git branch: {s}\n", .{self.branchSlice()}) catch return;

        // try to list top-level files for project context
        if (std.fs.cwd().openDir(self.cwdSlice(), .{ .iterate = true })) |dir_handle| {
            var dir = dir_handle;
            defer dir.close();
            w.writeAll("\nProject files: ") catch return;
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
            w.writeAll("\n") catch return;
        } else |_| {}

        // Load CLAUDE.md project instructions (check cwd, then parent dirs)
        self.loadClaudeMd(w);

        self.system_prompt_len = @intCast(fbs.pos);
    }

    fn loadClaudeMd(self: *AgentThread, w: anytype) void {
        // Try cwd first, then walk up to find project instructions
        // Checks: CLAUDE.md, AGENTS.md, .claude/CLAUDE.md, .claude/AGENTS.md
        var dir_path: [256]u8 = undefined;
        @memcpy(dir_path[0..self.cwd_len], self.cwd[0..self.cwd_len]);
        var path_len = self.cwd_len;

        const filenames = [_]struct { name: []const u8, subdir: []const u8 }{
            .{ .name = "CLAUDE.md", .subdir = "" },
            .{ .name = "AGENTS.md", .subdir = "" },
            .{ .name = "CLAUDE.md", .subdir = ".claude/" },
            .{ .name = "AGENTS.md", .subdir = ".claude/" },
        };

        // Track which files we've loaded to avoid duplicates
        var loaded_claude = false;
        var loaded_agents = false;

        var attempts: u8 = 0;
        while (attempts < 8) : (attempts += 1) {
            for (filenames) |f| {
                const is_agents = std.mem.eql(u8, f.name, "AGENTS.md");
                if (is_agents and loaded_agents) continue;
                if (!is_agents and loaded_claude) continue;

                var file_path: [512]u8 = undefined;
                const fp = std.fmt.bufPrint(&file_path, "{s}/{s}{s}", .{ dir_path[0..path_len], f.subdir, f.name }) catch continue;

                if (std.fs.cwd().readFileAlloc(std.heap.page_allocator, fp, 4096)) |content| {
                    defer std.heap.page_allocator.free(content);
                    w.print("\n# Project Instructions ({s})\n", .{f.name}) catch return;
                    const max = @min(content.len, 3072);
                    w.writeAll(content[0..max]) catch return;
                    w.writeByte('\n') catch return;
                    if (is_agents) loaded_agents = true else loaded_claude = true;
                } else |_| {}
            }

            if (loaded_claude and loaded_agents) break;

            // Walk up to parent directory
            if (std.mem.lastIndexOfScalar(u8, dir_path[0..path_len], '/')) |slash| {
                if (slash == 0) break; // at root
                path_len = @intCast(slash);
            } else break;
        }
    }

    fn systemPrompt(self: *const AgentThread) []const u8 {
        return self.system_prompt_buf[0..self.system_prompt_len];
    }

    fn toolsJson(self: *const AgentThread) []const u8 {
        if (self.all_tools_json_len > 0) return self.all_tools_json[0..self.all_tools_json_len];
        return TOOLS_JSON;
    }

    fn deinit(self: *AgentThread) void {
        // join all subagent threads
        for (&self.subagents, 0..) |*sa, i| {
            if (i >= self.subagent_count) break;
            if (sa.thread) |t| {
                sa.requestCancel();
                t.join();
                sa.thread = null;
            }
        }
        // Shut down fork-based inference server if running
        if (self.router_config.fork_server) |srv| {
            srv.shutdown();
            self.allocator.destroy(srv);
            self.router_config.fork_server = null;
        }
        if (self.session_log) |*sl| sl.close();
        self.history.deinit();
    }

    // ============================================================
    // Subagent management
    // ============================================================

    fn spawnSubAgent(self: *AgentThread, prompt: []const u8, description: []const u8) ![]const u8 {
        // Find a free slot (reuse completed subagents)
        var slot: ?usize = null;
        for (&self.subagents, 0..) |*sa, i| {
            if (i >= self.subagent_count) break;
            if (sa.isDone() and sa.thread != null) {
                sa.thread.?.join();
                sa.thread = null;
            }
            if (sa.thread == null and sa.isDone()) {
                slot = i;
                break;
            }
        }
        if (slot == null and self.subagent_count < MAX_SUBAGENTS) {
            slot = self.subagent_count;
            self.subagent_count += 1;
        }
        if (slot == null) return error.TooManySubagents;

        const sa = &self.subagents[slot.?];
        sa.* = .{}; // reset

        // Generate ID
        const id_num = self.next_subagent_id;
        self.next_subagent_id += 1;
        const id_str = std.fmt.bufPrint(&sa.id_buf, "sa-{d}", .{id_num}) catch "sa-?";
        sa.id_len = @intCast(id_str.len);

        // Copy description
        const dn = @min(description.len, sa.desc_buf.len);
        @memcpy(sa.desc_buf[0..dn], description[0..dn]);
        sa.desc_len = @intCast(dn);

        // Log spawn
        if (self.session_log) |*sl| sl.logAgentSpawn(sa.id(), "subagent", description) catch {};

        // Notify user
        var notify_buf: [256]u8 = undefined;
        const notify = std.fmt.bufPrint(&notify_buf, "Subagent {s}: {s}", .{ sa.id(), sa.desc() }) catch "Subagent spawned";
        _ = self.queues.output.push(.tool_call, notify);

        // Copy prompt for the subagent thread (stack-allocated prompt won't survive)
        const prompt_copy = try self.allocator.dupe(u8, prompt);

        // Config and system prompt: safe to reference self.* because
        // deinit() joins all subagent threads before freeing AgentThread.
        const cfg = self.config;

        // Spawn thread
        sa.thread = std.Thread.spawn(.{}, subAgentThreadFn, .{
            self.allocator, sa, prompt_copy, cfg, &self.system_prompt_buf, self.system_prompt_len,
        }) catch {
            self.allocator.free(prompt_copy);
            sa.setResult("Failed to spawn subagent thread", .failed);
            return error.SpawnFailed;
        };

        return sa.id();
    }

    fn collectSubAgent(self: *AgentThread, agent_id: []const u8, timeout_ms: u64) []const u8 {
        // Find the subagent
        for (&self.subagents, 0..) |*sa, i| {
            if (i >= self.subagent_count) break;
            if (std.mem.eql(u8, sa.id(), agent_id)) {
                // Wait for completion with timeout
                const deadline = @as(u64, @intCast(std.time.milliTimestamp())) + timeout_ms;
                while (!sa.isDone()) {
                    if (@as(u64, @intCast(std.time.milliTimestamp())) >= deadline) {
                        sa.requestCancel();
                        return "Subagent timed out";
                    }
                    if (self.queues.checkCancel()) {
                        sa.requestCancel();
                        return "Cancelled";
                    }
                    std.Thread.sleep(50 * std.time.ns_per_ms);
                }
                // Join thread
                if (sa.thread) |t| {
                    t.join();
                    sa.thread = null;
                }
                // Log result
                if (self.session_log) |*sl| sl.logAgentResult(sa.id(), sa.result()) catch {};
                return sa.result();
            }
        }
        return "Unknown subagent ID";
    }

    fn listSubAgents(self: *AgentThread, buf: []u8) []const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        if (self.subagent_count == 0) {
            w.writeAll("No subagents.\n") catch {};
            return buf[0..fbs.pos];
        }
        for (&self.subagents, 0..) |*sa, i| {
            if (i >= self.subagent_count) break;
            const status_str = switch (@atomicLoad(SubAgentStatus, &sa.status, .acquire)) {
                .running => "running",
                .done => "done",
                .failed => "failed",
            };
            w.print("{s} [{s}] {s}\n", .{ sa.id(), status_str, sa.desc() }) catch {};
        }
        return buf[0..fbs.pos];
    }

    /// Main agent loop: process requests from main thread and remote attach (FIFO)
    fn run(self: *AgentThread) void {
        // Create ctl FIFO for remote attach
        const ctl_fd: ?std.posix.fd_t = if (self.session_log) |*sl| sl.createCtlFifo() else null;
        defer if (ctl_fd) |fd| std.posix.close(fd);

        var req_msg: q.Msg = undefined;
        var fifo_buf: [4096]u8 = undefined;
        var fifo_line: [4096]u8 = undefined;
        var fifo_line_len: usize = 0;

        while (true) {
            // Check SPSC queue first
            if (self.queues.request.pop(&req_msg)) {
                if (req_msg.kind == .cancel) break;
                const query_text = req_msg.slice();
                self.queues.clearCancel();
                self.queues.setBusy(true);
                self.processQuery(query_text) catch |err| {
                    var errbuf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&errbuf, "agent error: {}", .{err}) catch "agent error";
                    _ = self.queues.output.push(.error_msg, msg);
                    if (self.session_log) |*sl| sl.logError(msg) catch {};
                };
                self.queues.setBusy(false);
                _ = self.queues.output.push(.done, "");
                continue;
            }

            // Check FIFO for remote input (non-blocking)
            if (ctl_fd) |fd| {
                const n = std.posix.read(fd, &fifo_buf) catch 0;
                if (n > 0) {
                    // Accumulate into fifo_line, process complete lines
                    for (fifo_buf[0..n]) |byte| {
                        if (byte == '\n') {
                            if (fifo_line_len > 0) {
                                const line = std.mem.trim(u8, fifo_line[0..fifo_line_len], " \t\r");
                                if (line.len > 0) {
                                    self.queues.clearCancel();
                                    self.queues.setBusy(true);
                                    self.processQuery(line) catch |err| {
                                        var errbuf: [256]u8 = undefined;
                                        const msg = std.fmt.bufPrint(&errbuf, "agent error: {}", .{err}) catch "agent error";
                                        _ = self.queues.output.push(.error_msg, msg);
                                        if (self.session_log) |*sl| sl.logError(msg) catch {};
                                    };
                                    self.queues.setBusy(false);
                                    _ = self.queues.output.push(.done, "");
                                }
                            }
                            fifo_line_len = 0;
                        } else if (fifo_line_len < fifo_line.len) {
                            fifo_line[fifo_line_len] = byte;
                            fifo_line_len += 1;
                        }
                    }
                    continue; // check for more
                }
            }

            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    fn buildContextSummary(self: *AgentThread, buf: *[256]u8) []const u8 {
        if (self.history.count == 0) return "";
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        w.print("{d} messages", .{self.history.count}) catch {};
        // Include first user message as topic hint
        if (self.history.count > 0 and self.history.messages[0].role == .user) {
            const first = self.history.messages[0].content[0..self.history.messages[0].content_len];
            const preview_len = @min(first.len, 80);
            w.print(", topic: {s}", .{first[0..preview_len]}) catch {};
        }
        return buf[0..fbs.pos];
    }

    fn processQuery(self: *AgentThread, query: []const u8) !void {
        // Save original model so we can restore after routing override
        const saved_model = self.config.model;
        defer self.config.model = saved_model;

        // Fast path: translate queries always use haiku (cheap + fast)
        const is_translate = std.mem.startsWith(u8, query, "Translate this to a shell command");
        if (is_translate) {
            const haiku = self.router_config.resolveModel(.haiku);
            self.config.model = haiku;
        }

        // ── ROUTING PHASE ──
        var route: ?router_mod.RouteDecision = null;
        if (self.router_config.enabled and !is_translate) {
            // Try local classification first (zero cost)
            route = router_mod.classifyLocal(query);

            // If ambiguous, try local GGUF inference first (pure Zig, no external deps)
            if (route == null and self.router_config.local_model_len > 0) {
                route = router_mod.classifyWithLocalModel(
                    self.allocator,
                    query,
                    &self.router_config,
                );
            }

            // If still ambiguous, call the router model via API (unless API is disabled)
            if (route == null and self.router_config.api_enabled) {
                var ctx_buf: [256]u8 = undefined;
                const ctx = self.buildContextSummary(&ctx_buf);
                route = router_mod.classifyWithModel(
                    self.allocator,
                    query,
                    ctx,
                    &self.router_config,
                    self.config.api_key,
                );
            }

            // Apply routing decision
            if (route) |*rd| {
                // Resolve model name from tier
                const model_name = self.router_config.resolveModel(rd.model_tier);
                rd.setModel(model_name);

                // Notify user about routing decision
                var summary_buf: [256]u8 = undefined;
                const summary = rd.summary(&summary_buf);
                _ = self.queues.output.push(.router_info, summary);

                // Log routing decision for training data
                logRouterDecision(query, rd.*);

                // Handle shell action — bypass LLM entirely, run as shell command
                if (rd.action == .shell) {
                    const result = std.process.Child.run(.{
                        .allocator = self.allocator,
                        .argv = &[_][]const u8{ "/bin/sh", "-c", query },
                        .max_output_bytes = 65536,
                    }) catch |err| {
                        var errbuf: [256]u8 = undefined;
                        const msg = std.fmt.bufPrint(&errbuf, "shell error: {}", .{err}) catch "shell error";
                        _ = self.queues.output.push(.error_msg, msg);
                        return;
                    };
                    defer self.allocator.free(result.stderr);
                    defer self.allocator.free(result.stdout);
                    if (result.stdout.len > 0)
                        _ = self.queues.output.push(.text_delta, result.stdout);
                    if (result.stderr.len > 0)
                        _ = self.queues.output.push(.error_msg, result.stderr);
                    return;
                }

                // Override model for this query
                self.config.model = rd.modelName();
            }
        }

        // add user message to history
        try self.history.add(.user, query);
        if (self.session_log) |*sl| sl.logUser(query) catch {};

        // track tokens for this query (across multiple API calls in tool loop)
        var query_input_tokens: u32 = 0;
        var query_output_tokens: u32 = 0;

        // tool loop: keep calling API until no more tool_use
        var iteration: usize = 0;
        const max_iter = self.config.max_tool_iterations;
        while (iteration < max_iter) : (iteration += 1) {
            if (self.queues.checkCancel()) return;

            const response = try self.callAPI();
            defer self.allocator.free(response.text_alloc);

            // accumulate tokens
            query_input_tokens += response.input_tokens;
            query_output_tokens += response.output_tokens;

            if (!response.has_tool_call) {
                // plain text response — add to history and done
                if (response.text.len > 0) {
                    try self.history.add(.assistant, response.text);
                    if (self.session_log) |*sl| sl.logAssistant(response.text) catch {};
                } else {
                    _ = self.queues.output.push(.error_msg, "empty response from API (check credentials/model)");
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
            const effective_input = if (tool_input.len == 0) "{}" else tool_input;
            aw.print("{{\"type\":\"tool_use\",\"id\":\"{s}\",\"name\":\"{s}\",\"input\":{s}}}", .{
                tool_id, tool_name, effective_input,
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

            // Truncate tool output to prevent body overflow (max 16KB for API)
            const MAX_TOOL_OUTPUT = 16384;
            const truncated = tool_output.len > MAX_TOOL_OUTPUT;
            const effective_output = if (truncated) tool_output[0..MAX_TOOL_OUTPUT] else tool_output;

            // Build tool_result user message
            const extra: usize = if (truncated) 100 else 0; // for truncation notice
            var result_json_buf = try self.allocator.alloc(u8, effective_output.len * 2 + 256 + extra);
            defer self.allocator.free(result_json_buf);
            var result_fbs = std.io.fixedBufferStream(result_json_buf);
            const rw = result_fbs.writer();
            rw.print("[{{\"type\":\"tool_result\",\"tool_use_id\":\"{s}\",\"content\":", .{tool_id}) catch {};
            if (truncated) {
                // Write truncated output with notice
                rw.writeByte('"') catch {};
                for (effective_output) |c| {
                    switch (c) {
                        '"' => rw.writeAll("\\\"") catch {},
                        '\\' => rw.writeAll("\\\\") catch {},
                        '\n' => rw.writeAll("\\n") catch {},
                        '\r' => rw.writeAll("\\r") catch {},
                        '\t' => rw.writeAll("\\t") catch {},
                        else => {
                            if (c < 0x20) {
                                rw.writeAll("\\u00") catch {};
                                const hex = "0123456789abcdef";
                                rw.writeByte(hex[c >> 4]) catch {};
                                rw.writeByte(hex[c & 0x0f]) catch {};
                            } else rw.writeByte(c) catch {};
                        },
                    }
                }
                rw.writeAll("\\n... [truncated]\"") catch {};
            } else {
                writeJSONString(rw, effective_output) catch {};
            }
            rw.writeAll("}]") catch {};
            try self.history.addKind(.user, .tool_result, result_json_buf[0..result_fbs.pos]);
        }

        // Update cumulative totals and send usage info
        self.total_input_tokens += query_input_tokens;
        self.total_output_tokens += query_output_tokens;
        if (query_input_tokens > 0 or query_output_tokens > 0) {
            var usage_buf: [256]u8 = undefined;
            const is_free = std.mem.startsWith(u8, self.config.api_key, "sk-ant-oat");
            const usage_msg = if (is_free)
                // OAuth/Max subscription — show tokens with "free" indicator
                std.fmt.bufPrint(&usage_buf, "tokens: {d}\xe2\x86\x91 {d}\xe2\x86\x93 | total: {d}\xe2\x86\x91 {d}\xe2\x86\x93 (free)", .{
                    query_input_tokens, query_output_tokens,
                    self.total_input_tokens, self.total_output_tokens,
                }) catch "usage unavailable"
            else blk: {
                // API key — show estimated cost
                const input_cost = @as(f64, @floatFromInt(self.total_input_tokens)) * 3.0 / 1_000_000.0;
                const output_cost = @as(f64, @floatFromInt(self.total_output_tokens)) * 15.0 / 1_000_000.0;
                const total_cost = input_cost + output_cost;
                break :blk std.fmt.bufPrint(&usage_buf, "tokens: {d}\xe2\x86\x91 {d}\xe2\x86\x93 | total: {d}\xe2\x86\x91 {d}\xe2\x86\x93 (${d:.4})", .{
                    query_input_tokens, query_output_tokens,
                    self.total_input_tokens, self.total_output_tokens,
                    total_cost,
                }) catch "usage unavailable";
            };
            _ = self.queues.output.push(.usage_info, usage_msg);
        }

        if (self.session_log) |*sl| sl.logDone() catch {};

        // Auto-compact: if cumulative input tokens exceed threshold, summarize history
        // This prevents context overflow on long conversations
        const AUTO_COMPACT_THRESHOLD: u32 = 120_000;
        if (self.total_input_tokens > AUTO_COMPACT_THRESHOLD and self.history.count > 4 and !self.compact_in_progress) {
            self.autoCompact();
        }
    }

    fn autoCompact(self: *AgentThread) void {
        self.compact_in_progress = true;
        defer self.compact_in_progress = false;

        _ = self.queues.output.push(.tool_call, "Auto-compacting conversation (context getting large)...");

        // Build a summary request using the current history
        const compact_query =
            \\Summarize our conversation so far in a concise way that preserves:
            \\1. Key decisions and their rationale
            \\2. Important code changes made (files, what changed, why)
            \\3. Current task/goal and next steps
            \\4. Any constraints or requirements mentioned
            \\Be thorough but concise. This summary replaces the conversation history.
        ;

        // Drop oldest messages to free context, keeping last 4 messages (recent context)
        const saved_count = self.history.count;
        if (saved_count < 6) return;

        // Add the compact query as a user message
        self.history.add(.user, compact_query) catch return;

        // Call API to get summary
        const response = self.callAPI() catch {
            // Remove the compact query we added
            if (self.history.count > saved_count) {
                self.allocator.free(self.history.messages[self.history.count - 1].content[0..self.history.messages[self.history.count - 1].alloc_len]);
                self.history.count -= 1;
            }
            return;
        };
        defer self.allocator.free(response.text_alloc);

        if (response.text.len == 0) return;

        // Keep summary + last 2 messages from before compact query
        // Strategy: free old messages, shift recent ones, prepend summary
        const summary = self.allocator.dupe(u8, response.text) catch return;

        // Remove the compact query + response from history (they were added by callAPI flow)
        // The compact query is at saved_count, remove it
        if (self.history.count > saved_count) {
            // Remove messages from saved_count onwards (compact query + any response)
            var ri = self.history.count;
            while (ri > saved_count) {
                ri -= 1;
                self.allocator.free(self.history.messages[ri].content[0..self.history.messages[ri].alloc_len]);
            }
            self.history.count = saved_count;
        }

        // Free all but the last 4 messages
        const keep = @min(saved_count, 4);
        const drop = saved_count - keep;
        for (0..drop) |i| {
            self.allocator.free(self.history.messages[i].content[0..self.history.messages[i].alloc_len]);
        }
        // Shift kept messages to make room for summary at front
        if (drop > 0) {
            std.mem.copyForwards(Message, self.history.messages[2..2 + keep], self.history.messages[drop..drop + keep]);
            self.history.count = 2 + keep;
        } else {
            // Need to make room — shift everything right by 2
            if (self.history.count + 2 <= MAX_HISTORY) {
                var si = self.history.count;
                while (si > 0) {
                    si -= 1;
                    self.history.messages[si + 2] = self.history.messages[si];
                }
                self.history.count += 2;
            } else {
                // Drop oldest 2 to make room
                self.allocator.free(self.history.messages[0].content[0..self.history.messages[0].alloc_len]);
                self.allocator.free(self.history.messages[1].content[0..self.history.messages[1].alloc_len]);
                std.mem.copyForwards(Message, self.history.messages[2..self.history.count], self.history.messages[2..self.history.count]);
                // Shift is a no-op here, just overwrite [0] and [1]
            }
        }

        // Insert summary as first two messages (user context + assistant summary)
        const ctx_msg = "Here is a summary of our conversation so far. Continue from where we left off.";
        const ctx_buf = self.allocator.dupe(u8, ctx_msg) catch {
            self.allocator.free(summary);
            return;
        };
        self.history.messages[0] = .{
            .role = .user,
            .kind = .text,
            .content = ctx_buf,
            .content_len = ctx_msg.len,
            .alloc_len = ctx_msg.len,
        };
        self.history.messages[1] = .{
            .role = .assistant,
            .kind = .text,
            .content = summary,
            .content_len = summary.len,
            .alloc_len = summary.len,
        };

        // Reset token counter so we don't immediately re-compact
        self.total_input_tokens = 0;
        self.total_output_tokens = 0;

        _ = self.queues.output.push(.tool_done, "Conversation compacted");
    }

    fn confirmTool(self: *AgentThread, tool_name: []const u8, detail: []const u8, allowed: *bool) bool {
        if (allowed.*) return true;
        const result = self.waitForConfirm(detail);
        switch (result) {
            .deny => return false,
            .allow_once => return true,
            .allow_always => {
                allowed.* = true;
                var msg_buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "Auto-allowing {s} for this session", .{tool_name}) catch "Auto-allowed";
                _ = self.queues.output.push(.tool_call, msg);
                return true;
            },
        }
    }

    fn dispatchTool(self: *AgentThread, tool_name: []const u8, tool_input: []const u8) ![]u8 {
        if (std.mem.eql(u8, tool_name, "Bash")) {
            const cmd = extractJsonField(tool_input, "command") orelse return error.MissingCommand;
            var unescape_buf: [8192]u8 = undefined;
            const preview = unescapeJSON(cmd, &unescape_buf) orelse cmd;
            var detail_buf: [512]u8 = undefined;
            const detail = std.fmt.bufPrint(&detail_buf, "$ {s}", .{preview}) catch preview;
            if (!self.confirmTool("Bash", detail, &self.allow_bash))
                return self.allocator.dupe(u8, "Tool execution denied by user.");
            return self.executeBash(cmd);
        }
        if (std.mem.eql(u8, tool_name, "Read")) {
            const path = extractJsonField(tool_input, "file_path") orelse return error.MissingPath;
            const offset_str = extractJsonField(tool_input, "offset");
            const limit_str = extractJsonField(tool_input, "limit");
            const offset: usize = if (offset_str) |s| std.fmt.parseInt(usize, s, 10) catch 0 else 0;
            const limit: usize = if (limit_str) |s| std.fmt.parseInt(usize, s, 10) catch 0 else 0;
            return self.executeRead(path, offset, limit);
        }
        if (std.mem.eql(u8, tool_name, "Edit")) {
            const path = extractJsonField(tool_input, "file_path") orelse return error.MissingPath;
            const old_str = extractJsonField(tool_input, "old_string") orelse return error.MissingContent;
            const new_str = extractJsonField(tool_input, "new_string") orelse return error.MissingContent;
            const replace_all = if (std.mem.indexOf(u8, tool_input, "\"replace_all\"")) |idx| blk: {
                const after = tool_input[@min(idx + 13, tool_input.len)..];
                break :blk std.mem.indexOf(u8, after, "true") != null;
            } else false;
            var path_buf2: [512]u8 = undefined;
            const rp = unescapeJSON(path, &path_buf2) orelse path;
            var detail_buf: [512]u8 = undefined;
            const detail = std.fmt.bufPrint(&detail_buf, "Edit {s}", .{rp}) catch rp;
            if (!self.confirmTool("Edit", detail, &self.allow_edit))
                return self.allocator.dupe(u8, "Tool execution denied by user.");
            return self.executeEdit(path, old_str, new_str, replace_all);
        }
        if (std.mem.eql(u8, tool_name, "Write")) {
            const path = extractJsonField(tool_input, "file_path") orelse return error.MissingPath;
            const content = extractJsonField(tool_input, "content") orelse return error.MissingContent;
            var path_buf2: [512]u8 = undefined;
            const rp = unescapeJSON(path, &path_buf2) orelse path;
            var detail_buf: [512]u8 = undefined;
            const detail = std.fmt.bufPrint(&detail_buf, "Write {s}", .{rp}) catch rp;
            if (!self.confirmTool("Write", detail, &self.allow_write))
                return self.allocator.dupe(u8, "Tool execution denied by user.");
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
        if (std.mem.eql(u8, tool_name, "Agent")) {
            const prompt_raw = extractJsonField(tool_input, "prompt") orelse return error.MissingPrompt;
            const desc_raw = extractJsonField(tool_input, "description") orelse "subagent task";
            var prompt_buf: [4096]u8 = undefined;
            const prompt = unescapeJSON(prompt_raw, &prompt_buf) orelse prompt_raw;
            var desc_buf2: [128]u8 = undefined;
            const description = unescapeJSON(desc_raw, &desc_buf2) orelse desc_raw;
            const agent_id = self.spawnSubAgent(prompt, description) catch |err| {
                var errbuf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&errbuf, "Failed to spawn subagent: {}", .{err}) catch "spawn failed";
                return self.allocator.dupe(u8, msg);
            };
            // Wait for result (timeout 120s)
            const result = self.collectSubAgent(agent_id, 120_000);
            return self.allocator.dupe(u8, result);
        }
        if (std.mem.eql(u8, tool_name, "WebFetch")) {
            const url = extractJsonField(tool_input, "url") orelse return error.MissingURL;
            const max_str = extractJsonField(tool_input, "max_bytes");
            const max_bytes: usize = if (max_str) |s| std.fmt.parseInt(usize, s, 10) catch 32768 else 32768;
            return self.executeWebFetch(url, max_bytes);
        }
        if (std.mem.eql(u8, tool_name, "WebSearch")) {
            const query = extractJsonField(tool_input, "query") orelse return error.MissingQuery;
            const max_str = extractJsonField(tool_input, "max_results");
            const max_results: usize = if (max_str) |s| std.fmt.parseInt(usize, s, 10) catch 8 else 8;
            return self.executeWebSearch(query, max_results);
        }
        // Check plugin tools
        for (self.plugin_tools[0..self.plugin_count], 0..) |*pt, pi| {
            if (std.mem.eql(u8, tool_name, pt.name())) {
                return self.executePluginTool(pt, @intCast(pi), tool_input);
            }
        }
        return error.UnknownTool;
    }

    fn executePluginTool(self: *AgentThread, pt: *const PluginTool, plugin_idx: u4, tool_input: []const u8) ![]u8 {
        // Substitute {param_name} placeholders in the command template
        var cmd_buf: [4096]u8 = undefined;
        var cmd_len: usize = 0;
        const template = pt.command();
        var ti: usize = 0;

        while (ti < template.len) {
            if (template[ti] == '{') {
                // Find closing brace
                const close = std.mem.indexOfScalarPos(u8, template, ti + 1, '}') orelse {
                    if (cmd_len < cmd_buf.len) {
                        cmd_buf[cmd_len] = template[ti];
                        cmd_len += 1;
                    }
                    ti += 1;
                    continue;
                };
                const param_name = template[ti + 1 .. close];
                // Look up param value from tool_input JSON
                const raw_value = extractJsonField(tool_input, param_name) orelse "";
                // Unescape JSON string
                var unescape_buf: [2048]u8 = undefined;
                const value = unescapeJSON(raw_value, &unescape_buf) orelse raw_value;
                // Shell-escape and substitute
                var esc_buf: [2048]u8 = undefined;
                const escaped = shellEscape(value, &esc_buf) orelse value;
                const n = @min(escaped.len, cmd_buf.len - cmd_len);
                @memcpy(cmd_buf[cmd_len..][0..n], escaped[0..n]);
                cmd_len += n;
                ti = close + 1;
            } else {
                if (cmd_len < cmd_buf.len) {
                    cmd_buf[cmd_len] = template[ti];
                    cmd_len += 1;
                }
                ti += 1;
            }
        }

        const final_cmd = cmd_buf[0..cmd_len];

        // Notify user about the command
        var notif_buf: [512]u8 = undefined;
        const notif = std.fmt.bufPrint(&notif_buf, "{s}: {s}", .{ pt.name(), final_cmd }) catch final_cmd;
        _ = self.queues.output.push(.tool_call, notif);

        // Confirmation flow if required
        if (pt.confirm) {
            const bit = @as(u16, 1) << plugin_idx;
            if (self.allow_plugins & bit == 0) {
                const result = self.waitForConfirm(final_cmd);
                switch (result) {
                    .deny => return self.allocator.dupe(u8, "Tool execution cancelled by user."),
                    .allow_once => {},
                    .allow_always => {
                        self.allow_plugins |= bit;
                        var abuf: [128]u8 = undefined;
                        const amsg = std.fmt.bufPrint(&abuf, "Auto-allowing {s} for this session", .{pt.name()}) catch "Auto-allowed";
                        _ = self.queues.output.push(.tool_call, amsg);
                    },
                }
            }
        }

        // Execute the command
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "/bin/sh", "-c", final_cmd },
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

    const ConfirmResult = enum { deny, allow_once, allow_always };

    fn waitForConfirm(self: *AgentThread, command: []const u8) ConfirmResult {
        // Send confirmation request to main thread
        var confirm_buf: [512]u8 = undefined;
        const confirm_msg = std.fmt.bufPrint(&confirm_buf, "Execute: {s}", .{command}) catch command;
        self.queues.output.pushWait(.confirm_request, confirm_msg);

        // Wait for response (up to 60 seconds)
        var msg: q.Msg = undefined;
        var ticks: usize = 0;
        while (ticks < 6000) : (ticks += 1) {
            if (self.queues.checkCancel()) return .deny;
            if (self.queues.request.pop(&msg)) {
                if (msg.kind == .confirm_response) {
                    if (msg.len == 0) return .deny;
                    return switch (msg.data[0]) {
                        'y', 'Y' => .allow_once,
                        'a', 'A', '!' => .allow_always,
                        else => .deny,
                    };
                }
                if (msg.kind == .cancel) return .deny;
            }
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        return .deny; // timeout
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
        input_tokens: u32 = 0,
        output_tokens: u32 = 0,
    };

    fn callAPI(self: *AgentThread) !APIResponse {
        // Retry with exponential backoff on transient errors
        var attempt: u8 = 0;
        const max_retries: u8 = 3;
        while (true) {
            const result = switch (self.config.provider) {
                .anthropic => self.callAnthropic(),
                .ollama, .openai_compat => self.callOpenAICompat(),
            };
            if (result) |resp| {
                return resp;
            } else |err| {
                attempt += 1;
                if (attempt >= max_retries or self.queues.checkCancel()) return err;
                // Notify user about retry
                var retry_buf: [128]u8 = undefined;
                const retry_msg = std.fmt.bufPrint(&retry_buf, "API error, retrying ({d}/{d})...", .{ attempt, max_retries }) catch "Retrying...";
                _ = self.queues.output.push(.tool_call, retry_msg);
                // Exponential backoff: 2s, 4s
                const delay_ms: u64 = @as(u64, 2000) * (@as(u64, 1) << @intCast(attempt - 1));
                std.Thread.sleep(delay_ms * std.time.ns_per_ms);
            }
        }
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
            self.toolsJson(),
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
        var resp_input_tokens: u32 = 0;
        var resp_output_tokens: u32 = 0;

        // Build curl command with headers
        var argv_buf: [50][]const u8 = undefined;
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
        var header_bufs: [2][512]u8 = undefined;
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

                // Anthropic API version and beta features
                argv_buf[argc] = "-H";
                argc += 1;
                argv_buf[argc] = "anthropic-version: 2023-06-01";
                argc += 1;
                argv_buf[argc] = "-H";
                argc += 1;
                argv_buf[argc] = "anthropic-beta: prompt-caching-scope-2026-01-05";
                argc += 1;

                // Claude Code SDK identification (Anthropic TypeScript SDK 0.74.0)
                argv_buf[argc] = "-H";
                argc += 1;
                argv_buf[argc] = "User-Agent: Anthropic/JS 0.74.0";
                argc += 1;
                argv_buf[argc] = "-H";
                argc += 1;
                argv_buf[argc] = "x-service-name: claude-code";
                argc += 1;
                argv_buf[argc] = "-H";
                argc += 1;
                argv_buf[argc] = "X-Stainless-Lang: js";
                argc += 1;
                argv_buf[argc] = "-H";
                argc += 1;
                argv_buf[argc] = "X-Stainless-Package-Version: 0.74.0";
                argc += 1;
                argv_buf[argc] = "-H";
                argc += 1;
                argv_buf[argc] = "X-Stainless-Runtime: node";
                argc += 1;
                argv_buf[argc] = "-H";
                argc += 1;
                argv_buf[argc] = "X-Stainless-Runtime-Version: v25.7.0";
                argc += 1;
                argv_buf[argc] = "-H";
                argc += 1;
                argv_buf[argc] = "X-Stainless-OS: Linux";
                argc += 1;
                argv_buf[argc] = "-H";
                argc += 1;
                argv_buf[argc] = "X-Stainless-Arch: x64";
                argc += 1;
                argv_buf[argc] = "-H";
                argc += 1;
                argv_buf[argc] = "X-Stainless-Helper-Method: stream";
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
        var sse_buf: [65536]u8 = undefined;
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
                            &has_tool_call, self.queues,
                            &resp_input_tokens, &resp_output_tokens);
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
            .input_tokens = resp_input_tokens,
            .output_tokens = resp_output_tokens,
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

    fn executeRead(self: *AgentThread, path: []const u8, offset: usize, limit: usize) ![]u8 {
        var path_buf: [512]u8 = undefined;
        const real_path = unescapeJSON(path, &path_buf) orelse path;

        var notif_buf: [512]u8 = undefined;
        if (offset > 0 or limit > 0) {
            const notif = std.fmt.bufPrint(&notif_buf, "Read {s}:{d}", .{ real_path, offset }) catch real_path;
            _ = self.queues.output.push(.tool_call, notif);
        } else {
            const notif = std.fmt.bufPrint(&notif_buf, "Read {s}", .{real_path}) catch real_path;
            _ = self.queues.output.push(.tool_call, notif);
        }

        const content = std.fs.cwd().readFileAlloc(self.allocator, real_path, 512 * 1024) catch |err| {
            var errbuf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&errbuf, "read error: {s}: {}", .{ real_path, err }) catch "read error";
            return self.allocator.dupe(u8, msg);
        };
        defer self.allocator.free(content);

        // Add line numbers and apply offset/limit
        var result: std.ArrayList(u8) = .{};
        var line_num: usize = 1;
        var start: usize = 0;
        const start_line = if (offset > 0) offset else 1;
        const max_lines = if (limit > 0) limit else 2000;
        var lines_output: usize = 0;

        while (start <= content.len and lines_output < max_lines) {
            const end = if (start < content.len)
                (std.mem.indexOfScalarPos(u8, content, start, '\n') orelse content.len)
            else
                content.len;

            if (line_num >= start_line) {
                result.writer(self.allocator).print("{d:>6}\t", .{line_num}) catch break;
                if (start < content.len) {
                    result.appendSlice(self.allocator, content[start..end]) catch break;
                }
                result.append(self.allocator, '\n') catch break;
                lines_output += 1;
            }

            if (end >= content.len) break;
            start = end + 1;
            line_num += 1;
        }

        return result.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
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

    fn executeEdit(self: *AgentThread, path: []const u8, old_str: []const u8, new_str: []const u8, replace_all: bool) ![]u8 {
        var path_buf: [512]u8 = undefined;
        const real_path = unescapeJSON(path, &path_buf) orelse path;

        // Unescape the search and replace strings
        const old_buf = try self.allocator.alloc(u8, old_str.len);
        defer self.allocator.free(old_buf);
        const real_old = unescapeJSON(old_str, old_buf) orelse old_str;

        const new_buf = try self.allocator.alloc(u8, new_str.len);
        defer self.allocator.free(new_buf);
        const real_new = unescapeJSON(new_str, new_buf) orelse new_str;

        var notif_buf: [512]u8 = undefined;
        const notif = std.fmt.bufPrint(&notif_buf, "Edit {s}", .{real_path}) catch real_path;
        _ = self.queues.output.push(.tool_call, notif);

        // Read current file content
        const content = std.fs.cwd().readFileAlloc(self.allocator, real_path, 512 * 1024) catch |err| {
            var errbuf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&errbuf, "edit error: cannot read {s}: {}", .{ real_path, err }) catch "read error";
            return self.allocator.dupe(u8, msg);
        };
        defer self.allocator.free(content);

        // Find occurrences
        if (std.mem.indexOf(u8, content, real_old) == null) {
            return self.allocator.dupe(u8, "edit error: old_string not found in file");
        }

        if (!replace_all) {
            // Check uniqueness
            if (std.mem.indexOf(u8, content, real_old)) |first| {
                if (std.mem.indexOfPos(u8, content, first + real_old.len, real_old) != null) {
                    return self.allocator.dupe(u8, "edit error: old_string found multiple times. Use replace_all:true or provide more context.");
                }
            }
        }

        // Backup before editing
        if (self.session_log) |*sl| sl.backupFile(real_path) catch {};

        // Build new content with replacements
        var result_content: std.ArrayList(u8) = .{};
        defer result_content.deinit(self.allocator);
        var pos: usize = 0;
        var replacements: usize = 0;

        while (pos < content.len) {
            if (std.mem.indexOfPos(u8, content, pos, real_old)) |match_start| {
                result_content.appendSlice(self.allocator, content[pos..match_start]) catch return error.OutOfMemory;
                result_content.appendSlice(self.allocator, real_new) catch return error.OutOfMemory;
                pos = match_start + real_old.len;
                replacements += 1;
                if (!replace_all) break;
            } else {
                result_content.appendSlice(self.allocator, content[pos..]) catch return error.OutOfMemory;
                break;
            }
        }
        // Append remaining if we broke early
        if (pos < content.len and !replace_all) {
            result_content.appendSlice(self.allocator, content[pos..]) catch return error.OutOfMemory;
        }

        // Write back
        const file = std.fs.cwd().createFile(real_path, .{}) catch |err| {
            var errbuf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&errbuf, "edit error: cannot write {s}: {}", .{ real_path, err }) catch "write error";
            return self.allocator.dupe(u8, msg);
        };
        defer file.close();
        file.writeAll(result_content.items) catch |err| {
            var errbuf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&errbuf, "write error: {}", .{err}) catch "write error";
            return self.allocator.dupe(u8, msg);
        };

        // Show diff preview in tool output
        var diff_result: std.ArrayList(u8) = .{};
        const dw = diff_result.writer(self.allocator);
        dw.print("Edited {s}: {d} replacement(s)\n", .{ real_path, replacements }) catch {};
        // Show context: what was replaced
        const old_preview = if (real_old.len > 200) real_old[0..200] else real_old;
        const new_preview = if (real_new.len > 200) real_new[0..200] else real_new;
        dw.writeAll("--- old\n") catch {};
        dw.writeAll(old_preview) catch {};
        if (real_old.len > 200) dw.writeAll("...") catch {};
        dw.writeAll("\n+++ new\n") catch {};
        dw.writeAll(new_preview) catch {};
        if (real_new.len > 200) dw.writeAll("...") catch {};
        dw.writeByte('\n') catch {};

        _ = self.queues.output.push(.tool_done, diff_result.items);
        return diff_result.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }

    fn executeWebFetch(self: *AgentThread, url: []const u8, max_bytes: usize) ![]u8 {
        var url_buf: [2048]u8 = undefined;
        const real_url = unescapeJSON(url, &url_buf) orelse url;

        var notif_buf: [512]u8 = undefined;
        const notif = std.fmt.bufPrint(&notif_buf, "Fetch {s}", .{real_url}) catch real_url;
        _ = self.queues.output.push(.tool_call, notif);

        // Use curl to fetch URL content
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{
                "curl", "-sS", "-L", "--max-time", "30",
                "-H", "User-Agent: Mozilla/5.0 (compatible; zish/1.0)",
                "-H", "Accept: text/html,application/json,text/plain",
                real_url,
            },
            .max_output_bytes = 256 * 1024,
        }) catch |err| {
            var errbuf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&errbuf, "fetch failed: {}", .{err}) catch "fetch failed";
            return self.allocator.dupe(u8, msg);
        };
        defer self.allocator.free(result.stderr);

        if (result.stdout.len == 0) {
            self.allocator.free(result.stdout);
            if (result.stderr.len > 0) {
                return self.allocator.dupe(u8, result.stderr);
            }
            return self.allocator.dupe(u8, "empty response");
        }

        // Check if content looks like HTML — strip tags if so
        const is_html = if (result.stdout.len > 50) blk: {
            var low: [64]u8 = undefined;
            for (result.stdout[0..@min(result.stdout.len, 64)], 0..) |c, j| {
                low[j] = if (c >= 'A' and c <= 'Z') c + 32 else c;
            }
            const check = low[0..@min(result.stdout.len, 64)];
            break :blk std.mem.indexOf(u8, check, "<!doctype") != null or
                std.mem.indexOf(u8, check, "<html") != null;
        } else false;

        if (is_html) {
            // Strip HTML tags and decode basic entities
            var text: std.ArrayList(u8) = .{};
            const src = result.stdout;
            var si: usize = 0;
            var in_tag = false;
            var in_script = false;
            var in_style = false;
            var last_was_space = false;
            const cap = @min(max_bytes * 2, src.len); // process more than max to account for compression

            while (si < cap) {
                if (src[si] == '<') {
                    // Check for script/style start/end
                    if (si + 7 < src.len) {
                        var tag_buf: [10]u8 = undefined;
                        const tlen = @min(10, src.len - si - 1);
                        for (src[si + 1 ..][0..tlen], 0..) |c, j| {
                            tag_buf[j] = if (c >= 'A' and c <= 'Z') c + 32 else c;
                        }
                        const tag = tag_buf[0..tlen];
                        if (std.mem.startsWith(u8, tag, "script")) in_script = true;
                        if (std.mem.startsWith(u8, tag, "/script")) in_script = false;
                        if (std.mem.startsWith(u8, tag, "style")) in_style = true;
                        if (std.mem.startsWith(u8, tag, "/style")) in_style = false;
                    }
                    in_tag = true;
                    si += 1;
                    continue;
                }
                if (src[si] == '>') {
                    in_tag = false;
                    si += 1;
                    continue;
                }
                if (in_tag or in_script or in_style) {
                    si += 1;
                    continue;
                }
                // Handle HTML entities
                if (src[si] == '&') {
                    if (si + 4 < src.len and std.mem.startsWith(u8, src[si..], "&amp;")) {
                        text.append(self.allocator, '&') catch break;
                        si += 5;
                        last_was_space = false;
                        continue;
                    }
                    if (si + 3 < src.len and std.mem.startsWith(u8, src[si..], "&lt;")) {
                        text.append(self.allocator, '<') catch break;
                        si += 4;
                        last_was_space = false;
                        continue;
                    }
                    if (si + 3 < src.len and std.mem.startsWith(u8, src[si..], "&gt;")) {
                        text.append(self.allocator, '>') catch break;
                        si += 4;
                        last_was_space = false;
                        continue;
                    }
                    if (si + 5 < src.len and std.mem.startsWith(u8, src[si..], "&quot;")) {
                        text.append(self.allocator, '"') catch break;
                        si += 6;
                        last_was_space = false;
                        continue;
                    }
                    if (si + 5 < src.len and std.mem.startsWith(u8, src[si..], "&nbsp;")) {
                        text.append(self.allocator, ' ') catch break;
                        si += 6;
                        last_was_space = true;
                        continue;
                    }
                    // Skip unknown entities
                    if (std.mem.indexOfScalarPos(u8, src, si + 1, ';')) |end| {
                        if (end - si < 10) {
                            si = end + 1;
                            continue;
                        }
                    }
                }
                // Collapse whitespace
                if (src[si] == ' ' or src[si] == '\t') {
                    if (!last_was_space) {
                        text.append(self.allocator, ' ') catch break;
                        last_was_space = true;
                    }
                    si += 1;
                    continue;
                }
                if (src[si] == '\n' or src[si] == '\r') {
                    if (!last_was_space) {
                        text.append(self.allocator, '\n') catch break;
                        last_was_space = true;
                    }
                    si += 1;
                    continue;
                }
                text.append(self.allocator, src[si]) catch break;
                last_was_space = false;
                si += 1;

                if (text.items.len >= max_bytes) break;
            }

            self.allocator.free(result.stdout);

            // Collapse multiple newlines
            const raw = text.items;
            var clean: std.ArrayList(u8) = .{};
            var ci: usize = 0;
            var consecutive_nl: u8 = 0;
            while (ci < raw.len) {
                if (raw[ci] == '\n') {
                    consecutive_nl += 1;
                    if (consecutive_nl <= 2)
                        clean.append(self.allocator, '\n') catch break;
                } else {
                    consecutive_nl = 0;
                    clean.append(self.allocator, raw[ci]) catch break;
                }
                ci += 1;
            }
            text.deinit(self.allocator);

            const final = clean.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
            _ = self.queues.output.push(.tool_done, final);
            return final;
        }

        // Non-HTML: return raw content truncated
        if (result.stdout.len > max_bytes) {
            const truncated = try self.allocator.alloc(u8, max_bytes + 20);
            @memcpy(truncated[0..max_bytes], result.stdout[0..max_bytes]);
            const suffix = "\n... [truncated]";
            @memcpy(truncated[max_bytes..max_bytes + suffix.len], suffix);
            self.allocator.free(result.stdout);
            const final_len = max_bytes + suffix.len;
            _ = self.queues.output.push(.tool_done, truncated[0..final_len]);
            return self.allocator.realloc(truncated, final_len) catch truncated;
        }

        _ = self.queues.output.push(.tool_done, result.stdout);
        return result.stdout;
    }

    fn executeWebSearch(self: *AgentThread, query: []const u8, max_results: usize) ![]u8 {
        var query_buf: [1024]u8 = undefined;
        const real_query = unescapeJSON(query, &query_buf) orelse query;

        var notif_buf: [512]u8 = undefined;
        const notif = std.fmt.bufPrint(&notif_buf, "Search: {s}", .{real_query}) catch real_query;
        _ = self.queues.output.push(.tool_call, notif);

        // URL-encode the query
        var encoded_buf: [2048]u8 = undefined;
        var ei: usize = 0;
        for (real_query) |c| {
            if (ei + 3 >= encoded_buf.len) break;
            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.') {
                encoded_buf[ei] = c;
                ei += 1;
            } else if (c == ' ') {
                encoded_buf[ei] = '+';
                ei += 1;
            } else {
                const hex = "0123456789ABCDEF";
                encoded_buf[ei] = '%';
                encoded_buf[ei + 1] = hex[c >> 4];
                encoded_buf[ei + 2] = hex[c & 0x0f];
                ei += 3;
            }
        }
        const encoded_query = encoded_buf[0..ei];

        // Use DuckDuckGo HTML lite
        var url_buf2: [2200]u8 = undefined;
        const search_url = std.fmt.bufPrint(&url_buf2, "https://html.duckduckgo.com/html/?q={s}", .{encoded_query}) catch return error.URLTooLong;

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{
                "curl", "-sS", "-L", "--max-time", "15",
                "-H", "User-Agent: Mozilla/5.0 (compatible; zish/1.0)",
                search_url,
            },
            .max_output_bytes = 256 * 1024,
        }) catch |err| {
            var errbuf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&errbuf, "search failed: {}", .{err}) catch "search failed";
            return self.allocator.dupe(u8, msg);
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.stdout.len == 0) {
            return self.allocator.dupe(u8, "no search results");
        }

        // Parse DuckDuckGo HTML results
        // Results are in <a class="result__a" href="...">title</a> and <a class="result__snippet">...</a>
        var output: std.ArrayList(u8) = .{};
        const w = output.writer(self.allocator);
        var count: usize = 0;
        const src = result.stdout;
        var si: usize = 0;
        const cap = @min(max_results, 20);

        while (si < src.len and count < cap) {
            // Find result link: class="result__a"
            const marker = "class=\"result__a\"";
            const pos = std.mem.indexOfPos(u8, src, si, marker) orelse break;
            si = pos + marker.len;

            // Extract href
            // Go back to find href="..."
            const href_start = if (std.mem.lastIndexOf(u8, src[0..pos], "href=\"")) |h| h + 6 else {
                continue;
            };
            const href_end = std.mem.indexOfScalarPos(u8, src, href_start, '"') orelse continue;
            var href = src[href_start..href_end];

            // DuckDuckGo wraps URLs in redirect — extract actual URL
            if (std.mem.indexOf(u8, href, "uddg=")) |uddg| {
                const url_start = uddg + 5;
                const url_end = std.mem.indexOfScalarPos(u8, href, url_start, '&') orelse href.len;
                href = href[url_start..url_end];
            }

            // Extract title (text between > and </a>)
            const title_start = std.mem.indexOfScalarPos(u8, src, si, '>') orelse continue;
            const title_end = std.mem.indexOfPos(u8, src, title_start, "</a>") orelse continue;
            si = title_end + 4;

            // Strip HTML from title
            var title_buf2: [512]u8 = undefined;
            var ti: usize = 0;
            var in_tag = false;
            for (src[title_start + 1 .. title_end]) |c| {
                if (c == '<') { in_tag = true; continue; }
                if (c == '>') { in_tag = false; continue; }
                if (!in_tag and ti < title_buf2.len) {
                    title_buf2[ti] = c;
                    ti += 1;
                }
            }

            // Find snippet: class="result__snippet"
            var snippet_text: []const u8 = "";
            var snippet_buf2: [1024]u8 = undefined;
            const snippet_marker = "class=\"result__snippet\"";
            if (std.mem.indexOfPos(u8, src, si, snippet_marker)) |sp| {
                const sn_start = std.mem.indexOfScalarPos(u8, src, sp + snippet_marker.len, '>') orelse si;
                const sn_end = std.mem.indexOfPos(u8, src, sn_start, "</a>") orelse
                    (std.mem.indexOfPos(u8, src, sn_start, "</td>") orelse si);
                // Strip HTML from snippet
                var sni: usize = 0;
                var s_tag = false;
                for (src[sn_start + 1 .. @min(sn_end, src.len)]) |c| {
                    if (c == '<') { s_tag = true; continue; }
                    if (c == '>') { s_tag = false; continue; }
                    if (!s_tag and sni < snippet_buf2.len) {
                        snippet_buf2[sni] = c;
                        sni += 1;
                    }
                }
                snippet_text = snippet_buf2[0..sni];
            }

            count += 1;
            w.print("{d}. {s}\n   {s}\n", .{
                count, title_buf2[0..ti], href,
            }) catch break;
            if (snippet_text.len > 0) {
                w.print("   {s}\n", .{snippet_text}) catch break;
            }
            w.writeByte('\n') catch break;
        }

        if (count == 0) {
            output.deinit(self.allocator);
            return self.allocator.dupe(u8, "no results found");
        }

        const final = output.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
        _ = self.queues.output.push(.tool_done, final);
        return final;
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

        // use find command as backend
        var cmd_buf: [1024]u8 = undefined;
        var dir_buf: [256]u8 = undefined;
        const dir = if (search_path) |p| (unescapeJSON(p, &dir_buf) orelse p) else ".";

        // Handle ** glob patterns: find -name doesn't support **
        // Convert **/* to just find all files; *.ext to find -name '*.ext'
        const cmd = blk: {
            if (std.mem.indexOf(u8, real_pattern, "**") != null) {
                // ** means recursive — just list all files, optionally filtered by extension
                // Extract extension filter if pattern is like **/*.ext
                if (std.mem.lastIndexOfScalar(u8, real_pattern, '.')) |dot| {
                    const ext = real_pattern[dot..];
                    break :blk std.fmt.bufPrint(&cmd_buf, "find {s} -type f -name '*{s}' 2>/dev/null | head -200 | sort", .{ dir, ext }) catch return error.PatternTooLong;
                }
                break :blk std.fmt.bufPrint(&cmd_buf, "find {s} -type f 2>/dev/null | head -200 | sort", .{dir}) catch return error.PatternTooLong;
            }
            break :blk std.fmt.bufPrint(&cmd_buf, "find {s} -name '{s}' -type f 2>/dev/null | head -200 | sort", .{ dir, real_pattern }) catch return error.PatternTooLong;
        };

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
    input_tokens: *u32,
    output_tokens: *u32,
) void {
    // Extract "type" field
    const type_val = jsonGetStr(data, "type") orelse return;

    // message_start has input token count
    if (std.mem.eql(u8, type_val, "message_start")) {
        if (jsonGetInt(data, "input_tokens")) |n| input_tokens.* = @intCast(n);
        return;
    }
    // message_delta has output token count
    if (std.mem.eql(u8, type_val, "message_delta")) {
        if (jsonGetInt(data, "output_tokens")) |n| output_tokens.* = @intCast(n);
        return;
    }

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
                queues.output.pushWait(.text_delta, decoded);
            }
            return;
        }
        // thinking delta — ignore (internal reasoning)
        if (std.mem.indexOf(u8, data, "\"thinking_delta\"") != null) return;
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
        queues.output.pushWait(.text_delta, decoded);
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

/// Extract integer value from JSON by key
fn jsonGetInt(json: []const u8, key: []const u8) ?u64 {
    var key_buf: [128]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&key_buf, "\"{s}\":", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, json, quoted_key) orelse return null;
    const after = json[idx + quoted_key.len..];
    const trimmed = std.mem.trimLeft(u8, after, " \t");
    // Find the end of the number
    var end: usize = 0;
    while (end < trimmed.len and (trimmed[end] >= '0' and trimmed[end] <= '9')) : (end += 1) {}
    if (end == 0) return null;
    return std.fmt.parseInt(u64, trimmed[0..end], 10) catch null;
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

/// Public wrapper for unescapeJSON (used by builtins for log display)
pub fn unescapeJSONPublic(src: []const u8, dest: []u8) ?[]const u8 {
    return unescapeJSON(src, dest);
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
            else => {
                if (c < 0x20) {
                    // escape control characters as \u00XX
                    try w.writeAll("\\u00");
                    const hex = "0123456789abcdef";
                    try w.writeByte(hex[c >> 4]);
                    try w.writeByte(hex[c & 0x0f]);
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

// ============================================================
// Markdown terminal renderer (streaming-aware)
// ============================================================

/// Tracks state for rendering markdown with ANSI codes across streamed chunks
pub const MarkdownRenderer = struct {
    in_code_block: bool = false,
    in_bold: bool = false,
    in_inline_code: bool = false,
    line_start: bool = true,

    /// Process a chunk of text and write ANSI-formatted output
    pub fn render(self: *MarkdownRenderer, writer: anytype, text: []const u8) !void {
        var i: usize = 0;
        while (i < text.len) {
            const c = text[i];

            // Handle code blocks (```)
            if (c == '`') {
                // Check for ``` (code block fence)
                if (i + 2 < text.len and text[i + 1] == '`' and text[i + 2] == '`') {
                    if (!self.in_code_block) {
                        self.in_code_block = true;
                        // Skip language identifier on same line
                        var skip = i + 3;
                        while (skip < text.len and text[skip] != '\n') : (skip += 1) {}
                        // Print header bar
                        // Extract lang name if present
                        const lang = std.mem.trim(u8, text[i + 3 .. skip], " \t\r");
                        if (lang.len > 0) {
                            try writer.writeAll("\x1b[90m─── ");
                            try writer.writeAll(lang);
                            try writer.writeAll(" ───\x1b[0m\n");
                        } else {
                            try writer.writeAll("\x1b[90m──────────\x1b[0m\n");
                        }
                        try writer.writeAll("\x1b[36m"); // cyan for code
                        i = if (skip < text.len) skip + 1 else skip;
                        self.line_start = true;
                        continue;
                    } else {
                        self.in_code_block = false;
                        try writer.writeAll("\x1b[0m");
                        try writer.writeAll("\x1b[90m──────────\x1b[0m");
                        i += 3;
                        // skip rest of line
                        while (i < text.len and text[i] != '\n') : (i += 1) {}
                        self.line_start = true;
                        continue;
                    }
                }

                // Inline code (single `)
                if (!self.in_code_block) {
                    if (!self.in_inline_code) {
                        self.in_inline_code = true;
                        try writer.writeAll("\x1b[36m"); // cyan
                    } else {
                        self.in_inline_code = false;
                        try writer.writeAll("\x1b[0m");
                    }
                    i += 1;
                    continue;
                }
            }

            // Inside code blocks, just pass through (already colored)
            if (self.in_code_block) {
                try writer.writeByte(c);
                self.line_start = (c == '\n');
                i += 1;
                continue;
            }

            // Headers at line start
            if (self.line_start and c == '#') {
                var level: usize = 0;
                var hi = i;
                while (hi < text.len and text[hi] == '#') : (hi += 1) { level += 1; }
                if (hi < text.len and text[hi] == ' ') {
                    // It's a header
                    try writer.writeAll("\x1b[1;33m"); // bold yellow
                    i = hi + 1; // skip "# "
                    // Write the rest of the line
                    while (i < text.len and text[i] != '\n') {
                        try writer.writeByte(text[i]);
                        i += 1;
                    }
                    try writer.writeAll("\x1b[0m");
                    if (i < text.len) {
                        try writer.writeByte('\n');
                        i += 1;
                    }
                    self.line_start = true;
                    continue;
                }
            }

            // Bold (**text**)
            if (c == '*' and i + 1 < text.len and text[i + 1] == '*') {
                if (!self.in_bold) {
                    self.in_bold = true;
                    try writer.writeAll("\x1b[1m"); // bold
                } else {
                    self.in_bold = false;
                    try writer.writeAll("\x1b[0m");
                }
                i += 2;
                continue;
            }

            // List items at line start
            if (self.line_start and (c == '-' or c == '*') and i + 1 < text.len and text[i + 1] == ' ') {
                try writer.writeAll("\x1b[33m•\x1b[0m "); // yellow bullet
                i += 2;
                self.line_start = false;
                continue;
            }

            // Numbered list at line start
            if (self.line_start and c >= '0' and c <= '9') {
                var ni = i;
                while (ni < text.len and text[ni] >= '0' and text[ni] <= '9') : (ni += 1) {}
                if (ni < text.len and text[ni] == '.' and ni + 1 < text.len and text[ni + 1] == ' ') {
                    try writer.writeAll("\x1b[33m");
                    try writer.writeAll(text[i..ni + 1]);
                    try writer.writeAll("\x1b[0m ");
                    i = ni + 2;
                    self.line_start = false;
                    continue;
                }
            }

            try writer.writeByte(c);
            self.line_start = (c == '\n');
            i += 1;
        }
    }

    pub fn reset(self: *MarkdownRenderer) void {
        self.* = .{};
    }
};

// ============================================================
// Public API — thread entry point
// ============================================================

pub const AgentContext = struct {
    queues: AgentQueues = .{},
    thread: ?std.Thread = null,
    allocator: std.mem.Allocator,
    model_override: [64]u8 = undefined,
    model_override_len: u8 = 0,

    pub fn init(allocator: std.mem.Allocator) AgentContext {
        return .{ .allocator = allocator };
    }

    /// Set a model override for the next agent thread start
    pub fn setModel(self: *AgentContext, model: []const u8) void {
        const n = @min(model.len, 64);
        @memcpy(self.model_override[0..n], model[0..n]);
        self.model_override_len = @intCast(n);
    }

    pub fn getModelOverride(self: *const AgentContext) ?[]const u8 {
        if (self.model_override_len == 0) return null;
        return self.model_override[0..self.model_override_len];
    }

    pub fn start(self: *AgentContext) !void {
        if (self.thread != null) return;
        self.thread = try std.Thread.spawn(.{}, agentThreadFn, .{ self.allocator, &self.queues, self.getModelOverride() });
    }

    pub fn stop(self: *AgentContext) void {
        if (self.thread) |t| {
            _ = self.queues.request.push(.cancel, "");
            t.join();
            self.thread = null;
        }
    }

    /// Send a query to the agent. Returns false if queue is full.
    /// Queries are queued and processed sequentially — safe to call while agent is busy.
    pub fn query(self: *AgentContext, text: []const u8) bool {
        // auto-start agent thread if not running (e.g. in -c mode)
        if (self.thread == null) self.start() catch return false;
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
                .usage_info => {
                    try writer.writeAll("\x1b[90m");
                    try writer.writeAll(msg.slice());
                    try writer.writeAll("\x1b[0m\n");
                },
                .router_info => {
                    try writer.writeAll("\x1b[90m[");
                    try writer.writeAll(msg.slice());
                    try writer.writeAll("]\x1b[0m\n");
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

/// Subagent thread: runs a single query, stores result, exits.
/// Has read-only tools (Read/Glob/Grep/Bash). No confirmation needed.
fn subAgentThreadFn(
    allocator: std.mem.Allocator,
    sa: *SubAgent,
    prompt_owned: []const u8,
    config: Config,
    sys_prompt: *const [8192]u8,
    sys_prompt_len: u16,
) void {
    defer allocator.free(prompt_owned);

    // Create a minimal agent — no session log, no plugin tools, auto-allow all
    var dummy_queues: AgentQueues = .{};
    var agent = AgentThread{
        .allocator = allocator,
        .queues = &dummy_queues,
        .config = config,
        .history = ConversationHistory.init(allocator),
        .session_log = null,
        .cwd = undefined,
        .cwd_len = 0,
        .git_branch = undefined,
        .git_branch_len = 0,
        .system_prompt_buf = sys_prompt.*,
        .system_prompt_len = sys_prompt_len,
        .plugin_tools = [_]PluginTool{.{}} ** MAX_PLUGIN_TOOLS,
        .plugin_count = 0,
        .all_tools_json = undefined,
        .all_tools_json_len = 0,
        .allow_bash = true,
        .allow_edit = false,
        .allow_write = false,
        .allow_plugins = 0,
    };
    // Set cwd
    const cwd = std.process.getCwd(&agent.cwd) catch "/";
    agent.cwd_len = @intCast(cwd.len);

    // Build subagent-specific tools (read-only: Bash, Read, Glob, Grep — no Edit/Write/Agent)
    const SUBAGENT_TOOLS =
        \\[
        \\{"name":"Bash","description":"Run a shell command.","input_schema":{"type":"object","properties":{"command":{"type":"string","description":"Shell command to run"}},"required":["command"]}},
        \\{"name":"Read","description":"Read a file. Returns contents with line numbers.","input_schema":{"type":"object","properties":{"file_path":{"type":"string","description":"Absolute path to the file"},"offset":{"type":"integer","description":"Line offset (optional)"},"limit":{"type":"integer","description":"Max lines (optional)"}},"required":["file_path"]}},
        \\{"name":"Glob","description":"Find files matching a glob pattern.","input_schema":{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern"},"path":{"type":"string","description":"Directory (default: cwd)"}},"required":["pattern"]}},
        \\{"name":"Grep","description":"Search file contents with regex.","input_schema":{"type":"object","properties":{"pattern":{"type":"string","description":"Regex pattern"},"path":{"type":"string","description":"File or directory"},"glob":{"type":"string","description":"Filter files by glob"}},"required":["pattern"]}}
        \\]
    ;
    @memcpy(agent.all_tools_json[0..SUBAGENT_TOOLS.len], SUBAGENT_TOOLS);
    agent.all_tools_json_len = SUBAGENT_TOOLS.len;

    defer agent.history.deinit();

    // Add a system instruction for the subagent role
    agent.history.add(.user, prompt_owned) catch {
        sa.setResult("Failed to add prompt to history", .failed);
        return;
    };
    if (agent.session_log) |*sl| sl.logUser(prompt_owned) catch {};

    // Process with tool loop (same as main agent but limited iterations)
    var iteration: usize = 0;
    const max_iter: usize = 15;
    var final_text: []const u8 = "";
    var final_alloc: ?[]u8 = null;
    defer if (final_alloc) |fa| allocator.free(fa);

    while (iteration < max_iter) : (iteration += 1) {
        if (sa.checkCancel()) {
            sa.setResult("Cancelled", .failed);
            return;
        }

        const response = agent.callAPI() catch |err| {
            var errbuf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&errbuf, "API error: {}", .{err}) catch "API error";
            sa.setResult(msg, .failed);
            return;
        };

        if (!response.has_tool_call) {
            // Final text response
            if (response.text.len > 0) {
                final_text = response.text;
                // Keep alloc alive until we copy to result
                if (final_alloc) |fa| allocator.free(fa);
                final_alloc = response.text_alloc;
            } else {
                allocator.free(response.text_alloc);
            }
            break;
        }

        // Tool use — dispatch it
        const tool_name = response.tool_name;
        const tool_input = response.tool_command;
        const tool_id = response.tool_use_id;

        // Build assistant history entry
        var assist_buf: [MAX_CONTENT_LEN]u8 = undefined;
        var assist_fbs = std.io.fixedBufferStream(&assist_buf);
        const aw = assist_fbs.writer();
        aw.writeByte('[') catch {};
        if (response.text.len > 0) {
            aw.writeAll("{\"type\":\"text\",\"text\":") catch {};
            writeJSONString(aw, response.text) catch {};
            aw.writeAll("},") catch {};
        }
        const effective_input = if (tool_input.len == 0) "{}" else tool_input;
        aw.print("{{\"type\":\"tool_use\",\"id\":\"{s}\",\"name\":\"{s}\",\"input\":{s}}}", .{
            tool_id, tool_name, effective_input,
        }) catch {};
        aw.writeByte(']') catch {};
        agent.history.addKind(.assistant, .tool_use_response, assist_buf[0..assist_fbs.pos]) catch {};
        allocator.free(response.text_alloc);

        // Dispatch tool (subagent: no Edit/Write/Agent, auto-allow Bash)
        const tool_output = agent.dispatchTool(tool_name, tool_input) catch |err| blk: {
            var errbuf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&errbuf, "tool error: {}", .{err}) catch "tool error";
            break :blk allocator.dupe(u8, msg) catch {
                sa.setResult("alloc failed", .failed);
                return;
            };
        };
        defer allocator.free(tool_output);

        // Build tool_result
        const MAX_TOOL_OUTPUT = 16384;
        const truncated = tool_output.len > MAX_TOOL_OUTPUT;
        const effective_output = if (truncated) tool_output[0..MAX_TOOL_OUTPUT] else tool_output;
        const extra: usize = if (truncated) 100 else 0;
        var result_json_buf = allocator.alloc(u8, effective_output.len * 2 + 256 + extra) catch {
            sa.setResult("alloc failed", .failed);
            return;
        };
        defer allocator.free(result_json_buf);
        var result_fbs = std.io.fixedBufferStream(result_json_buf);
        const rw = result_fbs.writer();
        rw.print("[{{\"type\":\"tool_result\",\"tool_use_id\":\"{s}\",\"content\":", .{tool_id}) catch {};
        if (truncated) {
            // Manually write JSON string with truncation notice inside
            rw.writeByte('"') catch {};
            for (effective_output) |c| {
                switch (c) {
                    '"' => rw.writeAll("\\\"") catch {},
                    '\\' => rw.writeAll("\\\\") catch {},
                    '\n' => rw.writeAll("\\n") catch {},
                    '\r' => rw.writeAll("\\r") catch {},
                    '\t' => rw.writeAll("\\t") catch {},
                    else => {
                        if (c < 0x20) {
                            rw.writeAll("\\u00") catch {};
                            const hex = "0123456789abcdef";
                            rw.writeByte(hex[c >> 4]) catch {};
                            rw.writeByte(hex[c & 0x0f]) catch {};
                        } else rw.writeByte(c) catch {};
                    },
                }
            }
            rw.writeAll("\\n... [truncated]\"") catch {};
        } else {
            writeJSONString(rw, effective_output) catch {};
        }
        rw.writeAll("}]") catch {};
        agent.history.addKind(.user, .tool_result, result_json_buf[0..result_fbs.pos]) catch {};
    }

    sa.setResult(if (final_text.len > 0) final_text else "No response from subagent", if (final_text.len > 0) .done else .failed);
}

/// Log router decision to ~/.zish/router_log.jsonl for training data.
/// Format: {"q":"query","action":"shell|agent|fan_out","tier":"haiku|sonnet|opus","reason":"...","ts":N}
fn logRouterDecision(query: []const u8, rd: router_mod.RouteDecision) void {
    if (query.len == 0 or query.len > 2048) return;

    var path_buf: [512]u8 = undefined;
    const home = std.process.getEnvVarOwned(std.heap.page_allocator, "HOME") catch return;
    defer std.heap.page_allocator.free(home);
    const path = std.fmt.bufPrint(&path_buf, "{s}/.zish/router_log.jsonl", .{home}) catch return;

    const file = std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch |e| switch (e) {
        error.FileNotFound => std.fs.cwd().createFile(path, .{}) catch return,
        else => return,
    };
    defer file.close();
    file.seekFromEnd(0) catch return;

    const action_str = switch (rd.action) {
        .shell => "shell",
        .agent => "agent",
        .fan_out => "fan_out",
    };
    const tier_str = switch (rd.model_tier) {
        .haiku => "haiku",
        .sonnet => "sonnet",
        .opus => "opus",
    };
    const ts: u64 = @bitCast(std.time.timestamp());
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;

    // Manual JSON building (zero-alloc, same pattern as other log functions)
    const prefix = "{\"q\":\"";
    if (pos + prefix.len < buf.len) { @memcpy(buf[pos..][0..prefix.len], prefix); pos += prefix.len; }
    // escape query
    for (query) |c| {
        if (pos + 6 >= buf.len) break;
        switch (c) {
            '"' => { @memcpy(buf[pos..][0..2], "\\\""); pos += 2; },
            '\\' => { @memcpy(buf[pos..][0..2], "\\\\"); pos += 2; },
            '\n' => { @memcpy(buf[pos..][0..2], "\\n"); pos += 2; },
            '\r' => { @memcpy(buf[pos..][0..2], "\\r"); pos += 2; },
            '\t' => { @memcpy(buf[pos..][0..2], "\\t"); pos += 2; },
            else => if (c < 0x20) {
                const hex = std.fmt.bufPrint(buf[pos..], "\\u{x:0>4}", .{c}) catch break;
                pos += hex.len;
            } else { buf[pos] = c; pos += 1; },
        }
    }
    const mid = std.fmt.bufPrint(buf[pos..], "\",\"action\":\"{s}\",\"tier\":\"{s}\",\"reason\":\"", .{ action_str, tier_str }) catch return;
    pos += mid.len;
    // escape reason
    for (rd.reason_buf[0..rd.reason_len]) |c| {
        if (pos + 6 >= buf.len) break;
        switch (c) {
            '"' => { @memcpy(buf[pos..][0..2], "\\\""); pos += 2; },
            '\\' => { @memcpy(buf[pos..][0..2], "\\\\"); pos += 2; },
            else => { buf[pos] = c; pos += 1; },
        }
    }
    const suffix = std.fmt.bufPrint(buf[pos..], "\",\"ts\":{d}}}\n", .{ts}) catch return;
    pos += suffix.len;
    _ = file.write(buf[0..pos]) catch {};
}

fn agentThreadFn(allocator: std.mem.Allocator, queues: *AgentQueues, model_override: ?[]const u8) void {
    var ac = log_mod.AgentConfig.load(allocator);
    var config = Config.fromAgentConfig(ac);
    if (model_override) |m| config.model = m;
    const rc = Config.buildRouterConfig(ac);
    var agent = AgentThread.init(allocator, queues, config, rc);
    // Config slices now point into ac's tracked buffers — must keep ac alive
    // until agent is done, then free both
    defer {
        agent.deinit();
        ac.deinit();
    }
    agent.run();
}
