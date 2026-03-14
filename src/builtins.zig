// builtins.zig - all shell builtin commands
const std = @import("std");
const Shell = @import("Shell.zig");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const input_mod = @import("input.zig");
const BindableAction = input_mod.BindableAction;
const editor = @import("editor.zig");
const audio_mod = @import("audio.zig");
const linkify = @import("linkify.zig");

// directory stack for pushd/popd
var dir_stack: std.ArrayList([]const u8) = undefined;
var dir_stack_initialized: bool = false;

fn ensureDirStack(allocator: std.mem.Allocator) void {
    if (!dir_stack_initialized) {
        dir_stack = std.ArrayList([]const u8){};
        dir_stack.ensureTotalCapacity(allocator, 8) catch {};
        dir_stack_initialized = true;
    }
}

/// Check if name is a builtin that dispatch() handles.
/// NOTE: This list must match what dispatch() below actually implements.
/// For syntax highlighting of standard bash builtins, see keywords.shell_builtins instead.
pub fn isBuiltin(name: []const u8) bool {
    // This list must stay in sync with dispatch() cases below
    const implemented_builtins = [_][]const u8{
        // simple returns
        "true", "false", ":", "continue", "break",
        // directory
        "cd", "pwd", "pushd", "popd", "dirs", "..", "...", "-",
        // io
        "echo", "printf", "read",
        // test
        "test", "[",
        // variables
        "export", "unset", "local", "declare", "readonly", "set", "shift", "getopts",
        // aliases
        "alias", "unalias",
        // source/eval/exec
        "source", ".", "eval", "exec",
        // info
        "type", "which", "hash", "history", "help",
        // job control
        "jobs", "fg", "bg", "wait", "kill", "disown", "trap",
        // shell control
        "exit", "return", "builtin", "command",
        // benchmarking
        "time",
        // zish specific (handled in eval.zig)
        "chpw",
        // agent
        "agent",
    };
    for (implemented_builtins) |b| {
        if (std.mem.eql(u8, name, b)) return true;
    }
    return false;
}

// main dispatch function - called from eval.zig
pub fn dispatch(shell: *Shell, cmd_name: []const u8, args: []const []const u8) !?u8 {
    // simple no-arg builtins
    if (std.mem.eql(u8, cmd_name, "true") or std.mem.eql(u8, cmd_name, ":")) return 0;
    if (std.mem.eql(u8, cmd_name, "false")) return 1;
    if (std.mem.eql(u8, cmd_name, "continue")) return 253;
    if (std.mem.eql(u8, cmd_name, "break")) return 254;

    // directory builtins
    if (std.mem.eql(u8, cmd_name, "cd")) return try cd(shell, args);
    if (std.mem.eql(u8, cmd_name, "pwd")) return try pwd(shell, args);
    if (std.mem.eql(u8, cmd_name, "pushd")) return try pushd(shell, args);
    if (std.mem.eql(u8, cmd_name, "popd")) return try popd(shell, args);
    if (std.mem.eql(u8, cmd_name, "dirs")) return try dirs(shell, args);
    if (std.mem.eql(u8, cmd_name, "..")) return try dotdot(shell);
    if (std.mem.eql(u8, cmd_name, "...")) return try dotdotdot(shell);
    if (std.mem.eql(u8, cmd_name, "-")) return try dash(shell);

    // io builtins
    if (std.mem.eql(u8, cmd_name, "echo")) return try echo(shell, args);
    if (std.mem.eql(u8, cmd_name, "printf")) return try printf(shell, args);
    if (std.mem.eql(u8, cmd_name, "read")) return try read(shell, args);

    // test builtin
    if (std.mem.eql(u8, cmd_name, "test") or std.mem.eql(u8, cmd_name, "[")) return try testCmd(shell, args);

    // variable builtins
    if (std.mem.eql(u8, cmd_name, "export")) return try exportVar(shell, args);
    if (std.mem.eql(u8, cmd_name, "unset")) return try unset(shell, args);
    if (std.mem.eql(u8, cmd_name, "local") or std.mem.eql(u8, cmd_name, "declare")) return try local(shell, args);
    if (std.mem.eql(u8, cmd_name, "readonly")) return try readonly(shell, args);
    if (std.mem.eql(u8, cmd_name, "set")) return try set(shell, args);
    if (std.mem.eql(u8, cmd_name, "shift")) return try shift(shell, args);
    if (std.mem.eql(u8, cmd_name, "getopts")) return try getopts(shell, args);

    // alias builtins
    if (std.mem.eql(u8, cmd_name, "alias")) return try alias(shell, args);
    if (std.mem.eql(u8, cmd_name, "unalias")) return try unalias(shell, args);

    // source/eval/exec
    if (std.mem.eql(u8, cmd_name, "source") or std.mem.eql(u8, cmd_name, ".")) return try source(shell, args);
    if (std.mem.eql(u8, cmd_name, "eval")) return try eval(shell, args);
    if (std.mem.eql(u8, cmd_name, "exec")) return try exec(shell, args);

    // info builtins
    if (std.mem.eql(u8, cmd_name, "type") or std.mem.eql(u8, cmd_name, "which")) return try typeCmd(shell, args);
    if (std.mem.eql(u8, cmd_name, "hash")) return try hash(shell, args);
    if (std.mem.eql(u8, cmd_name, "history")) return try history(shell, args);
    if (std.mem.eql(u8, cmd_name, "help")) return try help(shell, args);

    // job control
    if (std.mem.eql(u8, cmd_name, "jobs")) return try jobs(shell, args);
    if (std.mem.eql(u8, cmd_name, "fg")) return try fg(shell, args);
    if (std.mem.eql(u8, cmd_name, "bg")) return try bg(shell, args);
    if (std.mem.eql(u8, cmd_name, "wait")) return try wait(shell, args);
    if (std.mem.eql(u8, cmd_name, "kill")) return try kill(shell, args);
    if (std.mem.eql(u8, cmd_name, "disown")) return try disown(shell, args);
    if (std.mem.eql(u8, cmd_name, "trap")) return try trap(shell, args);

    // shell control
    if (std.mem.eql(u8, cmd_name, "exit")) return try exit(shell, args);
    if (std.mem.eql(u8, cmd_name, "return")) return try returnCmd(shell, args);
    if (std.mem.eql(u8, cmd_name, "builtin")) return try builtinCmd(shell, args);
    if (std.mem.eql(u8, cmd_name, "command")) return try commandCmd(shell, args);

    // benchmarking
    if (std.mem.eql(u8, cmd_name, "time")) return try timeCmd(shell, args);

    // zish specific
    if (std.mem.eql(u8, cmd_name, "chpw")) return null; // handled in eval.zig for now (complex)

    // agent
    if (std.mem.eql(u8, cmd_name, "agent")) return try agentCmd(shell, args);

    return null; // not a builtin
}

// ============ directory builtins ============

fn cd(shell: *Shell, args: []const []const u8) !u8 {
    // save current directory to OLDPWD
    var cwd_buf: [4096]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch "";

    const path = if (args.len > 1) blk: {
        const arg = args[1];
        // handle cd -
        if (std.mem.eql(u8, arg, "-")) {
            const oldpwd = shell.variables.get("OLDPWD") orelse
                std.posix.getenv("OLDPWD") orelse {
                try shell.stdout().writeAll("cd: OLDPWD not set\n");
                return 1;
            };
            try shell.stdout().print("{s}\n", .{oldpwd});
            break :blk oldpwd;
        }
        break :blk arg;
    } else blk: {
        break :blk std.posix.getenv("HOME") orelse {
            try shell.stdout().writeAll("cd: HOME not set\n");
            return 1;
        };
    };

    std.posix.chdir(path) catch {
        try shell.stdout().print("cd: {s}: no such file or directory\n", .{path});
        return 1;
    };

    // set OLDPWD after successful cd
    if (cwd.len > 0) {
        try setVar(shell, "OLDPWD", cwd);
    }
    return 0;
}

fn pwd(shell: *Shell, args: []const []const u8) !u8 {
    _ = args;
    var cwd_buf: [4096]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch {
        try shell.stdout().writeAll("pwd: cannot get current directory\n");
        return 1;
    };
    try shell.stdout().print("{s}\n", .{cwd});
    return 0;
}

fn dotdot(shell: *Shell) !u8 {
    std.posix.chdir("..") catch {
        try shell.stdout().writeAll("..: cannot go up\n");
        return 1;
    };
    return 0;
}

fn dotdotdot(shell: *Shell) !u8 {
    std.posix.chdir("../..") catch {
        try shell.stdout().writeAll("...: cannot go up\n");
        return 1;
    };
    return 0;
}

fn dash(shell: *Shell) !u8 {
    const oldpwd = shell.variables.get("OLDPWD") orelse
        std.posix.getenv("OLDPWD") orelse {
        try shell.stdout().writeAll("-: OLDPWD not set\n");
        return 1;
    };

    var cwd_buf: [4096]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch "";

    std.posix.chdir(oldpwd) catch {
        try shell.stdout().print("-: {s}: no such directory\n", .{oldpwd});
        return 1;
    };

    try setVar(shell, "OLDPWD", cwd);
    try shell.stdout().print("{s}\n", .{oldpwd});
    return 0;
}

pub fn pushd(shell: *Shell, args: []const []const u8) !u8 {
    ensureDirStack(shell.allocator);

    var cwd_buf: [4096]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch {
        try shell.stdout().writeAll("pushd: cannot get current directory\n");
        return 1;
    };

    if (args.len < 2) {
        if (dir_stack.items.len == 0) {
            try shell.stdout().writeAll("pushd: no other directory\n");
            return 1;
        }
        const top = dir_stack.pop() orelse {
            try shell.stdout().writeAll("pushd: no other directory\n");
            return 1;
        };
        std.posix.chdir(top) catch {
            try shell.stdout().print("pushd: {s}: no such directory\n", .{top});
            dir_stack.append(shell.allocator, top) catch {};
            return 1;
        };
        shell.allocator.free(@constCast(top)); // free the popped string after successful chdir
        try dir_stack.append(shell.allocator, try shell.allocator.dupe(u8, cwd));
        try printDirStack(shell);
        return 0;
    }

    const path = args[1];
    std.posix.chdir(path) catch {
        try shell.stdout().print("pushd: {s}: no such directory\n", .{path});
        return 1;
    };

    try dir_stack.append(shell.allocator, try shell.allocator.dupe(u8, cwd));
    try printDirStack(shell);
    return 0;
}

pub fn popd(shell: *Shell, args: []const []const u8) !u8 {
    _ = args;
    ensureDirStack(shell.allocator);

    if (dir_stack.items.len == 0) {
        try shell.stdout().writeAll("popd: directory stack empty\n");
        return 1;
    }

    const path = dir_stack.pop() orelse {
        try shell.stdout().writeAll("popd: directory stack empty\n");
        return 1;
    };
    defer shell.allocator.free(path);

    std.posix.chdir(path) catch {
        try shell.stdout().print("popd: {s}: no such directory\n", .{path});
        return 1;
    };

    try printDirStack(shell);
    return 0;
}

pub fn dirs(shell: *Shell, args: []const []const u8) !u8 {
    _ = args;
    ensureDirStack(shell.allocator);
    try printDirStack(shell);
    return 0;
}

fn printDirStack(shell: *Shell) !void {
    var cwd_buf: [4096]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch "";
    try shell.stdout().print("{s}", .{cwd});
    var i: usize = dir_stack.items.len;
    while (i > 0) {
        i -= 1;
        try shell.stdout().print(" {s}", .{dir_stack.items[i]});
    }
    try shell.stdout().writeAll("\n");
}

// ============ io builtins ============

fn echo(shell: *Shell, args: []const []const u8) !u8 {
    var interpret_escapes = false;
    var print_newline = true;
    var start: usize = 1;

    // parse flags
    while (start < args.len) {
        const arg = args[start];
        if (arg.len >= 2 and arg[0] == '-') {
            var valid = true;
            for (arg[1..]) |c| {
                switch (c) {
                    'e' => interpret_escapes = true,
                    'n' => print_newline = false,
                    'E' => interpret_escapes = false,
                    else => {
                        valid = false;
                        break;
                    },
                }
            }
            if (valid) {
                start += 1;
                continue;
            }
        }
        break;
    }

    // output args
    for (args[start..], 0..) |arg, i| {
        if (i > 0) try shell.stdout().writeAll(" ");
        if (interpret_escapes) {
            try writeEscaped(shell, arg);
        } else {
            try shell.stdout().writeAll(arg);
        }
    }
    if (print_newline) try shell.stdout().writeAll("\n");
    return 0;
}

fn writeEscaped(shell: *Shell, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            switch (s[i + 1]) {
                'n' => try shell.stdout().writeByte('\n'),
                't' => try shell.stdout().writeByte('\t'),
                'r' => try shell.stdout().writeByte('\r'),
                '\\' => try shell.stdout().writeByte('\\'),
                '0' => try shell.stdout().writeByte(0),
                else => {
                    try shell.stdout().writeByte(s[i]);
                    try shell.stdout().writeByte(s[i + 1]);
                },
            }
            i += 2;
        } else {
            try shell.stdout().writeByte(s[i]);
            i += 1;
        }
    }
}

fn printf(shell: *Shell, args: []const []const u8) !u8 {
    if (args.len < 2) {
        try shell.stdout().writeAll("printf: usage: printf format [arguments]\n");
        return 1;
    }

    const format = args[1];
    var arg_idx: usize = 2;
    const writer = shell.stdout();

    var i: usize = 0;
    while (i < format.len) {
        if (format[i] == '\\' and i + 1 < format.len) {
            const escaped = printfParseEscape(format[i + 1 ..]);
            try writer.writeByte(escaped.char);
            i += 1 + escaped.len;
        } else if (format[i] == '%') {
            const spec = printfParseSpec(format[i..]);
            if (spec.specifier == '%') {
                try writer.writeByte('%');
            } else {
                const arg = if (arg_idx < args.len) args[arg_idx] else "";
                if (arg_idx < args.len) arg_idx += 1;
                try printfFormatArg(writer, spec, arg);
            }
            i += spec.len;
        } else {
            try writer.writeByte(format[i]);
            i += 1;
        }
    }
    return 0;
}

const PrintfSpec = struct {
    specifier: u8,
    width: ?usize = null,
    precision: ?usize = null,
    left_align: bool = false,
    zero_pad: bool = false,
    len: usize,
};

fn printfParseSpec(fmt: []const u8) PrintfSpec {
    if (fmt.len < 2 or fmt[0] != '%') return .{ .specifier = 0, .len = 1 };

    var pos: usize = 1;
    var left_align = false;
    var zero_pad = false;

    // flags
    while (pos < fmt.len) {
        switch (fmt[pos]) {
            '-' => left_align = true,
            '0' => if (!left_align) {
                zero_pad = true;
            },
            '+', ' ', '#' => {},
            else => break,
        }
        pos += 1;
    }

    // width
    var width: ?usize = null;
    const width_start = pos;
    while (pos < fmt.len and fmt[pos] >= '0' and fmt[pos] <= '9') : (pos += 1) {}
    if (pos > width_start) {
        width = std.fmt.parseInt(usize, fmt[width_start..pos], 10) catch null;
    }

    // precision
    var precision: ?usize = null;
    if (pos < fmt.len and fmt[pos] == '.') {
        pos += 1;
        const prec_start = pos;
        while (pos < fmt.len and fmt[pos] >= '0' and fmt[pos] <= '9') : (pos += 1) {}
        precision = std.fmt.parseInt(usize, fmt[prec_start..pos], 10) catch 0;
    }

    // specifier
    const specifier: u8 = if (pos < fmt.len) fmt[pos] else 0;
    if (specifier != 0) pos += 1;

    return .{
        .specifier = specifier,
        .width = width,
        .precision = precision,
        .left_align = left_align,
        .zero_pad = zero_pad,
        .len = pos,
    };
}

fn printfFormatArg(writer: anytype, spec: PrintfSpec, arg: []const u8) !void {
    var buf: [64]u8 = undefined;
    var output: []const u8 = "";

    switch (spec.specifier) {
        's' => {
            output = if (spec.precision) |p| arg[0..@min(p, arg.len)] else arg;
        },
        'c' => {
            if (arg.len > 0) {
                // check if numeric
                if (std.fmt.parseInt(u8, arg, 0)) |code| {
                    buf[0] = code;
                    output = buf[0..1];
                } else |_| {
                    output = arg[0..1];
                }
            }
        },
        'd', 'i' => {
            const val = std.fmt.parseInt(i64, arg, 0) catch 0;
            output = std.fmt.bufPrint(&buf, "{d}", .{val}) catch "";
        },
        'u' => {
            const val = std.fmt.parseInt(u64, arg, 0) catch 0;
            output = std.fmt.bufPrint(&buf, "{d}", .{val}) catch "";
        },
        'x' => {
            const val = std.fmt.parseInt(u64, arg, 0) catch 0;
            output = std.fmt.bufPrint(&buf, "{x}", .{val}) catch "";
        },
        'X' => {
            const val = std.fmt.parseInt(u64, arg, 0) catch 0;
            output = std.fmt.bufPrint(&buf, "{X}", .{val}) catch "";
        },
        'o' => {
            const val = std.fmt.parseInt(u64, arg, 0) catch 0;
            output = std.fmt.bufPrint(&buf, "{o}", .{val}) catch "";
        },
        'f', 'e', 'g' => {
            const val = std.fmt.parseFloat(f64, arg) catch 0.0;
            const prec = spec.precision orelse 6;
            output = std.fmt.bufPrint(&buf, "{d:.6}", .{val}) catch blk: {
                // manual precision handling
                _ = prec;
                break :blk "";
            };
        },
        'b' => {
            // string with backslash escapes interpreted
            for (arg) |c| {
                if (c == '\\') continue; // simplified - just print
                try writer.writeByte(c);
            }
            return;
        },
        else => return,
    }

    // apply width padding
    const width = spec.width orelse 0;
    if (output.len >= width) {
        try writer.writeAll(output);
    } else {
        const pad_len = width - output.len;
        const pad_char: u8 = if (spec.zero_pad and !spec.left_align) '0' else ' ';
        if (spec.left_align) {
            try writer.writeAll(output);
            for (0..pad_len) |_| try writer.writeByte(pad_char);
        } else {
            for (0..pad_len) |_| try writer.writeByte(pad_char);
            try writer.writeAll(output);
        }
    }
}

const EscapeResult = struct { char: u8, len: usize };

fn printfParseEscape(s: []const u8) EscapeResult {
    if (s.len == 0) return .{ .char = '\\', .len = 0 };
    return switch (s[0]) {
        'n' => .{ .char = '\n', .len = 1 },
        't' => .{ .char = '\t', .len = 1 },
        'r' => .{ .char = '\r', .len = 1 },
        'a' => .{ .char = 0x07, .len = 1 },
        'b' => .{ .char = 0x08, .len = 1 },
        'f' => .{ .char = 0x0c, .len = 1 },
        'v' => .{ .char = 0x0b, .len = 1 },
        '\\' => .{ .char = '\\', .len = 1 },
        '0' => blk: {
            // octal \0nnn
            var val: u8 = 0;
            var len: usize = 1;
            while (len < 4 and len < s.len and s[len] >= '0' and s[len] <= '7') : (len += 1) {
                val = val *| 8 +| (s[len] - '0');
            }
            break :blk .{ .char = val, .len = len };
        },
        'x' => blk: {
            // hex \xNN
            if (s.len >= 3) {
                if (std.fmt.parseInt(u8, s[1..3], 16)) |val| {
                    break :blk .{ .char = val, .len = 3 };
                } else |_| {}
            }
            break :blk .{ .char = 'x', .len = 1 };
        },
        else => .{ .char = s[0], .len = 1 },
    };
}

fn read(shell: *Shell, args: []const []const u8) !u8 {
    // parse options
    var prompt: ?[]const u8 = null;
    var timeout_secs: ?u32 = null;
    var nchars: ?usize = null;
    var silent = false;
    var raw = false;
    var varnames_start: usize = 1;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (arg.len == 0 or arg[0] != '-') break;

        if (std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i >= args.len) {
                try shell.stdout().writeAll("read: -p requires prompt string\n");
                return 1;
            }
            prompt = args[i];
        } else if (std.mem.eql(u8, arg, "-t")) {
            i += 1;
            if (i >= args.len) {
                try shell.stdout().writeAll("read: -t requires timeout\n");
                return 1;
            }
            timeout_secs = std.fmt.parseInt(u32, args[i], 10) catch {
                try shell.stdout().writeAll("read: invalid timeout\n");
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "-n")) {
            i += 1;
            if (i >= args.len) {
                try shell.stdout().writeAll("read: -n requires count\n");
                return 1;
            }
            nchars = std.fmt.parseInt(usize, args[i], 10) catch {
                try shell.stdout().writeAll("read: invalid count\n");
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "-s")) {
            silent = true;
        } else if (std.mem.eql(u8, arg, "-r")) {
            raw = true;
        } else if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        } else {
            break; // not an option, must be varname
        }
        varnames_start = i + 1;
    }

    // need at least one variable name
    if (varnames_start >= args.len) {
        // default to REPLY if no varname given
        varnames_start = args.len;
    }

    // display prompt if given
    if (prompt) |p| {
        try shell.stdout().writeAll(p);
        shell.stdout().flush() catch {};
    }

    const stdin_fd = std.posix.STDIN_FILENO;

    // save terminal state for silent mode
    var orig_termios: ?std.posix.termios = null;
    if (silent and std.posix.isatty(stdin_fd)) {
        orig_termios = std.posix.tcgetattr(stdin_fd) catch null;
        if (orig_termios) |ot| {
            var new_termios = ot;
            new_termios.lflag.ECHO = false;
            std.posix.tcsetattr(stdin_fd, .NOW, new_termios) catch {};
        }
    }
    defer {
        if (orig_termios) |ot| {
            std.posix.tcsetattr(stdin_fd, .NOW, ot) catch {};
            // print newline since echo was off
            _ = std.posix.write(std.posix.STDOUT_FILENO, "\n") catch {};
        }
    }

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    const max_chars = nchars orelse (buf.len - 1);

    // set up timeout using poll
    const timeout_ms: i32 = if (timeout_secs) |t| @intCast(t * 1000) else -1;

    while (pos < max_chars) {
        // use poll for timeout support
        var fds = [_]std.posix.pollfd{.{
            .fd = stdin_fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};

        const poll_result = std.posix.poll(&fds, timeout_ms) catch return 1;
        if (poll_result == 0) {
            // timeout
            return 1;
        }

        var c: [1]u8 = undefined;
        const n = std.posix.read(stdin_fd, &c) catch return 1;
        if (n == 0) break; // EOF

        // handle newline (end of input unless -n specified)
        if (c[0] == '\n') {
            if (nchars == null) break;
            buf[pos] = c[0];
            pos += 1;
            continue;
        }

        // handle backslash escapes (unless -r)
        if (!raw and c[0] == '\\' and pos < max_chars) {
            // read next char
            const n2 = std.posix.read(stdin_fd, &c) catch break;
            if (n2 == 0) break;
            // in non-raw mode, backslash-newline continues line
            if (c[0] == '\n') continue;
            // otherwise keep the escaped char
        }

        buf[pos] = c[0];
        pos += 1;

        // if -n specified and we hit the count, stop
        if (nchars != null and pos >= max_chars) break;
    }

    const value = buf[0..pos];

    // assign to variable(s)
    if (varnames_start < args.len) {
        // single variable gets whole line
        try setVar(shell, args[varnames_start], value);
        // TODO: multiple variables split on IFS
    } else {
        // no variable specified, use REPLY
        try setVar(shell, "REPLY", value);
    }

    return 0;
}

// ============ test builtin ============

fn testCmd(shell: *Shell, args: []const []const u8) !u8 {
    _ = shell;
    if (args.len < 2) return 1;

    var test_args = args[1..];

    // handle [ ... ] syntax - remove trailing ]
    if (args[0].len == 1 and args[0][0] == '[') {
        if (test_args.len > 0 and std.mem.eql(u8, test_args[test_args.len - 1], "]")) {
            test_args = test_args[0 .. test_args.len - 1];
        }
    }

    if (test_args.len == 0) return 1;

    // unary operators
    if (test_args.len == 2) {
        const op = test_args[0];
        const arg = test_args[1];

        if (std.mem.eql(u8, op, "-n")) return if (arg.len > 0) 0 else 1;
        if (std.mem.eql(u8, op, "-z")) return if (arg.len == 0) 0 else 1;
        if (std.mem.eql(u8, op, "-d")) {
            var dir = std.fs.cwd().openDir(arg, .{}) catch return 1;
            dir.close();
            return 0;
        }
        if (std.mem.eql(u8, op, "-f")) {
            const stat = std.fs.cwd().statFile(arg) catch return 1;
            return if (stat.kind == .file) 0 else 1;
        }
        if (std.mem.eql(u8, op, "-e")) {
            std.fs.cwd().access(arg, .{}) catch return 1;
            return 0;
        }
        if (std.mem.eql(u8, op, "-r") or std.mem.eql(u8, op, "-w") or std.mem.eql(u8, op, "-x")) {
            std.fs.cwd().access(arg, .{}) catch return 1;
            return 0;
        }
        if (std.mem.eql(u8, op, "-s")) {
            const stat = std.fs.cwd().statFile(arg) catch return 1;
            return if (stat.size > 0) 0 else 1;
        }
        if (std.mem.eql(u8, op, "-L") or std.mem.eql(u8, op, "-h")) {
            const stat = std.fs.cwd().statFile(arg) catch return 1;
            return if (stat.kind == .sym_link) 0 else 1;
        }
    }

    // single arg: true if non-empty
    if (test_args.len == 1) {
        return if (test_args[0].len > 0) 0 else 1;
    }

    // binary operators
    if (test_args.len >= 3) {
        const left = test_args[0];
        const op = test_args[1];
        const right = test_args[2];

        // string comparison
        if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) {
            return if (std.mem.eql(u8, left, right)) 0 else 1;
        }
        if (std.mem.eql(u8, op, "!=")) {
            return if (!std.mem.eql(u8, left, right)) 0 else 1;
        }

        // integer comparison
        const l = std.fmt.parseInt(i64, left, 10) catch 0;
        const r = std.fmt.parseInt(i64, right, 10) catch 0;

        if (std.mem.eql(u8, op, "-eq")) return if (l == r) 0 else 1;
        if (std.mem.eql(u8, op, "-ne")) return if (l != r) 0 else 1;
        if (std.mem.eql(u8, op, "-lt")) return if (l < r) 0 else 1;
        if (std.mem.eql(u8, op, "-le")) return if (l <= r) 0 else 1;
        if (std.mem.eql(u8, op, "-gt")) return if (l > r) 0 else 1;
        if (std.mem.eql(u8, op, "-ge")) return if (l >= r) 0 else 1;
    }

    return 1;
}

