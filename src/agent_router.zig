// agent_router.zig - lightweight query router for agent dispatch
// Classifies user intent using local patterns or a cheap model (small tier/0.5B).
// The router never speaks to the user — it only emits structured routing decisions.

const std = @import("std");
const compat = @import("compat.zig");
const agent_mod = @import("agent.zig");
const inference = @import("inference/root.zig");

pub const RouteAction = enum(u8) {
    agent, // route to a single agent with specified model
    fan_out, // spawn parallel subagents
};

/// Model size tier — maps to any provider's small/medium/large models.
/// Names are labels, not tied to any vendor.
pub const ModelTier = enum(u8) {
    small, // fast, cheap: lookups, simple questions, classification
    medium, // balanced: code edits, debugging, multi-file changes
    large, // heavyweight: complex reasoning, architecture, audits
};

pub const CostTier = enum(u8) { low, medium, high };

pub const ToolMask = packed struct(u8) {
    bash: bool = true,
    read: bool = true,
    edit: bool = false,
    write: bool = false,
    glob: bool = true,
    grep: bool = true,
    agent: bool = false,
    _pad: bool = false,
};

pub const ALL_TOOLS = ToolMask{ .bash = true, .read = true, .edit = true, .write = true, .glob = true, .grep = true, .agent = true };
pub const READ_ONLY = ToolMask{ .bash = true, .read = true, .edit = false, .write = false, .glob = true, .grep = true, .agent = false };

pub const RouteDecision = struct {
    action: RouteAction = .agent,
    model_tier: ModelTier = .medium,
    cost: CostTier = .medium,
    tools: ToolMask = ALL_TOOLS,
    fan_out_count: u8 = 0,
    // Resolved model name for the provider
    model_buf: [64]u8 = undefined,
    model_len: u8 = 0,
    // Reason for logging
    reason_buf: [128]u8 = undefined,
    reason_len: u8 = 0,

    pub fn modelName(self: *const RouteDecision) []const u8 {
        return self.model_buf[0..self.model_len];
    }

    pub fn reason(self: *const RouteDecision) []const u8 {
        return self.reason_buf[0..self.reason_len];
    }

    pub fn setModel(self: *RouteDecision, name: []const u8) void {
        const n = @min(name.len, 64);
        @memcpy(self.model_buf[0..n], name[0..n]);
        self.model_len = @intCast(n);
    }

    pub fn setReason(self: *RouteDecision, msg: []const u8) void {
        const n = @min(msg.len, 128);
        @memcpy(self.reason_buf[0..n], msg[0..n]);
        self.reason_len = @intCast(n);
    }

    pub fn summary(self: *const RouteDecision, buf: *[256]u8) []const u8 {
        const action_str = switch (self.action) {
            .agent => "agent",
            .fan_out => "fan_out",
        };
        const tier_str = switch (self.model_tier) {
            .small => "small",
            .medium => "medium",
            .large => "large",
        };
        const cost_str = switch (self.cost) {
            .low => "low",
            .medium => "med",
            .high => "high",
        };
        return std.fmt.bufPrint(buf, "{s} -> {s} ({s} cost)", .{ action_str, tier_str, cost_str }) catch "route";
    }
};

// ============================================================
// Router configuration
// ============================================================

