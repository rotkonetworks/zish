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

fn rmRf(path: []const u8) void {
    var z: [4096]u8 = undefined;
    const p = toZ(&z, path) orelse return;
    const argv = [_:null]?[*:0]const u8{ "env", "rm", "-rf", "--", p, null };
    _ = execStatus(&argv);
}

// ===========================================================================
// validation of the extracted tree
// ===========================================================================

const S_IFMT: u32 = 0o170000;
const S_IFREG: u32 = 0o100000;
const S_IFDIR: u32 = 0o040000;

/// Enforce the exact allowed shape: feat.toml (regular) + bin/ (dir) holding
/// only regular files, one of which is `bin_name`. Anything else — symlinks
/// above all — refuses the install. Returns null on pass, message on refusal.
fn validateTree(tmp: []const u8, bin_name: []const u8) ?[]const u8 {
    var pbuf: [4096]u8 = undefined;

    const mf = std.fmt.bufPrint(&pbuf, "{s}/feat.toml", .{tmp}) catch return "path too long";
    const mf_mode = lstatMode(mf) orelse return "archive has no feat.toml";
    if (mf_mode & S_IFMT != S_IFREG) return "feat.toml is not a regular file";

    const bin_dir = std.fmt.bufPrint(&pbuf, "{s}/bin", .{tmp}) catch return "path too long";
    const bd_mode = lstatMode(bin_dir) orelse return "archive has no bin/ directory";
    if (bd_mode & S_IFMT != S_IFDIR) return "bin is not a directory";

    // top level: nothing but feat.toml and bin
    var names_buf: [64][]u8 = undefined;
    const top = listDir(tmp, &names_buf) orelse return "cannot open archive dir";
    for (top) |n| {
        if (std.mem.eql(u8, n, "feat.toml") or std.mem.eql(u8, n, "bin")) continue;
        return "archive contains files outside feat.toml + bin/";
    }

    // bin/: regular files only (lstat: a symlink here is the install attack)
    var found_bin = false;
    var bnames_buf: [64][]u8 = undefined;
    const bins = listDir(bin_dir, &bnames_buf) orelse return "cannot open bin dir";
    for (bins) |n| {
        var fbuf: [4096]u8 = undefined;
        const fp = std.fmt.bufPrint(&fbuf, "{s}/{s}", .{ bin_dir, n }) catch return "path too long";
        const m = lstatMode(fp) orelse return "unreadable file in bin/";
        if (m & S_IFMT != S_IFREG) return "bin/ contains a non-regular file (symlink?)";
        if (std.mem.eql(u8, n, bin_name)) found_bin = true;
    }
    if (!found_bin) return "bin/ does not contain the manifest's bin";
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
// main
// ===========================================================================

pub fn main(init: std.process.Init.Minimal) void {
    linux.exit(run(init));
}

fn run(init: std.process.Init.Minimal) u8 {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next(); // argv0
    const url = args.next() orelse {
        print("usage: gf <url>\nfetch a feat tarball and install it into the extra tier\n", .{});
        return 1;
    };
    if (args.next() != null) return fail("unexpected extra argument", .{});

    // feat root: same resolution as zish (ZISH_FEAT_PATH overrides)
    var root_buf: [4096]u8 = undefined;
    const root = if (getEnv("ZISH_FEAT_PATH")) |p|
        p
    else blk: {
        const home = getEnv("HOME") orelse return fail("no HOME", .{});
        break :blk std.fmt.bufPrint(&root_buf, "{s}/.zish/feats", .{home}) catch return fail("HOME too long", .{});
    };
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

    if (validateTree(tmp, bin_name)) |why| return fail("{s}", .{why});
    if (shadowsPath(name)) return fail("name {s} collides with an installed command — a feat never shadows a real binary", .{name});

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

    print(
        "gf: installed {s} into the extra tier: {s}\n" ++
            "    extra feats run quarantined: stripped environment, never as root,\n" ++
            "    and session feats get no run/prompt hostcalls.\n" ++
            "    to promote after you trust it:  mv {s} {s}/standard/{s}\n",
        .{ name, dest, dest, root, name },
    );
    return 0;
}
