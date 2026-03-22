// render_pipeline.zig — Protected cursor positioning for the terminal line editor.
//
// The deferred-wrap correction has been accidentally deleted 3+ times because it
// lived at the bottom of a large render function. This module isolates it as a
// standalone function with regression tests so it cannot be clobbered by changes
// to content emission, syntax highlighting, or ghost text rendering.

const std = @import("std");
const editor = @import("editor.zig");

const TermView = editor.TermView;

/// Finalize cursor position after rendering, correcting for deferred terminal wrap.
///
/// After writing exactly w chars on a line, the terminal cursor stays at col w
/// of the current row — it does NOT advance to the next row until the next
/// character is written. When our tracking shows render_col=0 from a >= w wrap,
/// the terminal is actually 1 row behind. This function corrects for that before
/// calling moveTo, ensuring relative cursor movement is calculated from the
/// terminal's actual position.
pub fn positionCursor(
    view: *TermView,
    render_row: u16,
    render_col: u16,
    cursor_row: u16,
    cursor_col: u16,
    cursor_at_end: bool,
    width: u16,
    hash: u64,
    cursor_pos: u16,
) void {
    // Deferred wrap correction for render position
    const in_deferred_wrap = render_col == 0 and render_row > 0;
    view.term.row = if (in_deferred_wrap) render_row - 1 else render_row;
    view.term.col = if (in_deferred_wrap) width else render_col;

    // Deferred wrap correction for cursor target
    const cursor_deferred = cursor_col == 0 and cursor_row > 0 and cursor_at_end;
    view.moveTo(
        if (cursor_deferred) cursor_row - 1 else cursor_row,
        if (cursor_deferred) width else cursor_col,
    );

    // Save state for change detection
    view.term.rows_owned = render_row + 1;
    view.last_hash = hash;
    view.last_cursor = cursor_pos;
}

// ============================================================
// Tests
// ============================================================

test "deferred-wrap: render_col==0 corrects terminal row" {
    var view = TermView.init(std.posix.STDERR_FILENO);
    view.term.width = 80;
    view.term.row = 0;
    view.term.col = 0;

    // Content filled exactly 2 rows (render_col=0, render_row=2 → deferred wrap)
    positionCursor(&view, 2, 0, 0, 5, false, 80, 0x1234, 5);

    // moveTo targets cursor (row 0, col 5); intermediate correction was row=1, col=80
    try std.testing.expectEqual(@as(u16, 0), view.term.row);
    try std.testing.expectEqual(@as(u16, 5), view.term.col);
    try std.testing.expectEqual(@as(u16, 3), view.term.rows_owned);
    try std.testing.expectEqual(@as(u64, 0x1234), view.last_hash);
}

test "deferred-wrap: no adjustment when render_col != 0" {
    var view = TermView.init(std.posix.STDERR_FILENO);
    view.term.width = 80;

    positionCursor(&view, 1, 50, 1, 30, false, 80, 0xABCD, 90);

    try std.testing.expectEqual(@as(u16, 1), view.term.row);
    try std.testing.expectEqual(@as(u16, 30), view.term.col);
}

test "deferred-wrap: cursor at exact fill corrects cursor target" {
    var view = TermView.init(std.posix.STDERR_FILENO);
    view.term.width = 80;

    // cursor_col=0, cursor_row=1, cursor_at_end=true → deferred wrap for cursor too
    positionCursor(&view, 1, 0, 1, 0, true, 80, 0, 80);

    // Both render and cursor corrected: row 1 → 0
    try std.testing.expectEqual(@as(u16, 0), view.term.row);
}
