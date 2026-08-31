//! gf — the feat fetcher: `gf <url>` downloads a feat tarball and installs it
//! into the EXTRA tier, quarantined by construction.
//!
//! This is the bottom layer of the feat distribution story (and of the later
//! agentic package manager): fetch → validate → stage. Trust decisions stay
//! with the human (or, later, a reviewer agent): everything gf installs lands
//! in `extra/`, where zish runs it with a stripped environment, refuses it as
//! root, and (for session feats) masks off the run/prompt hostcalls.
//! Promotion to `standard/` is a deliberate `mv` by someone with authority,
//! never gf's call.
//!
//! Tarball format: feat.toml and bin/<name> at the TOP level (what
//! `make dist-agent` produces). The archive is adversarial input:
//!   - the extracted tree is validated by lstat walk — regular files only,
//!     no symlinks anywhere (a symlinked bin/ member is the classic
//!     install-path attack), nothing outside feat.toml + bin/
//!   - manifest name/bin fields are charset-checked before they ever join a
//!     path (gf builds install paths itself; `../standard/x` in a name would
//!     otherwise be a tier escape)
//!   - the manifest's tier line is rewritten to "extra" so file and location
//!     never disagree (the directory is authoritative, but a lying manifest
//!     must not linger for a future reader)
//!   - a name that collides with anything on PATH is refused (dispatch-time
//!     no-shadowing already makes such a feat inert; refusing at install is
//!     the honest UX)
//!   - download and extraction happen in a temp dir INSIDE the feat root, so
//!     the final rename() into extra/<name> is atomic on one filesystem
//!
//! No upgrade in v1: an existing install is refused, remove it first.
//!
//! Source packages (format v2): a tarball may ship src/<file> instead of
//! bin/<name>, plus declarative build fields in the manifest:
//!     lang = "c" | "zig"      src = "main.c"      libc = "true" (zig only)
//! gf then compiles it locally with a FIXED template (zig cc -O2 / zig
//! build-exe -OReleaseFast) — the recipe is data, never code: a publisher
//! gets no build-time execution (the AUR's PKGBUILD hole, closed by
//! construction). Distributing source is what makes review-on-install
//! meaningful: reviewers read what was actually shipped, and the binary
//! trusted is the one built here from the hashed source.

const std = @import("std");
const linux = std.os.linux;

const alloc = std.heap.page_allocator;

const MAX_ARCHIVE = 64 * 1024 * 1024; // download size cap
const MAX_MANIFEST = 64 * 1024;
const MAX_NAME = 32;

// ===========================================================================
// pure helpers (unit-tested)
// ===========================================================================

/// A feat name / bin field must be safe to embed in a path gf constructs:
/// lowercase alnum plus - and _, starting alnum, length-capped. Anything else
/// (slashes, dots, "..") is refused before it touches a path.
fn validName(s: []const u8) bool {
    if (s.len == 0 or s.len > MAX_NAME) return false;
    if (!std.ascii.isAlphanumeric(s[0])) return false;
    for (s) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-' or c == '_')) return false;
    }
    return true;
}

/// The value of `key = "value"` on its own line, or null — same terse,
/// hostile-input semantics as zish's featManifestField (unknown fields are
/// ignored, never parsed).
fn manifestField(content: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, key)) continue;
        const after = line[key.len..];
        const eq = std.mem.indexOfScalar(u8, after, '=') orelse continue;
        if (std.mem.trim(u8, after[0..eq], " \t").len != 0) continue;
        const rest = std.mem.trim(u8, after[eq + 1 ..], " \t");
        if (rest.len < 2 or rest[0] != '"') continue;
        const end = std.mem.indexOfScalar(u8, rest[1..], '"') orelse continue;
        return rest[1 .. end + 1];
    }
    return null;
}

/// Rewrite the manifest so its tier line reads "extra" — replacing an existing
/// tier line, or appending one if the manifest had none.
fn forceExtraTier(content: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var wrote_tier = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var first = true;
    while (lines.next()) |raw| {
        if (!first) try out.append(alloc, '\n');
        first = false;
        const line = std.mem.trim(u8, raw, " \t\r");
        const is_tier = std.mem.startsWith(u8, line, "tier") and blk: {
            const after = line[4..];
            const eq = std.mem.indexOfScalar(u8, after, '=') orelse break :blk false;
            break :blk std.mem.trim(u8, after[0..eq], " \t").len == 0;
        };
        if (is_tier) {
            try out.appendSlice(alloc, "tier = \"extra\"");
            wrote_tier = true;
        } else {
            try out.appendSlice(alloc, raw);
        }
    }
    if (!wrote_tier) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(alloc, '\n');
        try out.appendSlice(alloc, "tier = \"extra\"\n");
    }
    return out.toOwnedSlice(alloc);
}

test "validName accepts feat names, rejects path escapes" {
    try std.testing.expect(validName("median"));
    try std.testing.expect(validName("my-feat_2"));
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName("../standard/x"));
    try std.testing.expect(!validName("a/b"));
    try std.testing.expect(!validName(".hidden"));
    try std.testing.expect(!validName("UPPER"));
    try std.testing.expect(!validName("a" ** 33));
}

test "manifestField extracts quoted values only" {
    const m = "name = \"calc\"\ntier = \"standard\"\nbin = \"calc\"\n";
    try std.testing.expectEqualStrings("calc", manifestField(m, "name").?);
    try std.testing.expectEqualStrings("standard", manifestField(m, "tier").?);
    try std.testing.expect(manifestField(m, "kind") == null);
    try std.testing.expect(manifestField("name = unquoted\n", "name") == null);
}

