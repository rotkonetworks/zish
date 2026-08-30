//! prompt.zig — PS1 escape expansion and prompt building, extracted from
//! Shell.zig. Coupled to the shell only for allocator/last_exit_code/vi-mode/
//! variables via the passed *Shell.
const std = @import("std");
const compat = @import("compat.zig");
const posix = compat.posix;
const Shell = @import("Shell.zig");

pub const PromptInfo = struct {
    slice: []const u8,
    visible_len: u16,
};

// Expand a bash-style PS1 string into `buf`, honouring the common backslash
// escapes. `\[` / `\]` mark non-printing regions whose bytes are emitted but
// excluded from the visible-width count. Returns the rendered prompt.
fn expandPS1(self: *Shell, ps1: []const u8, buf: *[256]u8) PromptInfo {
    var len: usize = 0;
    var visible: u16 = 0;
    var nonprint = false; // inside a \[ ... \] region

    const put = struct {
        fn f(b: *[256]u8, l: *usize, v: *u16, np: bool, s: []const u8) void {
            for (s) |c| {
                if (l.* >= b.len) return;
                b[l.*] = c;
                l.* += 1;
                if (!np and c != 0x1b) v.* += 1;
            }
        }
    }.f;

    var i: usize = 0;
    while (i < ps1.len) {
        const c = ps1[i];
        if (c != '\\') {
            // count visible bytes, but not ANSI escape bodies
            if (len >= buf.len) break;
            buf[len] = c;
            len += 1;
            if (!nonprint and c != 0x1b) visible += 1;
            i += 1;
            continue;
        }
        // backslash escape
        i += 1;
        if (i >= ps1.len) {
            put(buf, &len, &visible, nonprint, "\\");
            break;
        }
        const e = ps1[i];
        i += 1;
        switch (e) {
            '[' => nonprint = true,
            ']' => nonprint = false,
            '\\' => put(buf, &len, &visible, nonprint, "\\"),
            'n' => put(buf, &len, &visible, nonprint, "\n"),
            'r' => put(buf, &len, &visible, nonprint, "\r"),
            't' => { // HH:MM:SS (UTC)
                var tb: [16]u8 = undefined;
                put(buf, &len, &visible, nonprint, ps1Time(self, &tb));
            },
            'd' => { // Weekday Mon DD (UTC)
                var db: [32]u8 = undefined;
                put(buf, &len, &visible, nonprint, ps1Date(self, &db));
            },
            'u' => {
                const user = compat.getEnvVarOwned(self.allocator, "USER") catch "";
                defer if (user.len > 0) self.allocator.free(user);
                put(buf, &len, &visible, nonprint, user);
            },
            'h', 'H' => {
                var hb: [posix.HOST_NAME_MAX]u8 = undefined;
                const host = posix.gethostname(&hb) catch "localhost";
                const out = if (e == 'h') blk: {
                    const dot = std.mem.indexOfScalar(u8, host, '.') orelse host.len;
                    break :blk host[0..dot];
                } else host;
                put(buf, &len, &visible, nonprint, out);
            },
            'w', 'W' => {
                var cwd_buf: [256]u8 = undefined;
                const cwd = posix.getcwd(&cwd_buf) catch "?";
                const home = compat.getEnvVarOwned(self.allocator, "HOME") catch null;
                defer if (home) |h| self.allocator.free(h);
                if (e == 'w') {
                    var pb: [256]u8 = undefined;
                    const disp = if (home) |h| dblk: {
                        if (std.mem.eql(u8, cwd, h)) break :dblk "~";
                        if (std.mem.startsWith(u8, cwd, h) and cwd.len > h.len and cwd[h.len] == '/')
                            break :dblk std.fmt.bufPrint(&pb, "~{s}", .{cwd[h.len..]}) catch cwd;
                        break :dblk cwd;
                    } else cwd;
                    put(buf, &len, &visible, nonprint, disp);
                } else {
                    // \W: basename, or ~ for home, or / for root
                    if (home != null and std.mem.eql(u8, cwd, home.?)) {
                        put(buf, &len, &visible, nonprint, "~");
                    } else if (std.mem.eql(u8, cwd, "/")) {
                        put(buf, &len, &visible, nonprint, "/");
                    } else {
                        const base = std.fs.path.basename(cwd);
                        put(buf, &len, &visible, nonprint, if (base.len == 0) cwd else base);
                    }
                }
            },
            '$' => put(buf, &len, &visible, nonprint, if (compat.posix.geteuid() == 0) "#" else "$"),
            'e' => put(buf, &len, &visible, nonprint, "\x1b"),
            'a' => put(buf, &len, &visible, nonprint, "\x07"),
            's' => put(buf, &len, &visible, nonprint, "zish"),
            else => {
                // unknown escape: emit backslash + char literally
                var eb: [2]u8 = .{ '\\', e };
                put(buf, &len, &visible, nonprint, eb[0..2]);
            },
        }
    }

    return .{ .slice = buf[0..len], .visible_len = visible };
}

