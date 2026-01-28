// editor.zig - clean line editor architecture
// design: single source of truth, batched output, zero alloc hot path

const std = @import("std");
const keywords = @import("keywords.zig");

// ANSI color codes
pub const Color = struct {
    pub const reset: []const u8 = "\x1b[0m";
    pub const bold: []const u8 = "\x1b[1m";
    pub const dim: []const u8 = "\x1b[2m";
    pub const green: []const u8 = "\x1b[32m"; // strings
    pub const cyan: []const u8 = "\x1b[36m"; // variables
    pub const magenta: []const u8 = "\x1b[35m"; // keywords
    pub const blue: []const u8 = "\x1b[34m"; // builtins
    pub const gray: []const u8 = "\x1b[90m"; // comments
    pub const yellow: []const u8 = "\x1b[33m"; // escapes
};

pub const LINE_BUF_SIZE = 4096;
pub const RENDER_BUF_SIZE = 65536; // 64KB for large multiline content

/// pure text buffer - no rendering logic
pub const EditBuffer = struct {
    text: [LINE_BUF_SIZE]u8 = undefined,
    len: u16 = 0,
    cursor: u16 = 0,

    const Self = @This();

    pub fn insert(self: *Self, char: u8) bool {
        if (self.len >= LINE_BUF_SIZE - 1) return false;
        // shift right from cursor
        if (self.cursor < self.len) {
            std.mem.copyBackwards(
                u8,
                self.text[self.cursor + 1 .. self.len + 1],
                self.text[self.cursor .. self.len],
            );
        }
        self.text[self.cursor] = char;
        self.len += 1;
        self.cursor += 1;
        return true;
    }

    pub fn insertSlice(self: *Self, chars: []const u8) usize {
        var inserted: usize = 0;
        for (chars) |c| {
            if (!self.insert(c)) break;
            inserted += 1;
        }
        return inserted;
    }

    pub fn delete(self: *Self) bool {
        if (self.cursor == 0) return false;
        if (self.cursor < self.len) {
            std.mem.copyForwards(
                u8,
                self.text[self.cursor - 1 .. self.len - 1],
                self.text[self.cursor .. self.len],
            );
        }
        self.len -= 1;
        self.cursor -= 1;
        return true;
    }

    pub fn deleteForward(self: *Self) bool {
        if (self.cursor >= self.len) return false;
        if (self.cursor < self.len - 1) {
            std.mem.copyForwards(
                u8,
                self.text[self.cursor .. self.len - 1],
                self.text[self.cursor + 1 .. self.len],
            );
        }
        self.len -= 1;
        return true;
    }

    pub fn clear(self: *Self) void {
        self.len = 0;
        self.cursor = 0;
    }

    pub fn set(self: *Self, content: []const u8) void {
        const n: u16 = @intCast(@min(content.len, LINE_BUF_SIZE - 1));
        @memcpy(self.text[0..n], content[0..n]);
        self.len = n;
        self.cursor = n;
    }

    pub fn slice(self: *const Self) []const u8 {
        return self.text[0..self.len];
    }

    pub fn moveLeft(self: *Self) bool {
        if (self.cursor == 0) return false;
        self.cursor -= 1;
        return true;
    }

    pub fn moveRight(self: *Self) bool {
        if (self.cursor >= self.len) return false;
        self.cursor += 1;
        return true;
    }

    pub fn moveHome(self: *Self) void {
        self.cursor = 0;
    }

    pub fn moveEnd(self: *Self) void {
        self.cursor = self.len;
    }

    /// move to start of current line (after newline or pos 0)
    pub fn moveLineStart(self: *Self) void {
        while (self.cursor > 0 and self.text[self.cursor - 1] != '\n') {
            self.cursor -= 1;
        }
    }

    /// move to end of current line (before newline or end)
    pub fn moveLineEnd(self: *Self) void {
        while (self.cursor < self.len and self.text[self.cursor] != '\n') {
            self.cursor += 1;
        }
    }

    /// count newlines in buffer
    pub fn lineCount(self: *const Self) u16 {
        var count: u16 = 1;
        for (self.text[0..self.len]) |c| {
            if (c == '\n') count += 1;
        }
        return count;
    }
};

/// terminal output state
pub const TermState = struct {
    row: u16 = 0, // cursor row relative to prompt
    col: u16 = 0, // cursor column
    rows_owned: u16 = 1, // rows our content spans
    width: u16 = 0, // must be set via resize()
    height: u16 = 0, // must be set via resize()
};