test "forceExtraTier rewrites or appends the tier line" {
    const a = try forceExtraTier("name = \"x\"\ntier = \"standard\"\nbin = \"x\"\n");
    try std.testing.expect(std.mem.indexOf(u8, a, "tier = \"extra\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "standard") == null);
    const b = try forceExtraTier("name = \"x\"\nbin = \"x\"\n");
    try std.testing.expect(std.mem.indexOf(u8, b, "tier = \"extra\"") != null);
}

// ===========================================================================
// syscall plumbing
// ===========================================================================

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

fn fail(comptime fmt: []const u8, args: anytype) u8 {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "gf: " ++ fmt ++ "\n", args) catch return 1;
    _ = linux.write(2, msg.ptr, msg.len);
    return 1;
}

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = linux.write(1, msg.ptr, msg.len);
}

/// fork+exec via /usr/bin/env, inherit stdio, return the child's exit code
/// (255 on spawn/abnormal-exit).
fn execStatus(argv: [*:null]const ?[*:0]const u8) u8 {
    const pid_rc = linux.fork();
    const pid: isize = @bitCast(pid_rc);
    if (pid < 0) return 255;
    if (pid == 0) {
        _ = linux.execve("/usr/bin/env", argv, @ptrCast(std.c.environ));
        linux.exit(127);
    }
    var status: u32 = 0;
    _ = linux.waitpid(@intCast(pid), &status, 0);
    if ((status & 0x7f) != 0) return 255;
    return @truncate((status >> 8) & 0xff);
}

fn mkdirP(path: []const u8) void {
    var z: [4096]u8 = undefined;
    const p = toZ(&z, path) orelse return;
    _ = linux.mkdir(p, 0o700);
}

// statx with SYMLINK_NOFOLLOW == lstat: the mode must describe the entry
// itself, never a symlink target.
fn lstatx(path: []const u8) ?linux.Statx {
    var z: [4096]u8 = undefined;
    const p = toZ(&z, path) orelse return null;
    var stx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, p, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .SIZE = true }, &stx);
    if (@as(isize, @bitCast(rc)) != 0) return null;
    return stx;
}

fn lstatMode(path: []const u8) ?u32 {
    const stx = lstatx(path) orelse return null;
    return stx.mode;
}

fn fileSize(path: []const u8) ?u64 {
    const stx = lstatx(path) orelse return null;
    return stx.size;
}

fn readFileAlloc(path: []const u8, cap: usize) ?[]u8 {
    var z: [4096]u8 = undefined;
    const p = toZ(&z, path) orelse return null;
    const fd_rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    const fd: isize = @bitCast(fd_rc);
    if (fd < 0) return null;
    defer _ = linux.close(@intCast(fd));
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var tmp: [4096]u8 = undefined;
    while (buf.items.len <= cap) {
        const rc = linux.read(@intCast(fd), &tmp, tmp.len);
        const n: isize = @bitCast(rc);
        if (n <= 0) break;
        buf.appendSlice(alloc, tmp[0..@intCast(n)]) catch return null;
    }
    if (buf.items.len > cap) return null;
    return buf.toOwnedSlice(alloc) catch null;
}

fn writeFile(path: []const u8, bytes: []const u8, mode: u32) bool {
    var z: [4096]u8 = undefined;
    const p = toZ(&z, path) orelse return false;
    const fd_rc = linux.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, mode);
    const fd: isize = @bitCast(fd_rc);
    if (fd < 0) return false;
    defer _ = linux.close(@intCast(fd));
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(@intCast(fd), bytes.ptr + off, bytes.len - off);
        const n: isize = @bitCast(rc);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

/// fork+exec via /usr/bin/env, capturing stdout (for sha256sum). Returns null
/// on spawn failure or non-zero exit.
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
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var tmp: [4096]u8 = undefined;
    while (true) {
        const rc = linux.read(fds[0], &tmp, tmp.len);
        const n: isize = @bitCast(rc);
        if (n <= 0) break;
        buf.appendSlice(alloc, tmp[0..@intCast(n)]) catch break;
    }
    _ = linux.close(fds[0]);
    var status: u32 = 0;
    _ = linux.waitpid(@intCast(pid), &status, 0);
    if ((status & 0x7f) != 0 or ((status >> 8) & 0xff) != 0) return null;
    return buf.toOwnedSlice(alloc) catch null;
}

/// sha256 of a file, as 64 hex chars, via sha256sum.
fn sha256File(path: []const u8) ?[]const u8 {
    var z: [4096]u8 = undefined;
    const p = toZ(&z, path) orelse return null;
    const argv = [_:null]?[*:0]const u8{ "env", "sha256sum", "--", p, null };
    const out = execCapture(&argv) orelse return null;
    if (out.len < 64) return null;
    for (out[0..64]) |c| {
        if (!std.ascii.isHex(c)) return null;
    }
    return out[0..64];
}

fn rmRf(path: []const u8) void {
    var z: [4096]u8 = undefined;
    const p = toZ(&z, path) orelse return;
    const argv = [_:null]?[*:0]const u8{ "env", "rm", "-rf", "--", p, null };
    _ = execStatus(&argv);
}

// ===========================================================================
// install ledger — the seed of the distributed reputation system
// ===========================================================================

fn nowSeconds() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @intCast(ts.sec);
}

