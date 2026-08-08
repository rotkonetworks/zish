// jls - terse JSONL operations. Kills json.loads-per-line.
//   jls FILE             count records (non-empty lines)
//   jls -k key FILE      print value of top-level key per record
// Minimal scanner (no full JSON dep): finds "key" : then captures the scalar up to , or }.
const std = @import("std");

fn findKeyValue(line: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + key.len + 2 <= line.len) : (i += 1) {
        if (line[i] != '"' or !std.mem.startsWith(u8, line[i + 1 ..], key)) continue;
        const cq = i + 1 + key.len;
        if (cq >= line.len or line[cq] != '"') continue;
        var j = cq + 1;
        while (j < line.len and (line[j] == ' ' or line[j] == '\t')) j += 1;
        if (j >= line.len or line[j] != ':') continue;
        j += 1;
        while (j < line.len and (line[j] == ' ' or line[j] == '\t')) j += 1;
        const start = j;
        var end = j;
        while (end < line.len and line[end] != ',' and line[end] != '}' and line[end] != '\n') end += 1;
        return line[start..end];
    }
    return null;
}

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
    var key: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "-k")) { i += 1; key = argv[i]; }
        else if (path == null) path = a;
    }

    const data: []const u8 = if (path) |p|
    // never block an agent on a terminal: no file + stdin is a tty
    if (path == null and std.Io.File.stdin().isTty(init.io) catch false) {
        var eb: [256]u8 = undefined;
        var ew = std.Io.File.stderr().writer(init.io, &eb);
        ew.interface.writeAll("jls: no input (stdin is a terminal)\n") catch {};
        ew.flush() catch {};
        std.process.exit(2);
    }
        std.Io.Dir.cwd().readFileAlloc(init.io, p, alloc, .limited(1 << 30)) catch return
    else
        readAllStdin(alloc) catch return;
    defer if (path != null) alloc.free(data);

    var ob: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &ob);

    if (key) |k| {
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (findKeyValue(line, k)) |v| {
                if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') {
                    w.interface.writeAll(v[1 .. v.len - 1]) catch {};
                } else {
                    w.interface.writeAll(v) catch {};
                }
                w.interface.writeByte('\n') catch {};
            }
        }
    } else {
        var n: u64 = 0;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (line.len > 0) n += 1;
        }
        w.interface.print("{d}\n", .{n}) catch {};
    }
    w.flush() catch {};
}
