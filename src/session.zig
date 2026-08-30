//! session.zig — host loop for a **session feat**.
//!
//! A normal feat is a one-shot filter: fork+exec+argv+stdio, run to completion,
//! reap. A *session feat* (feat.toml `kind = "session"`) is long-lived and
//! speaks a terse newline-delimited JSON frame protocol with zish over a pipe
//! pair. This is the atom of the LLM-control layer: the feat emits request
//! frames, zish executes them through its OWN executor (the same
//! parse→eval→sandbox→fd-3 path everything else uses), and writes result frames
//! back. Single-threaded; no foreground tty dance — a session feat's stdio is
//! pipes, not the terminal (it never claims the tty).
//!
//! Frame protocol v0 (one JSON object per line):
//!   feat → zish
//!     {"t":"run","cmd":"<shell command>"}   execute via zish, capture stdout
//!     {"t":"say","text":"<text>"}           display text to the human
//!     {"t":"done"}                          end the session
//!   zish → feat (reply to "run")
//!     {"t":"result","code":<int>,"out":"<captured stdout>"}
//!
//! v0 inherits zish's environment into the feat and applies no extra sandbox
//! narrowing — that (per-exec Landlock/seccomp, the secrets channel) lands with
//! the model + real tools, not this stub round-trip.

const std = @import("std");
const Shell = @import("Shell.zig");
const compat = @import("compat.zig");
const expand = @import("expand.zig");

/// Fork+exec `bin_path` with a bidirectional pipe pair and service its frames
/// until it sends {"t":"done"} or its stdout closes. Returns 0.
pub fn hostSessionFeat(shell: *Shell, bin_path: []const u8, args: []const []const u8) !u8 {
    const alloc = shell.allocator;

    // to_feat: zish writes → feat's stdin.  from_feat: feat's stdout → zish reads.
    const to_feat = try compat.posix.pipe();
    const from_feat = try compat.posix.pipe();

    // null-terminated argv (argv0 = bin_path), like featExec.
    if (1 + args.len >= 250) return 1;
    var argv: [250]?[*:0]const u8 = undefined;
    var held: std.ArrayList([:0]u8) = .empty;
    defer {
        for (held.items) |h| alloc.free(h);
        held.deinit(alloc);
    }
    const argv0 = try alloc.dupeZ(u8, bin_path);
    try held.append(alloc, argv0);
    argv[0] = argv0.ptr;
    var n: usize = 1;
    for (args) |a| {
        const dz = try alloc.dupeZ(u8, a);
        try held.append(alloc, dz);
        argv[n] = dz.ptr;
        n += 1;
    }
    argv[n] = null;
    const argv_ptr: [*:null]const ?[*:0]const u8 = argv[0..n :null];
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);

    shell.stdout().flush() catch {};

    const pid = compat.posix.fork() catch {
        try shell.stdout().print("zish: session fork failed\n", .{});
        return 1;
    };
    if (pid == 0) {
        // child: wire stdin ← to_feat[0], stdout → from_feat[1], drop all pipe fds.
        compat.posix.dup2(to_feat[0], compat.posix.STDIN_FILENO) catch compat.posix.exit(127);
        compat.posix.dup2(from_feat[1], compat.posix.STDOUT_FILENO) catch compat.posix.exit(127);
        compat.posix.close(to_feat[0]);
        compat.posix.close(to_feat[1]);
        compat.posix.close(from_feat[0]);
        compat.posix.close(from_feat[1]);
        compat.posix.execveZ(argv0.ptr, argv_ptr, envp) catch {};
        compat.posix.exit(127);
    }

    // parent: close the child's ends; keep w (write to feat) and r (read from feat).
    compat.posix.close(to_feat[0]);
    compat.posix.close(from_feat[1]);
    const w = to_feat[1];
    const r = from_feat[0];
    defer compat.posix.close(w);
    defer compat.posix.close(r);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    var tmp: [4096]u8 = undefined;

    outer: while (true) {
        // fill until we hold at least one complete line
        while (std.mem.indexOfScalar(u8, buf.items, '\n') == null) {
            const got = compat.posix.read(r, &tmp) catch break :outer;
            if (got == 0) break :outer; // feat closed stdout
            try buf.appendSlice(alloc, tmp[0..got]);
        }
        // drain every complete line currently buffered
        while (std.mem.indexOfScalar(u8, buf.items, '\n')) |nl| {
            const line = buf.items[0..nl];
            const stop = handleFrame(shell, line, w) catch false;
            const rest = buf.items[nl + 1 ..];
            std.mem.copyForwards(u8, buf.items, rest);
            buf.items.len = rest.len;
            if (stop) break :outer;
        }
    }

    _ = compat.posix.waitpid(pid, 0); // reap; the session's payload is the frames
    return 0;
}

/// Dispatch one frame line. Returns true when the session should end.
fn handleFrame(shell: *Shell, line: []const u8, w: compat.posix.fd_t) !bool {
    const alloc = shell.allocator;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch return false;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return false,
    };
    const t = switch (obj.get("t") orelse return false) {
        .string => |s| s,
        else => return false,
    };

    if (std.mem.eql(u8, t, "done")) return true;

    if (std.mem.eql(u8, t, "say")) {
        const text = if (obj.get("text")) |v| (switch (v) {
            .string => |s| s,
            else => "",
        }) else "";
        try shell.stdout().print("{s}\n", .{text});
        shell.stdout().flush() catch {};
        return false;
    }

    if (std.mem.eql(u8, t, "run")) {
        const cmd = if (obj.get("cmd")) |v| (switch (v) {
            .string => |s| s,
            else => "",
        }) else "";
        // Execute through zish's own executor with stdout captured — the same
        // path command substitution uses, so shell state / builtins / sandbox
        // all apply.
        const out = expand.executeCommandAndCapture(shell, cmd) catch try alloc.dupe(u8, "");
        defer alloc.free(out);

        var frame: std.ArrayListUnmanaged(u8) = .empty;
        defer frame.deinit(alloc);
        try frame.appendSlice(alloc, "{\"t\":\"result\",\"code\":0,\"out\":\"");
        try appendJsonEscaped(&frame, alloc, out);
        try frame.appendSlice(alloc, "\"}\n");
        writeAll(w, frame.items);
        return false;
    }

    return false; // unknown frame type: ignore (forward-compat)
}

fn writeAll(fd: compat.posix.fd_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const k = compat.posix.write(fd, bytes[off..]) catch return;
        if (k == 0) return;
        off += k;
    }
}

fn appendJsonEscaped(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\r' => try out.appendSlice(alloc, "\\r"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        else => if (c < 0x20) {
            var b: [8]u8 = undefined;
            const e = std.fmt.bufPrint(&b, "\\u{x:0>4}", .{c}) catch continue;
            try out.appendSlice(alloc, e);
        } else try out.append(alloc, c),
    };
}
