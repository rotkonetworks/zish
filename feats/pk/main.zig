// pk - peek file lines, terse. One question, one answer.
//   pk FILE              first 10 lines
//   pk -n 3 FILE         first 3 lines
//   pk 4..10 FILE        lines 4..9 (Rust exclusive upper)
//   pk 4..=10 FILE       lines 4..10 (inclusive)
//   pk ..10 FILE         lines 1..9
//   pk 4.. FILE          lines 4..EOF
//   pk A B               multiple files, prefixed path:line (agent-safe)
const std = @import("std");

const LineRange = struct { lo: ?usize = null, hi: ?usize = null }; // hi is EXCLUSIVE

fn parseRange(tok: []const u8) ?LineRange {
    if (std.mem.indexOf(u8, tok, "..=")) |idx| {
        const lo = if (idx == 0) null else std.fmt.parseInt(usize, tok[0..idx], 10) catch return null;
        const hs = tok[idx + 3 ..];
        const hi = if (hs.len == 0) null else std.fmt.parseInt(usize, hs, 10) catch return null;
        return .{ .lo = lo, .hi = if (hi) |h| h + 1 else null };
    }
    if (std.mem.indexOf(u8, tok, "..")) |idx| {
        const lo = if (idx == 0) null else std.fmt.parseInt(usize, tok[0..idx], 10) catch return null;
        const hs = tok[idx + 2 ..];
        const hi = if (hs.len == 0) null else std.fmt.parseInt(usize, hs, 10) catch return null;
        return .{ .lo = lo, .hi = hi };
    }
    return null;
}

fn printUsage(io: std.Io) void {
    var eb: [256]u8 = undefined;
    var ew = std.Io.File.stderr().writer(io, &eb);
    ew.interface.writeAll("usage: pk [-n N] | [RANGE] FILE [FILE...]\n") catch {};
    ew.interface.writeAll("  RANGE: 4..10 (exclusive) | 4..=10 (inclusive) | ..10 | 4.. | ..\n") catch {};
    ew.flush() catch {};
}

pub fn main(init: std.process.Init) void {
    const alloc = init.gpa;
    const argv = init.minimal.args.toSlice(alloc) catch return;

    var n: usize = 10;
    var rng: ?LineRange = null;
    var tail_count: ?usize = null;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(alloc);

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "-n")) {
            i += 1;
            n = std.fmt.parseInt(usize, argv[i], 10) catch { std.process.exit(2); };
        } else if (std.mem.eql(u8, a, "-t")) {
            i += 1;
            tail_count = std.fmt.parseInt(usize, argv[i], 10) catch { std.process.exit(2); };
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            printUsage(init.io);
            std.process.exit(0);
        } else if (a.len > 1 and a[0] == '-') {
            printUsage(init.io);
            std.process.exit(2);
        } else if (parseRange(a)) |r| {
            rng = r; // a range token is not a file
        } else files.append(alloc, a) catch return;
    }
    if (files.items.len == 0) {
        printUsage(init.io);
        std.process.exit(2);
    }
    const multi = files.items.len > 1;

    var ob: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &ob);

    for (files.items) |f| {
        const data = std.Io.Dir.cwd().readFileAlloc(init.io, f, alloc, .limited(1 << 30)) catch continue;
        defer alloc.free(data);

        // tail (-t N) = last N lines: turn into an open-ended range from total-N+1
        var eff_rng = rng;
        if (tail_count != null and rng == null) {
            var total: usize = 0;
            var t: usize = 0;
            while (t < data.len) {
                const nl = std.mem.indexOfScalarPos(u8, data, t, '\n') orelse data.len;
                total += 1;
                if (nl >= data.len) break;
                t = nl + 1;
            }
            const tn = tail_count.?;
            eff_rng = .{ .lo = if (tn >= total) 1 else total - tn + 1, .hi = null };
        }

        var start: usize = 0;
        var line_no: usize = 0;
        var emitted: usize = 0;
        while (start < data.len) {
            const nl = std.mem.indexOfScalarPos(u8, data, start, '\n') orelse data.len;
            line_no += 1;
            const sel = if (eff_rng) |r|
                (r.lo orelse 1) <= line_no and (r.hi == null or line_no < r.hi.?)
            else
                emitted < n;
            if (sel) {
                if (multi) w.interface.print("{s}:{d}:", .{ f, line_no }) catch {};
                w.interface.writeAll(data[start..nl]) catch {};
                w.interface.writeAll("\n") catch {};
                emitted += 1;
            }
            if (nl >= data.len) break; // EOF: final line (with or without trailing newline)
            start = nl + 1;
        }
    }
    w.flush() catch {};
}
