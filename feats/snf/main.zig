// snf - file sniff: one terse line per file.
//   snf FILE [FILE...]
// Output: path<TAB>size<TAB>lines<TAB>ext<TAB>magic-hex
const std = @import("std");

fn countLines(data: []const u8) usize {
    var n: usize = 0;
    for (data) |c| { if (c == '\n') n += 1; }
    if (data.len > 0 and data[data.len - 1] != '\n') n += 1;
    return n;
}

fn extensionOf(path: []const u8) []const u8 {
    var name = path;
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |si| name = path[si + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |di| return name[di + 1 ..];
    return "-";
}

pub fn main(init: std.process.Init) void {
    const alloc = init.gpa;
    const argv = init.minimal.args.toSlice(alloc) catch return;
    if (argv.len < 2) return;

    var ob: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &ob);

    for (argv[1..]) |path| {
        const data = std.Io.Dir.cwd().readFileAlloc(init.io, path, alloc, .limited(1 << 20)) catch {
            w.interface.print("{s}\topen\n", .{path}) catch {};
            continue;
        };
        // true size from stat
        var size: u64 = data.len;
        if (std.Io.Dir.cwd().statFile(init.io, path, .{})) |st| {
            size = st.size;
        } else |_| {}

        // magic: first up to 6 bytes as hex
        var mb: [16]u8 = undefined;
        var ml: usize = 0;
        const n = @min(@as(usize, 6), data.len);
        var k: usize = 0;
        while (k < n) : (k += 1) {
            mb[ml] = "0123456789abcdef"[(data[k] >> 4) & 0xf];
            mb[ml + 1] = "0123456789abcdef"[data[k] & 0xf];
            ml += 2;
        }

        w.interface.print("{s}\t{d}\t{d}\t{s}\t{s}\n", .{
            path, size, countLines(data), extensionOf(path), mb[0..ml],
        }) catch {};
        alloc.free(data);
    }
    w.flush() catch {};
}
