//! ask — pose a question to the human and BLOCK until they answer in the
//! dashboard (or any client of the ask queue). A reusable interaction primitive:
//! a script or another feat (team, an agent loop) calls it to get a human
//! decision mid-run, routed to the browser.
//!
//!   ask "Deploy to prod?" "Yes" "No" "Only staging" "Abort"   # up to 4 options
//!   ask "What should the service be called?"                   # open-ended (free text)
//!   ask -t 60 "Proceed?" "Yes" "No"                            # 60s timeout
//!
//! Protocol (file-based, matches zish's file-shaped org state): writes the
//! question to ~/.zish/asks/<id>.json, then polls for ~/.zish/asks/<id>.answer.
//! For multiple choice the answer file holds the chosen 0-based INDEX; ask prints
//! that option's text. With -m (checkbox) it holds comma-separated indices and
//! ask prints each chosen option on its own line, in the order given, deduped.
//! Anything that is not a valid index (a typed "Other" answer) is echoed
//! verbatim. For an open question it holds free text, printed as-is.
//! Exit 0 = answered (answer on stdout), 3 = timed out, 2 = usage, 128+signal if interrupted.
//!
//! Herdr: when running inside a Herdr pane (HERDR_ENV=1 with HERDR_PANE_ID and
//! HERDR_BIN_PATH set) ask also reports the pane as `blocked` with the question
//! as the message, so the sidebar lights it up like an agent permission prompt —
//! including on remote machines. The report is released on every exit path
//! (answer, timeout, SIGINT/SIGTERM). It is best-effort: the reporter child gets
//! /dev/null for all three fds so it can never pollute the answer on stdout, and
//! a hung Herdr socket is killed after a bound instead of delaying the ask.
//! Herdr keeps one hook authority per pane, last writer wins; releasing hands
//! the pane back to screen detection or the previous integration's next report.

const std = @import("std");
const linux = std.os.linux;
const feat = @import("lib/feat.zig");
const alloc = std.heap.page_allocator;

const MAX = 1 << 20;
const POLL_MS = 200;
const DEFAULT_TIMEOUT_S: u64 = 300;

fn toZ(buf: []u8, s: []const u8) ?[*:0]const u8 {
    if (s.len >= buf.len) return null;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return @ptrCast(buf.ptr);
}
fn writeFd(fd: i32, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n: isize = @bitCast(linux.write(fd, bytes.ptr + off, bytes.len - off));
        if (n <= 0) return;
        off += @intCast(n);
    }
}
fn out(b: []const u8) void {
    writeFd(1, b);
}
fn warn(b: []const u8) void {
    writeFd(2, b);
}
fn slurp(fd: i32, cap: usize) []u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var tmp: [65536]u8 = undefined;
    while (buf.items.len < cap) {
        const n: isize = @bitCast(linux.read(fd, &tmp, tmp.len));
        if (n <= 0) break;
        buf.appendSlice(alloc, tmp[0..@intCast(n)]) catch break;
    }
    return buf.toOwnedSlice(alloc) catch &.{};
}
fn readFileAlloc(path: []const u8) ?[]u8 {
    var z: [4096]u8 = undefined;
    const p = toZ(&z, path) orelse return null;
    const fd: isize = @bitCast(linux.open(p, .{ .ACCMODE = .RDONLY }, 0));
    if (fd < 0) return null;
    defer _ = linux.close(@intCast(fd));
    return slurp(@intCast(fd), MAX);
}
fn writeFileTrunc(path: []const u8, bytes: []const u8) bool {
    var z: [4096]u8 = undefined;
    const p = toZ(&z, path) orelse return false;
    const fd: isize = @bitCast(linux.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600));
    if (fd < 0) return false;
    defer _ = linux.close(@intCast(fd));
    writeFd(@intCast(fd), bytes);
    return true;
}
fn unlinkPath(path: []const u8) void {
    var z: [4096]u8 = undefined;
    if (toZ(&z, path)) |p| _ = linux.unlink(p);
}
fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
}

