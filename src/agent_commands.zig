// agent_commands.zig — table-driven slash command dispatcher for agent interactive mode
const std = @import("std");
const Shell = @import("Shell.zig");
const editor = @import("editor.zig");
const agent_log = @import("agent_log.zig");
const agent_mod = @import("agent.zig");
const router_mod = @import("agent_router.zig");
const audio = @import("audio.zig");

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
    /// Enter tree view modal (vim-navigable agent tree).
    enter_tree,
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
        w.print("\x1b[{d};1H\x1b[2K\x1b[2;90m", .{row}) catch {}; // dim + dark gray
        _ = cols;
        if (scroll_off > 0) {
            var indicator_buf: [64]u8 = undefined;
            const indicator = std.fmt.bufPrint(&indicator_buf, "\xe2\x94\x80\xe2\x94\x80 \xe2\x86\x91 {d} lines \xe2\x94\x80\xe2\x94\x80", .{scroll_off}) catch "";
            w.writeAll(indicator) catch {};
        } else {
            w.writeAll("\xe2\x94\x80\xe2\x94\x80") catch {}; // just a short dash, not full width
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
                        w.writeAll("\x1b[33m> \x1b[0m") catch {};
                    } else {
                        w.writeAll("\x1b[90m> \x1b[0m") catch {};
                    }
                } else {
                    w.writeAll("  ") catch {};
                }
                w.writeAll(line_text) catch {};
            }
        }
        const vis_line = cur_line - scroll_start;
        const byte_col = ebuf.currentCol();
        const line_start_byte = ebuf.cursor - byte_col;
        const cur_col = displayWidth(ebuf.text[line_start_byte..ebuf.cursor]);
        const prefix_width: u16 = 2;
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
        w.print("\x1b[{d};1H\x1b[2K\x1b[90m", .{row}) catch {};
        var display_cols: u16 = 0;
        // Model name
        const mdl_w = displayWidth(mdl);
        if (display_cols + mdl_w < cols) {
            w.writeAll(mdl) catch {};
            display_cols += mdl_w;
        } else {
            const trunc = truncateToCols(mdl, cols -| display_cols);
            w.writeAll(mdl[0..trunc]) catch {};
            display_cols = cols;
        }
        // Status (highlighted)
        if (status.len > 0 and display_cols + 4 < cols) {
            w.writeAll(" \xc2\xb7 ") catch {}; // · (middle dot separator)
            display_cols += 3;
            w.writeAll("\x1b[33m") catch {}; // yellow for active status
            const sw = displayWidth(status);
            if (display_cols + sw < cols) {
                w.writeAll(status) catch {};
                display_cols += sw;
            } else {
                const trunc = truncateToCols(status, cols -| display_cols);
                w.writeAll(status[0..trunc]) catch {};
                display_cols = cols;
            }
            w.writeAll("\x1b[90m") catch {}; // back to dim
        }
        // Cost
        if (cost.len > 0 and display_cols + 4 < cols) {
            w.writeAll(" \xc2\xb7 ") catch {};
            display_cols += 3;
            w.writeAll(cost) catch {};
            display_cols += displayWidth(cost);
        }
        // Elapsed time
        if (elapsed_ms > 0 and display_cols + 6 < cols) {
            const secs = @divTrunc(elapsed_ms, 1000);
            var elapsed_buf: [32]u8 = undefined;
            const elapsed = if (secs >= 60)
                std.fmt.bufPrint(&elapsed_buf, " {d}m{d:0>2}s", .{ @divTrunc(secs, 60), @mod(secs, 60) }) catch ""
            else
                std.fmt.bufPrint(&elapsed_buf, " {d}s", .{secs}) catch "";
            w.writeAll(" \xc2\xb7") catch {};
            display_cols += 2;
            w.writeAll(elapsed) catch {};
            display_cols += displayWidth(elapsed);
        }
        // Hints (only if room)
        if (display_cols + 16 <= cols) {
            w.writeAll(" \xc2\xb7 ^D:exit \xc2\xb7 /help") catch {};
            display_cols += 16;
        }
        // Clear rest of line
        w.writeAll("\x1b[K\x1b[0m") catch {};
    }

    pub fn drawInputSafe(w: anytype, first_row: u16, rows: u16, ebuf: *const editor.EditBuffer, streaming: bool) void {
        if (streaming) {
            w.writeAll("\x1b" ++ "7") catch {}; // DECSC
            drawInput(w, first_row, rows, ebuf);
            w.writeAll("\x1b" ++ "8") catch {}; // DECRC
        } else {
            drawInput(w, first_row, rows, ebuf);
        }
    }

    pub fn drawInputSafeFull(w: anytype, first_row: u16, rows: u16, ebuf: *const editor.EditBuffer, streaming: bool, scroll_last: u16, t_rows: u16) void {
        if (streaming and t_rows > 0) {
            w.writeAll("\x1b" ++ "7") catch {}; // DECSC
            w.print("\x1b[1;{d}r", .{t_rows}) catch {};
            drawInput(w, first_row, rows, ebuf);
            w.print("\x1b[1;{d}r", .{scroll_last}) catch {};
            w.writeAll("\x1b" ++ "8") catch {}; // DECRC
        } else {
            drawInput(w, first_row, rows, ebuf);
        }
    }

    pub fn drawStatusBarSafe(w: anytype, stat_row: u16, t_rows: u16, scroll_last: u16, cols: u16, mdl: []const u8, cost: []const u8, status: []const u8) void {
        drawStatusBarSafeElapsed(w, stat_row, t_rows, scroll_last, cols, mdl, cost, status, 0);
    }

    pub fn drawStatusBarSafeElapsed(w: anytype, stat_row: u16, t_rows: u16, scroll_last: u16, cols: u16, mdl: []const u8, cost: []const u8, status: []const u8, elapsed_ms: i64) void {
        // Use DEC save/restore (ESC 7 / ESC 8) which is more reliable across
        // scroll region changes than SCO save/restore (ESC[s / ESC[u)
        w.writeAll("\x1b" ++ "7") catch {}; // DEC save cursor (DECSC)
        w.print("\x1b[1;{d}r", .{t_rows}) catch {};
        drawStatusBarFull(w, stat_row, cols, mdl, cost, status, elapsed_ms);
        w.print("\x1b[1;{d}r", .{scroll_last}) catch {};
        w.writeAll("\x1b" ++ "8") catch {}; // DEC restore cursor (DECRC)
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
        repaintFromHistoryHL(w, hist, out_rows, scroll_off, null);
    }

    pub fn repaintFromHistoryHL(w: anytype, hist: *const MessageHistory, out_rows: u16, scroll_off: u32, highlight: ?u32) void {
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
            // Subtle background highlight for focused line
            const is_hl = if (highlight) |hl| line_idx == hl else false;
            if (is_hl) w.writeAll("\x1b[48;5;236m") catch {}; // dark gray bg
            if (hist.getLine(line_idx)) |line_data| {
                w.writeAll(line_data) catch {};
            }
            if (is_hl) w.writeAll("\x1b[K\x1b[49m") catch {}; // clear to EOL with bg, then reset bg
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
    // Router correction tracking
    last_query_buf: *[512]u8,
    last_query_len: *usize,
    last_routed_tier: *[16]u8,
    last_routed_tier_len: *usize,

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
    .{ .name = "/agents", .has_arg = false, .handler = cmdTree },
    .{ .name = "/tasks", .has_arg = false, .handler = cmdTree },
    .{ .name = "/tree", .has_arg = false, .handler = cmdTree },
    .{ .name = "/sessions", .has_arg = false, .handler = cmdSessions },
    .{ .name = "/config", .has_arg = false, .handler = cmdConfig },
    .{ .name = "/search", .has_arg = true, .handler = cmdSearch },
    .{ .name = "/s", .has_arg = true, .handler = cmdSearch },
    .{ .name = "/voice", .has_arg = false, .handler = cmdVoice },
    .{ .name = "/init", .has_arg = false, .handler = cmdInit },
    .{ .name = "/effort", .has_arg = true, .handler = cmdEffort },
    .{ .name = "/git", .has_arg = true, .handler = cmdGit },
    .{ .name = "/help", .has_arg = false, .handler = cmdHelp },
    .{ .name = "help", .has_arg = false, .handler = cmdHelp },
};

