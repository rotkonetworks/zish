// agent_tools.zig - Tool dispatch and execution for the agent
// Extracted from agent.zig as Phase 1 of "Your Server as a Function" refactoring.
// All functions are free (non-method) and take explicit parameters via ToolContext.

const std = @import("std");
const q = @import("agent_queue.zig");
const log_mod = @import("agent_log.zig");

pub const AgentQueues = q.AgentQueues;
pub const SessionLog = log_mod.SessionLog;

// ============================================================
// Plugin tools — loaded from ~/.zish/agent-tools.json
// ============================================================

pub const MAX_PLUGIN_TOOLS = 16;
const MAX_PLUGIN_PARAMS = 8;

pub const PluginParam = struct {
    name_buf: [64]u8 = undefined,
    name_len: u8 = 0,
    type_buf: [16]u8 = undefined,
    type_len: u8 = 0,
    desc_buf: [256]u8 = undefined,
    desc_len: u16 = 0,

    pub fn name(self: *const PluginParam) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    pub fn desc(self: *const PluginParam) []const u8 {
        return self.desc_buf[0..self.desc_len];
    }
    pub fn paramType(self: *const PluginParam) []const u8 {
        if (self.type_len == 0) return "string";
        return self.type_buf[0..self.type_len];
    }
};

pub const PluginTool = struct {
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

    pub fn name(self: *const PluginTool) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    pub fn desc(self: *const PluginTool) []const u8 {
        return self.desc_buf[0..self.desc_len];
    }
    pub fn command(self: *const PluginTool) []const u8 {
        return self.cmd_buf[0..self.cmd_len];
    }
};

// ============================================================
// Subagent dispatch callback
// ============================================================

/// Function pointer type for spawning a subagent and collecting its result.
/// Called when the Agent tool is dispatched.
/// Returns allocated result text that the caller must free.
pub const SpawnAndCollectFn = *const fn (
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    prompt: []const u8,
    description: []const u8,
    full_tools: bool,
) error{ TooDeep, TooManySubagents, SpawnFailed, OutOfMemory }![]u8;

// ============================================================
// ToolContext — bundles common parameters for tool functions
// ============================================================

pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    queues: *AgentQueues,
    allow_bash: *bool,
    allow_edit: *bool,
    allow_write: *bool,
    allow_plugins: *u16,
    session_log: ?*SessionLog,
    plugin_tools: []PluginTool,
    plugin_count: u8,
    /// Callback for the "Agent" tool — spawns subagent, waits for result
    spawn_and_collect: ?SpawnAndCollectFn,
    spawn_ctx: ?*anyopaque,
    /// Agent identity for bulletin posts
    agent_id: []const u8 = "main",
    agent_depth: u8 = 0,
    /// Working directory for this agent. Worktree path for workers, null = process cwd.
    cwd: ?[]const u8 = null,

    /// Broadcast to the shared bulletin board (the commons).
    pub fn broadcast(self: *const ToolContext, kind: q.PostKind, text: []const u8) void {
        self.queues.bulletin.post(kind, self.agent_id, self.agent_depth, text);
    }

    /// Resolve a file path relative to this agent's cwd.
    /// Returns the path as-is if absolute, or prepends cwd if relative.
    pub fn resolvePath(self: *const ToolContext, path: []const u8, buf: *[512]u8) []const u8 {
        if (path.len > 0 and path[0] == '/') return path; // already absolute
        if (self.cwd) |c| {
            return std.fmt.bufPrint(buf, "{s}/{s}", .{ c, path }) catch path;
        }
        return path;
    }
};

// ============================================================
// Path resolution helper for tool executors
// ============================================================

fn resolvePath(path: []const u8, cwd: ?[]const u8, buf: *[512]u8) []const u8 {
    if (path.len > 0 and path[0] == '/') return path;
    if (cwd) |c| {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ c, path }) catch path;
    }
    return path;
}

// ============================================================
// Confirmation flow
// ============================================================

pub const ConfirmResult = enum { deny, allow_once, allow_always };