// ---------------------------------------------------------------------------
// Herdr lifecycle reporting (best-effort, never blocks the ask)
// ---------------------------------------------------------------------------

const HERDR_SOURCE = "custom:zish-ask";
const HERDR_AGENT = "ask";
const HERDR_MESSAGE_CAP = 200;
const HERDR_REPORT_WAIT_MS: u64 = 5000;

/// Which signal interrupted us (0 = none). Atomic: written from a handler,
/// read in the poll loop; a plain global could legally be hoisted in ReleaseFast.
var interrupted_by = std.atomic.Value(u32).init(0);

fn interrupted() bool {
    return interrupted_by.load(.acquire) != 0;
}

fn onSignal(sig: linux.SIG) callconv(.c) void {
    interrupted_by.store(@intFromEnum(sig), .release);
}

/// SIGINT/SIGTERM only set a flag: nanosleep returns EINTR, the poll loop sees
/// the flag and returns normally, so the defers (unlink + herdr release) run.
fn installSignalHandlers() void {
    const act = linux.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = 0,
    };
    _ = linux.sigaction(linux.SIG.INT, &act, null);
    _ = linux.sigaction(linux.SIG.TERM, &act, null);
}

const HerdrPane = struct {
    bin: []const u8,
    pane: []const u8,

    /// Present only when Herdr says so AND both handles are non-empty.
    fn detect(init: std.process.Init) ?HerdrPane {
        // The shared primitive hands back allocated values; the process arena
        // owns them, so they live exactly as long as the environ memory they
        // replaced.
        const arena = init.arena.allocator();
        const env = feat.env(arena, init.io, "HERDR_ENV") orelse return null;
        if (!std.mem.eql(u8, env, "1")) return null;
        const bin = feat.env(arena, init.io, "HERDR_BIN_PATH") orelse return null;
        const pane = feat.env(arena, init.io, "HERDR_PANE_ID") orelse return null;
        if (bin.len == 0 or pane.len == 0) return null;
        return .{ .bin = bin, .pane = pane };
    }

    fn reportBlocked(self: HerdrPane, init: std.process.Init, question: []const u8) void {
        var msg: [HERDR_MESSAGE_CAP + 1]u8 = undefined;
        const m = sidebarMessage(&msg, question);
        self.exec(init, &.{ "pane", "report-agent", self.pane, "--source", HERDR_SOURCE, "--agent", HERDR_AGENT, "--state", "blocked", "--message", m });
    }

    fn release(self: HerdrPane, init: std.process.Init) void {
        self.exec(init, &.{ "pane", "release-agent", self.pane, "--source", HERDR_SOURCE, "--agent", HERDR_AGENT });
    }

    /// fork+execve(bin, argv), the reporter inheriting our environment, all
    /// three fds on /dev/null, reaped within HERDR_REPORT_WAIT_MS or killed.
    /// Every failure is silently ignored: the report is a courtesy to the
    /// sidebar, the ask itself must still work.
    fn exec(self: HerdrPane, init: std.process.Init, args: []const []const u8) void {
        var zbuf: [8192]u8 = undefined;
        var argv: [16:null]?[*:0]const u8 = undefined;
        if (args.len + 1 >= argv.len) return;
        var off: usize = 0;
        argv[0] = zAt(&zbuf, &off, self.bin) orelse return;
        for (args, 1..) |a, i| argv[i] = zAt(&zbuf, &off, a) orelse return;
        argv[args.len + 1] = null;
        var binz: [4096]u8 = undefined;
        const bin = toZ(&binz, self.bin) orelse return;

        const pid: isize = @bitCast(linux.fork());
        if (pid < 0) return;
        if (pid == 0) {
            const devnull: isize = @bitCast(linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0));
            if (devnull >= 0) {
                _ = linux.dup2(@intCast(devnull), 0);
                _ = linux.dup2(@intCast(devnull), 1);
                _ = linux.dup2(@intCast(devnull), 2);
                if (devnull > 2) _ = linux.close(@intCast(devnull));
            }
            // The reporter inherits this process's environment block, taken
            // from the startup data Zig already holds — no libc environ needed.
            _ = linux.execve(bin, &argv, init.minimal.environ.block.slice.ptr);
            linux.exit(127);
        }
        const deadline = nowNs() + HERDR_REPORT_WAIT_MS * 1_000_000;
        var status: u32 = 0;
        while (true) {
            const rc: isize = @bitCast(linux.waitpid(@intCast(pid), &status, linux.W.NOHANG));
            if (rc == pid) return;
            if (rc < 0 and linux.errno(@as(usize, @bitCast(rc))) != .INTR) return;
            if (nowNs() >= deadline) break;
            var ts: linux.timespec = .{ .sec = 0, .nsec = 20 * 1_000_000 };
            _ = linux.nanosleep(&ts, &ts);
        }
        _ = linux.kill(@intCast(pid), linux.SIG.KILL);
        _ = linux.waitpid(@intCast(pid), &status, 0);
    }
};

