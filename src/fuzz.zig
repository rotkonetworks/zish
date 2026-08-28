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

// GGUF fuzz targets were removed with src/inference/. They guarded a parser
// for attacker-supplied model files — the single most hostile input the shell
// accepted, and where this suite found a real unbounded allocation. Deleting
// the parser removes the attack surface outright, which is strictly better
// than fuzzing it.