pub const RouterConfig = struct {
    enabled: bool = false,
    model: [64]u8 = undefined,
    model_len: u8 = 0,
    base_url: [256]u8 = undefined,
    base_url_len: u16 = 0,
    provider: agent_mod.Provider = .anthropic,
    api_enabled: bool = true, // false = local patterns only, no API calls
    // Local GGUF model path for pure-Zig inference (no external deps)
    local_model_path: [256]u8 = undefined,
    local_model_len: u16 = 0,
    // Fork-based inference server (lazy-spawned on first use)
    fork_server: ?*inference.ForkServer = null,
    // Legacy in-process context (kept for direct use)
    inference_ctx: ?*inference.InferenceContext = null,
    // Model names for each tier (provider-specific)
    haiku_model: [64]u8 = undefined,
    haiku_len: u8 = 0,
    sonnet_model: [64]u8 = undefined,
    sonnet_len: u8 = 0,
    opus_model: [64]u8 = undefined,
    opus_len: u8 = 0,
    // User-contributed keyword patterns loaded from ~/.zish/patterns/
    extra_keywords: [64]struct { word: [48]u8 = undefined, word_len: u8 = 0, tier: ModelTier = .medium } = undefined,
    extra_keyword_count: u8 = 0,

    pub fn routerModel(self: *const RouterConfig) []const u8 {
        if (self.model_len > 0) return self.model[0..self.model_len];
        return "claude-haiku-4-5-20251001";
    }

    pub fn routerBaseUrl(self: *const RouterConfig) []const u8 {
        if (self.base_url_len > 0) return self.base_url[0..self.base_url_len];
        return "https://api.anthropic.com";
    }

    pub fn resolveModel(self: *const RouterConfig, tier: ModelTier) []const u8 {
        return switch (tier) {
            .small => if (self.haiku_len > 0) self.haiku_model[0..self.haiku_len] else "claude-haiku-4-5-20251001",
            .medium => if (self.sonnet_len > 0) self.sonnet_model[0..self.sonnet_len] else "claude-sonnet-4-6",
            .large => if (self.opus_len > 0) self.opus_model[0..self.opus_len] else "claude-opus-4-6",
        };
    }

    pub fn setField(buf: *[64]u8, len: *u8, value: []const u8) void {
        const n = @min(value.len, 64);
        @memcpy(buf[0..n], value[0..n]);
        len.* = @intCast(n);
    }

    pub fn localModelPath(self: *const RouterConfig) ?[]const u8 {
        if (self.local_model_len > 0) return self.local_model_path[0..self.local_model_len];
        return null;
    }

    pub fn setFieldLong(buf: *[256]u8, len: *u16, value: []const u8) void {
        const n: u16 = @intCast(@min(value.len, 256));
        @memcpy(buf[0..n], value[0..n]);
        len.* = n;
    }

    pub fn init() RouterConfig {
        var cfg = RouterConfig{};
        // Set defaults
        setField(&cfg.haiku_model, &cfg.haiku_len, "claude-haiku-4-5-20251001");
        setField(&cfg.sonnet_model, &cfg.sonnet_len, "claude-sonnet-4-6");
        setField(&cfg.opus_model, &cfg.opus_len, "claude-opus-4-6");
        return cfg;
    }

    /// Load user-contributed patterns at runtime. Call after init().
    pub fn loadPlugins(self: *RouterConfig) void {
        self.loadUserPatterns();
    }

    /// Load patterns from ~/.zish/patterns/ directory.
    /// File format: lines of words, with optional header lines:
    ///   # comment
    ///   type: shell | agent
    ///   tier: haiku | sonnet | opus  (for agent type)
    ///   word1
    ///   word2
    fn loadUserPatterns(self: *RouterConfig) void {
        const alloc = std.heap.page_allocator;
        const home = compat.getEnvVarOwned(alloc, "HOME") catch return;
        defer alloc.free(home);
        var dir_buf: [512]u8 = undefined;
        const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/.zish/patterns", .{home}) catch return;
        var dir = std.Io.Dir.cwd().openDir(compat.io(), dir_path, .{ .iterate = true }) catch return;
        defer dir.close(compat.io());
        var iter = dir.iterate();
        while (iter.next(compat.io()) catch null) |entry| {
            if (entry.kind != .file) continue;
            const content = dir.readFileAlloc(compat.io(), entry.name, alloc, .limited(8192)) catch continue;
            defer alloc.free(content);
            self.parsePatternFile(content);
        }
    }

    fn parsePatternFile(self: *RouterConfig, content: []const u8) void {
        var tier: ModelTier = .medium;
        var is_agent: bool = true;
        var line_start: usize = 0;
        for (content, 0..) |c, ci| {
            if (c == '\n' or ci == content.len - 1) {
                const end = if (c == '\n') ci else ci + 1;
                const line = std.mem.trim(u8, content[line_start..end], " \t\r");
                line_start = ci + 1;
                if (line.len == 0 or line[0] == '#') continue;
                if (std.mem.startsWith(u8, line, "type:")) {
                    const val = std.mem.trim(u8, line[5..], " \t");
                    is_agent = std.mem.eql(u8, val, "agent");
                    continue;
                }
                if (std.mem.startsWith(u8, line, "tier:")) {
                    const val = std.mem.trim(u8, line[5..], " \t");
                    if (std.mem.eql(u8, val, "small") or std.mem.eql(u8, val, "haiku")) tier = .small
                    else if (std.mem.eql(u8, val, "medium") or std.mem.eql(u8, val, "sonnet")) tier = .medium
                    else if (std.mem.eql(u8, val, "large") or std.mem.eql(u8, val, "opus")) tier = .large;
                    continue;
                }
                // Only load agent keywords (shell type is ignored — use ! prefix instead)
                if (is_agent and self.extra_keyword_count < 64) {
                    const n: u8 = @intCast(@min(line.len, 48));
                    var kw = &self.extra_keywords[self.extra_keyword_count];
                    @memcpy(kw.word[0..n], line[0..n]);
                    kw.word_len = n;
                    kw.tier = tier;
                    self.extra_keyword_count += 1;
                }
            }
        }
    }
};

// ============================================================
// Local pattern classification (zero-cost, no API call)
// ============================================================

