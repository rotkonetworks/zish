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
const foreground = @import("foreground.zig");

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

/// One builtin: a name and the function that runs it.
///
/// A table rather than a chain of `if (std.mem.eql(...))`. The chain carried
/// a second, hand-maintained list in isBuiltin with the comment "This list
/// must stay in sync with dispatch() cases below" — a rule a human had to
/// remember. Deriving both from one table makes drift unrepresentable rather
/// than merely discouraged.
///
/// `run` returns `?u8`: null means "this name IS a builtin, but eval.zig
/// handles it" (feat, chpw), which the chain expressed the same way.
pub const Builtin = struct {
    name: []const u8,
    run: *const fn (*Shell, []const []const u8) anyerror!?u8,
};

// Adapters, so every entry has one signature. The alternative is a tagged
// union and a switch at the call site, which is more machinery for less.
fn bTrue(_: *Shell, _: []const []const u8) anyerror!?u8 {
    return 0;
}
fn bFalse(_: *Shell, _: []const []const u8) anyerror!?u8 {
    return 1;
}
fn bContinue(_: *Shell, _: []const []const u8) anyerror!?u8 {
    return 253;
}
fn bBreak(_: *Shell, _: []const []const u8) anyerror!?u8 {
    return 254;
}
/// Handled in eval.zig; listed here so isBuiltin agrees with reality.
fn bElsewhere(_: *Shell, _: []const []const u8) anyerror!?u8 {
    return null;
}

/// Wrap `fn(*Shell, args) !u8` into the table signature.
fn withArgs(comptime f: fn (*Shell, []const []const u8) anyerror!u8) fn (*Shell, []const []const u8) anyerror!?u8 {
    return struct {
        fn call(sh: *Shell, args: []const []const u8) anyerror!?u8 {
            return try f(sh, args);
        }
    }.call;
}

/// Wrap `fn(*Shell) !u8` (the builtins that take no arguments).
fn noArgs(comptime f: fn (*Shell) anyerror!u8) fn (*Shell, []const []const u8) anyerror!?u8 {
    return struct {
        fn call(sh: *Shell, _: []const []const u8) anyerror!?u8 {
            return try f(sh);
        }
    }.call;
}

/// Every builtin zish implements. Aliases (`:` for true, `[` for test, `.` for
/// source, `which` for type, `readarray` for mapfile, `declare` for local) are
/// separate rows pointing at the same function, so the alias set is data you
/// can read rather than `or` clauses buried in a condition.
pub const table = [_]Builtin{
    .{ .name = "true", .run = bTrue },
    .{ .name = ":", .run = bTrue },
    .{ .name = "false", .run = bFalse },
    .{ .name = "continue", .run = bContinue },
    .{ .name = "break", .run = bBreak },

    .{ .name = "cd", .run = withArgs(cd) },
    .{ .name = "pwd", .run = withArgs(pwd) },
    .{ .name = "pushd", .run = withArgs(pushd) },
    .{ .name = "popd", .run = withArgs(popd) },
    .{ .name = "dirs", .run = withArgs(dirs) },
    .{ .name = "..", .run = noArgs(dotdot) },
    .{ .name = "...", .run = noArgs(dotdotdot) },
    .{ .name = "-", .run = noArgs(dash) },

    .{ .name = "echo", .run = withArgs(echo) },
    .{ .name = "printf", .run = withArgs(printf) },
    .{ .name = "read", .run = withArgs(read) },
    .{ .name = "mapfile", .run = withArgs(mapfile) },
    .{ .name = "readarray", .run = withArgs(mapfile) },

    .{ .name = "test", .run = withArgs(testCmd) },
    .{ .name = "[", .run = withArgs(testCmd) },

    .{ .name = "export", .run = withArgs(exportVar) },
    .{ .name = "unset", .run = withArgs(unset) },
    .{ .name = "local", .run = withArgs(local) },
    .{ .name = "declare", .run = withArgs(local) },
    .{ .name = "readonly", .run = withArgs(readonly) },
    .{ .name = "set", .run = withArgs(set) },
    .{ .name = "shift", .run = withArgs(shift) },
    .{ .name = "getopts", .run = withArgs(getopts) },

    .{ .name = "alias", .run = withArgs(alias) },
    .{ .name = "unalias", .run = withArgs(unalias) },

    .{ .name = "source", .run = withArgs(source) },
    .{ .name = ".", .run = withArgs(source) },
    .{ .name = "eval", .run = withArgs(eval) },
    .{ .name = "exec", .run = withArgs(exec) },

    .{ .name = "type", .run = withArgs(typeCmd) },
    .{ .name = "which", .run = withArgs(typeCmd) },
    .{ .name = "hash", .run = withArgs(hash) },
    .{ .name = "history", .run = withArgs(history) },
    .{ .name = "help", .run = withArgs(help) },

    .{ .name = "jobs", .run = withArgs(jobs) },
    .{ .name = "fg", .run = withArgs(fg) },
    .{ .name = "bg", .run = withArgs(bg) },
    .{ .name = "wait", .run = withArgs(wait) },
    .{ .name = "kill", .run = withArgs(kill) },
    .{ .name = "disown", .run = withArgs(disown) },
    .{ .name = "trap", .run = withArgs(trap) },

    .{ .name = "exit", .run = withArgs(exit) },
    .{ .name = "return", .run = withArgs(returnCmd) },
    .{ .name = "builtin", .run = withArgs(builtinCmd) },
    .{ .name = "command", .run = withArgs(commandCmd) },
    .{ .name = "time", .run = withArgs(timeCmd) },

    .{ .name = "feat", .run = bElsewhere },
    .{ .name = "chpw", .run = bElsewhere },
};

