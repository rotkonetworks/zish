// agent_router.zig - lightweight query router for agent dispatch
// Classifies user intent using local patterns or a cheap model (Haiku/0.5B).
// The router never speaks to the user — it only emits structured routing decisions.

const std = @import("std");
const agent_mod = @import("agent.zig");
const inference = @import("inference/root.zig");

pub const RouteAction = enum(u8) {
    shell, // run as plain shell command, skip LLM entirely
    agent, // route to a single agent with specified model
    fan_out, // spawn parallel subagents
};

pub const ModelTier = enum(u8) {
    haiku, // simple: explanations, lookups, quick edits
    sonnet, // medium: multi-file changes, debugging, code gen
    opus, // hard: complex reasoning, large refactors, audits
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
    model_tier: ModelTier = .sonnet,
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
            .shell => "shell",
            .agent => "agent",
            .fan_out => "fan_out",
        };
        const tier_str = switch (self.model_tier) {
            .haiku => "haiku",
            .sonnet => "sonnet",
            .opus => "opus",
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
            .haiku => if (self.haiku_len > 0) self.haiku_model[0..self.haiku_len] else "claude-haiku-4-5-20251001",
            .sonnet => if (self.sonnet_len > 0) self.sonnet_model[0..self.sonnet_len] else "claude-sonnet-4-6",
            .opus => if (self.opus_len > 0) self.opus_model[0..self.opus_len] else "claude-opus-4-6",
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
};

// ============================================================
// Local pattern classification (zero-cost, no API call)
// ============================================================

/// Known shell commands that should bypass the agent entirely.
/// These are commands that make no sense to route through an LLM.
const SHELL_COMMANDS = [_][]const u8{
    "ls",    "cd",     "pwd",    "cat",   "echo",  "mkdir",  "rm",
    "cp",    "mv",     "touch",  "chmod", "chown", "find",   "grep",
    "head",  "tail",   "wc",     "sort",  "uniq",  "cut",    "tr",
    "sed",   "awk",    "diff",   "tar",   "gzip",  "gunzip", "zip",
    "unzip", "curl",   "wget",   "ssh",   "scp",   "rsync",  "df",
    "du",    "free",   "top",    "htop",  "ps",    "kill",   "man",
    "which", "whoami", "date",   "cal",   "env",   "export", "source",
    "make",  "cmake",  "cargo",  "npm",   "yarn",  "pip",    "python",
    "python3", "node", "ruby",   "perl",  "go",    "zig",    "rustc",
    "gcc",   "g++",    "clang",  "git",   "docker", "systemctl",
    "journalctl", "mount", "umount", "ip", "ping", "dig", "nslookup",
    "less",  "more",   "vi",     "vim",   "nano",  "emacs",
    // package managers
    "apt",   "apt-get", "dnf",  "yum",   "pacman", "brew",  "snap",
    "flatpak", "pnpm", "uv",   "pipx",  "gem",   "cpan",
    // containers & infra
    "podman", "kubectl", "helm", "terraform", "ansible", "vagrant",
    "docker-compose",
    // network & system
    "ss",    "netstat", "iptables", "nft",  "firewall-cmd",
    "lsof",  "strace", "ltrace", "perf",  "valgrind",
    "fdisk", "lsblk",  "blkid",  "mkfs",  "fsck",
    // file & text
    "xargs", "tee",    "file",   "stat",  "ln",    "readlink",
    "basename", "dirname", "realpath", "md5sum", "sha256sum",
    "jq",    "yq",     "rg",     "fd",    "bat",   "exa",
    // process & job
    "killall", "pkill", "pgrep", "nohup", "screen", "tmux",
    "bg",    "fg",     "jobs",   "wait",  "nice",  "renice",
    // misc
    "sudo",  "su",     "dmesg",  "uname", "uptime", "id",
    "groups", "passwd", "crontab", "at",   "watch",
    "xdg-open", "open", "pbcopy", "pbpaste", "xclip",
};

