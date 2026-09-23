// pen - pcli, answered in JSON.
//   pen balance [--account N] [--home DIR]
//   pen swap AMOUNTDENOM --into DENOM [--source N] [--home DIR] [--timeout S]
//   pen withdraw AMOUNTDENOM --to ADDRESS --channel N [--source N] [--home DIR]
//
// stdout is one JSON object, always — including on failure, where it carries
// ok:false, the exit status and the last line of pcli's own output. The exit
// status is 0 only when pcli succeeded, so a script can read the JSON *and*
// branch on $? without parsing prose.
//
// Why a feat: pcli prints for humans. Its tx ids live in
// "transaction confirmed and detected: <id> @ height <h>", its fees in
// "including transaction fee of 1.727mpenumbra", its balances in a padded table
// with unit suffixes (mpenumbra) that mean the raw number is not what it says.
// Scraping that in shell is where a trading loop's accounting goes wrong; here
// it is done once, in one place, and the caller gets fields.
//
// Zero libc, like every feat but para: the child is reached through
// /usr/bin/env (PATH search) with this process's environment block, the same
// idiom verify uses.
const std = @import("std");
const feat = @import("lib/feat.zig");
const linux = std.os.linux;

const MAX_OUT = 8 * 1024 * 1024;

const Run = struct { out: []u8, code: u8 };

fn slurp(fd: i32, cap: usize) []u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    var buf: [65536]u8 = undefined;
    while (list.items.len < cap) {
        const n = linux.read(fd, &buf, buf.len);
        if (@as(isize, @bitCast(n)) <= 0) break;
        list.appendSlice(std.heap.page_allocator, buf[0..n]) catch break;
    }
    return list.items;
}

/// Run `args` (argv, first element = program) with stdout+stderr captured.
/// PATH resolution and the environment come from /usr/bin/env, and an optional
/// VAR=VALUE assignment is inserted before the command — the libc-free way to
/// set the pcli home for the child (std.posix.setenv is gone in Zig 0.16).
fn run(init: std.process.Init, args: []const []const u8, timeout_s: u32, env_assign: ?[]const u8) ?Run {
    var argv: [64]?[*:0]const u8 = undefined;
    var held: [64][]u8 = undefined;
    var nh: usize = 0;
    var n: usize = 0;

    const z = struct {
        fn push(s: []const u8, h: *[64][]u8, nhp: *usize, av: *[64]?[*:0]const u8, np: *usize) bool {
            const dz = std.heap.page_allocator.dupeZ(u8, s) catch return false;
            h[nhp.*] = dz;
            nhp.* += 1;
            av[np.*] = dz.ptr;
            np.* += 1;
            return true;
        }
    }.push;

    if (!z("env", &held, &nh, &argv, &n)) return null;
    if (env_assign) |a| if (!z(a, &held, &nh, &argv, &n)) return null;
    if (timeout_s > 0) {
        if (!z("timeout", &held, &nh, &argv, &n)) return null;
        var tb: [16]u8 = undefined;
        const ts = std.fmt.bufPrint(&tb, "{d}", .{timeout_s}) catch return null;
        if (!z(ts, &held, &nh, &argv, &n)) return null;
    }
    for (args) |a| if (n >= argv.len - 1 or !z(a, &held, &nh, &argv, &n)) return null;
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

/// Collect every `<id>` from "confirmed and detected: <id> ..." lines.
fn txIds(alloc: std.mem.Allocator, text: []const u8) []const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "confirmed and detected: ")) |p| {
            const rest = line[p + "confirmed and detected: ".len ..];
            var e: usize = 0;
            while (e < rest.len and rest[e] != ' ' and rest[e] != '\t') e += 1;
            if (e > 0) list.append(alloc, rest[0..e]) catch {};
        }
    }
    return list.items;
}

/// Collect every `<amount>` from "including transaction fee of <amount>" lines.
fn fees(alloc: std.mem.Allocator, text: []const u8) []const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "including transaction fee of ")) |p| {
            const rest = line[p + "including transaction fee of ".len ..];
            var e: usize = 0;
            while (e < rest.len and rest[e] != ' ' and rest[e] != '\t') e += 1;
            if (e > 0) list.append(alloc, rest[0..e]) catch {};
        }
    }
    return list.items;
}

