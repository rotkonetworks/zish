// vim.zig - modal editing state machine
// design: zero-alloc, works with EditBuffer, clean state transitions

const std = @import("std");
const editor = @import("editor.zig");

pub const Mode = enum {
    normal,
    insert,
    replace, // single char replace (r)
    visual,
    visual_line,
};

pub const Operator = enum {
    none,
    delete, // d
    change, // c
    yank, // y
};

pub const TextObject = enum {
    word, // w
    word_big, // W
    quote_single, // '
    quote_double, // "
    backtick, // `
    paren, // ( )
    bracket, // [ ]
    brace, // { }
    angle, // < >
};

/// vim editing state machine
pub const Vim = struct {
    mode: Mode = .insert, // shells typically start in insert
    pending_op: Operator = .none,
    awaiting_text_obj: bool = false, // waiting for i/a + object
    text_obj_inner: bool = false, // true = inner, false = around
    count: u16 = 0, // numeric prefix (0 = 1)
    register: u8 = '"', // default register
    yank_buf: [editor.LINE_BUF_SIZE]u8 = undefined,
    yank_len: u16 = 0,
    last_cmd: u8 = 0, // for dot repeat
    last_count: u16 = 0,
    // visual mode
    visual_start: u16 = 0, // selection anchor
    // preferred column for j/k movement (vim remembers target col)
    preferred_col: u16 = 0,
    preferred_col_set: bool = false,
    pending_g: bool = false, // waiting for second char after g

    const Self = @This();

    /// get effective count (0 means 1)
    fn getCount(self: *Self) u16 {
        const c = if (self.count == 0) 1 else self.count;
        self.count = 0;
        return c;
    }

    /// handle key input, returns true if key was consumed
    pub fn handleKey(self: *Self, buf: *editor.EditBuffer, key: u8) KeyResult {
        return switch (self.mode) {
            .normal => self.handleNormal(buf, key),
            .insert => self.handleInsert(buf, key),
            .replace => self.handleReplace(buf, key),
            .visual, .visual_line => self.handleVisual(buf, key),
        };
    }

    fn handleNormal(self: *Self, buf: *editor.EditBuffer, key: u8) KeyResult {
        // handle pending g prefix (gg = go to top)
        if (self.pending_g) {
            self.pending_g = false;
            if (key == 'g') {
                self.preferred_col_set = false;
                buf.cursor = 0;
                return .consumed;
            }
            // unknown g-sequence, ignore
            return .consumed;
        }

        // numeric prefix
        if (key >= '1' and key <= '9') {
            self.count = self.count * 10 + (key - '0');
            return .consumed;
        }
        if (key == '0' and self.count > 0) {
            self.count = self.count * 10;
            return .consumed;
        }

        // check for pending operator
        if (self.pending_op != .none) {
            return self.handleMotionForOperator(buf, key);
        }

        const count = self.getCount();

        switch (key) {
            // mode changes
            'i' => {
                self.mode = .insert;
                return .mode_changed;
            },
            'I' => {
                buf.moveLineStart();
                self.mode = .insert;
                return .mode_changed;
            },
            'a' => {
                _ = buf.moveRight();
                self.mode = .insert;
                return .mode_changed;
            },
            'A' => {
                buf.moveLineEnd();
                self.mode = .insert;
                return .mode_changed;
            },
            'o' => {
                buf.moveLineEnd();
                _ = buf.insert('\n');
                self.mode = .insert;
                return .mode_changed;
            },
            'O' => {
                buf.moveLineStart();
                _ = buf.insert('\n');
                _ = buf.moveLeft();
                self.mode = .insert;
                return .mode_changed;
            },
            'R' => {
                self.mode = .replace;
                return .mode_changed;
            },
            'v' => {
                self.mode = .visual;
                self.visual_start = buf.cursor;
                return .mode_changed;
            },
            'V' => {
                self.mode = .visual_line;
                self.visual_start = buf.cursor;
                return .mode_changed;
            },

            // motions (horizontal resets preferred column)
            'h' => {
                self.preferred_col_set = false;
                for (0..count) |_| _ = buf.moveLeft();
                return .consumed;
            },
            'l' => {
                self.preferred_col_set = false;
                for (0..count) |_| _ = buf.moveRight();
                return .consumed;
            },
            'j' => {
                // move down (in multiline context)
                for (0..count) |_| self.moveDown(buf);
                return .consumed;
            },
            'k' => {
                // move up
                for (0..count) |_| self.moveUp(buf);
                return .consumed;
            },
            'w' => {
                self.preferred_col_set = false;
                for (0..count) |_| self.moveWordForward(buf);
                return .consumed;
            },
            'W' => {
                self.preferred_col_set = false;
                for (0..count) |_| self.moveWordForwardBig(buf);
                return .consumed;
            },
            'b' => {
                self.preferred_col_set = false;
                for (0..count) |_| self.moveWordBackward(buf);
                return .consumed;
            },
            'B' => {
                self.preferred_col_set = false;
                for (0..count) |_| self.moveWordBackwardBig(buf);
                return .consumed;
            },
            'e' => {
                self.preferred_col_set = false;
                for (0..count) |_| self.moveWordEnd(buf);
                return .consumed;
            },
            'E' => {
                self.preferred_col_set = false;
                for (0..count) |_| self.moveWordEndBig(buf);
                return .consumed;
            },
            '0' => {
                self.preferred_col_set = false;
                buf.moveLineStart();
                return .consumed;
            },
            '^' => {
                self.preferred_col_set = false;
                buf.moveLineStart();
                self.skipWhitespace(buf);
                return .consumed;
            },
            '$' => {
                self.preferred_col_set = false;
                buf.moveLineEnd();
                return .consumed;
            },
            'g' => {
                self.pending_g = true;
                return .need_more;
            },
            'G' => {
                self.preferred_col_set = false;
                buf.moveEnd();
                return .consumed;
            },

            // operators
            'd' => {
                self.pending_op = .delete;
                self.last_cmd = 'd';
                self.last_count = count;
                return .consumed;
            },
            'c' => {
                self.pending_op = .change;
                self.last_cmd = 'c';
                self.last_count = count;
                return .consumed;
            },
            'y' => {
                self.pending_op = .yank;
                self.last_cmd = 'y';
                self.last_count = count;
                return .consumed;
            },

            // Y — yank entire line (vim compat)
            'Y' => {
                const save = buf.cursor;
                buf.moveLineStart();
                const start = buf.cursor;
                buf.moveLineEnd();
                const end = buf.cursor;
                if (end > start) self.yankRange(buf, start, end);
                buf.cursor = save;
                return .consumed;
            },
            // ~ — toggle case under cursor, advance
            '~' => {
                for (0..count) |_| {
                    if (buf.cursor < buf.len and buf.text[buf.cursor] < 0x80) {
                        const c = buf.text[buf.cursor];
                        if (c >= 'a' and c <= 'z') {
                            buf.text[buf.cursor] = c - 32;
                        } else if (c >= 'A' and c <= 'Z') {
                            buf.text[buf.cursor] = c + 32;
                        }
                        _ = buf.moveRight();
                    }
                }
                return .consumed;
            },
            // J — join current line with next (remove newline at end of line)
            'J' => {
                // find newline at end of current line
                var pos = buf.cursor;
                while (pos < buf.len and buf.text[pos] != '\n') : (pos += 1) {}
                if (pos < buf.len) {
                    // delete the newline
                    const old = buf.cursor;
                    buf.cursor = pos;
                    _ = buf.deleteForward();
                    // ensure a space if the join point has none
                    if (buf.cursor < buf.len and buf.text[buf.cursor] != ' ' and
                        buf.cursor > 0 and buf.text[buf.cursor - 1] != ' ')
                    {
                        buf.insert(' ');
                    }
                    buf.cursor = old;
                }
                return .consumed;
            },

            // single char ops
            'x' => {
                for (0..count) |_| {
                    if (buf.cursor < buf.len) {
                        _ = buf.deleteForward();
                    }
                }
                return .consumed;
            },
            'X' => {
                for (0..count) |_| _ = buf.delete();
                return .consumed;
            },
            'r' => {
                self.mode = .replace;
                return .need_more;
            },
            's' => {
                _ = buf.deleteForward();
                self.mode = .insert;
                return .mode_changed;
            },
            'S' => {
                // delete line content, enter insert
                buf.moveLineStart();
                while (buf.cursor < buf.len and buf.text[buf.cursor] != '\n') {
                    _ = buf.deleteForward();
                }
                self.mode = .insert;
                return .mode_changed;
            },
            'C' => {
                // change to end of line
                while (buf.cursor < buf.len and buf.text[buf.cursor] != '\n') {
                    _ = buf.deleteForward();
                }
                self.mode = .insert;
                return .mode_changed;
            },
            'D' => {
                // delete to end of line
                while (buf.cursor < buf.len and buf.text[buf.cursor] != '\n') {
                    _ = buf.deleteForward();
                }
                return .consumed;
            },

            // paste
            'p' => {
                self.pasteAfter(buf, count);
                return .consumed;
            },
            'P' => {
                self.pasteBefore(buf, count);
                return .consumed;
            },

            // undo - would need undo stack
            'u' => return .consumed, // TODO: undo

            // repeat
            '.' => {
                // TODO: repeat last change
                return .consumed;
            },

            // escape does nothing in normal mode
            27 => return .consumed,

            else => return .unhandled,
        }
    }

    fn handleInsert(self: *Self, buf: *editor.EditBuffer, key: u8) KeyResult {
        // any insert mode action resets preferred column
        self.preferred_col_set = false;

        switch (key) {
            27 => { // escape
                self.mode = .normal;
                _ = buf.moveLeft(); // vim moves cursor left on escape
                return .mode_changed;
            },
            127 => { // backspace
                _ = buf.delete();
                return .consumed;
            },
            1 => { // ctrl-a - start of line
                buf.moveLineStart();
                return .consumed;
            },
            5 => { // ctrl-e - end of line
                buf.moveLineEnd();
                return .consumed;
            },
            21 => { // ctrl-u - delete to start
                while (buf.cursor > 0 and buf.text[buf.cursor - 1] != '\n') {
                    _ = buf.delete();
                }
                return .consumed;
            },
            23 => { // ctrl-w - delete word back
                self.deleteWordBack(buf);
                return .consumed;
            },
            else => {
                if (key >= 32 or key == '\n' or key == '\t') {
                    _ = buf.insert(key);
                    return .consumed;
                }
                return .unhandled;
            },
        }
    }

    fn handleReplace(self: *Self, buf: *editor.EditBuffer, key: u8) KeyResult {
        if (key == 27) { // escape
            self.mode = .normal;
            return .mode_changed;
        }
        if (buf.cursor < buf.len) {
            buf.text[buf.cursor] = key;
        }
        self.mode = .normal;
        return .consumed;
    }

    fn handleVisual(self: *Self, buf: *editor.EditBuffer, key: u8) KeyResult {
        switch (key) {
            27 => { // escape - cancel selection
                self.mode = .normal;
                return .mode_changed;
            },
            // motions extend selection
            'h' => {
                _ = buf.moveLeft();
                return .consumed;
            },
            'l' => {
                _ = buf.moveRight();
                return .consumed;
            },
            'j' => {
                self.moveDown(buf);
                return .consumed;
            },
            'k' => {
                self.moveUp(buf);
                return .consumed;
            },
            'w' => {
                self.moveWordForward(buf);
                return .consumed;
            },
            'b' => {
                self.moveWordBackward(buf);
                return .consumed;
            },
            'e' => {
                self.moveWordEnd(buf);
                return .consumed;
            },
            '0' => {
                buf.moveLineStart();
                return .consumed;
            },
            '$' => {
                buf.moveLineEnd();
                return .consumed;
            },
            '^' => {
                buf.moveLineStart();
                self.skipWhitespace(buf);
                return .consumed;
            },
            // operators on selection
            'd', 'x' => {
                const range = self.getVisualRange(buf);
                self.yankRange(buf, range.start, range.end);
                buf.cursor = range.start;
                for (0..(range.end - range.start)) |_| _ = buf.deleteForward();
                self.mode = .normal;
                return .mode_changed;
            },
            'c', 's' => {
                const range = self.getVisualRange(buf);
                self.yankRange(buf, range.start, range.end);
                buf.cursor = range.start;
                for (0..(range.end - range.start)) |_| _ = buf.deleteForward();
                self.mode = .insert;
                return .mode_changed;
            },
            'y' => {
                const range = self.getVisualRange(buf);
                self.yankRange(buf, range.start, range.end);
                buf.cursor = range.start;
                self.mode = .normal;
                return .mode_changed;
            },
            'v' => {
                // toggle back to normal
                self.mode = .normal;
                return .mode_changed;
            },
            'V' => {
                // switch to line visual
                self.mode = .visual_line;
                return .mode_changed;
            },
            'o' => {
                // swap cursor and anchor
                const tmp = self.visual_start;
                self.visual_start = buf.cursor;
                buf.cursor = tmp;
                return .consumed;
            },
            else => return .consumed,
        }
    }

    fn getVisualRange(self: *Self, buf: *editor.EditBuffer) Range {
        var start = @min(self.visual_start, buf.cursor);
        var end = @max(self.visual_start, buf.cursor);

        if (self.mode == .visual_line) {
            // extend to full lines
            const text = buf.text[0..buf.len];
            while (start > 0 and text[start - 1] != '\n') start -= 1;
            while (end < buf.len and text[end] != '\n') end += 1;
            if (end < buf.len) end += 1; // include newline
        } else {
            // character visual includes char under cursor
            if (end < buf.len) end += 1;
        }

        return .{ .start = start, .end = end };
    }

    fn yankRange(self: *Self, buf: *editor.EditBuffer, start: u16, end: u16) void {
        const len = end - start;
        if (len > 0 and len <= editor.LINE_BUF_SIZE) {
            @memcpy(self.yank_buf[0..len], buf.text[start..end]);
            self.yank_len = len;
        }
    }

    /// get visual selection boundaries for rendering
    pub fn getSelection(self: *const Self, buf: *const editor.EditBuffer) ?Range {
        if (self.mode != .visual and self.mode != .visual_line) return null;
        const start = @min(self.visual_start, buf.cursor);
        var end = @max(self.visual_start, buf.cursor);
        if (end < buf.len) end += 1;
        return .{ .start = start, .end = end };
    }

    fn handleMotionForOperator(self: *Self, buf: *editor.EditBuffer, key: u8) KeyResult {
        const start = buf.cursor;
        var end = start;

        // handle text object second char (after i/a)
        if (self.awaiting_text_obj) {
            self.awaiting_text_obj = false;
            const range = self.findTextObject(buf, key, self.text_obj_inner);
            if (range.start < range.end) {
                const was_change = self.pending_op == .change;
                self.executeOperator(buf, range.start, range.end);
                return if (was_change) .mode_changed else .consumed;
            }
            self.pending_op = .none;
            return .consumed;
        }

        // doubled operator (dd, cc, yy) - operate on whole line
        if ((self.pending_op == .delete and key == 'd') or
            (self.pending_op == .change and key == 'c') or
            (self.pending_op == .yank and key == 'y'))
        {
            buf.moveLineStart();
            const line_start = buf.cursor;
            buf.moveLineEnd();
            if (buf.cursor < buf.len and buf.text[buf.cursor] == '\n') {
                _ = buf.moveRight(); // include newline
            }
            end = buf.cursor;
            buf.cursor = line_start;

            self.executeOperator(buf, line_start, end);
            return if (self.pending_op == .change) .mode_changed else .consumed;
        }

        // motion keys
        const count = if (self.last_count > 0) self.last_count else 1;
        switch (key) {
            'h' => {
                for (0..count) |_| _ = buf.moveLeft();
                end = buf.cursor;
                buf.cursor = @min(start, end);
            },
            'l' => {
                for (0..count) |_| _ = buf.moveRight();
                end = buf.cursor;
            },
            'w' => {
                for (0..count) |_| self.moveWordForward(buf);
                end = buf.cursor;
            },
            'b' => {
                for (0..count) |_| self.moveWordBackward(buf);
                end = buf.cursor;
                buf.cursor = @min(start, end);
            },
            'e' => {
                for (0..count) |_| self.moveWordEnd(buf);
                end = buf.cursor + 1; // include char under cursor
            },
            '0' => {
                buf.moveLineStart();
                end = start;
                buf.cursor = buf.cursor;
                const tmp = buf.cursor;
                buf.cursor = @min(start, tmp);
                end = @max(start, tmp);
            },
            '$' => {
                buf.moveLineEnd();
                end = buf.cursor;
            },
            'i' => {
                // inner text object - need object char
                self.awaiting_text_obj = true;
                self.text_obj_inner = true;
                return .need_more;
            },
            'a' => {
                // around text object - need object char
                self.awaiting_text_obj = true;
                self.text_obj_inner = false;
                return .need_more;
            },
            27 => { // escape - cancel
                self.pending_op = .none;
                self.last_count = 0;
                return .consumed;
            },
            else => {
                self.pending_op = .none;
                self.last_count = 0;
                return .unhandled;
            },
        }

        // operate from original start to where motion moved cursor
        const op_start = @min(start, end);
        const op_end = @max(start, end);
        self.executeOperator(buf, op_start, op_end);
        return if (self.pending_op == .change) .mode_changed else .consumed;
    }

    const Range = struct { start: u16, end: u16 };

    /// find text object boundaries
    fn findTextObject(self: *Self, buf: *editor.EditBuffer, obj: u8, inner: bool) Range {
        const text = buf.text[0..buf.len];
        const cursor = buf.cursor;

        switch (obj) {
            'w', 'W' => {
                // word object
                const big = obj == 'W';
                var start = cursor;
                var end = cursor;

                // find word start
                if (big) {
                    while (start > 0 and !isWhitespace(text[start - 1])) start -= 1;
                } else {
                    while (start > 0 and isWordChar(text[start - 1])) start -= 1;
                }

                // find word end
                if (big) {
                    while (end < buf.len and !isWhitespace(text[end])) end += 1;
                } else {
                    while (end < buf.len and isWordChar(text[end])) end += 1;
                }

                // 'around' includes trailing whitespace
                if (!inner) {
                    while (end < buf.len and (text[end] == ' ' or text[end] == '\t')) end += 1;
                }

                return .{ .start = start, .end = end };
            },
            '"', '\'', '`' => {
                // quoted string
                const quote = obj;
                var start: u16 = 0;
                var end: u16 = 0;
                var found_start = false;

                // find opening quote before or at cursor
                var i: u16 = 0;
                while (i <= cursor and i < buf.len) : (i += 1) {
                    if (text[i] == quote) {
                        start = i;
                        found_start = true;
                    }
                }

                if (!found_start) return .{ .start = 0, .end = 0 };

                // find closing quote after start
                i = start + 1;
                while (i < buf.len) : (i += 1) {
                    if (text[i] == quote) {
                        end = i + 1;
                        break;
                    }
                }

                if (end == 0) return .{ .start = 0, .end = 0 };

                if (inner) {
                    return .{ .start = start + 1, .end = end - 1 };
                }
                return .{ .start = start, .end = end };
            },
            '(', ')', 'b' => {
                return self.findMatchingPair(buf, '(', ')');
            },
            '[', ']' => {
                return self.findMatchingPair(buf, '[', ']');
            },
            '{', '}', 'B' => {
                return self.findMatchingPair(buf, '{', '}');
            },
            '<', '>' => {
                return self.findMatchingPair(buf, '<', '>');
            },
            else => return .{ .start = 0, .end = 0 },
        }
    }

    fn findMatchingPair(self: *const Self, buf: *editor.EditBuffer, open: u8, close: u8) Range {
        const text = buf.text[0..buf.len];
        const cursor = buf.cursor;

        // find opening bracket going backward
        var depth: i16 = 0;
        var start: u16 = cursor;
        var found = false;

        // search backward for opening
        var i: i32 = @intCast(cursor);
        while (i >= 0) : (i -= 1) {
            const idx: u16 = @intCast(i);
            if (text[idx] == close) {
                depth += 1;
            } else if (text[idx] == open) {
                if (depth == 0) {
                    start = idx;
                    found = true;
                    break;
                }
                depth -= 1;
            }
        }

        if (!found) return .{ .start = 0, .end = 0 };

        // find closing bracket going forward
        depth = 1;
        var end: u16 = start + 1;
        while (end < buf.len) : (end += 1) {
            if (text[end] == open) {
                depth += 1;
            } else if (text[end] == close) {
                depth -= 1;
                if (depth == 0) {
                    end += 1; // include closing bracket
                    break;
                }
            }
        }

        // inner excludes brackets themselves
        if (self.text_obj_inner) {
            return .{ .start = start + 1, .end = end - 1 };
        }
        return .{ .start = start, .end = end };
    }

    fn executeOperator(self: *Self, buf: *editor.EditBuffer, start: u16, end: u16) void {
        if (start >= end) {
            self.pending_op = .none;
            return;
        }

        const op = self.pending_op;
        self.pending_op = .none;

        // yank text to register
        const len = end - start;
        if (len <= editor.LINE_BUF_SIZE) {
            @memcpy(self.yank_buf[0..len], buf.text[start..end]);
            self.yank_len = len;
        }

        switch (op) {
            .delete => {
                buf.cursor = start;
                for (0..len) |_| _ = buf.deleteForward();
            },
            .change => {
                buf.cursor = start;
                for (0..len) |_| _ = buf.deleteForward();
                self.mode = .insert;
            },
            .yank => {
                buf.cursor = start; // move to start of yanked region
            },
            .none => {},
        }
    }

    // motion helpers
    fn moveWordForward(self: *Self, buf: *editor.EditBuffer) void {
        _ = self;
        if (buf.cursor >= buf.len) return;

        const c = buf.text[buf.cursor];
        if (isWordChar(c)) {
            // skip current word chars
            while (buf.cursor < buf.len and isWordChar(buf.text[buf.cursor])) {
                _ = buf.moveRight();
            }
        } else if (isPunct(c)) {
            // skip current punct chars
            while (buf.cursor < buf.len and isPunct(buf.text[buf.cursor])) {
                _ = buf.moveRight();
            }
        }
        // skip whitespace
        while (buf.cursor < buf.len and isWhitespace(buf.text[buf.cursor])) {
            _ = buf.moveRight();
        }
    }

    fn moveWordForwardBig(self: *Self, buf: *editor.EditBuffer) void {
        _ = self;
        // skip non-whitespace
        while (buf.cursor < buf.len and !isWhitespace(buf.text[buf.cursor])) {
            _ = buf.moveRight();
        }
        // skip whitespace
        while (buf.cursor < buf.len and isWhitespace(buf.text[buf.cursor])) {
            _ = buf.moveRight();
        }
    }

    fn moveWordBackward(self: *Self, buf: *editor.EditBuffer) void {
        _ = self;
        if (buf.cursor == 0) return;

        // skip whitespace before
        while (buf.cursor > 0 and isWhitespace(buf.text[buf.cursor - 1])) {
            _ = buf.moveLeft();
        }
        if (buf.cursor == 0) return;

        // skip word or punct
        const c = buf.text[buf.cursor - 1];
        if (isWordChar(c)) {
            while (buf.cursor > 0 and isWordChar(buf.text[buf.cursor - 1])) {
                _ = buf.moveLeft();
            }
        } else if (isPunct(c)) {
            while (buf.cursor > 0 and isPunct(buf.text[buf.cursor - 1])) {
                _ = buf.moveLeft();
            }
        }
    }

    fn moveWordBackwardBig(self: *Self, buf: *editor.EditBuffer) void {
        _ = self;
        while (buf.cursor > 0 and isWhitespace(buf.text[buf.cursor - 1])) {
            _ = buf.moveLeft();
        }
        while (buf.cursor > 0 and !isWhitespace(buf.text[buf.cursor - 1])) {
            _ = buf.moveLeft();
        }
    }

    fn moveWordEnd(self: *Self, buf: *editor.EditBuffer) void {
        _ = self;
        if (buf.cursor >= buf.len) return;

        _ = buf.moveRight();
        // skip whitespace
        while (buf.cursor < buf.len and isWhitespace(buf.text[buf.cursor])) {
            _ = buf.moveRight();
        }
        if (buf.cursor >= buf.len) return;

        // skip to end of word or punct
        const c = buf.text[buf.cursor];
        if (isWordChar(c)) {
            while (buf.cursor < buf.len - 1 and isWordChar(buf.text[buf.cursor + 1])) {
                _ = buf.moveRight();
            }
        } else if (isPunct(c)) {
            while (buf.cursor < buf.len - 1 and isPunct(buf.text[buf.cursor + 1])) {
                _ = buf.moveRight();
            }
        }
    }

    fn moveWordEndBig(self: *Self, buf: *editor.EditBuffer) void {
        _ = self;
        _ = buf.moveRight();
        while (buf.cursor < buf.len and isWhitespace(buf.text[buf.cursor])) {
            _ = buf.moveRight();
        }
        if (buf.len == 0 or buf.cursor >= buf.len) return;
        while (buf.cursor < buf.len - 1 and !isWhitespace(buf.text[buf.cursor + 1])) {
            _ = buf.moveRight();
        }
    }

    pub fn moveDown(self: *Self, buf: *editor.EditBuffer) void {
        // get current column (count UTF-8 characters, not bytes)
        var col: u16 = 0;
        var i = buf.cursor;
        while (i > 0 and buf.text[i - 1] != '\n') {
            i -= 1;
            // Only count lead bytes (skip continuation bytes)
            if ((buf.text[i] & 0xC0) != 0x80) col += 1;
        }

        // set preferred column if not already set (first j/k in sequence)
        if (!self.preferred_col_set) {
            self.preferred_col = col;
            self.preferred_col_set = true;
        }

        // move to next line
        buf.moveLineEnd();
        if (buf.cursor < buf.len and buf.text[buf.cursor] == '\n') {
            _ = buf.moveRight();
            // move to preferred column (not current col)
            var c: u16 = 0;
            while (c < self.preferred_col and buf.cursor < buf.len and buf.text[buf.cursor] != '\n') {
                _ = buf.moveRight();
                c += 1;
            }
        }
    }

    pub fn moveUp(self: *Self, buf: *editor.EditBuffer) void {
        // get current column (count UTF-8 characters, not bytes)
        var col: u16 = 0;
        var i = buf.cursor;
        while (i > 0 and buf.text[i - 1] != '\n') {
            i -= 1;
            if ((buf.text[i] & 0xC0) != 0x80) col += 1;
        }

        // set preferred column if not already set
        if (!self.preferred_col_set) {
            self.preferred_col = col;
            self.preferred_col_set = true;
        }

        // move to previous line
        if (i > 0) {
            buf.cursor = i - 1; // skip newline
            buf.moveLineStart();
            // move to preferred column
            var c: u16 = 0;
            while (c < self.preferred_col and buf.cursor < buf.len and buf.text[buf.cursor] != '\n') {
                _ = buf.moveRight();
                c += 1;
            }
        }
    }

    fn skipWhitespace(self: *Self, buf: *editor.EditBuffer) void {
        _ = self;
        while (buf.cursor < buf.len and (buf.text[buf.cursor] == ' ' or buf.text[buf.cursor] == '\t')) {
            _ = buf.moveRight();
        }
    }

    fn deleteWordBack(self: *Self, buf: *editor.EditBuffer) void {
        _ = self;
        // skip whitespace
        while (buf.cursor > 0 and isWhitespace(buf.text[buf.cursor - 1])) {
            _ = buf.delete();
        }
        // delete word
        while (buf.cursor > 0 and isWordChar(buf.text[buf.cursor - 1])) {
            _ = buf.delete();
        }
    }

    fn pasteAfter(self: *Self, buf: *editor.EditBuffer, count: u16) void {
        if (self.yank_len == 0) return;
        _ = buf.moveRight();
        for (0..count) |_| {
            _ = buf.insertSlice(self.yank_buf[0..self.yank_len]);
        }
    }

    fn pasteBefore(self: *Self, buf: *editor.EditBuffer, count: u16) void {
        if (self.yank_len == 0) return;
        for (0..count) |_| {
            _ = buf.insertSlice(self.yank_buf[0..self.yank_len]);
        }
    }

    /// get mode indicator string for prompt
    pub fn modeIndicator(self: *const Self) []const u8 {
        return switch (self.mode) {
            .normal => "[N]",
            .insert => "[I]",
            .replace => "[R]",
            .visual => "[v]",
            .visual_line => "[V]",
        };
    }

    /// get mode indicator with color
    pub fn modeIndicatorColored(self: *const Self) []const u8 {
        return switch (self.mode) {
            .normal => "[\x1b[31mN\x1b[0m]",
            .insert => "[\x1b[33mI\x1b[0m]",
            .replace => "[\x1b[35mR\x1b[0m]",
            .visual => "[\x1b[36mv\x1b[0m]",
            .visual_line => "[\x1b[36mV\x1b[0m]",
        };
    }
};

