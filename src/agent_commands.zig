// agent_commands.zig — table-driven slash command dispatcher for agent interactive mode
const std = @import("std");
const Shell = @import("Shell.zig");
const editor = @import("editor.zig");
const agent_log = @import("agent_log.zig");
const agent_mod = @import("agent.zig");

/// Result of a command dispatch — tells the caller what to do next.
pub const DispatchResult = enum {
    /// Command handled, continue the input loop.
    handled,
    /// No matching command found — caller should send to agent.
    not_found,
    /// Exit agent mode (return 0).
    exit,
    /// Shell escape (return 2 = "dropped to shell, agent still running").
    shell_escape,
    /// Enter ?-translation mode (caller sets translate state).
    translate,
};

// ── Terminal width helpers (moved from agentInteractive local TermWidth) ──

pub const TermWidth = struct {
    pub fn charWidth(s: []const u8, i: *usize) u2 {
        var cp: u32 = 0;
        const b0 = s[i.*];
        var expect: u3 = 0;
        if ((b0 & 0xE0) == 0xC0) {
            cp = b0 & 0x1F;
            expect = 1;
        } else if ((b0 & 0xF0) == 0xE0) {
            cp = b0 & 0x0F;
            expect = 2;
        } else if ((b0 & 0xF8) == 0xF0) {
            cp = b0 & 0x07;
            expect = 3;
        }
        i.* += 1;
        var got: u3 = 0;
        while (got < expect and i.* < s.len and (s[i.*] & 0xC0) == 0x80) : (got += 1) {
            cp = (cp << 6) | @as(u32, s[i.*] & 0x3F);
            i.* += 1;
        }
        while (i.* < s.len and (s[i.*] & 0xC0) == 0x80) : (i.* += 1) {}
        if ((cp >= 0x1100 and cp <= 0x115F) or
            cp == 0x2329 or cp == 0x232A or
            (cp >= 0x2E80 and cp <= 0x303E) or
            (cp >= 0x3040 and cp <= 0x33BF) or
            (cp >= 0x3400 and cp <= 0x4DBF) or
            (cp >= 0x4E00 and cp <= 0xA4CF) or
            (cp >= 0xAC00 and cp <= 0xD7AF) or
            (cp >= 0xF900 and cp <= 0xFAFF) or
            (cp >= 0xFE30 and cp <= 0xFE6F) or
            (cp >= 0xFF01 and cp <= 0xFF60) or
            (cp >= 0xFFE0 and cp <= 0xFFE6) or
            (cp >= 0x1F300 and cp <= 0x1F9FF) or
            (cp >= 0x20000 and cp <= 0x2FA1F))
            return 2;
        return 1;
    }

    pub fn skipEsc(s: []const u8, i: *usize) void {
        i.* += 1;
        if (i.* < s.len and s[i.*] == '[') {
            i.* += 1;
            while (i.* < s.len and (s[i.*] < 0x40 or s[i.*] > 0x7E)) : (i.* += 1) {}
            if (i.* < s.len) i.* += 1;
        }
    }

    pub fn width(s: []const u8) u16 {
        var w: u16 = 0;
        var i: usize = 0;
        while (i < s.len) {
            if (s[i] == 0x1b) {
                skipEsc(s, &i);
            } else if (s[i] >= 0x80) {
                w += charWidth(s, &i);
            } else if (s[i] == '\t') {
                w = (w + 8) & ~@as(u16, 7);
                i += 1;
            } else {
                w += 1;
                i += 1;
            }
        }
        return w;
    }

    pub fn truncate(s: []const u8, max_cols: usize) usize {
        var i: usize = 0;
        var cols: usize = 0;
        while (i < s.len and cols < max_cols) {
            if (s[i] == 0x1b) {
                skipEsc(s, &i);
            } else if (s[i] >= 0x80) {
                const prev_i = i;
                const cw = charWidth(s, &i);
                if (cols + cw > max_cols) {
                    i = prev_i;
                    break;
                }
                cols += cw;
            } else if (s[i] == '\t') {
                const next = (cols + 8) & ~@as(usize, 7);
                if (next > max_cols) break;
                cols = next;
                i += 1;
            } else {
                cols += 1;
                i += 1;
            }
        }
        return i;
    }
};

const displayWidth = TermWidth.width;
const truncateToCols = TermWidth.truncate;

// ── Layout helpers (moved from agentInteractive local Layout struct) ──

