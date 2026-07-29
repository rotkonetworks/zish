const Shell = @This();

const std = @import("std");
const compat = @import("compat.zig");
const posix = compat.posix;
const types = @import("types.zig");
const lexer = @import("lexer.zig");

// Re-exported escaped-literal sentinels (defined in the lexer) for use by eval.
pub const LIT_DOLLAR = lexer.LIT_DOLLAR;
pub const LIT_BACKTICK = lexer.LIT_BACKTICK;
const parser = @import("parser.zig");
const ast = @import("ast.zig");
const glob = @import("glob.zig");
const hist = @import("history.zig");
const tty = @import("tty.zig");
const input_mod = @import("input.zig");
const completion_mod = @import("completion.zig");
const eval = @import("eval.zig");
const git = @import("git.zig");
const jobs = @import("jobs.zig");
const editor = @import("editor.zig");
const vim = @import("vim.zig");
const agent_mod = @import("agent.zig");
const agent_log = @import("agent_log.zig");
const audio = @import("audio.zig");

// Re-export from input module (for compatibility)
const VimMode = input_mod.VimMode;
const WordBoundary = input_mod.WordBoundary;
const HistoryDirection = input_mod.HistoryDirection;
const SearchDirection = input_mod.SearchDirection;
const MoveCursorAction = input_mod.MoveCursorAction;
const DeleteAction = input_mod.DeleteAction;
const YankAction = input_mod.YankAction;
const PasteAction = input_mod.PasteAction;
const InsertAtPosition = input_mod.InsertAtPosition;
const VimModeAction = input_mod.VimModeAction;
const Action = input_mod.Action;
const CycleDirection = input_mod.CycleDirection;

// Control key constants
const CTRL_C = input_mod.CTRL_C;
const CTRL_G = input_mod.CTRL_G;
const CTRL_L = input_mod.CTRL_L;
const CTRL_D = input_mod.CTRL_D;
const CTRL_Z = input_mod.CTRL_Z;

// global shell instance for signal handler - must use atomic access
// to avoid data races between main thread and signal handlers
var global_shell: @TypeOf(@as(?*Shell, null)) = null;

// Trap table for signal handlers
// Signals 1-31 are real signals, 0 is EXIT pseudo-signal
pub const TrapTable = struct {
    // trap commands indexed by signal number (0=EXIT, 1=HUP, 2=INT, etc.)
    // null = default behavior, empty string = ignore, other = command to run
    handlers: [32]?[]const u8 = [_]?[]const u8{null} ** 32,
    allocator: ?std.mem.Allocator = null,

    pub const Signal = enum(u8) {
        EXIT = 0,
        HUP = 1,
        INT = 2,
        QUIT = 3,
        ILL = 4,
        TRAP = 5,
        ABRT = 6,
        BUS = 7,
        FPE = 8,
        KILL = 9,
        USR1 = 10,
        SEGV = 11,
        USR2 = 12,
        PIPE = 13,
        ALRM = 14,
        TERM = 15,
        CHLD = 17,
        CONT = 18,
        STOP = 19,
        TSTP = 20,
        TTIN = 21,
        TTOU = 22,
        URG = 23,
        XCPU = 24,
        XFSZ = 25,
        VTALRM = 26,
        PROF = 27,
        WINCH = 28,
        IO = 29,
        PWR = 30,
        SYS = 31,

        pub fn fromName(sig_str: []const u8) ?Signal {
            var buf: [16]u8 = undefined;
            const upper = blk: {
                if (sig_str.len > 16) break :blk sig_str;
                for (sig_str, 0..) |c, i| {
                    buf[i] = std.ascii.toUpper(c);
                }
                break :blk buf[0..sig_str.len];
            };
            // strip SIG prefix if present
            const sig_name = if (std.mem.startsWith(u8, upper, "SIG")) upper[3..] else upper;

            inline for (std.meta.fields(Signal)) |field| {
                if (std.mem.eql(u8, sig_name, field.name)) {
                    return @enumFromInt(field.value);
                }
            }
            // try parsing as number
            const num = std.fmt.parseInt(u8, sig_str, 10) catch return null;
            if (num < 32) return @enumFromInt(num);
            return null;
        }

        pub fn name(self: Signal) []const u8 {
            return @tagName(self);
        }
    };

    pub fn set(self: *TrapTable, allocator: std.mem.Allocator, sig: Signal, cmd: ?[]const u8) !void {
        self.allocator = allocator;
        const idx = @intFromEnum(sig);

        // free old handler
        if (self.handlers[idx]) |old| {
            allocator.free(old);
        }

        // set new handler
        if (cmd) |c| {
            self.handlers[idx] = try allocator.dupe(u8, c);
        } else {
            self.handlers[idx] = null;
        }
    }

    pub fn get(self: *const TrapTable, sig: Signal) ?[]const u8 {
        return self.handlers[@intFromEnum(sig)];
    }

    pub fn deinit(self: *TrapTable) void {
        if (self.allocator) |allocator| {
            for (&self.handlers) |*h| {
                if (h.*) |cmd| {
                    allocator.free(cmd);
                    h.* = null;
                }
            }
        }
    }
};

// ansi color codes for zsh-like colorful prompt
const Colors = struct {
    const default_color = tty.Color.reset;
    const path = tty.Color.cyan;
    const userhost = tty.Color.green;
    const normal_mode = tty.Color.red;
    const insert_mode = tty.Color.yellow;
};

// One shadowed variable saved by `local` (see local_scopes field below).
pub const SavedLocal = struct { name: []u8, existed: bool, value: []u8 };

pub const GhostState = struct {
    enabled: bool = true,
    buf: [512]u8 = undefined,
    len: usize = 0,
    from_ctm: bool = false,
    candidates: [8][512]u8 = undefined,
    candidate_lens: [8]usize = [_]usize{0} ** 8,
    candidate_count: u8 = 0,
    candidate_idx: u8 = 0,
    infer_input: [512]u8 = undefined,
    infer_input_len: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    infer_prev_cmd: [512]u8 = undefined,
    infer_prev_len: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    infer_seq: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    infer_result: [512]u8 = undefined,
    infer_result_len: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    infer_result_seq: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    last_result_seq: u32 = 0,
    infer_thread: ?std.Thread = null,
    infer_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

allocator: std.mem.Allocator,
running: bool,
history: ?*hist.History,
vim_mode: VimMode,
history_index: i32,
history_search_prefix_len: usize,
original_termios: ?posix.termios = null,
aliases: std.StringHashMap([]const u8),
variables: std.StringHashMap([]const u8),
arrays: std.StringHashMap(std.ArrayListUnmanaged([]const u8)), // array variables
functions: std.StringHashMap(*const ast.AstNode), // name -> body AST
traps: TrapTable = .{}, // signal handlers
last_exit_code: u8 = 0,
last_bg_pid: compat.posix.pid_t = 0, // PID of the most recent background command ($!)

// local-variable scoping. Each active function call pushes a frame; `local x`
// records x's prior state into the top frame, and callFunction restores every
// recorded var when the function returns. Managed by eval.pushLocalScope /
// popLocalScope / declareLocal.
local_scopes: std.ArrayList(std.ArrayList(SavedLocal)) = .empty,

// shell options (set -e, -u, -x, -o pipefail)
opt_errexit: bool = false, // -e: exit on error
opt_nounset: bool = false, // -u: error on undefined variable
opt_xtrace: bool = false, // -x: print commands before execution
opt_pipefail: bool = false, // pipefail: pipeline fails if any command fails
// when true, external commands exec directly instead of fork+exec (for pipeline children)
in_pipeline: bool = false,
// loop control: number of enclosing loops to break/continue out of. 0 = none.
// set by the break/continue builtins, consumed by loop evaluators.
loop_break: u32 = 0,
loop_continue: u32 = 0,
// names of variables currently used as for-loop scratch (value points at a
// stack buffer in an active evaluateFor frame, must not be freed)
for_scratch_names: [16][]const u8 = [_][]const u8{""} ** 16,
for_scratch_depth: usize = 0,
// process substitution tracking
proc_subst_pids: [16]posix.pid_t = [_]posix.pid_t{0} ** 16,
proc_subst_fds: [16]posix.fd_t = [_]posix.fd_t{-1} ** 16,
proc_subst_count: usize = 0,
// job control
job_table: jobs.JobTable,

// new modular editor
edit_buf: editor.EditBuffer = .{},
term_view: editor.TermView,
vi: vim.Vim = .{},
keybindings: input_mod.KeyBindings = .{},

// vim clipboard for yank/paste operations (legacy, now in vi.yank_buf)
clipboard: []u8,
clipboard_len: usize = 0,
// search state
search_mode: bool = false,
search_buffer: []u8,
search_len: usize = 0,
// paste mode (bracketed paste)
paste_mode: bool = false,
// completion state (grouped sub-struct — see completion_mod for logic)
completion: completion_mod.CompletionState,
ctrl_d_pending: bool = false, // double ctrl+d to exit

// completion caches (grouped sub-struct)
cache: completion_mod.CacheState = .{},

// ghost text autosuggestion state (grouped sub-struct)
ghost: GhostState = .{},

// agent continue: loaded conversation context to send as first message
continue_context: ?[]const u8 = null,

// git info display (set via .zishrc: set git_prompt on)
show_git_info: bool = false,

// track displayed command lines for proper clearing
displayed_cmd_lines: usize = 1,
// track terminal cursor row (within our displayed content)
// this may differ from logical cursor during paste
terminal_cursor_row: usize = 0,

// terminal resize handling
terminal_resized: bool = false,
terminal_width: usize = 80,
terminal_height: usize = 24,
last_resize_time: i64 = 0,

stdout_writer: std.Io.File.Writer,
log_file: ?std.Io.File = null,

// PATH lookup cache - maps command name -> full path
path_cache: std.StringHashMap([]const u8),

// embedded LLM agent
agent: agent_mod.AgentContext,
agent_output_active: bool = false,
agent_md: agent_mod.MarkdownRenderer = .{},
bulletin_cursor: usize = 0,

// Voice mode state
voice_active: bool = false,
voice_capture: ?audio.Capture = null,
voice_playback: ?audio.Playback = null,

pub fn init(allocator: std.mem.Allocator) !*Shell {
    return initWithOptions(allocator, true);
}

pub fn initNonInteractive(allocator: std.mem.Allocator) !*Shell {
    return initWithOptions(allocator, false);
}

fn initWithOptions(allocator: std.mem.Allocator, load_config: bool) !*Shell {
    const shell = try allocator.create(Shell);

    // only load history for interactive mode
    const history = if (load_config)
        hist.History.init(allocator, null) catch null
    else
        null;

    const clipboard_buffer = try allocator.alloc(u8, types.MAX_COMMAND_LENGTH);
    const search_buffer = try allocator.alloc(u8, 256); // search queries are usually short

    const writer_buffer = try allocator.alloc(u8, types.MAX_COMMAND_LENGTH + types.MAX_PROMPT_LENGTH);

    shell.* = .{
        .allocator = allocator,
        .running = false,
        .history = history,
        .vim_mode = .insert,
        .history_index = -1,
        .history_search_prefix_len = 0,
        .original_termios = null,
        .aliases = std.StringHashMap([]const u8).init(allocator),
        .variables = std.StringHashMap([]const u8).init(allocator),
        .arrays = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator),
        .functions = std.StringHashMap(*const ast.AstNode).init(allocator),
        // new modular editor
        .edit_buf = .{},
        .term_view = editor.TermView.init(posix.STDERR_FILENO),
        .vi = .{},
        .clipboard = clipboard_buffer,
        .clipboard_len = 0,
        .search_mode = false,
        .search_buffer = search_buffer,
        .search_len = 0,
        .completion = completion_mod.CompletionState.init(),
        .stdout_writer = std.Io.File.stdout().writer(compat.io(), writer_buffer),
        .path_cache = std.StringHashMap([]const u8).init(allocator),
        .job_table = jobs.JobTable.init(allocator),
        .agent = agent_mod.AgentContext.init(allocator),
    };

    // don't enable raw mode here - will be enabled by run() for interactive mode
    // this prevents issues with child processes in non-interactive mode

    // load config only for interactive mode
    if (load_config) {
        shell.loadConfig() catch {}; // don't fail if no config file
        shell.loadKeybindings();
    }

    return shell;
}

pub fn deinit(self: *Shell) void {
    // restore terminal mode before cleanup
    self.disableRawMode();

    // restore default cursor style
    self.setCursorStyle(.default) catch {};

    // cleanup aliases
    var it = self.aliases.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.*);
    }
    self.aliases.deinit();

    // cleanup variables
    var var_it = self.variables.iterator();
    while (var_it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.*);
    }
    self.variables.deinit();

    // cleanup arrays
    var arr_it = self.arrays.iterator();
    while (arr_it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        for (entry.value_ptr.items) |elem| {
            self.allocator.free(elem);
        }
        entry.value_ptr.deinit(self.allocator);
    }
    self.arrays.deinit();

    // cleanup functions
    var fn_it = self.functions.iterator();
    while (fn_it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        entry.value_ptr.*.destroy(self.allocator); // free AST
    }
    self.functions.deinit();

    if (self.history) |h| h.deinit();

    // cleanup completion state
    self.completion.deinit(self.allocator);

    // cleanup path cache
    var path_it = self.path_cache.iterator();
    while (path_it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.*);
    }
    self.path_cache.deinit();

    // cleanup job table
    self.job_table.deinit();

    // cleanup traps
    self.traps.deinit();

    // Null out global pointer BEFORE freeing — prevents signal handler
    // from dereferencing freed memory if SIGWINCH arrives during shutdown.
    @atomicStore(?*Shell, &global_shell, null, .release);

    // stop ghost inference thread
    completion_mod.stopGhostInference(self);

    // stop agent thread so it can clean up
    self.agent.stop();

    if (self.continue_context) |ctx| self.allocator.free(ctx);
    self.allocator.free(self.clipboard);
    self.allocator.free(self.search_buffer);
    self.allocator.free(self.stdout().buffer);
    self.allocator.destroy(self);
}
/// Get command slice (prefers edit_buf)
fn getCommand(self: *Shell) []const u8 {
    return self.edit_buf.slice();
}

fn clearCommand(self: *Shell) void {
    self.edit_buf.clear();
}

/// Render using TermView
pub fn renderLine(self: *Shell) !void {
    // update ghost text suggestion before rendering
    completion_mod.updateGhostText(self);
    self.term_view.ghost_text = self.ghost.buf[0..self.ghost.len];
    var prompt_buf: [256]u8 = undefined;
    const prompt = self.buildPrompt(&prompt_buf);
    try self.term_view.render(&self.edit_buf, prompt.slice, prompt.visible_len);
}

/// Show live search results as user types
fn showSearchMatch(self: *Shell) !void {
    const writer = self.stdout();
    const search_term = self.search_buffer[0..self.search_len];

    // clear line and everything below (search result may wrap)
    try writer.writeAll("\r\x1b[J(reverse-i-search): ");
    try writer.writeAll(search_term);

    // find and show best match
    if (self.search_len > 0 and self.history != null) {
        const matches = self.history.?.fuzzySearch(search_term, self.allocator) catch return;
        defer self.allocator.free(matches);

        if (matches.len > 0) {
            const entry_idx = matches[0].entry_index;
            const entry = self.history.?.entries.items[entry_idx];
            const cmd = self.history.?.getCommand(entry);

            // show match after separator
            try writer.writeAll(" → ");
            try writer.writeAll(cmd);

            // store match in edit buffer for when user presses enter
            self.edit_buf.set(cmd);
        }
    }
    try writer.flush(); // flush erase before any stderr redraw
}

const PromptInfo = struct {
    slice: []const u8,
    visible_len: u16,
};

fn buildPrompt(self: *Shell, buf: *[256]u8) PromptInfo {
    // get mode indicator
    const mode_str = self.vi.modeIndicatorColored();

    // get user
    const user = compat.getEnvVarOwned(self.allocator, "USER") catch "?";
    defer if (!std.mem.eql(u8, user, "?")) self.allocator.free(user);

    // get hostname
    var hostname_buf: [posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = posix.gethostname(&hostname_buf) catch "localhost";

    // get cwd
    var cwd_buf: [256]u8 = undefined;
    const cwd = posix.getcwd(&cwd_buf) catch "?";

    // simplify home path
    const home = compat.getEnvVarOwned(self.allocator, "HOME") catch null;
    defer if (home) |h| self.allocator.free(h);

    var path_buf: [256]u8 = undefined;
    const display_path = if (home) |h| blk: {
        if (std.mem.startsWith(u8, cwd, h)) {
            if (std.mem.eql(u8, cwd, h)) {
                break :blk "~";
            } else {
                break :blk std.fmt.bufPrint(&path_buf, "~{s}", .{cwd[h.len..]}) catch cwd;
            }
        }
        break :blk cwd;
    } else cwd;

    // color codes
    const green = "\x1b[32m"; // user@host
    const cyan = "\x1b[36m"; // path
    const red = "\x1b[31m"; // error
    const yellow = "\x1b[33m"; // git branch
    const reset = "\x1b[0m";

    // get git branch (fast — reads .git/HEAD directly)
    var branch_buf: [64]u8 = undefined;
    var branch_visible: u16 = 0;
    const branch_str = blk: {
        const head = std.Io.Dir.cwd().openFile(compat.io(), ".git/HEAD", .{}) catch break :blk "";
        defer head.close(compat.io());
        var hbuf: [256]u8 = undefined;
        const n = compat.readAll(head, &hbuf) catch break :blk "";
        const content = std.mem.trim(u8, hbuf[0..n], " \t\r\n");
        if (std.mem.startsWith(u8, content, "ref: refs/heads/")) {
            const name = content[16..];
            const blen = @min(name.len, 30); // truncate long branches
            branch_visible = @intCast(blen + 3); // " (branch)"
            break :blk std.fmt.bufPrint(&branch_buf, " {s}({s}){s}", .{ yellow, name[0..blen], reset }) catch "";
        }
        break :blk "";
    };

    // exit code indicator
    var exit_buf: [32]u8 = undefined;
    var exit_visible: u16 = 0;
    const exit_str = if (self.last_exit_code != 0) blk: {
        const s = std.fmt.bufPrint(&exit_buf, " {s}[{d}]{s}", .{ red, self.last_exit_code, reset }) catch "";
        // visible: " [N]" = 3 + digits
        var digits: u16 = 1;
        var v = self.last_exit_code;
        while (v >= 10) : (v /= 10) digits += 1;
        exit_visible = digits + 3;
        break :blk s;
    } else "";

    // format: [M] user@host path (branch) [exit] $
    const len = std.fmt.bufPrint(buf, "{s} {s}{s}@{s}{s} {s}{s}{s}{s}{s} $ ", .{
        mode_str,
        green, user, hostname, reset,
        cyan, display_path, reset,
        branch_str,
        exit_str,
    }) catch return .{ .slice = "$ ", .visible_len = 2 };

    // Calculate visible length by walking the formatted string and stripping ANSI escapes.
    // This is always correct regardless of how many color codes or special chars are in the prompt.
    const formatted = buf[0..len.len];
    var visible: u16 = 0;
    var in_esc = false;
    for (formatted) |c| {
        if (c == 0x1b) {
            in_esc = true;
        } else if (in_esc) {
            if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z')) in_esc = false;
        } else {
            visible += 1;
        }
    }

    return .{
        .slice = formatted,
        .visible_len = visible,
    };
}

/// Look up a command in PATH, using cache when possible
pub fn lookupCommand(self: *Shell, cmd_name: []const u8) ?[]const u8 {
    // don't cache absolute/relative paths
    if (cmd_name.len > 0 and (cmd_name[0] == '/' or cmd_name[0] == '.')) {
        return null;
    }

    // check cache first
    if (self.path_cache.get(cmd_name)) |cached_path| {
        // verify file still exists and is executable
        const file = if (std.fs.path.isAbsolute(cached_path))
            std.Io.Dir.openFileAbsolute(compat.io(), cached_path, .{})
        else
            std.Io.Dir.cwd().openFile(compat.io(), cached_path, .{});
        if (file) |f| {
            f.close(compat.io());
            return cached_path;
        } else |_| {
            // file no longer exists, remove from cache
            if (self.path_cache.fetchRemove(cmd_name)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value);
            }
            return self.searchPath(cmd_name);
        }
    }

    return self.searchPath(cmd_name);
}

fn searchPath(self: *Shell, cmd_name: []const u8) ?[]const u8 {
    // Check shell variables first (for exported PATH), then fall back to system env
    const path_env = self.variables.get("PATH") orelse (posix.getenv("PATH") orelse return null);

    var path_iter = std.mem.splitScalar(u8, path_env, ':');
    while (path_iter.next()) |dir| {
        if (dir.len == 0) continue;

        // build full path: dir + "/" + cmd_name
        const full_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, cmd_name }) catch continue;

        // check if file exists and is executable
        const file = (if (std.fs.path.isAbsolute(full_path))
            std.Io.Dir.openFileAbsolute(compat.io(), full_path, .{})
        else
            std.Io.Dir.cwd().openFile(compat.io(), full_path, .{})) catch {
            self.allocator.free(full_path);
            continue;
        };
        const stat = file.stat(compat.io()) catch {
            file.close(compat.io());
            self.allocator.free(full_path);
            continue;
        };
        file.close(compat.io());
        // check execute bit
        if ((stat.permissions.toMode() & 0o111) == 0) {
            self.allocator.free(full_path);
            continue;
        }

        // found it - cache and return
        const key_copy = self.allocator.dupe(u8, cmd_name) catch {
            self.allocator.free(full_path);
            return null;
        };

        self.path_cache.put(key_copy, full_path) catch {
            self.allocator.free(key_copy);
            self.allocator.free(full_path);
            return null;
        };

        return full_path;
    }

    return null;
}

