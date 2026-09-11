//! verify — compile-check a snippet of code in whatever language its fence names,
//! using whatever compiler is installed. A reusable org primitive: `team` calls
//! it as the verifier member, but you can pipe any code to it directly.
//!
//!   verify caps                 → list the languages this host can check
//!   echo "<code>" | verify zig  → compile-check stdin as zig; exit 0 ok / 1 fail
//!   verify rust < file.rs       → same, from a file on stdin
//!
//! It compiles/checks only — it never runs the code. Each checker child is
//! `timeout`-wrapped so a pathological input can't hang. Exit: 0 compiles, 1 does
//! not (diagnostics on stdout), 3 no checker for that language (skip, not fail),
//! 2 usage error.

const std = @import("std");
const linux = std.os.linux;
const feat = @import("lib/feat.zig");
const alloc = std.heap.page_allocator;

const MAX_IN = 4 * 1024 * 1024;

// --- languages this feat knows a compile/check command for ------------------
const Lang = enum { zig, rust, python, go, c, cpp, ts, js, bash, lean, coq, kani };
const ALL = [_]Lang{ .zig, .rust, .python, .go, .c, .cpp, .ts, .js, .bash, .lean, .coq, .kani };

/// Proof oracles differ from compilers: they attest a theorem is proved, so they
/// (a) get a longer default timeout and (b) must reject proof holes — a Lean
/// `sorry` or a Coq `admit`/`Admitted` type-checks but proves nothing, and for a
/// counterfeiting proof "it compiled" ≠ "it holds". Fail closed on holes.
fn isProof(l: Lang) bool {
    return switch (l) {
        .lean, .coq, .kani => true,
        else => false,
    };
}

const Spec = struct { name: []const u8, tags: []const []const u8, ext: []const u8, bin: []const u8 };

fn spec(l: Lang) Spec {
    return switch (l) {
        .zig => .{ .name = "zig", .tags = &.{"zig"}, .ext = "zig", .bin = "zig" },
        .rust => .{ .name = "rust", .tags = &.{ "rust", "rs" }, .ext = "rs", .bin = "rustc" },
        .python => .{ .name = "python", .tags = &.{ "python", "py" }, .ext = "py", .bin = "python3" },
        .go => .{ .name = "go", .tags = &.{ "go", "golang" }, .ext = "go", .bin = "gofmt" },
        .c => .{ .name = "c", .tags = &.{"c"}, .ext = "c", .bin = "cc" },
        .cpp => .{ .name = "c++", .tags = &.{ "cpp", "c++", "cxx" }, .ext = "cpp", .bin = "c++" },
        .ts => .{ .name = "typescript", .tags = &.{ "ts", "typescript" }, .ext = "ts", .bin = "bun" },
        .js => .{ .name = "javascript", .tags = &.{ "js", "javascript" }, .ext = "js", .bin = "node" },
        .bash => .{ .name = "bash", .tags = &.{ "bash", "sh", "shell" }, .ext = "sh", .bin = "bash" },
        .lean => .{ .name = "lean", .tags = &.{ "lean", "lean4" }, .ext = "lean", .bin = "lean" },
        .coq => .{ .name = "coq", .tags = &.{ "coq", "rocq" }, .ext = "v", .bin = "coqc" },
        .kani => .{ .name = "kani", .tags = &.{"kani"}, .ext = "rs", .bin = "kani" },
    };
}

fn detect(tag: []const u8) ?Lang {
    for (ALL) |l| for (spec(l).tags) |t| if (std.ascii.eqlIgnoreCase(tag, t)) return l;
    return null;
}

// --- syscall-shaped helpers (match feats/team style) ------------------------
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
        const n: isize = @bitCast(linux.read(fd, &tmp, tmp.len));
        if (n <= 0) break;
        buf.appendSlice(alloc, tmp[0..@intCast(n)]) catch break;
    }
    return buf.toOwnedSlice(alloc) catch &.{};
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

