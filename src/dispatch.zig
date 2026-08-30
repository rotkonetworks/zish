//! dispatch.zig — mode-aware key→Action routing, extracted from Shell.zig.
//! This is the bridge between raw stdin bytes and the Action model: vi
//! normal/insert dispatch, the vim.zig state-machine adapter, and terminal
//! escape-sequence decoding (arrows, Home/End, bracketed paste, modifiers).
//! Shell.zig's readNextAction owns the read loop and paste/search-mode
//! short-circuits; everything below that layer lives here.

const std = @import("std");
const compat = @import("compat.zig");
const posix = compat.posix;
const Shell = @import("Shell.zig");
const input = @import("input.zig");

const Action = input.Action;
const CTRL_C = input.CTRL_C;
const CTRL_G = input.CTRL_G;
const CTRL_Z = input.CTRL_Z;

// Normal-mode key dispatch. Most keys map to a single self-contained Action
// via normalModeAction. Multi-key vi sequences (operators like dw/d$/cc/dd,
// numeric counts, r<char>, the g-prefix) can't be expressed as one Action, so
// those are driven through the vim.zig state machine, which mutates the edit
// buffer directly and tracks pending state across keystrokes.
pub fn normalModeDispatch(self: *Shell, char: u8) !Action {
    const v = &self.vi;
    // Visual / visual-line mode has its own selection-aware key handling in
    // vim.zig (handleVisual): motions extend the selection, and d/x/c/s/y
    // operate on exactly the selected range. normalModeAction() below knows
    // nothing about a selection — e.g. its 'y' always yanks the whole line —
    // so every key must route through the vim.zig state machine while a
    // selection is active, not just the operator-starting subset used in
    // normal mode.
    if (v.mode == .visual or v.mode == .visual_line) {
        // Structural keys stay structural even mid-selection: handleVisual's
        // `else` arm silently consumes anything it doesn't recognize, which
        // would otherwise make Enter and Ctrl-C dead keys in visual mode (no
        // way out except remembering Esc). Both of these already reset
        // vi.mode to .insert in their handlers, so the selection is properly
        // abandoned either way.
        return switch (char) {
            '\n', '\r', CTRL_C, CTRL_Z => normalModeAction(char),
            else => viStateMachineKey(self, char),
        };
    }
    // vim.zig is the SINGLE owner of vi editing. A key that is mid-sequence
    // (3j, dj, dfx, ciw) always completes it there; otherwise every key routes
    // to the state machine EXCEPT the handful that are shell-integration, not
    // editing: history navigation (j/k), incremental search (/ ?), line submit,
    // and the signal keys. Keeping two parallel normal-mode handlers is exactly
    // what let normalModeAction's whole-line 'y' shadow vim.zig's selection —
    // there is now one path.
    const in_sequence = v.pending_op != .none or v.awaiting_text_obj or
        v.awaiting_find or v.pending_g or v.mode == .replace or v.count != 0;
    if (in_sequence) return viStateMachineKey(self, char);
    return switch (char) {
        // The ONLY normal-mode keys not owned by vim.zig: history navigation,
        // incremental search, line submit, and the signal keys. Everything else
        // — including visual entry (v/V) — goes to the one state machine.
        'j', 'k', '/', '?', '\n', '\r', CTRL_C, CTRL_G, CTRL_Z => normalModeAction(char),
        else => viStateMachineKey(self, char),
    };
}

// Feed one key to the vim.zig state machine and translate the result back into
// an Action for the render/mode plumbing.
fn viStateMachineKey(self: *Shell, char: u8) !Action {
    const was_insert = self.vim_mode == .insert;
    const result = self.vi.handleKey(&self.edit_buf, char);
    // keep history-search prefix in sync if the buffer changed
    if (self.history_index != -1) {
        self.history_search_prefix_len = self.edit_buf.len;
    }
    // Visual / visual-line: vim.zig owns the selection state. Do NOT route
    // through the set_mode Action — its handler forces vi.mode back to normal
    // (vi.mode = if (mode == .normal) .normal else .insert), which would abandon
    // the selection the instant we entered it — that is what made a visual `y`
    // fall through to the whole-line yank. Just sync the block-cursor mode, force
    // the selection-highlight redraw (buffer text is unchanged, only the
    // selection moved, so the render hash must be invalidated), and render.
    if (self.vi.mode == .visual or self.vi.mode == .visual_line) {
        self.vim_mode = .normal;
        self.term_view.last_hash = 0xDEADBEEF;
        return .redraw_line;
    }
    // Reconcile the shell's mode with the state machine's. vim.zig is not
    // reliable about returning .mode_changed (e.g. cc/dd clear pending_op
    // before checking it), so sync straight off self.vi.mode instead. replace
    // leaves vim_mode == .normal (block cursor).
    const now_insert = self.vi.mode == .insert;
    if (now_insert != was_insert or result == .mode_changed) {
        self.vim_mode = if (now_insert) .insert else .normal;
        return .{ .vim_mode = .{ .set_mode = self.vim_mode } };
    }
    if (result == .unhandled) return .none;
    // Normal mode keeps the cursor on the last character, never past it.
    self.clampCursorNormal();
    return .redraw_line;
}

