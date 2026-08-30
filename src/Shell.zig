const Shell = @This();

const std = @import("std");
const compat = @import("compat.zig");
const paramexp = @import("paramexp.zig");
const prompt_mod = @import("prompt.zig");
const arith = @import("arith.zig");
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
const jobs = @import("jobs.zig");
const editor = @import("editor.zig");
const vim = @import("vim.zig");
const dispatch = @import("dispatch.zig");
const trace = @import("trace.zig");
const heredoc = @import("heredoc.zig");
const expand = @import("expand.zig");
const line_editor = @import("line_editor.zig");

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

/// POSIX getsid — session id of a process (0 = calling process). Used to tell
/// a top-level/login zish (session leader; Ctrl+Z self-suspend is meaningless)
/// from a zish running as a job under a parent job-control shell.
extern "c" fn getsid(pid: std.c.pid_t) std.c.pid_t;
const CTRL_R = input_mod.CTRL_R;

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
    candidates: [8][512]u8 = undefined,
    candidate_lens: [8]usize = [_]usize{0} ** 8,
    candidate_count: u8 = 0,
    candidate_idx: u8 = 0,
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
// Names that are EXPORTED to child processes. A plain assignment (`x=1`) sets a
// shell-local variable that must NOT reach children; only `export`ed names and
// variables inherited from the environment at startup do. Without this every
// shell variable — including secrets — leaked into every child's environment.
exported: std.StringHashMap(void),
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

// Heredoc temp files (/tmp/zish_heredoc_*) created while processing a command,
// deleted when that top-level executeCommand call returns so they don't leak.
heredoc_temps: std.ArrayList([]const u8) = .empty,

// shell options (set -e, -u, -x, -o pipefail)
opt_errexit: bool = false, // -e: exit on error
opt_nounset: bool = false, // -u: error on undefined variable
opt_xtrace: bool = false, // -x: print commands before execution
opt_pipefail: bool = false, // pipefail: pipeline fails if any command fails
// Nesting depth of executeCommand. Command substitution and PROMPT_COMMAND
// re-enter it, and the session trace records only depth 0.
exec_depth: u16 = 0,
// True in a process that is already a forked child of the interactive shell
// (pipeline stage, subshell, background job). Drives two decisions: a subshell
// need not fork again, and a forked child must not take the terminal.
forked_child: bool = false,
// The one AST node this forked child exists to run in its entirety.
//
// When evaluateCommand is about to run an external command and the node it was
// handed IS this node, nothing follows it in this process, so it may exec in
// place and skip a redundant fork. Any other node must fork, because there is
// still more of the body left to run afterwards.
//
// This is deliberately a node identity and not a bool: a sticky "exec directly"
// flag is wrong by construction once the body is a compound, and silently
// dropped every command after the first in `( a; b )`, `x | { a; b; }` and
// `( a; b ) &`.
exec_in_place_node: ?*const ast.AstNode = null,
// loop control: number of enclosing loops to break/continue out of. 0 = none.
// set by the break/continue builtins, consumed by loop evaluators.
loop_break: u32 = 0,
loop_continue: u32 = 0,
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

// search state
search_mode: bool = false,
in_prompt_command: bool = false, // re-entrancy guard for $PROMPT_COMMAND
search_buffer: []u8,
search_len: usize = 0,
// which match to show (0 = most recent); Ctrl+R steps to older matches
search_index: usize = 0,
// paste mode (bracketed paste)
paste_mode: bool = false,
// completion state (grouped sub-struct — see completion_mod for logic)
completion: completion_mod.CompletionState,
ctrl_d_pending: bool = false, // double ctrl+d to exit

// completion caches (grouped sub-struct)
cache: completion_mod.CacheState = .{},

// ghost text autosuggestion state (grouped sub-struct)
ghost: GhostState = .{},

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
stderr_writer: std.Io.File.Writer,
log_file: ?std.Io.File = null,

