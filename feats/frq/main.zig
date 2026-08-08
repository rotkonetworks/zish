// frq - field/token frequency table, terse. Kills the Python Counter habit.
//   frq                 token frequencies on stdin
//   frq FILE            token frequencies in FILE
//   frq -n 10 FILE      top 10 by count
//   frq -w 2 FILE       a specific whitespace field (1-based) per line
// Output: count<TAB>value per row, sorted by count descending.
const std = @import("std");

fn ltVal(_: void, a: []const u8, b: []const u8) bool { return std.mem.lessThan(u8, a, b); }

const Group = struct { count: usize, value: []const u8 };
fn ltCount(_: void, a: Group, b: Group) bool { return b.count < a.count; }

fn readAllStdin(alloc: std.mem.Allocator) ![]u8 {
    var cap: usize = 8192;
    var buf = try alloc.alloc(u8, cap);
    errdefer alloc.free(buf);
    var len: usize = 0;
    while (true) {
        if (len == cap) { cap *= 2; buf = try alloc.realloc(buf, cap); }
        const n = try std.posix.read(0, buf[len..]);
        if (n == 0) break;
        len += n;
    }
    return buf[0..len];
}

pub fn main(init: std.process.Init) void {
    const alloc = init.gpa;
    const argv = init.minimal.args.toSlice(alloc) catch return;

    var top: usize = 0; // 0 = all
    var field: usize = 0; // 0 = whole-line tokens
    var path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "-n")) { i += 1; top = std.fmt.parseInt(usize, argv[i], 10) catch 0; }
        else if (std.mem.eql(u8, a, "-w")) { i += 1; field = std.fmt.parseInt(usize, argv[i], 10) catch 0; }
        else if (path == null) path = a;
    }

    const data: []const u8 = if (path) |p|
    // never block an agent on a terminal: no file + stdin is a tty
    if (path == null and std.Io.File.stdin().isTty(init.io) catch false) {
        var eb: [256]u8 = undefined;
        var ew = std.Io.File.stderr().writer(init.io, &eb);
        ew.interface.writeAll("frq: no input (stdin is a terminal)\n") catch {};
        ew.flush() catch {};
        std.process.exit(2);
    }
        std.Io.Dir.cwd().readFileAlloc(init.io, p, alloc, .limited(1 << 30)) catch return
    else
        readAllStdin(alloc) catch return;
    defer if (path != null) alloc.free(data);

    // collect tokens (pointers into data)
    var toks: std.ArrayList([]const u8) = .empty;
    defer toks.deinit(alloc);
    if (field > 0) {
        // pick the given whitespace field of each line
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            var fi: usize = 1;
            var fs = std.mem.tokenizeAny(u8, line, " \t\r");
            while (fs.next()) |t| : (fi += 1) {
                if (fi == field) { toks.append(alloc, t) catch return; break; }
            }
        }
    } else {
        var fs = std.mem.tokenizeAny(u8, data, " \t\r\n");
        while (fs.next()) |t| toks.append(alloc, t) catch return;
    }
    if (toks.items.len == 0) return;

    // sort by value, then group adjacent runs
    std.mem.sort([]const u8, toks.items, {}, ltVal);
    var groups: std.ArrayList(Group) = .empty;
    defer groups.deinit(alloc);
    {
        var k: usize = 0;
        while (k < toks.items.len) {
            const value = toks.items[k];
            var run: usize = 1;
            while (k + run < toks.items.len and std.mem.eql(u8, toks.items[k + run], value)) run += 1;
            groups.append(alloc, .{ .count = run, .value = value }) catch return;
            k += run;
        }
    }
    std.mem.sort(Group, groups.items, {}, ltCount);

    var ob: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &ob);
    const limit = if (top == 0) groups.items.len else @min(top, groups.items.len);
    for (groups.items[0..limit]) |g| {
        w.interface.print("{d}\t{s}\n", .{ g.count, g.value }) catch {};
    }
    w.flush() catch {};
}