pub fn waitForConfirm(queues: *AgentQueues, command_text: []const u8) ConfirmResult {
    // Send confirmation request to main thread
    var confirm_buf: [512]u8 = undefined;
    const confirm_msg = std.fmt.bufPrint(&confirm_buf, "Execute: {s}", .{command_text}) catch command_text;
    queues.output.pushWait(.confirm_request, confirm_msg);

    // Wait for response (up to 60 seconds)
    var msg: q.Msg = undefined;
    var ticks: usize = 0;
    while (ticks < 6000) : (ticks += 1) {
        if (queues.checkCancel()) return .deny;
        if (queues.request.pop(&msg)) {
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

pub fn confirmTool(queues: *AgentQueues, tool_name: []const u8, detail: []const u8, allowed: *bool) bool {
    if (allowed.*) return true;
    const result = waitForConfirm(queues, detail);
    switch (result) {
        .deny => return false,
        .allow_once => return true,
        .allow_always => {
            allowed.* = true;
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Auto-allowing {s} for this session", .{tool_name}) catch "Auto-allowed";
            _ = queues.output.push(.tool_call, msg);
            return true;
        },
    }
}

// ============================================================
// Shell escape
// ============================================================

/// Shell-escape a value for safe inclusion in a command
pub fn shellEscape(value: []const u8, buf: []u8) ?[]const u8 {
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
// Plugin tool loading
// ============================================================

/// Load plugin tools from ~/.zish/agent-tools.json
/// Format: [{"name":"...", "description":"...", "command":"...", "confirm":true,
///           "parameters":{"param":{"type":"string","description":"..."}},
///           "required":["param"]}]
pub fn loadPluginTools(tools: *[MAX_PLUGIN_TOOLS]PluginTool) u8 {
    const alloc = std.heap.page_allocator;
    const home = std.process.getEnvVarOwned(alloc, "HOME") catch return 0;
    defer alloc.free(home);

    var count: u8 = 0;

    // 1. Load from ~/.zish/agent-tools.json (legacy single-file format)
    {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/.zish/agent-tools.json", .{home}) catch "";
        if (path.len > 0) {
            const content = std.fs.cwd().readFileAlloc(alloc, path, 32768) catch null;
            if (content) |c| {
                defer alloc.free(c);
                count = parseToolArray(c, tools, count);
            }
        }
    }

    // 2. Load from ~/.zish/tools/ directory (one .json file per tool)
    {
        var dir_buf: [512]u8 = undefined;
        const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/.zish/tools", .{home}) catch "";
        if (dir_path.len > 0) {
            var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return count;
            defer dir.close();
            var iter = dir.iterate();
            while (iter.next() catch null) |entry| {
                if (count >= MAX_PLUGIN_TOOLS) break;
                if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
                const content = dir.readFileAlloc(alloc, entry.name, 32768) catch continue;
                defer alloc.free(content);
                // Single tool file can be either { ... } or [ { ... }, ... ]
                const trimmed = std.mem.trimLeft(u8, content, " \t\n\r");
                if (trimmed.len > 0 and trimmed[0] == '[') {
                    count = parseToolArray(content, tools, count);
                } else if (trimmed.len > 0 and trimmed[0] == '{') {
                    parsePluginTool(trimmed, &tools[count]);
                    if (tools[count].name_len > 0) count += 1;
                }
            }
        }
    }

    return count;
}

fn parseToolArray(content: []const u8, tools: *[MAX_PLUGIN_TOOLS]PluginTool, start_count: u8) u8 {
    var count = start_count;
    var depth: i32 = 0;
    var obj_start: ?usize = null;
    var in_string = false;
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        if (content[i] == '\\' and in_string) {
            i += 1;
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

pub fn parsePluginTool(json: []const u8, tool: *PluginTool) void {
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

pub fn parsePluginParams(params_json: []const u8, tool: *PluginTool) void {
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
pub fn buildToolsJson(plugins: []const PluginTool, count: u8, buf: []u8, builtin_tools_json: []const u8) u16 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    // Start with built-in tools (strip outer [] from TOOLS_JSON)
    w.writeByte('[') catch return 0;
    const inner = std.mem.trim(u8, builtin_tools_json, " \n\r\t");
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

// ============================================================
// JSON helpers (used by tools internally)
// ============================================================

/// Extract string value from JSON by key (no allocation, returns raw escaped slice)
pub fn jsonGetStr(json: []const u8, key: []const u8) ?[]const u8 {
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

/// Extract a field value from tool input JSON
pub fn extractJsonField(json: []const u8, key: []const u8) ?[]const u8 {
    return jsonGetStr(json, key);
}

/// Unescape JSON string escapes (\n, \t, \\, \") into dest buffer
/// Returns slice of dest on success, null if dest too small
pub fn unescapeJSON(src: []const u8, dest: []u8) ?[]const u8 {
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

// ============================================================
// Tool dispatch — main entry point
// ============================================================

pub fn dispatch(ctx: *ToolContext, tool_name: []const u8, tool_input: []const u8) ![]u8 {
    if (std.mem.eql(u8, tool_name, "Bash")) {
        const cmd = extractJsonField(tool_input, "command") orelse return error.MissingCommand;
        var unescape_buf: [8192]u8 = undefined;
        const preview = unescapeJSON(cmd, &unescape_buf) orelse cmd;
        var detail_buf: [512]u8 = undefined;
        const detail = std.fmt.bufPrint(&detail_buf, "$ {s}", .{preview}) catch preview;
        if (!confirmTool(ctx.queues, "Bash", detail, ctx.allow_bash))
            return ctx.allocator.dupe(u8, "Tool execution denied by user.");
        return executeBash(ctx.allocator, ctx.queues, cmd, ctx.cwd);
    }
    if (std.mem.eql(u8, tool_name, "Read")) {
        const path = extractJsonField(tool_input, "file_path") orelse return error.MissingPath;
        const offset_str = extractJsonField(tool_input, "offset");
        const limit_str = extractJsonField(tool_input, "limit");
        const offset: usize = if (offset_str) |s| std.fmt.parseInt(usize, s, 10) catch 0 else 0;
        const limit: usize = if (limit_str) |s| std.fmt.parseInt(usize, s, 10) catch 0 else 0;
        return executeRead(ctx.allocator, ctx.queues, path, offset, limit, ctx.cwd);
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
        if (!confirmTool(ctx.queues, "Edit", detail, ctx.allow_edit))
            return ctx.allocator.dupe(u8, "Tool execution denied by user.");
        return executeEdit(ctx.allocator, ctx.queues, ctx.session_log, path, old_str, new_str, replace_all, ctx.cwd);
    }
    if (std.mem.eql(u8, tool_name, "Write")) {
        const path = extractJsonField(tool_input, "file_path") orelse return error.MissingPath;
        const content = extractJsonField(tool_input, "content") orelse return error.MissingContent;
        var path_buf2: [512]u8 = undefined;
        const rp = unescapeJSON(path, &path_buf2) orelse path;
        var detail_buf: [512]u8 = undefined;
        const detail = std.fmt.bufPrint(&detail_buf, "Write {s}", .{rp}) catch rp;
        if (!confirmTool(ctx.queues, "Write", detail, ctx.allow_write))
            return ctx.allocator.dupe(u8, "Tool execution denied by user.");
        return executeWrite(ctx.allocator, ctx.queues, ctx.session_log, path, content, ctx.cwd);
    }
    if (std.mem.eql(u8, tool_name, "Glob")) {
        const pattern = extractJsonField(tool_input, "pattern") orelse return error.MissingPattern;
        const path = extractJsonField(tool_input, "path");
        return executeGlob(ctx.allocator, ctx.queues, pattern, path, ctx.cwd);
    }
    if (std.mem.eql(u8, tool_name, "Grep")) {
        const pattern = extractJsonField(tool_input, "pattern") orelse return error.MissingPattern;
        const path = extractJsonField(tool_input, "path");
        const file_glob = extractJsonField(tool_input, "glob");
        return executeGrep(ctx.allocator, ctx.queues, pattern, path, file_glob, ctx.cwd);
    }
    if (std.mem.eql(u8, tool_name, "Agent")) {
        const prompt_raw = extractJsonField(tool_input, "prompt") orelse return error.MissingPrompt;
        const desc_raw = extractJsonField(tool_input, "description") orelse "subagent task";
        var prompt_buf: [4096]u8 = undefined;
        const prompt = unescapeJSON(prompt_raw, &prompt_buf) orelse prompt_raw;
        var desc_buf2: [128]u8 = undefined;
        const description = unescapeJSON(desc_raw, &desc_buf2) orelse desc_raw;
        if (ctx.spawn_and_collect) |spawn_fn| {
            const result = spawn_fn(ctx.spawn_ctx.?, ctx.allocator, prompt, description, ctx.allow_edit.*) catch |err| {
                var errbuf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&errbuf, "Failed to spawn subagent: {}", .{err}) catch "spawn failed";
                return ctx.allocator.dupe(u8, msg);
            };
            return result;
        }
        return ctx.allocator.dupe(u8, "Agent tool not available in this context");
    }
    if (std.mem.eql(u8, tool_name, "WebFetch")) {
        const url = extractJsonField(tool_input, "url") orelse return error.MissingURL;
        const max_str = extractJsonField(tool_input, "max_bytes");
        const max_bytes: usize = if (max_str) |s| std.fmt.parseInt(usize, s, 10) catch 32768 else 32768;
        return executeWebFetch(ctx.allocator, ctx.queues, url, max_bytes);
    }
    if (std.mem.eql(u8, tool_name, "WebSearch")) {
        const query = extractJsonField(tool_input, "query") orelse return error.MissingQuery;
        const max_str = extractJsonField(tool_input, "max_results");
        const max_results: usize = if (max_str) |s| std.fmt.parseInt(usize, s, 10) catch 8 else 8;
        return executeWebSearch(ctx.allocator, ctx.queues, query, max_results);
    }
    if (std.mem.eql(u8, tool_name, "Post")) {
        const post_type = extractJsonField(tool_input, "type") orelse return error.MissingPostType;
        const message = extractJsonField(tool_input, "message") orelse return error.MissingMessage;
        var msg_buf: [512]u8 = undefined;
        const msg = unescapeJSON(message, &msg_buf) orelse message;
        const kind: q.PostKind = if (std.mem.eql(u8, post_type, "discovery"))
            .discovery
        else if (std.mem.eql(u8, post_type, "escalate"))
            .escalate
        else if (std.mem.eql(u8, post_type, "request_peer"))
            .request_peer
        else if (std.mem.eql(u8, post_type, "vote"))
            .vote
        else
            .discovery;
        ctx.broadcast(kind, msg);
        return ctx.allocator.dupe(u8, "Posted to bulletin.");
    }
    // Check plugin tools
    for (ctx.plugin_tools[0..ctx.plugin_count], 0..) |*pt, pi| {
        if (std.mem.eql(u8, tool_name, pt.name())) {
            return executePluginTool(ctx.allocator, ctx.queues, ctx.allow_plugins, pt, @intCast(pi), tool_input);
        }
    }
    return error.UnknownTool;
}

// ============================================================
// Individual tool executors
// ============================================================

pub fn executeBash(allocator: std.mem.Allocator, queues: *AgentQueues, command: []const u8, cwd: ?[]const u8) ![]u8 {
    // unescape JSON string escapes in the command
    var cmd_buf: [8192]u8 = undefined;
    const cmd = unescapeJSON(command, &cmd_buf) orelse command;

    // notify main thread
    var notif_buf: [512]u8 = undefined;
    const notif = std.fmt.bufPrint(&notif_buf, "Bash {s}", .{cmd}) catch cmd;
    _ = queues.output.push(.tool_call, notif);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "/bin/sh", "-c", cmd },
        .max_output_bytes = 65536,
        .cwd = cwd,
    }) catch |err| {
        var errbuf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&errbuf, "exec failed: {}", .{err}) catch "exec failed";
        return allocator.dupe(u8, msg);
    };
    defer allocator.free(result.stderr);

    _ = queues.output.push(.tool_done, result.stdout);
    return result.stdout;
}

pub fn executeRead(allocator: std.mem.Allocator, queues: *AgentQueues, path: []const u8, offset: usize, limit: usize, cwd: ?[]const u8) ![]u8 {
    var path_buf: [512]u8 = undefined;
    const real_path = unescapeJSON(path, &path_buf) orelse path;
    var resolve_buf: [512]u8 = undefined;
    const resolved = resolvePath(real_path, cwd, &resolve_buf);

    var notif_buf: [512]u8 = undefined;
    if (offset > 0 or limit > 0) {
        const notif = std.fmt.bufPrint(&notif_buf, "Read {s}:{d}", .{ real_path, offset }) catch real_path;
        _ = queues.output.push(.tool_call, notif);
    } else {
        const notif = std.fmt.bufPrint(&notif_buf, "Read {s}", .{real_path}) catch real_path;
        _ = queues.output.push(.tool_call, notif);
    }

    const content = std.fs.cwd().readFileAlloc(allocator, resolved, 512 * 1024) catch |err| {
        var errbuf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&errbuf, "read error: {s}: {}", .{ resolved, err }) catch "read error";
        return allocator.dupe(u8, msg);
    };
    defer allocator.free(content);

    // Add line numbers and apply offset/limit
    var result_list: std.ArrayList(u8) = .{};
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
            result_list.writer(allocator).print("{d:>6}\t", .{line_num}) catch break;
            if (start < content.len) {
                result_list.appendSlice(allocator, content[start..end]) catch break;
            }
            result_list.append(allocator, '\n') catch break;
            lines_output += 1;
        }

        if (end >= content.len) break;
        start = end + 1;
        line_num += 1;
    }

    // Push preview with line numbers for user display
    var preview_list: std.ArrayList(u8) = .{};
    const pw = preview_list.writer(allocator);
    var pstart: usize = 0;
    var pline: usize = start_line;
    const preview_max: usize = 8;
    var pcount: usize = 0;
    const items = result_list.items;
    while (pstart < items.len and pcount < preview_max) {
        const pend = std.mem.indexOfScalarPos(u8, items, pstart, '\n') orelse items.len;
        const line = items[pstart..pend];
        // Line numbers are dim, content normal
        if (line.len > 6 and line[6] == '\t') {
            pw.print("\x1b[90m{s}\x1b[0m{s}\n", .{ line[0..6], line[7..] }) catch break;
        } else {
            pw.writeAll(line) catch break;
            pw.writeByte('\n') catch break;
        }
        pstart = if (pend < items.len) pend + 1 else items.len;
        pline += 1;
        pcount += 1;
    }
    if (lines_output > preview_max) {
        pw.print("\x1b[90m({d} more lines)\x1b[0m\n", .{lines_output - preview_max}) catch {};
    }
    _ = queues.output.push(.tool_done, preview_list.items);
    return result_list.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

pub fn executeWrite(allocator: std.mem.Allocator, queues: *AgentQueues, session_log: ?*SessionLog, path: []const u8, content: []const u8, cwd: ?[]const u8) ![]u8 {
    var path_buf: [512]u8 = undefined;
    const real_path = unescapeJSON(path, &path_buf) orelse path;
    var resolve_buf: [512]u8 = undefined;
    const resolved = resolvePath(real_path, cwd, &resolve_buf);

    // unescape content
    const content_buf = try allocator.alloc(u8, content.len);
    defer allocator.free(content_buf);
    const real_content = unescapeJSON(content, content_buf) orelse content;

    var notif_buf: [512]u8 = undefined;
    const notif = std.fmt.bufPrint(&notif_buf, "Write {s}", .{real_path}) catch real_path;
    _ = queues.output.push(.tool_call, notif);

    // backup existing file before overwriting
    if (session_log) |sl| sl.backupFile(resolved) catch {};

    const file = std.fs.cwd().createFile(resolved, .{}) catch |err| {
        var errbuf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&errbuf, "write error: {s}: {}", .{ resolved, err }) catch "write error";
        return allocator.dupe(u8, msg);
    };
    defer file.close();
    file.writeAll(real_content) catch |err| {
        var errbuf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&errbuf, "write error: {}", .{err}) catch "write error";
        return allocator.dupe(u8, msg);
    };

    var wcount: usize = 1;
    for (real_content) |wc| { if (wc == '\n') wcount += 1; }
    // Show preview of written content (green, like a diff with all additions)
    var wdone_result: std.ArrayList(u8) = .{};
    const wdw = wdone_result.writer(allocator);
    const max_preview: usize = 4;
    var line_n: usize = 0;
    var witer = std.mem.splitScalar(u8, real_content, '\n');
    while (witer.next()) |line| {
        if (line_n >= max_preview) {
            wdw.print("\x1b[32m+ ... ({d} more)\x1b[0m\n", .{wcount - max_preview}) catch {};
            break;
        }
        wdw.writeAll("\x1b[32m+ ") catch {};
        const show = if (line.len > 60) line[0..60] else line;
        wdw.writeAll(show) catch {};
        if (line.len > 60) wdw.writeAll("...") catch {};
        wdw.writeAll("\x1b[0m\n") catch {};
        line_n += 1;
    }
    _ = queues.output.push(.tool_done, wdone_result.items);
    var result_buf: [128]u8 = undefined;
    const result = std.fmt.bufPrint(&result_buf, "Wrote {d} bytes to {s}", .{ real_content.len, real_path }) catch "ok";
    return allocator.dupe(u8, result);
}

pub fn executeEdit(allocator: std.mem.Allocator, queues: *AgentQueues, session_log: ?*SessionLog, path: []const u8, old_str: []const u8, new_str: []const u8, replace_all: bool, cwd: ?[]const u8) ![]u8 {
    var path_buf: [512]u8 = undefined;
    const real_path = unescapeJSON(path, &path_buf) orelse path;
    var resolve_buf: [512]u8 = undefined;
    const resolved = resolvePath(real_path, cwd, &resolve_buf);

    // Unescape the search and replace strings
    const old_buf = try allocator.alloc(u8, old_str.len);
    defer allocator.free(old_buf);
    const real_old = unescapeJSON(old_str, old_buf) orelse old_str;

    const new_buf = try allocator.alloc(u8, new_str.len);
    defer allocator.free(new_buf);
    const real_new = unescapeJSON(new_str, new_buf) orelse new_str;

    var notif_buf: [512]u8 = undefined;
    const notif = std.fmt.bufPrint(&notif_buf, "Edit {s}", .{real_path}) catch real_path;
    _ = queues.output.push(.tool_call, notif);

    // Read current file content
    const content = std.fs.cwd().readFileAlloc(allocator, resolved, 512 * 1024) catch |err| {
        var errbuf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&errbuf, "edit error: cannot read {s}: {}", .{ resolved, err }) catch "read error";
        return allocator.dupe(u8, msg);
    };
    defer allocator.free(content);

    // Find occurrences
    if (std.mem.indexOf(u8, content, real_old) == null) {
        return allocator.dupe(u8, "edit error: old_string not found in file");
    }

    if (!replace_all) {
        // Check uniqueness
        if (std.mem.indexOf(u8, content, real_old)) |first| {
            if (std.mem.indexOfPos(u8, content, first + real_old.len, real_old) != null) {
                return allocator.dupe(u8, "edit error: old_string found multiple times. Use replace_all:true or provide more context.");
            }
        }
    }

    // Backup before editing
    if (session_log) |sl| sl.backupFile(resolved) catch {};

    // Build new content with replacements
    var result_content: std.ArrayList(u8) = .{};
    defer result_content.deinit(allocator);
    var pos: usize = 0;
    var replacements: usize = 0;

    while (pos < content.len) {
        if (std.mem.indexOfPos(u8, content, pos, real_old)) |match_start| {
            result_content.appendSlice(allocator, content[pos..match_start]) catch return error.OutOfMemory;
            result_content.appendSlice(allocator, real_new) catch return error.OutOfMemory;
            pos = match_start + real_old.len;
            replacements += 1;
            if (!replace_all) break;
        } else {
            result_content.appendSlice(allocator, content[pos..]) catch return error.OutOfMemory;
            break;
        }
    }
    // Append remaining if we broke early
    if (pos < content.len and !replace_all) {
        result_content.appendSlice(allocator, content[pos..]) catch return error.OutOfMemory;
    }

    // Write back
    const file = std.fs.cwd().createFile(resolved, .{}) catch |err| {
        var errbuf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&errbuf, "edit error: cannot write {s}: {}", .{ resolved, err }) catch "write error";
        return allocator.dupe(u8, msg);
    };
    defer file.close();
    file.writeAll(result_content.items) catch |err| {
        var errbuf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&errbuf, "write error: {}", .{err}) catch "write error";
        return allocator.dupe(u8, msg);
    };

    // Show diff summary in tool output (Claude Code style)
    var diff_result: std.ArrayList(u8) = .{};
    const dw = diff_result.writer(allocator);
    // Count added/removed lines
    var old_lines: usize = 1;
    for (real_old) |oc| { if (oc == '\n') old_lines += 1; }
    var new_lines: usize = 1;
    for (real_new) |nc| { if (nc == '\n') new_lines += 1; }
    _ = if (new_lines > old_lines) new_lines - old_lines else 0;
    _ = if (old_lines > new_lines) old_lines - new_lines else 0;
    // Show inline diff preview (Claude Code style)
    // Old lines in red, new lines in green, max 6 lines each
    const max_preview = 6;
    var old_count: usize = 0;
    var old_iter = std.mem.splitScalar(u8, real_old, '\n');
    while (old_iter.next()) |line| {
        if (old_count >= max_preview) {
            dw.print("\x1b[31m- ... ({d} more)\x1b[0m\n", .{old_lines - max_preview}) catch {};
            break;
        }
        dw.writeAll("\x1b[31m- ") catch {};
        const show = if (line.len > 60) line[0..60] else line;
        dw.writeAll(show) catch {};
        if (line.len > 60) dw.writeAll("...") catch {};
        dw.writeAll("\x1b[0m\n") catch {};
        old_count += 1;
    }
    var new_count: usize = 0;
    var new_iter = std.mem.splitScalar(u8, real_new, '\n');
    while (new_iter.next()) |line| {
        if (new_count >= max_preview) {
            dw.print("\x1b[32m+ ... ({d} more)\x1b[0m\n", .{new_lines - max_preview}) catch {};
            break;
        }
        dw.writeAll("\x1b[32m+ ") catch {};
        const show = if (line.len > 60) line[0..60] else line;
        dw.writeAll(show) catch {};
        if (line.len > 60) dw.writeAll("...") catch {};
        dw.writeAll("\x1b[0m\n") catch {};
        new_count += 1;
    }

    _ = queues.output.push(.tool_done, diff_result.items);
    return diff_result.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

