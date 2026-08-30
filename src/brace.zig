//! brace.zig — brace expansion ({a,b,c}, {1..5}), extracted from Shell.zig.
//! Pure over an allocator + input string; no shell state.
const std = @import("std");

// limits to prevent pathological input from causing resource exhaustion
const BRACE_MAX_DEPTH: u8 = 10; // max nesting depth for brace expansion
const BRACE_MAX_RANGE: u32 = 10000; // max elements in a numeric range
const BRACE_MAX_RESULTS: u32 = 100000; // max total expansion results

/// Expand brace patterns like {a,b,c} and {1..5}
/// Returns array of expanded strings (caller owns memory)
/// An endpoint is "zero-padded" (bash sense) when its digit part after an
/// optional sign is >= 2 chars and starts with '0'.
fn braceIsPadded(s: []const u8) bool {
    var t = s;
    if (t.len > 0 and (t[0] == '-' or t[0] == '+')) t = t[1..];
    return t.len >= 2 and t[0] == '0';
}

/// bash pads a numeric range when either endpoint is zero-padded; the field
/// width is the widest raw endpoint (sign included). Returns 0 for no padding.
fn bracePadWidth(a: []const u8, b: []const u8) usize {
    const a_pad = braceIsPadded(a);
    const b_pad = braceIsPadded(b);
    if (!a_pad and !b_pad) return 0;
    return @max(a.len, b.len);
}

/// Format an integer into a field of `width` chars, zero-padded, with the sign
/// occupying one slot inside the width (bash: -05, 000, 005 all width 3).
fn formatPadded(buf: []u8, n: i64, width: usize) ![]const u8 {
    if (width == 0) return std.fmt.bufPrint(buf, "{d}", .{n});
    const neg = n < 0;
    const mag: u64 = if (neg) @intCast(-n) else @intCast(n);
    const digits = if (neg and width > 0) width - 1 else width;
    if (neg) {
        return std.fmt.bufPrint(buf, "-{d:0>[1]}", .{ mag, digits });
    } else {
        return std.fmt.bufPrint(buf, "{d:0>[1]}", .{ mag, digits });
    }
}

pub fn expandBraces(allocator: std.mem.Allocator, input: []const u8) ![][]const u8 {
    return expandBracesWithDepth(allocator, input, 0);
}