/// Keywords that suggest the user wants an LLM agent, not a shell command
const AGENT_KEYWORDS = [_]struct { word: []const u8, tier: ModelTier }{
    // Haiku tier — simple questions
    .{ .word = "explain", .tier = .haiku },
    .{ .word = "what is", .tier = .haiku },
    .{ .word = "what's", .tier = .haiku },
    .{ .word = "how do", .tier = .haiku },
    .{ .word = "how to", .tier = .haiku },
    .{ .word = "tell me", .tier = .haiku },
    .{ .word = "describe", .tier = .haiku },
    .{ .word = "show me", .tier = .haiku },
    .{ .word = "list the", .tier = .haiku },
    .{ .word = "summarize", .tier = .haiku },
    .{ .word = "translate", .tier = .haiku },
    // Sonnet tier — code work
    .{ .word = "fix", .tier = .sonnet },
    .{ .word = "debug", .tier = .sonnet },
    .{ .word = "implement", .tier = .sonnet },
    .{ .word = "add a ", .tier = .sonnet },
    .{ .word = "add the", .tier = .sonnet },
    .{ .word = "create a", .tier = .sonnet },
    .{ .word = "write a", .tier = .sonnet },
    .{ .word = "modify", .tier = .sonnet },
    .{ .word = "change", .tier = .sonnet },
    .{ .word = "update", .tier = .sonnet },
    .{ .word = "refactor", .tier = .sonnet },
    .{ .word = "optimize", .tier = .sonnet },
    .{ .word = "build", .tier = .sonnet },
    .{ .word = "test", .tier = .sonnet },
    .{ .word = "generate", .tier = .sonnet },
    .{ .word = "convert", .tier = .sonnet },
    .{ .word = "migrate", .tier = .sonnet },
    .{ .word = "port", .tier = .sonnet },
    .{ .word = "rename", .tier = .sonnet },
    .{ .word = "extract", .tier = .sonnet },
    .{ .word = "move the", .tier = .sonnet },
    .{ .word = "split", .tier = .sonnet },
    .{ .word = "merge", .tier = .sonnet },
    .{ .word = "clean up", .tier = .sonnet },
    // Opus tier — complex reasoning
    .{ .word = "audit", .tier = .opus },
    .{ .word = "review all", .tier = .opus },
    .{ .word = "redesign", .tier = .opus },
    .{ .word = "architect", .tier = .opus },
    .{ .word = "security", .tier = .opus },
    .{ .word = "analyze the entire", .tier = .opus },
    .{ .word = "compare and contrast", .tier = .opus },
    .{ .word = "deep dive", .tier = .opus },
    .{ .word = "comprehensive", .tier = .opus },
    .{ .word = "thoroughly", .tier = .opus },
    .{ .word = "performance analysis", .tier = .opus },
    .{ .word = "investigate", .tier = .opus },
};

/// Try to classify query using only local heuristics. Returns null if ambiguous.
pub fn classifyLocal(query: []const u8) ?RouteDecision {
    if (query.len == 0) return null;

    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len == 0) return null;

    // Check for agent keywords (case-insensitive)
    var lower_buf: [512]u8 = undefined;
    const lower = toLower(trimmed, &lower_buf);

    // If first word is a known shell command, only match agent keywords at START of query
    // This prevents "sha256sum build.zig" from matching agent keyword "build"
    const first_word_is_shell = isShellCommand(trimmed);

    for (AGENT_KEYWORDS) |kw| {
        if (std.mem.startsWith(u8, lower, kw.word) or
            (!first_word_is_shell and containsWord(lower, kw.word)))
        {
            var rd = RouteDecision{
                .action = .agent,
                .model_tier = kw.tier,
                .cost = switch (kw.tier) {
                    .haiku => .low,
                    .sonnet => .medium,
                    .opus => .high,
                },
                .tools = switch (kw.tier) {
                    .haiku => READ_ONLY,
                    .sonnet => ALL_TOOLS,
                    .opus => ALL_TOOLS,
                },
            };
            rd.setReason("local: keyword match");
            return rd;
        }
    }

    // Short queries with question marks -> haiku
    if (trimmed.len < 80 and std.mem.indexOfScalar(u8, trimmed, '?') != null) {
        var rd = RouteDecision{
            .action = .agent,
            .model_tier = .haiku,
            .cost = .low,
            .tools = READ_ONLY,
        };
        rd.setReason("local: short question");
        return rd;
    }

    // Check for shell command patterns — AFTER agent keywords so natural language
    // queries like "find any TODO comments" don't get misrouted as shell "find"
    if (isShellCommand(trimmed) and !looksLikeNaturalLanguage(lower)) {
        var rd = RouteDecision{
            .action = .shell,
            .model_tier = .haiku,
            .cost = .low,
        };
        rd.setReason("local: shell command");
        return rd;
    }

    // Ambiguous — needs model classification
    return null;
}

fn isShellCommand(query: []const u8) bool {
    // Get the first word
    const first_space = std.mem.indexOfAny(u8, query, " \t|;&") orelse query.len;
    const first_word = query[0..first_space];

    // Check against known commands
    for (SHELL_COMMANDS) |cmd| {
        if (std.mem.eql(u8, first_word, cmd)) return true;
    }

    // Starts with ./ or / (executable path)
    if (std.mem.startsWith(u8, query, "./") or std.mem.startsWith(u8, query, "/")) return true;

    // Starts with $ or # (copy-pasted command)
    if (query[0] == '$' or query[0] == '#') return true;

    // Starts with sudo/doas followed by a command
    if (std.mem.startsWith(u8, query, "sudo ") or std.mem.startsWith(u8, query, "doas ")) {
        const rest = std.mem.trimLeft(u8, query[5..], " \t");
        return isShellCommand(rest);
    }

    // Variable assignment: FOO=bar or FOO=bar command
    if (first_word.len > 0 and first_word[0] >= 'A' and first_word[0] <= 'Z') {
        if (std.mem.indexOfScalar(u8, first_word, '=') != null) return true;
    }

    // Contains pipe, redirect, or semicolon early -> likely a command
    if (query.len < 120) {
        for (query) |c| {
            if (c == '|' or c == '>' or c == '<') return true;
        }
    }

    // Looks like a file path with extension (e.g., "script.sh")
    if (std.mem.indexOfScalar(u8, first_word, '.') != null and
        first_word.len > 3 and query.len < 100)
    {
        // common executable extensions
        for ([_][]const u8{ ".sh", ".py", ".rb", ".pl", ".js" }) |ext| {
            if (std.mem.endsWith(u8, first_word, ext)) return true;
        }
    }

    return false;
}