pub fn executeWebFetch(allocator: std.mem.Allocator, queues: *AgentQueues, url: []const u8, max_bytes: usize) ![]u8 {
    var url_buf: [2048]u8 = undefined;
    const real_url = unescapeJSON(url, &url_buf) orelse url;

    var notif_buf: [512]u8 = undefined;
    const notif = std.fmt.bufPrint(&notif_buf, "WebFetch {s}", .{real_url}) catch real_url;
    _ = queues.output.push(.tool_call, notif);

    // Use curl to fetch URL content
    const result = std.process.Child.run(.{
        .allocator = allocator,
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
        return allocator.dupe(u8, msg);
    };
    defer allocator.free(result.stderr);

    if (result.stdout.len == 0) {
        allocator.free(result.stdout);
        if (result.stderr.len > 0) {
            return allocator.dupe(u8, result.stderr);
        }
        return allocator.dupe(u8, "empty response");
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
                    text.append(allocator, '&') catch break;
                    si += 5;
                    last_was_space = false;
                    continue;
                }
                if (si + 3 < src.len and std.mem.startsWith(u8, src[si..], "&lt;")) {
                    text.append(allocator, '<') catch break;
                    si += 4;
                    last_was_space = false;
                    continue;
                }
                if (si + 3 < src.len and std.mem.startsWith(u8, src[si..], "&gt;")) {
                    text.append(allocator, '>') catch break;
                    si += 4;
                    last_was_space = false;
                    continue;
                }
                if (si + 5 < src.len and std.mem.startsWith(u8, src[si..], "&quot;")) {
                    text.append(allocator, '"') catch break;
                    si += 6;
                    last_was_space = false;
                    continue;
                }
                if (si + 5 < src.len and std.mem.startsWith(u8, src[si..], "&nbsp;")) {
                    text.append(allocator, ' ') catch break;
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
                    text.append(allocator, ' ') catch break;
                    last_was_space = true;
                }
                si += 1;
                continue;
            }
            if (src[si] == '\n' or src[si] == '\r') {
                if (!last_was_space) {
                    text.append(allocator, '\n') catch break;
                    last_was_space = true;
                }
                si += 1;
                continue;
            }
            text.append(allocator, src[si]) catch break;
            last_was_space = false;
            si += 1;

            if (text.items.len >= max_bytes) break;
        }

        allocator.free(result.stdout);

        // Collapse multiple newlines
        const raw = text.items;
        var clean: std.ArrayList(u8) = .{};
        var ci: usize = 0;
        var consecutive_nl: u8 = 0;
        while (ci < raw.len) {
            if (raw[ci] == '\n') {
                consecutive_nl += 1;
                if (consecutive_nl <= 2)
                    clean.append(allocator, '\n') catch break;
            } else {
                consecutive_nl = 0;
                clean.append(allocator, raw[ci]) catch break;
            }
            ci += 1;
        }
        text.deinit(allocator);

        const final = clean.toOwnedSlice(allocator) catch return error.OutOfMemory;
        _ = queues.output.push(.tool_done, final);
        return final;
    }

    // Non-HTML: return raw content truncated
    if (result.stdout.len > max_bytes) {
        const truncated = try allocator.alloc(u8, max_bytes + 20);
        @memcpy(truncated[0..max_bytes], result.stdout[0..max_bytes]);
        const suffix = "\n... [truncated]";
        @memcpy(truncated[max_bytes..max_bytes + suffix.len], suffix);
        allocator.free(result.stdout);
        const final_len = max_bytes + suffix.len;
        _ = queues.output.push(.tool_done, truncated[0..final_len]);
        return allocator.realloc(truncated, final_len) catch truncated;
    }

    _ = queues.output.push(.tool_done, result.stdout);
    return result.stdout;
}