fn expandBracesWithDepth(allocator: std.mem.Allocator, input: []const u8, depth: u8) ![][]const u8 {
    // prevent stack overflow from deeply nested braces
    if (depth >= BRACE_MAX_DEPTH) {
        const result = try allocator.alloc([]const u8, 1);
        result[0] = try allocator.dupe(u8, input);
        return result;
    }

    // fast path: no braces
    if (std.mem.indexOfScalar(u8, input, '{') == null) {
        const result = try allocator.alloc([]const u8, 1);
        result[0] = try allocator.dupe(u8, input);
        return result;
    }

    // find the first complete brace group
    var brace_start: ?usize = null;
    var brace_end: ?usize = null;
    var brace_depth: u32 = 0;
    var has_comma_or_range = false;

    for (input, 0..) |c, i| {
        if (c == '{') {
            if (brace_depth == 0) brace_start = i;
            brace_depth += 1;
        } else if (c == '}') {
            if (brace_depth > 0) {
                brace_depth -= 1;
                if (brace_depth == 0) {
                    brace_end = i;
                    break;
                }
            }
        } else if (brace_depth == 1) {
            if (c == ',' or (c == '.' and i + 1 < input.len and input[i + 1] == '.')) {
                has_comma_or_range = true;
            }
        }
    }

    // no valid brace pattern found
    if (brace_start == null or brace_end == null or !has_comma_or_range) {
        const result = try allocator.alloc([]const u8, 1);
        result[0] = try allocator.dupe(u8, input);
        return result;
    }

    const start = brace_start.?;
    const end = brace_end.?;
    const prefix = input[0..start];
    const suffix = input[end + 1 ..];
    const brace_content = input[start + 1 .. end];

    // parse brace content
    var expansions: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (expansions.items) |exp| allocator.free(exp);
        expansions.deinit(allocator);
    }

    // check for range pattern like {1..5}, {1..10..2}, {a..z}, {z..a..2}
    if (std.mem.indexOf(u8, brace_content, "..")) |range_pos| {
        const range_start_str = brace_content[0..range_pos];
        const rest = brace_content[range_pos + 2 ..];

        // optional step: second ".." splits end from step
        var range_end_str = rest;
        var step_str: ?[]const u8 = null;
        if (std.mem.indexOf(u8, rest, "..")) |step_pos| {
            range_end_str = rest[0..step_pos];
            step_str = rest[step_pos + 2 ..];
        }

        // try numeric range
        if (std.fmt.parseInt(i64, range_start_str, 10)) |start_num| {
            if (std.fmt.parseInt(i64, range_end_str, 10)) |end_num| {
                // parse step magnitude (bash: sign of step is ignored, direction
                // is derived from the endpoints). Default step is 1.
                var step_mag: i64 = 1;
                if (step_str) |ss| {
                    if (std.fmt.parseInt(i64, ss, 10)) |sv| {
                        step_mag = if (sv < 0) -sv else sv;
                    } else |_| {}
                }
                if (step_mag == 0) step_mag = 1;

                // zero-padding: bash pads output to the widest endpoint when
                // either endpoint has a leading zero (after optional sign).
                const pad_width = bracePadWidth(range_start_str, range_end_str);

                const span: i64 = if (end_num >= start_num) end_num - start_num else start_num - end_num;
                const range_size: u64 = @as(u64, @intCast(@divFloor(span, step_mag))) + 1;
                if (range_size > BRACE_MAX_RANGE) {
                    const result = try allocator.alloc([]const u8, 1);
                    result[0] = try allocator.dupe(u8, input);
                    return result;
                }

                const step: i64 = if (start_num <= end_num) step_mag else -step_mag;
                var n = start_num;
                while (true) {
                    var buf: [32]u8 = undefined;
                    const num_str = formatPadded(&buf, n, pad_width) catch break;
                    try expansions.append(allocator, try allocator.dupe(u8, num_str));
                    // stop once we would pass end_num (step may overshoot)
                    if (step > 0) {
                        if (n + step > end_num) break;
                    } else {
                        if (n + step < end_num) break;
                    }
                    n += step;
                }
            } else |_| {}
        } else |_| {
            // character range (single-char endpoints)
            if (range_start_str.len == 1 and range_end_str.len == 1) {
                const start_char = range_start_str[0];
                const end_char = range_end_str[0];
                var step_mag: i32 = 1;
                if (step_str) |ss| {
                    if (std.fmt.parseInt(i32, ss, 10)) |sv| {
                        step_mag = if (sv < 0) -sv else sv;
                    } else |_| {}
                }
                if (step_mag == 0) step_mag = 1;
                const step: i32 = if (start_char <= end_char) step_mag else -step_mag;
                var c: i32 = start_char;
                while (true) {
                    try expansions.append(allocator, try allocator.dupe(u8, &[_]u8{@intCast(c)}));
                    if (step > 0) {
                        if (c + step > end_char) break;
                    } else {
                        if (c + step < end_char) break;
                    }
                    c += step;
                }
            }
        }
    }

    // if range didn't produce expansions, parse as comma-separated list
    if (expansions.items.len == 0) {
        var item_start: usize = 0;
        var item_depth: u32 = 0;
        for (brace_content, 0..) |c, i| {
            if (c == '{') {
                item_depth += 1;
            } else if (c == '}') {
                if (item_depth > 0) item_depth -= 1;
            } else if (c == ',' and item_depth == 0) {
                try expansions.append(allocator, try allocator.dupe(u8, brace_content[item_start..i]));
                item_start = i + 1;
            }
        }
        // last item
        try expansions.append(allocator, try allocator.dupe(u8, brace_content[item_start..]));
    }

    // build results with prefix and suffix, then recursively expand
    var results: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (results.items) |r| allocator.free(r);
        results.deinit(allocator);
    }

    for (expansions.items) |exp| {
        // build: prefix + exp + suffix
        const combined = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, exp, suffix });
        defer allocator.free(combined);

        // recursively expand any remaining braces (with depth tracking)
        const sub_results = try expandBracesWithDepth(allocator, combined, depth + 1);
        defer allocator.free(sub_results);

        for (sub_results) |sub| {
            // enforce total result limit
            if (results.items.len >= BRACE_MAX_RESULTS) {
                allocator.free(sub);
                continue;
            }
            try results.append(allocator, sub);
        }
    }

    // clear expansions without freeing (we already transferred ownership conceptually,
    // but the errdefer above handles cleanup, and we've moved strings to results)
    expansions.clearRetainingCapacity();

    return try results.toOwnedSlice(allocator);
}

/// Free brace expansion results
pub fn freeBraceResults(allocator: std.mem.Allocator, results: [][]const u8) void {
    for (results) |r| allocator.free(r);
    allocator.free(results);
}

/// Check if input contains brace expansion patterns.
/// A `${...}` parameter expansion is NOT a brace group: its `{` is preceded by `$`,
/// and any commas/dots inside it (e.g. ${x,,}, ${x/a,b/c}) must not be mistaken for a
/// brace-list/range. Such groups are skipped whole.
pub fn hasBracePattern(input: []const u8) bool {
    var depth: u32 = 0;
    var has_content = false;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (c == '{') {
            // Parameter expansion `${` — skip the balanced group.
            if (i > 0 and input[i - 1] == '$') {
                var pdepth: u32 = 1;
                i += 1;
                while (i < input.len and pdepth > 0) : (i += 1) {
                    if (input[i] == '{') pdepth += 1 else if (input[i] == '}') pdepth -= 1;
                    if (pdepth == 0) break;
                }
                continue;
            }
            depth += 1;
        } else if (c == '}') {
            if (depth > 0) {
                depth -= 1;
                if (depth == 0 and has_content) return true;
            }
        } else if (depth == 1) {
            if (c == ',' or (c == '.' and i + 1 < input.len and input[i + 1] == '.')) {
                has_content = true;
            }
        }
    }
    return false;
}