pub const Layout = struct {
    pub fn drawSeparator(w: anytype, row: u16, cols: u16, scroll_off: u32) void {
        w.print("\x1b[{d};1H\x1b[2K\x1b[90m", .{row}) catch {};
        if (scroll_off > 0) {
            var indicator_buf: [64]u8 = undefined;
            const indicator = std.fmt.bufPrint(&indicator_buf, " \xe2\x86\x91 {d} lines ", .{scroll_off}) catch "";
            const ind_cols = displayWidth(indicator);
            const pad_left = (cols -| ind_cols) / 2;
            var ci: u16 = 0;
            while (ci < pad_left) : (ci += 1) w.writeAll("\xe2\x94\x80") catch {};
            w.writeAll(indicator) catch {};
            ci += ind_cols;
            while (ci < cols) : (ci += 1) w.writeAll("\xe2\x94\x80") catch {};
        } else {
            var ci: u16 = 0;
            while (ci < cols) : (ci += 1) w.writeAll("\xe2\x94\x80") catch {};
        }
        w.writeAll("\x1b[0m") catch {};
    }

    pub fn drawInput(w: anytype, first_row: u16, rows: u16, ebuf: *const editor.EditBuffer) void {
        const line_count = ebuf.lineCount();
        const cur_line: u16 = blk: {
            var cl: u16 = 0;
            for (ebuf.text[0..ebuf.cursor]) |c| {
                if (c == '\n') cl += 1;
            }
            break :blk cl;
        };
        const scroll_start: u16 = if (cur_line >= rows) cur_line - rows + 1 else 0;
        var line_i: u16 = 0;
        while (line_i < rows) : (line_i += 1) {
            w.print("\x1b[{d};1H\x1b[2K", .{first_row + line_i}) catch {};
            const abs_line = scroll_start + line_i;
            if (abs_line < line_count) {
                const line_text = ebuf.getLine(abs_line);
                if (abs_line == 0) {
                    if (ebuf.vi_mode == .normal) {
                        w.writeAll("\x1b[33m \xe2\x9d\xaf\x1b[0m  ") catch {};
                    } else {
                        w.writeAll("\x1b[34m \xe2\x9d\xaf\x1b[0m  ") catch {};
                    }
                } else {
                    w.writeAll("    ") catch {};
                }
                w.writeAll(line_text) catch {};
            }
        }
        const vis_line = cur_line - scroll_start;
        const byte_col = ebuf.currentCol();
        const line_start_byte = ebuf.cursor - byte_col;
        const cur_col = displayWidth(ebuf.text[line_start_byte..ebuf.cursor]);
        const prefix_width: u16 = 4;
        w.print("\x1b[{d};{d}H", .{ first_row + vis_line, prefix_width + cur_col + 1 }) catch {};
        if (ebuf.vi_mode == .normal) {
            w.writeAll("\x1b[2 q") catch {};
        } else {
            w.writeAll("\x1b[6 q") catch {};
        }
    }

    pub fn drawStatusBar(w: anytype, row: u16, cols: u16, mdl: []const u8, cost: []const u8, status: []const u8) void {
        drawStatusBarFull(w, row, cols, mdl, cost, status, 0);
    }

    pub fn drawStatusBarFull(w: anytype, row: u16, cols: u16, mdl: []const u8, cost: []const u8, status: []const u8, elapsed_ms: i64) void {
        w.print("\x1b[{d};1H\x1b[2K\x1b[90;7m ", .{row}) catch {};
        var display_cols: u16 = 1;
        const mdl_w = displayWidth(mdl);
        if (display_cols + mdl_w < cols) {
            w.writeAll(mdl) catch {};
            display_cols += mdl_w;
        } else {
            const trunc = truncateToCols(mdl, cols -| display_cols);
            w.writeAll(mdl[0..trunc]) catch {};
            display_cols = cols;
        }
        if (status.len > 0 and display_cols + 4 < cols) {
            w.writeAll(" \xe2\x94\x82 ") catch {};
            display_cols += 3;
            w.writeAll("\x1b[0;93;7m") catch {};
            const sw = displayWidth(status);
            if (display_cols + sw < cols) {
                w.writeAll(status) catch {};
                display_cols += sw;
            } else {
                const trunc = truncateToCols(status, cols -| display_cols);
                w.writeAll(status[0..trunc]) catch {};
                display_cols = cols;
            }
            w.writeAll("\x1b[90;7m") catch {};
        }
        if (cost.len > 0 and display_cols + 4 < cols) {
            w.writeAll(" \xe2\x94\x82 ") catch {};
            display_cols += 3;
            w.writeAll(cost) catch {};
            display_cols += displayWidth(cost);
        }
        if (elapsed_ms > 0 and display_cols + 6 < cols) {
            const secs = @divTrunc(elapsed_ms, 1000);
            var elapsed_buf: [32]u8 = undefined;
            const elapsed = if (secs >= 60)
                std.fmt.bufPrint(&elapsed_buf, " {d}m {d:0>2}s", .{ @divTrunc(secs, 60), @mod(secs, 60) }) catch ""
            else
                std.fmt.bufPrint(&elapsed_buf, " {d}s", .{secs}) catch "";
            w.writeAll(" \xe2\x94\x82") catch {};
            display_cols += 2;
            w.writeAll(elapsed) catch {};
            display_cols += displayWidth(elapsed);
        }
        if (display_cols + 19 <= cols) {
            w.writeAll(" \xe2\x94\x82 ^D:exit \xe2\x94\x82 /help ") catch {};
            display_cols += 19;
        }
        while (display_cols < cols) : (display_cols += 1) w.writeByte(' ') catch {};
        w.writeAll("\x1b[0m") catch {};
    }

    pub fn drawInputSafe(w: anytype, first_row: u16, rows: u16, ebuf: *const editor.EditBuffer, streaming: bool) void {
        if (streaming) {
            w.writeAll("\x1b[s") catch {};
            drawInput(w, first_row, rows, ebuf);
            w.writeAll("\x1b[u") catch {};
        } else {
            drawInput(w, first_row, rows, ebuf);
        }
    }

    pub fn drawInputSafeFull(w: anytype, first_row: u16, rows: u16, ebuf: *const editor.EditBuffer, streaming: bool, scroll_last: u16, t_rows: u16) void {
        if (streaming and t_rows > 0) {
            w.writeAll("\x1b[s") catch {};
            w.print("\x1b[1;{d}r", .{t_rows}) catch {};
            drawInput(w, first_row, rows, ebuf);
            w.print("\x1b[1;{d}r", .{scroll_last}) catch {};
            w.writeAll("\x1b[u") catch {};
        } else {
            drawInput(w, first_row, rows, ebuf);
        }
    }

    pub fn drawStatusBarSafe(w: anytype, stat_row: u16, t_rows: u16, scroll_last: u16, cols: u16, mdl: []const u8, cost: []const u8, status: []const u8) void {
        drawStatusBarSafeElapsed(w, stat_row, t_rows, scroll_last, cols, mdl, cost, status, 0);
    }

    pub fn drawStatusBarSafeElapsed(w: anytype, stat_row: u16, t_rows: u16, scroll_last: u16, cols: u16, mdl: []const u8, cost: []const u8, status: []const u8, elapsed_ms: i64) void {
        w.writeAll("\x1b[s") catch {};
        w.print("\x1b[1;{d}r", .{t_rows}) catch {};
        drawStatusBarFull(w, stat_row, cols, mdl, cost, status, elapsed_ms);
        w.print("\x1b[1;{d}r", .{scroll_last}) catch {};
        w.writeAll("\x1b[u") catch {};
    }

    pub fn goOutput(w: anytype, row: u16) void {
        w.print("\x1b[{d};1H", .{row}) catch {};
    }

    pub fn doExit(w: anytype, rows: u16, in_h: u16) void {
        w.writeAll("\x1b[0 q\x1b[?25h") catch {};
        w.print("\x1b[1;{d}r", .{rows}) catch {};
        w.print("\x1b[{d};1H\x1b[2K", .{rows}) catch {};
        var ri: u16 = 0;
        while (ri < in_h) : (ri += 1) {
            w.print("\x1b[{d};1H\x1b[2K", .{rows -| (1 + ri)}) catch {};
        }
        w.print("\x1b[{d};1H\x1b[2K", .{rows -| (1 + in_h)}) catch {};
        w.print("\x1b[{d};1H\n", .{rows}) catch {};
        w.flush() catch {};
    }

    pub fn repaintFromHistory(w: anytype, hist: *const MessageHistory, out_rows: u16, scroll_off: u32) void {
        if (hist.line_count == 0) return;
        const total = hist.line_count;
        const visible: u32 = @min(out_rows, total);
        const bottom_line = if (total > scroll_off) total - scroll_off else 0;
        const top_line = if (bottom_line > visible) bottom_line - visible else 0;

        var row: u16 = 1;
        var line_idx = top_line;
        while (row <= out_rows and line_idx < bottom_line) : ({
            row += 1;
            line_idx += 1;
        }) {
            w.print("\x1b[{d};1H\x1b[2K", .{row}) catch {};
            if (hist.getLine(line_idx)) |line_data| {
                w.writeAll(line_data) catch {};
            }
        }
        while (row <= out_rows) : (row += 1) {
            w.print("\x1b[{d};1H\x1b[2K", .{row}) catch {};
        }
        w.writeAll("\x1b[0m") catch {};
    }

    pub fn recalcLayout(
        w: anytype,
        t_rows: u16,
        t_cols: u16,
        in_h: u16,
        o_last: *u16,
        s_row: *u16,
        in_first: *u16,
        stat_row: *u16,
        ebuf: *const editor.EditBuffer,
        mdl: []const u8,
        cost: []const u8,
        scroll_off: u32,
        status: []const u8,
    ) void {
        const fr: u16 = 2;
        o_last.* = t_rows -| (fr + in_h);
        if (o_last.* < 2) o_last.* = 2;
        s_row.* = o_last.* + 1;
        in_first.* = s_row.* + 1;
        stat_row.* = t_rows;

        w.print("\x1b[1;{d}r", .{t_rows}) catch {};
        drawSeparator(w, s_row.*, t_cols, scroll_off);
        drawInput(w, in_first.*, in_h, ebuf);
        drawStatusBar(w, stat_row.*, t_cols, mdl, cost, status);
        w.print("\x1b[1;{d}r", .{o_last.*}) catch {};
    }
};

