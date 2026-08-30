//! Tiny command-line parser.
//!
//! A shell whose whole pitch is a self-contained binary should not pull a build
//! dependency just to parse five flags — least of all one fetched from
//! `archive/refs/heads/master.tar.gz`, a moving branch.
//!
//! Two properties worth having that a general parser cannot offer:
//!
//! **Zero allocation.** Values and positionals are slices *into* argv, which
//! outlives the shell's use of them, so there is nothing to free and no
//! failure path for an allocator that is out of memory before the shell has
//! even started.
//!
//! **POSIX option termination.** The first non-option argument ends option
//! parsing, so `zish script.sh -c foo` passes `-c foo` to the *script* rather
//! than to zish. A general-purpose parser gets this wrong for shells because
//! it keeps scanning for flags. That also makes positionals a contiguous tail
//! of argv, which is why no copying is needed.
//!
//! Supported forms: `-v`, `--verbose`, `-d VALUE`, `--file VALUE`,
//! `--file=VALUE`, and `--` to force the rest to be positional.
//! Deliberately absent: clustered short flags (`-abc`), optional values,
//! repeated-flag counting. Add them when something needs them.

const std = @import("std");

pub const Flag = struct {
    /// Single-character form, without the dash. Null for long-only flags.
    short: ?u8 = null,
    /// Long form, without the dashes. Null for short-only flags.
    long: ?[]const u8 = null,
    /// Shown in --help.
    help: []const u8,
    /// When true the flag consumes the next argument (or the part after '=').
    takes_value: bool = false,
    /// Placeholder for the value in --help, e.g. "FILE".
    value_name: []const u8 = "VALUE",
};

pub const Error = error{
    UnknownFlag,
    MissingValue,
    TooManyFlags,
};

pub const max_flags = 32;

pub const Result = struct {
    /// Parallel to the spec: set[i] is true when flags[i] appeared.
    set: [max_flags]bool = [_]bool{false} ** max_flags,
    /// Parallel to the spec: values[i] is the value for a takes_value flag.
    values: [max_flags]?[]const u8 = [_]?[]const u8{null} ** max_flags,
    /// Contiguous tail of argv after option parsing stopped. Borrowed.
    positionals: []const []const u8 = &.{},
    /// The argument that caused the error, for a useful message.
    bad_arg: []const u8 = "",

    spec: []const Flag = &.{},

    fn indexOf(self: Result, name: []const u8) ?usize {
        for (self.spec, 0..) |f, i| {
            if (f.long) |l| if (std.mem.eql(u8, l, name)) return i;
            if (name.len == 1 and f.short == name[0]) return i;
        }
        return null;
    }

    /// True when the flag was present. Unknown names return false rather than
    /// trapping: the spec is a comptime literal in practice, so a typo is a
    /// programming error caught by the tests, not a runtime condition worth
    /// panicking a user's shell over.
    pub fn isSet(self: Result, name: []const u8) bool {
        return if (self.indexOf(name)) |i| self.set[i] else false;
    }

    pub fn value(self: Result, name: []const u8) ?[]const u8 {
        return if (self.indexOf(name)) |i| self.values[i] else null;
    }
};

/// Parse `argv` (including argv[0], which is skipped) against `spec`.
pub fn parse(spec: []const Flag, argv: []const []const u8) Error!Result {
    if (spec.len > max_flags) return Error.TooManyFlags;

    var r = Result{ .spec = spec };
    var i: usize = 1; // skip argv[0]

    while (i < argv.len) : (i += 1) {
        const arg = argv[i];

        // "--" ends options; everything after is positional.
        if (std.mem.eql(u8, arg, "--")) {
            r.positionals = argv[i + 1 ..];
            return r;
        }

        // A bare "-" is a conventional stdin placeholder, not a flag.
        if (arg.len < 2 or arg[0] != '-' or std.mem.eql(u8, arg, "-")) {
            r.positionals = argv[i..];
            return r;
        }

        const is_long = arg[1] == '-';
        const body = if (is_long) arg[2..] else arg[1..];

        // --name=value
        var inline_value: ?[]const u8 = null;
        var name = body;
        if (is_long) {
            if (std.mem.indexOfScalar(u8, body, '=')) |eq| {
                name = body[0..eq];
                inline_value = body[eq + 1 ..];
            }
        }

        const idx = blk: {
            for (spec, 0..) |f, n| {
                if (is_long) {
                    if (f.long) |l| if (std.mem.eql(u8, l, name)) break :blk n;
                } else {
                    if (name.len == 1 and f.short == name[0]) break :blk n;
                }
            }
            r.bad_arg = arg;
            return Error.UnknownFlag;
        };

        r.set[idx] = true;
        if (!spec[idx].takes_value) {
            if (inline_value != null) {
                r.bad_arg = arg;
                return Error.UnknownFlag; // --boolean=x is a mistake, not a value
            }
            continue;
        }

        if (inline_value) |v| {
            r.values[idx] = v;
        } else {
            if (i + 1 >= argv.len) {
                r.bad_arg = arg;
                return Error.MissingValue;
            }
            i += 1;
            r.values[idx] = argv[i];
        }
    }

    return r;
}

