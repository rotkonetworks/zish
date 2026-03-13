// agent.zig - LLM agent thread for zish
// Runs in background, communicates via lock-free queues.
// Supports Anthropic API, Ollama, and any OpenAI-compatible endpoint.

const std = @import("std");
const q = @import("agent_queue.zig");
const log_mod = @import("agent_log.zig");
const router_mod = @import("agent_router.zig");
const tools_mod = @import("agent_tools.zig");
const svc = @import("agent_service.zig");
const filters = @import("agent_filters.zig");

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
            if (std.mem.eql(u8, cfg.model, "claude-opus-4-6")) {
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
// Service pipeline — comptime filter composition
// ============================================================

/// Core service: the tool loop. Calls API, dispatches tools, repeats.
/// Innermost layer of the filter stack.
const ToolLoopService = struct {
    agent: *AgentThread,

    pub fn serve(self: *ToolLoopService, ctx: *svc.AgentCtx, req: *svc.Request) svc.Response {
        // Short-circuit if router already handled it
        if (req.handled) return .{ .status = .ok };

        _ = ctx; // context fields accessed via self.agent

        // Add user message to conversation history before calling API
        self.agent.history.add(.user, req.query) catch return .{ .status = .error_msg };

        return self.agent.runToolLoop() catch |err| {
            var errbuf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&errbuf, "tool loop error: {}", .{err}) catch "tool loop error";
            _ = self.agent.queues.output.push(.error_msg, msg);
            return .{ .status = .error_msg };
        };
    }
};

/// The composed pipeline type (built at comptime):
///   Router → Logging → TokenTracking → Retry → ToolLoop
const Pipeline = svc.Stack(ToolLoopService, .{
    filters.RetryFilter,
    filters.TokenTrackingFilter,
    filters.LoggingFilter,
    filters.RouterFilter,
});

// ============================================================
// Plugin tools — loaded from ~/.zish/agent-tools.json
// (Types and loading functions in agent_tools.zig)
// ============================================================

const MAX_PLUGIN_TOOLS = tools_mod.MAX_PLUGIN_TOOLS;

const PluginTool = tools_mod.PluginTool;

// Plugin tool loading delegated to agent_tools.zig
const loadPluginTools = tools_mod.loadPluginTools;

/// Build Anthropic tools JSON array including built-in + plugin tools
fn buildToolsJson(plugins: []const PluginTool, count: u8, buf: []u8) u16 {
    return tools_mod.buildToolsJson(plugins, count, buf, TOOLS_JSON);
}

// shellEscape moved to agent_tools.zig

// ============================================================
// Conversation history
// ============================================================