/// zero-allocation syntax highlighter - state machine
pub const SyntaxHighlighter = struct {
    state: State = .normal,
    word_buf: [128]u8 = undefined,
    word_len: u8 = 0,
    at_line_start: bool = true,
    first_word: bool = true,

    const State = enum {
        normal,
        word,
        string_sq, // single quote
        string_dq, // double quote
        variable,
        comment,
        escape,
    };

    const Self = @This();

    pub fn feed(self: *Self, out: *TermView, c: u8) void {
        switch (self.state) {
            .normal => self.handleNormal(out, c),
            .word => self.handleWord(out, c),
            .string_sq => self.handleStringSq(out, c),
            .string_dq => self.handleStringDq(out, c),
            .variable => self.handleVariable(out, c),
            .comment => self.handleComment(out, c),
            .escape => self.handleEscape(out, c),
        }
    }

    fn handleNormal(self: *Self, out: *TermView, c: u8) void {
        switch (c) {
            'a'...'z', 'A'...'Z', '_', '-', '.', '/', '0'...'9' => {
                self.state = .word;
                self.word_buf[0] = c;
                self.word_len = 1;
            },
            '\'' => {
                self.state = .string_sq;
                _ = out.emit(Color.green);
                _ = out.emitByte(c);
            },
            '"' => {
                self.state = .string_dq;
                _ = out.emit(Color.green);
                _ = out.emitByte(c);
            },
            '$' => {
                self.state = .variable;
                _ = out.emit(Color.cyan);
                _ = out.emitByte(c);
            },
            '#' => {
                if (self.at_line_start or self.first_word) {
                    self.state = .comment;
                    _ = out.emit(Color.gray);
                }
                _ = out.emitByte(c);
            },
            '\\' => {
                self.state = .escape;
                _ = out.emit(Color.yellow);
                _ = out.emitByte(c);
            },
            ' ', '\t' => {
                _ = out.emitByte(c);
                // space after first word means next words aren't commands
                if (!self.at_line_start) self.first_word = false;
            },
            ';', '|', '&' => {
                _ = out.emitByte(c);
                self.first_word = true; // next word is a command
            },
            else => {
                _ = out.emitByte(c);
                self.at_line_start = false;
            },
        }
        if (c != ' ' and c != '\t') self.at_line_start = false;
    }

    fn handleWord(self: *Self, out: *TermView, c: u8) void {
        switch (c) {
            'a'...'z', 'A'...'Z', '_', '-', '.', '/', '0'...'9' => {
                if (self.word_len < 127) {
                    self.word_buf[self.word_len] = c;
                    self.word_len += 1;
                }
            },
            else => {
                self.flushWord(out);
                self.state = .normal;
                self.handleNormal(out, c);
            },
        }
    }

    fn handleStringSq(self: *Self, out: *TermView, c: u8) void {
        _ = out.emitByte(c);
        if (c == '\'') {
            _ = out.emit(Color.reset);
            self.state = .normal;
        }
    }

    fn handleStringDq(self: *Self, out: *TermView, c: u8) void {
        if (c == '$') {
            _ = out.emit(Color.cyan);
            _ = out.emitByte(c);
            // stay in string_dq but show variable color briefly
        } else {
            if (c != '"') _ = out.emit(Color.green); // restore string color
            _ = out.emitByte(c);
            if (c == '"') {
                _ = out.emit(Color.reset);
                self.state = .normal;
            }
        }
    }

    fn handleVariable(self: *Self, out: *TermView, c: u8) void {
        switch (c) {
            'a'...'z', 'A'...'Z', '_', '0'...'9', '{', '}', '?', '#', '@', '*' => {
                _ = out.emitByte(c);
            },
            else => {
                _ = out.emit(Color.reset);
                self.state = .normal;
                self.handleNormal(out, c);
            },
        }
    }

    fn handleComment(_: *Self, out: *TermView, c: u8) void {
        // comments go to end of line - newlines handled by caller
        _ = out.emitByte(c);
    }

    fn handleEscape(self: *Self, out: *TermView, c: u8) void {
        _ = out.emitByte(c);
        _ = out.emit(Color.reset);
        self.state = .normal;
    }

    pub fn flushWord(self: *Self, out: *TermView) void {
        if (self.word_len == 0) return;
        const word = self.word_buf[0..self.word_len];

        // determine color based on word type
        if (self.first_word) {
            if (keywords.isKeyword(word)) {
                _ = out.emit(Color.magenta);
            } else if (keywords.isBuiltin(word)) {
                _ = out.emit(Color.blue);
            }
        }

        _ = out.emit(word);
        _ = out.emit(Color.reset);
        self.word_len = 0;
        self.first_word = false;
    }
};