pub fn executeWebSearch(allocator: std.mem.Allocator, queues: *AgentQueues, query: []const u8, max_results: usize) ![]u8 {
    var query_buf: [1024]u8 = undefined;
    const real_query = unescapeJSON(query, &query_buf) orelse query;

    var notif_buf: [512]u8 = undefined;
    const notif = std.fmt.bufPrint(&notif_buf, "WebSearch {s}", .{real_query}) catch real_query;
    _ = queues.output.push(.tool_call, notif);

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
        .allocator = allocator,
        .argv = &[_][]const u8{
            "curl", "-sS", "-L", "--max-time", "15",
            "-H", "User-Agent: Mozilla/5.0 (compatible; zish/1.0)",
            search_url,
        },
        .max_output_bytes = 256 * 1024,
    }) catch |err| {
        var errbuf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&errbuf, "search failed: {}", .{err}) catch "search failed";
        return allocator.dupe(u8, msg);
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.stdout.len == 0) {
        return allocator.dupe(u8, "no search results");
    }

    // Parse DuckDuckGo HTML results
    var output: std.ArrayList(u8) = .{};
    const w = output.writer(allocator);
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
        output.deinit(allocator);
        return allocator.dupe(u8, "no results found");
    }

    const final = output.toOwnedSlice(allocator) catch return error.OutOfMemory;
    _ = queues.output.push(.tool_done, final);
    return final;
}

