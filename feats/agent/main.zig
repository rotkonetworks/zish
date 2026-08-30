//! agent (session-feat stub) — proves the v0 frame round-trip with NO model.
//!
//! It emits `run` frames, reads zish's `result` replies (which requires zish to
//! have actually executed the command and written back), then `say`s what it got
//! and ends. Reaching the final `say` is itself proof the bidirectional loop
//! works: without zish executing and replying, the `readLine` after each `run`
//! would block forever and the feat would never reach `say`/`done`.
//!
//! The real agent replaces the canned body with a model loop (call the LLM →
//! parse tool-calls → emit `run` → feed `result` back), same frames.

const std = @import("std");
const linux = std.os.linux;

pub fn main() void {
    // 1. ask zish to run a command; capture what it sent back.
    var buf: [1 << 16]u8 = undefined;
    const r1 = runCapture("echo hello from the agent feat", &buf);
    // 2. run another; the result is what we echo back to prove data flowed.
    const r2 = runCapture("pwd", &buf);

    // 3. tell the human what the second command returned, via zish's renderer.
    var sbuf: [1 << 16]u8 = undefined;
    const msg = std.fmt.bufPrint(&sbuf, "agent: two commands ran; pwd result frame was {d} bytes, first was {d}", .{ r2, r1 }) catch "agent: done";
    say(msg);

    emit("{\"t\":\"done\"}\n");
}

/// Emit a `run` frame for `cmd`, then read the one-line `result` reply.
/// Returns the reply length (bytes), 0 if the stream closed.
fn runCapture(cmd: []const u8, reply: []u8) usize {
    var fbuf: [4096]u8 = undefined;
    const frame = std.fmt.bufPrint(&fbuf, "{{\"t\":\"run\",\"cmd\":\"{s}\"}}\n", .{cmd}) catch return 0;
    emit(frame);
    return readLine(reply);
}

fn say(text: []const u8) void {
    var fbuf: [1 << 16]u8 = undefined;
    const frame = std.fmt.bufPrint(&fbuf, "{{\"t\":\"say\",\"text\":\"{s}\"}}\n", .{text}) catch return;
    emit(frame);
}

fn emit(s: []const u8) void {
    var off: usize = 0;
    while (off < s.len) {
        const rc = linux.write(1, s.ptr + off, s.len - off);
        const sr: isize = @bitCast(rc);
        if (sr <= 0) return;
        off += @intCast(sr);
    }
}

/// Read one newline-terminated line from stdin into `buf`; returns bytes read
/// (including the newline), 0 on EOF.
fn readLine(buf: []u8) usize {
    var n: usize = 0;
    while (n < buf.len) {
        const rc = linux.read(0, buf.ptr + n, 1);
        const sr: isize = @bitCast(rc);
        if (sr <= 0) break;
        const c = buf[n];
        n += 1;
        if (c == '\n') break;
    }
    return n;
}
