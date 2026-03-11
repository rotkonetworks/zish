// agent_log.zig - persistent session logging for zish agent
// Stores conversations, tool calls, and file backups under ~/.zish/
//
// Directory layout:
//   ~/.zish/
//     agent.json                  - global config
//     history.jsonl               - all user prompts across sessions
//     sessions/
//       {session-id}/
//         meta.json               - session metadata
//         conversation.jsonl      - full transcript
//         file-backups/
//           {path-hash}@v{n}      - file snapshots
//           index.jsonl           - hash→path mapping
//         subagents/
//           {agent-id}.jsonl      - subagent transcript
//           {agent-id}.meta.json  - subagent type

const std = @import("std");

// ============================================================
// Session ID: {unix-hex}-{random-hex} e.g. "67cfab3c-a1f2"
// ============================================================

pub const SESSION_ID_LEN = 13; // 8 hex + '-' + 4 hex
pub const SessionId = [SESSION_ID_LEN]u8;

pub fn generateSessionId() SessionId {
    var id: SessionId = undefined;
    const ts: u32 = @intCast(@as(u64, @bitCast(std.time.timestamp())) & 0xFFFFFFFF);
    var rand_bytes: [2]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);

    _ = std.fmt.bufPrint(&id, "{x:0>8}-{x:0>4}", .{
        ts,
        @as(u16, @bitCast(rand_bytes)),
    }) catch unreachable;
    return id;
}

// ============================================================
// Base directory management
// ============================================================

const MAX_PATH = 512;

pub fn getBaseDir(buf: *[MAX_PATH]u8) ?[]const u8 {
    const home = std.process.getEnvVarOwned(std.heap.page_allocator, "HOME") catch return null;
    defer std.heap.page_allocator.free(home);
    const len = std.fmt.bufPrint(buf, "{s}/.zish", .{home}) catch return null;
    return len;
}