/// Copy `s` NUL-terminated into `buf` at `*off`, bumping the offset.
fn zAt(buf: []u8, off: *usize, s: []const u8) ?[*:0]const u8 {
    if (off.* + s.len + 1 > buf.len) return null;
    const start = off.*;
    @memcpy(buf[start .. start + s.len], s);
    buf[start + s.len] = 0;
    off.* = start + s.len + 1;
    return @ptrCast(buf.ptr + start);
}

/// The question, capped to HERDR_MESSAGE_CAP bytes at a UTF-8 boundary, with
/// control bytes flattened to spaces: it is headed for a sidebar, not a terminal.
fn sidebarMessage(buf: []u8, q: []const u8) []const u8 {
    var n: usize = 0;
    for (q) |c| {
        if (n >= HERDR_MESSAGE_CAP) break;
        buf[n] = if (c < 0x20 or c == 0x7f) ' ' else c;
        n += 1;
    }
    // don't split a multibyte sequence: back off over continuation bytes
    if (n < q.len) while (n > 0 and (buf[n - 1] & 0xC0) == 0x80) : (n -= 1) {};
    if (n < q.len and n > 0 and buf[n - 1] >= 0xC0) n -= 1;
    return buf[0..n];
}

/// JSON-escape into `o`.
fn jsonEsc(o: *std.ArrayListUnmanaged(u8), s: []const u8) void {
    for (s) |c| switch (c) {
        '"' => o.appendSlice(alloc, "\\\"") catch {},
        '\\' => o.appendSlice(alloc, "\\\\") catch {},
        '\n' => o.appendSlice(alloc, "\\n") catch {},
        '\r' => {},
        '\t' => o.appendSlice(alloc, "\\t") catch {},
        else => if (c >= 0x20) (o.append(alloc, c) catch {}),
    };
}

pub fn main(init: std.process.Init) u8 {
    // Full Init installs a no-op SIGPIPE handler; a filter must die on a closed
    // stdout like every other CLI, so restore the default before doing anything.
    feat.restoreSigpipe();
    return run(init);
}