/// Append a JSON string with minimal escaping (quotes, backslash; control
/// bytes dropped — ledger lines must stay single-line valid JSON).
fn appendJsonStr(out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        else => if (c >= 0x20) try out.append(alloc, c),
    };
}

/// Append one install event to <root>/ledger.jsonl: what was installed, from
/// where, hashed as what, when. Append-only by contract — this is the local
/// end of the broadcast/review/reputation pipeline (a review verdict for the
/// same sha lands beside it later; a feed/chain replicates it later still).
/// Best-effort: a failed ledger write never fails the install, but is noted.
fn ledgerAppend(root: []const u8, name: []const u8, url: []const u8, sha: []const u8) void {
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(alloc);
    line.appendSlice(alloc, "{\"t\":\"install\",\"name\":\"") catch return;
    appendJsonStr(&line, name) catch return;
    line.appendSlice(alloc, "\",\"sha256\":\"") catch return;
    appendJsonStr(&line, sha) catch return;
    line.appendSlice(alloc, "\",\"url\":\"") catch return;
    appendJsonStr(&line, url) catch return;
    var tsbuf: [32]u8 = undefined;
    const ts = std.fmt.bufPrint(&tsbuf, "\",\"ts\":{d}}}\n", .{nowSeconds()}) catch return;
    line.appendSlice(alloc, ts) catch return;

    var pbuf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "{s}/ledger.jsonl", .{root}) catch return;
    var z: [4096]u8 = undefined;
    const p = toZ(&z, path) orelse return;
    const fd_rc = linux.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o600);
    const fd: isize = @bitCast(fd_rc);
    if (fd < 0) {
        print("gf: warning: could not write ledger\n", .{});
        return;
    }
    defer _ = linux.close(@intCast(fd));
    var off: usize = 0;
    while (off < line.items.len) {
        const rc = linux.write(@intCast(fd), line.items.ptr + off, line.items.len - off);
        const n: isize = @bitCast(rc);
        if (n <= 0) break;
        off += @intCast(n);
    }
}

test "appendJsonStr escapes quotes and drops control bytes" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try appendJsonStr(&out, "a\"b\\c\x1bd");
    try std.testing.expectEqualStrings("a\\\"b\\\\cd", out.items);
}

// ===========================================================================
// review-on-install — install, then have the agent feat judge the source and
// append the verdict beside the install event. DECOUPLED from install
// success: no agent feat / no key / model down / malformed output is a loud
// note and NO verdict record, never a failed or partial install. Advisory in
// the dictator era, by design. Binary packages are skipped (reviewing a
// binary is worthless — this is why source packages exist).
// ===========================================================================

fn objStr2(v: std.json.Value, key: []const u8) ?[]const u8 {
    const o = switch (v) {
        .object => |ob| ob,
        else => return null,
    };
    return switch (o.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// Resolve the installed agent feat's binary: standard tier first, then extra.
fn resolveAgentBin(root: []const u8, buf: []u8) ?[]const u8 {
    for ([_][]const u8{ "standard", "extra" }) |tier| {
        const p = std.fmt.bufPrint(buf, "{s}/{s}/agent/bin/agent", .{ root, tier }) catch continue;
        if (lstatMode(p) != null) return p;
    }
    return null;
}

/// The review rubric path: $ZISH_RUBRIC_DIR/feat-review-v1.toml, else
/// $HOME/.zish/rubrics/feat-review-v1.toml.
fn resolveRubric(buf: []u8) ?[]const u8 {
    if (getEnv("ZISH_RUBRIC_DIR")) |d| {
        const p = std.fmt.bufPrint(buf, "{s}/feat-review-v1.toml", .{d}) catch return null;
        if (lstatMode(p) != null) return p;
        return null;
    }
    const home = getEnv("HOME") orelse return null;
    const p = std.fmt.bufPrint(buf, "{s}/.zish/rubrics/feat-review-v1.toml", .{home}) catch return null;
    if (lstatMode(p) != null) return p;
    return null;
}

/// Append a review verdict to the ledger, joined to the install by sha256.
/// The bare pass/fail is lifted to top level for greppability; the full
/// verdict object rides along as an escaped string under "result".
fn reviewLedgerAppend(root: []const u8, sha: []const u8, verdict_word: []const u8, verdict_raw: []const u8) void {
    const model = getEnv("ZISH_JUDGE_MODEL") orelse "deepseek/deepseek-v4-flash-0731";
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(alloc);
    line.appendSlice(alloc, "{\"t\":\"review\",\"sha256\":\"") catch return;
    appendJsonStr(&line, sha) catch return;
    line.appendSlice(alloc, "\",\"rubric\":\"feat-review-v1\",\"reviewer\":\"") catch return;
    appendJsonStr(&line, model) catch return;
    line.appendSlice(alloc, "\",\"verdict\":\"") catch return;
    appendJsonStr(&line, verdict_word) catch return;
    line.appendSlice(alloc, "\",\"sig\":\"\",\"result\":\"") catch return;
    appendJsonStr(&line, verdict_raw) catch return;
    var tsbuf: [32]u8 = undefined;
    const ts = std.fmt.bufPrint(&tsbuf, "\",\"ts\":{d}}}\n", .{nowSeconds()}) catch return;
    line.appendSlice(alloc, ts) catch return;

    var pbuf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "{s}/ledger.jsonl", .{root}) catch return;
    var z: [4096]u8 = undefined;
    const p = toZ(&z, path) orelse return;
    const fd_rc = linux.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o600);
    const fd: isize = @bitCast(fd_rc);
    if (fd < 0) return;
    defer _ = linux.close(@intCast(fd));
    var off: usize = 0;
    while (off < line.items.len) {
        const rc = linux.write(@intCast(fd), line.items.ptr + off, line.items.len - off);
        const n: isize = @bitCast(rc);
        if (n <= 0) break;
        off += @intCast(n);
    }
}

