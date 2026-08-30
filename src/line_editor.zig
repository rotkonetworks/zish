//! line_editor.zig — interactive line-editor action execution.
//!
//! `handleAction` is the shell's single key-action interpreter: it takes a
//! decoded `Action` (produced by dispatch.zig from a keystroke, in either emacs
//! or vi mode) and mutates the edit buffer / cursor / mode / screen accordingly,
//! covering insertion, deletion, yank/paste, history and reverse-search, cursor
//! and word motion, completion, and command submission. `handleCursorMovement`
//! plus the word/line-motion helpers are its motion primitives.
//!
//! Lifted out of Shell.zig as free functions over `*Shell`: the shell remains
//! the state owner (edit buffer, terminal view, history, mode flags) and keeps
//! the lifecycle/run-loop/exec glue, while the ~900-line action-execution layer
//! lives here where it can be read as one unit. Circular import with Shell.zig
//! is fine (eval.zig already does it) — only function references, no type cycle.

const std = @import("std");
const Shell = @import("Shell.zig");
const compat = @import("compat.zig");
const posix = compat.posix;
const heredoc = @import("heredoc.zig");
const prompt_mod = @import("prompt.zig");
const input_mod = @import("input.zig");
const completion_mod = @import("completion.zig");
const dispatch = @import("dispatch.zig");
const eval = @import("eval.zig");

const Action = input_mod.Action;
const MoveCursorAction = input_mod.MoveCursorAction;
const WordBoundary = input_mod.WordBoundary;

// POSIX getsid — session id of a process (0 = calling process); same extern the
// shell uses to tell a login/session-leader zish from one running as a job.
extern "c" fn getsid(pid: std.c.pid_t) std.c.pid_t;