pub fn resolveInsertAction(self: *Shell, char: u8) Action {
    // Structural keys that cannot be rebound
    return switch (char) {
        '\n', '\r' => .execute_command, // Enter (ctrl+j / ctrl+m)
        '\t' => .tap_complete, // Tab (ctrl+i)
        0x08, 127 => .backspace, // Backspace (ctrl+h / DEL)
        32...126 => .{ .input_char = char },
        // UTF-8 lead/continuation bytes — insert so accents/CJK/emoji work.
        0x80...0xFF => .{ .input_char = char },
        // Ctrl keys — look up in configurable keybindings table
        0x01...0x07, 0x0B...0x0C, 0x0E...0x1A => self.keybindings.lookupCtrl(char) orelse .none,
        else => .none,
    };
}

// Normal-mode keys that are NOT vi editing — shell integration only. Every
// editing key (h/l/w/b/e/i/a/x/p/y/u/v/…) is now owned by vim.zig and reached
// through viStateMachineKey; this handles just the four things vim.zig doesn't:
// history navigation, incremental search, line submit, and the signal keys.
fn normalModeAction(char: u8) Action {
    return switch (char) {
        'j' => .{ .move_cursor = .line_down }, // history: next
        'k' => .{ .move_cursor = .line_up }, // history: prev

        '/' => .{ .enter_search_mode = .forward },
        '?' => .{ .enter_search_mode = .backward },

        // Enter accepts the line (readline vi-command-mode). In raw mode the
        // terminal delivers CR (\r) for Return, so both must submit.
        '\n', '\r' => .execute_command,

        CTRL_C => .cancel,
        CTRL_G => .cancel_agent,
        CTRL_Z => .suspend_shell,

        else => .none,
    };
}

pub fn escapeSequenceAction(self: *Shell) !Action {
    const stdin_fd = posix.STDIN_FILENO;
    var temp_buf: [2]u8 = undefined;

    // Set non-blocking temporarily via system call
    const F_GETFL = 3;
    const F_SETFL = 4;
    const O_NONBLOCK = 0x800;

    const flags_raw = std.posix.system.fcntl(stdin_fd, F_GETFL, @as(usize, 0));
    const flags: usize = if (@TypeOf(flags_raw) == c_int) @intCast(flags_raw) else flags_raw;
    _ = std.posix.system.fcntl(stdin_fd, F_SETFL, flags | O_NONBLOCK);
    defer _ = std.posix.system.fcntl(stdin_fd, F_SETFL, flags);

    // Try to read - if nothing there (EAGAIN), it's just ESC
    const result = std.posix.system.read(stdin_fd, &temp_buf, temp_buf.len);
    if (result <= 0) {
        // Bare Esc. In reverse-i-search this MUST cancel the search — the
        // search_mode check in readNextAction sits after the \x1b interception,
        // so getSearchModeAction never sees Esc. Returning set_mode=.normal here
        // would flip vim_mode while leaving search_mode set, and every following
        // key would still route to the search handler (stuck-in-search loop).
        if (self.search_mode) return .{ .exit_search_mode = false };
        return .{ .vim_mode = .{ .set_mode = .normal } };
    }
    const bytes_read: usize = @intCast(result);

    if (temp_buf[0] != '[') {
        // Alt+key: look up in keybindings table
        if (self.keybindings.lookupAlt(temp_buf[0])) |action| return action;
        if (self.search_mode) return .{ .exit_search_mode = false };
        return .{ .vim_mode = .{ .set_mode = .normal } };
    }

    // Need at least 2 bytes for a valid escape sequence
    // If incomplete, treat as just ESC (vim normal mode)
    if (bytes_read < 2) {
        if (self.search_mode) return .{ .exit_search_mode = false };
        return .{ .vim_mode = .{ .set_mode = .normal } };
    }

    const cmd_byte = temp_buf[1];

    return switch (cmd_byte) {
        'A' => .{ .history_nav = .up }, // Up arrow
        'B' => .{ .history_nav = .down }, // Down arrow
        'C' => .{ .move_cursor = .{ .relative = 1 } }, // Right arrow
        'D' => .{ .move_cursor = .{ .relative = -1 } }, // Left arrow
        'Z' => .{ .cycle_complete = .backward }, // Shift+Tab
        'H' => .{ .move_cursor = .to_line_start }, // Home key
        'F' => .{ .move_cursor = .to_line_end }, // End key
        '1' => try handleExtendedEscapeSequence(stdin_fd, flags), // Ctrl+arrows, Home, End
        '2' => try handleBracketedPaste(stdin_fd, flags), // Bracketed paste
        '3' => try readTildeSequence(stdin_fd, flags, .{ .delete = .char_under_cursor }), // Delete key
        '4' => try readTildeSequence(stdin_fd, flags, .{ .move_cursor = .to_line_end }), // End key
        '7' => try readTildeSequence(stdin_fd, flags, .{ .move_cursor = .to_line_start }), // Home key
        '8' => try readTildeSequence(stdin_fd, flags, .{ .move_cursor = .to_line_end }), // End key
        '?' => {
            consumeEscapeSequence(stdin_fd);
            return .none;
        }, // DA response, consume and ignore
        else => .none,
    };
}