/// Is `name` an executable on PATH?
fn onPath(init: std.process.Init, name: []const u8) bool {
    // The shared primitive hands back allocated values; the process arena owns
    // them, so they live exactly as long as the environ memory they replaced.
    const path_env = feat.env(init.arena.allocator(), init.io, "PATH") orelse "/usr/bin:/bin";
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        var buf: [4096]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        var zb: [4096]u8 = undefined;
        const z = toZ(&zb, full) orelse continue;
        if (@as(isize, @bitCast(linux.access(z, 1))) == 0) return true; // X_OK
    }
    return false;
}

const Run = struct { out: []u8, code: u8 };

/// fork+exec `env timeout <n> <argv…>` capturing stdout+stderr merged. The child
/// is a compiler, never the checked code.
fn runChecker(init: std.process.Init, args: []const []const u8, timeout_s: u32) ?Run {
    return runCheckerIn(init, args, timeout_s, null);
}

/// Same, with the child chdir'd into `cwd` before exec (still under `timeout`).
/// The parent's cwd is never touched.
fn runCheckerIn(init: std.process.Init, args: []const []const u8, timeout_s: u32, cwd: ?[]const u8) ?Run {
    var cwdz_buf: [4096]u8 = undefined;
    const cwdz: ?[*:0]const u8 = if (cwd) |d| (toZ(&cwdz_buf, d) orelse return null) else null;

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
    if (timeout_s > 0) {
        if (!push("timeout", &held, &nh, &argv, &n)) return null;
        var tb: [16]u8 = undefined;
        const ts = std.fmt.bufPrint(&tb, "{d}", .{timeout_s}) catch return null;
        if (!push(ts, &held, &nh, &argv, &n)) return null;
    }
    for (args) |a| if (n >= argv.len - 1 or !push(a, &held, &nh, &argv, &n)) return null;
    argv[n] = null;
    const argvz: [*:null]const ?[*:0]const u8 = argv[0..n :null];

    var fds: [2]i32 = undefined;
    if (@as(isize, @bitCast(linux.pipe2(&fds, .{}))) < 0) return null;
    const pid: isize = @bitCast(linux.fork());
    if (pid < 0) {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        return null;
    }
    if (pid == 0) {
        _ = linux.close(fds[0]);
        _ = linux.dup2(fds[1], 1);
        _ = linux.dup2(fds[1], 2);
        _ = linux.close(fds[1]);
        // the parent verified the dir is enterable; a failure here is still
        // surfaced as a distinct exit (126) rather than a blank build failure.
        if (cwdz) |d| if (@as(isize, @bitCast(linux.chdir(d))) < 0) linux.exit(126);
        // The checker inherits this process's environment block, taken from the
        // startup data Zig already holds — no libc environ needed.
        _ = linux.execve("/usr/bin/env", argvz, init.minimal.environ.block.slice.ptr);
        linux.exit(127);
    }
    _ = linux.close(fds[1]);
    const data = slurp(fds[0], MAX_IN);
    _ = linux.close(fds[0]);
    var status: u32 = 0;
    _ = linux.waitpid(@intCast(pid), &status, 0);
    const code: u8 = if ((status & 0x7f) != 0) 128 else @intCast((status >> 8) & 0xff);
    return .{ .out = data, .code = code };
}

/// Compile-check `code` as language `l`. Returns exit 0 (ok) / 1 (fail); prints
/// diagnostics. Writes a temp file (0600) with the right extension, reaps it.
fn verifyTimeout(init: std.process.Init, default: u32) u32 {
    const v = feat.env(init.arena.allocator(), init.io, "ZISH_VERIFY_TIMEOUT") orelse return default;
    return std.fmt.parseInt(u32, v, 10) catch default;
}

/// A word-boundary search for a proof-hole token, so we don't trip on it inside a
/// longer identifier (e.g. `sorryAx`, `admitted_by`). Returns the token if the
/// code admits its goal, else null.
fn containsWord(code: []const u8, word: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, code, i, word)) |at| {
        const before = if (at == 0) 0 else code[at - 1];
        const after = if (at + word.len >= code.len) 0 else code[at + word.len];
        const bw = (before >= 'a' and before <= 'z') or (before >= 'A' and before <= 'Z') or (before >= '0' and before <= '9') or before == '_';
        const aw = (after >= 'a' and after <= 'z') or (after >= 'A' and after <= 'Z') or (after >= '0' and after <= '9') or after == '_';
        if (!bw and !aw) return true;
        i = at + word.len;
    }
    return false;
}