// PATH lookup cache - maps command name -> full path
path_cache: std.StringHashMap([]const u8),

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
        .exported = std.StringHashMap(void).init(allocator),
        .arrays = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator),
        .functions = std.StringHashMap(*const ast.AstNode).init(allocator),
        // new modular editor
        .edit_buf = .{},
        .term_view = editor.TermView.init(posix.STDERR_FILENO),
        .vi = .{},
        .search_mode = false,
        .search_buffer = search_buffer,
        .search_len = 0,
        .completion = completion_mod.CompletionState.init(),
        // Streaming, not the default positional, mode. A shell's stdout is a
        // stream: it must append sequentially, never pwrite at a tracked
        // offset. Positional mode self-corrects to streaming only on an
        // unseekable target (terminal, pipe); command substitution redirects
        // stdout to a *seekable* capture file, where positional writes would
        // succeed at a stale offset and scatter the output. Streaming is also
        // correct now that the shell is single-threaded (the one reason to
        // prefer positional — seek-position thread-safety — no longer applies).
        .stdout_writer = std.Io.File.Writer.initStreaming(std.Io.File.stdout(), compat.io(), writer_buffer),
        // Unbuffered (empty buffer → every write drains straight to fd 2): builtin
        // diagnostics must reach the terminal immediately and must not sit in a
        // buffer that a redirect or `2>` never flushes.
        .stderr_writer = std.Io.File.Writer.initStreaming(std.Io.File.stderr(), compat.io(), &.{}),
        .path_cache = std.StringHashMap([]const u8).init(allocator),
        .job_table = jobs.JobTable.init(allocator),
    };

    // Every variable inherited from the environment is exported by definition —
    // record their names so that reassigning one (e.g. PATH=...) keeps it in the
    // child environment, while a brand-new `x=1` does not.
    {
        const env_ptr = std.c.environ;
        var ei: usize = 0;
        while (env_ptr[ei]) |entry| : (ei += 1) {
            const slice = std.mem.sliceTo(entry, 0);
            const eq = std.mem.indexOfScalar(u8, slice, '=') orelse continue;
            shell.markExported(slice[0..eq]) catch {};
        }
    }

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

    // cleanup exported-name set (owns its keys)
    var ex_it = self.exported.keyIterator();
    while (ex_it.next()) |k| self.allocator.free(k.*);
    self.exported.deinit();

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

    self.allocator.free(self.search_buffer);
    self.allocator.free(self.stdout().buffer);
    self.allocator.destroy(self);
}
/// Get command slice (prefers edit_buf)
fn getCommand(self: *Shell) []const u8 {
    return self.edit_buf.slice();
}

pub fn clearCommand(self: *Shell) void {
    self.edit_buf.clear();
}

/// Render using TermView
pub fn renderLine(self: *Shell) !void {
    // update ghost text suggestion before rendering
    completion_mod.updateGhostText(self);
    self.term_view.ghost_text = self.ghost.buf[0..self.ghost.len];
    var prompt_buf: [256]u8 = undefined;
    const prompt = prompt_mod.buildPrompt(self, &prompt_buf);
    try self.term_view.render(&self.edit_buf, prompt.slice, prompt.visible_len);
}

/// Show live search results as user types
pub fn showSearchMatch(self: *Shell) !void {
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
            // clamp the cycle index to the available matches (stops at oldest)
            if (self.search_index >= matches.len) self.search_index = matches.len - 1;
            const entry_idx = matches[self.search_index].entry_index;
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

    self.notifyBackgroundJobs();
    self.runPromptCommand();
    try self.renderLine();

    var last_action: Action = .none;

    while (self.running) {
        // handle terminal resize (atomic access - signal handler may set this)
        if (@atomicLoad(bool, &self.terminal_resized, .acquire)) {
            @atomicStore(bool, &self.terminal_resized, false, .release);
            try self.handleResize();
        }

        try self.log(last_action);

        last_action = try self.readNextAction();
        try line_editor.handleAction(self, last_action);
        try self.stdout().flush();
    }

    // restore terminal and exit immediately
    self.disableRawMode();
    self.setCursorStyle(.default) catch {};
    self.stdout().flush() catch {};
    if (self.history) |h| h.sync();
    std.process.exit(self.last_exit_code);
}

pub inline fn stdout(self: *Shell) *std.Io.Writer {
    return &self.stdout_writer.interface;
}