pub fn handleAction(self: *Shell, action: Action) !void {
    // reset ctrl+d pending on any other action
    if (action != .exit_shell and action != .none) {
        self.ctrl_d_pending = false;
    }

    switch (action) {
        .none => {},

        .cancel => {
            completion_mod.exitCompletionMode(self);
            self.ghost.len = 0;
            // print ^C like bash does
            try self.stdout().writeAll("^C\n");
            try self.stdout().flush();
            // signal we're on a fresh line
            self.term_view.finishLine();
            self.displayed_cmd_lines = 1;
            self.terminal_cursor_row = 0;
            // clear and render new prompt
            self.clearCommand();
            self.paste_mode = false;
            self.history_index = -1;
            self.history_search_prefix_len = 0;
            self.vi.mode = .insert;
            self.vim_mode = .insert; // legacy compat
            try self.renderLine();
            try self.setCursorStyle(.bar);
        },

        .exit_shell => {
            // double ctrl+d to exit (like zsh)
            if (self.ctrl_d_pending) {
                self.running = false;
                try self.stdout().writeByte('\n');
            } else {
                self.ctrl_d_pending = true;
                try self.stdout().writeAll("\r\n(press ctrl+d again to exit)\r\n");
                try self.stdout().flush();
                try self.renderLine();
            }
        },

        .cancel_agent => {
            // The embedded agent was removed; Ctrl+G is now a no-op.
        },

        .suspend_shell => {
            // Ctrl+Z at the prompt. Suspending the shell only makes sense
            // when zish itself runs as a job under a parent job-control
            // shell. When zish is the session leader (login shell, top-level
            // shell on a pty) there is no parent shell to return to — the
            // self-suspend dance just echoed "^Z" and garbled the redraw.
            // bash ignores SIGTSTP for itself and does nothing here; so do
            // we: a clean no-op, no echo, no redraw.
            const pid = compat.posix.getpid();
            if (getsid(0) == pid) return;

            // suspend the shell with Ctrl+Z
            try self.stdout().writeAll("^Z\n");
            try self.stdout().flush();

            // restore terminal to original state before suspending
            self.disableRawMode();

            // send SIGTSTP to ourselves - we'll be stopped here.
            // The shell durably ignores SIGTSTP (setupJobControlSignals), so
            // temporarily restore the default disposition around the raise —
            // the same dance bash's `suspend` builtin does.
            const default_action = posix.Sigaction{
                .handler = .{ .handler = posix.SIG.DFL },
                .mask = std.mem.zeroes(posix.sigset_t),
                .flags = 0,
            };
            const ignore_action = posix.Sigaction{
                .handler = .{ .handler = posix.SIG.IGN },
                .mask = std.mem.zeroes(posix.sigset_t),
                .flags = 0,
            };
            posix.sigaction(posix.SIG.TSTP, &default_action, null);
            _ = posix.kill(pid, posix.SIG.TSTP) catch {};
            // === EXECUTION RESUMES HERE AFTER SIGCONT === (re-ignore first)
            posix.sigaction(posix.SIG.TSTP, &ignore_action, null);

            // === EXECUTION RESUMES HERE AFTER SIGCONT ===
            // the parent shell may have changed terminal settings while we
            // were suspended, so we must re-read the current state rather
            // than using our cached original_termios
            self.original_termios = null; // force re-read of terminal state
            self.enableRawMode() catch {};
            // (no cached shell_tmodes to refresh: the editor's raw mode is
            // restored through foreground.Session/original_termios now)

            // redraw the prompt
            try self.stdout().writeAll("\n");
            try self.renderLine();
        },

        .input_char => |char| {
            // exit completion mode when typing
            completion_mod.exitCompletionMode(self);

            if (self.search_mode) {
                // Add to search buffer and show live results
                if (self.search_len < self.search_buffer.len) {
                    self.search_buffer[self.search_len] = char;
                    self.search_len += 1;
                    self.search_index = 0; // new term → jump to most recent match
                    try self.showSearchMatch();
                }
            } else {
                // Skip duplicate slash right after completion inserted one
                if (char == '/' and self.completion.skip_next_slash) {
                    self.completion.skip_next_slash = false;
                    return; // don't insert, don't redraw
                }
                self.completion.skip_next_slash = false; // clear for any other char

                // Use new edit_buf for insertion
                if (!self.edit_buf.insert(char)) return;

                // Update history prefix if in navigation mode
                if (self.history_index != -1) {
                    self.history_search_prefix_len = self.edit_buf.len;
                }

                // Update display (skip during paste mode - redraw at paste end)
                if (!self.paste_mode) {
                    try self.renderLine();
                }
            }
        },

        .backspace => {
            if (self.search_mode) {
                if (self.search_len > 0) {
                    self.search_len -= 1;
                    self.search_index = 0; // term changed → most recent match
                    try self.showSearchMatch();
                }
            } else {
                if (self.edit_buf.delete()) {
                    // Update history prefix if in navigation mode
                    if (self.history_index != -1) {
                        self.history_search_prefix_len = self.edit_buf.len;
                    }
                    try self.renderLine();
                }
            }
        },

        .delete_word_backward => {
            // exit completion mode
            completion_mod.exitCompletionMode(self);

            // delete word before cursor (like Ctrl+W in bash/zsh)
            const text = self.edit_buf.slice();
            var pos = self.edit_buf.cursor;

            // skip whitespace first
            while (pos > 0 and (text[pos - 1] == ' ' or text[pos - 1] == '\t')) : (pos -= 1) {}

            // then skip non-whitespace (the word)
            while (pos > 0 and text[pos - 1] != ' ' and text[pos - 1] != '\t') : (pos -= 1) {}

            // delete from pos to cursor
            const chars_to_delete = self.edit_buf.cursor - pos;
            var i: usize = 0;
            while (i < chars_to_delete) : (i += 1) {
                _ = self.edit_buf.delete();
            }

            if (self.history_index != -1) {
                self.history_search_prefix_len = self.edit_buf.len;
            }
            try self.renderLine();
        },

        .kill_to_beginning => {
            // Ctrl+U: kill from cursor to start of line, save to kill buffer
            const pos = self.edit_buf.cursor;
            if (pos > 0) {
                // Save killed text to yank buffer
                @memcpy(self.vi.yank_buf[0..pos], self.edit_buf.text[0..pos]);
                self.vi.yank_len = @intCast(pos);
                // Delete by repeated backspace
                var i: usize = 0;
                while (i < pos) : (i += 1) _ = self.edit_buf.delete();
                if (self.history_index != -1) {
                    self.history_search_prefix_len = self.edit_buf.len;
                }
                try self.renderLine();
            }
        },

        .kill_to_end => {
            // Ctrl+K: kill from cursor to end of line, save to kill buffer
            const start = self.edit_buf.cursor;
            var end: u16 = start;
            while (end < self.edit_buf.len and self.edit_buf.text[end] != '\n') end += 1;
            if (end > start) {
                const len = end - start;
                @memcpy(self.vi.yank_buf[0..len], self.edit_buf.text[start..end]);
                self.vi.yank_len = @intCast(len);
                self.edit_buf.cursor = start;
                var i: usize = 0;
                while (i < len) : (i += 1) _ = self.edit_buf.deleteForward();
                if (self.history_index != -1) {
                    self.history_search_prefix_len = self.edit_buf.len;
                }
                try self.renderLine();
            }
        },

        .yank_killed => {
            // Ctrl+Y: paste kill buffer at cursor
            if (self.vi.yank_len > 0) {
                _ = self.edit_buf.insertSlice(self.vi.yank_buf[0..self.vi.yank_len]);
                if (self.history_index != -1) {
                    self.history_search_prefix_len = self.edit_buf.len;
                }
                try self.renderLine();
            }
        },

        .transpose_chars => {
            // Ctrl+T: swap character before cursor with character at cursor
            if (self.edit_buf.cursor > 0 and self.edit_buf.cursor < self.edit_buf.len) {
                const c1 = self.edit_buf.text[self.edit_buf.cursor - 1];
                const c2 = self.edit_buf.text[self.edit_buf.cursor];
                self.edit_buf.text[self.edit_buf.cursor - 1] = c2;
                self.edit_buf.text[self.edit_buf.cursor] = c1;
                self.edit_buf.cursor += 1;
                try self.renderLine();
            } else if (self.edit_buf.cursor >= 2 and self.edit_buf.cursor == self.edit_buf.len) {
                // at end of line: swap last two chars (bash behavior)
                const pos = self.edit_buf.cursor;
                const c1 = self.edit_buf.text[pos - 2];
                const c2 = self.edit_buf.text[pos - 1];
                self.edit_buf.text[pos - 2] = c2;
                self.edit_buf.text[pos - 1] = c1;
                try self.renderLine();
            }
        },

        .insert_last_arg => {
            // Alt+.: insert last argument from previous history command
            if (self.history) |h| {
                const items = h.entries.items;
                if (items.len > 0) {
                    const prev = h.getCommand(items[items.len - 1]);
                    if (prev.len > 0) {
                        // find last whitespace-separated argument
                        var end: usize = prev.len;
                        while (end > 0 and (prev[end - 1] == ' ' or prev[end - 1] == '\t')) end -= 1;
                        var start: usize = end;
                        while (start > 0 and prev[start - 1] != ' ' and prev[start - 1] != '\t') start -= 1;
                        const last_arg = prev[start..end];
                        if (last_arg.len > 0) {
                            if (self.edit_buf.len > 0 and self.edit_buf.cursor > 0 and
                                self.edit_buf.text[self.edit_buf.cursor - 1] != ' ')
                            {
                                _ = self.edit_buf.insert(' ');
                            }
                            _ = self.edit_buf.insertSlice(last_arg);
                            try self.renderLine();
                        }
                    }
                }
            }
        },

        .delete => |delete_action| {
            switch (delete_action) {
                .char_under_cursor => {
                    if (self.edit_buf.deleteForward()) {
                        if (self.history_index != -1) {
                            self.history_search_prefix_len = self.edit_buf.len;
                        }
                        self.clampCursorNormal();
                        try self.renderLine();
                    }
                },
                .to_line_end => {
                    // Delete to end of line (D in vim)
                    const start = self.edit_buf.cursor;
                    self.edit_buf.moveLineEnd();
                    const end = self.edit_buf.cursor;
                    if (end > start) {
                        // yank to vim register
                        const len = end - start;
                        @memcpy(self.vi.yank_buf[0..len], self.edit_buf.text[start..end]);
                        self.vi.yank_len = @intCast(len);
                        // delete
                        self.edit_buf.cursor = start;
                        var i: usize = 0;
                        while (i < len) : (i += 1) _ = self.edit_buf.deleteForward();
                        if (self.history_index != -1) {
                            self.history_search_prefix_len = self.edit_buf.len;
                        }
                        self.clampCursorNormal();
                        try self.renderLine();
                    }
                },
                .char_at => |pos| {
                    if (pos < self.edit_buf.len) {
                        const old_cursor = self.edit_buf.cursor;
                        self.edit_buf.cursor = @intCast(pos);
                        _ = self.edit_buf.deleteForward();
                        self.edit_buf.cursor = if (old_cursor > pos) old_cursor - 1 else old_cursor;
                        if (self.history_index != -1) {
                            self.history_search_prefix_len = self.edit_buf.len;
                        }
                        try self.renderLine();
                    }
                },
            }
        },

        .execute_command => {
            if (self.search_mode) {
                // In search mode, treat enter as exit search
                try handleAction(self, .{ .exit_search_mode = true });
            } else {
                completion_mod.exitCompletionMode(self);
                self.ghost.len = 0;

                const command = std.mem.trim(u8, self.edit_buf.slice(), " \t\n\r");

                // Check for line continuation (trailing backslash)
                if (command.len > 0 and command[command.len - 1] == '\\') {
                    // Check it's not an escaped backslash (\\)
                    const is_escaped = command.len >= 2 and command[command.len - 2] == '\\';
                    if (!is_escaped) {
                        // Line continuation - insert newline and continue editing
                        _ = self.edit_buf.insert('\n');
                        try self.renderLine();
                        return;
                    }
                }

                // Check for heredoc (need to collect lines until delimiter)
                if (heredoc.findDelimiter(command)) |delim| {
                    if (!heredoc.complete(command, delim)) {
                        // Need more input - continue editing
                        _ = self.edit_buf.insert('\n');
                        try self.renderLine();
                        return;
                    }
                }

                // Erase the on-screen ghost suggestion before the newline
                // commits this line to scrollback. Setting ghost.len=0 above
                // only clears the state; the dimmed glyphs are still drawn to
                // the right of the cursor, and without this re-render they get
                // baked into the scrolled-back line and copied along with the
                // command. Re-render with an empty ghost (render() emits \x1b[J,
                // which erases them); the cursor is at end-of-line whenever a
                // ghost is shown, so the following newline stays clean.
                self.term_view.ghost_text = "";
                {
                    var pbuf: [256]u8 = undefined;
                    const p = prompt_mod.buildPrompt(self, &pbuf);
                    self.term_view.render(&self.edit_buf, p.slice, p.visible_len) catch {};
                }

                try self.stdout().writeByte('\n');
                try self.stdout().flush();

                if (command.len > 0) {
                    // Preprocess heredoc: convert << DELIM ... DELIM to <<< "content"
                    const processed_cmd = if (heredoc.findDelimiter(command)) |delim|
                        heredoc.preprocess(self.allocator, &self.heredoc_temps, command, delim) catch command
                    else
                        command;
                    defer if (processed_cmd.ptr != command.ptr) self.allocator.free(processed_cmd);

                    const start_ts = compat.timestamp();
                    self.last_exit_code = try self.executeCommand(processed_cmd);
                    const elapsed = compat.timestamp() - start_ts;

                    // Show elapsed time for long-running commands (>1s)
                    if (elapsed > 0) {
                        var time_buf: [32]u8 = undefined;
                        const time_str = if (elapsed >= 3600)
                            std.fmt.bufPrint(&time_buf, "\x1b[90m {d}h{d}m{d}s\x1b[0m", .{
                                @divFloor(elapsed, 3600),
                                @divFloor(@mod(elapsed, 3600), 60),
                                @mod(elapsed, 60),
                            }) catch ""
                        else if (elapsed >= 60)
                            std.fmt.bufPrint(&time_buf, "\x1b[90m {d}m{d}s\x1b[0m", .{
                                @divFloor(elapsed, 60),
                                @mod(elapsed, 60),
                            }) catch ""
                        else
                            std.fmt.bufPrint(&time_buf, "\x1b[90m {d}s\x1b[0m", .{elapsed}) catch "";
                        if (time_str.len > 0) {
                            try self.stdout().writeAll(time_str);
                            try self.stdout().writeByte('\n');
                        }
                    }

                    // Add to history
                    if (self.history) |h| {
                        h.addCommand(command, self.last_exit_code) catch {};
                    }

                    // Log command execution for training data
                    Shell.logCommandExecution(command, self.last_exit_code, elapsed);
                }

                // flush any command output before rendering new prompt
                try self.stdout().flush();

                // Backstop: guarantee the terminal is back in the line editor's
                // raw mode before the next prompt, no matter what the command
                // (or a misbehaving child) left it in. Without this, a command
                // that leaves the tty cooked makes the prompt echo "^C" and
                // line-buffer input — the shell must own its input mode.
                self.ensureRawMode();

                self.clearCommand();
                self.history_index = -1;
                self.history_search_prefix_len = 0;
                self.vi.mode = .insert;
                self.vim_mode = .insert; // legacy compat
                self.term_view.finishLine();
                self.displayed_cmd_lines = 1;
                self.terminal_cursor_row = 0;
                try self.setCursorStyle(.bar);

                if (self.running) {
                    // sync history from other sessions before next prompt
                    if (self.history) |h| h.sync();
                    self.notifyBackgroundJobs();
                    self.runPromptCommand();
                    try self.renderLine();
                }
            }
        },

        .redraw_line => try self.renderLine(),

        .clear_screen => {
            try self.stdout().writeAll("\x1b[2J\x1b[H");
            try self.stdout().flush();
            self.term_view.finishLine();
            self.displayed_cmd_lines = 1;
            self.terminal_cursor_row = 0;
            try self.renderLine();
        },

        .vim_mode => |mode_action| {
            switch (mode_action) {
                .set_mode => |mode| {
                    const was_insert = self.vim_mode == .insert;
                    self.vim_mode = mode;
                    self.vi.mode = if (mode == .normal) .normal else .insert;
                    if (mode == .normal) {
                        self.paste_mode = false;
                        // abandon any half-typed vi operator sequence so the
                        // next key starts fresh (e.g. Esc during a pending 'd')
                        self.vi.pending_op = .none;
                        self.vi.awaiting_text_obj = false;
                        self.vi.pending_g = false;
                        self.vi.count = 0;
                        // vim: leaving insert mode pulls the cursor back off the
                        // end-of-line position onto the last typed character, so
                        // x/D/r operate on it instead of no-op'ing past the end.
                        if (was_insert and self.edit_buf.cursor > 0 and
                            self.edit_buf.text[self.edit_buf.cursor - 1] != '\n')
                        {
                            _ = self.edit_buf.moveLeft();
                        }
                    }
                },
            }
            // update cursor style to match vim mode
            const cursor = if (self.vim_mode == .normal) Shell.CursorStyle.block else Shell.CursorStyle.bar;
            try self.setCursorStyle(cursor);
            // force redraw - prompt changed even if text didn't
            self.term_view.last_hash = 0xDEADBEEF;
            return self.renderLine();
        },

        .tap_complete => {
            if (self.completion.mode) {
                try completion_mod.handleCompletionCycle(self, .forward);
            } else {
                // Tab always does traditional completion (ls <tab> shows files)
                // Ghost text is accepted via Right arrow or End key
                try completion_mod.handleTabCompletion(self);
            }
        },

        .cycle_ghost => |direction| {
            // Alt+Up/Down — cycle through ghost text candidates
            const dir: i8 = if (direction == .forward) 1 else -1;
            if (completion_mod.cycleGhostCandidate(self, dir)) {
                try self.renderLine();
            }
        },

        .accept_ghost => {
            // Alt+E: accept one character of ghost text
            if (completion_mod.acceptGhostChar(self)) try self.renderLine();
        },

        .toggle_ghost => {
            // Ctrl+O: toggle ghost autosuggestion on/off
            completion_mod.toggleGhost(self);
            try self.renderLine();
        },

        .cycle_complete => |direction| {
            if (self.completion.mode) {
                try completion_mod.handleCompletionCycle(self,direction);
            } else {
                try completion_mod.handleTabCompletion(self);
            }
        },

        .move_cursor => |move| {
            try handleCursorMovement(self, move);
        },

        .history_nav => |direction| {
            try self.handleHistoryNavigation(direction);
        },

        .enter_search_mode => |direction| {
            self.search_mode = true;
            self.search_len = 0;
            self.search_index = 0;
            // clear all wrapped rows of the command line first
            if (self.term_view.term.row > 0) {
                try self.stdout().print("\x1b[{d}A", .{self.term_view.term.row});
            }
            try self.stdout().writeAll("\r\x1b[J");
            if (direction == .backward) {
                try self.stdout().writeAll("(reverse-i-search): ");
            } else {
                try self.stdout().writeAll("(forward-i-search): ");
            }
            try self.stdout().flush(); // flush erase before any stderr redraw
        },

        .search_next_match => {
            // Ctrl+R pressed again — search_index was already advanced; redraw
            // the search UI with the next (older) match.
            try self.showSearchMatch();
        },

        .exit_search_mode => |execute| {
            self.search_mode = false;

            // The search UI ["(reverse-i-search): ..."] is drawn with raw stdout
            // writes that never update the TermView hash, so renderLine()'s
            // skip-guard can early-return and leave that text on screen when the
            // edit buffer is unchanged (e.g. Ctrl+R then Esc with no typing).
            // Force a full repaint, as the .vim_mode handler does.
            self.term_view.last_hash = 0xDEADBEEF;

            // Esc cancelled the search: land in vi normal mode so the cursor
            // and subsequent keys behave as expected (i → insert). Without this
            // the user stays in whatever mode Ctrl+R was entered from and the
            // block-cursor / mode is inconsistent.
            if (!execute) {
                self.vim_mode = .normal;
                self.vi.mode = .normal;
                self.paste_mode = false;
                self.setCursorStyle(.block) catch {};
            }

            if (execute and self.search_len > 0 and self.history != null) {
                const search_term = self.search_buffer[0..self.search_len];
                const matches = self.history.?.fuzzySearch(search_term, self.allocator) catch {
                    try self.renderLine();
                    return;
                };
                defer self.allocator.free(matches);

                if (matches.len > 0) {
                    const entry_idx = matches[0].entry_index;
                    const entry = self.history.?.entries.items[entry_idx];
                    const cmd = self.history.?.getCommand(entry);
                    self.edit_buf.set(cmd);
                                    }
            }

            self.search_len = 0;
            try self.renderLine();
        },

        .undo => {
            self.clearCommand();
            try self.renderLine();
        },

        .enter_paste_mode => {
            self.paste_mode = true;
        },

        .exit_paste_mode => {
            self.paste_mode = false;
            try self.stdout().flush(); // sync before render
            try self.renderLine();
        },
    }
}