pub fn run(self: *Shell) !void {
    self.running = true;

    // enable raw mode for interactive input handling
    try self.enableRawMode();

    // setup signal handler for terminal resize
    self.setupResizeHandler();

    // setup job control signal handlers (ignore SIGTTIN/SIGTTOU)
    setupJobControlSignals();

    // initialize terminal dimensions
    const initial_size = self.getTerminalSize();
    self.terminal_width = initial_size.width;
    self.terminal_height = initial_size.height;

    // set initial cursor style based on vim mode
    const initial_cursor = if (self.vim_mode == .normal) CursorStyle.block else CursorStyle.bar;
    try self.setCursorStyle(initial_cursor);

    // Agent thread starts lazily on first `agent` command or query — no eager startup.
    // Ghost text inference also lazy — only if completion_model is configured.
    {
        var cfg = agent_log.AgentConfig.load(self.allocator);
        defer cfg.deinit();
        if (cfg.completion_model.len > 0) {
            // expand ~ to home directory
            var path_buf: [512]u8 = undefined;
            const model_path = if (std.mem.startsWith(u8, cfg.completion_model, "~/")) blk: {
                const home = compat.getEnvVarOwned(self.allocator, "HOME") catch break :blk cfg.completion_model;
                defer self.allocator.free(home);
                break :blk std.fmt.bufPrint(&path_buf, "{s}{s}", .{ home, cfg.completion_model[1..] }) catch cfg.completion_model;
            } else cfg.completion_model;
            completion_mod.startGhostInference(self, model_path);
        }
    }

    try self.renderLine();

    var last_action: Action = .none;

    while (self.running) {
        // handle terminal resize (atomic access - signal handler may set this)
        if (@atomicLoad(bool, &self.terminal_resized, .acquire)) {
            @atomicStore(bool, &self.terminal_resized, false, .release);
            try self.handleResize();
        }

        // drain any pending agent output (terminal-aware)
        try self.drainAgentOutput();

        try self.log(last_action);

        // when agent is busy, use poll so we can keep draining output
        if (self.agent.isBusy()) {
            last_action = self.pollNextAction() catch .none;
        } else {
            last_action = try self.readNextAction();
        }
        try self.handleAction(last_action);
        try self.stdout().flush();
    }

    // restore terminal and exit immediately — background threads
    // (agent, ghost inference) are cleaned up by the OS on process exit
    self.disableRawMode();
    self.setCursorStyle(.default) catch {};
    self.stdout().flush() catch {};
    if (self.history) |h| h.sync();
    std.process.exit(self.last_exit_code);
}

pub inline fn stdout(self: *Shell) *std.Io.Writer {
    return &self.stdout_writer.interface;
}

// cursor styles for vim modes
const CursorStyle = enum {
    block, // normal mode
    bar, // insert mode
    default, // restore terminal default

    fn escapeCode(self: CursorStyle) []const u8 {
        return switch (self) {
            .block => "\x1b[2 q", // steady block cursor
            .bar => "\x1b[6 q", // steady bar cursor
            .default => "\x1b[0 q", // reset to default
        };
    }
};

fn setCursorStyle(_: *Shell, style: CursorStyle) !void {
    // Write to stderr so it doesn't interfere with pipelines
    _ = posix.write(posix.STDERR_FILENO, style.escapeCode()) catch {};
}

const TerminalSize = struct {
    width: usize,
    height: usize,
};

fn getTerminalSize(_: *Shell) TerminalSize {
    const TIOCGWINSZ = if (@hasDecl(std.posix.system, "T")) std.posix.system.T.IOCGWINSZ else 0x5413;

    const winsize = extern struct {
        ws_row: u16,
        ws_col: u16,
        ws_xpixel: u16,
        ws_ypixel: u16,
    };

    var ws: winsize = undefined;
    const result = std.posix.system.ioctl(posix.STDOUT_FILENO, TIOCGWINSZ, @intFromPtr(&ws));

    if (result == 0 and ws.ws_col > 0 and ws.ws_row > 0) {
        return .{ .width = ws.ws_col, .height = ws.ws_row };
    }

    return .{ .width = 80, .height = 24 }; // fallback if ioctl fails
}

fn handleSigwinch(_: posix.SIG) callconv(.c) void {
    // atomic load to safely access from signal handler context
    const shell = @atomicLoad(?*Shell, &global_shell, .acquire);
    if (shell) |s| {
        @atomicStore(bool, &s.terminal_resized, true, .release);
    }
}

fn setupResizeHandler(self: *Shell) void {
    // atomic store to safely publish to signal handler
    @atomicStore(?*Shell, &global_shell, self, .release);

    const SIGWINCH: posix.SIG = if (@hasField(posix.SIG, "WINCH")) .WINCH else @enumFromInt(28);

    const empty_mask: posix.sigset_t = std.mem.zeroes(posix.sigset_t);

    var act = posix.Sigaction{
        .handler = .{ .handler = handleSigwinch },
        .mask = empty_mask,
        .flags = 0,
    };

    posix.sigaction(SIGWINCH, &act, null);
}

/// Set up signal handlers for job control
/// Interactive shells must ignore SIGTTIN/SIGTTOU to avoid being stopped
/// when terminal control is temporarily given to a child process group
fn setupJobControlSignals() void {
    const ignore_action = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = 0,
    };

    // Ignore SIGTTIN - sent when bg process reads from terminal
    posix.sigaction(posix.SIG.TTIN, &ignore_action, null);

    // Ignore SIGTTOU - sent when bg process writes to terminal
    posix.sigaction(posix.SIG.TTOU, &ignore_action, null);
}

fn handleResize(self: *Shell) !void {
    // get current terminal size
    const new_size = self.getTerminalSize();

    // check if dimensions actually changed
    if (new_size.width == self.terminal_width and new_size.height == self.terminal_height) {
        return; // spurious SIGWINCH, nothing changed
    }

    // Debounce rapid resizes to avoid redraw storms during a window drag.
    //
    // A WIDTH change must NOT be debounced into a "do nothing" return:
    // TermView.render() runs its own updateSize() on the very next keystroke and
    // adopts the new width regardless. If we have not reset the row/col tracking
    // by then, that render moves the cursor up by a now-stale term.row and erases
    // content it then fails to repaint — the screen blanks until the next key
    // (the resize-related blank). So a width change always runs the
    // geometry-coherent redraw below (cheap, a single render); the debounce only
    // throttles height-only changes, where no reflow happens.
    const now = compat.milliTimestamp();
    const debounce_ms = 50; // wait 50ms between redraws
    const width_changed = new_size.width != self.terminal_width;
    if (!width_changed and now - self.last_resize_time < debounce_ms) {
        // schedule another check by keeping the flag set
        @atomicStore(bool, &self.terminal_resized, true, .release);
        return;
    }
    self.last_resize_time = now;

    // update stored dimensions
    self.terminal_width = new_size.width;
    self.terminal_height = new_size.height;

    // update term_view dimensions
    self.term_view.term.width = @intCast(new_size.width);
    self.term_view.term.height = @intCast(new_size.height);
    self.term_view.last_width = @intCast(new_size.width); // keep render()'s own size check in sync

    // Move to the top of our region. term.row is still the valid pre-reflow
    // offset (no render has run at the new width yet). We do NOT erase here: the
    // erase is left to render(), which emits \x1b[J atomically with the content
    // in a single stderr write. Erasing on stdout and flushing it separately
    // opens a cross-FD window where the screen is blank between the stdout-erase
    // flush and the stderr redraw. Repositioning only (no erase) is safe to
    // flush across FDs because it leaves the screen contents intact.
    if (self.term_view.term.row > 0) {
        try self.stdout().print("\x1b[{d}A", .{self.term_view.term.row});
    }
    try self.stdout().writeAll("\r");
    try self.stdout().flush(); // sync cursor move before the stderr redraw
    self.term_view.term.row = 0;
    self.term_view.term.col = 0;
    self.term_view.last_hash = 0;

    try self.renderLine();
    if (self.completion.mode and self.completion.displayed) {
        try completion_mod.displayCompletions(self);
    }
}

fn log(self: *Shell, last_action: Action) !void {
    if (self.log_file) |file| {
        var buff: [1024 * 256]u8 = undefined;
        const slice = try std.fmt.bufPrint(
            buff[0..],
            "\x1b[H\x1b[J" ++
                "State:\n" ++
                "\tcursor: {}\n" ++
                "\tvim_mode: {s}\n" ++
                "\thistory_index: {}\n" ++
                "\tbuf_len: {}\n" ++
                "\tsearch_mode: {}\n" ++
                "\tsearch_len: {}\n" ++
                "\tcommand: '{s}'\n" ++
                "\tsearch_buffer: '{s}'\n" ++
                "\tlast_action: '{}'\n",
            .{
                self.edit_buf.cursor, @tagName(self.vim_mode),
                self.history_index,
                self.edit_buf.len,
                self.search_mode, self.search_len,
                self.edit_buf.slice(), self.search_buffer[0..self.search_len],
                last_action,
            },
        );
        try compat.writeAll(file, slice);
    }
}

fn handleAction(self: *Shell, action: Action) !void {
    // reset ctrl+d pending on any other action
    if (action != .exit_shell and action != .none) {
        self.ctrl_d_pending = false;
    }

    switch (action) {
        .none => {},

        .cancel => {
            completion_mod.exitCompletionMode(self);
            self.ghost.len = 0;
            // print ^C like bash does
            try self.stdout().writeAll("^C\n");
            try self.stdout().flush();
            // signal we're on a fresh line
            self.term_view.finishLine();
            self.displayed_cmd_lines = 1;
            self.terminal_cursor_row = 0;
            // clear and render new prompt
            self.clearCommand();
            self.paste_mode = false;
            self.history_index = -1;
            self.history_search_prefix_len = 0;
            self.vi.mode = .insert;
            self.vim_mode = .insert; // legacy compat
            try self.renderLine();
            try self.setCursorStyle(.bar);
        },

        .exit_shell => {
            // double ctrl+d to exit (like zsh)
            if (self.ctrl_d_pending) {
                self.running = false;
                try self.stdout().writeByte('\n');
            } else {
                self.ctrl_d_pending = true;
                try self.stdout().writeAll("\r\n(press ctrl+d again to exit)\r\n");
                try self.stdout().flush();
                try self.renderLine();
            }
        },

        .cancel_agent => {
            if (self.agent.isBusy()) {
                self.agent.cancel();
                // move below prompt content before printing
                self.term_view.moveTo(self.term_view.term.rows_owned -| 1, 0);
                self.term_view.clearToEOL();
                try self.term_view.flush();
                try self.stdout().writeAll("\r\n^G agent cancelled\n");
                try self.stdout().flush();
                self.term_view.finishLine();
                try self.renderLine();
            }
        },

        .suspend_shell => {
            // suspend the shell with Ctrl+Z
            try self.stdout().writeAll("^Z\n");
            try self.stdout().flush();

            // restore terminal to original state before suspending
            self.disableRawMode();

            // send SIGTSTP to ourselves - we'll be stopped here
            const pid = std.os.linux.getpid();
            _ = posix.kill(pid, posix.SIG.TSTP) catch {};

            // === EXECUTION RESUMES HERE AFTER SIGCONT ===
            // the parent shell may have changed terminal settings while we
            // were suspended, so we must re-read the current state rather
            // than using our cached original_termios
            self.original_termios = null; // force re-read of terminal state
            self.enableRawMode() catch {};

            // also update our cached shell terminal modes for job control
            self.job_table.shell_tmodes = posix.tcgetattr(posix.STDIN_FILENO) catch self.job_table.shell_tmodes;

            // redraw the prompt
            try self.stdout().writeAll("\n");
            try self.renderLine();
        },

        .input_char => |char| {
            // exit completion mode when typing
            completion_mod.exitCompletionMode(self);

            if (self.search_mode) {
                // Add to search buffer and show live results
                if (self.search_len < self.search_buffer.len) {
                    self.search_buffer[self.search_len] = char;
                    self.search_len += 1;
                    try self.showSearchMatch();
                }
            } else {
                // Skip duplicate slash right after completion inserted one
                if (char == '/' and self.completion.skip_next_slash) {
                    self.completion.skip_next_slash = false;
                    return; // don't insert, don't redraw
                }
                self.completion.skip_next_slash = false; // clear for any other char

                // Use new edit_buf for insertion
                if (!self.edit_buf.insert(char)) return;

                // Update history prefix if in navigation mode
                if (self.history_index != -1) {
                    self.history_search_prefix_len = self.edit_buf.len;
                }

                // Update display (skip during paste mode - redraw at paste end)
                if (!self.paste_mode) {
                    try self.renderLine();
                }
            }
        },

        .backspace => {
            if (self.search_mode) {
                if (self.search_len > 0) {
                    self.search_len -= 1;
                    try self.showSearchMatch();
                }
            } else {
                if (self.edit_buf.delete()) {
                    // Update history prefix if in navigation mode
                    if (self.history_index != -1) {
                        self.history_search_prefix_len = self.edit_buf.len;
                    }
                    try self.renderLine();
                }
            }
        },

        .delete_word_backward => {
            // exit completion mode
            completion_mod.exitCompletionMode(self);

            // delete word before cursor (like Ctrl+W in bash/zsh)
            const text = self.edit_buf.slice();
            var pos = self.edit_buf.cursor;

            // skip whitespace first
            while (pos > 0 and (text[pos - 1] == ' ' or text[pos - 1] == '\t')) : (pos -= 1) {}

            // then skip non-whitespace (the word)
            while (pos > 0 and text[pos - 1] != ' ' and text[pos - 1] != '\t') : (pos -= 1) {}

            // delete from pos to cursor
            const chars_to_delete = self.edit_buf.cursor - pos;
            var i: usize = 0;
            while (i < chars_to_delete) : (i += 1) {
                _ = self.edit_buf.delete();
            }

            if (self.history_index != -1) {
                self.history_search_prefix_len = self.edit_buf.len;
            }
            try self.renderLine();
        },

        .kill_to_beginning => {
            // Ctrl+U: kill from cursor to start of line, save to kill buffer
            const pos = self.edit_buf.cursor;
            if (pos > 0) {
                // Save killed text to yank buffer
                @memcpy(self.vi.yank_buf[0..pos], self.edit_buf.text[0..pos]);
                self.vi.yank_len = @intCast(pos);
                // Delete by repeated backspace
                var i: usize = 0;
                while (i < pos) : (i += 1) _ = self.edit_buf.delete();
                if (self.history_index != -1) {
                    self.history_search_prefix_len = self.edit_buf.len;
                }
                try self.renderLine();
            }
        },

        .kill_to_end => {
            // Ctrl+K: kill from cursor to end of line, save to kill buffer
            const start = self.edit_buf.cursor;
            var end: u16 = start;
            while (end < self.edit_buf.len and self.edit_buf.text[end] != '\n') end += 1;
            if (end > start) {
                const len = end - start;
                @memcpy(self.vi.yank_buf[0..len], self.edit_buf.text[start..end]);
                self.vi.yank_len = @intCast(len);
                self.edit_buf.cursor = start;
                var i: usize = 0;
                while (i < len) : (i += 1) _ = self.edit_buf.deleteForward();
                if (self.history_index != -1) {
                    self.history_search_prefix_len = self.edit_buf.len;
                }
                try self.renderLine();
            }
        },

        .yank_killed => {
            // Ctrl+Y: paste kill buffer at cursor
            if (self.vi.yank_len > 0) {
                _ = self.edit_buf.insertSlice(self.vi.yank_buf[0..self.vi.yank_len]);
                if (self.history_index != -1) {
                    self.history_search_prefix_len = self.edit_buf.len;
                }
                try self.renderLine();
            }
        },

        .transpose_chars => {
            // Ctrl+T: swap character before cursor with character at cursor
            if (self.edit_buf.cursor > 0 and self.edit_buf.cursor < self.edit_buf.len) {
                const c1 = self.edit_buf.text[self.edit_buf.cursor - 1];
                const c2 = self.edit_buf.text[self.edit_buf.cursor];
                self.edit_buf.text[self.edit_buf.cursor - 1] = c2;
                self.edit_buf.text[self.edit_buf.cursor] = c1;
                self.edit_buf.cursor += 1;
                try self.renderLine();
            } else if (self.edit_buf.cursor >= 2 and self.edit_buf.cursor == self.edit_buf.len) {
                // at end of line: swap last two chars (bash behavior)
                const pos = self.edit_buf.cursor;
                const c1 = self.edit_buf.text[pos - 2];
                const c2 = self.edit_buf.text[pos - 1];
                self.edit_buf.text[pos - 2] = c2;
                self.edit_buf.text[pos - 1] = c1;
                try self.renderLine();
            }
        },

        .insert_last_arg => {
            // Alt+.: insert last argument from previous history command
            if (self.history) |h| {
                const items = h.entries.items;
                if (items.len > 0) {
                    const prev = h.getCommand(items[items.len - 1]);
                    if (prev.len > 0) {
                        // find last whitespace-separated argument
                        var end: usize = prev.len;
                        while (end > 0 and (prev[end - 1] == ' ' or prev[end - 1] == '\t')) end -= 1;
                        var start: usize = end;
                        while (start > 0 and prev[start - 1] != ' ' and prev[start - 1] != '\t') start -= 1;
                        const last_arg = prev[start..end];
                        if (last_arg.len > 0) {
                            if (self.edit_buf.len > 0 and self.edit_buf.cursor > 0 and
                                self.edit_buf.text[self.edit_buf.cursor - 1] != ' ')
                            {
                                _ = self.edit_buf.insert(' ');
                            }
                            _ = self.edit_buf.insertSlice(last_arg);
                            try self.renderLine();
                        }
                    }
                }
            }
        },

        .delete => |delete_action| {
            switch (delete_action) {
                .char_under_cursor => {
                    if (self.edit_buf.deleteForward()) {
                        if (self.history_index != -1) {
                            self.history_search_prefix_len = self.edit_buf.len;
                        }
                        try self.renderLine();
                    }
                },
                .to_line_end => {
                    // Delete to end of line (D in vim)
                    const start = self.edit_buf.cursor;
                    self.edit_buf.moveLineEnd();
                    const end = self.edit_buf.cursor;
                    if (end > start) {
                        // yank to vim register
                        const len = end - start;
                        @memcpy(self.vi.yank_buf[0..len], self.edit_buf.text[start..end]);
                        self.vi.yank_len = @intCast(len);
                        // delete
                        self.edit_buf.cursor = start;
                        var i: usize = 0;
                        while (i < len) : (i += 1) _ = self.edit_buf.deleteForward();
                        if (self.history_index != -1) {
                            self.history_search_prefix_len = self.edit_buf.len;
                        }
                        try self.renderLine();
                    }
                },
                .char_at => |pos| {
                    if (pos < self.edit_buf.len) {
                        const old_cursor = self.edit_buf.cursor;
                        self.edit_buf.cursor = @intCast(pos);
                        _ = self.edit_buf.deleteForward();
                        self.edit_buf.cursor = if (old_cursor > pos) old_cursor - 1 else old_cursor;
                        if (self.history_index != -1) {
                            self.history_search_prefix_len = self.edit_buf.len;
                        }
                        try self.renderLine();
                    }
                },
            }
        },

        .execute_command => {
            if (self.search_mode) {
                // In search mode, treat enter as exit search
                try self.handleAction(.{ .exit_search_mode = true });
            } else {
                completion_mod.exitCompletionMode(self);
                self.ghost.len = 0;

                const command = std.mem.trim(u8, self.edit_buf.slice(), " \t\n\r");

                // Check for line continuation (trailing backslash)
                if (command.len > 0 and command[command.len - 1] == '\\') {
                    // Check it's not an escaped backslash (\\)
                    const is_escaped = command.len >= 2 and command[command.len - 2] == '\\';
                    if (!is_escaped) {
                        // Line continuation - insert newline and continue editing
                        _ = self.edit_buf.insert('\n');
                        try self.renderLine();
                        return;
                    }
                }

                // Check for heredoc (need to collect lines until delimiter)
                if (findHeredocDelimiter(command)) |delim| {
                    if (!heredocComplete(command, delim)) {
                        // Need more input - continue editing
                        _ = self.edit_buf.insert('\n');
                        try self.renderLine();
                        return;
                    }
                }

                try self.stdout().writeByte('\n');
                try self.stdout().flush();

                if (command.len > 0) {
                    // ? translate mode: natural language -> shell command
                    if (command[0] == '?' and command.len > 1) {
                        const nl_query = std.mem.trimStart(u8, command[1..], " \t");
                        if (nl_query.len > 0) {
                            try self.handleTranslateQuery(nl_query);
                            self.clearCommand();
                            self.history_index = -1;
                            self.history_search_prefix_len = 0;
                            self.vi.mode = .insert;
                            self.vim_mode = .insert;
                            self.term_view.finishLine();
                            self.displayed_cmd_lines = 1;
                            try self.renderLine();
                            return;
                        }
                    }

                    // Preprocess heredoc: convert << DELIM ... DELIM to <<< "content"
                    const processed_cmd = if (findHeredocDelimiter(command)) |delim|
                        self.preprocessHeredoc(command, delim) catch command
                    else
                        command;
                    defer if (processed_cmd.ptr != command.ptr) self.allocator.free(processed_cmd);

                    const start_ts = compat.timestamp();
                    self.last_exit_code = try self.executeCommand(processed_cmd);
                    const elapsed = compat.timestamp() - start_ts;

                    // Show elapsed time for long-running commands (>1s)
                    if (elapsed > 0) {
                        var time_buf: [32]u8 = undefined;
                        const time_str = if (elapsed >= 3600)
                            std.fmt.bufPrint(&time_buf, "\x1b[90m {d}h{d}m{d}s\x1b[0m", .{
                                @divFloor(elapsed, 3600),
                                @divFloor(@mod(elapsed, 3600), 60),
                                @mod(elapsed, 60),
                            }) catch ""
                        else if (elapsed >= 60)
                            std.fmt.bufPrint(&time_buf, "\x1b[90m {d}m{d}s\x1b[0m", .{
                                @divFloor(elapsed, 60),
                                @mod(elapsed, 60),
                            }) catch ""
                        else
                            std.fmt.bufPrint(&time_buf, "\x1b[90m {d}s\x1b[0m", .{elapsed}) catch "";
                        if (time_str.len > 0) {
                            try self.stdout().writeAll(time_str);
                            try self.stdout().writeByte('\n');
                        }
                    }

                    // Add to history
                    if (self.history) |h| {
                        h.addCommand(command, self.last_exit_code) catch {};
                    }

                    // Log command execution for training data
                    logCommandExecution(command, self.last_exit_code, elapsed);
                }

                // flush any command output before rendering new prompt
                try self.stdout().flush();

                self.clearCommand();
                self.history_index = -1;
                self.history_search_prefix_len = 0;
                self.vi.mode = .insert;
                self.vim_mode = .insert; // legacy compat
                self.term_view.finishLine();
                self.displayed_cmd_lines = 1;
                self.terminal_cursor_row = 0;
                try self.setCursorStyle(.bar);

                if (self.running) {
                    // sync history from other sessions before next prompt
                    if (self.history) |h| h.sync();
                    try self.renderLine();
                }
            }
        },

        .redraw_line => try self.renderLine(),

        .clear_screen => {
            try self.stdout().writeAll("\x1b[2J\x1b[H");
            try self.stdout().flush();
            self.term_view.finishLine();
            self.displayed_cmd_lines = 1;
            self.terminal_cursor_row = 0;
            try self.renderLine();
        },

        .vim_mode => |mode_action| {
            switch (mode_action) {
                .set_mode => |mode| {
                    self.vim_mode = mode;
                    self.vi.mode = if (mode == .normal) .normal else .insert;
                    if (mode == .normal) self.paste_mode = false;
                },
                .enter_visual => |vtype| {
                    self.vi.mode = if (vtype == .line) .visual_line else .visual;
                    self.vi.visual_start = self.edit_buf.cursor;
                },
            }
            // update cursor style to match vim mode
            const cursor = if (self.vim_mode == .normal) CursorStyle.block else CursorStyle.bar;
            try self.setCursorStyle(cursor);
            // force redraw - prompt changed even if text didn't
            self.term_view.last_hash = 0xDEADBEEF;
            return self.renderLine();
        },

        .tap_complete => {
            if (self.completion.mode) {
                try completion_mod.handleCompletionCycle(self, .forward);
            } else {
                // Tab always does traditional completion (ls <tab> shows files)
                // Ghost text is accepted via Right arrow or End key
                try completion_mod.handleTabCompletion(self);
            }
        },

        .cycle_ghost => |direction| {
            // Alt+Up/Down — cycle through ghost text candidates
            const dir: i8 = if (direction == .forward) 1 else -1;
            if (completion_mod.cycleGhostCandidate(self, dir)) {
                try self.renderLine();
            }
        },

        .cycle_complete => |direction| {
            if (self.completion.mode) {
                try completion_mod.handleCompletionCycle(self,direction);
            } else {
                try completion_mod.handleTabCompletion(self);
            }
        },

        .move_cursor => |move| {
            try self.handleCursorMovement(move);
        },

        .history_nav => |direction| {
            try self.handleHistoryNavigation(direction);
        },

        .enter_search_mode => |direction| {
            self.search_mode = true;
            self.search_len = 0;
            // clear all wrapped rows of the command line first
            if (self.term_view.term.row > 0) {
                try self.stdout().print("\x1b[{d}A", .{self.term_view.term.row});
            }
            try self.stdout().writeAll("\r\x1b[J");
            if (direction == .backward) {
                try self.stdout().writeAll("(reverse-i-search): ");
            } else {
                try self.stdout().writeAll("(forward-i-search): ");
            }
            try self.stdout().flush(); // flush erase before any stderr redraw
        },

        .exit_search_mode => |execute| {
            self.search_mode = false;

            // The search UI ["(reverse-i-search): ..."] is drawn with raw stdout
            // writes that never update the TermView hash, so renderLine()'s
            // skip-guard can early-return and leave that text on screen when the
            // edit buffer is unchanged (e.g. Ctrl+R then Esc with no typing).
            // Force a full repaint, as the .vim_mode handler does.
            self.term_view.last_hash = 0xDEADBEEF;

            // Esc cancelled the search: land in vi normal mode so the cursor
            // and subsequent keys behave as expected (i → insert). Without this
            // the user stays in whatever mode Ctrl+R was entered from and the
            // block-cursor / mode is inconsistent.
            if (!execute) {
                self.vim_mode = .normal;
                self.vi.mode = .normal;
                self.paste_mode = false;
                self.setCursorStyle(.block) catch {};
            }

            if (execute and self.search_len > 0 and self.history != null) {
                const search_term = self.search_buffer[0..self.search_len];
                const matches = self.history.?.fuzzySearch(search_term, self.allocator) catch {
                    try self.renderLine();
                    return;
                };
                defer self.allocator.free(matches);

                if (matches.len > 0) {
                    const entry_idx = matches[0].entry_index;
                    const entry = self.history.?.entries.items[entry_idx];
                    const cmd = self.history.?.getCommand(entry);
                    self.edit_buf.set(cmd);
                                    }
            }

            self.search_len = 0;
            try self.renderLine();
        },

        .yank => |yank_action| {
            switch (yank_action) {
                .line => {
                    // yank to vim register
                    const slice = self.edit_buf.slice();
                    @memcpy(self.vi.yank_buf[0..slice.len], slice);
                    self.vi.yank_len = @intCast(slice.len);
                },
                .selection => |sel| {
                    if (sel.end > sel.start and sel.end <= self.edit_buf.len) {
                        const len = sel.end - sel.start;
                        @memcpy(self.vi.yank_buf[0..len], self.edit_buf.text[sel.start..sel.end]);
                        self.vi.yank_len = @intCast(len);
                    }
                },
            }
        },

        .paste => |paste_action| {
            if (self.vi.yank_len == 0) return;

            // position cursor for paste
            if (paste_action == .after_cursor and self.edit_buf.cursor < self.edit_buf.len) {
                _ = self.edit_buf.moveRight();
            }

            // insert yanked text
            _ = self.edit_buf.insertSlice(self.vi.yank_buf[0..self.vi.yank_len]);
                        try self.renderLine();
        },

        .insert_at_position => |pos_type| {
            switch (pos_type) {
                .cursor => {},
                .after_cursor => _ = self.edit_buf.moveRight(),
                .line_start => self.edit_buf.moveLineStart(),
                .line_end => self.edit_buf.moveLineEnd(),
            }
            self.vi.mode = .insert;
            self.vim_mode = .insert;
            try self.setCursorStyle(.bar);
            try self.renderLine();
        },

        .open_line => |direction| {
            switch (direction) {
                .below => {
                    // o - open line below: go to end of line, insert newline
                    self.edit_buf.moveLineEnd();
                    _ = self.edit_buf.insert('\n');
                },
                .above => {
                    // O - open line above: go to start of line, insert newline, move back
                    self.edit_buf.moveLineStart();
                    _ = self.edit_buf.insert('\n');
                    _ = self.edit_buf.moveLeft();
                },
            }
            self.vi.mode = .insert;
            self.vim_mode = .insert;
            try self.setCursorStyle(.bar);
            try self.renderLine();
        },

        .undo => {
            self.clearCommand();
            try self.renderLine();
        },

        .enter_paste_mode => {
            self.paste_mode = true;
        },

        .exit_paste_mode => {
            self.paste_mode = false;
            try self.stdout().flush(); // sync before render
            try self.renderLine();
        },
    }
}

