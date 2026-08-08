//! Fuzz targets for zish.
//!
//!   zig build fuzz            run every target: randomized sweep + one Smith pass
//!   zig build fuzz --fuzz     coverage-guided search (see TOOLCHAIN NOTE)
//!   zig build test            same targets, wired into the normal suite
//!
//! Each target is a plain `fn (input: []const u8)` core, driven two ways:
//!
//!   1. a seeded PRNG sweep that runs on every `zig build test`. Not
//!      coverage-guided, but it runs today and it runs in CI.
//!   2. std.testing.fuzz, which feeds the same core from the coverage-guided
//!      engine when the toolchain supports it.
//!
//! Splitting the core out means neither driver can drift from the other, and a
//! crash found by either reproduces through the same entry point.
//!
//! TOOLCHAIN NOTE — `--fuzz` does not work on Zig 0.16.0. Two independent
//! upstream bugs, neither of them in this file. A six-line stdlib-only fuzz
//! test reproduces both, so nothing here can work around them.
//!
//! 1. compiler/test_runner.zig:566 — will not compile in fuzz mode:
//!
//!        error: expected type '*const debug.StackTrace',
//!               found '*builtin.StackTrace'
//!
//!    std.debug.StackTrace was refactored to {return_addresses, skipped} and
//!    writeStackTrace updated with it, but this call still passes the
//!    {index, instruction_addresses} value from @errorReturnTrace(). Only the
//!    fuzz path is affected, which is why plain `zig test` is fine.
//!
//!    Fixable locally by vendoring a patched runner (verified: it builds and
//!    31/31 tests pass). Not worth doing while bug 2 stands — it costs 617
//!    lines of copied compiler internals that must be re-synced on every Zig
//!    upgrade, and it silently overrides the runner for the normal test path
//!    too, so any drift changes how ordinary tests behave.
//!
//! 2. std/Build/Fuzz.zig:477 — with bug 1 patched, the build runner itself
//!    aborts before fuzzing starts:
//!
//!        panic: start index 1 is larger than end index 0
//!        Fuzz.zig:477 in addEntryPoint   →  for (pcs[1..], 1..)
//!
//!    `pcs` (the collected program counters) is empty, and addEntryPoint
//!    slices it unconditionally. This lives in the build runner, compiled from
//!    the installed std, so it cannot be overridden from a project.
//!
//! Retry after a toolchain bump: `zig build fuzz --fuzz`. If it builds and the
//! web UI stays up past a few seconds, both are fixed. Until then the PRNG
//! sweep below is the only driver that runs, which is why it exists.
//!
//! SAFETY — read before adding a target.
//!
//! Only *pure* surfaces are fuzzed: the lexer, the parser, the arithmetic
//! evaluator and the glob matcher. None of them fork, exec, open files or
//! mutate anything outside their own arena.
//!
//! Never point a fuzzer at the executor. A coverage-guided fuzzer optimises
//! for reaching new code, and the new code behind `evaluateCommand` is
//! `execvpeZ`. It would synthesise `rm -rf ~` and run it, on your machine,
//! with your permissions. For end-to-end coverage drive `zish -c` from
//! tests/regress.sh, inside a container.
//!
//! What these targets look for: index out of bounds, unsigned underflow
//! (`x - 1` at x==0), slice bounds, unchecked @memcpy, integer overflow,
//! unbounded recursion (stack exhaustion on deeply nested `$(( (((...))) ))`),
//! and — via std.testing.allocator — leaks on error paths. Each of those
//! aborts the process, which is what both drivers record as a finding.

const std = @import("std");
const Smith = std.testing.Smith;

const compat = @import("compat.zig");
const parser = @import("parser.zig");
const glob = @import("glob.zig");
const Shell = @import("Shell.zig");

/// Characters that make shell syntax interesting.
///
/// Uniform random bytes waste nearly all their budget on inputs that die in
/// the first branch. A metacharacter-heavy alphabet reaches the quoting,
/// nesting and expansion paths where the bugs live.
const shell_alphabet =
    "$(){}[]<>|&;'\"`\\ \n\t=*?!~-+/%^:,." ++
    "0123456789" ++
    "abcdefixyz_";

