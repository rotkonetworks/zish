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

pub const ViMode = enum { insert, normal };

/// pure text buffer - no rendering logic
pub const EditBuffer = struct {
    text: [LINE_BUF_SIZE]u8 = undefined,
    len: u16 = 0,
    cursor: u16 = 0,
    vi_mode: ViMode = .insert,

    // Undo: single-level snapshot (saved before destructive operations)
    undo_text: [LINE_BUF_SIZE]u8 = undefined,
    undo_len: u16 = 0,
    undo_cursor: u16 = 0,
    has_undo: bool = false,

    const Self = @This();

    /// Save current state for undo. Call before destructive edits.
    pub fn saveUndo(self: *Self) void {
        @memcpy(self.undo_text[0..self.len], self.text[0..self.len]);
        self.undo_len = self.len;
        self.undo_cursor = self.cursor;
        self.has_undo = true;
    }

    /// Restore from undo snapshot.
    pub fn undo(self: *Self) bool {
        if (!self.has_undo) return false;
        @memcpy(self.text[0..self.undo_len], self.undo_text[0..self.undo_len]);
        self.len = self.undo_len;
        self.cursor = self.undo_cursor;
        self.has_undo = false;
        return true;
    }

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
        // Find start of UTF-8 character before cursor
        var char_start = self.cursor - 1;
        while (char_start > 0 and (self.text[char_start] & 0xC0) == 0x80) char_start -= 1;
        const char_len = self.cursor - char_start;
        if (self.cursor < self.len) {
            std.mem.copyForwards(
                u8,
                self.text[char_start .. self.len - char_len],
                self.text[self.cursor .. self.len],
            );
        }
        self.len -= @intCast(char_len);
        self.cursor = @intCast(char_start);
        return true;
    }

    pub fn deleteForward(self: *Self) bool {
        if (self.cursor >= self.len) return false;
        // Find length of UTF-8 character at cursor
        const b0 = self.text[self.cursor];
        const char_len: usize = if (b0 < 0x80) 1 else if ((b0 & 0xE0) == 0xC0) 2 else if ((b0 & 0xF0) == 0xE0) 3 else if ((b0 & 0xF8) == 0xF0) 4 else 1;
        const del_end = @min(self.cursor + char_len, self.len);
        const actual_len = del_end - self.cursor;
        if (del_end < self.len) {
            std.mem.copyForwards(
                u8,
                self.text[self.cursor .. self.len - actual_len],
                self.text[del_end .. self.len],
            );
        }
        self.len -= @intCast(actual_len);
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
        // Skip back over UTF-8 continuation bytes (10xxxxxx)
        self.cursor -= 1;
        while (self.cursor > 0 and (self.text[self.cursor] & 0xC0) == 0x80)
            self.cursor -= 1;
        return true;
    }

    pub fn moveRight(self: *Self) bool {
        if (self.cursor >= self.len) return false;
        // Skip forward over full UTF-8 sequence
        const b0 = self.text[self.cursor];
        const char_len: u16 = if (b0 < 0x80) 1 else if ((b0 & 0xE0) == 0xC0) 2 else if ((b0 & 0xF0) == 0xE0) 3 else if ((b0 & 0xF8) == 0xF0) 4 else 1;
        self.cursor = @min(self.cursor + char_len, self.len);
        return true;
    }

    pub fn moveHome(self: *Self) void {
        self.moveLineStart();
    }

    pub fn moveEnd(self: *Self) void {
        self.moveLineEnd();
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

    /// column offset within current line (chars since last \n or start)
    pub fn currentCol(self: *const Self) u16 {
        var col: u16 = 0;
        var i = self.cursor;
        while (i > 0 and self.text[i - 1] != '\n') {
            i -= 1;
            col += 1;
        }
        return col;
    }

    /// move cursor up one line, preserving column where possible
    pub fn moveUp(self: *Self) bool {
        const col = self.currentCol();
        // find start of current line
        const line_start = self.cursor - col;
        if (line_start == 0) return false; // already on first line
        // go to end of previous line (before the \n)
        const prev_end = line_start - 1;
        // find start of previous line
        var prev_start = prev_end;
        while (prev_start > 0 and self.text[prev_start - 1] != '\n') {
            prev_start -= 1;
        }
        const prev_len = prev_end - prev_start;
        var target: u16 = @intCast(prev_start + @min(col, prev_len));
        // Snap to UTF-8 character boundary (don't land on continuation byte)
        while (target > prev_start and (self.text[target] & 0xC0) == 0x80) target -= 1;
        self.cursor = target;
        return true;
    }

    /// move cursor down one line, preserving column where possible
    pub fn moveDown(self: *Self) bool {
        const col = self.currentCol();
        // find end of current line
        var pos: u16 = self.cursor;
        while (pos < self.len and self.text[pos] != '\n') {
            pos += 1;
        }
        if (pos >= self.len) return false; // already on last line
        // skip the \n to get to next line start
        const next_start = pos + 1;
        // find end of next line
        var next_end = next_start;
        while (next_end < self.len and self.text[next_end] != '\n') {
            next_end += 1;
        }
        const next_len = next_end - next_start;
        var target: u16 = @intCast(next_start + @min(col, next_len));
        // Snap to UTF-8 character boundary (don't land on continuation byte)
        while (target > next_start and (self.text[target] & 0xC0) == 0x80) target -= 1;
        self.cursor = target;
        return true;
    }

    // ── Vi-mode motions ──

    fn isWordChar(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c >= 0x80;
    }

    /// move forward to start of next word (vi 'w')
    pub fn wordForward(self: *Self) void {
        // skip current word chars
        while (self.cursor < self.len and isWordChar(self.text[self.cursor])) self.cursor += 1;
        // skip non-word chars (punctuation/spaces)
        while (self.cursor < self.len and !isWordChar(self.text[self.cursor]) and self.text[self.cursor] != '\n')
            self.cursor += 1;
    }

    /// move backward to start of previous word (vi 'b')
    pub fn wordBack(self: *Self) void {
        if (self.cursor == 0) return;
        self.cursor -= 1;
        // skip non-word chars
        while (self.cursor > 0 and !isWordChar(self.text[self.cursor])) self.cursor -= 1;
        // skip word chars to find start
        while (self.cursor > 0 and isWordChar(self.text[self.cursor - 1])) self.cursor -= 1;
    }

    /// move forward to end of word (vi 'e')
    pub fn wordEnd(self: *Self) void {
        if (self.cursor >= self.len) return;
        self.cursor += 1;
        // skip non-word chars
        while (self.cursor < self.len and !isWordChar(self.text[self.cursor])) self.cursor += 1;
        // skip to end of word
        while (self.cursor < self.len and isWordChar(self.text[self.cursor])) self.cursor += 1;
        // Back up to last char of word, snapping to UTF-8 lead byte
        if (self.cursor > 0) {
            self.cursor -= 1;
            while (self.cursor > 0 and (self.text[self.cursor] & 0xC0) == 0x80)
                self.cursor -= 1;
        }
    }

    /// delete from cursor to end of line (vi 'D' / 'd$')
    pub fn deleteToEnd(self: *Self) void {
        var end = self.cursor;
        while (end < self.len and self.text[end] != '\n') end += 1;
        if (end > self.cursor) {
            // shift remaining text
            const remaining = self.len - end;
            if (remaining > 0)
                std.mem.copyForwards(u8, self.text[self.cursor..self.cursor + remaining], self.text[end..self.len]);
            self.len -= @intCast(end - self.cursor);
        }
    }

    /// delete word under/after cursor (vi 'dw')
    pub fn deleteWord(self: *Self) void {
        const start = self.cursor;
        self.wordForward();
        const end = self.cursor;
        self.cursor = @intCast(start);
        if (end > start) {
            const remaining = self.len - end;
            if (remaining > 0)
                std.mem.copyForwards(u8, self.text[start..start + remaining], self.text[end..self.len]);
            self.len -= @intCast(end - start);
        }
    }

    /// delete entire current line content (vi 'dd')
    pub fn deleteLine(self: *Self) void {
        self.moveLineStart();
        self.deleteToEnd();
        // Also remove the trailing newline (vi 'dd' removes the whole line)
        if (self.cursor < self.len and self.text[self.cursor] == '\n') {
            _ = self.deleteForward();
        } else if (self.cursor > 0 and self.cursor == self.len) {
            // Last line: remove the preceding newline instead
            self.cursor -= 1;
            _ = self.deleteForward();
        }
    }

    /// replace character under cursor (vi 'r')
    pub fn replaceChar(self: *Self, c: u8) void {
        if (self.cursor < self.len) {
            self.text[self.cursor] = c;
        }
    }

    /// delete character under cursor in normal mode (vi 'x')
    pub fn deleteAt(self: *Self) bool {
        return self.deleteForward();
    }

    /// put cursor at first non-blank of line (vi '^')
    pub fn moveFirstNonBlank(self: *Self) void {
        self.moveLineStart();
        while (self.cursor < self.len and (self.text[self.cursor] == ' ' or self.text[self.cursor] == '\t'))
            self.cursor += 1;
    }

    /// get the text of a specific line (0-indexed)
    pub fn getLine(self: *const Self, line_idx: u16) []const u8 {
        var current_line: u16 = 0;
        var start: usize = 0;
        for (self.text[0..self.len], 0..) |c, i| {
            if (c == '\n') {
                if (current_line == line_idx) return self.text[start..i];
                current_line += 1;
                start = i + 1;
            }
        }
        if (current_line == line_idx) return self.text[start..self.len];
        return "";
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
                _ = out.emit(Color.magenta);
                _ = out.emitByte(c);
                _ = out.emit(Color.reset);
                self.first_word = true; // next word is a command
            },
            '>', '<' => {
                _ = out.emit(Color.magenta);
                _ = out.emitByte(c);
                _ = out.emit(Color.reset);
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
        } else if (word.len > 1 and word[0] == '-') {
            // flags: --verbose, -f (dim white)
            _ = out.emit(Color.gray);
        } else if (word.len > 0 and word[0] >= '0' and word[0] <= '9') {
            // numbers
            _ = out.emit(Color.yellow);
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
    // ghost text suggestion (set by Shell, rendered after content in dim)
    ghost_text: []const u8 = "",

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
        var hash = std.hash.Wyhash.hash(0, text);
        if (self.ghost_text.len > 0) hash ^= std.hash.Wyhash.hash(1, self.ghost_text);

        // detect size change - force redraw when width changes
        const size_changed = self.term.width != self.last_width;
        if (size_changed) {
            self.last_width = self.term.width;
        }

        // skip if nothing changed
        if (!size_changed and hash == self.last_hash and buf.cursor == self.last_cursor) {
            return;
        }

        // Note: cursor hide/show removed — caused flicker in normal shell mode
        // Agent mode handles cursor visibility separately via \x1b[?25l/h

        const w = self.term.width;
        const cont_marker_len: u16 = 2; // "│ "

        // compute cursor position in content
        // Prompt may wrap: simulate column advancement matching terminal behavior.
        // Terminal wraps: writing char at col w-1 advances cursor to col w,
        // which is a "pending wrap" — next char goes to col 0 of next row.
        var cursor_row: u16 = 0;
        var cursor_col: u16 = prompt_visible_len;
        // Handle prompt wrapping
        if (w > 0) {
            while (cursor_col >= w) {
                cursor_col -= w;
                cursor_row += 1;
            }
        }

        for (text[0..buf.cursor]) |c| {
            if (c == '\n') {
                cursor_row += 1;
                cursor_col = cont_marker_len;
            } else {
                cursor_col += 1;
                if (w > 0 and cursor_col >= w) {
                    cursor_col -= w;
                    cursor_row += 1;
                }
            }
        }

        // move to start of our region
        if (self.term.row > 0) {
            _ = self.emitCSI("{d}A", .{self.term.row});
        }
        _ = self.emit("\r");

        // clear from start of our region to end of screen
        // this is simpler and more reliable than per-line clearing,
        // and avoids disturbing soft-wrap metadata on individual lines
        _ = self.emit("\x1b[J");

        // emit prompt
        _ = self.emit(prompt);

        // track rendering position as we emit
        var render_row: u16 = 0;
        var render_col: u16 = prompt_visible_len;
        if (w > 0) {
            while (render_col >= w) {
                render_col -= w;
                render_row += 1;
            }
        }

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
                // clear to end of line before newline to avoid trailing artifacts
                self.clearToEOL();
                _ = self.emitByte('\n');
                _ = self.emit(Color.gray);
                _ = self.emit("│");
                _ = self.emit(Color.reset);
                _ = self.emitByte(' ');
                hl.at_line_start = true;
                hl.first_word = true; // new line = new command context
                render_row += 1;
                render_col = cont_marker_len;
            } else {
                hl.feed(self, c);
                render_col += 1;
                if (w > 0 and render_col >= w) {
                    render_col -= w;
                    render_row += 1;
                    render_col = 0;
                }
            }
        }
        hl.flushWord(self);
        _ = self.emit(Color.reset);

        // render ghost text suggestion (dim, after content, only when cursor at end)
        if (self.ghost_text.len > 0 and buf.cursor == buf.len) {
            _ = self.emit("\x1b[90m"); // dim gray
            for (self.ghost_text) |c| {
                if (self.out_len > RENDER_BUF_SIZE - 64) break;
                if (c == '\n') break; // only show first line of ghost
                _ = self.emitByte(c);
                render_col += 1;
                if (w > 0 and render_col >= w) {
                    render_col -= w;
                    render_row += 1;
                }
            }
            _ = self.emit("\x1b[0m");
        }

        // clear any leftover content after our text
        _ = self.emit("\x1b[J");

        // Track render end position, then move to cursor
        self.term.row = render_row;
        self.term.col = render_col;
        self.moveTo(cursor_row, cursor_col);
        // moveTo updates self.term.row/col to cursor position

        self.term.rows_owned = render_row + 1;
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

test "EditBuffer undo" {
    var buf = EditBuffer{};
    buf.set("hello world");
    try std.testing.expectEqualStrings("hello world", buf.slice());

    // Save undo, then modify
    buf.saveUndo();
    buf.set("goodbye");
    try std.testing.expectEqualStrings("goodbye", buf.slice());

    // Undo restores
    try std.testing.expect(buf.undo());
    try std.testing.expectEqualStrings("hello world", buf.slice());

    // Second undo fails (single level)
    try std.testing.expect(!buf.undo());
}

test "EditBuffer undo preserves cursor" {
    var buf = EditBuffer{};
    _ = buf.insert('a');
    _ = buf.insert('b');
    _ = buf.insert('c');
    buf.cursor = 1; // cursor at 'b'

    buf.saveUndo();
    _ = buf.deleteForward(); // delete 'b'
    try std.testing.expectEqualStrings("ac", buf.slice());

    _ = buf.undo();
    try std.testing.expectEqualStrings("abc", buf.slice());
    try std.testing.expectEqual(@as(u16, 1), buf.cursor);
}
