//! sanitize.zig — escape-sequence sanitization for feat-rendered text.
//!
//! Everything a session feat asks zish to render (`say`, `stream`, `status`,
//! `prompt` questions) is HOSTILE INPUT: model output and tool stdout painted
//! onto the user's terminal. Unsanitized it can clobber terminal state or spoof
//! zish's own UI chrome (a forged "hunk accepted" card is an attack on the
//! review gate). This module is the single chokepoint: no feat-supplied byte
//! reaches the terminal except through here.
//!
//! Policy (deny by default; text comes out, control never does):
//!   - C0 controls are dropped, except '\n' and '\t'. In particular '\r' (line
//!     overwrite), BEL, and 0x7F (DEL) are dropped.
//!   - ESC starts a sequence; the WHOLE sequence is consumed and dropped:
//!       CSI  (ESC '[')            through its final byte 0x40..0x7E
//!       OSC  (ESC ']')            through BEL or ST (ESC '\')
//!       DCS/SOS/PM/APC (ESC 'P'/'X'/'^'/'_') through ST (BEL also accepted —
//!                                 lenient termination only widens what we DROP)
//!       ESC + intermediates (0x20..0x2F) through one final 0x30..0x7E
//!       any other ESC + one byte  (ESC 7, ESC c, ESC =, ...)
//!     A sequence unterminated at end-of-input is dropped entirely — the prefix
//!     must not leak. (Frames are sanitized independently; an escape split
//!     across two frames renders as garbled plain text, never as a live
//!     sequence — fail-safe.)
//!   - Bytes >= 0x80 are validated as UTF-8: well-formed sequences pass through
//!     intact (never strip continuation bytes — that corrupts every multibyte
//!     character); malformed bytes are dropped, which also kills raw 8-bit C1
//!     controls (a lone 0x9B is invalid UTF-8). Decoded C1 codepoints
//!     U+0080..U+009F (0xC2 0x80..0xC2 0x9F) are dropped too — some terminals
//!     honor U+009B as CSI even in UTF-8 mode.

const std = @import("std");

/// Write `text` to `writer` with all terminal control stripped per the module
/// policy. Stateless per call: callers sanitize each frame independently.
pub fn writeSanitized(writer: anytype, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == 0x1b) {
            i = skipEscape(text, i + 1);
            continue;
        }
        if (c < 0x20) {
            if (c == '\n' or c == '\t') try writer.writeByte(c);
            i += 1;
            continue;
        }
        if (c == 0x7f) {
            i += 1;
            continue;
        }
        if (c < 0x80) {
            try writer.writeByte(c);
            i += 1;
            continue;
        }
        // multibyte: pass only well-formed UTF-8, minus encoded C1 controls
        const len = std.unicode.utf8ByteSequenceLength(c) catch {
            i += 1; // invalid lead byte (incl. raw C1) — drop
            continue;
        };
        if (i + len > text.len or !std.unicode.utf8ValidateSlice(text[i .. i + len])) {
            i += 1; // truncated or malformed — drop the lead, resync
            continue;
        }
        if (len == 2 and c == 0xc2 and text[i + 1] <= 0x9f) {
            i += 2; // U+0080..U+009F: C1 control in UTF-8 clothing
            continue;
        }
        try writer.writeAll(text[i .. i + len]);
        i += len;
    }
}