/// Iterations per target in the PRNG sweep. Kept modest so `zig build test`
/// stays fast; the coverage-guided driver is the one meant to run long.
///
/// Override for a real soak run:
///     ZISH_FUZZ_ITERS=10000000 zig build fuzz
const sweep_iterations = 20_000;

fn iterations(default: usize) usize {
    const env = compat.posix.getenv("ZISH_FUZZ_ITERS") orelse return default;
    return std.fmt.parseInt(usize, env, 10) catch default;
}

// ---------------------------------------------------------------------------
// Cores — the actual targets. Both drivers call these.
// ---------------------------------------------------------------------------

/// Parser core. Drives the lexer too, since the parser pulls tokens from it.
fn coreParser(src: []const u8) void {
    // testing.allocator turns a leak into a failure. That is most of the value
    // here: the parser allocates on nearly every path, including error paths.
    var p = parser.Parser.init(src, std.testing.allocator) catch return;
    defer p.deinit();
    _ = p.parse() catch return;
}

/// Glob core. A pure predicate over two strings, no filesystem access, so the
/// backtracking can be hammered without touching disk. Pattern matchers are a
/// classic home for both quadratic blowup and index underflow.
fn coreGlob(pattern: []const u8, text: []const u8) void {
    _ = glob.matchGlob(pattern, text);
}

/// Arithmetic core. evaluateArithmetic is pure with respect to processes — it
/// reads and writes shell variables and nothing else — so it is safe in-process.
/// This is where INT_MIN/-1 and the 19-digit literal overflow lived.
fn coreArith(shell: *Shell, expr: []const u8) void {
    _ = shell.evaluateArithmetic(expr) catch {};
}

// ---------------------------------------------------------------------------
// Input generation
// ---------------------------------------------------------------------------

fn randomShellish(rand: std.Random, out: []u8) []u8 {
    const n = rand.uintLessThan(usize, out.len + 1);
    for (out[0..n]) |*c| c.* = shell_alphabet[rand.uintLessThan(usize, shell_alphabet.len)];
    return out[0..n];
}

fn smithShellish(smith: *Smith, out: []u8) []u8 {
    var n: usize = 0;
    // 20:1 continue:stop biases toward longer inputs, where the nesting bugs are.
    while (n < out.len and !smith.eosWeightedSimple(20, 1)) : (n += 1) {
        out[n] = shell_alphabet[smith.value(u8) % shell_alphabet.len];
    }
    return out[0..n];
}

/// A long unbroken token followed by an escape.
///
/// Targets the MAX_TOKEN_LENGTH (1024) boundary specifically: the
/// escape-continuation paths in lexer.zig @memcpy an already-accumulated token
/// without re-checking it against the destination array, so the bug only
/// appears once a token has grown past the limit. Neither driver would
/// stumble onto a 1024-character run of non-metacharacters on its own.
fn buildLongToken(buf: []u8, run_len: usize, tail: u8) []const u8 {
    @memset(buf[0..run_len], 'a');
    buf[run_len] = '\\';
    buf[run_len + 1] = tail;
    return buf[0 .. run_len + 2];
}

// ---------------------------------------------------------------------------
// Driver 1: seeded PRNG sweep (runs on every `zig build test`)
// ---------------------------------------------------------------------------

test "sweep: parser" {
    var prng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    const rand = prng.random();
    var buf: [512]u8 = undefined;
    for (0..iterations(sweep_iterations)) |_| coreParser(randomShellish(rand, &buf));
}

test "sweep: lexer long token" {
    var prng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    const rand = prng.random();
    var buf: [4096]u8 = undefined;
    for (0..iterations(sweep_iterations) / 20) |_| {
        const run_len = 900 + rand.uintLessThan(usize, 300);
        const tail = shell_alphabet[rand.uintLessThan(usize, shell_alphabet.len)];
        coreParser(buildLongToken(&buf, run_len, tail));
    }
}

test "sweep: glob match" {
    var prng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    const rand = prng.random();
    var pbuf: [128]u8 = undefined;
    var tbuf: [128]u8 = undefined;
    for (0..iterations(sweep_iterations)) |_| {
        coreGlob(randomShellish(rand, &pbuf), randomShellish(rand, &tbuf));
    }
}