fn handleCursorMovement(self: *Shell, move_action: MoveCursorAction) !void {
    const old_pos = self.edit_buf.cursor;
    const max_pos = self.edit_buf.len;
    const cmd = self.edit_buf.slice();

    // Handle line up/down specially - may need history fallback
    switch (move_action) {
        .line_up => {
            // Check if buffer has newlines - if so, try line navigation first
            const has_newlines = std.mem.indexOfScalar(u8, cmd, '\n') != null;

            if (has_newlines) {
                // Check if we're on the first line (no newline before cursor)
                const on_first_line = std.mem.lastIndexOfScalar(u8, cmd[0..old_pos], '\n') == null;
                if (on_first_line) {
                    // Already on first line, fall back to history
                    self.vi.preferred_col_set = false; // reset preferred col on history nav
                    try self.handleHistoryNavigation(.up);
                    try self.renderLine();
                } else {
                    // Use vim's moveUp which tracks preferred column
                    self.vi.moveUp(&self.edit_buf);
                    try self.renderLine();
                }
            } else {
                // No newlines in buffer, just do history navigation
                self.vi.preferred_col_set = false;
                try self.handleHistoryNavigation(.up);
                try self.renderLine();
            }
            return;
        },
        .line_down => {
            // Check if buffer has newlines - if so, try line navigation first
            const has_newlines = std.mem.indexOfScalar(u8, cmd, '\n') != null;

            if (has_newlines) {
                // Check if we're on the last line (no newline after cursor)
                const on_last_line = std.mem.indexOfScalar(u8, cmd[old_pos..], '\n') == null;
                if (on_last_line) {
                    // Already on last line, fall back to history
                    self.vi.preferred_col_set = false;
                    try self.handleHistoryNavigation(.down);
                    try self.renderLine();
                } else {
                    // Use vim's moveDown which tracks preferred column
                    self.vi.moveDown(&self.edit_buf);
                    try self.renderLine();
                }
            } else {
                // No newlines in buffer, just do history navigation
                self.vi.preferred_col_set = false;
                try self.handleHistoryNavigation(.down);
                try self.renderLine();
            }
            return;
        },
        else => {},
    }

    // Horizontal movement resets preferred column for j/k navigation
    self.vi.preferred_col_set = false;

    // Calculate new position (clamped to valid range)
    const new_pos = switch (move_action) {
        .relative => |steps| blk: {
            const new = @as(isize, @intCast(self.edit_buf.cursor)) + steps;
            break :blk @as(usize, @intCast(@max(0, @min(new, @as(isize, @intCast(max_pos))))));
        },
        .absolute => |pos| @min(pos, max_pos),
        .to_line_start => findCurrentLineStart(self, cmd, old_pos),
        .to_line_end => findCurrentLineEnd(self, cmd, old_pos),
        .word_forward => |boundary| findWordForward(self, boundary),
        .word_backward => |boundary| findWordBackward(self, boundary),
        .line_up, .line_down => unreachable,
    };

    if (new_pos == old_pos) {
        // At end of line — accept ghost text if available
        if (old_pos == max_pos and self.ghost.len > 0) {
            switch (move_action) {
                .relative => |steps| {
                    if (steps > 0) {
                        // Right arrow: accept all ghost text
                        if (completion_mod.acceptGhostText(self)) try self.renderLine();
                    }
                },
                .to_line_end => {
                    // End key: accept all ghost text
                    if (completion_mod.acceptGhostText(self)) try self.renderLine();
                },
                .word_forward => {
                    // Ctrl+Right: accept one word from ghost text
                    if (completion_mod.acceptGhostWord(self)) try self.renderLine();
                },
                else => {},
            }
        }
        return;
    }

    self.edit_buf.cursor = @intCast(new_pos);

    // Use renderLine when content wraps across terminal rows
    // (multiline content OR single-line that exceeds terminal width)
    var prompt_buf: [256]u8 = undefined;
    const prompt_info = prompt_mod.buildPrompt(self, &prompt_buf);
    const total_width = @as(usize, prompt_info.visible_len) + cmd.len;
    const wraps = std.mem.indexOfScalar(u8, cmd, '\n') != null or
        (self.terminal_width > 0 and total_width > self.terminal_width);

    if (wraps) {
        try self.stdout().flush();
        try self.renderLine();
    } else {
        const steps = if (new_pos > old_pos)
            new_pos - old_pos
        else
            old_pos - new_pos;

        if (new_pos > old_pos) {
            try self.stdout().print("\x1b[{d}C", .{steps});
        } else {
            try self.stdout().print("\x1b[{d}D", .{steps});
        }
    }
}

