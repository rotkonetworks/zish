//! aurev — the PKGBUILD reviewer, shaped as a pager.
//!
//! `yay` pipes PKGBUILD diffs to `$PAGER` for you to review before it builds.
//! A pager is a stdin→stdout filter, so aurev *is* a pager: set
//! `PAGER=aurev` (or yay's pager config) and every pending AUR update gets
//! agent-reviewed inside your normal `yay -Syu` flow, no fork of yay needed.
//!
//! Flow: slurp the diff on stdin → judge it (agent --judge + the
//! pkgbuild-review rubric) → print a verdict header → then print the diff
//! itself, so it still works as a pager and you still see the change and
//! decide. Advisory on your own machine: aurev flags, you choose.
//!
//! FAIL-OPEN by construction. A pager must never break yay's flow, and the
//! review is advice, not a gate: if the agent feat is missing, the key is
//! absent, the model is down, or the verdict is malformed, aurev prints a note
//! and the raw diff and exits 0. Worst case you fall back to eyeballing it —
//! the status quo. (This is the deliberate inverse of the shell's fail-closed
//! security posture: there, a missing guarantee refuses to run; here, missing
//! *advice* must not stop you seeing your own diff.)
//!
//! aurev is the SECOND caller of the `agent --judge` primitive (after gf's
//! review-on-install), which is the proof the judge generalizes: same binary,
//! a different rubric, a different subject, zero new protocol.

const std = @import("std");
const linux = std.os.linux;
const alloc = std.heap.page_allocator;

const MAX_INPUT = 16 * 1024 * 1024; // a diff larger than this is not human-reviewable anyway
const RUBRIC = "pkgbuild-review-v1";

// ---------------------------------------------------------------------------
// syscall plumbing (feats are standalone binaries; helpers are self-contained)
// ---------------------------------------------------------------------------

fn getEnv(name: [:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name.ptr) orelse return null;
    return std.mem.span(v);
}

fn toZ(buf: []u8, s: []const u8) ?[*:0]const u8 {
    if (s.len >= buf.len) return null;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return @ptrCast(buf.ptr);
}

fn writeFd(fd: i32, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        const n: isize = @bitCast(rc);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

fn out(bytes: []const u8) void {
    writeFd(1, bytes);
}

fn warn(bytes: []const u8) void {
    writeFd(2, bytes);
}

fn isTty(fd: i32) bool {
    var t: std.c.termios = undefined;
    return std.c.tcgetattr(fd, &t) == 0;
}

/// Read all of a file descriptor into memory, capped.
fn slurp(fd: i32, cap: usize) []u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var tmp: [65536]u8 = undefined;
    while (buf.items.len < cap) {
        const rc = linux.read(fd, &tmp, tmp.len);
        const n: isize = @bitCast(rc);
        if (n <= 0) break;
        buf.appendSlice(alloc, tmp[0..@intCast(n)]) catch break;
    }
    return buf.toOwnedSlice(alloc) catch &.{};
}

fn readFileAlloc(path: []const u8, cap: usize) ?[]u8 {
    var z: [4096]u8 = undefined;
    const p = toZ(&z, path) orelse return null;
    const fd_rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    const fd: isize = @bitCast(fd_rc);
    if (fd < 0) return null;
    defer _ = linux.close(@intCast(fd));
    const data = slurp(@intCast(fd), cap);
    return data;
}

fn writeFile(path: []const u8, bytes: []const u8, mode: u32) bool {
    var z: [4096]u8 = undefined;
    const p = toZ(&z, path) orelse return false;
    const fd_rc = linux.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, mode);
    const fd: isize = @bitCast(fd_rc);
    if (fd < 0) return false;
    defer _ = linux.close(@intCast(fd));
    writeFd(@intCast(fd), bytes);
    return true;
}

fn unlinkPath(path: []const u8) void {
    var z: [4096]u8 = undefined;
    const p = toZ(&z, path) orelse return;
    _ = linux.unlink(p);
}

fn lstatMode(path: []const u8) ?u32 {
    var z: [4096]u8 = undefined;
    const p = toZ(&z, path) orelse return null;
    var stx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, p, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &stx);
    if (@as(isize, @bitCast(rc)) != 0) return null;
    return stx.mode;
}

fn nowSeconds() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @intCast(ts.sec);
}