fn ensureDir(path: []const u8) !void {
    const dir = std.fs.cwd();
    dir.makePath(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

// ============================================================
// Session Log — append-only JSONL writer
// ============================================================

pub const SessionLog = struct {
    session_id: SessionId,
    dir_buf: [MAX_PATH]u8,
    dir_len: u16,
    file: ?std.fs.File,
    allocator: std.mem.Allocator,
    message_count: u32,

    pub fn create(allocator: std.mem.Allocator, cwd: []const u8, git_branch: []const u8, provider: []const u8, model: []const u8) !SessionLog {
        var base_buf: [MAX_PATH]u8 = undefined;
        const base = getBaseDir(&base_buf) orelse return error.NoHomeDir;

        const sid = generateSessionId();

        // create session directory
        var dir_buf: [MAX_PATH]u8 = undefined;
        const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/sessions/{s}", .{ base, sid }) catch return error.PathTooLong;
        try ensureDir(dir_path);

        // write meta.json
        var meta_path_buf: [MAX_PATH]u8 = undefined;
        const meta_path = std.fmt.bufPrint(&meta_path_buf, "{s}/meta.json", .{dir_path}) catch return error.PathTooLong;
        const meta_file = try std.fs.cwd().createFile(meta_path, .{});
        defer meta_file.close();

        const ts = std.time.timestamp();
        var meta_buf: [1024]u8 = undefined;
        const meta_json = std.fmt.bufPrint(&meta_buf,
            \\{{"id":"{s}","created":{d},"cwd":"{s}","git_branch":"{s}","provider":"{s}","model":"{s}","message_count":0,"status":"active"}}
        , .{ sid, ts, cwd, git_branch, provider, model }) catch return error.MetaTooLong;
        try meta_file.writeAll(meta_json);

        // open conversation.jsonl
        var conv_path_buf: [MAX_PATH]u8 = undefined;
        const conv_path = std.fmt.bufPrint(&conv_path_buf, "{s}/conversation.jsonl", .{dir_path}) catch return error.PathTooLong;
        const conv_file = try std.fs.cwd().createFile(conv_path, .{ .truncate = false });

        // append to global history index
        appendSessionIndex(base, &sid, ts, cwd) catch {};

        var log = SessionLog{
            .session_id = sid,
            .dir_buf = undefined,
            .dir_len = @intCast(dir_path.len),
            .file = conv_file,
            .allocator = allocator,
            .message_count = 0,
        };
        @memcpy(log.dir_buf[0..dir_path.len], dir_path);
        return log;
    }

    pub fn open(allocator: std.mem.Allocator, session_id: []const u8) !SessionLog {
        var base_buf: [MAX_PATH]u8 = undefined;
        const base = getBaseDir(&base_buf) orelse return error.NoHomeDir;

        var dir_buf: [MAX_PATH]u8 = undefined;
        const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/sessions/{s}", .{ base, session_id }) catch return error.PathTooLong;

        var conv_path_buf: [MAX_PATH]u8 = undefined;
        const conv_path = std.fmt.bufPrint(&conv_path_buf, "{s}/conversation.jsonl", .{dir_path}) catch return error.PathTooLong;

        const conv_file = std.fs.cwd().openFile(conv_path, .{ .mode = .write_only }) catch return error.SessionNotFound;
        conv_file.seekFromEnd(0) catch {};

        var log = SessionLog{
            .session_id = undefined,
            .dir_buf = undefined,
            .dir_len = @intCast(dir_path.len),
            .file = conv_file,
            .allocator = allocator,
            .message_count = 0,
        };
        const sid_len = @min(session_id.len, SESSION_ID_LEN);
        @memcpy(log.session_id[0..sid_len], session_id[0..sid_len]);
        @memcpy(log.dir_buf[0..dir_path.len], dir_path);
        return log;
    }

    pub fn close(self: *SessionLog) void {
        if (self.file) |f| {
            f.close();
            self.file = null;
        }
        // remove ctl FIFO (signals session is no longer active)
        var ctl_buf: [MAX_PATH]u8 = undefined;
        if (self.ctlPath(&ctl_buf)) |p| {
            std.fs.cwd().deleteFile(p) catch {};
        }
        // update meta.json with final message count
        self.updateMeta() catch {};
    }

    fn dirPath(self: *const SessionLog) []const u8 {
        return self.dir_buf[0..self.dir_len];
    }

    /// Path to the control FIFO for remote attach
    pub fn ctlPath(self: *const SessionLog, buf: *[MAX_PATH]u8) ?[]const u8 {
        return std.fmt.bufPrint(buf, "{s}/ctl", .{self.dirPath()}) catch null;
    }

    /// Create the ctl FIFO. Returns the fd opened for read+write (non-blocking).
    /// Opened RDWR so the agent itself keeps a writer reference, preventing
    /// EOF when an attached client disconnects.
    pub fn createCtlFifo(self: *const SessionLog) ?std.posix.fd_t {
        var path_buf: [MAX_PATH]u8 = undefined;
        const path = self.ctlPath(&path_buf) orelse return null;
        // Create FIFO (named pipe) via mknod with S.IFIFO
        const path_z = toNullTerminated(path) orelse return null;
        _ = std.os.linux.mknod(path_z, std.os.linux.S.IFIFO | 0o660, 0);
        // Open RDWR non-blocking — RDWR keeps a writer ref so reads don't EOF
        const fd = std.posix.open(path, .{ .ACCMODE = .RDWR, .NONBLOCK = true }, 0) catch return null;
        return fd;
    }

    // ── Logging functions ──

    pub fn logUser(self: *SessionLog, content: []const u8) !void {
        try self.writeEntry("u", content, .{});
        self.message_count += 1;
        // also append to global history
        self.appendHistory(content) catch {};
    }

    pub fn logAssistant(self: *SessionLog, content: []const u8) !void {
        try self.writeEntry("a", content, .{});
        self.message_count += 1;
    }

    pub fn logToolCall(self: *SessionLog, tool: []const u8, input: []const u8) !void {
        try self.writeToolEntry("tc", tool, input);
    }

    pub fn logToolResult(self: *SessionLog, tool: []const u8, output: []const u8, exit_code: u8) !void {
        const f = self.file orelse return;
        var buf: [8192]u8 = undefined;
        const ts = std.time.timestamp();
        var fbs = std.io.fixedBufferStream(&buf);
        const w = fbs.writer();
        try w.print("{{\"t\":\"tr\",\"ts\":{d},\"tool\":", .{ts});
        try writeJsonStr(w, tool);
        try w.writeAll(",\"output\":");
        // truncate output to fit
        const max_out = 6000;
        const out_slice = if (output.len > max_out) output[0..max_out] else output;
        try writeJsonStr(w, out_slice);
        try w.print(",\"exit\":{d}}}\n", .{exit_code});
        try f.writeAll(fbs.getWritten());
    }

    pub fn logAgentSpawn(self: *SessionLog, agent_id: []const u8, agent_type: []const u8, description: []const u8) !void {
        const f = self.file orelse return;
        var buf: [2048]u8 = undefined;
        const ts = std.time.timestamp();
        var fbs = std.io.fixedBufferStream(&buf);
        const w = fbs.writer();
        try w.print("{{\"t\":\"as\",\"ts\":{d},\"agent_id\":", .{ts});
        try writeJsonStr(w, agent_id);
        try w.writeAll(",\"type\":");
        try writeJsonStr(w, agent_type);
        try w.writeAll(",\"desc\":");
        try writeJsonStr(w, description);
        try w.writeAll("}\n");
        try f.writeAll(fbs.getWritten());
    }

    pub fn logAgentResult(self: *SessionLog, agent_id: []const u8, result: []const u8) !void {
        const f = self.file orelse return;
        var buf: [8192]u8 = undefined;
        const ts = std.time.timestamp();
        var fbs = std.io.fixedBufferStream(&buf);
        const w = fbs.writer();
        try w.print("{{\"t\":\"ar\",\"ts\":{d},\"agent_id\":", .{ts});
        try writeJsonStr(w, agent_id);
        try w.writeAll(",\"result\":");
        const max_r = 6000;
        const r_slice = if (result.len > max_r) result[0..max_r] else result;
        try writeJsonStr(w, r_slice);
        try w.writeAll("}\n");
        try f.writeAll(fbs.getWritten());
    }

    pub fn logDone(self: *SessionLog) !void {
        const f = self.file orelse return;
        var buf: [64]u8 = undefined;
        const ts = std.time.timestamp();
        const line = std.fmt.bufPrint(&buf, "{{\"t\":\"d\",\"ts\":{d}}}\n", .{ts}) catch return;
        try f.writeAll(line);
    }

    pub fn logError(self: *SessionLog, msg: []const u8) !void {
        try self.writeEntry("e", msg, .{});
    }

    // ── File backup ──

    pub fn backupFile(self: *SessionLog, file_path: []const u8) !void {
        const dir = self.dirPath();

        // ensure file-backups dir exists
        var backups_dir_buf: [MAX_PATH]u8 = undefined;
        const backups_dir = std.fmt.bufPrint(&backups_dir_buf, "{s}/file-backups", .{dir}) catch return;
        ensureDir(backups_dir) catch return;

        // hash the path
        var full_hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(file_path, &full_hash, .{});
        var path_hash: [16]u8 = undefined;
        @memcpy(&path_hash, full_hash[0..16]);
        // manual hex encoding
        var hex_buf: [32]u8 = undefined;
        const hex_chars = "0123456789abcdef";
        for (path_hash, 0..) |byte, i| {
            hex_buf[i * 2] = hex_chars[byte >> 4];
            hex_buf[i * 2 + 1] = hex_chars[byte & 0x0f];
        }
        const hex_str = hex_buf[0..32];

        // find next version number
        var version: u32 = 1;
        while (version < 100) : (version += 1) {
            var check_buf: [MAX_PATH]u8 = undefined;
            const check_path = std.fmt.bufPrint(&check_buf, "{s}/{s}@v{d}", .{ backups_dir, hex_str, version }) catch break;
            std.fs.cwd().access(check_path, .{}) catch break; // doesn't exist = use this version
        }

        // copy file content
        var backup_path_buf: [MAX_PATH]u8 = undefined;
        const backup_path = std.fmt.bufPrint(&backup_path_buf, "{s}/{s}@v{d}", .{ backups_dir, hex_str, version }) catch return;

        const src = std.fs.cwd().openFile(file_path, .{}) catch return; // file might not exist yet
        defer src.close();
        const dst = std.fs.cwd().createFile(backup_path, .{}) catch return;
        defer dst.close();

        // copy in chunks
        var copy_buf: [8192]u8 = undefined;
        while (true) {
            const n = src.read(&copy_buf) catch break;
            if (n == 0) break;
            dst.writeAll(copy_buf[0..n]) catch break;
        }

        // append to index
        var idx_path_buf: [MAX_PATH]u8 = undefined;
        const idx_path = std.fmt.bufPrint(&idx_path_buf, "{s}/index.jsonl", .{backups_dir}) catch return;
        const idx = std.fs.cwd().createFile(idx_path, .{ .truncate = false }) catch return;
        defer idx.close();
        idx.seekFromEnd(0) catch {};

        var idx_line_buf: [1024]u8 = undefined;
        const ts = std.time.timestamp();
        const idx_line = std.fmt.bufPrint(&idx_line_buf,
            "{{\"hash\":\"{s}\",\"path\":\"{s}\",\"v\":{d},\"ts\":{d}}}\n",
            .{ hex_str, file_path, version, ts },
        ) catch return;
        idx.writeAll(idx_line) catch {};
    }

    // ── Internal helpers ──

    fn writeEntry(self: *SessionLog, entry_type: []const u8, content: []const u8, _: anytype) !void {
        const f = self.file orelse return;
        var buf: [8192]u8 = undefined;
        const ts = std.time.timestamp();
        var fbs = std.io.fixedBufferStream(&buf);
        const w = fbs.writer();
        try w.print("{{\"t\":\"{s}\",\"ts\":{d},\"content\":", .{ entry_type, ts });
        const max_c = 7000;
        const c_slice = if (content.len > max_c) content[0..max_c] else content;
        try writeJsonStr(w, c_slice);
        try w.writeAll("}\n");
        try f.writeAll(fbs.getWritten());
    }

    fn writeToolEntry(self: *SessionLog, entry_type: []const u8, tool: []const u8, input: []const u8) !void {
        const f = self.file orelse return;
        var buf: [8192]u8 = undefined;
        const ts = std.time.timestamp();
        var fbs = std.io.fixedBufferStream(&buf);
        const w = fbs.writer();
        try w.print("{{\"t\":\"{s}\",\"ts\":{d},\"tool\":", .{ entry_type, ts });
        try writeJsonStr(w, tool);
        try w.writeAll(",\"input\":");
        const max_i = 6000;
        const i_slice = if (input.len > max_i) input[0..max_i] else input;
        try writeJsonStr(w, i_slice);
        try w.writeAll("}\n");
        try f.writeAll(fbs.getWritten());
    }

    fn appendHistory(self: *SessionLog, content: []const u8) !void {
        var base_buf: [MAX_PATH]u8 = undefined;
        const base = getBaseDir(&base_buf) orelse return;

        var hist_path_buf: [MAX_PATH]u8 = undefined;
        const hist_path = std.fmt.bufPrint(&hist_path_buf, "{s}/history.jsonl", .{base}) catch return;

        const f = std.fs.cwd().createFile(hist_path, .{ .truncate = false }) catch return;
        defer f.close();
        f.seekFromEnd(0) catch {};

        var buf: [4200]u8 = undefined;
        const ts = std.time.timestamp();
        var fbs = std.io.fixedBufferStream(&buf);
        const w = fbs.writer();
        w.print("{{\"ts\":{d},\"sid\":\"{s}\",\"q\":", .{ ts, self.session_id }) catch return;
        const max_q = 3000;
        const q_slice = if (content.len > max_q) content[0..max_q] else content;
        writeJsonStr(w, q_slice) catch return;
        w.writeAll("}\n") catch return;
        f.writeAll(fbs.getWritten()) catch {};
    }

    fn updateMeta(self: *SessionLog) !void {
        var meta_path_buf: [MAX_PATH]u8 = undefined;
        const meta_path = std.fmt.bufPrint(&meta_path_buf, "{s}/meta.json", .{self.dirPath()}) catch return;

        // read existing meta
        const meta_content = std.fs.cwd().readFileAlloc(self.allocator, meta_path, 4096) catch return;
        defer self.allocator.free(meta_content);

        // rewrite with updated count and status
        const f = std.fs.cwd().createFile(meta_path, .{}) catch return;
        defer f.close();

        // simple approach: find "message_count":N and "status":"active", replace
        var buf: [2048]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const w = fbs.writer();

        // just rewrite the whole thing using known fields from original
        const ts = std.time.timestamp();
        w.print("{{\"id\":\"{s}\",\"message_count\":{d},\"status\":\"done\",\"last_active\":{d}}}", .{
            self.session_id, self.message_count, ts,
        }) catch return;
        f.writeAll(fbs.getWritten()) catch {};
    }
};

// ============================================================
// Session index
// ============================================================

fn appendSessionIndex(base: []const u8, sid: *const SessionId, ts: i64, cwd: []const u8) !void {
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/sessions/index.jsonl", .{base}) catch return;

    ensureDir(std.fmt.bufPrint(&path_buf, "{s}/sessions", .{base}) catch return) catch {};

    const f = std.fs.cwd().createFile(path, .{ .truncate = false }) catch return;
    defer f.close();
    f.seekFromEnd(0) catch {};

    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf,
        "{{\"id\":\"{s}\",\"created\":{d},\"cwd\":\"{s}\",\"status\":\"active\"}}\n",
        .{ sid.*, ts, cwd },
    ) catch return;
    f.writeAll(line) catch {};
}

// ============================================================
// Agent config — loaded from ~/.zish/agent.json + env overrides
// ============================================================

pub const AgentConfig = struct {
    provider: []const u8,
    model: []const u8,
    base_url: []const u8,
    api_key: []const u8,
    api_key_cmd: []const u8,
    max_tokens: u32,
    max_tool_iterations: u32,
    max_agents: u8,
    auto_allow: bool,

    // Allocation tracking for proper cleanup
    // Max 7 possible: file content, creds content, 4 env vars, api_key_cmd stdout
    alloc_bufs: [8]?[]const u8 = .{null} ** 8,
    alloc_count: u8 = 0,
    owned_allocator: ?std.mem.Allocator = null,

    fn trackAlloc(self: *AgentConfig, buf: []const u8) void {
        std.debug.assert(self.alloc_count < 8);
        self.alloc_bufs[self.alloc_count] = buf;
        self.alloc_count += 1;
    }

    pub fn deinit(self: *AgentConfig) void {
        if (self.owned_allocator) |a| {
            for (self.alloc_bufs[0..self.alloc_count]) |maybe_buf| {
                if (maybe_buf) |buf| {
                    const mut: []u8 = @constCast(buf);
                    a.free(mut);
                }
            }
        }
        self.alloc_count = 0;
    }

    pub fn load(allocator: std.mem.Allocator) AgentConfig {
        var cfg = AgentConfig{
            .provider = "anthropic",
            .model = "claude-sonnet-4-6",
            .base_url = "https://api.anthropic.com",
            .api_key = "",
            .api_key_cmd = "",
            .max_tokens = 8192,
            .max_tool_iterations = 10,
            .max_agents = 8,
            .auto_allow = false,
            .owned_allocator = allocator,
        };

        // try loading from file first
        cfg.loadFromFile(allocator) catch {};

        // env vars override file config
        cfg.loadFromEnv(allocator);

        // if api_key still empty and api_key_cmd is set, run it
        if (cfg.api_key.len == 0 and cfg.api_key_cmd.len > 0) {
            cfg.resolveApiKeyCmd(allocator);
        }

        // if still no key, try Claude Code OAuth credentials (~/.claude/.credentials.json)
        if (cfg.api_key.len == 0 and std.mem.eql(u8, cfg.provider, "anthropic")) {
            cfg.loadClaudeCodeCredentials(allocator);
        }

        return cfg;
    }

    fn loadFromFile(self: *AgentConfig, allocator: std.mem.Allocator) !void {
        var base_buf: [MAX_PATH]u8 = undefined;
        const base = getBaseDir(&base_buf) orelse return;

        var path_buf: [MAX_PATH]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/agent.json", .{base}) catch return;

        const content = std.fs.cwd().readFileAlloc(allocator, path, 8192) catch return;
        self.trackAlloc(content);
        // simple key extraction (no full JSON parser needed)
        if (jsonExtractStr(content, "provider")) |v| self.provider = v;
        if (jsonExtractStr(content, "model")) |v| self.model = v;
        if (jsonExtractStr(content, "base_url")) |v| self.base_url = v;
        if (jsonExtractStr(content, "api_key")) |v| self.api_key = v;
        if (jsonExtractStr(content, "api_key_cmd")) |v| self.api_key_cmd = v;
        if (jsonExtractInt(content, "max_tokens")) |v| self.max_tokens = v;
        if (jsonExtractInt(content, "max_tool_iterations")) |v| self.max_tool_iterations = v;
        if (jsonExtractInt(content, "max_agents")) |v| self.max_agents = @intCast(@min(v, 16));
        // Check "auto_allow": true
        if (std.mem.indexOf(u8, content, "\"auto_allow\"")) |idx| {
            const after = content[@min(idx + 12, content.len)..];
            const trimmed = std.mem.trimLeft(u8, after, " \t\n\r:");
            self.auto_allow = std.mem.startsWith(u8, trimmed, "true");
        }
    }

    fn loadFromEnv(self: *AgentConfig, allocator: std.mem.Allocator) void {
        if (std.process.getEnvVarOwned(allocator, "ZISH_AGENT_PROVIDER") catch null) |p| {
            self.provider = p;
            self.trackAlloc(p);
        }
        const key = (std.process.getEnvVarOwned(allocator, "ZISH_AGENT_KEY") catch null)
            orelse (std.process.getEnvVarOwned(allocator, "ANTHROPIC_API_KEY") catch null);
        if (key) |k| {
            self.api_key = k;
            self.trackAlloc(k);
        }
        if (std.process.getEnvVarOwned(allocator, "ZISH_AGENT_URL") catch null) |u| {
            self.base_url = u;
            self.trackAlloc(u);
        }
        if (std.process.getEnvVarOwned(allocator, "ZISH_AGENT_MODEL") catch null) |m| {
            self.model = m;
            self.trackAlloc(m);
        }
    }

    fn resolveApiKeyCmd(self: *AgentConfig, allocator: std.mem.Allocator) void {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "/bin/sh", "-c", self.api_key_cmd },
            .max_output_bytes = 4096,
        }) catch return;
        defer allocator.free(result.stderr);
        // trim trailing newline
        const key = std.mem.trimRight(u8, result.stdout, "\n\r ");
        if (key.len > 0) {
            self.api_key = key;
            self.trackAlloc(result.stdout);
        } else {
            allocator.free(result.stdout);
        }
    }

    /// Load OAuth access token from Claude Code's credentials file (~/.claude/.credentials.json)
    fn loadClaudeCodeCredentials(self: *AgentConfig, allocator: std.mem.Allocator) void {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch return;
        defer allocator.free(home);

        var path_buf: [MAX_PATH]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/.claude/.credentials.json", .{home}) catch return;

        const content = std.fs.cwd().readFileAlloc(allocator, path, 8192) catch return;
        self.trackAlloc(content);

        // extract accessToken from nested claudeAiOauth object
        // format: {"claudeAiOauth":{"accessToken":"sk-ant-oat01-...","expiresAt":...}}
        if (std.mem.indexOf(u8, content, "\"accessToken\"")) |_| {
            if (jsonExtractStr(content, "accessToken")) |token| {
                if (token.len > 0) {
                    self.api_key = token;
                }
            }
        }
    }
};