fn proofHole(l: Lang, code: []const u8) ?[]const u8 {
    const holes: []const []const u8 = switch (l) {
        .lean => &.{ "sorry", "admit" },
        .coq => &.{ "admit", "Admitted", "give_up" },
        .kani => &.{}, // kani has no admit; a passing harness is a real result
        else => &.{},
    };
    for (holes) |h| if (containsWord(code, h)) return h;
    return null;
}

fn check(init: std.process.Init, l: Lang, code: []const u8) u8 {
    const sp = spec(l);
    const home = feat.env(init.arena.allocator(), init.io, "HOME") orelse "/tmp";
    const pid = linux.getpid();
    const path = std.fmt.allocPrint(alloc, "{s}/.zish-verify-{d}.{s}", .{ home, pid, sp.ext }) catch return 2;
    defer alloc.free(path);
    if (!writeFileTrunc(path, code)) {
        warn("verify: cannot write temp file\n");
        return 2;
    }
    defer unlinkPath(path);
    const rmeta = std.fmt.allocPrint(alloc, "{s}/.zish-verify-{d}.rmeta", .{ home, pid }) catch (alloc.dupe(u8, "/tmp/zv.rmeta") catch "/tmp/zv.rmeta");
    defer alloc.free(rmeta);
    defer unlinkPath(rmeta);
    const od = std.fmt.allocPrint(alloc, "{s}/.zish-verify-{d}.out", .{ home, pid }) catch (alloc.dupe(u8, "/tmp") catch "/tmp");
    defer alloc.free(od);

    // proof oracles can be slow (Kani model-checking, Lean elaboration) — give
    // them room; override with ZISH_VERIFY_TIMEOUT.
    const t: u32 = if (isProof(l)) verifyTimeout(init, 300) else verifyTimeout(init, 60);
    const res: ?Run = switch (l) {
        .zig => runChecker(init, &.{ "zig", "ast-check", path }, t),
        .rust => runChecker(init, &.{ "rustc", "--edition", "2021", "--crate-type", "lib", "--emit=metadata", "-o", rmeta, path }, t),
        .python => runChecker(init, &.{ "python3", "-m", "py_compile", path }, t),
        .go => runChecker(init, &.{ "gofmt", "-e", path }, t),
        .c => runChecker(init, &.{ "cc", "-fsyntax-only", path }, t),
        .cpp => runChecker(init, &.{ "c++", "-fsyntax-only", path }, t),
        .ts => runChecker(init, &.{ "bun", "build", "--outdir", od, path }, t),
        .js => runChecker(init, &.{ "node", "--check", path }, t),
        .bash => runChecker(init, &.{ "bash", "-n", path }, t),
        // lean type-checks the file (errors → non-zero); with no `sorry` a
        // successful elaboration means the theorems are proved.
        .lean => runChecker(init, &.{ "lean", path }, t),
        // coqc compiles the .v; Admitted/admit already rejected above.
        .coq => runChecker(init, &.{ "coqc", "-q", path }, t),
        // kani model-checks the Rust harnesses; exit 0 = no counterexample found.
        .kani => runChecker(init, &.{ "kani", path }, t),
    };
    const r = res orelse {
        warn("verify: compiler spawn failed\n");
        return 2;
    };
    defer alloc.free(r.out);
    const trimmed = std.mem.trim(u8, r.out, " \t\r\n");
    if (trimmed.len > 0) {
        out(trimmed);
        out("\n");
    }
    return if (r.code == 0) 0 else 1;
}

