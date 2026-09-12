//! aur — a conductor for reviewed AUR upgrades, not a package manager.
//!
//! paru/yay are ~60k lines because they re-implement the whole AUR helper: dep
//! resolution, split packages, .SRCINFO, chroot, local repos. We need none of
//! that. For *reviewed upgrades of already-installed AUR packages* the job is
//! tiny, because the existing tools already do the hard part. `aur` is only the
//! gate: enumerate pending updates, fetch each PKGBUILD, judge it with the same
//! `agent --judge` primitive aurev uses, and decide whether the build proceeds.
//!
//! `aur check` — the pre-flight gate (this slice). Read-only: it installs
//! nothing. It fetches the incoming PKGBUILD for every pending AUR update,
//! reviews each against the pkgbuild-review rubric (cached by content hash in
//! the shared aurev ledger), prints a report, and sets its exit code:
//!
//!     exit 0  — every pending PKGBUILD passed         (build may proceed)
//!     exit 1  — at least one PKGBUILD failed review    (block)
//!     exit 2  — a PKGBUILD could not be reviewed        (block)
//!
//! So it composes as a real gate, unlike an advisory PAGER:
//!
//!     aur check && yay -Syu
//!
//! Note the posture is the INVERSE of aurev. aurev is a pager: advice, fail-open
//! (missing reviewer → show the raw diff, exit 0, you eyeball it). `aur check`
//! is a gate: a gate that fails open is not a gate, so when the reviewer is
//! unavailable it FAILS CLOSED — loud on stderr, nonzero exit, `&&` blocks. You
//! keep the manual override (`yay -Syu` directly); the default just refuses to
//! wave through what it could not read. This matches the shell's fail-closed
//! containment invariant.
//!
//! Autonomy (`aur upgrade`, which would actually install) is deliberately NOT
//! here. Auto-installing on the reviewer's own pass is the highest-stakes step
//! in the whole system — one false-negative is autonomous compromise — so it
//! waits until the reviewer benchmark has measured that the verdict is worth
//! trusting. Until then: gate, don't drive.

const std = @import("std");
const linux = std.os.linux;
const alloc = std.heap.page_allocator;
// Shared feat primitives. Zig confines imports to the root file's own
// directory, so this feat dir carries a `lib/feat.zig` symlink to
// ../lib/feat.zig — which keeps the Makefile's `zig build-exe
// feats/<name>/main.zig` recipe (and the musl dist build) exact.
const feat = @import("lib/feat.zig");

const MAX_OUT = 16 * 1024 * 1024;
const RUBRIC = "pkgbuild-review-v1";

// ---------------------------------------------------------------------------
// small helpers (feats are standalone; kept syscall-shaped like aurev/gf)
// ---------------------------------------------------------------------------

// Environment lookups go through `feat.env`, the shared zero-libc reader (Zig
// 0.16 dropped `std.posix.getenv`). It wants an io and returns allocated
// bytes; the process arena `std.process.Init` hands us owns them, so callers
// never free — the same borrow `std.c.getenv` used to give.

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
    return slurp(@intCast(fd), cap);
}

fn writeFileMode(path: []const u8, bytes: []const u8, mode: u32) bool {
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

fn exists(path: []const u8) bool {
    var z: [4096]u8 = undefined;
    const p = toZ(&z, path) orelse return false;
    var stx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, p, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &stx);
    return @as(isize, @bitCast(rc)) == 0;
}

fn nowSeconds() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @intCast(ts.sec);
}

const ExecResult = struct { out: []u8, code: u8 };

/// fork+exec via /usr/bin/env, capturing stdout and the exit code. `cwd`, when
/// set, is passed as env's own `-C DIR` (coreutils env) so the command runs
/// there. args[0] is the program name; the rest are its arguments. Returns null
/// only on a spawn/plumbing failure (never on a non-zero child exit — callers
/// decide what a code means).
fn exec(init: std.process.Init, cwd: ?[]const u8, args: []const []const u8) ?ExecResult {
    var argv: [40]?[*:0]const u8 = undefined;
    var held: [40][]u8 = undefined;
    var nh: usize = 0;
    var n: usize = 0;
    const push = struct {
        fn z(s: []const u8, h: [][]u8, nhp: *usize, av: []?[*:0]const u8, np: *usize) bool {
            const dz = alloc.dupeZ(u8, s) catch return false;
            h[nhp.*] = dz;
            nhp.* += 1;
            av[np.*] = dz.ptr;
            np.* += 1;
            return true;
        }
    }.z;
    defer for (held[0..nh]) |h| alloc.free(h);

    if (!push("env", &held, &nh, &argv, &n)) return null;
    if (cwd) |d| {
        if (!push("-C", &held, &nh, &argv, &n)) return null;
        if (!push(d, &held, &nh, &argv, &n)) return null;
    }
    for (args) |a| if (n >= argv.len - 1 or !push(a, &held, &nh, &argv, &n)) return null;
    argv[n] = null;
    const argvz: [*:null]const ?[*:0]const u8 = argv[0..n :null];

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
        // the inherited environment block, handed to us by the startup (envp)
        _ = linux.execve("/usr/bin/env", argvz, init.minimal.environ.block.slice.ptr);
        linux.exit(127);
    }
    _ = linux.close(fds[1]);
    const data = slurp(fds[0], MAX_OUT);
    _ = linux.close(fds[0]);
    var status: u32 = 0;
    _ = linux.waitpid(@intCast(pid), &status, 0);
    const code: u8 = if ((status & 0x7f) != 0) 128 else @intCast((status >> 8) & 0xff);
    return .{ .out = data, .code = code };
}