pub fn executeGlob(allocator: std.mem.Allocator, queues: *AgentQueues, pattern: []const u8, search_path: ?[]const u8, cwd: ?[]const u8) ![]u8 {
    var pattern_buf: [256]u8 = undefined;
    const real_pattern = unescapeJSON(pattern, &pattern_buf) orelse pattern;

    var notif_buf: [512]u8 = undefined;
    if (search_path) |p| {
        const notif = std.fmt.bufPrint(&notif_buf, "Glob {s} in {s}", .{ real_pattern, p }) catch real_pattern;
        _ = queues.output.push(.tool_call, notif);
    } else {
        const notif = std.fmt.bufPrint(&notif_buf, "Glob {s}", .{real_pattern}) catch real_pattern;
        _ = queues.output.push(.tool_call, notif);
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
        .allocator = allocator,
        .argv = &[_][]const u8{ "/bin/sh", "-c", cmd },
        .max_output_bytes = 65536,
        .cwd = cwd,
    }) catch |err| {
        var errbuf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&errbuf, "glob error: {}", .{err}) catch "glob error";
        return allocator.dupe(u8, msg);
    };
    defer allocator.free(result.stderr);
    // Count result lines for feedback
    var match_count: usize = 0;
    for (result.stdout) |sc| { if (sc == '\n') match_count += 1; }
    var done_buf2: [64]u8 = undefined;
    const done_msg2 = std.fmt.bufPrint(&done_buf2, "{d} files", .{match_count}) catch "";
    _ = queues.output.push(.tool_done, done_msg2);
    return result.stdout;
}

