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
