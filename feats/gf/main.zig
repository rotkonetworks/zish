//! gf — the feat fetcher. `gf install <name>` resolves a feat from the index and
//! installs it; `gf <url>` installs a tarball from a URL. Both do fetch →
//! validate → stage.
//!
//! Trust stays with the human (or a reviewer agent). A tarball from a
//! user-pointed index or a bare URL lands in `extra/`, where zish runs it with a
//! stripped environment, refuses it as root, and masks the run/prompt hostcalls
//! for session feats. A sha-verified tarball from the built-in default index
//! installs to `standard/` and is callable at once; promoting anything else is a
//! deliberate `mv`.
//!
//! Tarball format: feat.toml and bin/<name> at the top level (what `make
//! dist-all` produces). The archive is adversarial input:
//!   - the extracted tree is validated by lstat walk: regular files only, no
//!     symlinks (a symlinked bin/ member is the classic install-path attack),
//!     nothing outside feat.toml + bin/.
//!   - manifest name/bin fields are charset-checked before they join a path (gf
//!     builds install paths itself; `../standard/x` in a name would be a tier
//!     escape).
//!   - the manifest's tier line is rewritten to match the install location, so a
//!     lying manifest can't mislead a later reader; the directory is authoritative.
//!   - a name that collides with a command on PATH is refused (dispatch already
//!     makes such a feat inert; refusing at install is the honest UX).
//!   - download and extraction happen in a temp dir inside the feat root, so the
//!     final rename() into the tier is atomic on one filesystem.
//!
//! No upgrade in v1: an existing install at the target tier is refused; remove it first.
//!
//! Source packages (format v2): a tarball may ship src/<file> instead of
//! bin/<name>, plus declarative build fields:
//!     lang = "c" | "zig"      src = "main.c"      libc = "true" (zig only)
//! gf compiles it locally with a fixed template (zig cc -O2 / zig build-exe
//! -OReleaseFast). The recipe is data, not code: the publisher gets no
//! build-time execution (the AUR PKGBUILD hole, closed here). Distributing
//! source is what makes review-on-install meaningful: reviewers read what
//! shipped, and the binary trusted is the one built here from the hashed source.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const alloc = std.heap.page_allocator;

const MAX_ARCHIVE = 64 * 1024 * 1024; // download size cap
const MAX_MANIFEST = 64 * 1024;
const MAX_NAME = 32;

// The built-in feat index: rotko's release channel. `gf install/list/search`
// resolve against this with zero config; `ZISH_FEAT_INDEX` overrides it. The
// index URL is the rolling `latest/download` pointer, but each entry inside it
// pins an IMMUTABLE `releases/download/<tag>/…` tarball URL + sha256 (see
// `make dist-all`), so a release cut mid-fetch can never 404 a pinned artifact.
const DEFAULT_FEAT_INDEX = "https://github.com/rotkonetworks/zish/releases/latest/download/index.jsonl";

// This host's arch, matched against an index entry's optional `arch` field so a
// multi-arch index hands out the right binary (an entry with no `arch` is
// arch-independent — e.g. a source package built locally).
const HOST_ARCH: []const u8 = switch (builtin.target.cpu.arch) {
    .x86_64 => "x86_64",
    .aarch64 => "aarch64",
    else => "unknown",
};

/// The feat index to use: the caller's `ZISH_FEAT_INDEX` if set, else the
/// built-in default. `is_default` is the trust signal — only the built-in
/// default (rotko's own release channel) earns a standard-tier install; a
/// user-pointed index or a bare URL stays quarantined in extra/.
fn indexUrl() struct { url: []const u8, is_default: bool } {
    if (getEnv("ZISH_FEAT_INDEX")) |u| return .{ .url = u, .is_default = false };
    return .{ .url = DEFAULT_FEAT_INDEX, .is_default = true };
}

/// Read one line of selection from stdin (without the newline). In a terminal
/// the human types it; piped (`echo "1 3" | gf setup`) it is read the same way.
/// Immediate EOF returns an empty line, which `gf setup` treats as "cancel" —
/// so it never hangs when stdin is /dev/null. EINTR-safe.
fn readSelection(buf: []u8) []const u8 {
    var n: usize = 0;
    while (n < buf.len) {
        var c: [1]u8 = undefined;
        const rc = linux.read(0, &c, 1);
        const r: isize = @bitCast(rc);
        if (r < 0) {
            if (-r == @intFromEnum(linux.E.INTR)) continue;
            break;
        }
        if (r == 0) break; // EOF
        if (c[0] == '\n') break;
        buf[n] = c[0];
        n += 1;
    }
    return buf[0..n];
}

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

/// Rewrite the manifest so its tier line reads `tier` ("extra" or "standard") —
/// replacing an existing tier line, or appending one if the manifest had none.
/// gf, not the publisher, decides the tier: the installed directory is
/// authoritative, and the manifest is made to agree so a future reader is never
/// misled by a lying `tier =` line shipped in the tarball.
fn forceTier(content: []const u8, tier: []const u8) ![]u8 {
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
            try out.appendSlice(alloc, "tier = \"");
            try out.appendSlice(alloc, tier);
            try out.append(alloc, '"');
            wrote_tier = true;
        } else {
            try out.appendSlice(alloc, raw);
        }
    }
    if (!wrote_tier) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(alloc, '\n');
        try out.appendSlice(alloc, "tier = \"");
        try out.appendSlice(alloc, tier);
        try out.appendSlice(alloc, "\"\n");
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