fn run(init: std.process.Init) u8 {
    var it = init.minimal.args.iterate();
    _ = it.next(); // argv[0]

    var timeout_s: u64 = DEFAULT_TIMEOUT_S;
    var multi = false; // allow choosing several options (answer = comma-sep indices)
    var question: ?[]const u8 = null;
    var options: std.ArrayListUnmanaged([]const u8) = .empty;
    defer options.deinit(alloc);

    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            warn("usage: ask [-t <seconds>] [-m] \"<question>\" [\"opt1\" ... \"opt4\"]\n");
            return 0;
        }
        if (std.mem.eql(u8, a, "-t")) {
            const v = it.next() orelse return usageErr();
            timeout_s = std.fmt.parseInt(u64, v, 10) catch return usageErr();
            continue;
        }
        if (std.mem.eql(u8, a, "-m") or std.mem.eql(u8, a, "--multi")) {
            multi = true;
            continue;
        }
        if (question == null) {
            question = a;
        } else {
            if (options.items.len >= 4) {
                warn("ask: at most 4 options\n");
                return 2;
            }
            options.append(alloc, a) catch {};
        }
    }
    const q = question orelse return usageErr();
    if (options.items.len == 1) {
        warn("ask: give 0 (open) or 2-4 options\n");
        return 2;
    }
    if (multi and options.items.len == 0) {
        warn("ask: -m needs options to choose from\n");
        return 2;
    }

    const home = feat.env(init.arena.allocator(), init.io, "HOME") orelse {
        warn("ask: HOME unset\n");
        return 2;
    };
    // ensure ~/.zish/asks
    {
        var db: [4096]u8 = undefined;
        if (std.fmt.bufPrint(&db, "{s}/.zish", .{home})) |d| {
            var z: [4096]u8 = undefined;
            if (toZ(&z, d)) |p| _ = linux.mkdir(p, 0o700);
        } else |_| {}
        if (std.fmt.bufPrint(&db, "{s}/.zish/asks", .{home})) |d| {
            var z: [4096]u8 = undefined;
            if (toZ(&z, d)) |p| _ = linux.mkdir(p, 0o700);
        } else |_| {}
    }

    const id = std.fmt.allocPrint(alloc, "{d}-{d}", .{ linux.getpid(), nowNs() }) catch return 2;
    defer alloc.free(id);
    const qpath = std.fmt.allocPrint(alloc, "{s}/.zish/asks/{s}.json", .{ home, id }) catch return 2;
    defer alloc.free(qpath);
    const apath = std.fmt.allocPrint(alloc, "{s}/.zish/asks/{s}.answer", .{ home, id }) catch return 2;
    defer alloc.free(apath);

    // write the question record
    {
        var j: std.ArrayListUnmanaged(u8) = .empty;
        defer j.deinit(alloc);
        j.appendSlice(alloc, "{\"id\":\"") catch {};
        jsonEsc(&j, id);
        j.appendSlice(alloc, "\",\"q\":\"") catch {};
        jsonEsc(&j, q);
        j.appendSlice(alloc, "\",\"options\":[") catch {};
        for (options.items, 0..) |opt, i| {
            if (i > 0) j.append(alloc, ',') catch {};
            j.append(alloc, '"') catch {};
            jsonEsc(&j, opt);
            j.append(alloc, '"') catch {};
        }
        j.appendSlice(alloc, if (multi) "],\"multi\":true}" else "],\"multi\":false}") catch {};
        if (!writeFileTrunc(qpath, j.items)) {
            warn("ask: cannot write question\n");
            return 2;
        }
    }
    defer unlinkPath(qpath);
    defer unlinkPath(apath);

    // handlers first: a signal during the (bounded) report must still release
    installSignalHandlers();

    // surface the question in Herdr's sidebar; released on every exit path
    const herdr = HerdrPane.detect(init);
    if (herdr) |h| h.reportBlocked(init, q);
    defer if (herdr) |h| h.release(init);

    // block, polling for the answer file
    const deadline = nowNs() + timeout_s *% 1_000_000_000;
    while (nowNs() < deadline and !interrupted()) {
        if (readFileAlloc(apath)) |raw| {
            defer alloc.free(raw);
            const ans = std.mem.trim(u8, raw, " \t\r\n");
            if (ans.len == 0) {
                // written but empty; keep waiting a beat
            } else if (options.items.len == 0) {
                out(ans); // open question — free text
                out("\n");
                return 0;
            } else if (multi) {
                // checkbox: "0,2" -> the chosen options, one per line
                if (!printChecked(ans, options.items)) out(ans);
                out("\n");
                return 0;
            } else {
                // MC: a plain in-range index prints that option; anything else
                // (an "Other" custom answer, or an out-of-range number) is echoed
                // verbatim — so a choice question always accepts a typed answer too.
                if (std.fmt.parseInt(usize, ans, 10)) |idx| {
                    if (idx < options.items.len) {
                        out(options.items[idx]);
                        out("\n");
                        return 0;
                    }
                } else |_| {}
                out(ans);
                out("\n");
                return 0;
            }
        }
        var ts: linux.timespec = .{ .sec = 0, .nsec = POLL_MS * 1_000_000 };
        _ = linux.nanosleep(&ts, &ts);
    }
    const sig = interrupted_by.load(.acquire);
    if (sig != 0) {
        warn("ask: interrupted\n");
        return @intCast(128 + (sig & 0x7f));
    }
    warn("ask: timed out with no answer\n");
    return 3;
}

