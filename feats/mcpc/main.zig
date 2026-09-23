// mcpc - call one MCP tool and get its result, once, from any zish script.
//   mcpc [-t SECS] [-q] TOOL [JSON] -- CMD [ARGS...]
//
//   mcpc dex_tools_quote '{"params":{"input":"200000transfer/channel-18/erc20:0xa00C...","into":"penumbra"}}' \
//        -- penumbra-mcp --home /data/mcp serve --pcli-home /data/none --account 0
//   → {"height":...,"output":"75.5798penumbra","price":0.0003779,...}
//
// The result object is printed as one line of JSON, so `mcpc ... | jget price`
// composes; `-q` prints nothing and leaves the answer in the exit status.
//
// Why a feat: an MCP server is a *session* — stdin in, stdout out, one JSON-RPC
// object per line — and a shell cannot hold that. Piping a hand-written
// initialize + tools/call at a server and hoping the replies flush before stdin
// closes is what this replaces: the write end stays open until the matching
// response arrives, so a tool that takes 30 s (a cold liquidity-graph rebuild,
// say) is answered rather than truncated. `-t` bounds that wait.
//
// Zero libc: the child is reached through /usr/bin/env with this process's
// environment block, the same idiom verify and pen use.
const std = @import("std");
const feat = @import("lib/feat.zig");
const linux = std.os.linux;

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

const MAX_LINE = 16 * 1024 * 1024;

/// End index (exclusive) of the JSON value starting at s[i], by bracket
/// matching that respects strings.
fn valueEnd(s: []const u8, i: usize) ?usize {
    if (i >= s.len) return null;
    switch (s[i]) {
        '"' => {
            var j = i + 1;
            while (j < s.len) : (j += 1) {
                if (s[j] == '\\') {
                    j += 1;
                    continue;
                }
                if (s[j] == '"') return j + 1;
            }
            return null;
        },
        '{', '[' => {
            const close: u8 = if (s[i] == '{') '}' else ']';
            var depth: usize = 0;
            var in_str = false;
            var j = i;
            while (j < s.len) : (j += 1) {
                const c = s[j];
                if (in_str) {
                    if (c == '\\') {
                        j += 1;
                        continue;
                    }
                    if (c == '"') in_str = false;
                    continue;
                }
                if (c == '"') in_str = true else if (c == s[i]) depth += 1 else if (c == close) {
                    depth -= 1;
                    if (depth == 0) return j + 1;
                }
            }
            return null;
        },
        else => {
            var j = i;
            while (j < s.len and s[j] != ',' and s[j] != '}' and s[j] != ']' and s[j] != '\n') j += 1;
            return j;
        },
    }
}

/// The `result` value of a response line that carries `"id":ID`.
fn resultOf(line: []const u8, id: usize) ?[]const u8 {
    var needle_buf: [24]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"id\":{d}", .{id}) catch return null;
    if (std.mem.indexOf(u8, line, needle) == null) return null;
    const p = std.mem.indexOf(u8, line, "\"result\":") orelse {
        // an error response: surface it as the result so the caller sees why
        if (std.mem.indexOf(u8, line, "\"error\":")) |e| {
            const start = e + "\"error\":".len;
            const end = valueEnd(line, start) orelse return null;
            return line[start..end];
        }
        return null;
    };
    const start = p + "\"result\":".len;
    const end = valueEnd(line, start) orelse return null;
    return line[start..end];
}

/// Unescape the JSON string body at s (between the quotes) into `out`.
fn unescape(alloc: std.mem.Allocator, s: []const u8) []const u8 {
    var b: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            const c: u8 = switch (s[i]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                'b' => 8,
                'f' => 12,
                else => s[i],
            };
            b.append(alloc, c) catch {};
        } else {
            b.append(alloc, s[i]) catch {};
        }
    }
    return b.items;
}

/// The tool's *answer* out of the MCP envelope: structuredContent when the
/// server sends it, else the first content[].text (unescaped, so a JSON payload
/// stays JSON and a plain message stays a message). Falls back to the envelope
/// itself when neither is present.
fn payload(alloc: std.mem.Allocator, result: []const u8) []const u8 {
    if (std.mem.indexOf(u8, result, "\"structuredContent\":")) |p| {
        const start = p + "\"structuredContent\":".len;
        if (valueEnd(result, start)) |end| return result[start..end];
    }
    if (std.mem.indexOf(u8, result, "\"text\":\"")) |p| {
        const start = p + "\"text\":".len; // keeps the opening quote
        if (start < result.len and result[start] == '"') {
            var j = start + 1;
            while (j < result.len) : (j += 1) {
                if (result[j] == '\\') {
                    j += 1;
                    continue;
                }
                if (result[j] == '"') return unescape(alloc, result[start + 1 .. j]);
            }
        }
    }
    return result;
}