// --- lake mode: a whole Lean 4 project ---------------------------------------
//
// `verify lake <dir>` attests a lake project, not a snippet. The attestation is
// only worth anything if none of the project's own sources admit a goal, so the
// hole scan walks `<dir>` for `*.lean` first, excluding `.lake/` (the dependency
// and build tree: mathlib etc. legitimately carry `sorry` in docs/tests and are
// not what we are attesting). The scan must be conclusive: anything it cannot
// read, or a walk that trips a cap, is reported as inconclusive and fails (1)
// rather than being skipped — an unscanned file could be the hidden hole.

const LAKE_MAX_DEPTH: usize = 64; // also bounds symlink cycles (we follow dir symlinks, as lake does)
const LAKE_MAX_VISITS: usize = 200_000; // total directory entries examined
const LAKE_MAX_FILE: usize = 16 * 1024 * 1024; // a source file larger than this is unscannable

const ScanFail = enum { hole, inconclusive };
const Scan = struct { fail: ScanFail, path: []const u8, detail: []const u8 };

const Walker = struct {
    visits: usize = 0,
    /// relative path of the entry being examined, for the report
    rel: [4096]u8 = undefined,
    rel_len: usize = 0,

    fn push(w: *Walker, name: []const u8) bool {
        if (w.rel_len + name.len + 1 >= w.rel.len) return false;
        if (w.rel_len > 0) {
            w.rel[w.rel_len] = '/';
            w.rel_len += 1;
        }
        @memcpy(w.rel[w.rel_len .. w.rel_len + name.len], name);
        w.rel_len += name.len;
        return true;
    }
    fn relPath(w: *Walker) []const u8 {
        return w.rel[0..w.rel_len];
    }

    fn fail(w: *Walker, kind: ScanFail, detail: []const u8) Scan {
        const p = alloc.dupe(u8, w.relPath()) catch "?";
        return .{ .fail = kind, .path = p, .detail = detail };
    }

    /// Scan one `.lean` file open as `fd` (consumed). Null = clean.
    fn scanFile(w: *Walker, fd: i32) ?Scan {
        defer _ = linux.close(fd);
        var st: linux.Statx = undefined;
        if (@as(isize, @bitCast(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true }, &st))) < 0)
            return w.fail(.inconclusive, "cannot stat source file");
        if (!st.mask.TYPE or !linux.S.ISREG(st.mode)) return w.fail(.inconclusive, "not a regular file");
        const data = slurp(fd, LAKE_MAX_FILE);
        defer alloc.free(data);
        if (data.len >= LAKE_MAX_FILE) return w.fail(.inconclusive, "file too large to scan");
        if (proofHole(.lean, data)) |tok| return w.fail(.hole, tok);
        return null;
    }

    /// Walk the directory open as `dfd` (consumed). Null = clean.
    fn walkDir(w: *Walker, dfd: i32, depth: usize) ?Scan {
        defer _ = linux.close(dfd);
        if (depth > LAKE_MAX_DEPTH) return w.fail(.inconclusive, "directory nesting too deep (symlink cycle?)");
        var buf: [32768]u8 align(@alignOf(linux.dirent64)) = undefined;
        while (true) {
            const rc: isize = @bitCast(linux.getdents64(dfd, &buf, buf.len));
            if (rc < 0) return w.fail(.inconclusive, "cannot list directory");
            if (rc == 0) return null;
            const got: usize = @intCast(rc);
            var off: usize = 0;
            while (off < got) {
                const ent: *linux.dirent64 = @ptrCast(@alignCast(buf[off..].ptr));
                const reclen: usize = ent.reclen;
                if (reclen == 0 or off + reclen > got) return w.fail(.inconclusive, "malformed directory entry");
                const name_start = off + @offsetOf(linux.dirent64, "name");
                const name = std.mem.sliceTo(buf[name_start .. off + reclen], 0);
                off += reclen;
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                // .lake is the dep/build tree (not ours); .git is never sources.
                if (std.mem.eql(u8, name, ".lake") or std.mem.eql(u8, name, ".git")) continue;

                w.visits += 1;
                if (w.visits > LAKE_MAX_VISITS) return w.fail(.inconclusive, "too many entries (symlink cycle?)");
                const saved = w.rel_len;
                defer w.rel_len = saved;
                if (!w.push(name)) return w.fail(.inconclusive, "path too long");
                var nz: [4096]u8 = undefined;
                const namez = toZ(&nz, name) orelse return w.fail(.inconclusive, "name too long");

                // A directory (or symlink to one): descend. Symlinks are followed
                // because lake follows them — a hole behind a link is still a hole;
                // cycles trip the depth/visit caps and fail closed.
                const is_dir_hint = ent.type == linux.DT.DIR or ent.type == linux.DT.LNK or ent.type == linux.DT.UNKNOWN;
                if (is_dir_hint) {
                    const sub: isize = @bitCast(linux.openat(dfd, namez, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0));
                    if (sub >= 0) {
                        if (w.walkDir(@intCast(sub), depth + 1)) |s| return s;
                        continue;
                    }
                    const err = linux.errno(@bitCast(sub));
                    if (err != .NOTDIR) return w.fail(.inconclusive, "cannot open directory");
                    // ENOTDIR: a non-directory; fall through to the file check.
                }
                if (!std.mem.endsWith(u8, name, ".lean")) continue;
                // Only a regular file is scannable: opening a FIFO named X.lean
                // would block forever (this scan is not under `timeout`), and a
                // device/socket is not a source. NONBLOCK makes the open itself
                // never block; the type check is then done on the opened fd (not
                // by path) so nothing can be swapped in between. Symlinks are
                // followed, as lake does.
                const ffd: isize = @bitCast(linux.openat(dfd, namez, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true }, 0));
                if (ffd < 0) return w.fail(.inconclusive, "cannot read source file");
                if (w.scanFile(@intCast(ffd))) |s| return s;
            }
        }
    }
};