/// Keywords that suggest the user wants an LLM agent, not a shell command
const AGENT_KEYWORDS = [_]struct { word: []const u8, tier: ModelTier }{
    // Small tier — simple questions
    .{ .word = "explain", .tier = .small},
    .{ .word = "what is", .tier = .small},
    .{ .word = "what's", .tier = .small},
    .{ .word = "how do", .tier = .small},
    .{ .word = "how to", .tier = .small},
    .{ .word = "tell me", .tier = .small},
    .{ .word = "describe", .tier = .small},
    .{ .word = "show me", .tier = .small},
    .{ .word = "list the", .tier = .small},
    .{ .word = "summarize", .tier = .small},
    .{ .word = "translate", .tier = .small},
    // Medium tier — code work
    .{ .word = "fix", .tier = .medium},
    .{ .word = "debug", .tier = .medium},
    .{ .word = "implement", .tier = .medium},
    .{ .word = "add a ", .tier = .medium},
    .{ .word = "add the", .tier = .medium},
    .{ .word = "create a", .tier = .medium},
    .{ .word = "write a", .tier = .medium},
    .{ .word = "modify", .tier = .medium},
    .{ .word = "change", .tier = .medium},
    .{ .word = "update", .tier = .medium},
    .{ .word = "refactor", .tier = .medium},
    .{ .word = "optimize", .tier = .medium},
    .{ .word = "build", .tier = .medium},
    .{ .word = "test", .tier = .medium},
    .{ .word = "generate", .tier = .medium},
    .{ .word = "convert", .tier = .medium},
    .{ .word = "migrate", .tier = .medium},
    .{ .word = "port", .tier = .medium},
    .{ .word = "rename", .tier = .medium},
    .{ .word = "extract", .tier = .medium},
    .{ .word = "move the", .tier = .medium},
    .{ .word = "split", .tier = .medium},
    .{ .word = "merge", .tier = .medium},
    .{ .word = "clean up", .tier = .medium},
    // Large tier — complex reasoning
    .{ .word = "audit", .tier = .large},
    .{ .word = "review all", .tier = .large},
    .{ .word = "redesign", .tier = .large},
    .{ .word = "architect", .tier = .large},
    .{ .word = "security", .tier = .large},
    .{ .word = "analyze the entire", .tier = .large},
    .{ .word = "compare and contrast", .tier = .large},
    .{ .word = "deep dive", .tier = .large},
    .{ .word = "comprehensive", .tier = .large},
    .{ .word = "thoroughly", .tier = .large},
    .{ .word = "performance analysis", .tier = .large},
    .{ .word = "investigate", .tier = .large},
};

/// Try to classify query using only local heuristics. Returns null if ambiguous.
pub fn classifyLocal(query: []const u8) ?RouteDecision {
    return classifyLocalWithConfig(query, null);
}

pub fn classifyLocalWithConfig(query: []const u8, config: ?*const RouterConfig) ?RouteDecision {
    if (query.len == 0) return null;

    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len == 0) return null;

    // Check for agent keywords (case-insensitive)
    var lower_buf: [512]u8 = undefined;
    const lower = toLower(trimmed, &lower_buf);

    for (AGENT_KEYWORDS) |kw| {
        if (std.mem.startsWith(u8, lower, kw.word) or
            containsWord(lower, kw.word))
        {
            var rd = RouteDecision{
                .action = .agent,
                .model_tier = kw.tier,
                .cost = switch (kw.tier) {
                    .small => .low,
                    .medium => .medium,
                    .large => .high,
                },
                .tools = switch (kw.tier) {
                    .small => READ_ONLY,
                    .medium => ALL_TOOLS,
                    .large => ALL_TOOLS,
                },
            };
            rd.setReason("local: keyword match");
            return rd;
        }
    }

    // Check user-contributed agent keywords from ~/.zish/patterns/
    if (config) |cfg| {
        for (0..cfg.extra_keyword_count) |i| {
            const kw = &cfg.extra_keywords[i];
            if (kw.word_len == 0) continue;
            const word = kw.word[0..kw.word_len];
            if (std.mem.startsWith(u8, lower, word) or
                containsWord(lower, word))
            {
                var rd = RouteDecision{
                    .action = .agent,
                    .model_tier = kw.tier,
                    .cost = switch (kw.tier) {
                        .small => .low,
                        .medium => .medium,
                        .large => .high,
                    },
                    .tools = switch (kw.tier) {
                        .small => READ_ONLY,
                        .medium => ALL_TOOLS,
                        .large => ALL_TOOLS,
                    },
                };
                rd.setReason("plugin: keyword match");
                return rd;
            }
        }
    }

    // Short queries with question marks -> small
    if (trimmed.len < 80 and std.mem.indexOfScalar(u8, trimmed, '?') != null) {
        var rd = RouteDecision{
            .action = .agent,
            .model_tier = .small,
            .cost = .low,
            .tools = READ_ONLY,
        };
        rd.setReason("local: short question");
        return rd;
    }

    // Ambiguous — needs model classification
    return null;
}

