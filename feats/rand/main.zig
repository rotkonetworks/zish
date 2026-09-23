// rand - a uniform integer draw, and a percentage jitter draw.
//   rand MIN MAX        uniform integer in [MIN, MAX] inclusive
//   rand -j PCT         uniform integer in [-PCT, +PCT] (size jitter)
//   rand -p PCT         true with probability PCT% (exit 0) else false (exit 1)
//
// Why a feat: `$RANDOM` is unbound in zish, `16#hex` does not parse, and the
// nanosecond clock is not a random source — a schedule that leans on it is
// pretending. std.crypto.random is a CSPRNG seeded from the OS.
const std = @import("std");
const feat = @import("lib/feat.zig");
const linux = std.os.linux;

/// A seeded xoshiro, the way para seeds its own: getrandom plus the pid, so two
/// feats started in the same millisecond do not draw the same sequence.
fn rng() std.Random {
    var seed: [8]u8 = undefined;
    _ = linux.getrandom(&seed, seed.len, 0);
    const prng = struct {
        var p: std.Random.DefaultPrng = undefined;
    };
    prng.p = std.Random.DefaultPrng.init(std.mem.readInt(u64, &seed, .little) ^
        (@as(u64, @bitCast(@as(i64, linux.getpid()))) << 20));
    return prng.p.random();
}

pub fn main(init: std.process.Init) void {
    feat.restoreSigpipe();
    const alloc = init.arena.allocator();
    const argv = init.minimal.args.toSlice(alloc) catch return;

    if (argv.len < 2) {
        _ = feat.err(init.io, "usage: rand MIN MAX | rand -j PCT | rand -p PCT\n");
        std.process.exit(feat.EXIT_USAGE);
    }

    const r = rng();

    if (std.mem.eql(u8, argv[1], "-j") or std.mem.eql(u8, argv[1], "-p")) {
        const pct = std.fmt.parseInt(u32, if (argv.len > 2) argv[2] else "0", 10) catch {
            _ = feat.err(init.io, "rand: PCT must be an integer\n");
            std.process.exit(feat.EXIT_USAGE);
        };
        if (pct > 100) {
            _ = feat.err(init.io, "rand: PCT must be 0..100\n");
            std.process.exit(feat.EXIT_USAGE);
        }
        if (std.mem.eql(u8, argv[1], "-p")) {
            // probability gate: the exit status IS the answer
            const roll = r.intRangeAtMost(u32, 0, 99);
            if (roll < pct) std.process.exit(feat.EXIT_OK);
            std.process.exit(feat.EXIT_FAIL);
        }
        const v = r.intRangeAtMost(i64, -@as(i64, pct), pct);
        _ = feat.print(init.io, "{d}\n", .{v});
        return;
    }

    const lo = std.fmt.parseInt(i64, argv[1], 10) catch 0;
    const hi = std.fmt.parseInt(i64, if (argv.len > 2) argv[2] else "99", 10) catch 99;
    if (hi < lo) {
        _ = feat.err(init.io, "rand: MAX must be >= MIN\n");
        std.process.exit(feat.EXIT_USAGE);
    }
    const v = r.intRangeAtMost(i64, lo, hi);
    _ = feat.print(init.io, "{d}\n", .{v});
}
