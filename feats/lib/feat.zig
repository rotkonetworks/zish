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
/// nobody can answer. Fail closed — an unreadable stdin is treated as a tty,
/// because "I could not ask" must not become "I blocked".
pub fn stdinIsTty(io: std.Io) bool {
    return std.Io.File.stdin().isTty(io) catch true;
}

/// Whether `fd` is a terminal. Errors read as "not a terminal" (a closed fd, or
/// an fd that is not a tty), which is what a caller asking about an output or an
/// arbitrary descriptor wants.
///
/// Deliberately separate from `stdinIsTty`, which fails *closed*: the two
/// disagree on failure, and that disagreement is the point. A feat about to read
/// stdin must treat "unknown" as a terminal; a feat choosing pager-vs-help on a
/// closed stdin — as `aur` does — must treat it as not one.
pub fn isTty(fd: std.posix.fd_t) bool {
    var t: std.os.linux.termios = undefined;
    return @as(isize, @bitCast(std.os.linux.tcgetattr(fd, &t))) == 0;
}

/// Restore SIGPIPE to its default disposition: die on a closed stdout.
///
/// Full `std.process.Init` installs a no-op SIGPIPE handler, because its io
/// layer reports EPIPE rather than taking the signal. For a CLI filter that is a
/// behaviour change — `feat ... | head -c1` then exits 0 where the same feat
/// built against libc exits 141, and the producer keeps writing into a pipe
/// nobody is reading. Feats are filters, so they want the traditional
/// disposition; call this once at the top of `main`.
pub fn restoreSigpipe() void {
    var dfl: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.PIPE, &dfl, null);
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

// ---------------------------------------------------------------------------
// feat data files — the rubrics and prompt data a feat reads at runtime
//
// These belong to the feat that reads them, not to the repo root and not to one
// shared `~/.zish/rubrics` directory: a rubric IS that feat's data, and it has
// exactly one consumer. Keeping them in the feat directory is also what makes
// them *travel* — the same directory is staged into the registry whatever built
// it (`make feats`, the AUR package, a `gf install`), so a feat's data reaches a
// fresh machine with no extra root to search and nothing in $HOME.
// ---------------------------------------------------------------------------

/// This process's own executable path (no trailing NUL), from /proc/self/exe.
/// Null when it cannot be read, or when it was truncated — a truncated path is
/// not this binary.
pub fn selfExe(buf: []u8) ?[]const u8 {
    const rc: isize = @bitCast(std.os.linux.readlink("/proc/self/exe", buf.ptr, buf.len));
    if (rc <= 0) return null;
    const n: usize = @intCast(rc);
    if (n >= buf.len) return null;
    return buf[0..n];
}

/// Whether `path` names something that exists. Symlinks are not followed, so a
/// dangling link reads as absent.
pub fn fileExists(path: []const u8) bool {
    var z: [4096]u8 = undefined;
    const p = zPath(&z, path) orelse return false;
    var stx: std.os.linux.Statx = undefined;
    const rc = std.os.linux.statx(std.os.linux.AT.FDCWD, p, std.os.linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &stx);
    return @as(isize, @bitCast(rc)) == 0;
}

/// NUL-terminate `s` into `z` for the raw syscalls above. Null if it does not fit.
fn zPath(z: []u8, s: []const u8) ?[*:0]const u8 {
    if (s.len >= z.len) return null;
    @memcpy(z[0..s.len], s);
    z[s.len] = 0;
    return @ptrCast(z.ptr);
}

/// Resolve a data file that ships with the feat reading it — `name` is a bare
/// filename, e.g. `lenses.toml`.
///
/// First hit wins:
///
///   1. `$ZISH_RUBRIC_DIR/<name>` — an explicit override. When set it is the
///      ONLY place searched, so a caller that names a directory gets that
///      directory or nothing (the rule `ZISH_FEAT_PATH` already has for feats).
///   2. `$HOME/.zish/rubrics/<name>` — the user's own copy, which overrides the
///      shipped one, exactly as a user feat shadows a shipped feat.
///   3. `<featdir>/rubrics/<name>` — shipped beside the binary. `<featdir>` comes
///      from /proc/self/exe (`<featdir>/bin/<feat>`), so this works identically
///      for a user-root feat and a system-root one.
///
/// Returns a path into `buf`, or null when the file is nowhere.
pub fn rubricFile(alloc: std.mem.Allocator, io: std.Io, buf: []u8, name: []const u8) ?[]const u8 {
    if (env(alloc, io, "ZISH_RUBRIC_DIR")) |d| {
        defer alloc.free(d);
        const p = std.fmt.bufPrint(buf, "{s}/{s}", .{ d, name }) catch return null;
        return if (fileExists(p)) p else null;
    }
    if (env(alloc, io, "HOME")) |home| {
        defer alloc.free(home);
        if (std.fmt.bufPrint(buf, "{s}/.zish/rubrics/{s}", .{ home, name })) |p| {
            if (fileExists(p)) return p;
        } else |_| {}
    }
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = selfExe(&exe_buf) orelse return null;
    const bindir = std.fs.path.dirname(exe) orelse return null;
    const featdir = std.fs.path.dirname(bindir) orelse return null;
    const p = std.fmt.bufPrint(buf, "{s}/rubrics/{s}", .{ featdir, name }) catch return null;
    return if (fileExists(p)) p else null;
}
