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

fn expandSimpleGlob(allocator: std.mem.Allocator, pattern: []const u8) ![][]const u8 {
    var results = try std.ArrayList([]const u8).initCapacity(allocator, 16);
    errdefer {
        for (results.items) |item| allocator.free(item);
        results.deinit(allocator);
    }

    // split pattern into directory and filename parts
    const last_slash = std.mem.lastIndexOf(u8, pattern, "/");
    const dir_path = if (last_slash) |idx| pattern[0..idx] else ".";
    const file_pattern = if (last_slash) |idx| pattern[idx + 1 ..] else pattern;

    // open directory
    var dir = std.Io.Dir.cwd().openDir(compat.io(), dir_path, .{ .iterate = true }) catch {
        // if directory doesn't exist, return empty
        return try results.toOwnedSlice(allocator);
    };
    defer dir.close(compat.io());

    // A leading '.' in a filename is only matched when the pattern's first
    // char is a literal '.' (POSIX: hidden files hidden from wildcards).
    const pattern_matches_dot = file_pattern.len > 0 and file_pattern[0] == '.';

    // iterate and match
    var iter = dir.iterate();
    while (try iter.next(compat.io())) |entry| {
        if (entry.name.len > 0 and entry.name[0] == '.' and !pattern_matches_dot) continue;
        if (matchGlob(file_pattern, entry.name)) {
            const full_path = if (std.mem.eql(u8, dir_path, "."))
                try allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
            try results.append(allocator, full_path);
        }
    }

    // sort results for consistent output
    std.mem.sort([]const u8, results.items, {}, stringLessThan);

    return try results.toOwnedSlice(allocator);
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
    const suffix = if (star_star_idx + 2 < pattern.len) pattern[star_star_idx + 2 ..] else "";

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
