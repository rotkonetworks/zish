// editor.zig - clean line editor architecture
// design: single source of truth, batched output, zero alloc hot path

const std = @import("std");
const compat = @import("compat.zig");
const keywords = @import("keywords.zig");
const render_pipeline = @import("render_pipeline.zig");

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
    pub const flag: []const u8 = "\x1b[94m"; // flags (committed, distinct from ghost gray)
};

pub const LINE_BUF_SIZE = 4096;
pub const RENDER_BUF_SIZE = 65536; // 64KB for large multiline content

pub const ViMode = enum { insert, normal };

/// bounded number of undo levels kept (each snapshot is a full LINE_BUF_SIZE
/// copy; Shell is heap-allocated via allocator.create so this is fine memory-
/// wise, but keep it small — it's a line editor, not a full text editor).
pub const UNDO_HISTORY = 16;

const Snapshot = struct {
    text: [LINE_BUF_SIZE]u8 = undefined,
    len: u16 = 0,
    cursor: u16 = 0,
};

/// pure text buffer - no rendering logic
pub const EditBuffer = struct {
    text: [LINE_BUF_SIZE]u8 = undefined,
    len: u16 = 0,
    cursor: u16 = 0,
    vi_mode: ViMode = .insert,

    // Undo/redo: bounded ring of full-buffer snapshots. `saveUndo()` pushes
    // the pre-edit state onto the undo stack and clears the redo stack (a
    // new edit invalidates any redo history — matches vim). `undo()` pops
    // the undo stack, pushing the *current* state onto the redo stack first
    // so `Ctrl-R` can restore it. `redo()` is the mirror image.
    undo_stack: [UNDO_HISTORY]Snapshot = undefined,
    undo_top: u8 = 0, // number of valid entries in undo_stack
    redo_stack: [UNDO_HISTORY]Snapshot = undefined,
    redo_top: u8 = 0,

    const Self = @This();

    fn snapshotCurrent(self: *const Self) Snapshot {
        var s = Snapshot{ .len = self.len, .cursor = self.cursor };
        @memcpy(s.text[0..self.len], self.text[0..self.len]);
        return s;
    }

    fn applySnapshot(self: *Self, s: *const Snapshot) void {
        @memcpy(self.text[0..s.len], s.text[0..s.len]);
        self.len = s.len;
        self.cursor = s.cursor;
    }

    /// Save current state for undo. Call before destructive edits.
    /// Clears the redo stack — a fresh edit invalidates old redo history.
    pub fn saveUndo(self: *Self) void {
        if (self.undo_top >= UNDO_HISTORY) {
            // drop the oldest entry to make room (shift down)
            for (0..UNDO_HISTORY - 1) |i| self.undo_stack[i] = self.undo_stack[i + 1];
            self.undo_top = UNDO_HISTORY - 1;
        }
        self.undo_stack[self.undo_top] = self.snapshotCurrent();
        self.undo_top += 1;
        self.redo_top = 0;
    }

    /// Restore the most recent undo snapshot, pushing the current state to redo.
    pub fn undo(self: *Self) bool {
        if (self.undo_top == 0) return false;
        if (self.redo_top < UNDO_HISTORY) {
            self.redo_stack[self.redo_top] = self.snapshotCurrent();
            self.redo_top += 1;
        }
        self.undo_top -= 1;
        self.applySnapshot(&self.undo_stack[self.undo_top]);
        return true;
    }

    /// Re-apply the most recently undone change.
    pub fn redo(self: *Self) bool {
        if (self.redo_top == 0) return false;
        if (self.undo_top < UNDO_HISTORY) {
            self.undo_stack[self.undo_top] = self.snapshotCurrent();
            self.undo_top += 1;
        }
        self.redo_top -= 1;
        self.applySnapshot(&self.redo_stack[self.redo_top]);
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

    pub fn moveEnd(self: *Self) void {
        // G: end of the whole buffer, not just the current line.
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

    /// put cursor at first non-blank of line (vi '^')
    pub fn moveFirstNonBlank(self: *Self) void {
        self.moveLineStart();
        while (self.cursor < self.len and (self.text[self.cursor] == ' ' or self.text[self.cursor] == '\t'))
            self.cursor += 1;
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
                if (self.word_len >= 127) {
                    // Buffer full — flush current word and start fresh.
                    // Without this, chars are silently dropped, causing
                    // render_col to desync from actual terminal position.
                    self.flushWord(out);
                }
                self.word_buf[self.word_len] = c;
                self.word_len += 1;
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
            // flags: --verbose, -f (committed, NOT ghost-gray)
            _ = out.emit(Color.flag);
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
    fd: compat.posix.fd_t,
    // ghost text suggestion (set by Shell, rendered after content in dim)
    ghost_text: []const u8 = "",

    const Self = @This();

    pub fn init(fd: compat.posix.fd_t) Self {
        var self = Self{ .fd = fd };
        self.updateSize();
        self.last_width = self.term.width;
        return self;
    }

    /// query terminal size via ioctl
    pub fn updateSize(self: *Self) void {
        var ws: compat.posix.winsize = undefined;
        if (std.posix.system.ioctl(self.fd, compat.posix.T.IOCGWINSZ, @intFromPtr(&ws)) == 0) {
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

    /// flush to terminal
    pub fn flush(self: *Self) !void {
        if (self.out_len == 0) return;
        _ = try compat.posix.write(self.fd, self.out[0..self.out_len]);
        self.out_len = 0;
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

    /// Render the edit buffer to the terminal.
    ///
    /// The deferred-wrap cursor correction lives in render_pipeline.positionCursor
    /// (a standalone function with regression tests) so it cannot be accidentally
    /// deleted by changes to content emission or syntax highlighting.
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

        const w = self.term.width;
        // No gutter glyph on continuation lines: a decoration is not
        // selectable-excludable and would land in copied text.
        const cont_marker_len: u16 = 0;

        // When the prompt is wider than the terminal it is truncated on emit to
        // (w-4) visible chars + ".. " (see the prompt-emit branch below), so it
        // occupies that many columns on screen, NOT prompt_visible_len. Seed the
        // position trackers with the on-screen width or the wrap math is off by
        // (prompt_visible_len - effective) columns — a horizontal desync in
        // narrow windows.
        const effective_prompt_vis: u16 = if (w > 0 and prompt_visible_len >= w)
            (w -| 4) + 3
        else
            prompt_visible_len;

        // compute cursor position in content
        var cursor_row: u16 = 0;
        var cursor_col: u16 = effective_prompt_vis;
        // Whether the cursor's current row was reached by a hard '\n' (not a
        // width-wrap). A col-0 position from a newline is a real terminal row;
        // one from a wrap is the deferred-wrap phantom (physical cursor still on
        // the row above at col=width). positionCursor must not correct the former.
        var cursor_via_newline = false;

        for (text[0..buf.cursor]) |c| {
            if (c == '\n') {
                cursor_row += 1;
                cursor_col = cont_marker_len;
                cursor_via_newline = true;
            } else {
                cursor_col += 1;
                if (w > 0 and cursor_col >= w) {
                    cursor_row += 1;
                    cursor_col = 0;
                    cursor_via_newline = false;
                }
            }
        }

        // move to start of our region. Clamp the cursor-up to (height-1): if our
        // content is taller than the screen the prompt-start scrolled off the
        // top, so moving up by more than that saturates at the top margin and the
        // following \x1b[J would erase the whole viewport (the small-window
        // blank-flash). positionCursor already clamps term.row; this is a
        // defensive backstop in case it was set elsewhere.
        if (self.term.row > 0) {
            const max_up: u16 = if (self.term.height > 0) self.term.height - 1 else self.term.row;
            const up = @min(self.term.row, max_up);
            if (up > 0) _ = self.emitCSI("{d}A", .{up});
        }
        _ = self.emit("\r");

        // clear from start of our region to end of screen
        _ = self.emit("\x1b[J");

        // emit prompt — truncate if wider than terminal
        if (w > 0 and prompt_visible_len >= w) {
            const max_vis = w -| 4;
            var vis: u16 = 0;
            var byte_pos: usize = 0;
            var in_esc = false;
            while (byte_pos < prompt.len and vis < max_vis) {
                if (prompt[byte_pos] == 0x1b) {
                    in_esc = true;
                } else if (in_esc) {
                    if ((prompt[byte_pos] >= 'A' and prompt[byte_pos] <= 'Z') or (prompt[byte_pos] >= 'a' and prompt[byte_pos] <= 'z')) in_esc = false;
                } else {
                    vis += 1;
                }
                byte_pos += 1;
            }
            while (in_esc and byte_pos < prompt.len) {
                if ((prompt[byte_pos] >= 'A' and prompt[byte_pos] <= 'Z') or (prompt[byte_pos] >= 'a' and prompt[byte_pos] <= 'z')) in_esc = false;
                byte_pos += 1;
            }
            _ = self.emit(prompt[0..byte_pos]);
            _ = self.emit("\x1b[0m.. ");
        } else {
            _ = self.emit(prompt);
        }

        // track rendering position as we emit (seed with the on-screen prompt
        // width, matching cursor_col above — see effective_prompt_vis note)
        var render_row: u16 = 0;
        var render_col: u16 = effective_prompt_vis;
        var render_via_newline = false; // see cursor_via_newline above

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
                self.clearToEOL();
                _ = self.emitByte('\n');
                hl.at_line_start = true;
                hl.first_word = true;
                render_row += 1;
                render_col = cont_marker_len;
                render_via_newline = true;
            } else {
                hl.feed(self, c);
                render_col += 1;
                if (w > 0 and render_col >= w) {
                    render_row += 1;
                    render_col = 0;
                    render_via_newline = false;
                }
            }
        }
        hl.flushWord(self);
        _ = self.emit(Color.reset);

        // render ghost text suggestion (two-tone: completes-current-token | future)
        if (self.ghost_text.len > 0 and buf.cursor == buf.len) {
            var ghost_match_len: usize = 0;
            while (ghost_match_len < self.ghost_text.len and
                self.ghost_text[ghost_match_len] != ' ' and
                self.ghost_text[ghost_match_len] != '\t' and
                self.ghost_text[ghost_match_len] != '\n')
            {
                ghost_match_len += 1;
            }

            // left: completes the token you're typing
            _ = self.emit(Color.cyan);
            for (self.ghost_text[0..ghost_match_len]) |c| {
                if (self.out_len > RENDER_BUF_SIZE - 64) break;
                if (c == '\n') break;
                _ = self.emitByte(c);
                render_col += 1;
                if (w > 0 and render_col >= w) {
                    render_row += 1;
                    render_col = 0;
                    render_via_newline = false;
                }
            }
            // right: future (italic = placeholder, never reads as committed)
            _ = self.emit("\x1b[3;90m");
            for (self.ghost_text[ghost_match_len..]) |c| {
                if (self.out_len > RENDER_BUF_SIZE - 64) break;
                if (c == '\n') break;
                _ = self.emitByte(c);
                render_col += 1;
                if (w > 0 and render_col >= w) {
                    render_row += 1;
                    render_col = 0;
                    render_via_newline = false;
                }
            }
            _ = self.emit(Color.reset);
        }

        // clear any leftover content after our text
        _ = self.emit("\x1b[J");

        // Cursor positioning with deferred-wrap correction.
        // Isolated in render_pipeline.zig with regression tests — do not inline.
        render_pipeline.positionCursor(
            self,
            render_row,
            render_col,
            cursor_row,
            cursor_col,
            buf.cursor == buf.len,
            w,
            hash,
            buf.cursor,
            render_via_newline,
            cursor_via_newline,
        );

        // Optional render trace for debugging the small-window blank bug.
        // Gated on $ZISH_RENDER_LOG (path). Zero cost when unset.
        debugLogRender(self, w, render_row, render_col, cursor_row, cursor_col, buf.len, buf.cursor);

        try self.flush();
    }

    fn debugLogRender(self: *Self, w: u16, render_row: u16, render_col: u16, cursor_row: u16, cursor_col: u16, blen: u16, cur: u16) void {
        const path = compat.posix.getenv("ZISH_RENDER_LOG") orelse return;
        const f = std.Io.Dir.cwd().createFile(compat.io(), path, .{ .truncate = false }) catch return;
        defer f.close(compat.io());
        const end = f.length(compat.io()) catch 0;
        var buf: [2048]u8 = undefined;
        // header line: geometry + computed cursor model
        var w1: std.Io.Writer = .fixed(&buf);
        w1.print("RENDER w={d} h={d} | term.row={d} col={d} rows_owned={d} | render_row={d} col={d} cursor_row={d} col={d} | blen={d} cur={d} | bytes=", .{
            w, self.term.height, self.term.row, self.term.col, self.term.rows_owned,
            render_row, render_col, cursor_row, cursor_col, blen, cur,
        }) catch {};
        _ = f.writePositionalAll(compat.io(), w1.buffered(), end) catch return;
        // escaped emitted bytes
        var pos = end + w1.end;
        var eb: [16]u8 = undefined;
        for (self.out[0..self.out_len]) |c| {
            const s = switch (c) {
                0x1b => "<ESC>",
                '\r' => "<CR>",
                '\n' => "<LF>",
                else => blk: {
                    eb[0] = c;
                    break :blk eb[0..1];
                },
            };
            _ = f.writePositionalAll(compat.io(), s, pos) catch break;
            pos += s.len;
        }
        _ = f.writePositionalAll(compat.io(), "\n", pos) catch {};
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
