// glob.zig - wildcard pattern matching and expansion

const std = @import("std");
const compat = @import("compat.zig");

pub fn expandGlob(allocator: std.mem.Allocator, pattern: []const u8) ![][]const u8 {
    // check if pattern contains glob characters
    if (!hasGlobChars(pattern)) {
        // no glob chars, return as-is
        const result = try allocator.alloc([]const u8, 1);
        result[0] = try allocator.dupe(u8, pattern);
        return result;
    }

    // handle different glob types
    if (std.mem.indexOf(u8, pattern, "**") != null) {
        return expandRecursiveGlob(allocator, pattern);
    } else {
        return expandSimpleGlob(allocator, pattern);
    }
}

// Glob character check using lookup table
const glob_char_table: [256]bool = blk: {
    var table = [_]bool{false} ** 256;
    table['*'] = true;
    table['?'] = true;
    table['['] = true;
    break :blk table;
};

pub inline fn hasGlobChars(pattern: []const u8) bool {
    for (pattern) |c| {
        if (glob_char_table[c]) return true;
    }
    return false;
}

fn joinPath(allocator: std.mem.Allocator, prefix: []const u8, name: []const u8) ![]const u8 {
    if (prefix.len == 0 or prefix[prefix.len - 1] == '/')
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, name });
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name });
}

fn isDirPath(path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(compat.io(), path, .{}) catch return false;
    return st.kind == .directory;
}

fn freeList(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |item| allocator.free(item);
    list.deinit(allocator);
}

// Expands one path component at a time. Splitting at the last '/' and opening
// the directory half literally can't do `*/main.zig`: there is no directory
// called `*`, so the pattern silently came back unexpanded.
fn expandSimpleGlob(allocator: std.mem.Allocator, pattern: []const u8) ![][]const u8 {
    // leading slashes are kept verbatim (`//x` stays `//x`, as in bash)
    var lead: usize = 0;
    while (lead < pattern.len and pattern[lead] == '/') lead += 1;

    // candidate prefixes so far; "" joins as "name", "/" joins as "/name"
    var prefixes = try std.ArrayList([]const u8).initCapacity(allocator, 8);
    errdefer freeList(allocator, &prefixes);
    try prefixes.append(allocator, try allocator.dupe(u8, pattern[0..lead]));

    var it = std.mem.splitScalar(u8, pattern[lead..], '/');
    while (it.next()) |comp| {
        const is_last = it.peek() == null;
        if (comp.len == 0 and !is_last) continue; // `a//b` is `a/b`

        var next = try std.ArrayList([]const u8).initCapacity(allocator, 16);
        errdefer freeList(allocator, &next);

        for (prefixes.items) |prefix| {
            if (comp.len == 0) {
                // trailing slash: directories only, keep the slash
                if (isDirPath(prefix)) try next.append(allocator, try joinPath(allocator, prefix, ""));
            } else if (!hasGlobChars(comp)) {
                const joined = try joinPath(allocator, prefix, comp);
                std.Io.Dir.cwd().access(compat.io(), joined, .{}) catch {
                    allocator.free(joined);
                    continue;
                };
                try next.append(allocator, joined);
            } else {
                const dir_path = if (prefix.len == 0) "." else prefix;
                var dir = std.Io.Dir.cwd().openDir(compat.io(), dir_path, .{ .iterate = true }) catch continue;
                defer dir.close(compat.io());

                // A leading '.' is only matched by a literal '.' in the pattern
                // (POSIX: hidden files hidden from wildcards).
                const matches_dot = comp[0] == '.';
                var iter = dir.iterate();
                while (try iter.next(compat.io())) |entry| {
                    if (entry.name.len > 0 and entry.name[0] == '.' and !matches_dot) continue;
                    if (!matchGlob(comp, entry.name)) continue;
                    // an intermediate component has to be enterable
                    if (!is_last and entry.kind != .directory and entry.kind != .sym_link) continue;
                    try next.append(allocator, try joinPath(allocator, prefix, entry.name));
                }
            }
        }

        freeList(allocator, &prefixes);
        prefixes = next;
    }

    std.mem.sort([]const u8, prefixes.items, {}, stringLessThan);
    return try prefixes.toOwnedSlice(allocator);
}