fn handleCursorMovement(self: *Shell, move_action: MoveCursorAction) !void {
    const old_pos = self.edit_buf.cursor;
    const max_pos = self.edit_buf.len;
    const cmd = self.edit_buf.slice();

    // Handle line up/down specially - may need history fallback
    switch (move_action) {
        .line_up => {
            // Check if buffer has newlines - if so, try line navigation first
            const has_newlines = std.mem.indexOfScalar(u8, cmd, '\n') != null;

            if (has_newlines) {
                // Check if we're on the first line (no newline before cursor)
                const on_first_line = std.mem.lastIndexOfScalar(u8, cmd[0..old_pos], '\n') == null;
                if (on_first_line) {
                    // Already on first line, fall back to history
                    self.vi.preferred_col_set = false; // reset preferred col on history nav
                    try self.handleHistoryNavigation(.up);
                    try self.renderLine();
                } else {
                    // Use vim's moveUp which tracks preferred column
                    self.vi.moveUp(&self.edit_buf);
                    try self.renderLine();
                }
            } else {
                // No newlines in buffer, just do history navigation
                self.vi.preferred_col_set = false;
                try self.handleHistoryNavigation(.up);
                try self.renderLine();
            }
            return;
        },
        .line_down => {
            // Check if buffer has newlines - if so, try line navigation first
            const has_newlines = std.mem.indexOfScalar(u8, cmd, '\n') != null;

            if (has_newlines) {
                // Check if we're on the last line (no newline after cursor)
                const on_last_line = std.mem.indexOfScalar(u8, cmd[old_pos..], '\n') == null;
                if (on_last_line) {
                    // Already on last line, fall back to history
                    self.vi.preferred_col_set = false;
                    try self.handleHistoryNavigation(.down);
                    try self.renderLine();
                } else {
                    // Use vim's moveDown which tracks preferred column
                    self.vi.moveDown(&self.edit_buf);
                    try self.renderLine();
                }
            } else {
                // No newlines in buffer, just do history navigation
                self.vi.preferred_col_set = false;
                try self.handleHistoryNavigation(.down);
                try self.renderLine();
            }
            return;
        },
        else => {},
    }

    // Horizontal movement resets preferred column for j/k navigation
    self.vi.preferred_col_set = false;

    // Calculate new position (clamped to valid range)
    const new_pos = switch (move_action) {
        .relative => |steps| blk: {
            const new = @as(isize, @intCast(self.edit_buf.cursor)) + steps;
            break :blk @as(usize, @intCast(@max(0, @min(new, @as(isize, @intCast(max_pos))))));
        },
        .absolute => |pos| @min(pos, max_pos),
        .to_line_start => self.findCurrentLineStart(cmd, old_pos),
        .to_line_end => self.findCurrentLineEnd(cmd, old_pos),
        .word_forward => |boundary| self.findWordForward(boundary),
        .word_backward => |boundary| self.findWordBackward(boundary),
        .line_up, .line_down => unreachable,
    };

    if (new_pos == old_pos) {
        // At end of line — accept ghost text if available
        if (old_pos == max_pos and self.ghost.len > 0) {
            switch (move_action) {
                .relative => |steps| {
                    if (steps > 0) {
                        // Right arrow: accept all ghost text
                        if (completion_mod.acceptGhostText(self)) try self.renderLine();
                    }
                },
                .to_line_end => {
                    // End key: accept all ghost text
                    if (completion_mod.acceptGhostText(self)) try self.renderLine();
                },
                .word_forward => {
                    // Ctrl+Right: accept one word from ghost text
                    if (completion_mod.acceptGhostWord(self)) try self.renderLine();
                },
                else => {},
            }
        }
        return;
    }

    self.edit_buf.cursor = @intCast(new_pos);

    // Use renderLine when content wraps across terminal rows
    // (multiline content OR single-line that exceeds terminal width)
    var prompt_buf: [256]u8 = undefined;
    const prompt_info = self.buildPrompt(&prompt_buf);
    const total_width = @as(usize, prompt_info.visible_len) + cmd.len;
    const wraps = std.mem.indexOfScalar(u8, cmd, '\n') != null or
        (self.terminal_width > 0 and total_width > self.terminal_width);

    if (wraps) {
        try self.stdout().flush();
        try self.renderLine();
    } else {
        const steps = if (new_pos > old_pos)
            new_pos - old_pos
        else
            old_pos - new_pos;

        if (new_pos > old_pos) {
            try self.stdout().print("\x1b[{d}C", .{steps});
        } else {
            try self.stdout().print("\x1b[{d}D", .{steps});
        }
    }
}

fn findLinePosition(self: *Shell, cmd: []const u8, pos: usize, going_up: bool) struct { found: bool, pos: usize } {
    _ = self;

    // Find current line start and column
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < pos) : (i += 1) {
        if (cmd[i] == '\n') {
            line_start = i + 1;
        }
    }
    const col = pos - line_start;

    if (going_up) {
        // Find previous line
        if (line_start == 0) return .{ .found = false, .pos = 0 };

        // Find start of previous line
        var prev_line_start: usize = 0;
        if (line_start >= 2) {
            i = line_start - 2; // skip the newline before current line
            while (i > 0) : (i -= 1) {
                if (cmd[i] == '\n') {
                    prev_line_start = i + 1;
                    break;
                }
            }
        }

        // Find end of previous line
        const prev_line_end = line_start - 1;
        const prev_line_len = prev_line_end - prev_line_start;

        // Target position on previous line
        const target_col = @min(col, prev_line_len);
        return .{ .found = true, .pos = prev_line_start + target_col };
    } else {
        // Find next line
        var next_line_start: usize = 0;
        i = pos;
        while (i < cmd.len) : (i += 1) {
            if (cmd[i] == '\n') {
                next_line_start = i + 1;
                break;
            }
        }

        if (next_line_start == 0 or next_line_start >= cmd.len) {
            return .{ .found = false, .pos = 0 };
        }

        // Find end of next line
        var next_line_end = cmd.len;
        i = next_line_start;
        while (i < cmd.len) : (i += 1) {
            if (cmd[i] == '\n') {
                next_line_end = i;
                break;
            }
        }

        const next_line_len = next_line_end - next_line_start;
        const target_col = @min(col, next_line_len);
        return .{ .found = true, .pos = next_line_start + target_col };
    }
}

fn findCurrentLineStart(self: *Shell, cmd: []const u8, pos: usize) usize {
    _ = self;
    if (pos == 0) return 0;
    var i = pos - 1;
    while (i > 0) : (i -= 1) {
        if (cmd[i] == '\n') return i + 1;
    }
    if (cmd[0] == '\n') return 1;
    return 0;
}

fn findCurrentLineEnd(self: *Shell, cmd: []const u8, pos: usize) usize {
    _ = self;
    var i = pos;
    while (i < cmd.len) : (i += 1) {
        if (cmd[i] == '\n') return i;
    }
    return cmd.len;
}

fn findWordForward(self: *Shell, boundary: WordBoundary) usize {
    const buf = self.edit_buf.slice();
    var pos = self.edit_buf.cursor;
    const max = self.edit_buf.len;

    if (pos >= max) return max;

    return switch (boundary) {
        .word => blk: {
            // Skip current word (alphanumeric + underscore)
            while (pos < max and isWordChar(buf[pos])) : (pos += 1) {}
            // Skip whitespace
            while (pos < max and isWhitespace(buf[pos])) : (pos += 1) {}
            break :blk pos;
        },
        .WORD => blk: {
            // Skip non-whitespace
            while (pos < max and !isWhitespace(buf[pos])) : (pos += 1) {}
            // Skip whitespace
            while (pos < max and isWhitespace(buf[pos])) : (pos += 1) {}
            break :blk pos;
        },
        .word_end => blk: {
            // Move forward one if we're on the last char of a word
            if (pos < max and isWordChar(buf[pos]) and
                (pos + 1 >= max or !isWordChar(buf[pos + 1])))
            {
                pos += 1;
            }
            // Skip whitespace
            while (pos < max and isWhitespace(buf[pos])) : (pos += 1) {}
            // Move to end of word
            while (pos < max and isWordChar(buf[pos])) : (pos += 1) {}
            // Back up one to be ON the last character
            if (pos > self.edit_buf.cursor) pos -= 1;
            break :blk pos;
        },
        .WORD_end => blk: {
            // Move forward one if we're on the last char of a WORD
            if (pos < max and !isWhitespace(buf[pos]) and
                (pos + 1 >= max or isWhitespace(buf[pos + 1])))
            {
                pos += 1;
            }
            // Skip whitespace
            while (pos < max and isWhitespace(buf[pos])) : (pos += 1) {}
            // Move to end of WORD
            while (pos < max and !isWhitespace(buf[pos])) : (pos += 1) {}
            // Back up one to be ON the last character
            if (pos > self.edit_buf.cursor) pos -= 1;
            break :blk pos;
        },
    };
}