/// Look up and dispatch a slash command (or special prefix command).
/// Returns the dispatch result for the caller to act on.
pub fn dispatch(ctx: *CommandCtx, raw_query: []const u8) DispatchResult {
    // Defensive trim — login shell terminal settings can leave stray CR/whitespace
    const query = std.mem.trim(u8, raw_query, " \t\r\n\x00");

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
    ctx.out.print("  \x1b[90mcost\x1b[0m      {s}\n", .{if (ctx.cost_len.* > 0) ctx.cost_buf[0..ctx.cost_len.*] else "n/a"}) catch {};
    ctx.out.print("  \x1b[90mmodel\x1b[0m     {s}\n", .{ctx.model_name}) catch {};
    ctx.historyNote("Session cost displayed");
    ctx.out.flush() catch {};
    return .handled;
}

fn cmdModel(ctx: *CommandCtx, arg: []const u8) DispatchResult {
    Layout.goOutput(ctx.out, ctx.out_last.*);
    if (arg.len > 0) {
        // Log correction if router had classified differently
        if (ctx.last_query_len.* > 0 and ctx.last_routed_tier_len.* > 0) {
            const corrected = if (std.mem.eql(u8, arg, "large") or std.mem.eql(u8, arg, "opus"))
                "large"
            else if (std.mem.eql(u8, arg, "small") or std.mem.eql(u8, arg, "haiku"))
                "small"
            else if (std.mem.eql(u8, arg, "medium") or std.mem.eql(u8, arg, "sonnet"))
                "medium"
            else
                arg;
            const routed = ctx.last_routed_tier[0..ctx.last_routed_tier_len.*];
            if (!std.mem.eql(u8, routed, corrected)) {
                router_mod.logCorrection(
                    ctx.last_query_buf[0..ctx.last_query_len.*],
                    routed,
                    corrected,
                );
            }
        }

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
        ctx.out.writeAll("\x1b[90mUsage: /model <large|medium|small|model-id>\x1b[0m\n") catch {};
        ctx.historyNote("Model info displayed");
    }
    ctx.out.flush() catch {};
    return .handled;
}