/// fork+exec via /usr/bin/env, capturing stdout; null on spawn failure or
/// non-zero exit.
fn execCapture(argv: [*:null]const ?[*:0]const u8) ?[]u8 {
    var fds: [2]i32 = undefined;
    if (@as(isize, @bitCast(linux.pipe2(&fds, .{}))) < 0) return null;
    const pid_rc = linux.fork();
    const pid: isize = @bitCast(pid_rc);
    if (pid < 0) {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        return null;
    }
    if (pid == 0) {
        _ = linux.close(fds[0]);
        _ = linux.dup2(fds[1], 1);
        _ = linux.close(fds[1]);
        _ = linux.execve("/usr/bin/env", argv, @ptrCast(std.c.environ));
        linux.exit(127);
    }
    _ = linux.close(fds[1]);
    const data = slurp(fds[0], MAX_INPUT);
    _ = linux.close(fds[0]);
    var status: u32 = 0;
    _ = linux.waitpid(@intCast(pid), &status, 0);
    if ((status & 0x7f) != 0 or ((status >> 8) & 0xff) != 0) {
        alloc.free(data);
        return null;
    }
    return data;
}

fn sha256File(path: []const u8) ?[]const u8 {
    var z: [4096]u8 = undefined;
    const p = toZ(&z, path) orelse return null;
    const argv = [_:null]?[*:0]const u8{ "env", "sha256sum", "--", p, null };
    const o = execCapture(&argv) orelse return null;
    if (o.len < 64) return null;
    for (o[0..64]) |c| if (!std.ascii.isHex(c)) return null;
    return o[0..64];
}

fn appendJsonStr(o: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try o.appendSlice(alloc, "\\\""),
        '\\' => try o.appendSlice(alloc, "\\\\"),
        else => if (c >= 0x20) try o.append(alloc, c),
    };
}