/// batched terminal output - single write() per render
pub const TermView = struct {
    out: [RENDER_BUF_SIZE]u8 = undefined,
    out_len: usize = 0,
    term: TermState = .{},
    last_hash: u64 = 0,
    last_cursor: u16 = 0,
    last_width: u16 = 0,
    fd: std.posix.fd_t,

    const Self = @This();

    pub fn init(fd: std.posix.fd_t) Self {
        var self = Self{ .fd = fd };
        self.updateSize();
        self.last_width = self.term.width;
        return self;
    }

    /// query terminal size via ioctl
    pub fn updateSize(self: *Self) void {
        var ws: std.posix.winsize = undefined;
        if (std.posix.system.ioctl(self.fd, std.posix.T.IOCGWINSZ, @intFromPtr(&ws)) == 0) {
            if (ws.col > 0) self.term.width = ws.col;
            if (ws.row > 0) self.term.height = ws.row;
        }
        // fallback if ioctl fails
        if (self.term.width == 0) self.term.width = 80;
        if (self.term.height == 0) self.term.height = 24;
    }

    /// check if buffer has space (with margin for escape sequences)
    pub fn hasSpace(self: *const Self, needed: usize) bool {
        return self.out_len + needed + 64 < RENDER_BUF_SIZE;
    }

    /// queue bytes (no syscall) - returns false if buffer full
    pub fn emit(self: *Self, bytes: []const u8) bool {
        if (!self.hasSpace(bytes.len)) return false;
        @memcpy(self.out[self.out_len..][0..bytes.len], bytes);
        self.out_len += bytes.len;
        return true;
    }

    pub fn emitByte(self: *Self, b: u8) bool {
        if (!self.hasSpace(1)) return false;
        self.out[self.out_len] = b;
        self.out_len += 1;
        return true;
    }

    /// emit CSI escape sequence
    pub fn emitCSI(self: *Self, comptime fmt: []const u8, args: anytype) bool {
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "\x1b[" ++ fmt, args) catch return false;
        return self.emit(s);
    }

    /// emit SGR (color/style)
    pub fn emitSGR(self: *Self, code: u8) bool {
        var buf: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "\x1b[{d}m", .{code}) catch return false;
        return self.emit(s);
    }

    /// flush to terminal
    pub fn flush(self: *Self) !void {
        if (self.out_len == 0) return;
        _ = try std.posix.write(self.fd, self.out[0..self.out_len]);
        self.out_len = 0;
    }

    /// move cursor relatively
    pub fn moveRel(self: *Self, dr: i16, dc: i16) void {
        if (dr < 0) _ = self.emitCSI("{d}A", .{@as(u16, @intCast(-dr))});
        if (dr > 0) _ = self.emitCSI("{d}B", .{@as(u16, @intCast(dr))});
        if (dc < 0) _ = self.emitCSI("{d}D", .{@as(u16, @intCast(-dc))});
        if (dc > 0) _ = self.emitCSI("{d}C", .{@as(u16, @intCast(dc))});
    }

    /// move to row/col relative to our region
    pub fn moveTo(self: *Self, row: u16, col: u16) void {
        const dr = @as(i16, @intCast(row)) - @as(i16, @intCast(self.term.row));
        if (dr != 0 or col != self.term.col) {
            // absolute column is more reliable
            if (dr < 0) _ = self.emitCSI("{d}A", .{@as(u16, @intCast(-dr))});
            if (dr > 0) _ = self.emitCSI("{d}B", .{@as(u16, @intCast(dr))});
            _ = self.emit("\r");
            if (col > 0) _ = self.emitCSI("{d}C", .{col});
        }
        self.term.row = row;
        self.term.col = col;
    }

    /// clear line from cursor
    pub fn clearToEOL(self: *Self) void {
        _ = self.emit("\x1b[K");
    }

    /// clear entire line
    pub fn clearLine(self: *Self) void {
        _ = self.emit("\x1b[2K");
    }

    /// main render - single entry point
    pub fn render(
        self: *Self,
        buf: *const EditBuffer,
        prompt: []const u8,
        prompt_visible_len: u16,
    ) !void {
        // dynamic size check
        self.updateSize();

        const text = buf.slice();
        const hash = std.hash.Wyhash.hash(0, text);

        // detect size change - force redraw when width changes
        const size_changed = self.term.width != self.last_width;
        if (size_changed) {
            self.last_width = self.term.width;
        }

        // skip if nothing changed
        if (!size_changed and hash == self.last_hash and buf.cursor == self.last_cursor) {
            return;
        }

        // compute cursor position in content
        var cursor_row: u16 = 0;
        var cursor_col: u16 = prompt_visible_len;
        const cont_marker_len: u16 = 2; // "│ "

        for (text[0..buf.cursor]) |c| {
            if (c == '\n') {
                cursor_row += 1;
                cursor_col = cont_marker_len;
            } else {
                cursor_col += 1;
                if (cursor_col >= self.term.width) {
                    cursor_row += 1;
                    cursor_col = 0;
                }
            }
        }

        // compute total rows
        var total_rows: u16 = 1;
        var col: u16 = prompt_visible_len;
        for (text) |c| {
            if (c == '\n') {
                total_rows += 1;
                col = cont_marker_len;
            } else {
                col += 1;
                if (col >= self.term.width) {
                    total_rows += 1;
                    col = 0;
                }
            }
        }

        // move to start of our region
        if (self.term.row > 0) {
            _ = self.emitCSI("{d}A", .{self.term.row});
        }
        _ = self.emit("\r");
        self.term.row = 0;
        self.term.col = 0;

        // clear old lines (limit to prevent runaway)
        const clear_rows = @min(self.term.rows_owned, self.term.height);
        for (0..clear_rows) |i| {
            self.clearLine();
            if (i < clear_rows - 1) {
                _ = self.emit("\x1b[1B"); // down
            }
        }

        // back to start
        if (clear_rows > 1) {
            _ = self.emitCSI("{d}A", .{clear_rows - 1});
        }
        _ = self.emit("\r");

        // emit prompt
        _ = self.emit(prompt);

        // emit content with syntax highlighting and continuation markers
        var hl = SyntaxHighlighter{};
        for (text) |c| {
            // flush buffer if getting full (leave room for escape sequences)
            if (self.out_len > RENDER_BUF_SIZE - 256) {
                try self.flush();
            }
            if (c == '\n') {
                hl.flushWord(self);
                _ = self.emit(Color.reset);
                _ = self.emitByte('\n');
                _ = self.emit(Color.gray);
                _ = self.emit("│");
                _ = self.emit(Color.reset);
                _ = self.emitByte(' ');
                hl.at_line_start = true;
                hl.first_word = true; // new line = new command context
            } else {
                hl.feed(self, c);
            }
        }
        hl.flushWord(self);
        _ = self.emit(Color.reset);

        // compute where we ended up
        var end_row: u16 = 0;
        col = prompt_visible_len;
        for (text) |c| {
            if (c == '\n') {
                end_row += 1;
                col = cont_marker_len;
            } else {
                col += 1;
                if (col >= self.term.width) {
                    end_row += 1;
                    col = 0;
                }
            }
        }
        self.term.row = end_row;
        self.term.col = col;

        // move to cursor position
        self.moveTo(cursor_row, cursor_col);

        // update state
        self.term.rows_owned = total_rows;
        self.last_hash = hash;
        self.last_cursor = buf.cursor;

        try self.flush();
    }

    /// call when done with line (enter, ctrl-c)
    pub fn finishLine(self: *Self) void {
        self.term.row = 0;
        self.term.col = 0;
        self.term.rows_owned = 1;
        // use sentinel that won't match any real hash to force next render
        self.last_hash = 0xDEADBEEF;
        self.last_cursor = 0xFFFF;
    }

    /// call on terminal resize
    pub fn resize(self: *Self, width: u16, height: u16) void {
        self.term.width = width;
        self.term.height = height;
        // force redraw
        self.last_hash = 0xDEADBEEF;
    }
};

// tests
test "EditBuffer insert and delete" {
    var buf = EditBuffer{};

    _ = buf.insert('a');
    _ = buf.insert('b');
    _ = buf.insert('c');
    try std.testing.expectEqualStrings("abc", buf.slice());
    try std.testing.expectEqual(@as(u16, 3), buf.cursor);

    _ = buf.delete();
    try std.testing.expectEqualStrings("ab", buf.slice());

    buf.cursor = 1;
    _ = buf.insert('x');
    try std.testing.expectEqualStrings("axb", buf.slice());
}

test "EditBuffer multiline" {
    var buf = EditBuffer{};
    buf.set("line1\nline2\nline3");
    try std.testing.expectEqual(@as(u16, 3), buf.lineCount());
}
