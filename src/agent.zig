// agent.zig - LLM agent thread for zish
// Runs in background, communicates via lock-free queues.
// Supports Anthropic API, Ollama, and any OpenAI-compatible endpoint.

const std = @import("std");
const compat = @import("compat.zig");
const q = @import("agent_queue.zig");
const log_mod = @import("agent_log.zig");
const router_mod = @import("agent_router.zig");
const tools_mod = @import("agent_tools.zig");
const svc = @import("agent_service.zig");
const filters = @import("agent_filters.zig");
const inference = @import("inference/root.zig");

pub const AgentQueues = q.AgentQueues;
pub const SessionLog = log_mod.SessionLog;
pub const AgentConfig = log_mod.AgentConfig;

// ============================================================
// Configuration
// ============================================================

pub const Provider = enum { anthropic, ollama, openai_compat, local };

pub const Config = struct {
    provider: Provider = .anthropic,
    model: []const u8 = "claude-opus-4-6",
    api_key: []const u8 = "",
    base_url: []const u8 = "https://api.anthropic.com",
    max_tokens: u32 = 16384,
    thinking_budget: u32 = 0, // 0 = disabled, >0 = extended thinking budget tokens
    max_tool_iterations: u32 = 10,
    auto_allow: bool = false,
    local_model: []const u8 = "", // path to GGUF for local provider

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
        } else if (std.mem.eql(u8, ac.provider, "local")) {
            cfg.provider = .local;
        } else {
            cfg.provider = .anthropic;
        }
        // Local model path (shared with router config field)
        if (ac.router_local_model.len > 0) {
            cfg.local_model = ac.router_local_model;
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
        // Load user-contributed patterns from ~/.zish/patterns/
        rc.loadPlugins();
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
            .local => "local",
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

const MAX_MSGS = 64;
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
            // Drop oldest messages until we reach a clean boundary
            // (first remaining message must be user .text, not tool_result)
            var n: usize = 2;
            while (n < self.count -| 2) {
                // Ensure the new first message is a user text message
                if (self.messages[n].kind == .tool_result or
                    (self.messages[n].role == .assistant and self.messages[n].kind == .tool_use_response))
                {
                    n += 1;
                } else break;
            }
            n = @min(n, self.count -| 2); // keep at least 2 messages
            for (0..n) |i| {
                self.allocator.free(self.messages[i].content[0..self.messages[i].alloc_len]);
            }
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
    \\{"name":"WebSearch","description":"Search the web using DuckDuckGo. Returns titles, URLs and snippets. Use when you need current information.","input_schema":{"type":"object","properties":{"query":{"type":"string","description":"Search query"},"max_results":{"type":"integer","description":"Max results to return (default: 8)"}},"required":["query"]}},
    \\{"name":"Post","description":"Post to the shared bulletin board. All agents see all posts. Use to share discoveries, flag problems, request help, or vote (+1/-1) on other agents' posts. Types: discovery (share findings), escalate (urgent, override plans), request_peer (ask for help), vote (+1 or -1 on a claim/decision).","input_schema":{"type":"object","properties":{"type":{"type":"string","enum":["discovery","escalate","request_peer","vote"],"description":"Post type"},"message":{"type":"string","description":"Post content. For votes, prefix with +1 or -1"}},"required":["type","message"]}}
    \\]
;

// ============================================================
// HTTP + SSE streaming
// ============================================================