/// Render `--help` text into `buf`, returning the used slice.
pub fn renderHelp(spec: []const Flag, usage: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    const put = struct {
        fn f(b: []u8, at: *usize, s: []const u8) void {
            const room = b.len - at.*;
            const take = @min(room, s.len);
            @memcpy(b[at.*..][0..take], s[0..take]);
            at.* += take;
        }
    }.f;

    put(buf, &n, usage);
    put(buf, &n, "\n\n");
    for (spec) |f| {
        var line: [128]u8 = undefined;
        var ln: usize = 0;
        put(&line, &ln, "  ");
        if (f.short) |s| {
            put(&line, &ln, &[_]u8{ '-', s });
            if (f.long != null) put(&line, &ln, ", ");
        } else {
            put(&line, &ln, "    ");
        }
        if (f.long) |l| {
            put(&line, &ln, "--");
            put(&line, &ln, l);
        }
        if (f.takes_value) {
            put(&line, &ln, " ");
            put(&line, &ln, f.value_name);
        }
        // pad to a column so the help text lines up
        while (ln < 30 and ln < line.len) : (ln += 1) line[ln] = ' ';
        put(&line, &ln, f.help);
        put(buf, &n, line[0..ln]);
        put(buf, &n, "\n");
    }
    return buf[0..n];
}

// ============================================================
// Tests
// ============================================================

const test_spec = [_]Flag{
    .{ .short = 'h', .long = "help", .help = "show help" },
    .{ .short = 'v', .long = "version", .help = "show version" },
    .{ .short = 'c', .help = "command", .takes_value = true, .value_name = "CMD" },
    .{ .short = 'd', .long = "debug-log-file", .help = "log file", .takes_value = true },
};

/// Test helper: a literal argv. Named `av` because `argv` would shadow the
/// parameter of `parse`.
fn av(comptime items: []const []const u8) []const []const u8 {
    return items;
}

test "short and long boolean flags" {
    const r = try parse(&test_spec, av(&.{ "zish", "-h" }));
    try std.testing.expect(r.isSet("help"));
    try std.testing.expect(!r.isSet("version"));

    const r2 = try parse(&test_spec, av(&.{ "zish", "--version" }));
    try std.testing.expect(r2.isSet("version"));
}

test "value flags: separate, and --long=value" {
    const r = try parse(&test_spec, av(&.{ "zish", "-c", "echo hi" }));
    try std.testing.expectEqualStrings("echo hi", r.value("c").?);

    const r2 = try parse(&test_spec, av(&.{ "zish", "--debug-log-file=/tmp/l" }));
    try std.testing.expectEqualStrings("/tmp/l", r2.value("debug-log-file").?);

    const r3 = try parse(&test_spec, av(&.{ "zish", "-d", "/tmp/l" }));
    try std.testing.expectEqualStrings("/tmp/l", r3.value("debug-log-file").?);
}

test "first non-option ends option parsing (POSIX)" {
    // `-c` here belongs to the script, not to zish. A parser that keeps
    // scanning would steal it and change what the script receives.
    const r = try parse(&test_spec, av(&.{ "zish", "script.sh", "-c", "arg" }));
    try std.testing.expect(!r.isSet("c"));
    try std.testing.expectEqual(@as(usize, 3), r.positionals.len);
    try std.testing.expectEqualStrings("script.sh", r.positionals[0]);
    try std.testing.expectEqualStrings("-c", r.positionals[1]);
}

test "-- forces the rest positional" {
    const r = try parse(&test_spec, av(&.{ "zish", "--", "-h", "x" }));
    try std.testing.expect(!r.isSet("help"));
    try std.testing.expectEqual(@as(usize, 2), r.positionals.len);
    try std.testing.expectEqualStrings("-h", r.positionals[0]);
}

test "a bare - is positional, not a flag" {
    const r = try parse(&test_spec, av(&.{ "zish", "-" }));
    try std.testing.expectEqual(@as(usize, 1), r.positionals.len);
    try std.testing.expectEqualStrings("-", r.positionals[0]);
}

test "errors: unknown flag and missing value" {
    try std.testing.expectError(Error.UnknownFlag, parse(&test_spec, av(&.{ "zish", "-Z" })));
    try std.testing.expectError(Error.UnknownFlag, parse(&test_spec, av(&.{ "zish", "--nope" })));
    try std.testing.expectError(Error.MissingValue, parse(&test_spec, av(&.{ "zish", "-c" })));
    try std.testing.expectError(Error.UnknownFlag, parse(&test_spec, av(&.{ "zish", "--help=x" })));
}

test "flags after a value are still parsed" {
    const r = try parse(&test_spec, av(&.{ "zish", "-d", "/tmp/l", "-h" }));
    try std.testing.expect(r.isSet("help"));
    try std.testing.expectEqualStrings("/tmp/l", r.value("debug-log-file").?);
}

test "renderHelp lists every flag" {
    var buf: [1024]u8 = undefined;
    const out = renderHelp(&test_spec, "usage: zish [options] [script]", &buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "--help") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "--debug-log-file") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "CMD") != null);
}