/// Detect natural language queries that start with shell command names.
/// E.g. "find any TODO comments in the codebase" vs "find . -name '*.zig'"
fn looksLikeNaturalLanguage(lower_query: []const u8) bool {
    // Natural language indicators — articles, pronouns, prepositions common in queries
    const nl_words = [_][]const u8{
        " any ", " the ", " all ", " every ", " each ",
        " my ", " our ", " this ", " that ", " these ",
        " please ", " can you ", " could you ",
        " where ", " which ", " who ", " what ", " how ",
        " about ", " from the ", " in the ", " of the ",
        " comments", " functions", " files ", " errors",
        " code ", " codebase", " project", " repository",
    };
    for (nl_words) |w| {
        if (std.mem.indexOf(u8, lower_query, w) != null) return true;
    }
    return false;
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
    var fbs = std.io.fixedBufferStream(&body_buf);
    const w = fbs.writer();

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
        writeEscaped(w, query[0..@min(query.len, 500)]);
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
        writeEscaped(w, query[0..@min(query.len, 500)]);
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
        writeEscaped(w, query[0..@min(query.len, 500)]);
        w.writeAll("\"}]}") catch return null;
    }

    const body = body_buf[0..fbs.pos];

    // Build URL
    var url_buf: [256]u8 = undefined;
    const url = switch (config.provider) {
        .anthropic => std.fmt.bufPrint(&url_buf, "{s}/v1/messages", .{config.routerBaseUrl()}) catch return null,
        .ollama => std.fmt.bufPrint(&url_buf, "{s}/api/chat", .{config.routerBaseUrl()}) catch return null,
        .openai_compat => std.fmt.bufPrint(&url_buf, "{s}/v1/chat/completions", .{config.routerBaseUrl()}) catch return null,
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
    var child = std.process.Child.init(argv[0..argc], allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch return null;

    // Write body
    if (child.stdin) |*stdin_pipe| {
        stdin_pipe.writeAll(body) catch {};
        stdin_pipe.close();
        child.stdin = null;
    }

    // Read response
    var resp_buf: [4096]u8 = undefined;
    var resp_len: usize = 0;
    if (child.stdout) |stdout| {
        while (resp_len < resp_buf.len) {
            const n = stdout.read(resp_buf[resp_len..]) catch break;
            if (n == 0) break;
            resp_len += n;
        }
    }
    _ = child.wait() catch {};

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
    // and verbose format: {"action":"shell","model":"sonnet",...}
    if (jsonGetStr(json, "r")) |r| {
        // Compact format
        if (std.mem.eql(u8, r, "s")) {
            rd.action = .shell;
            rd.cost = .low;
            rd.setReason("model: shell command");
        } else {
            rd.action = .agent;
            // Parse tier
            if (jsonGetStr(json, "t")) |t| {
                if (std.mem.eql(u8, t, "h")) {
                    rd.model_tier = .haiku;
                    rd.cost = .low;
                } else if (std.mem.eql(u8, t, "o")) {
                    rd.model_tier = .opus;
                    rd.cost = .high;
                } else {
                    rd.model_tier = .sonnet;
                    rd.cost = .medium;
                }
            }
            rd.setReason("model: agent task");
        }
    } else if (jsonGetStr(json, "action")) |a| {
        // Verbose format
        if (std.mem.eql(u8, a, "shell")) {
            rd.action = .shell;
        } else if (std.mem.eql(u8, a, "fan_out")) {
            rd.action = .fan_out;
            rd.fan_out_count = 3;
        } else {
            rd.action = .agent;
        }

        if (jsonGetStr(json, "model")) |m| {
            if (std.mem.eql(u8, m, "haiku")) {
                rd.model_tier = .haiku;
            } else if (std.mem.eql(u8, m, "opus")) {
                rd.model_tier = .opus;
            } else {
                rd.model_tier = .sonnet;
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
        .shell => ToolMask{},
        .agent => switch (rd.model_tier) {
            .haiku => READ_ONLY,
            .sonnet => ALL_TOOLS,
            .opus => ALL_TOOLS,
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
        srv.* = inference.ForkServer.spawn(model_path) catch return null;
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