/// Hole-scan every own-source `.lean` under `root`. Null = clean and conclusive.
fn lakeHoleScan(root: []const u8) ?Scan {
    var w = Walker{};
    var z: [4096]u8 = undefined;
    const rz = toZ(&z, root) orelse return w.fail(.inconclusive, "path too long");
    const dfd: isize = @bitCast(linux.open(rz, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0));
    if (dfd < 0) return w.fail(.inconclusive, "cannot open project directory");
    return w.walkDir(@intCast(dfd), 0);
}

fn fileExists(dir: []const u8, name: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch return false;
    var zb: [4096]u8 = undefined;
    const z = toZ(&zb, full) orelse return false;
    return @as(isize, @bitCast(linux.access(z, 0))) == 0; // F_OK
}

/// `verify lake <dir>`: 2 usage / 1 hole-or-inconclusive-or-build-fail /
/// 4 no lake / 0 built.
fn checkLake(init: std.process.Init, dir: []const u8) u8 {
    if (!fileExists(dir, "lakefile.lean") and !fileExists(dir, "lakefile.toml")) {
        var b: [4400]u8 = undefined;
        warn(std.fmt.bufPrint(&b, "verify: lake: '{s}' is not a lake project (no lakefile.lean/lakefile.toml)\n", .{dir}) catch "verify: lake: not a lake project\n");
        return 2;
    }
    // Hole gate before the toolchain check (same order as single-file proofs):
    // a holed project is a definitive fail, never a "no checker" skip.
    if (lakeHoleScan(dir)) |s| {
        var b: [4600]u8 = undefined;
        const msg = switch (s.fail) {
            .hole => std.fmt.bufPrint(&b, "verify: proof hole — {s} contains `{s}`; a proof that admits its goal is not a proof.\n", .{ s.path, s.detail }) catch "verify: proof hole\n",
            .inconclusive => std.fmt.bufPrint(&b, "verify: lake: scan inconclusive — {s}: {s}; refusing to attest.\n", .{ s.path, s.detail }) catch "verify: lake: scan inconclusive\n",
        };
        out(msg);
        return 1;
    }
    if (!onPath(init, "lake")) {
        warn("verify: 'lake' toolchain ('lake') not installed\n");
        return 4;
    }
    // whole-project builds (mathlib) are slow: much longer default than a snippet.
    const r = runCheckerIn(init, &.{ "lake", "build" }, verifyTimeout(init, 1800), dir) orelse {
        warn("verify: compiler spawn failed\n");
        return 2;
    };
    defer alloc.free(r.out);
    const trimmed = std.mem.trim(u8, r.out, " \t\r\n");
    if (trimmed.len > 0) {
        out(trimmed);
        out("\n");
    }
    if (r.code == 124) out("verify: lake build timed out\n");
    if (r.code == 126) out("verify: lake: cannot enter project directory\n");
    return if (r.code == 0) 0 else 1;
}