test "sweep: arithmetic" {
    // page_allocator, not testing.allocator: a Shell owns long-lived state that
    // outlives an iteration, so leak accounting here reports noise rather than
    // findings. Crash-safety is what this target is for.
    const shell = try Shell.initNonInteractive(std.heap.page_allocator);
    defer shell.deinit();

    var prng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    const rand = prng.random();
    var buf: [256]u8 = undefined;
    for (0..iterations(sweep_iterations)) |_| coreArith(shell, randomShellish(rand, &buf));
}

// ---------------------------------------------------------------------------
// Driver 2: coverage-guided (std.testing.fuzz)
// ---------------------------------------------------------------------------

test "fuzz: parser" {
    try std.testing.fuzz({}, fuzzParser, .{});
}

fn fuzzParser(_: void, smith: *Smith) !void {
    var buf: [512]u8 = undefined;
    coreParser(smithShellish(smith, &buf));
}

test "fuzz: lexer long token" {
    try std.testing.fuzz({}, fuzzLongToken, .{});
}

fn fuzzLongToken(_: void, smith: *Smith) !void {
    var buf: [4096]u8 = undefined;
    const run_len = smith.valueRangeAtMost(u16, 900, 1200);
    const tail = shell_alphabet[smith.value(u8) % shell_alphabet.len];
    coreParser(buildLongToken(&buf, run_len, tail));
}

test "fuzz: glob match" {
    try std.testing.fuzz({}, fuzzGlobMatch, .{});
}

fn fuzzGlobMatch(_: void, smith: *Smith) !void {
    var pbuf: [128]u8 = undefined;
    var tbuf: [128]u8 = undefined;
    coreGlob(smithShellish(smith, &pbuf), smithShellish(smith, &tbuf));
}

test "fuzz: arithmetic" {
    const shell = try Shell.initNonInteractive(std.heap.page_allocator);
    defer shell.deinit();
    try std.testing.fuzz(shell, fuzzArith, .{});
}

fn fuzzArith(shell: *Shell, smith: *Smith) !void {
    var buf: [256]u8 = undefined;
    coreArith(shell, smithShellish(smith, &buf));
}

// ---------------------------------------------------------------------------
// Deeply nested expressions — stack exhaustion
// ---------------------------------------------------------------------------
//
// Both the arithmetic evaluator and the command parser are recursive descent
// with no depth counter. Hostile input is a single long run of opening
// brackets; there is no matching close required to blow the stack, because the
// recursion happens on the way down. A shell that segfaults on a pasted string
// is a denial of service, and in the "model output reaches the shell" threat
// model it is trivially reachable.
//
// Depth is capped well below what a default 8 MiB stack tolerates so a *pass*
// is meaningful. If these start crashing, the fix is an explicit depth limit
// returning a syntax error, the way bash caps expansion nesting.

const max_nest_depth = 2_000;

fn buildNested(buf: []u8, depth: usize, open: []const u8, close: []const u8) []const u8 {
    var n: usize = 0;
    for (0..depth) |_| {
        if (n + open.len > buf.len) break;
        @memcpy(buf[n..][0..open.len], open);
        n += open.len;
    }
    if (n < buf.len) {
        buf[n] = '1';
        n += 1;
    }
    for (0..depth) |_| {
        if (n + close.len > buf.len) break;
        @memcpy(buf[n..][0..close.len], close);
        n += close.len;
    }
    return buf[0..n];
}

test "sweep: nested arithmetic" {
    const shell = try Shell.initNonInteractive(std.heap.page_allocator);
    defer shell.deinit();

    var prng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    const rand = prng.random();
    var buf: [16384]u8 = undefined;
    for (0..iterations(sweep_iterations) / 200) |_| {
        const depth = 1 + rand.uintLessThan(usize, max_nest_depth);
        coreArith(shell, buildNested(&buf, depth, "(", ")"));
    }
}

test "sweep: nested command substitution" {
    var prng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    const rand = prng.random();
    var buf: [16384]u8 = undefined;
    for (0..iterations(sweep_iterations) / 200) |_| {
        const depth = 1 + rand.uintLessThan(usize, max_nest_depth / 2);
        coreParser(buildNested(&buf, depth, "$(", ")"));
    }
}