pub const KeyResult = enum {
    consumed, // key handled, update display
    mode_changed, // mode changed, update prompt
    need_more, // waiting for more keys (e.g., 'g' prefix)
    unhandled, // key not handled by vim
    execute, // enter pressed in normal mode - execute command
};

fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_' or c >= 0x80;
}

fn isPunct(c: u8) bool {
    return !isWordChar(c) and !isWhitespace(c);
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

// tests
test "vim basic insert mode" {
    var buf = editor.EditBuffer{};
    var vim = Vim{};

    // start in insert mode
    try std.testing.expectEqual(Mode.insert, vim.mode);

    // type some text
    _ = vim.handleKey(&buf, 'h');
    _ = vim.handleKey(&buf, 'i');
    try std.testing.expectEqualStrings("hi", buf.slice());

    // escape to normal
    _ = vim.handleKey(&buf, 27);
    try std.testing.expectEqual(Mode.normal, vim.mode);
}

test "vim motions" {
    var buf = editor.EditBuffer{};
    var vim = Vim{ .mode = .normal };

    buf.set("hello world");
    buf.cursor = 0;

    // w - word forward
    _ = vim.handleKey(&buf, 'w');
    try std.testing.expectEqual(@as(u16, 6), buf.cursor);

    // b - word backward
    _ = vim.handleKey(&buf, 'b');
    try std.testing.expectEqual(@as(u16, 0), buf.cursor);

    // $ - end of line
    _ = vim.handleKey(&buf, '$');
    try std.testing.expectEqual(@as(u16, 11), buf.cursor);

    // 0 - start of line
    _ = vim.handleKey(&buf, '0');
    try std.testing.expectEqual(@as(u16, 0), buf.cursor);
}

test "vim delete word" {
    var buf = editor.EditBuffer{};
    var vim = Vim{ .mode = .normal };

    buf.set("hello world");
    buf.cursor = 0;

    // dw - delete word
    _ = vim.handleKey(&buf, 'd');
    _ = vim.handleKey(&buf, 'w');
    try std.testing.expectEqualStrings("world", buf.slice());
}

test "vim ciw - change inner word" {
    var buf = editor.EditBuffer{};
    var vi = Vim{ .mode = .normal };

    buf.set("hello world");
    buf.cursor = 2; // in middle of "hello"

    // ciw - change inner word
    _ = vi.handleKey(&buf, 'c');
    _ = vi.handleKey(&buf, 'i');
    _ = vi.handleKey(&buf, 'w');

    try std.testing.expectEqualStrings(" world", buf.slice());
    try std.testing.expectEqual(Mode.insert, vi.mode);
}

test "vim diw - delete inner word" {
    var buf = editor.EditBuffer{};
    var vi = Vim{ .mode = .normal };

    buf.set("hello world");
    buf.cursor = 7; // in middle of "world"

    // diw - delete inner word
    _ = vi.handleKey(&buf, 'd');
    _ = vi.handleKey(&buf, 'i');
    _ = vi.handleKey(&buf, 'w');

    try std.testing.expectEqualStrings("hello ", buf.slice());
}

test "vim ci\" - change inside quotes" {
    var buf = editor.EditBuffer{};
    var vi = Vim{ .mode = .normal };

    buf.set("echo \"hello world\"");
    buf.cursor = 8; // inside quotes

    // ci" - change inside quotes
    _ = vi.handleKey(&buf, 'c');
    _ = vi.handleKey(&buf, 'i');
    _ = vi.handleKey(&buf, '"');

    try std.testing.expectEqualStrings("echo \"\"", buf.slice());
    try std.testing.expectEqual(Mode.insert, vi.mode);
}

test "vim visual mode" {
    var buf = editor.EditBuffer{};
    var vi = Vim{ .mode = .normal };

    buf.set("hello world");
    buf.cursor = 0;

    // v - enter visual
    _ = vi.handleKey(&buf, 'v');
    try std.testing.expectEqual(Mode.visual, vi.mode);

    // move right to select "hello"
    _ = vi.handleKey(&buf, 'e');
    try std.testing.expectEqual(@as(u16, 4), buf.cursor);

    // d - delete selection
    _ = vi.handleKey(&buf, 'd');
    try std.testing.expectEqualStrings(" world", buf.slice());
    try std.testing.expectEqual(Mode.normal, vi.mode);
}