// ── MessageHistory ring buffer (moved from builtins.zig) ──

pub const MessageHistory = struct {
    buf: [BUF_SIZE]u8 = undefined,
    buf_pos: u32 = 0,
    buf_used: u32 = 0,
    line_starts: [MAX_LINES]u32 = undefined,
    line_lens: [MAX_LINES]u16 = undefined,
    line_count: u32 = 0,
    first_line: u32 = 0,
    cur_line_start: u32 = 0,
    cur_line_len: u16 = 0,
    in_line: bool = false,

    const BUF_SIZE = 512 * 1024;
    const MAX_LINES = 8192;

    pub fn commitLine(self: *MessageHistory) void {
        if (!self.in_line) return;
        const idx = (self.first_line + self.line_count) % MAX_LINES;
        self.line_starts[idx] = self.cur_line_start;
        self.line_lens[idx] = self.cur_line_len;
        if (self.line_count >= MAX_LINES) {
            self.first_line = (self.first_line + 1) % MAX_LINES;
        } else {
            self.line_count += 1;
        }
        self.in_line = false;
        self.cur_line_len = 0;
    }

    pub fn appendByte(self: *MessageHistory, b: u8) void {
        if (!self.in_line) {
            self.cur_line_start = self.buf_pos;
            self.cur_line_len = 0;
            self.in_line = true;
        }
        self.buf[self.buf_pos % BUF_SIZE] = b;
        self.buf_pos +%= 1;
        if (self.buf_used < BUF_SIZE) self.buf_used += 1;
        if (self.cur_line_len < 65535) self.cur_line_len += 1;
    }

    pub fn appendSlice(self: *MessageHistory, data: []const u8) void {
        for (data) |b| {
            if (b == '\n') {
                self.commitLine();
            } else {
                self.appendByte(b);
            }
        }
    }

    pub fn getLine(self: *const MessageHistory, idx: u32) ?[]const u8 {
        if (idx >= self.line_count) return null;
        const real_idx = (self.first_line + idx) % MAX_LINES;
        const start = self.line_starts[real_idx];
        const len = self.line_lens[real_idx];
        if (len == 0) return "";
        const SCRATCH_SIZE = 16384;
        const S = struct {
            threadlocal var scratch: [SCRATCH_SIZE]u8 = undefined;
        };
        const copy_len: usize = @min(len, SCRATCH_SIZE);
        for (0..copy_len) |i| {
            S.scratch[i] = self.buf[(start +% @as(u32, @intCast(i))) % BUF_SIZE];
        }
        return S.scratch[0..copy_len];
    }

    pub fn searchBack(self: *const MessageHistory, pattern: []const u8, start_from: u32) ?u32 {
        if (pattern.len == 0 or self.line_count == 0) return null;
        var low_pat: [128]u8 = undefined;
        const plen = @min(pattern.len, 128);
        for (pattern[0..plen], 0..) |c, i| {
            low_pat[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        const lp = low_pat[0..plen];

        var idx: u32 = @min(start_from, self.line_count);
        while (idx > 0) {
            idx -= 1;
            const line = self.getLine(idx) orelse continue;
            if (line.len < plen) continue;
            var stripped: [8192]u8 = undefined;
            var si: usize = 0;
            var li: usize = 0;
            while (li < line.len and si < stripped.len) {
                if (line[li] == 0x1b) {
                    li += 1;
                    if (li < line.len and line[li] == '[') {
                        li += 1;
                        while (li < line.len and (line[li] < 0x40 or line[li] > 0x7E))
                            li += 1;
                        if (li < line.len) li += 1;
                    }
                    continue;
                }
                stripped[si] = if (line[li] >= 'A' and line[li] <= 'Z') line[li] + 32 else line[li];
                si += 1;
                li += 1;
            }
            if (si >= plen) {
                var j: usize = 0;
                while (j + plen <= si) : (j += 1) {
                    if (std.mem.eql(u8, stripped[j..j + plen], lp)) return idx;
                }
            }
        }
        return null;
    }

    pub fn searchForward(self: *const MessageHistory, pattern: []const u8, start_from: u32) ?u32 {
        if (pattern.len == 0 or self.line_count == 0) return null;
        var low_pat: [128]u8 = undefined;
        const plen = @min(pattern.len, 128);
        for (pattern[0..plen], 0..) |c, i| {
            low_pat[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        const lp = low_pat[0..plen];

        var idx: u32 = start_from;
        while (idx < self.line_count) : (idx += 1) {
            const line = self.getLine(idx) orelse continue;
            if (line.len < plen) continue;
            var stripped: [8192]u8 = undefined;
            var si: usize = 0;
            var li: usize = 0;
            while (li < line.len and si < stripped.len) {
                if (line[li] == 0x1b) {
                    li += 1;
                    if (li < line.len and line[li] == '[') {
                        li += 1;
                        while (li < line.len and (line[li] < 0x40 or line[li] > 0x7E))
                            li += 1;
                        if (li < line.len) li += 1;
                    }
                    continue;
                }
                stripped[si] = if (line[li] >= 'A' and line[li] <= 'Z') line[li] + 32 else line[li];
                si += 1;
                li += 1;
            }
            if (si >= plen) {
                var j: usize = 0;
                while (j + plen <= si) : (j += 1) {
                    if (std.mem.eql(u8, stripped[j..j + plen], lp)) return idx;
                }
            }
        }
        return null;
    }
};

// ── TeeWriter (moved from builtins.zig) ──

pub fn TeeWriter(comptime W: type) type {
    return struct {
        inner: W,
        hist: *MessageHistory,

        const Self = @This();

        pub fn writeAll(self: Self, data: []const u8) !void {
            try self.inner.writeAll(data);
            self.hist.appendSlice(data);
        }

        pub fn writeByte(self: Self, b: u8) !void {
            try self.inner.writeByte(b);
            if (b == '\n') {
                self.hist.commitLine();
            } else {
                self.hist.appendByte(b);
            }
        }

        pub fn print(self: Self, comptime fmt: []const u8, args: anytype) !void {
            try self.inner.print(fmt, args);
            var fmt_buf: [4096]u8 = undefined;
            const formatted = std.fmt.bufPrint(&fmt_buf, fmt, args) catch {
                self.hist.appendSlice(&fmt_buf);
                return;
            };
            self.hist.appendSlice(formatted);
        }

        pub fn flush(self: Self) !void {
            try self.inner.flush();
        }
    };
}

// ── Command context: bundles all TUI state needed by handlers ──

pub const CommandCtx = struct {
    shell: *Shell,
    out: *std.Io.Writer,
    // Model display
    model_name: []u8,
    model_buf: *[64]u8,
    // Cost display
    cost_buf: *[32]u8,
    cost_len: *usize,
    // Status text
    status_text: *[64]u8,
    status_len: *usize,
    // Message history
    msg_history: *MessageHistory,
    // Edit buffer
    edit_buf: *editor.EditBuffer,
    // Agent state
    agent_active: *bool,
    query_start_ms: *i64,
    // Scroll state
    scroll_offset: *u32,
    // Layout params
    out_last: *u16,
    sep_row: *u16,
    input_first_row: *u16,
    status_row: *u16,
    term_rows: *u16,
    term_cols: *u16,
    input_height: *u16,
    // Markdown renderer
    md: *agent_mod.MarkdownRenderer,
    last_was_text: *bool,

    // ── Helper methods for common patterns ──

    fn goOutputAndFlush(self: *CommandCtx) void {
        Layout.goOutput(self.out, self.out_last.*);
        self.out.flush() catch {};
    }

    fn setStatus(self: *CommandCtx, text: []const u8) void {
        @memcpy(self.status_text[0..text.len], text);
        self.status_len.* = text.len;
    }

    fn drawStatusElapsed(self: *CommandCtx) void {
        const elapsed = if (self.query_start_ms.* > 0) std.time.milliTimestamp() - self.query_start_ms.* else 0;
        Layout.drawStatusBarSafeElapsed(self.out, self.status_row.*, self.term_rows.*, self.out_last.*, self.term_cols.*, self.model_name, self.cost_buf[0..self.cost_len.*], self.status_text[0..self.status_len.*], elapsed);
    }

    fn historyNote(self: *CommandCtx, text: []const u8) void {
        self.msg_history.appendSlice(text);
        self.msg_history.commitLine();
    }

    fn recalc(self: *CommandCtx) void {
        Layout.recalcLayout(self.out, self.term_rows.*, self.term_cols.*, self.input_height.*, self.out_last, self.sep_row, self.input_first_row, self.status_row, self.edit_buf, self.model_name, self.cost_buf[0..self.cost_len.*], self.scroll_offset.*, self.status_text[0..self.status_len.*]);
    }
};

// ── Command table ──

const Command = struct {
    name: []const u8,
    has_arg: bool, // true = command takes remaining text as argument
    handler: *const fn (*CommandCtx, []const u8) DispatchResult,
};

const commands = [_]Command{
    .{ .name = "exit", .has_arg = false, .handler = cmdExit },
    .{ .name = "quit", .has_arg = false, .handler = cmdExit },
    .{ .name = "clear", .has_arg = false, .handler = cmdClear },
    .{ .name = "/compact", .has_arg = false, .handler = cmdCompact },
    .{ .name = "compact", .has_arg = false, .handler = cmdCompact },
    .{ .name = "/cost", .has_arg = false, .handler = cmdCost },
    .{ .name = "/model", .has_arg = true, .handler = cmdModel },
    .{ .name = "/diff", .has_arg = false, .handler = cmdDiff },
    .{ .name = "/commit", .has_arg = true, .handler = cmdCommit },
    .{ .name = "/review", .has_arg = false, .handler = cmdReview },
    .{ .name = "/undo", .has_arg = false, .handler = cmdUndo },
    .{ .name = "/plan", .has_arg = true, .handler = cmdPlan },
    .{ .name = "/spawn", .has_arg = true, .handler = cmdSpawn },
    .{ .name = "/queue", .has_arg = true, .handler = cmdQueue },
    .{ .name = "/agents", .has_arg = false, .handler = cmdAgents },
    .{ .name = "/tasks", .has_arg = false, .handler = cmdAgents },
    .{ .name = "/sessions", .has_arg = false, .handler = cmdSessions },
    .{ .name = "/config", .has_arg = false, .handler = cmdConfig },
    .{ .name = "/search", .has_arg = true, .handler = cmdSearch },
    .{ .name = "/s", .has_arg = true, .handler = cmdSearch },
    .{ .name = "/help", .has_arg = false, .handler = cmdHelp },
    .{ .name = "help", .has_arg = false, .handler = cmdHelp },
};

/// Look up and dispatch a slash command (or special prefix command).
/// Returns the dispatch result for the caller to act on.
pub fn dispatch(ctx: *CommandCtx, query: []const u8) DispatchResult {
    // Special prefix commands
    if (query.len > 0 and query[0] == '!') return cmdShellEscape(ctx, query);
    if (query.len > 1 and query[0] == '?') return cmdTranslate(ctx, query);

    // Table lookup
    for (&commands) |*cmd| {
        if (cmd.has_arg) {
            // Match exact or with trailing space + argument
            if (std.mem.eql(u8, query, cmd.name)) {
                return cmd.handler(ctx, "");
            }
            if (query.len > cmd.name.len and
                std.mem.startsWith(u8, query, cmd.name) and
                query[cmd.name.len] == ' ')
            {
                const arg = std.mem.trim(u8, query[cmd.name.len + 1 ..], " ");
                return cmd.handler(ctx, arg);
            }
        } else {
            if (std.mem.eql(u8, query, cmd.name)) {
                return cmd.handler(ctx, "");
            }
        }
    }

    return .not_found;
}

// ── Handler implementations ──

fn cmdExit(ctx: *CommandCtx, _: []const u8) DispatchResult {
    if (ctx.agent_active.*) ctx.shell.agent.cancel();
    Layout.doExit(ctx.out, ctx.term_rows.*, ctx.input_height.*);
    return .exit;
}

fn cmdClear(ctx: *CommandCtx, _: []const u8) DispatchResult {
    ctx.shell.agent.stop();
    ctx.shell.agent.start() catch {};
    ctx.md.reset();
    ctx.last_was_text.* = false;
    ctx.agent_active.* = false;
    ctx.query_start_ms.* = 0;
    ctx.status_len.* = 0;
    ctx.scroll_offset.* = 0;
    Layout.goOutput(ctx.out, ctx.out_last.*);
    ctx.out.writeAll("\x1b[90mconversation cleared\x1b[0m\n") catch {};
    ctx.msg_history.* = .{};
    ctx.historyNote("\x1b[90mconversation cleared\x1b[0m");
    Layout.drawStatusBarSafe(ctx.out, ctx.status_row.*, ctx.term_rows.*, ctx.out_last.*, ctx.term_cols.*, ctx.model_name, ctx.cost_buf[0..ctx.cost_len.*], "");
    ctx.out.flush() catch {};
    return .handled;
}

fn cmdCompact(ctx: *CommandCtx, _: []const u8) DispatchResult {
    if (ctx.shell.agent.query("Please provide a brief summary of our conversation so far in 2-3 sentences, focusing on what was accomplished and any important context. Start with 'Summary:' and be concise.")) {
        Layout.goOutput(ctx.out, ctx.out_last.*);
        ctx.out.writeAll("\x1b[90mCompacting...\x1b[0m\n") catch {};
        ctx.historyNote("\x1b[90mCompacting...\x1b[0m");
        ctx.agent_active.* = true;
    }
    ctx.out.flush() catch {};
    return .handled;
}

fn cmdCost(ctx: *CommandCtx, _: []const u8) DispatchResult {
    Layout.goOutput(ctx.out, ctx.out_last.*);
    ctx.out.print("\x1b[1mSession Cost:\x1b[0m {s}\n", .{if (ctx.cost_len.* > 0) ctx.cost_buf[0..ctx.cost_len.*] else "n/a"}) catch {};
    ctx.out.print("\x1b[1mModel:\x1b[0m        {s}\n", .{ctx.model_name}) catch {};
    ctx.historyNote("Session cost displayed");
    ctx.out.flush() catch {};
    return .handled;
}

fn cmdModel(ctx: *CommandCtx, arg: []const u8) DispatchResult {
    Layout.goOutput(ctx.out, ctx.out_last.*);
    if (arg.len > 0) {
        ctx.shell.agent.setModel(arg);
        const src = ctx.shell.agent.getModelOverride() orelse arg;
        const clen = @min(src.len, ctx.model_buf.len);
        @memcpy(ctx.model_buf[0..clen], src[0..clen]);
        ctx.model_name = ctx.model_buf[0..clen];
        ctx.out.print("\x1b[90mModel switched to \x1b[33m{s}\x1b[0m\n", .{ctx.model_name}) catch {};
        ctx.historyNote("Model switched");
        ctx.drawStatusElapsed();
    } else {
        ctx.out.print("\x1b[1mCurrent model:\x1b[0m {s}\n", .{ctx.model_name}) catch {};
        ctx.out.writeAll("\x1b[90mUsage: /model <opus|sonnet|haiku|model-id>\x1b[0m\n") catch {};
        ctx.historyNote("Model info displayed");
    }
    ctx.out.flush() catch {};
    return .handled;
}

fn cmdDiff(ctx: *CommandCtx, _: []const u8) DispatchResult {
    Layout.goOutput(ctx.out, ctx.out_last.*);
    if (ctx.shell.agent.query("Run `git diff --stat && git diff` to show current changes. Show the output directly, don't summarize.")) {
        ctx.agent_active.* = true;
        ctx.setStatus("running diff...");
    }
    ctx.out.flush() catch {};
    return .handled;
}

fn cmdCommit(ctx: *CommandCtx, arg: []const u8) DispatchResult {
    Layout.goOutput(ctx.out, ctx.out_last.*);
    if (arg.len > 0) {
        // Escape single quotes in commit message
        var esc_buf: [2048]u8 = undefined;
        var esc_len: usize = 0;
        for (arg) |ch| {
            if (ch == '\'') {
                if (esc_len + 4 > esc_buf.len) break;
                @memcpy(esc_buf[esc_len..][0..4], "'\\''");
                esc_len += 4;
            } else {
                if (esc_len >= esc_buf.len) break;
                esc_buf[esc_len] = ch;
                esc_len += 1;
            }
        }
        const escaped = esc_buf[0..esc_len];
        var commit_prompt_buf: [4096]u8 = undefined;
        const commit_prompt = std.fmt.bufPrint(&commit_prompt_buf, "Run `git add -A && git commit -m '{s}'`. Show the result.", .{escaped}) catch "Run git commit";
        if (ctx.shell.agent.query(commit_prompt)) {
            ctx.agent_active.* = true;
        }
    } else {
        if (ctx.shell.agent.query("Look at `git diff --cached` and `git diff` and `git status`, then create a good commit. Stage relevant files with `git add` (not -A, be selective), write a concise commit message focused on the 'why', and run `git commit`. Show the result.")) {
            ctx.agent_active.* = true;
            ctx.setStatus("committing...");
        }
    }
    ctx.out.flush() catch {};
    return .handled;
}

fn cmdReview(ctx: *CommandCtx, _: []const u8) DispatchResult {
    Layout.goOutput(ctx.out, ctx.out_last.*);
    if (ctx.shell.agent.query("Review all changes made in this session. Run `git diff` and provide a concise code review: what changed, potential issues, and suggestions.")) {
        ctx.agent_active.* = true;
        ctx.setStatus("reviewing...");
    }
    ctx.out.flush() catch {};
    return .handled;
}

fn cmdUndo(ctx: *CommandCtx, _: []const u8) DispatchResult {
    Layout.goOutput(ctx.out, ctx.out_last.*);
    if (ctx.shell.agent.query("Undo the last file change. Run `git diff --name-only` to see what changed, then `git checkout -- <file>` for the most recently modified file. If there are staged changes, use `git checkout HEAD -- <file>`. Show what was undone.")) {
        ctx.agent_active.* = true;
        ctx.setStatus("undoing...");
    }
    ctx.out.flush() catch {};
    return .handled;
}

fn cmdPlan(ctx: *CommandCtx, arg: []const u8) DispatchResult {
    Layout.goOutput(ctx.out, ctx.out_last.*);
    if (arg.len > 0) {
        var plan_buf: [4096]u8 = undefined;
        const plan_prompt = std.fmt.bufPrint(&plan_buf, "PLANNING MODE — do NOT execute any tools. Only use Read/Glob/Grep to understand the codebase, then provide a detailed implementation plan with:\n1. Files to modify\n2. Changes needed in each file\n3. Order of operations\n4. Potential risks\n\nTask: {s}", .{arg}) catch arg;
        if (ctx.shell.agent.query(plan_prompt)) {
            ctx.agent_active.* = true;
            ctx.setStatus("planning...");
        }
    } else {
        ctx.out.writeAll("\x1b[90mUsage: /plan <description of what you want to implement>\x1b[0m\n") catch {};
        ctx.historyNote("Plan usage displayed");
    }
    ctx.out.flush() catch {};
    return .handled;
}

fn cmdSpawn(ctx: *CommandCtx, arg: []const u8) DispatchResult {
    const agent_queue = @import("agent_queue.zig");
    _ = agent_queue;
    Layout.goOutput(ctx.out, ctx.out_last.*);
    if (arg.len > 0) {
        _ = ctx.shell.agent.queues.request.push(.spawn_worker, arg);
        ctx.out.print("\x1b[90mSpawning worker: {s}\x1b[0m\n", .{arg[0..@min(arg.len, 60)]}) catch {};
    } else {
        ctx.out.writeAll("\x1b[90mUsage: /spawn <task description>\x1b[0m\n") catch {};
    }
    ctx.historyNote("Worker spawned");
    ctx.out.flush() catch {};
    return .handled;
}

fn cmdQueue(ctx: *CommandCtx, arg: []const u8) DispatchResult {
    Layout.goOutput(ctx.out, ctx.out_last.*);
    if (arg.len > 0) {
        _ = ctx.shell.agent.queues.request.push(.add_task, arg);
        ctx.out.print("\x1b[90mQueued: {s}\x1b[0m\n", .{arg}) catch {};
    } else {
        ctx.out.writeAll("\x1b[90mUsage: /queue <task description>\x1b[0m\n") catch {};
    }
    ctx.historyNote("Task queued");
    ctx.out.flush() catch {};
    return .handled;
}

fn cmdAgents(ctx: *CommandCtx, _: []const u8) DispatchResult {
    Layout.goOutput(ctx.out, ctx.out_last.*);
    if (ctx.shell.agent.isBusy()) {
        ctx.out.writeAll("\x1b[33mAgent busy\x1b[0m\n") catch {};
    } else {
        ctx.out.writeAll("\x1b[90mAgent idle\x1b[0m\n") catch {};
    }
    _ = ctx.shell.agent.queues.request.push(.agent_status_req, "");
    ctx.out.writeAll("\x1b[90mWorkers & tasks:\x1b[0m\n") catch {};
    ctx.historyNote("Agent status requested");
    ctx.out.flush() catch {};
    return .handled;
}

fn cmdSessions(ctx: *CommandCtx, _: []const u8) DispatchResult {
    Layout.goOutput(ctx.out, ctx.out_last.*);
    var sessions_list: std.ArrayList(agent_log.SessionInfo) = .{};
    defer sessions_list.deinit(ctx.shell.allocator);
    agent_log.listSessions(ctx.shell.allocator, &sessions_list) catch {};
    if (sessions_list.items.len == 0) {
        ctx.out.writeAll("\x1b[90mNo saved sessions.\x1b[0m\n") catch {};
    } else {
        const start = if (sessions_list.items.len > 10) sessions_list.items.len - 10 else 0;
        for (sessions_list.items[start..]) |*info| {
            const epoch_secs: u64 = if (info.created > 0) @intCast(info.created) else 0;
            const es = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
            const eday = es.getEpochDay();
            const eyd = eday.calculateYearDay();
            const emd = eyd.calculateMonthDay();
            const eds = es.getDaySeconds();
            ctx.out.print("  \x1b[33m{s}\x1b[0m  {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}  {s}\n", .{
                @as([]const u8, &info.id),
                eyd.year,
                @intFromEnum(emd.month),
                emd.day_index + 1,
                eds.getHoursIntoDay(),
                eds.getMinutesIntoHour(),
                info.cwd(),
            }) catch {};
        }
    }
    ctx.historyNote("Sessions listed");
    ctx.out.flush() catch {};
    return .handled;
}

fn cmdConfig(ctx: *CommandCtx, _: []const u8) DispatchResult {
    Layout.goOutput(ctx.out, ctx.out_last.*);
    ctx.out.print("\x1b[1mModel:\x1b[0m    {s}\n", .{ctx.model_name}) catch {};
    ctx.out.print("\x1b[1mCost:\x1b[0m     {s}\n", .{if (ctx.cost_len.* > 0) ctx.cost_buf[0..ctx.cost_len.*] else "n/a"}) catch {};
    {
        var conf = agent_log.AgentConfig.load(ctx.shell.allocator);
        defer conf.deinit();
        ctx.out.print("\x1b[1mProvider:\x1b[0m {s}\n", .{conf.provider}) catch {};
        if (conf.api_key.len > 8) {
            ctx.out.print("\x1b[1mAPI Key:\x1b[0m  {s}...{s}\n", .{ conf.api_key[0..4], conf.api_key[conf.api_key.len - 4 ..] }) catch {};
        }
    }
    ctx.historyNote("Config displayed");
    ctx.out.flush() catch {};
    return .handled;
}

fn cmdSearch(ctx: *CommandCtx, arg: []const u8) DispatchResult {
    if (arg.len > 0) {
        const search_start = if (ctx.msg_history.line_count > ctx.scroll_offset.*)
            ctx.msg_history.line_count - ctx.scroll_offset.*
        else
            ctx.msg_history.line_count;
        if (ctx.msg_history.searchBack(arg, search_start)) |found_line| {
            const lines_from_bottom = ctx.msg_history.line_count - found_line;
            ctx.scroll_offset.* = if (lines_from_bottom > ctx.out_last.* / 2)
                lines_from_bottom - ctx.out_last.* / 2
            else
                0;
            Layout.repaintFromHistory(ctx.out, ctx.msg_history, ctx.out_last.*, ctx.scroll_offset.*);
            Layout.drawSeparator(ctx.out, ctx.sep_row.*, ctx.term_cols.*, ctx.scroll_offset.*);
        } else {
            Layout.goOutput(ctx.out, ctx.out_last.*);
            ctx.out.print("\x1b[90mPattern not found: {s}\x1b[0m\n", .{arg}) catch {};
        }
    }
    ctx.out.flush() catch {};
    return .handled;
}

fn cmdHelp(ctx: *CommandCtx, _: []const u8) DispatchResult {
    Layout.goOutput(ctx.out, ctx.out_last.*);
    const help_text =
        \\\x1b[1mAgent Mode Commands:\x1b[0m
        \\  \x1b[33mexit\x1b[0m / \x1b[33mquit\x1b[0m / \x1b[33mCtrl+D\x1b[0m  — leave agent mode
        \\  \x1b[33mclear\x1b[0m                — reset conversation
        \\  \x1b[33m/compact\x1b[0m             — summarize conversation
        \\  \x1b[33m/cost\x1b[0m                — show session cost
        \\  \x1b[33m/model\x1b[0m [name]        — show/switch model
        \\  \x1b[33m/diff\x1b[0m                — show git changes
        \\  \x1b[33m/commit\x1b[0m [msg]        — commit (AI message if no msg)
        \\  \x1b[33m/review\x1b[0m              — review session changes
        \\  \x1b[33m/undo\x1b[0m                — undo last file change
        \\  \x1b[33m/plan\x1b[0m <task>          — plan without executing
        \\  \x1b[33m/spawn\x1b[0m <task>         — spawn worker (full tools)
        \\  \x1b[33m/queue\x1b[0m <task>         — queue autonomous task
        \\  \x1b[33m/agents\x1b[0m              — list workers & tasks
        \\  \x1b[33m/sessions\x1b[0m            — list recent sessions
        \\  \x1b[33m/config\x1b[0m              — show configuration
        \\  \x1b[33m/search\x1b[0m <pattern>    — search history (also /s)
        \\  \x1b[33m/help\x1b[0m                — show this help
        \\
        \\
        \\  \x1b[33m!command\x1b[0m             — run shell command (zish engine)
        \\  \x1b[33m!\x1b[0m                    — drop to full zish shell
        \\  \x1b[33m?intent\x1b[0m              — translate to shell command
        \\
        \\  \x1b[33mEnter\x1b[0m submits, \x1b[33mAlt+Enter\x1b[0m inserts newline.
        \\  \x1b[33mPageUp/Down\x1b[0m scrolls through history.
        \\  \x1b[33m^K/^N\x1b[0m jumps between messages.
        \\  \x1b[33mCtrl+C\x1b[0m cancels when busy, clears/exits when idle.
        \\  \x1b[33mEsc\x1b[0m enters vi normal mode (\x1b[33mi\x1b[0m to return to insert).
        \\  \x1b[33mRight/End\x1b[0m accepts ghost text, \x1b[33mCtrl+Right\x1b[0m one word.
        \\
    ;
    ctx.out.writeAll(help_text) catch {};
    var help_iter = std.mem.splitScalar(u8, help_text, '\n');
    while (help_iter.next()) |hl| {
        if (hl.len > 0) ctx.msg_history.appendSlice(hl);
        ctx.msg_history.commitLine();
    }
    ctx.out.flush() catch {};
    return .handled;
}

// ── Special prefix handlers ──

fn cmdShellEscape(ctx: *CommandCtx, query: []const u8) DispatchResult {
    ctx.out.print("\x1b[1;{d}r", .{ctx.term_rows.*}) catch {};
    Layout.doExit(ctx.out, ctx.term_rows.*, ctx.input_height.*);
    ctx.out.flush() catch {};

    const cmd = std.mem.trim(u8, query[1..], " ");
    if (cmd.len > 0) {
        // Single command — execute and return
        ctx.out.print("\x1b[90m$ {s}\x1b[0m\n", .{cmd}) catch {};
        ctx.msg_history.appendSlice("\x1b[90m$ ");
        ctx.msg_history.appendSlice(cmd);
        ctx.msg_history.appendSlice("\x1b[0m");
        ctx.msg_history.commitLine();
        ctx.out.flush() catch {};
        ctx.shell.disableRawMode();
        const exit_code = ctx.shell.executeCommand(cmd) catch 1;
        _ = exit_code;
        ctx.shell.enableRawMode() catch {};
    } else {
        // Bare "!" — drop to interactive shell
        ctx.out.writeAll("\x1b[90m-- shell (type 'agent' to return)\x1b[0m\n") catch {};
        ctx.msg_history.appendSlice("\x1b[90m-- shell escape\x1b[0m");
        ctx.msg_history.commitLine();
        ctx.out.flush() catch {};
        return .shell_escape;
    }

    // Rebuild agent TUI layout
    @atomicStore(bool, &ctx.shell.terminal_resized, false, .release);
    ctx.term_rows.* = getTermRows();
    ctx.term_cols.* = getTermCols();
    // Push content up to make room for TUI
    {
        var si: u16 = 0;
        while (si < ctx.term_rows.*) : (si += 1) ctx.out.writeByte('\n') catch {};
    }
    ctx.recalc();
    Layout.repaintFromHistory(ctx.out, ctx.msg_history, ctx.out_last.*, ctx.scroll_offset.*);
    ctx.out.flush() catch {};
    return .handled;
}

fn cmdTranslate(ctx: *CommandCtx, query: []const u8) DispatchResult {
    const intent = std.mem.trim(u8, query[1..], " ");
    if (intent.len > 0) {
        var prompt_buf: [2048]u8 = undefined;
        const prompt = std.fmt.bufPrint(&prompt_buf,
            \\Translate this intent to a shell command. Reply with ONLY the command on the first line, nothing else.
            \\No explanation, no markdown, just the raw command.
            \\
            \\Intent: {s}
        , .{intent}) catch intent;
        if (ctx.shell.agent.query(prompt)) {
            ctx.agent_active.* = true;
            ctx.setStatus("translating...");
            Layout.drawStatusBar(ctx.out, ctx.status_row.*, ctx.term_cols.*, ctx.model_name, ctx.cost_buf[0..ctx.cost_len.*], ctx.status_text[0..ctx.status_len.*]);
        }
    }
    ctx.out.flush() catch {};
    return .translate;
}

// ── Terminal size helpers (duplicated from builtins to avoid circular dep) ──

fn getTermRows() u16 {
    const TIOCGWINSZ = 0x5413;
    const Winsize = extern struct { ws_row: u16, ws_col: u16, ws_xpixel: u16, ws_ypixel: u16 };
    var ws: Winsize = undefined;
    if (std.posix.system.ioctl(std.posix.STDOUT_FILENO, TIOCGWINSZ, @intFromPtr(&ws)) == 0 and ws.ws_row > 0)
        return ws.ws_row;
    return 24;
}

fn getTermCols() u16 {
    const TIOCGWINSZ = 0x5413;
    const Winsize = extern struct { ws_row: u16, ws_col: u16, ws_xpixel: u16, ws_ypixel: u16 };
    var ws: Winsize = undefined;
    if (std.posix.system.ioctl(std.posix.STDOUT_FILENO, TIOCGWINSZ, @intFromPtr(&ws)) == 0 and ws.ws_col > 0)
        return ws.ws_col;
    return 80;
}