test "forceTier rewrites or appends the tier line" {
    const a = try forceTier("name = \"x\"\ntier = \"standard\"\nbin = \"x\"\n", "extra");
    try std.testing.expect(std.mem.indexOf(u8, a, "tier = \"extra\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "standard") == null);
    const b = try forceTier("name = \"x\"\nbin = \"x\"\n", "extra");
    try std.testing.expect(std.mem.indexOf(u8, b, "tier = \"extra\"") != null);
    // a trusted (default-index) install writes the standard tier instead
    const c = try forceTier("name = \"x\"\ntier = \"extra\"\nbin = \"x\"\n", "standard");
    try std.testing.expect(std.mem.indexOf(u8, c, "tier = \"standard\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, c, "\"extra\"") == null);
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

/// Re-exec THIS gf binary (fork + execve of /proc/self/exe, resolved in the
/// still-gf child before the exec). `gf setup` uses it to install each pick
/// through the exact `gf install <name>` path — same tier, sha-pin, and ledger.
/// (Routing through `env` would not work: env replaces the image, so
/// /proc/self/exe would then point at env, not gf.)
fn execSelf(argv: [*:null]const ?[*:0]const u8) u8 {
    const pid_rc = linux.fork();
    const pid: isize = @bitCast(pid_rc);
    if (pid < 0) return 255;
    if (pid == 0) {
        _ = linux.execve("/proc/self/exe", argv, @ptrCast(std.c.environ));
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
    if (!settingOn("review", true)) {
        print("gf: review is off ({s} installed unreviewed; `gf settings` to re-enable)\n", .{name});
        return;
    }
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

/// A feat index entry, resolved by name. The index is the "crates.io for feats"
/// piece — but minimal: a single static JSONL file (one object per line,
/// `{"name":..,"url":..,"sha256":..,"version":..}`) hosted anywhere. No server,
/// no accounts. The index is the trust root; the sha is the join key that
/// `gf install <name>` pins against.
// An index entry resolves to one of two delivery shapes:
//   git entry:     {"name","git","ref",...}      -> clone the user-repo at ref
//   tarball entry: {"name","url","sha256",...}    -> fetch prebuilt bytes, sha-pin
// git is the user-repository path (publish = git push + one index line); tarball
// is for prebuilt/bootstrap artifacts (e.g. gf installing itself). The trust
// root is the ref (immutable commit/tag) for git, the sha for tarballs.
const ResolvedKind = enum { git, tarball };
const Resolved = struct { kind: ResolvedKind, loc: []const u8, pin: []const u8, publisher: ?[]const u8 };

/// Fetch the index body (curl, protocol-restricted, size-capped). Caller frees.
fn fetchIndex(idx_url: []const u8) ?[]u8 {
    var uz: [4096]u8 = undefined;
    const up = toZ(&uz, idx_url) orelse return null;
    const argv = [_:null]?[*:0]const u8{
        "env",            "curl", "-fsSL",     "--max-time", "60", "--proto", "=http,https,file",
        "--max-filesize", "4194304",           up,           null,
    };
    return execCapture(&argv);
}

fn resolveIndex(idx_url: []const u8, name: []const u8) ?Resolved {
    const data = fetchIndex(idx_url) orelse return null;
    defer alloc.free(data);
    // last match wins: republishing appends a newer line for the same name, so
    // the newest entry (later in the file) supersedes — cargo-like versioning.
    var found: ?Resolved = null;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |ln| {
        const line = std.mem.trim(u8, ln, " \t\r");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        defer parsed.deinit();
        const nm = objStr2(parsed.value, "name") orelse continue;
        if (!std.mem.eql(u8, nm, name)) continue;
        // arch gate: an entry that names an `arch` must match this host (a
        // multi-arch index carries one tarball line per arch); an entry with no
        // `arch` is arch-independent (e.g. a source package built locally).
        if (objStr2(parsed.value, "arch")) |a| {
            if (!std.mem.eql(u8, a, HOST_ARCH)) continue;
        }
        // build the candidate; on success, free any prior match and keep this one
        const cand: ?Resolved = blk: {
            // git entry (user-repo) takes precedence; it MUST pin a ref.
            if (objStr2(parsed.value, "git")) |g| {
                const ref = objStr2(parsed.value, "ref") orelse break :blk null;
                const pubkey = objStr2(parsed.value, "publisher");
                break :blk Resolved{
                    .kind = .git,
                    .loc = alloc.dupe(u8, g) catch break :blk null,
                    .pin = alloc.dupe(u8, ref) catch break :blk null,
                    .publisher = if (pubkey) |p| (alloc.dupe(u8, p) catch null) else null,
                };
            }
            if (objStr2(parsed.value, "url")) |u| {
                const sha = objStr2(parsed.value, "sha256") orelse break :blk null;
                break :blk Resolved{
                    .kind = .tarball,
                    .loc = alloc.dupe(u8, u) catch break :blk null,
                    .pin = alloc.dupe(u8, sha) catch break :blk null,
                    .publisher = null,
                };
            }
            break :blk null;
        };
        if (cand) |c| {
            if (found) |old| {
                alloc.free(old.loc);
                alloc.free(old.pin);
                if (old.publisher) |p| alloc.free(p);
            }
            found = c;
        }
    }
    return found;
}

/// The first two whitespace fields of an ssh .pub line ("ssh-ed25519 AAAA…"),
/// dropping any trailing comment.
fn pubField2(raw: []const u8) []const u8 {
    const t = std.mem.trim(u8, raw, " \t\r\n");
    var it = std.mem.tokenizeAny(u8, t, " \t");
    _ = it.next() orelse return t;
    const b = it.next() orelse return t;
    return t[0 .. (@intFromPtr(b.ptr) - @intFromPtr(t.ptr)) + b.len];
}

/// Append `s` to a JSON string, dropping quotes/backslashes/control chars.
/// The fields here are structured tokens (name, ref, url, base64 key) that
/// never legitimately contain those, so this is a sanitizer, not an escaper.
fn appendClean(o: *std.ArrayListUnmanaged(u8), s: []const u8) void {
    for (s) |c| if (c >= 0x20 and c != '"' and c != '\\') o.append(alloc, c) catch {};
}

/// Append a line to a local index file (O_APPEND|O_CREAT). Returns false on error.
fn appendLine(path: []const u8, line: []const u8) bool {
    var z: [4096]u8 = undefined;
    const p = toZ(&z, path) orelse return false;
    const fd_rc = linux.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);
    const fd: isize = @bitCast(fd_rc);
    if (fd < 0) return false;
    defer _ = linux.close(@intCast(fd));
    return @as(isize, @bitCast(linux.write(@intCast(fd), line.ptr, line.len))) == @as(isize, @intCast(line.len));
}

/// `gf publish [dir]` — the cargo-easy write side. In a feat repo it cuts a
/// signed tag from feat.toml's version, pushes it, and emits (or appends) the
/// index line binding name → repo → ref → publisher key. One key signs both
/// your published tags and your review verdicts.
fn cmdPublish(dir_arg: ?[]const u8) u8 {
    const dir = dir_arg orelse ".";
    const key = getEnv("ZISH_SIGN_KEY") orelse
        return fail("set ZISH_SIGN_KEY to your ssh signing key (the same key that signs your reviews)", .{});

    var mb: [4096]u8 = undefined;
    const mfp = std.fmt.bufPrint(&mb, "{s}/feat.toml", .{dir}) catch return fail("path too long", .{});
    const content = readFileAlloc(mfp, 1 << 20) orelse
        return fail("no feat.toml in {s} — run publish inside a feat repo", .{dir});
    defer alloc.free(content);
    const name = manifestField(content, "name") orelse return fail("feat.toml has no name", .{});
    if (!validName(name)) return fail("invalid feat name in feat.toml", .{});
    const ver = manifestField(content, "version") orelse
        return fail("feat.toml needs a version = \"vX.Y.Z\" line to publish", .{});

    var dz: [4096]u8 = undefined;
    const dp = toZ(&dz, dir) orelse return 1;
    {
        const argv = [_:null]?[*:0]const u8{ "env", "git", "-C", dp, "rev-parse", "--is-inside-work-tree", null };
        if (execStatus(&argv) != 0) return fail("{s} is not a git repository", .{dir});
    }
    const origin_raw = blk: {
        const argv = [_:null]?[*:0]const u8{ "env", "git", "-C", dp, "remote", "get-url", "origin", null };
        break :blk execCapture(&argv) orelse
            return fail("no 'origin' remote — add one: git -C {s} remote add origin <url>", .{dir});
    };
    defer alloc.free(origin_raw);
    const origin = std.mem.trim(u8, origin_raw, " \t\r\n");
    if (origin.len == 0) return fail("origin remote is empty", .{});

    var rz: [512]u8 = undefined;
    const rp = toZ(&rz, ver) orelse return fail("version too long", .{});
    var skb: [4096]u8 = undefined;
    const skcfg = std.fmt.bufPrint(&skb, "user.signingkey={s}", .{key}) catch return 1;
    var skz: [4096]u8 = undefined;
    const skp = toZ(&skz, skcfg) orelse return 1;
    var msgb: [600]u8 = undefined;
    const msg = std.fmt.bufPrint(&msgb, "release {s}", .{ver}) catch return 1;
    var msgz: [600]u8 = undefined;
    const mp = toZ(&msgz, msg) orelse return 1;
    {
        // signed annotated tag: ssh format, key from ZISH_SIGN_KEY
        const argv = [_:null]?[*:0]const u8{ "env", "git", "-C", dp, "-c", "gpg.format=ssh", "-c", skp, "tag", "-s", rp, "-m", mp, null };
        if (execStatus(&argv) != 0)
            return fail("could not create signed tag {s} (already exists, or key {s} unreadable?)", .{ ver, key });
    }
    {
        const argv = [_:null]?[*:0]const u8{ "env", "git", "-C", dp, "push", "origin", rp, null };
        if (execStatus(&argv) != 0) return fail("git push origin {s} failed", .{ver});
    }

    var pkb: [4096]u8 = undefined;
    const pkp = std.fmt.bufPrint(&pkb, "{s}.pub", .{key}) catch return 1;
    const pubraw = readFileAlloc(pkp, 8192) orelse return fail("could not read the public key {s}.pub", .{key});
    defer alloc.free(pubraw);
    const pubkey = pubField2(pubraw);

    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(alloc);
    line.appendSlice(alloc, "{\"name\":\"") catch return 1;
    appendClean(&line, name);
    line.appendSlice(alloc, "\",\"git\":\"") catch return 1;
    appendClean(&line, origin);
    line.appendSlice(alloc, "\",\"ref\":\"") catch return 1;
    appendClean(&line, ver);
    line.appendSlice(alloc, "\",\"publisher\":\"") catch return 1;
    appendClean(&line, pubkey);
    line.appendSlice(alloc, "\"}\n") catch return 1;

    // If the index is a local file we control, append the line automatically
    // (cargo-to-crates.io ease). Otherwise print it for the user to add.
    if (getEnv("ZISH_FEAT_INDEX")) |idx| {
        const local: ?[]const u8 = if (std.mem.startsWith(u8, idx, "file://"))
            idx[7..]
        else if (std.mem.indexOf(u8, idx, "://") == null)
            idx
        else
            null;
        if (local) |p| {
            if (appendLine(p, line.items)) {
                print("published {s} {s} → {s}\nindexed in {s} (newest line wins)\n", .{ name, ver, origin, p });
                return 0;
            }
            print("published {s} {s}, but could not write the index at {s}; add this line yourself:\n", .{ name, ver, p });
        }
    }
    print("published {s} {s} → {s}\nadd this line to your feat index:\n", .{ name, ver, origin });
    print("{s}", .{line.items});
    return 0;
}

/// `gf remove <name>` — uninstall a feat from the feat root (both tiers). gf
/// builds the path from a charset-checked name, so it can never escape the root.
fn cmdRemove(name: []const u8) u8 {
    if (!validName(name)) return fail("invalid feat name: {s}", .{name});
    var rb: [4096]u8 = undefined;
    const root = featRootPath(&rb) orelse return fail("no HOME", .{});
    var removed = false;
    for ([_][]const u8{ "standard", "extra" }) |tier| {
        var pb: [4096]u8 = undefined;
        const p = std.fmt.bufPrint(&pb, "{s}/{s}/{s}", .{ root, tier, name }) catch continue;
        if (lstatMode(p) != null) {
            rmRf(p);
            print("gf: removed {s} from the {s} tier\n", .{ name, tier });
            removed = true;
        }
    }
    if (!removed) return fail("{s} is not installed", .{name});
    return 0;
}

// ---- gf settings: persistent on/off toggles (config at ~/.zish/gf.conf) -----

const SettingDef = struct { key: []const u8, label: []const u8, desc: []const u8, default_on: bool };
const GF_SETTINGS = [_]SettingDef{
    .{ .key = "review", .label = "review", .desc = "AI review-on-install (agent judges each source package, records a verdict)", .default_on = true },
};

fn gfConfigPath(buf: []u8) ?[]const u8 {
    if (getEnv("ZISH_GF_CONFIG")) |p| return p;
    const home = getEnv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.zish/gf.conf", .{home}) catch null;
}

/// Read a boolean setting from the config file (`key = on|off`). A missing file
/// or key returns `default_on`, so a fresh install behaves as the defaults say.
fn settingOn(key: []const u8, default_on: bool) bool {
    var cb: [4096]u8 = undefined;
    const cp = gfConfigPath(&cb) orelse return default_on;
    const data = readFileAlloc(cp, 64 * 1024) orelse return default_on;
    defer alloc.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (!std.mem.startsWith(u8, line, key)) continue;
        const after = line[key.len..];
        const eq = std.mem.indexOfScalar(u8, after, '=') orelse continue;
        if (std.mem.trim(u8, after[0..eq], " \t").len != 0) continue; // "reviewer=" != "review ="
        const val = std.mem.trim(u8, after[eq + 1 ..], " \t");
        return std.mem.eql(u8, val, "on") or std.mem.eql(u8, val, "true") or
            std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "yes");
    }
    return default_on;
}

/// Write every known setting to the config file (whole-file rewrite, 0644).
fn writeSettings(states: []const bool) bool {
    if (getEnv("HOME")) |h| {
        var zb: [4096]u8 = undefined;
        if (std.fmt.bufPrint(&zb, "{s}/.zish", .{h}) catch null) |zp| mkdirP(zp);
    }
    var cb: [4096]u8 = undefined;
    const cp = gfConfigPath(&cb) orelse return false;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    out.appendSlice(alloc, "# gf settings — toggle with `gf settings`\n") catch return false;
    for (GF_SETTINGS, 0..) |s, i| {
        out.appendSlice(alloc, s.key) catch return false;
        out.appendSlice(alloc, " = ") catch return false;
        out.appendSlice(alloc, if (states[i]) "on" else "off") catch return false;
        out.append(alloc, '\n') catch return false;
    }
    return writeFile(cp, out.items, 0o644);
}

/// `gf settings` — an interactive on/off checklist, same shape as `gf setup`:
/// pick a number to flip a setting, read from stdin so it also composes
/// (`echo 1 | gf settings`). Empty selection changes nothing.
fn cmdSettings() u8 {
    var states: [GF_SETTINGS.len]bool = undefined;
    for (GF_SETTINGS, 0..) |s, i| states[i] = settingOn(s.key, s.default_on);

    print("gf settings — toggle by number:\n\n", .{});
    for (GF_SETTINGS, 0..) |s, i| {
        print("  {d:>2}) [{s}] {s}  — {s}\n", .{ i + 1, if (states[i]) "on " else "off", s.label, s.desc });
    }
    print("\nFlip by number (space/comma-separated), or empty to cancel: ", .{});

    var lb: [256]u8 = undefined;
    const sel = readSelection(&lb);
    const trimmed = std.mem.trim(u8, sel, " \t\r");
    if (trimmed.len == 0) {
        print("no change.\n", .{});
        return 0;
    }
    var changed = false;
    var toks = std.mem.tokenizeAny(u8, trimmed, " ,");
    while (toks.next()) |tok| {
        const n = std.fmt.parseInt(usize, tok, 10) catch {
            print("  (ignoring \"{s}\": not a number)\n", .{tok});
            continue;
        };
        if (n < 1 or n > GF_SETTINGS.len) {
            print("  (ignoring {d}: out of range)\n", .{n});
            continue;
        }
        states[n - 1] = !states[n - 1];
        changed = true;
    }
    if (!changed) {
        print("no change.\n", .{});
        return 0;
    }
    if (!writeSettings(&states)) return fail("could not write settings to the config", .{});
    for (GF_SETTINGS, 0..) |s, i| print("  {s} = {s}\n", .{ s.label, if (states[i]) "on" else "off" });
    return 0;
}

const FeatState = enum { available, active, inactive };

/// `gf setup` — an interactive checklist over the index. Every feat is shown
/// with its state: available (not installed), active (standard tier, callable),
/// or inactive (extra tier, quarantined). Picking a number toggles it — install
/// an available feat, remove an installed one — each via a re-exec of the same
/// `gf install`/`gf remove` path, so the tier, sha-pin and ledger rules match.
fn cmdSetup() u8 {
    const ix = indexUrl();
    const data = fetchIndex(ix.url) orelse return fail("could not fetch the feat index ({s})", .{ix.url});
    defer alloc.free(data);
    var rb: [4096]u8 = undefined;
    const root = featRootPath(&rb) orelse return fail("no HOME", .{});

    const Item = struct { name: []const u8, ver: []const u8, desc: []const u8, state: FeatState };
    var items: std.ArrayListUnmanaged(Item) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(alloc);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |ln| {
        const line = std.mem.trim(u8, ln, " \t\r");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        defer parsed.deinit();
        const nm = objStr2(parsed.value, "name") orelse continue;
        if (objStr2(parsed.value, "arch")) |a| {
            if (!std.mem.eql(u8, a, HOST_ARCH)) continue;
        }
        if (seen.contains(nm)) continue;
        seen.put(alloc, alloc.dupe(u8, nm) catch nm, {}) catch {};
        var sb: [4096]u8 = undefined;
        var eb: [4096]u8 = undefined;
        const sp = std.fmt.bufPrint(&sb, "{s}/standard/{s}", .{ root, nm }) catch continue;
        const ep = std.fmt.bufPrint(&eb, "{s}/extra/{s}", .{ root, nm }) catch continue;
        const state: FeatState = if (lstatMode(sp) != null) .active else if (lstatMode(ep) != null) .inactive else .available;
        items.append(alloc, .{
            .name = alloc.dupe(u8, nm) catch continue,
            .ver = alloc.dupe(u8, objStr2(parsed.value, "version") orelse "") catch "",
            .desc = alloc.dupe(u8, objStr2(parsed.value, "desc") orelse "") catch "",
            .state = state,
        }) catch {};
    }

    if (items.items.len == 0) {
        print("gf setup: the feat index is empty ({s}).\n", .{ix.url});
        return 0;
    }
    print("Feats (from {s}) — [ ] available  [*] active  [~] inactive:\n\n", .{ix.url});
    for (items.items, 0..) |it, i| {
        const mark = switch (it.state) {
            .available => "[ ]",
            .active => "[*]",
            .inactive => "[~]",
        };
        if (it.desc.len != 0) {
            print("  {d:>2}) {s} {s}  {s}  — {s}\n", .{ i + 1, mark, it.name, it.ver, it.desc });
        } else {
            print("  {d:>2}) {s} {s}  {s}\n", .{ i + 1, mark, it.name, it.ver });
        }
    }
    print("\nToggle by number (install an available feat, remove an installed one), 'all', or empty to cancel: ", .{});

    var lb: [1024]u8 = undefined;
    const sel = readSelection(&lb);
    const trimmed = std.mem.trim(u8, sel, " \t\r");
    if (trimmed.len == 0) {
        print("cancelled.\n", .{});
        return 0;
    }

    var chosen: std.ArrayListUnmanaged(usize) = .empty;
    defer chosen.deinit(alloc);
    if (std.ascii.eqlIgnoreCase(trimmed, "all")) {
        for (0..items.items.len) |i| chosen.append(alloc, i) catch {};
    } else {
        var toks = std.mem.tokenizeAny(u8, trimmed, " ,");
        while (toks.next()) |tok| {
            const n = std.fmt.parseInt(usize, tok, 10) catch {
                print("  (ignoring \"{s}\": not a number)\n", .{tok});
                continue;
            };
            if (n < 1 or n > items.items.len) {
                print("  (ignoring {d}: out of range)\n", .{n});
                continue;
            }
            chosen.append(alloc, n - 1) catch {};
        }
    }
    if (chosen.items.len == 0) {
        print("nothing selected.\n", .{});
        return 0;
    }

    // each pick toggles: available → install, installed → remove. Both go
    // through a re-exec of this same gf binary (/proc/self/exe), inheriting the
    // environment, so the index/tier/pin rules are identical to running the
    // command directly.
    var did: usize = 0;
    var fail_n: usize = 0;
    for (chosen.items) |i| {
        const it = items.items[i];
        var nz: [256]u8 = undefined;
        const np = toZ(&nz, it.name) orelse {
            fail_n += 1;
            continue;
        };
        const verb: [*:0]const u8 = if (it.state == .available) "install" else "remove";
        print("\n→ {s} {s} …\n", .{ verb, it.name });
        const argv = [_:null]?[*:0]const u8{ "gf", verb, np, null };
        if (execSelf(&argv) == 0) did += 1 else fail_n += 1;
    }
    print("\ngf setup: {d} changed, {d} failed.\n", .{ did, fail_n });
    return if (fail_n == 0) 0 else 1;
}

/// `gf search [query]` / `gf list` — AUR-style discovery over the index. Both
/// fold the index into one readable line per feat (name · version · what it
/// does), deduped and arch-filtered so a multi-arch index reads as one feat per
/// name; search narrows by a substring on the name, list shows everything.
/// Zero-config: resolves the built-in default index unless ZISH_FEAT_INDEX is set.
fn cmdSearch(query: []const u8) u8 {
    const ix = indexUrl();
    const data = fetchIndex(ix.url) orelse return fail("could not fetch the feat index ({s})", .{ix.url});
    defer alloc.free(data);
    // Dedup by name: a multi-arch index has one line per (name, arch); collapse
    // to the entries that apply to THIS host so each feat prints once.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(alloc);
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |ln| {
        const line = std.mem.trim(u8, ln, " \t\r");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        defer parsed.deinit();
        const nm = objStr2(parsed.value, "name") orelse continue;
        if (query.len != 0 and std.mem.indexOf(u8, nm, query) == null) continue;
        if (objStr2(parsed.value, "arch")) |a| {
            if (!std.mem.eql(u8, a, HOST_ARCH)) continue;
        }
        if (seen.contains(nm)) continue;
        seen.put(alloc, alloc.dupe(u8, nm) catch nm, {}) catch {};
        const ver = objStr2(parsed.value, "version") orelse objStr2(parsed.value, "ref") orelse "";
        const desc = objStr2(parsed.value, "desc") orelse "";
        const signed = if (objStr2(parsed.value, "publisher") != null) " [signed]" else "";
        if (desc.len != 0) {
            print("{s}  {s}  — {s}{s}\n", .{ nm, ver, desc, signed });
        } else {
            print("{s}  {s}{s}\n", .{ nm, ver, signed });
        }
        n += 1;
    }
    if (n == 0) {
        if (query.len != 0) print("no feats match \"{s}\"\n", .{query}) else print("the feat index is empty ({s})\n", .{ix.url});
    } else if (query.len == 0) {
        print("\ninstall one:  gf install <name>\n", .{});
    }
    return 0;
}

fn run(init: std.process.Init.Minimal) u8 {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next(); // argv0
    const first = args.next() orelse {
        print("usage: gf setup                 interactive checklist: install / remove feats from the index\n" ++
            "       gf settings                toggle options on/off (AI review-on-install, …)\n" ++
            "       gf list                    list every feat in the index (name · version · what it does)\n" ++
            "       gf install <name>          install a feat by name from the feat index (pinned + verified)\n" ++
            "       gf remove <name>           uninstall a feat (from either tier)\n" ++
            "       gf search <query>          find feats in the index (AUR-style)\n" ++
            "       gf <url>                   fetch a feat tarball from a URL, install into the extra tier\n" ++
            "       gf publish [dir]           sign + push a release tag, emit the index line (cargo-style)\n" ++
            "       gf status [feat] [--json]  show install + review history (the ledger fold)\n", .{});
        return 1;
    };

    if (std.mem.eql(u8, first, "setup")) {
        if (args.next() != null) return fail("usage: gf setup", .{});
        return cmdSetup();
    }

    if (std.mem.eql(u8, first, "settings")) {
        if (args.next() != null) return fail("usage: gf settings", .{});
        return cmdSettings();
    }

    if (std.mem.eql(u8, first, "remove") or std.mem.eql(u8, first, "uninstall")) {
        const name = args.next() orelse return fail("usage: gf remove <name>", .{});
        if (args.next() != null) return fail("usage: gf remove <name>", .{});
        return cmdRemove(name);
    }

    if (std.mem.eql(u8, first, "list")) {
        if (args.next() != null) return fail("usage: gf list", .{});
        return cmdSearch("");
    }

    if (std.mem.eql(u8, first, "search")) {
        const q = args.next() orelse "";
        if (args.next() != null) return fail("usage: gf search [query]", .{});
        return cmdSearch(q);
    }

    if (std.mem.eql(u8, first, "publish")) {
        const dir = args.next();
        if (args.next() != null) return fail("usage: gf publish [dir]", .{});
        return cmdPublish(dir);
    }

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

    // Resolve the target: a bare URL, or `install <name>` against the feat
    // index. Install-by-name PINS the sha — the index is the trust root, so gf
    // refuses any downloaded bytes that don't match what the index declares.
    var expected_sha: ?[]const u8 = null; // tarball pin (index sha256)
    var git_ref: ?[]const u8 = null; // git pin (index ref: commit/tag)
    var publisher: ?[]const u8 = null; // git: index-declared signing pubkey
    var to_standard = false; // trusted default-index tarball → standard tier
    const url = blk: {
        if (std.mem.eql(u8, first, "install")) {
            const name_arg = args.next() orelse return fail("usage: gf install <name>", .{});
            if (args.next() != null) return fail("unexpected extra argument", .{});
            const ix = indexUrl();
            const r = resolveIndex(ix.url, name_arg) orelse
                return fail("{s} not found in the feat index ({s})", .{ name_arg, ix.url });
            switch (r.kind) {
                .tarball => {
                    expected_sha = r.pin;
                    // A sha-verified tarball from gf's OWN default index (rotko's
                    // release channel) installs to standard/, callable at once.
                    // A user-pointed ZISH_FEAT_INDEX or a bare `gf <url>` stays
                    // quarantined in extra/ — quarantine protects against
                    // third-party publishers, not against the same release
                    // channel that ships zish itself.
                    if (ix.is_default) to_standard = true;
                },
                .git => {
                    git_ref = r.pin;
                    publisher = r.publisher;
                },
            }
            break :blk r.loc;
        }
        if (args.next() != null) return fail("unexpected extra argument", .{});
        break :blk first;
    };

    // feat root: same resolution as zish (ZISH_FEAT_PATH overrides). The
    // destination tier is decided above (to_standard): a trusted default-index
    // tarball lands in standard/ (instantly callable), everything else in
    // extra/ (quarantined).
    const tier_name: []const u8 = if (to_standard) "standard" else "extra";
    var root_buf: [4096]u8 = undefined;
    const root = featRootPath(&root_buf) orelse return fail("no HOME", .{});
    mkdirP(root);
    var tierdir_buf: [4096]u8 = undefined;
    const tier_dir = std.fmt.bufPrint(&tierdir_buf, "{s}/{s}", .{ root, tier_name }) catch return fail("path too long", .{});
    mkdirP(tier_dir);

    // temp dir inside the feat root: rename() into extra/ stays one filesystem
    const pid = linux.getpid();
    var tmp_buf: [4096]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}/.gf-tmp-{d}", .{ root, pid }) catch return fail("path too long", .{});
    mkdirP(tmp);
    var cleanup_tmp = true;
    defer if (cleanup_tmp) rmRf(tmp);

    // Fetch the payload into `tmp` (feat.toml at the top, bin/ or src/ beside
    // it) by one of two paths: clone a git user-repo at its pinned ref, or
    // download + extract a tarball.
    var sha: []const u8 = ""; // ledger content hash; set per path
    if (git_ref) |ref| {
        // git user-repo install: clone the publisher's repo and check out the
        // PINNED ref (an immutable commit/tag — the trust root). We never run a
        // publisher-supplied build script: the source-package path below builds
        // the declared source via gf's own fixed template. GIT_ALLOW_PROTOCOL
        // fences off ext::/other transports on the clone.
        var uz: [4096]u8 = undefined;
        var tz: [4096]u8 = undefined;
        var rz: [4096]u8 = undefined;
        const up = toZ(&uz, url) orelse return fail("url too long", .{});
        const tp = toZ(&tz, tmp) orelse return 1;
        const rp = toZ(&rz, ref) orelse return fail("ref too long", .{});
        {
            const argv = [_:null]?[*:0]const u8{
                "env", "GIT_ALLOW_PROTOCOL=file:git:http:https:ssh", "GIT_TERMINAL_PROMPT=0",
                "git", "clone", "--quiet", up, tp, null,
            };
            if (execStatus(&argv) != 0) return fail("git clone failed: {s}", .{url});
        }
        {
            const argv = [_:null]?[*:0]const u8{
                "env", "git", "-C", tp, "-c", "advice.detachedHead=false", "checkout", "--quiet", rp, null,
            };
            if (execStatus(&argv) != 0) return fail("git checkout {s} failed (ref not found in {s}?)", .{ ref, url });
        }
        // When the index declares a publisher key, the ref MUST be a tag signed
        // by that key. We verify with a wildcard-principal allowed_signers (the
        // tagger's email is irrelevant — only "signed by THIS key" matters), so
        // the ref becomes cryptographically bound to the publisher, not just
        // immutable. Fail-closed: a missing/unsigned/wrong-key tag refuses.
        if (publisher) |pk| {
            // allowed_signers lives OUTSIDE the clone tree (a sibling of tmp) so
            // it is never renamed into the installed feat.
            var af_buf: [4096]u8 = undefined;
            const af = std.fmt.bufPrint(&af_buf, "{s}.allowed", .{tmp}) catch return 1;
            var al_buf: [4096]u8 = undefined;
            const al = std.fmt.bufPrint(&al_buf, "* namespaces=\"git\" {s}\n", .{pk}) catch return fail("publisher key too long", .{});
            if (!writeFile(af, al, 0o600)) return fail("could not stage the publisher key", .{});
            var cfg: [4096]u8 = undefined;
            const cfgval = std.fmt.bufPrint(&cfg, "gpg.ssh.allowedSignersFile={s}", .{af}) catch return 1;
            var cfgz: [4096]u8 = undefined;
            const cfgp = toZ(&cfgz, cfgval) orelse return 1;
            const argv = [_:null]?[*:0]const u8{
                "env", "git", "-C", tp, "-c", "gpg.format=ssh", "-c", cfgp, "tag", "-v", rp, null,
            };
            const vrc = execStatus(&argv);
            rmRf(af);
            if (vrc != 0)
                return fail("publisher signature check failed for {s} — refusing (tag not signed by the index's publisher key)", .{ref});
            print("gf: publisher signature verified ({s})\n", .{ref});
        }
        // drop .git so it is never staged into the tier
        var gd_buf: [4096]u8 = undefined;
        const gd = std.fmt.bufPrint(&gd_buf, "{s}/.git", .{tmp}) catch return 1;
        rmRf(gd);
        // The PIN is enforced above by checking out the immutable ref — not by a
        // byte hash. The ledger sha256 for a git install is the hash of the
        // installed artifact, computed after staging (below).
    } else {
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
        // hash the exact bytes; sha-pin to the index; then drop the archive
        sha = sha256File(archive) orelse "";
        if (expected_sha) |want| {
            if (want.len != sha.len or !std.ascii.eqlIgnoreCase(want, sha))
                return fail("sha256 mismatch: index expected {s}, downloaded {s} — refusing", .{ want, sha });
        }
        var az2: [4096]u8 = undefined;
        if (toZ(&az2, archive)) |ap| _ = linux.unlink(ap);
    }

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
    const rewritten = forceTier(manifest, tier_name) catch return fail("out of memory", .{});
    if (!writeFile(mf_path, rewritten, 0o600)) return fail("cannot rewrite manifest", .{});
    {
        var bz: [4096]u8 = undefined;
        var bp_buf: [4096]u8 = undefined;
        const bp = std.fmt.bufPrint(&bp_buf, "{s}/bin/{s}", .{ tmp, bin_name }) catch return 1;
        const p = toZ(&bz, bp) orelse return 1;
        _ = linux.chmod(p, 0o755);
    }

    // atomic install: refuse an existing feat at this tier (no silent upgrade
    // in v1). A copy in the other tier is left alone — dispatch resolves
    // standard/ before extra/, so the tiers don't collide.
    var dest_buf: [4096]u8 = undefined;
    const dest = std.fmt.bufPrint(&dest_buf, "{s}/{s}/{s}", .{ root, tier_name, name }) catch return 1;
    if (lstatMode(dest) != null) return fail("{s} is already installed at {s} — remove it first", .{ name, dest });
    {
        var tz: [4096]u8 = undefined;
        var dz: [4096]u8 = undefined;
        const tp = toZ(&tz, tmp) orelse return 1;
        const dp = toZ(&dz, dest) orelse return 1;
        if (@as(isize, @bitCast(linux.rename(tp, dp))) != 0) return fail("install rename failed", .{});
        cleanup_tmp = false;
    }

    // For a git install the content hash is the installed artifact (the ref
    // enforced the pin, not a byte hash); compute it now that it's staged.
    if (git_ref != null and sha.len == 0) {
        var bz: [4096]u8 = undefined;
        const bp = std.fmt.bufPrint(&bz, "{s}/bin/{s}", .{ dest, bin_name }) catch return 1;
        sha = sha256File(bp) orelse "";
    }

    // attest the install in the append-only ledger (name, content hash,
    // origin, time) — the local end of the review/reputation pipeline
    ledgerAppend(root, name, url, sha);

    // review-on-install: the agent judges the source and appends a verdict
    // beside the install event. Decoupled — any failure leaves the install
    // intact and simply unreviewed.
    reviewInstalled(root, dest, name, sha);

    if (to_standard) {
        print(
            "gf: installed {s} into the standard tier: {s}\n" ++
                "    run it now:  {s}\n",
            .{ name, dest, name },
        );
    } else {
        print(
            "gf: installed {s} into the extra tier: {s}\n" ++
                "    extra feats run quarantined: stripped environment, never as root,\n" ++
                "    and session feats get no run/prompt hostcalls.\n" ++
                "    to promote after you trust it:  mv {s} {s}/standard/{s}\n",
            .{ name, dest, dest, root, name },
        );
    }
    return 0;
}