fn sha256File(init: std.process.Init, path: []const u8) ?[]const u8 {
    const r = exec(init, null, &.{ "sha256sum", "--", path }) orelse return null;
    if (r.code != 0 or r.out.len < 64) return null;
    for (r.out[0..64]) |c| if (!std.ascii.isHex(c)) return null;
    return r.out[0..64];
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
// path resolution — same rules as aurev/gf/zish
// ---------------------------------------------------------------------------

fn featRootPath(init: std.process.Init, buf: []u8) ?[]const u8 {
    if (feat.env(init.arena.allocator(), init.io, "ZISH_FEAT_PATH")) |p| return p;
    const home = feat.env(init.arena.allocator(), init.io, "HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.zish/feats", .{home}) catch null;
}

fn resolveAgentBin(root: []const u8, buf: []u8) ?[]const u8 {
    for ([_][]const u8{ "standard", "extra" }) |tier| {
        const p = std.fmt.bufPrint(buf, "{s}/{s}/agent/bin/agent", .{ root, tier }) catch continue;
        if (exists(p)) return p;
    }
    return null;
}

/// One AUR-review store, keyed by PKGBUILD content hash, shared by both verbs.
/// A diff reviewed via `aur review` and a full PKGBUILD reviewed via `aur check`
/// are different bytes → different hashes, so they never collide; they just
/// live in the same ledger. (The file keeps its historical `aurev.jsonl` name.)
fn ledgerPath(init: std.process.Init, buf: []u8) ?[]const u8 {
    const home = feat.env(init.arena.allocator(), init.io, "HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.zish/aurev.jsonl", .{home}) catch null;
}

// ---------------------------------------------------------------------------
// crypto — an ed25519 ssh key vouches for a verdict, so a peer can REUSE it
// instead of paying tokens to re-judge the same bytes. One key is the author's
// identity (and, later, wallet); the same key signs published feat tags.
//
//   sign   : ZISH_SIGN_KEY   = path to an ssh ed25519 private key
//            ZISH_SIGNER_ID   = the identity recorded beside it (e.g. an email)
//   verify : ZISH_SIGNERS     = an ssh allowed_signers file — the trust set
//   pull   : ZISH_REVIEW_FEEDS = comma-separated URLs of peers' ledgers
//
// The signed message binds the verdict to the exact bytes it judged:
//     <sha256> LF <result-json>
// so a signature can't be lifted onto a different PKGBUILD or a different
// verdict. Signing is fail-open (no key ⇒ recorded unsigned, usable locally but
// not shareable); verifying is fail-closed (a feed verdict is trusted ONLY if
// its signature checks out against a signer we list).
// ---------------------------------------------------------------------------
const SIGN_NS = "zish-review";

fn sigTempPath(init: std.process.Init, buf: []u8, tag: []const u8) ?[]const u8 {
    const home = feat.env(init.arena.allocator(), init.io, "HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.zish/.sig-{s}-{d}", .{ home, tag, linux.getpid() }) catch null;
}

/// Write the canonical signed message `<rubric>\n<sha>\n<result>` to `path`
/// (0600). The rubric is bound in so a verdict signed under one grading sheet
/// (or format version) never verifies under another — the wire format is
/// versioned by `rubric`.
fn writeSignMsg(path: []const u8, rubric: []const u8, sha: []const u8, result: []const u8) bool {
    var m: std.ArrayListUnmanaged(u8) = .empty;
    defer m.deinit(alloc);
    m.appendSlice(alloc, rubric) catch return false;
    m.append(alloc, '\n') catch return false;
    m.appendSlice(alloc, sha) catch return false;
    m.append(alloc, '\n') catch return false;
    m.appendSlice(alloc, result) catch return false;
    return writeFileMode(path, m.items, 0o600);
}

/// Run env+args with `stdin_path` as fd0 and stdout/stderr sent to /dev/null
/// (ssh-keygen's own chatter must not pollute aur's output). Returns exit code.
fn execStdinFile(init: std.process.Init, stdin_path: []const u8, args: []const []const u8) u8 {
    var argv: [40]?[*:0]const u8 = undefined;
    var held: [40][]u8 = undefined;
    var nh: usize = 0;
    var n: usize = 0;
    const dupz = struct {
        fn z(s: []const u8, h: [][]u8, nhp: *usize, av: []?[*:0]const u8, np: *usize) bool {
            const dz = alloc.dupeZ(u8, s) catch return false;
            h[nhp.*] = dz;
            nhp.* += 1;
            av[np.*] = dz.ptr;
            np.* += 1;
            return true;
        }
    }.z;
    defer for (held[0..nh]) |h| alloc.free(h);
    if (!dupz("env", &held, &nh, &argv, &n)) return 127;
    for (args) |a| if (n >= argv.len - 1 or !dupz(a, &held, &nh, &argv, &n)) return 127;
    argv[n] = null;
    const argvz: [*:null]const ?[*:0]const u8 = argv[0..n :null];
    var iz: [4096]u8 = undefined;
    const inz = toZ(&iz, stdin_path) orelse return 127;
    const pid_rc = linux.fork();
    const pid: isize = @bitCast(pid_rc);
    if (pid < 0) return 127;
    if (pid == 0) {
        const infd: isize = @bitCast(linux.open(inz, .{ .ACCMODE = .RDONLY }, 0));
        if (infd >= 0) {
            _ = linux.dup2(@intCast(infd), 0);
            _ = linux.close(@intCast(infd));
        }
        const dn: isize = @bitCast(linux.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0));
        if (dn >= 0) {
            _ = linux.dup2(@intCast(dn), 1);
            _ = linux.dup2(@intCast(dn), 2);
            _ = linux.close(@intCast(dn));
        }
        // the inherited environment block, handed to us by the startup (envp)
        _ = linux.execve("/usr/bin/env", argvz, init.minimal.environ.block.slice.ptr);
        linux.exit(127);
    }
    var status: u32 = 0;
    _ = linux.waitpid(@intCast(pid), &status, 0);
    return if ((status & 0x7f) != 0) 128 else @intCast((status >> 8) & 0xff);
}