fn lookup(name: []const u8) ?Builtin {
    for (table) |b| {
        if (std.mem.eql(u8, b.name, name)) return b;
    }
    return null;
}

/// Is `name` a builtin dispatch() knows about?
///
/// Derived from the same table dispatch uses, so the two cannot disagree.
/// (For syntax highlighting of standard bash builtins, see
/// keywords.shell_builtins instead — that list is deliberately wider.)
pub fn isBuiltin(name: []const u8) bool {
    return lookup(name) != null;
}

// main dispatch function - called from eval.zig
pub fn dispatch(shell: *Shell, cmd_name: []const u8, args: []const []const u8) !?u8 {
    const b = lookup(cmd_name) orelse return null; // not a builtin
    return b.run(shell, args);
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
                try shell.stderr().writeAll("cd: OLDPWD not set\n");
                return 1;
            };
            try shell.stdout().print("{s}\n", .{oldpwd});
            break :blk oldpwd;
        }
        break :blk arg;
    } else blk: {
        break :blk compat.posix.getenv("HOME") orelse {
            try shell.stderr().writeAll("cd: HOME not set\n");
            return 1;
        };
    };

    compat.posix.chdir(path) catch {
        try shell.stderr().print("cd: {s}: no such file or directory\n", .{path});
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
        try shell.stderr().writeAll("pwd: cannot get current directory\n");
        return 1;
    };
    try shell.stdout().print("{s}\n", .{cwd});
    return 0;
}

fn dotdot(shell: *Shell) !u8 {
    compat.posix.chdir("..") catch {
        try shell.stderr().writeAll("..: cannot go up\n");
        return 1;
    };
    return 0;
}

fn dotdotdot(shell: *Shell) !u8 {
    compat.posix.chdir("../..") catch {
        try shell.stderr().writeAll("...: cannot go up\n");
        return 1;
    };
    return 0;
}

fn dash(shell: *Shell) !u8 {
    const oldpwd = shell.variables.get("OLDPWD") orelse
        compat.posix.getenv("OLDPWD") orelse {
        try shell.stderr().writeAll("-: OLDPWD not set\n");
        return 1;
    };

    var cwd_buf: [4096]u8 = undefined;
    const cwd = compat.posix.getcwd(&cwd_buf) catch "";

    compat.posix.chdir(oldpwd) catch {
        try shell.stderr().print("-: {s}: no such directory\n", .{oldpwd});
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
        try shell.stderr().writeAll("pushd: cannot get current directory\n");
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
            try shell.stderr().print("pushd: {s}: no such directory\n", .{top});
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
        try shell.stderr().print("pushd: {s}: no such directory\n", .{path});
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
        try shell.stderr().print("popd: {s}: no such directory\n", .{path});
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
            // \c suppresses everything after it, including the newline.
            if (try writeEscaped(shell, arg)) return 0;
        } else {
            try shell.stdout().writeAll(arg);
        }
    }
    if (print_newline) try shell.stdout().writeAll("\n");
    return 0;
}