fn findWordBackward(self: *Shell, boundary: WordBoundary) usize {
    const buf = self.edit_buf.slice();
    if (self.edit_buf.cursor == 0) return 0;

    var pos = self.edit_buf.cursor - 1;

    return switch (boundary) {
        .word, .word_end => blk: {
            // Skip whitespace
            while (pos > 0 and isWhitespace(buf[pos])) : (pos -= 1) {}
            // Skip to beginning of word
            while (pos > 0 and isWordChar(buf[pos - 1])) : (pos -= 1) {}
            break :blk pos;
        },
        .WORD, .WORD_end => blk: {
            // Skip whitespace
            while (pos > 0 and isWhitespace(buf[pos])) : (pos -= 1) {}
            // Skip to beginning of WORD
            while (pos > 0 and !isWhitespace(buf[pos - 1])) : (pos -= 1) {}
            break :blk pos;
        },
    };
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

/// Handle ? translate mode: send NL query to agent, collect response, populate edit buffer.
fn handleTranslateQuery(self: *Shell, nl_query: []const u8) !void {
    const agent_queue = @import("agent_queue.zig");

    // Build translate prompt
    var prompt_buf: [2048]u8 = undefined;
    const prompt = std.fmt.bufPrint(&prompt_buf, "Translate this to a shell command. Reply with ONLY the command, nothing else — no explanation, no markdown, no backticks:\n{s}", .{nl_query}) catch return;

    // Send to agent
    if (!self.agent.query(prompt)) {
        try self.stdout().writeAll("\x1b[31m? agent queue full\x1b[0m\n");
        return;
    }

    // Show thinking indicator
    const writer = self.stdout();
    try writer.writeAll("\x1b[90m? translating...\x1b[0m");
    try writer.flush();

    // Collect response (blocking wait with timeout)
    var result_buf: [2048]u8 = undefined;
    var result_len: usize = 0;
    var done = false;
    var ticks: u32 = 0;
    const max_ticks: u32 = 1500; // 30s timeout at 20ms poll

    while (!done and ticks < max_ticks) : (ticks += 1) {
        var msg: agent_queue.Msg = undefined;
        while (self.agent.queues.output.pop(&msg)) {
            switch (msg.kind) {
                .text_delta => {
                    const text = msg.slice();
                    const remaining = result_buf.len - result_len;
                    const n = @min(text.len, remaining);
                    @memcpy(result_buf[result_len..][0..n], text[0..n]);
                    result_len += n;
                },
                .done => {
                    done = true;
                },
                .error_msg => {
                    try writer.writeAll("\r\x1b[2K\x1b[31m? ");
                    try writer.writeAll(msg.slice());
                    try writer.writeAll("\x1b[0m\n");
                    return;
                },
                else => {},
            }
        }
        if (!done) compat.sleep(20 * std.time.ns_per_ms);
    }

    // Clear thinking indicator
    try writer.writeAll("\r\x1b[2K");

    if (result_len == 0) {
        try writer.writeAll("\x1b[31m? no response\x1b[0m\n");
        return;
    }

    // Strip any leading/trailing whitespace and backticks from response
    var result = std.mem.trim(u8, result_buf[0..result_len], " \t\n\r");
    // Strip ```sh ... ``` or ``` ... ``` wrapping
    if (std.mem.startsWith(u8, result, "```")) {
        if (std.mem.indexOfScalar(u8, result[3..], '\n')) |nl| {
            result = result[3 + nl + 1 ..];
        } else {
            result = result[3..];
        }
        if (std.mem.endsWith(u8, result, "```")) {
            result = result[0 .. result.len - 3];
        }
        result = std.mem.trim(u8, result, " \t\n\r");
    }
    // Strip single backtick wrapping
    if (result.len > 2 and result[0] == '`' and result[result.len - 1] == '`') {
        result = result[1 .. result.len - 1];
    }

    if (result.len == 0) {
        try writer.writeAll("\x1b[31m? empty response\x1b[0m\n");
        return;
    }

    // Log translation for training data
    logTranslation(nl_query, result);

    // Show suggested command and populate edit buffer
    try writer.writeAll("\x1b[90m? \x1b[0m\x1b[1m");
    try writer.writeAll(result);
    try writer.writeAll("\x1b[0m\n");
    try writer.flush();

    // Put command in edit buffer so user can review and press Enter to run
    self.edit_buf.clear();
    _ = self.edit_buf.insertSlice(result);
}

/// Log a ? translate query and result for training data.
fn logTranslation(query: []const u8, result: []const u8) void {
    var path_buf: [512]u8 = undefined;
    const home = compat.getEnvVarOwned(std.heap.page_allocator, "HOME") catch return;
    defer std.heap.page_allocator.free(home);
    const path = std.fmt.bufPrint(&path_buf, "{s}/.zish/translate_log.jsonl", .{home}) catch return;

    const file = std.Io.Dir.cwd().openFile(compat.io(), path, .{ .mode = .write_only }) catch |e| switch (e) {
        error.FileNotFound => std.Io.Dir.cwd().createFile(compat.io(), path, .{}) catch return,
        else => return,
    };
    defer file.close(compat.io());
    const end_pos = file.length(compat.io()) catch return;

    const ts: u64 = @bitCast(compat.timestamp());
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    pos += logCopy(&buf, pos, "{\"query\":\"");
    pos = logEscape(&buf, pos, query);
    pos += logCopy(&buf, pos, "\",\"cmd\":\"");
    pos = logEscape(&buf, pos, result);
    pos += logCopy(&buf, pos, "\",\"ts\":");
    pos += (std.fmt.bufPrint(buf[pos..], "{d}", .{ts}) catch return).len;
    pos += logCopy(&buf, pos, "}\n");
    file.writePositionalAll(compat.io(), buf[0..pos], end_pos) catch {};
}

/// Log every executed command with exit code and duration for training data.
fn logCommandExecution(command: []const u8, exit_code: u8, elapsed: i64) void {
    if (command.len == 0 or command.len > 2048) return;

    var path_buf: [512]u8 = undefined;
    const home = compat.getEnvVarOwned(std.heap.page_allocator, "HOME") catch return;
    defer std.heap.page_allocator.free(home);
    const path = std.fmt.bufPrint(&path_buf, "{s}/.zish/command_log.jsonl", .{home}) catch return;

    const file = std.Io.Dir.cwd().openFile(compat.io(), path, .{ .mode = .write_only }) catch |e| switch (e) {
        error.FileNotFound => std.Io.Dir.cwd().createFile(compat.io(), path, .{}) catch return,
        else => return,
    };
    defer file.close(compat.io());
    const end_pos = file.length(compat.io()) catch return;

    var cwd_buf: [256]u8 = undefined;
    const cwd = posix.getcwd(&cwd_buf) catch "?";

    const ts: u64 = @bitCast(compat.timestamp());
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    pos += logCopy(&buf, pos, "{\"cmd\":\"");
    pos = logEscape(&buf, pos, command);
    pos += logCopy(&buf, pos, "\",\"cwd\":\"");
    pos = logEscape(&buf, pos, cwd);
    pos += logCopy(&buf, pos, "\",\"exit\":");
    pos += (std.fmt.bufPrint(buf[pos..], "{d}", .{exit_code}) catch return).len;
    pos += logCopy(&buf, pos, ",\"dur\":");
    pos += (std.fmt.bufPrint(buf[pos..], "{d}", .{elapsed}) catch return).len;
    pos += logCopy(&buf, pos, ",\"ts\":");
    pos += (std.fmt.bufPrint(buf[pos..], "{d}", .{ts}) catch return).len;
    pos += logCopy(&buf, pos, "}\n");
    file.writePositionalAll(compat.io(), buf[0..pos], end_pos) catch {};
}

/// Shared helpers for JSON log writing.
fn logCopy(buf: *[4096]u8, pos: usize, s: []const u8) usize {
    if (pos + s.len > buf.len) return 0;
    @memcpy(buf[pos..][0..s.len], s);
    return s.len;
}

fn logEscape(buf: *[4096]u8, start: usize, s: []const u8) usize {
    var pos = start;
    for (s) |c| {
        if (pos + 6 > buf.len) break;
        switch (c) {
            '"' => {
                pos += logCopy(buf, pos, "\\\"");
            },
            '\\' => {
                pos += logCopy(buf, pos, "\\\\");
            },
            '\n' => {
                pos += logCopy(buf, pos, "\\n");
            },
            '\r' => {
                pos += logCopy(buf, pos, "\\r");
            },
            '\t' => {
                pos += logCopy(buf, pos, "\\t");
            },
            else => {
                if (c < 0x20) {
                    // control characters as \u00XX
                    pos += (std.fmt.bufPrint(buf[pos..], "\\u00{x:0>2}", .{c}) catch break).len;
                } else {
                    buf[pos] = c;
                    pos += 1;
                }
            },
        }
    }
    return pos;
}

/// Drain agent output with proper terminal coordination.
/// Clears the current prompt on first output, then streams directly.
/// Re-renders prompt only when agent is done.
/// Handler for agent output in inline shell mode (not interactive TUI).
/// Used by agent_drain.drain() — each message kind dispatches to an onXxx method.
const ShellDrainHandler = struct {
    shell: *Shell,
    writer: *std.Io.Writer,
    last_was_text: bool = false,
    wrote: bool = false,

    fn ensureActive(self: *ShellDrainHandler) !void {
        if (!self.shell.agent_output_active) {
            self.shell.term_view.moveTo(self.shell.term_view.term.rows_owned -| 1, 0);
            self.shell.term_view.clearToEOL();
            try self.shell.term_view.flush();
            try self.writer.writeAll("\r\n");
            self.shell.agent_output_active = true;
        }
        self.wrote = true;
    }

    fn resetText(self: *ShellDrainHandler) !void {
        if (self.last_was_text) try self.writer.writeAll("\x1b[0m");
        self.last_was_text = false;
    }

    pub fn onTextDelta(self: *ShellDrainHandler, data: []const u8) !void {
        try self.ensureActive();
        try self.shell.agent_md.render(self.writer, data);
        self.last_was_text = true;
    }

    pub fn onToolCall(self: *ShellDrainHandler, data: []const u8) !void {
        try self.ensureActive();
        try self.resetText();
        try self.writer.writeAll("\x1b[90m\xe2\x9a\xa1 "); // ⚡
        try self.writer.writeAll(data);
        try self.writer.writeAll("\x1b[0m\n");
    }

    pub fn onToolDone(self: *ShellDrainHandler, data: []const u8) !void {
        try self.ensureActive();
        self.last_was_text = false;
        if (data.len > 0) {
            const has_ansi = std.mem.indexOf(u8, data, "\x1b[3") != null;
            if (has_ansi) {
                try self.writer.writeAll("  ");
                try self.writer.writeAll(data);
            } else {
                try self.writer.writeAll("  \x1b[90m");
                try self.writer.writeAll(data);
            }
            try self.writer.writeAll("\x1b[0m\n");
        } else {
            try self.writer.writeAll("  \x1b[32m\xe2\x9c\x93\x1b[0m\n"); // ✓
        }
    }

    pub fn onError(self: *ShellDrainHandler, data: []const u8) !void {
        try self.ensureActive();
        if (self.last_was_text) try self.writer.writeAll("\x1b[0m\n");
        self.last_was_text = false;
        try self.writer.writeAll("\x1b[31m\xe2\x9c\x97 "); // ✗
        try self.writer.writeAll(data);
        try self.writer.writeAll("\x1b[0m\n");
    }

    pub fn onDone(self: *ShellDrainHandler) !void {
        try self.ensureActive();
        try self.resetText();
        try self.writer.writeByte('\n');
        self.shell.agent_md.reset();
        self.shell.agent_output_active = false;
        try self.writer.flush();
        self.shell.term_view.finishLine();
        try self.shell.renderLine();
    }

    pub fn onConfirmRequest(self: *ShellDrainHandler, data: []const u8) !void {
        try self.ensureActive();
        if (self.last_was_text) try self.writer.writeAll("\x1b[0m\n");
        self.last_was_text = false;
        self.shell.agent_md.reset();
        try self.writer.writeAll("\x1b[33m\xe2\x9a\xa0 "); // ⚠
        try self.writer.writeAll(data);
        try self.writer.writeAll(" \x1b[90m[\x1b[32my\x1b[90m/\x1b[31mn\x1b[90m/\x1b[33ma\x1b[90mlways]\x1b[0m ");
        try self.writer.flush();
        var resp: [1]u8 = undefined;
        const n = posix.read(posix.STDIN_FILENO, &resp) catch 0;
        if (n > 0 and (resp[0] == 'y' or resp[0] == 'Y')) {
            _ = self.shell.agent.queues.request.push(.confirm_response, "y");
            try self.writer.writeAll("y\n");
        } else if (n > 0 and (resp[0] == 'a' or resp[0] == 'A' or resp[0] == '!')) {
            _ = self.shell.agent.queues.request.push(.confirm_response, "a");
            try self.writer.writeAll("a (always)\n");
        } else {
            _ = self.shell.agent.queues.request.push(.confirm_response, "n");
            try self.writer.writeAll("n\n");
        }
        try self.writer.flush();
    }

    pub fn onUsage(self: *ShellDrainHandler, data: []const u8) !void {
        try self.ensureActive();
        self.last_was_text = false;
        try self.writer.writeAll("\x1b[90m");
        try self.writer.writeAll(data);
        try self.writer.writeAll("\x1b[0m\n");
    }

    pub fn onAgentStatus(self: *ShellDrainHandler, data: []const u8) !void {
        try self.ensureActive();
        self.last_was_text = false;
        if (data.len > 0) {
            try self.writer.writeAll(data);
            try self.writer.writeByte('\n');
        }
    }

    pub fn onCancel(self: *ShellDrainHandler) !void {
        self.last_was_text = false;
        self.shell.agent_output_active = false;
    }
};

fn drainAgentOutput(self: *Shell) !void {
    const agent_drain = @import("agent_drain.zig");
    var handler = ShellDrainHandler{
        .shell = self,
        .writer = self.stdout(),
    };
    _ = try agent_drain.drain(ShellDrainHandler, &handler, &self.agent.queues);

    if (handler.wrote) {
        try handler.writer.flush();
    }

    self.drainBulletin(handler.writer) catch {};
}

fn drainBulletin(self: *Shell, writer: anytype) !void {
    const aq = @import("agent_queue.zig");
    var posts: [8]aq.Post = undefined;
    const br = self.agent.queues.bulletin.read(self.bulletin_cursor, &posts);
    self.bulletin_cursor = br.new_cursor;
    if (br.count == 0) return;

    for (posts[0..br.count]) |*p| {
        // Only surface escalations and discoveries to the user
        switch (p.kind) {
            .escalate => {
                try writer.writeAll("\x1b[33m⚠ [");
                try writer.writeAll(p.authorSlice());
                try writer.writeAll("] ");
                try writer.writeAll(p.slice());
                try writer.writeAll("\x1b[0m\n");
            },
            .discovery => {
                try writer.writeAll("\x1b[36m● [");
                try writer.writeAll(p.authorSlice());
                try writer.writeAll("] ");
                try writer.writeAll(p.slice());
                try writer.writeAll("\x1b[0m\n");
            },
            else => {},
        }
    }
    try writer.flush();
}

/// Non-blocking input read using poll. Returns .none if no input available within timeout.
/// Used when agent is busy so we can interleave output draining with input reading.
fn pollNextAction(self: *Shell) !Action {
    const stdin_fd = posix.STDIN_FILENO;
    var fds = [_]posix.pollfd{.{
        .fd = stdin_fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    // 50ms timeout — responsive enough for streaming, not too CPU-hot
    const poll_result = posix.poll(&fds, 50) catch return .none;
    if (poll_result == 0) return .none; // timeout, no input

    // input available, read normally
    return self.readNextAction();
}

fn readNextAction(self: *Shell) !Action {
    var temp_buf: [1]u8 = undefined;
    const count = try compat.readAll(std.Io.File.stdin(), temp_buf[0..]);
    const char = temp_buf[0];

    if (count == 0) return .none;

    // Always check for escape sequences (arrow keys, Ctrl+arrows, paste end, etc.)
    if (char == '\x1b') {
        return self.escapeSequenceAction();
    }

    // In paste mode (and insert mode), buffer content for editing
    // In normal mode, don't capture chars as input even if paste_mode is stuck
    if (self.paste_mode and self.vim_mode == .insert) {
        if (char == CTRL_C) {
            self.paste_mode = false;
            return .cancel;
        }
        // Store newlines for multiline editing
        if (char == '\n' or char == '\r') {
            return .{ .input_char = '\n' };
        }
        // Printable ASCII or any UTF-8 byte (>= 0x80). Dropping non-ASCII here
        // is why pasted commands with accents / CJK / a stray non-breaking space
        // or em-dash from a web page get silently corrupted.
        if ((char >= 32 and char <= 126) or char >= 0x80) {
            return .{ .input_char = char };
        }
        return .none;
    }

    if (self.search_mode) {
        return self.getSearchModeAction(char);
    }

    // dispatch based on vim mode
    return switch (self.vim_mode) {
        .normal => normalModeAction(char),
        .insert => self.resolveInsertAction(char),
    };
}

fn resolveInsertAction(self: *Shell, char: u8) Action {
    // Structural keys that cannot be rebound
    return switch (char) {
        '\n', '\r' => .execute_command, // Enter (ctrl+j / ctrl+m)
        '\t' => .tap_complete, // Tab (ctrl+i)
        0x08, 127 => .backspace, // Backspace (ctrl+h / DEL)
        32...126 => .{ .input_char = char },
        // UTF-8 lead/continuation bytes — insert so accents/CJK/emoji work.
        0x80...0xFF => .{ .input_char = char },
        // Ctrl keys — look up in configurable keybindings table
        0x01...0x07, 0x0B...0x0C, 0x0E...0x1A => self.keybindings.lookupCtrl(char) orelse .none,
        else => .none,
    };
}

fn normalModeAction(char: u8) Action {
    return switch (char) {
        'h' => .{ .move_cursor = .{ .relative = -1 } },
        'l' => .{ .move_cursor = .{ .relative = 1 } },
        '0' => .{ .move_cursor = .to_line_start },
        '$' => .{ .move_cursor = .to_line_end },

        'w' => .{ .move_cursor = .{ .word_forward = .word } },
        'W' => .{ .move_cursor = .{ .word_forward = .WORD } },
        'b' => .{ .move_cursor = .{ .word_backward = .word } },
        'B' => .{ .move_cursor = .{ .word_backward = .WORD } },
        'e' => .{ .move_cursor = .{ .word_forward = .word_end } },
        'E' => .{ .move_cursor = .{ .word_forward = .WORD_end } },

        'j' => .{ .move_cursor = .line_down },
        'k' => .{ .move_cursor = .line_up },

        'i' => .{ .vim_mode = .{ .set_mode = .insert } },

        'a' => .{ .insert_at_position = .after_cursor },
        'A' => .{ .insert_at_position = .line_end },
        'I' => .{ .insert_at_position = .line_start },

        'o' => .{ .open_line = .below },
        'O' => .{ .open_line = .above },

        'x' => .{ .delete = .char_under_cursor },
        'D' => .{ .delete = .to_line_end },

        'p' => .{ .paste = .after_cursor },
        'P' => .{ .paste = .before_cursor },

        'y' => .{ .yank = .line },

        'u' => .undo,

        '/' => .{ .enter_search_mode = .forward },
        '?' => .{ .enter_search_mode = .backward },

        'v' => .{ .vim_mode = .{ .enter_visual = .char } },
        'V' => .{ .vim_mode = .{ .enter_visual = .line } },

        '\n' => .execute_command,

        CTRL_C => .cancel,
        CTRL_G => .cancel_agent,
        CTRL_Z => .suspend_shell,

        else => .none,
    };
}

fn escapeSequenceAction(self: *Shell) !Action {
    const stdin_fd = posix.STDIN_FILENO;
    var temp_buf: [2]u8 = undefined;

    // Set non-blocking temporarily via system call
    const F_GETFL = 3;
    const F_SETFL = 4;
    const O_NONBLOCK = 0x800;

    const flags_raw = std.posix.system.fcntl(stdin_fd, F_GETFL, @as(usize, 0));
    const flags: usize = if (@TypeOf(flags_raw) == c_int) @intCast(flags_raw) else flags_raw;
    _ = std.posix.system.fcntl(stdin_fd, F_SETFL, flags | O_NONBLOCK);
    defer _ = std.posix.system.fcntl(stdin_fd, F_SETFL, flags);

    // Try to read - if nothing there (EAGAIN), it's just ESC
    const result = std.posix.system.read(stdin_fd, &temp_buf, temp_buf.len);
    if (result <= 0) {
        // Bare Esc. In reverse-i-search this MUST cancel the search — the
        // search_mode check in readNextAction sits after the \x1b interception,
        // so getSearchModeAction never sees Esc. Returning set_mode=.normal here
        // would flip vim_mode while leaving search_mode set, and every following
        // key would still route to the search handler (stuck-in-search loop).
        if (self.search_mode) return .{ .exit_search_mode = false };
        return .{ .vim_mode = .{ .set_mode = .normal } };
    }
    const bytes_read: usize = @intCast(result);

    if (temp_buf[0] != '[') {
        // Alt+key: look up in keybindings table
        if (self.keybindings.lookupAlt(temp_buf[0])) |action| return action;
        if (self.search_mode) return .{ .exit_search_mode = false };
        return .{ .vim_mode = .{ .set_mode = .normal } };
    }

    // Need at least 2 bytes for a valid escape sequence
    // If incomplete, treat as just ESC (vim normal mode)
    if (bytes_read < 2) {
        if (self.search_mode) return .{ .exit_search_mode = false };
        return .{ .vim_mode = .{ .set_mode = .normal } };
    }

    const cmd_byte = temp_buf[1];

    return switch (cmd_byte) {
        'A' => .{ .history_nav = .up }, // Up arrow
        'B' => .{ .history_nav = .down }, // Down arrow
        'C' => .{ .move_cursor = .{ .relative = 1 } }, // Right arrow
        'D' => .{ .move_cursor = .{ .relative = -1 } }, // Left arrow
        'Z' => .{ .cycle_complete = .backward }, // Shift+Tab
        'H' => .{ .move_cursor = .to_line_start }, // Home key
        'F' => .{ .move_cursor = .to_line_end }, // End key
        '1' => try handleExtendedEscapeSequence(stdin_fd, flags), // Ctrl+arrows, Home, End
        '2' => try handleBracketedPaste(stdin_fd, flags), // Bracketed paste
        '3' => try readTildeSequence(stdin_fd, flags, .{ .delete = .char_under_cursor }), // Delete key
        '4' => try readTildeSequence(stdin_fd, flags, .{ .move_cursor = .to_line_end }), // End key
        '7' => try readTildeSequence(stdin_fd, flags, .{ .move_cursor = .to_line_start }), // Home key
        '8' => try readTildeSequence(stdin_fd, flags, .{ .move_cursor = .to_line_end }), // End key
        '?' => { consumeEscapeSequence(stdin_fd); return .none; }, // DA response, consume and ignore
        else => .none,
    };
}

/// consume remaining bytes of an escape sequence until terminator (letter or ~)
fn consumeEscapeSequence(stdin_fd: posix.fd_t) void {
    var buf: [1]u8 = undefined;
    var iterations: u8 = 0;
    while (iterations < 32) : (iterations += 1) {
        const n = std.posix.system.read(stdin_fd, &buf, 1);
        if (n <= 0) break;
        const c = buf[0];
        // escape sequences end with a letter or ~
        if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '~') break;
    }
}

fn readTildeSequence(stdin_fd: posix.fd_t, flags: usize, action: Action) !Action {
    var buf: [1]u8 = undefined;
    const result = std.posix.system.read(stdin_fd, &buf, 1);
    if (result <= 0) return .none;
    if (buf[0] == '~') return action;
    _ = flags;
    return .none;
}

fn handleExtendedEscapeSequence(stdin_fd: posix.fd_t, flags: usize) !Action {
    var temp_buf: [1]u8 = undefined;
    _ = flags;

    // Read the next character (semicolon or tilde)
    var result = std.posix.system.read(stdin_fd, &temp_buf, 1);
    if (result <= 0) return .none;

    const semicolon = temp_buf[0];

    // handle ESC[1~ (Home key in some terminals)
    if (semicolon == '~') {
        return .{ .move_cursor = .to_line_start };
    }

    // expect semicolon for modified keys
    if (semicolon != ';') {
        // Not a modifier sequence — could be ESC[15~ (F5) etc.
        // Consume until we hit a letter or ~ to drain the sequence
        if (semicolon >= '0' and semicolon <= '9') {
            while (true) {
                result = std.posix.system.read(stdin_fd, &temp_buf, 1);
                if (result <= 0) break;
                if (temp_buf[0] == '~' or (temp_buf[0] >= 'A' and temp_buf[0] <= 'Z')) break;
                if (temp_buf[0] >= 'a' and temp_buf[0] <= 'z') break;
            }
        }
        return .none;
    }

    // read modifier: 2=Shift, 3=Alt, 5=Ctrl, 6=Ctrl+Shift, etc.
    result = std.posix.system.read(stdin_fd, &temp_buf, 1);
    if (result <= 0) return .none;
    const modifier = temp_buf[0];

    // read direction key (always consume to prevent stray bytes)
    result = std.posix.system.read(stdin_fd, &temp_buf, 1);
    if (result <= 0) return .none;

    if (modifier == '5' or modifier == '6') {
        // Ctrl (or Ctrl+Shift)
        return switch (temp_buf[0]) {
            'C' => .{ .move_cursor = .{ .word_forward = .WORD } },      // Ctrl+Right
            'D' => .{ .move_cursor = .{ .word_backward = .WORD } },     // Ctrl+Left
            'A' => .{ .move_cursor = .to_line_start },                   // Ctrl+Up
            'B' => .{ .move_cursor = .to_line_end },                     // Ctrl+Down
            'H' => .{ .move_cursor = .to_line_start },                   // Ctrl+Home
            'F' => .{ .move_cursor = .to_line_end },                     // Ctrl+End
            else => .none,
        };
    } else if (modifier == '2') {
        // Shift
        return switch (temp_buf[0]) {
            'C' => .{ .move_cursor = .{ .relative = 1 } },
            'D' => .{ .move_cursor = .{ .relative = -1 } },
            'A' => .{ .history_nav = .up },
            'B' => .{ .history_nav = .down },
            else => .none,
        };
    } else if (modifier == '3') {
        // Alt — cycle ghost text candidates
        return switch (temp_buf[0]) {
            'A' => .{ .cycle_ghost = .backward },    // Alt+Up
            'B' => .{ .cycle_ghost = .forward },     // Alt+Down
            else => .none,
        };
    } else {
        // Unknown modifier — consume and ignore
        return .none;
    }
}

fn handleBracketedPaste(stdin_fd: posix.fd_t, flags: usize) !Action {
    _ = flags;

    // Sequence is ESC[200~ or ESC[201~
    // We've already read ESC[2, now read the rest: '0', '0'/'1', '~'

    var buf: [3]u8 = undefined;
    const result = std.posix.system.read(stdin_fd, &buf, 3);
    if (result < 3) return .none;

    // First char should be '0'
    if (buf[0] != '0') return .none;
    // Third char should be '~'
    if (buf[2] != '~') return .none;

    // Check for '0~' (paste start: 200~) or '1~' (paste end: 201~)
    return switch (buf[1]) {
        '0' => .enter_paste_mode,
        '1' => .exit_paste_mode,
        else => .none,
    };
}

fn getSearchModeAction(self: *Shell, char: u8) Action {
    return switch (char) {
        '\n' => .{ .exit_search_mode = true },
        '\x1b' => .{ .exit_search_mode = false },
        8, 127 => blk: {
            if (self.search_len > 0) {
                break :blk .backspace;
            }
            break :blk .none;
        },
        32...126 => .{ .input_char = char },
        else => .none,
    };
}

pub fn enableRawMode(self: *Shell) !void {
    const stdin_fd = posix.STDIN_FILENO;

    // use saved original if available (prevents child processes from
    // corrupting our terminal state), otherwise read current state
    var termios = if (self.original_termios) |orig|
        orig
    else blk: {
        const current = posix.tcgetattr(stdin_fd) catch return;
        self.original_termios = current;
        break :blk current;
    };

    // modify terminal attributes for raw mode
    // disable canonical mode and echo
    termios.lflag.ICANON = false;
    termios.lflag.ECHO = false;
    termios.lflag.ISIG = false; // disable ctrl+c/ctrl+z signals

    // disable input translations (ICRNL translates CR to NL, breaking Enter/Ctrl+J distinction)
    termios.iflag.ICRNL = false;
    termios.iflag.IXON = false; // disable Ctrl+S/Ctrl+Q flow control

    // set minimum characters to read and timeout
    termios.cc[@intFromEnum(posix.V.MIN)] = 1; // read 1 char at a time
    termios.cc[@intFromEnum(posix.V.TIME)] = 0; // no timeout

    // apply the changes
    posix.tcsetattr(stdin_fd, .NOW, termios) catch return;

    // enable bracketed paste mode (write to stderr to avoid capture by redirects)
    _ = posix.write(posix.STDERR_FILENO, "\x1b[?2004h") catch {};
}

pub fn disableRawMode(self: *Shell) void {
    // disable bracketed paste mode (write to stderr to avoid capture by redirects)
    _ = posix.write(posix.STDERR_FILENO, "\x1b[?2004l") catch {};

    if (self.original_termios) |original| {
        const stdin_fd = posix.STDIN_FILENO;
        posix.tcsetattr(stdin_fd, .NOW, original) catch {};
    }
}

fn handleHistoryNavigation(self: *Shell, direction: HistoryDirection) !void {
    const h = self.history orelse return;

    switch (direction) {
        .up => {
            // Save current command if we're starting history navigation
            if (self.history_index == -1) {
                self.history_index = @intCast(h.entries.items.len);
                // Save prefix for prefix-based search
                self.history_search_prefix_len = self.edit_buf.len;
            }

            // Move up in history with optional prefix filtering
            if (self.history_index > 0) {
                if (self.history_search_prefix_len > 0) {
                    // Prefix search - find previous matching entry
                    const prefix = self.edit_buf.text[0..self.history_search_prefix_len];
                    var idx = self.history_index - 1;
                    while (idx >= 0) : (idx -= 1) {
                        const entry = h.entries.items[@intCast(idx)];
                        const cmd = h.getCommand(entry);
                        if (cmd.len >= prefix.len and std.mem.eql(u8, cmd[0..prefix.len], prefix)) {
                            self.history_index = idx;
                            try self.loadHistoryEntry(h);
                            break;
                        }
                        if (idx == 0) break;
                    }
                } else {
                    // No prefix - simple navigation
                    self.history_index -= 1;
                    try self.loadHistoryEntry(h);
                }
            }
        },
        .down => {
            // Can't go down if not in history navigation
            if (self.history_index == -1) return;

            if (self.history_search_prefix_len > 0) {
                // Prefix search - find next matching entry
                const prefix = self.edit_buf.text[0..self.history_search_prefix_len];
                var idx = self.history_index + 1;
                const max_idx: i32 = @intCast(h.entries.items.len);
                while (idx < max_idx) : (idx += 1) {
                    const entry = h.entries.items[@intCast(idx)];
                    const cmd = h.getCommand(entry);
                    if (cmd.len >= prefix.len and std.mem.eql(u8, cmd[0..prefix.len], prefix)) {
                        self.history_index = idx;
                        try self.loadHistoryEntry(h);
                        break;
                    }
                } else {
                    // No more matches - restore prefix
                    self.history_index = -1;
                    self.edit_buf.len = @intCast(self.history_search_prefix_len);
                    self.edit_buf.cursor = @intCast(self.history_search_prefix_len);
                                        self.history_search_prefix_len = 0;
                }
            } else {
                self.history_index += 1;

                // Reached the end - clear command (back to empty current line)
                if (self.history_index >= @as(i32, @intCast(h.entries.items.len))) {
                    self.history_index = -1;
                    self.clearCommand();
                } else {
                    try self.loadHistoryEntry(h);
                }
            }
        },
    }

    // Redraw the line with new content
    try self.renderLine();
}

fn loadHistoryEntry(self: *Shell, h: *hist.History) !void {
    const entry = h.entries.items[@intCast(self.history_index)];
    const history_cmd = h.getCommand(entry);

    // Force clear all owned rows before setting new content
    // This prevents stale wrapped lines when switching from long → short command
    if (self.term_view.term.rows_owned > 1) {
        const writer = self.stdout();
        // Move to start of our region
        if (self.term_view.term.row > 0) {
            writer.print("\x1b[{d}A", .{self.term_view.term.row}) catch {};
        }
        writer.writeAll("\r\x1b[J") catch {}; // clear from here to end of screen
        writer.flush() catch {}; // flush erase before stderr redraw
        self.term_view.term.row = 0;
        self.term_view.term.col = 0;
        self.term_view.last_hash = 0; // force full redraw
    }

    self.edit_buf.set(history_cmd);
    }

fn loadKeybindings(self: *Shell) void {
    var path_buf: [512]u8 = undefined;
    const home = compat.getEnvVarOwned(self.allocator, "HOME") catch return;
    defer self.allocator.free(home);
    const path = std.fmt.bufPrint(&path_buf, "{s}/.zish/keybindings.json", .{home}) catch return;
    self.keybindings = input_mod.KeyBindings.loadFromFile(path);
}

fn loadConfig(self: *Shell) !void {
    // get home directory
    const home = compat.getEnvVarOwned(self.allocator, "HOME") catch return;
    defer self.allocator.free(home);

    // construct ~/.zishrc path
    const config_path = try std.fmt.allocPrint(self.allocator, "{s}/.zishrc", .{home});
    defer self.allocator.free(config_path);

    // check if file exists
    std.Io.Dir.cwd().access(compat.io(), config_path, .{}) catch return;

    // source the config file using the source builtin
    const source_cmd = try std.fmt.allocPrint(self.allocator, "source {s}", .{config_path});
    defer self.allocator.free(source_cmd);

    _ = self.executeCommand(source_cmd) catch {};
}

pub fn executeCommand(self: *Shell, command: []const u8) !u8 {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    if (trimmed.len == 0) return 0;

    // Preprocess heredoc: convert << DELIM ... DELIM to file redirect
    const processed = if (findHeredocDelimiter(trimmed)) |delim|
        (if (heredocComplete(trimmed, delim))
            self.preprocessHeredoc(trimmed, delim) catch trimmed
        else
            trimmed)
    else
        trimmed;
    defer if (processed.ptr != trimmed.ptr) self.allocator.free(processed);

    const exit_code = try self.executeCommandInternal(processed);
    self.last_exit_code = exit_code;
    return exit_code;
}

/// Execute a trap handler for a signal
pub fn executeTrap(self: *Shell, sig: TrapTable.Signal) void {
    if (self.traps.get(sig)) |cmd| {
        if (cmd.len == 0) return; // empty string = ignore
        _ = self.executeCommand(cmd) catch {};
    }
}

/// Run EXIT trap (call before shell exits)
pub fn runExitTrap(self: *Shell) void {
    self.executeTrap(TrapTable.Signal.EXIT);
}

// ============ Array operations ============

/// Set array variable (replaces existing)
pub fn setArray(self: *Shell, name: []const u8, values: []const []const u8) !void {
    // remove existing array if present
    if (self.arrays.fetchRemove(name)) |old| {
        self.allocator.free(old.key);
        for (old.value.items) |elem| {
            self.allocator.free(elem);
        }
        // need mutable copy to call deinit
        var arr_copy = old.value;
        arr_copy.deinit(self.allocator);
    }

    // also remove from scalar variables (array shadows scalar)
    if (self.variables.fetchRemove(name)) |old| {
        self.allocator.free(old.key);
        self.allocator.free(old.value);
    }

    const name_copy = try self.allocator.dupe(u8, name);
    errdefer self.allocator.free(name_copy);

    var arr: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (arr.items) |elem| self.allocator.free(elem);
        arr.deinit(self.allocator);
    }

    for (values) |val| {
        try arr.append(self.allocator, try self.allocator.dupe(u8, val));
    }

    try self.arrays.put(name_copy, arr);
}

/// Get array element by index
pub fn getArrayElement(self: *Shell, name: []const u8, index: usize) ?[]const u8 {
    if (self.arrays.get(name)) |arr| {
        if (index < arr.items.len) {
            return arr.items[index];
        }
    }
    return null;
}

/// Get all array elements (for ${arr[@]} or ${arr[*]})
pub fn getArrayAll(self: *Shell, name: []const u8) ?[]const []const u8 {
    if (self.arrays.get(name)) |arr| {
        return arr.items;
    }
    return null;
}

/// Get array length (for ${#arr[@]})
pub fn getArrayLen(self: *Shell, name: []const u8) ?usize {
    if (self.arrays.get(name)) |arr| {
        return arr.items.len;
    }
    return null;
}

/// Set single array element
pub fn setArrayElement(self: *Shell, name: []const u8, index: usize, value: []const u8) !void {
    const arr_ptr = self.arrays.getPtr(name) orelse {
        // create new array with this element
        var arr: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (arr.items) |elem| self.allocator.free(elem);
            arr.deinit(self.allocator);
        }

        // extend to index with empty strings, then set the target element
        while (arr.items.len < index) {
            try arr.append(self.allocator, try self.allocator.dupe(u8, ""));
        }
        // append the actual value at index (not overwriting)
        try arr.append(self.allocator, try self.allocator.dupe(u8, value));

        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        try self.arrays.put(name_copy, arr);
        return;
    };

    // extend array if needed
    while (arr_ptr.items.len <= index) {
        try arr_ptr.append(self.allocator, try self.allocator.dupe(u8, ""));
    }

    // free old value and set new
    self.allocator.free(arr_ptr.items[index]);
    arr_ptr.items[index] = try self.allocator.dupe(u8, value);
}