fn objStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    const o = switch (v) {
        .object => |ob| ob,
        else => return null,
    };
    return switch (o.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// path resolution — same rules as gf/zish
// ---------------------------------------------------------------------------

fn featRootPath(buf: []u8) ?[]const u8 {
    if (getEnv("ZISH_FEAT_PATH")) |p| return p;
    const home = getEnv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.zish/feats", .{home}) catch null;
}

fn resolveAgentBin(root: []const u8, buf: []u8) ?[]const u8 {
    for ([_][]const u8{ "standard", "extra" }) |tier| {
        const p = std.fmt.bufPrint(buf, "{s}/{s}/agent/bin/agent", .{ root, tier }) catch continue;
        if (lstatMode(p) != null) return p;
    }
    return null;
}

fn resolveRubric(buf: []u8) ?[]const u8 {
    if (getEnv("ZISH_RUBRIC_DIR")) |d| {
        const p = std.fmt.bufPrint(buf, "{s}/{s}.toml", .{ d, RUBRIC }) catch return null;
        return if (lstatMode(p) != null) p else null;
    }
    const home = getEnv("HOME") orelse return null;
    const p = std.fmt.bufPrint(buf, "{s}/.zish/rubrics/{s}.toml", .{ home, RUBRIC }) catch return null;
    return if (lstatMode(p) != null) p else null;
}

/// aurev keeps its OWN ledger (AUR reviews, not feat installs): a review record
/// per PKGBUILD content hash. This is the "read others' reviews" substrate — a
/// prior verdict for the same bytes is found here (and, once ledgers sync,
/// someone else's verdict for the same bytes appears here too).
fn ledgerPath(buf: []u8) ?[]const u8 {
    const home = getEnv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.zish/aurev.jsonl", .{home}) catch null;
}

// ---------------------------------------------------------------------------
// rendering
// ---------------------------------------------------------------------------

const C = struct {
    const reset = "\x1b[0m";
    const dim = "\x1b[2m";
    const bold = "\x1b[1m";
    const green = "\x1b[32m";
    const red = "\x1b[31m";
    const yellow = "\x1b[33m";
};

fn colorize() bool {
    return isTty(1);
}

/// Print the verdict header above the diff. `cached` marks a prior verdict for
/// the same bytes (read from the ledger) rather than a fresh review.
fn printHeader(verdict_raw: []const u8, cached: bool) void {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, verdict_raw, .{}) catch {
        return;
    };
    defer parsed.deinit();
    const verdict = objStr(parsed.value, "verdict") orelse "unknown";
    const analysis = objStr(parsed.value, "analysis") orelse "";
    const col = colorize();

    var b: std.ArrayListUnmanaged(u8) = .empty;
    defer b.deinit(alloc);
    const rule = "\xe2\x94\x81" ** 3; // ━━━
    b.appendSlice(alloc, if (col) C.dim else "") catch {};
    b.appendSlice(alloc, rule) catch {};
    b.appendSlice(alloc, " aurev") catch {};
    if (cached) b.appendSlice(alloc, " (cached)") catch {};
    b.appendSlice(alloc, " " ++ rule) catch {};
    b.appendSlice(alloc, if (col) C.reset else "") catch {};
    b.appendSlice(alloc, "\n  verdict: ") catch {};
    if (std.mem.eql(u8, verdict, "pass")) {
        b.appendSlice(alloc, if (col) C.green ++ C.bold else "") catch {};
        b.appendSlice(alloc, "PASS") catch {};
    } else if (std.mem.eql(u8, verdict, "fail")) {
        b.appendSlice(alloc, if (col) C.red ++ C.bold else "") catch {};
        b.appendSlice(alloc, "FAIL \xe2\x80\x94 review the diff carefully") catch {};
    } else {
        b.appendSlice(alloc, if (col) C.yellow else "") catch {};
        b.appendSlice(alloc, verdict) catch {};
    }
    b.appendSlice(alloc, if (col) C.reset else "") catch {};
    b.appendSlice(alloc, "\n") catch {};

    // scores line
    if (switch (parsed.value) {
        .object => |ob| ob.get("scores"),
        else => null,
    }) |sc| {
        if (sc == .object) {
            b.appendSlice(alloc, "  scores: ") catch {};
            var it = sc.object.iterator();
            var first = true;
            while (it.next()) |e| {
                if (!first) b.appendSlice(alloc, "  ") catch {};
                first = false;
                b.appendSlice(alloc, e.key_ptr.*) catch {};
                b.appendSlice(alloc, " ") catch {};
                const n: i64 = switch (e.value_ptr.*) {
                    .integer => |iv| iv,
                    else => -1,
                };
                var nb: [8]u8 = undefined;
                b.appendSlice(alloc, std.fmt.bufPrint(&nb, "{d}/10", .{n}) catch "?") catch {};
            }
            b.appendSlice(alloc, "\n") catch {};
        }
    }

    // analysis, wrapped-ish (just indent; the pager handles width)
    if (analysis.len > 0) {
        b.appendSlice(alloc, if (col) C.dim else "") catch {};
        b.appendSlice(alloc, "  ") catch {};
        for (analysis) |ch| {
            b.append(alloc, ch) catch {};
            if (ch == '\n') b.appendSlice(alloc, "  ") catch {};
        }
        b.appendSlice(alloc, if (col) C.reset else "") catch {};
        b.appendSlice(alloc, "\n") catch {};
    }
    b.appendSlice(alloc, if (col) C.dim else "") catch {};
    b.appendSlice(alloc, rule ++ rule ++ rule ++ "\n") catch {};
    b.appendSlice(alloc, if (col) C.reset else "") catch {};
    out(b.items);
}

// ---------------------------------------------------------------------------
// ledger
// ---------------------------------------------------------------------------

/// A prior verdict for this sha, if one is recorded. Returns the raw verdict
/// JSON (the "result" field) so it can be rendered identically to a fresh one.
fn findCached(sha: []const u8) ?[]u8 {
    var lb: [4096]u8 = undefined;
    const lp = ledgerPath(&lb) orelse return null;
    const content = readFileAlloc(lp, 16 * 1024 * 1024) orelse return null;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |ln| {
        const line = std.mem.trim(u8, ln, " \t\r");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        const rsha = objStr(parsed.value, "sha256") orelse {
            parsed.deinit();
            continue;
        };
        if (std.mem.eql(u8, rsha, sha)) {
            const res = objStr(parsed.value, "result") orelse {
                parsed.deinit();
                continue;
            };
            const dup = alloc.dupe(u8, res) catch null;
            parsed.deinit();
            return dup;
        }
        parsed.deinit();
    }
    return null;
}