fn toLower(s: []const u8, buf: *[512]u8) []const u8 {
    const n = @min(s.len, 512);
    for (s[0..n], 0..) |c, i| {
        buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    return buf[0..n];
}

fn containsWord(haystack: []const u8, word: []const u8) bool {
    var pos: usize = 0;
    while (pos < haystack.len) {
        const idx = std.mem.indexOfPos(u8, haystack, pos, word) orelse return false;
        // Check word boundary: must be at start or preceded by space/punctuation
        const at_start = (idx == 0 or haystack[idx - 1] == ' ' or haystack[idx - 1] == ',' or haystack[idx - 1] == '.');
        const at_end = (idx + word.len >= haystack.len or haystack[idx + word.len] == ' ' or haystack[idx + word.len] == ',' or haystack[idx + word.len] == '.');
        if (at_start and at_end) return true;
        pos = idx + 1;
    }
    return false;
}

// ============================================================
// Model-based classification (local model via Ollama or cheap API)
// ============================================================

const ROUTER_SYSTEM_PROMPT =
    \\Classify if input is a SHELL command or needs AI AGENT help.
    \\Respond with JSON: {"r":"s"} for shell, {"r":"a","t":"h|s|o"} for agent (h=easy,s=code,o=hard)
;

// Few-shot examples baked into the request for reliable small-model classification
const FEW_SHOT_EXAMPLES = [_]struct { user: []const u8, response: []const u8 }{
    .{ .user = "ls -la", .response = "{\"r\":\"s\"}" },
    .{ .user = "git commit -m fix", .response = "{\"r\":\"s\"}" },
    .{ .user = "make install", .response = "{\"r\":\"s\"}" },
    .{ .user = "docker ps", .response = "{\"r\":\"s\"}" },
    .{ .user = "cat /etc/hosts", .response = "{\"r\":\"s\"}" },
    .{ .user = "fix the bug", .response = "{\"r\":\"a\",\"t\":\"s\"}" },
    .{ .user = "what is TCP", .response = "{\"r\":\"a\",\"t\":\"h\"}" },
    .{ .user = "audit for security", .response = "{\"r\":\"a\",\"t\":\"o\"}" },
    .{ .user = "refactor the parser", .response = "{\"r\":\"a\",\"t\":\"s\"}" },
    .{ .user = "explain how this works", .response = "{\"r\":\"a\",\"t\":\"h\"}" },
    .{ .user = "implement authentication", .response = "{\"r\":\"a\",\"t\":\"s\"}" },
    .{ .user = "review all code for memory leaks", .response = "{\"r\":\"a\",\"t\":\"o\"}" },
};

/// Classify a query using a local model (Ollama) or cheap API call.
/// Returns null on failure (caller should fall back to default).
pub fn classifyWithModel(
    allocator: std.mem.Allocator,
    query: []const u8,
    context_summary: []const u8,
    config: *const RouterConfig,
    api_key: []const u8,
) ?RouteDecision {
    _ = context_summary; // reserved for future use

    // Build request body — use Ollama native API for think:false support
    var body_buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&body_buf);

    const is_ollama = (config.provider == .ollama);

    if (is_ollama) {
        // Ollama native /api/chat with think:false (disables reasoning overhead)
        w.writeAll("{\"model\":\"") catch return null;
        w.writeAll(config.routerModel()) catch return null;
        w.writeAll("\",\"stream\":false,\"think\":false,\"options\":{\"num_predict\":30,\"temperature\":0.0},\"messages\":[") catch return null;

        // System message
        w.writeAll("{\"role\":\"system\",\"content\":\"") catch return null;
        w.writeAll(ROUTER_SYSTEM_PROMPT) catch return null;
        w.writeAll("\"},") catch return null;

        // Few-shot examples
        for (FEW_SHOT_EXAMPLES) |ex| {
            w.print("{{\"role\":\"user\",\"content\":\"{s}\"}},{{\"role\":\"assistant\",\"content\":\"{s}\"}},", .{ ex.user, ex.response }) catch return null;
        }

        // Actual query
        w.writeAll("{\"role\":\"user\",\"content\":\"") catch return null;
        writeEscaped(&w, query[0..@min(query.len, 500)]);
        w.writeAll("\"}]}") catch return null;
    } else if (config.provider == .anthropic) {
        // Anthropic Messages API
        w.writeAll("{\"model\":\"") catch return null;
        w.writeAll(config.routerModel()) catch return null;
        w.writeAll("\",\"max_tokens\":64,\"system\":\"") catch return null;
        w.writeAll(ROUTER_SYSTEM_PROMPT) catch return null;
        w.writeAll("\",\"messages\":[") catch return null;
        for (FEW_SHOT_EXAMPLES) |ex| {
            w.print("{{\"role\":\"user\",\"content\":\"{s}\"}},{{\"role\":\"assistant\",\"content\":\"{s}\"}},", .{ ex.user, ex.response }) catch return null;
        }
        w.writeAll("{\"role\":\"user\",\"content\":\"") catch return null;
        writeEscaped(&w, query[0..@min(query.len, 500)]);
        w.writeAll("\"}]}") catch return null;
    } else {
        // OpenAI-compat
        w.writeAll("{\"model\":\"") catch return null;
        w.writeAll(config.routerModel()) catch return null;
        w.writeAll("\",\"max_tokens\":64,\"temperature\":0.0,\"messages\":[") catch return null;
        w.writeAll("{\"role\":\"system\",\"content\":\"") catch return null;
        w.writeAll(ROUTER_SYSTEM_PROMPT) catch return null;
        w.writeAll("\"},") catch return null;
        for (FEW_SHOT_EXAMPLES) |ex| {
            w.print("{{\"role\":\"user\",\"content\":\"{s}\"}},{{\"role\":\"assistant\",\"content\":\"{s}\"}},", .{ ex.user, ex.response }) catch return null;
        }
        w.writeAll("{\"role\":\"user\",\"content\":\"") catch return null;
        writeEscaped(&w, query[0..@min(query.len, 500)]);
        w.writeAll("\"}]}") catch return null;
    }

    const body = body_buf[0..w.end];

    // Build URL
    var url_buf: [256]u8 = undefined;
    const url = switch (config.provider) {
        .anthropic => std.fmt.bufPrint(&url_buf, "{s}/v1/messages", .{config.routerBaseUrl()}) catch return null,
        .ollama => std.fmt.bufPrint(&url_buf, "{s}/api/chat", .{config.routerBaseUrl()}) catch return null,
        .openai_compat => std.fmt.bufPrint(&url_buf, "{s}/v1/chat/completions", .{config.routerBaseUrl()}) catch return null,
        .local => return null, // local models use ForkServer, not HTTP
    };

    // Call curl (non-streaming, small response)
    var argv: [20][]const u8 = undefined;
    var argc: usize = 0;
    argv[argc] = "curl";
    argc += 1;
    argv[argc] = "-sS";
    argc += 1;
    argv[argc] = "--max-time";
    argc += 1;
    argv[argc] = "3"; // 3 second timeout — router must be fast
    argc += 1;
    argv[argc] = "-X";
    argc += 1;
    argv[argc] = "POST";
    argc += 1;
    argv[argc] = "-H";
    argc += 1;
    argv[argc] = "Content-Type: application/json";
    argc += 1;

    var auth_buf: [512]u8 = undefined;
    switch (config.provider) {
        .anthropic => {
            // OAuth tokens (sk-ant-oat01-) use Bearer auth; API keys use X-Api-Key
            const is_oauth = std.mem.startsWith(u8, api_key, "sk-ant-oat01-");
            const auth = if (is_oauth)
                std.fmt.bufPrint(&auth_buf, "Authorization: Bearer {s}", .{api_key}) catch return null
            else
                std.fmt.bufPrint(&auth_buf, "x-api-key: {s}", .{api_key}) catch return null;
            argv[argc] = "-H";
            argc += 1;
            argv[argc] = auth;
            argc += 1;
            argv[argc] = "-H";
            argc += 1;
            argv[argc] = "anthropic-version: 2023-06-01";
            argc += 1;
            // OAuth requires the beta flag
            if (is_oauth) {
                argv[argc] = "-H";
                argc += 1;
                argv[argc] = "anthropic-beta: oauth-2025-04-20";
                argc += 1;
            }
        },
        .local => return null, // handled by ForkServer
        .ollama => {}, // no auth needed
        .openai_compat => {
            if (api_key.len > 0) {
                const auth = std.fmt.bufPrint(&auth_buf, "Authorization: Bearer {s}", .{api_key}) catch return null;
                argv[argc] = "-H";
                argc += 1;
                argv[argc] = auth;
                argc += 1;
            }
        },
    }

    argv[argc] = "-d";
    argc += 1;
    argv[argc] = "@-";
    argc += 1;
    argv[argc] = url;
    argc += 1;

    // Spawn curl
    _ = allocator;
    var child = std.process.spawn(compat.io(), .{
        .argv = argv[0..argc],
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore, // never read — a .pipe here can deadlock wait() if curl writes >64KB
    }) catch return null;

    // Write body
    if (child.stdin) |stdin_pipe| {
        compat.writeAll(stdin_pipe, body) catch {};
        stdin_pipe.close(compat.io());
        child.stdin = null;
    }

    // Read response
    var resp_buf: [4096]u8 = undefined;
    var resp_len: usize = 0;
    if (child.stdout) |stdout| {
        while (resp_len < resp_buf.len) {
            const n = stdout.readStreaming(compat.io(), &.{resp_buf[resp_len..]}) catch break;
            if (n == 0) break;
            resp_len += n;
        }
    }
    if (child.stdout) |s| { s.close(compat.io()); child.stdout = null; }
    _ = child.wait(compat.io()) catch {};

    if (resp_len == 0) return null;
    const response = resp_buf[0..resp_len];

    // Extract the text content from the response
    const text = extractResponseText(response) orelse return null;

    return parseRouteResponse(text);
}