/// `i` points just past an ESC. Return the index just past the end of the
/// escape sequence (or text.len if unterminated — the caller drops it all).
fn skipEscape(text: []const u8, i: usize) usize {
    if (i >= text.len) return text.len;
    switch (text[i]) {
        '[' => { // CSI: params 0x30..0x3F, intermediates 0x20..0x2F, final 0x40..0x7E
            var j = i + 1;
            while (j < text.len) : (j += 1) {
                const b = text[j];
                if (b >= 0x40 and b <= 0x7e) return j + 1;
                if (b < 0x20 or b > 0x3f) return j; // malformed: stop consuming, resync here
            }
            return text.len;
        },
        ']', 'P', 'X', '^', '_' => { // OSC / DCS / SOS / PM / APC: string until ST or BEL
            var j = i + 1;
            while (j < text.len) : (j += 1) {
                const b = text[j];
                if (b == 0x07) return j + 1; // BEL terminator
                if (b == 0x1b) {
                    if (j + 1 < text.len and text[j + 1] == '\\') return j + 2; // ST
                    return j; // bare ESC inside string: re-enter at the ESC
                }
            }
            return text.len;
        },
        0x20...0x2f => { // intermediates then one final 0x30..0x7E
            var j = i;
            while (j < text.len and text[j] >= 0x20 and text[j] <= 0x2f) : (j += 1) {}
            if (j < text.len and text[j] >= 0x30 and text[j] <= 0x7e) return j + 1;
            return j;
        },
        else => return i + 1, // two-byte sequence: ESC + one final
    }
}

fn expectSanitized(input: []const u8, expected: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeSanitized(&w, input);
    try std.testing.expectEqualStrings(expected, w.buffered());
}

test "plain text and UTF-8 pass through intact" {
    try expectSanitized("hello world", "hello world");
    try expectSanitized("h\xc3\xa9llo \xe2\x86\x92 \xf0\x9f\xa6\x80", "h\xc3\xa9llo \xe2\x86\x92 \xf0\x9f\xa6\x80");
    try expectSanitized("line1\nline2\ttabbed", "line1\nline2\ttabbed");
}

test "SGR and cursor CSI stripped, text kept" {
    try expectSanitized("a\x1b[31mred\x1b[0mb", "aredb");
    try expectSanitized("up\x1b[2Aover\x1b[10;20Hend", "upoverend");
    try expectSanitized("\x1b[?1049h", ""); // alt-screen switch
    try expectSanitized("\x1b[2J\x1b[H", ""); // clear screen + home
}

test "OSC stripped with both terminators" {
    try expectSanitized("\x1b]0;evil title\x07text", "text");
    try expectSanitized("\x1b]8;;https://evil\x1b\\link\x1b]8;;\x1b\\", "link");
}

test "DCS APC PM SOS strings stripped" {
    try expectSanitized("a\x1bPq payload\x1b\\b", "ab");
    try expectSanitized("a\x1b_apc data\x1b\\b", "ab");
    try expectSanitized("a\x1b^pm\x07b", "ab"); // lenient BEL terminator
    try expectSanitized("a\x1bXsos\x1b\\b", "ab");
}

test "unterminated sequences do not leak their prefix" {
    try expectSanitized("ok\x1b[31", "ok");
    try expectSanitized("ok\x1b]0;evil", "ok");
    try expectSanitized("ok\x1bP payload", "ok");
    try expectSanitized("ok\x1b", "ok");
}

test "C0 controls dropped except newline and tab" {
    try expectSanitized("a\x07b\rc\x08d\x00e", "abcde");
    try expectSanitized("keep\ttab\nand newline", "keep\ttab\nand newline");
    try expectSanitized("del\x7fchar", "delchar");
}

test "two-byte and charset escapes stripped" {
    try expectSanitized("a\x1b7b\x1b8c", "abc"); // save/restore cursor
    try expectSanitized("a\x1b(Bb", "ab"); // charset designator (ESC + intermediate + final)
    try expectSanitized("a\x1bcb", "ab"); // RIS full reset
}

test "raw and encoded C1 controls dropped, UTF-8 resyncs" {
    try expectSanitized("a\x9b31mb", "a31mb"); // lone 0x9B is invalid UTF-8, dropped
    try expectSanitized("a\xc2\x9b31mb", "a31mb"); // U+009B (CSI) in UTF-8
    try expectSanitized("a\xc2\x85b", "ab"); // U+0085 NEL
    try expectSanitized("a\xc3hello", "ahello"); // truncated 2-byte seq: drop lead, keep rest
    try expectSanitized("ok\xf0\x9f\xa6", "ok"); // truncated emoji at end (drops bytes, resync eats rest)
}
