// cnt - count things, in the fewest bytes.
//   cnt          count lines on stdin
//   cnt FILE     count lines in FILE
//   cnt -b FILE  count bytes
//   cnt -w FILE  count whitespace-delimited words
// Emits a single integer. That's the whole contract.
const std = @import("std");

const Want = enum { lines, bytes, words };

fn countIt(io: std.Io, alloc: std.mem.Allocator, path: ?[]const u8, want: Want) !u64 {
    var data: []const u8 = undefined;
    var owned: ?[]u8 = null;
    if (path) |p| {
        data = try std.Io.Dir.cwd().readFileAlloc(io, p, alloc, .limited(1 << 30));
    } else {
        var cap: usize = 8192;
        var buf = try alloc.alloc(u8, cap);
        errdefer alloc.free(buf);
        var len: usize = 0;
        while (true) {
            if (len == cap) {
                cap *= 2;
                buf = try alloc.realloc(buf, cap);
            }
            const n = try std.posix.read(0, buf[len..]);
            if (n == 0) break;
            len += n;
        }
        data = buf[0..len];
        owned = buf;
    }
    defer if (owned) |s| alloc.free(s);

    var total: u64 = 0;
    switch (want) {
        .bytes => total = data.len,
        .lines => {
            for (data) |c| {
                if (c == '\n') total += 1;
            }
            if (data.len > 0 and data[data.len - 1] != '\n') total += 1;
        },
        .words => {
            var in_word = false;
            for (data) |c| {
                const ws = c == ' ' or c == '\n' or c == '\t' or c == '\r';
                if (!ws and !in_word) { total += 1; in_word = true; }
                if (ws) in_word = false;
            }
        },
    }
    return total;
}

pub fn main(init: std.process.Init) void {
    const alloc = init.gpa;
    const argv = init.minimal.args.toSlice(alloc) catch return;

    var want: Want = .lines;
    var path: ?[]const u8 = null;
    for (argv[1..]) |a| {
        if (std.mem.eql(u8, a, "-b")) { want = .bytes; continue; }
        if (std.mem.eql(u8, a, "-w")) { want = .words; continue; }
        if (std.mem.eql(u8, a, "-l")) { want = .lines; continue; }
        if (path == null) path = a;
    }

    const n = countIt(init.io, alloc, path, want) catch return;
    // never block an agent on a terminal: no file + stdin is a tty
    if (path == null and std.Io.File.stdin().isTty(init.io) catch false) {
        var eb: [256]u8 = undefined;
        var ew = std.Io.File.stderr().writer(init.io, &eb);
        ew.interface.writeAll("cnt: no input (stdin is a terminal)\n") catch {};
        ew.flush() catch {};
        std.process.exit(2);
    }

    var ob: [4096]u8 = undefined;
    var nb: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&nb, "{d}\n", .{n}) catch return;
    var w = std.Io.File.stdout().writer(init.io, &ob);
    w.interface.writeAll(s) catch {};
    w.flush() catch {};
}