fn writeEscaped(w: anytype, s: []const u8) void {
    for (s) |c| {
        switch (c) {
            '"' => w.writeAll("\\\"") catch {},
            '\\' => w.writeAll("\\\\") catch {},
            '\n' => w.writeAll("\\n") catch {},
            '\r' => {},
            '\t' => w.writeAll("\\t") catch {},
            else => {
                if (c >= 0x20) w.writeByte(c) catch {};
            },
        }
    }
}

fn extractResponseText(json: []const u8) ?[]const u8 {
    // Ollama native: {"message":{"content":"..."}}
    // OpenAI: {"choices":[{"message":{"content":"..."}}]}
    // Anthropic: {"content":[{"type":"text","text":"..."}]}
    if (jsonGetStr(json, "content")) |t| {
        if (t.len > 0) return t;
    }
    if (jsonGetStr(json, "text")) |t| return t;
    return null;
}

fn parseRouteResponse(text: []const u8) ?RouteDecision {
    // Find the JSON object in the response (model might add extra text)
    const start = std.mem.indexOfScalar(u8, text, '{') orelse return null;
    const end_search = text[start..];
    var depth: i32 = 0;
    var end: usize = 0;
    for (end_search, 0..) |c, i| {
        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth == 0) {
                end = start + i + 1;
                break;
            }
        }
    }
    if (end == 0) return null;
    const json = text[start..end];

    var rd = RouteDecision{};

    // Support compact format: {"r":"s"} / {"r":"a","t":"h|s|o"}
    // and verbose format: {"action":"agent","model":"medium",...}
    if (jsonGetStr(json, "r")) |r| {
        // Compact format — "s" (shell) now treated as agent/small
        if (std.mem.eql(u8, r, "s")) {
            rd.action = .agent;
            rd.model_tier = .small;
            rd.cost = .low;
            rd.setReason("model: simple task");
        } else {
            rd.action = .agent;
            // Parse tier
            if (jsonGetStr(json, "t")) |t| {
                if (std.mem.eql(u8, t, "h")) {
                    rd.model_tier = .small;
                    rd.cost = .low;
                } else if (std.mem.eql(u8, t, "o")) {
                    rd.model_tier = .large;
                    rd.cost = .high;
                } else {
                    rd.model_tier = .medium;
                    rd.cost = .medium;
                }
            }
            rd.setReason("model: agent task");
        }
    } else if (jsonGetStr(json, "action")) |a| {
        // Verbose format
        if (std.mem.eql(u8, a, "fan_out")) {
            rd.action = .fan_out;
            rd.fan_out_count = 3;
        } else {
            rd.action = .agent;
        }

        if (jsonGetStr(json, "model")) |m| {
            if (std.mem.eql(u8, m, "haiku") or std.mem.eql(u8, m, "small")) {
                rd.model_tier = .small;
            } else if (std.mem.eql(u8, m, "opus") or std.mem.eql(u8, m, "large")) {
                rd.model_tier = .large;
            } else {
                rd.model_tier = .medium;
            }
        }

        if (jsonGetStr(json, "cost")) |c| {
            if (std.mem.eql(u8, c, "low")) {
                rd.cost = .low;
            } else if (std.mem.eql(u8, c, "high")) {
                rd.cost = .high;
            } else {
                rd.cost = .medium;
            }
        }

        if (jsonGetStr(json, "reason")) |reason| {
            rd.setReason(reason);
        } else {
            rd.setReason("model classification");
        }
    } else {
        return null; // couldn't parse
    }

    // Set tool mask based on action/tier
    rd.tools = switch (rd.action) {
        .agent => switch (rd.model_tier) {
            .small => READ_ONLY,
            .medium => ALL_TOOLS,
            .large => ALL_TOOLS,
        },
        .fan_out => READ_ONLY,
    };

    return rd;
}

