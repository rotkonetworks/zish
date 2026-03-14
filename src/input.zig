// input.zig - Key handling and input modes for zish
const std = @import("std");

// Control key helper
pub fn ctrlKey(comptime char_code: u8) u8 {
    return char_code & 0x1F;
}

// Control key constants
pub const CTRL_C = ctrlKey('c');
pub const CTRL_G = ctrlKey('g');
pub const CTRL_L = ctrlKey('l');
pub const CTRL_D = ctrlKey('d');
pub const CTRL_R = ctrlKey('r');
pub const CTRL_Z = ctrlKey('z');

// Vim modes
pub const VimMode = enum {
    normal,
    insert,
};

// Movement types
pub const WordBoundary = enum {
    word,      // lowercase w/b - stop at punctuation
    WORD,      // uppercase W/B - only whitespace
    word_end,  // e - to end of word
    WORD_end,  // E - to end of WORD
};

pub const MoveCursorAction = union(enum) {
    relative: isize,
    absolute: usize,
    to_line_start,
    to_line_end,
    word_forward: WordBoundary,
    word_backward: WordBoundary,
    line_up,
    line_down,
};

pub const HistoryDirection = enum {
    up,
    down,
};

pub const SearchDirection = enum {
    forward,
    backward,
};

pub const CycleDirection = enum {
    forward,
    backward,
};

pub const DeleteAction = union(enum) {
    char_under_cursor,
    to_line_end,
    char_at: usize,
};

pub const YankAction = union(enum) {
    line,
    selection: struct { start: usize, end: usize },
};

pub const PasteAction = enum {
    after_cursor,
    before_cursor,
};

pub const InsertAtPosition = enum {
    cursor,
    after_cursor,
    line_end,
    line_start,
};

pub const OpenLineDirection = enum {
    below, // o - open line below
    above, // O - open line above
};

pub const VisualModeType = enum {
    char,  // v
    line,  // V
};

pub const VimModeAction = union(enum) {
    set_mode: VimMode,
    enter_visual: VisualModeType,
};

// Main action type
pub const Action = union(enum) {
    none,
    cancel,
    exit_shell,
    execute_command,
    redraw_line,
    clear_screen,
    vim_mode: VimModeAction,
    input_char: u8,
    backspace,
    delete_word_backward,
    delete: DeleteAction,
    tap_complete,
    cycle_complete: CycleDirection,
    cycle_ghost: CycleDirection,
    move_cursor: MoveCursorAction,
    history_nav: HistoryDirection,
    enter_search_mode: SearchDirection,
    exit_search_mode: bool,
    yank: YankAction,
    paste: PasteAction,
    insert_at_position: InsertAtPosition,
    open_line: OpenLineDirection,
    undo,
    enter_paste_mode,
    exit_paste_mode,
    suspend_shell,
    cancel_agent, // Ctrl+G: cancel agent work
    // readline bindings
    kill_to_beginning, // Ctrl+U: kill from cursor to start of line
    kill_to_end, // Ctrl+K: kill from cursor to end of line
    yank_killed, // Ctrl+Y: paste kill buffer
    transpose_chars, // Ctrl+T: swap char before cursor with char at cursor
    insert_last_arg, // Alt+.: insert last argument from previous command
};

const CTRL_W = 23;

/// Get action for insert mode keypress
pub fn insertModeAction(char: u8) Action {
    return switch (char) {
        '\n' => .execute_command,
        CTRL_C => .cancel,
        CTRL_L => .clear_screen,
        CTRL_D => .exit_shell,
        CTRL_R => .{ .enter_search_mode = .backward }, // reverse history search
        CTRL_G => .cancel_agent,
        CTRL_Z => .suspend_shell,
        CTRL_W => .delete_word_backward,
        '\t' => .tap_complete,
        8, 127 => .backspace,
        32...126 => .{ .input_char = char },
        else => .none,
    };
}

