//! feat.zig — the primitives every feat was re-implementing.
//!
//! Feats are standalone binaries (`fork + exec + argv + stdio`), and this is a
//! *source* library: sharing it does not touch the process boundary the feat
//! spec rests on. What it removes is the per-feat copy of the same handful of
//! helpers — which is where the conventions drift, because "stdout is data,
//! stderr is diagnostics, one record per line, exit 2 on a usage error, never
//! block an agent on a terminal" was being remembered once per feat instead of
//! written down once.
//!
//! **Primitives only.** No policy, no configuration, no state, no I/O on behalf
//! of a caller that did not ask. A feat that needs a decision makes it itself.
//!
//! **Zero libc.** Zig 0.16 removed `std.posix.getenv` and
//! `std.process.getEnvVarOwned`, which is the only reason several feats linked
//! libc at all; `env` here reads `/proc/self/environ` instead. zish is
//! Linux-only, so that is not a portability cost.
//!
//! ## How a feat uses this
//!
//! Zig 0.16 confines an import to the *root file's own directory tree*, so
//! `@import("../lib/feat.zig")` cannot work when the build command is
//! `zig build-exe feats/<name>/main.zig` — and a `..` form fails in every mode
//! (local, `-lc`, `-target x86_64-linux-musl`) and under `zig test`. The module
//! flag form (`-Mroot`/`--dep`) compiles but would force every build site,
//! including the shipped `tests/*_test.sh`, to change.
//!
//! So each feat carries a relative symlink and imports through it:
//!
//!     feats/<name>/lib/feat.zig -> ../../lib/feat.zig
//!     const feat = @import("lib/feat.zig");
//!
//! Keep the name exactly `lib/feat.zig`: one convention, verifiable at a glance.
//!
//! Take the full `std.process.Init` and use `init.io` / `init.gpa`. `init.arena`
//! is the right home for values from `env`, so nothing needs freeing.

const std = @import("std");

/// Exit codes the feat convention pins (feat-spec §5): 0 success, 1 general
/// error, 2 usage error. Feats should not invent others.
pub const EXIT_OK: u8 = 0;
pub const EXIT_FAIL: u8 = 1;
pub const EXIT_USAGE: u8 = 2;

/// Cap on a `/proc/self/environ` read: the process's whole environment block.
/// 8 KiB is far past any real one and bounds a hostile case; a larger block is
/// truncated rather than allowed to grow without limit, and a variable whose
/// value sits past the cap reads as unset.
const ENVIRON_CAP = 8 * 1024;

/// The value of environment variable `name`, or null when unset.
///
/// The environment is already in this process's memory as a NUL-separated
/// block, so it is read from `/proc/self/environ` rather than through
/// `std.c.environ` — one lookup is not worth linking libc for. The caller owns
/// the returned slice.
pub fn env(alloc: std.mem.Allocator, io: std.Io, name: []const u8) ?[]u8 {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '=') != null) return null;
    const file = std.Io.Dir.openFileAbsolute(io, "/proc/self/environ", .{}) catch return null;
    defer file.close(io);

    var buf: [ENVIRON_CAP]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = file.readStreaming(io, &.{buf[len..]}) catch break;
        if (n == 0) break;
        len += n;
    }

    var entries = std.mem.splitScalar(u8, buf[0..len], 0);
    while (entries.next()) |entry| {
        if (entry.len <= name.len) continue;
        if (entry[name.len] != '=') continue;
        if (!std.mem.startsWith(u8, entry, name)) continue;
        return alloc.dupe(u8, entry[name.len + 1 ..]) catch null;
    }
    return null;
}

/// Everything on stdin, read to EOF. Caller owns the slice.
pub fn slurpStdin(alloc: std.mem.Allocator, io: std.Io) ![]u8 {
    _ = io;
    var cap: usize = 8192;
    var buf = try alloc.alloc(u8, cap);
    errdefer alloc.free(buf);
    var len: usize = 0;
    while (true) {
        if (len == cap) {
            cap *= 2;
            buf = try alloc.realloc(buf, cap);
        }
        const n = try std.posix.read(0, buf[len..]);
        if (n == 0) break;
        len += n;
    }
    return buf[0..len];
}

/// Whether stdin is a terminal.
///
/// A feat that would otherwise read stdin must check this: an agent running it
/// with no pipe and no redirect would otherwise block forever on a prompt
/// nobody can answer. Fail closed — an unreadable stdin is treated as a tty.
pub fn stdinIsTty(io: std.Io) bool {
    return std.Io.File.stdin().isTty(io) catch true;
}

/// Write `bytes` to stdout, once. Returns false if the write failed.
pub fn out(io: std.Io, bytes: []const u8) bool {
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch return false;
    return true;
}

/// Write `bytes` to stderr, once. Diagnostics only — never data.
pub fn err(io: std.Io, bytes: []const u8) bool {
    std.Io.File.stderr().writeStreamingAll(io, bytes) catch return false;
    return true;
}

/// `out` with formatting, into a stack buffer. Terse output is the norm, so a
/// fixed buffer is the right shape; anything longer should be assembled by the
/// caller.
pub fn print(io: std.Io, comptime fmt: []const u8, args: anytype) bool {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return false;
    return out(io, s);
}

/// `err` with formatting.
pub fn eprint(io: std.Io, comptime fmt: []const u8, args: anytype) bool {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return false;
    return err(io, s);
}

/// Append `s` to `b` as the *contents* of a JSON string: quotes and backslashes
/// escaped, control bytes as `\u00XX`, so the result never contains a raw
/// newline or ESC. Callers add the surrounding quotes.
pub fn jsonEscape(b: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try b.appendSlice(alloc, "\\\""),
        '\\' => try b.appendSlice(alloc, "\\\\"),
        '\n' => try b.appendSlice(alloc, "\\n"),
        '\r' => try b.appendSlice(alloc, "\\r"),
        '\t' => try b.appendSlice(alloc, "\\t"),
        // 0x00-0x1F MUST be escaped (RFC 8259). \t \n \r have short forms above;
        // everything else in the range is \u00XX — including 0x08 (\b), which an
        // off-by-one here previously passed through raw and produced invalid JSON.
        0...8, 11, 12, 14...31 => {
            var ub: [8]u8 = undefined;
            try b.appendSlice(alloc, std.fmt.bufPrint(&ub, "\\u{x:0>4}", .{c}) catch "\\u0000");
        },
        else => try b.append(alloc, c),
    };
}

/// Create `path` exclusively and write `bytes` in one go. Returns error.PathAlreadyExists
/// when it exists — which is what makes this an atomic publish: two writers
/// racing produce one winner, never a half-written record or an interleaved one.
/// A caller that needs uniqueness in the name supplies it.
pub fn publish(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{
        .exclusive = true,
        .permissions = .fromMode(0o600),
    });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

/// A whole file, with a default cap so no caller has to pick one.
pub fn readFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(limit));
}
