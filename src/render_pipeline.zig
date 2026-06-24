// render_pipeline.zig — Protected cursor positioning for the terminal line editor.
//
// The deferred-wrap correction has been accidentally deleted 3+ times because it
// lived at the bottom of a large render function. This module isolates it as a
// standalone function with regression tests so it cannot be clobbered by changes
// to content emission, syntax highlighting, or ghost text rendering.

const std = @import("std");
const compat = @import("compat.zig");
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
    // Viewport-overflow / wrap-induced scroll correction.
    //
    // When the rendered content (prompt + wrapped input) is taller than the
    // terminal viewport, emitting it scrolls the terminal: the prompt-start row
    // scrolls off the top and only the bottom `height` rows stay visible. The
    // cursor ends on the bottom visible row, so the number of rows physically
    // above it on-screen is at most `height - 1` — NOT render_row, which keeps
    // counting from the now off-screen prompt anchor.
    //
    // Without this clamp, the next render emits `\x1b[{render_row}A` (cursor up
    // by more rows than exist). A real terminal saturates that move at the top
    // margin (row 0); the following `\x1b[J` then erases from row 0 to the
    // bottom = the ENTIRE viewport, blanking the screen until the repaint lands.
    // (See render() in editor.zig: cursor-up + clear-to-EOS.) This is the
    // "small window blanks after 3-4 chars" bug.
    const height = view.term.height;
    const max_visible_row: u16 = if (height > 0) height - 1 else render_row;

    // Deferred wrap correction for render position
    const in_deferred_wrap = render_col == 0 and render_row > 0;
    const raw_row: u16 = if (in_deferred_wrap) render_row - 1 else render_row;
    view.term.row = @min(raw_row, max_visible_row);
    view.term.col = if (in_deferred_wrap) width else render_col;

    // Deferred wrap correction for cursor target. The target is in the same
    // content-row coordinates; when content overflows the viewport, shift it up
    // by the scrolled-off rows so it stays within the visible region.
    const scrolled_off: u16 = if (height > 0 and render_row > max_visible_row)
        render_row - max_visible_row
    else
        0;
    const cursor_deferred = cursor_col == 0 and cursor_row > 0 and cursor_at_end;
    const target_row: u16 = if (cursor_deferred) cursor_row - 1 else cursor_row;
    view.moveTo(
        target_row -| scrolled_off,
        if (cursor_deferred) width else cursor_col,
    );

    // Save state for change detection. rows_owned reflects on-screen rows so the
    // next "move to region start" never exceeds the viewport.
    view.term.rows_owned = @min(render_row + 1, max_visible_row + 1);
    view.last_hash = hash;
    view.last_cursor = cursor_pos;
}

// ============================================================
// Tests
// ============================================================

test "deferred-wrap: render_col==0 corrects terminal row" {
    var view = TermView.init(compat.posix.STDERR_FILENO);
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
    var view = TermView.init(compat.posix.STDERR_FILENO);
    view.term.width = 80;

    positionCursor(&view, 1, 50, 1, 30, false, 80, 0xABCD, 90);

    try std.testing.expectEqual(@as(u16, 1), view.term.row);
    try std.testing.expectEqual(@as(u16, 30), view.term.col);
}

test "deferred-wrap: cursor at exact fill corrects cursor target" {
    var view = TermView.init(compat.posix.STDERR_FILENO);
    view.term.width = 80;

    // cursor_col=0, cursor_row=1, cursor_at_end=true → deferred wrap for cursor too
    positionCursor(&view, 1, 0, 1, 0, true, 80, 0, 80);

    // Both render and cursor corrected: row 1 → 0
    try std.testing.expectEqual(@as(u16, 0), view.term.row);
}

test "viewport overflow: term.row clamped to height-1 (small-window blank fix)" {
    var view = TermView.init(compat.posix.STDERR_FILENO);
    view.term.width = 12;
    view.term.height = 3; // short window: only rows 0..2 visible

    // Content wrapped to 5 rows in a 3-row viewport — the terminal scrolled, so
    // the prompt anchor is off-screen. render_row=4, cursor at the end.
    positionCursor(&view, 4, 6, 4, 6, true, 12, 0xBEEF, 60);

    // term.row must never exceed height-1, or the next render's \x1b[{row}A
    // overshoots and \x1b[J blanks the whole viewport.
    try std.testing.expect(view.term.row <= 2);
    try std.testing.expect(view.term.rows_owned <= 3);
}

test "viewport overflow: height==0 (unknown) falls back to no clamp" {
    var view = TermView.init(compat.posix.STDERR_FILENO);
    view.term.width = 80;
    view.term.height = 0; // size not yet known

    positionCursor(&view, 3, 10, 3, 10, false, 80, 0, 40);
    // With unknown height, behave as before (no clamp): term.row == render_row
    try std.testing.expectEqual(@as(u16, 3), view.term.row);
}