const MAX_MSGS = 20;
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
    messages: [MAX_MSGS]Message = undefined,
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
        if (self.count >= MAX_MSGS) {
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
// Autonomous Task Queue — agent works through these when idle
// ============================================================

const MAX_TASKS = 16;

const Task = struct {
    buf: [512]u8 = undefined,
    len: u16 = 0,
    status: TaskStatus = .pending,

    fn text(self: *const Task) []const u8 {
        return self.buf[0..self.len];
    }
};

const TaskStatus = enum { pending, running, done, failed };

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
    // Full tool access (Edit/Write) — user-spawned workers get this
    full_tools: bool = false,

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
    // Recursion depth — 0 = main agent, incremented for each subagent level
    depth: u8 = 0,
    // Autonomous task queue — agent works through these when idle
    task_queue: [MAX_TASKS]Task = undefined,
    task_count: u8 = 0,
    task_head: u8 = 0, // next task to process

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
        return self.spawnSubAgentFull(prompt, description, false);
    }

    fn spawnWorker(self: *AgentThread, prompt: []const u8, description: []const u8) ![]const u8 {
        return self.spawnSubAgentFull(prompt, description, true);
    }

    fn spawnSubAgentFull(self: *AgentThread, prompt: []const u8, description: []const u8, full_tools: bool) ![]const u8 {
        // Recursion depth limit — max 3 levels deep
        if (self.depth >= 3) return error.TooDeep;

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
        sa.full_tools = full_tools;

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

        // Spawn thread — pass depth+1 for recursion tracking
        const child_depth = self.depth + 1;
        sa.thread = std.Thread.spawn(.{}, subAgentThreadFn, .{
            self.allocator, sa, prompt_copy, cfg, &self.system_prompt_buf, self.system_prompt_len, full_tools, child_depth,
        }) catch {
            self.allocator.free(prompt_copy);
            sa.setResult("Failed to spawn subagent thread", .failed);
            return error.SpawnFailed;
        };

        return sa.id();
    }

    fn addTask(self: *AgentThread, text: []const u8) bool {
        if (self.task_count >= MAX_TASKS) return false;
        var task = &self.task_queue[self.task_count];
        task.* = .{};
        const n: u16 = @intCast(@min(text.len, 512));
        @memcpy(task.buf[0..n], text[0..n]);
        task.len = n;
        task.status = .pending;
        self.task_count += 1;
        return true;
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
                if (req_msg.kind == .add_task) {
                    if (self.addTask(req_msg.slice())) {
                        var tbuf: [128]u8 = undefined;
                        const tmsg = std.fmt.bufPrint(&tbuf, "Queued task {d}: {s}", .{
                            self.task_count, req_msg.slice()[0..@min(req_msg.slice().len, 60)],
                        }) catch "Task queued";
                        _ = self.queues.output.push(.tool_done, tmsg);
                    }
                    continue;
                }
                if (req_msg.kind == .spawn_worker) {
                    const task_text = req_msg.slice();
                    const desc = task_text[0..@min(task_text.len, 60)];
                    _ = self.spawnWorker(task_text, desc) catch {
                        _ = self.queues.output.push(.error_msg, "Failed to spawn worker (max 8)");
                    };
                    continue;
                }
                if (req_msg.kind == .agent_status_req) {
                    // Report subagent status back to main thread
                    for (&self.subagents, 0..) |*sa, i| {
                        if (sa.id_len == 0) continue;
                        var sbuf: [256]u8 = undefined;
                        const status_str = switch (@atomicLoad(SubAgentStatus, &sa.status, .acquire)) {
                            .running => "\x1b[33mrunning\x1b[0m",
                            .done => "\x1b[32mdone\x1b[0m",
                            .failed => "\x1b[31mfailed\x1b[0m",
                        };
                        const tools_str: []const u8 = if (sa.full_tools) " \x1b[36m[full]\x1b[0m" else "";
                        const smsg = std.fmt.bufPrint(&sbuf, "  \x1b[33m{d}\x1b[0m ({s}) [{s}]{s} {s}", .{
                            i, sa.id(), status_str, tools_str, sa.desc(),
                        }) catch continue;
                        _ = self.queues.output.push(.agent_status, smsg);
                    }
                    // Also report task queue
                    for (self.task_queue[0..self.task_count], 0..) |*task, i| {
                        var tbuf2: [256]u8 = undefined;
                        const tstat = switch (task.status) {
                            .pending => "\x1b[90mpending\x1b[0m",
                            .running => "\x1b[33mrunning\x1b[0m",
                            .done => "\x1b[32mdone\x1b[0m",
                            .failed => "\x1b[31mfailed\x1b[0m",
                        };
                        const tmsg2 = std.fmt.bufPrint(&tbuf2, "  \x1b[90mtask {d}\x1b[0m [{s}] {s}", .{
                            i, tstat, task.text(),
                        }) catch continue;
                        _ = self.queues.output.push(.agent_status, tmsg2);
                    }
                    _ = self.queues.output.push(.agent_status, "");
                    continue;
                }
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

            // ── EXHALE: process autonomous tasks when idle ──
            if (self.task_head < self.task_count and self.task_queue[self.task_head].status == .pending) {
                const task = &self.task_queue[self.task_head];
                task.status = .running;
                const task_text = task.text();

                // Notify user
                var notify_buf: [256]u8 = undefined;
                const notify = std.fmt.bufPrint(&notify_buf, "⚙ task {d}/{d}: {s}", .{
                    self.task_head + 1, self.task_count, task_text[0..@min(task_text.len, 80)],
                }) catch "⚙ processing task";
                _ = self.queues.output.push(.tool_call, notify);

                self.queues.setBusy(true);
                self.processQuery(task_text) catch |err| {
                    var errbuf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&errbuf, "task error: {}", .{err}) catch "task error";
                    _ = self.queues.output.push(.error_msg, msg);
                    task.status = .failed;
                };
                if (task.status == .running) task.status = .done;
                self.queues.setBusy(false);
                _ = self.queues.output.push(.done, "");
                self.task_head += 1;
                continue;
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
        // Build context summary for router
        var ctx_summary_buf: [256]u8 = undefined;
        const ctx_summary = self.buildContextSummary(&ctx_summary_buf);

        // Build shared context for the filter pipeline
        var ctx = svc.AgentCtx{
            .allocator = self.allocator,
            .queues = self.queues,
            .config = &self.config,
            .router_config = &self.router_config,
            .session_log = if (self.session_log != null) &self.session_log.? else null,
            .total_input_tokens = &self.total_input_tokens,
            .total_output_tokens = &self.total_output_tokens,
            .context_summary = ctx_summary,
        };

        // Build request
        var req = svc.Request{
            .query = query,
        };

        // Instantiate the pipeline (ToolLoop → Retry → TokenTracking → Logging → Router)
        var pipeline = Pipeline{
            .inner = .{ // LoggingFilter
                .inner = .{ // TokenTrackingFilter
                    .inner = .{ // RetryFilter
                        .inner = .{ // ToolLoopService
                            .agent = self,
                        },
                    },
                },
            },
        };

        // Run the full pipeline
        const resp = pipeline.serve(&ctx, &req);
        _ = resp;

        // Auto-compact: if cumulative input tokens exceed threshold, summarize history
        const AUTO_COMPACT_THRESHOLD: u32 = 120_000;
        if (self.total_input_tokens > AUTO_COMPACT_THRESHOLD and self.history.count > 4 and !self.compact_in_progress) {
            self.autoCompact();
        }
    }

    /// Core tool loop: add user message, call API, dispatch tools, repeat.
    /// Returns aggregated token counts for this query invocation.
    fn runToolLoop(self: *AgentThread) !svc.Response {
        var query_input_tokens: u32 = 0;
        var query_output_tokens: u32 = 0;

        // tool loop: keep calling API until no more tool_use
        var iteration: usize = 0;
        const max_iter = self.config.max_tool_iterations;
        while (iteration < max_iter) : (iteration += 1) {
            if (self.queues.checkCancel()) return .{ .status = .cancelled };

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
            const tool_name = response.tool_name();
            const tool_input = response.tool_command();
            const tool_id = response.tool_use_id();

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

            if (self.session_log) |*sl| sl.logToolCall(tool_name, tool_input) catch {};

            // dispatch tool
            if (self.queues.checkCancel()) return .{ .status = .cancelled };
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

        return .{
            .status = .ok,
            .input_tokens = query_input_tokens,
            .output_tokens = query_output_tokens,
        };
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
        if (self.history.count < 6) return;

        // Add the compact query as a user message
        // Note: addKind may evict oldest 2 messages if at MAX_MSGS capacity,
        // so we capture saved_count AFTER the add to avoid stale indices.
        self.history.add(.user, compact_query) catch return;
        const saved_count = self.history.count - 1; // count before compact_query was added

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

        // Free all but the last few messages, ensuring we start at a clean boundary
        // (not a tool_result, which would reference a missing tool_use)
        var keep = @min(saved_count, 4);
        // Walk backwards from the keep boundary to find a user text message
        while (keep < saved_count) {
            const boundary_idx = saved_count - keep;
            if (self.history.messages[boundary_idx].kind == .tool_result) {
                keep += 1; // include the preceding tool_use_response too
            } else break;
        }
        keep = @min(keep, saved_count); // don't exceed total
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
            if (self.history.count + 2 <= MAX_MSGS) {
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

    /// Build a ToolContext for dispatching tools via agent_tools module
    fn makeToolContext(self: *AgentThread) tools_mod.ToolContext {
        return .{
            .allocator = self.allocator,
            .queues = self.queues,
            .allow_bash = &self.allow_bash,
            .allow_edit = &self.allow_edit,
            .allow_write = &self.allow_write,
            .allow_plugins = &self.allow_plugins,
            .session_log = if (self.session_log != null) &self.session_log.? else null,
            .plugin_tools = &self.plugin_tools,
            .plugin_count = self.plugin_count,
            .spawn_and_collect = &spawnAndCollectCallback,
            .spawn_ctx = @ptrCast(self),
        };
    }

    /// Callback for Agent tool: spawns subagent and collects result
    fn spawnAndCollectCallback(ctx: *anyopaque, allocator: std.mem.Allocator, prompt: []const u8, description: []const u8, full_tools: bool) error{ TooDeep, TooManySubagents, SpawnFailed, OutOfMemory }![]u8 {
        const self: *AgentThread = @ptrCast(@alignCast(ctx));
        const agent_id = try self.spawnSubAgentFull(prompt, description, full_tools);
        // Wait for result (timeout 120s)
        const result = self.collectSubAgent(agent_id, 120_000);
        return allocator.dupe(u8, result);
    }

    fn dispatchTool(self: *AgentThread, tool_name: []const u8, tool_input: []const u8) ![]u8 {
        var ctx = self.makeToolContext();
        return tools_mod.dispatch(&ctx, tool_name, tool_input);
    }

    // Tool execution, confirmation, and plugin tools moved to agent_tools.zig

    const APIResponse = struct {
        text: []u8,           // sub-slice of text_alloc (the actual content)
        text_alloc: []u8,     // full allocation — caller must free this
        has_tool_call: bool,
        // Inline buffers — NOT slices into caller's stack frame
        tool_cmd_buf: [4096]u8 = undefined,
        tool_cmd_len: u16 = 0,
        tool_name_buf: [64]u8 = undefined,
        tool_name_len: u8 = 0,
        tool_id_buf: [64]u8 = undefined,
        tool_id_len: u8 = 0,
        input_tokens: u32 = 0,
        output_tokens: u32 = 0,

        fn tool_command(self: *const APIResponse) []const u8 {
            return self.tool_cmd_buf[0..self.tool_cmd_len];
        }
        fn tool_name(self: *const APIResponse) []const u8 {
            return self.tool_name_buf[0..self.tool_name_len];
        }
        fn tool_use_id(self: *const APIResponse) []const u8 {
            return self.tool_id_buf[0..self.tool_id_len];
        }
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
        if (self.config.api_key.len == 0) {
            _ = self.queues.output.push(.error_msg, "No API key configured — set ANTHROPIC_API_KEY, ~/.zish/key, or login to Claude Code");
            return error.NoAPIKey;
        }
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
                // OAuth tokens (sk-ant-oat01-) use Bearer auth; API keys use X-Api-Key
                const is_oauth = std.mem.startsWith(u8, self.config.api_key, "sk-ant-oat01-");
                const h0 = if (is_oauth)
                    std.fmt.bufPrint(&header_bufs[hdr_idx], "Authorization: Bearer {s}", .{self.config.api_key}) catch ""
                else
                    std.fmt.bufPrint(&header_bufs[hdr_idx], "X-Api-Key: {s}", .{self.config.api_key}) catch "";
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
                // OAuth tokens require the oauth beta flag
                argv_buf[argc] = if (is_oauth)
                    "anthropic-beta: oauth-2025-04-20,prompt-caching-scope-2026-01-05"
                else
                    "anthropic-beta: prompt-caching-scope-2026-01-05";
                argc += 1;

                // Anthropic TypeScript SDK 0.74.0 identification
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
                argv_buf[argc] = "X-Stainless-Retry-Count: 0";
                argc += 1;
                argv_buf[argc] = "-H";
                argc += 1;
                argv_buf[argc] = "X-Stainless-Timeout: 120";
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
            // Empty response with no tool call — likely auth failure or network issue
            _ = self.queues.output.push(.error_msg, "API returned empty response — check authentication or network");
            self.allocator.free(text_buf);
            return error.EmptyResponse;
        }

        var resp = APIResponse{
            .text = text_buf[0..text_len],
            .text_alloc = text_buf,
            .has_tool_call = has_tool_call,
            .input_tokens = resp_input_tokens,
            .output_tokens = resp_output_tokens,
        };
        // Copy tool data into response's inline buffers (not slices into our stack)
        const tcl = @min(tool_cmd_len, resp.tool_cmd_buf.len);
        @memcpy(resp.tool_cmd_buf[0..tcl], tool_cmd_buf[0..tcl]);
        resp.tool_cmd_len = @intCast(tcl);
        const tnl = @min(tool_name_len, resp.tool_name_buf.len);
        @memcpy(resp.tool_name_buf[0..tnl], tool_name_buf[0..tnl]);
        resp.tool_name_len = @intCast(tnl);
        const til = @min(tool_id_len, resp.tool_id_buf.len);
        @memcpy(resp.tool_id_buf[0..til], tool_id_buf[0..til]);
        resp.tool_id_len = @intCast(til);
        return resp;
    }

    // Tool execution functions moved to agent_tools.zig






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
            // Reset tool input buffer — handles multiple tool_use blocks in one response
            // by keeping only the last one (earlier tool calls are re-requested next turn)
            tool_cmd_len.* = 0;
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
                if (unescapeJSON(text, text_buf.*[text_len.*..])) |decoded| {
                    // Unescape succeeded — decoded is a slice of text_buf
                    text_len.* += decoded.len;
                    queues.output.pushWait(.text_delta, decoded);
                } else {
                    // Buffer full or unescape failed — push raw text, don't advance text_buf
                    queues.output.pushWait(.text_delta, text);
                }
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
        if (unescapeJSON(text, text_buf.*[text_len.*..])) |decoded| {
            text_len.* += decoded.len;
            queues.output.pushWait(.text_delta, decoded);
        } else {
            queues.output.pushWait(.text_delta, text);
        }
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
    in_header: bool = false,
    in_blockquote: bool = false,
    in_strikethrough: bool = false,
    in_italic: bool = false,
    line_start: bool = true,
    // Pending characters from end of previous chunk (for cross-chunk ** and ``` detection)
    pending_stars: u8 = 0, // count of trailing * from previous chunk
    pending_backticks: u8 = 0, // count of trailing ` from previous chunk

    /// Process a chunk of text and write ANSI-formatted output
    pub fn render(self: *MarkdownRenderer, writer: anytype, text: []const u8) !void {
        var i: usize = 0;

        // Handle pending characters from previous chunk
        if (self.pending_backticks > 0) {
            const pb = self.pending_backticks;
            self.pending_backticks = 0;
            // Count leading backticks in current chunk
            var leading: u8 = 0;
            while (i < text.len and text[i] == '`' and leading + pb < 3) : (i += 1) {
                leading += 1;
            }
            const total = pb + leading;
            if (total >= 3) {
                // Code block fence split across chunks
                if (!self.in_code_block) {
                    self.in_code_block = true;
                    // Skip language identifier
                    var skip = i;
                    while (skip < text.len and text[skip] != '\n') : (skip += 1) {}
                    const lang = std.mem.trim(u8, text[i..skip], " \t\r");
                    if (lang.len > 0) {
                        try writer.writeAll("\x1b[90m─── ");
                        try writer.writeAll(lang);
                        try writer.writeAll(" ───\x1b[0m\n");
                    } else {
                        try writer.writeAll("\x1b[90m──────────\x1b[0m\n");
                    }
                    try writer.writeAll("\x1b[36m");
                    i = if (skip < text.len) skip + 1 else skip;
                    self.line_start = true;
                } else {
                    self.in_code_block = false;
                    try writer.writeAll("\x1b[0m\n");
                    try writer.writeAll("\x1b[90m──────────\x1b[0m\n");
                    while (i < text.len and text[i] != '\n') : (i += 1) {}
                    self.line_start = true;
                }
            } else if (total >= 1 and !self.in_code_block) {
                // Inline code toggle
                if (!self.in_inline_code) {
                    self.in_inline_code = true;
                    if (self.in_bold) {
                        try writer.writeAll("\x1b[22m\x1b[36m"); // unbold + cyan
                    } else {
                        try writer.writeAll("\x1b[36m");
                    }
                } else {
                    self.in_inline_code = false;
                    if (self.in_bold) {
                        try writer.writeAll("\x1b[39m\x1b[1m"); // reset fg + restore bold
                    } else {
                        try writer.writeAll("\x1b[39m"); // reset fg only
                    }
                }
                // Emit any extra backticks as literal
                var extra: u8 = total - 1;
                while (extra > 0) : (extra -= 1) try writer.writeByte('`');
            } else {
                // Not enough for a toggle — emit as literal
                var j: u8 = 0;
                while (j < pb) : (j += 1) try writer.writeByte('`');
            }
        }
        if (self.pending_stars > 0) {
            const ps = self.pending_stars;
            self.pending_stars = 0;
            if (ps >= 1 and i < text.len and text[i] == '*') {
                // ** split across chunks — bold toggle
                i += 1;
                if (!self.in_bold) {
                    self.in_bold = true;
                    try writer.writeAll("\x1b[1m");
                } else {
                    self.in_bold = false;
                    try writer.writeAll("\x1b[22m"); // unbold only, not full reset
                }
            } else {
                // Single trailing * from prev chunk — italic toggle (flanking check)
                const next_ch: u8 = if (i < text.len) text[i] else '\n';
                const can_open = next_ch != ' ' and next_ch != '\n';
                if ((!self.in_italic and can_open) or self.in_italic) {
                    if (!self.in_italic) {
                        self.in_italic = true;
                        try writer.writeAll("\x1b[3m");
                    } else {
                        self.in_italic = false;
                        try writer.writeAll("\x1b[23m");
                    }
                } else {
                    try writer.writeByte('*');
                }
            }
        }

        while (i < text.len) {
            const c = text[i];

            // Handle code blocks (```)
            if (c == '`') {
                // At chunk boundary — defer backticks to next chunk
                if (i + 2 >= text.len and !self.in_code_block) {
                    var bt: u8 = 0;
                    while (i + bt < text.len and text[i + bt] == '`') : (bt += 1) {}
                    if (i + bt == text.len and bt < 3) {
                        self.pending_backticks = bt;
                        break; // end of chunk
                    }
                }
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
                        try writer.writeAll("\x1b[0m\n");
                        try writer.writeAll("\x1b[90m──────────\x1b[0m\n");
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
                        if (self.in_bold) {
                            try writer.writeAll("\x1b[22m\x1b[36m"); // unbold + cyan
                        } else {
                            try writer.writeAll("\x1b[36m"); // cyan
                        }
                    } else {
                        self.in_inline_code = false;
                        // Reset fg color; restore bold if it was active before inline code
                        if (self.in_bold) {
                            try writer.writeAll("\x1b[39m\x1b[1m"); // reset fg + re-enable bold
                        } else {
                            try writer.writeAll("\x1b[39m"); // reset fg only
                        }
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

            // Backslash escapes: \* \` \# \[ \> \- \_ etc.
            if (c == '\\' and i + 1 < text.len) {
                const next = text[i + 1];
                if (next == '*' or next == '`' or next == '#' or next == '[' or
                    next == '>' or next == '-' or next == '_' or next == '\\' or next == '~')
                {
                    try writer.writeByte(next);
                    i += 2;
                    self.line_start = false;
                    continue;
                }
            }

            // Headers at line start
            if (self.line_start and c == '#' and !self.in_header) {
                var hi = i;
                while (hi < text.len and text[hi] == '#') : (hi += 1) {}
                if (hi < text.len and text[hi] == ' ') {
                    // Start header — let normal loop handle inline formatting
                    self.in_header = true;
                    try writer.writeAll("\x1b[1;33m"); // bold yellow
                    i = hi + 1; // skip "# "
                    self.line_start = false;
                    continue;
                }
            }

            // Blockquotes at line start: > text
            if (self.line_start and c == '>' and !self.in_code_block and !self.in_blockquote) {
                var qi = i + 1;
                if (qi < text.len and text[qi] == ' ') qi += 1; // skip optional space after >
                self.in_blockquote = true;
                try writer.writeAll("\x1b[90m\xe2\x94\x82\x1b[39m\x1b[3m "); // dim │, reset fg, italic
                i = qi;
                self.line_start = false;
                continue;
            }

            // Strikethrough (~~text~~) — not inside code spans
            if (c == '~' and !self.in_code_block and !self.in_inline_code and
                i + 1 < text.len and text[i + 1] == '~')
            {
                if (!self.in_strikethrough) {
                    self.in_strikethrough = true;
                    try writer.writeAll("\x1b[9m"); // strikethrough
                } else {
                    self.in_strikethrough = false;
                    try writer.writeAll("\x1b[29m"); // end strikethrough
                }
                i += 2;
                continue;
            }

            // Bold (**text**) and italic (*text*) — not inside code spans
            if (c == '*' and !self.in_code_block and !self.in_inline_code) {
                if (i + 1 < text.len and text[i + 1] == '*') {
                    // Flanking delimiter check for bold
                    const next_b: u8 = if (i + 2 < text.len) text[i + 2] else '\n';
                    const prev_b: u8 = if (i > 0) text[i - 1] else '\n';
                    const b_can_open = next_b != ' ' and next_b != '\n';
                    const b_can_close = prev_b != ' ' and prev_b != '\n';
                    if ((!self.in_bold and b_can_open) or (self.in_bold and b_can_close)) {
                        if (!self.in_bold) {
                            self.in_bold = true;
                            try writer.writeAll("\x1b[1m"); // bold
                        } else {
                            self.in_bold = false;
                            try writer.writeAll("\x1b[22m"); // unbold only
                        }
                        i += 2;
                        continue;
                    }
                    // Not flanking — emit literal **
                    try writer.writeAll("**");
                    i += 2;
                    self.line_start = false;
                    continue;
                } else if (i + 1 == text.len) {
                    // Trailing * at chunk boundary — defer to next chunk
                    self.pending_stars = 1;
                    i += 1;
                    continue;
                } else {
                    // Single * = italic toggle (flanking delimiter rules)
                    // Opening: next char must not be space/newline
                    // Closing: prev char must not be space/newline
                    const next_ch = text[i + 1]; // safe: i+1 < text.len checked above
                    const prev_ch: u8 = if (i > 0) text[i - 1] else '\n';
                    const can_open = next_ch != ' ' and next_ch != '\n';
                    const can_close = prev_ch != ' ' and prev_ch != '\n';
                    if ((!self.in_italic and can_open) or (self.in_italic and can_close)) {
                        if (!self.in_italic) {
                            self.in_italic = true;
                            try writer.writeAll("\x1b[3m"); // italic
                        } else {
                            self.in_italic = false;
                            try writer.writeAll("\x1b[23m"); // end italic
                        }
                        i += 1;
                        continue;
                    }
                    // Not a delimiter — emit literal *
                    try writer.writeByte('*');
                    i += 1;
                    self.line_start = false;
                    continue;
                }
            }

            // Horizontal rule at line start: ---, ***, ___ (3+ same char, rest is whitespace)
            if (self.line_start and (c == '-' or c == '*' or c == '_') and !self.in_code_block) {
                var hr_count: usize = 0;
                var hr_j = i;
                while (hr_j < text.len and (text[hr_j] == c or text[hr_j] == ' ')) : (hr_j += 1) {
                    if (text[hr_j] == c) hr_count += 1;
                }
                // 3+ of the same char, followed by newline or end of text
                if (hr_count >= 3 and (hr_j >= text.len or text[hr_j] == '\n')) {
                    try writer.writeAll("\x1b[90m");
                    var hk: usize = 0;
                    while (hk < 10) : (hk += 1) try writer.writeAll("\xe2\x94\x80");
                    try writer.writeAll("\x1b[0m\n");
                    i = hr_j;
                    if (i < text.len and text[i] == '\n') i += 1;
                    self.line_start = true;
                    continue;
                }
            }

            // Task list checkboxes: - [ ] or - [x] at line start
            if (self.line_start and (c == '-' or c == '*') and !self.in_code_block and
                i + 5 < text.len and text[i + 1] == ' ' and text[i + 2] == '[')
            {
                const cb = text[i + 3];
                if ((cb == ' ' or cb == 'x' or cb == 'X') and text[i + 4] == ']' and text[i + 5] == ' ') {
                    if (cb == ' ') {
                        try writer.writeAll("\x1b[90m\xe2\x98\x90\x1b[39m "); // unchecked ☐ dim
                    } else {
                        try writer.writeAll("\x1b[32m\xe2\x9c\x93\x1b[39m "); // checked ✓ green
                    }
                    i += 6;
                    self.line_start = false;
                    continue;
                }
            }

            // List items at line start
            if (self.line_start and (c == '-' or c == '*') and i + 1 < text.len and text[i + 1] == ' ') {
                try writer.writeAll("\x1b[33m\xe2\x80\xa2\x1b[39m "); // yellow bullet, reset fg only
                i += 2;
                self.line_start = false;
                continue;
            }

            // Numbered list at line start
            if (self.line_start and c >= '0' and c <= '9') {
                var ni = i;
                while (ni < text.len and text[ni] >= '0' and text[ni] <= '9') : (ni += 1) {}
                if (ni < text.len and (text[ni] == '.' or text[ni] == ')') and ni + 1 < text.len and text[ni + 1] == ' ') {
                    try writer.writeAll("\x1b[33m");
                    try writer.writeAll(text[i..ni + 1]);
                    try writer.writeAll("\x1b[39m "); // reset fg only, preserve bold
                    i = ni + 2;
                    self.line_start = false;
                    continue;
                }
            }

            // Links: [text](url) — show text in cyan, hide url
            if (c == '[' and !self.in_code_block and !self.in_inline_code) {
                // Scan for closing ](
                var j = i + 1;
                while (j < text.len and text[j] != ']' and text[j] != '\n') : (j += 1) {}
                if (j < text.len and text[j] == ']' and j + 1 < text.len and text[j + 1] == '(') {
                    // Found ]( — scan for closing )
                    var k = j + 2;
                    while (k < text.len and text[k] != ')' and text[k] != '\n') : (k += 1) {}
                    if (k < text.len and text[k] == ')') {
                        const link_text = text[i + 1 .. j];
                        if (link_text.len > 0) {
                            try writer.writeAll("\x1b[36m"); // cyan
                            try writer.writeAll(link_text);
                            if (self.in_bold) {
                                try writer.writeAll("\x1b[39m\x1b[1m"); // reset fg + restore bold
                            } else {
                                try writer.writeAll("\x1b[39m"); // reset fg only
                            }
                            i = k + 1;
                            self.line_start = false;
                            continue;
                        }
                    }
                }
            }

            if (c == '\n' and self.in_header) {
                self.in_header = false;
                try writer.writeAll("\x1b[0m\n");
            } else if (c == '\n' and self.in_blockquote) {
                self.in_blockquote = false;
                try writer.writeAll("\x1b[23m\n"); // end italic
            } else {
                try writer.writeByte(c);
            }
            self.line_start = (c == '\n');
            i += 1;
        }
    }

    /// Flush pending delimiter chars that didn't form complete markup.
    /// Call before reset() when a message is complete (done/cancel).
    /// Flush pending delimiter chars and close any open formatting.
    /// Call before reset() when a message is complete (done/cancel).
    pub fn flush(self: *MarkdownRenderer, writer: anytype) !void {
        if (self.pending_backticks > 0) {
            var j: u8 = 0;
            while (j < self.pending_backticks) : (j += 1) try writer.writeByte('`');
            self.pending_backticks = 0;
        }
        if (self.pending_stars > 0) {
            var j: u8 = 0;
            while (j < self.pending_stars) : (j += 1) try writer.writeByte('*');
            self.pending_stars = 0;
        }
        // Close any active inline formatting to prevent terminal state leaks
        if (self.in_bold) try writer.writeAll("\x1b[22m");
        if (self.in_italic) try writer.writeAll("\x1b[23m");
        if (self.in_strikethrough) try writer.writeAll("\x1b[29m");
        if (self.in_header or self.in_blockquote) try writer.writeAll("\x1b[0m");
        if (self.in_code_block or self.in_inline_code) try writer.writeAll("\x1b[39m");
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
/// When full_tools=false: read-only (Bash/Read/Glob/Grep). No confirmation needed.
/// When full_tools=true: full tool access (Edit/Write included). For user-spawned workers.
fn subAgentThreadFn(
    allocator: std.mem.Allocator,
    sa: *SubAgent,
    prompt_owned: []const u8,
    config: Config,
    sys_prompt: *const [8192]u8,
    sys_prompt_len: u16,
    full_tools: bool,
    depth: u8,
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
        .allow_edit = full_tools,
        .allow_write = full_tools,
        .allow_plugins = 0,
        .depth = depth,
    };
    // Set cwd
    const cwd = std.process.getCwd(&agent.cwd) catch "/";
    agent.cwd_len = @intCast(cwd.len);

    if (full_tools) {
        // Full tool set — same as main agent (Edit, Write, Glob, Grep, Read, Bash, WebFetch, WebSearch)
        const tools = std.mem.trim(u8, TOOLS_JSON, " \n\r\t");
        @memcpy(agent.all_tools_json[0..tools.len], tools);
        agent.all_tools_json_len = @intCast(tools.len);
    } else {
        // Read-only subagent tools (Bash, Read, Glob, Grep — no Edit/Write/Agent)
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
    }

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
        const tool_name = response.tool_name();
        const tool_input = response.tool_command();
        const tool_id = response.tool_use_id();

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

        // Dispatch tool (full_tools: all tools including Agent for recursive spawning)
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

    // Join any sub-agents this worker spawned (recursive cleanup)
    for (&agent.subagents, 0..) |*child_sa, i| {
        if (i >= agent.subagent_count) break;
        if (child_sa.thread) |t| {
            child_sa.requestCancel();
            t.join();
            child_sa.thread = null;
        }
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