fn expandRecursiveGlob(allocator: std.mem.Allocator, pattern: []const u8) ![][]const u8 {
    var results = try std.ArrayList([]const u8).initCapacity(allocator, 16);
    errdefer {
        for (results.items) |item| allocator.free(item);
        results.deinit(allocator);
    }

    // split on **
    const star_star_idx = std.mem.indexOf(u8, pattern, "**") orelse return error.InvalidPattern;
    const prefix = pattern[0..star_star_idx];
    // `**/x`: the suffix is a filename, so it must not keep the '/'
    const suffix = std.mem.trimStart(u8, pattern[star_star_idx + 2 ..], "/");

    // start directory
    const start_dir = if (prefix.len > 0 and prefix[prefix.len - 1] == '/')
        prefix[0 .. prefix.len - 1]
    else if (prefix.len > 0)
        prefix
    else
        ".";

    // recursively walk directories (start at depth 0)
    try walkRecursive(allocator, &results, start_dir, suffix, 0);

    // sort results
    std.mem.sort([]const u8, results.items, {}, stringLessThan);

    return try results.toOwnedSlice(allocator);
}

const MAX_GLOB_DEPTH: u8 = 32; // prevent runaway recursion

fn walkRecursive(
    allocator: std.mem.Allocator,
    results: *std.ArrayList([]const u8),
    dir_path: []const u8,
    file_pattern: []const u8,
    depth: u8,
) !void {
    // depth limit to prevent stack overflow on deep/cyclic trees
    if (depth >= MAX_GLOB_DEPTH) return;

    var dir = std.Io.Dir.cwd().openDir(compat.io(), dir_path, .{ .iterate = true }) catch return;
    defer dir.close(compat.io());

    var iter = dir.iterate();
    while (try iter.next(compat.io())) |entry| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        defer allocator.free(full_path);

        // skip hidden files unless explicitly in pattern
        // (length-guarded like the same check in expandGlob — indexing [0] on an
        // empty name is an out-of-bounds read)
        if (entry.name.len > 0 and entry.name[0] == '.' and file_pattern.len > 0 and file_pattern[0] != '.') {
            continue;
        }

        // only recurse into real directories, skip symlinks to avoid loops
        if (entry.kind == .directory) {
            try walkRecursive(allocator, results, full_path, file_pattern, depth + 1);
        }

        // check if file matches pattern
        if (file_pattern.len == 0 or matchGlob(file_pattern, entry.name)) {
            const result = try allocator.dupe(u8, full_path);
            try results.append(allocator, result);
        }
    }
}

pub fn matchGlob(pattern: []const u8, text: []const u8) bool {
    return matchGlobImpl(pattern, text, 0, 0);
}

fn matchGlobImpl(pattern: []const u8, text: []const u8, p_idx: usize, t_idx: usize) bool {
    // end of pattern
    if (p_idx >= pattern.len) {
        return t_idx >= text.len;
    }

    // end of text
    if (t_idx >= text.len) {
        // remaining pattern must be all *
        for (pattern[p_idx..]) |c| {
            if (c != '*') return false;
        }
        return true;
    }

    const p_char = pattern[p_idx];

    if (p_char == '*') {
        // try matching zero or more characters
        // first try matching zero characters
        if (matchGlobImpl(pattern, text, p_idx + 1, t_idx)) {
            return true;
        }
        // then try matching one or more characters
        return matchGlobImpl(pattern, text, p_idx, t_idx + 1);
    } else if (p_char == '?') {
        // match any single character
        return matchGlobImpl(pattern, text, p_idx + 1, t_idx + 1);
    } else if (p_char == '[') {
        // character class
        const close_idx = std.mem.indexOfScalarPos(u8, pattern, p_idx, ']') orelse return false;
        const char_class = pattern[p_idx + 1 .. close_idx];
        const matched = matchCharClass(char_class, text[t_idx]);
        if (!matched) return false;
        return matchGlobImpl(pattern, text, close_idx + 1, t_idx + 1);
    } else {
        // literal character
        if (p_char != text[t_idx]) return false;
        return matchGlobImpl(pattern, text, p_idx + 1, t_idx + 1);
    }
}

fn matchCharClass(class: []const u8, char: u8) bool {
    if (class.len == 0) return false;

    const negated = class[0] == '!' or class[0] == '^';
    const chars = if (negated) class[1..] else class;

    var i: usize = 0;
    var matched = false;
    while (i < chars.len) : (i += 1) {
        if (i + 2 < chars.len and chars[i + 1] == '-') {
            // range: a-z
            const start = chars[i];
            const end = chars[i + 2];
            if (char >= start and char <= end) {
                matched = true;
                break;
            }
            i += 2;
        } else {
            // single char
            if (char == chars[i]) {
                matched = true;
                break;
            }
        }
    }

    return if (negated) !matched else matched;
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// free expanded glob results
pub fn freeGlobResults(allocator: std.mem.Allocator, results: [][]const u8) void {
    for (results) |item| {
        allocator.free(item);
    }
    allocator.free(results);
}