/// Append to array (for arr+=(values))
pub fn appendArray(self: *Shell, name: []const u8, values: []const []const u8) !void {
    const arr_ptr = self.arrays.getPtr(name) orelse {
        // create new array
        return self.setArray(name, values);
    };

    for (values) |val| {
        try arr_ptr.append(self.allocator, try self.allocator.dupe(u8, val));
    }
}

/// Result of variable expansion - either borrowed (no alloc) or owned (needs free)
pub const ExpandResult = struct {
    slice: []const u8,
    owned: bool,

    pub fn deinit(self: ExpandResult, allocator: std.mem.Allocator) void {
        if (self.owned) {
            allocator.free(self.slice);
        }
    }
};

/// Expand variables without allocation when possible
// Expansion character lookup table - SectorLambda-inspired
const expansion_char_table: [256]bool = blk: {
    var table = [_]bool{false} ** 256;
    table['$'] = true;
    table['`'] = true;
    // Escaped-literal sentinels (from the lexer) must not take the no-op fast path;
    // they need converting back to '$' / '`' during expansion.
    table[lexer.LIT_DOLLAR] = true;
    table[lexer.LIT_BACKTICK] = true;
    break :blk table;
};

pub fn expandVariablesZ(self: *Shell, input: []const u8) !ExpandResult {
    // Fast path: if no special chars, return slice directly (no alloc!)
    if (input.len > 0 and input[0] == '~') {
        // Tilde needs expansion
    } else {
        // Single pass check using lookup table
        var needs_expansion = false;
        for (input) |c| {
            if (expansion_char_table[c]) {
                needs_expansion = true;
                break;
            }
        }
        if (!needs_expansion) {
            return .{ .slice = input, .owned = false };
        }
    }

    // Need expansion - allocate
    const expanded = try self.expandVariablesAllocOpt(input, true);
    return .{ .slice = expanded, .owned = true };
}

/// Like expandVariablesZ but never performs tilde expansion (for content
/// inside double quotes, where bash leaves '~' literal).
pub fn expandVariablesNoTildeZ(self: *Shell, input: []const u8) !ExpandResult {
    var needs_expansion = false;
    for (input) |c| {
        if (expansion_char_table[c]) {
            needs_expansion = true;
            break;
        }
    }
    if (!needs_expansion) {
        return .{ .slice = input, .owned = false };
    }
    const expanded = try self.expandVariablesAllocOpt(input, false);
    return .{ .slice = expanded, .owned = true };
}

pub fn expandVariables(self: *Shell, input: []const u8) ![]const u8 {
    // Legacy API - always returns owned slice for compatibility
    // Use lookup table for fast check
    if (input.len == 0 or input[0] != '~') {
        var needs_expansion = false;
        for (input) |c| {
            if (expansion_char_table[c]) {
                needs_expansion = true;
                break;
            }
        }
        if (!needs_expansion) {
            return try self.allocator.dupe(u8, input);
        }
    }

    return self.expandVariablesAllocOpt(input, true);
}

/// Append the positional parameters ($1, $2, ...) joined by a single space.
/// Used for unquoted $@ and $*; the count is tracked in the "#" variable.
fn appendPositionalParams(self: *Shell, result: *std.ArrayList(u8)) !void {
    const count_str = self.variables.get("#") orelse return;
    const count = std.fmt.parseInt(usize, count_str, 10) catch return;
    var idx: usize = 1;
    while (idx <= count) : (idx += 1) {
        var num_buf: [16]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{idx}) catch continue;
        if (self.variables.get(num_str)) |val| {
            if (idx > 1) try result.append(self.allocator, ' ');
            try result.appendSlice(self.allocator, val);
        }
    }
}

/// Resolve a tilde-prefix name (the text between '~' and the first '/') to a
/// home/directory path. Returns an owned allocation, or null when the prefix
/// is not a recognised tilde form (caller then leaves the '~' literal).
///   ""     -> $HOME
///   "+"    -> $PWD
///   "-"    -> $OLDPWD
///   "user" -> that user's home via getpwnam
fn tildePrefixHome(self: *Shell, name: []const u8) ?[]u8 {
    if (name.len == 0) {
        const home = compat.getEnvVarOwned(self.allocator, "HOME") catch return null;
        return home;
    }
    if (name.len == 1 and name[0] == '+') {
        if (self.getVarValue("PWD")) |pwd| return self.allocator.dupe(u8, pwd) catch null;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = compat.posix.getcwd(&buf) catch return null;
        return self.allocator.dupe(u8, cwd) catch null;
    }
    if (name.len == 1 and name[0] == '-') {
        const old = self.getVarValue("OLDPWD") orelse
            (compat.posix.getenv("OLDPWD") orelse return null);
        return self.allocator.dupe(u8, old) catch null;
    }
    // ~user via getpwnam
    var name_buf: [256]u8 = undefined;
    if (name.len >= name_buf.len) return null;
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;
    const pw = std.c.getpwnam(name_buf[0..name.len :0]) orelse return null;
    const dir = pw.dir orelse return null;
    return self.allocator.dupe(u8, std.mem.sliceTo(dir, 0)) catch null;
}

fn getVarValue(self: *Shell, key: []const u8) ?[]const u8 {
    return self.variables.get(key);
}