/// Exec `agent --judge` on the installed source and append the verdict. All
/// failure paths are loud notes that leave the install intact and unreviewed.
fn reviewInstalled(root: []const u8, dest: []const u8, name: []const u8, sha: []const u8) void {
    var sbuf: [4096]u8 = undefined;
    const src_dir = std.fmt.bufPrint(&sbuf, "{s}/src", .{dest}) catch return;
    if (lstatMode(src_dir) == null) {
        print("gf: {s} is a binary package; skipping source review\n", .{name});
        return;
    }
    var abuf: [4096]u8 = undefined;
    const agent_bin = resolveAgentBin(root, &abuf) orelse {
        print("gf: no agent feat installed; install it to enable review-on-install\n", .{});
        return;
    };
    var rbuf: [4096]u8 = undefined;
    const rubric = resolveRubric(&rbuf) orelse {
        print("gf: no review rubric found; skipping review\n", .{});
        return;
    };
    var mfbuf: [4096]u8 = undefined;
    const manifest = std.fmt.bufPrint(&mfbuf, "{s}/feat.toml", .{dest}) catch return;

    // argv: env agent [--mock M] --judge rubric dest/feat.toml dest/src/<each>
    var argv: [128]?[*:0]const u8 = undefined;
    var held: [128][]u8 = undefined; // own the z-dupes until exec
    var nheld: usize = 0;
    var n: usize = 0;
    const push = struct {
        fn z(s: []const u8, held_: [][]u8, nheld_: *usize) ?[*:0]const u8 {
            const dz = alloc.dupeZ(u8, s) catch return null;
            held_[nheld_.*] = dz;
            nheld_.* += 1;
            return dz.ptr;
        }
    }.z;
    argv[n] = push("env", &held, &nheld) orelse return;
    n += 1;
    argv[n] = push(agent_bin, &held, &nheld) orelse return;
    n += 1;
    if (getEnv("ZISH_JUDGE_MOCK")) |m| {
        argv[n] = push("--mock", &held, &nheld) orelse return;
        n += 1;
        argv[n] = push(m, &held, &nheld) orelse return;
        n += 1;
    }
    argv[n] = push("--judge", &held, &nheld) orelse return;
    n += 1;
    argv[n] = push(rubric, &held, &nheld) orelse return;
    n += 1;
    argv[n] = push(manifest, &held, &nheld) orelse return;
    n += 1;
    // each source file (bounded)
    var names_buf: [64][]u8 = undefined;
    if (listDir(src_dir, &names_buf)) |srcs| {
        for (srcs) |sname| {
            if (n >= argv.len - 1) break;
            var fb: [4096]u8 = undefined;
            const fp = std.fmt.bufPrint(&fb, "{s}/src/{s}", .{ dest, sname }) catch continue;
            argv[n] = push(fp, &held, &nheld) orelse continue;
            n += 1;
        }
    }
    argv[n] = null;
    const argv_z: [*:null]const ?[*:0]const u8 = argv[0..n :null];

    const out = execCapture(argv_z) orelse {
        print("gf: review produced no verdict; {s} stands installed but unreviewed\n", .{name});
        return;
    };
    if (out.len == 0 or out[0] != '{') {
        print("gf: review output was not a verdict; {s} stands unreviewed\n", .{name});
        return;
    }
    // agent already validated shape; re-parse to lift the bare verdict word
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, out, .{}) catch {
        print("gf: review verdict did not parse; {s} stands unreviewed\n", .{name});
        return;
    };
    defer parsed.deinit();
    const word = objStr2(parsed.value, "verdict") orelse "unknown";
    reviewLedgerAppend(root, sha, word, out);
    print("gf: reviewed {s}: verdict {s} (recorded in ledger)\n", .{ name, word });
}

// ===========================================================================
// validation of the extracted tree
// ===========================================================================

const S_IFMT: u32 = 0o170000;
const S_IFREG: u32 = 0o100000;
const S_IFDIR: u32 = 0o040000;

/// Enforce the exact allowed shape. The archive is either a BINARY package
/// (feat.toml + bin/<bin_name>) or a SOURCE package (feat.toml + src/<member>).
/// Exactly one of bin/ or src/ may be present; the payload dir holds only
/// regular files (lstat catches symlinks — the install-path attack); nothing
/// else lives at top level. Returns null on pass, a message on refusal.
/// `member` is the required file inside the payload dir (bin_name for binary,
/// the manifest's src for source).
fn validateTree(tmp: []const u8, payload_dir: []const u8, member: []const u8) ?[]const u8 {
    var pbuf: [4096]u8 = undefined;

    const mf = std.fmt.bufPrint(&pbuf, "{s}/feat.toml", .{tmp}) catch return "path too long";
    const mf_mode = lstatMode(mf) orelse return "archive has no feat.toml";
    if (mf_mode & S_IFMT != S_IFREG) return "feat.toml is not a regular file";

    var dbuf: [4096]u8 = undefined;
    const dir = std.fmt.bufPrint(&dbuf, "{s}/{s}", .{ tmp, payload_dir }) catch return "path too long";
    const d_mode = lstatMode(dir) orelse return "archive is missing its payload directory";
    if (d_mode & S_IFMT != S_IFDIR) return "payload path is not a directory";

    // top level: nothing but feat.toml and the one payload dir
    var names_buf: [64][]u8 = undefined;
    const top = listDir(tmp, &names_buf) orelse return "cannot open archive dir";
    for (top) |n| {
        if (std.mem.eql(u8, n, "feat.toml") or std.mem.eql(u8, n, payload_dir)) continue;
        return "archive contains files outside feat.toml + payload dir";
    }

    // payload dir: regular files only (lstat: a symlink here is the attack)
    var found = false;
    var mnames_buf: [64][]u8 = undefined;
    const members = listDir(dir, &mnames_buf) orelse return "cannot open payload dir";
    for (members) |n| {
        var fbuf: [4096]u8 = undefined;
        const fp = std.fmt.bufPrint(&fbuf, "{s}/{s}", .{ dir, n }) catch return "path too long";
        const m = lstatMode(fp) orelse return "unreadable payload file";
        if (m & S_IFMT != S_IFREG) return "payload contains a non-regular file (symlink?)";
        if (std.mem.eql(u8, n, member)) found = true;
    }
    if (!found) return "payload does not contain the required member";
    return null;
}