fn cmdDiff(ctx: *CommandCtx, _: []const u8) DispatchResult {
    Layout.goOutput(ctx.out, ctx.out_last.*);
    // Run git diff directly — no API call needed, saves tokens
    const result = std.process.Child.run(.{
        .allocator = ctx.shell.allocator,
        .argv = &[_][]const u8{ "git", "diff", "--stat", "--color=always" },
        .max_output_bytes = 64 * 1024,
    }) catch {
        ctx.out.writeAll("\x1b[90mnot a git repository\x1b[0m\n") catch {};
        ctx.out.flush() catch {};
        return .handled;
    };
    defer ctx.shell.allocator.free(result.stdout);
    defer ctx.shell.allocator.free(result.stderr);
    if (result.stdout.len > 0) {
        ctx.out.writeAll(result.stdout) catch {};
        ctx.historyNote("git diff --stat shown");
    } else {
        ctx.out.writeAll("\x1b[90mno changes\x1b[0m\n") catch {};
        ctx.historyNote("No changes");
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

fn cmdTree(_: *CommandCtx, _: []const u8) DispatchResult {
    return .enter_tree;
}

// ── Tree View ──────────────────────────────────────────────────────────

/// A parsed tree node from the agent's binary protocol.
pub const TreeNode = struct {
    depth: u8,
    status: u8, // 0=running, 1=done, 2=failed, 3=pending
    kind: u8, // 0=main, 1=subagent(ro), 2=worker(full), 3=task
    id: [16]u8 = undefined,
    id_len: u8 = 0,
    desc: [200]u8 = undefined,
    desc_len: u8 = 0,
    preview: [512]u8 = undefined,
    preview_len: u16 = 0,

    pub fn idSlice(self: *const TreeNode) []const u8 {
        return self.id[0..self.id_len];
    }
    pub fn descSlice(self: *const TreeNode) []const u8 {
        return self.desc[0..self.desc_len];
    }
    pub fn previewSlice(self: *const TreeNode) []const u8 {
        return self.preview[0..self.preview_len];
    }

    pub fn statusIcon(self: *const TreeNode) []const u8 {
        return switch (self.status) {
            0 => "\x1b[33m\xe2\x97\x8f\x1b[0m", // ● yellow (running)
            1 => "\x1b[32m\xe2\x9c\x93\x1b[0m", // ✓ green (done)
            2 => "\x1b[31m\xe2\x9c\x97\x1b[0m", // ✗ red (failed)
            3 => "\x1b[90m\xe2\x97\x8b\x1b[0m", // ○ dim (pending)
            else => "?",
        };
    }

    pub fn kindLabel(self: *const TreeNode) []const u8 {
        return switch (self.kind) {
            0 => "\x1b[1magent\x1b[0m",
            1 => "\x1b[36msubagent\x1b[0m",
            2 => "\x1b[35mworker\x1b[0m",
            3 => "\x1b[90mtask\x1b[0m",
            else => "?",
        };
    }

    /// Parse a binary tree node from the agent protocol.
    pub fn parse(data: []const u8) ?TreeNode {
        if (data.len < 5) return null;
        var node: TreeNode = .{
            .depth = data[0],
            .status = data[1],
            .kind = data[2],
            .id_len = 0,
            .desc_len = 0,
        };
        const id_len = data[3];
        if (4 + id_len >= data.len) return null;
        const il: u8 = @min(id_len, 16);
        @memcpy(node.id[0..il], data[4..][0..il]);
        node.id_len = il;
        const desc_off: usize = 4 + id_len;
        const dl = data[desc_off];
        const desc_start = desc_off + 1;
        if (desc_start + dl > data.len) return null;
        const dll: u8 = @min(dl, 200);
        @memcpy(node.desc[0..dll], data[desc_start..][0..dll]);
        node.desc_len = dll;
        // Preview is everything after desc
        const prev_start = desc_start + dl;
        if (prev_start < data.len) {
            const plen: u16 = @intCast(@min(data.len - prev_start, 512));
            @memcpy(node.preview[0..plen], data[prev_start..][0..plen]);
            node.preview_len = plen;
        }
        return node;
    }
};

/// Render the tree view. Called from the main input loop when in tree mode.
/// Returns when user presses q/Esc to exit tree view.
pub fn runTreeView(
    shell: *Shell,
    out: *std.Io.Writer,
    term_rows: u16,
    term_cols: u16,
) void {
    const q = @import("agent_queue.zig");

    // Request tree data from agent
    _ = shell.agent.queues.request.push(.agent_tree_req, "");

    // Collect nodes (poll for up to 500ms)
    var nodes: [64]TreeNode = undefined;
    var node_count: u8 = 0;
    var deadline: i64 = std.time.milliTimestamp() + 500;
    var got_end = false;

    while (std.time.milliTimestamp() < deadline and !got_end) {
        var msg: q.Msg = undefined;
        while (shell.agent.queues.output.pop(&msg)) {
            if (msg.kind == .agent_tree_node) {
                if (msg.len == 0) {
                    got_end = true;
                    break;
                }
                if (node_count < 64) {
                    if (TreeNode.parse(msg.slice())) |parsed| {
                        nodes[node_count] = parsed;
                        node_count += 1;
                    }
                }
            }
            // Discard other messages during tree collection
        }
        if (!got_end) std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    if (node_count == 0) {
        // No nodes — show empty state in scroll region
        out.writeAll("\x1b[90mNo agents or tasks.\x1b[0m\n") catch {};
        out.flush() catch {};
        return;
    }

    // Tree view state
    var cursor: u8 = 0;
    var scroll_top: u8 = 0;
    var viewing_result = false;
    var result_buf: [32768]u8 = undefined;
    var result_len: usize = 0;
    var result_scroll: u16 = 0;

    // Bulletin state — read recent posts from the commons
    var bulletin_cursor: usize = 0;
    var bulletin_posts: [16]q.Post = undefined;
    var bulletin_count: usize = 0;
    // Start from recent history (last 16 posts)
    const cur_pos = shell.agent.bulletin.position();
    if (cur_pos > 16) {
        bulletin_cursor = cur_pos - 16;
    }
    {
        const br = shell.agent.bulletin.read(bulletin_cursor, &bulletin_posts);
        bulletin_count = br.count;
        bulletin_cursor = br.new_cursor;
    }

    // Layout: header(1) | tree(dynamic) | separator(1) | bulletin(4) | footer(1)
    const header_rows: u16 = 1;
    const footer_rows: u16 = 1;
    const bulletin_rows: u16 = @min(4, term_rows / 4);
    const sep_rows: u16 = 1;
    const view_height = term_rows -| (header_rows + footer_rows + bulletin_rows + sep_rows);

    // Save scroll region, use full screen
    out.print("\x1b[1;{d}r", .{term_rows}) catch {};

    // Main tree view loop
    while (true) {
        // Clear and render
        out.writeAll("\x1b[?25l") catch {}; // hide cursor

        // Poll bulletin for new posts
        {
            const br = shell.agent.bulletin.read(bulletin_cursor, bulletin_posts[bulletin_count..]);
            if (br.count > 0) {
                // Shift old posts out if full
                if (bulletin_count + br.count > bulletin_posts.len) {
                    const shift = bulletin_count + br.count - bulletin_posts.len;
                    for (0..bulletin_posts.len - shift) |i| {
                        bulletin_posts[i] = bulletin_posts[i + shift];
                    }
                    bulletin_count = bulletin_posts.len - br.count;
                }
                bulletin_count += br.count;
            }
            bulletin_cursor = br.new_cursor;
        }

        if (viewing_result) {
            drawResultView(out, term_rows, term_cols, &nodes[cursor], result_buf[0..result_len], result_scroll, view_height);
        } else {
            drawTreeView(out, term_rows, term_cols, nodes[0..node_count], cursor, scroll_top, view_height);
            // Draw bulletin separator + feed
            const bsep_row = header_rows + 1 + view_height;
            drawBulletin(out, bsep_row, term_rows, term_cols, bulletin_posts[0..bulletin_count], bulletin_rows);
        }

        out.flush() catch {};

        // Read input
        var byte: [1]u8 = undefined;
        const nr = std.fs.File.stdin().read(&byte) catch break;
        if (nr == 0) break;

        if (viewing_result) {
            switch (byte[0]) {
                'q', 0x1B, 'h' => { // Esc, q, h = back to tree
                    viewing_result = false;
                    result_scroll = 0;
                },
                'j' => result_scroll +|= 1,
                'k' => {
                    result_scroll -|= 1;
                },
                'G' => {
                    // Jump to end
                    const lines = countLines(result_buf[0..result_len]);
                    result_scroll = if (lines > view_height) lines - view_height else 0;
                },
                'g' => {
                    result_scroll = 0;
                },
                'd' => { // Ctrl+D / half page down
                    result_scroll +|= view_height / 2;
                },
                'u' => { // Ctrl+U / half page up
                    const half = view_height / 2;
                    result_scroll -|= half;
                },
                else => {},
            }
        } else {
            switch (byte[0]) {
                'q', 0x1B => break, // quit tree view
                'j' => {
                    if (cursor + 1 < node_count) {
                        cursor += 1;
                        { const vh: u8 = @intCast(@min(view_height, 255)); if (cursor >= scroll_top +| vh) scroll_top = cursor -| vh +| 1; }
                    }
                },
                'k' => {
                    if (cursor > 0) {
                        cursor -= 1;
                        if (cursor < scroll_top) scroll_top = cursor;
                    }
                },
                'l', 0x0D => { // Enter or l = view result
                    if (nodes[cursor].status == 1 or nodes[cursor].status == 2) {
                        // Fetch result
                        result_len = 0;
                        _ = shell.agent.queues.request.push(.agent_result_req, nodes[cursor].idSlice());
                        // Collect result chunks
                        const rdl: i64 = std.time.milliTimestamp() + 1000;
                        var got_res_end = false;
                        while (std.time.milliTimestamp() < rdl and !got_res_end) {
                            var rmsg: q.Msg = undefined;
                            while (shell.agent.queues.output.pop(&rmsg)) {
                                if (rmsg.kind == .agent_result) {
                                    if (rmsg.len == 0) {
                                        got_res_end = true;
                                        break;
                                    }
                                    const chunk = rmsg.slice();
                                    const space = result_buf.len - result_len;
                                    const cn = @min(chunk.len, space);
                                    @memcpy(result_buf[result_len..][0..cn], chunk[0..cn]);
                                    result_len += cn;
                                }
                            }
                            if (!got_res_end) std.Thread.sleep(10 * std.time.ns_per_ms);
                        }
                        viewing_result = true;
                        result_scroll = 0;
                    } else if (nodes[cursor].preview_len > 0) {
                        // Use preview for running agents
                        const pv = nodes[cursor].previewSlice();
                        const cn = @min(pv.len, result_buf.len);
                        @memcpy(result_buf[0..cn], pv[0..cn]);
                        result_len = cn;
                        viewing_result = true;
                        result_scroll = 0;
                    }
                },
                'r' => { // Refresh tree
                    _ = shell.agent.queues.request.push(.agent_tree_req, "");
                    node_count = 0;
                    deadline = std.time.milliTimestamp() + 500;
                    got_end = false;
                    while (std.time.milliTimestamp() < deadline and !got_end) {
                        var rmsg: q.Msg = undefined;
                        while (shell.agent.queues.output.pop(&rmsg)) {
                            if (rmsg.kind == .agent_tree_node) {
                                if (rmsg.len == 0) {
                                    got_end = true;
                                    break;
                                }
                                if (node_count < 64) {
                                    if (TreeNode.parse(rmsg.slice())) |parsed| {
                                        nodes[node_count] = parsed;
                                        node_count += 1;
                                    }
                                }
                            }
                        }
                        if (!got_end) std.Thread.sleep(10 * std.time.ns_per_ms);
                    }
                    if (cursor >= node_count and node_count > 0) cursor = node_count - 1;
                },
                'G' => {
                    if (node_count > 0) {
                        cursor = node_count - 1;
                        { const vh: u8 = @intCast(@min(view_height, 255)); if (cursor >= scroll_top +| vh) scroll_top = cursor -| vh +| 1; }
                    }
                },
                'g' => {
                    cursor = 0;
                    scroll_top = 0;
                },
                else => {},
            }
        }
    }

    // Restore cursor and show
    out.writeAll("\x1b[?25h") catch {}; // show cursor
    out.flush() catch {};
}

fn drawTreeView(
    w: *std.Io.Writer,
    term_rows: u16,
    term_cols: u16,
    nodes: []const TreeNode,
    cursor: u8,
    scroll_top: u8,
    view_height: u16,
) void {
    // Header
    w.print("\x1b[1;1H\x1b[2K\x1b[1;7m Agent Tree \x1b[0m\x1b[90m  j/k:move  l/Enter:view  r:refresh  q:exit\x1b[0m", .{}) catch {};

    // Tree nodes
    const end = @min(@as(u16, scroll_top) + view_height, @as(u16, @intCast(nodes.len)));
    for (scroll_top..@intCast(end)) |idx| {
        const i: u8 = @intCast(idx);
        const row: u16 = @as(u16, @intCast(idx - scroll_top)) + 2;
        const node = &nodes[idx];

        w.print("\x1b[{d};1H\x1b[2K", .{row}) catch {};

        // Cursor indicator
        if (i == cursor) {
            w.writeAll("\x1b[7m") catch {}; // reverse video
        }

        // Tree connector lines
        const indent = @as(u16, node.depth) * 3;
        var pad: u16 = 0;
        while (pad < indent) : (pad += 1) {
            w.writeByte(' ') catch {};
        }

        // Tree branch characters
        if (node.depth > 0) {
            // Check if this is the last node at this depth
            var is_last = true;
            for (idx + 1..nodes.len) |j| {
                if (nodes[j].depth <= node.depth) {
                    if (nodes[j].depth == node.depth) is_last = false;
                    break;
                }
            }
            if (is_last) {
                w.writeAll("\xe2\x94\x94\xe2\x94\x80 ") catch {}; // └─
            } else {
                w.writeAll("\xe2\x94\x9c\xe2\x94\x80 ") catch {}; // ├─
            }
        }

        // Status icon + kind + id + description
        w.writeAll(node.statusIcon()) catch {};
        w.writeByte(' ') catch {};
        w.writeAll(node.kindLabel()) catch {};
        w.print(" \x1b[1m{s}\x1b[0m", .{node.idSlice()}) catch {};
        if (i == cursor) w.writeAll("\x1b[7m") catch {};
        w.writeByte(' ') catch {};

        // Truncate description to fit
        const used = indent + 3 + 20 + node.id_len; // approximate
        const avail = if (term_cols > used) term_cols - used else 10;
        const desc = node.descSlice();
        if (desc.len > avail) {
            w.writeAll(desc[0..avail -| 1]) catch {};
            w.writeAll("\xe2\x80\xa6") catch {}; // …
        } else {
            w.writeAll(desc) catch {};
        }

        if (i == cursor) {
            w.writeAll("\x1b[0m") catch {};
        }
    }

    // Clear remaining rows
    var r: u16 = @as(u16, @intCast(end - scroll_top)) + 2;
    while (r < term_rows) : (r += 1) {
        w.print("\x1b[{d};1H\x1b[2K", .{r}) catch {};
    }

    // Footer
    w.print("\x1b[{d};1H\x1b[2K\x1b[90m {d}/{d} nodes\x1b[0m", .{
        term_rows, @as(u16, cursor) + 1, @as(u16, @intCast(nodes.len)),
    }) catch {};
}

fn drawResultView(
    w: *std.Io.Writer,
    term_rows: u16,
    term_cols: u16,
    node: *const TreeNode,
    result: []const u8,
    scroll: u16,
    view_height: u16,
) void {
    _ = term_cols;
    // Header
    w.print("\x1b[1;1H\x1b[2K\x1b[1;7m {s} {s} \x1b[0m\x1b[90m  j/k:scroll  g/G:top/bottom  h/q:back\x1b[0m", .{
        node.kindLabel(), node.idSlice(),
    }) catch {};

    // Render result text line by line with scroll
    var line_start: usize = 0;
    var line_num: u16 = 0;
    var row: u16 = 2;

    for (result, 0..) |c, ci| {
        if (c == '\n' or ci == result.len - 1) {
            const end = if (c == '\n') ci else ci + 1;
            if (line_num >= scroll and row <= term_rows - 1) {
                w.print("\x1b[{d};1H\x1b[2K", .{row}) catch {};
                w.writeAll(result[line_start..end]) catch {};
                row += 1;
            }
            line_num += 1;
            line_start = ci + 1;
        }
    }

    // Clear remaining rows
    while (row < term_rows) : (row += 1) {
        w.print("\x1b[{d};1H\x1b[2K", .{row}) catch {};
    }

    // Footer
    w.print("\x1b[{d};1H\x1b[2K\x1b[90m line {d}  {s}\x1b[0m", .{
        term_rows, scroll + 1, node.descSlice(),
    }) catch {};
    _ = view_height;
}

fn countLines(text: []const u8) u16 {
    var count: u16 = 1;
    for (text) |c| {
        if (c == '\n') count +|= 1;
    }
    return count;
}

fn drawBulletin(
    w: *std.Io.Writer,
    start_row: u16,
    term_rows: u16,
    term_cols: u16,
    posts: []const @import("agent_queue.zig").Post,
    max_rows: u16,
) void {
    _ = term_cols;
    // Separator
    w.print("\x1b[{d};1H\x1b[2K\x1b[90m\xe2\x94\x80\xe2\x94\x80 bulletin ", .{start_row}) catch {};
    var pad: u16 = 12;
    while (pad < 40) : (pad += 1) w.writeAll("\xe2\x94\x80") catch {};
    w.writeAll("\x1b[0m") catch {};

    // Posts (most recent at bottom)
    const avail = @min(max_rows, term_rows -| start_row -| 1);
    const show_start = if (posts.len > avail) posts.len - avail else 0;
    var row: u16 = start_row + 1;
    for (posts[show_start..]) |*post| {
        if (row >= term_rows) break;
        w.print("\x1b[{d};1H\x1b[2K", .{row}) catch {};
        // Post kind icon
        const icon: []const u8 = switch (post.kind) {
            .discovery => "\x1b[32m\xe2\x97\x86\x1b[0m", // ◆ green
            .escalate => "\x1b[31m\xe2\x96\xb2\x1b[0m", // ▲ red
            .request_peer => "\x1b[33m\xe2\x97\x8b\x1b[0m", // ○ yellow
            .status_change => "\x1b[36m\xe2\x97\x8f\x1b[0m", // ● cyan
            .vote => "\x1b[34m\xe2\x9c\x93\x1b[0m", // ✓ blue
        };
        w.writeAll(icon) catch {};
        w.print(" \x1b[1m{s}\x1b[0m \x1b[90m", .{post.authorSlice()}) catch {};
        // Truncate message
        const msg = post.slice();
        const show_len = @min(msg.len, 80);
        w.writeAll(msg[0..show_len]) catch {};
        if (msg.len > 80) w.writeAll("\xe2\x80\xa6") catch {};
        w.writeAll("\x1b[0m") catch {};
        row += 1;
    }
    // Clear remaining
    while (row < term_rows) : (row += 1) {
        w.print("\x1b[{d};1H\x1b[2K", .{row}) catch {};
    }
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
        const now_secs: u64 = @intCast(std.time.timestamp());
        for (sessions_list.items[start..]) |*info| {
            const epoch_secs: u64 = if (info.created > 0) @intCast(info.created) else 0;
            // Relative time
            const age = if (now_secs > epoch_secs) now_secs - epoch_secs else 0;
            var time_buf: [16]u8 = undefined;
            const time_str = if (age < 60)
                std.fmt.bufPrint(&time_buf, "{d}s ago", .{age}) catch "just now"
            else if (age < 3600)
                std.fmt.bufPrint(&time_buf, "{d}m ago", .{age / 60}) catch "recently"
            else if (age < 86400)
                std.fmt.bufPrint(&time_buf, "{d}h ago", .{age / 3600}) catch "today"
            else
                std.fmt.bufPrint(&time_buf, "{d}d ago", .{age / 86400}) catch "old";
            // Shorten CWD: replace home with ~
            const cwd = info.cwd();
            const home = std.posix.getenv("HOME") orelse "";
            var cwd_buf: [128]u8 = undefined;
            const display_cwd = if (home.len > 0 and std.mem.startsWith(u8, cwd, home)) blk: {
                const rest = cwd[home.len..];
                cwd_buf[0] = '~';
                const rlen = @min(rest.len, cwd_buf.len - 1);
                @memcpy(cwd_buf[1..][0..rlen], rest[0..rlen]);
                break :blk cwd_buf[0 .. rlen + 1];
            } else cwd;
            ctx.out.print("  \x1b[33m{s}\x1b[0m  \x1b[90m{s: <8}\x1b[0m  {s}\n", .{
                @as([]const u8, &info.id),
                time_str,
                display_cwd,
            }) catch {};
        }
    }
    ctx.historyNote("Sessions listed");
    ctx.out.flush() catch {};
    return .handled;
}

fn cmdConfig(ctx: *CommandCtx, _: []const u8) DispatchResult {
    Layout.goOutput(ctx.out, ctx.out_last.*);
    ctx.out.print("  \x1b[90mmodel\x1b[0m     {s}\n", .{ctx.model_name}) catch {};
    ctx.out.print("  \x1b[90mcost\x1b[0m      {s}\n", .{if (ctx.cost_len.* > 0) ctx.cost_buf[0..ctx.cost_len.*] else "n/a"}) catch {};
    {
        var conf = agent_log.AgentConfig.load(ctx.shell.allocator);
        defer conf.deinit();
        ctx.out.print("  \x1b[90mprovider\x1b[0m  {s}\n", .{conf.provider}) catch {};
        if (conf.api_key.len > 8) {
            ctx.out.print("  \x1b[90mapi key\x1b[0m   {s}...{s}\n", .{ conf.api_key[0..4], conf.api_key[conf.api_key.len - 4 ..] }) catch {};
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

fn cmdVoice(ctx: *CommandCtx, _: []const u8) DispatchResult {
    const shell = ctx.shell;
    Layout.goOutput(ctx.out, ctx.out_last.*);

    if (shell.voice_active) {
        // Stop voice mode
        if (shell.voice_capture) |*cap| cap.stop();
        if (shell.voice_playback) |*play| play.stop();
        shell.voice_capture = null;
        shell.voice_playback = null;
        shell.voice_active = false;
        ctx.out.writeAll("\x1b[33mvoice off\x1b[0m\n") catch {};
        ctx.setStatus("voice off");
    } else {
        // Start voice mode
        shell.voice_capture = audio.Capture.start(shell.allocator) catch |e| {
            ctx.out.print("\x1b[31mmic failed: {}\x1b[0m\n", .{e}) catch {};
            ctx.out.flush() catch {};
            return .handled;
        };
        shell.voice_playback = audio.Playback.start(shell.allocator, 24000) catch |e| {
            if (shell.voice_capture) |*cap| cap.stop();
            shell.voice_capture = null;
            ctx.out.print("\x1b[31mspeaker failed: {}\x1b[0m\n", .{e}) catch {};
            ctx.out.flush() catch {};
            return .handled;
        };
        shell.voice_active = true;
        ctx.out.writeAll("\x1b[32mvoice on\x1b[0m — listening\n") catch {};
        ctx.setStatus("voice on");
    }
    ctx.drawStatusElapsed();
    ctx.out.flush() catch {};
    return .handled;
}

fn cmdEffort(ctx: *CommandCtx, arg: []const u8) DispatchResult {
    Layout.goOutput(ctx.out, ctx.out_last.*);
    if (arg.len > 0) {
        const level = std.mem.trim(u8, arg, " ");
        if (std.mem.eql(u8, level, "low") or std.mem.eql(u8, level, "min")) {
            ctx.shell.agent.setMaxTokens(2048);
            ctx.out.writeAll("\x1b[90meffort: low (2K tokens)\x1b[0m\n") catch {};
        } else if (std.mem.eql(u8, level, "high") or std.mem.eql(u8, level, "max")) {
            ctx.shell.agent.setMaxTokens(16384);
            ctx.out.writeAll("\x1b[90meffort: high (16K tokens)\x1b[0m\n") catch {};
        } else {
            // Default / medium
            ctx.shell.agent.setMaxTokens(8192);
            ctx.out.writeAll("\x1b[90meffort: medium (8K tokens)\x1b[0m\n") catch {};
        }
    } else {
        ctx.out.writeAll("\x1b[90mUsage: /effort <low|medium|high>\x1b[0m\n") catch {};
    }
    ctx.out.flush() catch {};
    return .handled;
}

fn cmdGit(ctx: *CommandCtx, arg: []const u8) DispatchResult {
    Layout.goOutput(ctx.out, ctx.out_last.*);
    const sub = if (arg.len > 0) std.mem.trim(u8, arg, " ") else "s";

    // Map shortcuts to git commands
    const cmd = if (std.mem.eql(u8, sub, "s") or std.mem.eql(u8, sub, "status"))
        &[_][]const u8{ "git", "status", "--short", "--branch" }
    else if (std.mem.eql(u8, sub, "d") or std.mem.eql(u8, sub, "diff"))
        &[_][]const u8{ "git", "diff", "--stat", "--color=always" }
    else if (std.mem.eql(u8, sub, "dd"))
        &[_][]const u8{ "git", "diff", "--color=always" }
    else if (std.mem.eql(u8, sub, "l") or std.mem.eql(u8, sub, "log"))
        &[_][]const u8{ "git", "log", "--oneline", "--graph", "--color=always", "-15" }
    else if (std.mem.eql(u8, sub, "b") or std.mem.eql(u8, sub, "branch"))
        &[_][]const u8{ "git", "branch", "--color=always", "-a" }
    else if (std.mem.eql(u8, sub, "a") or std.mem.eql(u8, sub, "add"))
        &[_][]const u8{ "git", "add", "-A" }
    else if (std.mem.eql(u8, sub, "p") or std.mem.eql(u8, sub, "push"))
        &[_][]const u8{ "git", "push" }
    else if (std.mem.eql(u8, sub, "pl") or std.mem.eql(u8, sub, "pull"))
        &[_][]const u8{ "git", "pull" }
    else {
        ctx.out.writeAll("\x1b[90m/git shortcuts: s(tatus) d(iff) dd(full) l(og) b(ranch) a(dd) p(ush) pl(ull)\x1b[0m\n") catch {};
        ctx.out.flush() catch {};
        return .handled;
    };

    const result = std.process.Child.run(.{
        .allocator = ctx.shell.allocator,
        .argv = cmd,
        .max_output_bytes = 64 * 1024,
    }) catch {
        ctx.out.writeAll("\x1b[90mnot a git repo\x1b[0m\n") catch {};
        ctx.out.flush() catch {};
        return .handled;
    };
    defer ctx.shell.allocator.free(result.stdout);
    defer ctx.shell.allocator.free(result.stderr);
    if (result.stdout.len > 0) {
        ctx.out.writeAll(result.stdout) catch {};
    } else if (result.stderr.len > 0) {
        ctx.out.writeAll(result.stderr) catch {};
    } else {
        ctx.out.writeAll("\x1b[32m\xe2\x9c\x93\x1b[0m\n") catch {}; // ✓
    }
    ctx.historyNote("git command");
    ctx.out.flush() catch {};
    return .handled;
}

fn cmdInit(ctx: *CommandCtx, _: []const u8) DispatchResult {
    Layout.goOutput(ctx.out, ctx.out_last.*);
    if (ctx.shell.agent.query(
        "Analyze this project and create a CLAUDE.md file in the current directory. " ++
        "Use Glob, Read, and Grep to understand the project structure, build system, " ++
        "key files, and conventions. Write a concise CLAUDE.md with: " ++
        "1) Build/run/test commands " ++
        "2) Project structure overview " ++
        "3) Key architecture decisions " ++
        "4) Code style conventions. " ++
        "Keep it under 100 lines. If CLAUDE.md already exists, update it."
    )) {
        ctx.agent_active.* = true;
        ctx.setStatus("initializing...");
    }
    ctx.out.flush() catch {};
    return .handled;
}

fn cmdHelp(ctx: *CommandCtx, _: []const u8) DispatchResult {
    Layout.goOutput(ctx.out, ctx.out_last.*);
    const help_text =
        \\\x1b[1mCommands\x1b[0m
        \\  \x1b[33m/compact\x1b[0m\x1b[90m ·········· summarize conversation\x1b[0m
        \\  \x1b[33m/cost\x1b[0m\x1b[90m ············· show session cost\x1b[0m
        \\  \x1b[33m/model\x1b[0m [name]\x1b[90m ····· show/switch model\x1b[0m
        \\  \x1b[33m/diff\x1b[0m\x1b[90m ············· show git changes\x1b[0m
        \\  \x1b[33m/commit\x1b[0m [msg]\x1b[90m ····· commit with AI message\x1b[0m
        \\  \x1b[33m/review\x1b[0m\x1b[90m ··········· review session changes\x1b[0m
        \\  \x1b[33m/undo\x1b[0m\x1b[90m ············· undo last file change\x1b[0m
        \\  \x1b[33m/plan\x1b[0m <task>\x1b[90m ······ plan without executing\x1b[0m
        \\  \x1b[33m/spawn\x1b[0m <task>\x1b[90m ····· spawn worker subagent\x1b[0m
        \\  \x1b[33m/queue\x1b[0m <task>\x1b[90m ····· queue autonomous task\x1b[0m
        \\  \x1b[33m/tree\x1b[0m\x1b[90m ············· agent tree view\x1b[0m
        \\  \x1b[33m/sessions\x1b[0m\x1b[90m ········· list recent sessions\x1b[0m
        \\  \x1b[33m/config\x1b[0m\x1b[90m ··········· show configuration\x1b[0m
        \\  \x1b[33m/search\x1b[0m <pattern>\x1b[90m · search history\x1b[0m
        \\  \x1b[33m/voice\x1b[0m\x1b[90m ············ toggle voice mode\x1b[0m
        \\  \x1b[33m/init\x1b[0m\x1b[90m ············· generate CLAUDE.md\x1b[0m
        \\  \x1b[33m/effort\x1b[0m <level>\x1b[90m ··· low/medium/high\x1b[0m
        \\  \x1b[33m/git\x1b[0m <cmd>\x1b[90m ········ s d dd l b a p pl\x1b[0m
        \\
        \\\x1b[1mShortcuts\x1b[0m
        \\  \x1b[33m!command\x1b[0m\x1b[90m ·········· run shell command\x1b[0m
        \\  \x1b[33m!\x1b[0m\x1b[90m ················· drop to zish shell\x1b[0m
        \\  \x1b[33m?intent\x1b[0m\x1b[90m ··········· translate to command\x1b[0m
        \\
        \\\x1b[1mKeys\x1b[0m
        \\  \x1b[33mEnter\x1b[0m\x1b[90m submit\x1b[0m  \x1b[33mAlt+Enter\x1b[0m\x1b[90m newline\x1b[0m  \x1b[33mCtrl+C\x1b[0m\x1b[90m cancel\x1b[0m
        \\  \x1b[33m^U/^F\x1b[0m\x1b[90m scroll up/down\x1b[0m  \x1b[33m^K/^N\x1b[0m\x1b[90m jump messages\x1b[0m
        \\  \x1b[33mEsc\x1b[0m\x1b[90m vi mode\x1b[0m  \x1b[33mCtrl+D\x1b[0m\x1b[90m exit\x1b[0m  \x1b[33mRight\x1b[0m\x1b[90m accept ghost\x1b[0m
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
            Layout.drawStatusBarSafe(ctx.out, ctx.status_row.*, ctx.term_rows.*, ctx.out_last.*, ctx.term_cols.*, ctx.model_name, ctx.cost_buf[0..ctx.cost_len.*], ctx.status_text[0..ctx.status_len.*]);
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