pub fn executeGrep(allocator: std.mem.Allocator, queues: *AgentQueues, pattern: []const u8, search_path: ?[]const u8, file_glob: ?[]const u8, cwd: ?[]const u8) ![]u8 {
    var pattern_buf: [256]u8 = undefined;
    const real_pattern = unescapeJSON(pattern, &pattern_buf) orelse pattern;

    var notif_buf: [512]u8 = undefined;
    const notif = std.fmt.bufPrint(&notif_buf, "Grep {s}", .{real_pattern}) catch real_pattern;
    _ = queues.output.push(.tool_call, notif);

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
        .allocator = allocator,
        .argv = &[_][]const u8{ "/bin/sh", "-c", cmd },
        .max_output_bytes = 65536,
        .cwd = cwd,
    }) catch |err| {
        var errbuf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&errbuf, "grep error: {}", .{err}) catch "grep error";
        return allocator.dupe(u8, msg);
    };
    defer allocator.free(result.stderr);
    var grep_count: usize = 0;
    for (result.stdout) |gc| { if (gc == '\n') grep_count += 1; }
    var grep_done_buf: [64]u8 = undefined;
    const grep_done = std.fmt.bufPrint(&grep_done_buf, "{d} matches", .{grep_count}) catch "";
    _ = queues.output.push(.tool_done, grep_done);
    return result.stdout;
}

