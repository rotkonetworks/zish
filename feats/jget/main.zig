// jget - pull one value out of a JSON *document* by path.
//   jget PATH [FILE]         value on stdout: strings unquoted, numbers raw
//   jget -j PATH [FILE]      the raw JSON subtree at PATH
//   jget -q PATH [FILE]      no output, exit status is the answer
//
// PATH is dot-separated, with integer elements indexing arrays:
//   result.sync_info.latest_block_height
//   markets.0.ticker
//
// Why a feat: `jls` scans a scalar after `"key":` on a *line*, so it returns
// nothing for a nested object — on a real cometbft `/status` payload it silently
// prints nothing, which is how a block-height reader ends up shelling out to
// pcli every 2 s. This one walks the document properly (brace/bracket matching
// that respects string escapes), so nested paths work on real payloads.
//
// It is a reader, not a validator: it finds the path and prints exactly the
// bytes there. Malformed JSON is a miss (exit 1), not a parse error to explain.
const std = @import("std");
const feat = @import("lib/feat.zig");

const MAX_INPUT = 64 * 1024 * 1024;

/// Skip whitespace, return the index of the next significant byte.
fn skipWs(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len and (s[j] == ' ' or s[j] == '\t' or s[j] == '\n' or s[j] == '\r')) j += 1;
    return j;
}

/// End index (exclusive) of the string starting at s[i] == '"'.
fn stringEnd(s: []const u8, i: usize) ?usize {
    var j = i + 1;
    while (j < s.len) {
        if (s[j] == '\\') {
            j += 2;
            continue;
        }
        if (s[j] == '"') return j + 1;
        j += 1;
    }
    return null;
}

/// End index (exclusive) of the value starting at i (object, array, string,
/// number, true/false/null), by matching brackets and respecting strings.
fn valueEnd(s: []const u8, i: usize) ?usize {
    const start = skipWs(s, i);
    if (start >= s.len) return null;
    switch (s[start]) {
        '"' => return stringEnd(s, start),
        '{', '[' => {
            const open = s[start];
            const close: u8 = if (open == '{') '}' else ']';
            var depth: usize = 0;
            var j = start;
            while (j < s.len) {
                const c = s[j];
                if (c == '"') {
                    j = stringEnd(s, j) orelse return null;
                    continue;
                }
                if (c == open) depth += 1;
                if (c == close) {
                    depth -= 1;
                    if (depth == 0) return j + 1;
                }
                j += 1;
            }
            return null;
        },
        else => {
            var j = start;
            while (j < s.len and s[j] != ',' and s[j] != '}' and s[j] != ']' and
                s[j] != ' ' and s[j] != '\t' and s[j] != '\n' and s[j] != '\r') j += 1;
            return j;
        },
    }
}

/// The value bytes for object key `key` inside the object starting at s[i] == '{'.
fn objectMember(s: []const u8, i: usize, key: []const u8) ?[]const u8 {
    var j = skipWs(s, i);
    if (j >= s.len or s[j] != '{') return null;
    j += 1;
    while (j < s.len) {
        j = skipWs(s, j);
        if (j >= s.len) return null;
        if (s[j] == '}') return null;
        if (s[j] != '"') return null;
        const ke = stringEnd(s, j) orelse return null;
        const this_key = s[j + 1 .. ke - 1];
        j = skipWs(s, ke);
        if (j >= s.len or s[j] != ':') return null;
        j = skipWs(s, j + 1);
        const ve = valueEnd(s, j) orelse return null;
        if (std.mem.eql(u8, this_key, key)) return s[j..ve];
        j = skipWs(s, ve);
        if (j < s.len and s[j] == ',') j += 1 else return null;
    }
    return null;
}

/// The element at index `n` inside the array starting at s[i] == '['.
fn arrayIndex(s: []const u8, i: usize, n: usize) ?[]const u8 {
    var j = skipWs(s, i);
    if (j >= s.len or s[j] != '[') return null;
    j += 1;
    var idx: usize = 0;
    while (j < s.len) {
        j = skipWs(s, j);
        if (j >= s.len or s[j] == ']') return null;
        const ve = valueEnd(s, j) orelse return null;
        if (idx == n) return s[j..ve];
        idx += 1;
        j = skipWs(s, ve);
        if (j < s.len and s[j] == ',') j += 1 else return null;
    }
    return null;
}

fn walk(doc: []const u8, path: []const u8) ?[]const u8 {
    var cur: []const u8 = doc;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        const is_index = std.fmt.parseInt(usize, part, 10) catch null;
        if (is_index) |n| {
            // array element: cur must be the array
            cur = arrayIndex(cur, 0, n) orelse return null;
        } else {
            cur = objectMember(cur, 0, part) orelse return null;
        }
    }
    return cur;
}

pub fn main(init: std.process.Init) void {
    feat.restoreSigpipe();
    const alloc = init.gpa;
    const arena = init.arena.allocator();
    const argv = init.minimal.args.toSlice(arena) catch return;

    var raw = false;
    var quiet = false;
    var path: ?[]const u8 = null;
    var file: ?[]const u8 = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "-j")) raw = true else if (std.mem.eql(u8, a, "-q")) quiet = true else if (path == null) path = a else file = a;
    }
    const p = path orelse {
        _ = feat.err(init.io, "usage: jget [-j|-q] PATH [FILE]\n");
        std.process.exit(feat.EXIT_USAGE);
    };

    const data: []const u8 = if (file) |f|
        feat.readFile(alloc, init.io, f, MAX_INPUT) catch {
            _ = feat.eprint(init.io, "jget: cannot read {s}\n", .{f});
            std.process.exit(feat.EXIT_FAIL);
        }
    else blk: {
        if (feat.stdinIsTty(init.io)) {
            _ = feat.err(init.io, "jget: no input (stdin is a terminal)\n");
            std.process.exit(feat.EXIT_USAGE);
        }
        break :blk feat.slurpStdin(alloc, init.io) catch {
            _ = feat.err(init.io, "jget: cannot read stdin\n");
            std.process.exit(feat.EXIT_FAIL);
        };
    };
    defer if (file != null) alloc.free(data);

    const v = walk(data, p) orelse std.process.exit(feat.EXIT_FAIL);
    if (quiet) return;

    if (raw) {
        _ = feat.out(init.io, v);
        _ = feat.out(init.io, "\n");
    } else if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') {
        // unescape the escapes that matter for a single line of output
        var buf: [8192]u8 = undefined;
        var n: usize = 0;
        var j: usize = 1;
        while (j + 1 < v.len and n < buf.len) : (j += 1) {
            if (v[j] == '\\' and j + 1 < v.len - 1) {
                j += 1;
                buf[n] = switch (v[j]) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    else => v[j],
                };
            } else {
                buf[n] = v[j];
            }
            n += 1;
        }
        _ = feat.out(init.io, buf[0..n]);
        _ = feat.out(init.io, "\n");
    } else {
        _ = feat.out(init.io, v);
        _ = feat.out(init.io, "\n");
    }
}