test "sweep: nested braces and subshells" {
    var prng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    const rand = prng.random();
    var buf: [16384]u8 = undefined;
    for (0..iterations(sweep_iterations) / 200) |_| {
        const depth = 1 + rand.uintLessThan(usize, max_nest_depth / 2);
        coreParser(buildNested(&buf, depth, "( ", " )"));
    }
}

// ---------------------------------------------------------------------------
// GGUF model file parser — genuinely hostile input
// ---------------------------------------------------------------------------
//
// Every other target here parses text the user typed. This one parses a *file*
// downloaded from the internet, which is the only place in zish where the
// attacker fully controls the bytes and never had to type them.
//
// The header hands the parser two attacker-chosen u64 counts
// (`tensor_count`, `metadata_kv_count`) that drive allocation loops, plus
// per-tensor dimensions and offsets used for pointer arithmetic into the
// mmap'd region. That is the classic shape of a heap overflow, so it is worth
// the cost of touching the filesystem once per iteration.

const gguf = @import("inference/gguf.zig");

fn coreGguf(bytes: []const u8, path: [:0]const u8) void {
    {
        const file = std.Io.Dir.createFileAbsolute(compat.io(), path, .{}) catch return;
        defer file.close(compat.io());
        compat.writeAll(file, bytes) catch return;
    }
    var f = gguf.GGUFFile.open(path, std.heap.page_allocator) catch return;
    f.deinit();
}

/// Emit a structurally plausible GGUF file.
///
/// The magic and version are always valid: random bytes are rejected at offset
/// 4 and would test nothing past the first branch. Counts are usually small so
/// the parser actually walks the body, but occasionally a full random u64 to
/// probe unbounded allocation and multiplication overflow.
fn buildGguf(rand: std.Random, out: []u8) []const u8 {
    std.mem.writeInt(u32, out[0..4], 0x46554747, .little); // "GGUF"
    std.mem.writeInt(u32, out[4..8], 3, .little); // version 3
    const huge = rand.uintLessThan(u8, 8) == 0;
    const tc: u64 = if (huge) rand.int(u64) else rand.uintLessThan(u64, 8);
    const mc: u64 = if (huge) rand.int(u64) else rand.uintLessThan(u64, 8);
    std.mem.writeInt(u64, out[8..16], tc, .little);
    std.mem.writeInt(u64, out[16..24], mc, .little);
    const body = rand.uintLessThan(usize, out.len - 24);
    rand.bytes(out[24..][0..body]);
    return out[0 .. 24 + body];
}

test "sweep: gguf parser" {
    var prng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    const rand = prng.random();

    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/zish_fuzz_gguf_{d}.bin", .{std.testing.random_seed});
    defer std.Io.Dir.deleteFileAbsolute(compat.io(), path) catch {};

    var buf: [8192]u8 = undefined;
    for (0..iterations(sweep_iterations) / 200) |_| {
        coreGguf(buildGguf(rand, &buf), path);
    }
}

// Real models must still parse.
//
// The bounds added to gguf.zig reject lengths that exceed the remaining file.
// That is only correct if no *valid* file ever trips them, so this loads
// whatever real models are on this machine and fails if one is refused.
// Hardening that quietly breaks model loading is worse than the bug it fixed.
//
// Skips when no model is installed, so it stays CI-friendly.
test "gguf: real models still load" {
    const home = compat.posix.getenv("HOME") orelse return error.SkipZigTest;

    const names = [_][]const u8{
        "qwen25_ctm_k32.gguf",
        "shell_completion.gguf",
    };

    var checked: usize = 0;
    for (names) |name| {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}/.zish/models/{s}", .{ home, name }) catch continue;

        // Distinguish "not installed" from "parser refused it".
        std.Io.Dir.accessAbsolute(compat.io(), path, .{}) catch continue;

        var f = gguf.GGUFFile.open(path, std.heap.page_allocator) catch |err| {
            std.debug.print("gguf: valid model {s} was REJECTED: {}\n", .{ name, err });
            return error.ValidModelRejected;
        };
        defer f.deinit();

        try std.testing.expect(f.header.tensor_count > 0);
        checked += 1;
    }

    if (checked == 0) return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// GGUF: hand-built malicious files