/// Get action for vim normal mode keypress
pub fn normalModeAction(char: u8) Action {
    return switch (char) {
        'h' => .{ .move_cursor = .{ .relative = -1 } },
        'l' => .{ .move_cursor = .{ .relative = 1 } },
        '0' => .{ .move_cursor = .to_line_start },
        '$' => .{ .move_cursor = .to_line_end },

        'w' => .{ .move_cursor = .{ .word_forward = .word } },
        'W' => .{ .move_cursor = .{ .word_forward = .WORD } },
        'b' => .{ .move_cursor = .{ .word_backward = .word } },
        'B' => .{ .move_cursor = .{ .word_backward = .WORD } },
        'e' => .{ .move_cursor = .{ .word_forward = .word_end } },
        'E' => .{ .move_cursor = .{ .word_forward = .WORD_end } },

        'j' => .{ .move_cursor = .line_down },
        'k' => .{ .move_cursor = .line_up },

        'i' => .{ .vim_mode = .{ .set_mode = .insert } },

        'a' => .{ .insert_at_position = .after_cursor },
        'A' => .{ .insert_at_position = .line_end },
        'I' => .{ .insert_at_position = .line_start },

        'o' => .{ .open_line = .below },
        'O' => .{ .open_line = .above },

        'x' => .{ .delete = .char_under_cursor },
        'D' => .{ .delete = .to_line_end },

        'p' => .{ .paste = .after_cursor },
        'P' => .{ .paste = .before_cursor },

        'y' => .{ .yank = .line },

        'u' => .undo,

        '/' => .{ .enter_search_mode = .forward },
        '?' => .{ .enter_search_mode = .backward },

        '\n' => .execute_command,

        CTRL_C => .cancel,
        CTRL_G => .cancel_agent,
        CTRL_Z => .suspend_shell,

        else => .none,
    };
}

/// Parse escape sequence from stdin
pub fn parseEscapeSequence() !Action {
    const stdin = std.io.getStdIn();
    var temp_buf: [3]u8 = undefined;

    const flags = std.posix.fcntl(stdin.handle, .F_GETFL, 0) catch 0;
    _ = std.posix.fcntl(stdin.handle, .F_SETFL, @as(u32, @bitCast(flags)) | @as(u32, @bitCast(@as(i32, std.posix.O.NONBLOCK)))) catch {};
    defer _ = std.posix.fcntl(stdin.handle, .F_SETFL, flags) catch {};

    std.time.sleep(10 * std.time.ns_per_ms);

    const bytes_read = stdin.read(&temp_buf) catch |err| {
        if (err == error.WouldBlock) {
            return .{ .vim_mode = .{ .set_mode = .normal } };
        }
        return .none;
    };

    if (bytes_read < 2) return .none;

    if (temp_buf[0] == '[') {
        return switch (temp_buf[1]) {
            'A' => .{ .move_cursor = .line_up },
            'B' => .{ .move_cursor = .line_down },
            'C' => .{ .move_cursor = .{ .relative = 1 } },
            'D' => .{ .move_cursor = .{ .relative = -1 } },
            'H' => .{ .move_cursor = .to_line_start },
            'F' => .{ .move_cursor = .to_line_end },
            'Z' => .{ .cycle_complete = .backward },
            '3' => if (bytes_read >= 3 and temp_buf[2] == '~')
                .{ .delete = .char_under_cursor }
            else
                .none,
            '1' => handleExtendedSequence(stdin, temp_buf[2]),
            else => .none,
        };
    }

    return .none;
}

fn handleExtendedSequence(stdin: std.fs.File, first_byte: u8) Action {
    if (first_byte != ';') return .none;

    var temp_buf: [2]u8 = undefined;
    const modifier_read = stdin.read(temp_buf[0..1]) catch return .none;
    if (modifier_read == 0 or temp_buf[0] != '5') return .none;

    const direction_read = stdin.read(temp_buf[0..1]) catch return .none;
    if (direction_read == 0) return .none;

    return switch (temp_buf[0]) {
        'C' => .{ .move_cursor = .{ .word_forward = .word } },
        'D' => .{ .move_cursor = .{ .word_backward = .word } },
        'A' => .{ .move_cursor = .to_line_start },
        'B' => .{ .move_cursor = .to_line_end },
        else => .none,
    };
}

/// Word character detection
pub fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

pub fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t';
}

// ── Configurable Keybindings ──