// ============================================================
// JSON helpers (same zero-alloc pattern as agent.zig)
// ============================================================

fn jsonGetStr(json: []const u8, key: []const u8) ?[]const u8 {
    var key_buf: [128]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&key_buf, "\"{s}\":", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, json, quoted_key) orelse return null;
    const after = json[idx + quoted_key.len..];
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

// ============================================================
// Local GGUF inference classification (pure Zig, no external deps)
// ============================================================

/// Build the classification prompt for local inference.
fn buildClassificationPrompt(buf: []u8, query: []const u8) []const u8 {
    const prompt_prefix =
        \\<|im_start|>system
        \\Classify if input is a SHELL command or needs AI AGENT help.
        \\Respond with JSON: {"r":"s"} for shell, {"r":"a","t":"h|s|o"} for agent (h=easy,s=code,o=hard)
        \\<|im_end|>
        \\<|im_start|>user
        \\ls -la<|im_end|>
        \\<|im_start|>assistant
        \\{"r":"s"}<|im_end|>
        \\<|im_start|>user
        \\fix the bug<|im_end|>
        \\<|im_start|>assistant
        \\{"r":"a","t":"s"}<|im_end|>
        \\<|im_start|>user
        \\what is TCP<|im_end|>
        \\<|im_start|>assistant
        \\{"r":"a","t":"h"}<|im_end|>
        \\<|im_start|>user
        \\
    ;
    const prompt_suffix =
        \\<|im_end|>
        \\<|im_start|>assistant
        \\
    ;
    const query_trunc = query[0..@min(query.len, 500)];
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ prompt_prefix, query_trunc, prompt_suffix }) catch buf[0..0];
}