/// Sign a verdict with the configured ssh key. Returns base64(ssh-signature),
/// or null when no key is set / signing fails (fail-open — caller records the
/// review unsigned).
fn signReview(init: std.process.Init, rubric: []const u8, sha: []const u8, result: []const u8) ?[]u8 {
    const key = feat.env(init.arena.allocator(), init.io, "ZISH_SIGN_KEY") orelse return null;
    var mb: [4096]u8 = undefined;
    const msg = sigTempPath(init, &mb, "sign") orelse return null;
    if (!writeSignMsg(msg, rubric, sha, result)) return null;
    defer unlinkPath(msg);
    // ssh-keygen -Y sign -n <ns> -f <key> <msg>  →  writes <msg>.sig (its
    // "Signing file …" chatter is sent to /dev/null via execStdinFile).
    if (execStdinFile(init, "/dev/null", &.{ "ssh-keygen", "-Y", "sign", "-n", SIGN_NS, "-f", key, msg }) != 0) return null;
    var sb: [4160]u8 = undefined;
    const sigpath = std.fmt.bufPrint(&sb, "{s}.sig", .{msg}) catch return null;
    defer unlinkPath(sigpath);
    const sigraw = readFileAlloc(sigpath, 16384) orelse return null;
    defer alloc.free(sigraw);
    const enc = std.base64.standard.Encoder;
    const buf = alloc.alloc(u8, enc.calcSize(sigraw.len)) catch return null;
    _ = enc.encode(buf, sigraw);
    return buf;
}

/// Verify a peer's signed verdict against the trust set. True only if the
/// signature is valid for `signer` under ZISH_SIGNERS (fail-closed).
fn verifyReview(init: std.process.Init, rubric: []const u8, signer: []const u8, sig_b64: []const u8, sha: []const u8, result: []const u8) bool {
    const signers = feat.env(init.arena.allocator(), init.io, "ZISH_SIGNERS") orelse return false;
    if (signer.len == 0 or sig_b64.len == 0) return false;
    const dec = std.base64.standard.Decoder;
    const rawlen = dec.calcSizeForSlice(sig_b64) catch return false;
    const sigraw = alloc.alloc(u8, rawlen) catch return false;
    defer alloc.free(sigraw);
    dec.decode(sigraw, sig_b64) catch return false;
    var sb: [4096]u8 = undefined;
    const sigpath = sigTempPath(init, &sb, "vsig") orelse return false;
    if (!writeFileMode(sigpath, sigraw, 0o600)) return false;
    defer unlinkPath(sigpath);
    var mb: [4096]u8 = undefined;
    const msg = sigTempPath(init, &mb, "vmsg") orelse return false;
    if (!writeSignMsg(msg, rubric, sha, result)) return false;
    defer unlinkPath(msg);
    // ssh-keygen -Y verify -f <signers> -I <signer> -n <ns> -s <sig>  < msg
    return execStdinFile(init, msg, &.{ "ssh-keygen", "-Y", "verify", "-f", signers, "-I", signer, "-n", SIGN_NS, "-s", sigpath }) == 0;
}

/// A verdict for these exact bytes: your own ledger first (trusted as self),
/// then peers' feeds (trusted only after the signature verifies).
// ---------------------------------------------------------------------------
// local reputation — you grade a peer against your OWN verdicts. A signer's
// count ticks up each time their verdict for the same bytes matches yours;
// once it reaches the threshold you REUSE their reviews (skipping your own
// judge call — the token saving), and a single disagreement resets it to 0.
// Purely local: no scores shared, no global benchmark. `~/.zish/aur-trust.jsonl`
// is append-only; the last line for a signer wins.
// ---------------------------------------------------------------------------
fn trustThreshold(init: std.process.Init) usize {
    if (feat.env(init.arena.allocator(), init.io, "ZISH_TRUST_AT")) |v| return std.fmt.parseInt(usize, v, 10) catch 3;
    return 3;
}

fn repPath(init: std.process.Init, buf: []u8) ?[]const u8 {
    const home = feat.env(init.arena.allocator(), init.io, "HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.zish/aur-trust.jsonl", .{home}) catch null;
}

fn repGet(init: std.process.Init, signer: []const u8) usize {
    if (signer.len == 0) return 0;
    var pb: [4096]u8 = undefined;
    const p = repPath(init, &pb) orelse return 0;
    const content = readFileAlloc(p, MAX_OUT) orelse return 0;
    defer alloc.free(content);
    var rep: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |ln| {
        const line = std.mem.trim(u8, ln, " \t\r");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        defer parsed.deinit();
        const s = objStr(parsed.value, "signer") orelse continue;
        if (!std.mem.eql(u8, s, signer)) continue;
        rep = blk: {
            const ob = switch (parsed.value) {
                .object => |o| o,
                else => break :blk rep,
            };
            break :blk switch (ob.get("rep") orelse break :blk rep) {
                .integer => |iv| if (iv < 0) 0 else @intCast(iv),
                else => rep,
            };
        };
    }
    return rep;
}