/// Bindable actions — the subset of Action that can be configured via keybindings.
/// Each maps to a concrete Action value (no payload needed from the binding itself).
pub const BindableAction = enum(u8) {
    none = 0,
    // cursor movement
    move_line_start,
    move_line_end,
    move_left,
    move_right,
    move_word_forward,
    move_word_backward,
    move_up,
    move_down,
    // editing
    backspace,
    delete_char,
    delete_word_backward,
    kill_to_end,
    kill_to_beginning,
    yank_killed,
    transpose_chars,
    insert_last_arg,
    undo,
    // history
    history_up,
    history_down,
    search_backward,
    search_forward,
    // shell control
    cancel,
    cancel_agent,
    clear_screen,
    exit_shell,
    suspend_shell,
    execute_command,
    tab_complete,
    // vi
    enter_normal_mode,

    /// Convert to runtime Action
    pub fn toAction(self: BindableAction) Action {
        return switch (self) {
            .none => .none,
            .move_line_start => .{ .move_cursor = .to_line_start },
            .move_line_end => .{ .move_cursor = .to_line_end },
            .move_left => .{ .move_cursor = .{ .relative = -1 } },
            .move_right => .{ .move_cursor = .{ .relative = 1 } },
            .move_word_forward => .{ .move_cursor = .{ .word_forward = .word } },
            .move_word_backward => .{ .move_cursor = .{ .word_backward = .word } },
            .move_up => .{ .move_cursor = .line_up },
            .move_down => .{ .move_cursor = .line_down },
            .backspace => .backspace,
            .delete_char => .{ .delete = .char_under_cursor },
            .delete_word_backward => .delete_word_backward,
            .kill_to_end => .kill_to_end,
            .kill_to_beginning => .kill_to_beginning,
            .yank_killed => .yank_killed,
            .transpose_chars => .transpose_chars,
            .insert_last_arg => .insert_last_arg,
            .undo => .undo,
            .history_up => .{ .history_nav = .up },
            .history_down => .{ .history_nav = .down },
            .search_backward => .{ .enter_search_mode = .backward },
            .search_forward => .{ .enter_search_mode = .forward },
            .cancel => .cancel,
            .cancel_agent => .cancel_agent,
            .clear_screen => .clear_screen,
            .exit_shell => .exit_shell,
            .suspend_shell => .suspend_shell,
            .execute_command => .execute_command,
            .tab_complete => .tap_complete,
            .enter_normal_mode => .{ .vim_mode = .{ .set_mode = .normal } },
        };
    }

    /// Parse from string name (used by JSON config loader)
    pub fn fromName(name: []const u8) ?BindableAction {
        inline for (std.meta.fields(BindableAction)) |field| {
            if (std.mem.eql(u8, name, field.name)) {
                return @enumFromInt(field.value);
            }
        }
        return null;
    }
};

/// Key identifier for binding lookup
pub const KeyId = struct {
    /// Ctrl+key index (0=a, 1=b, ..., 25=z)
    pub fn ctrl(comptime c: u8) u8 {
        return (c & 0x1F) - 1; // ctrl+a=0, ctrl+b=1, ..., ctrl+z=25
    }
    // Alt+key: use the raw ASCII byte as index into the alt table
};