/// List a directory's entries (skipping . and ..) via libc opendir/readdir.
/// Names are duped into `alloc`; more than names.len entries fails closed
/// (null) — a legitimate feat archive is tiny.
fn listDir(path: []const u8, names: [][]u8) ?[][]u8 {
    var z: [4096]u8 = undefined;
    const p = toZ(&z, path) orelse return null;
    const d = std.c.opendir(p) orelse return null;
    defer _ = std.c.closedir(d);
    var n: usize = 0;
    while (std.c.readdir(d)) |ent| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.name)));
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (n >= names.len) return null; // absurdly large archive: fail closed
        names[n] = alloc.dupe(u8, name) catch return null;
        n += 1;
    }
    return names[0..n];
}

/// A source filename gf will embed in a build command: like validName but
/// allows one dot for the extension (main.c, agent.zig). Still no slashes, no
/// "..", so it can never escape the src/ dir.
fn validSrcName(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    if (!std.ascii.isAlphanumeric(s[0])) return false;
    var dots: usize = 0;
    for (s) |c| {
        if (c == '.') {
            dots += 1;
        } else if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-' or c == '_')) {
            return false;
        }
    }
    return dots <= 1;
}

/// Compile src/<src_file> to bin/<bin_name> inside the temp tree with a FIXED
/// template — the manifest chooses lang/libc, never the command. Returns null
/// on success, a message on refusal or build failure. Everything here is data
/// gf controls; the publisher's only inputs are the (charset-checked) filename
/// and the source itself, which is what reviewers read.
fn buildSource(tmp: []const u8, lang: []const u8, src_file: []const u8, bin_name: []const u8, want_libc: bool) ?[]const u8 {
    var sbuf: [4096]u8 = undefined;
    var obuf: [4096]u8 = undefined;
    const src_path = std.fmt.bufPrint(&sbuf, "{s}/src/{s}", .{ tmp, src_file }) catch return "path too long";
    const bin_dir = std.fmt.bufPrint(&obuf, "{s}/bin", .{tmp}) catch return "path too long";
    mkdirP(bin_dir);
    var pbuf: [4096]u8 = undefined;
    const out_path = std.fmt.bufPrint(&pbuf, "{s}/bin/{s}", .{ tmp, bin_name }) catch return "path too long";

    var sz: [4096]u8 = undefined;
    var oz: [4096]u8 = undefined;
    const sp = toZ(&sz, src_path) orelse return "path too long";
    const op = toZ(&oz, out_path) orelse return "path too long";
    var emit_buf: [4096]u8 = undefined;
    const emit = std.fmt.bufPrintZ(&emit_buf, "-femit-bin={s}", .{out_path}) catch return "path too long";

    var st: u8 = 255;
    if (std.mem.eql(u8, lang, "c")) {
        // zig cc: -O2, static-ish, output binary. libc flag is irrelevant (cc
        // links libc anyway); we ignore it for C.
        const argv = [_:null]?[*:0]const u8{ "env", "zig", "cc", "-O2", "-o", op, sp, null };
        st = execStatus(&argv);
    } else if (std.mem.eql(u8, lang, "zig")) {
        if (want_libc) {
            const argv = [_:null]?[*:0]const u8{ "env", "zig", "build-exe", "-OReleaseFast", "-fstrip", "-lc", sp, emit.ptr, null };
            st = execStatus(&argv);
        } else {
            const argv = [_:null]?[*:0]const u8{ "env", "zig", "build-exe", "-OReleaseFast", "-fstrip", sp, emit.ptr, null };
            st = execStatus(&argv);
        }
    } else {
        return "unsupported lang (want \"c\" or \"zig\")";
    }
    if (st != 0) return "build failed";
    if (lstatMode(out_path) == null) return "build produced no binary";
    var bz: [4096]u8 = undefined;
    if (toZ(&bz, out_path)) |p| _ = linux.chmod(p, 0o755);

    // the built binary is trusted; the source dir has served its purpose but
    // ships alongside so reviewers/audits can re-derive — leave src/ in place.
    return null;
}

test "validSrcName allows one extension dot, rejects traversal" {
    try std.testing.expect(validSrcName("main.c"));
    try std.testing.expect(validSrcName("agent.zig"));
    try std.testing.expect(validSrcName("x"));
    try std.testing.expect(!validSrcName("../x.c"));
    try std.testing.expect(!validSrcName("a/b.c"));
    try std.testing.expect(!validSrcName("a.b.c"));
    try std.testing.expect(!validSrcName(".hidden"));
}