fn repSet(init: std.process.Init, signer: []const u8, n: usize) void {
    if (signer.len == 0) return;
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(alloc);
    line.appendSlice(alloc, "{\"signer\":\"") catch return;
    appendJsonStr(&line, signer) catch return;
    var nb: [32]u8 = undefined;
    line.appendSlice(alloc, std.fmt.bufPrint(&nb, "\",\"rep\":{d}}}\n", .{n}) catch return) catch return;
    var pb: [4096]u8 = undefined;
    const p = repPath(init, &pb) orelse return;
    var z: [4096]u8 = undefined;
    const pz = toZ(&z, p) orelse return;
    const fd_rc = linux.open(pz, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o600);
    const fd: isize = @bitCast(fd_rc);
    if (fd < 0) return;
    defer _ = linux.close(@intCast(fd));
    writeFd(@intCast(fd), line.items);
}

fn findInLedger(init: std.process.Init, sha: []const u8) ?[]u8 {
    var lb: [4096]u8 = undefined;
    const lp = ledgerPath(init, &lb) orelse return null;
    const content = readFileAlloc(lp, MAX_OUT) orelse return null;
    defer alloc.free(content);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |ln| {
        const line = std.mem.trim(u8, ln, " \t\r");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        defer parsed.deinit();
        const rsha = objStr(parsed.value, "sha256") orelse continue;
        if (!std.mem.eql(u8, rsha, sha)) continue;
        // a verdict is bound to the rubric it was graded under; only our rubric
        // answers our question, even for the same bytes
        const rrub = objStr(parsed.value, "rubric") orelse continue;
        if (!std.mem.eql(u8, rrub, RUBRIC)) continue;
        const res = objStr(parsed.value, "result") orelse continue;
        return alloc.dupe(u8, res) catch null;
    }
    return null;
}

/// A peer ledger fetched at most once per process. `body` is null when the
/// fetch failed (a cached negative, so a broken feed isn't retried per package).
const FeedEntry = struct { url: []u8, body: ?[]u8 };
var feed_cache: std.ArrayListUnmanaged(FeedEntry) = .empty;

fn feedBody(init: std.process.Init, url: []const u8) ?[]const u8 {
    for (feed_cache.items) |e| if (std.mem.eql(u8, e.url, url)) return e.body;
    var body: ?[]u8 = null;
    if (exec(init, null, &.{ "curl", "-fsSL", "--max-time", "30", "--proto", "=http,https,file", url })) |r| {
        if (r.code == 0) body = r.out else alloc.free(r.out);
    }
    const ku = alloc.dupe(u8, url) catch return body;
    feed_cache.append(alloc, .{ .url = ku, .body = body }) catch {};
    return body;
}

const FeedVerdict = struct { signer: []u8, result: []u8 };

fn freeFeedVerdicts(list: *std.ArrayListUnmanaged(FeedVerdict)) void {
    for (list.items) |fv| {
        alloc.free(fv.signer);
        alloc.free(fv.result);
    }
    list.deinit(alloc);
}

/// Gather every verified peer verdict for `sha` across all feeds: graded under
/// our rubric AND signature valid against our trust set. Whether to REUSE one
/// is a separate, reputation-gated decision (see reviewPkgbuild).
fn collectFeedVerdicts(init: std.process.Init, sha: []const u8, out_list: *std.ArrayListUnmanaged(FeedVerdict)) void {
    const feeds = feat.env(init.arena.allocator(), init.io, "ZISH_REVIEW_FEEDS") orelse return;
    var it = std.mem.splitScalar(u8, feeds, ',');
    while (it.next()) |raw| {
        const url = std.mem.trim(u8, raw, " \t");
        if (url.len == 0) continue;
        const body = feedBody(init, url) orelse continue;
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |ln| {
            const line = std.mem.trim(u8, ln, " \t\r");
            if (line.len == 0) continue;
            const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
            defer parsed.deinit();
            const rsha = objStr(parsed.value, "sha256") orelse continue;
            if (!std.mem.eql(u8, rsha, sha)) continue;
            const rrub = objStr(parsed.value, "rubric") orelse continue;
            if (!std.mem.eql(u8, rrub, RUBRIC)) continue;
            const res = objStr(parsed.value, "result") orelse continue;
            const signer = objStr(parsed.value, "signer") orelse "";
            const sig = objStr(parsed.value, "sig") orelse "";
            if (!verifyReview(init, RUBRIC, signer, sig, sha, res)) continue;
            const sdup = alloc.dupe(u8, signer) catch continue;
            const rdup = alloc.dupe(u8, res) catch {
                alloc.free(sdup);
                continue;
            };
            out_list.append(alloc, .{ .signer = sdup, .result = rdup }) catch {
                alloc.free(sdup);
                alloc.free(rdup);
            };
        }
    }
}

