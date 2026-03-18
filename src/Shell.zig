const Shell = @This();

const std = @import("std");
const types = @import("types.zig");
const lexer = @import("lexer.zig");
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
            const upper = blk: {
                var buf: [16]u8 = undefined;
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

allocator: std.mem.Allocator,
running: bool,
history: ?*hist.History,
vim_mode: VimMode,
history_index: i32,
history_search_prefix_len: usize,
original_termios: ?std.posix.termios = null,
aliases: std.StringHashMap([]const u8),
variables: std.StringHashMap([]const u8),
arrays: std.StringHashMap(std.ArrayListUnmanaged([]const u8)), // array variables
functions: std.StringHashMap(*const ast.AstNode), // name -> body AST
traps: TrapTable = .{}, // signal handlers
last_exit_code: u8 = 0,

// shell options (set -e, -u, -x, -o pipefail)
opt_errexit: bool = false, // -e: exit on error
opt_nounset: bool = false, // -u: error on undefined variable
opt_xtrace: bool = false, // -x: print commands before execution
opt_pipefail: bool = false, // pipefail: pipeline fails if any command fails
// when true, external commands exec directly instead of fork+exec (for pipeline children)
in_pipeline: bool = false,
// process substitution tracking
proc_subst_pids: [16]std.posix.pid_t = [_]std.posix.pid_t{0} ** 16,
proc_subst_fds: [16]std.posix.fd_t = [_]std.posix.fd_t{-1} ** 16,
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
// completion state
completion_mode: bool = false,
completion_matches: std.ArrayList([]const u8),
completion_index: usize = 0,
completion_word_start: usize = 0,
completion_word_end: usize = 0,
completion_original_len: usize = 0,
completion_pattern_len: usize = 0,
completion_menu_lines: usize = 0,
completion_displayed: bool = false,
skip_next_slash: bool = false, // set after completion inserts / for directory
ctrl_d_pending: bool = false, // double ctrl+d to exit

// flag completion cache (one command at a time, TTL 5 min)
flag_cache_cmd: [64]u8 = undefined,
flag_cache_cmd_len: usize = 0,
flag_cache_buf: [8192]u8 = undefined,
flag_cache_offsets: [256]u16 = undefined,
flag_cache_lens: [256]u8 = undefined,
flag_cache_count: usize = 0,
flag_cache_ts: i64 = 0, // timestamp when cache was populated
// flag description cache (parallel to flag_cache)
flag_desc_buf: [16384]u8 = undefined,
flag_desc_offsets: [256]u16 = undefined,
flag_desc_lens: [256]u8 = undefined,

// subcommand completion cache (one command at a time, TTL 5 min)
subcmd_cache_cmd: [32]u8 = undefined,
subcmd_cache_cmd_len: usize = 0,
subcmd_cache_buf: [4096]u8 = undefined,
subcmd_cache_offsets: [128]u16 = undefined,
subcmd_cache_lens: [128]u8 = undefined,
subcmd_cache_count: usize = 0,
subcmd_cache_ts: i64 = 0,

// ghost text autosuggestion (fish-style) with multiple candidates
opt_autosuggestion: bool = true,
ghost_buf: [512]u8 = undefined,
ghost_len: usize = 0,
ghost_from_ctm: bool = false,
// Multiple ghost candidates (Alt+Up/Down to cycle)
ghost_candidates: [8][512]u8 = undefined,
ghost_candidate_lens: [8]usize = [_]usize{0} ** 8,
ghost_candidate_count: u8 = 0,
ghost_candidate_idx: u8 = 0, // currently shown candidate
// CTM inference for ghost text (async — runs on background thread)
ghost_infer_input: [512]u8 = undefined, // command line sent to inference
ghost_infer_input_len: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
ghost_infer_seq: std.atomic.Value(u32) = std.atomic.Value(u32).init(0), // increment on new request
ghost_infer_result: [512]u8 = undefined, // inference result
ghost_infer_result_len: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
ghost_infer_result_seq: std.atomic.Value(u32) = std.atomic.Value(u32).init(0), // seq of completed result
ghost_last_result_seq: u32 = 0, // last result seq we consumed (non-atomic, main thread only)
ghost_infer_thread: ?std.Thread = null,
ghost_infer_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

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

stdout_writer: std.fs.File.Writer,
log_file: ?std.fs.File = null,

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
        .term_view = editor.TermView.init(std.posix.STDERR_FILENO),
        .vi = .{},
        .clipboard = clipboard_buffer,
        .clipboard_len = 0,
        .search_mode = false,
        .search_buffer = search_buffer,
        .search_len = 0,
        .completion_mode = false,
        .completion_matches = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 },
        .completion_index = 0,
        .completion_word_start = 0,
        .completion_word_end = 0,
        .completion_original_len = 0,
        .completion_pattern_len = 0,
        .completion_menu_lines = 0,
        .completion_displayed = false,
        .stdout_writer = .init(.stdout(), writer_buffer),
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

    // cleanup completion matches
    for (self.completion_matches.items) |match| {
        self.allocator.free(match);
    }
    self.completion_matches.deinit(self.allocator);

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
    self.term_view.ghost_text = self.ghost_buf[0..self.ghost_len];
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
}