// ============ variable builtins ============

fn exportVar(shell: *Shell, args: []const []const u8) !u8 {
    for (args[1..]) |arg| {
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
            const name = arg[0..eq_pos];
            const value = arg[eq_pos + 1 ..];
            try setVar(shell, name, value);
        } else {
            try shell.stdout().print("export: {s}: not a valid identifier\n", .{arg});
            return 1;
        }
    }
    return 0;
}

fn unset(shell: *Shell, args: []const []const u8) !u8 {
    for (args[1..]) |arg| {
        if (shell.variables.fetchRemove(arg)) |kv| {
            shell.allocator.free(kv.key);
            shell.allocator.free(kv.value);
        }
    }
    return 0;
}

fn local(shell: *Shell, args: []const []const u8) !u8 {
    for (args[1..]) |arg| {
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
            const name = arg[0..eq_pos];
            const value = arg[eq_pos + 1 ..];
            try setVar(shell, name, value);
        } else {
            try setVar(shell, arg, "");
        }
    }
    return 0;
}

fn readonly(shell: *Shell, args: []const []const u8) !u8 {
    // simplified: just set the variable (no actual readonly enforcement)
    return local(shell, args);
}

fn set(shell: *Shell, args: []const []const u8) !u8 {
    // no args: show current options
    if (args.len < 2) {
        try shell.stdout().print("errexit\t{s}\n", .{if (shell.opt_errexit) "on" else "off"});
        try shell.stdout().print("nounset\t{s}\n", .{if (shell.opt_nounset) "on" else "off"});
        try shell.stdout().print("xtrace\t{s}\n", .{if (shell.opt_xtrace) "on" else "off"});
        try shell.stdout().print("pipefail\t{s}\n", .{if (shell.opt_pipefail) "on" else "off"});
        return 0;
    }

    // set -- arg1 arg2 ... sets positional parameters
    if (std.mem.eql(u8, args[1], "--")) {
        // clear existing positional parameters
        var i: usize = 1;
        while (i <= 99) : (i += 1) {
            var num_buf: [16]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch break;
            if (shell.variables.fetchRemove(num_str)) |kv| {
                shell.allocator.free(kv.key);
                shell.allocator.free(kv.value);
            } else break;
        }
        // set new positional parameters
        for (args[2..], 1..) |arg, idx| {
            var num_buf: [16]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{idx}) catch continue;
            try setVar(shell, num_str, arg);
        }
        // set $#
        var count_buf: [16]u8 = undefined;
        const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{args.len - 2}) catch "0";
        try setVar(shell, "#", count_str);
        return 0;
    }

    // process each argument
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        // handle -o option_name / +o option_name
        if ((arg.len == 2 and arg[0] == '-' and arg[1] == 'o') or
            (arg.len == 2 and arg[0] == '+' and arg[1] == 'o'))
        {
            const enable = arg[0] == '-';
            i += 1;
            if (i >= args.len) {
                try shell.stdout().writeAll("set: -o requires option name\n");
                return 1;
            }
            const opt_name = args[i];
            if (std.mem.eql(u8, opt_name, "errexit")) {
                shell.opt_errexit = enable;
            } else if (std.mem.eql(u8, opt_name, "nounset")) {
                shell.opt_nounset = enable;
            } else if (std.mem.eql(u8, opt_name, "xtrace")) {
                shell.opt_xtrace = enable;
            } else if (std.mem.eql(u8, opt_name, "pipefail")) {
                shell.opt_pipefail = enable;
            } else {
                try shell.stdout().print("set: unknown option: {s}\n", .{opt_name});
                return 1;
            }
            continue;
        }

        // handle -euxo / +eux style options
        if (arg.len >= 2 and (arg[0] == '-' or arg[0] == '+')) {
            const enable = arg[0] == '-';
            for (arg[1..]) |c| {
                switch (c) {
                    'e' => shell.opt_errexit = enable,
                    'u' => shell.opt_nounset = enable,
                    'x' => shell.opt_xtrace = enable,
                    'o' => {}, // handled above as -o name
                    else => {
                        try shell.stdout().print("set: invalid option: -{c}\n", .{c});
                        return 1;
                    },
                }
            }
            continue;
        }

        // legacy style: set option [on|off]
        const value = if (i + 1 < args.len) args[i + 1] else "on";
        const enabled = std.mem.eql(u8, value, "on") or std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true");

        if (std.mem.eql(u8, arg, "git_prompt")) {
            shell.show_git_info = enabled;
            if (i + 1 < args.len) i += 1;
        } else if (std.mem.eql(u8, arg, "errexit")) {
            shell.opt_errexit = enabled;
            if (i + 1 < args.len) i += 1;
        } else if (std.mem.eql(u8, arg, "nounset")) {
            shell.opt_nounset = enabled;
            if (i + 1 < args.len) i += 1;
        } else if (std.mem.eql(u8, arg, "xtrace")) {
            shell.opt_xtrace = enabled;
            if (i + 1 < args.len) i += 1;
        } else if (std.mem.eql(u8, arg, "pipefail")) {
            shell.opt_pipefail = enabled;
            if (i + 1 < args.len) i += 1;
        } else if (std.mem.eql(u8, arg, "autosuggestion") or std.mem.eql(u8, arg, "ghost")) {
            shell.opt_autosuggestion = enabled;
            if (i + 1 < args.len) i += 1;
        } else {
            try shell.stdout().print("set: unknown option: {s}\n", .{arg});
            return 1;
        }
    }

    return 0;
}

fn shift(shell: *Shell, args: []const []const u8) !u8 {
    const n: usize = if (args.len > 1)
        std.fmt.parseInt(usize, args[1], 10) catch 1
    else
        1;

    const argc_str = shell.variables.get("#") orelse "0";
    const argc = std.fmt.parseInt(usize, argc_str, 10) catch 0;

    if (n > argc) {
        try shell.stdout().print("shift: {d}: shift count out of range\n", .{n});
        return 1;
    }

    // shift: $2 -> $1, $3 -> $2, etc
    var i: usize = 1;
    while (i <= argc - n) : (i += 1) {
        var src_buf: [16]u8 = undefined;
        var dst_buf: [16]u8 = undefined;
        const src_str = std.fmt.bufPrint(&src_buf, "{d}", .{i + n}) catch continue;
        const dst_str = std.fmt.bufPrint(&dst_buf, "{d}", .{i}) catch continue;

        if (shell.variables.get(src_str)) |value| {
            try setVar(shell, dst_str, value);
        }
    }

    // remove extra parameters
    i = argc - n + 1;
    while (i <= argc) : (i += 1) {
        var num_buf: [16]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch continue;
        if (shell.variables.fetchRemove(num_str)) |old| {
            shell.allocator.free(old.key);
            shell.allocator.free(old.value);
        }
    }

    // update $#
    var count_buf: [16]u8 = undefined;
    const new_count = std.fmt.bufPrint(&count_buf, "{d}", .{argc - n}) catch "0";
    try setVar(shell, "#", new_count);

    return 0;
}

fn getopts(shell: *Shell, args: []const []const u8) !u8 {
    if (args.len < 3) {
        try shell.stdout().writeAll("getopts: usage: getopts optstring name\n");
        return 1;
    }

    const optstring = args[1];
    const varname = args[2];

    const optind_str = shell.variables.get("OPTIND") orelse "1";
    var optind = std.fmt.parseInt(usize, optind_str, 10) catch 1;

    var idx_buf: [16]u8 = undefined;
    const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{optind}) catch return 1;
    const arg = shell.variables.get(idx_str) orelse return 1;

    if (arg.len < 2 or arg[0] != '-') return 1;

    const opt = arg[1];

    var valid = false;
    var needs_arg = false;
    for (optstring, 0..) |c, i| {
        if (c == opt) {
            valid = true;
            if (i + 1 < optstring.len and optstring[i + 1] == ':') {
                needs_arg = true;
            }
            break;
        }
    }

    if (!valid) {
        try setVar(shell, varname, "?");
        try setVar(shell, "OPTARG", "");
        optind += 1;
        try setOptind(shell, optind);
        return 0;
    }

    var opt_buf: [2]u8 = .{ opt, 0 };
    try setVar(shell, varname, opt_buf[0..1]);

    if (needs_arg) {
        if (arg.len > 2) {
            try setVar(shell, "OPTARG", arg[2..]);
            optind += 1;
        } else {
            optind += 1;
            var next_buf: [16]u8 = undefined;
            const next_str = std.fmt.bufPrint(&next_buf, "{d}", .{optind}) catch return 1;
            const next_arg = shell.variables.get(next_str) orelse {
                try shell.stdout().print("getopts: option requires argument -- {c}\n", .{opt});
                return 1;
            };
            try setVar(shell, "OPTARG", next_arg);
            optind += 1;
        }
    } else {
        try setVar(shell, "OPTARG", "");
        optind += 1;
    }

    try setOptind(shell, optind);
    return 0;
}

// ============ alias builtins ============

fn alias(shell: *Shell, args: []const []const u8) !u8 {
    if (args.len == 1) {
        var iter = shell.aliases.iterator();
        while (iter.next()) |entry| {
            try shell.stdout().print("alias {s}='{s}'\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        return 0;
    }

    for (args[1..]) |arg| {
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
            const name = arg[0..eq_pos];
            var value = arg[eq_pos + 1 ..];

            // remove quotes if present
            if (value.len >= 2) {
                if ((value[0] == '\'' and value[value.len - 1] == '\'') or
                    (value[0] == '"' and value[value.len - 1] == '"'))
                {
                    value = value[1 .. value.len - 1];
                }
            }

            const name_copy = try shell.allocator.dupe(u8, name);
            const value_copy = try shell.allocator.dupe(u8, value);

            if (shell.aliases.fetchRemove(name_copy)) |old| {
                shell.allocator.free(old.key);
                shell.allocator.free(old.value);
            }

            try shell.aliases.put(name_copy, value_copy);
        } else {
            if (shell.aliases.get(arg)) |value| {
                try shell.stdout().print("alias {s}='{s}'\n", .{ arg, value });
            } else {
                try shell.stdout().print("alias: {s}: not found\n", .{arg});
                return 1;
            }
        }
    }
    return 0;
}

fn unalias(shell: *Shell, args: []const []const u8) !u8 {
    for (args[1..]) |arg| {
        if (shell.aliases.fetchRemove(arg)) |old| {
            shell.allocator.free(old.key);
            shell.allocator.free(old.value);
        }
    }
    return 0;
}

// ============ source/eval/exec ============

fn source(shell: *Shell, args: []const []const u8) !u8 {
    if (args.len < 2) {
        try shell.stdout().print("{s}: filename argument required\n", .{args[0]});
        return 1;
    }
    const filename = args[1];

    const file = std.fs.cwd().openFile(filename, .{}) catch {
        try shell.stdout().print("{s}: {s}: No such file or directory\n", .{ args[0], filename });
        return 1;
    };
    defer file.close();

    const content = file.readToEndAlloc(shell.allocator, 1024 * 1024) catch {
        try shell.stdout().print("{s}: {s}: Error reading file\n", .{ args[0], filename });
        return 1;
    };
    defer shell.allocator.free(content);

    // set positional parameters from remaining args
    for (args[2..], 1..) |arg, i| {
        var num_buf: [16]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch continue;
        try setVar(shell, num_str, arg);
    }

    var p = parser.Parser.init(content, shell.allocator) catch {
        try shell.stdout().print("{s}: {s}: Parse error\n", .{ args[0], filename });
        return 1;
    };
    defer p.deinit();

    const tree = p.parse() catch {
        try shell.stdout().print("{s}: {s}: Syntax error\n", .{ args[0], filename });
        return 1;
    };

    const eval_mod = @import("eval.zig");
    return try eval_mod.evaluateAst(shell, tree);
}

fn eval(shell: *Shell, args: []const []const u8) !u8 {
    if (args.len < 2) return 0;

    var total_len: usize = 0;
    for (args[1..]) |arg| {
        total_len += arg.len + 1;
    }

    const cmd = try shell.allocator.alloc(u8, total_len);
    defer shell.allocator.free(cmd);

    var pos: usize = 0;
    for (args[1..], 0..) |arg, i| {
        @memcpy(cmd[pos..][0..arg.len], arg);
        pos += arg.len;
        if (i < args.len - 2) {
            cmd[pos] = ' ';
            pos += 1;
        }
    }

    var p = parser.Parser.init(cmd[0..pos], shell.allocator) catch return 1;
    defer p.deinit();

    const tree = p.parse() catch {
        try shell.stdout().writeAll("eval: parse error\n");
        return 1;
    };

    const eval_mod = @import("eval.zig");
    return try eval_mod.evaluateAst(shell, tree);
}

fn exec(shell: *Shell, args: []const []const u8) !u8 {
    if (args.len < 2) {
        try shell.stdout().writeAll("exec: usage: exec command [arguments]\n");
        return 1;
    }

    const cmd_name = args[1];
    const full_path = shell.lookupCommand(cmd_name) orelse cmd_name;

    var argv_buf: [256]?[*:0]const u8 = undefined;
    var arg_count: usize = 0;

    for (args[1..]) |arg| {
        if (arg_count >= 255) break;
        const duped = try shell.allocator.dupeZ(u8, arg);
        argv_buf[arg_count] = duped.ptr;
        arg_count += 1;
    }
    argv_buf[arg_count] = null;

    const argv = argv_buf[0..arg_count :null];
    const envp = @as([*:null]const ?[*:0]const u8, @ptrCast(std.os.environ.ptr));

    const path_z = try shell.allocator.dupeZ(u8, full_path);
    std.posix.execvpeZ(path_z.ptr, argv, envp) catch {
        shell.stdout().print("exec: {s}: command not found\n", .{cmd_name}) catch {};
        std.posix.exit(126);
    };
    unreachable;
}

// ============ info builtins ============

fn typeCmd(shell: *Shell, args: []const []const u8) !u8 {
    if (args.len < 2) {
        try shell.stdout().writeAll("type: usage: type name [name ...]\n");
        return 1;
    }

    var ret: u8 = 0;
    for (args[1..]) |name| {
        if (shell.aliases.get(name)) |value| {
            try shell.stdout().print("{s} is aliased to '{s}'\n", .{ name, value });
            continue;
        }

        if (shell.functions.get(name)) |_| {
            try shell.stdout().print("{s} is a shell function\n", .{name});
            continue;
        }

        if (isBuiltin(name)) {
            try shell.stdout().print("{s} is a shell builtin\n", .{name});
            continue;
        }

        if (shell.lookupCommand(name)) |path| {
            try shell.stdout().print("{s} is {s}\n", .{ name, path });
            continue;
        }

        try shell.stdout().print("type: {s}: not found\n", .{name});
        ret = 1;
    }
    return ret;
}

fn hash(shell: *Shell, args: []const []const u8) !u8 {
    if (args.len < 2) {
        var iter = shell.path_cache.iterator();
        while (iter.next()) |entry| {
            try shell.stdout().print("{s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        return 0;
    }

    const arg = args[1];
    if (std.mem.eql(u8, arg, "-r")) {
        var iter = shell.path_cache.iterator();
        while (iter.next()) |entry| {
            shell.allocator.free(entry.key_ptr.*);
            shell.allocator.free(entry.value_ptr.*);
        }
        shell.path_cache.clearRetainingCapacity();
        return 0;
    }

    for (args[1..]) |name| {
        if (shell.lookupCommand(name)) |path| {
            try shell.stdout().print("{s}={s}\n", .{ name, path });
        } else {
            try shell.stdout().print("hash: {s}: not found\n", .{name});
        }
    }
    return 0;
}

fn history(shell: *Shell, args: []const []const u8) !u8 {
    _ = args;
    const h = shell.history orelse {
        try shell.stdout().writeAll("history: not available\n");
        return 1;
    };

    for (h.entries.items, 1..) |entry, i| {
        const cmd = h.getCommand(entry);
        try shell.stdout().print("{d}  {s}\n", .{ i, cmd });
    }
    return 0;
}

fn help(shell: *Shell, args: []const []const u8) !u8 {
    _ = args;
    try shell.stdout().writeAll(
        \\zish builtins:
        \\  cd, pwd, pushd, popd, dirs    directory navigation
        \\  echo, printf, read            i/o
        \\  export, unset, set, local     variables
        \\  alias, unalias                aliases
        \\  source, eval, exec            execution
        \\  type, hash, history           info
        \\  jobs, fg, bg, wait, disown    job control
        \\  test, [, true, false          conditionals
        \\  shift, getopts                argument handling
        \\
    );
    return 0;
}

// ============ job control ============

fn jobs(shell: *Shell, args: []const []const u8) !u8 {
    const verbose = args.len > 1 and std.mem.eql(u8, args[1], "-l");

    // Update job statuses first
    shell.job_table.updateJobStatuses();

    if (shell.job_table.jobs.items.len == 0) {
        return 0; // no jobs, silent success (like bash)
    }

    for (shell.job_table.jobs.items) |*job| {
        try shell.job_table.formatJob(job, shell.stdout(), verbose);
    }

    // Clean up done jobs after displaying
    shell.job_table.cleanupDoneJobs();

    return 0;
}

fn fg(shell: *Shell, args: []const []const u8) !u8 {
    // Update job statuses
    shell.job_table.updateJobStatuses();

    var job: ?*@import("jobs.zig").Job = null;

    if (args.len > 1) {
        // Parse job spec: %1, %+, %-, or just number
        const spec = args[1];
        if (spec[0] == '%') {
            if (spec.len == 1 or spec[1] == '+' or spec[1] == '%') {
                job = shell.job_table.getCurrentJob();
            } else if (spec[1] == '-') {
                if (shell.job_table.previous_job) |id| {
                    job = shell.job_table.getJob(id);
                }
            } else {
                const job_id = std.fmt.parseInt(u32, spec[1..], 10) catch {
                    try shell.stdout().print("fg: {s}: no such job\n", .{spec});
                    return 1;
                };
                job = shell.job_table.getJob(job_id);
            }
        } else {
            // Assume it's a job number
            const job_id = std.fmt.parseInt(u32, spec, 10) catch {
                try shell.stdout().print("fg: {s}: no such job\n", .{spec});
                return 1;
            };
            job = shell.job_table.getJob(job_id);
        }
    } else {
        // No args: use current job
        job = shell.job_table.getCurrentJob();
    }

    if (job == null) {
        try shell.stdout().writeAll("fg: no current job\n");
        return 1;
    }

    const j = job.?;
    try shell.stdout().print("{s}\n", .{j.command});

    // Disable raw mode before giving terminal to job
    shell.disableRawMode();

    // Put job in foreground and wait
    const status = shell.job_table.putJobInForeground(j, j.state == .stopped) catch |err| {
        try shell.stdout().print("fg: failed to put job in foreground: {}\n", .{err});
        shell.enableRawMode() catch {};
        return 1;
    };

    // Re-enable raw mode
    shell.enableRawMode() catch {};

    // If job completed, remove it
    if (j.isCompleted()) {
        shell.job_table.removeJob(j.id);
    }

    return @truncate(@as(u32, @bitCast(status)));
}

fn bg(shell: *Shell, args: []const []const u8) !u8 {
    // Update job statuses
    shell.job_table.updateJobStatuses();

    var job: ?*@import("jobs.zig").Job = null;

    if (args.len > 1) {
        const spec = args[1];
        if (spec[0] == '%') {
            if (spec.len == 1 or spec[1] == '+' or spec[1] == '%') {
                job = shell.job_table.getCurrentJob();
            } else if (spec[1] == '-') {
                if (shell.job_table.previous_job) |id| {
                    job = shell.job_table.getJob(id);
                }
            } else {
                const job_id = std.fmt.parseInt(u32, spec[1..], 10) catch {
                    try shell.stdout().print("bg: {s}: no such job\n", .{spec});
                    return 1;
                };
                job = shell.job_table.getJob(job_id);
            }
        } else {
            const job_id = std.fmt.parseInt(u32, spec, 10) catch {
                try shell.stdout().print("bg: {s}: no such job\n", .{spec});
                return 1;
            };
            job = shell.job_table.getJob(job_id);
        }
    } else {
        job = shell.job_table.getCurrentJob();
    }

    if (job == null) {
        try shell.stdout().writeAll("bg: no current job\n");
        return 1;
    }

    const j = job.?;

    if (j.state != .stopped) {
        try shell.stdout().print("bg: job {d} already in background\n", .{j.id});
        return 0;
    }

    try shell.stdout().print("[{d}]+ {s} &\n", .{ j.id, j.command });

    // Put job in background and continue it
    shell.job_table.putJobInBackground(j, true);

    return 0;
}

fn wait(shell: *Shell, args: []const []const u8) !u8 {
    if (args.len > 1) {
        // Wait for specific job/pid
        const spec = args[1];
        var pid: std.posix.pid_t = 0;

        if (spec[0] == '%') {
            // Job spec
            const job_id = std.fmt.parseInt(u32, spec[1..], 10) catch {
                try shell.stdout().print("wait: {s}: no such job\n", .{spec});
                return 127;
            };
            if (shell.job_table.getJob(job_id)) |job| {
                pid = job.pgid;
            } else {
                try shell.stdout().print("wait: {s}: no such job\n", .{spec});
                return 127;
            }
        } else {
            pid = std.fmt.parseInt(std.posix.pid_t, spec, 10) catch {
                try shell.stdout().print("wait: {s}: invalid pid\n", .{spec});
                return 1;
            };
        }

        // Wait for specific process/group
        const result = std.posix.waitpid(pid, 0);
        if (result.pid > 0) {
            shell.job_table.markProcessStatus(result.pid, result.status);
            return @truncate(std.posix.W.EXITSTATUS(result.status));
        }
    } else {
        // Wait for all background jobs
        while (true) {
            const result = std.posix.waitpid(-1, 0);
            if (result.pid <= 0) break;
            shell.job_table.markProcessStatus(result.pid, result.status);
        }
        shell.job_table.cleanupDoneJobs();
    }
    return 0;
}

fn kill(shell: *Shell, args: []const []const u8) !u8 {
    if (args.len < 2) {
        try shell.stdout().writeAll("kill: usage: kill [-signal] pid\n");
        return 1;
    }

    var sig: u8 = 15; // SIGTERM default
    var pid_start: usize = 1;

    // check for -l (list signals)
    if (std.mem.eql(u8, args[1], "-l")) {
        try shell.stdout().writeAll("HUP INT QUIT ILL TRAP ABRT IOT BUS FPE KILL USR1 SEGV USR2 PIPE ALRM\n");
        try shell.stdout().writeAll("TERM STKFLT CHLD CLD CONT STOP TSTP TTIN TTOU URG XCPU XFSZ VTALRM PROF\n");
        try shell.stdout().writeAll("WINCH IO POLL PWR SYS RT<N> RTMIN+<N> RTMAX-<N>\n");
        return 0;
    }

    // parse signal
    if (args[1][0] == '-') {
        const sig_str = args[1][1..];
        sig = std.fmt.parseInt(u8, sig_str, 10) catch blk: {
            // named signals
            if (std.mem.eql(u8, sig_str, "HUP")) break :blk 1;
            if (std.mem.eql(u8, sig_str, "INT")) break :blk 2;
            if (std.mem.eql(u8, sig_str, "QUIT")) break :blk 3;
            if (std.mem.eql(u8, sig_str, "KILL")) break :blk 9;
            if (std.mem.eql(u8, sig_str, "TERM")) break :blk 15;
            if (std.mem.eql(u8, sig_str, "STOP")) break :blk 19;
            if (std.mem.eql(u8, sig_str, "CONT")) break :blk 18;
            try shell.stdout().print("kill: invalid signal: {s}\n", .{sig_str});
            return 1;
        };
        pid_start = 2;
    }

    for (args[pid_start..]) |pid_str| {
        const pid = std.fmt.parseInt(std.posix.pid_t, pid_str, 10) catch {
            try shell.stdout().print("kill: invalid pid: {s}\n", .{pid_str});
            return 1;
        };
        const result = std.os.linux.kill(pid, sig);
        if (result != 0) {
            try shell.stdout().print("kill: {d}: operation not permitted\n", .{pid});
            return 1;
        }
    }
    return 0;
}

fn disown(shell: *Shell, args: []const []const u8) !u8 {
    // disown [-h] [-ar] [jobspec ...]
    // -h: mark jobs to not receive SIGHUP
    // -a: remove all jobs
    // -r: remove only running jobs

    var remove_all = false;
    var running_only = false;
    var job_specs_start: usize = 1;

    // Parse flags
    while (job_specs_start < args.len) {
        const arg = args[job_specs_start];
        if (arg.len > 0 and arg[0] == '-') {
            for (arg[1..]) |c| {
                switch (c) {
                    'a' => remove_all = true,
                    'r' => running_only = true,
                    'h' => {}, // mark to not receive SIGHUP (no-op for now)
                    else => {
                        try shell.stdout().print("disown: invalid option: -{c}\n", .{c});
                        return 1;
                    },
                }
            }
            job_specs_start += 1;
        } else {
            break;
        }
    }

    if (remove_all) {
        // Remove all jobs (or only running ones if -r)
        var i: usize = 0;
        while (i < shell.job_table.jobs.items.len) {
            const job = &shell.job_table.jobs.items[i];
            if (!running_only or job.state == .running) {
                var removed = shell.job_table.jobs.orderedRemove(i);
                removed.deinit(shell.allocator);
                // Don't increment i since we removed an item
            } else {
                i += 1;
            }
        }
        return 0;
    }

    // Remove specific jobs
    if (job_specs_start >= args.len) {
        // No job spec: remove current job
        if (shell.job_table.getCurrentJob()) |job| {
            shell.job_table.removeJob(job.id);
        } else {
            try shell.stdout().writeAll("disown: no current job\n");
            return 1;
        }
        return 0;
    }

    // Process each job spec
    for (args[job_specs_start..]) |spec| {
        var job_id: ?u32 = null;

        if (spec[0] == '%') {
            if (spec.len == 1 or spec[1] == '+' or spec[1] == '%') {
                if (shell.job_table.getCurrentJob()) |job| {
                    job_id = job.id;
                }
            } else if (spec[1] == '-') {
                job_id = shell.job_table.previous_job;
            } else {
                job_id = std.fmt.parseInt(u32, spec[1..], 10) catch null;
            }
        } else {
            job_id = std.fmt.parseInt(u32, spec, 10) catch null;
        }

        if (job_id) |id| {
            if (shell.job_table.getJob(id)) |job| {
                if (!running_only or job.state == .running) {
                    shell.job_table.removeJob(id);
                }
            } else {
                try shell.stdout().print("disown: {s}: no such job\n", .{spec});
            }
        } else {
            try shell.stdout().print("disown: {s}: no such job\n", .{spec});
        }
    }

    return 0;
}

fn trap(shell: *Shell, args: []const []const u8) !u8 {
    const TrapTable = Shell.TrapTable;

    // trap (no args) - list all traps
    if (args.len == 1) {
        inline for (std.meta.fields(TrapTable.Signal)) |field| {
            const sig: TrapTable.Signal = @enumFromInt(field.value);
            if (shell.traps.get(sig)) |cmd| {
                try shell.stdout().print("trap -- '{s}' {s}\n", .{ cmd, field.name });
            }
        }
        return 0;
    }

    // trap -l - list signal names
    if (args.len == 2 and std.mem.eql(u8, args[1], "-l")) {
        var col: usize = 0;
        inline for (std.meta.fields(TrapTable.Signal)) |field| {
            try shell.stdout().print("{d:>2}) SIG{s:<8}", .{ field.value, field.name });
            col += 1;
            if (col % 4 == 0) {
                try shell.stdout().writeAll("\n");
            }
        }
        if (col % 4 != 0) try shell.stdout().writeAll("\n");
        return 0;
    }

    // trap -p [signals...] - print traps for specific signals
    if (args.len >= 2 and std.mem.eql(u8, args[1], "-p")) {
        if (args.len == 2) {
            // print all traps (same as no args)
            inline for (std.meta.fields(TrapTable.Signal)) |field| {
                const sig: TrapTable.Signal = @enumFromInt(field.value);
                if (shell.traps.get(sig)) |cmd| {
                    try shell.stdout().print("trap -- '{s}' {s}\n", .{ cmd, field.name });
                }
            }
        } else {
            // print specific signals
            for (args[2..]) |sig_name| {
                if (TrapTable.Signal.fromName(sig_name)) |sig| {
                    if (shell.traps.get(sig)) |cmd| {
                        try shell.stdout().print("trap -- '{s}' {s}\n", .{ cmd, @tagName(sig) });
                    }
                } else {
                    try shell.stdout().print("trap: {s}: invalid signal\n", .{sig_name});
                    return 1;
                }
            }
        }
        return 0;
    }

    // trap cmd signal [signal...]
    // trap '' signal - ignore signal
    // trap - signal - reset to default
    if (args.len < 3) {
        try shell.stdout().writeAll("trap: usage: trap [-lp] [cmd] [signal ...]\n");
        return 1;
    }

    const cmd_arg = args[1];

    // handle reset case: trap - SIGNAL
    const cmd: ?[]const u8 = if (std.mem.eql(u8, cmd_arg, "-"))
        null
    else
        cmd_arg;

    // set trap for each signal
    for (args[2..]) |sig_name| {
        if (TrapTable.Signal.fromName(sig_name)) |sig| {
            try shell.traps.set(shell.allocator, sig, cmd);
        } else {
            try shell.stdout().print("trap: {s}: invalid signal\n", .{sig_name});
            return 1;
        }
    }

    return 0;
}

// ============ shell control ============

fn exit(shell: *Shell, args: []const []const u8) !u8 {
    const code: u8 = if (args.len > 1)
        std.fmt.parseInt(u8, args[1], 10) catch 0
    else
        shell.last_exit_code;

    // run EXIT trap before exiting
    shell.runExitTrap();

    shell.running = false;
    return code;
}

fn returnCmd(shell: *Shell, args: []const []const u8) !u8 {
    _ = shell;
    // return value for function
    if (args.len > 1) {
        return std.fmt.parseInt(u8, args[1], 10) catch 0;
    }
    return 0;
}

fn builtinCmd(shell: *Shell, args: []const []const u8) !u8 {
    // run builtin directly, bypassing alias lookup
    _ = shell;
    if (args.len < 2) return 0;
    // TODO: implement proper builtin dispatch
    return 0;
}

fn commandCmd(shell: *Shell, args: []const []const u8) !u8 {
    // run command directly, bypassing alias/function lookup
    // just return null to let eval.zig handle external command
    _ = shell;
    _ = args;
    return 127; // fall through to external command
}

// ============ time builtin - criterion-style benchmarking ============

// rusage struct for Linux (matches kernel definition)
const Rusage = extern struct {
    ru_utime: std.posix.timeval, // user time
    ru_stime: std.posix.timeval, // system time
    ru_maxrss: isize, // max resident set size (KB on Linux)
    ru_ixrss: isize,
    ru_idrss: isize,
    ru_isrss: isize,
    ru_minflt: isize, // page faults not requiring I/O
    ru_majflt: isize, // page faults requiring I/O
    ru_nswap: isize,
    ru_inblock: isize,
    ru_oublock: isize,
    ru_msgsnd: isize,
    ru_msgrcv: isize,
    ru_nsignals: isize,
    ru_nvcsw: isize, // voluntary context switches
    ru_nivcsw: isize, // involuntary context switches
};

// wait4 syscall - like waitpid but returns rusage
fn wait4(pid: std.posix.pid_t, status: *u32, options: u32, rusage: ?*Rusage) std.posix.pid_t {
    const ret = std.os.linux.syscall4(
        .wait4,
        @bitCast(@as(isize, pid)),
        @intFromPtr(status),
        options,
        @intFromPtr(rusage),
    );
    return @truncate(@as(isize, @bitCast(ret)));
}

const BenchSample = struct {
    wall_ns: i128,
    user_ns: i128,
    sys_ns: i128,
    maxrss_kb: isize,
    exit_code: u8,
};

fn timeCmd(shell: *Shell, args: []const []const u8) !u8 {
    const writer = shell.stdout();

    // parse options
    var iterations: usize = 1;
    var warmup: usize = 0;
    var show_histogram = false;
    var quiet = false;
    var verbose = false;
    var cmd_start: usize = 1;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (arg.len == 0 or arg[0] != '-') break;

        if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--iterations")) {
            i += 1;
            if (i >= args.len) {
                try writer.writeAll("time: -n requires iteration count\n");
                return 1;
            }
            iterations = std.fmt.parseInt(usize, args[i], 10) catch {
                try writer.writeAll("time: invalid iteration count\n");
                return 1;
            };
            iterations = @max(1, @min(iterations, 10000));
        } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--warmup")) {
            i += 1;
            if (i >= args.len) {
                try writer.writeAll("time: -w requires warmup count\n");
                return 1;
            }
            warmup = std.fmt.parseInt(usize, args[i], 10) catch {
                try writer.writeAll("time: invalid warmup count\n");
                return 1;
            };
            warmup = @min(warmup, 100);
        } else if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--histogram")) {
            show_histogram = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            try writer.writeAll(
                \\time - command timing and benchmarking
                \\
                \\usage: time [options] command [args...]
                \\
                \\options:
                \\  -v, --verbose        show detailed stats (memory, etc.)
                \\  -n, --iterations N   benchmark with N iterations
                \\  -w, --warmup W       run W warmup iterations first
                \\  -H, --histogram      show timing distribution
                \\  -q, --quiet          minimal output (just time)
                \\      --help           show this help
                \\
                \\examples:
                \\  time ls              basic timing (bash-style)
                \\  time -v ls           verbose with memory stats
                \\  time -n 100 ls       benchmark with statistics
                \\  time -n 50 -w 5 cmd  benchmark with warmup
                \\
            );
            return 0;
        } else if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        } else {
            break;
        }
        cmd_start = i + 1;
    }

    if (cmd_start >= args.len) {
        try writer.writeAll("time: no command specified\n");
        return 1;
    }

    const cmd_args = args[cmd_start..];
    const is_benchmark = iterations > 1;

    // run warmup iterations
    for (0..warmup) |_| {
        _ = try runTimedCommand(shell, cmd_args);
    }

    // collect samples
    var samples: [10000]BenchSample = undefined;
    var last_exit: u8 = 0;

    for (0..iterations) |iter| {
        samples[iter] = try runTimedCommand(shell, cmd_args);
        last_exit = samples[iter].exit_code;
    }

    // compute statistics
    const stats = computeStats(samples[0..iterations]);

    // output results
    if (is_benchmark) {
        try printBenchmarkResults(writer, stats, iterations, quiet, show_histogram, samples[0..iterations]);
    } else {
        try printSingleResult(writer, samples[0], quiet, verbose);
    }

    return last_exit;
}

