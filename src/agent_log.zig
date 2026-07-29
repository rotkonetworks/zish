// agent_log.zig - shell configuration loader (~/.zish/agent.json + env)
//
// The heavy API agent and its session logging were removed; what remains is the
// shared AgentConfig used by ghost-text inference and local routing config
// (completion_model, router_local_model, router_local_only, router_enabled, ...).

const std = @import("std");
const compat = @import("compat.zig");

const MAX_PATH = 512;

pub fn getBaseDir(buf: *[MAX_PATH]u8) ?[]const u8 {
    const home = compat.getEnvVarOwned(std.heap.page_allocator, "HOME") catch return null;
    defer std.heap.page_allocator.free(home);
    const len = std.fmt.bufPrint(buf, "{s}/.zish", .{home}) catch return null;
    return len;
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
    // Router config
    router_enabled: bool = false,
    router_provider: []const u8 = "",
    router_model: []const u8 = "claude-haiku-4-5-20251001",
    router_base_url: []const u8 = "",
    router_local_only: bool = false, // true = never call router API, only use local patterns
    router_local_model: []const u8 = "", // path to local GGUF model for pure-Zig inference
    completion_model: []const u8 = "", // path to GGUF model for shell completion (ghost text)
    haiku_model: []const u8 = "claude-haiku-4-5-20251001",
    sonnet_model: []const u8 = "claude-sonnet-4-6",
    opus_model: []const u8 = "claude-opus-4-6",

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

        return cfg;
    }

    fn loadFromFile(self: *AgentConfig, allocator: std.mem.Allocator) !void {
        var base_buf: [MAX_PATH]u8 = undefined;
        const base = getBaseDir(&base_buf) orelse return;

        var path_buf: [MAX_PATH]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/agent.json", .{base}) catch return;

        const content = std.Io.Dir.cwd().readFileAlloc(compat.io(), path, allocator, .limited(8192)) catch return;
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
            const trimmed = std.mem.trimStart(u8, after, " \t\n\r:");
            self.auto_allow = std.mem.startsWith(u8, trimmed, "true");
        }
        // Router config
        if (std.mem.indexOf(u8, content, "\"router_enabled\"")) |idx| {
            const after = content[@min(idx + 16, content.len)..];
            const trimmed = std.mem.trimStart(u8, after, " \t\n\r:");
            self.router_enabled = std.mem.startsWith(u8, trimmed, "true");
        }
        if (jsonExtractStr(content, "router_model")) |v| self.router_model = v;
        if (jsonExtractStr(content, "router_provider")) |v| self.router_provider = v;
        if (jsonExtractStr(content, "router_base_url")) |v| self.router_base_url = v;
        if (std.mem.indexOf(u8, content, "\"router_local_only\"")) |idx| {
            const after = content[@min(idx + 19, content.len)..];
            const trimmed = std.mem.trimStart(u8, after, " \t\n\r:");
            self.router_local_only = std.mem.startsWith(u8, trimmed, "true");
        }
        if (jsonExtractStr(content, "router_local_model")) |v| self.router_local_model = v;
        if (jsonExtractStr(content, "completion_model")) |v| self.completion_model = v;
        if (jsonExtractStr(content, "haiku_model")) |v| self.haiku_model = v;
        if (jsonExtractStr(content, "sonnet_model")) |v| self.sonnet_model = v;
        if (jsonExtractStr(content, "opus_model")) |v| self.opus_model = v;
    }

    fn loadFromEnv(self: *AgentConfig, allocator: std.mem.Allocator) void {
        if (compat.getEnvVarOwned(allocator, "ZISH_AGENT_PROVIDER") catch null) |p| {
            self.provider = p;
            self.trackAlloc(p);
        }
        const key = (compat.getEnvVarOwned(allocator, "ZISH_AGENT_KEY") catch null)
            orelse (compat.getEnvVarOwned(allocator, "ANTHROPIC_API_KEY") catch null);
        if (key) |k| {
            self.api_key = k;
            self.trackAlloc(k);
        }
        if (compat.getEnvVarOwned(allocator, "ZISH_AGENT_URL") catch null) |u| {
            self.base_url = u;
            self.trackAlloc(u);
        }
        if (compat.getEnvVarOwned(allocator, "ZISH_AGENT_MODEL") catch null) |m| {
            self.model = m;
            self.trackAlloc(m);
        }
    }
};

// ============================================================
// JSON helpers (zero-alloc, grep-style)
// ============================================================

pub fn jsonExtractStr(json: []const u8, key: []const u8) ?[]const u8 {
    var key_buf: [128]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&key_buf, "\"{s}\":", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, json, quoted_key) orelse return null;
    const after = json[idx + quoted_key.len ..];
    const trimmed = std.mem.trimStart(u8, after, " \t");
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
    const after = json[idx + quoted_key.len ..];
    const trimmed = std.mem.trimStart(u8, after, " \t");
    // find end of number
    var end: usize = 0;
    while (end < trimmed.len and trimmed[end] >= '0' and trimmed[end] <= '9') : (end += 1) {}
    if (end == 0) return null;
    return std.fmt.parseInt(u32, trimmed[0..end], 10) catch null;
}