fn recordReview(sha: []const u8, verdict_word: []const u8, verdict_raw: []const u8) void {
    const model = getEnv("ZISH_JUDGE_MODEL") orelse "deepseek/deepseek-v4-flash-0731";
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(alloc);
    line.appendSlice(alloc, "{\"t\":\"review\",\"kind\":\"pkgbuild\",\"sha256\":\"") catch return;
    appendJsonStr(&line, sha) catch return;
    line.appendSlice(alloc, "\",\"rubric\":\"" ++ RUBRIC ++ "\",\"reviewer\":\"") catch return;
    appendJsonStr(&line, model) catch return;
    line.appendSlice(alloc, "\",\"verdict\":\"") catch return;
    appendJsonStr(&line, verdict_word) catch return;
    line.appendSlice(alloc, "\",\"sig\":\"\",\"result\":\"") catch return;
    appendJsonStr(&line, verdict_raw) catch return;
    var tb: [32]u8 = undefined;
    line.appendSlice(alloc, std.fmt.bufPrint(&tb, "\",\"ts\":{d}}}\n", .{nowSeconds()}) catch return) catch return;

    var lb: [4096]u8 = undefined;
    const lp = ledgerPath(&lb) orelse return;
    var z: [4096]u8 = undefined;
    const p = toZ(&z, lp) orelse return;
    const fd_rc = linux.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o600);
    const fd: isize = @bitCast(fd_rc);
    if (fd < 0) return;
    defer _ = linux.close(@intCast(fd));
    writeFd(@intCast(fd), line.items);
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

pub fn main() void {
    linux.exit(run());
}

fn run() u8 {
    const input = slurp(0, MAX_INPUT);
    if (input.len == 0) return 0; // nothing piped in — nothing to do

    // Everything from here is best-effort review; the diff is ALWAYS printed
    // at the end. `defer` guarantees fail-open.
    var reviewed = false;
    defer {
        if (!reviewed) {
            warn("aurev: review unavailable, showing raw diff\n");
        }
        out(input);
    }

    var rootb: [4096]u8 = undefined;
    const root = featRootPath(&rootb) orelse return 0;
    var agentb: [4096]u8 = undefined;
    const agent_bin = resolveAgentBin(root, &agentb) orelse return 0;
    var rubb: [4096]u8 = undefined;
    const rubric = resolveRubric(&rubb) orelse return 0;

    // subject temp file + its content hash (the join key for the ledger)
    const home = getEnv("HOME") orelse return 0;
    var subjb: [4096]u8 = undefined;
    const subj = std.fmt.bufPrint(&subjb, "{s}/.zish/.aurev_subj_{d}", .{ home, linux.getpid() }) catch return 0;
    if (!writeFile(subj, input, 0o600)) return 0;
    defer unlinkPath(subj);
    const sha = sha256File(subj) orelse "";

    // read side: a prior verdict for these exact bytes (yours, or later a
    // shared reviewer's) — show it instead of paying for a re-review.
    if (sha.len > 0) {
        if (findCached(sha)) |cached| {
            defer alloc.free(cached);
            printHeader(cached, true);
            reviewed = true;
            return 0;
        }
    }

    // fresh review: agent --judge <rubric> <subject>
    var argv: [12]?[*:0]const u8 = undefined;
    var held: [12][]u8 = undefined;
    var nh: usize = 0;
    var n: usize = 0;
    const push = struct {
        fn z(s: []const u8, h: [][]u8, nhp: *usize) ?[*:0]const u8 {
            const dz = alloc.dupeZ(u8, s) catch return null;
            h[nhp.*] = dz;
            nhp.* += 1;
            return dz.ptr;
        }
    }.z;
    argv[n] = push("env", &held, &nh) orelse return 0;
    n += 1;
    argv[n] = push(agent_bin, &held, &nh) orelse return 0;
    n += 1;
    if (getEnv("ZISH_JUDGE_MOCK")) |m| {
        argv[n] = push("--mock", &held, &nh) orelse return 0;
        n += 1;
        argv[n] = push(m, &held, &nh) orelse return 0;
        n += 1;
    }
    argv[n] = push("--judge", &held, &nh) orelse return 0;
    n += 1;
    argv[n] = push(rubric, &held, &nh) orelse return 0;
    n += 1;
    argv[n] = push(subj, &held, &nh) orelse return 0;
    n += 1;
    argv[n] = null;
    const argvz: [*:null]const ?[*:0]const u8 = argv[0..n :null];

    const verdict = execCapture(argvz) orelse return 0;
    defer alloc.free(verdict);
    if (verdict.len == 0 or verdict[0] != '{') return 0;

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, verdict, .{}) catch return 0;
    const word = objStr(parsed.value, "verdict") orelse "unknown";
    printHeader(verdict, false);
    if (sha.len > 0) recordReview(sha, word, verdict);
    parsed.deinit();
    reviewed = true;
    return 0;
}