/// Keybinding configuration — fixed-size tables for Ctrl and Alt bindings.
/// Loaded from ~/.zish/keybindings.json at shell startup.
pub const KeyBindings = struct {
    /// Ctrl+a (index 0) through Ctrl+z (index 25)
    ctrl: [26]BindableAction = default_ctrl,
    /// Alt+<ascii byte> — 128 entries for all ASCII chars
    alt: [128]BindableAction = default_alt,

    /// Default Ctrl bindings (readline-compatible)
    /// Index = byte_value - 1, so ctrl+a (0x01) = index 0, ctrl+z (0x1A) = index 25
    const default_ctrl: [26]BindableAction = blk: {
        var t = [_]BindableAction{.none} ** 26;
        t[0] = .move_line_start;       // ctrl+a (0x01)
        t[1] = .move_left;             // ctrl+b (0x02)
        t[2] = .cancel;                // ctrl+c (0x03)
        t[3] = .exit_shell;            // ctrl+d (0x04)
        t[4] = .move_line_end;         // ctrl+e (0x05)
        t[5] = .move_right;            // ctrl+f (0x06)
        t[6] = .cancel_agent;          // ctrl+g (0x07)
        // t[7] = backspace (ctrl+h=0x08) — handled structurally, not here
        // t[8] = tab (ctrl+i=0x09) — handled structurally, not here
        // t[9] = enter (ctrl+j=0x0A) — handled structurally, not here
        t[10] = .kill_to_end;          // ctrl+k (0x0B)
        t[11] = .clear_screen;         // ctrl+l (0x0C)
        // t[12] = enter (ctrl+m=0x0D) — handled structurally
        t[13] = .history_down;          // ctrl+n (0x0E)
        t[15] = .history_up;            // ctrl+p (0x10)
        t[17] = .search_backward;       // ctrl+r (0x12)
        t[18] = .search_forward;        // ctrl+s (0x13)
        t[19] = .transpose_chars;       // ctrl+t (0x14)
        t[20] = .kill_to_beginning;     // ctrl+u (0x15)
        t[22] = .delete_word_backward;  // ctrl+w (0x17)
        t[24] = .yank_killed;           // ctrl+y (0x19)
        t[25] = .suspend_shell;         // ctrl+z (0x1A)
        break :blk t;
    };

    /// Default Alt bindings
    const default_alt: [128]BindableAction = blk: {
        var t = [_]BindableAction{.none} ** 128;
        t['b'] = .move_word_backward;
        t['f'] = .move_word_forward;
        t['.'] = .insert_last_arg;
        break :blk t;
    };

    /// Look up Ctrl+key binding. `byte` is the raw control character (0x01-0x1A).
    pub fn lookupCtrl(self: *const KeyBindings, byte: u8) ?Action {
        if (byte < 1 or byte > 26) return null;
        const ba = self.ctrl[byte - 1];
        if (ba == .none) return null;
        return ba.toAction();
    }

    /// Look up Alt+key binding. `byte` is the ASCII char after ESC.
    pub fn lookupAlt(self: *const KeyBindings, byte: u8) ?Action {
        if (byte >= 128) return null;
        const ba = self.alt[byte];
        if (ba == .none) return null;
        return ba.toAction();
    }

    /// Load keybindings from a JSON file, overriding defaults.
    /// Format: {"ctrl+a": "move_line_start", "alt+b": "move_word_backward", ...}
    pub fn loadFromFile(path: []const u8) KeyBindings {
        var kb = KeyBindings{}; // start with defaults
        const file = std.fs.cwd().openFile(path, .{}) catch return kb;
        defer file.close();
        var buf: [8192]u8 = undefined;
        const len = file.readAll(&buf) catch return kb;
        kb.parseJson(buf[0..len]);
        return kb;
    }

    /// Parse JSON keybindings. Minimal parser for {"key": "action", ...} format.
    fn parseJson(self: *KeyBindings, json: []const u8) void {
        var i: usize = 0;
        // skip to first '{'
        while (i < json.len and json[i] != '{') i += 1;
        if (i >= json.len) return;
        i += 1;

        while (i < json.len) {
            // skip whitespace and commas
            while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r' or json[i] == ',')) i += 1;
            if (i >= json.len or json[i] == '}') break;

            // skip comments (// to end of line)
            if (i + 1 < json.len and json[i] == '/' and json[i + 1] == '/') {
                while (i < json.len and json[i] != '\n') i += 1;
                continue;
            }

            // parse key string
            if (json[i] != '"') { i += 1; continue; }
            i += 1;
            const key_start = i;
            while (i < json.len and json[i] != '"') i += 1;
            if (i >= json.len) break;
            const key_name = json[key_start..i];
            i += 1; // skip closing "

            // skip : and whitespace
            while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == ':')) i += 1;

            // parse value string
            if (i >= json.len or json[i] != '"') { i += 1; continue; }
            i += 1;
            const val_start = i;
            while (i < json.len and json[i] != '"') i += 1;
            if (i >= json.len) break;
            const action_name = json[val_start..i];
            i += 1; // skip closing "

            // resolve action
            const action = BindableAction.fromName(action_name) orelse continue;

            // resolve key
            if (parseKeyName(key_name)) |key| {
                switch (key.kind) {
                    .ctrl => self.ctrl[key.index] = action,
                    .alt => if (key.index < 128) { self.alt[key.index] = action; },
                }
            }
        }
    }

    const KeyKind = enum { ctrl, alt };
    const ParsedKey = struct { kind: KeyKind, index: u8 };

    fn parseKeyName(name: []const u8) ?ParsedKey {
        // "ctrl+x" format
        if (name.len >= 6 and std.mem.eql(u8, name[0..5], "ctrl+")) {
            const ch = name[5];
            if (ch >= 'a' and ch <= 'z') {
                return .{ .kind = .ctrl, .index = ch - 'a' };
            }
        }
        // "alt+x" format
        if (name.len >= 5 and std.mem.eql(u8, name[0..4], "alt+")) {
            const rest = name[4..];
            if (rest.len == 1 and rest[0] < 128) {
                return .{ .kind = .alt, .index = rest[0] };
            }
            // special names
            if (std.mem.eql(u8, rest, "dot") or std.mem.eql(u8, rest, ".")) {
                return .{ .kind = .alt, .index = '.' };
            }
        }
        return null;
    }
};