/// Checkbox answer: comma-separated 0-based indices. Prints each chosen option
/// on its own line (order as given, duplicates dropped) and returns true.
/// Returns false without printing when any token is not an in-range index, so
/// the caller can echo the raw answer (a typed "Other") verbatim instead.
fn printChecked(ans: []const u8, options: []const []const u8) bool {
    var picked: [4]usize = undefined;
    const n = parseChecked(ans, options, &picked) orelse return false;
    for (picked[0..n], 0..) |idx, i| {
        if (i > 0) out("\n");
        out(options[idx]);
    }
    return true;
}

/// The picks in `ans` ("2, 0,2") as indices into `options`, deduped, in input
/// order. Null when the answer is empty, out of range, or malformed.
///
/// Pure on purpose: deciding the picks and WRITING them are separate concerns,
/// and the write side owns fd 1. A test that exercised the printing version
/// wrote into fd 1 — which, under `zig build test`, is the test runner's own
/// protocol, so the writes corrupted the handshake and the runner reported a
/// bogus "zig version mismatch". The verdict is what needs testing; the output
/// is a loop.
fn parseChecked(ans: []const u8, options: []const []const u8, picked: *[4]usize) ?usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, ans, ',');
    while (it.next()) |tok| {
        const t = std.mem.trim(u8, tok, " \t");
        if (t.len == 0) return null;
        const idx = std.fmt.parseInt(usize, t, 10) catch return null;
        if (idx >= options.len) return null;
        var dup = false;
        for (picked[0..n]) |p| dup = dup or p == idx;
        if (dup) continue;
        if (n >= picked.len) return null;
        picked[n] = idx;
        n += 1;
    }
    if (n == 0) return null;
    return n;
}

test "parseChecked accepts in-range comma lists and rejects anything else" {
    const opts = [_][]const u8{ "a", "b", "c" };
    var picked: [4]usize = undefined;
    // The verdict only. Parsing is separate from printing precisely so this
    // test never writes to fd 1 — that is the runner's protocol under
    // `zig build test`.
    try std.testing.expect(parseChecked("0", &opts, &picked).? == 1);
    try std.testing.expect(parseChecked("2, 0,2", &opts, &picked).? == 2); // dedup
    try std.testing.expect(parseChecked("0,2", &opts, &picked).? == 2);
    try std.testing.expect(parseChecked("", &opts, &picked) == null);
    try std.testing.expect(parseChecked("3", &opts, &picked) == null);
    try std.testing.expect(parseChecked("0,", &opts, &picked) == null);
    try std.testing.expect(parseChecked("0,x", &opts, &picked) == null);
    try std.testing.expect(parseChecked("something else", &opts, &picked) == null);
}

fn usageErr() u8 {
    warn("usage: ask [-t <seconds>] [-m] \"<question>\" [\"opt1\" ... \"opt4\"]\n");
    return 2;
}