fn ps1Time(self: *Shell, out: *[16]u8) []const u8 {
    _ = self;
    const secs: u64 = @intCast(@max(0, compat.timestamp()));
    const day_secs = secs % 86400;
    const h = day_secs / 3600;
    const m = (day_secs % 3600) / 60;
    const s = day_secs % 60;
    return std.fmt.bufPrint(out, "{d:0>2}:{d:0>2}:{d:0>2}", .{ h, m, s }) catch "";
}

fn ps1Date(self: *Shell, out: *[32]u8) []const u8 {
    _ = self;
    const secs: i64 = compat.timestamp();
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, secs)) };
    const ed = es.getEpochDay();
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    const wdays = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const wday = wdays[@intCast(ed.day % 7)]; // epoch day 0 = 1970-01-01 = Thursday
    const mon = months[@intFromEnum(md.month) - 1];
    return std.fmt.bufPrint(out, "{s} {s} {d:0>2}", .{ wday, mon, md.day_index + 1 }) catch "";
}

pub fn buildPrompt(self: *Shell, buf: *[256]u8) PromptInfo {
    // Custom PS1 overrides the built-in prompt when set (shell var or env).
    if (self.variables.get("PS1") orelse (posix.getenv("PS1"))) |ps1| {
        if (ps1.len > 0) return expandPS1(self, ps1, buf);
    }

    // get mode indicator
    const mode_str = self.vi.modeIndicatorColored();

    // get user
    const user = compat.getEnvVarOwned(self.allocator, "USER") catch "?";
    defer if (!std.mem.eql(u8, user, "?")) self.allocator.free(user);

    // get hostname
    var hostname_buf: [posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = posix.gethostname(&hostname_buf) catch "localhost";

    // get cwd
    var cwd_buf: [256]u8 = undefined;
    const cwd = posix.getcwd(&cwd_buf) catch "?";

    // simplify home path
    const home = compat.getEnvVarOwned(self.allocator, "HOME") catch null;
    defer if (home) |h| self.allocator.free(h);

    var path_buf: [256]u8 = undefined;
    const display_path = if (home) |h| blk: {
        if (std.mem.startsWith(u8, cwd, h)) {
            if (std.mem.eql(u8, cwd, h)) {
                break :blk "~";
            } else {
                break :blk std.fmt.bufPrint(&path_buf, "~{s}", .{cwd[h.len..]}) catch cwd;
            }
        }
        break :blk cwd;
    } else cwd;

    // color codes
    const green = "\x1b[32m"; // user@host
    const cyan = "\x1b[36m"; // path
    const red = "\x1b[31m"; // error
    const yellow = "\x1b[33m"; // git branch
    const reset = "\x1b[0m";

    // get git branch (fast — reads .git/HEAD directly)
    var branch_buf: [64]u8 = undefined;
    var branch_visible: u16 = 0;
    const branch_str = blk: {
        const head = std.Io.Dir.cwd().openFile(compat.io(), ".git/HEAD", .{}) catch break :blk "";
        defer head.close(compat.io());
        var hbuf: [256]u8 = undefined;
        const n = compat.readAll(head, &hbuf) catch break :blk "";
        const content = std.mem.trim(u8, hbuf[0..n], " \t\r\n");
        if (std.mem.startsWith(u8, content, "ref: refs/heads/")) {
            const name = content[16..];
            const blen = @min(name.len, 30); // truncate long branches
            branch_visible = @intCast(blen + 3); // " (branch)"
            break :blk std.fmt.bufPrint(&branch_buf, " {s}({s}){s}", .{ yellow, name[0..blen], reset }) catch "";
        }
        break :blk "";
    };

    // exit code indicator
    var exit_buf: [32]u8 = undefined;
    var exit_visible: u16 = 0;
    const exit_str = if (self.last_exit_code != 0) blk: {
        const s = std.fmt.bufPrint(&exit_buf, " {s}[{d}]{s}", .{ red, self.last_exit_code, reset }) catch "";
        // visible: " [N]" = 3 + digits
        var digits: u16 = 1;
        var v = self.last_exit_code;
        while (v >= 10) : (v /= 10) digits += 1;
        exit_visible = digits + 3;
        break :blk s;
    } else "";

    // format: [M] user@host path (branch) [exit] $
    const len = std.fmt.bufPrint(buf, "{s} {s}{s}@{s}{s} {s}{s}{s}{s}{s} $ ", .{
        mode_str,
        green, user, hostname, reset,
        cyan, display_path, reset,
        branch_str,
        exit_str,
    }) catch return .{ .slice = "$ ", .visible_len = 2 };

    // Calculate visible length by walking the formatted string and stripping ANSI escapes.
    // This is always correct regardless of how many color codes or special chars are in the prompt.
    const formatted = buf[0..len.len];
    var visible: u16 = 0;
    var in_esc = false;
    for (formatted) |c| {
        if (c == 0x1b) {
            in_esc = true;
        } else if (in_esc) {
            if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z')) in_esc = false;
        } else {
            visible += 1;
        }
    }

    return .{
        .slice = formatted,
        .visible_len = visible,
    };
}