fn findLinePosition(self: *Shell, cmd: []const u8, pos: usize, going_up: bool) struct { found: bool, pos: usize } {
    _ = self;

    // Find current line start and column
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < pos) : (i += 1) {
        if (cmd[i] == '\n') {
            line_start = i + 1;
        }
    }
    const col = pos - line_start;

    if (going_up) {
        // Find previous line
        if (line_start == 0) return .{ .found = false, .pos = 0 };

        // Find start of previous line
        var prev_line_start: usize = 0;
        if (line_start >= 2) {
            i = line_start - 2; // skip the newline before current line
            while (i > 0) : (i -= 1) {
                if (cmd[i] == '\n') {
                    prev_line_start = i + 1;
                    break;
                }
            }
        }

        // Find end of previous line
        const prev_line_end = line_start - 1;
        const prev_line_len = prev_line_end - prev_line_start;

        // Target position on previous line
        const target_col = @min(col, prev_line_len);
        return .{ .found = true, .pos = prev_line_start + target_col };
    } else {
        // Find next line
        var next_line_start: usize = 0;
        i = pos;
        while (i < cmd.len) : (i += 1) {
            if (cmd[i] == '\n') {
                next_line_start = i + 1;
                break;
            }
        }

        if (next_line_start == 0 or next_line_start >= cmd.len) {
            return .{ .found = false, .pos = 0 };
        }

        // Find end of next line
        var next_line_end = cmd.len;
        i = next_line_start;
        while (i < cmd.len) : (i += 1) {
            if (cmd[i] == '\n') {
                next_line_end = i;
                break;
            }
        }

        const next_line_len = next_line_end - next_line_start;
        const target_col = @min(col, next_line_len);
        return .{ .found = true, .pos = next_line_start + target_col };
    }
}