/// Classify a query using local GGUF inference (pure Zig, zero external deps).
/// Uses fork-based process isolation: model loaded in child process,
/// shell stays responsive even if inference crashes or OOMs.
/// Child is lazily spawned on first call and reused for subsequent queries.
pub fn classifyWithLocalModel(
    allocator: std.mem.Allocator,
    query: []const u8,
    config: *RouterConfig,
) ?RouteDecision {
    const model_path = config.localModelPath() orelse return null;

    // Lazy-spawn fork server
    if (config.fork_server == null) {
        const srv = allocator.create(inference.ForkServer) catch return null;
        srv.* = inference.ForkServer.spawn(model_path) catch {
            allocator.destroy(srv);
            return null;
        };
        config.fork_server = srv;
    }

    var srv = config.fork_server.?;

    // Check if child is still alive (may have crashed on a previous request)
    if (!srv.isAlive()) {
        // Respawn
        srv.shutdown();
        srv.* = inference.ForkServer.spawn(model_path) catch {
            // Already shut down — drop the dead server so later cleanup
            // doesn't shutdown() it a second time (double-close/waitpid).
            allocator.destroy(srv);
            config.fork_server = null;
            return null;
        };
    }

    // Build prompt
    var prompt_buf: [4096]u8 = undefined;
    const prompt = buildClassificationPrompt(&prompt_buf, query);
    if (prompt.len == 0) return null;

    // Generate via forked child (greedy, max 30 tokens)
    const response = srv.generate(prompt, 30, 0, allocator) catch return null;
    defer allocator.free(response);

    if (response.len == 0) return null;

    // Parse the JSON classification from the response
    return parseRouteResponse(response);
}

// ============================================================
// Correction logging — user feedback on router decisions
// ============================================================

/// Log a correction when user overrides the routed tier via /model.
/// Written to ~/.zish/router_log.jsonl alongside normal route decisions.
pub fn logCorrection(query: []const u8, routed_tier: []const u8, corrected_tier: []const u8) void {
    if (query.len == 0 or query.len > 2048) return;

    const alloc = std.heap.page_allocator;
    const home = compat.getEnvVarOwned(alloc, "HOME") catch return;
    defer alloc.free(home);

    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.zish/router_log.jsonl", .{home}) catch return;

    const file = std.Io.Dir.cwd().openFile(compat.io(), path, .{ .mode = .write_only }) catch |e| switch (e) {
        error.FileNotFound => std.Io.Dir.cwd().createFile(compat.io(), path, .{}) catch return,
        else => return,
    };
    defer file.close(compat.io());
    const file_end = file.length(compat.io()) catch return;

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
    const mid = std.fmt.bufPrint(buf[pos..], "\",\"routed\":\"{s}\",\"corrected\":\"{s}\",\"ts\":{d}}}\n", .{
        routed_tier, corrected_tier, ts,
    }) catch return;
    pos += mid.len;
    file.writePositionalAll(compat.io(), buf[0..pos], file_end) catch {};
}

// ============================================================
// Pattern learner — extract corrections into learned patterns
// ============================================================

