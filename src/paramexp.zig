//! paramexp.zig — ${var#..}/${var%..}/${var/a/b} parameter-expansion string
//! ops, extracted from Shell.zig. Pure functions (allocator passed in); the
//! only dependency is glob matching.
const std = @import("std");
const glob = @import("glob.zig");

pub fn isSubstringOffset(rest: []const u8) bool {
    if (rest.len == 0) return false;
    const c = rest[0];
    if (std.ascii.isDigit(c)) return true;
    if (c == '(') return true;
    if (c == ' ' or c == '\t') return true;
    return false;
}

/// Parse a substring offset/length expression starting at input[i.*], advancing i.
/// Handles an optional '(' ... ')' arithmetic wrapper and a leading sign.
pub fn parseOffsetExpr(input: []const u8, i: *usize) i64 {
    var paren = false;
    if (i.* < input.len and input[i.*] == '(') {
        paren = true;
        i.* += 1;
        while (i.* < input.len and (input[i.*] == ' ' or input[i.*] == '\t')) i.* += 1;
    }
    const start = i.*;
    if (i.* < input.len and (input[i.*] == '-' or input[i.*] == '+')) i.* += 1;
    while (i.* < input.len and std.ascii.isDigit(input[i.*])) i.* += 1;
    const num_str = input[start..i.*];
    const val = std.fmt.parseInt(i64, num_str, 10) catch 0;
    if (paren) {
        while (i.* < input.len and input[i.*] != ')') i.* += 1;
        if (i.* < input.len and input[i.*] == ')') i.* += 1;
    }
    return val;
}

pub fn stripPrefix(str: []const u8, pattern: []const u8, greedy: bool) []const u8 {
    if (str.len == 0 or pattern.len == 0) return str;

    // For greedy, try matching from longest to shortest
    // For non-greedy, try matching from shortest to longest
    if (greedy) {
        var match_len = str.len;
        while (match_len > 0) : (match_len -= 1) {
            if (glob.matchGlob(pattern, str[0..match_len])) {
                return str[match_len..];
            }
        }
    } else {
        var match_len: usize = 1;
        while (match_len <= str.len) : (match_len += 1) {
            if (glob.matchGlob(pattern, str[0..match_len])) {
                return str[match_len..];
            }
        }
    }
    return str;
}

/// Strip suffix from string using glob pattern matching
/// If greedy is true, removes longest match; otherwise removes shortest match
pub fn stripSuffix(str: []const u8, pattern: []const u8, greedy: bool) []const u8 {
    if (str.len == 0 or pattern.len == 0) return str;

    // For greedy, try matching from longest to shortest
    // For non-greedy, try matching from shortest to longest
    if (greedy) {
        var match_start: usize = 0;
        while (match_start < str.len) : (match_start += 1) {
            if (glob.matchGlob(pattern, str[match_start..])) {
                return str[0..match_start];
            }
        }
    } else {
        var match_start = str.len;
        while (match_start > 0) : (match_start -= 1) {
            if (glob.matchGlob(pattern, str[match_start - 1 ..])) {
                return str[0 .. match_start - 1];
            }
        }
    }
    return str;
}

/// Replace pattern in string with replacement
/// If replace_all is true, replaces all occurrences; otherwise only first
pub fn patternReplace(allocator: std.mem.Allocator, str: []const u8, pattern: []const u8, replacement: []const u8, replace_all: bool) ![]const u8 {
    if (str.len == 0 or pattern.len == 0) return try allocator.dupe(u8, str);

    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(allocator);

    var i: usize = 0;
    var replaced = false;

    while (i < str.len) {
        // Try to match pattern at this position
        var matched = false;
        if (!replaced or replace_all) {
            // Try each possible match length at this position
            var match_len = str.len - i;
            while (match_len > 0) : (match_len -= 1) {
                if (glob.matchGlob(pattern, str[i .. i + match_len])) {
                    try result.appendSlice(allocator, replacement);
                    i += match_len;
                    matched = true;
                    replaced = true;
                    break;
                }
            }
        }

        if (!matched) {
            try result.append(allocator, str[i]);
            i += 1;
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Pattern substitution with optional anchoring.
/// anchor: 0 = unanchored (delegates to patternReplace), '#' = match only at
/// the start of the string, '%' = match only at the end.
pub fn patternReplaceAnchored(allocator: std.mem.Allocator, str: []const u8, pattern: []const u8, replacement: []const u8, replace_all: bool, anchor: u8) ![]const u8 {
    if (anchor == 0) return patternReplace(allocator, str, pattern, replacement, replace_all);
    if (pattern.len == 0) return allocator.dupe(u8, str);

    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(allocator);

    if (anchor == '#') {
        // Longest match anchored at start.
        var match_len = str.len;
        while (true) : (match_len -= 1) {
            if (glob.matchGlob(pattern, str[0..match_len])) {
                try result.appendSlice(allocator, replacement);
                try result.appendSlice(allocator, str[match_len..]);
                return result.toOwnedSlice(allocator);
            }
            if (match_len == 0) break;
        }
    } else { // '%' - longest match anchored at end
        var start: usize = 0;
        while (start <= str.len) : (start += 1) {
            if (glob.matchGlob(pattern, str[start..])) {
                try result.appendSlice(allocator, str[0..start]);
                try result.appendSlice(allocator, replacement);
                return result.toOwnedSlice(allocator);
            }
        }
    }
    return allocator.dupe(u8, str);
}