/// Refuse names that collide with an executable on PATH. Dispatch-time
/// no-shadowing already makes such a feat inert; refusing here is honest UX.
fn shadowsPath(name: []const u8) bool {
    const path_env = getEnv("PATH") orelse return false;
    var dirs = std.mem.splitScalar(u8, path_env, ':');
    while (dirs.next()) |d| {
        if (d.len == 0) continue;
        var buf: [4096]u8 = undefined;
        const cand = std.fmt.bufPrint(&buf, "{s}/{s}", .{ d, name }) catch continue;
        var z: [4096]u8 = undefined;
        const p = toZ(&z, cand) orelse continue;
        if (@as(isize, @bitCast(linux.access(p, 1))) == 0) return true; // X_OK
    }
    return false;
}

// ===========================================================================
// gf status — the read-side fold over the ledger
//
// The write side appends install + review events; this projects them back
// into "what is currently known about each feat", grouped by content hash.
// TWO renderings over ONE fold: --json for agents (the ledger is
// agent-drivable data), a pretty terminal card for humans. v1 is TRANSPARENCY
// only — it surfaces verdicts, it does not GATE on them: weighting reviews by
// reviewer reputation needs the calibration benchmark, and gating on an
// uncalibrated signal would be shipping the illusion of trust. Promotion
// gating (`gf promote`) is the next slice, after the benchmark supplies weights.
// ===========================================================================

const StInstall = struct { sha: []const u8, name: []const u8, url: []const u8, ts: i64 };
const StReview = struct { sha: []const u8, verdict: []const u8, reviewer: []const u8, result: []const u8, ts: i64 };

fn cmdStatus(root: []const u8, filter: ?[]const u8, json: bool) u8 {
    var pbuf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "{s}/ledger.jsonl", .{root}) catch return fail("path too long", .{});
    const content = readFileAlloc(path, 16 * 1024 * 1024) orelse {
        if (json) print("{{\"feats\":[]}}\n", .{}) else print("gf: no ledger yet (nothing installed through gf)\n", .{});
        return 0;
    };

    var installs: std.ArrayListUnmanaged(StInstall) = .empty;
    var reviews: std.ArrayListUnmanaged(StReview) = .empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |ln| {
        const line = std.mem.trim(u8, ln, " \t\r");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        // NOTE: parsed is intentionally leaked into `alloc` (page_allocator,
        // process-lifetime) so the extracted slices stay valid for rendering.
        const t = objStr2(parsed.value, "t") orelse continue;
        if (std.mem.eql(u8, t, "install")) {
            installs.append(alloc, .{
                .sha = objStr2(parsed.value, "sha256") orelse "",
                .name = objStr2(parsed.value, "name") orelse "?",
                .url = objStr2(parsed.value, "url") orelse "",
                .ts = objInt2(parsed.value, "ts") orelse 0,
            }) catch continue;
        } else if (std.mem.eql(u8, t, "review")) {
            reviews.append(alloc, .{
                .sha = objStr2(parsed.value, "sha256") orelse "",
                .verdict = objStr2(parsed.value, "verdict") orelse "unknown",
                .reviewer = objStr2(parsed.value, "reviewer") orelse "?",
                .result = objStr2(parsed.value, "result") orelse "",
                .ts = objInt2(parsed.value, "ts") orelse 0,
            }) catch continue;
        }
    }

    if (json) return statusJson(installs.items, reviews.items, filter);
    return statusHuman(installs.items, reviews.items, filter);
}

fn objInt2(v: std.json.Value, key: []const u8) ?i64 {
    const o = switch (v) {
        .object => |ob| ob,
        else => return null,
    };
    return switch (o.get(key) orelse return null) {
        .integer => |iv| iv,
        else => null,
    };
}

fn matches(name: []const u8, filter: ?[]const u8) bool {
    return filter == null or std.mem.eql(u8, name, filter.?);
}

/// Agent rendering: the fold as one JSON object per install, reviews nested.
/// Latest install per name wins the summary, but every record is present.
fn statusJson(installs: []const StInstall, reviews: []const StReview, filter: ?[]const u8) u8 {
    var b: std.ArrayListUnmanaged(u8) = .empty;
    b.appendSlice(alloc, "{\"feats\":[") catch return 1;
    var first = true;
    for (installs) |in| {
        if (!matches(in.name, filter)) continue;
        if (!first) b.appendSlice(alloc, ",") catch return 1;
        first = false;
        b.appendSlice(alloc, "{\"name\":\"") catch return 1;
        appendJsonStr(&b, in.name) catch return 1;
        b.appendSlice(alloc, "\",\"sha256\":\"") catch return 1;
        appendJsonStr(&b, in.sha) catch return 1;
        b.appendSlice(alloc, "\",\"url\":\"") catch return 1;
        appendJsonStr(&b, in.url) catch return 1;
        var tb: [64]u8 = undefined;
        b.appendSlice(alloc, std.fmt.bufPrint(&tb, "\",\"installed_at\":{d},\"reviews\":[", .{in.ts}) catch return 1) catch return 1;
        var rfirst = true;
        for (reviews) |rv| {
            if (!std.mem.eql(u8, rv.sha, in.sha)) continue;
            if (!rfirst) b.appendSlice(alloc, ",") catch return 1;
            rfirst = false;
            b.appendSlice(alloc, "{\"verdict\":\"") catch return 1;
            appendJsonStr(&b, rv.verdict) catch return 1;
            b.appendSlice(alloc, "\",\"reviewer\":\"") catch return 1;
            appendJsonStr(&b, rv.reviewer) catch return 1;
            b.appendSlice(alloc, "\",\"result\":\"") catch return 1;
            appendJsonStr(&b, rv.result) catch return 1;
            var rtb: [64]u8 = undefined;
            b.appendSlice(alloc, std.fmt.bufPrint(&rtb, "\",\"ts\":{d}}}", .{rv.ts}) catch return 1) catch return 1;
        }
        b.appendSlice(alloc, "]}") catch return 1;
    }
    b.appendSlice(alloc, "]}\n") catch return 1;
    writeAll1(b.items);
    return 0;
}