fn runTimedCommand(shell: *Shell, cmd_args: []const []const u8) !BenchSample {
    const start = std.time.nanoTimestamp();

    // fork and run command
    const pid = std.posix.fork() catch return BenchSample{
        .wall_ns = 0,
        .user_ns = 0,
        .sys_ns = 0,
        .maxrss_kb = 0,
        .exit_code = 127,
    };

    if (pid == 0) {
        // child - exec the command
        var argv_buf: [256]?[*:0]const u8 = undefined;
        for (cmd_args, 0..) |arg, i| {
            const arg_z = shell.allocator.dupeZ(u8, arg) catch std.posix.exit(127);
            argv_buf[i] = arg_z.ptr;
        }
        argv_buf[cmd_args.len] = null;

        const argv = argv_buf[0..cmd_args.len :null];
        std.posix.execvpeZ(argv[0].?, argv, @ptrCast(std.os.environ.ptr)) catch {};
        std.posix.exit(127);
    }

    // parent - wait for child with rusage via wait4
    var status: u32 = 0;
    var rusage: Rusage = std.mem.zeroes(Rusage);
    _ = wait4(pid, &status, 0, &rusage);
    const end = std.time.nanoTimestamp();

    const wall_ns = end - start;
    const user_ns = timevalToNs(rusage.ru_utime);
    const sys_ns = timevalToNs(rusage.ru_stime);

    const exit_code: u8 = if (std.posix.W.IFEXITED(status))
        std.posix.W.EXITSTATUS(status)
    else if (std.posix.W.IFSIGNALED(status))
        128 + @as(u8, @truncate(@as(u32, @intCast(std.posix.W.TERMSIG(status)))))
    else
        1;

    return BenchSample{
        .wall_ns = wall_ns,
        .user_ns = user_ns,
        .sys_ns = sys_ns,
        .maxrss_kb = rusage.ru_maxrss,
        .exit_code = exit_code,
    };
}

fn timevalToNs(tv: std.posix.timeval) i128 {
    return @as(i128, tv.sec) * 1_000_000_000 + @as(i128, tv.usec) * 1000;
}

const BenchStats = struct {
    mean_ns: f64,
    median_ns: f64,
    stddev_ns: f64,
    min_ns: f64,
    max_ns: f64,
    p5_ns: f64,
    p95_ns: f64,
    outliers_low: usize,
    outliers_high: usize,
    mean_user_ns: f64,
    mean_sys_ns: f64,
    max_rss_kb: isize,
};

fn computeStats(samples: []const BenchSample) BenchStats {
    if (samples.len == 0) {
        return std.mem.zeroes(BenchStats);
    }

    // extract wall times and sort
    var times: [10000]f64 = undefined;
    var sum: f64 = 0;
    var user_sum: f64 = 0;
    var sys_sum: f64 = 0;
    var max_rss: isize = 0;

    for (samples, 0..) |s, i| {
        times[i] = @floatFromInt(s.wall_ns);
        sum += times[i];
        user_sum += @as(f64, @floatFromInt(s.user_ns));
        sys_sum += @as(f64, @floatFromInt(s.sys_ns));
        if (s.maxrss_kb > max_rss) max_rss = s.maxrss_kb;
    }

    const n = samples.len;
    const nf: f64 = @floatFromInt(n);

    // sort for percentiles
    std.mem.sort(f64, times[0..n], {}, std.sort.asc(f64));

    const mean = sum / nf;
    const median = if (n % 2 == 0)
        (times[n / 2 - 1] + times[n / 2]) / 2.0
    else
        times[n / 2];

    // stddev
    var variance_sum: f64 = 0;
    for (times[0..n]) |t| {
        const diff = t - mean;
        variance_sum += diff * diff;
    }
    const stddev = @sqrt(variance_sum / nf);

    // percentiles
    const p5_idx = @min(n - 1, @as(usize, @intFromFloat(nf * 0.05)));
    const p95_idx = @min(n - 1, @as(usize, @intFromFloat(nf * 0.95)));

    // outlier detection using IQR
    const q1_idx = @as(usize, @intFromFloat(nf * 0.25));
    const q3_idx = @min(n - 1, @as(usize, @intFromFloat(nf * 0.75)));
    const q1 = times[q1_idx];
    const q3 = times[q3_idx];
    const iqr = q3 - q1;
    const low_fence = q1 - 1.5 * iqr;
    const high_fence = q3 + 1.5 * iqr;

    var outliers_low: usize = 0;
    var outliers_high: usize = 0;
    for (times[0..n]) |t| {
        if (t < low_fence) outliers_low += 1;
        if (t > high_fence) outliers_high += 1;
    }

    return BenchStats{
        .mean_ns = mean,
        .median_ns = median,
        .stddev_ns = stddev,
        .min_ns = times[0],
        .max_ns = times[n - 1],
        .p5_ns = times[p5_idx],
        .p95_ns = times[p95_idx],
        .outliers_low = outliers_low,
        .outliers_high = outliers_high,
        .mean_user_ns = user_sum / nf,
        .mean_sys_ns = sys_sum / nf,
        .max_rss_kb = max_rss,
    };
}

fn printSingleResult(writer: anytype, sample: BenchSample, quiet: bool, verbose: bool) !void {
    const wall_s = @as(f64, @floatFromInt(sample.wall_ns)) / 1_000_000_000.0;
    const user_s = @as(f64, @floatFromInt(sample.user_ns)) / 1_000_000_000.0;
    const sys_s = @as(f64, @floatFromInt(sample.sys_ns)) / 1_000_000_000.0;

    if (quiet) {
        try writer.print("{d:.3}s\n", .{wall_s});
        return;
    }

    if (verbose) {
        // bash-style multiline
        try writer.print("\nreal\t{d}m{d:.3}s\n", .{
            @as(u32, @intFromFloat(wall_s / 60.0)),
            @mod(wall_s, 60.0),
        });
        try writer.print("user\t{d}m{d:.3}s\n", .{
            @as(u32, @intFromFloat(user_s / 60.0)),
            @mod(user_s, 60.0),
        });
        try writer.print("sys\t{d}m{d:.3}s\n", .{
            @as(u32, @intFromFloat(sys_s / 60.0)),
            @mod(sys_s, 60.0),
        });
        if (sample.maxrss_kb > 0) {
            try writer.print("mem\t{d} KB\n", .{sample.maxrss_kb});
        }
        return;
    }

    // zsh-style one-liner with memory
    try writer.print("{d:.2}s user {d:.2}s sys {d} KB {d:.3}s total\n", .{
        user_s,
        sys_s,
        sample.maxrss_kb,
        wall_s,
    });
}

fn printBenchmarkResults(writer: anytype, stats: BenchStats, n: usize, quiet: bool, show_histogram: bool, samples: []const BenchSample) !void {
    if (quiet) {
        try writer.print("{d:.3}ms ± {d:.3}ms\n", .{
            stats.mean_ns / 1_000_000.0,
            stats.stddev_ns / 1_000_000.0,
        });
        return;
    }

    try writer.writeAll("\n");
    try writer.print("  benchmark: {d} iterations\n", .{n});
    try writer.writeAll("  ─────────────────────────────────────\n");

    // main timing stats
    try writer.print("  mean:    {s}  ± {s}\n", .{
        formatDuration(stats.mean_ns),
        formatDuration(stats.stddev_ns),
    });
    try writer.print("  median:  {s}\n", .{formatDuration(stats.median_ns)});
    try writer.print("  range:   {s} ... {s}\n", .{
        formatDuration(stats.min_ns),
        formatDuration(stats.max_ns),
    });
    try writer.print("  p5/p95:  {s} ... {s}\n", .{
        formatDuration(stats.p5_ns),
        formatDuration(stats.p95_ns),
    });

    // outliers
    const total_outliers = stats.outliers_low + stats.outliers_high;
    if (total_outliers > 0) {
        const pct = @as(f64, @floatFromInt(total_outliers)) / @as(f64, @floatFromInt(n)) * 100.0;
        try writer.print("  outliers: {d} ({d:.1}%)", .{ total_outliers, pct });
        if (stats.outliers_low > 0 and stats.outliers_high > 0) {
            try writer.print(" [{d} low, {d} high]", .{ stats.outliers_low, stats.outliers_high });
        }
        try writer.writeAll("\n");
    }

    try writer.writeAll("  ─────────────────────────────────────\n");

    // resource usage
    try writer.print("  user:    {s}  (mean)\n", .{formatDuration(stats.mean_user_ns)});
    try writer.print("  sys:     {s}  (mean)\n", .{formatDuration(stats.mean_sys_ns)});
    if (stats.max_rss_kb > 0) {
        try writer.print("  mem:     {d} KB  (peak)\n", .{stats.max_rss_kb});
    }

    // throughput
    if (stats.mean_ns > 0) {
        const ops_per_sec = 1_000_000_000.0 / stats.mean_ns;
        if (ops_per_sec >= 1.0) {
            try writer.print("  throughput: {d:.2} ops/sec\n", .{ops_per_sec});
        }
    }

    // histogram
    if (show_histogram and n >= 5) {
        try writer.writeAll("\n  distribution:\n");
        try printHistogram(writer, samples);
    }

    try writer.writeAll("\n");
}

fn printHistogram(writer: anytype, samples: []const BenchSample) !void {
    if (samples.len < 2) return;

    // find min/max
    var min_ns: i128 = samples[0].wall_ns;
    var max_ns: i128 = samples[0].wall_ns;
    for (samples) |s| {
        if (s.wall_ns < min_ns) min_ns = s.wall_ns;
        if (s.wall_ns > max_ns) max_ns = s.wall_ns;
    }

    if (min_ns == max_ns) {
        try writer.writeAll("  [all samples identical]\n");
        return;
    }

    // create buckets
    const num_buckets: usize = 10;
    var buckets: [10]usize = [_]usize{0} ** 10;
    const range: f64 = @floatFromInt(max_ns - min_ns);
    const bucket_size = range / @as(f64, @floatFromInt(num_buckets));

    for (samples) |s| {
        const offset: f64 = @floatFromInt(s.wall_ns - min_ns);
        var bucket_idx = @as(usize, @intFromFloat(offset / bucket_size));
        bucket_idx = @min(bucket_idx, num_buckets - 1);
        buckets[bucket_idx] += 1;
    }

    // find max bucket for scaling
    var max_count: usize = 1;
    for (buckets) |count| {
        if (count > max_count) max_count = count;
    }

    // print histogram
    const bar_chars = "▏▎▍▌▋▊▉█";
    const max_bar_width: usize = 30;

    for (buckets, 0..) |count, bi| {
        const bucket_start = min_ns + @as(i128, @intFromFloat(@as(f64, @floatFromInt(bi)) * bucket_size));
        const bucket_end = min_ns + @as(i128, @intFromFloat(@as(f64, @floatFromInt(bi + 1)) * bucket_size));

        // left label
        try writer.print("  {s:>8} │", .{formatDuration(@floatFromInt(bucket_start))});

        // bar
        const bar_width = (count * max_bar_width) / max_count;
        const remainder = ((count * max_bar_width * 8) / max_count) % 8;

        for (0..bar_width) |_| {
            try writer.writeAll("█");
        }
        if (remainder > 0 and bar_width < max_bar_width) {
            const partial_idx = (remainder - 1) * 3;
            try writer.writeAll(bar_chars[partial_idx .. partial_idx + 3]);
        }

        // right padding and count
        const spaces_needed = max_bar_width - bar_width - @min(@as(usize, 1), if (remainder > 0) @as(usize, 1) else @as(usize, 0));
        for (0..spaces_needed) |_| {
            try writer.writeAll(" ");
        }

        try writer.print(" {d}\n", .{count});
        _ = bucket_end;
    }
}

fn formatDuration(ns: f64) [12]u8 {
    var buf: [12]u8 = undefined;
    @memset(&buf, ' ');

    if (ns < 1_000) {
        _ = std.fmt.bufPrint(&buf, "{d:>7.1} ns", .{ns}) catch {};
    } else if (ns < 1_000_000) {
        _ = std.fmt.bufPrint(&buf, "{d:>7.2} µs", .{ns / 1_000.0}) catch {};
    } else if (ns < 1_000_000_000) {
        _ = std.fmt.bufPrint(&buf, "{d:>7.2} ms", .{ns / 1_000_000.0}) catch {};
    } else {
        _ = std.fmt.bufPrint(&buf, "{d:>7.3} s ", .{ns / 1_000_000_000.0}) catch {};
    }
    return buf;
}

// ============ helpers ============

fn setVar(shell: *Shell, name: []const u8, value: []const u8) !void {
    const name_copy = try shell.allocator.dupe(u8, name);
    const value_copy = try shell.allocator.dupe(u8, value);

    if (shell.variables.fetchRemove(name_copy)) |old| {
        shell.allocator.free(old.key);
        shell.allocator.free(old.value);
    }
    try shell.variables.put(name_copy, value_copy);
}

fn setOptind(shell: *Shell, optind: usize) !void {
    var buf: [16]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d}", .{optind}) catch "1";
    try setVar(shell, "OPTIND", str);
}

// ============ agent builtin ============

const agent_mod = @import("agent.zig");
const agent_log = @import("agent_log.zig");
const agent_commands = @import("agent_commands.zig");

