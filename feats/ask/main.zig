//! ask — pose a question to the human and BLOCK until they answer in the
//! dashboard (or any client of the ask queue). A reusable interaction primitive:
//! a script or another feat (team, an agent loop) calls it to get a human
//! decision mid-run, routed to the browser.
//!
//!   ask "Deploy to prod?" "Yes" "No" "Only staging" "Abort"   # up to 4 options
//!   ask "What should the service be called?"                   # open-ended (free text)
//!   ask -t 60 "Proceed?" "Yes" "No"                            # 60s timeout
//!
//! Protocol (file-based, matches zish's file-shaped org state): writes the
//! question to ~/.zish/asks/<id>.json, then polls for ~/.zish/asks/<id>.answer.
//! For multiple choice the answer file holds the chosen 0-based INDEX; ask prints
//! that option's text. For an open question it holds free text, printed as-is.
//! Exit 0 = answered (answer on stdout), 3 = timed out, 2 = usage.

const std = @import("std");
const linux = std.os.linux;
const alloc = std.heap.page_allocator;

const MAX = 1 << 20;
const POLL_MS = 200;
const DEFAULT_TIMEOUT_S: u64 = 300;

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
fn out(b: []const u8) void {
    writeFd(1, b);
}
fn warn(b: []const u8) void {
    writeFd(2, b);
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
fn readFileAlloc(path: []const u8) ?[]u8 {
    var z: [4096]u8 = undefined;
    const p = toZ(&z, path) orelse return null;
    const fd: isize = @bitCast(linux.open(p, .{ .ACCMODE = .RDONLY }, 0));
    if (fd < 0) return null;
    defer _ = linux.close(@intCast(fd));
    return slurp(@intCast(fd), MAX);
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
fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
}

/// JSON-escape into `o`.
fn jsonEsc(o: *std.ArrayListUnmanaged(u8), s: []const u8) void {
    for (s) |c| switch (c) {
        '"' => o.appendSlice(alloc, "\\\"") catch {},
        '\\' => o.appendSlice(alloc, "\\\\") catch {},
        '\n' => o.appendSlice(alloc, "\\n") catch {},
        '\r' => {},
        '\t' => o.appendSlice(alloc, "\\t") catch {},
        else => if (c >= 0x20) (o.append(alloc, c) catch {}),
    };
}

pub fn main(init: std.process.Init.Minimal) u8 {
    return run(init.args);
}

fn run(args: std.process.Args) u8 {
    var it = args.iterate();
    _ = it.next(); // argv[0]

    var timeout_s: u64 = DEFAULT_TIMEOUT_S;
    var question: ?[]const u8 = null;
    var options: std.ArrayListUnmanaged([]const u8) = .empty;
    defer options.deinit(alloc);

    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            warn("usage: ask [-t <seconds>] \"<question>\" [\"opt1\" ... \"opt4\"]\n");
            return 0;
        }
        if (std.mem.eql(u8, a, "-t")) {
            const v = it.next() orelse return usageErr();
            timeout_s = std.fmt.parseInt(u64, v, 10) catch return usageErr();
            continue;
        }
        if (question == null) {
            question = a;
        } else {
            if (options.items.len >= 4) {
                warn("ask: at most 4 options\n");
                return 2;
            }
            options.append(alloc, a) catch {};
        }
    }
    const q = question orelse return usageErr();
    if (options.items.len == 1) {
        warn("ask: give 0 (open) or 2-4 options\n");
        return 2;
    }

    const home = getEnv("HOME") orelse {
        warn("ask: HOME unset\n");
        return 2;
    };
    // ensure ~/.zish/asks
    {
        var db: [4096]u8 = undefined;
        if (std.fmt.bufPrint(&db, "{s}/.zish", .{home})) |d| {
            var z: [4096]u8 = undefined;
            if (toZ(&z, d)) |p| _ = linux.mkdir(p, 0o700);
        } else |_| {}
        if (std.fmt.bufPrint(&db, "{s}/.zish/asks", .{home})) |d| {
            var z: [4096]u8 = undefined;
            if (toZ(&z, d)) |p| _ = linux.mkdir(p, 0o700);
        } else |_| {}
    }

    const id = std.fmt.allocPrint(alloc, "{d}-{d}", .{ linux.getpid(), nowNs() }) catch return 2;
    defer alloc.free(id);
    const qpath = std.fmt.allocPrint(alloc, "{s}/.zish/asks/{s}.json", .{ home, id }) catch return 2;
    defer alloc.free(qpath);
    const apath = std.fmt.allocPrint(alloc, "{s}/.zish/asks/{s}.answer", .{ home, id }) catch return 2;
    defer alloc.free(apath);

    // write the question record
    {
        var j: std.ArrayListUnmanaged(u8) = .empty;
        defer j.deinit(alloc);
        j.appendSlice(alloc, "{\"id\":\"") catch {};
        jsonEsc(&j, id);
        j.appendSlice(alloc, "\",\"q\":\"") catch {};
        jsonEsc(&j, q);
        j.appendSlice(alloc, "\",\"options\":[") catch {};
        for (options.items, 0..) |opt, i| {
            if (i > 0) j.append(alloc, ',') catch {};
            j.append(alloc, '"') catch {};
            jsonEsc(&j, opt);
            j.append(alloc, '"') catch {};
        }
        j.appendSlice(alloc, "]}") catch {};
        if (!writeFileTrunc(qpath, j.items)) {
            warn("ask: cannot write question\n");
            return 2;
        }
    }
    defer unlinkPath(qpath);
    defer unlinkPath(apath);

    // block, polling for the answer file
    const deadline = nowNs() + timeout_s *% 1_000_000_000;
    while (nowNs() < deadline) {
        if (readFileAlloc(apath)) |raw| {
            defer alloc.free(raw);
            const ans = std.mem.trim(u8, raw, " \t\r\n");
            if (ans.len == 0) {
                // written but empty; keep waiting a beat
            } else if (options.items.len == 0) {
                out(ans); // open question — free text
                out("\n");
                return 0;
            } else if (std.fmt.parseInt(usize, ans, 10)) |idx| {
                if (idx < options.items.len) {
                    out(options.items[idx]); // MC — print the chosen option text
                    out("\n");
                    return 0;
                }
            } else |_| {
                out(ans); // not an index — echo whatever came back
                out("\n");
                return 0;
            }
        }
        var ts: linux.timespec = .{ .sec = 0, .nsec = POLL_MS * 1_000_000 };
        _ = linux.nanosleep(&ts, &ts);
    }
    warn("ask: timed out with no answer\n");
    return 3;
}

fn usageErr() u8 {
    warn("usage: ask [-t <seconds>] \"<question>\" [\"opt1\" ... \"opt4\"]\n");
    return 2;
}