// ---------------------------------------------------------------------------
//
// The random generator above will not reliably produce these two shapes, and
// both are one-line crashes from a downloaded model, so they get deterministic
// tests. Each must be *rejected* — an error return is a pass, a crash is not.

const GgufWriter = struct {
    buf: []u8,
    n: usize = 0,

    fn u32le(w: *GgufWriter, v: u32) void {
        std.mem.writeInt(u32, w.buf[w.n..][0..4], v, .little);
        w.n += 4;
    }
    fn u64le(w: *GgufWriter, v: u64) void {
        std.mem.writeInt(u64, w.buf[w.n..][0..8], v, .little);
        w.n += 8;
    }
    fn str(w: *GgufWriter, s: []const u8) void {
        w.u64le(s.len);
        @memcpy(w.buf[w.n..][0..s.len], s);
        w.n += s.len;
    }
    /// magic + version 3 + tensor_count + metadata_kv_count
    fn header(w: *GgufWriter, tensors: u64, kvs: u64) void {
        w.u32le(0x46554747);
        w.u32le(3);
        w.u64le(tensors);
        w.u64le(kvs);
    }
};

fn expectGgufRejected(bytes: []const u8, path: [:0]const u8) !void {
    {
        const file = try std.Io.Dir.createFileAbsolute(compat.io(), path, .{});
        defer file.close(compat.io());
        try compat.writeAll(file, bytes);
    }
    defer std.Io.Dir.deleteFileAbsolute(compat.io(), path) catch {};

    if (gguf.GGUFFile.open(path, std.heap.page_allocator)) |*f| {
        var m = f.*;
        m.deinit();
        return error.MaliciousFileAccepted;
    } else |_| {
        // Any error is fine. Not crashing is the point.
    }
}

test "gguf: zero alignment is rejected, not a divide by zero" {
    // general.alignment reaches `offset % alignment` in alignOffset and
    // std.mem.alignForward, both of which require a non-zero power of two.
    var buf: [256]u8 = undefined;
    var w = GgufWriter{ .buf = &buf };
    w.header(0, 1);
    w.str("general.alignment");
    w.u32le(4); // MetadataType.uint32
    w.u32le(0); // the payload

    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/zish_gguf_align0_{d}", .{std.testing.random_seed});
    try expectGgufRejected(buf[0..w.n], path);
}

test "gguf: non-power-of-two alignment is rejected" {
    var buf: [256]u8 = undefined;
    var w = GgufWriter{ .buf = &buf };
    w.header(0, 1);
    w.str("general.alignment");
    w.u32le(4);
    w.u32le(33); // not a power of two

    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/zish_gguf_align33_{d}", .{std.testing.random_seed});
    try expectGgufRejected(buf[0..w.n], path);
}

test "gguf: deeply nested arrays do not exhaust the stack" {
    // An array whose element type is `array` recurses Value.read -> Array.read.
    // Each level costs 12 bytes on disk.
    //
    // The buffer is 1 MiB, and heap-allocated, for a reason: at 12 bytes per
    // level that is ~87k frames, which genuinely overflows the default 8 MiB
    // stack when the depth guard is removed. An earlier 64 KiB version of this
    // test passed with the guard disabled — 5k frames is simply not deep
    // enough — which would have made it decoration rather than a regression
    // test. If you shrink this buffer, confirm the test still fails without
    // the guard in Array.read.
    const buf = try std.testing.allocator.alloc(u8, 1 << 20);
    defer std.testing.allocator.free(buf);
    var w = GgufWriter{ .buf = buf };
    w.header(0, 1);
    w.str("x");
    w.u32le(9); // MetadataType.array — the value is an array...
    while (w.n + 32 < buf.len) {
        w.u32le(9); // ...whose element type is also an array
        w.u64le(1); // ...containing exactly one element
    }

    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/zish_gguf_nested_{d}", .{std.testing.random_seed});
    try expectGgufRejected(buf[0..w.n], path);
}