pub fn executePluginTool(allocator: std.mem.Allocator, queues: *AgentQueues, allow_plugins: *u16, pt: *const PluginTool, plugin_idx: u4, tool_input: []const u8) ![]u8 {
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
    _ = queues.output.push(.tool_call, notif);

    // Confirmation flow if required
    if (pt.confirm) {
        const bit = @as(u16, 1) << plugin_idx;
        if (allow_plugins.* & bit == 0) {
            const result = waitForConfirm(queues, final_cmd);
            switch (result) {
                .deny => return allocator.dupe(u8, "Tool execution cancelled by user."),
                .allow_once => {},
                .allow_always => {
                    allow_plugins.* |= bit;
                    var abuf: [128]u8 = undefined;
                    const amsg = std.fmt.bufPrint(&abuf, "Auto-allowing {s} for this session", .{pt.name()}) catch "Auto-allowed";
                    _ = queues.output.push(.tool_call, amsg);
                },
            }
        }
    }

    // Execute the command
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "/bin/sh", "-c", final_cmd },
        .max_output_bytes = 65536,
    }) catch |err| {
        var errbuf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&errbuf, "exec failed: {}", .{err}) catch "exec failed";
        return allocator.dupe(u8, msg);
    };
    defer allocator.free(result.stderr);

    _ = queues.output.push(.tool_done, result.stdout);
    return result.stdout;
}