fn expandVariablesAllocOpt(self: *Shell, input: []const u8, expand_tilde: bool) ![]const u8 {

    // Simple variable expansion - replace $VAR with variable value
    var result = try std.ArrayList(u8).initCapacity(self.allocator, input.len);
    defer result.deinit(self.allocator);

    var i: usize = 0;

    // Tilde expansion at start of input: ~ ~/ ~user ~+ ~-
    if (expand_tilde and input.len > 0 and input[0] == '~') {
        // the prefix runs to the first '/' (or end of word)
        const slash = std.mem.indexOfScalar(u8, input, '/') orelse input.len;
        const name = input[1..slash]; // text between '~' and '/'
        if (self.tildePrefixHome(name)) |home| {
            defer self.allocator.free(home);
            try result.appendSlice(self.allocator, home);
            i = slash; // continue after the prefix (keep the '/')
        }
    }

    while (i < input.len) {
        if (input[i] == '$' and i + 1 < input.len) {
            // Found variable expansion
            i += 1; // skip $

            // Handle special single-character variables first
            if (i < input.len and input[i] == '?') {
                var exit_code_buf: [8]u8 = undefined;
                const exit_code_str = std.fmt.bufPrint(&exit_code_buf, "{d}", .{self.last_exit_code}) catch "0";
                try result.appendSlice(self.allocator, exit_code_str);
                i += 1; // consume the ?
                continue;
            }

            // $# - number of positional parameters
            if (i < input.len and input[i] == '#') {
                const count = self.variables.get("#") orelse "0";
                try result.appendSlice(self.allocator, count);
                i += 1;
                continue;
            }

            // $@ and $* - all positional parameters joined with a space
            if (i < input.len and (input[i] == '@' or input[i] == '*')) {
                try self.appendPositionalParams(&result);
                i += 1;
                continue;
            }

            // $$ - shell process ID (temp-file idiom: /tmp/foo.$$)
            if (i < input.len and input[i] == '$') {
                var buf: [16]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{compat.posix.getpid()}) catch "0";
                try result.appendSlice(self.allocator, s);
                i += 1;
                continue;
            }

            // $! - PID of the most recent background command
            if (i < input.len and input[i] == '!') {
                if (self.last_bg_pid != 0) {
                    var buf: [16]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "{d}", .{self.last_bg_pid}) catch "";
                    try result.appendSlice(self.allocator, s);
                }
                i += 1;
                continue;
            }

            // Check for $((arithmetic)) first
            if (i + 1 < input.len and input[i] == '(' and input[i+1] == '(') {
                i += 2; // skip ((
                const expr_start = i;

                // Find matching ))
                var paren_count: u32 = 2;
                while (i < input.len and paren_count > 0) {
                    if (input[i] == '(') {
                        paren_count += 1;
                    } else if (input[i] == ')') {
                        paren_count -= 1;
                        if (paren_count == 0) break;
                    }
                    i += 1;
                }

                if (paren_count == 0) {
                    const expr = input[expr_start..i-1];
                    i += 1; // consume final ) (first one was consumed in loop)

                    // Evaluate arithmetic expression
                    const arith_result = try self.evaluateArithmetic(expr);
                    var buf: [32]u8 = undefined;
                    const result_str = std.fmt.bufPrint(&buf, "{d}", .{arith_result}) catch "0";
                    try result.appendSlice(self.allocator, result_str);
                    continue;
                }
            }

            // Handle command substitution $(command)
            if (i < input.len and input[i] == '(') {
                i += 1; // skip (
                const cmd_start = i;

                // Find matching closing paren
                var paren_count: u32 = 1;
                while (i < input.len and paren_count > 0) {
                    switch (input[i]) {
                        '(' => paren_count += 1,
                        ')' => paren_count -= 1,
                        else => {},
                    }
                    if (paren_count > 0) i += 1;
                }

                if (paren_count == 0) {
                    const command = input[cmd_start..i];
                    i += 1; // consume )

                    // Execute command and capture output
                    const cmd_output = self.executeCommandAndCapture(command) catch "";
                    defer if (cmd_output.len > 0) self.allocator.free(cmd_output);
                    try result.appendSlice(self.allocator, std.mem.trimEnd(u8, cmd_output, "\n\r"));
                    continue;
                } else {
                    // Unmatched parens, treat as regular text
                    try result.append(self.allocator, '$');
                    try result.append(self.allocator, '(');
                    i = cmd_start;
                    continue;
                }
            }

            // Handle ${VAR} and ${VAR:-default} syntax
            if (i < input.len and input[i] == '{') {
                i += 1; // skip {

                // Check for ${#VAR} or ${#arr[@]} length expansion
                if (i < input.len and input[i] == '#') {
                    i += 1; // skip #
                    const name_start = i;
                    while (i < input.len and input[i] != '}') {
                        i += 1;
                    }
                    const var_name = input[name_start..i];
                    if (i < input.len and input[i] == '}') i += 1;

                    // ${#} is the positional-parameter count ($#), not a length.
                    if (var_name.len == 0) {
                        const count = self.variables.get("#") orelse "0";
                        try result.appendSlice(self.allocator, count);
                        continue;
                    }

                    var var_len: usize = 0;

                    // check for array length: ${#arr[@]} or ${#arr[*]}
                    if (std.mem.endsWith(u8, var_name, "[@]") or std.mem.endsWith(u8, var_name, "[*]")) {
                        const arr_name = var_name[0 .. var_name.len - 3];
                        if (self.getArrayLen(arr_name)) |len| {
                            var_len = len;
                        }
                    } else if (std.mem.indexOfScalar(u8, var_name, '[')) |bracket_pos| {
                        // ${#arr[n]} - length of element
                        const arr_name = var_name[0..bracket_pos];
                        if (std.mem.indexOfScalar(u8, var_name[bracket_pos..], ']')) |close_offset| {
                            const index_str = var_name[bracket_pos + 1 .. bracket_pos + close_offset];
                            const idx = std.fmt.parseInt(usize, index_str, 10) catch 0;
                            if (self.getArrayElement(arr_name, idx)) |elem| {
                                var_len = elem.len;
                            }
                        }
                    } else {
                        // regular variable length
                        if (self.variables.get(var_name)) |value| {
                            var_len = value.len;
                        } else if (compat.getEnvVarOwned(self.allocator, var_name)) |val| {
                            var_len = val.len;
                            self.allocator.free(val);
                        } else |_| {}
                    }

                    var len_buf: [20]u8 = undefined;
                    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{var_len}) catch "0";
                    try result.appendSlice(self.allocator, len_str);
                    continue;
                }

                // ${@} and ${*} - all positional parameters
                if (i < input.len and (input[i] == '@' or input[i] == '*')) {
                    i += 1;
                    if (i < input.len and input[i] == '}') {
                        i += 1;
                        try self.appendPositionalParams(&result);
                        continue;
                    }
                    // Not a plain ${@}/${*}; rewind and fall through.
                    i -= 1;
                }

                const name_start = i;

                // Find end of variable name or modifier.
                // Stop at: } : - + ? = # % / ^ , (but not '[' so array subscripts stay
                // part of the name)
                while (i < input.len and input[i] != '}' and input[i] != ':' and
                    input[i] != '-' and input[i] != '+' and input[i] != '?' and
                    input[i] != '=' and input[i] != '#' and input[i] != '%' and
                    input[i] != '/' and input[i] != '^' and input[i] != ',')
                {
                    i += 1;
                }

                const var_name = input[name_start..i];

                // Look up variable value first (needed for all modifiers)
                var var_value: ?[]const u8 = null;
                var owned_value: ?[]const u8 = null;
                defer if (owned_value) |v| self.allocator.free(v);

                // check for array expansion: ${arr[@]} or ${arr[*]} or ${arr[n]}
                if (std.mem.endsWith(u8, var_name, "[@]") or std.mem.endsWith(u8, var_name, "[*]")) {
                    // expand all array elements
                    const arr_name = var_name[0 .. var_name.len - 3];
                    if (self.getArrayAll(arr_name)) |elements| {
                        // skip to closing brace
                        while (i < input.len and input[i] != '}') i += 1;
                        if (i < input.len and input[i] == '}') i += 1;

                        // join elements with spaces
                        for (elements, 0..) |elem, idx| {
                            if (idx > 0) try result.append(self.allocator, ' ');
                            try result.appendSlice(self.allocator, elem);
                        }
                        continue;
                    }
                } else if (std.mem.indexOfScalar(u8, var_name, '[')) |bracket_pos| {
                    // array element: ${arr[n]}
                    const arr_name = var_name[0..bracket_pos];
                    if (std.mem.indexOfScalar(u8, var_name[bracket_pos..], ']')) |close_offset| {
                        const index_str = var_name[bracket_pos + 1 .. bracket_pos + close_offset];
                        const idx = std.fmt.parseInt(usize, index_str, 10) catch 0;
                        if (self.getArrayElement(arr_name, idx)) |elem| {
                            var_value = elem;
                        }
                    }
                } else {
                    // regular scalar variable
                    if (self.variables.get(var_name)) |value| {
                        var_value = value;
                    } else {
                        const env_value = compat.getEnvVarOwned(self.allocator, var_name) catch null;
                        if (env_value) |val| {
                            owned_value = val;
                            var_value = val;
                        }
                    }
                }

                // Handle different modifiers
                if (i < input.len and input[i] == '#') {
                    // ${VAR#pattern} or ${VAR##pattern} - remove prefix
                    i += 1;
                    const greedy = i < input.len and input[i] == '#';
                    if (greedy) i += 1;

                    const pattern_start = i;
                    while (i < input.len and input[i] != '}') i += 1;
                    const pattern = input[pattern_start..i];
                    if (i < input.len and input[i] == '}') i += 1;

                    if (var_value) |v| {
                        const stripped = stripPrefix(v, pattern, greedy);
                        try result.appendSlice(self.allocator, stripped);
                    }
                } else if (i < input.len and input[i] == '%') {
                    // ${VAR%pattern} or ${VAR%%pattern} - remove suffix
                    i += 1;
                    const greedy = i < input.len and input[i] == '%';
                    if (greedy) i += 1;

                    const pattern_start = i;
                    while (i < input.len and input[i] != '}') i += 1;
                    const pattern = input[pattern_start..i];
                    if (i < input.len and input[i] == '}') i += 1;

                    if (var_value) |v| {
                        const stripped = stripSuffix(v, pattern, greedy);
                        try result.appendSlice(self.allocator, stripped);
                    }
                } else if (i < input.len and input[i] == '/') {
                    // ${VAR/pattern/replacement}   - replace first match
                    // ${VAR//pattern/replacement}  - replace all matches
                    // ${VAR/#pattern/replacement}  - anchor at start
                    // ${VAR/%pattern/replacement}  - anchor at end
                    i += 1;
                    const replace_all = i < input.len and input[i] == '/';
                    if (replace_all) i += 1;

                    var anchor: u8 = 0; // 0 = none, '#' = start, '%' = end
                    if (!replace_all and i < input.len and (input[i] == '#' or input[i] == '%')) {
                        anchor = input[i];
                        i += 1;
                    }

                    const pattern_start = i;
                    while (i < input.len and input[i] != '/' and input[i] != '}') i += 1;
                    const pattern = input[pattern_start..i];

                    var replacement: []const u8 = "";
                    if (i < input.len and input[i] == '/') {
                        i += 1;
                        const repl_start = i;
                        while (i < input.len and input[i] != '}') i += 1;
                        replacement = input[repl_start..i];
                    }
                    if (i < input.len and input[i] == '}') i += 1;

                    if (var_value) |v| {
                        const replaced = try patternReplaceAnchored(self.allocator, v, pattern, replacement, replace_all, anchor);
                        defer self.allocator.free(replaced);
                        try result.appendSlice(self.allocator, replaced);
                    }
                } else if (i < input.len and input[i] == ':' and isSubstringOffset(input[i + 1 ..])) {
                    // ${VAR:offset} or ${VAR:offset:length} - substring.
                    // Note: ${VAR:-x}, ${VAR:=x}, ${VAR:+x}, ${VAR:?x} are default/alt/assign/error
                    // operators, NOT substring; a negative offset must be written as `${VAR: -n}`
                    // (with a space) or `${VAR:(-n)}`.
                    i += 1;
                    // Skip optional leading whitespace before the offset expression.
                    while (i < input.len and (input[i] == ' ' or input[i] == '\t')) i += 1;
                    const offset = parseOffsetExpr(input, &i);

                    var length: ?i64 = null;
                    if (i < input.len and input[i] == ':') {
                        i += 1;
                        while (i < input.len and (input[i] == ' ' or input[i] == '\t')) i += 1;
                        length = parseOffsetExpr(input, &i);
                    }
                    if (i < input.len and input[i] == '}') i += 1;

                    if (var_value) |v| {
                        // Handle negative offset (from end).
                        var start: usize = 0;
                        if (offset < 0) {
                            const abs_offset: usize = @intCast(-offset);
                            start = if (abs_offset > v.len) 0 else v.len - abs_offset;
                        } else {
                            start = @min(@as(usize, @intCast(offset)), v.len);
                        }

                        var end = v.len;
                        if (length) |l| {
                            if (l < 0) {
                                // Negative length: offset from end of string.
                                const from_end: usize = @intCast(-l);
                                end = if (from_end > v.len) start else @max(start, v.len - from_end);
                            } else {
                                end = @min(start + @as(usize, @intCast(l)), v.len);
                            }
                        }
                        try result.appendSlice(self.allocator, v[start..end]);
                    }
                } else if (i < input.len and (input[i] == '^' or input[i] == ',')) {
                    // ${VAR^} ${VAR^^} ${VAR,} ${VAR,,} - case modification (bash).
                    const op = input[i];
                    i += 1;
                    const all = i < input.len and input[i] == op;
                    if (all) i += 1;
                    // Optional pattern (only the pattern's matching chars are converted); we
                    // support the common no-pattern form and treat any pattern as "match all".
                    while (i < input.len and input[i] != '}') i += 1;
                    if (i < input.len and input[i] == '}') i += 1;

                    if (var_value) |v| {
                        const upper = op == '^';
                        if (all) {
                            for (v) |ch| {
                                try result.append(self.allocator, if (upper) std.ascii.toUpper(ch) else std.ascii.toLower(ch));
                            }
                        } else {
                            for (v, 0..) |ch, idx| {
                                if (idx == 0) {
                                    try result.append(self.allocator, if (upper) std.ascii.toUpper(ch) else std.ascii.toLower(ch));
                                } else {
                                    try result.append(self.allocator, ch);
                                }
                            }
                        }
                    }
                } else {
                    // Original modifier handling: ${VAR:-default}, ${VAR:+alt}, ${VAR:?error}
                    var modifier: u8 = 0;
                    var has_colon = false;
                    var default_value: []const u8 = "";

                    if (i < input.len and input[i] == ':') {
                        has_colon = true;
                        i += 1;
                    }

                    if (i < input.len and (input[i] == '-' or input[i] == '+' or input[i] == '?' or input[i] == '=')) {
                        modifier = input[i];
                        i += 1;

                        // Find the default/alternate value up to closing }
                        const val_start = i;
                        var brace_depth: u32 = 1;
                        while (i < input.len and brace_depth > 0) {
                            if (input[i] == '{') brace_depth += 1;
                            if (input[i] == '}') brace_depth -= 1;
                            if (brace_depth > 0) i += 1;
                        }
                        default_value = input[val_start..i];
                    }

                    // Skip closing }
                    if (i < input.len and input[i] == '}') i += 1;

                    // Apply modifier
                    const is_set = var_value != null;
                    const is_empty = if (var_value) |v| v.len == 0 else true;
                    const use_default = if (has_colon) !is_set or is_empty else !is_set;

                    switch (modifier) {
                        '-' => {
                            // ${VAR:-default} or ${VAR-default}
                            if (use_default) {
                                // Recursively expand the default value
                                const expanded_default = try self.expandVariablesAllocOpt(default_value, true);
                                defer self.allocator.free(expanded_default);
                                try result.appendSlice(self.allocator, expanded_default);
                            } else if (var_value) |v| {
                                try result.appendSlice(self.allocator, v);
                            }
                        },
                        '+' => {
                            // ${VAR:+alternate} or ${VAR+alternate}
                            if (!use_default) {
                                const expanded_alt = try self.expandVariablesAllocOpt(default_value, true);
                                defer self.allocator.free(expanded_alt);
                                try result.appendSlice(self.allocator, expanded_alt);
                            }
                        },
                        '=' => {
                            // ${VAR:=word} or ${VAR=word} - assign default if unset (or empty w/ colon)
                            if (use_default) {
                                const expanded_default = try self.expandVariablesAllocOpt(default_value, expand_tilde);
                                // Assign to the shell variable, then use it.
                                const name_copy = try self.allocator.dupe(u8, var_name);
                                if (self.variables.fetchRemove(name_copy)) |old| {
                                    self.allocator.free(old.key);
                                    self.allocator.free(old.value);
                                }
                                self.variables.put(name_copy, expanded_default) catch {
                                    self.allocator.free(name_copy);
                                    self.allocator.free(expanded_default);
                                };
                                try result.appendSlice(self.allocator, expanded_default);
                            } else if (var_value) |v| {
                                try result.appendSlice(self.allocator, v);
                            }
                        },
                        '?' => {
                            // ${VAR:?error} or ${VAR?error}
                            if (use_default) {
                                std.debug.print("zish: {s}: {s}\n", .{ var_name, if (default_value.len > 0) default_value else "parameter not set" });
                                return error.ParameterNotSet;
                            } else if (var_value) |v| {
                                try result.appendSlice(self.allocator, v);
                            }
                        },
                        else => {
                            // No modifier, just ${VAR}
                            if (var_value) |v| {
                                try result.appendSlice(self.allocator, v);
                            } else if (self.opt_nounset) {
                                std.debug.print("zish: {s}: unbound variable\n", .{var_name});
                                return error.UnboundVariable;
                            }
                        },
                    }
                }
            } else {
                // Simple $VAR without braces
                const name_start = i;
                // Find end of variable name (alphanumeric + underscore)
                while (i < input.len and (std.ascii.isAlphanumeric(input[i]) or input[i] == '_')) {
                    i += 1;
                }

                if (i > name_start) {
                    const var_name = input[name_start..i];

                    // Look up variable
                    if (self.variables.get(var_name)) |value| {
                        try result.appendSlice(self.allocator, value);
                    } else {
                        // Try environment variable
                        const env_value = compat.getEnvVarOwned(self.allocator, var_name) catch null;
                        if (env_value) |val| {
                            defer self.allocator.free(val);
                            try result.appendSlice(self.allocator, val);
                        } else if (self.opt_nounset) {
                            // nounset: error on unbound variable
                            std.debug.print("zish: {s}: unbound variable\n", .{var_name});
                            return error.UnboundVariable;
                        }
                        // If no variable found and nounset not set, leave empty
                    }
                } else {
                    // Just a lone $, keep it
                    try result.append(self.allocator, '$');
                }
            }
        } else if (input[i] == '`') {
            // Handle backtick command substitution
            i += 1; // skip `
            const cmd_start = i;

            // Find matching closing backtick
            while (i < input.len and input[i] != '`') {
                i += 1;
            }

            if (i < input.len) {
                const command = input[cmd_start..i];
                i += 1; // consume closing `

                // Execute command and capture output
                const cmd_output = self.executeCommandAndCapture(command) catch "";
                defer if (cmd_output.len > 0) self.allocator.free(cmd_output);
                try result.appendSlice(self.allocator, std.mem.trimEnd(u8, cmd_output, "\n\r"));
            } else {
                // Unmatched backtick, treat as regular text
                try result.append(self.allocator, '`');
                i = cmd_start;
            }
        } else if (input[i] == lexer.LIT_DOLLAR) {
            // Escaped '$' - emit literally, do not expand.
            try result.append(self.allocator, '$');
            i += 1;
        } else if (input[i] == lexer.LIT_BACKTICK) {
            // Escaped '`' - emit literally, do not run as command substitution.
            try result.append(self.allocator, '`');
            i += 1;
        } else {
            try result.append(self.allocator, input[i]);
            i += 1;
        }
    }

    return try result.toOwnedSlice(self.allocator);
}

pub fn evaluateArithmetic(self: *Shell, expr: []const u8) !i64 {
    var p = ArithParser{ .shell = self, .src = expr, .pos = 0 };
    p.skipSpace();
    if (p.pos >= p.src.len) return 0;
    const v = p.parseComma() catch |e| switch (e) {
        error.DivideByZero => return error.DivideByZero,
        else => return 0,
    };
    return v;
}