fn recordReview(init: std.process.Init, sha: []const u8, verdict_word: []const u8, verdict_raw: []const u8) void {
    const model = feat.env(init.arena.allocator(), init.io, "ZISH_JUDGE_MODEL") orelse "deepseek/deepseek-v4-flash-0731";
    // Canonicalize the result to exactly the bytes we store (control chars
    // dropped, same as appendJsonStr) so the signature covers what a verifier
    // reconstructs from the stored line.
    var canon: std.ArrayListUnmanaged(u8) = .empty;
    defer canon.deinit(alloc);
    for (verdict_raw) |c| if (c >= 0x20) (canon.append(alloc, c) catch return);
    const signer = feat.env(init.arena.allocator(), init.io, "ZISH_SIGNER_ID") orelse "";
    const sig = signReview(init, RUBRIC, sha, canon.items);
    defer if (sig) |s| alloc.free(s);

    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(alloc);
    line.appendSlice(alloc, "{\"t\":\"review\",\"kind\":\"pkgbuild\",\"sha256\":\"") catch return;
    appendJsonStr(&line, sha) catch return;
    line.appendSlice(alloc, "\",\"rubric\":\"" ++ RUBRIC ++ "\",\"reviewer\":\"") catch return;
    appendJsonStr(&line, model) catch return;
    line.appendSlice(alloc, "\",\"verdict\":\"") catch return;
    appendJsonStr(&line, verdict_word) catch return;
    line.appendSlice(alloc, "\",\"signer\":\"") catch return;
    appendJsonStr(&line, signer) catch return;
    line.appendSlice(alloc, "\",\"sig\":\"") catch return;
    if (sig) |s| appendJsonStr(&line, s) catch return;
    line.appendSlice(alloc, "\",\"result\":\"") catch return;
    appendJsonStr(&line, canon.items) catch return;
    var tb: [32]u8 = undefined;
    line.appendSlice(alloc, std.fmt.bufPrint(&tb, "\",\"ts\":{d}}}\n", .{nowSeconds()}) catch return) catch return;

    var lb: [4096]u8 = undefined;
    const lp = ledgerPath(init, &lb) orelse return;
    var z: [4096]u8 = undefined;
    const p = toZ(&z, lp) orelse return;
    const fd_rc = linux.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o600);
    const fd: isize = @bitCast(fd_rc);
    if (fd < 0) return;
    defer _ = linux.close(@intCast(fd));
    writeFd(@intCast(fd), line.items);
}

// ---------------------------------------------------------------------------
// review of one PKGBUILD
// ---------------------------------------------------------------------------

const Outcome = enum { pass, fail, unreviewable };

const Reviewed = struct {
    outcome: Outcome,
    /// raw verdict JSON (owned), or "" when unreviewable
    verdict: []u8,
    cached: bool,
};

/// Judge a single PKGBUILD file: cache read by content hash, else a fresh
/// `agent --judge`. Never installs anything.
fn reviewPkgbuild(init: std.process.Init, agent_bin: ?[]const u8, rubric: ?[]const u8, path: []const u8) Reviewed {
    const sha = sha256File(init, path) orelse "";

    // 1. our own prior verdict for these exact bytes — always trusted, free
    if (sha.len > 0) {
        if (findInLedger(init, sha)) |cached| {
            const word = verdictWord(cached);
            return .{ .outcome = wordOutcome(word), .verdict = cached, .cached = true };
        }
    }

    // 2. every verified peer verdict for these bytes (signature + rubric checked)
    var feeds: std.ArrayListUnmanaged(FeedVerdict) = .empty;
    defer freeFeedVerdicts(&feeds);
    if (sha.len > 0) collectFeedVerdicts(init, sha, &feeds);

    // 3. a peer we've locally vetted (rep >= threshold) → REUSE, skip the judge.
    // This is the token saving: once earned, their signature stands in for a call.
    const thresh = trustThreshold(init);
    for (feeds.items) |fv| {
        if (repGet(init, fv.signer) >= thresh) {
            const word = verdictWord(fv.result);
            const dup = alloc.dupe(u8, fv.result) catch
                return .{ .outcome = .unreviewable, .verdict = &.{}, .cached = false };
            return .{ .outcome = wordOutcome(word), .verdict = dup, .cached = true };
        }
    }

    // 4. no vetted peer: judge ourselves (the bootstrap cost). Needs agent+rubric.
    const abin = agent_bin orelse return .{ .outcome = .unreviewable, .verdict = &.{}, .cached = false };
    const rub = rubric orelse return .{ .outcome = .unreviewable, .verdict = &.{}, .cached = false };

    var args: [8][]const u8 = undefined;
    var n: usize = 0;
    args[n] = abin;
    n += 1;
    if (feat.env(init.arena.allocator(), init.io, "ZISH_JUDGE_MOCK")) |m| {
        args[n] = "--mock";
        n += 1;
        args[n] = m;
        n += 1;
    }
    args[n] = "--judge";
    n += 1;
    args[n] = rub;
    n += 1;
    args[n] = path;
    n += 1;

    const r = exec(init, null, args[0..n]) orelse
        return .{ .outcome = .unreviewable, .verdict = &.{}, .cached = false };
    if (r.code != 0 or r.out.len == 0 or r.out[0] != '{')
        return .{ .outcome = .unreviewable, .verdict = &.{}, .cached = false };

    const word = verdictWord(r.out);
    if (std.mem.eql(u8, word, "unknown"))
        return .{ .outcome = .unreviewable, .verdict = r.out, .cached = false };

    // 5. calibrate peers against our own verdict: agreement ticks the signer's
    // count up (toward being trusted enough to reuse), a disagreement resets it.
    for (feeds.items) |fv| {
        if (std.mem.eql(u8, verdictWord(fv.result), word))
            repSet(init, fv.signer, repGet(init, fv.signer) + 1)
        else
            repSet(init, fv.signer, 0);
    }

    if (sha.len > 0) recordReview(init, sha, word, r.out);
    return .{ .outcome = wordOutcome(word), .verdict = r.out, .cached = false };
}

fn verdictWord(verdict_raw: []const u8) []const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, verdict_raw, .{}) catch return "unknown";
    defer parsed.deinit();
    const w = objStr(parsed.value, "verdict") orelse return "unknown";
    // Return a stable literal, never the slice into `parsed` (freed on defer).
    if (std.mem.eql(u8, w, "pass")) return "pass";
    if (std.mem.eql(u8, w, "fail")) return "fail";
    return "unknown";
}

fn wordOutcome(word: []const u8) Outcome {
    if (std.mem.eql(u8, word, "pass")) return .pass;
    if (std.mem.eql(u8, word, "fail")) return .fail;
    return .unreviewable;
}

// ---------------------------------------------------------------------------
// fetching PKGBUILDs (drive the user's helper, don't reimplement it)
// ---------------------------------------------------------------------------

