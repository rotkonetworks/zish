//! verify — compile-check a snippet of code in whatever language its fence names,
//! using whatever compiler is installed. A reusable org primitive: `team` calls
//! it as the verifier member, but you can pipe any code to it directly.
//!
//!   verify caps                 → list the languages this host can check
//!   echo "<code>" | verify zig  → compile-check stdin as zig; exit 0 ok / 1 fail
//!   verify rust < file.rs       → same, from a file on stdin
//!
//! It is COMPILE/CHECK ONLY — it never RUNS the code. Each checker child is
//! `timeout`-wrapped so a pathological input can't hang. Exit: 0 compiles, 1 does
//! not (diagnostics on stdout), 3 no checker for that language (skip, not fail),
//! 2 usage error.

const std = @import("std");
const linux = std.os.linux;
const alloc = std.heap.page_allocator;

const MAX_IN = 4 * 1024 * 1024;

// --- languages this feat knows a compile/check command for ------------------
const Lang = enum { zig, rust, python, go, c, cpp, ts, js, bash };
const ALL = [_]Lang{ .zig, .rust, .python, .go, .c, .cpp, .ts, .js, .bash };

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
    };
}

fn detect(tag: []const u8) ?Lang {
    for (ALL) |l| for (spec(l).tags) |t| if (std.ascii.eqlIgnoreCase(tag, t)) return l;
    return null;
}

// --- syscall-shaped helpers (match feats/team style) ------------------------
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
fn onPath(name: []const u8) bool {
    const path_env = getEnv("PATH") orelse "/usr/bin:/bin";
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
/// is a COMPILER, never the checked code.
fn runChecker(args: []const []const u8, timeout_s: u32) ?Run {
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
        _ = linux.execve("/usr/bin/env", argvz, @ptrCast(std.c.environ));
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
fn check(l: Lang, code: []const u8) u8 {
    const sp = spec(l);
    const home = getEnv("HOME") orelse "/tmp";
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

    const res: ?Run = switch (l) {
        .zig => runChecker(&.{ "zig", "ast-check", path }, 60),
        .rust => runChecker(&.{ "rustc", "--edition", "2021", "--crate-type", "lib", "--emit=metadata", "-o", rmeta, path }, 60),
        .python => runChecker(&.{ "python3", "-m", "py_compile", path }, 60),
        .go => runChecker(&.{ "gofmt", "-e", path }, 60),
        .c => runChecker(&.{ "cc", "-fsyntax-only", path }, 60),
        .cpp => runChecker(&.{ "c++", "-fsyntax-only", path }, 60),
        .ts => runChecker(&.{ "bun", "build", "--outdir", od, path }, 60),
        .js => runChecker(&.{ "node", "--check", path }, 60),
        .bash => runChecker(&.{ "bash", "-n", path }, 60),
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

/// Print the comma-joined names of every language whose checker is installed.
fn printCaps() void {
    var o: std.ArrayListUnmanaged(u8) = .empty;
    defer o.deinit(alloc);
    for (ALL) |l| {
        const sp = spec(l);
        if (!onPath(sp.bin)) continue;
        if (o.items.len > 0) o.appendSlice(alloc, ", ") catch {};
        o.appendSlice(alloc, sp.name) catch {};
    }
    o.append(alloc, '\n') catch {};
    out(o.items);
}

fn usage() void {
    warn(
        \\verify — compile-check code in the language its fence names.
        \\  verify caps            list installable checkers on this host
        \\  verify <lang> < code   compile-check stdin; exit 0 ok / 1 fail / 3 no checker
        \\
    );
}

pub fn main(init: std.process.Init.Minimal) u8 {
    return run(init.args);
}

fn run(args: std.process.Args) u8 {
    var it = args.iterate();
    _ = it.next(); // argv[0]
    const sub = it.next() orelse {
        usage();
        return 2;
    };

    if (std.mem.eql(u8, sub, "caps") or std.mem.eql(u8, sub, "--caps")) {
        printCaps();
        return 0;
    }
    if (std.mem.eql(u8, sub, "-h") or std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "help")) {
        usage();
        return 0;
    }

    // otherwise `sub` is a language tag; code comes on stdin
    const l = detect(sub) orelse {
        var b: [256]u8 = undefined;
        warn(std.fmt.bufPrint(&b, "verify: no checker for language '{s}'\n", .{sub}) catch "verify: unknown language\n");
        return 3; // skip, not a compile failure
    };
    if (!onPath(spec(l).bin)) {
        var b: [256]u8 = undefined;
        warn(std.fmt.bufPrint(&b, "verify: '{s}' toolchain ('{s}') not installed\n", .{ spec(l).name, spec(l).bin }) catch "verify: toolchain missing\n");
        return 4; // KNOWN language, checker missing — distinct from an unknown tag (3)
    }
    const code = slurp(0, MAX_IN);
    defer alloc.free(code);
    if (std.mem.trim(u8, code, " \t\r\n").len == 0) {
        warn("verify: no code on stdin\n");
        return 2;
    }
    return check(l, code);
}