fn agentCmd(shell: *Shell, args: []const []const u8) !u8 {
    const out = shell.stdout();

    if (args.len < 2) {
        // interactive agent mode
        return agentInteractive(shell);
    }

    var subcmd = args[1];
    var arg_start: usize = 1;

    // Handle -m <model> flag (must be before subcommand)
    if (std.mem.eql(u8, subcmd, "-m") and args.len >= 3) {
        const model = args[2];
        // Resolve model aliases
        const resolved = if (std.mem.eql(u8, model, "opus") or std.mem.eql(u8, model, "large"))
            "claude-opus-4-6"
        else if (std.mem.eql(u8, model, "sonnet") or std.mem.eql(u8, model, "medium"))
            "claude-sonnet-4-6"
        else if (std.mem.eql(u8, model, "haiku") or std.mem.eql(u8, model, "small"))
            "claude-haiku-4-5-20251001"
        else
            model;

        // Set model override and restart agent
        shell.agent.setModel(resolved);
        shell.agent.stop();
        try out.print("\x1b[90mSwitching to {s}\x1b[0m\n", .{resolved});
        try out.flush();

        arg_start = 3;
        if (args.len < 4) {
            // agent -m opus (no further args) — enter interactive mode
            return agentInteractive(shell);
        }
        subcmd = args[3];
        arg_start = 3;
    }

    // agent c / agent continue — re-enter interactive mode (same as bare agent)
    if (std.mem.eql(u8, subcmd, "c") or std.mem.eql(u8, subcmd, "continue")) {
        return agentInteractive(shell);
    }

    // agent stop
    if (std.mem.eql(u8, subcmd, "stop")) {
        shell.agent.cancel();
        try out.writeAll("agent: cancelled\n");
        try out.flush();
        return 0;
    }

    // agent status
    if (std.mem.eql(u8, subcmd, "status")) {
        if (shell.agent.isBusy()) {
            try out.writeAll("agent: busy\n");
        } else {
            try out.writeAll("agent: idle\n");
        }
        try out.flush();
        return 0;
    }

    // agent attach [session-id] — attach to a running session (like screen/tmux)
    if (std.mem.eql(u8, subcmd, "attach")) {
        return agentAttach(shell, args);
    }

    // agent sessions
    if (std.mem.eql(u8, subcmd, "sessions")) {
        var sessions: std.ArrayList(agent_log.SessionInfo) = .{};
        defer sessions.deinit(shell.allocator);
        agent_log.listSessions(shell.allocator, &sessions) catch {};

        if (sessions.items.len == 0) {
            try out.writeAll("No saved sessions.\n");
        } else {
            try out.writeAll("ID             Created              CWD\n");
            // show last 20 sessions
            const start = if (sessions.items.len > 20) sessions.items.len - 20 else 0;
            for (sessions.items[start..]) |*info| {
                // format timestamp as date
                const epoch_secs: u64 = if (info.created > 0) @intCast(info.created) else 0;
                const es = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
                const day = es.getEpochDay();
                const yd = day.calculateYearDay();
                const md = yd.calculateMonthDay();
                const ds = es.getDaySeconds();
                try out.print("{s}  {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}  {s}\n", .{
                    @as([]const u8, &info.id),
                    yd.year,
                    @intFromEnum(md.month),
                    md.day_index + 1,
                    ds.getHoursIntoDay(),
                    ds.getMinutesIntoHour(),
                    info.cwd(),
                });
            }
        }
        try out.flush();
        return 0;
    }

    // agent config
    if (std.mem.eql(u8, subcmd, "config")) {
        var cfg = agent_log.AgentConfig.load(shell.allocator);
        defer cfg.deinit();
        try out.print("provider:   {s}\n", .{cfg.provider});
        try out.print("model:      {s}\n", .{cfg.model});
        try out.print("base_url:   {s}\n", .{cfg.base_url});
        try out.print("api_key:    {s}\n", .{if (cfg.api_key.len > 0) "***set***" else "(not set)"});
        if (cfg.api_key_cmd.len > 0) {
            try out.print("api_key_cmd: {s}\n", .{cfg.api_key_cmd});
        }
        try out.print("max_tokens: {d}\n", .{cfg.max_tokens});
        try out.print("max_iters:  {d}\n", .{cfg.max_tool_iterations});
        // Router config
        try out.print("\n\x1b[1mRouter:\x1b[0m\n", .{});
        try out.print("  enabled:  {}\n", .{cfg.router_enabled});
        if (cfg.router_enabled) {
            if (cfg.router_provider.len > 0) try out.print("  provider: {s}\n", .{cfg.router_provider});
            try out.print("  model:    {s}\n", .{cfg.router_model});
            if (cfg.router_base_url.len > 0) try out.print("  base_url: {s}\n", .{cfg.router_base_url});
            try out.print("  local_only: {}\n", .{cfg.router_local_only});
            try out.print("  small:    {s}\n", .{cfg.haiku_model});
            try out.print("  medium:   {s}\n", .{cfg.sonnet_model});
            try out.print("  large:    {s}\n", .{cfg.opus_model});
        }
        try out.flush();
        return 0;
    }

    // agent bench — benchmark local inference (GPU vs CPU)
    if (std.mem.eql(u8, subcmd, "bench")) {
        const inference = @import("inference/root.zig");
        var cfg = agent_log.AgentConfig.load(shell.allocator);
        defer cfg.deinit();

        const model_path = if (cfg.router_local_model.len > 0) cfg.router_local_model else blk: {
            try out.writeAll("agent bench: no local model configured (set router_local_model in ~/.zish/agent.json)\n");
            try out.flush();
            break :blk "";
        };
        if (model_path.len == 0) return 0;

        try out.print("Loading model: {s}\n", .{model_path});
        try out.flush();

        var ctx = inference.InferenceContext.load(model_path, shell.allocator) catch |e| {
            try out.print("Failed to load model: {}\n", .{e});
            try out.flush();
            return 1;
        };
        defer ctx.deinit();

        const info = ctx.modelInfo();
        try out.print("Model: {s} ({} layers, dim={}, vocab={})\n", .{ info.arch, info.layers, info.dim, info.vocab });
        try out.print("GPU: {s}\n", .{if (ctx.gpu_ctx != null) "active" else "CPU only"});
        try out.flush();

        // Benchmark (no warmup — first token time is interesting)
        const n: usize = 16;
        try out.print("Benchmarking {} tokens...\n", .{n});
        try out.flush();
        const result = ctx.bench(n);

        try out.print("\n\x1b[1mResults:\x1b[0m\n", .{});
        try out.print("  Prefill:  {d:.1} tokens/sec\n", .{result.prefill_tps});
        try out.print("  Generate: {d:.1} tokens/sec\n", .{result.generate_tps});
        try out.print("  Backend:  {s}\n", .{if (result.gpu) "GPU (Vulkan)" else "CPU"});
        try out.flush();
        return 0;
    }

    // agent clear
    if (std.mem.eql(u8, subcmd, "clear")) {
        // stop and restart agent to clear conversation
        shell.agent.stop();
        shell.agent.start() catch {};
        try out.writeAll("agent: conversation cleared\n");
        try out.flush();
        return 0;
    }

    // agent log [session-id] — view conversation log
    if (std.mem.eql(u8, subcmd, "log")) {
        return agentLog(shell, args);
    }

    // agent tasks — list subagent tasks from latest session log
    if (std.mem.eql(u8, subcmd, "tasks")) {
        try out.writeAll("\x1b[1mSubagent Tasks:\x1b[0m\n");
        if (shell.agent.isBusy()) {
            try out.writeAll("\x1b[90m  (agent is busy — subagents may be running)\x1b[0m\n");
        }
        // Show subagent entries from latest session log
        if (agentLatestSession(shell)) |sid| {
            var base_buf2: [512]u8 = undefined;
            if (agent_log.getBaseDir(&base_buf2)) |base| {
                var p_buf: [512]u8 = undefined;
                if (std.fmt.bufPrint(&p_buf, "{s}/sessions/{s}/conversation.jsonl", .{ base, sid })) |conv_path| {
                    if (std.fs.cwd().readFileAlloc(shell.allocator, conv_path, 512 * 1024)) |content| {
                        defer shell.allocator.free(content);
                        var iter = std.mem.splitScalar(u8, content, '\n');
                        var found_any = false;
                        while (iter.next()) |line| {
                            const t = agent_log.jsonExtractStr(line, "t") orelse continue;
                            if (std.mem.eql(u8, t, "as")) {
                                const aid = agent_log.jsonExtractStr(line, "agent_id") orelse "?";
                                const desc = agent_log.jsonExtractStr(line, "desc") orelse "task";
                                try out.print("  \x1b[36m{s}\x1b[0m  {s}\n", .{ aid, desc });
                                found_any = true;
                            } else if (std.mem.eql(u8, t, "ar")) {
                                const aid = agent_log.jsonExtractStr(line, "agent_id") orelse "?";
                                try out.print("  \x1b[32m{s}\x1b[0m  done\n", .{aid});
                            }
                        }
                        if (!found_any) try out.writeAll("\x1b[90m  No subagents in current session.\x1b[0m\n");
                    } else |_| {
                        try out.writeAll("\x1b[90m  No session data.\x1b[0m\n");
                    }
                } else |_| {}
            }
        } else {
            try out.writeAll("\x1b[90m  No sessions found.\x1b[0m\n");
        }
        try out.flush();
        return 0;
    }

    // agent help
    if (std.mem.eql(u8, subcmd, "help")) {
        try out.writeAll(
            \\Usage: agent [command|query]
            \\
            \\Commands:
            \\  agent              Enter interactive agent mode
            \\  agent c|continue   Re-enter interactive mode (continue session)
            \\  agent attach [id]  Attach to a running session (like screen/tmux)
            \\  agent stop         Cancel current operation
            \\  agent status       Show agent status (busy/idle)
            \\  agent sessions     List recent sessions
            \\  agent log [id]     View conversation log (latest or by session id)
            \\  agent tasks        List subagent tasks
            \\  agent config       Show current configuration
            \\  agent clear        Reset conversation history
            \\  agent help         Show this help
            \\
            \\  agent <query>      Send a one-shot query
            \\  agent -m <model> [query]  Use specific model (opus/sonnet/haiku)
            \\
            \\Interactive mode commands:
            \\  /compact           Summarize conversation to save context
            \\  /help              Show interactive help
            \\  clear              Reset conversation
            \\  exit, quit, Ctrl+D Leave agent mode
            \\
        );
        try out.flush();
        return 0;
    }

    // agent "query..." - send query to agent
    // join all args after "agent" (or after -m <model>) as the query
    var query_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    for (args[arg_start..], 0..) |arg, i| {
        if (i > 0 and pos < query_buf.len - 1) {
            query_buf[pos] = ' ';
            pos += 1;
        }
        const space = @min(arg.len, query_buf.len - pos);
        @memcpy(query_buf[pos..][0..space], arg[0..space]);
        pos += space;
        if (pos >= query_buf.len) break;
    }
    const query_text = std.mem.trim(u8, query_buf[0..pos], " \t\r\n");
    if (query_text.len == 0) {
        return agentInteractive(shell);
    }
    if (!shell.agent.query(query_text)) {
        try out.writeAll("agent: busy, use 'agent stop' or Ctrl+G to cancel\n");
        try out.flush();
        return 1;
    }

    // One-shot mode: always wait for the agent to finish and drain output.
    // This makes `zish -c 'agent <query>'` and `agent <query>` at the prompt
    // both work synchronously — essential for scripting and recursive use.
    {
        const agent_drain = @import("agent_drain.zig");
        var handler = agent_drain.SimpleHandler.init(out, &shell.agent.queues.request);
        // wait up to 120 seconds
        var ticks: usize = 0;
        while (!handler.isDone() and ticks < 2400) : (ticks += 1) {
            _ = try agent_drain.drain(agent_drain.SimpleHandler, &handler, &shell.agent.queues);
            try handler.flush();
            if (!handler.isDone()) std.Thread.sleep(50 * std.time.ns_per_ms);
        }
    }
    return 0;
}

fn getTermRows() u16 {
    const TIOCGWINSZ = 0x5413;
    const Winsize = extern struct { ws_row: u16, ws_col: u16, ws_xpixel: u16, ws_ypixel: u16 };
    var ws: Winsize = undefined;
    if (std.posix.system.ioctl(std.posix.STDOUT_FILENO, TIOCGWINSZ, @intFromPtr(&ws)) == 0 and ws.ws_row > 0)
        return ws.ws_row;
    return 24;
}

fn getTermCols() u16 {
    const TIOCGWINSZ = 0x5413;
    const Winsize = extern struct { ws_row: u16, ws_col: u16, ws_xpixel: u16, ws_ypixel: u16 };
    var ws: Winsize = undefined;
    if (std.posix.system.ioctl(std.posix.STDOUT_FILENO, TIOCGWINSZ, @intFromPtr(&ws)) == 0 and ws.ws_col > 0)
        return ws.ws_col;
    return 80;
}

// ── TUI Layout ──
// Row 1..N         Scrollable output area (ANSI scroll region)
// Row N+1          Separator ── (with scroll indicator when not at bottom)
// Row N+2..N+1+H   Input area (1-5 rows, grows with content)
// Row term_rows    Status bar: model │ $cost │ Ctrl+D:exit │ /help

/// Message history ring buffer — defined in agent_commands.zig
const MessageHistory = agent_commands.MessageHistory;

/// TeeWriter — defined in agent_commands.zig
fn TeeWriter(comptime W: type) type {
    return agent_commands.TeeWriter(W);
}

/// Escape sequence parse result
/// Apply a BindableAction to an EditBuffer in the agent TUI context.
/// Returns: .modified if buffer content changed (needs height recalc), .moved if only cursor moved, .none if nothing happened
const TuiEditResult = enum { none, moved, modified, special };

fn applyTuiBindableAction(
    ba: BindableAction,
    edit_buf: *editor.EditBuffer,
    shell: *Shell,
) TuiEditResult {
    switch (ba) {
        .move_line_start => { edit_buf.moveLineStart(); return .moved; },
        .move_line_end => { edit_buf.moveLineEnd(); return .moved; },
        .move_left => { _ = edit_buf.moveLeft(); return .moved; },
        .move_right => { _ = edit_buf.moveRight(); return .moved; },
        .move_word_forward => { edit_buf.wordForward(); return .moved; },
        .move_word_backward => { edit_buf.wordBack(); return .moved; },
        .move_up => { _ = edit_buf.moveUp(); return .moved; },
        .move_down => { _ = edit_buf.moveDown(); return .moved; },
        .backspace => { if (edit_buf.delete()) return .modified; return .none; },
        .delete_char => { if (edit_buf.deleteForward()) return .modified; return .none; },
        .delete_word_backward => {
            const text = edit_buf.slice();
            var pos: u16 = edit_buf.cursor;
            while (pos > 0 and (text[pos - 1] == ' ' or text[pos - 1] == '\t')) pos -= 1;
            while (pos > 0 and text[pos - 1] != ' ' and text[pos - 1] != '\t') pos -= 1;
            const n = edit_buf.cursor - pos;
            if (n == 0) return .none;
            var i: usize = 0;
            while (i < n) : (i += 1) _ = edit_buf.delete();
            return .modified;
        },
        .kill_to_end => {
            const start = edit_buf.cursor;
            var end: u16 = start;
            while (end < edit_buf.len and edit_buf.text[end] != '\n') end += 1;
            if (end <= start) return .none;
            const len = end - start;
            @memcpy(shell.vi.yank_buf[0..len], edit_buf.text[start..end]);
            shell.vi.yank_len = @intCast(len);
            edit_buf.cursor = start;
            var i: usize = 0;
            while (i < len) : (i += 1) _ = edit_buf.deleteForward();
            return .modified;
        },
        .kill_to_beginning => {
            const pos = edit_buf.cursor;
            if (pos == 0) return .none;
            @memcpy(shell.vi.yank_buf[0..pos], edit_buf.text[0..pos]);
            shell.vi.yank_len = @intCast(pos);
            var i: usize = 0;
            while (i < pos) : (i += 1) _ = edit_buf.delete();
            return .modified;
        },
        .yank_killed => {
            if (shell.vi.yank_len == 0) return .none;
            _ = edit_buf.insertSlice(shell.vi.yank_buf[0..shell.vi.yank_len]);
            return .modified;
        },
        .transpose_chars => {
            if (edit_buf.cursor > 0 and edit_buf.cursor < edit_buf.len) {
                const c1 = edit_buf.text[edit_buf.cursor - 1];
                const c2 = edit_buf.text[edit_buf.cursor];
                edit_buf.text[edit_buf.cursor - 1] = c2;
                edit_buf.text[edit_buf.cursor] = c1;
                edit_buf.cursor += 1;
                return .moved;
            } else if (edit_buf.cursor >= 2 and edit_buf.cursor == edit_buf.len) {
                const p = edit_buf.cursor;
                const c1 = edit_buf.text[p - 2];
                const c2 = edit_buf.text[p - 1];
                edit_buf.text[p - 2] = c2;
                edit_buf.text[p - 1] = c1;
                return .moved;
            }
            return .none;
        },
        .insert_last_arg => {
            if (shell.history) |h| {
                const items = h.entries.items;
                if (items.len > 0) {
                    const prev = h.getCommand(items[items.len - 1]);
                    if (prev.len > 0) {
                        var end: usize = prev.len;
                        while (end > 0 and (prev[end - 1] == ' ' or prev[end - 1] == '\t')) end -= 1;
                        var start: usize = end;
                        while (start > 0 and prev[start - 1] != ' ' and prev[start - 1] != '\t') start -= 1;
                        const last_arg = prev[start..end];
                        if (last_arg.len > 0) {
                            if (edit_buf.len > 0 and edit_buf.cursor > 0 and
                                edit_buf.text[edit_buf.cursor - 1] != ' ')
                            {
                                _ = edit_buf.insert(' ');
                            }
                            _ = edit_buf.insertSlice(last_arg);
                            return .modified;
                        }
                    }
                }
            }
            return .none;
        },
        .undo => return .none, // no undo in TUI
        .none => return .none,
        // these are handled specially before reaching this function
        .cancel, .cancel_agent, .clear_screen, .exit_shell,
        .suspend_shell, .execute_command, .tab_complete,
        .history_up, .history_down, .search_backward, .search_forward,
        .enter_normal_mode,
        => return .special,
    }
}

/// Map a runtime Action back to BindableAction for TUI dispatch.
fn actionToBindable(action: input_mod.Action) BindableAction {
    return switch (action) {
        .move_cursor => |m| switch (m) {
            .to_line_start => .move_line_start,
            .to_line_end => .move_line_end,
            .relative => |r| if (r < 0) .move_left else .move_right,
            .word_forward => .move_word_forward,
            .word_backward => .move_word_backward,
            .line_up => .move_up,
            .line_down => .move_down,
            else => .none,
        },
        .backspace => .backspace,
        .delete => |d| switch (d) {
            .char_under_cursor => .delete_char,
            else => .none,
        },
        .delete_word_backward => .delete_word_backward,
        .kill_to_end => .kill_to_end,
        .kill_to_beginning => .kill_to_beginning,
        .yank_killed => .yank_killed,
        .transpose_chars => .transpose_chars,
        .insert_last_arg => .insert_last_arg,
        .undo => .undo,
        .history_nav => |d| switch (d) {
            .up => .history_up,
            .down => .history_down,
        },
        .enter_search_mode => |d| switch (d) {
            .backward => .search_backward,
            .forward => .search_forward,
        },
        .cancel => .cancel,
        .cancel_agent => .cancel_agent,
        .clear_screen => .clear_screen,
        .exit_shell => .exit_shell,
        .suspend_shell => .suspend_shell,
        .execute_command => .execute_command,
        .tap_complete => .tab_complete,
        .cycle_ghost => .none,
        .vim_mode => .enter_normal_mode,
        else => .none,
    };
}

const EscAction = union(enum) {
    none,
    enter,
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,
    ctrl_left, // Ctrl+Left: word left
    ctrl_right, // Ctrl+Right: word right
    ctrl_up, // Ctrl+Up: jump to previous message
    ctrl_down, // Ctrl+Down: jump to next message
    page_up,
    page_down,
    home,
    end,
    alt_enter,
    delete,
    paste, // bracketed paste start (ESC[200~)
    alt_key: u8, // Alt+<byte> — looked up in keybindings table by caller
};