/// Print the comma-joined names of every language whose checker is installed.
fn printCaps(init: std.process.Init) void {
    var o: std.ArrayListUnmanaged(u8) = .empty;
    defer o.deinit(alloc);
    for (ALL) |l| {
        const sp = spec(l);
        if (!onPath(init, sp.bin)) continue;
        if (o.items.len > 0) o.appendSlice(alloc, ", ") catch {};
        o.appendSlice(alloc, sp.name) catch {};
    }
    if (onPath(init, "lake")) {
        if (o.items.len > 0) o.appendSlice(alloc, ", ") catch {};
        o.appendSlice(alloc, "lake") catch {};
    }
    o.append(alloc, '\n') catch {};
    out(o.items);
}

fn usage() void {
    warn(
        \\verify — compile-check code, or check a PROOF with its assistant.
        \\  verify caps            list installable checkers (compilers + proof oracles)
        \\  verify <lang> < code   check stdin; exit 0 ok / 1 fail / 3 unknown / 4 no checker
        \\  verify lake <dir>      `lake build` a Lean 4 project; its own *.lean (not .lake/)
        \\                         must be hole-free; exit 0 built / 1 hole|fail / 2 no lakefile / 4 no lake
        \\  compilers: zig rust python go c c++ ts js bash
        \\  proof oracles: lean coq kani   (reject `sorry`/`admit` holes; longer timeout)
        \\
    );
}

pub fn main(init: std.process.Init) u8 {
    return run(init);
}

fn run(init: std.process.Init) u8 {
    var it = init.minimal.args.iterate();
    _ = it.next(); // argv[0]
    const sub = it.next() orelse {
        usage();
        return 2;
    };

    if (std.mem.eql(u8, sub, "caps") or std.mem.eql(u8, sub, "--caps")) {
        printCaps(init);
        return 0;
    }
    if (std.mem.eql(u8, sub, "-h") or std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "help")) {
        usage();
        return 0;
    }

    // `lake <dir>`: a whole project on disk, not a snippet on stdin.
    if (std.mem.eql(u8, sub, "lake")) {
        const dir = it.next() orelse {
            usage();
            return 2;
        };
        return checkLake(init, dir);
    }

    // otherwise `sub` is a language tag; code comes on stdin
    const l = detect(sub) orelse {
        var b: [256]u8 = undefined;
        warn(std.fmt.bufPrint(&b, "verify: no checker for language '{s}'\n", .{sub}) catch "verify: unknown language\n");
        return 3; // skip, not a compile failure
    };
    const code = slurp(0, MAX_IN);
    defer alloc.free(code);
    if (std.mem.trim(u8, code, " \t\r\n").len == 0) {
        warn("verify: no code on stdin\n");
        return 2;
    }
    // Proof-hole gate runs before the toolchain check: a proof that admits its goal
    // is a definitive fail (1), never an ambiguous "no checker" skip — fail closed.
    if (isProof(l)) {
        if (proofHole(l, code)) |tok| {
            var b: [160]u8 = undefined;
            out(std.fmt.bufPrint(&b, "verify: proof hole — contains `{s}`; a proof that admits its goal is not a proof.\n", .{tok}) catch "verify: proof hole\n");
            return 1;
        }
    }
    if (!onPath(init, spec(l).bin)) {
        var b: [256]u8 = undefined;
        warn(std.fmt.bufPrint(&b, "verify: '{s}' toolchain ('{s}') not installed\n", .{ spec(l).name, spec(l).bin }) catch "verify: toolchain missing\n");
        return 4; // known language, checker missing — distinct from an unknown tag (3)
    }
    return check(init, l, code);
}