fn jsonString(b: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, s: []const u8) void {
    b.append(alloc, '"') catch {};
    feat.jsonEscape(b, alloc, s) catch {};
    b.append(alloc, '"') catch {};
}

/// The last non-empty line of pcli's output: what a human would paste.
fn lastLine(text: []const u8) []const u8 {
    var last: []const u8 = "";
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        const t = std.mem.trim(u8, l, " \t\r");
        if (t.len > 0) last = t;
    }
    return last;
}

fn emit(init: std.process.Init, b: *std.ArrayListUnmanaged(u8)) void {
    b.append(std.heap.page_allocator, '\n') catch {};
    _ = feat.out(init.io, b.items);
}

pub fn main(init: std.process.Init) void {
    feat.restoreSigpipe();
    const alloc = std.heap.page_allocator;
    const arena = init.arena.allocator();
    const argv = init.minimal.args.toSlice(arena) catch return;

    if (argv.len < 2) {
        _ = feat.err(init.io, "usage: pen balance|swap|withdraw ...\n");
        std.process.exit(feat.EXIT_USAGE);
    }
    const sub = argv[1];

    // shared flags
    var home: ?[]const u8 = null;
    var source: ?[]const u8 = null;
    var into: ?[]const u8 = null;
    var to: ?[]const u8 = null;
    var channel: ?[]const u8 = null;
    var account: ?[]const u8 = null;
    var timeout_s: u32 = 300;
    var value: ?[]const u8 = null;

    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--home")) {
            i += 1;
            home = argv[i];
        } else if (std.mem.eql(u8, a, "--source")) {
            i += 1;
            source = argv[i];
        } else if (std.mem.eql(u8, a, "--into")) {
            i += 1;
            into = argv[i];
        } else if (std.mem.eql(u8, a, "--to")) {
            i += 1;
            to = argv[i];
        } else if (std.mem.eql(u8, a, "--channel")) {
            i += 1;
            channel = argv[i];
        } else if (std.mem.eql(u8, a, "--account")) {
            i += 1;
            account = argv[i];
        } else if (std.mem.eql(u8, a, "--timeout")) {
            i += 1;
            timeout_s = std.fmt.parseInt(u32, argv[i], 10) catch 300;
        } else if (value == null) {
            value = a;
        }
    }

    // pcli home: flag wins, else the env var a caller already exported
    const env_home = feat.env(arena, init.io, "PENUMBRA_PCLI_HOME");
    const pcli_home = home orelse env_home orelse "";
    const env_assign: ?[]const u8 = if (pcli_home.len > 0)
        (std.fmt.allocPrint(arena, "PENUMBRA_PCLI_HOME={s}", .{pcli_home}) catch null)
    else
        null;

    var b: std.ArrayListUnmanaged(u8) = .empty;

    if (std.mem.eql(u8, sub, "balance")) {
        const acct = account orelse "0";
        const args = [_][]const u8{ "pcli", "view", "balance" };
        const r = run(init, &args, timeout_s, env_assign) orelse {
            _ = feat.err(init.io, "pen: cannot run pcli\n");
            std.process.exit(feat.EXIT_FAIL);
        };
        // rows look like: " # 0      200000000transfer/channel-18/erc20:0x..."
        b.appendSlice(alloc, "{\"account\":") catch {};
        b.appendSlice(alloc, acct) catch {};
        b.appendSlice(alloc, ",\"entries\":[") catch {};
        var first = true;
        var it = std.mem.splitScalar(u8, r.out, '\n');
        while (it.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (t.len == 0 or t[0] != '#') continue;
            var f = std.mem.tokenizeAny(u8, t, " \t");
            _ = f.next() orelse continue; // '#'
            const row_acct = f.next() orelse continue;
            const amtden = f.next() orelse continue;
            if (!std.mem.eql(u8, row_acct, acct)) continue;
            var e: usize = 0;
            while (e < amtden.len and (std.ascii.isDigit(amtden[e]) or amtden[e] == '.')) e += 1;
            if (e == 0) continue;
            if (!first) b.append(alloc, ',') catch {};
            first = false;
            b.appendSlice(alloc, "{\"amount\":") catch {};
            jsonString(&b, alloc, amtden[0..e]);
            b.appendSlice(alloc, ",\"denom\":") catch {};
            jsonString(&b, alloc, amtden[e..]);
            b.append(alloc, '}') catch {};
        }
        b.appendSlice(alloc, "],\"exit\":") catch {};
        var nb: [8]u8 = undefined;
        b.appendSlice(alloc, std.fmt.bufPrint(&nb, "{d}", .{r.code}) catch "0") catch {};
        b.append(alloc, '}') catch {};
        emit(init, &b);
        std.process.exit(if (r.code == 0) feat.EXIT_OK else feat.EXIT_FAIL);
    }

    const val = value orelse {
        _ = feat.eprint(init.io, "pen {s}: missing amount, e.g. 1000transfer/channel-18/erc20:0x...\n", .{sub});
        std.process.exit(feat.EXIT_USAGE);
    };

    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    args.appendSlice(alloc, &.{ "pcli", "tx" }) catch {};

    if (std.mem.eql(u8, sub, "swap")) {
        const dst = into orelse {
            _ = feat.err(init.io, "pen swap: --into DENOM is required\n");
            std.process.exit(feat.EXIT_USAGE);
        };
        args.appendSlice(alloc, &.{ "swap", "--into", dst }) catch {};
        if (source) |s| args.appendSlice(alloc, &.{ "--source", s }) catch {};
        args.append(alloc, val) catch {};
    } else if (std.mem.eql(u8, sub, "withdraw")) {
        const dest = to orelse {
            _ = feat.err(init.io, "pen withdraw: --to ADDRESS is required\n");
            std.process.exit(feat.EXIT_USAGE);
        };
        const ch = channel orelse {
            _ = feat.err(init.io, "pen withdraw: --channel N is required\n");
            std.process.exit(feat.EXIT_USAGE);
        };
        args.appendSlice(alloc, &.{ "withdraw", "--to", dest, "--channel", ch }) catch {};
        if (source) |s| args.appendSlice(alloc, &.{ "--source", s }) catch {};
        args.append(alloc, val) catch {};
    } else {
        _ = feat.eprint(init.io, "pen: unknown subcommand {s}\n", .{sub});
        std.process.exit(feat.EXIT_USAGE);
    }

    const r = run(init, args.items, timeout_s, env_assign) orelse {
        _ = feat.err(init.io, "pen: cannot run pcli\n");
        std.process.exit(feat.EXIT_FAIL);
    };
    const ids = txIds(alloc, r.out);
    const fs = fees(alloc, r.out);

    b.appendSlice(alloc, "{\"ok\":") catch {};
    b.appendSlice(alloc, if (r.code == 0) "true" else "false") catch {};
    b.appendSlice(alloc, ",\"exit\":") catch {};
    var nb: [8]u8 = undefined;
    b.appendSlice(alloc, std.fmt.bufPrint(&nb, "{d}", .{r.code}) catch "0") catch {};
    b.appendSlice(alloc, ",\"tx_ids\":[") catch {};
    for (ids, 0..) |id, k| {
        if (k > 0) b.append(alloc, ',') catch {};
        jsonString(&b, alloc, id);
    }
    b.appendSlice(alloc, "],\"fees\":[") catch {};
    for (fs, 0..) |fee, k| {
        if (k > 0) b.append(alloc, ',') catch {};
        jsonString(&b, alloc, fee);
    }
    b.appendSlice(alloc, "],\"sub\":") catch {};
    jsonString(&b, alloc, sub);
    if (r.code != 0) {
        b.appendSlice(alloc, ",\"tail\":") catch {};
        jsonString(&b, alloc, lastLine(r.out));
    }
    b.append(alloc, '}') catch {};
    emit(init, &b);
    std.process.exit(if (r.code == 0) feat.EXIT_OK else feat.EXIT_FAIL);
}