fn parseEscSequence() EscAction {
    const stdin = std.fs.File.stdin();
    var esc_poll = [_]std.posix.pollfd{.{
        .fd = std.posix.STDIN_FILENO,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    if ((std.posix.poll(&esc_poll, 10) catch 0) == 0) return .none;

    var b: [1]u8 = undefined;
    const n = stdin.read(&b) catch return .none;
    if (n == 0) return .none;

    // ESC followed by \r or \n — treat as plain enter (ignore the ESC).
    // Don't return alt_enter here: too many terminals send spurious ESC before Enter.
    if (b[0] == '\r' or b[0] == '\n') return .enter;

    // Alt+key: ESC followed by a regular character (not '[')
    if (b[0] != '[') {
        if (b[0] >= 0x20 and b[0] < 0x7F) return .{ .alt_key = b[0] };
        return .none;
    }

    // Read CSI parameter
    if ((std.posix.poll(&esc_poll, 10) catch 0) == 0) return .none;
    const n2 = stdin.read(&b) catch return .none;
    if (n2 == 0) return .none;

    return switch (b[0]) {
        'A' => .arrow_up,
        'B' => .arrow_down,
        'C' => .arrow_right,
        'D' => .arrow_left,
        'H' => .home,
        'F' => .end,
        '1' => blk: {
            // ESC[1;Nx — modified arrows (Shift/Alt/Ctrl)
            // Read ";N<dir>" sequence
            var mod_buf: [3]u8 = undefined;
            var mi: usize = 0;
            while (mi < 3) : (mi += 1) {
                if ((std.posix.poll(&esc_poll, 10) catch 0) == 0) break;
                const mn = stdin.read(mod_buf[mi..][0..1]) catch break;
                if (mn == 0) break;
                // Direction letter terminates the sequence
                if (mod_buf[mi] >= 'A' and mod_buf[mi] <= 'H') { mi += 1; break; }
            }
            // We expect ";N<dir>" where N is modifier, dir is A/B/C/D/H/F
            if (mi >= 3 and mod_buf[0] == ';') {
                const modifier = mod_buf[1];
                const direction = mod_buf[2];
                if (modifier == '5') { // Ctrl+
                    break :blk switch (direction) {
                        'C' => .ctrl_right,
                        'D' => .ctrl_left,
                        'A' => .ctrl_up,
                        'B' => .ctrl_down,
                        'H' => .home,
                        'F' => .end,
                        else => .none,
                    };
                }
                // Shift (2), Alt (3) — treat as normal arrows
                break :blk switch (direction) {
                    'A' => .arrow_up,
                    'B' => .arrow_down,
                    'C' => .arrow_right,
                    'D' => .arrow_left,
                    'H' => .home,
                    'F' => .end,
                    else => .none,
                };
            }
            // Consume remaining
            while ((std.posix.poll(&esc_poll, 5) catch 0) > 0) {
                _ = stdin.read(&b) catch break;
            }
            break :blk .none;
        },
        '2' => blk: {
            // ESC [ 2 0 0 ~ = bracketed paste start
            // Read remaining chars to check for "00~"
            var seq: [4]u8 = undefined;
            var si: usize = 0;
            while (si < 4) : (si += 1) {
                if ((std.posix.poll(&esc_poll, 10) catch 0) == 0) break;
                const sn = stdin.read(seq[si..][0..1]) catch break;
                if (sn == 0) break;
                if (seq[si] == '~') { si += 1; break; }
            }
            if (si >= 3 and seq[0] == '0' and seq[1] == '0' and seq[2] == '~') {
                break :blk .paste;
            }
            // Not paste — consume rest
            while ((std.posix.poll(&esc_poll, 5) catch 0) > 0) {
                _ = stdin.read(&b) catch break;
            }
            break :blk .none;
        },
        '5' => blk: {
            // PageUp: ESC [ 5 ~ (or ESC [ 5 ; N ~)
            var discard: [1]u8 = undefined;
            while (true) {
                const dn = stdin.read(&discard) catch break;
                if (dn == 0 or (discard[0] >= 0x40 and discard[0] <= 0x7E)) break;
            }
            break :blk .page_up;
        },
        '6' => blk: {
            // PageDown: ESC [ 6 ~ (or ESC [ 6 ; N ~)
            var discard: [1]u8 = undefined;
            while (true) {
                const dn = stdin.read(&discard) catch break;
                if (dn == 0 or (discard[0] >= 0x40 and discard[0] <= 0x7E)) break;
            }
            break :blk .page_down;
        },
        '3' => blk: {
            // Delete: ESC [ 3 ~ (or ESC [ 3 ; N ~)
            var discard: [1]u8 = undefined;
            while (true) {
                const dn = stdin.read(&discard) catch break;
                if (dn == 0 or (discard[0] >= 0x40 and discard[0] <= 0x7E)) break;
            }
            break :blk .delete;
        },
        else => blk: {
            // Consume remaining bytes of unknown sequence
            while ((std.posix.poll(&esc_poll, 5) catch 0) > 0) {
                _ = stdin.read(&b) catch break;
            }
            break :blk .none;
        },
    };
}

fn agentInteractive(shell: *Shell) !u8 {
    const out = shell.stdout();
    const agent_queue = @import("agent_queue.zig");

    const was_running = shell.agent.thread != null;

    // Ensure agent thread is running
    shell.agent.start() catch {
        try out.writeAll("\x1b[31magent: failed to start\x1b[0m\n");
        try out.flush();
        return 1;
    };

    var cfg = agent_log.AgentConfig.load(shell.allocator);
    var model_buf: [64]u8 = undefined;
    const model_src = shell.agent.getModelOverride() orelse cfg.model;
    const mlen = @min(model_src.len, model_buf.len);
    var model_name: []u8 = model_buf[0..mlen];
    @memcpy(model_name, model_src[0..mlen]);
    cfg.deinit();

    // ── TUI State ──
    var term_rows = getTermRows();
    var term_cols = getTermCols();
    var input_height: u16 = 1; // dynamic: min(editbuf.lineCount(), 5)
    const fixed_rows: u16 = 2; // separator + status bar

    // Layout computation
    var out_last = term_rows -| (fixed_rows + input_height); // last row of output scroll region
    if (out_last < 2) out_last = 2;
    var sep_row = out_last + 1;
    var input_first_row = sep_row + 1;
    var status_row = term_rows;

    var edit_buf: editor.EditBuffer = .{};
    var md: agent_mod.MarkdownRenderer = .{ .term_width = term_cols };
    var last_was_text = false;
    var agent_active = false;
    var in_confirm = false;
    var cursor_at: enum { output, input } = .output;
    var voice_was_speaking = false;
    var voice_silence_start: i64 = 0; // timestamp when speech stopped
    const voice_silence_timeout: i64 = 800; // ms of silence before auto-submit
    // Audio accumulation buffer: up to 30 seconds @ 16kHz mono
    var voice_audio_buf: [16000 * 30]i16 = undefined;
    var voice_audio_len: usize = 0;
    // TTS text accumulation buffer: collect response text for voice output
    var tts_buf: [8192]u8 = undefined;
    var tts_len: usize = 0;
    // Track last tool name for smart output display
    var last_tool: [32]u8 = undefined;
    var last_tool_len: usize = 0;

    // ? translation mode — captures response to pre-fill input
    var translate_mode = false;
    var translate_buf: [512]u8 = undefined;
    var translate_len: usize = 0;

    // Status bar state
    var cost_buf: [32]u8 = undefined;
    var cost_len: usize = 0;
    var status_text: [64]u8 = undefined;
    var status_len: usize = 0;
    var query_start_ms: i64 = 0; // timestamp when current query started

    // Message history for scrollback
    var msg_history: MessageHistory = .{};
    var scroll_offset: u32 = 0; // 0 = at bottom (live), >0 = scrolled up N lines

    // Router correction tracking
    var last_query_buf: [512]u8 = undefined;
    var last_query_len: usize = 0;
    var last_routed_tier: [16]u8 = undefined;
    var last_routed_tier_len: usize = 0;

    // Context window tracking for progress bar
    // Restore context tokens from agent if continuing a session
    var ctx_tokens: u32 = if (was_running) shell.agent.getTotalInputTokens() else 0;
    const ctx_max: u32 = 200_000; // default context window size

    // Files changed counter (shown in status bar cost area)
    var files_changed: u16 = 0;

    // Input history (ring buffer of previous queries)
    const HIST_SIZE = 64;
    var input_history: [HIST_SIZE][editor.LINE_BUF_SIZE]u8 = undefined;
    var input_history_lens: [HIST_SIZE]u16 = [_]u16{0} ** HIST_SIZE;
    var input_history_count: usize = 0;
    var input_history_write: usize = 0; // next write position
    var input_history_pos: usize = 0; // browsing position (0 = newest, counting backwards)
    var input_history_saved: [editor.LINE_BUF_SIZE]u8 = undefined; // saved current input when browsing
    var input_history_saved_len: u16 = 0;
    var input_history_browsing: bool = false;

    // ── Layout helpers (defined in agent_commands.zig) ──

    const TermWidth = agent_commands.TermWidth;
    const displayWidth = TermWidth.width;
    const truncateToCols = TermWidth.truncate;
    const Layout = agent_commands.Layout;
    const recalcLayout = struct {
        fn f(
            w: anytype,
            t_rows: u16,
            t_cols: u16,
            in_h: u16,
            o_last: *u16,
            s_row: *u16,
            in_first: *u16,
            stat_row: *u16,
            ebuf: *const editor.EditBuffer,
            mdl: []const u8,
            cost: []const u8,
            scroll_off: u32,
            status: []const u8,
        ) void {
            Layout.recalcLayout(w, t_rows, t_cols, in_h, o_last, s_row, in_first, stat_row, ebuf, mdl, cost, scroll_off, status);
        }
    };

    // ── Setup: push content up, configure layout ──
    {
        var i: u16 = 0;
        while (i < term_rows) : (i += 1) try out.writeByte('\n');
    }

    // Enable bracketed paste mode so we can handle Ctrl+V / paste correctly
    try out.writeAll("\x1b[?2004h");

    // Initial layout
    recalcLayout.f(out, term_rows, term_cols, input_height, &out_last, &sep_row, &input_first_row, &status_row, &edit_buf, model_name, cost_buf[0..cost_len], scroll_offset, status_text[0..status_len]);

    // Print header in scroll region (model · cwd · hint)
    Layout.goOutput(out, out_last);
    {
        var cwd_buf: [256]u8 = undefined;
        const cwd_full = std.posix.getcwd(&cwd_buf) catch "?";
        const home = std.posix.getenv("HOME") orelse "";
        var cwd_short_buf: [256]u8 = undefined;
        const cwd = if (home.len > 0 and std.mem.startsWith(u8, cwd_full, home))
            std.fmt.bufPrint(&cwd_short_buf, "~{s}", .{cwd_full[home.len..]}) catch cwd_full
        else
            cwd_full;
        // Detect git branch for context
        var branch: []const u8 = "";
        var branch_read_buf: [256]u8 = undefined;
        if (std.fs.cwd().openFile(".git/HEAD", .{})) |head| {
            defer head.close();
            const n = head.read(&branch_read_buf) catch 0;
            const content = std.mem.trim(u8, branch_read_buf[0..n], " \t\r\n");
            if (std.mem.startsWith(u8, content, "ref: refs/heads/"))
                branch = content[16..];
        } else |_| {}

        // Count dirty files for context
        var dirty_count: u16 = 0;
        {
            const git_result = std.process.Child.run(.{
                .allocator = shell.allocator,
                .argv = &[_][]const u8{ "git", "status", "--porcelain" },
                .max_output_bytes = 8192,
            }) catch null;
            if (git_result) |gr| {
                defer shell.allocator.free(gr.stdout);
                defer shell.allocator.free(gr.stderr);
                for (gr.stdout) |gc| {
                    if (gc == '\n') dirty_count += 1;
                }
            }
        }

        // Header: ╭ model · cwd · branch [dirty] · tips
        try out.writeAll("\x1b[90m\xe2\x95\xad "); // ╭
        try out.writeAll(model_name);
        try out.writeAll(" \xc2\xb7 "); // ·
        try out.writeAll(cwd);
        if (branch.len > 0) {
            try out.writeAll(" \xc2\xb7 \x1b[33m"); // · yellow
            try out.writeAll(branch);
            if (dirty_count > 0) {
                var dirty_buf: [16]u8 = undefined;
                const dirty_str = std.fmt.bufPrint(&dirty_buf, "\x1b[31m +{d}", .{dirty_count}) catch "";
                try out.writeAll(dirty_str);
            }
            try out.writeAll("\x1b[90m");
        }
        if (was_running) {
            try out.writeAll(" \xc2\xb7 continuing");
        } else {
            try out.writeAll(" \xc2\xb7 /help");
        }
        try out.writeAll("\x1b[0m\n");
        // First-use tips (only on fresh session)
        if (!was_running) {
            try out.writeAll("\x1b[2;90m  Tips: @file to include files \xc2\xb7 !cmd to run shell \xc2\xb7 ^P think \xc2\xb7 ^T model\x1b[0m\n");
        }
    }
    // Capture header in history
    {
        var hdr_buf: [256]u8 = undefined;
        const hdr = if (was_running)
            std.fmt.bufPrint(&hdr_buf, "\x1b[90m{s} \xc2\xb7 continuing\x1b[0m", .{model_name}) catch ""
        else
            std.fmt.bufPrint(&hdr_buf, "\x1b[90m{s} \xc2\xb7 /help\x1b[0m", .{model_name}) catch "";
        msg_history.appendSlice(hdr);
        msg_history.commitLine();
    }
    // Position cursor on input line
    Layout.drawInputSafeFull(out, input_first_row, input_height, &edit_buf, false, out_last, term_rows);
    try out.flush();

    // Create TeeWriter for capturing output to history
    const TW = TeeWriter(@TypeOf(out));

    // ── Main event loop ──
    while (true) {
        // Check terminal resize (debounced — bspwm sends rapid SIGWINCH during tiling)
        if (@atomicLoad(bool, &shell.terminal_resized, .acquire)) {
            @atomicStore(bool, &shell.terminal_resized, false, .release);
            const new_rows = getTermRows();
            const new_cols = getTermCols();
            // Skip if dimensions unchanged (spurious signal)
            if (new_rows == term_rows and new_cols == term_cols) continue;
            term_rows = new_rows;
            term_cols = new_cols;
            md.term_width = term_cols;
            // Full redraw: reset scroll region, clear, recalc layout, repaint
            out.print("\x1b[1;{d}r", .{term_rows}) catch {}; // expand to full screen
            out.writeAll("\x1b[H\x1b[2J") catch {}; // home + clear
            // Recalc: draws separator, input, status bar, sets scroll region to 1..out_last
            recalcLayout.f(out, term_rows, term_cols, input_height, &out_last, &sep_row, &input_first_row, &status_row, &edit_buf, model_name, cost_buf[0..cost_len], scroll_offset, status_text[0..status_len]);
            // Repaint history inside scroll region
            Layout.repaintFromHistory(out, &msg_history, out_last, scroll_offset);
            // Redraw input outside scroll region (recalcLayout already drew it, but repaint may have scrolled)
            Layout.drawInputSafeFull(out, input_first_row, input_height, &edit_buf, false, out_last, term_rows);
            Layout.drawSeparator(out, sep_row, term_cols, scroll_offset);
            if (!agent_active) cursor_at = .input;
            try out.flush();
        }

        // When idle, move cursor to input area (once, not every loop iteration)
        if (!agent_active and !in_confirm and cursor_at == .output) {
            Layout.drawInputSafeFull(out, input_first_row, input_height, &edit_buf, false, out_last, term_rows);
            cursor_at = .input;
            // Also redraw separator in case scroll state changed
            Layout.drawSeparator(out, sep_row, term_cols, scroll_offset);
            try out.flush();
        }

        // Poll stdin (and mic if voice active) with timeout
        var poll_fds: [2]std.posix.pollfd = .{
            .{
                .fd = std.posix.STDIN_FILENO,
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
            .{
                .fd = if (shell.voice_capture) |cap| cap.stdout_fd else -1,
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
        };
        const n_poll_fds: u32 = if (shell.voice_active and shell.voice_capture != null) 2 else 1;
        const poll_n = std.posix.poll(poll_fds[0..n_poll_fds], if (agent_active) @as(i32, 20) else @as(i32, 100)) catch 0;

        // ── Read mic audio if available ──
        if (n_poll_fds > 1 and (poll_fds[1].revents & std.posix.POLL.IN) != 0) {
            if (shell.voice_capture) |*cap| {
            var mic_buf: [1600]i16 = undefined; // 100ms @ 16kHz
            const n_samples = cap.read(&mic_buf);
            if (n_samples > 0) {
                const speaking = audio_mod.detectVoice(mic_buf[0..n_samples], 500_000);
                if (speaking) {
                    // Accumulate audio
                    const avail = voice_audio_buf.len - voice_audio_len;
                    const copy_n = @min(n_samples, avail);
                    if (copy_n > 0) {
                        @memcpy(voice_audio_buf[voice_audio_len..][0..copy_n], mic_buf[0..copy_n]);
                        voice_audio_len += copy_n;
                    }
                    voice_silence_start = 0; // reset silence timer
                    if (!voice_was_speaking) {
                        // Speech started
                        const s = "listening...";
                        @memcpy(status_text[0..s.len], s);
                        status_len = s.len;
                        Layout.drawStatusBarSafeCtx(out, status_row, term_rows, out_last, term_cols, model_name, cost_buf[0..cost_len], status_text[0..status_len], 0, ctx_tokens, ctx_max);
                    }
                } else if (voice_was_speaking and voice_audio_len > 0) {
                    // Speech just stopped — start silence timer
                    if (voice_silence_start == 0) {
                        voice_silence_start = std.time.milliTimestamp();
                        // Also buffer the trailing silence (some ASR models need it)
                        const avail = voice_audio_buf.len - voice_audio_len;
                        const copy_n = @min(n_samples, avail);
                        if (copy_n > 0) {
                            @memcpy(voice_audio_buf[voice_audio_len..][0..copy_n], mic_buf[0..copy_n]);
                            voice_audio_len += copy_n;
                        }
                    }
                }
                voice_was_speaking = speaking;
            }
            } // voice_capture null check
        }

        // ── Voice silence timeout → submit to ASR ──
        if (voice_silence_start > 0 and voice_audio_len > 1600) { // at least 100ms of audio
            const elapsed = std.time.milliTimestamp() - voice_silence_start;
            if (elapsed >= voice_silence_timeout) {
                // Transcribe accumulated audio
                const s = "transcribing...";
                @memcpy(status_text[0..s.len], s);
                status_len = s.len;
                Layout.drawStatusBarSafeCtx(out, status_row, term_rows, out_last, term_cols, model_name, cost_buf[0..cost_len], status_text[0..status_len], 0, ctx_tokens, ctx_max);
                try out.flush();

                // Write audio to temp WAV file, run curl to ASR endpoint
                const text = voiceTranscribe(shell.allocator, voice_audio_buf[0..voice_audio_len]);
                voice_audio_len = 0;
                voice_silence_start = 0;

                if (text) |transcribed| {
                    defer shell.allocator.free(transcribed);
                    if (transcribed.len > 0) {
                        // Show what was heard
                        Layout.goOutput(out, out_last);
                        try out.print("\x1b[36m> {s}\x1b[0m\n", .{transcribed});
                        msg_history.appendSlice("\x1b[36m> ");
                        msg_history.appendSlice(transcribed);
                        msg_history.appendSlice("\x1b[0m");
                        msg_history.commitLine();
                        cursor_at = .output;

                        // Send to agent
                        if (shell.agent.query(transcribed)) {
                            agent_active = true;
                            query_start_ms = std.time.milliTimestamp();
                            const thinking = "thinking...";
                            @memcpy(status_text[0..thinking.len], thinking);
                            status_len = thinking.len;
                        }
                    }
                } else {
                    const vs = "voice on";
                    @memcpy(status_text[0..vs.len], vs);
                    status_len = vs.len;
                }
                Layout.drawStatusBarSafeCtx(out, status_row, term_rows, out_last, term_cols, model_name, cost_buf[0..cost_len], status_text[0..status_len], if (query_start_ms > 0) std.time.milliTimestamp() - query_start_ms else 0, ctx_tokens, ctx_max);
                try out.flush();
            }
        }

        // ── Drain agent output queue ──
        var got_output = false;
        var msg: agent_queue.Msg = undefined;
        while (shell.agent.queues.output.pop(&msg)) {
            got_output = true;
            if (!agent_active and msg.kind != .done and msg.kind != .usage_info and msg.kind != .router_info and msg.kind != .confirm_response and msg.kind != .add_task and msg.kind != .spawn_worker and msg.kind != .agent_status_req and msg.kind != .agent_status) {
                agent_active = true;
            }

            // Auto-scroll to bottom on new output
            if (scroll_offset > 0 and msg.kind != .confirm_request) {
                scroll_offset = 0;
                Layout.drawSeparator(out, sep_row, term_cols, 0);
            }

            // Ensure cursor is in scroll region for output
            if (cursor_at != .output and msg.kind != .confirm_request) {
                Layout.goOutput(out, out_last);
                cursor_at = .output;
            }

            // Create tee writer for this message processing
            var tee = TW{ .inner = out, .hist = &msg_history };

            switch (msg.kind) {
                .text_delta => {
                    // Hide cursor during streaming for clean appearance
                    if (!last_was_text) {
                        try out.writeAll("\x1b[?25l"); // hide cursor
                        const writing = "writing";
                        @memcpy(status_text[0..writing.len], writing);
                        status_len = writing.len;
                    }
                    try md.render(tee, msg.slice());
                    try out.flush(); // flush each delta for smooth streaming
                    last_was_text = true;
                    // capture text for voice TTS output
                    if (shell.voice_active) {
                        const s = msg.slice();
                        const avail = tts_buf.len - tts_len;
                        const n = @min(s.len, avail);
                        if (n > 0) {
                            @memcpy(tts_buf[tts_len..][0..n], s[0..n]);
                            tts_len += n;
                        }
                    }
                    // capture text for ? translation
                    if (translate_mode) {
                        const s = msg.slice();
                        const avail = translate_buf.len - translate_len;
                        const n = @min(s.len, avail);
                        if (n > 0) {
                            @memcpy(translate_buf[translate_len..][0..n], s[0..n]);
                            translate_len += n;
                        }
                    }
                },
                .tool_call => {
                    if (last_was_text) {
                        try md.flush(tee);
                        try tee.writeAll("\x1b[0m");
                    }
                    md.reset();
                    last_was_text = false;
                    const tool_text = msg.slice();
                    // Track tool name for smart output + update status bar
                    {
                        const paren = std.mem.indexOfScalar(u8, tool_text, '(') orelse tool_text.len;
                        const name_end = @min(paren, std.mem.indexOfScalar(u8, tool_text, ' ') orelse tool_text.len);
                        last_tool_len = @min(name_end, last_tool.len);
                        @memcpy(last_tool[0..last_tool_len], tool_text[0..last_tool_len]);
                        const slen = @min(name_end, status_text.len);
                        @memcpy(status_text[0..slen], tool_text[0..slen]);
                        status_len = slen;
                        Layout.drawStatusBarSafeCtx(out, status_row, term_rows, out_last, term_cols, model_name, cost_buf[0..cost_len], status_text[0..status_len], if (query_start_ms > 0) std.time.milliTimestamp() - query_start_ms else 0, ctx_tokens, ctx_max);
                    }
                    // ⚡ ToolName args — compact indicator
                    try tee.writeAll("\n\x1b[90m\xe2\x9a\xa1 ");
                    // Find tool name and path argument
                    const space_pos = std.mem.indexOfScalar(u8, tool_text, ' ');
                    if (space_pos) |sp| {
                        const tool_name = tool_text[0..sp];
                        const tool_args = std.mem.trim(u8, tool_text[sp + 1 ..], " ");
                        try tee.writeAll(tool_name);
                        try tee.writeAll(" ");
                        // If args start with /, make it a clickable file link with short display
                        if (tool_args.len > 0 and tool_args[0] == '/') {
                            const path_end = std.mem.indexOfScalar(u8, tool_args, ' ') orelse tool_args.len;
                            const path = tool_args[0..path_end];
                            // Shorten: /home/user/... → ~/... or /cwd/... → ./...
                            const home = std.posix.getenv("HOME") orelse "";
                            var short_buf: [256]u8 = undefined;
                            const display_path = if (home.len > 0 and std.mem.startsWith(u8, path, home))
                                std.fmt.bufPrint(&short_buf, "~{s}", .{path[home.len..]}) catch path
                            else blk: {
                                var cwd_b: [256]u8 = undefined;
                                const cwd_s = std.posix.getcwd(&cwd_b) catch break :blk path;
                                if (std.mem.startsWith(u8, path, cwd_s) and path.len > cwd_s.len and path[cwd_s.len] == '/')
                                    break :blk path[cwd_s.len + 1 ..]
                                else
                                    break :blk path;
                            };
                            try tee.writeAll("\x1b]8;;file://");
                            try tee.writeAll(path);
                            try tee.writeAll("\x1b\\\x1b[4m"); // OSC 8 + underline
                            try tee.writeAll(display_path);
                            try tee.writeAll("\x1b[24m\x1b]8;;\x1b\\"); // end underline + close OSC 8
                            if (path_end < tool_args.len) try tee.writeAll(tool_args[path_end..]);
                        } else {
                            const max_w: usize = if (term_cols > 4) term_cols - 4 else term_cols;
                            const dw = displayWidth(tool_args);
                            if (dw + displayWidth(tool_name) + 3 > max_w) {
                                const avail = max_w -| (displayWidth(tool_name) + 3);
                                const trunc = truncateToCols(tool_args, avail);
                                try tee.writeAll(tool_args[0..trunc]);
                                try tee.writeAll("\xe2\x80\xa6");
                            } else {
                                try tee.writeAll(tool_args);
                            }
                        }
                    } else {
                        try tee.writeAll(tool_text);
                    }
                    try tee.writeAll("\x1b[0m\n");
                },
                .tool_done => {
                    last_was_text = false;
                    const done_text = msg.slice();

                    // Track file changes for status bar
                    {
                        const tool_name_fc = last_tool[0..last_tool_len];
                        if (std.mem.eql(u8, tool_name_fc, "Edit") or std.mem.eql(u8, tool_name_fc, "Write")) {
                            files_changed +|= 1;
                        }
                    }

                    if (done_text.len > 0) {
                        const has_ansi = std.mem.indexOf(u8, done_text, "\x1b[3") != null;
                        var line_count: usize = 1;
                        for (done_text) |dc| {
                            if (dc == '\n') line_count += 1;
                        }

                        // Smart threshold based on tool type
                        const tool_name = last_tool[0..last_tool_len];
                        const max_inline: usize = if (has_ansi)
                            999 // Edit diffs always show
                        else if (std.mem.eql(u8, tool_name, "Bash"))
                            20
                        else if (std.mem.eql(u8, tool_name, "Glob") or std.mem.eql(u8, tool_name, "Grep"))
                            15
                        else
                            8;

                        if (has_ansi or line_count <= max_inline) {
                            // Show inline with linkified paths
                            var line_start: usize = 0;
                            var shown: usize = 0;
                            for (done_text, 0..) |dc, di| {
                                if (dc == '\n' or di == done_text.len - 1) {
                                    const end = if (dc == '\n') di else di + 1;
                                    const line = done_text[line_start..end];
                                    if (has_ansi) {
                                        try tee.writeAll("  ");
                                        try tee.writeAll(line);
                                        try tee.writeAll("\x1b[0m\n");
                                    } else {
                                        try tee.writeAll("  \x1b[90m");
                                        linkify.writeLinked(tee, line) catch try tee.writeAll(line);
                                        try tee.writeAll("\x1b[0m\n");
                                    }
                                    line_start = di + 1;
                                    shown += 1;
                                }
                            }
                        } else {
                            // Show first lines + compact remainder
                            var line_start: usize = 0;
                            var shown: usize = 0;
                            const preview = max_inline / 2; // show half the threshold
                            for (done_text, 0..) |dc, di| {
                                if (dc == '\n' or di == done_text.len - 1) {
                                    if (shown < preview) {
                                        const end = if (dc == '\n') di else di + 1;
                                        const line = done_text[line_start..end];
                                        try tee.writeAll("  \x1b[90m");
                                        linkify.writeLinked(tee, line) catch try tee.writeAll(line);
                                        try tee.writeAll("\x1b[0m\n");
                                    }
                                    line_start = di + 1;
                                    shown += 1;
                                }
                            }
                            var more_buf: [64]u8 = undefined;
                            const more = std.fmt.bufPrint(&more_buf, "  \x1b[90m({d} more lines \xc2\xb7 ^U to scroll)\x1b[0m\n", .{line_count - preview}) catch "";
                            try tee.writeAll(more);
                            // Full content to history for scrollback
                            msg_history.appendSlice("  \x1b[90m");
                            msg_history.appendSlice(done_text[line_start..]);
                            msg_history.appendSlice("\x1b[0m");
                            msg_history.commitLine();
                        }
                    } else {
                        try tee.writeAll("  \x1b[32m\xe2\x9c\x93\x1b[0m\n");
                    }
                    // Back to thinking after tool completes
                    const thinking = "thinking...";
                    @memcpy(status_text[0..thinking.len], thinking);
                    status_len = thinking.len;
                    Layout.drawStatusBarSafeCtx(out, status_row, term_rows, out_last, term_cols, model_name, cost_buf[0..cost_len], status_text[0..status_len], if (query_start_ms > 0) std.time.milliTimestamp() - query_start_ms else 0, ctx_tokens, ctx_max);
                },
                .error_msg => {
                    if (last_was_text) {
                        try md.flush(tee);
                        md.reset();
                        try tee.writeAll("\x1b[0m\n");
                    }
                    last_was_text = false;
                    try tee.writeAll("\x1b[31m\xe2\x9c\x97 "); // ✗ red prefix
                    linkify.writeLinked(tee, msg.slice()) catch try tee.writeAll(msg.slice());
                    try tee.writeAll("\x1b[0m\n");
                    // Update status bar to show error state
                    const err_s = "error";
                    @memcpy(status_text[0..err_s.len], err_s);
                    status_len = err_s.len;
                },
                .usage_info => {
                    // Parse cost + token totals from usage_info for status bar
                    // Format: "tokens: N↑ N↓ | total: N↑ N↓ ($X.XX)" or "(free)"
                    const usage_text = msg.slice();
                    if (std.mem.indexOf(u8, usage_text, "(free)") != null) {
                        const free = "free";
                        @memcpy(cost_buf[0..free.len], free);
                        cost_len = free.len;
                    } else if (std.mem.indexOf(u8, usage_text, "($")) |dollar_pos| {
                        const cost_start = dollar_pos + 1;
                        if (std.mem.indexOfScalarPos(u8, usage_text, cost_start, ')')) |paren_end| {
                            const cost_str = usage_text[cost_start..paren_end];
                            // Also grab total tokens: find "total: N↑"
                            if (std.mem.indexOf(u8, usage_text, "total: ")) |total_pos| {
                                // Parse total input tokens for compact display
                                const tok_start = total_pos + 7;
                                const tok_end = std.mem.indexOfScalarPos(u8, usage_text, tok_start, '\xe2') orelse tok_start;
                                const tok_str = usage_text[tok_start..tok_end];
                                // Format: "$0.05 · 12K tok"
                                var tok_val: u32 = 0;
                                for (tok_str) |tc| {
                                    if (tc >= '0' and tc <= '9') tok_val = tok_val * 10 + (tc - '0');
                                }
                                const prev_tokens = ctx_tokens;
                                ctx_tokens = tok_val;
                                // Warn at 80% context usage (once)
                                if (tok_val > ctx_max * 80 / 100 and prev_tokens <= ctx_max * 80 / 100) {
                                    out.print("\x1b[33m\xe2\x9a\xa0 Context {d}% full \xe2\x80\x94 consider /compact\x1b[0m\n", .{tok_val * 100 / ctx_max}) catch {};
                                }
                                if (files_changed > 0) {
                                    cost_len = (std.fmt.bufPrint(&cost_buf, "{s} \xc2\xb7 {d} file{s}", .{ cost_str, files_changed, if (files_changed == 1) "" else "s" }) catch cost_str).len;
                                } else {
                                    cost_len = (std.fmt.bufPrint(&cost_buf, "{s}", .{cost_str}) catch cost_str).len;
                                }
                            } else {
                                cost_len = @min(cost_str.len, cost_buf.len);
                                @memcpy(cost_buf[0..cost_len], cost_str[0..cost_len]);
                            }
                        }
                    }
                    Layout.drawStatusBarSafeCtx(out, status_row, term_rows, out_last, term_cols, model_name, cost_buf[0..cost_len], status_text[0..status_len], if (query_start_ms > 0) std.time.milliTimestamp() - query_start_ms else 0, ctx_tokens, ctx_max);
                    if (last_was_text) {
                        try md.flush(tee);
                        md.reset();
                        try tee.writeAll("\x1b[0m\n");
                        last_was_text = false;
                    }
                },
                .router_info => {
                    // Don't print router info in output — show in status bar only
                    last_was_text = false;
                    // Extract tier from summary "agent -> small (low cost)"
                    const info = msg.slice();
                    if (std.mem.indexOf(u8, info, "-> ")) |arrow| {
                        const after = info[arrow + 3..];
                        const tier_end = std.mem.indexOfScalar(u8, after, ' ') orelse after.len;
                        const tier_name = after[0..tier_end];
                        const tlen = @min(tier_name.len, last_routed_tier.len);
                        @memcpy(last_routed_tier[0..tlen], tier_name[0..tlen]);
                        last_routed_tier_len = tlen;
                    }
                },
                .done => {
                    if (last_was_text) {
                        try md.flush(tee);
                        try tee.writeAll("\x1b[0m\n");
                    }
                    try out.writeAll("\x1b[?25h"); // show cursor
                    last_was_text = false;
                    md.reset();
                    agent_active = false;
                    // Show elapsed time + cost summary after response
                    if (query_start_ms > 0) {
                        const resp_elapsed = std.time.milliTimestamp() - query_start_ms;
                        const resp_secs = @divTrunc(resp_elapsed, 1000);
                        var time_buf: [64]u8 = undefined;
                        const time_str = if (resp_secs >= 60)
                            std.fmt.bufPrint(&time_buf, "\x1b[90m{d}m{d:0>2}s", .{ @divTrunc(resp_secs, 60), @mod(resp_secs, 60) }) catch ""
                        else
                            std.fmt.bufPrint(&time_buf, "\x1b[90m{d}s", .{resp_secs}) catch "";
                        try tee.writeAll(time_str);
                        if (cost_len > 0) {
                            try tee.writeAll(" \xc2\xb7 ");
                            try tee.writeAll(cost_buf[0..cost_len]);
                        }
                        if (ctx_tokens > 1000) {
                            var tok_buf: [16]u8 = undefined;
                            const tok_str = std.fmt.bufPrint(&tok_buf, " \xc2\xb7 {d}K ctx", .{ctx_tokens / 1000}) catch "";
                            try tee.writeAll(tok_str);
                        }
                        try tee.writeAll("\x1b[0m\n");
                    }
                    query_start_ms = 0;
                    // Voice TTS: speak the response
                    if (shell.voice_active and tts_len > 0) {
                        const speaking_s = "speaking...";
                        @memcpy(status_text[0..speaking_s.len], speaking_s);
                        status_len = speaking_s.len;
                        Layout.drawStatusBarSafe(out, status_row, term_rows, out_last, term_cols, model_name, cost_buf[0..cost_len], status_text[0..status_len]);
                        try out.flush();
                        voiceSpeak(shell.allocator, tts_buf[0..tts_len]);
                        tts_len = 0;
                    }
                    // Show done indicator briefly in status
                    status_len = 0;
                    Layout.drawStatusBarSafe(out, status_row, term_rows, out_last, term_cols, model_name, cost_buf[0..cost_len], "");
                    msg_history.commitLine(); // flush any partial line
                    // ? translation done — pre-fill input with !<command>
                    if (translate_mode and translate_len > 0) {
                        translate_mode = false;
                        // extract first line (the command)
                        const ttext = translate_buf[0..translate_len];
                        const first_nl = std.mem.indexOfScalar(u8, ttext, '\n') orelse ttext.len;
                        const cmd_line = std.mem.trim(u8, ttext[0..first_nl], " \t\r");
                        if (cmd_line.len > 0) {
                            edit_buf.clear();
                            _ = edit_buf.insertSlice("!");
                            _ = edit_buf.insertSlice(cmd_line);
                            // Recalculate input height for pre-filled content
                            const new_h: u16 = @min(edit_buf.lineCount(), 5);
                            if (new_h != input_height) {
                                input_height = new_h;
                                recalcLayout.f(out, term_rows, term_cols, input_height, &out_last, &sep_row, &input_first_row, &status_row, &edit_buf, model_name, cost_buf[0..cost_len], scroll_offset, status_text[0..status_len]);
                            }
                        }
                    }
                    translate_mode = false;
                    cursor_at = .output; // will switch to input next iteration
                },
                .confirm_request => {
                    if (last_was_text) {
                        try md.flush(tee);
                        try tee.writeAll("\x1b[0m\n");
                    }
                    last_was_text = false;
                    md.reset();
                    in_confirm = true;
                    // Update status bar to show awaiting confirmation
                    const confirm_s = "awaiting";
                    @memcpy(status_text[0..confirm_s.len], confirm_s);
                    status_len = confirm_s.len;
                    Layout.drawStatusBarSafeCtx(out, status_row, term_rows, out_last, term_cols, model_name, cost_buf[0..cost_len], status_text[0..status_len], if (query_start_ms > 0) std.time.milliTimestamp() - query_start_ms else 0, ctx_tokens, ctx_max);
                    // Render confirm prompt in input area (outside scroll region)
                    out.print("\x1b[1;{d}r", .{term_rows}) catch {};
                    try out.print("\x1b[{d};1H\x1b[2K\x1b[33m\xe2\x9a\xa0 \x1b[0m{s} \x1b[90m[\x1b[32my\x1b[90m/\x1b[31mn\x1b[90m/\x1b[33ma\x1b[90mlways]\x1b[0m ", .{ input_first_row, msg.slice() }); // ⚠ prefix
                    out.print("\x1b[1;{d}r", .{out_last}) catch {};
                    // Leave cursor at confirm prompt (don't restore to output)
                    cursor_at = .input;
                },
                .confirm_response, .add_task, .spawn_worker, .agent_status_req,
                .agent_tree_req, .agent_result_req => {},
                .agent_status => {
                    if (last_was_text) {
                        try md.flush(tee);
                        md.reset();
                        try tee.writeAll("\x1b[0m\n");
                    }
                    last_was_text = false;
                    if (msg.len > 0) {
                        try tee.writeAll(msg.slice());
                        try tee.writeByte('\n');
                    }
                },
                .cancel => {
                    try md.flush(tee);
                    md.reset();
                    try out.writeAll("\x1b[?25h"); // show cursor
                    msg_history.commitLine();
                    agent_active = false;
                    translate_mode = false;
                    status_len = 0;
                    cursor_at = .output;
                },
                .agent_tree_node, .agent_result => {}, // handled by tree view modal
            }
        }
        if (got_output) {
            // Only refresh input area on layout-changing events (done/tool boundaries)
            // Skip during text_delta streaming to avoid cursor flicker
            if (cursor_at == .output and !agent_active) {
                Layout.drawInputSafeFull(out, input_first_row, input_height, &edit_buf, false, out_last, term_rows);
            }
            try out.flush();
        } else if (agent_active and query_start_ms > 0) {
            const elapsed = std.time.milliTimestamp() - query_start_ms;

            // Live token counter from agent thread
            const live_tokens = shell.agent.getTotalInputTokens();
            if (live_tokens > 1000) ctx_tokens = live_tokens;

            // Status bar with spinner + context progress bar (spinner is built into drawStatusBarCtx)
            Layout.drawStatusBarSafeCtx(out, status_row, term_rows, out_last, term_cols, model_name, cost_buf[0..cost_len], status_text[0..status_len], elapsed, ctx_tokens, ctx_max);
            try out.flush();
        }

        // ── Handle stdin ──
        if (poll_n > 0 and (poll_fds[0].revents & std.posix.POLL.IN) != 0) {
            var byte: [1]u8 = undefined;
            const n = std.fs.File.stdin().read(&byte) catch break;
            if (n == 0) {
                Layout.doExit(out, term_rows, input_height);
                if (cost_len > 0 or files_changed > 0) {
                    out.writeAll("\x1b[90m") catch {};
                    if (cost_len > 0) out.writeAll(cost_buf[0..cost_len]) catch {};
                    if (files_changed > 0) {
                        if (cost_len > 0) out.writeAll(" \xc2\xb7 ") catch {};
                        out.print("{d} file{s} changed", .{ files_changed, if (files_changed == 1) @as([]const u8, "") else "s" }) catch {};
                    }
                    out.writeAll("\x1b[0m\n") catch {};
                    out.flush() catch {};
                }
                return 0;
            }

            if (in_confirm) {
                if (byte[0] == 'y' or byte[0] == 'Y') {
                    _ = shell.agent.queues.request.push(.confirm_response, "y");
                    msg_history.appendSlice("y");
                    msg_history.commitLine();
                } else if (byte[0] == 'a' or byte[0] == 'A' or byte[0] == '!') {
                    _ = shell.agent.queues.request.push(.confirm_response, "a");
                    msg_history.appendSlice("a (always)");
                    msg_history.commitLine();
                } else {
                    _ = shell.agent.queues.request.push(.confirm_response, "n");
                    msg_history.appendSlice("n");
                    msg_history.commitLine();
                }
                in_confirm = false;
                Layout.drawInputSafeFull(out, input_first_row, input_height, &edit_buf, false, out_last, term_rows);
                cursor_at = .input;
                try out.flush();
                continue;
            }

            // Ctrl+C / Ctrl+G
            if (byte[0] == 3 or byte[0] == 7) {
                if (agent_active) {
                    shell.agent.cancel();
                    Layout.goOutput(out, out_last);
                    // Close any open formatting and flush partial line to history
                    if (last_was_text) {
                        try out.writeAll("\x1b[0m");
                        msg_history.appendSlice("\x1b[0m");
                    }
                    msg_history.commitLine(); // commit partial streamed line
                    // Show what was happening when cancelled
                    const cancel_elapsed = if (query_start_ms > 0) std.time.milliTimestamp() - query_start_ms else 0;
                    const cancel_secs = @divTrunc(cancel_elapsed, 1000);
                    if (status_len > 0 and cancel_secs > 0) {
                        var cancel_buf: [96]u8 = undefined;
                        const cancel_msg = std.fmt.bufPrint(&cancel_buf, "\n\x1b[90m(cancelled after {d}s while {s})\x1b[0m\n", .{ cancel_secs, status_text[0..status_len] }) catch "\n\x1b[90m(cancelled)\x1b[0m\n";
                        try out.writeAll(cancel_msg);
                        msg_history.appendSlice(cancel_msg);
                    } else {
                        try out.writeAll("\n\x1b[90m(cancelled)\x1b[0m\n");
                        msg_history.appendSlice("\x1b[90m(cancelled)\x1b[0m");
                    }
                    msg_history.commitLine();
                    try md.flush(out);
                    md.reset();
                    agent_active = false;
                    query_start_ms = 0;
                    status_len = 0;
                    last_was_text = false;
                    cursor_at = .output;
                    Layout.drawStatusBarSafe(out, status_row, term_rows, out_last, term_cols, model_name, cost_buf[0..cost_len], "");
                } else if (edit_buf.len > 0) {
                    edit_buf.clear();
                    // Recalc input height
                    const new_h: u16 = 1;
                    if (new_h != input_height) {
                        input_height = new_h;
                        recalcLayout.f(out, term_rows, term_cols, input_height, &out_last, &sep_row, &input_first_row, &status_row, &edit_buf, model_name, cost_buf[0..cost_len], scroll_offset, status_text[0..status_len]);
                    }
                    Layout.drawInputSafeFull(out, input_first_row, input_height, &edit_buf, false, out_last, term_rows);
                    cursor_at = .input;
                } else {
                    {
                        // Show exit summary
                        Layout.doExit(out, term_rows, input_height);
                        if (cost_len > 0 or files_changed > 0) {
                            out.writeAll("\x1b[90m") catch {};
                            if (cost_len > 0) {
                                out.writeAll(cost_buf[0..cost_len]) catch {};
                            }
                            if (files_changed > 0) {
                                if (cost_len > 0) out.writeAll(" \xc2\xb7 ") catch {};
                                out.print("{d} file{s} changed", .{ files_changed, if (files_changed == 1) @as([]const u8, "") else "s" }) catch {};
                            }
                            out.writeAll("\x1b[0m\n") catch {};
                            out.flush() catch {};
                        }
                    }
                    return 0;
                }
                try out.flush();
                continue;
            }

            // Ctrl+D — exit on empty line
            if (byte[0] == 4) {
                if (edit_buf.len == 0) {
                    if (agent_active) shell.agent.cancel();
                    {
                        // Show exit summary
                        Layout.doExit(out, term_rows, input_height);
                        if (cost_len > 0 or files_changed > 0) {
                            out.writeAll("\x1b[90m") catch {};
                            if (cost_len > 0) {
                                out.writeAll(cost_buf[0..cost_len]) catch {};
                            }
                            if (files_changed > 0) {
                                if (cost_len > 0) out.writeAll(" \xc2\xb7 ") catch {};
                                out.print("{d} file{s} changed", .{ files_changed, if (files_changed == 1) @as([]const u8, "") else "s" }) catch {};
                            }
                            out.writeAll("\x1b[0m\n") catch {};
                            out.flush() catch {};
                        }
                    }
                    return 0;
                }
                continue;
            }

            // Ctrl+A (0x01) — readline home (move to line start)
            if (byte[0] == 0x01) {
                edit_buf.moveLineStart();
                Layout.drawInputSafeFull(out, input_first_row, input_height, &edit_buf, agent_active, out_last, term_rows);
                if (!agent_active) cursor_at = .input;
                try out.flush();
                continue;
            }

            // Ctrl+E (0x05) — readline end (move to line end)
            if (byte[0] == 0x05) {
                edit_buf.moveLineEnd();
                Layout.drawInputSafeFull(out, input_first_row, input_height, &edit_buf, agent_active, out_last, term_rows);
                if (!agent_active) cursor_at = .input;
                try out.flush();
                continue;
            }

            // Ctrl+T (0x14) — cycle model (haiku → sonnet → opus)
            if (byte[0] == 0x14) {
                const next_model: []const u8 = if (std.mem.indexOf(u8, model_name, "haiku") != null)
                    "sonnet"
                else if (std.mem.indexOf(u8, model_name, "sonnet") != null)
                    "opus"
                else
                    "haiku";
                // Dispatch /model command
                var cmd_ctx = agent_commands.CommandCtx{
                    .shell = shell, .out = out, .model_name = model_name, .model_buf = &model_buf,
                    .cost_buf = &cost_buf, .cost_len = &cost_len, .status_text = &status_text,
                    .status_len = &status_len, .msg_history = &msg_history, .edit_buf = &edit_buf,
                    .agent_active = &agent_active, .query_start_ms = &query_start_ms,
                    .scroll_offset = &scroll_offset, .out_last = &out_last, .sep_row = &sep_row,
                    .input_first_row = &input_first_row, .status_row = &status_row,
                    .term_rows = &term_rows, .term_cols = &term_cols, .input_height = &input_height,
                    .md = &md, .last_was_text = &last_was_text, .last_query_buf = &last_query_buf,
                    .last_query_len = &last_query_len, .last_routed_tier = &last_routed_tier,
                    .last_routed_tier_len = &last_routed_tier_len,
                };
                _ = agent_commands.dispatch(&cmd_ctx, std.fmt.bufPrint(&model_buf, "/model {s}", .{next_model}) catch "/model sonnet");
                model_name = cmd_ctx.model_name;
                Layout.drawStatusBarSafeCtx(out, status_row, term_rows, out_last, term_cols, model_name, cost_buf[0..cost_len], status_text[0..status_len], 0, ctx_tokens, ctx_max);
                try out.flush();
                continue;
            }

            // Ctrl+W (0x17) — delete word backward
            if (byte[0] == 0x17) {
                if (edit_buf.len > 0 and edit_buf.cursor > 0) {
                    const old_cursor = edit_buf.cursor;
                    edit_buf.wordBack();
                    const new_cursor = edit_buf.cursor;
                    // Delete from new_cursor to old_cursor
                    var di: usize = old_cursor - new_cursor;
                    while (di > 0) : (di -= 1) {
                        _ = edit_buf.deleteForward();
                    }
                    const new_h: u16 = @min(edit_buf.lineCount(), 5);
                    if (new_h != input_height) {
                        input_height = new_h;
                        recalcLayout.f(out, term_rows, term_cols, input_height, &out_last, &sep_row, &input_first_row, &status_row, &edit_buf, model_name, cost_buf[0..cost_len], scroll_offset, status_text[0..status_len]);
                    }
                    Layout.drawInputSafeFull(out, input_first_row, input_height, &edit_buf, agent_active, out_last, term_rows);
                    if (!agent_active) cursor_at = .input;
                    try out.flush();
                }
                continue;
            }

            // Ctrl+P (0x10) — toggle extended thinking
            if (byte[0] == 0x10) {
                const current_tb = shell.agent.queues.shared_thinking_budget.load(.monotonic);
                if (current_tb > 0) {
                    shell.agent.queues.shared_thinking_budget.store(0, .monotonic);
                    const off_s = "thinking off";
                    @memcpy(status_text[0..off_s.len], off_s);
                    status_len = off_s.len;
                } else {
                    shell.agent.queues.shared_thinking_budget.store(10000, .monotonic);
                    const on_s = "thinking on (10K)";
                    @memcpy(status_text[0..on_s.len], on_s);
                    status_len = on_s.len;
                }
                Layout.drawStatusBarSafeCtx(out, status_row, term_rows, out_last, term_cols, model_name, cost_buf[0..cost_len], status_text[0..status_len], 0, ctx_tokens, ctx_max);
                try out.flush();
                continue;
            }

            // Ctrl+B (0x02) — show background tasks / agents
            if (byte[0] == 0x02) {
                // Trigger /tree command
                const cmds = @import("agent_commands.zig");
                cmds.runTreeView(shell, out, term_rows, term_cols);
                recalcLayout.f(out, term_rows, term_cols, input_height, &out_last, &sep_row, &input_first_row, &status_row, &edit_buf, model_name, cost_buf[0..cost_len], scroll_offset, status_text[0..status_len]);
                cursor_at = .output;
                try out.flush();
                continue;
            }

            // Ctrl+U (0x15) — scroll up half page (vim-style)
            // Ctrl+F (0x06) — scroll down half page
            if (byte[0] == 0x15 or byte[0] == 0x06) {
                if (msg_history.line_count > 0) {
                    const page = out_last / 2;
                    if (byte[0] == 0x06) {
                        // Down
                        if (scroll_offset > page) {
                            scroll_offset -= page;
                        } else {
                            scroll_offset = 0;
                        }
                    } else {
                        // Up
                        scroll_offset += page;
                        if (scroll_offset > msg_history.line_count) scroll_offset = msg_history.line_count;
                    }
                    Layout.repaintFromHistory(out, &msg_history, out_last, scroll_offset);
                    Layout.drawSeparator(out, sep_row, term_cols, scroll_offset);
                    try out.flush();
                }
                continue;
            }

            // Ctrl+L (0x0C) — clear screen, redraw from history
            if (byte[0] == 0x0C) {
                scroll_offset = 0;
                out.print("\x1b[1;{d}r", .{term_rows}) catch {};
                out.writeAll("\x1b[H\x1b[2J") catch {};
                recalcLayout.f(out, term_rows, term_cols, input_height, &out_last, &sep_row, &input_first_row, &status_row, &edit_buf, model_name, cost_buf[0..cost_len], scroll_offset, status_text[0..status_len]);
                Layout.repaintFromHistory(out, &msg_history, out_last, scroll_offset);
                try out.flush();
                cursor_at = .input;
                continue;
            }

            // Ctrl+K — jump to previous user message in scrollback
            // Ctrl+N — jump to next user message in scrollback
            // Ctrl+O (0x0F) — scroll to show context around current position
            if (byte[0] == 0x0F and scroll_offset > 0) {
                // Jump scroll to center the current view
                if (scroll_offset > out_last) {
                    scroll_offset -= out_last;
                } else {
                    scroll_offset = 0;
                }
                Layout.repaintFromHistory(out, &msg_history, out_last, scroll_offset);
                Layout.drawSeparator(out, sep_row, term_cols, scroll_offset);
                try out.flush();
                continue;
            }

            if (byte[0] == 11 or byte[0] == 14) {
                if (msg_history.line_count > 0) {
                    var hl_line: ?u32 = null;
                    if (byte[0] == 11) {
                        // Ctrl+K — jump to previous user message (search for bold ">")
                        const current_pos = if (msg_history.line_count > scroll_offset)
                            msg_history.line_count - scroll_offset
                        else msg_history.line_count;
                        const search_start = if (current_pos > 0) current_pos - 1 else 0;
                        if (msg_history.searchBack("> ", search_start)) |found| {
                            hl_line = found;
                            const from_bottom = msg_history.line_count - found;
                            // Position found line near top of screen
                            scroll_offset = if (from_bottom > 2) from_bottom - 2 else 0;
                        }
                    } else {
                        // Ctrl+N — jump to next user message
                        const current_pos = if (msg_history.line_count > scroll_offset)
                            msg_history.line_count - scroll_offset
                        else 0;
                        if (msg_history.searchForward("> ", current_pos + 1)) |found| {
                            hl_line = found;
                            const from_bottom = msg_history.line_count - found;
                            scroll_offset = if (from_bottom > 2) from_bottom - 2 else 0;
                        } else {
                            scroll_offset = 0; // no more, go to bottom
                        }
                    }
                    Layout.repaintFromHistoryHL(out, &msg_history, out_last, scroll_offset, hl_line);
                    Layout.drawSeparator(out, sep_row, term_cols, scroll_offset);
                    try out.flush();
                }
                continue;
            }

            // Escape sequence — parse arrows, PageUp/Down, etc.
            if (byte[0] == 27) {
                const action = parseEscSequence();
                if (action == .enter) {
                    byte[0] = '\r'; // fall through to Enter handler below
                } else {
                switch (action) {
                    .arrow_left => {
                        _ = edit_buf.moveLeft();
                        Layout.drawInputSafeFull(out, input_first_row, input_height, &edit_buf, agent_active, out_last, term_rows);
                        if (!agent_active) cursor_at = .input;
                        try out.flush();
                    },
                    .arrow_right => {
                        _ = edit_buf.moveRight();
                        Layout.drawInputSafeFull(out, input_first_row, input_height, &edit_buf, agent_active, out_last, term_rows);
                        if (!agent_active) cursor_at = .input;
                        try out.flush();
                    },
                    .arrow_up => {
                        // Single-line: browse input history. Multi-line: move cursor up.
                        if (edit_buf.lineCount() <= 1 and input_history_count > 0) {
                            if (!input_history_browsing) {
                                // Save current input
                                input_history_browsing = true;
                                input_history_pos = 0;
                                input_history_saved_len = @intCast(edit_buf.len);
                                @memcpy(input_history_saved[0..edit_buf.len], edit_buf.text[0..edit_buf.len]);
                            }
                            if (input_history_pos < input_history_count) {
                                input_history_pos += 1;
                                // Load from history
                                const idx = (input_history_write + HIST_SIZE - input_history_pos) % HIST_SIZE;
                                const hlen = input_history_lens[idx];
                                edit_buf.clear();
                                _ = edit_buf.insertSlice(input_history[idx][0..hlen]);
                            }
                        } else {
                            _ = edit_buf.moveUp();
                        }
                        Layout.drawInputSafeFull(out, input_first_row, input_height, &edit_buf, agent_active, out_last, term_rows);
                        if (!agent_active) cursor_at = .input;
                        try out.flush();
                    },
                    .arrow_down => {
                        if (edit_buf.lineCount() <= 1 and input_history_browsing) {
                            if (input_history_pos > 1) {
                                input_history_pos -= 1;
                                const idx = (input_history_write + HIST_SIZE - input_history_pos) % HIST_SIZE;
                                const hlen = input_history_lens[idx];
                                edit_buf.clear();
                                _ = edit_buf.insertSlice(input_history[idx][0..hlen]);
                            } else {
                                // Back to original input
                                input_history_pos = 0;
                                input_history_browsing = false;
                                edit_buf.clear();
                                _ = edit_buf.insertSlice(input_history_saved[0..input_history_saved_len]);
                            }
                        } else {
                            _ = edit_buf.moveDown();
                        }
                        Layout.drawInputSafeFull(out, input_first_row, input_height, &edit_buf, agent_active, out_last, term_rows);
                        if (!agent_active) cursor_at = .input;
                        try out.flush();
                    },
                    .ctrl_up => {
                        // Jump to previous user message (same as Ctrl+K)
                        if (msg_history.line_count > 0) {
                            const current_pos = if (msg_history.line_count > scroll_offset)
                                msg_history.line_count - scroll_offset
                            else msg_history.line_count;
                            const search_start = if (current_pos > 0) current_pos - 1 else 0;
                            if (msg_history.searchBack("> ", search_start)) |found| {
                                const from_bottom = msg_history.line_count - found;
                                scroll_offset = if (from_bottom > 2) from_bottom - 2 else 0;
                            } else {
                                scroll_offset = msg_history.line_count;
                            }
                            Layout.repaintFromHistory(out, &msg_history, out_last, scroll_offset);
                            Layout.drawSeparator(out, sep_row, term_cols, scroll_offset);
                            try out.flush();
                        }
                    },
                    .ctrl_down => {
                        // Jump to next user message (same as Ctrl+N)
                        if (scroll_offset > 0 and msg_history.line_count > 0) {
                            const current_pos = if (msg_history.line_count > scroll_offset)
                                msg_history.line_count - scroll_offset
                            else 0;
                            if (msg_history.searchForward("> ", current_pos + 1)) |found| {
                                const from_bottom = msg_history.line_count - found;
                                scroll_offset = if (from_bottom > 2) from_bottom - 2 else 0;
                            } else {
                                scroll_offset = 0;
                            }
                            Layout.repaintFromHistory(out, &msg_history, out_last, scroll_offset);
                            Layout.drawSeparator(out, sep_row, term_cols, scroll_offset);
                            try out.flush();
                        }
                    },
                    .ctrl_left => {
                        edit_buf.wordBack();
                        Layout.drawInputSafeFull(out, input_first_row, input_height, &edit_buf, agent_active, out_last, term_rows);
                        if (!agent_active) cursor_at = .input;
                        try out.flush();
                    },
                    .ctrl_right => {
                        edit_buf.wordForward();
                        Layout.drawInputSafeFull(out, input_first_row, input_height, &edit_buf, agent_active, out_last, term_rows);
                        if (!agent_active) cursor_at = .input;
                        try out.flush();
                    },
                    .home => {
                        edit_buf.moveLineStart();
                        Layout.drawInputSafeFull(out, input_first_row, input_height, &edit_buf, agent_active, out_last, term_rows);
                        if (!agent_active) cursor_at = .input;
                        try out.flush();
                    },
                    .end => {
                        edit_buf.moveLineEnd();
                        Layout.drawInputSafeFull(out, input_first_row, input_height, &edit_buf, agent_active, out_last, term_rows);
                        if (!agent_active) cursor_at = .input;
                        try out.flush();
                    },
                    .page_up => {
                        if (msg_history.line_count > 0) {
                            const page = out_last / 2;
                            scroll_offset += page;
                            if (scroll_offset > msg_history.line_count) scroll_offset = msg_history.line_count;
                            Layout.repaintFromHistory(out, &msg_history, out_last, scroll_offset);
                            Layout.drawSeparator(out, sep_row, term_cols, scroll_offset);
                            try out.flush();
                        }
                    },
                    .page_down => {
                        if (scroll_offset > 0) {
                            const page = out_last / 2;
                            if (scroll_offset > page) {
                                scroll_offset -= page;
                            } else {
                                scroll_offset = 0;
                            }
                            Layout.repaintFromHistory(out, &msg_history, out_last, scroll_offset);
                            Layout.drawSeparator(out, sep_row, term_cols, scroll_offset);
                            try out.flush();
                        }
                    },
                    .alt_enter => {
                        if (edit_buf.insert('\n')) {
                            const new_h: u16 = @min(edit_buf.lineCount(), 5);
                            if (new_h != input_height) {
                                input_height = new_h;
                                recalcLayout.f(out, term_rows, term_cols, input_height, &out_last, &sep_row, &input_first_row, &status_row, &edit_buf, model_name, cost_buf[0..cost_len], scroll_offset, status_text[0..status_len]);
                            }
                            Layout.drawInputSafeFull(out, input_first_row, input_height, &edit_buf, agent_active, out_last, term_rows);
                            if (!agent_active) cursor_at = .input;
                            try out.flush();
                        }
                    },
                    .delete => {
                        if (edit_buf.deleteForward()) {
                            const new_h: u16 = @min(edit_buf.lineCount(), 5);
                            if (new_h != input_height) {
                                input_height = new_h;
                                recalcLayout.f(out, term_rows, term_cols, input_height, &out_last, &sep_row, &input_first_row, &status_row, &edit_buf, model_name, cost_buf[0..cost_len], scroll_offset, status_text[0..status_len]);
                            }
                            Layout.drawInputSafeFull(out, input_first_row, input_height, &edit_buf, agent_active, out_last, term_rows);
                            if (!agent_active) cursor_at = .input;
                            try out.flush();
                        }
                    },
                    .alt_key => |alt_byte| {
                        // Look up Alt+key in configurable keybindings table
                        if (shell.keybindings.lookupAlt(alt_byte)) |act| {
                            const ba = actionToBindable(act);
                            const result = applyTuiBindableAction(ba, &edit_buf, shell);
                            if (result != .none) {
                                if (result == .modified) {
                                    const new_h: u16 = @min(edit_buf.lineCount(), 5);
                                    if (new_h != input_height) {
                                        input_height = new_h;
                                        recalcLayout.f(out, term_rows, term_cols, input_height, &out_last, &sep_row, &input_first_row, &status_row, &edit_buf, model_name, cost_buf[0..cost_len], scroll_offset, status_text[0..status_len]);
                                    }
                                }
                                Layout.drawInputSafeFull(out, input_first_row, input_height, &edit_buf, agent_active, out_last, term_rows);
                                if (!agent_active) cursor_at = .input;
                                try out.flush();
                            }
                        }
                    },
                    .paste => {
                        // Bracketed paste: read until ESC[201~
                        const stdin_f = std.fs.File.stdin();
                        var paste_byte: [1]u8 = undefined;
                        var esc_state: u8 = 0; // 0=normal, 1=ESC, 2=[, 3=2, 4=0, 5=1
                        var pasted = false;
                        while (true) {
                            const pn = stdin_f.read(&paste_byte) catch break;
                            if (pn == 0) break;
                            const pc = paste_byte[0];
                            // Detect ESC[201~ end sequence
                            switch (esc_state) {
                                0 => if (pc == 0x1b) { esc_state = 1; continue; },
                                1 => { esc_state = if (pc == '[') 2 else 0; if (esc_state == 0) { _ = edit_buf.insert(0x1b); _ = edit_buf.insert(pc); pasted = true; } continue; },
                                2 => { esc_state = if (pc == '2') 3 else 0; if (esc_state == 0) { _ = edit_buf.insert(pc); pasted = true; } continue; },
                                3 => { esc_state = if (pc == '0') 4 else 0; if (esc_state == 0) { _ = edit_buf.insert(pc); pasted = true; } continue; },
                                4 => { esc_state = if (pc == '1') 5 else 0; if (esc_state == 0) { _ = edit_buf.insert(pc); pasted = true; } continue; },
                                5 => { if (pc == '~') break; esc_state = 0; _ = edit_buf.insert(pc); pasted = true; continue; }, // end of paste
                                else => { esc_state = 0; },
                            }
                            // Insert the character (convert \r to \n)
                            if (pc == '\r') {
                                _ = edit_buf.insert('\n');
                            } else if (pc >= 0x20 or pc == '\n' or pc == '\t') {
                                _ = edit_buf.insert(pc);
                            }
                            pasted = true;
                        }
                        if (pasted) {
                            // Switch to insert mode if in vi normal
                            edit_buf.vi_mode = .insert;
                            const new_h: u16 = @min(edit_buf.lineCount(), 5);
                            if (new_h != input_height) {
                                input_height = new_h;
                                recalcLayout.f(out, term_rows, term_cols, input_height, &out_last, &sep_row, &input_first_row, &status_row, &edit_buf, model_name, cost_buf[0..cost_len], scroll_offset, status_text[0..status_len]);
                            }
                            Layout.drawInputSafeFull(out, input_first_row, input_height, &edit_buf, agent_active, out_last, term_rows);
                            if (!agent_active) cursor_at = .input;
                            try out.flush();
                        }
                    },
                    .none => {
                        // Bare Escape — switch to vi normal mode
                        if (edit_buf.vi_mode == .insert) {
                            edit_buf.vi_mode = .normal;
                            if (edit_buf.cursor > 0) edit_buf.cursor -= 1; // vi convention
                            Layout.drawInputSafeFull(out, input_first_row, input_height, &edit_buf, agent_active, out_last, term_rows);
                            if (!agent_active) cursor_at = .input;
                            try out.flush();
                        }
                    },
                    .enter => {}, // handled above, won't reach here
                }
                continue;
                } // end else
            }

            // ── Vi normal mode key handling ──
            if (edit_buf.vi_mode == .normal and byte[0] >= 0x20 and byte[0] < 0x80) {
                const vi_c = byte[0];
                var need_redraw = true;
                var vi_pending: u8 = 0; // for two-key commands (dd, dw, cc, etc.)
                _ = &vi_pending;
                switch (vi_c) {
                    // Mode switches
                    'i' => { edit_buf.vi_mode = .insert; need_redraw = false; },
                    'a' => {
                        if (edit_buf.cursor < edit_buf.len) edit_buf.cursor += 1;
                        edit_buf.vi_mode = .insert;
                    },
                    'A' => { edit_buf.moveLineEnd(); edit_buf.vi_mode = .insert; },
                    'I' => { edit_buf.moveFirstNonBlank(); edit_buf.vi_mode = .insert; },
                    'o' => {
                        edit_buf.moveLineEnd();
                        _ = edit_buf.insert('\n');
                        edit_buf.vi_mode = .insert;
                    },
                    'O' => {
                        edit_buf.moveLineStart();
                        _ = edit_buf.insert('\n');
                        if (edit_buf.cursor > 0) edit_buf.cursor -= 1;
                        edit_buf.vi_mode = .insert;
                    },
                    // Movement
                    'h' => { _ = edit_buf.moveLeft(); },
                    'l' => { _ = edit_buf.moveRight(); },
                    'j' => { _ = edit_buf.moveDown(); },
                    'k' => { _ = edit_buf.moveUp(); },
                    'w' => { edit_buf.wordForward(); },
                    'b' => { edit_buf.wordBack(); },
                    'e' => { edit_buf.wordEnd(); },
                    '0' => { edit_buf.moveLineStart(); },
                    '^' => { edit_buf.moveFirstNonBlank(); },
                    '$' => { edit_buf.moveLineEnd(); },
                    // Delete operations
                    'x' => { _ = edit_buf.deleteAt(); },
                    'X' => { _ = edit_buf.delete(); },
                    'D' => { edit_buf.deleteToEnd(); },
                    'C' => { edit_buf.deleteToEnd(); edit_buf.vi_mode = .insert; },
                    'S' => { edit_buf.deleteLine(); edit_buf.vi_mode = .insert; },
                    // Two-key commands: read next key
                    'd', 'c' => {
                        // Read next key for motion
                        var esc_poll2 = [_]std.posix.pollfd{.{
                            .fd = std.posix.STDIN_FILENO,
                            .events = std.posix.POLL.IN,
                            .revents = 0,
                        }};
                        if ((std.posix.poll(&esc_poll2, 500) catch 0) > 0) {
                            var b2: [1]u8 = undefined;
                            const n2 = std.fs.File.stdin().read(&b2) catch 0;
                            if (n2 > 0) {
                                if (b2[0] == vi_c) {
                                    // dd or cc — delete/change entire line
                                    if (vi_c == 'c') {
                                        edit_buf.deleteLine();
                                        edit_buf.vi_mode = .insert;
                                    } else {
                                        edit_buf.deleteLine();
                                    }
                                } else if (b2[0] == 'w') {
                                    // dw or cw
                                    edit_buf.deleteWord();
                                    if (vi_c == 'c') edit_buf.vi_mode = .insert;
                                } else if (b2[0] == '$') {
                                    // d$ or c$
                                    edit_buf.deleteToEnd();
                                    if (vi_c == 'c') edit_buf.vi_mode = .insert;
                                } else if (b2[0] == '0') {
                                    // d0 or c0 — delete to start of line
                                    const start_pos = edit_buf.cursor;
                                    edit_buf.moveLineStart();
                                    const end = start_pos;
                                    const begin = edit_buf.cursor;
                                    if (end > begin) {
                                        const remaining = edit_buf.len - end;
                                        if (remaining > 0)
                                            std.mem.copyForwards(u8, edit_buf.text[begin..begin + remaining], edit_buf.text[end..edit_buf.len]);
                                        edit_buf.len -= @intCast(end - begin);
                                    }
                                    if (vi_c == 'c') edit_buf.vi_mode = .insert;
                                } else {
                                    need_redraw = false; // unknown motion, ignore
                                }
                            }
                        } else {
                            need_redraw = false;
                        }
                    },
                    'r' => {
                        // Replace char: read next key (UTF-8 aware)
                        var esc_poll2 = [_]std.posix.pollfd{.{
                            .fd = std.posix.STDIN_FILENO,
                            .events = std.posix.POLL.IN,
                            .revents = 0,
                        }};
                        if ((std.posix.poll(&esc_poll2, 500) catch 0) > 0) {
                            var b2: [4]u8 = undefined;
                            const n2 = std.fs.File.stdin().read(b2[0..1]) catch 0;
                            if (n2 > 0 and b2[0] >= 0x20) {
                                // Determine UTF-8 sequence length from lead byte
                                const seq_len: usize = if (b2[0] < 0x80) 1 else if ((b2[0] & 0xE0) == 0xC0) 2 else if ((b2[0] & 0xF0) == 0xE0) 3 else if ((b2[0] & 0xF8) == 0xF0) 4 else 1;
                                // Read remaining continuation bytes
                                var got: usize = 1;
                                while (got < seq_len) {
                                    const nr = std.fs.File.stdin().read(b2[got .. got + 1]) catch break;
                                    if (nr == 0) break;
                                    got += 1;
                                }
                                if (got == seq_len) {
                                    // Delete old char under cursor (may be multi-byte)
                                    if (edit_buf.cursor < edit_buf.len) {
                                        const old_b0 = edit_buf.text[edit_buf.cursor];
                                        const old_len: usize = if (old_b0 < 0x80) 1 else if ((old_b0 & 0xE0) == 0xC0) 2 else if ((old_b0 & 0xF0) == 0xE0) 3 else if ((old_b0 & 0xF8) == 0xF0) 4 else 1;
                                        const del_end = @min(edit_buf.cursor + old_len, edit_buf.len);
                                        // Remove old bytes
                                        var di: usize = 0;
                                        while (di < old_len and edit_buf.cursor < edit_buf.len) : (di += 1) {
                                            _ = edit_buf.deleteAt();
                                        }
                                        _ = del_end;
                                        // Insert new bytes
                                        _ = edit_buf.insertSlice(b2[0..seq_len]);
                                        // Keep cursor on the replaced char
                                        if (edit_buf.cursor > 0) edit_buf.cursor -= 1;
                                    }
                                }
                            }
                        } else {
                            need_redraw = false;
                        }
                    },
                    // Paste / put not implemented, treat 'p' as no-op
                    else => { need_redraw = false; },
                }
                if (need_redraw) {
                    const new_h: u16 = @min(edit_buf.lineCount(), 5);
                    if (new_h != input_height) {
                        input_height = new_h;
                        recalcLayout.f(out, term_rows, term_cols, input_height, &out_last, &sep_row, &input_first_row, &status_row, &edit_buf, model_name, cost_buf[0..cost_len], scroll_offset, status_text[0..status_len]);
                    }
                    Layout.drawInputSafeFull(out, input_first_row, input_height, &edit_buf, agent_active, out_last, term_rows);
                    if (!agent_active) cursor_at = .input;
                    try out.flush();
                }
                continue;
            }

            // Ctrl+J (0x0A) — insert newline
            if (byte[0] == 0x0A) {
                if (edit_buf.insert('\n')) {
                    const new_h: u16 = @min(edit_buf.lineCount(), 5);
                    if (new_h != input_height) {
                        input_height = new_h;
                        recalcLayout.f(out, term_rows, term_cols, input_height, &out_last, &sep_row, &input_first_row, &status_row, &edit_buf, model_name, cost_buf[0..cost_len], scroll_offset, status_text[0..status_len]);
                    }
                    Layout.drawInputSafeFull(out, input_first_row, input_height, &edit_buf, agent_active, out_last, term_rows);
                    if (!agent_active) cursor_at = .input;
                    try out.flush();
                }
                continue;
            }

            // Tab — complete slash commands and file paths
            if (byte[0] == '\t') {
                const text = edit_buf.slice();
                if (text.len > 0 and text[0] == '/') {
                    // Slash command completion
                    const slash_cmds = [_][]const u8{
                        "/compact", "/cost",     "/model",    "/diff",    "/commit",
                        "/review",  "/undo",     "/plan",     "/spawn",   "/queue",
                        "/agents",  "/tasks",    "/tree",     "/sessions", "/config",
                        "/search",  "/voice",    "/init",     "/effort",  "/status",
                        "/think",   "/build",    "/test",     "/fix",     "/web",     "/pr",
                        "/run",     "/cd",
                        "/git",     "/export",
                        "/new",     "/clear",    "/help",
                    };
                    var matches: [16][]const u8 = undefined;
                    var match_count: u8 = 0;
                    for (slash_cmds) |cmd| {
                        if (std.mem.startsWith(u8, cmd, text)) {
                            if (match_count < matches.len) {
                                matches[match_count] = cmd;
                                match_count += 1;
                            }
                        }
                    }
                    if (match_count == 1) {
                        edit_buf.clear();
                        _ = edit_buf.insertSlice(matches[0]);
                        _ = edit_buf.insert(' ');
                    } else if (match_count > 1) {
                        // Find common prefix among matches and complete to it
                        var common_len: usize = matches[0].len;
                        for (matches[1..match_count]) |m| {
                            common_len = @min(common_len, m.len);
                            var j: usize = 0;
                            while (j < common_len and matches[0][j] == m[j]) : (j += 1) {}
                            common_len = j;
                        }
                        if (common_len > text.len) {
                            edit_buf.clear();
                            _ = edit_buf.insertSlice(matches[0][0..common_len]);
                        } else {
                            // Show matches in output area
                            // Show matches in scroll region
                            try out.print("\x1b[{d};1H\x1b[90m", .{out_last});
                            for (matches[0..match_count]) |m| {
                                try out.writeAll(m);
                                try out.writeByte(' ');
                            }
                            try out.writeAll("\x1b[0m\n");
                            msg_history.appendSlice("\x1b[90m");
                            for (matches[0..match_count]) |m| {
                                msg_history.appendSlice(m);
                                msg_history.appendSlice(" ");
                            }
                            msg_history.appendSlice("\x1b[0m");
                            msg_history.commitLine();
                        }
                    }
                } else if (text.len > 0) {
                    // File path completion — find the word under cursor
                    const cur = edit_buf.cursor;
                    var word_start: u16 = cur;
                    while (word_start > 0 and text[word_start - 1] != ' ' and text[word_start - 1] != '\n') : (word_start -= 1) {}
                    var prefix = text[word_start..cur];
                    // Strip @ prefix for file mention completion
                    const is_at_mention = prefix.len > 0 and prefix[0] == '@';
                    if (is_at_mention) prefix = prefix[1..];
                    if (prefix.len > 0) {
                        // Split into dir and file prefix
                        const last_slash = std.mem.lastIndexOfScalar(u8, prefix, '/');
                        const dir_path = if (last_slash) |s| prefix[0 .. s + 1] else "";
                        const file_prefix = if (last_slash) |s| prefix[s + 1 ..] else prefix;

                        const dir_to_open = if (dir_path.len > 0) dir_path else ".";
                        var dir = std.fs.cwd().openDir(dir_to_open, .{ .iterate = true }) catch {
                            continue;
                        };
                        defer dir.close();

                        // Collect up to 32 matches
                        var name_storage: [32][256]u8 = undefined;
                        var name_lens: [32]u16 = undefined;
                        var match_count: u16 = 0;
                        var iter = dir.iterate();
                        while (iter.next() catch null) |entry| {
                            if (std.mem.startsWith(u8, entry.name, file_prefix)) {
                                if (match_count < 32) {
                                    const elen: u16 = @intCast(@min(entry.name.len, 256));
                                    @memcpy(name_storage[match_count][0..elen], entry.name[0..elen]);
                                    name_lens[match_count] = elen;
                                    match_count += 1;
                                }
                            }
                        }
                        if (match_count == 1) {
                            const suffix_start = file_prefix.len;
                            const suffix = name_storage[0][suffix_start..name_lens[0]];
                            _ = edit_buf.insertSlice(suffix);
                        } else if (match_count > 1) {
                            // Find common prefix among matches
                            var common_len: u16 = name_lens[0];
                            for (1..match_count) |i| {
                                common_len = @min(common_len, name_lens[i]);
                                var j: u16 = 0;
                                while (j < common_len and name_storage[0][j] == name_storage[i][j]) : (j += 1) {}
                                common_len = j;
                            }
                            if (common_len > file_prefix.len) {
                                const suffix = name_storage[0][file_prefix.len..common_len];
                                _ = edit_buf.insertSlice(suffix);
                            } else {
                                // Show matches in scroll region
                                try out.print("\x1b[{d};1H\x1b[90m", .{out_last});
                                for (0..match_count) |i| {
                                    try out.writeAll(name_storage[i][0..name_lens[i]]);
                                    try out.writeByte(' ');
                                }
                                try out.writeAll("\x1b[0m\n");
                            }
                        }
                    }
                }
                Layout.drawInputSafeFull(out, input_first_row, input_height, &edit_buf, agent_active, out_last, term_rows);
                if (!agent_active) cursor_at = .input;
                try out.flush();
                continue;
            }

            // Enter (0x0D CR) — submit query
            if (byte[0] == '\r') {
                // Copy query to stack buffer before clearing edit_buf
                // (query is a slice into edit_buf.text which clear() invalidates)
                var query_buf: [editor.LINE_BUF_SIZE]u8 = undefined;
                const raw_query = std.mem.trim(u8, edit_buf.slice(), " \t\n\r");
                const qlen = @min(raw_query.len, query_buf.len);
                @memcpy(query_buf[0..qlen], raw_query[0..qlen]);
                const query = query_buf[0..qlen];

                // Save to input history
                if (qlen > 0) {
                    const hlen: u16 = @intCast(qlen);
                    @memcpy(input_history[input_history_write][0..qlen], query_buf[0..qlen]);
                    input_history_lens[input_history_write] = hlen;
                    input_history_write = (input_history_write + 1) % HIST_SIZE;
                    if (input_history_count < HIST_SIZE) input_history_count += 1;
                }
                input_history_browsing = false;
                input_history_pos = 0;

                edit_buf.clear();
                edit_buf.vi_mode = .insert;

                // Reset input height
                if (input_height != 1) {
                    input_height = 1;
                    recalcLayout.f(out, term_rows, term_cols, input_height, &out_last, &sep_row, &input_first_row, &status_row, &edit_buf, model_name, cost_buf[0..cost_len], scroll_offset, status_text[0..status_len]);
                }

                if (query.len == 0) {
                    Layout.drawInputSafeFull(out, input_first_row, input_height, &edit_buf, false, out_last, term_rows);
                    cursor_at = .input;
                    try out.flush();
                    continue;
                }

                // Scroll to bottom if scrolled up
                if (scroll_offset > 0) {
                    scroll_offset = 0;
                    Layout.drawSeparator(out, sep_row, term_cols, 0);
                }

                // Echo user message in output scroll region
                Layout.goOutput(out, out_last);
                cursor_at = .output;
                try out.writeByte('\n'); // blank line before user message
                msg_history.commitLine();
                {
                    var first = true;
                    var rest: []const u8 = query;
                    while (rest.len > 0) {
                        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
                        const line = rest[0..nl];
                        if (first) {
                            try out.writeAll("\x1b[1m> \x1b[0m");
                            msg_history.appendSlice("\x1b[1m> \x1b[0m");
                            first = false;
                        } else {
                            try out.writeAll("  ");
                            msg_history.appendSlice("  ");
                        }
                        try out.writeAll(line);
                        try out.writeByte('\n');
                        msg_history.appendSlice(line);
                        msg_history.commitLine();
                        rest = if (nl < rest.len) rest[nl + 1 ..] else &.{};
                    }
                    if (first) {
                        try out.writeAll("\x1b[1m> \x1b[0m\n");
                        msg_history.appendSlice("\x1b[1m> \x1b[0m");
                        msg_history.commitLine();
                    }
                }

                Layout.drawInputSafeFull(out, input_first_row, input_height, &edit_buf, true, out_last, term_rows);
                try out.flush();

                // Dispatch slash commands via table-driven handler
                {
                    var cmd_ctx = agent_commands.CommandCtx{
                        .shell = shell,
                        .out = out,
                        .model_name = model_name,
                        .model_buf = &model_buf,
                        .cost_buf = &cost_buf,
                        .cost_len = &cost_len,
                        .status_text = &status_text,
                        .status_len = &status_len,
                        .msg_history = &msg_history,
                        .edit_buf = &edit_buf,
                        .agent_active = &agent_active,
                        .query_start_ms = &query_start_ms,
                        .scroll_offset = &scroll_offset,
                        .out_last = &out_last,
                        .sep_row = &sep_row,
                        .input_first_row = &input_first_row,
                        .status_row = &status_row,
                        .term_rows = &term_rows,
                        .term_cols = &term_cols,
                        .input_height = &input_height,
                        .md = &md,
                        .last_was_text = &last_was_text,
                        .last_query_buf = &last_query_buf,
                        .last_query_len = &last_query_len,
                        .last_routed_tier = &last_routed_tier,
                        .last_routed_tier_len = &last_routed_tier_len,
                    };
                    const result = agent_commands.dispatch(&cmd_ctx, query);
                    // Sync back model_name (may have changed via /model)
                    model_name = cmd_ctx.model_name;
                    switch (result) {
                        .handled => {
                            cursor_at = .output;
                            continue;
                        },
                        .exit => return 0,
                        .shell_escape => return 2,
                        .translate => {
                            translate_mode = true;
                            translate_len = 0;
                            cursor_at = .output;
                            continue;
                        },
                        .enter_tree => {
                            // Enter modal tree view — takes over the screen
                            const cmds = @import("agent_commands.zig");
                            cmds.runTreeView(shell, out, term_rows, term_cols);
                            // Restore scroll region and redraw layout
                            recalcLayout.f(out, term_rows, term_cols, input_height, &out_last, &sep_row, &input_first_row, &status_row, &edit_buf, model_name, cost_buf[0..cost_len], scroll_offset, status_text[0..status_len]);
                            cursor_at = .output;
                            continue;
                        },
                        .not_found => {
                            // Track last query for router correction feedback
                            const qcopy_len = @min(query.len, last_query_buf.len);
                            @memcpy(last_query_buf[0..qcopy_len], query[0..qcopy_len]);
                            last_query_len = qcopy_len;
                            last_routed_tier_len = 0; // reset until router_info arrives

                            // Expand @file mentions: read file and append contents
                            var expanded_buf: [4096]u8 = undefined;
                            var at_file_count: u8 = 0;
                            const expanded_query: []const u8 = if (std.mem.indexOfScalar(u8, query, '@') != null) blk: {
                                const result_q = expandAtMentions(query, &expanded_buf, shell.allocator) orelse query;
                                // Count <file> tags to show attachment indicator
                                var fi: usize = 0;
                                while (fi < result_q.len) : (fi += 1) {
                                    if (fi + 6 < result_q.len and std.mem.eql(u8, result_q[fi..][0..6], "<file ")) at_file_count += 1;
                                }
                                break :blk result_q;
                            } else query;
                            if (at_file_count > 0) {
                                var fbuf: [32]u8 = undefined;
                                const fmsg = std.fmt.bufPrint(&fbuf, "\x1b[90m  {d} file{s} attached\x1b[0m\n", .{ at_file_count, if (at_file_count == 1) @as([]const u8, "") else "s" }) catch "";
                                try out.writeAll(fmsg);
                                msg_history.appendSlice(fmsg);
                                msg_history.commitLine();
                            }

                            // Detect thinking keywords and set budget
                            // "think" → 4K tokens, "megathink" → 10K, "ultrathink" → 32K
                            if (std.mem.indexOf(u8, expanded_query, "ultrathink") != null) {
                                shell.agent.queues.shared_thinking_budget.store(32000, .monotonic);
                            } else if (std.mem.indexOf(u8, expanded_query, "megathink") != null) {
                                shell.agent.queues.shared_thinking_budget.store(10000, .monotonic);
                            } else if (std.mem.indexOf(u8, expanded_query, " think") != null or
                                std.mem.startsWith(u8, expanded_query, "think"))
                            {
                                shell.agent.queues.shared_thinking_budget.store(4000, .monotonic);
                            } else {
                                shell.agent.queues.shared_thinking_budget.store(0, .monotonic);
                            }

                            // Send to agent — always queues, never blocks
                            if (!shell.agent.query(expanded_query)) {
                                try out.writeAll("\x1b[31mqueue full, try again\x1b[0m\n");
                                msg_history.appendSlice("\x1b[31mqueue full, try again\x1b[0m");
                                msg_history.commitLine();
                                cursor_at = .output;
                            } else {
                                agent_active = true;
                                cursor_at = .output;
                                query_start_ms = std.time.milliTimestamp();
                                const tb = shell.agent.queues.shared_thinking_budget.load(.monotonic);
                                const thinking_s = if (tb >= 32000) "ultrathinking..." else if (tb >= 10000) "megathinking..." else if (tb > 0) "thinking deeply..." else "thinking...";
                                @memcpy(status_text[0..thinking_s.len], thinking_s);
                                status_len = thinking_s.len;
                                Layout.drawStatusBarSafeCtx(out, status_row, term_rows, out_last, term_cols, model_name, cost_buf[0..cost_len], status_text[0..status_len], if (query_start_ms > 0) std.time.milliTimestamp() - query_start_ms else 0, ctx_tokens, ctx_max);
                            }
                            try out.flush();
                            continue;
                        },
                    }
                }
            }

            // Backspace (in normal mode, just move left)
            if (byte[0] == 127 or byte[0] == 8) {
                if (edit_buf.vi_mode == .normal) {
                    if (edit_buf.moveLeft()) {
                        Layout.drawInputSafeFull(out, input_first_row, input_height, &edit_buf, agent_active, out_last, term_rows);
                        if (!agent_active) cursor_at = .input;
                        try out.flush();
                    }
                    continue;
                }
                if (edit_buf.delete()) {
                    const new_h: u16 = @min(edit_buf.lineCount(), 5);
                    if (new_h != input_height) {
                        input_height = new_h;
                        recalcLayout.f(out, term_rows, term_cols, input_height, &out_last, &sep_row, &input_first_row, &status_row, &edit_buf, model_name, cost_buf[0..cost_len], scroll_offset, status_text[0..status_len]);
                    }
                    Layout.drawInputSafeFull(out, input_first_row, input_height, &edit_buf, agent_active, out_last, term_rows);
                    if (!agent_active) cursor_at = .input;
                    try out.flush();
                }
                continue;
            }

            // Configurable Ctrl key bindings (from ~/.zish/keybindings.json)
            // Skip keys handled above: 0x01(^A) 0x02(^B) 0x03(^C) 0x04(^D) 0x05(^E)
            // 0x06(^F) 0x07(^G) 0x0B(^K) 0x0C(^L) 0x0E(^N) 0x0F(^O) 0x15(^U) 0x17(^W)
            if (byte[0] >= 0x01 and byte[0] <= 0x1A and
                byte[0] != 0x03 and byte[0] != 0x04 and byte[0] != 0x07 and
                byte[0] != 0x0B and byte[0] != 0x0E and
                byte[0] != 0x08 and byte[0] != 0x09 and byte[0] != 0x0A and byte[0] != 0x0D)
            {
                if (shell.keybindings.lookupCtrl(byte[0])) |action| {
                    // Map Action back to BindableAction for TUI application
                    const ba = actionToBindable(action);
                    const result = applyTuiBindableAction(ba, &edit_buf, shell);
                    if (result != .none) {
                        if (result == .modified) {
                            const new_h: u16 = @min(edit_buf.lineCount(), 5);
                            if (new_h != input_height) {
                                input_height = new_h;
                                recalcLayout.f(out, term_rows, term_cols, input_height, &out_last, &sep_row, &input_first_row, &status_row, &edit_buf, model_name, cost_buf[0..cost_len], scroll_offset, status_text[0..status_len]);
                            }
                        }
                        Layout.drawInputSafeFull(out, input_first_row, input_height, &edit_buf, agent_active, out_last, term_rows);
                        if (!agent_active) cursor_at = .input;
                        try out.flush();
                    }
                    continue;
                }
                continue; // unknown ctrl key, ignore
            }

            // Regular character — always typeable, even during streaming
            if (byte[0] >= 0x20 or byte[0] == '\t') {
                // Handle UTF-8 multi-byte: read continuation bytes immediately
                if (byte[0] >= 0xC0) {
                    const expect: u8 = if (byte[0] >= 0xF0) 3 else if (byte[0] >= 0xE0) 2 else 1;
                    _ = edit_buf.insert(byte[0]);
                    var ci: u8 = 0;
                    while (ci < expect) : (ci += 1) {
                        var cb: [1]u8 = undefined;
                        const cn = std.fs.File.stdin().read(&cb) catch break;
                        if (cn == 0 or (cb[0] & 0xC0) != 0x80) break;
                        _ = edit_buf.insert(cb[0]);
                    }
                    Layout.drawInputSafeFull(out, input_first_row, input_height, &edit_buf, agent_active, out_last, term_rows);
                    if (!agent_active) cursor_at = .input;
                    try out.flush();
                    continue;
                }
                if (edit_buf.insert(byte[0])) {
                    Layout.drawInputSafeFull(out, input_first_row, input_height, &edit_buf, agent_active, out_last, term_rows);
                    if (!agent_active) cursor_at = .input;
                    try out.flush();
                }
            }
        }
    }
    return 0;
}

fn agentLog(shell: *Shell, args: []const []const u8) !u8 {
    const out = shell.stdout();

    // Determine session ID: arg or latest
    var session_id: []const u8 = "";
    if (args.len >= 3) {
        session_id = args[2];
    } else {
        // Find most recent session
        var sessions: std.ArrayList(agent_log.SessionInfo) = .{};
        defer sessions.deinit(shell.allocator);
        agent_log.listSessions(shell.allocator, &sessions) catch {};
        if (sessions.items.len == 0) {
            try out.writeAll("No sessions found.\n");
            try out.flush();
            return 1;
        }
        const last = &sessions.items[sessions.items.len - 1];
        session_id = &last.id;
    }

    // Read conversation.jsonl for this session
    var base_buf: [512]u8 = undefined;
    const base = agent_log.getBaseDir(&base_buf) orelse {
        try out.writeAll("Cannot find ~/.zish directory.\n");
        try out.flush();
        return 1;
    };

    var path_buf: [512]u8 = undefined;
    const conv_path = std.fmt.bufPrint(&path_buf, "{s}/sessions/{s}/conversation.jsonl", .{ base, session_id }) catch {
        try out.writeAll("Path too long.\n");
        try out.flush();
        return 1;
    };

    const content = std.fs.cwd().readFileAlloc(shell.allocator, conv_path, 512 * 1024) catch {
        try out.print("Session not found: {s}\n", .{session_id});
        try out.flush();
        return 1;
    };
    defer shell.allocator.free(content);

    // Also read meta.json for context
    var meta_path_buf: [512]u8 = undefined;
    const meta_path = std.fmt.bufPrint(&meta_path_buf, "{s}/sessions/{s}/meta.json", .{ base, session_id }) catch "";
    if (std.fs.cwd().readFileAlloc(shell.allocator, meta_path, 4096)) |meta| {
        defer shell.allocator.free(meta);
        try out.print("\x1b[90m{s}", .{session_id});
        if (agent_log.jsonExtractStr(meta, "model")) |model| {
            try out.print(" \xc2\xb7 {s}", .{model});
        }
        if (agent_log.jsonExtractStr(meta, "cwd")) |cwd| {
            const home = std.posix.getenv("HOME") orelse "";
            if (home.len > 0 and std.mem.startsWith(u8, cwd, home)) {
                try out.print(" \xc2\xb7 ~{s}", .{cwd[home.len..]});
            } else {
                try out.print(" \xc2\xb7 {s}", .{cwd});
            }
        }
        try out.writeAll("\x1b[0m\n\n");
    } else |_| {}

    // Parse and display JSONL entries
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    var md: agent_mod.MarkdownRenderer = .{};

    while (line_iter.next()) |line| {
        renderLogLine(out, &md, line) catch {};
    }

    try out.flush();
    return 0;
}

fn agentLatestSession(shell: *Shell) ?[]const u8 {
    var sessions: std.ArrayList(agent_log.SessionInfo) = .{};
    defer sessions.deinit(shell.allocator);
    agent_log.listSessions(shell.allocator, &sessions) catch return null;
    if (sessions.items.len == 0) return null;
    return &sessions.items[sessions.items.len - 1].id;
}

/// Attach to a running agent session — like screen/tmux.
/// Replays conversation log, then follows live output and sends input via FIFO.
fn agentAttach(shell: *Shell, args: []const []const u8) !u8 {
    const out = shell.stdout();

    // Determine session ID
    var session_id: []const u8 = "";
    if (args.len >= 3) {
        session_id = args[2];
    } else {
        // Find latest active session (has ctl FIFO)
        var sessions: std.ArrayList(agent_log.SessionInfo) = .{};
        defer sessions.deinit(shell.allocator);
        agent_log.listSessions(shell.allocator, &sessions) catch {};
        // Search from newest to oldest for an active session
        var found = false;
        var si: usize = sessions.items.len;
        while (si > 0) {
            si -= 1;
            const info = &sessions.items[si];
            // Check if ctl FIFO exists
            var base_buf: [512]u8 = undefined;
            const base = agent_log.getBaseDir(&base_buf) orelse break;
            var ctl_check: [512]u8 = undefined;
            const ctl_p = std.fmt.bufPrint(&ctl_check, "{s}/sessions/{s}/ctl", .{ base, @as([]const u8, &info.id) }) catch continue;
            std.fs.cwd().access(ctl_p, .{}) catch continue;
            session_id = &info.id;
            found = true;
            break;
        }
        if (!found) {
            try out.writeAll("No active sessions to attach to.\nUse 'agent attach <session-id>' for a specific session.\n");
            try out.flush();
            return 1;
        }
    }

    // Resolve paths
    var base_buf: [512]u8 = undefined;
    const base = agent_log.getBaseDir(&base_buf) orelse {
        try out.writeAll("Cannot find ~/.zish directory.\n");
        try out.flush();
        return 1;
    };

    var conv_path_buf: [512]u8 = undefined;
    const conv_path = std.fmt.bufPrint(&conv_path_buf, "{s}/sessions/{s}/conversation.jsonl", .{ base, session_id }) catch {
        try out.writeAll("Path too long.\n");
        try out.flush();
        return 1;
    };

    var ctl_path_buf: [512]u8 = undefined;
    const ctl_path = std.fmt.bufPrint(&ctl_path_buf, "{s}/sessions/{s}/ctl", .{ base, session_id }) catch {
        try out.writeAll("Path too long.\n");
        try out.flush();
        return 1;
    };

    // Check if ctl FIFO exists (session is alive)
    const has_ctl = blk: {
        std.fs.cwd().access(ctl_path, .{}) catch break :blk false;
        break :blk true;
    };

    // Open conversation.jsonl for reading
    const conv_file = std.fs.cwd().openFile(conv_path, .{}) catch {
        try out.print("Session not found: {s}\n", .{session_id});
        try out.flush();
        return 1;
    };
    defer conv_file.close();

    // Read meta.json for header
    var meta_path_buf: [512]u8 = undefined;
    const meta_path = std.fmt.bufPrint(&meta_path_buf, "{s}/sessions/{s}/meta.json", .{ base, session_id }) catch "";
    const meta_model = if (std.fs.cwd().readFileAlloc(shell.allocator, meta_path, 4096)) |meta| blk: {
        defer shell.allocator.free(meta);
        break :blk agent_log.jsonExtractStr(meta, "model");
    } else |_| null;
    _ = meta_model;

    // Get terminal dimensions
    const term_rows = getTermRows();
    const term_cols = getTermCols();
    const output_bottom = term_rows - 2;

    // Setup TUI (same as interactive mode)
    try out.print("\x1b[1;{d}r", .{output_bottom});
    try out.print("\x1b[{d};1H", .{output_bottom});

    // Separator
    try out.print("\x1b[{d};1H\x1b[90m", .{output_bottom + 1});
    {
        var ci: u16 = 0;
        while (ci < term_cols) : (ci += 1) try out.writeByte('-');
    }
    try out.writeAll("\x1b[0m");

    // Input bar
    try out.print("\x1b[{d};1H\x1b[2K\x1b[1;35m>>\x1b[0m ", .{term_rows});

    // Header
    try out.print("\x1b[{d};1H", .{output_bottom});
    if (has_ctl) {
        try out.print("\x1b[1;35m-- attached \x1b[0m\x1b[90m{s} (live)\x1b[0m\n", .{session_id});
    } else {
        try out.print("\x1b[1;35m-- replay \x1b[0m\x1b[90m{s} (ended)\x1b[0m\n", .{session_id});
    }
    try out.flush();

    // Replay existing content
    const initial = std.fs.cwd().readFileAlloc(shell.allocator, conv_path, 1024 * 1024) catch "";
    defer if (initial.len > 0) shell.allocator.free(initial);

    var md: agent_mod.MarkdownRenderer = .{};
    var line_iter = std.mem.splitScalar(u8, initial, '\n');
    while (line_iter.next()) |line| {
        renderLogLine(out, &md, line) catch {};
    }
    try out.flush();

    // Track file position for follow mode
    var file_pos: u64 = if (initial.len > 0) @intCast(initial.len) else 0;

    // Open ctl FIFO for writing (if alive)
    const ctl_fd: ?std.posix.fd_t = if (has_ctl) blk: {
        break :blk std.posix.open(ctl_path, .{ .ACCMODE = .WRONLY, .NONBLOCK = true }, 0) catch null;
    } else null;
    defer if (ctl_fd) |fd| std.posix.close(fd);

    // State
    var line_buf: [4096]u8 = undefined;
    var line_len: usize = 0;

    const InputBar = struct {
        fn draw(w: anytype, rows: u16, buf: []const u8, len: usize) void {
            w.print("\x1b[{d};1H\x1b[2K\x1b[1;35m>>\x1b[0m ", .{rows}) catch {};
            if (len > 0) w.writeAll(buf[0..len]) catch {};
        }
    };

    const exitRestore = struct {
        fn f(w: anytype, rows: u16) void {
            w.print("\x1b[1;{d}r", .{rows}) catch {};
            w.print("\x1b[{d};1H", .{rows}) catch {};
            w.writeAll("\x1b[2K\x1b[90mdetached\x1b[0m\n") catch {};
            w.flush() catch {};
        }
    };

    // Follow mode event loop
    while (true) {
        // Poll stdin
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = std.posix.STDIN_FILENO,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const poll_timeout: i32 = 200; // check file every 200ms
        const poll_n = std.posix.poll(&poll_fds, poll_timeout) catch 0;

        // Check for new data in conversation.jsonl
        const file_size = blk: {
            const stat = conv_file.stat() catch break :blk file_pos;
            break :blk stat.size;
        };

        if (file_size > file_pos) {
            // Read new data
            conv_file.seekTo(file_pos) catch {};
            const new_len = file_size - file_pos;
            const max_read: usize = @min(@as(usize, @intCast(new_len)), 65536);
            var read_buf = shell.allocator.alloc(u8, max_read) catch continue;
            defer shell.allocator.free(read_buf);
            const n = conv_file.read(read_buf) catch 0;
            if (n > 0) {
                file_pos += n;
                // Position cursor in output area
                try out.print("\x1b[{d};1H", .{output_bottom});
                // Render each new line
                var new_iter = std.mem.splitScalar(u8, read_buf[0..n], '\n');
                while (new_iter.next()) |line| {
                    renderLogLine(out, &md, line) catch {};
                }
                // Refresh input bar
                InputBar.draw(out, term_rows, &line_buf, line_len);
                try out.flush();
            }
        }

        // Handle stdin
        if (poll_n > 0 and (poll_fds[0].revents & std.posix.POLL.IN) != 0) {
            var byte: [1]u8 = undefined;
            const n = std.fs.File.stdin().read(&byte) catch break;
            if (n == 0) {
                exitRestore.f(out, term_rows);
                return 0;
            }

            // Ctrl+C / Ctrl+D — detach
            if (byte[0] == 3 or byte[0] == 4) {
                if (line_len == 0) {
                    exitRestore.f(out, term_rows);
                    return 0;
                }
                line_len = 0;
                InputBar.draw(out, term_rows, &line_buf, 0);
                try out.flush();
                continue;
            }

            // Escape sequences — discard
            if (byte[0] == 27) {
                var esc_buf: [8]u8 = undefined;
                var esc_poll = [_]std.posix.pollfd{.{
                    .fd = std.posix.STDIN_FILENO,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                if ((std.posix.poll(&esc_poll, 10) catch 0) > 0) {
                    _ = std.fs.File.stdin().read(&esc_buf) catch {};
                }
                continue;
            }

            // Enter — send to FIFO
            if (byte[0] == '\n' or byte[0] == '\r') {
                if (line_len == 0) continue;
                const input = line_buf[0..line_len];
                line_len = 0;

                if (std.mem.eql(u8, std.mem.trim(u8, input, " \t"), "exit") or
                    std.mem.eql(u8, std.mem.trim(u8, input, " \t"), "quit"))
                {
                    exitRestore.f(out, term_rows);
                    return 0;
                }

                if (ctl_fd) |fd| {
                    // Write to FIFO with newline
                    _ = std.posix.write(fd, input) catch {};
                    _ = std.posix.write(fd, "\n") catch {};
                    // Echo in output area
                    try out.print("\x1b[{d};1H", .{output_bottom});
                    try out.writeAll("\n\x1b[1;35m> \x1b[0m");
                    try out.writeAll(input);
                    try out.writeByte('\n');
                } else {
                    try out.print("\x1b[{d};1H", .{output_bottom});
                    try out.writeAll("\n\x1b[31msession ended — read-only\x1b[0m\n");
                }
                InputBar.draw(out, term_rows, &line_buf, 0);
                try out.flush();
                continue;
            }

            // Backspace
            if (byte[0] == 127 or byte[0] == 8) {
                if (line_len > 0) {
                    line_len -= 1;
                    InputBar.draw(out, term_rows, &line_buf, line_len);
                    try out.flush();
                }
                continue;
            }

            // Regular char
            if (byte[0] >= 0x20 or byte[0] == '\t') {
                if (line_len < line_buf.len - 1) {
                    line_buf[line_len] = byte[0];
                    line_len += 1;
                    InputBar.draw(out, term_rows, &line_buf, line_len);
                    try out.flush();
                }
            }
        }
    }
    return 0;
}

/// Render a single JSONL log line with formatting
fn renderLogLine(out: anytype, md: *agent_mod.MarkdownRenderer, line: []const u8) !void {
    if (line.len < 5) return;
    const entry_type = agent_log.jsonExtractStr(line, "t") orelse return;

    if (std.mem.eql(u8, entry_type, "u")) {
        if (agent_log.jsonExtractStr(line, "content")) |content| {
            try out.writeAll("\n\x1b[1m> ");
            try out.writeAll(content);
            try out.writeAll("\x1b[0m\n\n");
            md.reset();
        }
    } else if (std.mem.eql(u8, entry_type, "a")) {
        if (agent_log.jsonExtractStr(line, "content")) |content| {
            var unescape_buf: [8192]u8 = undefined;
            const unescaped = agent_mod.unescapeJSONPublic(content, &unescape_buf) orelse content;
            try md.render(out, unescaped);
            try out.writeAll("\x1b[0m\n");
            md.reset();
        }
    } else if (std.mem.eql(u8, entry_type, "tc")) {
        if (agent_log.jsonExtractStr(line, "tool")) |tool| {
            try out.writeAll("\x1b[90m\xe2\x9a\xa1 ");
            try out.writeAll(tool);
            try out.writeAll("\x1b[0m\n");
        }
    } else if (std.mem.eql(u8, entry_type, "e")) {
        if (agent_log.jsonExtractStr(line, "content")) |content| {
            try out.writeAll("\x1b[31m");
            try out.writeAll(content);
            try out.writeAll("\x1b[0m\n");
        }
    } else if (std.mem.eql(u8, entry_type, "as")) {
        const desc = agent_log.jsonExtractStr(line, "desc") orelse "task";
        const aid = agent_log.jsonExtractStr(line, "agent_id") orelse "?";
        try out.print("\x1b[90m\xe2\x9a\xa1 subagent {s}: {s}\x1b[0m\n", .{ aid, desc });
    } else if (std.mem.eql(u8, entry_type, "ar")) {
        const aid = agent_log.jsonExtractStr(line, "agent_id") orelse "?";
        try out.print("\x1b[90m  \xe2\x9c\x93 {s} done\x1b[0m\n", .{aid});
    } else if (std.mem.eql(u8, entry_type, "d")) {
        // skip dividers in log view
    }
}

// ── @file mention expansion ──

/// Expand @path mentions in query text. Reads each mentioned file and appends
/// its contents to the query. Returns null if no expansion needed or on error.
/// Pattern: "@path/to/file" at word boundary (preceded by space or start of string).
fn expandAtMentions(query: []const u8, buf: *[4096]u8, alloc: std.mem.Allocator) ?[]const u8 {
    var result: std.ArrayList(u8) = .{};
    defer result.deinit(alloc);
    result.appendSlice(alloc, query) catch return null;

    var files_found = false;
    var i: usize = 0;
    while (i < query.len) : (i += 1) {
        if (query[i] != '@') continue;
        // Must be at start or after whitespace
        if (i > 0 and query[i - 1] != ' ' and query[i - 1] != '\n' and query[i - 1] != '\t') continue;
        // Extract path after @
        const path_start = i + 1;
        if (path_start >= query.len) continue;
        var path_end = path_start;
        while (path_end < query.len and query[path_end] != ' ' and query[path_end] != '\n' and query[path_end] != '\t') : (path_end += 1) {}
        const path = query[path_start..path_end];
        if (path.len == 0) continue;
        // Try to read the file
        const file = std.fs.cwd().openFile(path, .{}) catch continue;
        defer file.close();
        var read_buf: [3072]u8 = undefined;
        const n = file.readAll(&read_buf) catch continue;
        if (n == 0) continue;
        // Append file contents to query
        files_found = true;
        result.appendSlice(alloc, "\n\n<file path=\"") catch continue;
        result.appendSlice(alloc, path) catch continue;
        result.appendSlice(alloc, "\">\n") catch continue;
        result.appendSlice(alloc, read_buf[0..n]) catch continue;
        result.appendSlice(alloc, "\n</file>") catch continue;
    }

    if (!files_found) return null;
    // Copy to static buffer
    const total = @min(result.items.len, buf.len);
    @memcpy(buf[0..total], result.items[0..total]);
    return buf[0..total];
}

// ── Voice TTS: speak text via remote TTS endpoint ──

/// Send text to TTS endpoint, pipe audio to paplay.
/// Blocks until playback complete (or errors out).
fn voiceSpeak(alloc: std.mem.Allocator, text: []const u8) void {
    // Strip markdown/ANSI from text for cleaner TTS
    var clean_buf: [8192]u8 = undefined;
    var clean_len: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        // Skip ANSI escape sequences
        if (text[i] == '\x1b' and i + 1 < text.len and text[i + 1] == '[') {
            while (i < text.len and text[i] != 'm') : (i += 1) {}
            i += 1;
            continue;
        }
        // Skip markdown: **, *, ```, #
        if (text[i] == '*' or text[i] == '`' or (text[i] == '#' and (i == 0 or text[i - 1] == '\n'))) {
            i += 1;
            continue;
        }
        if (clean_len < clean_buf.len) {
            clean_buf[clean_len] = text[i];
            clean_len += 1;
        }
        i += 1;
    }
    if (clean_len == 0) return;

    // JSON-escape the text (escape " and \ and newlines)
    var escaped_buf: [16384]u8 = undefined;
    var esc_len: usize = 0;
    for (clean_buf[0..clean_len]) |c| {
        if (esc_len + 2 >= escaped_buf.len) break;
        switch (c) {
            '"' => { escaped_buf[esc_len] = '\\'; esc_len += 1; escaped_buf[esc_len] = '"'; esc_len += 1; },
            '\\' => { escaped_buf[esc_len] = '\\'; esc_len += 1; escaped_buf[esc_len] = '\\'; esc_len += 1; },
            '\n' => { escaped_buf[esc_len] = '\\'; esc_len += 1; escaped_buf[esc_len] = 'n'; esc_len += 1; },
            '\r' => { escaped_buf[esc_len] = '\\'; esc_len += 1; escaped_buf[esc_len] = 'r'; esc_len += 1; },
            else => { escaped_buf[esc_len] = c; esc_len += 1; },
        }
    }

    // Build JSON request body
    var json_buf: [16384]u8 = undefined;
    const json = std.fmt.bufPrint(&json_buf,
        \\{{"text":"{s}","speaker":"ryan","language":"english"}}
    , .{escaped_buf[0..esc_len]}) catch return;

    // curl to TTS endpoint → raw WAV → pipe to paplay
    // Two-step: curl gets WAV, then paplay plays it
    var child = std.process.Child.init(
        &.{
            "sh", "-c",
            "curl -sS --max-time 60 -X POST -H 'Content-Type: application/json' " ++
                "-d @- http://localhost:8888/synthesize -o /tmp/zish_tts.wav < /dev/stdin && " ++
                "paplay --format=s16le --rate=24000 --channels=1 --raw /tmp/zish_tts.wav",
        },
        alloc,
    );
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return;
    if (child.stdin) |stdin| {
        stdin.writeAll(json) catch {};
        stdin.close();
        child.stdin = null;
    }
    _ = child.wait() catch {};
}

// ── Voice transcription via ASR endpoint ──

// ── Whisper ASR: local model loaded once, stays warm ──

const whisper_mod = @import("inference/whisper.zig");

/// Lazy-loaded whisper model (loaded on first /voice, stays in memory).
var whisper_model: ?whisper_mod.WhisperModel = null;

fn getWhisperModel(alloc: std.mem.Allocator) ?*const whisper_mod.WhisperModel {
    if (whisper_model != null) return &whisper_model.?;
    whisper_model = whisper_mod.WhisperModel.load(
        "/home/alice/.zish/models/ggml-tiny.en.bin",
        alloc,
    ) catch return null;
    return &whisper_model.?;
}

/// Transcribe audio using local whisper model (pure Zig, no subprocess).
fn voiceTranscribe(alloc: std.mem.Allocator, samples: []const i16) ?[]u8 {
    const model = getWhisperModel(alloc) orelse return null;
    return model.transcribe(alloc, samples) catch return null;
}
