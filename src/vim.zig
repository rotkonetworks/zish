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

/// find-char motion kind (f/F/t/T)
pub const FindKind = enum { f, F, t, T };

fn findKindFor(key: u8) FindKind {
    return switch (key) {
        'f' => .f,
        'F' => .F,
        't' => .t,
        'T' => .T,
        else => unreachable,
    };
}

/// ',' reverses the direction of the last f/F/t/T (f<->F, t<->T)
fn oppositeFindKind(k: FindKind) FindKind {
    return switch (k) {
        .f => .F,
        .F => .f,
        .t => .T,
        .T => .t,
    };
}

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

    // find-char motions: f/F/t/T await one more key (the target char).
    // pending_op (if any) stays set while we wait, same pattern as
    // awaiting_text_obj, so the eventual target char can be applied either
    // as a plain motion or as an operator range.
    awaiting_find: bool = false,
    find_pending_kind: FindKind = .f,
    find_pending_count: u16 = 1,
    // last f/F/t/T for ';' (repeat) and ',' (repeat reversed). ',' does not
    // overwrite this — only a fresh f/F/t/T does.
    last_find_kind: ?FindKind = null,
    last_find_char: u8 = 0,

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
        // find-char target char (f/F/t/T's second keystroke). Checked before
        // the numeric-prefix parsing below because the target itself can be
        // a digit (e.g. `f0`, `df3`) — it must never be swallowed as a count.
        // This also serves the operator-integrated case (`df{char}`, etc.):
        // pending_op stays set while awaiting_find is true, so when the
        // target arrives here we still see it and route to executeOperator.
        if (self.awaiting_find) {
            self.awaiting_find = false;
            const kind = self.find_pending_kind;
            const count = self.find_pending_count;
            const result = computeFind(buf, kind, key, count, false) orelse {
                // not found: cancel any pending operator, no-op motion
                self.pending_op = .none;
                self.last_count = 0;
                return .consumed;
            };
            self.last_find_kind = kind;
            self.last_find_char = key;
            if (self.pending_op != .none) {
                const was_change = self.pending_op == .change;
                self.executeOperator(buf, result.op_start, result.op_end);
                return if (was_change) .mode_changed else .consumed;
            }
            buf.cursor = result.cursor;
            return .consumed;
        }

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

        // numeric prefix. Saturating: an interactive line is at most
        // LINE_BUF_SIZE chars, so a huge typed count can never be honored
        // anyway — better to clamp than to overflow-panic (--release=safe
        // has overflow checks on) on a stray run of digits.
        if (key >= '1' and key <= '9') {
            self.count = self.count *| 10 +| (key - '0');
            return .consumed;
        }
        if (key == '0' and self.count > 0) {
            self.count = self.count *| 10;
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
            '%' => {
                self.preferred_col_set = false;
                if (findPercentMatch(buf, buf.cursor)) |idx| buf.cursor = idx;
                return .consumed;
            },
            'f', 'F', 't', 'T' => {
                self.awaiting_find = true;
                self.find_pending_kind = findKindFor(key);
                self.find_pending_count = count;
                return .need_more;
            },
            ';' => {
                self.preferred_col_set = false;
                if (self.doFindRepeat(buf, false, count)) |r| buf.cursor = r.cursor;
                return .consumed;
            },
            ',' => {
                self.preferred_col_set = false;
                if (self.doFindRepeat(buf, true, count)) |r| buf.cursor = r.cursor;
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
                        _ = buf.insert(' ');
                    }
                    buf.cursor = old;
                }
                return .consumed;
            },

            // single char ops
            'x' => {
                buf.saveUndo();
                for (0..count) |_| {
                    if (buf.cursor < buf.len) {
                        _ = buf.deleteForward();
                    }
                }
                return .consumed;
            },
            'X' => {
                buf.saveUndo();
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
                buf.saveUndo();
                // delete line content, enter insert
                buf.moveLineStart();
                while (buf.cursor < buf.len and buf.text[buf.cursor] != '\n') {
                    _ = buf.deleteForward();
                }
                self.mode = .insert;
                return .mode_changed;
            },
            'C' => {
                buf.saveUndo();
                // change to end of line
                while (buf.cursor < buf.len and buf.text[buf.cursor] != '\n') {
                    _ = buf.deleteForward();
                }
                self.mode = .insert;
                return .mode_changed;
            },
            'D' => {
                buf.saveUndo();
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

            // undo
            'u' => {
                if (buf.undo()) return .consumed;
                return .consumed;
            },
            18 => { // Ctrl-R — redo
                if (buf.redo()) return .consumed;
                return .consumed;
            },

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
                buf.saveUndo();
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
            const was_change = self.pending_op == .change;
            if (self.findTextObject(buf, key, self.text_obj_inner)) |range| {
                if (range.start == range.end) {
                    // Empty object (e.g. `ci"` on `""`): nothing to delete or
                    // yank, but `c` still enters insert right at the (empty)
                    // location — matches vim.
                    self.pending_op = .none;
                    if (was_change) {
                        buf.saveUndo();
                        buf.cursor = range.start;
                        self.mode = .insert;
                        return .mode_changed;
                    }
                    return .consumed;
                }
                self.executeOperator(buf, range.start, range.end);
                return if (was_change) .mode_changed else .consumed;
            }
            self.pending_op = .none;
            return .consumed;
        }

        // Note: there is deliberately no `awaiting_find` branch here. The
        // find-char target char is intercepted at the very top of
        // handleNormal (before pending_g/digit-prefix/pending_op dispatch),
        // so by the time control could reach this function with
        // awaiting_find still true, handleNormal would already have
        // consumed the key itself — this function never sees it.

        // doubled operator (dd, cc, yy) - operate on whole line
        if ((self.pending_op == .delete and key == 'd') or
            (self.pending_op == .change and key == 'c') or
            (self.pending_op == .yank and key == 'y'))
        {
            // Consume any count typed after the operator (e.g. "d2d") so it
            // doesn't leak into the next keystroke. Repeating over multiple
            // lines for "NdN" is a separate, pre-existing limitation (this
            // branch only ever touches the current line) — out of scope here.
            _ = self.getCount();
            buf.moveLineStart();
            const line_start = buf.cursor;
            buf.moveLineEnd();
            if (buf.cursor < buf.len and buf.text[buf.cursor] == '\n') {
                _ = buf.moveRight(); // include newline
            }
            end = buf.cursor;
            buf.cursor = line_start;

            const was_change = self.pending_op == .change;
            self.executeOperator(buf, line_start, end);
            return if (was_change) .mode_changed else .consumed;
        }

        // motion keys — combine the count typed before the operator
        // (last_count, e.g. "2d...") with one typed after it (e.g. "d2w");
        // vim multiplies them. getCount() consumes self.count (which digit
        // keys accumulate even while an operator is pending — see
        // handleNormal's numeric-prefix block, which runs before the
        // pending_op dispatch).
        const post_count = self.getCount();
        const count = (if (self.last_count > 0) self.last_count else 1) *| post_count;
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
            '%' => {
                if (findPercentMatch(buf, start)) |idx| {
                    end = idx + 1; // inclusive of both brackets
                } else {
                    self.pending_op = .none;
                    self.last_count = 0;
                    return .consumed;
                }
            },
            'f', 'F', 't', 'T' => {
                self.awaiting_find = true;
                self.find_pending_kind = findKindFor(key);
                self.find_pending_count = count;
                return .need_more;
            },
            ';', ',' => {
                const reverse = key == ',';
                const r = self.doFindRepeat(buf, reverse, count) orelse {
                    self.pending_op = .none;
                    self.last_count = 0;
                    return .consumed;
                };
                const was_change = self.pending_op == .change;
                self.executeOperator(buf, r.op_start, r.op_end);
                return if (was_change) .mode_changed else .consumed;
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
        const was_change = self.pending_op == .change;
        self.executeOperator(buf, op_start, op_end);
        return if (was_change) .mode_changed else .consumed;
    }

    const Range = struct { start: u16, end: u16 };

    /// find text object boundaries. Returns null when no object is found
    /// (distinct from a found-but-empty object, e.g. `ci""` on `""`, which
    /// returns a valid zero-width Range).
    fn findTextObject(self: *Self, buf: *editor.EditBuffer, obj: u8, inner: bool) ?Range {
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
                return findQuoteObject(buf, obj, cursor, inner);
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
            else => return null,
        }
    }

    /// Quote text object, parity-aware: scans the current line from its
    /// start, pairing quotes (1st&2nd, 3rd&4th, ...) rather than just taking
    /// "nearest quote at-or-before cursor" as the opener. That naive approach
    /// mispairs e.g. `a "b" "c"` with the cursor on the space between the two
    /// strings (it would pair the close of the first string with the open of
    /// the second). Matches vim: if the cursor sits before or inside a pair,
    /// or exactly on its closing quote, that pair is the target; otherwise
    /// scanning continues to the next pair on the line.
    fn findQuoteObject(buf: *const editor.EditBuffer, quote: u8, cursor: u16, inner: bool) ?Range {
        const text = buf.text[0..buf.len];
        var line_start: u16 = cursor;
        while (line_start > 0 and text[line_start - 1] != '\n') line_start -= 1;
        var line_end: u16 = cursor;
        while (line_end < buf.len and text[line_end] != '\n') line_end += 1;

        var i: u16 = line_start;
        while (i < line_end) {
            if (text[i] != quote) {
                i += 1;
                continue;
            }
            const open = i;
            var j: u16 = open + 1;
            while (j < line_end and text[j] != quote) j += 1;
            if (j >= line_end) return null; // unterminated quote on this line
            const close = j;
            if (cursor <= close) {
                if (inner) return .{ .start = open + 1, .end = close };
                return .{ .start = open, .end = close + 1 };
            }
            i = close + 1;
        }
        return null;
    }

    fn findMatchingPair(self: *const Self, buf: *editor.EditBuffer, open: u8, close: u8) ?Range {
        const text = buf.text[0..buf.len];
        const cursor = buf.cursor;
        if (buf.len == 0) return null;

        // Search backward for the opening bracket enclosing the cursor. If
        // the cursor sits ON the closing bracket, that bracket is not part
        // of the backward scan itself — start looking just before it, or a
        // naive scan sees `)` first (depth 1), then the matching `(`
        // immediately after decrements right back to a false "not found"
        // (previously: `di)` with the cursor on `)` silently did nothing).
        const scan_from: i32 = if (cursor < buf.len and text[cursor] == close)
            @as(i32, @intCast(cursor)) - 1
        else
            @intCast(cursor);

        var depth: i16 = 0;
        var start: u16 = cursor;
        var found = false;
        var i: i32 = scan_from;
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

        if (!found) return null;

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
        if (depth != 0) return null; // unterminated

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

        // Save undo once, here, for every destructive operator — the sole
        // owner, so a single dw/cw/df{x}/text-object edit costs exactly one
        // undo level (call sites used to save it themselves before invoking
        // this, which double-booked levels once more paths funneled through
        // here). Must run before mutating buf below.
        if (op == .delete or op == .change) buf.saveUndo();

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

    // ── find-char motions (f/F/t/T, ;/,) ──

    const FindResult = struct { cursor: u16, op_start: u16, op_end: u16 };

    /// Index of the nth `target` strictly after `from` on the same line
    /// (f/F/t/T never cross a newline), or null if not found.
    fn findCharForward(buf: *const editor.EditBuffer, from: u16, target: u8, count: u16) ?u16 {
        var pos: u16 = from;
        var remaining = count;
        while (remaining > 0) : (remaining -= 1) {
            pos += 1;
            while (true) {
                if (pos >= buf.len or buf.text[pos] == '\n') return null;
                if (buf.text[pos] == target) break;
                pos += 1;
            }
        }
        return pos;
    }

    /// Index of the nth `target` strictly before `from` on the same line.
    fn findCharBackward(buf: *const editor.EditBuffer, from: u16, target: u8, count: u16) ?u16 {
        var pos: u16 = from;
        var remaining = count;
        while (remaining > 0) : (remaining -= 1) {
            if (pos == 0) return null;
            pos -= 1;
            while (true) {
                if (buf.text[pos] == '\n') return null;
                if (buf.text[pos] == target) break;
                if (pos == 0) return null;
                pos -= 1;
            }
        }
        return pos;
    }

    /// Compute both the plain-motion destination and the operator range for
    /// one f/F/t/T application. Inclusivity table (why each op_start/op_end
    /// is what it is):
    ///   f  cursor lands ON the char;      operator range includes it.
    ///   F  cursor lands ON the char;      operator range includes it
    ///      (backward direction — op_start/op_end below already order it).
    ///   t  cursor lands just BEFORE it;   operator range excludes it.
    ///   T  cursor lands just AFTER it;    operator range excludes it.
    /// `is_repeat` is true only for ';'/',': vim advances one extra position
    /// before searching so repeating t/T doesn't get stuck re-finding the
    /// same adjacent match it already stopped next to.
    fn computeFind(buf: *editor.EditBuffer, kind: FindKind, target: u8, count: u16, is_repeat: bool) ?FindResult {
        const start = buf.cursor;
        return switch (kind) {
            .f => blk: {
                const idx = findCharForward(buf, start, target, count) orelse break :blk null;
                break :blk .{ .cursor = idx, .op_start = start, .op_end = idx + 1 };
            },
            .F => blk: {
                const idx = findCharBackward(buf, start, target, count) orelse break :blk null;
                break :blk .{ .cursor = idx, .op_start = idx, .op_end = start };
            },
            .t => blk: {
                if (is_repeat and start + 1 >= buf.len) break :blk null;
                const from = if (is_repeat) start + 1 else start;
                const idx = findCharForward(buf, from, target, count) orelse break :blk null;
                break :blk .{ .cursor = idx - 1, .op_start = start, .op_end = idx };
            },
            .T => blk: {
                if (is_repeat and start == 0) break :blk null;
                const from = if (is_repeat) start - 1 else start;
                const idx = findCharBackward(buf, from, target, count) orelse break :blk null;
                break :blk .{ .cursor = idx + 1, .op_start = idx + 1, .op_end = start };
            },
        };
    }

    /// ';' (reverse=false) / ',' (reverse=true) — repeat the last f/F/t/T.
    /// Returns null if no find has happened yet.
    fn doFindRepeat(self: *Self, buf: *editor.EditBuffer, reverse: bool, count: u16) ?FindResult {
        const kind = self.last_find_kind orelse return null;
        const eff_kind = if (reverse) oppositeFindKind(kind) else kind;
        return computeFind(buf, eff_kind, self.last_find_char, count, true);
    }

    // ── '%' matching-bracket motion ──

    fn isBracket(c: u8) bool {
        return c == '(' or c == ')' or c == '[' or c == ']' or c == '{' or c == '}';
    }

    fn matchForward(buf: *const editor.EditBuffer, from: u16, open: u8, close: u8) ?u16 {
        var depth: i16 = 0;
        var i = from;
        while (i < buf.len) : (i += 1) {
            if (buf.text[i] == open) {
                depth += 1;
            } else if (buf.text[i] == close) {
                depth -= 1;
                if (depth == 0) return i;
            }
        }
        return null;
    }

    fn matchBackward(buf: *const editor.EditBuffer, from: u16, open: u8, close: u8) ?u16 {
        var depth: i16 = 0;
        var i: i32 = @intCast(from);
        while (i >= 0) : (i -= 1) {
            const idx: u16 = @intCast(i);
            if (buf.text[idx] == close) {
                depth += 1;
            } else if (buf.text[idx] == open) {
                depth -= 1;
                if (depth == 0) return idx;
            }
        }
        return null;
    }

    /// vim '%': search forward on the current line from `cursor` for the
    /// first bracket char, then jump to its match (forward if it's an
    /// opener, backward if it's a closer).
    fn findPercentMatch(buf: *const editor.EditBuffer, cursor: u16) ?u16 {
        if (buf.len == 0) return null;
        const text = buf.text[0..buf.len];
        var line_end = cursor;
        while (line_end < buf.len and text[line_end] != '\n') line_end += 1;

        var i = cursor;
        while (i < line_end and !isBracket(text[i])) i += 1;
        if (i >= line_end) return null;

        return switch (text[i]) {
            '(' => matchForward(buf, i, '(', ')'),
            '[' => matchForward(buf, i, '[', ']'),
            '{' => matchForward(buf, i, '{', '}'),
            ')' => matchBackward(buf, i, '(', ')'),
            ']' => matchBackward(buf, i, '[', ']'),
            '}' => matchBackward(buf, i, '{', '}'),
            else => null,
        };
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

// ── find-char motions: f/F/t/T, ;/, ──

test "vim fx - find char forward, cursor lands on it" {
    var buf = editor.EditBuffer{};
    var vi = Vim{ .mode = .normal };
    buf.set("hello world");
    buf.cursor = 0;

    _ = vi.handleKey(&buf, 'f');
    _ = vi.handleKey(&buf, 'o');
    try std.testing.expectEqual(@as(u16, 4), buf.cursor); // first 'o' in "hello"
}

test "vim Fx - find char backward" {
    var buf = editor.EditBuffer{};
    var vi = Vim{ .mode = .normal };
    buf.set("hello world");
    buf.cursor = 10; // 'd'

    _ = vi.handleKey(&buf, 'F');
    _ = vi.handleKey(&buf, 'o');
    try std.testing.expectEqual(@as(u16, 7), buf.cursor); // 'o' in "world"
}

test "vim tx - find char forward, cursor lands just before it" {
    var buf = editor.EditBuffer{};
    var vi = Vim{ .mode = .normal };
    buf.set("hello world");
    buf.cursor = 0;

    _ = vi.handleKey(&buf, 't');
    _ = vi.handleKey(&buf, 'o');
    try std.testing.expectEqual(@as(u16, 3), buf.cursor); // just before 'o' at 4
}

test "vim Tx - find char backward, cursor lands just after it" {
    var buf = editor.EditBuffer{};
    var vi = Vim{ .mode = .normal };
    buf.set("hello world");
    buf.cursor = 10;

    _ = vi.handleKey(&buf, 'T');
    _ = vi.handleKey(&buf, 'o');
    try std.testing.expectEqual(@as(u16, 8), buf.cursor); // just after 'o' at 7
}

test "vim 3fa - count with find" {
    var buf = editor.EditBuffer{};
    var vi = Vim{ .mode = .normal };
    buf.set("banana");
    buf.cursor = 0;

    _ = vi.handleKey(&buf, '3');
    _ = vi.handleKey(&buf, 'f');
    _ = vi.handleKey(&buf, 'a');
    try std.testing.expectEqual(@as(u16, 5), buf.cursor); // 3rd 'a' -> index 5
}

test "vim dfx - delete through found char, inclusive" {
    var buf = editor.EditBuffer{};
    var vi = Vim{ .mode = .normal };
    buf.set("hello, world");
    buf.cursor = 0;

    _ = vi.handleKey(&buf, 'd');
    _ = vi.handleKey(&buf, 'f');
    _ = vi.handleKey(&buf, ',');
    try std.testing.expectEqualStrings(" world", buf.slice());
}

test "vim dtx - delete up to found char, exclusive" {
    var buf = editor.EditBuffer{};
    var vi = Vim{ .mode = .normal };
    buf.set("hello, world");
    buf.cursor = 0;

    _ = vi.handleKey(&buf, 'd');
    _ = vi.handleKey(&buf, 't');
    _ = vi.handleKey(&buf, ',');
    try std.testing.expectEqualStrings(", world", buf.slice());
}

test "vim d2fx - count combines with operator find" {
    var buf = editor.EditBuffer{};
    var vi = Vim{ .mode = .normal };
    buf.set("a,b,c,d");
    buf.cursor = 0;

    _ = vi.handleKey(&buf, 'd');
    _ = vi.handleKey(&buf, '2');
    _ = vi.handleKey(&buf, 'f');
    _ = vi.handleKey(&buf, ',');
    try std.testing.expectEqualStrings("c,d", buf.slice());
}

test "vim cfx - change through found char enters insert" {
    var buf = editor.EditBuffer{};
    var vi = Vim{ .mode = .normal };
    buf.set("hello, world");
    buf.cursor = 0;

    _ = vi.handleKey(&buf, 'c');
    _ = vi.handleKey(&buf, 'f');
    const r = vi.handleKey(&buf, ',');
    try std.testing.expectEqual(KeyResult.mode_changed, r);
    try std.testing.expectEqual(Mode.insert, vi.mode);
    try std.testing.expectEqualStrings(" world", buf.slice());
}

test "vim ; repeats last find, , reverses it" {
    var buf = editor.EditBuffer{};
    var vi = Vim{ .mode = .normal };
    buf.set("a,b,c,d");
    buf.cursor = 0;

    _ = vi.handleKey(&buf, 'f');
    _ = vi.handleKey(&buf, ',');
    try std.testing.expectEqual(@as(u16, 1), buf.cursor);

    _ = vi.handleKey(&buf, ';');
    try std.testing.expectEqual(@as(u16, 3), buf.cursor);

    _ = vi.handleKey(&buf, ';');
    try std.testing.expectEqual(@as(u16, 5), buf.cursor);

    // ',' reverses direction: from index 5, find backward -> index 3
    _ = vi.handleKey(&buf, ',');
    try std.testing.expectEqual(@as(u16, 3), buf.cursor);
}

test "vim ; on t advances past an adjacent match" {
    var buf = editor.EditBuffer{};
    var vi = Vim{ .mode = .normal };
    buf.set("a,b,c");
    buf.cursor = 0;

    _ = vi.handleKey(&buf, 't');
    _ = vi.handleKey(&buf, ',');
    try std.testing.expectEqual(@as(u16, 0), buf.cursor); // already before first ','

    // naive repeat would re-find the same comma and get stuck at 0
    _ = vi.handleKey(&buf, ';');
    try std.testing.expectEqual(@as(u16, 2), buf.cursor); // just before second ','
}

// ── % matching bracket ──

test "vim % jumps to matching paren" {
    var buf = editor.EditBuffer{};
    var vi = Vim{ .mode = .normal };
    buf.set("echo (a b) c");
    buf.cursor = 0;

    _ = vi.handleKey(&buf, '%');
    try std.testing.expectEqual(@as(u16, 9), buf.cursor); // the ')'

    _ = vi.handleKey(&buf, '%');
    try std.testing.expectEqual(@as(u16, 5), buf.cursor); // back to '('
}

test "vim d% deletes through matching bracket" {
    var buf = editor.EditBuffer{};
    var vi = Vim{ .mode = .normal };
    buf.set("echo (a b) c");
    buf.cursor = 5; // on '('

    _ = vi.handleKey(&buf, 'd');
    _ = vi.handleKey(&buf, '%');
    try std.testing.expectEqualStrings("echo  c", buf.slice());
}

// ── undo / redo ──

test "vim u then Ctrl-R round-trips a change" {
    var buf = editor.EditBuffer{};
    var vi = Vim{ .mode = .normal };
    buf.set("hello world");
    buf.cursor = 0;

    _ = vi.handleKey(&buf, 'd');
    _ = vi.handleKey(&buf, 'w');
    try std.testing.expectEqualStrings("world", buf.slice());

    _ = vi.handleKey(&buf, 'u');
    try std.testing.expectEqualStrings("hello world", buf.slice());

    _ = vi.handleKey(&buf, 18); // Ctrl-R
    try std.testing.expectEqualStrings("world", buf.slice());
}

test "vim multi-level undo/redo" {
    var buf = editor.EditBuffer{};
    var vi = Vim{ .mode = .normal };
    buf.set("aaa bbb ccc");
    buf.cursor = 0;

    _ = vi.handleKey(&buf, 'd');
    _ = vi.handleKey(&buf, 'w');
    try std.testing.expectEqualStrings("bbb ccc", buf.slice());

    _ = vi.handleKey(&buf, 'd');
    _ = vi.handleKey(&buf, 'w');
    try std.testing.expectEqualStrings("ccc", buf.slice());

    _ = vi.handleKey(&buf, 'u');
    try std.testing.expectEqualStrings("bbb ccc", buf.slice());
    _ = vi.handleKey(&buf, 'u');
    try std.testing.expectEqualStrings("aaa bbb ccc", buf.slice());

    _ = vi.handleKey(&buf, 18);
    try std.testing.expectEqualStrings("bbb ccc", buf.slice());
    _ = vi.handleKey(&buf, 18);
    try std.testing.expectEqualStrings("ccc", buf.slice());
}

test "vim d2d does not leak the count into the next keystroke" {
    var buf = editor.EditBuffer{};
    var vi = Vim{ .mode = .normal };
    buf.set("hello");
    buf.cursor = 0;

    // d2d: doubled-op branch, with a count typed *after* the operator. If
    // that count were left in self.count instead of being consumed, it
    // would silently apply to the next unrelated keystroke.
    _ = vi.handleKey(&buf, 'd');
    _ = vi.handleKey(&buf, '2');
    _ = vi.handleKey(&buf, 'd');
    try std.testing.expectEqualStrings("", buf.slice()); // single line deleted

    buf.set("hello");
    buf.cursor = 0;
    _ = vi.handleKey(&buf, 'x'); // a leaked count of 2 would delete "he"
    try std.testing.expectEqualStrings("ello", buf.slice());
}

// ── text object fixes ──

test "vim di) with cursor on the closing paren" {
    var buf = editor.EditBuffer{};
    var vi = Vim{ .mode = .normal };
    buf.set("echo (abc)");
    buf.cursor = 9; // on ')'

    _ = vi.handleKey(&buf, 'd');
    _ = vi.handleKey(&buf, 'i');
    _ = vi.handleKey(&buf, ')');
    try std.testing.expectEqualStrings("echo ()", buf.slice());
}

test "vim ci( on the opening paren enters insert" {
    var buf = editor.EditBuffer{};
    var vi = Vim{ .mode = .normal };
    buf.set("echo (abc)");
    buf.cursor = 5; // on '('

    _ = vi.handleKey(&buf, 'c');
    _ = vi.handleKey(&buf, 'i');
    _ = vi.handleKey(&buf, '(');
    try std.testing.expectEqualStrings("echo ()", buf.slice());
    try std.testing.expectEqual(Mode.insert, vi.mode);
}

test "vim di\" picks the pair after the cursor, not a mispaired neighbor" {
    var buf = editor.EditBuffer{};
    var vi = Vim{ .mode = .normal };
    buf.set("a \"b\" \"c\"");
    buf.cursor = 5; // the space between the two quoted strings

    _ = vi.handleKey(&buf, 'd');
    _ = vi.handleKey(&buf, 'i');
    _ = vi.handleKey(&buf, '"');
    try std.testing.expectEqualStrings("a \"b\" \"\"", buf.slice());
}

test "vim ci\" on empty quotes enters insert without deleting" {
    var buf = editor.EditBuffer{};
    var vi = Vim{ .mode = .normal };
    buf.set("echo \"\"");
    buf.cursor = 6; // between the quotes

    const r1 = vi.handleKey(&buf, 'c');
    _ = r1;
    _ = vi.handleKey(&buf, 'i');
    const r = vi.handleKey(&buf, '"');
    try std.testing.expectEqual(KeyResult.mode_changed, r);
    try std.testing.expectEqual(Mode.insert, vi.mode);
    try std.testing.expectEqualStrings("echo \"\"", buf.slice());
    try std.testing.expectEqual(@as(u16, 6), buf.cursor);
}

test "vim da( removes the parens and their contents" {
    var buf = editor.EditBuffer{};
    var vi = Vim{ .mode = .normal };
    buf.set("echo (abc) tail");
    buf.cursor = 6; // inside parens

    _ = vi.handleKey(&buf, 'd');
    _ = vi.handleKey(&buf, 'a');
    _ = vi.handleKey(&buf, '(');
    try std.testing.expectEqualStrings("echo  tail", buf.slice());
}

test "vim caw changes a word and its trailing space" {
    var buf = editor.EditBuffer{};
    var vi = Vim{ .mode = .normal };
    buf.set("hello world");
    buf.cursor = 0;

    _ = vi.handleKey(&buf, 'c');
    _ = vi.handleKey(&buf, 'a');
    const r = vi.handleKey(&buf, 'w');
    try std.testing.expectEqual(KeyResult.mode_changed, r);
    try std.testing.expectEqualStrings("world", buf.slice());
}