/// Fetch the incoming PKGBUILD for `pkg` into `base_dir` via `<helper> -G` and
/// return the path to it. The helper clones the package's build files into a
/// subdir named after the pkgbase; for the common case (pkgbase == pkgname)
/// that is `base_dir/pkg/PKGBUILD`. Otherwise we walk one level to find the
/// single cloned dir's PKGBUILD. Returns null if the fetch failed.
fn fetchPkgbuild(init: std.process.Init, helper: []const u8, base_dir: []const u8, pkg: []const u8, buf: []u8) ?[]const u8 {
    const r = exec(init, base_dir, &.{ helper, "-G", "--", pkg }) orelse return null;
    alloc.free(r.out);
    if (r.code != 0) return null;

    // fast path: pkgbase == pkgname (the common case)
    const direct = std.fmt.bufPrint(buf, "{s}/{s}/PKGBUILD", .{ base_dir, pkg }) catch return null;
    if (exists(direct)) return direct;

    // fallback (split packages: the clone dir is the pkgbase, not the pkgname):
    // let `find` locate the single fetched PKGBUILD rather than walk dirents.
    const f = exec(init, null, &.{ "find", base_dir, "-maxdepth", "2", "-name", "PKGBUILD", "-type", "f" }) orelse return null;
    defer alloc.free(f.out);
    if (f.code != 0) return null;
    var flines = std.mem.splitScalar(u8, f.out, '\n');
    while (flines.next()) |ln| {
        const path = std.mem.trim(u8, ln, " \t\r");
        if (path.len == 0) continue;
        if (path.len >= buf.len) continue;
        @memcpy(buf[0..path.len], path);
        return buf[0..path.len];
    }
    return null;
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

/// Full verdict block for `aur review` (the pager): verdict badge, scores,
/// analysis — printed above the diff. `cached` marks a prior verdict for the
/// same bytes served from the ledger.
fn printHeader(verdict_raw: []const u8, cached: bool) void {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, verdict_raw, .{}) catch return;
    defer parsed.deinit();
    const verdict = objStr(parsed.value, "verdict") orelse "unknown";
    const analysis = objStr(parsed.value, "analysis") orelse "";
    const col = feat.isTty(1);

    var b: std.ArrayListUnmanaged(u8) = .empty;
    defer b.deinit(alloc);
    const rule = "\xe2\x94\x81" ** 3; // ━━━
    b.appendSlice(alloc, if (col) C.dim else "") catch {};
    b.appendSlice(alloc, rule ++ " aur") catch {};
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

    // A closed-blob package is unverifiable, not unsafe: a pass here covers the
    // packaging + pinned provenance, never the payload. Say so plainly rather
    // than dressing trust-the-vendor up as an audit.
    if (std.mem.eql(u8, objStr(parsed.value, "auditability") orelse "", "blob")) {
        b.appendSlice(alloc, if (col) C.yellow else "") catch {};
        b.appendSlice(alloc, "  payload: closed binary — packaging + provenance only, code NOT audited\n") catch {};
        b.appendSlice(alloc, if (col) C.reset else "") catch {};
    }

    if (switch (parsed.value) {
        .object => |ob| ob.get("scores"),
        else => null,
    }) |sc| {
        if (sc == .object) {
            b.appendSlice(alloc, "  scores:") catch {};
            var sit = sc.object.iterator();
            while (sit.next()) |e| {
                b.appendSlice(alloc, " ") catch {};
                b.appendSlice(alloc, e.key_ptr.*) catch {};
                const nv: i64 = switch (e.value_ptr.*) {
                    .integer => |iv| iv,
                    else => -1,
                };
                var nb: [12]u8 = undefined;
                b.appendSlice(alloc, std.fmt.bufPrint(&nb, " {d}/10", .{nv}) catch "") catch {};
            }
            b.appendSlice(alloc, "\n") catch {};
        }
    }

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

fn auditabilityIsBlob(verdict_raw: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, verdict_raw, .{}) catch return false;
    defer parsed.deinit();
    return std.mem.eql(u8, objStr(parsed.value, "auditability") orelse "", "blob");
}

fn scoresInline(b: *std.ArrayListUnmanaged(u8), verdict_raw: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, verdict_raw, .{}) catch return;
    defer parsed.deinit();
    const sc = switch (parsed.value) {
        .object => |ob| ob.get("scores") orelse return,
        else => return,
    };
    if (sc != .object) return;
    b.appendSlice(alloc, " (") catch {};
    var it = sc.object.iterator();
    var first = true;
    while (it.next()) |e| {
        if (!first) b.appendSlice(alloc, " ") catch {};
        first = false;
        b.appendSlice(alloc, e.key_ptr.*) catch {};
        const nv: i64 = switch (e.value_ptr.*) {
            .integer => |iv| iv,
            else => -1,
        };
        var nb: [8]u8 = undefined;
        b.appendSlice(alloc, std.fmt.bufPrint(&nb, " {d}", .{nv}) catch "") catch {};
    }
    b.appendSlice(alloc, ")") catch {};
}