/// Recursive-descent integer arithmetic evaluator matching bash `$(( ))`
/// semantics: full C-style operator set and precedence, assignment (writes
/// back into shell variables), pre/post inc-dec, ternary, comma, and number
/// bases (0x.., 0.. octal, base#n). Bare identifiers resolve to shell
/// variables (recursively evaluated, undefined -> 0).
const ArithParser = struct {
    shell: *Shell,
    src: []const u8,
    pos: usize,

    const Error = error{ SyntaxError, DivideByZero, OutOfMemory };

    fn skipSpace(self: *ArithParser) void {
        while (self.pos < self.src.len and (self.src[self.pos] == ' ' or
            self.src[self.pos] == '\t' or self.src[self.pos] == '\n' or
            self.src[self.pos] == '\r')) self.pos += 1;
    }

    fn peek(self: *ArithParser) u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else 0;
    }
    fn peek2(self: *ArithParser) u8 {
        return if (self.pos + 1 < self.src.len) self.src[self.pos + 1] else 0;
    }

    // returns true and consumes if the next non-space chars match `s`
    fn eat(self: *ArithParser, s: []const u8) bool {
        self.skipSpace();
        if (self.pos + s.len <= self.src.len and std.mem.eql(u8, self.src[self.pos .. self.pos + s.len], s)) {
            self.pos += s.len;
            return true;
        }
        return false;
    }

    // level 0: comma operator (lowest precedence)
    fn parseComma(self: *ArithParser) Error!i64 {
        var v = try self.parseAssign();
        while (true) {
            self.skipSpace();
            if (self.peek() == ',') {
                self.pos += 1;
                v = try self.parseAssign();
            } else break;
        }
        return v;
    }

    // level 1: assignment (right-assoc). Detect an lvalue followed by an
    // assignment operator; otherwise fall through to ternary.
    fn parseAssign(self: *ArithParser) Error!i64 {
        const save = self.pos;
        self.skipSpace();
        const name_start = self.pos;
        if (self.readIdent()) |name| {
            self.skipSpace();
            const c = self.peek();
            const c2 = self.peek2();
            // plain '=' (but not '==')
            if (c == '=' and c2 != '=') {
                self.pos += 1;
                const rhs = try self.parseAssign();
                try self.storeVar(name, rhs);
                return rhs;
            }
            // compound: += -= *= /= %= &= |= ^= <<= >>=
            const compound: ?u8 = switch (c) {
                '+', '-', '*', '/', '%', '&', '|', '^' => if (c2 == '=') c else null,
                else => null,
            };
            if (compound) |op| {
                self.pos += 2;
                const rhs = try self.parseAssign();
                const cur = self.readVar(name);
                const res = try applyBinary(op, cur, rhs);
                try self.storeVar(name, res);
                return res;
            }
            if ((c == '<' and c2 == '<' and self.peekN(2) == '=') or
                (c == '>' and c2 == '>' and self.peekN(2) == '='))
            {
                const is_left = c == '<';
                self.pos += 3;
                const rhs = try self.parseAssign();
                const cur = self.readVar(name);
                const res = if (is_left) cur << @intCast(@as(u6, @truncate(@as(u64, @bitCast(rhs)))))
                else cur >> @intCast(@as(u6, @truncate(@as(u64, @bitCast(rhs)))));
                try self.storeVar(name, res);
                return res;
            }
            _ = name_start;
        }
        // not an assignment — rewind and parse a ternary
        self.pos = save;
        return self.parseTernary();
    }

    fn peekN(self: *ArithParser, n: usize) u8 {
        return if (self.pos + n < self.src.len) self.src[self.pos + n] else 0;
    }

    // level 2: ternary ?:
    fn parseTernary(self: *ArithParser) Error!i64 {
        const cond = try self.parseLogicalOr();
        self.skipSpace();
        if (self.peek() == '?') {
            self.pos += 1;
            const then_v = try self.parseAssign();
            self.skipSpace();
            if (self.peek() != ':') return error.SyntaxError;
            self.pos += 1;
            const else_v = try self.parseAssign();
            return if (cond != 0) then_v else else_v;
        }
        return cond;
    }

    fn parseLogicalOr(self: *ArithParser) Error!i64 {
        var v = try self.parseLogicalAnd();
        while (self.eat("||")) {
            const r = try self.parseLogicalAnd();
            v = if (v != 0 or r != 0) 1 else 0;
        }
        return v;
    }
    fn parseLogicalAnd(self: *ArithParser) Error!i64 {
        var v = try self.parseBitOr();
        while (self.eat("&&")) {
            const r = try self.parseBitOr();
            v = if (v != 0 and r != 0) 1 else 0;
        }
        return v;
    }
    fn parseBitOr(self: *ArithParser) Error!i64 {
        var v = try self.parseBitXor();
        while (true) {
            self.skipSpace();
            if (self.peek() == '|' and self.peek2() != '|') {
                self.pos += 1;
                v |= try self.parseBitXor();
            } else break;
        }
        return v;
    }
    fn parseBitXor(self: *ArithParser) Error!i64 {
        var v = try self.parseBitAnd();
        while (true) {
            self.skipSpace();
            if (self.peek() == '^') {
                self.pos += 1;
                v ^= try self.parseBitAnd();
            } else break;
        }
        return v;
    }
    fn parseBitAnd(self: *ArithParser) Error!i64 {
        var v = try self.parseEquality();
        while (true) {
            self.skipSpace();
            if (self.peek() == '&' and self.peek2() != '&') {
                self.pos += 1;
                v &= try self.parseEquality();
            } else break;
        }
        return v;
    }
    fn parseEquality(self: *ArithParser) Error!i64 {
        var v = try self.parseRelational();
        while (true) {
            if (self.eat("==")) {
                v = if (v == try self.parseRelational()) 1 else 0;
            } else if (self.eat("!=")) {
                v = if (v != try self.parseRelational()) 1 else 0;
            } else break;
        }
        return v;
    }
    fn parseRelational(self: *ArithParser) Error!i64 {
        var v = try self.parseShift();
        while (true) {
            if (self.eat("<=")) {
                v = if (v <= try self.parseShift()) 1 else 0;
            } else if (self.eat(">=")) {
                v = if (v >= try self.parseShift()) 1 else 0;
            } else if (self.peek() == '<' and self.peek2() != '<') {
                self.pos += 1;
                v = if (v < try self.parseShift()) 1 else 0;
            } else if (self.peek() == '>' and self.peek2() != '>') {
                self.pos += 1;
                v = if (v > try self.parseShift()) 1 else 0;
            } else break;
        }
        return v;
    }
    fn parseShift(self: *ArithParser) Error!i64 {
        var v = try self.parseAdditive();
        while (true) {
            if (self.eat("<<")) {
                const r = try self.parseAdditive();
                v <<= @intCast(@as(u6, @truncate(@as(u64, @bitCast(r)))));
            } else if (self.eat(">>")) {
                const r = try self.parseAdditive();
                v >>= @intCast(@as(u6, @truncate(@as(u64, @bitCast(r)))));
            } else break;
        }
        return v;
    }
    fn parseAdditive(self: *ArithParser) Error!i64 {
        var v = try self.parseMultiplicative();
        while (true) {
            self.skipSpace();
            const c = self.peek();
            if (c == '+' and self.peek2() != '+') {
                self.pos += 1;
                v +%= try self.parseMultiplicative();
            } else if (c == '-' and self.peek2() != '-') {
                self.pos += 1;
                v -%= try self.parseMultiplicative();
            } else break;
        }
        return v;
    }
    fn parseMultiplicative(self: *ArithParser) Error!i64 {
        var v = try self.parsePower();
        while (true) {
            self.skipSpace();
            const c = self.peek();
            if (c == '*' and self.peek2() != '*') {
                self.pos += 1;
                v *%= try self.parsePower();
            } else if (c == '/') {
                self.pos += 1;
                const r = try self.parsePower();
                if (r == 0) return error.DivideByZero;
                v = @divTrunc(v, r);
            } else if (c == '%') {
                self.pos += 1;
                const r = try self.parsePower();
                if (r == 0) return error.DivideByZero;
                v = @rem(v, r);
            } else break;
        }
        return v;
    }
    // exponentiation (right-assoc, higher than unary in bash)
    fn parsePower(self: *ArithParser) Error!i64 {
        const base = try self.parseUnary();
        if (self.eat("**")) {
            const exp = try self.parsePower();
            return ipow(base, exp);
        }
        return base;
    }
    fn parseUnary(self: *ArithParser) Error!i64 {
        self.skipSpace();
        const c = self.peek();
        if (c == '+' and self.peek2() != '+') {
            self.pos += 1;
            return self.parseUnary();
        }
        if (c == '-' and self.peek2() != '-') {
            self.pos += 1;
            return -%(try self.parseUnary());
        }
        if (c == '!') {
            self.pos += 1;
            return if ((try self.parseUnary()) == 0) 1 else 0;
        }
        if (c == '~') {
            self.pos += 1;
            return ~(try self.parseUnary());
        }
        // pre-increment / pre-decrement
        if (c == '+' and self.peek2() == '+') {
            self.pos += 2;
            self.skipSpace();
            const name = self.readIdent() orelse return error.SyntaxError;
            const nv = self.readVar(name) +% 1;
            try self.storeVar(name, nv);
            return nv;
        }
        if (c == '-' and self.peek2() == '-') {
            self.pos += 2;
            self.skipSpace();
            const name = self.readIdent() orelse return error.SyntaxError;
            const nv = self.readVar(name) -% 1;
            try self.storeVar(name, nv);
            return nv;
        }
        return self.parsePrimary();
    }
    fn parsePrimary(self: *ArithParser) Error!i64 {
        self.skipSpace();
        const c = self.peek();
        if (c == '(') {
            self.pos += 1;
            const v = try self.parseComma();
            self.skipSpace();
            if (self.peek() != ')') return error.SyntaxError;
            self.pos += 1;
            return v;
        }
        if (std.ascii.isDigit(c)) {
            return self.parseNumber();
        }
        if (std.ascii.isAlphabetic(c) or c == '_') {
            const name = self.readIdent() orelse return error.SyntaxError;
            // post-increment / post-decrement
            self.skipSpace();
            if (self.peek() == '+' and self.peek2() == '+') {
                self.pos += 2;
                const old = self.readVar(name);
                try self.storeVar(name, old +% 1);
                return old;
            }
            if (self.peek() == '-' and self.peek2() == '-') {
                self.pos += 2;
                const old = self.readVar(name);
                try self.storeVar(name, old -% 1);
                return old;
            }
            return self.readVar(name);
        }
        return error.SyntaxError;
    }

    fn parseNumber(self: *ArithParser) Error!i64 {
        const start = self.pos;
        // hex / explicit octal 0x / 0 prefix
        if (self.peek() == '0' and (self.peek2() == 'x' or self.peek2() == 'X')) {
            self.pos += 2;
            const ds = self.pos;
            while (self.pos < self.src.len and std.ascii.isHex(self.src[self.pos])) self.pos += 1;
            return std.fmt.parseInt(i64, self.src[ds..self.pos], 16) catch error.SyntaxError;
        }
        // read a run of alphanumerics (covers decimal, octal, and base#digits)
        while (self.pos < self.src.len and (std.ascii.isAlphanumeric(self.src[self.pos]) or self.src[self.pos] == '#')) {
            self.pos += 1;
        }
        const tok = self.src[start..self.pos];
        if (std.mem.indexOfScalar(u8, tok, '#')) |h| {
            const base = std.fmt.parseInt(u8, tok[0..h], 10) catch return error.SyntaxError;
            if (base < 2 or base > 36) return error.SyntaxError;
            return parseInBase(tok[h + 1 ..], base) catch error.SyntaxError;
        }
        if (tok.len > 1 and tok[0] == '0') {
            return std.fmt.parseInt(i64, tok[1..], 8) catch error.SyntaxError;
        }
        return std.fmt.parseInt(i64, tok, 10) catch error.SyntaxError;
    }

    fn readIdent(self: *ArithParser) ?[]const u8 {
        self.skipSpace();
        const start = self.pos;
        if (self.pos >= self.src.len) return null;
        if (!(std.ascii.isAlphabetic(self.src[self.pos]) or self.src[self.pos] == '_')) return null;
        self.pos += 1;
        while (self.pos < self.src.len and (std.ascii.isAlphanumeric(self.src[self.pos]) or self.src[self.pos] == '_')) {
            self.pos += 1;
        }
        return self.src[start..self.pos];
    }

    fn readVar(self: *ArithParser, name: []const u8) i64 {
        const val = self.shell.variables.get(name) orelse
            (compat.posix.getenv(name) orelse return 0);
        // bash: variable value is itself an arithmetic expression
        return self.shell.evaluateArithmetic(val) catch 0;
    }

    fn storeVar(self: *ArithParser, name: []const u8, value: i64) Error!void {
        var buf: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
        if (self.shell.variables.getPtr(name)) |ptr| {
            self.shell.allocator.free(ptr.*);
            ptr.* = try self.shell.allocator.dupe(u8, s);
        } else {
            const nk = try self.shell.allocator.dupe(u8, name);
            const nv = try self.shell.allocator.dupe(u8, s);
            try self.shell.variables.put(nk, nv);
        }
    }
};

fn applyBinary(op: u8, a: i64, b: i64) ArithParser.Error!i64 {
    return switch (op) {
        '+' => a +% b,
        '-' => a -% b,
        '*' => a *% b,
        '/' => if (b == 0) error.DivideByZero else @divTrunc(a, b),
        '%' => if (b == 0) error.DivideByZero else @rem(a, b),
        '&' => a & b,
        '|' => a | b,
        '^' => a ^ b,
        else => error.SyntaxError,
    };
}

fn ipow(base: i64, exp: i64) i64 {
    if (exp < 0) return 0; // integer arithmetic: negative exponent -> 0
    var result: i64 = 1;
    var b = base;
    var e = exp;
    while (e > 0) : (e >>= 1) {
        if (e & 1 == 1) result *%= b;
        b *%= b;
    }
    return result;
}

fn parseInBase(digits: []const u8, base: u8) !i64 {
    var v: i64 = 0;
    for (digits) |c| {
        const d: i64 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'z' => c - 'a' + 10,
            'A'...'Z' => c - 'A' + 10,
            '@' => 62,
            '_' => 63,
            else => return error.InvalidCharacter,
        };
        if (d >= base) return error.InvalidCharacter;
        v = v * base + d;
    }
    return v;
}

fn executeCommandAndCapture(self: *Shell, command: []const u8) ![]const u8 {
    // Execute a command and capture its output using zish's own evaluator so
    // that shell-local variables, functions, nested substitutions and builtins
    // (echo, printf, ...) behave exactly as in an interactive session.
    const trimmed_cmd = std.mem.trim(u8, command, " \t\n\r");
    if (trimmed_cmd.len == 0) return self.allocator.dupe(u8, "");

    // pwd fast path (pure builtin, no output-affecting state)
    if (std.mem.eql(u8, trimmed_cmd, "pwd")) {
        var buf: [4096]u8 = undefined;
        const cwd = posix.getcwd(&buf) catch return self.allocator.dupe(u8, "");
        return self.allocator.dupe(u8, cwd);
    }

    return self.captureInternal(trimmed_cmd) catch
        self.executeExternalAndCapture(trimmed_cmd) catch
        self.allocator.dupe(u8, "");
}

/// Run a command through zish's own evaluator with stdout redirected to a pipe,
/// returning the captured output. stdout is restored afterwards.
fn captureInternal(self: *Shell, command: []const u8) ![]const u8 {
    const pipe_fds = try compat.posix.pipe();
    // pipe_fds[0] = read end, pipe_fds[1] = write end

    const stdout_backup = try compat.posix.dup(compat.posix.STDOUT_FILENO);
    defer compat.posix.close(stdout_backup);

    // Flush any pending buffered stdout before swapping the fd so it lands on
    // the terminal rather than in the captured buffer.
    self.stdout().flush() catch {};

    try compat.posix.dup2(pipe_fds[1], compat.posix.STDOUT_FILENO);
    compat.posix.close(pipe_fds[1]);

    // Drain the pipe on a background thread so large output can't deadlock by
    // filling the pipe buffer while the writer is still running.
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buffer.deinit(self.allocator);

    const Reader = struct {
        fn run(alloc: std.mem.Allocator, fd: compat.posix.fd_t, out: *std.ArrayListUnmanaged(u8)) void {
            var tmp: [4096]u8 = undefined;
            while (true) {
                const n = compat.posix.read(fd, &tmp) catch break;
                if (n == 0) break;
                out.appendSlice(alloc, tmp[0..n]) catch break;
            }
        }
    };
    const thread = std.Thread.spawn(.{}, Reader.run, .{ self.allocator, pipe_fds[0], &buffer }) catch {
        // Fall back to synchronous drain if a thread can't be spawned.
        _ = self.executeCommandInternal(command) catch {};
        self.stdout().flush() catch {};
        compat.posix.dup2(stdout_backup, compat.posix.STDOUT_FILENO) catch {};
        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = compat.posix.read(pipe_fds[0], &tmp) catch break;
            if (n == 0) break;
            buffer.appendSlice(self.allocator, tmp[0..n]) catch break;
        }
        compat.posix.close(pipe_fds[0]);
        return buffer.toOwnedSlice(self.allocator);
    };

    _ = self.executeCommandInternal(command) catch {};
    self.stdout().flush() catch {};

    // Restore stdout and close the write end so the reader sees EOF.
    compat.posix.dup2(stdout_backup, compat.posix.STDOUT_FILENO) catch {};

    thread.join();
    compat.posix.close(pipe_fds[0]);

    return buffer.toOwnedSlice(self.allocator);
}

fn executeExternalAndCapture(self: *Shell, command: []const u8) ![]const u8 {
    // Execute external command and capture output
    const result = try std.process.run(self.allocator, compat.io(), .{
        .argv = &[_][]const u8{ "/bin/sh", "-c", command },
        .stdout_limit = .limited(4096),
    });
    defer self.allocator.free(result.stderr);

    return result.stdout; // caller owns this memory
}

fn executeCommandInternal(self: *Shell, command: []const u8) !u8 {
    var cmd_parser = parser.Parser.init(command, self.allocator) catch |err| {
        try self.stdout().print("zish: parse error: {}\n", .{err});
        return 1;
    };
    defer cmd_parser.deinit();

    const ast_root = cmd_parser.parse() catch |err| {
        try self.stdout().print("zish: parse error: {}\n", .{err});
        return 1;
    };

    return eval.evaluateAst(self, ast_root);
}

fn executeExternal(self: *Shell, command: []const u8) !u8 {
    // tokenize command
    var lex = try lexer.Lexer.init(command);
    var tokens = try std.ArrayList([]const u8).initCapacity(self.allocator, 16);
    defer {
        // free all allocated token strings
        for (tokens.items) |token_str| {
            self.allocator.free(token_str);
        }
        tokens.deinit(self.allocator);
    }

    while (true) {
        const token = try lex.nextToken();
        if (token.ty == .Eof) break;
        if (token.ty == .Word or token.ty == .String) {
            // allocate separate storage for each token to avoid buffer reuse issues
            const owned_token = try self.allocator.dupe(u8, token.value);
            try tokens.append(self.allocator, owned_token);
        }
    }

    if (tokens.items.len == 0) return 1;

    // prepare args for exec with glob expansion
    var args = try std.ArrayList([]const u8).initCapacity(self.allocator, tokens.items.len);
    defer {
        for (args.items) |arg| {
            // Only free if it was allocated by glob expansion (not in tokens)
            var is_original = false;
            for (tokens.items) |tok| {
                if (arg.ptr == tok.ptr) {
                    is_original = true;
                    break;
                }
            }
            if (!is_original) self.allocator.free(arg);
        }
        args.deinit(self.allocator);
    }

    for (tokens.items) |token_val| {
        // Check if this looks like a glob pattern
        const has_glob = for (token_val) |c| {
            if (c == '*' or c == '?' or c == '[') break true;
        } else false;

        if (has_glob) {
            // Expand glob pattern
            const glob_results = glob.expandGlob(self.allocator, token_val) catch {
                // If glob fails, use literal
                try args.append(self.allocator, token_val);
                continue;
            };
            defer self.allocator.free(glob_results);

            if (glob_results.len == 0) {
                // No matches, use literal pattern
                try args.append(self.allocator, token_val);
            } else {
                // Add all glob matches
                for (glob_results) |match| {
                    try args.append(self.allocator, match);
                }
            }
        } else {
            try args.append(self.allocator, token_val);
        }
    }

    // execute with PATH resolution
    // restore terminal to normal mode so child can handle signals properly
    const is_tty = posix.isatty(posix.STDIN_FILENO);
    if (is_tty) {
        self.disableRawMode();
    }
    defer if (is_tty) {
        self.enableRawMode() catch {};
    };

    // spawn child first, THEN ignore SIGINT in parent
    // (child must not inherit SIG_IGN or it can't be interrupted)
    // environment is inherited from parent by default
    var child = std.process.spawn(compat.io(), .{
        .argv = args.items,
        .stdout = .inherit,
        .stderr = .inherit,
        .stdin = .inherit,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            try self.stdout().print("zish: {s}: command not found\n", .{args.items[0]});
            return 127;
        },
        else => return err,
    };

    // now ignore SIGINT in shell while child runs
    var old_sigint: posix.Sigaction = undefined;
    const ignore_action = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &ignore_action, &old_sigint);
    defer posix.sigaction(posix.SIG.INT, &old_sigint, null);

    const term = try child.wait(compat.io());
    return switch (term) {
        .exited => |code| code,
        .signal => |sig| @as(u8, @intCast(@intFromEnum(sig) + 128)),
        .stopped => |sig| @as(u8, @intCast(@intFromEnum(sig) + 128)),
        .unknown => |code| @as(u8, @intCast(code)),
    };
}

/// Find heredoc delimiter in command (e.g., << 'EOF' or << EOF or <<EOF)
fn findHeredocDelimiter(command: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < command.len) : (i += 1) {
        // look for << but not <<<
        if (command[i] == '<' and command[i + 1] == '<') {
            if (i + 2 < command.len and command[i + 2] == '<') {
                i += 2; // skip <<<
                continue;
            }
            // found <<, now parse delimiter
            var j = i + 2;
            // skip optional - for <<-
            if (j < command.len and command[j] == '-') j += 1;
            // skip whitespace
            while (j < command.len and (command[j] == ' ' or command[j] == '\t')) : (j += 1) {}
            if (j >= command.len) return null;

            // check for quoted delimiter
            const quote = command[j];
            if (quote == '\'' or quote == '"') {
                j += 1;
                const start = j;
                while (j < command.len and command[j] != quote) : (j += 1) {}
                if (j > start) return command[start..j];
            } else {
                // unquoted delimiter - word until whitespace/newline
                const start = j;
                while (j < command.len and command[j] != ' ' and command[j] != '\t' and command[j] != '\n') : (j += 1) {}
                if (j > start) return command[start..j];
            }
        }
    }
    return null;
}

/// Detect heredoc operator flags at position `pos` (which points at the first
/// '<' of a "<<"). Returns whether it is <<- (strip tabs) and whether the
/// delimiter was quoted (no expansion of the body).
const HeredocFlags = struct { dash: bool, quoted: bool };
fn heredocFlags(command: []const u8, pos: usize) HeredocFlags {
    var j = pos + 2;
    var dash = false;
    if (j < command.len and command[j] == '-') {
        dash = true;
        j += 1;
    }
    while (j < command.len and (command[j] == ' ' or command[j] == '\t')) : (j += 1) {}
    const quoted = j < command.len and (command[j] == '\'' or command[j] == '"');
    return .{ .dash = dash, .quoted = quoted };
}