fn getGitBranch(buf: []u8) ![]const u8 {
    const result = std.process.run(std.heap.page_allocator, compat.io(), .{
        .argv = &[_][]const u8{ "git", "rev-parse", "--abbrev-ref", "HEAD" },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(256),
    }) catch return error.GitFailed;
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);
    const trimmed = std.mem.trimEnd(u8, result.stdout, "\n\r ");
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
    // Git worktree isolation — workers get their own worktree
    worktree_path: [256]u8 = undefined,
    worktree_path_len: u16 = 0,
    branch_name: [64]u8 = undefined,
    branch_name_len: u8 = 0,
    has_worktree: bool = false,

    fn id(self: *const SubAgent) []const u8 {
        return self.id_buf[0..self.id_len];
    }

    fn desc(self: *const SubAgent) []const u8 {
        return self.desc_buf[0..self.desc_len];
    }

    fn worktreePath(self: *const SubAgent) []const u8 {
        return self.worktree_path[0..self.worktree_path_len];
    }

    fn branchName(self: *const SubAgent) []const u8 {
        return self.branch_name[0..self.branch_name_len];
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
    // Local inference server (for provider = .local)
    local_server: ?*inference.ForkServer = null,
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
    // Agent identity (for bulletin posts)
    agent_id: [16]u8 = undefined,
    agent_id_len: u8 = 0,
    // Bulletin read cursor — tracks what we've already seen
    bulletin_cursor: usize = 0,
    // Separate cursor for request_peer pickup (exhale phase)
    peer_scan_cursor: usize = 0,

    /// Post to the shared bulletin board — visible to all agents.
    fn broadcast(self: *AgentThread, kind: q.PostKind, text: []const u8) void {
        self.queues.bulletin.post(kind, self.agent_id[0..self.agent_id_len], self.depth, text);
    }

    /// Coffee pause: read the bulletin, format relevant peer activity.
    /// Returns a slice into buf with bulletin context, or empty if nothing new.
    /// Called between tool calls so the agent stays aware of peer activity.
    ///
    /// Every agent reads the bulletin — no hierarchy. Read-only agents that
    /// can't act on what they see cast votes instead (upvote/downvote).
    /// This is the commons: everyone has a voice.
    fn coffeePause(self: *AgentThread, buf: []u8) []const u8 {
        var posts: [16]q.Post = undefined;
        const br = self.queues.bulletin.read(self.bulletin_cursor, &posts);
        self.bulletin_cursor = br.new_cursor;
        if (br.count == 0) return buf[0..0];

        // Filter: skip own posts and vote echoes
        var relevant: [16]usize = undefined;
        var rel_count: usize = 0;
        const my_id = self.agent_id[0..self.agent_id_len];
        for (0..br.count) |i| {
            if (std.mem.eql(u8, posts[i].authorSlice(), my_id)) continue;
            if (posts[i].kind == .status_change) continue;
            // Skip vote posts (they're signals, not conversation)
            if (posts[i].kind == .vote) continue;
            relevant[rel_count] = i;
            rel_count += 1;
            if (rel_count >= relevant.len) break;
        }
        if (rel_count == 0) return buf[0..0];

        // Build context note for the model — LLM decides what to vote/comment on via Post tool
        var fbs: std.Io.Writer = .fixed(buf);
        const w = &fbs;
        w.writeAll("\n\n[bulletin — peer activity]\n") catch {};
        for (relevant[0..rel_count]) |idx| {
            const p = &posts[idx];
            const kind_str: []const u8 = switch (p.kind) {
                .discovery => "discovery",
                .escalate => "ESCALATE",
                .request_peer => "help wanted",
                .vote => "vote",
                .status_change => "status",
            };
            w.print("- {s} ({s}): {s}\n", .{ p.authorSlice(), kind_str, p.slice() }) catch {};
        }
        // Tell the model what it can do based on its permissions
        if (!self.allow_edit) {
            w.writeAll("[you are read-only — respond with discoveries or escalate if urgent]\n") catch {};
        }
        return buf[0..fbs.end];
    }

    /// Scan bulletin for unclaimed request_peer posts and spawn workers.
    /// Only called by main agent (depth 0) during exhale phase.
    fn pickUpPeerRequests(self: *AgentThread) void {
        var posts: [32]q.Post = undefined;
        const br = self.queues.bulletin.read(self.peer_scan_cursor, &posts);
        self.peer_scan_cursor = br.new_cursor;
        if (br.count == 0) return;

        for (posts[0..br.count]) |*p| {
            if (p.kind != .request_peer) continue;
            // Don't pick up our own requests
            const author = p.authorSlice();
            const self_id = self.agent_id[0..self.agent_id_len];
            if (std.mem.eql(u8, author, self_id)) continue;

            // Check if we have capacity
            if (self.subagent_count >= MAX_SUBAGENTS) break;

            // Spawn a worker for this request
            const task_text = p.slice();
            if (task_text.len == 0) continue;

            _ = self.spawnWorker(task_text, "peer-request") catch continue;

            // Acknowledge on bulletin
            var ack_buf: [128]u8 = undefined;
            const ack = std.fmt.bufPrint(&ack_buf, "picked up: {s}", .{
                task_text[0..@min(task_text.len, 80)],
            }) catch continue;
            self.broadcast(.status_change, ack);
        }
    }

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

        // main agent identity
        const main_id = "main";
        @memcpy(self.agent_id[0..main_id.len], main_id);
        self.agent_id_len = main_id.len;

        // Start reading bulletin from current position (don't replay old posts)
        self.bulletin_cursor = queues.bulletin.position();
        self.peer_scan_cursor = self.bulletin_cursor;

        // get cwd
        const cwd = compat.posix.getcwd(&self.cwd) catch "/";
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
        var fbs: std.Io.Writer = .fixed(&self.system_prompt_buf);
        const w = &fbs;
        w.writeAll(SYSTEM_PROMPT_PREFIX) catch return;
        w.print("\nWorking directory: {s}\n", .{self.cwdSlice()}) catch return;
        w.print("Git branch: {s}\n", .{self.branchSlice()}) catch return;

        // try to list top-level files for project context
        if (std.Io.Dir.cwd().openDir(compat.io(), self.cwdSlice(), .{ .iterate = true })) |dir_handle| {
            var dir = dir_handle;
            defer dir.close(compat.io());
            w.writeAll("\nProject files: ") catch return;
            var count: usize = 0;
            var iter = dir.iterate();
            while (iter.next(compat.io()) catch null) |entry| {
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

        self.system_prompt_len = @intCast(fbs.end);
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

                if (std.Io.Dir.cwd().readFileAlloc(compat.io(), fp, std.heap.page_allocator, .limited(4096))) |content| {
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
        // join all subagent threads and clean up worktrees
        for (&self.subagents, 0..) |*sa, i| {
            if (i >= self.subagent_count) break;
            if (sa.thread) |t| {
                sa.requestCancel();
                t.join();
                sa.thread = null;
            }
            if (sa.has_worktree) self.cleanupWorktree(sa);
        }
        // Shut down local inference server if running
        if (self.local_server) |srv| {
            srv.shutdown();
            self.allocator.destroy(srv);
            self.local_server = null;
        }
        // Shut down fork-based router inference server if running
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

        // Create git worktree for full-tools workers (filesystem isolation)
        if (full_tools) {
            const branch = std.fmt.bufPrint(&sa.branch_name, "zish-worker-{d}", .{id_num}) catch "zish-worker";
            sa.branch_name_len = @intCast(branch.len);

            const wt_path = std.fmt.bufPrint(&sa.worktree_path, "/tmp/zish-worktree-{d}", .{id_num}) catch "";
            sa.worktree_path_len = @intCast(wt_path.len);

            // git worktree add -b <branch> <path> HEAD
            var wt_cmd_buf: [512]u8 = undefined;
            const wt_cmd = std.fmt.bufPrint(&wt_cmd_buf, "git worktree add -b {s} {s} HEAD 2>&1", .{
                branch, wt_path,
            }) catch "";
            const wt_result = std.process.run(self.allocator, compat.io(), .{
                .argv = &[_][]const u8{ "/bin/sh", "-c", wt_cmd },
                .stdout_limit = .limited(4096),
                .stderr_limit = .limited(4096),
                .cwd = if (self.cwd_len > 0) .{ .path = self.cwd[0..self.cwd_len] } else .inherit,
            }) catch {
                sa.setResult("Failed to create git worktree", .failed);
                return error.SpawnFailed;
            };
            self.allocator.free(wt_result.stdout);
            self.allocator.free(wt_result.stderr);

            if (wt_result.term != .exited or wt_result.term.exited != 0) {
                sa.setResult("git worktree add failed", .failed);
                return error.SpawnFailed;
            }
            sa.has_worktree = true;
        }

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
            self.allocator, sa, prompt_copy, cfg, &self.system_prompt_buf, self.system_prompt_len, full_tools, child_depth, self.queues.bulletin,
        }) catch {
            self.allocator.free(prompt_copy);
            if (sa.has_worktree) self.cleanupWorktree(sa);
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
                const deadline = @as(u64, @intCast(compat.milliTimestamp())) + timeout_ms;
                while (!sa.isDone()) {
                    if (@as(u64, @intCast(compat.milliTimestamp())) >= deadline) {
                        sa.requestCancel();
                        return "Subagent timed out";
                    }
                    if (self.queues.checkCancel()) {
                        sa.requestCancel();
                        return "Cancelled";
                    }
                    compat.sleep(50 * std.time.ns_per_ms);
                }
                // Join thread
                if (sa.thread) |t| {
                    t.join();
                    sa.thread = null;
                }
                // Merge worktree branch if worker made changes
                if (sa.has_worktree) {
                    self.mergeWorktree(sa);
                }
                // Log result
                if (self.session_log) |*sl| sl.logAgentResult(sa.id(), sa.result()) catch {};
                return sa.result();
            }
        }
        return "Unknown subagent ID";
    }

    /// Merge a worker's worktree branch, then clean up.
    /// Auto-commits any uncommitted changes in the worktree first.
    fn mergeWorktree(self: *AgentThread, sa: *SubAgent) void {
        const cwd: std.process.Child.Cwd = if (self.cwd_len > 0) .{ .path = self.cwd[0..self.cwd_len] } else .inherit;
        const wt = sa.worktreePath();
        const branch = sa.branchName();

        // 1. Auto-commit any uncommitted changes in the worktree
        var commit_cmd_buf: [512]u8 = undefined;
        const desc_trunc = sa.desc()[0..@min(sa.desc().len, 60)];
        const commit_cmd = std.fmt.bufPrint(&commit_cmd_buf,
            "cd {s} && git add -A && git diff --cached --quiet 2>/dev/null || git commit -m 'worker {s}: {s}' 2>&1",
            .{ wt, sa.id(), desc_trunc },
        ) catch "";
        if (commit_cmd.len > 0) {
            const cr = std.process.run(self.allocator, compat.io(), .{
                .argv = &[_][]const u8{ "/bin/sh", "-c", commit_cmd },
                .stdout_limit = .limited(4096),
                .stderr_limit = .limited(4096),
            }) catch null;
            if (cr) |r| {
                self.allocator.free(r.stdout);
                self.allocator.free(r.stderr);
            }
        }

        // 2. Merge worker branch into parent
        const status = @atomicLoad(SubAgentStatus, &sa.status, .acquire);
        if (status == .done) {
            var merge_buf: [256]u8 = undefined;
            const merge_cmd = std.fmt.bufPrint(&merge_buf,
                "git merge --no-edit {s} 2>&1", .{branch},
            ) catch "";
            if (merge_cmd.len > 0) {
                const mr = std.process.run(self.allocator, compat.io(), .{
                    .argv = &[_][]const u8{ "/bin/sh", "-c", merge_cmd },
                    .stdout_limit = .limited(4096),
                    .stderr_limit = .limited(4096),
                    .cwd = cwd,
                }) catch null;
                if (mr) |r| {
                    defer self.allocator.free(r.stdout);
                    defer self.allocator.free(r.stderr);
                    if (r.term != .exited or r.term.exited != 0) {
                        // Merge conflict — abort, keep branch for manual resolution
                        const abort = std.process.run(self.allocator, compat.io(), .{
                            .argv = &[_][]const u8{ "/bin/sh", "-c", "git merge --abort 2>/dev/null" },
                            .stdout_limit = .limited(256),
                            .stderr_limit = .limited(256),
                            .cwd = cwd,
                        }) catch null;
                        if (abort) |ar| {
                            self.allocator.free(ar.stdout);
                            self.allocator.free(ar.stderr);
                        }
                        _ = self.queues.output.push(.error_msg,
                            "merge conflict from worker — branch preserved for manual resolution");
                        // Remove worktree but keep branch
                        var rm_buf: [256]u8 = undefined;
                        const rm_cmd = std.fmt.bufPrint(&rm_buf,
                            "git worktree remove --force {s} 2>/dev/null", .{wt},
                        ) catch "";
                        if (rm_cmd.len > 0) {
                            const rr = std.process.run(self.allocator, compat.io(), .{
                                .argv = &[_][]const u8{ "/bin/sh", "-c", rm_cmd },
                                .stdout_limit = .limited(256),
                                .stderr_limit = .limited(256),
                                .cwd = cwd,
                            }) catch null;
                            if (rr) |r2| {
                                self.allocator.free(r2.stdout);
                                self.allocator.free(r2.stderr);
                            }
                        }
                        sa.has_worktree = false;
                        return;
                    }
                }
            }
        }

        // 3. Clean up worktree + branch
        self.cleanupWorktree(sa);
    }

    /// Remove worktree directory and delete the branch.
    fn cleanupWorktree(self: *AgentThread, sa: *SubAgent) void {
        if (!sa.has_worktree) return;
        const cwd: std.process.Child.Cwd = if (self.cwd_len > 0) .{ .path = self.cwd[0..self.cwd_len] } else .inherit;
        var cleanup_buf: [512]u8 = undefined;
        const cleanup_cmd = std.fmt.bufPrint(&cleanup_buf,
            "git worktree remove --force {s} 2>/dev/null; git branch -D {s} 2>/dev/null",
            .{ sa.worktreePath(), sa.branchName() },
        ) catch "";
        if (cleanup_cmd.len > 0) {
            const cr = std.process.run(self.allocator, compat.io(), .{
                .argv = &[_][]const u8{ "/bin/sh", "-c", cleanup_cmd },
                .stdout_limit = .limited(256),
                .stderr_limit = .limited(256),
                .cwd = cwd,
            }) catch null;
            if (cr) |r| {
                self.allocator.free(r.stdout);
                self.allocator.free(r.stderr);
            }
        }
        sa.has_worktree = false;
    }

    fn listSubAgents(self: *AgentThread, buf: []u8) []const u8 {
        var fbs: std.Io.Writer = .fixed(buf);
        const w = &fbs;
        if (self.subagent_count == 0) {
            w.writeAll("No subagents.\n") catch {};
            return buf[0..fbs.end];
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
        return buf[0..fbs.end];
    }

    /// Main agent loop: process requests from main thread and remote attach (FIFO)
    fn run(self: *AgentThread) void {
        // Create ctl FIFO for remote attach
        const ctl_fd: ?compat.posix.fd_t = if (self.session_log) |*sl| sl.createCtlFifo() else null;
        defer if (ctl_fd) |fd| compat.posix.close(fd);

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
                if (req_msg.kind == .agent_tree_req) {
                    self.sendTreeNodes();
                    continue;
                }
                if (req_msg.kind == .agent_result_req) {
                    self.sendAgentResult(req_msg.slice());
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
                const n = compat.posix.read(fd, &fifo_buf) catch 0;
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

            // ── EXHALE: pick up request_peer posts from bulletin ──
            if (self.depth == 0) { // only main agent spawns workers for help requests
                self.pickUpPeerRequests();
            }

            compat.sleep(10 * std.time.ns_per_ms);
        }
    }

    fn buildContextSummary(self: *AgentThread, buf: *[256]u8) []const u8 {
        if (self.history.count == 0) return "";
        var fbs: std.Io.Writer = .fixed(buf);
        const w = &fbs;
        w.print("{d} messages", .{self.history.count}) catch {};
        // Include first user message as topic hint
        if (self.history.count > 0 and self.history.messages[0].role == .user) {
            const first = self.history.messages[0].content[0..self.history.messages[0].content_len];
            const preview_len = @min(first.len, 80);
            w.print(", topic: {s}", .{first[0..preview_len]}) catch {};
        }
        return buf[0..fbs.end];
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
            var assist_fbs: std.Io.Writer = .fixed(&assist_buf);
            const aw = &assist_fbs;
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
            try self.history.addKind(.assistant, .tool_use_response, assist_buf[0..assist_fbs.end]);

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
            var result_fbs: std.Io.Writer = .fixed(result_json_buf);
            const rw = &result_fbs;
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
            // ☕ Coffee pause — check what peers are up to before next API call
            var bulletin_buf: [2048]u8 = undefined;
            const bulletin_note = self.coffeePause(&bulletin_buf);
            if (bulletin_note.len > 0) {
                // Append bulletin as a text block alongside the tool_result
                rw.writeAll("},{\"type\":\"text\",\"text\":") catch {};
                writeJSONString(rw, bulletin_note) catch {};
                rw.writeAll("}]") catch {};
            } else {
                rw.writeAll("}]") catch {};
            }
            try self.history.addKind(.user, .tool_result, result_json_buf[0..result_fbs.end]);
        }

        return .{
            .status = .ok,
            .input_tokens = query_input_tokens,
            .output_tokens = query_output_tokens,
        };
    }

    /// Send structured tree nodes for the tree view.
    /// Binary format per node: [depth:u8][status:u8][type:u8][id_len:u8][id][desc_len:u8][desc][result_preview...]
    /// Status: 0=running, 1=done, 2=failed, 3=pending
    /// Type: 0=agent(main), 1=subagent(readonly), 2=worker(full), 3=task
    fn sendTreeNodes(self: *AgentThread) void {
        // Node 0: main agent
        var buf: [q.MAX_MSG_LEN]u8 = undefined;
        const main_status: u8 = if (self.queues.isBusy()) 0 else 1;
        buf[0] = 0; // depth 0
        buf[1] = main_status;
        buf[2] = 0; // type: main agent
        buf[3] = 4; // id_len
        @memcpy(buf[4..8], "main");
        const model = self.config.model;
        const mlen: u8 = @intCast(@min(model.len, 200));
        buf[8] = mlen;
        @memcpy(buf[9..][0..mlen], model[0..mlen]);
        _ = self.queues.output.push(.agent_tree_node, buf[0 .. 9 + mlen]);

        // Subagents
        for (&self.subagents) |*sa| {
            if (sa.id_len == 0) continue;
            var nbuf: [q.MAX_MSG_LEN]u8 = undefined;
            nbuf[0] = 1; // depth 1
            nbuf[1] = switch (@atomicLoad(SubAgentStatus, &sa.status, .acquire)) {
                .running => 0,
                .done => 1,
                .failed => 2,
            };
            nbuf[2] = if (sa.full_tools) 2 else 1; // worker or read-only
            nbuf[3] = sa.id_len;
            @memcpy(nbuf[4..][0..sa.id_len], sa.id_buf[0..sa.id_len]);
            const dlen = sa.desc_len;
            nbuf[4 + sa.id_len] = dlen;
            @memcpy(nbuf[5 + sa.id_len ..][0..dlen], sa.desc_buf[0..dlen]);
            // Result preview (first 200 bytes if done)
            const preview_start = @as(usize, 5) + sa.id_len + dlen;
            if (sa.isDone() and sa.result_len > 0) {
                const plen = @min(sa.result_len, @as(u32, @intCast(q.MAX_MSG_LEN - preview_start)));
                @memcpy(nbuf[preview_start..][0..plen], sa.result_buf[0..plen]);
                _ = self.queues.output.push(.agent_tree_node, nbuf[0 .. preview_start + plen]);
            } else {
                _ = self.queues.output.push(.agent_tree_node, nbuf[0..preview_start]);
            }
        }

        // Tasks
        for (self.task_queue[0..self.task_count], 0..) |*task, i| {
            var tbuf: [q.MAX_MSG_LEN]u8 = undefined;
            tbuf[0] = 1; // depth 1
            tbuf[1] = switch (task.status) {
                .pending => 3,
                .running => 0,
                .done => 1,
                .failed => 2,
            };
            tbuf[2] = 3; // type: task
            // ID = task index as string
            var id_tmp: [4]u8 = undefined;
            const id_str = std.fmt.bufPrint(&id_tmp, "t{d}", .{i}) catch "t?";
            tbuf[3] = @intCast(id_str.len);
            @memcpy(tbuf[4..][0..id_str.len], id_str);
            const ttext = task.text();
            const tlen: u8 = @intCast(@min(ttext.len, 200));
            tbuf[4 + id_str.len] = tlen;
            @memcpy(tbuf[5 + id_str.len ..][0..tlen], ttext[0..tlen]);
            _ = self.queues.output.push(.agent_tree_node, tbuf[0 .. 5 + id_str.len + tlen]);
        }

        // End marker: empty node
        _ = self.queues.output.push(.agent_tree_node, "");
    }

    /// Send full result for a subagent by ID
    fn sendAgentResult(self: *AgentThread, id_text: []const u8) void {
        for (&self.subagents) |*sa| {
            if (sa.id_len == 0) continue;
            if (std.mem.eql(u8, sa.id(), id_text)) {
                if (sa.isDone()) {
                    const res = sa.result();
                    // Send in chunks since result can be up to 32KB
                    var offset: usize = 0;
                    while (offset < res.len) {
                        const chunk_len = @min(res.len - offset, q.MAX_MSG_LEN);
                        _ = self.queues.output.push(.agent_result, res[offset..][0..chunk_len]);
                        offset += chunk_len;
                    }
                } else {
                    _ = self.queues.output.push(.agent_result, "(running...)");
                }
                _ = self.queues.output.push(.agent_result, "");
                return;
            }
        }
        _ = self.queues.output.push(.agent_result, "(not found)");
        _ = self.queues.output.push(.agent_result, "");
    }

    fn autoCompact(self: *AgentThread) void {
        self.compact_in_progress = true;
        defer self.compact_in_progress = false;

        _ = self.queues.output.push(.tool_call, "compacting context...");

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

        // Free all but the last few messages, ensuring we start at a clean boundary.
        // The first kept message must be a user .text message (not tool_result,
        // not following a tool_use_response that would create consecutive assistant msgs).
        var keep = @min(saved_count, 4);
        // Walk backwards until the boundary message is a user text message
        while (keep < saved_count) {
            const boundary_idx = saved_count - keep;
            const bmsg = self.history.messages[boundary_idx];
            if (bmsg.kind != .text or bmsg.role != .user) {
                keep += 1; // skip tool_result, tool_use_response, or misaligned messages
            } else break;
        }
        keep = @min(keep, saved_count); // don't exceed total
        const drop = saved_count - keep;
        for (0..drop) |i| {
            self.allocator.free(self.history.messages[i].content[0..self.history.messages[i].alloc_len]);
        }
        // Shift kept messages to make room for summary at front.
        // Copy direction matters: src starts at `drop`, dest at 2 — when drop < 2
        // dest > src (overlap), so we must copy backwards to avoid smearing.
        if (drop > 0) {
            if (drop > 2) {
                std.mem.copyForwards(Message, self.history.messages[2 .. 2 + keep], self.history.messages[drop .. drop + keep]);
            } else if (drop < 2) {
                std.mem.copyBackwards(Message, self.history.messages[2 .. 2 + keep], self.history.messages[drop .. drop + keep]);
            }
            // drop == 2: messages already in place
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
                // Drop oldest 2 (before summary), overwrite [0] and [1] below.
                // Messages [2..count] stay in place, count unchanged.
                self.allocator.free(self.history.messages[0].content[0..self.history.messages[0].alloc_len]);
                self.allocator.free(self.history.messages[1].content[0..self.history.messages[1].alloc_len]);
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

        _ = self.queues.output.push(.tool_done, "context compacted");
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
            .agent_id = self.agent_id[0..self.agent_id_len],
            .agent_depth = self.depth,
            .cwd = if (self.cwd_len > 0) self.cwd[0..self.cwd_len] else null,
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
                .local => self.callLocal(),
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
                compat.sleep(delay_ms * std.time.ns_per_ms);
            }
        }
    }

    fn buildMessagesJSON(self: *AgentThread, buf: []u8) ![]const u8 {
        var fbs: std.Io.Writer = .fixed(buf);
        const w = &fbs;
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
        return buf[0..fbs.end];
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

        var fbs: std.Io.Writer = .fixed(&body_buf);
        const w = &fbs;
        // Check for effort override from /effort command
        const effective_max_tokens = blk: {
            const override = self.queues.shared_max_tokens.load(.monotonic);
            break :blk if (override > 0) override else self.config.max_tokens;
        };
        const is_oauth = std.mem.startsWith(u8, self.config.api_key, "sk-ant-oat01-");

        w.print("{{\"model\":\"{s}\",\"max_tokens\":{d},\"stream\":true", .{
            self.config.model,
            effective_max_tokens,
        }) catch return error.BodyTooLarge;
        // Thinking mode: adaptive only works on opus models.
        // For OAuth, we need the thinking field but must match the model's capability.
        const thinking_budget = self.queues.shared_thinking_budget.load(.monotonic);
        const model_supports_thinking = std.mem.indexOf(u8, self.config.model, "opus") != null;
        if (thinking_budget > 0 and model_supports_thinking) {
            w.print(",\"thinking\":{{\"type\":\"enabled\",\"budget_tokens\":{d}}}", .{thinking_budget}) catch return error.BodyTooLarge;
        } else if (is_oauth and model_supports_thinking) {
            w.writeAll(",\"thinking\":{\"type\":\"adaptive\"}") catch return error.BodyTooLarge;
        }
        // System prompt: OAuth tokens need billing header prefix for authentication
        if (is_oauth) {
            // System as array: billing header block + actual system prompt with cache_control
            // The billing header identifies this as a Claude Code compatible client.
            // Format: x-anthropic-billing-header: cc_version=<version>; cc_entrypoint=cli; cch=<hash>;
            // cc_version: Claude Code version (e.g. "2.1.81.df2")
            // cc_entrypoint: "cli" for command-line usage
            // cch: content cache hash — any hex value, used for prompt caching optimization
            w.writeAll(",\"system\":[{\"type\":\"text\",\"text\":\"x-anthropic-billing-header: cc_version=2.1.81.df2; cc_entrypoint=cli; cch=a1b2c;\"},{\"type\":\"text\",\"text\":") catch return error.BodyTooLarge;
            writeJSONString(w, self.systemPrompt()) catch return error.BodyTooLarge;
            w.writeAll(",\"cache_control\":{\"type\":\"ephemeral\",\"ttl\":\"1h\"}}]") catch return error.BodyTooLarge;
        } else {
            w.writeAll(",\"system\":") catch return error.BodyTooLarge;
            writeJSONString(w, self.systemPrompt()) catch return error.BodyTooLarge;
        }
        w.print(",\"messages\":{s},\"tools\":{s}}}", .{
            messages_json,
            self.toolsJson(),
        }) catch return error.BodyTooLarge;

        const body = body_buf[0..fbs.end];

        // Build URL (OAuth requires ?beta=true query parameter)
        var url_buf: [256]u8 = undefined;
        const url = if (is_oauth)
            std.fmt.bufPrint(&url_buf, "{s}/v1/messages?beta=true", .{self.config.base_url})
                catch return error.URLTooLong
        else
            std.fmt.bufPrint(&url_buf, "{s}/v1/messages", .{self.config.base_url})
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

    fn callLocal(self: *AgentThread) !APIResponse {
        // Lazy-spawn the ForkServer
        if (self.local_server == null) {
            if (self.config.local_model.len == 0)
                return error.NoLocalModel;
            const srv = self.allocator.create(inference.ForkServer) catch return error.OutOfMemory;
            srv.* = inference.ForkServer.spawn(self.config.local_model) catch {
                self.allocator.destroy(srv);
                _ = self.queues.output.push(.error_msg, "Failed to load local model");
                return error.InferenceError;
            };
            self.local_server = srv;
        }
        const srv = self.local_server.?;

        // Build a chat-style text prompt from conversation history
        var prompt_buf = try self.allocator.alloc(u8, MAX_CONTENT_LEN * 2);
        defer self.allocator.free(prompt_buf);
        var fbs: std.Io.Writer = .fixed(prompt_buf);
        const w = &fbs;

        // System prompt
        w.writeAll("System: ") catch {};
        w.writeAll(self.systemPrompt()) catch {};
        w.writeAll("\n\nAvailable tools: Bash, Read, Edit, Write, Glob, Grep\n") catch {};
        w.writeAll("To use a tool, write: <tool>ToolName</tool><input>{\"param\":\"value\"}</input>\n\n") catch {};

        // Conversation history
        for (0..self.history.count) |i| {
            const msg = &self.history.messages[i];
            const role_str = if (msg.role == .user) "User" else "Assistant";
            const content = msg.content[0..msg.content_len];
            w.print("{s}: {s}\n", .{ role_str, content }) catch {};
        }
        w.writeAll("Assistant:") catch {};
        const prompt = prompt_buf[0..fbs.end];

        // Call ForkServer
        const max_tokens: u16 = @intCast(@min(self.config.max_tokens, 4096));
        const response = srv.generate(prompt, max_tokens, 0.7, self.allocator) catch {
            _ = self.queues.output.push(.error_msg, "Local inference failed");
            return error.InferenceError;
        };

        // Stream the text to the user
        if (response.len > 0) {
            _ = self.queues.output.push(.text_delta, response);
        }

        // Parse for tool calls: <tool>Name</tool><input>JSON</input>
        var resp = APIResponse{
            .text = response,
            .text_alloc = response,
            .has_tool_call = false,
            .input_tokens = @intCast(prompt.len / 4), // rough estimate
            .output_tokens = @intCast(response.len / 4),
        };

        if (std.mem.indexOf(u8, response, "<tool>")) |tool_start| {
            const name_start = tool_start + 6;
            if (std.mem.indexOfPos(u8, response, name_start, "</tool>")) |name_end| {
                const tool_name = response[name_start..name_end];
                const tn = @min(tool_name.len, 64);
                @memcpy(resp.tool_name_buf[0..tn], tool_name[0..tn]);
                resp.tool_name_len = @intCast(tn);

                if (std.mem.indexOfPos(u8, response, name_end, "<input>")) |input_start| {
                    const json_start = input_start + 7;
                    if (std.mem.indexOfPos(u8, response, json_start, "</input>")) |input_end| {
                        const tool_input = response[json_start..input_end];
                        const ti = @min(tool_input.len, 4096);
                        @memcpy(resp.tool_cmd_buf[0..ti], tool_input[0..ti]);
                        resp.tool_cmd_len = @intCast(ti);
                        resp.has_tool_call = true;
                    }
                }

                // Generate a tool_use id
                const id = std.fmt.bufPrint(&resp.tool_id_buf, "local_{d}", .{
                    @as(u64, @bitCast(compat.milliTimestamp())),
                }) catch "local_0";
                resp.tool_id_len = @intCast(id.len);

                // Trim tool markup from displayed text
                resp.text = response[0..tool_start];
            }
        }

        return resp;
    }

    fn doStreamRequest(self: *AgentThread, url: []const u8, body: []const u8, provider: Provider) !APIResponse {
        // Output accumulator
        var text_buf = try self.allocator.alloc(u8, MAX_CONTENT_LEN);
        errdefer self.allocator.free(text_buf);
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

        // Acquire rate limit slot — blocks until a concurrent request slot is available.
        // This prevents all subagents from hammering the API simultaneously.
        if (!self.queues.bulletin.rate_limit.acquire()) {
            _ = self.queues.output.push(.error_msg, "Rate limit — waiting for cooldown");
            return error.RateLimited;
        }
        defer self.queues.bulletin.rate_limit.release();

        // Build curl command with headers
        var argv_buf: [50][]const u8 = undefined;
        var argc: usize = 0;

        argv_buf[argc] = "curl";
        argc += 1;
        argv_buf[argc] = "-sS"; // silent but show errors
        argc += 1;
        argv_buf[argc] = "-D";
        argc += 1;
        argv_buf[argc] = "/dev/stderr"; // dump response headers to stderr for rate limit parsing
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
                // Beta features: OAuth needs Claude Code identification flags
                argv_buf[argc] = if (is_oauth)
                    "anthropic-beta: claude-code-20250219,oauth-2025-04-20,interleaved-thinking-2025-05-14,prompt-caching-scope-2026-01-05"
                else
                    "anthropic-beta: prompt-caching-scope-2026-01-05";
                argc += 1;

                if (is_oauth) {
                    // OAuth requires these additional headers for Claude Code compatibility
                    argv_buf[argc] = "-H";
                    argc += 1;
                    argv_buf[argc] = "anthropic-dangerous-direct-browser-access: true";
                    argc += 1;
                    argv_buf[argc] = "-H";
                    argc += 1;
                    argv_buf[argc] = "x-app: cli";
                    argc += 1;
                }

                // SDK identification headers
                argv_buf[argc] = "-H";
                argc += 1;
                argv_buf[argc] = "User-Agent: claude-cli/2.1.81 (external, cli)";
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
            .local => unreachable, // local provider never calls doStreamRequest
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
        var child = std.process.spawn(compat.io(), .{
            .argv = argv_buf[0..argc],
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch return error.CurlFailed;
        errdefer child.kill(compat.io()); // no-op if already waited/killed

        // Write body to curl stdin
        if (child.stdin) |*stdin_pipe| {
            compat.writeAll(stdin_pipe.*, body) catch {};
            stdin_pipe.close(compat.io());
            child.stdin = null;
        }

        // Read streaming SSE output from curl stdout
        const stdout_file = child.stdout.?;
        var sse_buf: [65536]u8 = undefined;
        var sse_pos: usize = 0;

        outer: while (true) {
            if (self.queues.checkCancel()) {
                child.kill(compat.io()); // kills, waits, and cleans up all resources
                return error.Cancelled;
            }

            const n = stdout_file.readStreaming(compat.io(), &.{sse_buf[sse_pos..]}) catch break;
            if (n == 0) break;
            sse_pos += n;

            // Process complete lines
            var scan: usize = 0;
            while (scan < sse_pos) {
                const line_end = std.mem.indexOfScalarPos(u8, sse_buf[0..sse_pos], scan, '\n') orelse break;
                const line = std.mem.trimEnd(u8, sse_buf[scan..line_end], "\r");
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
                    .local => unreachable,
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

        // Read stderr: contains response headers (from -D /dev/stderr) + curl errors.
        // Parse rate limit headers, then report remaining content as errors.
        if (child.stderr) |*stderr_pipe| {
            var err_out: [4096]u8 = undefined;
            const err_n = stderr_pipe.readStreaming(compat.io(), &.{&err_out}) catch 0;
            stderr_pipe.close(compat.io());
            child.stderr = null;
            if (err_n > 0) {
                const stderr_data = err_out[0..err_n];
                // Parse rate limit utilization from response headers
                parseRateLimitHeaders(self.queues.bulletin, stderr_data);
                // Only report non-header content as errors (after the blank line)
                if (std.mem.indexOf(u8, stderr_data, "\r\n\r\n")) |end| {
                    const after = stderr_data[end + 4 ..];
                    if (after.len > 0 and !std.mem.startsWith(u8, after, "HTTP/"))
                        _ = self.queues.output.push(.error_msg, after);
                } else if (!std.mem.startsWith(u8, stderr_data, "HTTP/")) {
                    _ = self.queues.output.push(.error_msg, stderr_data);
                }
            }
        }
        // Close stdout pipe before wait in case child still has pending output
        if (child.stdout) |*s| { s.close(compat.io()); child.stdout = null; }

        _ = child.wait(compat.io()) catch {};

        // If no text was received but no tool call, check if response was an error
        if (text_len == 0 and !has_tool_call) {
            // The response might have been a non-streaming error JSON
            if (sse_pos > 0) {
                const remaining = sse_buf[0..sse_pos];
                if (std.mem.indexOf(u8, remaining, "\"error\"")) |_| {
                    _ = self.queues.output.push(.error_msg, remaining);
                    return error.HTTPError;
                }
            }
            // Empty response with no tool call — likely auth failure or network issue
            _ = self.queues.output.push(.error_msg, "API returned empty response — check authentication or network");
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
        // thinking delta — don't show content, but update status
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
    const trimmed = std.mem.trimStart(u8, after, " \t");
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
    const trimmed = std.mem.trimStart(u8, after, " \t");
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
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        switch (c) {
            '"' => { try w.writeAll("\\\""); i += 1; },
            '\\' => { try w.writeAll("\\\\"); i += 1; },
            '\n' => { try w.writeAll("\\n"); i += 1; },
            '\r' => { try w.writeAll("\\r"); i += 1; },
            '\t' => { try w.writeAll("\\t"); i += 1; },
            else => {
                if (c < 0x20) {
                    // Escape control characters as \u00XX
                    try w.writeAll("\\u00");
                    const hex = "0123456789abcdef";
                    try w.writeByte(hex[c >> 4]);
                    try w.writeByte(hex[c & 0x0f]);
                    i += 1;
                } else if (c < 0x80) {
                    // ASCII: always valid UTF-8
                    try w.writeByte(c);
                    i += 1;
                } else {
                    // Multi-byte UTF-8: validate sequence, replace invalid bytes
                    const seq_len: usize = if (c >= 0xF0 and i + 3 < s.len) 4
                        else if (c >= 0xE0 and i + 2 < s.len) 3
                        else if (c >= 0xC0 and i + 1 < s.len) 2
                        else 0;
                    if (seq_len > 0) {
                        // Check continuation bytes (must be 10xxxxxx)
                        var valid = true;
                        for (1..seq_len) |j| {
                            if (s[i + j] & 0xC0 != 0x80) { valid = false; break; }
                        }
                        if (valid) {
                            try w.writeAll(s[i..][0..seq_len]);
                            i += seq_len;
                        } else {
                            // Invalid sequence — skip byte
                            i += 1;
                        }
                    } else {
                        // Invalid lead byte or truncated — skip
                        i += 1;
                    }
                }
            },
        }
    }
    try w.writeByte('"');
}

// ============================================================
// Markdown terminal renderer (streaming-aware)
// ============================================================

// Code syntax helpers for keyword highlighting
fn isWordBoundary(text: []const u8, pos: usize) bool {
    if (pos == 0) return true;
    const prev = text[pos - 1];
    return prev == ' ' or prev == '\t' or prev == '\n' or prev == '(' or prev == '{' or
        prev == '[' or prev == ',' or prev == ';' or prev == ':' or prev == '!' or prev == '|';
}

/// Parse rate limit headers from curl's -D /dev/stderr output.
/// Updates the shared RateLimitState on the Bulletin.
fn parseRateLimitHeaders(bulletin: *q.Bulletin, data: []const u8) void {
    var util_5h: ?u8 = null;
    var util_7d: ?u8 = null;
    var exceeded = false;

    var pos: usize = 0;
    while (pos < data.len) {
        const end = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse data.len;
        const line = std.mem.trimEnd(u8, data[pos..end], "\r ");

        if (std.mem.startsWith(u8, line, "anthropic-ratelimit-unified-5h-utilization: ")) {
            util_5h = parseUtilPercent(line[44..]);
        } else if (std.mem.startsWith(u8, line, "anthropic-ratelimit-unified-7d-utilization: ")) {
            util_7d = parseUtilPercent(line[44..]);
        } else if (std.mem.startsWith(u8, line, "anthropic-ratelimit-unified-status: ")) {
            const status = std.mem.trim(u8, line[36..], " ");
            if (std.mem.eql(u8, status, "exceeded")) exceeded = true;
        }
        pos = end + 1;
    }

    if (util_5h != null or util_7d != null or exceeded) {
        bulletin.rate_limit.update(util_5h orelse 0, util_7d orelse 0, exceeded);
    }
}

fn parseUtilPercent(s: []const u8) u8 {
    const trimmed = std.mem.trim(u8, s, " \r\n");
    // Parse "0.12" -> 12
    const f = std.fmt.parseFloat(f32, trimmed) catch return 0;
    return @intFromFloat(@min(100.0, @max(0.0, f * 100.0)));
}

fn matchKeyword(text: []const u8, pos: usize) ?usize {
    // Common keywords across languages (sorted by frequency in code output)
    const keywords = [_][]const u8{
        "const", "var", "let", "fn", "func", "function", "def", "class", "struct",
        "if", "else", "for", "while", "return", "import", "from", "pub", "self",
        "true", "false", "null", "nil", "None", "undefined", "void",
        "try", "catch", "throw", "async", "await", "yield",
        "type", "interface", "enum", "match", "switch", "case", "break", "continue",
        "new", "this", "super", "extends", "implements",
        "export", "default", "module", "require", "package",
        "static", "final", "override", "abstract", "private", "public", "protected",
    };
    const remaining = text[pos..];
    for (keywords) |kw| {
        if (remaining.len >= kw.len and std.mem.eql(u8, remaining[0..kw.len], kw)) {
            // Must end at word boundary
            if (remaining.len == kw.len) return kw.len;
            const after = remaining[kw.len];
            if (after == ' ' or after == '\t' or after == '\n' or after == '(' or
                after == ')' or after == '{' or after == '}' or after == '[' or
                after == ']' or after == ',' or after == ';' or after == ':' or
                after == '.' or after == '<' or after == '>')
                return kw.len;
        }
    }
    return null;
}

/// Tracks state for rendering markdown with ANSI codes across streamed chunks
pub const MarkdownRenderer = struct {
    in_code_block: bool = false,
    in_bold: bool = false,
    in_inline_code: bool = false,
    in_header: bool = false,
    in_blockquote: bool = false,
    in_strikethrough: bool = false,
    in_italic: bool = false,
    in_code_string: bool = false, // inside string literal in code block
    code_string_char: u8 = '"', // which quote char opened the string
    line_start: bool = true,
    // Word wrap state
    col: u16 = 0, // current column position
    term_width: u16 = 80, // terminal width for word wrap
    // Pending characters from end of previous chunk (for cross-chunk ** and ``` detection)
    pending_stars: u8 = 0, // count of trailing * from previous chunk
    pending_backticks: u8 = 0, // count of trailing ` from previous chunk

    /// Reset column tracking (call when emitting newline from any code path)
    fn resetCol(self: *MarkdownRenderer) void {
        self.col = 0;
    }

    fn advanceCol(self: *MarkdownRenderer, n: u16) void {
        self.col +|= n;
    }

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
                    var skip = i;
                    while (skip < text.len and text[skip] != '\n') : (skip += 1) {}
                    const lang = std.mem.trim(u8, text[i..skip], " \t\r");
                    if (lang.len > 0) {
                        try writer.writeAll("\x1b[90m\xe2\x94\x8c "); // ┌
                        try writer.writeAll(lang);
                        try writer.writeAll("\x1b[0m\n");
                    } else {
                        try writer.writeAll("\x1b[90m\xe2\x94\x8c\x1b[0m\n"); // ┌
                    }
                    try writer.writeAll("\x1b[90m\xe2\x94\x82\x1b[36m ");
                    i = if (skip < text.len) skip + 1 else skip;
                    self.line_start = true;
                } else {
                    self.in_code_block = false;
                    try writer.writeAll("\x1b[0m\x1b[90m\xe2\x94\x94\x1b[0m\n"); // └
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
                        // Code block header with language label
                        const lang = std.mem.trim(u8, text[i + 3 .. skip], " \t\r");
                        if (lang.len > 0) {
                            try writer.writeAll("\x1b[90m\xe2\x94\x8c "); // ┌ top border
                            try writer.writeAll(lang);
                            try writer.writeAll("\x1b[0m\n");
                        } else {
                            try writer.writeAll("\x1b[90m\xe2\x94\x8c\x1b[0m\n"); // ┌
                        }
                        try writer.writeAll("\x1b[90m\xe2\x94\x82\x1b[36m "); // │ prefix + cyan
                        i = if (skip < text.len) skip + 1 else skip;
                        self.line_start = true;
                        continue;
                    } else {
                        self.in_code_block = false;
                        try writer.writeAll("\x1b[0m\x1b[90m\xe2\x94\x94\x1b[0m\n"); // └ bottom border
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

            // Inside code blocks — syntax coloring
            if (self.in_code_block) {
                if (self.line_start) {
                    // Diff coloring: +lines green, -lines red
                    if (c == '+' and i + 1 < text.len and text[i + 1] != '+') {
                        try writer.writeAll("\x1b[32m"); // green
                    } else if (c == '-' and i + 1 < text.len and text[i + 1] != '-') {
                        try writer.writeAll("\x1b[31m"); // red
                    } else if (c == '@' and i + 1 < text.len and text[i + 1] == '@') {
                        try writer.writeAll("\x1b[35m"); // magenta for @@ hunk headers
                    }
                }
                // String literals: "..." or '...' — yellow
                if ((c == '"' or c == '\'') and !self.in_code_string) {
                    self.in_code_string = true;
                    self.code_string_char = c;
                    try writer.writeAll("\x1b[33m"); // yellow
                    try writer.writeByte(c);
                } else if (self.in_code_string and c == self.code_string_char) {
                    try writer.writeByte(c);
                    try writer.writeAll("\x1b[36m"); // back to cyan
                    self.in_code_string = false;
                } else if (c == '\n') {
                    if (self.in_code_string) {
                        try writer.writeAll("\x1b[36m");
                        self.in_code_string = false;
                    }
                    try writer.writeAll("\x1b[0m\n\x1b[90m\xe2\x94\x82\x1b[36m "); // newline + │ prefix
                } else {
                    // Comments: // or # at line start
                    if (self.line_start and (c == '#' or (c == '/' and i + 1 < text.len and text[i + 1] == '/'))) {
                        try writer.writeAll("\x1b[90m"); // dim for comments
                    }
                    // Keywords at word boundary — magenta
                    else if (!self.in_code_string and isWordBoundary(text, i)) {
                        if (matchKeyword(text, i)) |kw_len| {
                            try writer.writeAll("\x1b[35m"); // magenta
                            try writer.writeAll(text[i..][0..kw_len]);
                            try writer.writeAll("\x1b[36m"); // back to cyan
                            i += kw_len;
                            self.line_start = false;
                            continue;
                        } else {
                            // Number literals at word boundary — yellow
                            if (c >= '0' and c <= '9') {
                                try writer.writeAll("\x1b[33m"); // yellow
                                while (i < text.len and ((text[i] >= '0' and text[i] <= '9') or text[i] == '.' or text[i] == 'x' or text[i] == 'b' or text[i] == '_' or (text[i] >= 'a' and text[i] <= 'f') or (text[i] >= 'A' and text[i] <= 'F'))) {
                                    try writer.writeByte(text[i]);
                                    i += 1;
                                }
                                try writer.writeAll("\x1b[36m"); // back to cyan
                                self.line_start = false;
                                continue;
                            }
                            try writer.writeByte(c);
                        }
                    } else {
                        try writer.writeByte(c);
                    }
                }
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
                    try writer.writeAll("\x1b[2;90m"); // dim + gray
                    var hk: u16 = 0;
                    while (hk < self.term_width) : (hk += 1) try writer.writeAll("\xe2\x94\x80");
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

            // List items at line start (with optional indentation for nesting)
            if (self.line_start and !self.in_code_block) {
                // Check for indented list: spaces then - or *
                var li = i;
                var indent: usize = 0;
                while (li < text.len and text[li] == ' ') : (li += 1) { indent += 1; }
                if (li < text.len and (text[li] == '-' or text[li] == '*') and li + 1 < text.len and text[li + 1] == ' ') {
                    // Render indent then bullet
                    var sp: usize = 0;
                    while (sp < indent) : (sp += 1) try writer.writeByte(' ');
                    try writer.writeAll("\x1b[33m\xe2\x80\xa2\x1b[39m "); // yellow bullet
                    i = li + 2;
                    self.line_start = false;
                    continue;
                }
            }
            // (non-indented bullets handled by the indented check above)

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

            // Image links: ![alt](url) — show as dim placeholder
            if (c == '!' and i + 1 < text.len and text[i + 1] == '[' and !self.in_code_block) {
                var j = i + 2;
                while (j < text.len and text[j] != ']' and text[j] != '\n') : (j += 1) {}
                if (j < text.len and text[j] == ']' and j + 1 < text.len and text[j + 1] == '(') {
                    var k = j + 2;
                    while (k < text.len and text[k] != ')' and text[k] != '\n') : (k += 1) {}
                    if (k < text.len and text[k] == ')') {
                        const alt = text[i + 2 .. j];
                        try writer.writeAll("\x1b[90m[image: ");
                        if (alt.len > 0) try writer.writeAll(alt) else try writer.writeAll("image");
                        try writer.writeAll("]\x1b[0m");
                        i = k + 1;
                        self.line_start = false;
                        continue;
                    }
                }
            }

            // Table rows: | col | col | — render with dim pipes and bold headers
            if (self.line_start and c == '|' and !self.in_code_block) {
                // Check if this looks like a table row (has at least one more |)
                if (std.mem.indexOfScalarPos(u8, text, i + 1, '|')) |_| {
                    // Check for separator row: |---|---|
                    var is_sep = true;
                    var si = i + 1;
                    while (si < text.len and text[si] != '\n') : (si += 1) {
                        if (text[si] != '-' and text[si] != '|' and text[si] != ' ' and text[si] != ':') {
                            is_sep = false;
                            break;
                        }
                    }
                    if (is_sep) {
                        // Replace separator with box-drawing line
                        try writer.writeAll("\x1b[90m");
                        var sep_j = i;
                        while (sep_j < si) : (sep_j += 1) {
                            if (text[sep_j] == '|') {
                                try writer.writeAll("\xe2\x94\xbc"); // ┼
                            } else {
                                try writer.writeAll("\xe2\x94\x80"); // ─
                            }
                        }
                        try writer.writeAll("\x1b[0m\n");
                        i = si;
                        if (i < text.len and text[i] == '\n') i += 1;
                        self.line_start = true;
                        continue;
                    }
                    // Check if this is a header row (next non-empty line is separator)
                    var is_header = false;
                    var ni = si;
                    if (ni < text.len and text[ni] == '\n') ni += 1;
                    if (ni < text.len and text[ni] == '|') {
                        // Check if next line is separator
                        var nj = ni + 1;
                        var next_is_sep = true;
                        while (nj < text.len and text[nj] != '\n') : (nj += 1) {
                            if (text[nj] != '-' and text[nj] != '|' and text[nj] != ' ' and text[nj] != ':') {
                                next_is_sep = false;
                                break;
                            }
                        }
                        is_header = next_is_sep;
                    }
                    // Render table row: dim pipes, content normal (bold if header)
                    if (is_header) try writer.writeAll("\x1b[1m"); // bold headers
                    while (i < text.len and text[i] != '\n') {
                        if (text[i] == '|') {
                            if (is_header) try writer.writeAll("\x1b[22m"); // unbold for pipe
                            try writer.writeAll("\x1b[90m\xe2\x94\x82\x1b[0m"); // dim │
                            if (is_header) try writer.writeAll("\x1b[1m"); // re-bold
                        } else {
                            try writer.writeByte(text[i]);
                        }
                        i += 1;
                    }
                    if (is_header) try writer.writeAll("\x1b[22m"); // end bold
                    if (i < text.len and text[i] == '\n') {
                        try writer.writeByte('\n');
                        i += 1;
                    }
                    self.line_start = true;
                    continue;
                }
            }

            // Links: [text](url) — clickable OSC 8 hyperlink in cyan
            if (c == '[' and !self.in_code_block and !self.in_inline_code) {
                var j = i + 1;
                while (j < text.len and text[j] != ']' and text[j] != '\n') : (j += 1) {}
                if (j < text.len and text[j] == ']' and j + 1 < text.len and text[j + 1] == '(') {
                    var k = j + 2;
                    while (k < text.len and text[k] != ')' and text[k] != '\n') : (k += 1) {}
                    if (k < text.len and text[k] == ')') {
                        const link_text = text[i + 1 .. j];
                        const link_url = text[j + 2 .. k];
                        if (link_text.len > 0) {
                            // OSC 8 hyperlink: \e]8;;URL\e\\TEXT\e]8;;\e\\
                            if (link_url.len > 0) {
                                try writer.writeAll("\x1b]8;;");
                                try writer.writeAll(link_url);
                                try writer.writeAll("\x1b\\");
                            }
                            try writer.writeAll("\x1b[4;36m"); // underline + cyan
                            try writer.writeAll(link_text);
                            try writer.writeAll("\x1b[24;39m"); // end underline + reset fg
                            if (link_url.len > 0) {
                                try writer.writeAll("\x1b]8;;\x1b\\"); // close OSC 8
                            }
                            if (self.in_bold) try writer.writeAll("\x1b[1m");
                            i = k + 1;
                            self.line_start = false;
                            continue;
                        }
                    }
                }
            }

            // HTML tags: strip or convert to ANSI
            if (c == '<' and !self.in_code_block and !self.in_inline_code) {
                var ti = i + 1;
                const closing = ti < text.len and text[ti] == '/';
                if (closing) ti += 1;
                const tag_start = ti;
                while (ti < text.len and text[ti] != '>' and text[ti] != ' ' and text[ti] != '\n') : (ti += 1) {}
                if (ti < text.len and (text[ti] == '>' or text[ti] == ' ')) {
                    const tag = text[tag_start..ti];
                    // Skip to closing >
                    while (ti < text.len and text[ti] != '>') : (ti += 1) {}
                    if (ti < text.len) ti += 1;
                    // Handle specific tags
                    if (std.mem.eql(u8, tag, "br")) {
                        try writer.writeByte('\n');
                        self.line_start = true;
                        self.resetCol();
                    } else if (std.mem.eql(u8, tag, "b") or std.mem.eql(u8, tag, "strong")) {
                        if (!closing) try writer.writeAll("\x1b[1m") else try writer.writeAll("\x1b[22m");
                    } else if (std.mem.eql(u8, tag, "i") or std.mem.eql(u8, tag, "em")) {
                        if (!closing) try writer.writeAll("\x1b[3m") else try writer.writeAll("\x1b[23m");
                    } else if (std.mem.eql(u8, tag, "code")) {
                        if (!closing) try writer.writeAll("\x1b[36m") else try writer.writeAll("\x1b[39m");
                    }
                    // details/summary/div/p/span — just strip the tag
                    i = ti;
                    continue;
                }
            }

            if (c == '\n' and self.in_header) {
                self.in_header = false;
                try writer.writeAll("\x1b[0m\n");
            } else if (c == '\n' and self.in_blockquote) {
                self.in_blockquote = false;
                try writer.writeAll("\x1b[0m\n"); // full reset (italic + dim + color)
            } else {
                // Word wrap for prose (not inside code blocks)
                if (!self.in_code_block and c == ' ' and self.col >= self.term_width - 5) {
                    try writer.writeByte('\n');
                    self.col = 0;
                    self.line_start = true;
                } else {
                    try writer.writeByte(c);
                    if (c == '\n') {
                        self.col = 0;
                    } else {
                        self.col += 1;
                    }
                }
            }
            // Track line position — newline resets, other chars clear line_start
            // (handlers that `continue` manage line_start themselves)
            if (c == '\n') {
                self.line_start = true;
                self.resetCol();
            } else {
                self.line_start = false;
            }
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
        // Full ANSI reset if any formatting was active — prevents terminal state leaks
        if (self.in_bold or self.in_italic or self.in_strikethrough or
            self.in_header or self.in_blockquote or self.in_code_block or self.in_inline_code)
        {
            try writer.writeAll("\x1b[0m");
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
    bulletin: *q.Bulletin,
    pub fn getTotalInputTokens(self: *const AgentContext) u32 {
        return self.queues.shared_input_tokens.load(.monotonic);
    }

    pub fn setMaxTokens(self: *AgentContext, tokens: u32) void {
        self.queues.shared_max_tokens.store(tokens, .monotonic);
    }

    pub fn init(allocator: std.mem.Allocator) AgentContext {
        const bulletin = allocator.create(q.Bulletin) catch @panic("OOM: bulletin");
        bulletin.* = .{};
        var ctx = AgentContext{ .allocator = allocator, .bulletin = bulletin };
        ctx.queues.bulletin = bulletin;
        return ctx;
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
            // pushWait: a plain push drops the cancel when the queue is full,
            // leaving join() hanging forever. pushWait is bounded (~5s).
            self.queues.request.pushWait(.cancel, "");
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
                else => {},
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
    bulletin: *q.Bulletin,
) void {
    defer allocator.free(prompt_owned);

    // Create a minimal agent — no session log, no plugin tools, auto-allow all
    var dummy_queues: AgentQueues = .{};
    dummy_queues.bulletin = bulletin;
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
    // Set agent identity from subagent ID
    const sa_id = sa.id();
    @memcpy(agent.agent_id[0..sa_id.len], sa_id);
    agent.agent_id_len = @intCast(sa_id.len);
    // Start reading bulletin from current position
    agent.bulletin_cursor = bulletin.position();
    // Announce arrival on the bulletin
    agent.broadcast(.status_change, "spawned");

    // Set cwd — use worktree path if this is an isolated worker
    if (sa.has_worktree) {
        const wt = sa.worktreePath();
        @memcpy(agent.cwd[0..wt.len], wt);
        agent.cwd_len = @intCast(wt.len);
    } else {
        const cwd = compat.posix.getcwd(&agent.cwd) catch "/";
        agent.cwd_len = @intCast(cwd.len);
    }
    agent.peer_scan_cursor = agent.bulletin_cursor;

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
            \\{"name":"Grep","description":"Search file contents with regex.","input_schema":{"type":"object","properties":{"pattern":{"type":"string","description":"Regex pattern"},"path":{"type":"string","description":"File or directory"},"glob":{"type":"string","description":"Filter files by glob"}},"required":["pattern"]}},
            \\{"name":"Post","description":"Post to the shared bulletin board. All agents see all posts. Use to share discoveries, flag problems, or vote (+1/-1) on other agents' posts. Types: discovery (share findings), escalate (urgent), vote (+1 or -1).","input_schema":{"type":"object","properties":{"type":{"type":"string","enum":["discovery","escalate","vote"],"description":"Post type"},"message":{"type":"string","description":"Post content. For votes, prefix with +1 or -1"}},"required":["type","message"]}}
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
        var assist_fbs: std.Io.Writer = .fixed(&assist_buf);
        const aw = &assist_fbs;
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
        agent.history.addKind(.assistant, .tool_use_response, assist_buf[0..assist_fbs.end]) catch {};
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
        var result_fbs: std.Io.Writer = .fixed(result_json_buf);
        const rw = &result_fbs;
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
        agent.history.addKind(.user, .tool_result, result_json_buf[0..result_fbs.end]) catch {};
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

    const status: SubAgentStatus = if (final_text.len > 0) .done else .failed;
    sa.setResult(if (final_text.len > 0) final_text else "No response from subagent", status);
    // Announce completion on the bulletin
    agent.broadcast(if (status == .done) .discovery else .escalate, if (final_text.len > 0) final_text[0..@min(final_text.len, 256)] else "failed");
}

fn agentThreadFn(allocator: std.mem.Allocator, queues: *AgentQueues, model_override: ?[]const u8) void {
    var ac = log_mod.AgentConfig.load(allocator);
    var config = Config.fromAgentConfig(ac);
    if (model_override) |m| config.model = m;
    const rc = Config.buildRouterConfig(ac);

    // Learn from past corrections before loading patterns
    router_mod.learnPatterns();

    var agent = AgentThread.init(allocator, queues, config, rc);
    // Config slices now point into ac's tracked buffers — must keep ac alive
    // until agent is done, then free both
    defer {
        agent.deinit();
        ac.deinit();
    }
    agent.run();
}