fn printLine(pkg: []const u8, rv: Reviewed, col: bool) void {
    var b: std.ArrayListUnmanaged(u8) = .empty;
    defer b.deinit(alloc);
    b.appendSlice(alloc, "  ") catch {};
    switch (rv.outcome) {
        .pass => {
            b.appendSlice(alloc, if (col) C.green ++ C.bold else "") catch {};
            b.appendSlice(alloc, "PASS") catch {};
        },
        .fail => {
            b.appendSlice(alloc, if (col) C.red ++ C.bold else "") catch {};
            b.appendSlice(alloc, "FAIL") catch {};
        },
        .unreviewable => {
            b.appendSlice(alloc, if (col) C.yellow ++ C.bold else "") catch {};
            b.appendSlice(alloc, "SKIP") catch {};
        },
    }
    b.appendSlice(alloc, if (col) C.reset else "") catch {};
    b.appendSlice(alloc, " ") catch {};
    b.appendSlice(alloc, pkg) catch {};
    if (rv.cached) b.appendSlice(alloc, if (col) C.dim ++ " (cached)" ++ C.reset else " (cached)") catch {};
    if (rv.verdict.len > 0 and rv.outcome != .unreviewable) {
        b.appendSlice(alloc, if (col) C.dim else "") catch {};
        scoresInline(&b, rv.verdict);
        if (auditabilityIsBlob(rv.verdict))
            b.appendSlice(alloc, " · blob (unaudited payload)") catch {};
        b.appendSlice(alloc, if (col) C.reset else "") catch {};
    }
    b.appendSlice(alloc, "\n") catch {};
    out(b.items);
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) u8 {
    // Full Init installs a no-op SIGPIPE handler; a filter must die on a closed
    // stdout like every other CLI, so restore the default before doing anything.
    feat.restoreSigpipe();
    return run(init);
}

fn run(init: std.process.Init) u8 {
    var verb: ?[]const u8 = null;
    var json = false;
    var targets: std.ArrayListUnmanaged([]const u8) = .empty;
    defer targets.deinit(alloc);
    var it = init.minimal.args.iterate();
    _ = it.next(); // skip argv[0]
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            printHelp();
            return 0;
        } else if (verb == null and (std.mem.eql(u8, a, "check") or std.mem.eql(u8, a, "review"))) {
            verb = a;
        } else if (verb != null and std.mem.eql(u8, verb.?, "check") and a.len > 0 and a[0] != '-') {
            // bare args after `check` are package targets (pacman-style)
            targets.append(alloc, a) catch {};
        } else {
            warn("aur: unknown argument\n");
            return 2;
        }
    }
    if (verb) |v| {
        if (std.mem.eql(u8, v, "review")) return reviewPager(init);
        return checkGate(init, json, targets.items);
    }
    // No verb: act as a pager when stdin is piped (so a bare `PAGER=aur` in
    // yay's config just works); otherwise show help.
    if (!feat.isTty(0)) return reviewPager(init);
    printHelp();
    return 0;
}

fn printHelp() void {
    out(
        \\aur — PKGBUILD review: a gate for upgrades, a pager for diffs.
        \\
        \\  aur check [pkg...] [--json]
        \\                       review PKGBUILDs before they build. No targets = every
        \\                       pending AUR update (the sysupgrade sense); with targets,
        \\                       just those packages (pacman-style).
        \\                       exit 0 = all pass, 1 = a failure, 2 = unreviewable.
        \\                       compose as a gate:  aur check && yay -Syu
        \\                                   or:     aur check foo bar && yay -S foo bar
        \\
        \\  aur review           review a PKGBUILD diff on stdin: print the verdict, then the
        \\                       diff (a pager for yay). set:  PAGER="aur review"
        \\                       advisory + fail-open — no reviewer just shows the raw diff.
        \\
    );
}

// ---------------------------------------------------------------------------
// `aur review` — the pager (was the aurev feat). Advisory, FAIL-OPEN: the diff
// is ALWAYS printed, review or no review, so it never breaks yay's flow.
// ---------------------------------------------------------------------------

fn reviewPager(init: std.process.Init) u8 {
    const input = slurp(0, MAX_OUT);
    if (input.len == 0) return 0; // nothing piped in

    var shown = false;
    defer {
        if (!shown) warn("aur: review unavailable, showing raw diff\n");
        out(input);
    }

    // Resolve the agent + rubric if present, but do NOT bail when they're
    // missing: a cached or peer-signed verdict for these bytes needs neither.
    var rootb: [4096]u8 = undefined;
    var agentb: [4096]u8 = undefined;
    var rubb: [4096]u8 = undefined;
    const agent_bin: ?[]const u8 = if (featRootPath(init, &rootb)) |root| resolveAgentBin(root, &agentb) else null;
    // Override file if one is configured, else the sheet compiled into this
    // binary; the judge wants a PATH, so either way the bytes are spilled.
    const rub_bytes = feat.rubric(init.arena.allocator(), init.io, RUBRIC ++ ".toml", @embedFile("rubrics/pkgbuild-review-v1.toml"));
    const rubric: ?[]const u8 = if (rub_bytes) |b|
        feat.spillTemp(init.arena.allocator(), init.io, &rubb, "aur-rubric", b)
    else
        null;
    defer {
        if (rubric) |p| feat.unlink(p);
    }

    const home = feat.env(init.arena.allocator(), init.io, "HOME") orelse return 0;
    var subjb: [4096]u8 = undefined;
    const subj = std.fmt.bufPrint(&subjb, "{s}/.zish/.aur_review_{d}", .{ home, linux.getpid() }) catch return 0;
    if (!writeFileMode(subj, input, 0o600)) return 0;
    defer unlinkPath(subj);

    const rv = reviewPkgbuild(init, agent_bin, rubric, subj);
    defer if (rv.verdict.len > 0) alloc.free(rv.verdict);
    if (rv.verdict.len > 0) {
        printHeader(rv.verdict, rv.cached);
        shown = true;
    }
    return 0;
}