/// Scan router_log.jsonl for corrections, extract common words per tier,
/// write ~/.zish/patterns/learned.txt. Called on agent startup.
pub fn learnPatterns() void {
    const alloc = std.heap.page_allocator;
    const home = compat.getEnvVarOwned(alloc, "HOME") catch return;
    defer alloc.free(home);

    // Read the log file
    var log_path_buf: [512]u8 = undefined;
    const log_path = std.fmt.bufPrint(&log_path_buf, "{s}/.zish/router_log.jsonl", .{home}) catch return;
    const log_content = std.Io.Dir.cwd().readFileAlloc(compat.io(), log_path, alloc, .limited(1 << 20)) catch return; // 1MB max
    defer alloc.free(log_content);

    // Count word → tier corrections
    // Simple approach: for each correction entry, extract words from query,
    // tally which tier each word maps to
    const MAX_WORDS = 256;
    var words: [MAX_WORDS][48]u8 = undefined;
    var word_lens: [MAX_WORDS]u8 = [_]u8{0} ** MAX_WORDS;
    var word_tiers: [MAX_WORDS]ModelTier = [_]ModelTier{.medium} ** MAX_WORDS;
    var word_counts: [MAX_WORDS]u16 = [_]u16{0} ** MAX_WORDS;
    var word_total: usize = 0;

    // Parse each line
    var line_start: usize = 0;
    for (log_content, 0..) |c, ci| {
        if (c != '\n' and ci != log_content.len - 1) continue;
        const end = if (c == '\n') ci else ci + 1;
        const line = log_content[line_start..end];
        line_start = ci + 1;

        // Only process correction entries (have "corrected" field)
        const corrected = jsonGetStr(line, "corrected") orelse continue;
        const query = jsonGetStr(line, "q") orelse continue;

        const tier: ModelTier = if (std.mem.eql(u8, corrected, "small")) .small
            else if (std.mem.eql(u8, corrected, "large")) .large
            else .medium;

        // Extract words from query (lowercase, skip short ones)
        var lower_buf: [512]u8 = undefined;
        const lower = toLower(query, &lower_buf);
        var wstart: usize = 0;
        for (lower, 0..) |lc, li| {
            if (lc == ' ' or li == lower.len - 1) {
                const wend = if (lc == ' ') li else li + 1;
                const word = lower[wstart..wend];
                wstart = li + 1;
                if (word.len < 3 or word.len > 47) continue;
                // Skip common stopwords
                if (isStopword(word)) continue;

                // Find or insert word
                var found = false;
                for (0..word_total) |wi| {
                    if (word_lens[wi] == word.len and
                        std.mem.eql(u8, words[wi][0..word_lens[wi]], word))
                    {
                        word_counts[wi] += 1;
                        word_tiers[wi] = tier; // last correction wins
                        found = true;
                        break;
                    }
                }
                if (!found and word_total < MAX_WORDS) {
                    const wl: u8 = @intCast(word.len);
                    @memcpy(words[word_total][0..wl], word);
                    word_lens[word_total] = wl;
                    word_tiers[word_total] = tier;
                    word_counts[word_total] = 1;
                    word_total += 1;
                }
            }
        }
    }

    // Filter: only keep words with >= 3 corrections (confident signal)
    var out_buf: [4096]u8 = undefined;
    var out_pos: usize = 0;
    const header = "# auto-learned from router corrections\n# regenerated on agent startup\n";
    @memcpy(out_buf[out_pos..][0..header.len], header);
    out_pos += header.len;

    // Group by tier
    const tiers = [_]struct { t: ModelTier, label: []const u8 }{
        .{ .t = .small, .label = "type: agent\ntier: small\n" },
        .{ .t = .medium, .label = "type: agent\ntier: medium\n" },
        .{ .t = .large, .label = "type: agent\ntier: large\n" },
    };
    for (tiers) |tg| {
        var has_words = false;
        for (0..word_total) |wi| {
            if (word_tiers[wi] == tg.t and word_counts[wi] >= 3) {
                has_words = true;
                break;
            }
        }
        if (!has_words) continue;

        if (out_pos + tg.label.len >= out_buf.len) break;
        @memcpy(out_buf[out_pos..][0..tg.label.len], tg.label);
        out_pos += tg.label.len;

        for (0..word_total) |wi| {
            if (word_tiers[wi] != tg.t or word_counts[wi] < 3) continue;
            const wl = word_lens[wi];
            if (out_pos + wl + 1 >= out_buf.len) break;
            @memcpy(out_buf[out_pos..][0..wl], words[wi][0..wl]);
            out_pos += wl;
            out_buf[out_pos] = '\n';
            out_pos += 1;
        }
    }

    if (out_pos <= header.len) return; // nothing learned

    // Write to ~/.zish/patterns/learned.txt
    var pat_path_buf: [512]u8 = undefined;
    const pat_dir = std.fmt.bufPrint(&pat_path_buf, "{s}/.zish/patterns", .{home}) catch return;
    std.Io.Dir.cwd().createDirPath(compat.io(), pat_dir) catch {};

    var file_path_buf: [512]u8 = undefined;
    const file_path = std.fmt.bufPrint(&file_path_buf, "{s}/.zish/patterns/learned.txt", .{home}) catch return;
    const file = std.Io.Dir.cwd().createFile(compat.io(), file_path, .{}) catch return;
    defer file.close(compat.io());
    compat.writeAll(file, out_buf[0..out_pos]) catch {};
}

fn isStopword(w: []const u8) bool {
    const stops = [_][]const u8{
        "the", "and", "for", "that", "this", "with", "from", "are", "was",
        "have", "has", "had", "been", "will", "can", "not", "but", "all",
        "they", "you", "your", "what", "how", "when", "where", "which",
        "there", "their", "than", "then", "its", "also", "just", "into",
        "some", "about", "out", "more", "very",
    };
    for (stops) |s| {
        if (std.mem.eql(u8, w, s)) return true;
    }
    return false;
}
