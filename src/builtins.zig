// builtins.zig - all shell builtin commands
const std = @import("std");
const Shell = @import("Shell.zig");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const input_mod = @import("input.zig");
const BindableAction = input_mod.BindableAction;
const editor = @import("editor.zig");
const linkify = @import("linkify.zig");
const compat = @import("compat.zig");

// directory stack for pushd/popd
var dir_stack: std.ArrayList([]const u8) = undefined;
var dir_stack_initialized: bool = false;

fn ensureDirStack(allocator: std.mem.Allocator) !void {
    if (!dir_stack_initialized) {
        dir_stack = .empty;
        try dir_stack.ensureTotalCapacity(allocator, 8);
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
        "echo", "printf", "read", "mapfile", "readarray",
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
        "feat",
        "chpw",
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
    if (std.mem.eql(u8, cmd_name, "mapfile") or std.mem.eql(u8, cmd_name, "readarray")) return try mapfile(shell, args);

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
    if (std.mem.eql(u8, cmd_name, "feat")) return null; // handled in eval.zig
    if (std.mem.eql(u8, cmd_name, "chpw")) return null; // handled in eval.zig for now (complex)

    return null; // not a builtin
}

// ============ directory builtins ============

fn cd(shell: *Shell, args: []const []const u8) !u8 {
    // save current directory to OLDPWD
    var cwd_buf: [4096]u8 = undefined;
    const cwd = compat.posix.getcwd(&cwd_buf) catch "";

    const path = if (args.len > 1) blk: {
        const arg = args[1];
        // handle cd -
        if (std.mem.eql(u8, arg, "-")) {
            const oldpwd = shell.variables.get("OLDPWD") orelse
                compat.posix.getenv("OLDPWD") orelse {
                try shell.stdout().writeAll("cd: OLDPWD not set\n");
                return 1;
            };
            try shell.stdout().print("{s}\n", .{oldpwd});
            break :blk oldpwd;
        }
        break :blk arg;
    } else blk: {
        break :blk compat.posix.getenv("HOME") orelse {
            try shell.stdout().writeAll("cd: HOME not set\n");
            return 1;
        };
    };

    compat.posix.chdir(path) catch {
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
    const cwd = compat.posix.getcwd(&cwd_buf) catch {
        try shell.stdout().writeAll("pwd: cannot get current directory\n");
        return 1;
    };
    try shell.stdout().print("{s}\n", .{cwd});
    return 0;
}

fn dotdot(shell: *Shell) !u8 {
    compat.posix.chdir("..") catch {
        try shell.stdout().writeAll("..: cannot go up\n");
        return 1;
    };
    return 0;
}

fn dotdotdot(shell: *Shell) !u8 {
    compat.posix.chdir("../..") catch {
        try shell.stdout().writeAll("...: cannot go up\n");
        return 1;
    };
    return 0;
}

fn dash(shell: *Shell) !u8 {
    const oldpwd = shell.variables.get("OLDPWD") orelse
        compat.posix.getenv("OLDPWD") orelse {
        try shell.stdout().writeAll("-: OLDPWD not set\n");
        return 1;
    };

    var cwd_buf: [4096]u8 = undefined;
    const cwd = compat.posix.getcwd(&cwd_buf) catch "";

    compat.posix.chdir(oldpwd) catch {
        try shell.stdout().print("-: {s}: no such directory\n", .{oldpwd});
        return 1;
    };

    try setVar(shell, "OLDPWD", cwd);
    try shell.stdout().print("{s}\n", .{oldpwd});
    return 0;
}

pub fn pushd(shell: *Shell, args: []const []const u8) !u8 {
    ensureDirStack(shell.allocator) catch return 1;

    var cwd_buf: [4096]u8 = undefined;
    const cwd = compat.posix.getcwd(&cwd_buf) catch {
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
        compat.posix.chdir(top) catch {
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
    compat.posix.chdir(path) catch {
        try shell.stdout().print("pushd: {s}: no such directory\n", .{path});
        return 1;
    };

    try dir_stack.append(shell.allocator, try shell.allocator.dupe(u8, cwd));
    try printDirStack(shell);
    return 0;
}

pub fn popd(shell: *Shell, args: []const []const u8) !u8 {
    _ = args;
    ensureDirStack(shell.allocator) catch return 1;

    if (dir_stack.items.len == 0) {
        try shell.stdout().writeAll("popd: directory stack empty\n");
        return 1;
    }

    const path = dir_stack.pop() orelse {
        try shell.stdout().writeAll("popd: directory stack empty\n");
        return 1;
    };
    defer shell.allocator.free(path);

    compat.posix.chdir(path) catch {
        try shell.stdout().print("popd: {s}: no such directory\n", .{path});
        return 1;
    };

    try printDirStack(shell);
    return 0;
}

pub fn dirs(shell: *Shell, args: []const []const u8) !u8 {
    _ = args;
    ensureDirStack(shell.allocator) catch return 1;
    try printDirStack(shell);
    return 0;
}

fn printDirStack(shell: *Shell) !void {
    var cwd_buf: [4096]u8 = undefined;
    const cwd = compat.posix.getcwd(&cwd_buf) catch "";
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

    // POSIX: the format is reused as often as necessary to consume all the
    // arguments (`printf '%s\n' a b c` prints three lines). Repeat until every
    // argument is consumed; break if a whole pass consumes no argument (the
    // format has no conversions) so a format like "hi\n" prints exactly once
    // instead of looping forever.
    while (true) {
        const pass_start = arg_idx;
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
        if (arg_idx >= args.len) break; // all arguments consumed
        if (arg_idx == pass_start) break; // format has no conversions — avoid infinite loop
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
            // string with backslash escapes interpreted (\t, \n, \xNN, \0nnn…)
            var k: usize = 0;
            while (k < arg.len) {
                if (arg[k] == '\\' and k + 1 < arg.len) {
                    const esc = printfParseEscape(arg[k + 1 ..]);
                    if (esc.len > 0) {
                        try writer.writeByte(esc.char);
                        k += 1 + esc.len;
                        continue;
                    }
                }
                try writer.writeByte(arg[k]);
                k += 1;
            }
            return;
        },
        'q' => {
            // quote the argument so it can be reused as shell input.
            if (arg.len == 0) {
                try writer.writeAll("''");
                return;
            }
            for (arg) |c| {
                const needs_escape = switch (c) {
                    ' ', '\t', '\n', '|', '&', ';', '<', '>', '(', ')', '$', '`',
                    '"', '\'', '\\', '*', '?', '[', ']', '{', '}', '~', '#', '!' => true,
                    else => false,
                };
                if (needs_escape) try writer.writeByte('\\');
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

    const stdin_fd = compat.posix.STDIN_FILENO;

    // save terminal state for silent mode
    var orig_termios: ?compat.posix.termios = null;
    if (silent and compat.posix.isatty(stdin_fd)) {
        orig_termios = compat.posix.tcgetattr(stdin_fd) catch null;
        if (orig_termios) |ot| {
            var new_termios = ot;
            new_termios.lflag.ECHO = false;
            compat.posix.tcsetattr(stdin_fd, .NOW, new_termios) catch {};
        }
    }
    defer {
        if (orig_termios) |ot| {
            compat.posix.tcsetattr(stdin_fd, .NOW, ot) catch {};
            // print newline since echo was off
            _ = compat.posix.write(compat.posix.STDOUT_FILENO, "\n") catch {};
        }
    }

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    // clamp so buf[pos] writes can never run past the buffer
    const max_chars = @min(nchars orelse (buf.len - 1), buf.len - 1);

    // set up timeout using poll
    const timeout_ms: i32 = if (timeout_secs) |t| @intCast(t * 1000) else -1;

    // track EOF so we can report failure (like bash: read returns non-zero at
    // end of input). without this, `while read x` never terminates on a pipe.
    var hit_eof = false;

    while (pos < max_chars) {
        // use poll for timeout support
        var fds = [_]compat.posix.pollfd{.{
            .fd = stdin_fd,
            .events = compat.posix.POLL.IN,
            .revents = 0,
        }};

        const poll_result = compat.posix.poll(&fds, timeout_ms) catch return 1;
        if (poll_result == 0) {
            // timeout
            return 1;
        }

        var c: [1]u8 = undefined;
        const n = compat.posix.read(stdin_fd, &c) catch return 1;
        if (n == 0) {
            hit_eof = true;
            break; // EOF
        }

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
            const n2 = compat.posix.read(stdin_fd, &c) catch break;
            if (n2 == 0) {
                hit_eof = true;
                break;
            }
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
    if (varnames_start >= args.len) {
        // no variable specified, use REPLY
        try setVar(shell, "REPLY", value);
    } else {
        const varnames = args[varnames_start..];
        if (varnames.len == 1) {
            // single variable gets the whole line with leading/trailing IFS
            // whitespace stripped (bash behaviour)
            try setVar(shell, varnames[0], stripIfs(value));
        } else {
            // multiple variables: split on IFS whitespace; the last variable
            // gets all remaining fields (with internal separators preserved),
            // matching bash/POSIX `read a b c` behaviour.
            var rest = value;
            for (varnames, 0..) |name, vi| {
                const is_last = vi == varnames.len - 1;
                if (is_last) {
                    try setVar(shell, name, stripIfs(rest));
                    break;
                }
                // skip leading IFS whitespace
                var start: usize = 0;
                while (start < rest.len and isIfsWhitespace(rest[start])) start += 1;
                // find end of field
                var end = start;
                while (end < rest.len and !isIfsWhitespace(rest[end])) end += 1;
                try setVar(shell, name, rest[start..end]);
                rest = rest[end..];
            }
        }
    }

    // bash/POSIX: read fails (non-zero) when EOF is reached and no data was read.
    return if (hit_eof and pos == 0) 1 else 0;
}

// mapfile / readarray — read lines of stdin into an array variable.
// Supports: -t (strip trailing newline), -n count, -s skip, -O origin,
// -d delim (line delimiter). Default array name is MAPFILE.
fn mapfile(shell: *Shell, args: []const []const u8) !u8 {
    var strip = false; // -t
    var max_count: usize = 0; // -n (0 = all)
    var skip: usize = 0; // -s
    var origin: ?usize = null; // -O (null = clear + start at 0)
    var delim: u8 = '\n'; // -d
    var name: []const u8 = "MAPFILE";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (arg.len == 0 or arg[0] != '-' or std.mem.eql(u8, arg, "-")) break;
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        }
        if (std.mem.eql(u8, arg, "-t")) {
            strip = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "-c")) {
            i += 1;
            if (i >= args.len) return 1;
            max_count = std.fmt.parseInt(usize, args[i], 10) catch return 1;
        } else if (std.mem.eql(u8, arg, "-s")) {
            i += 1;
            if (i >= args.len) return 1;
            skip = std.fmt.parseInt(usize, args[i], 10) catch return 1;
        } else if (std.mem.eql(u8, arg, "-O")) {
            i += 1;
            if (i >= args.len) return 1;
            origin = std.fmt.parseInt(usize, args[i], 10) catch return 1;
        } else if (std.mem.eql(u8, arg, "-d")) {
            i += 1;
            if (i >= args.len) return 1;
            delim = if (args[i].len > 0) args[i][0] else 0;
        } else if (std.mem.startsWith(u8, arg, "-") and (std.mem.indexOfScalar(u8, "utnc", arg[1]) != null)) {
            // ignore unsupported flags that take no arg (e.g. -u fd handled loosely)
        } else {
            break;
        }
    }

    if (i < args.len) name = args[i];

    // Collect lines (each retains its trailing delimiter, like bash).
    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |l| shell.allocator.free(l);
        lines.deinit(shell.allocator);
    }

    const stdin_fd = compat.posix.STDIN_FILENO;
    var cur: std.ArrayList(u8) = .empty;
    defer cur.deinit(shell.allocator);

    var skipped: usize = 0;
    var kept: usize = 0;
    read_loop: while (true) {
        if (max_count != 0 and kept >= max_count) break;
        var c: [1]u8 = undefined;
        const n = compat.posix.read(stdin_fd, &c) catch break;
        if (n == 0) {
            // flush any trailing partial line (no delimiter at EOF)
            if (cur.items.len > 0) {
                if (skipped < skip) {
                    skipped += 1;
                } else {
                    try lines.append(shell.allocator, try shell.allocator.dupe(u8, cur.items));
                    kept += 1;
                }
                cur.clearRetainingCapacity();
            }
            break;
        }
        try cur.append(shell.allocator, c[0]);
        if (c[0] == delim) {
            if (skipped < skip) {
                skipped += 1;
            } else {
                var line = cur.items;
                if (strip and line.len > 0 and line[line.len - 1] == delim) {
                    line = line[0 .. line.len - 1];
                }
                try lines.append(shell.allocator, try shell.allocator.dupe(u8, line));
                kept += 1;
            }
            cur.clearRetainingCapacity();
            if (max_count != 0 and kept >= max_count) break :read_loop;
        }
    }

    if (origin) |o| {
        // -O: assign starting at index origin, keeping existing elements.
        for (lines.items, 0..) |line, idx| {
            try shell.setArrayElement(name, o + idx, line);
        }
    } else {
        try shell.setArray(name, lines.items);
    }
    return 0;
}

fn isIfsWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

fn stripIfs(s: []const u8) []const u8 {
    var start: usize = 0;
    var end = s.len;
    while (start < end and isIfsWhitespace(s[start])) start += 1;
    while (end > start and isIfsWhitespace(s[end - 1])) end -= 1;
    return s[start..end];
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
            var dir = std.Io.Dir.cwd().openDir(compat.io(), arg, .{}) catch return 1;
            dir.close(compat.io());
            return 0;
        }
        if (std.mem.eql(u8, op, "-f")) {
            const stat = std.Io.Dir.cwd().statFile(compat.io(), arg, .{}) catch return 1;
            return if (stat.kind == .file) 0 else 1;
        }
        if (std.mem.eql(u8, op, "-e")) {
            std.Io.Dir.cwd().access(compat.io(), arg, .{}) catch return 1;
            return 0;
        }
        if (std.mem.eql(u8, op, "-r") or std.mem.eql(u8, op, "-w") or std.mem.eql(u8, op, "-x")) {
            std.Io.Dir.cwd().access(compat.io(), arg, .{}) catch return 1;
            return 0;
        }
        if (std.mem.eql(u8, op, "-s")) {
            const stat = std.Io.Dir.cwd().statFile(compat.io(), arg, .{}) catch return 1;
            return if (stat.size > 0) 0 else 1;
        }
        if (std.mem.eql(u8, op, "-L") or std.mem.eql(u8, op, "-h")) {
            const stat = std.Io.Dir.cwd().statFile(compat.io(), arg, .{}) catch return 1;
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
    const eval_mod = @import("eval.zig");
    for (args[1..]) |arg| {
        const name = if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos|
            arg[0..eq_pos]
        else
            arg;
        // Register the variable as local to the current function call so its
        // prior (global) value is restored on return. Outside a function this
        // returns false and `local` degrades to a plain assignment.
        _ = try eval_mod.declareLocal(shell, name);
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
            try setVar(shell, name, arg[eq_pos + 1 ..]);
        } else {
            try setVar(shell, name, "");
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
            shell.ghost.enabled = enabled;
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

    const file = std.Io.Dir.cwd().openFile(compat.io(), filename, .{}) catch {
        try shell.stdout().print("{s}: {s}: No such file or directory\n", .{ args[0], filename });
        return 1;
    };
    defer file.close(compat.io());

    const content = std.Io.Dir.cwd().readFileAlloc(compat.io(), filename, shell.allocator, .limited(1024 * 1024)) catch {
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
    const envp = @as([*:null]const ?[*:0]const u8, @ptrCast(std.c.environ));

    const path_z = try shell.allocator.dupeZ(u8, full_path);
    compat.posix.execvpeZ(path_z.ptr, argv, envp) catch {
        shell.stdout().print("exec: {s}: command not found\n", .{cmd_name}) catch {};
        compat.posix.exit(126);
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
        var pid: compat.posix.pid_t = 0;

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
            pid = std.fmt.parseInt(compat.posix.pid_t, spec, 10) catch {
                try shell.stdout().print("wait: {s}: invalid pid\n", .{spec});
                return 1;
            };
        }

        // Wait for specific process/group
        const result = compat.posix.waitpid(pid, 0);
        if (result.pid > 0) {
            shell.job_table.markProcessStatus(result.pid, result.status);
            return @truncate(compat.posix.W.EXITSTATUS(result.status));
        }
    } else {
        // Wait for all background jobs
        while (true) {
            const result = compat.posix.waitpid(-1, 0);
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
        const pid = std.fmt.parseInt(compat.posix.pid_t, pid_str, 10) catch {
            try shell.stdout().print("kill: invalid pid: {s}\n", .{pid_str});
            return 1;
        };
        const result = std.c.kill(pid, @enumFromInt(sig));
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
    ru_utime: compat.posix.timeval, // user time
    ru_stime: compat.posix.timeval, // system time
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
fn wait4(pid: compat.posix.pid_t, status: *u32, options: u32, rusage: ?*Rusage) compat.posix.pid_t {
    return compat.posix.waitRusage(pid, status, options, @ptrCast(rusage));
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
    const start = compat.nanoTimestamp();

    // fork and run command
    const pid = compat.posix.fork() catch return BenchSample{
        .wall_ns = 0,
        .user_ns = 0,
        .sys_ns = 0,
        .maxrss_kb = 0,
        .exit_code = 127,
    };

    if (pid == 0) {
        // child - exec the command
        var argv_buf: [256]?[*:0]const u8 = undefined;
        if (cmd_args.len >= argv_buf.len) {
            compat.posix.exit(126);
        }
        for (cmd_args, 0..) |arg, i| {
            const arg_z = shell.allocator.dupeZ(u8, arg) catch compat.posix.exit(127);
            argv_buf[i] = arg_z.ptr;
        }
        argv_buf[cmd_args.len] = null;

        const argv = argv_buf[0..cmd_args.len :null];
        compat.posix.execvpeZ(argv[0].?, argv, @ptrCast(std.c.environ)) catch {};
        compat.posix.exit(127);
    }

    // parent - wait for child with rusage via wait4
    var status: u32 = 0;
    var rusage: Rusage = std.mem.zeroes(Rusage);
    _ = wait4(pid, &status, 0, &rusage);
    const end = compat.nanoTimestamp();

    const wall_ns = end - start;
    const user_ns = timevalToNs(rusage.ru_utime);
    const sys_ns = timevalToNs(rusage.ru_stime);

    const exit_code: u8 = if (compat.posix.W.IFEXITED(status))
        compat.posix.W.EXITSTATUS(status)
    else if (compat.posix.W.IFSIGNALED(status))
        128 + @as(u8, @truncate(@as(u32, @intCast(@intFromEnum(compat.posix.W.TERMSIG(status))))))
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

fn timevalToNs(tv: compat.posix.timeval) i128 {
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