// ============================================================
// Session listing
// ============================================================

pub const SessionInfo = struct {
    id: [SESSION_ID_LEN]u8,
    created: i64,
    cwd_buf: [128]u8,
    cwd_len: u8,
    status_buf: [16]u8,
    status_len: u8,

    pub fn cwd(self: *const SessionInfo) []const u8 {
        return self.cwd_buf[0..self.cwd_len];
    }
    pub fn status(self: *const SessionInfo) []const u8 {
        return self.status_buf[0..self.status_len];
    }
};

pub fn listSessions(allocator: std.mem.Allocator, out: *std.ArrayList(SessionInfo)) !void {
    var base_buf: [MAX_PATH]u8 = undefined;
    const base = getBaseDir(&base_buf) orelse return;

    var path_buf: [MAX_PATH]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/sessions/index.jsonl", .{base}) catch return;

    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return;
    defer allocator.free(content);

    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        if (line.len < 10) continue;
        const id_str = jsonExtractStr(line, "id") orelse continue;
        if (id_str.len != SESSION_ID_LEN) continue;

        var info = SessionInfo{
            .id = undefined,
            .created = 0,
            .cwd_buf = undefined,
            .cwd_len = 0,
            .status_buf = undefined,
            .status_len = 0,
        };
        @memcpy(&info.id, id_str[0..SESSION_ID_LEN]);
        if (jsonExtractStr(line, "cwd")) |s| {
            const n = @min(s.len, 128);
            @memcpy(info.cwd_buf[0..n], s[0..n]);
            info.cwd_len = @intCast(n);
        }
        if (jsonExtractStr(line, "status")) |s| {
            const n = @min(s.len, 16);
            @memcpy(info.status_buf[0..n], s[0..n]);
            info.status_len = @intCast(n);
        }
        if (jsonExtractInt(line, "created")) |ts| info.created = @intCast(ts);
        try out.append(allocator, info);
    }
}

