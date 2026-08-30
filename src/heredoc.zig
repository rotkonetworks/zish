//! heredoc.zig — heredoc detection and materialization.
//!
//! A heredoc (`cmd << DELIM\nbody\nDELIM`) is rewritten into a plain input
//! redirect (`cmd < /tmp/zish_heredoc_XXXX`) before the parser ever sees it: the
//! body is written to an unlinkable temp file and the `<<` becomes a `<`. This
//! keeps the parser/evaluator ignorant of heredocs — they only ever handle file
//! redirects.
//!
//! Decoupled from Shell: every entry point takes an explicit allocator and, when
//! it needs to register a temp for later cleanup, a pointer to the caller's temps
//! list. No shell state, so no circular import.

const std = @import("std");
const compat = @import("compat.zig");

/// Byte offset of the first heredoc operator `<<` (not `<<<`) that is NOT inside
/// quotes and not in a comment. A raw-byte scan would mistake a literal `<<` in a
/// string (`echo "a << b"`) for a heredoc and miss the real one later in the
/// script.
pub fn findOp(command: []const u8) ?usize {
    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    var at_word_start = true;
    while (i < command.len) : (i += 1) {
        const c = command[i];
        if (in_single) {
            if (c == '\'') in_single = false;
            continue;
        }
        if (in_double) {
            if (c == '\\' and i + 1 < command.len) {
                i += 1;
            } else if (c == '"') in_double = false;
            continue;
        }
        switch (c) {
            '\\' => {
                if (i + 1 < command.len) i += 1;
                at_word_start = false;
                continue;
            },
            '\'' => {
                in_single = true;
                at_word_start = false;
                continue;
            },
            '"' => {
                in_double = true;
                at_word_start = false;
                continue;
            },
            '#' => {
                if (at_word_start) {
                    while (i < command.len and command[i] != '\n') : (i += 1) {}
                    at_word_start = true;
                    continue;
                }
                at_word_start = false;
                continue;
            },
            '<' => {
                if (i + 1 < command.len and command[i + 1] == '<') {
                    if (i + 2 < command.len and command[i + 2] == '<') {
                        i += 2; // here-string, not a heredoc
                        at_word_start = false;
                        continue;
                    }
                    return i;
                }
                at_word_start = false;
                continue;
            },
            ' ', '\t', '\n', ';', '|', '&', '(' => {
                at_word_start = true;
                continue;
            },
            else => {
                at_word_start = false;
                continue;
            },
        }
    }
    return null;
}

/// Characters that terminate an unquoted heredoc delimiter word.
fn isDelimEnd(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', ';', '|', '&', '<', '>', '(', ')' => true,
        else => false,
    };
}

/// Byte offset just past the delimiter word for the heredoc whose `<<` starts at
/// `pos`. Everything between here and the newline is the REST OF THE LINE
/// (redirects, pipes, `;`, `&&`, further heredocs) and must be preserved.
fn delimEnd(command: []const u8, pos: usize) usize {
    var j = pos + 2;
    if (j < command.len and command[j] == '-') j += 1;
    while (j < command.len and (command[j] == ' ' or command[j] == '\t')) : (j += 1) {}
    if (j >= command.len) return command.len;
    const quote = command[j];
    if (quote == '\'' or quote == '"') {
        j += 1;
        while (j < command.len and command[j] != quote) : (j += 1) {}
        if (j < command.len) j += 1; // consume closing quote
        return j;
    }
    while (j < command.len and !isDelimEnd(command[j])) : (j += 1) {}
    return j;
}

/// The delimiter word of the first heredoc in `command`, or null if there is none.
pub fn findDelimiter(command: []const u8) ?[]const u8 {
    if (findOp(command)) |i| {
        {
            // found <<, now parse delimiter
            var j = i + 2;
            // skip optional - for <<-
            if (j < command.len and command[j] == '-') j += 1;
            // skip whitespace
            while (j < command.len and (command[j] == ' ' or command[j] == '\t')) : (j += 1) {}
            if (j >= command.len) return null;

            // check for quoted delimiter
            const quote = command[j];
            if (quote == '\'' or quote == '"') {
                j += 1;
                const start = j;
                while (j < command.len and command[j] != quote) : (j += 1) {}
                if (j > start) return command[start..j];
            } else {
                // unquoted delimiter - word until whitespace/newline OR an
                // operator. Stopping only at whitespace absorbed `;` and `|`
                // into the delimiter, so `cat <<A; echo x` looked for a
                // delimiter line "A;" that never came.
                const start = j;
                while (j < command.len and !isDelimEnd(command[j])) : (j += 1) {}
                if (j > start) return command[start..j];
            }
        }
    }
    return null;
}