/// Diagnostics writer (fd 2). Flushes any pending buffered stdout first so a
/// preceding line of normal output still appears before the error, then writes
/// straight through (the stderr writer is unbuffered). Builtins send every
/// error here, matching bash — so `cmd 2>/dev/null` silences them and
/// `x=$(cmd)` does not capture them.
pub inline fn stderr(self: *Shell) *std.Io.Writer {
    self.stdout_writer.interface.flush() catch {};
    return &self.stderr_writer.interface;
}

/// Mark `name` as exported to child processes (idempotent; owns a copy of the
/// name). Called by `export` and for every variable inherited from the env.
pub fn markExported(self: *Shell, name: []const u8) !void {
    if (self.exported.contains(name)) return;
    const owned = try self.allocator.dupe(u8, name);
    errdefer self.allocator.free(owned);
    try self.exported.put(owned, {});
}

/// Whether `name` should be placed in a child process's environment.
pub fn isExported(self: *Shell, name: []const u8) bool {
    return self.exported.contains(name);
}

// cursor styles for vim modes
pub const CursorStyle = enum {
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

pub fn setCursorStyle(_: *Shell, style: CursorStyle) !void {
    // Write to stderr so it doesn't interfere with pipelines.
    //
    // Only when stderr is a terminal: cursor-shape control is meaningless to a
    // file or a pipe, and emitting it there corrupts whatever is reading. The
    // fuzz test binary hit exactly that — Shell.deinit reset the cursor into
    // the build runner's protocol stream and failed the step.
    if (!posix.isatty(posix.STDERR_FILENO)) return;
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
/// when terminal control is temporarily given to a child process group,
/// and SIGINT/SIGQUIT/SIGTSTP so that Ctrl+C/Ctrl+Z with the terminal in
/// cooked mode (while a foreground child runs, or in any race window at the
/// prompt) cannot kill or stop the shell itself. This is only called from
/// run(), so scripts keep default dispositions. Forked children reset all of
/// these to SIG_DFL before exec (jobs.resetChildSignals), so foreground
/// programs still receive Ctrl+C/Ctrl+Z normally. The `suspend_shell` action
/// and the executeExternal spawn path temporarily restore defaults around
/// their specific needs.
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

    // Ignore keyboard signals for the shell itself (bash does the same).
    posix.sigaction(posix.SIG.INT, &ignore_action, null);
    posix.sigaction(posix.SIG.QUIT, &ignore_action, null);
    posix.sigaction(posix.SIG.TSTP, &ignore_action, null);
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

/// Log every executed command with exit code and duration for training data.
pub fn logCommandExecution(command: []const u8, exit_code: u8, elapsed: i64) void {
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

fn readNextAction(self: *Shell) !Action {
    // Wait for input with poll() before reading, and let EINTR surface: a
    // SIGWINCH must return control to run()'s loop so it reflows the line at the
    // new width immediately (zsh-parity), not sit blocked until the next
    // keystroke. std.posix.poll and readStreaming both retry EINTR internally,
    // so use the libc poll directly — it returns -1/EINTR, and run() then sees
    // the terminal_resized flag on the next loop turn.
    var pfd = [_]std.c.pollfd{.{ .fd = std.posix.STDIN_FILENO, .events = std.c.POLL.IN, .revents = 0 }};
    const prc = std.c.poll(&pfd, 1, -1);
    if (prc <= 0) return .none; // EINTR (SIGWINCH) or spurious wake — loop again

    var temp_buf: [1]u8 = undefined;
    const count = try compat.readAll(std.Io.File.stdin(), temp_buf[0..]);
    const char = temp_buf[0];

    if (count == 0) return .none;

    // Always check for escape sequences (arrow keys, Ctrl+arrows, paste end, etc.)
    if (char == '\x1b') {
        return dispatch.escapeSequenceAction(self);
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

    // dispatch based on vim mode (mode-aware key routing lives in dispatch.zig)
    return switch (self.vim_mode) {
        .normal => dispatch.normalModeDispatch(self, char),
        .insert => dispatch.resolveInsertAction(self, char),
    };
}

// In vim normal mode the cursor rests ON a character, never past the end of
// its line. After a delete at end-of-line it can land on the newline/end, so
// pull it back onto the last character (no-op in insert mode or at line start).
pub fn clampCursorNormal(self: *Shell) void {
    if (self.vim_mode != .normal) return;
    const b = &self.edit_buf;
    const at_line_end = b.cursor >= b.len or b.text[b.cursor] == '\n';
    if (at_line_end and b.cursor > 0 and b.text[b.cursor - 1] != '\n') {
        _ = b.moveLeft();
    }
}

fn getSearchModeAction(self: *Shell, char: u8) Action {
    return switch (char) {
        '\n' => .{ .exit_search_mode = true },
        '\x1b' => .{ .exit_search_mode = false },
        CTRL_R => blk: {
            // Ctrl+R again: advance to the next (older) match
            self.search_index += 1;
            break :blk .search_next_match;
        },
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

    // enable bracketed paste mode (write to stderr to avoid capture by redirects,
    // and only when stderr is a terminal — see disableRawMode)
    if (posix.isatty(posix.STDERR_FILENO)) {
        _ = posix.write(posix.STDERR_FILENO, "\x1b[?2004h") catch {};
    }
}

/// Re-assert raw mode — termios only, no escape sequences (unlike
/// enableRawMode, which also toggles bracketed paste). A backstop: called after
/// every command so the line editor is guaranteed to read a raw terminal, even
/// if a command left it cooked or otherwise altered its modes. Without this the
/// prompt could get stuck echoing "^C" and line-buffering input — the shell
/// must own its input mode by construction, not trust every child to restore
/// it. Cheap enough to run per command; no per-keystroke cost.
pub fn ensureRawMode(self: *Shell) void {
    const orig = self.original_termios orelse return;
    var t = orig;
    t.lflag.ICANON = false;
    t.lflag.ECHO = false;
    t.lflag.ISIG = false;
    t.iflag.ICRNL = false;
    t.iflag.IXON = false;
    t.cc[@intFromEnum(posix.V.MIN)] = 1;
    t.cc[@intFromEnum(posix.V.TIME)] = 0;
    posix.tcsetattr(posix.STDIN_FILENO, .NOW, t) catch {};
}

pub fn disableRawMode(self: *Shell) void {
    // Disable bracketed paste mode. Written to stderr to avoid capture by
    // redirects, and only when stderr is a terminal: sending mode-switch
    // escapes to a pipe or file is noise at best and corrupts a structured
    // consumer at worst (this fired into the test runner's protocol stream).
    if (posix.isatty(posix.STDERR_FILENO)) {
        _ = posix.write(posix.STDERR_FILENO, "\x1b[?2004l") catch {};
    }

    if (self.original_termios) |original| {
        const stdin_fd = posix.STDIN_FILENO;
        posix.tcsetattr(stdin_fd, .NOW, original) catch {};
    }
}

pub fn handleHistoryNavigation(self: *Shell, direction: HistoryDirection) !void {
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

    // Sourcing the rc file is startup, not a command anyone ran. Entering it at
    // depth 1 keeps it out of the session trace, which should contain only what
    // the user or the driving harness actually submitted.
    self.exec_depth += 1;
    defer self.exec_depth -= 1;

    _ = self.executeCommand(source_cmd) catch {};
}

pub fn executeCommand(self: *Shell, command: []const u8) !u8 {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    if (trimmed.len == 0) return 0;

    // Session trace. Only the outermost call is recorded: this function
    // recurses for command substitution and PROMPT_COMMAND, and a harness
    // wants the command that was run, not its internals.
    const tracing = trace.enabled() and self.exec_depth == 0;
    const trace_start: i64 = if (tracing) compat.milliTimestamp() else 0;
    self.exec_depth += 1;
    defer self.exec_depth -= 1;

    // Delete any heredoc temp files this call materialises once it returns. The
    // mark makes nested executeCommand calls (command substitution,
    // PROMPT_COMMAND) clean up only their own files, not an outer call's.
    const hd_mark = self.heredoc_temps.items.len;
    defer heredoc.cleanupTemps(self.allocator, &self.heredoc_temps, hd_mark);

    // Preprocess heredoc: convert << DELIM ... DELIM to file redirect
    const processed = if (heredoc.findDelimiter(trimmed)) |delim|
        (if (heredoc.complete(trimmed, delim))
            heredoc.preprocess(self.allocator, &self.heredoc_temps, trimmed, delim) catch trimmed
        else
            trimmed)
    else
        trimmed;
    defer if (processed.ptr != trimmed.ptr) self.allocator.free(processed);

    const exit_code = try self.executeCommandInternal(processed);
    self.last_exit_code = exit_code;

    if (tracing) {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = compat.posix.getcwd(&cwd_buf) catch "";
        trace.record(self.allocator, trimmed, cwd, exit_code, trace_start, compat.milliTimestamp());
    }

    return exit_code;
}

// Delete and forget heredoc temp files recorded at or after `mark`.
/// Reap finished background jobs and print their "[N]+ Done ..." notices,
/// matching bash's behavior of checking job status right before a fresh
/// prompt. There is no SIGCHLD handler — the core is single-threaded and a
/// handler would add reentrancy hazards — so this synchronous poll at prompt
/// time is the only place background children get reaped and their
/// completion reported; without it they stay unreaped until `jobs`/`wait`
/// happens to run. Only called from the interactive prompt loop in run() and
/// right after a command finishes, never mid-line-edit, and never from
/// `zish -c` (which never reaches run()).
pub fn notifyBackgroundJobs(self: *Shell) void {
    self.job_table.updateJobStatuses();

    const pending = self.job_table.getPendingNotifications() catch return;
    defer self.allocator.free(pending);

    for (pending) |notif| {
        defer self.allocator.free(notif.command);

        const marker: u8 = if (self.job_table.current_job == notif.job_id)
            '+'
        else if (self.job_table.previous_job == notif.job_id)
            '-'
        else
            ' ';

        const line = switch (notif.state) {
            .done => if (notif.signaled)
                std.fmt.allocPrint(self.allocator, "[{d}]{c}  {s}              {s}\n", .{
                    notif.job_id, marker,
                    if (notif.term_signal == 9) "Killed" else "Terminated",
                    notif.command,
                }) catch continue
            else if (notif.exit_status == 0)
                std.fmt.allocPrint(self.allocator, "[{d}]{c}  Done                    {s}\n", .{
                    notif.job_id, marker, notif.command,
                }) catch continue
            else
                std.fmt.allocPrint(self.allocator, "[{d}]{c}  Exit {d}                  {s}\n", .{
                    notif.job_id, marker, notif.exit_status, notif.command,
                }) catch continue,
            .stopped => std.fmt.allocPrint(self.allocator, "[{d}]{c}  Stopped                 {s}\n", .{
                notif.job_id, marker, notif.command,
            }) catch continue,
            .running => continue,
        };
        defer self.allocator.free(line);
        // Through the shell's stderr writer (flushes pending stdout first) so the
        // notice lands cleanly before the next prompt, consistent with builtin
        // diagnostics.
        self.stderr().writeAll(line) catch {};
    }

    self.job_table.cleanupDoneJobs();
}

/// Run $PROMPT_COMMAND (if set) just before displaying an interactive prompt,
/// matching bash. $? is preserved across its execution.
pub fn runPromptCommand(self: *Shell) void {
    const pc = self.variables.get("PROMPT_COMMAND") orelse (posix.getenv("PROMPT_COMMAND") orelse return);
    if (pc.len == 0) return;
    // guard against re-entrancy (a PROMPT_COMMAND that itself triggers a prompt)
    if (self.in_prompt_command) return;
    self.in_prompt_command = true;
    defer self.in_prompt_command = false;
    // dupe: executing the command can mutate `variables` and reallocate the
    // hashmap, invalidating the pc slice.
    const cmd = self.allocator.dupe(u8, pc) catch return;
    const saved = self.last_exit_code;
    _ = self.executeCommand(cmd) catch {};
    self.allocator.free(cmd);
    self.last_exit_code = saved;
    // Flush its output so it lands before the prompt (drawn to stderr), matching
    // bash where PROMPT_COMMAND output precedes the prompt line.
    self.stdout().flush() catch {};
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
// Expansion character lookup table
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
    const expanded = try expand.allocOpt(self, input, true);
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
    const expanded = try expand.allocOpt(self, input, false);
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

    return expand.allocOpt(self, input, true);
}

pub fn evaluateArithmetic(self: *Shell, expr: []const u8) !i64 {
    return arith.evaluateArithmetic(self, expr);
}

pub fn executeCommandInternal(self: *Shell, command: []const u8) !u8 {
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