// ============================================================
// JSON helpers (zero-alloc, grep-style)
// ============================================================

fn writeJsonStr(w: anytype, s: []const u8) !void {
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
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

pub fn jsonExtractStr(json: []const u8, key: []const u8) ?[]const u8 {
    var key_buf: [128]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&key_buf, "\"{s}\":", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, json, quoted_key) orelse return null;
    const after = json[idx + quoted_key.len..];
    const trimmed = std.mem.trimLeft(u8, after, " \t");
    if (trimmed.len == 0 or trimmed[0] != '"') return null;
    var i: usize = 1;
    while (i < trimmed.len) : (i += 1) {
        if (trimmed[i] == '\\') {
            i += 1;
            continue;
        }
        if (trimmed[i] == '"') return trimmed[1..i];
    }
    return null;
}

pub fn jsonExtractInt(json: []const u8, key: []const u8) ?u32 {
    var key_buf: [128]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&key_buf, "\"{s}\":", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, json, quoted_key) orelse return null;
    const after = json[idx + quoted_key.len..];
    const trimmed = std.mem.trimLeft(u8, after, " \t");
    // find end of number
    var end: usize = 0;
    while (end < trimmed.len and trimmed[end] >= '0' and trimmed[end] <= '9') : (end += 1) {}
    if (end == 0) return null;
    return std.fmt.parseInt(u32, trimmed[0..end], 10) catch null;
}

/// Convert a slice to a null-terminated pointer using a threadlocal buffer.
threadlocal var nt_buf: [MAX_PATH + 1]u8 = undefined;
fn toNullTerminated(s: []const u8) ?[*:0]const u8 {
    if (s.len >= MAX_PATH) return null;
    @memcpy(nt_buf[0..s.len], s);
    nt_buf[s.len] = 0;
    return @ptrCast(&nt_buf);
}