fn findCurrentLineStart(self: *Shell, cmd: []const u8, pos: usize) usize {
    _ = self;
    if (pos == 0) return 0;
    var i = pos - 1;
    while (i > 0) : (i -= 1) {
        if (cmd[i] == '\n') return i + 1;
    }
    if (cmd[0] == '\n') return 1;
    return 0;
}

fn findCurrentLineEnd(self: *Shell, cmd: []const u8, pos: usize) usize {
    _ = self;
    var i = pos;
    while (i < cmd.len) : (i += 1) {
        if (cmd[i] == '\n') return i;
    }
    return cmd.len;
}

fn findWordForward(self: *Shell, boundary: WordBoundary) usize {
    const buf = self.edit_buf.slice();
    var pos = self.edit_buf.cursor;
    const max = self.edit_buf.len;

    if (pos >= max) return max;

    return switch (boundary) {
        .word => blk: {
            // Skip current word (alphanumeric + underscore)
            while (pos < max and isWordChar(buf[pos])) : (pos += 1) {}
            // Skip whitespace
            while (pos < max and isWhitespace(buf[pos])) : (pos += 1) {}
            break :blk pos;
        },
        .WORD => blk: {
            // Skip non-whitespace
            while (pos < max and !isWhitespace(buf[pos])) : (pos += 1) {}
            // Skip whitespace
            while (pos < max and isWhitespace(buf[pos])) : (pos += 1) {}
            break :blk pos;
        },
        .word_end => blk: {
            // Move forward one if we're on the last char of a word
            if (pos < max and isWordChar(buf[pos]) and
                (pos + 1 >= max or !isWordChar(buf[pos + 1])))
            {
                pos += 1;
            }
            // Skip whitespace
            while (pos < max and isWhitespace(buf[pos])) : (pos += 1) {}
            // Move to end of word
            while (pos < max and isWordChar(buf[pos])) : (pos += 1) {}
            // Back up one to be ON the last character
            if (pos > self.edit_buf.cursor) pos -= 1;
            break :blk pos;
        },
        .WORD_end => blk: {
            // Move forward one if we're on the last char of a WORD
            if (pos < max and !isWhitespace(buf[pos]) and
                (pos + 1 >= max or isWhitespace(buf[pos + 1])))
            {
                pos += 1;
            }
            // Skip whitespace
            while (pos < max and isWhitespace(buf[pos])) : (pos += 1) {}
            // Move to end of WORD
            while (pos < max and !isWhitespace(buf[pos])) : (pos += 1) {}
            // Back up one to be ON the last character
            if (pos > self.edit_buf.cursor) pos -= 1;
            break :blk pos;
        },
    };
}

fn findWordBackward(self: *Shell, boundary: WordBoundary) usize {
    const buf = self.edit_buf.slice();
    if (self.edit_buf.cursor == 0) return 0;

    var pos = self.edit_buf.cursor - 1;

    return switch (boundary) {
        .word, .word_end => blk: {
            // Skip whitespace
            while (pos > 0 and isWhitespace(buf[pos])) : (pos -= 1) {}
            // Skip to beginning of word
            while (pos > 0 and isWordChar(buf[pos - 1])) : (pos -= 1) {}
            break :blk pos;
        },
        .WORD, .WORD_end => blk: {
            // Skip whitespace
            while (pos > 0 and isWhitespace(buf[pos])) : (pos -= 1) {}
            // Skip to beginning of WORD
            while (pos > 0 and !isWhitespace(buf[pos - 1])) : (pos -= 1) {}
            break :blk pos;
        },
    };
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