/// consume remaining bytes of an escape sequence until terminator (letter or ~)
fn consumeEscapeSequence(stdin_fd: posix.fd_t) void {
    var buf: [1]u8 = undefined;
    var iterations: u8 = 0;
    while (iterations < 32) : (iterations += 1) {
        const n = std.posix.system.read(stdin_fd, &buf, 1);
        if (n <= 0) break;
        const c = buf[0];
        // escape sequences end with a letter or ~
        if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '~') break;
    }
}

fn readTildeSequence(stdin_fd: posix.fd_t, flags: usize, action: Action) !Action {
    var buf: [1]u8 = undefined;
    const result = std.posix.system.read(stdin_fd, &buf, 1);
    if (result <= 0) return .none;
    if (buf[0] == '~') return action;
    _ = flags;
    return .none;
}

fn handleExtendedEscapeSequence(stdin_fd: posix.fd_t, flags: usize) !Action {
    var temp_buf: [1]u8 = undefined;
    _ = flags;

    // Read the next character (semicolon or tilde)
    var result = std.posix.system.read(stdin_fd, &temp_buf, 1);
    if (result <= 0) return .none;

    const semicolon = temp_buf[0];

    // handle ESC[1~ (Home key in some terminals)
    if (semicolon == '~') {
        return .{ .move_cursor = .to_line_start };
    }

    // expect semicolon for modified keys
    if (semicolon != ';') {
        // Not a modifier sequence — could be ESC[15~ (F5) etc.
        // Consume until we hit a letter or ~ to drain the sequence
        if (semicolon >= '0' and semicolon <= '9') {
            while (true) {
                result = std.posix.system.read(stdin_fd, &temp_buf, 1);
                if (result <= 0) break;
                if (temp_buf[0] == '~' or (temp_buf[0] >= 'A' and temp_buf[0] <= 'Z')) break;
                if (temp_buf[0] >= 'a' and temp_buf[0] <= 'z') break;
            }
        }
        return .none;
    }

    // read modifier: 2=Shift, 3=Alt, 5=Ctrl, 6=Ctrl+Shift, etc.
    result = std.posix.system.read(stdin_fd, &temp_buf, 1);
    if (result <= 0) return .none;
    const modifier = temp_buf[0];

    // read direction key (always consume to prevent stray bytes)
    result = std.posix.system.read(stdin_fd, &temp_buf, 1);
    if (result <= 0) return .none;

    if (modifier == '5' or modifier == '6') {
        // Ctrl (or Ctrl+Shift)
        return switch (temp_buf[0]) {
            'C' => .{ .move_cursor = .{ .word_forward = .WORD } }, // Ctrl+Right
            'D' => .{ .move_cursor = .{ .word_backward = .WORD } }, // Ctrl+Left
            'A' => .{ .move_cursor = .to_line_start }, // Ctrl+Up
            'B' => .{ .move_cursor = .to_line_end }, // Ctrl+Down
            'H' => .{ .move_cursor = .to_line_start }, // Ctrl+Home
            'F' => .{ .move_cursor = .to_line_end }, // Ctrl+End
            else => .none,
        };
    } else if (modifier == '2') {
        // Shift
        return switch (temp_buf[0]) {
            'C' => .{ .move_cursor = .{ .relative = 1 } },
            'D' => .{ .move_cursor = .{ .relative = -1 } },
            'A' => .{ .history_nav = .up },
            'B' => .{ .history_nav = .down },
            else => .none,
        };
    } else if (modifier == '3') {
        // Alt — cycle ghost text candidates
        return switch (temp_buf[0]) {
            'A' => .{ .cycle_ghost = .backward }, // Alt+Up
            'B' => .{ .cycle_ghost = .forward }, // Alt+Down
            else => .none,
        };
    } else {
        // Unknown modifier — consume and ignore
        return .none;
    }
}

fn handleBracketedPaste(stdin_fd: posix.fd_t, flags: usize) !Action {
    _ = flags;

    // Sequence is ESC[200~ or ESC[201~
    // We've already read ESC[2, now read the rest: '0', '0'/'1', '~'

    var buf: [3]u8 = undefined;
    const result = std.posix.system.read(stdin_fd, &buf, 3);
    if (result < 3) return .none;

    // First char should be '0'
    if (buf[0] != '0') return .none;
    // Third char should be '~'
    if (buf[2] != '~') return .none;

    // Check for '0~' (paste start: 200~) or '1~' (paste end: 201~)
    return switch (buf[1]) {
        '0' => .enter_paste_mode,
        '1' => .exit_paste_mode,
        else => .none,
    };
}
