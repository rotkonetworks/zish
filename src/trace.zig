//! Structured session trace — one JSON record per top-level command.
//!
//! A harness driving zish should never have to parse ANSI escapes, prompt
//! redraws or history replay to find out what happened. It opens a file
//! descriptor, and zish writes it a machine-readable record per command:
//!
//!     zish -c 'make test' 3>trace.jsonl
//!     {"ts":1785303570123,"cmd":"make test","cwd":"/src","exit":0,"ms":842}
//!
//! Design notes
//!
//! **Off unless asked for.** The trace fd is probed once at startup with
//! fstat. If it is not open, every call here is a branch on a bool. There is
//! no config file, no flag, and nothing to disable — a harness that wants the
//! trace opens the fd, and one that doesn't, doesn't.
//!
//! **A separate fd, never stdout.** stdout belongs to the command being run.
//! Multiplexing structured data onto it is exactly the ANSI-soup problem this
//! exists to avoid.
//!
//! **Top-level commands only.** `executeCommand` recurses for command
//! substitution and PROMPT_COMMAND; recording those would bury the command the
//! user or agent actually ran under its own internals. The caller passes depth.
//!
//! **Best-effort.** A failed write is dropped. The trace must never be able to
//! break or block the shell — if the harness stops reading, the shell keeps
//! working.
//!
//! Not recorded yet: bytes written to stdout/stderr. Counting them means
//! interposing on the command's output, which changes isatty() answers and
//! breaks interactive programs. That needs a real pty story, not a byte
//! counter, so it is deliberately absent rather than half-done.

const std = @import("std");
const compat = @import("compat.zig");

/// Default descriptor. 3 is the first fd past stdio, and the conventional
/// "extra channel" a parent opens for a child. Override with ZISH_TRACE_FD.
const default_fd: i32 = 3;

var trace_fd: ?i32 = null;
var probed = false;

/// Probe for a trace descriptor. Call once, from main, before anything runs.
pub fn init() void {
    if (probed) return;
    probed = true;

    var fd: i32 = default_fd;
    if (compat.posix.getenv("ZISH_TRACE_FD")) |s| {
        fd = std.fmt.parseInt(i32, s, 10) catch return;
        // Refusing stdio here is not paranoia: `ZISH_TRACE_FD=1` would
        // interleave JSON into the command's own output, which is precisely
        // the failure this module exists to prevent.
        if (fd <= 2) return;
    }

    // fstat fails with EBADF when the descriptor was never opened, which is
    // the common case — no harness, no trace.
    _ = compat.posix.fstat(fd) catch return;
    trace_fd = fd;
}

pub fn enabled() bool {
    return trace_fd != null;
}

/// Append `s` to `out` as the body of a JSON string (no surrounding quotes).
///
/// Command lines are arbitrary bytes, not guaranteed UTF-8, so anything that
/// would produce invalid JSON is replaced rather than passed through: a
/// harness parsing this must never hit a decode error because someone typed a
/// stray 0x80.
fn escapeJson(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    const valid = std.unicode.utf8ValidateSlice(s);
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => {
                if (c < 0x20) {
                    var buf: [6]u8 = undefined;
                    const esc = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch continue;
                    try out.appendSlice(alloc, esc);
                } else if (c < 0x80 or valid) {
                    try out.append(alloc, c);
                } else {
                    // Non-UTF-8 byte in a non-UTF-8 string: emit U+FFFD.
                    try out.appendSlice(alloc, "\u{FFFD}");
                }
            },
        }
    }
}

/// Write one record. Silently does nothing when tracing is off.
pub fn record(
    alloc: std.mem.Allocator,
    cmd: []const u8,
    cwd: []const u8,
    exit_code: u8,
    start_ms: i64,
    end_ms: i64,
) void {
    const fd = trace_fd orelse return;

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);

    var num: [24]u8 = undefined;
    const int = struct {
        fn put(l: *std.ArrayList(u8), a: std.mem.Allocator, b: []u8, v: i64) !void {
            try l.appendSlice(a, std.fmt.bufPrint(b, "{d}", .{v}) catch "0");
        }
    }.put;

    line.appendSlice(alloc, "{\"ts\":") catch return;
    int(&line, alloc, &num, start_ms) catch return;
    line.appendSlice(alloc, ",\"cmd\":\"") catch return;
    escapeJson(&line, alloc, cmd) catch return;
    line.appendSlice(alloc, "\",\"cwd\":\"") catch return;
    escapeJson(&line, alloc, cwd) catch return;
    line.appendSlice(alloc, "\",\"exit\":") catch return;
    int(&line, alloc, &num, exit_code) catch return;
    line.appendSlice(alloc, ",\"ms\":") catch return;
    int(&line, alloc, &num, end_ms - start_ms) catch return;
    line.appendSlice(alloc, "}\n") catch return;

    // One write per record keeps lines atomic up to PIPE_BUF, so a harness
    // reading concurrently never sees a torn record. Failures are dropped:
    // a dead harness must not take the shell with it.
    var off: usize = 0;
    while (off < line.items.len) {
        const n = compat.posix.write(fd, line.items[off..]) catch return;
        if (n == 0) return;
        off += n;
    }
}

// ============================================================
// Tests
// ============================================================

test "escapeJson: quotes, backslashes and control bytes" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try escapeJson(&out, alloc, "echo \"hi\"\\ \n\t");
    try std.testing.expectEqualStrings("echo \\\"hi\\\"\\\\ \\n\\t", out.items);
}

test "escapeJson: invalid UTF-8 becomes U+FFFD" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    // 0x80 is a bare continuation byte — not valid on its own.
    try escapeJson(&out, alloc, "a\x80b");
    try std.testing.expectEqualStrings("a\u{FFFD}b", out.items);
}

test "escapeJson: valid UTF-8 passes through" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try escapeJson(&out, alloc, "echo äö→");
    try std.testing.expectEqualStrings("echo äö→", out.items);
}

test "record: no-op when tracing is disabled" {
    // trace_fd is null in the test binary (fd 3 is not a trace sink), so this
    // must not write anywhere or crash.
    record(std.testing.allocator, "echo hi", "/tmp", 0, 100, 142);
}