fn checkGate(init: std.process.Init, json: bool, targets: []const []const u8) u8 {
    const col = feat.isTty(1) and !json;
    const helper = feat.env(init.arena.allocator(), init.io, "AUR_HELPER") orelse "yay";

    var pkgs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer pkgs.deinit(alloc);
    var list_out: ?[]u8 = null; // kept alive: pkgs slices point into it
    defer if (list_out) |o| alloc.free(o);

    if (targets.len > 0) {
        // targeted gate (pacman-style targets): review exactly these packages,
        // whether or not they have a pending update.
        for (targets) |t| pkgs.append(alloc, t) catch {};
    } else {
        // no targets = the sysupgrade sense: every pending AUR update.
        // `-Qua -q` prints one bare package name per line; a non-zero exit with
        // no output means "nothing to upgrade", which is success, not failure.
        const list = exec(init, null, &.{ helper, "-Qua", "-q" }) orelse {
            warn("aur: could not run the AUR helper (");
            warn(helper);
            warn("). set AUR_HELPER if it is named differently.\n");
            return 2;
        };
        list_out = list.out;
        var lines = std.mem.splitScalar(u8, list.out, '\n');
        while (lines.next()) |ln| {
            const name = std.mem.trim(u8, ln, " \t\r");
            if (name.len == 0) continue;
            pkgs.append(alloc, name) catch {};
        }

        if (pkgs.items.len == 0) {
            if (json) out("[]\n") else out("aur: no pending AUR updates.\n");
            return 0;
        }
    }

    // The gate needs a reviewer. If it is not available, FAIL CLOSED (loud,
    // nonzero) — a gate that waves things through when it cannot read them is
    // not a gate. The user keeps the manual override of running the helper
    // directly.
    var rootb: [4096]u8 = undefined;
    const root = featRootPath(init, &rootb) orelse {
        warn("aur: no feat root (HOME unset).\n");
        return 2;
    };
    var agentb: [4096]u8 = undefined;
    const agent_bin = resolveAgentBin(root, &agentb) orelse {
        warn("aur: agent feat not installed — cannot review, refusing to wave the build through.\n");
        warn("     install it, or override with the helper directly.\n");
        return 2;
    };
    var rubb: [4096]u8 = undefined;
    const rubric_bytes = feat.rubric(init.arena.allocator(), init.io, RUBRIC ++ ".toml", @embedFile("rubrics/pkgbuild-review-v1.toml")) orelse {
        warn("aur: pkgbuild-review rubric not found — cannot review.\n");
        return 2;
    };
    const rubric = feat.spillTemp(init.arena.allocator(), init.io, &rubb, "aur-rubric", rubric_bytes) orelse {
        warn("aur: cannot stage the pkgbuild-review rubric — cannot review.\n");
        return 2;
    };
    defer feat.unlink(rubric);

    // scratch clone dir for fetched PKGBUILDs
    var baseb: [256]u8 = undefined;
    const base_dir = std.fmt.bufPrint(&baseb, "/tmp/aur-check-{d}", .{linux.getpid()}) catch return 2;
    var basez: [256]u8 = undefined;
    if (toZ(&basez, base_dir)) |bz| _ = linux.mkdir(bz, 0o700);
    defer {
        const rm = exec(init, null, &.{ "rm", "-rf", "--", base_dir });
        if (rm) |r| alloc.free(r.out);
    }

    if (!json) {
        var hb: [128]u8 = undefined;
        out(std.fmt.bufPrint(&hb, "aur: reviewing {d} pending AUR update(s)...\n", .{pkgs.items.len}) catch "");
    }

    var any_fail = false;
    var any_unrev = false;
    var jb: std.ArrayListUnmanaged(u8) = .empty;
    defer jb.deinit(alloc);
    if (json) jb.appendSlice(alloc, "[") catch {};

    for (pkgs.items, 0..) |pkg, i| {
        var pathb: [4096]u8 = undefined;
        const rv = blk: {
            const pb = fetchPkgbuild(init, helper, base_dir, pkg, &pathb) orelse
                break :blk Reviewed{ .outcome = .unreviewable, .verdict = &.{}, .cached = false };
            break :blk reviewPkgbuild(init, agent_bin, rubric, pb);
        };
        defer if (rv.verdict.len > 0) alloc.free(rv.verdict);

        switch (rv.outcome) {
            .fail => any_fail = true,
            .unreviewable => any_unrev = true,
            .pass => {},
        }

        if (json) {
            if (i != 0) jb.appendSlice(alloc, ",") catch {};
            jb.appendSlice(alloc, "{\"pkg\":\"") catch {};
            appendJsonStr(&jb, pkg) catch {};
            jb.appendSlice(alloc, "\",\"verdict\":\"") catch {};
            jb.appendSlice(alloc, switch (rv.outcome) {
                .pass => "pass",
                .fail => "fail",
                .unreviewable => "unreviewable",
            }) catch {};
            jb.appendSlice(alloc, "\",\"cached\":") catch {};
            jb.appendSlice(alloc, if (rv.cached) "true" else "false") catch {};
            jb.appendSlice(alloc, "}") catch {};
        } else {
            printLine(pkg, rv, col);
        }
    }

    if (json) {
        jb.appendSlice(alloc, "]\n") catch {};
        out(jb.items);
    } else {
        if (any_fail) {
            out(if (col) C.red ++ C.bold ++ "aur: review failed — blocking upgrade.\n" ++ C.reset else "aur: review failed — blocking upgrade.\n");
        } else if (any_unrev) {
            out(if (col) C.yellow ++ "aur: some packages could not be reviewed — blocking upgrade.\n" ++ C.reset else "aur: some packages could not be reviewed — blocking upgrade.\n");
        } else {
            out(if (col) C.green ++ C.bold ++ "aur: all pending PKGBUILDs pass.\n" ++ C.reset else "aur: all pending PKGBUILDs pass.\n");
        }
    }

    if (any_fail) return 1;
    if (any_unrev) return 2;
    return 0;
}
