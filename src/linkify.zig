// linkify.zig — detect and wrap file paths, URLs, and references with OSC 8 hyperlinks.
//
// Scans text for:
// - Absolute file paths: /foo/bar.zig, /home/alice/file.txt
// - Relative paths with extensions: src/main.zig, ./foo/bar.rs
// - file:line references: src/main.zig:42
// - URLs: https://example.com, http://...
// - Git short hashes: abc1234 (7+ hex chars after known prefixes)
//
// Wraps detected spans with OSC 8: \e]8;;URI\e\\TEXT\e]8;;\e\\
// Returns a new buffer with links inserted, or the original if nothing found.

const std = @import("std");

/// Write text to writer, wrapping detected paths/URLs with OSC 8 hyperlinks.
/// Dim gray underline for paths, cyan underline for URLs.
pub fn writeLinked(writer: anytype, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        // Check for URL
        if (i + 8 < text.len and (std.mem.startsWith(u8, text[i..], "https://") or std.mem.startsWith(u8, text[i..], "http://"))) {
            const url_start = i;
            while (i < text.len and text[i] != ' ' and text[i] != '\n' and text[i] != ')' and text[i] != ']' and text[i] != '>' and text[i] != '"' and text[i] != '\'' and text[i] != '\t') : (i += 1) {}
            // Strip trailing punctuation
            while (i > url_start and (text[i - 1] == '.' or text[i - 1] == ',' or text[i - 1] == ';')) : (i -= 1) {}
            const url = text[url_start..i];
            try writer.writeAll("\x1b]8;;");
            try writer.writeAll(url);
            try writer.writeAll("\x1b\\\x1b[4;36m");
            try writer.writeAll(url);
            try writer.writeAll("\x1b[24;39m\x1b]8;;\x1b\\");
            continue;
        }

        // Check for absolute path: / followed by path chars
        if (text[i] == '/' and i + 1 < text.len and isPathChar(text[i + 1]) and (i == 0 or !isPathChar(text[i - 1]))) {
            const path_start = i;
            while (i < text.len and isPathCharOrColon(text[i])) : (i += 1) {}
            // Must have at least one / separator and be reasonable length
            const path = text[path_start..i];
            if (path.len > 2 and std.mem.indexOfScalar(u8, path[1..], '/') != null) {
                // Check for :line suffix
                var file_path = path;
                var line_suffix: []const u8 = "";
                if (std.mem.lastIndexOfScalar(u8, path, ':')) |colon| {
                    if (colon > 0 and colon < path.len - 1) {
                        const after = path[colon + 1 ..];
                        var all_digits = true;
                        for (after) |ac| {
                            if (ac < '0' or ac > '9') { all_digits = false; break; }
                        }
                        if (all_digits and after.len <= 6) {
                            file_path = path[0..colon];
                            line_suffix = path[colon..];
                        }
                    }
                }
                // Strip trailing punctuation from path
                while (file_path.len > 1 and (file_path[file_path.len - 1] == '.' or file_path[file_path.len - 1] == ',' or file_path[file_path.len - 1] == ';' or file_path[file_path.len - 1] == ':')) {
                    file_path = file_path[0 .. file_path.len - 1];
                }
                try writer.writeAll("\x1b]8;;file://");
                try writer.writeAll(file_path);
                try writer.writeAll("\x1b\\\x1b[4m");
                try writer.writeAll(file_path);
                try writer.writeAll("\x1b[24m\x1b]8;;\x1b\\");
                if (line_suffix.len > 0) {
                    try writer.writeAll("\x1b[90m");
                    try writer.writeAll(line_suffix);
                    try writer.writeAll("\x1b[39m");
                }
                continue;
            }
            // Not a real path, rewind
            i = path_start;
        }

        // Regular character
        try writer.writeByte(text[i]);
        i += 1;
    }
}

fn isPathChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '/' or c == '.' or c == '_' or c == '-' or c == '+' or c == '~';
}

fn isPathCharOrColon(c: u8) bool {
    return isPathChar(c) or c == ':';
}