/// Detect heredoc operator flags at position `pos` (which points at the first
/// '<' of a "<<"). Returns whether it is <<- (strip tabs) and whether the
/// delimiter was quoted (no expansion of the body).
const Flags = struct { dash: bool, quoted: bool };
fn flags(command: []const u8, pos: usize) Flags {
    var j = pos + 2;
    var dash = false;
    if (j < command.len and command[j] == '-') {
        dash = true;
        j += 1;
    }
    while (j < command.len and (command[j] == ' ' or command[j] == '\t')) : (j += 1) {}
    const quoted = j < command.len and (command[j] == '\'' or command[j] == '"');
    return .{ .dash = dash, .quoted = quoted };
}

/// Preprocess heredoc: convert "cmd << DELIM\ncontent\nDELIM" to
/// "cmd < /tmp/zish_heredoc_XXXX". Registers each temp path in `temps` so the
/// caller can delete them when the enclosing command returns.
pub fn preprocess(
    allocator: std.mem.Allocator,
    temps: *std.ArrayList([]const u8),
    command: []const u8,
    delimiter: []const u8,
) ![]const u8 {
    // Find << position (quote/comment aware — must agree with findDelimiter)
    const heredoc_pos: usize = findOp(command) orelse 0;

    const hd_flags = flags(command, heredoc_pos);

    // Get part before <<
    const prefix = command[0..heredoc_pos];

    // Everything between the end of the delimiter word and the newline belongs
    // to the COMMAND, not to the heredoc: `cat <<A >out.txt`, `cat <<A | tr`,
    // `cat <<A && echo`, `cat <<A ; cat <<B`. Dropping this span would silently
    // lose the redirect/pipe.
    const de = delimEnd(command, heredoc_pos);
    var content_start: usize = de;
    while (content_start < command.len and command[content_start] != '\n') : (content_start += 1) {}
    const line_rest = command[de..content_start];
    if (content_start < command.len) content_start += 1; // skip the newline

    // Find where content ends (at delimiter line)
    // Scan line by line from content_start
    var content_end = content_start;
    var suffix_start: usize = command.len; // text after closing delimiter
    var found_delim = false;
    var line_start = content_start;
    while (line_start < command.len) {
        // find end of this line
        var line_end = line_start;
        while (line_end < command.len and command[line_end] != '\n') : (line_end += 1) {}

        // For <<- the closing delimiter may be preceded by tabs; otherwise it
        // must match exactly (POSIX: leading tabs stripped only with <<-).
        const raw_line = command[line_start..line_end];
        const cmp_line = if (hd_flags.dash) std.mem.trimStart(u8, raw_line, "\t") else raw_line;
        if (std.mem.eql(u8, cmp_line, delimiter)) {
            // This line is the delimiter - content ends before this line
            content_end = line_start;
            found_delim = true;
            // remove trailing newline from content if present
            if (content_end > content_start and command[content_end - 1] == '\n') {
                content_end -= 1;
            }
            // suffix is everything after the delimiter line
            suffix_start = if (line_end < command.len) line_end + 1 else line_end;
            break;
        }

        // move to next line
        if (line_end < command.len) {
            line_start = line_end + 1;
        } else {
            break;
        }
    }

    // Handle case where no delimiter was found (shouldn't happen if complete() returned true)
    if (!found_delim and content_start < command.len) {
        content_end = command.len;
    }

    var content = command[content_start..content_end];

    // <<- : strip leading tabs from every body line.
    var stripped_owned: ?[]u8 = null;
    defer if (stripped_owned) |s| allocator.free(s);
    if (hd_flags.dash and content.len > 0) {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        var ls: usize = 0;
        while (ls <= content.len) {
            var le = ls;
            while (le < content.len and content[le] != '\n') : (le += 1) {}
            const l = std.mem.trimStart(u8, content[ls..le], "\t");
            try out.appendSlice(allocator, l);
            if (le < content.len) try out.append(allocator, '\n');
            if (le >= content.len) break;
            ls = le + 1;
        }
        stripped_owned = try out.toOwnedSlice(allocator);
        content = stripped_owned.?;
    }

    // NOTE: the body is written to the temp file VERBATIM here. For an unquoted
    // delimiter, variable/command expansion is deferred to when the `<` redirect
    // is applied (execution time) so it sees assignments made earlier on the same
    // line, e.g. `x=EXP; cat <<C ... has $x ... C` must print `has EXP`. The
    // expand-vs-literal choice is encoded in the temp file name ("_e_" vs "_q_")
    // and consumed by applyRedirect in eval.zig.

    const suffix = std.mem.trim(u8, command[suffix_start..], " \t\r\n");

    // Write content to a temp file in /tmp, which is world-writable — so the
    // name must be unguessable and the create must not follow a planted
    // symlink. A predictable name (timestamp + counter) plus a symlink-following
    // O_CREAT|O_TRUNC was an arbitrary-file-overwrite: an attacker pre-creates
    // `/tmp/zish_heredoc_e_<ts>_1` as a symlink to a victim's file and the
    // heredoc body lands there. Now: 8 random bytes in the name, and
    // `.exclusive` (O_EXCL) so the create fails closed on any pre-existing path,
    // symlink included. The mode tag stays right after the prefix so
    // heredocTempMode() can still classify it.
    const mode_tag: u8 = if (hd_flags.quoted) 'q' else 'e';
    var rnd: [8]u8 = undefined;
    var path_buf: [80]u8 = undefined;
    var file: std.Io.File = undefined;
    var attempt: u8 = 0;
    const tmp_path = while (true) {
        compat.posix.randomBytes(&rnd);
        const p = std.fmt.bufPrint(&path_buf, "/tmp/zish_heredoc_{c}_{s}", .{ mode_tag, std.fmt.bytesToHex(rnd, .lower) }) catch return error.OutOfMemory;
        if (std.Io.Dir.createFileAbsolute(compat.io(), p, .{ .truncate = true, .exclusive = true, .permissions = .fromMode(0o600) })) |f| {
            file = f;
            break p;
        } else |err| {
            // PathAlreadyExists on a random 64-bit name means either the
            // 1-in-2^64 collision or an attacker spraying names; retry a few
            // times, then give up rather than fall back to an unsafe create.
            attempt += 1;
            if (err == error.PathAlreadyExists and attempt < 8) continue;
            return error.FileError;
        }
    };
    defer file.close(compat.io());
    compat.writeAll(file, content) catch return error.WriteError;
    compat.writeAll(file, "\n") catch return error.WriteError;

    // Record for cleanup when the enclosing executeCommand call returns.
    if (allocator.dupe(u8, tmp_path)) |owned| {
        temps.append(allocator, owned) catch allocator.free(owned);
    } else |_| {}

    // Build new command: prefix < /tmp/zish_heredoc_TS <line_rest>; suffix
    const need_suffix = suffix.len > 0;
    const total_len = prefix.len + 2 + tmp_path.len + line_rest.len + if (need_suffix) 1 + suffix.len else 0;
    const result = try allocator.alloc(u8, total_len);
    var pos: usize = 0;
    @memcpy(result[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    @memcpy(result[pos..][0..2], "< ");
    pos += 2;
    @memcpy(result[pos..][0..tmp_path.len], tmp_path);
    pos += tmp_path.len;
    @memcpy(result[pos..][0..line_rest.len], line_rest);
    pos += line_rest.len;
    if (need_suffix) {
        result[pos] = '\n';
        pos += 1;
        @memcpy(result[pos..][0..suffix.len], suffix);
    }

    // The suffix may contain further heredocs (cat <<A ...; cat <<B ...).
    // Process them too by recursing on the rewritten command.
    if (need_suffix) {
        if (findDelimiter(result)) |next_delim| {
            defer allocator.free(result);
            return try preprocess(allocator, temps, result, next_delim);
        }
    }

    return result;
}

/// Check if heredoc is complete (delimiter found on its own line).
pub fn complete(command: []const u8, delimiter: []const u8) bool {
    // find where heredoc content starts (after first newline after <<)
    var found_heredoc = false;
    var dash = false;
    var i: usize = 0;
    while (i + 1 < command.len) : (i += 1) {
        if (command[i] == '<' and command[i + 1] == '<') {
            if (i + 2 < command.len and command[i + 2] == '<') {
                i += 2;
                continue;
            }
            found_heredoc = true;
            dash = i + 2 < command.len and command[i + 2] == '-';
            // skip to end of line
            while (i < command.len and command[i] != '\n') : (i += 1) {}
            break;
        }
    }
    if (!found_heredoc) return true;

    // now check each line for the delimiter
    while (i < command.len) {
        // skip newline
        if (command[i] == '\n') i += 1;
        if (i >= command.len) break;

        // get this line
        const line_start = i;
        while (i < command.len and command[i] != '\n') : (i += 1) {}
        const line = command[line_start..i];

        // <<- allows leading tabs before the closing delimiter; otherwise the
        // line must match the delimiter exactly.
        const cmp = if (dash) std.mem.trimStart(u8, line, "\t") else line;
        if (std.mem.eql(u8, cmp, delimiter)) {
            return true;
        }
    }
    return false;
}

/// Delete and free every temp registered in `temps` above index `mark`,
/// restoring the list to its length at `mark`.
pub fn cleanupTemps(allocator: std.mem.Allocator, temps: *std.ArrayList([]const u8), mark: usize) void {
    while (temps.items.len > mark) {
        const p = temps.pop() orelse break;
        std.Io.Dir.deleteFileAbsolute(compat.io(), p) catch {};
        allocator.free(p);
    }
}