pub fn main(init: std.process.Init) void {
    feat.restoreSigpipe();
    const alloc = std.heap.page_allocator;
    const arena = init.arena.allocator();
    const argv = init.minimal.args.toSlice(arena) catch return;

    var timeout_s: u32 = 90;
    var quiet = false;
    var tool: ?[]const u8 = null;
    var json: ?[]const u8 = null;
    var cmd_at: ?usize = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--") and cmd_at == null and tool != null) {
            cmd_at = i + 1;
            break;
        } else if (std.mem.eql(u8, a, "-t")) {
            i += 1;
            timeout_s = std.fmt.parseInt(u32, argv[i], 10) catch 90;
        } else if (std.mem.eql(u8, a, "-q")) {
            quiet = true;
        } else if (tool == null) {
            tool = a;
        } else if (json == null) {
            json = a;
        }
    }
    const t = tool orelse {
        _ = feat.err(init.io, "usage: mcpc [-t SECS] [-q] TOOL [JSON] -- CMD [ARGS...]\n");
        std.process.exit(feat.EXIT_USAGE);
    };
    const ca = cmd_at orelse {
        _ = feat.err(init.io, "mcpc: missing '-- CMD' (the MCP server to run)\n");
        std.process.exit(feat.EXIT_USAGE);
    };
    if (ca >= argv.len) {
        _ = feat.err(init.io, "mcpc: no command after '--'\n");
        std.process.exit(feat.EXIT_USAGE);
    }

    // child argv: env <server cmd...>
    var cargv: [64]?[*:0]const u8 = undefined;
    var held: [64][]u8 = undefined;
    var nh: usize = 0;
    var n: usize = 0;
    const push = struct {
        fn p(s: []const u8, h: *[64][]u8, nhp: *usize, av: *[64]?[*:0]const u8, np: *usize) bool {
            const dz = std.heap.page_allocator.dupeZ(u8, s) catch return false;
            h[nhp.*] = dz;
            nhp.* += 1;
            av[np.*] = dz.ptr;
            np.* += 1;
            return true;
        }
    }.p;
    if (!push("env", &held, &nh, &cargv, &n)) return;
    for (argv[ca..]) |a| if (n >= cargv.len - 1 or !push(a, &held, &nh, &cargv, &n)) return;
    cargv[n] = null;
    const cargvz: [*:null]const ?[*:0]const u8 = cargv[0..n :null];

    var to_child: [2]i32 = undefined; // parent writes to index 1
    var from_child: [2]i32 = undefined; // parent reads from index 0
    if (@as(isize, @bitCast(linux.pipe2(&to_child, .{}))) < 0) return;
    if (@as(isize, @bitCast(linux.pipe2(&from_child, .{}))) < 0) return;

    const pid: isize = @bitCast(linux.fork());
    if (pid < 0) return;
    if (pid == 0) {
        _ = linux.close(to_child[1]);
        _ = linux.close(from_child[0]);
        _ = linux.dup2(to_child[0], 0);
        _ = linux.dup2(from_child[1], 1);
        _ = linux.close(to_child[0]);
        _ = linux.close(from_child[1]);
        _ = linux.execve("/usr/bin/env", cargvz, init.minimal.environ.block.slice.ptr);
        linux.exit(127);
    }
    _ = linux.close(to_child[0]);
    _ = linux.close(from_child[1]);

    // requests: initialize (id 1), then the tool call (id 2)
    var req: std.ArrayListUnmanaged(u8) = .empty;
    req.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"mcpc\",\"version\":\"1\"}}}\n") catch {};
    req.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"") catch {};
    feat.jsonEscape(&req, alloc, t) catch {};
    req.appendSlice(alloc, "\",\"arguments\":") catch {};
    req.appendSlice(alloc, json orelse "{}") catch {};
    req.appendSlice(alloc, "}}\n") catch {};
    _ = linux.write(to_child[1], req.items.ptr, req.items.len);

    // read until the id:2 response arrives, or the deadline passes
    var line: std.ArrayListUnmanaged(u8) = .empty;
    var answer: ?[]const u8 = null;
    const start_ms = nowMs();
    var fds = [_]linux.pollfd{.{ .fd = from_child[0], .events = linux.POLL.IN, .revents = 0 }};
    var fbuf: [65536]u8 = undefined;
    while (answer == null) {
        const elapsed = nowMs() - start_ms;
        if (elapsed > @as(i64, timeout_s) * 1000) break;
        const remaining: i32 = @intCast(@as(i64, timeout_s) * 1000 - elapsed);
        fds[0].revents = 0;
        const pr = linux.poll(&fds, 1, remaining);
        if (@as(isize, @bitCast(pr)) <= 0) break;
        const nr = linux.read(from_child[0], &fbuf, fbuf.len);
        if (@as(isize, @bitCast(nr)) <= 0) break;
        var chunk: []const u8 = fbuf[0..nr];
        while (chunk.len > 0) {
            if (std.mem.indexOfScalar(u8, chunk, '\n')) |nl| {
                line.appendSlice(alloc, chunk[0..nl]) catch {};
                // The answer must be a stable copy: `line` is reused for the next
                // response line, so a slice into it would be overwritten.
                if (resultOf(line.items, 2)) |res| answer = alloc.dupe(u8, res) catch null;
                line.clearRetainingCapacity();
                chunk = chunk[nl + 1 ..];
            } else {
                line.appendSlice(alloc, chunk) catch {};
                if (line.items.len > MAX_LINE) break;
                break;
            }
        }
    }

    // the server has answered (or not): it is a one-shot session, so end it
    _ = linux.kill(@intCast(pid), linux.SIG.TERM);
    var status: u32 = 0;
    _ = linux.waitpid(@intCast(pid), &status, 0);

    const raw_answer = answer orelse {
        _ = feat.eprint(init.io, "mcpc: no response for tool {s} within {d}s\n", .{ t, timeout_s });
        std.process.exit(feat.EXIT_FAIL);
    };
    const res = payload(alloc, raw_answer);
    if (!quiet) {
        _ = feat.out(init.io, res);
        _ = feat.out(init.io, "\n");
    }
    if (std.mem.indexOf(u8, res, "\"isError\":true") != null or
        std.mem.startsWith(u8, res, "{\"code\":") or std.mem.startsWith(u8, res, "{\"message\":"))
    {
        std.process.exit(feat.EXIT_FAIL);
    }
}