/// Preprocess heredoc: convert "cmd << DELIM\ncontent\nDELIM" to "cmd < /tmp/zish_heredoc_XXXX"
fn preprocessHeredoc(self: *Shell, command: []const u8, delimiter: []const u8) ![]const u8 {
    const allocator = self.allocator;
    // Find << position
    var heredoc_pos: usize = 0;
    var i: usize = 0;
    while (i + 1 < command.len) : (i += 1) {
        if (command[i] == '<' and command[i + 1] == '<') {
            if (i + 2 < command.len and command[i + 2] == '<') {
                i += 2;
                continue;
            }
            heredoc_pos = i;
            break;
        }
    }

    const flags = heredocFlags(command, heredoc_pos);

    // Get part before <<
    const prefix = command[0..heredoc_pos];

    // Find where heredoc content starts (after newline following delimiter specification)
    var content_start: usize = heredoc_pos + 2;
    // skip past the delimiter specification to the newline
    while (content_start < command.len and command[content_start] != '\n') : (content_start += 1) {}
    if (content_start < command.len) content_start += 1; // skip the newline

    // Find where content ends (at delimiter line)
    // Scan line by line from content_start
    var content_end = content_start;
    var suffix_start: usize = command.len; // text after closing delimiter
    var found_delim = false;
    var line_start = content_start;
    while (line_start < command.len) {
        // find end of this line
        var line_end = line_start;
        while (line_end < command.len and command[line_end] != '\n') : (line_end += 1) {}

        // For <<- the closing delimiter may be preceded by tabs; otherwise it
        // must match exactly (POSIX: leading tabs stripped only with <<-).
        const raw_line = command[line_start..line_end];
        const cmp_line = if (flags.dash) std.mem.trimStart(u8, raw_line, "\t") else raw_line;
        if (std.mem.eql(u8, cmp_line, delimiter)) {
            // This line is the delimiter - content ends before this line
            content_end = line_start;
            found_delim = true;
            // remove trailing newline from content if present
            if (content_end > content_start and command[content_end - 1] == '\n') {
                content_end -= 1;
            }
            // suffix is everything after the delimiter line
            suffix_start = if (line_end < command.len) line_end + 1 else line_end;
            break;
        }

        // move to next line
        if (line_end < command.len) {
            line_start = line_end + 1;
        } else {
            break;
        }
    }

    // Handle case where no delimiter was found (shouldn't happen if heredocComplete returned true)
    if (!found_delim and content_start < command.len) {
        content_end = command.len;
    }

    var content = command[content_start..content_end];

    // <<- : strip leading tabs from every body line.
    var stripped_owned: ?[]u8 = null;
    defer if (stripped_owned) |s| allocator.free(s);
    if (flags.dash and content.len > 0) {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        var ls: usize = 0;
        while (ls <= content.len) {
            var le = ls;
            while (le < content.len and content[le] != '\n') : (le += 1) {}
            const l = std.mem.trimStart(u8, content[ls..le], "\t");
            try out.appendSlice(allocator, l);
            if (le < content.len) try out.append(allocator, '\n');
            if (le >= content.len) break;
            ls = le + 1;
        }
        stripped_owned = try out.toOwnedSlice(allocator);
        content = stripped_owned.?;
    }

    // Unquoted delimiter: expand variables and command substitutions in body.
    var expanded_owned: ?[]const u8 = null;
    defer if (expanded_owned) |e| allocator.free(e);
    if (!flags.quoted and content.len > 0) {
        expanded_owned = try self.expandVariables(content);
        content = expanded_owned.?;
    }

    const suffix = std.mem.trim(u8, command[suffix_start..], " \t\r\n");

    // Write content to a temp file. Salt the name with a monotonic counter so
    // chained heredocs processed within the same millisecond don't collide.
    const ts = compat.milliTimestamp();
    const S = struct {
        var seq: u32 = 0;
    };
    S.seq +%= 1;
    var path_buf: [80]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&path_buf, "/tmp/zish_heredoc_{d}_{d}", .{ ts, S.seq }) catch return error.OutOfMemory;

    const file = std.Io.Dir.createFileAbsolute(compat.io(), tmp_path, .{ .truncate = true }) catch return error.FileError;
    defer file.close(compat.io());
    compat.writeAll(file, content) catch return error.WriteError;
    compat.writeAll(file, "\n") catch return error.WriteError;

    // Build new command: prefix < /tmp/zish_heredoc_TS; suffix
    const need_suffix = suffix.len > 0;
    const total_len = prefix.len + 2 + tmp_path.len + if (need_suffix) 1 + suffix.len else 0;
    const result = try allocator.alloc(u8, total_len);
    var pos: usize = 0;
    @memcpy(result[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    @memcpy(result[pos..][0..2], "< ");
    pos += 2;
    @memcpy(result[pos..][0..tmp_path.len], tmp_path);
    pos += tmp_path.len;
    if (need_suffix) {
        result[pos] = '\n';
        pos += 1;
        @memcpy(result[pos..][0..suffix.len], suffix);
    }

    // The suffix may contain further heredocs (cat <<A ...; cat <<B ...).
    // Process them too by recursing on the rewritten command.
    if (need_suffix) {
        if (findHeredocDelimiter(result)) |next_delim| {
            defer allocator.free(result);
            return try self.preprocessHeredoc(result, next_delim);
        }
    }

    return result;
}

// limits to prevent pathological input from causing resource exhaustion
const BRACE_MAX_DEPTH: u8 = 10; // max nesting depth for brace expansion
const BRACE_MAX_RANGE: u32 = 10000; // max elements in a numeric range
const BRACE_MAX_RESULTS: u32 = 100000; // max total expansion results

/// Expand brace patterns like {a,b,c} and {1..5}
/// Returns array of expanded strings (caller owns memory)
/// An endpoint is "zero-padded" (bash sense) when its digit part after an
/// optional sign is >= 2 chars and starts with '0'.
fn braceIsPadded(s: []const u8) bool {
    var t = s;
    if (t.len > 0 and (t[0] == '-' or t[0] == '+')) t = t[1..];
    return t.len >= 2 and t[0] == '0';
}

/// bash pads a numeric range when either endpoint is zero-padded; the field
/// width is the widest raw endpoint (sign included). Returns 0 for no padding.
fn bracePadWidth(a: []const u8, b: []const u8) usize {
    const a_pad = braceIsPadded(a);
    const b_pad = braceIsPadded(b);
    if (!a_pad and !b_pad) return 0;
    return @max(a.len, b.len);
}

/// Format an integer into a field of `width` chars, zero-padded, with the sign
/// occupying one slot inside the width (bash: -05, 000, 005 all width 3).
fn formatPadded(buf: []u8, n: i64, width: usize) ![]const u8 {
    if (width == 0) return std.fmt.bufPrint(buf, "{d}", .{n});
    const neg = n < 0;
    const mag: u64 = if (neg) @intCast(-n) else @intCast(n);
    const digits = if (neg and width > 0) width - 1 else width;
    if (neg) {
        return std.fmt.bufPrint(buf, "-{d:0>[1]}", .{ mag, digits });
    } else {
        return std.fmt.bufPrint(buf, "{d:0>[1]}", .{ mag, digits });
    }
}

pub fn expandBraces(allocator: std.mem.Allocator, input: []const u8) ![][]const u8 {
    return expandBracesWithDepth(allocator, input, 0);
}

fn expandBracesWithDepth(allocator: std.mem.Allocator, input: []const u8, depth: u8) ![][]const u8 {
    // prevent stack overflow from deeply nested braces
    if (depth >= BRACE_MAX_DEPTH) {
        const result = try allocator.alloc([]const u8, 1);
        result[0] = try allocator.dupe(u8, input);
        return result;
    }

    // fast path: no braces
    if (std.mem.indexOfScalar(u8, input, '{') == null) {
        const result = try allocator.alloc([]const u8, 1);
        result[0] = try allocator.dupe(u8, input);
        return result;
    }

    // find the first complete brace group
    var brace_start: ?usize = null;
    var brace_end: ?usize = null;
    var brace_depth: u32 = 0;
    var has_comma_or_range = false;

    for (input, 0..) |c, i| {
        if (c == '{') {
            if (brace_depth == 0) brace_start = i;
            brace_depth += 1;
        } else if (c == '}') {
            if (brace_depth > 0) {
                brace_depth -= 1;
                if (brace_depth == 0) {
                    brace_end = i;
                    break;
                }
            }
        } else if (brace_depth == 1) {
            if (c == ',' or (c == '.' and i + 1 < input.len and input[i + 1] == '.')) {
                has_comma_or_range = true;
            }
        }
    }

    // no valid brace pattern found
    if (brace_start == null or brace_end == null or !has_comma_or_range) {
        const result = try allocator.alloc([]const u8, 1);
        result[0] = try allocator.dupe(u8, input);
        return result;
    }

    const start = brace_start.?;
    const end = brace_end.?;
    const prefix = input[0..start];
    const suffix = input[end + 1 ..];
    const brace_content = input[start + 1 .. end];

    // parse brace content
    var expansions: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (expansions.items) |exp| allocator.free(exp);
        expansions.deinit(allocator);
    }

    // check for range pattern like {1..5}, {1..10..2}, {a..z}, {z..a..2}
    if (std.mem.indexOf(u8, brace_content, "..")) |range_pos| {
        const range_start_str = brace_content[0..range_pos];
        const rest = brace_content[range_pos + 2 ..];

        // optional step: second ".." splits end from step
        var range_end_str = rest;
        var step_str: ?[]const u8 = null;
        if (std.mem.indexOf(u8, rest, "..")) |step_pos| {
            range_end_str = rest[0..step_pos];
            step_str = rest[step_pos + 2 ..];
        }

        // try numeric range
        if (std.fmt.parseInt(i64, range_start_str, 10)) |start_num| {
            if (std.fmt.parseInt(i64, range_end_str, 10)) |end_num| {
                // parse step magnitude (bash: sign of step is ignored, direction
                // is derived from the endpoints). Default step is 1.
                var step_mag: i64 = 1;
                if (step_str) |ss| {
                    if (std.fmt.parseInt(i64, ss, 10)) |sv| {
                        step_mag = if (sv < 0) -sv else sv;
                    } else |_| {}
                }
                if (step_mag == 0) step_mag = 1;

                // zero-padding: bash pads output to the widest endpoint when
                // either endpoint has a leading zero (after optional sign).
                const pad_width = bracePadWidth(range_start_str, range_end_str);

                const span: i64 = if (end_num >= start_num) end_num - start_num else start_num - end_num;
                const range_size: u64 = @as(u64, @intCast(@divFloor(span, step_mag))) + 1;
                if (range_size > BRACE_MAX_RANGE) {
                    const result = try allocator.alloc([]const u8, 1);
                    result[0] = try allocator.dupe(u8, input);
                    return result;
                }

                const step: i64 = if (start_num <= end_num) step_mag else -step_mag;
                var n = start_num;
                while (true) {
                    var buf: [32]u8 = undefined;
                    const num_str = formatPadded(&buf, n, pad_width) catch break;
                    try expansions.append(allocator, try allocator.dupe(u8, num_str));
                    // stop once we would pass end_num (step may overshoot)
                    if (step > 0) {
                        if (n + step > end_num) break;
                    } else {
                        if (n + step < end_num) break;
                    }
                    n += step;
                }
            } else |_| {}
        } else |_| {
            // character range (single-char endpoints)
            if (range_start_str.len == 1 and range_end_str.len == 1) {
                const start_char = range_start_str[0];
                const end_char = range_end_str[0];
                var step_mag: i32 = 1;
                if (step_str) |ss| {
                    if (std.fmt.parseInt(i32, ss, 10)) |sv| {
                        step_mag = if (sv < 0) -sv else sv;
                    } else |_| {}
                }
                if (step_mag == 0) step_mag = 1;
                const step: i32 = if (start_char <= end_char) step_mag else -step_mag;
                var c: i32 = start_char;
                while (true) {
                    try expansions.append(allocator, try allocator.dupe(u8, &[_]u8{@intCast(c)}));
                    if (step > 0) {
                        if (c + step > end_char) break;
                    } else {
                        if (c + step < end_char) break;
                    }
                    c += step;
                }
            }
        }
    }

    // if range didn't produce expansions, parse as comma-separated list
    if (expansions.items.len == 0) {
        var item_start: usize = 0;
        var item_depth: u32 = 0;
        for (brace_content, 0..) |c, i| {
            if (c == '{') {
                item_depth += 1;
            } else if (c == '}') {
                if (item_depth > 0) item_depth -= 1;
            } else if (c == ',' and item_depth == 0) {
                try expansions.append(allocator, try allocator.dupe(u8, brace_content[item_start..i]));
                item_start = i + 1;
            }
        }
        // last item
        try expansions.append(allocator, try allocator.dupe(u8, brace_content[item_start..]));
    }

    // build results with prefix and suffix, then recursively expand
    var results: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (results.items) |r| allocator.free(r);
        results.deinit(allocator);
    }

    for (expansions.items) |exp| {
        // build: prefix + exp + suffix
        const combined = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, exp, suffix });
        defer allocator.free(combined);

        // recursively expand any remaining braces (with depth tracking)
        const sub_results = try expandBracesWithDepth(allocator, combined, depth + 1);
        defer allocator.free(sub_results);

        for (sub_results) |sub| {
            // enforce total result limit
            if (results.items.len >= BRACE_MAX_RESULTS) {
                allocator.free(sub);
                continue;
            }
            try results.append(allocator, sub);
        }
    }

    // clear expansions without freeing (we already transferred ownership conceptually,
    // but the errdefer above handles cleanup, and we've moved strings to results)
    expansions.clearRetainingCapacity();

    return try results.toOwnedSlice(allocator);
}

/// Free brace expansion results
pub fn freeBraceResults(allocator: std.mem.Allocator, results: [][]const u8) void {
    for (results) |r| allocator.free(r);
    allocator.free(results);
}

/// Strip prefix from string using glob pattern matching
/// If greedy is true, removes longest match; otherwise removes shortest match
/// After a ':' in ${VAR:...}, decide whether it introduces a substring offset
/// rather than a default/alt/assign/error operator. `rest` is the text after the ':'.
/// Substring: digit, '(' (arithmetic), or whitespace (e.g. `${VAR: -1}`). A bare
/// leading '-'/'+'/'?'/'=' is an operator, not substring.
fn isSubstringOffset(rest: []const u8) bool {
    if (rest.len == 0) return false;
    const c = rest[0];
    if (std.ascii.isDigit(c)) return true;
    if (c == '(') return true;
    if (c == ' ' or c == '\t') return true;
    return false;
}

/// Parse a substring offset/length expression starting at input[i.*], advancing i.
/// Handles an optional '(' ... ')' arithmetic wrapper and a leading sign.
fn parseOffsetExpr(input: []const u8, i: *usize) i64 {
    var paren = false;
    if (i.* < input.len and input[i.*] == '(') {
        paren = true;
        i.* += 1;
        while (i.* < input.len and (input[i.*] == ' ' or input[i.*] == '\t')) i.* += 1;
    }
    const start = i.*;
    if (i.* < input.len and (input[i.*] == '-' or input[i.*] == '+')) i.* += 1;
    while (i.* < input.len and std.ascii.isDigit(input[i.*])) i.* += 1;
    const num_str = input[start..i.*];
    const val = std.fmt.parseInt(i64, num_str, 10) catch 0;
    if (paren) {
        while (i.* < input.len and input[i.*] != ')') i.* += 1;
        if (i.* < input.len and input[i.*] == ')') i.* += 1;
    }
    return val;
}

fn stripPrefix(str: []const u8, pattern: []const u8, greedy: bool) []const u8 {
    if (str.len == 0 or pattern.len == 0) return str;

    // For greedy, try matching from longest to shortest
    // For non-greedy, try matching from shortest to longest
    if (greedy) {
        var match_len = str.len;
        while (match_len > 0) : (match_len -= 1) {
            if (glob.matchGlob(pattern, str[0..match_len])) {
                return str[match_len..];
            }
        }
    } else {
        var match_len: usize = 1;
        while (match_len <= str.len) : (match_len += 1) {
            if (glob.matchGlob(pattern, str[0..match_len])) {
                return str[match_len..];
            }
        }
    }
    return str;
}

/// Strip suffix from string using glob pattern matching
/// If greedy is true, removes longest match; otherwise removes shortest match
fn stripSuffix(str: []const u8, pattern: []const u8, greedy: bool) []const u8 {
    if (str.len == 0 or pattern.len == 0) return str;

    // For greedy, try matching from longest to shortest
    // For non-greedy, try matching from shortest to longest
    if (greedy) {
        var match_start: usize = 0;
        while (match_start < str.len) : (match_start += 1) {
            if (glob.matchGlob(pattern, str[match_start..])) {
                return str[0..match_start];
            }
        }
    } else {
        var match_start = str.len;
        while (match_start > 0) : (match_start -= 1) {
            if (glob.matchGlob(pattern, str[match_start - 1 ..])) {
                return str[0 .. match_start - 1];
            }
        }
    }
    return str;
}

/// Replace pattern in string with replacement
/// If replace_all is true, replaces all occurrences; otherwise only first
fn patternReplace(allocator: std.mem.Allocator, str: []const u8, pattern: []const u8, replacement: []const u8, replace_all: bool) ![]const u8 {
    if (str.len == 0 or pattern.len == 0) return try allocator.dupe(u8, str);

    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(allocator);

    var i: usize = 0;
    var replaced = false;

    while (i < str.len) {
        // Try to match pattern at this position
        var matched = false;
        if (!replaced or replace_all) {
            // Try each possible match length at this position
            var match_len = str.len - i;
            while (match_len > 0) : (match_len -= 1) {
                if (glob.matchGlob(pattern, str[i .. i + match_len])) {
                    try result.appendSlice(allocator, replacement);
                    i += match_len;
                    matched = true;
                    replaced = true;
                    break;
                }
            }
        }

        if (!matched) {
            try result.append(allocator, str[i]);
            i += 1;
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Pattern substitution with optional anchoring.
/// anchor: 0 = unanchored (delegates to patternReplace), '#' = match only at
/// the start of the string, '%' = match only at the end.
fn patternReplaceAnchored(allocator: std.mem.Allocator, str: []const u8, pattern: []const u8, replacement: []const u8, replace_all: bool, anchor: u8) ![]const u8 {
    if (anchor == 0) return patternReplace(allocator, str, pattern, replacement, replace_all);
    if (pattern.len == 0) return allocator.dupe(u8, str);

    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(allocator);

    if (anchor == '#') {
        // Longest match anchored at start.
        var match_len = str.len;
        while (true) : (match_len -= 1) {
            if (glob.matchGlob(pattern, str[0..match_len])) {
                try result.appendSlice(allocator, replacement);
                try result.appendSlice(allocator, str[match_len..]);
                return result.toOwnedSlice(allocator);
            }
            if (match_len == 0) break;
        }
    } else { // '%' - longest match anchored at end
        var start: usize = 0;
        while (start <= str.len) : (start += 1) {
            if (glob.matchGlob(pattern, str[start..])) {
                try result.appendSlice(allocator, str[0..start]);
                try result.appendSlice(allocator, replacement);
                return result.toOwnedSlice(allocator);
            }
        }
    }
    return allocator.dupe(u8, str);
}

/// Check if input contains brace expansion patterns.
/// A `${...}` parameter expansion is NOT a brace group: its `{` is preceded by `$`,
/// and any commas/dots inside it (e.g. ${x,,}, ${x/a,b/c}) must not be mistaken for a
/// brace-list/range. Such groups are skipped whole.
pub fn hasBracePattern(input: []const u8) bool {
    var depth: u32 = 0;
    var has_content = false;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (c == '{') {
            // Parameter expansion `${` — skip the balanced group.
            if (i > 0 and input[i - 1] == '$') {
                var pdepth: u32 = 1;
                i += 1;
                while (i < input.len and pdepth > 0) : (i += 1) {
                    if (input[i] == '{') pdepth += 1 else if (input[i] == '}') pdepth -= 1;
                    if (pdepth == 0) break;
                }
                continue;
            }
            depth += 1;
        } else if (c == '}') {
            if (depth > 0) {
                depth -= 1;
                if (depth == 0 and has_content) return true;
            }
        } else if (depth == 1) {
            if (c == ',' or (c == '.' and i + 1 < input.len and input[i + 1] == '.')) {
                has_content = true;
            }
        }
    }
    return false;
}

/// Check if heredoc is complete (delimiter found on its own line)
fn heredocComplete(command: []const u8, delimiter: []const u8) bool {
    // find where heredoc content starts (after first newline after <<)
    var found_heredoc = false;
    var dash = false;
    var i: usize = 0;
    while (i + 1 < command.len) : (i += 1) {
        if (command[i] == '<' and command[i + 1] == '<') {
            if (i + 2 < command.len and command[i + 2] == '<') {
                i += 2;
                continue;
            }
            found_heredoc = true;
            dash = i + 2 < command.len and command[i + 2] == '-';
            // skip to end of line
            while (i < command.len and command[i] != '\n') : (i += 1) {}
            break;
        }
    }
    if (!found_heredoc) return true;

    // now check each line for the delimiter
    while (i < command.len) {
        // skip newline
        if (command[i] == '\n') i += 1;
        if (i >= command.len) break;

        // get this line
        const line_start = i;
        while (i < command.len and command[i] != '\n') : (i += 1) {}
        const line = command[line_start..i];

        // <<- allows leading tabs before the closing delimiter; otherwise the
        // line must match the delimiter exactly.
        const cmp = if (dash) std.mem.trimStart(u8, line, "\t") else line;
        if (std.mem.eql(u8, cmp, delimiter)) {
            return true;
        }
    }
    return false;
}