/// Write `s` with backslash escapes decoded (echo -e dialect). Returns true if
/// a `\c` was hit: bash then suppresses ALL further output, including the other
/// arguments and the trailing newline.
fn writeEscaped(shell: *Shell, s: []const u8) !bool {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\') {
            const esc = parseEscape(s[i + 1 ..], .echo);
            if (esc.stop) return true;
            try shell.stdout().writeByte(esc.char);
            i += 1 + esc.len;
        } else {
            try shell.stdout().writeByte(s[i]);
            i += 1;
        }
    }
    return false;
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
            if (format[i] == '\\') {
                const escaped = parseEscape(format[i + 1 ..], .printf_format);
                try writer.writeByte(escaped.char);
                i += 1 + escaped.len;
            } else if (format[i] == '%') {
                const spec = printfParseSpec(format[i..]);
                if (spec.specifier == '%') {
                    try writer.writeByte('%');
                } else {
                    const arg = if (arg_idx < args.len) args[arg_idx] else "";
                    if (arg_idx < args.len) arg_idx += 1;
                    // %b's \c aborts the whole printf: rest of the format,
                    // remaining arguments, and any format-reuse passes.
                    if (try printfFormatArg(writer, spec, arg)) return 0;
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

/// Rewrite Zig's float exponent (`3.142e4`, `1e-4`) into C printf's `e+04` /
/// `e-04` form, into `out`. `upper` uppercases the `e`. Falls back to the input
/// if it has no exponent or doesn't fit.
fn cStyleExponent(out: []u8, s: []const u8, upper: bool) []const u8 {
    const e_idx = std.mem.indexOfScalar(u8, s, 'e') orelse return s;
    const mant = s[0..e_idx];
    var exp = s[e_idx + 1 ..];
    var neg = false;
    if (exp.len > 0 and (exp[0] == '+' or exp[0] == '-')) {
        neg = exp[0] == '-';
        exp = exp[1..];
    }
    const pad: usize = if (exp.len < 2) 2 - exp.len else 0;
    return std.fmt.bufPrint(out, "{s}{c}{c}{s}{s}", .{
        mant,
        @as(u8, if (upper) 'E' else 'e'),
        @as(u8, if (neg) '-' else '+'),
        ("00")[0..pad],
        exp,
    }) catch s;
}

/// Format one argument per `spec`. Returns true when a %b argument hit `\c`,
/// which aborts the entire printf invocation (bash semantics).
fn printfFormatArg(writer: anytype, spec: PrintfSpec, arg: []const u8) !bool {
    var buf: [64]u8 = undefined;
    var output: []const u8 = "";

    switch (spec.specifier) {
        's' => {
            output = if (spec.precision) |p| arg[0..@min(p, arg.len)] else arg;
        },
        'c' => {
            // bash %c is the FIRST BYTE of the argument, never a numeric code:
            // printf '%c' 65 prints '6', not 'A'.
            if (arg.len > 0) output = arg[0..1];
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
        'f', 'F' => {
            // Honor the requested precision (was hardcoded to 6): %.2f -> 3.14.
            const val = std.fmt.parseFloat(f64, arg) catch 0.0;
            const prec = spec.precision orelse 6;
            output = std.fmt.bufPrint(&buf, "{d:.[1]}", .{ val, prec }) catch "";
        },
        'e', 'E', 'g', 'G' => {
            const val = std.fmt.parseFloat(f64, arg) catch 0.0;
            const prec = spec.precision orelse 6;
            var tmp: [64]u8 = undefined;
            const raw = std.fmt.bufPrint(&tmp, "{e:.[1]}", .{ val, prec }) catch "";
            // Zig prints the exponent as `e4`/`e-4`; C printf uses `e+04`.
            output = cStyleExponent(&buf, raw, spec.specifier == 'E' or spec.specifier == 'G');
        },
        'b' => {
            // string with backslash escapes interpreted (\t, \n, \xNN, \0nnn…)
            var k: usize = 0;
            while (k < arg.len) {
                if (arg[k] == '\\') {
                    const esc = parseEscape(arg[k + 1 ..], .printf_b);
                    if (esc.stop) return true;
                    if (esc.len > 0) {
                        try writer.writeByte(esc.char);
                        k += 1 + esc.len;
                        continue;
                    }
                }
                try writer.writeByte(arg[k]);
                k += 1;
            }
            return false;
        },
        'q' => {
            // Quote so the result re-reads as this exact word (bash %q):
            //  - empty            -> ''
            //  - any control byte -> wrap the WHOLE word in $'...' (so a newline
            //    becomes $'a\nb', which round-trips; a backslash-newline would
            //    reparse as a line continuation and NOT round-trip)
            //  - otherwise        -> backslash-escape shell metacharacters in place
            if (arg.len == 0) {
                try writer.writeAll("''");
                return false;
            }
            var has_ctrl = false;
            for (arg) |c| {
                if (c < 0x20 or c == 0x7f) has_ctrl = true;
            }
            if (has_ctrl) {
                try writer.writeAll("$'");
                for (arg) |c| switch (c) {
                    '\n' => try writer.writeAll("\\n"),
                    '\t' => try writer.writeAll("\\t"),
                    '\r' => try writer.writeAll("\\r"),
                    '\\' => try writer.writeAll("\\\\"),
                    '\'' => try writer.writeAll("\\'"),
                    else => {
                        if (c < 0x20 or c == 0x7f) {
                            var ob: [8]u8 = undefined;
                            try writer.writeAll(std.fmt.bufPrint(&ob, "\\{o:0>3}", .{c}) catch "");
                        } else try writer.writeByte(c);
                    },
                };
                try writer.writeAll("'");
            } else {
                for (arg) |c| {
                    const needs_escape = switch (c) {
                        ' ', '|', '&', ';', '<', '>', '(', ')', '$', '`',
                        '"', '\'', '\\', '*', '?', '[', ']', '{', '}', '~', '#', '!' => true,
                        else => false,
                    };
                    if (needs_escape) try writer.writeByte('\\');
                    try writer.writeByte(c);
                }
            }
            return false;
        },
        else => return false,
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
    return false;
}

/// The three escape dialects bash implements. They agree on the common
/// sequences (\n \t \r \a \b \e \E \f \v \\ \xHH) and differ only in the octal
/// form, \c, and \' \" \? — verified against bash 5 byte-for-byte:
///   echo -e         octal \0nnn;  \c stops all output;  \' \" \? stay literal
///   printf format   octal \nnn;   \c stays literal;     \' \" \? drop the backslash
///   printf %b       octal \0nnn or \nnn; \c stops;      \' \" \? stay literal
pub const EscapeMode = enum { echo, printf_format, printf_b };

pub const EscapeResult = struct {
    char: u8,
    len: usize, // input bytes consumed AFTER the backslash
    stop: bool = false, // \c: suppress all further output
};

/// Decode one backslash escape. `s` is the text immediately following a
/// backslash. An unrecognized (or trailing) escape returns {char='\\', len=0}:
/// the caller emits the backslash and continues at the next byte, which
/// reproduces the input literally — exactly what bash does.
///
/// This is the ONLY escape decoder; echo (builtin + fast path) and printf all
/// route through it so the dialects can never drift apart again.
pub fn parseEscape(s: []const u8, mode: EscapeMode) EscapeResult {
    const literal: EscapeResult = .{ .char = '\\', .len = 0 };
    if (s.len == 0) return literal;
    switch (s[0]) {
        'n' => return .{ .char = '\n', .len = 1 },
        't' => return .{ .char = '\t', .len = 1 },
        'r' => return .{ .char = '\r', .len = 1 },
        'a' => return .{ .char = 0x07, .len = 1 },
        'b' => return .{ .char = 0x08, .len = 1 },
        'e', 'E' => return .{ .char = 0x1b, .len = 1 },
        'f' => return .{ .char = 0x0c, .len = 1 },
        'v' => return .{ .char = 0x0b, .len = 1 },
        '\\' => return .{ .char = '\\', .len = 1 },
        'c' => return if (mode == .printf_format)
            literal
        else
            .{ .char = 0, .len = 1, .stop = true },
        '\'', '"', '?' => return if (mode == .printf_format)
            .{ .char = s[0], .len = 1 }
        else
            literal,
        'x' => {
            // \xH or \xHH — one or two hex digits, else literal. Overflow wraps
            // (mod 256), matching bash.
            var val: u8 = 0;
            var n: usize = 0;
            while (n < 2 and 1 + n < s.len) : (n += 1) {
                const d = std.fmt.charToDigit(s[1 + n], 16) catch break;
                val = val *% 16 +% d;
            }
            if (n == 0) return literal;
            return .{ .char = val, .len = 1 + n };
        },
        '0'...'7' => {
            // Octal. The dialects differ only in the leading '0' (see above);
            // up to 3 value digits either way, wrapping mod 256 like bash.
            var i: usize = 0;
            switch (mode) {
                .echo => {
                    if (s[0] != '0') return literal;
                    i = 1;
                },
                .printf_b => {
                    if (s[0] == '0') i = 1;
                },
                .printf_format => {},
            }
            var val: u8 = 0;
            var n: usize = 0;
            while (n < 3 and i < s.len and s[i] >= '0' and s[i] <= '7') : (n += 1) {
                val = val *% 8 +% (s[i] - '0');
                i += 1;
            }
            return .{ .char = val, .len = i };
        },
        else => return literal,
    }
}

// One owner for delimiter-terminated reads from an fd — backs both `read` and
// `mapfile`. It over-reads a block and serves lines out of it (bash's strategy:
// ~1 read/line instead of ~1 poll+read per byte), growing the caller's buffer so
// there is no line-length limit, and reconciling the fd offset on pushback().
//
// SAFETY: over-reading past a delimiter is only sound on a fd we can
// rewind. init() probes with lseek; a non-seekable fd (pipe/tty/socket) drops to
// byte-at-a-time so it never reads past what it returns — the over-read branch
// is unreachable unless rewind is proven. INVARIANT: after pushback() the kernel
// fd offset sits exactly past the last byte returned, so a following reader (even
// a process sharing the OFD) sees the exact remainder. Buffered bytes never
// outlive a pushback().
const LineReader = struct {
    const SEEK_CUR: u32 = 1;

    fd: compat.posix.fd_t,
    buf: [4096]u8 = undefined,
    start: usize = 0, // unconsumed region is buf[start..end]
    end: usize = 0,
    overread: bool, // block-read (seekable) vs byte-at-a-time (non-seekable)

    fn init(fd: compat.posix.fd_t) LineReader {
        // Seekable ⇒ we can lseek unconsumed bytes back, so over-reading is safe.
        var overread = true;
        _ = compat.posix.lseek(fd, 0, SEEK_CUR) catch {
            overread = false;
        };
        return .{ .fd = fd, .overread = overread };
    }

    // Refill buf when empty; returns bytes now available (0 = EOF). Reads a full
    // block when we can rewind, a single byte when we cannot.
    fn fill(self: *LineReader) !usize {
        if (self.start < self.end) return self.end - self.start;
        self.start = 0;
        self.end = 0;
        const cap: usize = if (self.overread) self.buf.len else 1;
        self.end = compat.posix.read(self.fd, self.buf[0..cap]) catch return error.ReadFailed;
        return self.end;
    }

    // Append bytes up to and including the next `delim` into `out` (grows as
    // needed). Returns true if a delimiter was consumed, false at EOF first.
    fn nextLine(self: *LineReader, alloc: std.mem.Allocator, out: *std.ArrayList(u8), delim: u8) !bool {
        while (true) {
            if (try self.fill() == 0) return false; // EOF
            const region = self.buf[self.start..self.end];
            if (std.mem.indexOfScalar(u8, region, delim)) |i| {
                try out.appendSlice(alloc, region[0 .. i + 1]); // include the delim
                self.start += i + 1;
                return true;
            }
            try out.appendSlice(alloc, region);
            self.start = self.end; // whole buffer consumed; read more
        }
    }

    // Reconcile the fd: push buffered-but-unconsumed bytes back so the offset
    // sits exactly past the last byte returned. No-op in byte mode (nothing is
    // ever over-read) and at EOF (buffer drained).
    fn pushback(self: *LineReader) void {
        const leftover = self.end - self.start;
        if (leftover == 0 or !self.overread) return;
        _ = compat.posix.lseek(self.fd, -@as(i64, @intCast(leftover)), SEEK_CUR) catch {};
        self.start = self.end;
    }
};

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
                try shell.stderr().writeAll("read: -p requires prompt string\n");
                return 1;
            }
            prompt = args[i];
        } else if (std.mem.eql(u8, arg, "-t")) {
            i += 1;
            if (i >= args.len) {
                try shell.stderr().writeAll("read: -t requires timeout\n");
                return 1;
            }
            timeout_secs = std.fmt.parseInt(u32, args[i], 10) catch {
                try shell.stderr().writeAll("read: invalid timeout\n");
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "-n")) {
            i += 1;
            if (i >= args.len) {
                try shell.stderr().writeAll("read: -n requires count\n");
                return 1;
            }
            nchars = std.fmt.parseInt(usize, args[i], 10) catch {
                try shell.stderr().writeAll("read: invalid count\n");
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

    // Cook the terminal for the duration of the read.
    //
    // The interactive line editor leaves the terminal in raw mode: no canonical
    // line discipline, ECHO off, ICRNL off. A `read` running in that state has
    // no echo (you can't see what you type) and, worse, receives Enter as CR
    // rather than LF — so this loop, which ends the line on '\n', waits forever.
    // That is the "overwrite? [y/N] — stuck, can't press y and Enter" bug: the
    // prompt is a shell function's `printf` + `read`, not the program's own.
    // bash's read relies on the terminal being cooked; do the same. For -n
    // (fixed char count) stay non-canonical so it returns without Enter, but
    // still echo and translate CR->LF. Restore the prior mode on every exit.
    var orig_termios: ?compat.posix.termios = null;
    if (compat.posix.isatty(stdin_fd)) {
        orig_termios = compat.posix.tcgetattr(stdin_fd) catch null;
        if (orig_termios) |ot| {
            var nt = ot;
            nt.lflag.ICANON = (nchars == null); // line mode unless -n
            nt.lflag.ECHO = !silent;
            nt.lflag.ISIG = true; // Ctrl+C can abort the read
            nt.iflag.ICRNL = true; // Enter (CR) arrives as LF
            nt.cc[@intFromEnum(compat.posix.V.MIN)] = 1;
            nt.cc[@intFromEnum(compat.posix.V.TIME)] = 0;
            compat.posix.tcsetattr(stdin_fd, .NOW, nt) catch {};
        }
    }
    defer {
        if (orig_termios) |ot| {
            compat.posix.tcsetattr(stdin_fd, .NOW, ot) catch {};
            // echo was suppressed for -s: move to a fresh line as the user's
            // Enter was not shown.
            if (silent) _ = compat.posix.write(compat.posix.STDOUT_FILENO, "\n") catch {};
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

    // The bytes read this call; either LineReader's growable buffer (fast path)
    // or buf[0..pos] (byte path).
    var value: []const u8 = &.{};
    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(shell.allocator);

    // Fast path for the hot case — a plain raw whole-line read. LineReader
    // block-reads on a seekable fd and byte-reads on a pipe/tty, growing the
    // buffer so there is no line-length limit; pushback() leaves the fd exactly
    // past the line. -n (char count), -t (timeout), and non-raw (backslash
    // processing) change the stop condition, so they keep the byte path below.
    var used_fast = false;
    if (raw and nchars == null and timeout_secs == null) {
        var lr = LineReader.init(stdin_fd);
        const had_delim = lr.nextLine(shell.allocator, &line_buf, '\n') catch return 1;
        lr.pushback();
        var v = line_buf.items;
        if (had_delim and v.len > 0 and v[v.len - 1] == '\n') v = v[0 .. v.len - 1];
        value = v;
        hit_eof = !had_delim; // EOF before a delimiter ⇒ read reports failure
        used_fast = true;
    }

    // Byte-at-a-time path: modes the fast path excludes (-n / -t / non-raw).
    // poll() is only needed to honour -t; without a timeout it is pure syscall
    // overhead, so gate it.
    while (!used_fast and pos < max_chars) {
        if (timeout_secs != null) {
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

    if (!used_fast) value = buf[0..pos];

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

    // bash/POSIX: read returns non-zero when EOF is reached before a line
    // delimiter. hit_eof is set only in that case (a newline-terminated line
    // breaks/returns before EOF is seen), so a partial final line without a
    // trailing newline still reports failure — its data is assigned, but a
    // `while read` loop correctly skips the body for it, matching bash.
    return if (hit_eof) 1 else 0;
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
    var lr = LineReader.init(stdin_fd);
    var cur: std.ArrayList(u8) = .empty; // one buffer, recycled per line
    defer cur.deinit(shell.allocator);

    var skipped: usize = 0;
    var kept: usize = 0;
    while (true) {
        if (max_count != 0 and kept >= max_count) break;
        cur.clearRetainingCapacity();
        // nextLine appends up to and including `delim` (or to EOF); had_delim is
        // false only when EOF was reached first.
        const had_delim = lr.nextLine(shell.allocator, &cur, delim) catch break;
        if (!had_delim and cur.items.len == 0) break; // clean EOF

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
        if (!had_delim) break; // trailing partial line (no delimiter at EOF)
    }
    // Reconcile the fd when we stopped early (-n) on a seekable fd, so a later
    // reader sees the lines we did not consume — parity with bash's mapfile.
    lr.pushback();

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
    if (args.len < 2) return 1;

    var test_args = args[1..];

    // handle [ ... ] syntax - remove trailing ]
    if (args[0].len == 1 and args[0][0] == '[') {
        if (test_args.len > 0 and std.mem.eql(u8, test_args[test_args.len - 1], "]")) {
            test_args = test_args[0 .. test_args.len - 1];
        }
    }

    if (test_args.len == 0) return 1;

    // Delegate to the one `test` evaluator (handles !, -a/-o, -nt/-ot/-ef).
    // Imported here rather than at module scope: eval imports builtins, so the
    // cycle is broken at the call site.
    const eval_mod = @import("eval.zig");
    return if (eval_mod.evaluateTestExprFlat(shell, test_args)) 0 else 1;
}

// ============ variable builtins ============

fn exportVar(shell: *Shell, args: []const []const u8) !u8 {
    for (args[1..]) |arg| {
        // Accept a leading `-p`/`--` gracefully (ignore); real work is names.
        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--")) continue;
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| {
            const name = arg[0..eq_pos];
            try setVar(shell, name, arg[eq_pos + 1 ..]);
            try shell.markExported(name);
        } else {
            // `export NAME` marks an existing (or future) variable exported
            // without assigning — bash accepts this; it is not an error.
            if (!isValidName(arg)) {
                try shell.stderr().print("export: `{s}': not a valid identifier\n", .{arg});
                return 1;
            }
            try shell.markExported(arg);
        }
    }
    return 0;
}

fn isValidName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

fn unset(shell: *Shell, args: []const []const u8) !u8 {
    for (args[1..]) |arg| {
        if (shell.variables.fetchRemove(arg)) |kv| {
            shell.allocator.free(kv.key);
            shell.allocator.free(kv.value);
        }
        // Drop the export mark too, so a later same-name assignment stays local.
        if (shell.exported.fetchRemove(arg)) |kv| shell.allocator.free(kv.key);
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
                try shell.stderr().writeAll("set: -o requires option name\n");
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
                try shell.stderr().print("set: unknown option: {s}\n", .{opt_name});
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
                        try shell.stderr().print("set: invalid option: -{c}\n", .{c});
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
            try shell.stderr().print("set: unknown option: {s}\n", .{arg});
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
        try shell.stderr().print("shift: {d}: shift count out of range\n", .{n});
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
                try shell.stderr().print("getopts: option requires argument -- {c}\n", .{opt});
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
                try shell.stderr().print("alias: {s}: not found\n", .{arg});
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
        try shell.stderr().print("{s}: {s}: No such file or directory\n", .{ args[0], filename });
        return 1;
    };
    defer file.close(compat.io());

    const content = std.Io.Dir.cwd().readFileAlloc(compat.io(), filename, shell.allocator, .limited(1024 * 1024)) catch {
        try shell.stderr().print("{s}: {s}: Error reading file\n", .{ args[0], filename });
        return 1;
    };
    defer shell.allocator.free(content);

    const eval_mod = @import("eval.zig");

    // `source file a b c` runs the script with $1..$n set to a b c (and $#
    // updated), restoring the caller's positionals afterward — same discipline as
    // a function call. With no extra args, the caller's positionals are left
    // untouched (bash). The old code set $1.. but never $# and never restored,
    // so a sourced script permanently clobbered the caller's $1.
    var saved: std.ArrayList([]u8) = .empty;
    defer {
        for (saved.items) |s| shell.allocator.free(s);
        saved.deinit(shell.allocator);
    }
    const have_args = args.len > 2;
    if (have_args) {
        try eval_mod.savePositionals(shell, &saved);
        try eval_mod.installPositionals(shell, args[2..]);
    }
    defer if (have_args) eval_mod.restorePositionals(shell, saved.items);

    var p = parser.Parser.init(content, shell.allocator) catch {
        try shell.stderr().print("{s}: {s}: Parse error\n", .{ args[0], filename });
        return 1;
    };
    defer p.deinit();

    const tree = p.parse() catch {
        try shell.stderr().print("{s}: {s}: Syntax error\n", .{ args[0], filename });
        return 1;
    };

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
        try shell.stderr().writeAll("eval: parse error\n");
        return 1;
    };

    const eval_mod = @import("eval.zig");
    return try eval_mod.evaluateAst(shell, tree);
}

fn exec(shell: *Shell, args: []const []const u8) !u8 {
    if (args.len < 2) {
        try shell.stderr().writeAll("exec: usage: exec command [arguments]\n");
        return 1;
    }

    const cmd_name = args[1];
    const full_path = shell.lookupCommand(cmd_name) orelse cmd_name;

    var argv_buf: [256]?[*:0]const u8 = undefined;
    // Fail closed rather than silently exec with a truncated argv.
    if (args.len - 1 >= argv_buf.len) {
        try shell.stderr().writeAll("exec: too many arguments\n");
        return 1;
    }
    var arg_count: usize = 0;
    for (args[1..]) |arg| {
        const duped = try shell.allocator.dupeZ(u8, arg);
        argv_buf[arg_count] = duped.ptr;
        arg_count += 1;
    }
    argv_buf[arg_count] = null;

    const argv = argv_buf[0..arg_count :null];
    // Pass the shell's full environment (exported vars set this session), not the
    // raw process environ — otherwise `FOO=1; exec env` loses FOO.
    const eval_mod = @import("eval.zig");
    const envp = eval_mod.buildEnvironment(shell) catch
        @as([*:null]const ?[*:0]const u8, @ptrCast(std.c.environ));

    const path_z = try shell.allocator.dupeZ(u8, full_path);
    compat.posix.execvpeZ(path_z.ptr, argv, envp) catch {
        shell.stderr().print("exec: {s}: command not found\n", .{cmd_name}) catch {};
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

        try shell.stderr().print("type: {s}: not found\n", .{name});
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
            try shell.stderr().print("hash: {s}: not found\n", .{name});
        }
    }
    return 0;
}

fn history(shell: *Shell, args: []const []const u8) !u8 {
    _ = args;
    const h = shell.history orelse {
        try shell.stderr().writeAll("history: not available\n");
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
        // Mark done jobs notified here so the prompt-time notifier doesn't print
        // a second "Done" line for a job the user already saw via `jobs`.
        if (job.state == .done) job.notified = true;
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
        job = shell.job_table.parseJobSpec(args[1]);
        if (job == null) {
            try shell.stderr().print("fg: {s}: no such job\n", .{args[1]});
            return 1;
        }
    } else {
        // No args: use current job
        job = shell.job_table.getCurrentJob();
    }

    if (job == null) {
        try shell.stderr().writeAll("fg: no current job\n");
        return 1;
    }

    const j = job.?;
    try shell.stdout().print("{s}\n", .{j.command});
    shell.stdout().flush() catch {};

    // Same foreground discipline as launching a fresh child, through the
    // single owner (cooked tty, terminal to the job's pgroup, SIGINT-ignored
    // UNTRACED wait, reclaim, editor raw mode restored) — replaces the
    // divergent JobTable.putJobInForeground/shell_tmodes mechanism.
    const status = foreground.resumeJobForeground(shell, j, j.state == .stopped);

    // If job completed, remove it
    if (j.isCompleted()) {
        shell.job_table.removeJob(j.id);
    }

    return status;
}

fn bg(shell: *Shell, args: []const []const u8) !u8 {
    // Update job statuses
    shell.job_table.updateJobStatuses();

    var job: ?*@import("jobs.zig").Job = null;

    if (args.len > 1) {
        job = shell.job_table.parseJobSpec(args[1]);
        if (job == null) {
            try shell.stderr().print("bg: {s}: no such job\n", .{args[1]});
            return 1;
        }
    } else {
        job = shell.job_table.getCurrentJob();
    }

    if (job == null) {
        try shell.stderr().writeAll("bg: no current job\n");
        return 1;
    }

    const j = job.?;

    if (j.state != .stopped) {
        try shell.stderr().print("bg: job {d} already in background\n", .{j.id});
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

        if (spec.len > 0 and spec[0] == '%') {
            // Job spec (%N, %+, %-, %%) — shared resolver
            const job = shell.job_table.parseJobSpec(spec) orelse {
                try shell.stderr().print("wait: {s}: no such job\n", .{spec});
                return 127;
            };
            pid = job.pgid;
        } else {
            pid = std.fmt.parseInt(compat.posix.pid_t, spec, 10) catch {
                try shell.stderr().print("wait: {s}: invalid pid\n", .{spec});
                return 1;
            };
        }

        // Wait for specific process/group
        const result = compat.posix.waitpid(pid, 0);
        if (result.pid > 0) {
            shell.job_table.markProcessStatus(result.pid, result.status);
            return @import("jobs.zig").JobTable.decodeStatus(result.status).code;
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
        try shell.stderr().writeAll("kill: usage: kill [-signal] pid\n");
        return 1;
    }

    var sig: u8 = 15; // SIGTERM default
    var pid_start: usize = 1;

    // -l lists signal names, derived from the one authoritative Signal enum
    // (shared with `trap`) so the list can never drift from what's accepted.
    if (std.mem.eql(u8, args[1], "-l")) {
        inline for (std.meta.fields(Shell.TrapTable.Signal), 0..) |f, i| {
            if (i > 0) try shell.stdout().writeByte(' ');
            try shell.stdout().writeAll(f.name);
        }
        try shell.stdout().writeByte('\n');
        return 0;
    }

    // -SIG / -NN: resolve through the same Signal.fromName `trap` uses, so every
    // name (USR1, WINCH, SIGHUP, …) and number works, not a hand-picked seven.
    if (args[1][0] == '-') {
        const sig_str = args[1][1..];
        const parsed = Shell.TrapTable.Signal.fromName(sig_str) orelse {
            try shell.stderr().print("kill: {s}: invalid signal specification\n", .{sig_str});
            return 1;
        };
        sig = @intFromEnum(parsed);
        pid_start = 2;
    }

    for (args[pid_start..]) |pid_str| {
        const pid = std.fmt.parseInt(compat.posix.pid_t, pid_str, 10) catch {
            try shell.stderr().print("kill: invalid pid: {s}\n", .{pid_str});
            return 1;
        };
        const result = std.c.kill(pid, @enumFromInt(sig));
        if (result != 0) {
            try shell.stderr().print("kill: {d}: operation not permitted\n", .{pid});
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
                        try shell.stderr().print("disown: invalid option: -{c}\n", .{c});
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

    // Process each job spec via the shared resolver
    for (args[job_specs_start..]) |spec| {
        if (shell.job_table.parseJobSpec(spec)) |job| {
            if (!running_only or job.state == .running) {
                shell.job_table.removeJob(job.id);
            }
        } else {
            try shell.stderr().print("disown: {s}: no such job\n", .{spec});
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
                    try shell.stderr().print("trap: {s}: invalid signal\n", .{sig_name});
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
            try shell.stderr().print("trap: {s}: invalid signal\n", .{sig_name});
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
    // `builtin NAME [args]` runs NAME as a builtin only, bypassing any function
    // or alias of the same name. Re-dispatch through the builtin table (which is
    // exactly "builtins only, no alias/function"); error if NAME isn't a builtin.
    if (args.len < 2) return 0;
    if (try dispatch(shell, args[1], args[1..])) |rc| return rc;
    try shell.stderr().print("builtin: {s}: not a shell builtin\n", .{args[1]});
    return 1;
}

fn commandCmd(shell: *Shell, args: []const []const u8) !u8 {
    // `command -v/-V NAME` — resolution query used pervasively in scripts
    // (`if command -v foo >/dev/null; then ...`). `command NAME [args]` runs NAME
    // ignoring functions/aliases; the builtin case is handled here, the external
    // case still falls through to eval (see below).
    if (args.len < 2) return 0;

    if (std.mem.eql(u8, args[1], "-v") or std.mem.eql(u8, args[1], "-V")) {
        if (args.len < 3) return 1;
        const verbose = std.mem.eql(u8, args[1], "-V");
        const name = args[2];
        if (shell.aliases.get(name)) |val| {
            if (verbose)
                try shell.stdout().print("{s} is aliased to `{s}'\n", .{ name, val })
            else
                try shell.stdout().print("alias {s}='{s}'\n", .{ name, val });
            return 0;
        }
        if (shell.functions.get(name) != null) {
            if (verbose)
                try shell.stdout().print("{s} is a function\n", .{name})
            else
                try shell.stdout().print("{s}\n", .{name});
            return 0;
        }
        if (isBuiltin(name)) {
            if (verbose)
                try shell.stdout().print("{s} is a shell builtin\n", .{name})
            else
                try shell.stdout().print("{s}\n", .{name});
            return 0;
        }
        if (shell.lookupCommand(name)) |path| {
            if (verbose)
                try shell.stdout().print("{s} is {s}\n", .{ name, path })
            else
                try shell.stdout().print("{s}\n", .{path});
            return 0;
        }
        if (verbose) try shell.stderr().print("{s}: not found\n", .{name});
        return 1;
    }

    // `command NAME args` where NAME is a builtin: dispatch it directly.
    if (isBuiltin(args[1])) {
        if (try dispatch(shell, args[1], args[1..])) |rc| return rc;
    }
    // External NAME: eval owns the fork/exec + foreground discipline, and the
    // function/alias-bypass belongs in its resolution order. Signal that eval
    // should run args[1..] as an external command, not treat "command" as one.
    return error.RunAsCommand;
}

// ============ time builtin - statistical benchmarking ============

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

// (the wait4-with-rusage wait now happens inside foreground.Session.reap,
// via its optional rusage argument)

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

    // run warmup iterations. 148 = the timed child was Ctrl+Z'd and is now a
    // stopped job — do not fork further iterations on top of it.
    for (0..warmup) |_| {
        const s = try runTimedCommand(shell, cmd_args);
        if (s.exit_code == 148) return 148;
    }

    // collect samples
    var samples: [10000]BenchSample = undefined;
    var last_exit: u8 = 0;
    var collected: usize = 0;

    for (0..iterations) |iter| {
        samples[iter] = try runTimedCommand(shell, cmd_args);
        last_exit = samples[iter].exit_code;
        collected = iter + 1;
        if (last_exit == 148) break; // stopped by Ctrl+Z — stop benchmarking
    }

    // compute statistics
    const stats = computeStats(samples[0..collected]);

    // output results
    if (is_benchmark) {
        try printBenchmarkResults(writer, stats, collected, quiet, show_histogram, samples[0..collected]);
    } else {
        try printSingleResult(writer, samples[0], quiet, verbose);
    }

    return last_exit;
}

fn runTimedCommand(shell: *Shell, cmd_args: []const []const u8) !BenchSample {
    // Full foreground job-control discipline via the single owner: cooked
    // tty, own pgroup + terminal for the child, default signals, UNTRACED
    // wait, stopped-job registration. Before this, `time sleep 30` could not
    // be Ctrl+C'd (child inherited SIG_IGN through exec) and Ctrl+Z wedged
    // the shell (non-UNTRACED wait).
    var fg_session = foreground.Session.begin(shell);
    defer fg_session.end();

    shell.stdout().flush() catch {};

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
        // child: own pgroup + terminal, then default signals, then exec
        fg_session.setupChild();
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

    // parent: race-avoidance setpgid, then the owned wait (routed through
    // wait4 for rusage — the `rusage` argument of Session.reap).
    fg_session.registerChild(pid);

    var cmd_buf: [512]u8 = undefined;
    var cmd_len: usize = 0;
    for (cmd_args, 0..) |a, i| {
        if (i > 0 and cmd_len < cmd_buf.len) {
            cmd_buf[cmd_len] = ' ';
            cmd_len += 1;
        }
        const n = @min(a.len, cmd_buf.len - cmd_len);
        @memcpy(cmd_buf[cmd_len .. cmd_len + n], a[0..n]);
        cmd_len += n;
        if (cmd_len >= cmd_buf.len) break;
    }

    var rusage: Rusage = std.mem.zeroes(Rusage);
    const out = fg_session.reap(pid, cmd_buf[0..cmd_len], @ptrCast(&rusage));
    const end = compat.nanoTimestamp();

    const wall_ns = end - start;
    const user_ns = timevalToNs(rusage.ru_utime);
    const sys_ns = timevalToNs(rusage.ru_stime);

    return BenchSample{
        .wall_ns = wall_ns,
        .user_ns = user_ns,
        .sys_ns = sys_ns,
        .maxrss_kb = rusage.ru_maxrss,
        .exit_code = out.code,
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