/// Human rendering: a card per feat with a colored verdict badge. Reads as a
/// glance: green pass, red fail, dim "unreviewed".
fn statusHuman(installs: []const StInstall, reviews: []const StReview, filter: ?[]const u8) u8 {
    var any = false;
    for (installs) |in| {
        if (!matches(in.name, filter)) continue;
        any = true;

        // find the latest review for this sha
        var verdict: []const u8 = "";
        var reviewer: []const u8 = "";
        var latest_ts: i64 = -1;
        var nrev: usize = 0;
        for (reviews) |rv| {
            if (!std.mem.eql(u8, rv.sha, in.sha)) continue;
            nrev += 1;
            if (rv.ts >= latest_ts) {
                latest_ts = rv.ts;
                verdict = rv.verdict;
                reviewer = rv.reviewer;
            }
        }

        // badge
        const badge = if (verdict.len == 0)
            "\x1b[2m ?  unreviewed\x1b[0m"
        else if (std.mem.eql(u8, verdict, "pass"))
            "\x1b[32m \xe2\x9c\x93  pass\x1b[0m"
        else if (std.mem.eql(u8, verdict, "fail"))
            "\x1b[31m \xe2\x9c\x97  fail\x1b[0m"
        else
            "\x1b[33m ?  " ++ "unknown\x1b[0m";

        const short = if (in.sha.len >= 12) in.sha[0..12] else in.sha;
        print("\x1b[1m{s}\x1b[0m  {s}\n", .{ in.name, badge });
        print("    sha {s}  \x1b[2m{s}\x1b[0m\n", .{ short, in.url });
        if (verdict.len > 0) {
            print("    reviewed by {s}", .{reviewer});
            if (nrev > 1) print("  (+{d} more)", .{nrev - 1});
            print("\n", .{});
        }
    }
    if (!any) {
        if (filter) |f| print("gf: no record of {s}\n", .{f}) else print("gf: nothing installed through gf yet\n", .{});
    }
    return 0;
}