const PromptInfo = struct {
    slice: []const u8,
    visible_len: u16,
};

fn buildPrompt(self: *Shell, buf: *[256]u8) PromptInfo {
    // get mode indicator
    const mode_str = self.vi.modeIndicatorColored();

    // get user
    const user = std.process.getEnvVarOwned(self.allocator, "USER") catch "?";
    defer if (!std.mem.eql(u8, user, "?")) self.allocator.free(user);

    // get hostname
    var hostname_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = std.posix.gethostname(&hostname_buf) catch "localhost";

    // get cwd
    var cwd_buf: [256]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch "?";

    // simplify home path
    const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch null;
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
        const head = std.fs.cwd().openFile(".git/HEAD", .{}) catch break :blk "";
        defer head.close();
        var hbuf: [256]u8 = undefined;
        const n = head.read(&hbuf) catch break :blk "";
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

    // calculate visible length (mode indicator is 3-4 chars visible)
    const mode_visible: u16 = if (self.vi.mode == .visual_line) 4 else 3;
    const rest_raw = user.len + 1 + hostname.len + 1 + display_path.len + 3; // +1(@) +1(space-before-path) +3(" $ ")
    const rest_visible: u16 = if (rest_raw > 250) 250 else @intCast(rest_raw);

    return .{
        .slice = buf[0..len.len],
        .visible_len = mode_visible + 1 + rest_visible + branch_visible + exit_visible, // +1 for space after mode
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
            std.fs.openFileAbsolute(cached_path, .{})
        else
            std.fs.cwd().openFile(cached_path, .{});
        if (file) |f| {
            f.close();
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
    const path_env = self.variables.get("PATH") orelse (std.posix.getenv("PATH") orelse return null);

    var path_iter = std.mem.splitScalar(u8, path_env, ':');
    while (path_iter.next()) |dir| {
        if (dir.len == 0) continue;

        // build full path: dir + "/" + cmd_name
        const full_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, cmd_name }) catch continue;

        // check if file exists and is executable
        const file = (if (std.fs.path.isAbsolute(full_path))
            std.fs.openFileAbsolute(full_path, .{})
        else
            std.fs.cwd().openFile(full_path, .{})) catch {
            self.allocator.free(full_path);
            continue;
        };
        const stat = file.stat() catch {
            file.close();
            self.allocator.free(full_path);
            continue;
        };
        file.close();
        // check execute bit
        if ((stat.mode & 0o111) == 0) {
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

    // start agent background thread (optional - silently skip if thread fails)
    self.agent.start() catch {};

    // start ghost text inference if completion_model is configured
    {
        var cfg = agent_log.AgentConfig.load(self.allocator);
        defer cfg.deinit();
        // Debug: log model loading
        {
            const f = std.fs.createFileAbsolute("/tmp/zish_inference.log", .{ .truncate = true }) catch null;
            if (f) |file| {
                file.writeAll("completion_model=") catch {};
                file.writeAll(if (cfg.completion_model.len > 0) cfg.completion_model else "(empty)") catch {};
                file.writeAll("\n") catch {};
                file.close();
            }
        }
        if (cfg.completion_model.len > 0) {
            // expand ~ to home directory
            var path_buf: [512]u8 = undefined;
            const model_path = if (std.mem.startsWith(u8, cfg.completion_model, "~/")) blk: {
                const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch break :blk cfg.completion_model;
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
    _ = std.posix.write(std.posix.STDERR_FILENO, style.escapeCode()) catch {};
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
    const result = std.posix.system.ioctl(std.posix.STDOUT_FILENO, TIOCGWINSZ, @intFromPtr(&ws));

    if (result == 0 and ws.ws_col > 0 and ws.ws_row > 0) {
        return .{ .width = ws.ws_col, .height = ws.ws_row };
    }

    return .{ .width = 80, .height = 24 }; // fallback if ioctl fails
}

fn handleSigwinch(_: c_int) callconv(.c) void {
    // atomic load to safely access from signal handler context
    const shell = @atomicLoad(?*Shell, &global_shell, .acquire);
    if (shell) |s| {
        @atomicStore(bool, &s.terminal_resized, true, .release);
    }
}

fn setupResizeHandler(self: *Shell) void {
    // atomic store to safely publish to signal handler
    @atomicStore(?*Shell, &global_shell, self, .release);

    const SIGWINCH = if (@hasDecl(std.posix.SIG, "WINCH")) std.posix.SIG.WINCH else 28;

    const empty_mask: std.posix.sigset_t = std.mem.zeroes(std.posix.sigset_t);

    var act = std.posix.Sigaction{
        .handler = .{ .handler = handleSigwinch },
        .mask = empty_mask,
        .flags = 0,
    };

    std.posix.sigaction(SIGWINCH, &act, null);
}

/// Set up signal handlers for job control
/// Interactive shells must ignore SIGTTIN/SIGTTOU to avoid being stopped
/// when terminal control is temporarily given to a child process group
fn setupJobControlSignals() void {
    const ignore_action = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };

    // Ignore SIGTTIN - sent when bg process reads from terminal
    std.posix.sigaction(std.posix.SIG.TTIN, &ignore_action, null);

    // Ignore SIGTTOU - sent when bg process writes to terminal
    std.posix.sigaction(std.posix.SIG.TTOU, &ignore_action, null);
}

fn handleResize(self: *Shell) !void {
    // get current terminal size
    const new_size = self.getTerminalSize();

    // check if dimensions actually changed
    if (new_size.width == self.terminal_width and new_size.height == self.terminal_height) {
        return; // spurious SIGWINCH, nothing changed
    }

    // debounce rapid resizes
    const now = std.time.milliTimestamp();
    const debounce_ms = 50; // wait 50ms between redraws
    if (now - self.last_resize_time < debounce_ms) {
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

    // Clear from prompt start down and redraw everything
    if (self.term_view.term.row > 0) {
        try self.stdout().print("\x1b[{d}A", .{self.term_view.term.row});
    }
    try self.stdout().writeAll("\r\x1b[J");
    self.term_view.term.row = 0;
    self.term_view.term.col = 0;
    self.term_view.last_hash = 0;

    try self.renderLine();
    if (self.completion_mode and self.completion_displayed) {
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
        try file.writeAll(slice);
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
            self.ghost_len = 0;
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
            _ = std.posix.kill(pid, std.posix.SIG.TSTP) catch {};

            // === EXECUTION RESUMES HERE AFTER SIGCONT ===
            // the parent shell may have changed terminal settings while we
            // were suspended, so we must re-read the current state rather
            // than using our cached original_termios
            self.original_termios = null; // force re-read of terminal state
            self.enableRawMode() catch {};

            // also update our cached shell terminal modes for job control
            self.job_table.shell_tmodes = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch self.job_table.shell_tmodes;

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
                if (char == '/' and self.skip_next_slash) {
                    self.skip_next_slash = false;
                    return; // don't insert, don't redraw
                }
                self.skip_next_slash = false; // clear for any other char

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
                self.ghost_len = 0;

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
                        const nl_query = std.mem.trimLeft(u8, command[1..], " \t");
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
                        preprocessHeredoc(self.allocator, command, delim) catch command
                    else
                        command;
                    defer if (processed_cmd.ptr != command.ptr) self.allocator.free(processed_cmd);

                    const start_ts = std.time.timestamp();
                    self.last_exit_code = try self.executeCommand(processed_cmd);
                    const elapsed = std.time.timestamp() - start_ts;

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
            if (self.completion_mode) {
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
            if (self.completion_mode) {
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
        },

        .exit_search_mode => |execute| {
            self.search_mode = false;

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
        if (old_pos == max_pos and self.ghost_len > 0) {
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
        if (!done) std.Thread.sleep(20 * std.time.ns_per_ms);
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
    const home = std.process.getEnvVarOwned(std.heap.page_allocator, "HOME") catch return;
    defer std.heap.page_allocator.free(home);
    const path = std.fmt.bufPrint(&path_buf, "{s}/.zish/translate_log.jsonl", .{home}) catch return;

    const file = std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch |e| switch (e) {
        error.FileNotFound => std.fs.cwd().createFile(path, .{}) catch return,
        else => return,
    };
    defer file.close();
    file.seekFromEnd(0) catch return;

    const ts: u64 = @bitCast(std.time.timestamp());
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    pos += logCopy(&buf, pos, "{\"query\":\"");
    pos = logEscape(&buf, pos, query);
    pos += logCopy(&buf, pos, "\",\"cmd\":\"");
    pos = logEscape(&buf, pos, result);
    pos += logCopy(&buf, pos, "\",\"ts\":");
    pos += (std.fmt.bufPrint(buf[pos..], "{d}", .{ts}) catch return).len;
    pos += logCopy(&buf, pos, "}\n");
    _ = file.write(buf[0..pos]) catch {};
}

/// Log every executed command with exit code and duration for training data.
fn logCommandExecution(command: []const u8, exit_code: u8, elapsed: i64) void {
    if (command.len == 0 or command.len > 2048) return;

    var path_buf: [512]u8 = undefined;
    const home = std.process.getEnvVarOwned(std.heap.page_allocator, "HOME") catch return;
    defer std.heap.page_allocator.free(home);
    const path = std.fmt.bufPrint(&path_buf, "{s}/.zish/command_log.jsonl", .{home}) catch return;

    const file = std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch |e| switch (e) {
        error.FileNotFound => std.fs.cwd().createFile(path, .{}) catch return,
        else => return,
    };
    defer file.close();
    file.seekFromEnd(0) catch return;

    var cwd_buf: [256]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch "?";

    const ts: u64 = @bitCast(std.time.timestamp());
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
    _ = file.write(buf[0..pos]) catch {};
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
fn drainAgentOutput(self: *Shell) !void {
    const q = @import("agent_queue.zig");
    var msg: q.Msg = undefined;
    var wrote = false;
    var last_was_text = false;
    const writer = self.stdout();

    while (self.agent.queues.output.pop(&msg)) {
        if (!self.agent_output_active) {
            // first message of a new agent response: clear prompt and move below
            self.term_view.moveTo(self.term_view.term.rows_owned -| 1, 0);
            self.term_view.clearToEOL();
            try self.term_view.flush();
            try writer.writeAll("\r\n");
            self.agent_output_active = true;
        }
        wrote = true;

        switch (msg.kind) {
            .text_delta => {
                try self.agent_md.render(writer, msg.slice());
                last_was_text = true;
            },
            .tool_call => {
                if (last_was_text) try writer.writeAll("\x1b[0m");
                last_was_text = false;
                try writer.writeAll("\x1b[90m\xe2\x9a\xa1 "); // ⚡
                try writer.writeAll(msg.slice());
                try writer.writeAll("\x1b[0m\n");
            },
            .tool_done => {
                last_was_text = false;
                const dt = msg.slice();
                if (dt.len > 0) {
                    const has_ansi = std.mem.indexOf(u8, dt, "\x1b[3") != null;
                    if (has_ansi) {
                        try writer.writeAll("  ");
                        try writer.writeAll(dt);
                        try writer.writeAll("\x1b[0m\n");
                    } else {
                        try writer.writeAll("  \x1b[90m");
                        try writer.writeAll(dt);
                        try writer.writeAll("\x1b[0m\n");
                    }
                } else {
                    try writer.writeAll("  \x1b[32m\xe2\x9c\x93\x1b[0m\n"); // ✓
                }
            },
            .error_msg => {
                if (last_was_text) try writer.writeAll("\x1b[0m\n");
                last_was_text = false;
                try writer.writeAll("\x1b[31m\xe2\x9c\x97 "); // ✗ prefix
                try writer.writeAll(msg.slice());
                try writer.writeAll("\x1b[0m\n");
            },
            .done => {
                if (last_was_text) try writer.writeAll("\x1b[0m");
                last_was_text = false;
                try writer.writeByte('\n');
                self.agent_md.reset();
                self.agent_output_active = false;
                // re-render prompt now that agent is done
                try writer.flush();
                self.term_view.finishLine();
                try self.renderLine();
            },
            .confirm_request => {
                if (last_was_text) try writer.writeAll("\x1b[0m\n");
                last_was_text = false;
                self.agent_md.reset();
                // Show confirmation prompt
                try writer.writeAll("\x1b[33m\xe2\x9a\xa0 "); // ⚠ prefix
                try writer.writeAll(msg.slice());
                try writer.writeAll(" \x1b[90m[\x1b[32my\x1b[90m/\x1b[31mn\x1b[90m/\x1b[33ma\x1b[90mlways]\x1b[0m ");
                try writer.flush();
                // Read single keystroke (terminal is in raw mode)
                var resp: [1]u8 = undefined;
                const n = std.posix.read(std.posix.STDIN_FILENO, &resp) catch 0;
                if (n > 0 and (resp[0] == 'y' or resp[0] == 'Y')) {
                    _ = self.agent.queues.request.push(.confirm_response, "y");
                    try writer.writeAll("y\n");
                } else if (n > 0 and (resp[0] == 'a' or resp[0] == 'A' or resp[0] == '!')) {
                    _ = self.agent.queues.request.push(.confirm_response, "a");
                    try writer.writeAll("a (always)\n");
                } else {
                    _ = self.agent.queues.request.push(.confirm_response, "n");
                    try writer.writeAll("n\n");
                }
                try writer.flush();
            },
            .usage_info => {
                last_was_text = false;
                try writer.writeAll("\x1b[90m"); // dim
                try writer.writeAll(msg.slice());
                try writer.writeAll("\x1b[0m\n");
            },
            .router_info => {
                // Suppress router info (matches interactive mode)
            },
            .confirm_response, .add_task, .spawn_worker, .agent_status_req,
            .agent_tree_req, .agent_result_req => {}, // handled on agent side
            .agent_tree_node, .agent_result => {}, // only used in interactive tree view
            .agent_status => {
                last_was_text = false;
                if (msg.len > 0) {
                    try writer.writeAll(msg.slice());
                    try writer.writeByte('\n');
                }
            },
            .cancel => {
                last_was_text = false;
                self.agent_output_active = false;
            },
        }
    }

    if (wrote) {
        try writer.flush();
    }

    // ── Bulletin: show escalations and discoveries to the user ──
    self.drainBulletin(writer) catch {};
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
    const stdin_fd = std.posix.STDIN_FILENO;
    var fds = [_]std.posix.pollfd{.{
        .fd = stdin_fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};

    // 50ms timeout — responsive enough for streaming, not too CPU-hot
    const poll_result = std.posix.poll(&fds, 50) catch return .none;
    if (poll_result == 0) return .none; // timeout, no input

    // input available, read normally
    return self.readNextAction();
}

fn readNextAction(self: *Shell) !Action {
    var temp_buf: [1]u8 = undefined;
    const count = try std.fs.File.stdin().read(temp_buf[0..]);
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
        if (char >= 32 and char <= 126) {
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
    const stdin_fd = std.posix.STDIN_FILENO;
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
        return .{ .vim_mode = .{ .set_mode = .normal } };
    }
    const bytes_read: usize = @intCast(result);

    if (temp_buf[0] != '[') {
        // Alt+key: look up in keybindings table
        if (self.keybindings.lookupAlt(temp_buf[0])) |action| return action;
        return .{ .vim_mode = .{ .set_mode = .normal } };
    }

    // Need at least 2 bytes for a valid escape sequence
    // If incomplete, treat as just ESC (vim normal mode)
    if (bytes_read < 2) return .{ .vim_mode = .{ .set_mode = .normal } };

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
fn consumeEscapeSequence(stdin_fd: std.posix.fd_t) void {
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

fn readTildeSequence(stdin_fd: std.posix.fd_t, flags: usize, action: Action) !Action {
    var buf: [1]u8 = undefined;
    const result = std.posix.system.read(stdin_fd, &buf, 1);
    if (result <= 0) return .none;
    if (buf[0] == '~') return action;
    _ = flags;
    return .none;
}

fn handleExtendedEscapeSequence(stdin_fd: std.posix.fd_t, flags: usize) !Action {
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

fn handleBracketedPaste(stdin_fd: std.posix.fd_t, flags: usize) !Action {
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
    const stdin_fd = std.posix.STDIN_FILENO;

    // use saved original if available (prevents child processes from
    // corrupting our terminal state), otherwise read current state
    var termios = if (self.original_termios) |orig|
        orig
    else blk: {
        const current = std.posix.tcgetattr(stdin_fd) catch return;
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
    termios.cc[@intFromEnum(std.posix.V.MIN)] = 1; // read 1 char at a time
    termios.cc[@intFromEnum(std.posix.V.TIME)] = 0; // no timeout

    // apply the changes
    std.posix.tcsetattr(stdin_fd, .NOW, termios) catch return;

    // enable bracketed paste mode (write to stderr to avoid capture by redirects)
    _ = std.posix.write(std.posix.STDERR_FILENO, "\x1b[?2004h") catch {};
}

pub fn disableRawMode(self: *Shell) void {
    // disable bracketed paste mode (write to stderr to avoid capture by redirects)
    _ = std.posix.write(std.posix.STDERR_FILENO, "\x1b[?2004l") catch {};

    if (self.original_termios) |original| {
        const stdin_fd = std.posix.STDIN_FILENO;
        std.posix.tcsetattr(stdin_fd, .NOW, original) catch {};
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
        self.term_view.term.row = 0;
        self.term_view.term.col = 0;
        self.term_view.last_hash = 0; // force full redraw
    }

    self.edit_buf.set(history_cmd);
    }

fn loadKeybindings(self: *Shell) void {
    var path_buf: [512]u8 = undefined;
    const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch return;
    defer self.allocator.free(home);
    const path = std.fmt.bufPrint(&path_buf, "{s}/.zish/keybindings.json", .{home}) catch return;
    self.keybindings = input_mod.KeyBindings.loadFromFile(path);
}

fn loadConfig(self: *Shell) !void {
    // get home directory
    const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch return;
    defer self.allocator.free(home);

    // construct ~/.zishrc path
    const config_path = try std.fmt.allocPrint(self.allocator, "{s}/.zishrc", .{home});
    defer self.allocator.free(config_path);

    // check if file exists
    std.fs.cwd().access(config_path, .{}) catch return;

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
            preprocessHeredoc(self.allocator, trimmed, delim) catch trimmed
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

    var arr = std.ArrayListUnmanaged([]const u8){};
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
        var arr = std.ArrayListUnmanaged([]const u8){};
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
    const expanded = try self.expandVariablesAlloc(input);
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

    return self.expandVariablesAlloc(input);
}

fn expandVariablesAlloc(self: *Shell, input: []const u8) ![]const u8 {

    // Simple variable expansion - replace $VAR with variable value
    var result = try std.ArrayList(u8).initCapacity(self.allocator, input.len);
    defer result.deinit(self.allocator);

    var i: usize = 0;

    // Tilde expansion at start of input
    if (input.len > 0 and input[0] == '~') {
        if (input.len == 1 or input[1] == '/') {
            const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch "";
            defer if (home.len > 0) self.allocator.free(home);
            try result.appendSlice(self.allocator, home);
            i = 1; // skip the ~
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
                    try result.appendSlice(self.allocator, std.mem.trimRight(u8, cmd_output, "\n\r"));
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
                        } else if (std.process.getEnvVarOwned(self.allocator, var_name)) |val| {
                            var_len = val.len;
                            self.allocator.free(val);
                        } else |_| {}
                    }

                    var len_buf: [20]u8 = undefined;
                    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{var_len}) catch "0";
                    try result.appendSlice(self.allocator, len_str);
                    continue;
                }

                const name_start = i;

                // Find end of variable name or modifier
                // Stop at: } : - + ? # % /
                while (i < input.len and input[i] != '}' and input[i] != ':' and
                    input[i] != '-' and input[i] != '+' and input[i] != '?' and
                    input[i] != '#' and input[i] != '%' and input[i] != '/')
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
                        const env_value = std.process.getEnvVarOwned(self.allocator, var_name) catch null;
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
                    // ${VAR/pattern/replacement} or ${VAR//pattern/replacement}
                    i += 1;
                    const replace_all = i < input.len and input[i] == '/';
                    if (replace_all) i += 1;

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
                        const replaced = try patternReplace(self.allocator, v, pattern, replacement, replace_all);
                        defer self.allocator.free(replaced);
                        try result.appendSlice(self.allocator, replaced);
                    }
                } else if (i < input.len and input[i] == ':' and i + 1 < input.len and
                    (std.ascii.isDigit(input[i + 1]) or input[i + 1] == '-'))
                {
                    // ${VAR:offset} or ${VAR:offset:length} - substring
                    i += 1;
                    const offset_start = i;
                    var negative_offset = false;
                    if (i < input.len and input[i] == '-') {
                        negative_offset = true;
                        i += 1;
                    }
                    while (i < input.len and std.ascii.isDigit(input[i])) i += 1;
                    const offset_str = input[offset_start..i];
                    const offset = std.fmt.parseInt(i32, offset_str, 10) catch 0;

                    var length: ?usize = null;
                    if (i < input.len and input[i] == ':') {
                        i += 1;
                        const len_start = i;
                        while (i < input.len and std.ascii.isDigit(input[i])) i += 1;
                        if (i > len_start) {
                            length = std.fmt.parseInt(usize, input[len_start..i], 10) catch null;
                        }
                    }
                    if (i < input.len and input[i] == '}') i += 1;

                    if (var_value) |v| {
                        // Handle negative offset (from end)
                        var start: usize = 0;
                        if (offset < 0) {
                            const abs_offset: usize = @intCast(-offset);
                            start = if (abs_offset > v.len) 0 else v.len - abs_offset;
                        } else {
                            start = @min(@as(usize, @intCast(offset)), v.len);
                        }

                        const end = if (length) |l| @min(start + l, v.len) else v.len;
                        try result.appendSlice(self.allocator, v[start..end]);
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

                    if (i < input.len and (input[i] == '-' or input[i] == '+' or input[i] == '?')) {
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
                                const expanded_default = try self.expandVariablesAlloc(default_value);
                                defer self.allocator.free(expanded_default);
                                try result.appendSlice(self.allocator, expanded_default);
                            } else if (var_value) |v| {
                                try result.appendSlice(self.allocator, v);
                            }
                        },
                        '+' => {
                            // ${VAR:+alternate} or ${VAR+alternate}
                            if (!use_default) {
                                const expanded_alt = try self.expandVariablesAlloc(default_value);
                                defer self.allocator.free(expanded_alt);
                                try result.appendSlice(self.allocator, expanded_alt);
                            }
                        },
                        '?' => {
                            // ${VAR:?error} or ${VAR?error}
                            if (use_default) {
                                try self.stdout().print("zish: {s}: {s}\n", .{ var_name, if (default_value.len > 0) default_value else "parameter not set" });
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
                        const env_value = std.process.getEnvVarOwned(self.allocator, var_name) catch null;
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
                try result.appendSlice(self.allocator, std.mem.trimRight(u8, cmd_output, "\n\r"));
            } else {
                // Unmatched backtick, treat as regular text
                try result.append(self.allocator, '`');
                i = cmd_start;
            }
        } else {
            try result.append(self.allocator, input[i]);
            i += 1;
        }
    }

    return try result.toOwnedSlice(self.allocator);
}

pub fn evaluateArithmetic(self: *Shell, expr: []const u8) !i64 {
    const trimmed = std.mem.trim(u8, expr, " \t\n\r");
    if (trimmed.len == 0) return 0;

    // SectorLambda-inspired: fast path for common simple expressions
    // Pattern: "var + num", "num + var", "var + var", "num OP num"
    if (tryFastArithmetic(trimmed, self)) |result| {
        return result;
    }

    // Slow path: recursive evaluation for complex expressions
    for ([_]u8{ '+', '-', '*', '/' }) |op| {
        if (std.mem.lastIndexOfScalar(u8, trimmed, op)) |op_pos| {
            if (op_pos > 0 and op_pos < trimmed.len - 1) {
                const left = try self.evaluateArithmetic(trimmed[0..op_pos]);
                const right = try self.evaluateArithmetic(trimmed[op_pos + 1 ..]);
                return switch (op) {
                    '+' => left + right,
                    '-' => left - right,
                    '*' => left * right,
                    '/' => if (right != 0) @divTrunc(left, right) else 0,
                    else => 0,
                };
            }
        }
    }

    // try to parse as number
    if (std.fmt.parseInt(i64, trimmed, 10)) |num| {
        return num;
    } else |_| {
        // try as variable
        if (self.variables.get(trimmed)) |val| {
            return std.fmt.parseInt(i64, val, 10) catch 0;
        }
        // unknown variable defaults to 0
        return 0;
    }
}

// Fast path for simple binary expressions - avoids recursion overhead
// Handles: "a + b", "1 + 2", "i + 1", etc.
fn tryFastArithmetic(expr: []const u8, shell: *Shell) ?i64 {
    // Find operator (only handle single operator case)
    var op_pos: ?usize = null;
    var op_char: u8 = 0;
    var op_count: usize = 0;

    for (expr, 0..) |c, i| {
        if (c == '+' or c == '-' or c == '*' or c == '/') {
            if (i > 0 and i < expr.len - 1) {
                op_count += 1;
                if (op_count > 1) return null; // Multiple operators - use slow path
                op_pos = i;
                op_char = c;
            }
        }
    }

    const pos = op_pos orelse return null;

    // Parse left operand
    const left_str = std.mem.trim(u8, expr[0..pos], " \t");
    const left = if (std.fmt.parseInt(i64, left_str, 10)) |n|
        n
    else |_| blk: {
        const val = shell.variables.get(left_str) orelse return null;
        break :blk std.fmt.parseInt(i64, val, 10) catch return null;
    };

    // Parse right operand
    const right_str = std.mem.trim(u8, expr[pos + 1 ..], " \t");
    const right = if (std.fmt.parseInt(i64, right_str, 10)) |n|
        n
    else |_| blk: {
        const val = shell.variables.get(right_str) orelse return null;
        break :blk std.fmt.parseInt(i64, val, 10) catch return null;
    };

    return switch (op_char) {
        '+' => left + right,
        '-' => left - right,
        '*' => left * right,
        '/' => if (right != 0) @divTrunc(left, right) else 0,
        else => null,
    };
}

fn executeCommandAndCapture(self: *Shell, command: []const u8) ![]const u8 {
    // Execute a command and capture its output
    const trimmed_cmd = std.mem.trim(u8, command, " \t\n\r");

    // Fast path for simple built-ins (no pipes/redirects)
    if (std.mem.indexOfAny(u8, trimmed_cmd, "|<>&;") == null) {
        // pwd builtin
        if (std.mem.eql(u8, trimmed_cmd, "pwd")) {
            var buf: [4096]u8 = undefined;
            const cwd = std.posix.getcwd(&buf) catch return self.allocator.dupe(u8, "");
            return self.allocator.dupe(u8, cwd);
        }

        // echo builtin - very common in command substitution
        if (std.mem.startsWith(u8, trimmed_cmd, "echo ") or std.mem.eql(u8, trimmed_cmd, "echo")) {
            const args = if (trimmed_cmd.len > 5) trimmed_cmd[5..] else "";
            // Handle -n flag
            if (std.mem.startsWith(u8, args, "-n ")) {
                return self.allocator.dupe(u8, args[3..]);
            } else if (std.mem.eql(u8, args, "-n")) {
                return self.allocator.dupe(u8, "");
            }
            // Normal echo - just return args with newline (no expansion needed for simple case)
            var result = try std.ArrayList(u8).initCapacity(self.allocator, args.len + 1);
            try result.appendSlice(self.allocator, args);
            try result.append(self.allocator, '\n');
            return result.toOwnedSlice(self.allocator);
        }

        // printf builtin - simple version
        if (std.mem.startsWith(u8, trimmed_cmd, "printf ")) {
            const args = trimmed_cmd[7..];
            return self.allocator.dupe(u8, args);
        }

        // true/false
        if (std.mem.eql(u8, trimmed_cmd, "true") or std.mem.eql(u8, trimmed_cmd, ":")) {
            return self.allocator.dupe(u8, "");
        }
        if (std.mem.eql(u8, trimmed_cmd, "false")) {
            return self.allocator.dupe(u8, "");
        }
    }

    // For all other commands (including pipelines), execute via shell
    return self.executeExternalAndCapture(trimmed_cmd) catch self.allocator.dupe(u8, "");
}

fn executeExternalAndCapture(self: *Shell, command: []const u8) ![]const u8 {
    // Execute external command and capture output
    const result = try std.process.Child.run(.{
        .allocator = self.allocator,
        .argv = &[_][]const u8{ "/bin/sh", "-c", command },
        .max_output_bytes = 4096,
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
    const is_tty = std.posix.isatty(std.posix.STDIN_FILENO);
    if (is_tty) {
        self.disableRawMode();
    }
    defer if (is_tty) {
        self.enableRawMode() catch {};
    };

    var child = std.process.Child.init(args.items, self.allocator);
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.stdin_behavior = .Inherit;

    // inherit full environment from parent
    child.env_map = null; // null means inherit all from parent

    // spawn child first, THEN ignore SIGINT in parent
    // (child must not inherit SIG_IGN or it can't be interrupted)
    child.spawn() catch |err| switch (err) {
        error.FileNotFound => {
            try self.stdout().print("zish: {s}: command not found\n", .{args.items[0]});
            return 127;
        },
        else => return err,
    };

    // now ignore SIGINT in shell while child runs
    var old_sigint: std.posix.Sigaction = undefined;
    const ignore_action = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &ignore_action, &old_sigint);
    defer std.posix.sigaction(std.posix.SIG.INT, &old_sigint, null);

    const term = child.wait();
    return switch (term) {
        .Exited => |code| code,
        .Signal => |sig| @as(u8, @intCast(sig + 128)),
        .Stopped => |sig| @as(u8, @intCast(sig + 128)),
        .Unknown => |code| @as(u8, @intCast(code)),
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

/// Preprocess heredoc: convert "cmd << DELIM\ncontent\nDELIM" to "cmd < /tmp/zish_heredoc_XXXX"
fn preprocessHeredoc(allocator: std.mem.Allocator, command: []const u8, delimiter: []const u8) ![]const u8 {
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

        const line = std.mem.trim(u8, command[line_start..line_end], " \t");
        if (std.mem.eql(u8, line, delimiter)) {
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

    const content = command[content_start..content_end];
    const suffix = std.mem.trim(u8, command[suffix_start..], " \t\r\n");

    // Write content to a temp file (use timestamp for uniqueness)
    const ts = std.time.milliTimestamp();
    var path_buf: [64]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&path_buf, "/tmp/zish_heredoc_{d}", .{ts}) catch return error.OutOfMemory;

    const file = std.fs.createFileAbsolute(tmp_path, .{ .truncate = true }) catch return error.FileError;
    defer file.close();
    file.writeAll(content) catch return error.WriteError;
    file.writeAll("\n") catch return error.WriteError;

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

    return result;
}

// limits to prevent pathological input from causing resource exhaustion
const BRACE_MAX_DEPTH: u8 = 10; // max nesting depth for brace expansion
const BRACE_MAX_RANGE: u32 = 10000; // max elements in a numeric range
const BRACE_MAX_RESULTS: u32 = 100000; // max total expansion results

/// Expand brace patterns like {a,b,c} and {1..5}
/// Returns array of expanded strings (caller owns memory)
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
    var expansions = std.ArrayListUnmanaged([]const u8){};
    defer {
        for (expansions.items) |exp| allocator.free(exp);
        expansions.deinit(allocator);
    }

    // check for range pattern like 1..5 or a..z
    if (std.mem.indexOf(u8, brace_content, "..")) |range_pos| {
        const range_start_str = brace_content[0..range_pos];
        const range_end_str = brace_content[range_pos + 2 ..];

        // try numeric range
        if (std.fmt.parseInt(i32, range_start_str, 10)) |start_num| {
            if (std.fmt.parseInt(i32, range_end_str, 10)) |end_num| {
                // calculate range size and enforce limit
                const range_size: u32 = @intCast(@abs(@as(i64, end_num) - @as(i64, start_num)) + 1);
                if (range_size > BRACE_MAX_RANGE) {
                    // range too large, treat as literal
                    const result = try allocator.alloc([]const u8, 1);
                    result[0] = try allocator.dupe(u8, input);
                    return result;
                }

                const step: i32 = if (start_num <= end_num) 1 else -1;
                var n = start_num;
                while (true) {
                    var buf: [16]u8 = undefined;
                    const num_str = std.fmt.bufPrint(&buf, "{d}", .{n}) catch break;
                    try expansions.append(allocator, try allocator.dupe(u8, num_str));
                    if (n == end_num) break;
                    n += step;
                }
            } else |_| {}
        } else |_| {
            // try character range (always limited to 256 max)
            if (range_start_str.len == 1 and range_end_str.len == 1) {
                const start_char = range_start_str[0];
                const end_char = range_end_str[0];
                if (std.ascii.isAlphabetic(start_char) and std.ascii.isAlphabetic(end_char)) {
                    const step: i8 = if (start_char <= end_char) 1 else -1;
                    var c = start_char;
                    while (true) {
                        try expansions.append(allocator, try allocator.dupe(u8, &[_]u8{c}));
                        if (c == end_char) break;
                        c = @intCast(@as(i16, c) + step);
                    }
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
    var results = std.ArrayListUnmanaged([]const u8){};
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

    var result = std.ArrayListUnmanaged(u8){};
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

/// Check if input contains brace expansion patterns
pub fn hasBracePattern(input: []const u8) bool {
    var depth: u32 = 0;
    var has_content = false;
    for (input, 0..) |c, i| {
        if (c == '{') {
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
    var i: usize = 0;
    while (i + 1 < command.len) : (i += 1) {
        if (command[i] == '<' and command[i + 1] == '<') {
            if (i + 2 < command.len and command[i + 2] == '<') {
                i += 2;
                continue;
            }
            found_heredoc = true;
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

        // check if line is exactly the delimiter (trimmed)
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.eql(u8, trimmed, delimiter)) {
            return true;
        }
    }
    return false;
}