fn writeAll1(bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(1, bytes.ptr + off, bytes.len - off);
        const n: isize = @bitCast(rc);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

// ===========================================================================
// main
// ===========================================================================

pub fn main(init: std.process.Init.Minimal) void {
    linux.exit(run(init));
}

/// Feat root: same resolution as zish (ZISH_FEAT_PATH overrides).
fn featRootPath(buf: []u8) ?[]const u8 {
    if (getEnv("ZISH_FEAT_PATH")) |p| return p;
    const home = getEnv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.zish/feats", .{home}) catch null;
}

fn run(init: std.process.Init.Minimal) u8 {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next(); // argv0
    const first = args.next() orelse {
        print("usage: gf <url>              fetch a feat tarball, install into the extra tier\n" ++
            "       gf status [feat] [--json]  show install + review history (the ledger fold)\n", .{});
        return 1;
    };

    // `gf status [feat] [--json]` — the read-side fold over the ledger.
    if (std.mem.eql(u8, first, "status")) {
        var name: ?[]const u8 = null;
        var json = false;
        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--json")) json = true else name = a;
        }
        var rb: [4096]u8 = undefined;
        const root = featRootPath(&rb) orelse return fail("no HOME", .{});
        return cmdStatus(root, name, json);
    }

    const url = first;
    if (args.next() != null) return fail("unexpected extra argument", .{});

    // feat root: same resolution as zish (ZISH_FEAT_PATH overrides)
    var root_buf: [4096]u8 = undefined;
    const root = featRootPath(&root_buf) orelse return fail("no HOME", .{});
    mkdirP(root);
    var extra_buf: [4096]u8 = undefined;
    const extra_dir = std.fmt.bufPrint(&extra_buf, "{s}/extra", .{root}) catch return fail("path too long", .{});
    mkdirP(extra_dir);

    // temp dir inside the feat root: rename() into extra/ stays one filesystem
    const pid = linux.getpid();
    var tmp_buf: [4096]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}/.gf-tmp-{d}", .{ root, pid }) catch return fail("path too long", .{});
    mkdirP(tmp);
    var cleanup_tmp = true;
    defer if (cleanup_tmp) rmRf(tmp);

    // download (protocol-restricted; file:// is what the test suite uses)
    var ar_buf: [4096]u8 = undefined;
    const archive = std.fmt.bufPrint(&ar_buf, "{s}/archive.tar.gz", .{tmp}) catch return fail("path too long", .{});
    {
        var az: [4096]u8 = undefined;
        var uz: [4096]u8 = undefined;
        const ap = toZ(&az, archive) orelse return fail("path too long", .{});
        const up = toZ(&uz, url) orelse return fail("url too long", .{});
        var szbuf: [24]u8 = undefined;
        var szz: [24]u8 = undefined;
        const szs = std.fmt.bufPrint(&szbuf, "{d}", .{MAX_ARCHIVE}) catch return 1;
        const szp = toZ(&szz, szs) orelse return 1;
        const argv = [_:null]?[*:0]const u8{
            "env",            "curl", "-fsSL", "--max-time", "300", "--proto", "=http,https,file",
            "--max-filesize", szp,
            "-o",             ap,
            up,
            null,
        };
        const st = execStatus(&argv);
        if (st != 0) return fail("download failed (curl exit {d}): {s}", .{ st, url });
    }
    // curl's --max-filesize misses some servers; verify the landed size too
    const sz = fileSize(archive) orelse return fail("download produced no file", .{});
    if (sz > MAX_ARCHIVE) return fail("archive exceeds {d} bytes", .{MAX_ARCHIVE});

    // extract into the temp dir
    {
        var az: [4096]u8 = undefined;
        var tz: [4096]u8 = undefined;
        const ap = toZ(&az, archive) orelse return 1;
        const tp = toZ(&tz, tmp) orelse return 1;
        const argv = [_:null]?[*:0]const u8{ "env", "tar", "-xzf", ap, "-C", tp, null };
        const st = execStatus(&argv);
        if (st != 0) return fail("extract failed (tar exit {d})", .{st});
    }
    // hash the exact bytes that were installed, then drop the archive
    const sha = sha256File(archive) orelse "";
    var az2: [4096]u8 = undefined;
    if (toZ(&az2, archive)) |ap| _ = linux.unlink(ap);

    // manifest: name + bin, charset-checked before they join any path
    var mf_buf: [4096]u8 = undefined;
    const mf_path = std.fmt.bufPrint(&mf_buf, "{s}/feat.toml", .{tmp}) catch return 1;
    const manifest = readFileAlloc(mf_path, MAX_MANIFEST) orelse
        return fail("archive has no readable feat.toml (or it is oversized)", .{});
    const name = manifestField(manifest, "name") orelse return fail("manifest has no name", .{});
    const bin_name = manifestField(manifest, "bin") orelse name;
    if (!validName(name)) return fail("invalid feat name {s}", .{name});
    if (!validName(bin_name)) return fail("invalid bin name {s}", .{bin_name});

    // Source package? Presence of a `src` manifest field selects it. gf builds
    // it locally from a fixed template; the recipe is declarative data, never
    // an executable script the publisher supplies.
    const is_source = manifestField(manifest, "src") != null;
    if (is_source) {
        const src_file = manifestField(manifest, "src").?;
        const lang = manifestField(manifest, "lang") orelse return fail("source package needs a lang field", .{});
        const want_libc = if (manifestField(manifest, "libc")) |l| std.mem.eql(u8, l, "true") else false;
        if (!validSrcName(src_file)) return fail("invalid src filename {s}", .{src_file});
        if (validateTree(tmp, "src", src_file)) |why| return fail("{s}", .{why});
        if (shadowsPath(name)) return fail("name {s} collides with an installed command — a feat never shadows a real binary", .{name});
        print("gf: building {s} from source ({s})...\n", .{ name, lang });
        if (buildSource(tmp, lang, src_file, bin_name, want_libc)) |why| return fail("{s}", .{why});
    } else {
        if (validateTree(tmp, "bin", bin_name)) |why| return fail("{s}", .{why});
        if (shadowsPath(name)) return fail("name {s} collides with an installed command — a feat never shadows a real binary", .{name});
    }

    // force the quarantine tier in the manifest, mark the binary executable
    const rewritten = forceExtraTier(manifest) catch return fail("out of memory", .{});
    if (!writeFile(mf_path, rewritten, 0o600)) return fail("cannot rewrite manifest", .{});
    {
        var bz: [4096]u8 = undefined;
        var bp_buf: [4096]u8 = undefined;
        const bp = std.fmt.bufPrint(&bp_buf, "{s}/bin/{s}", .{ tmp, bin_name }) catch return 1;
        const p = toZ(&bz, bp) orelse return 1;
        _ = linux.chmod(p, 0o755);
    }

    // atomic install: refuse an existing feat (no silent upgrade in v1)
    var dest_buf: [4096]u8 = undefined;
    const dest = std.fmt.bufPrint(&dest_buf, "{s}/extra/{s}", .{ root, name }) catch return 1;
    if (lstatMode(dest) != null) return fail("{s} is already installed at {s} — remove it first", .{ name, dest });
    {
        var tz: [4096]u8 = undefined;
        var dz: [4096]u8 = undefined;
        const tp = toZ(&tz, tmp) orelse return 1;
        const dp = toZ(&dz, dest) orelse return 1;
        if (@as(isize, @bitCast(linux.rename(tp, dp))) != 0) return fail("install rename failed", .{});
        cleanup_tmp = false;
    }

    // attest the install in the append-only ledger (name, content hash,
    // origin, time) — the local end of the review/reputation pipeline
    ledgerAppend(root, name, url, sha);

    // review-on-install: the agent judges the source and appends a verdict
    // beside the install event. Decoupled — any failure leaves the install
    // intact and simply unreviewed.
    reviewInstalled(root, dest, name, sha);

    print(
        "gf: installed {s} into the extra tier: {s}\n" ++
            "    extra feats run quarantined: stripped environment, never as root,\n" ++
            "    and session feats get no run/prompt hostcalls.\n" ++
            "    to promote after you trust it:  mv {s} {s}/standard/{s}\n",
        .{ name, dest, dest, root, name },
    );
    return 0;
}
