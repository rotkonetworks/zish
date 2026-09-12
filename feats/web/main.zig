//! web — web search + readable page fetch from the shell, so an agent (or you)
//! can check instead of guess.
//!
//!   web search <query...>     # top results: title / url / snippet
//!   web fetch <url>           # the page as clean, bounded text (tags stripped)
//!   web get <url>             # alias for fetch
//!
//! Keyless by default: search scrapes DuckDuckGo's HTML endpoint (no API key).
//! Override the search backend with a URL template holding {q}:
//!   ZISH_WEB_SEARCH="https://searx.example/search?q={q}&format=json"   (or any engine)
//! Network is curl (execed), so it inherits the shell's proxy/DNS. Output is
//! bounded (ZISH_WEB_MAX bytes, default 20000), so the caller gets the gist, not
//! a multi-megabyte dump.

const std = @import("std");
const linux = std.os.linux;
const alloc = std.heap.page_allocator;
// Shared feat primitives. Zig confines imports to the root file's own
// directory, so this feat dir carries a `lib/feat.zig` symlink to
// ../lib/feat.zig. build.zig is the only thing that compiles this file —
// including whether it links libc.
const feat = @import("lib/feat.zig");

const UA = "Mozilla/5.0 (X11; Linux x86_64) zish-web/1";
const FETCH_CAP = 4 * 1024 * 1024; // read cap from curl
const DEFAULT_MAX = 20000; // bytes of text handed back
const MAX_RESULTS = 8;

// Environment lookups go through `feat.env`, the shared zero-libc reader (Zig
// 0.16 dropped `std.posix.getenv`). It wants an io and returns allocated
// bytes; the process arena `std.process.Init` hands us owns them, so callers
// never free — the same borrow `std.c.getenv` used to give.
fn writeFd(fd: i32, b: []const u8) void {
    var off: usize = 0;
    while (off < b.len) {
        const n: isize = @bitCast(linux.write(fd, b.ptr + off, b.len - off));
        if (n <= 0) return;
        off += @intCast(n);
    }
}
fn out(b: []const u8) void {
    writeFd(1, b);
}
fn warn(b: []const u8) void {
    writeFd(2, b);
}

fn webMax(init: std.process.Init) usize {
    const v = feat.env(init.arena.allocator(), init.io, "ZISH_WEB_MAX") orelse return DEFAULT_MAX;
    return std.fmt.parseInt(usize, v, 10) catch DEFAULT_MAX;
}

// --- curl fetch (fork+exec /usr/bin/env curl, capture stdout) ----------------

fn curlGet(init: std.process.Init, url: []const u8) ?[]u8 {
    var argv: [16]?[*:0]const u8 = undefined;
    var held: [16][]u8 = undefined;
    var nh: usize = 0;
    var n: usize = 0;
    defer for (held[0..nh]) |h| alloc.free(h);
    const push = struct {
        fn z(s: []const u8, h: [][]u8, nhp: *usize, av: []?[*:0]const u8, np: *usize) bool {
            const dz = alloc.dupeZ(u8, s) catch return false;
            h[nhp.*] = dz;
            nhp.* += 1;
            av[np.*] = dz.ptr;
            np.* += 1;
            return true;
        }
    }.z;
    const timeout = feat.env(init.arena.allocator(), init.io, "ZISH_WEB_TIMEOUT") orelse "20";
    for ([_][]const u8{ "env", "curl", "-sL", "--max-time", timeout, "-A", UA, url }) |a| {
        if (!push(a, &held, &nh, &argv, &n)) return null;
    }
    argv[n] = null;
    const argvz: [*:null]const ?[*:0]const u8 = argv[0..n :null];

    var fds: [2]i32 = undefined;
    if (@as(isize, @bitCast(linux.pipe2(&fds, .{}))) < 0) return null;
    const pid: isize = @bitCast(linux.fork());
    if (pid < 0) {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        return null;
    }
    if (pid == 0) {
        _ = linux.close(fds[0]);
        _ = linux.dup2(fds[1], 1);
        _ = linux.close(fds[1]);
        // the inherited environment block, handed to us by the startup (envp)
        _ = linux.execve("/usr/bin/env", argvz, init.minimal.environ.block.slice.ptr);
        linux.exit(127);
    }
    _ = linux.close(fds[1]);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var tmp: [65536]u8 = undefined;
    while (buf.items.len < FETCH_CAP) {
        const r: isize = @bitCast(linux.read(fds[0], &tmp, tmp.len));
        if (r <= 0) break;
        buf.appendSlice(alloc, tmp[0..@intCast(r)]) catch break;
    }
    _ = linux.close(fds[0]);
    var status: u32 = 0;
    _ = linux.waitpid(@intCast(pid), &status, 0);
    // A failed fetch is not an empty page. curl exits non-zero for a DNS
    // failure, a timeout, or a refused connection, and returning an empty slice
    // for those made the caller report success with no output — indistinguishable
    // from a page that really was empty, and unreachable from the feat's own
    // "fetch failed" path. Fail closed instead.
    if (!std.posix.W.IFEXITED(status) or std.posix.W.EXITSTATUS(status) != 0) return null;
    return buf.toOwnedSlice(alloc) catch null;
}

// --- text transforms ---------------------------------------------------------

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

/// percent-decode (+ → space); appends to `o`.
fn urlDecode(o: *std.ArrayListUnmanaged(u8), s: []const u8) void {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                o.append(alloc, c) catch {};
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                o.append(alloc, c) catch {};
                continue;
            };
            o.append(alloc, @intCast(hi * 16 + lo)) catch {};
            i += 2;
        } else if (c == '+') {
            o.append(alloc, ' ') catch {};
        } else o.append(alloc, c) catch {};
    }
}

/// percent-encode `s` for a query value; appends to `o`.
fn urlEncode(o: *std.ArrayListUnmanaged(u8), s: []const u8) void {
    for (s) |c| {
        const unreserved = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '~';
        if (unreserved) {
            o.append(alloc, c) catch {};
        } else {
            var b: [3]u8 = undefined;
            _ = std.fmt.bufPrint(&b, "%{X:0>2}", .{c}) catch continue;
            o.appendSlice(alloc, &b) catch {};
        }
    }
}

/// decode the handful of HTML entities that matter for readable text.
fn decodeEntities(s: []const u8) []u8 {
    var o: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            const rest = s[i..];
            const Ent = struct { k: []const u8, v: []const u8 };
            const ents = [_]Ent{
                .{ .k = "&amp;", .v = "&" },   .{ .k = "&lt;", .v = "<" },
                .{ .k = "&gt;", .v = ">" },     .{ .k = "&quot;", .v = "\"" },
                .{ .k = "&#39;", .v = "'" },    .{ .k = "&#x27;", .v = "'" },
                .{ .k = "&nbsp;", .v = " " },   .{ .k = "&mdash;", .v = "—" },
                .{ .k = "&ndash;", .v = "-" },  .{ .k = "&hellip;", .v = "…" },
            };
            var matched = false;
            for (ents) |e| {
                if (std.mem.startsWith(u8, rest, e.k)) {
                    o.appendSlice(alloc, e.v) catch {};
                    i += e.k.len;
                    matched = true;
                    break;
                }
            }
            // generic numeric entity: &#NN;  or  &#xHH;
            if (!matched and std.mem.startsWith(u8, rest, "&#")) {
                var j: usize = 2;
                const hex = j < rest.len and (rest[j] == 'x' or rest[j] == 'X');
                if (hex) j += 1;
                const ds = j;
                while (j < rest.len and rest[j] != ';' and j < ds + 8) : (j += 1) {}
                if (j < rest.len and rest[j] == ';' and j > ds) {
                    const cp = std.fmt.parseInt(u21, rest[ds..j], if (hex) 16 else 10) catch 0;
                    var ub: [4]u8 = undefined;
                    const ln = std.unicode.utf8Encode(cp, &ub) catch 0;
                    if (ln > 0) {
                        o.appendSlice(alloc, ub[0..ln]) catch {};
                        i += j + 1;
                        matched = true;
                    }
                }
            }
            if (!matched) {
                o.append(alloc, s[i]) catch {};
                i += 1;
            }
        } else {
            o.append(alloc, s[i]) catch {};
            i += 1;
        }
    }
    return o.toOwnedSlice(alloc) catch dupe(s);
}

fn dupe(s: []const u8) []u8 {
    return alloc.dupe(u8, s) catch @constCast(s[0..0]);
}

/// case-insensitive find of `needle` in `hay` from `start`.
fn findCI(hay: []const u8, needle: []const u8, start: usize) ?usize {
    if (needle.len == 0 or start >= hay.len) return null;
    var i = start;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// Strip HTML to readable text: drop <script>/<style> spans, turn block-closers
/// into newlines, remove remaining tags, decode entities, collapse whitespace.
fn htmlToText(html: []const u8) []u8 {
    var s: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < html.len) {
        if (html[i] == '<') {
            // skip <script…>…</script> and <style…>…</style> wholesale
            if (findCI(html, "<script", i) == i) {
                if (findCI(html, "</script>", i)) |e| {
                    i = e + "</script>".len;
                    continue;
                } else break;
            }
            if (findCI(html, "<style", i) == i) {
                if (findCI(html, "</style>", i)) |e| {
                    i = e + "</style>".len;
                    continue;
                } else break;
            }
            // block boundaries → newline
            const blocks = [_][]const u8{ "</p", "<br", "</div", "</li", "</tr", "</h1", "</h2", "</h3", "</h4", "</h5", "</h6", "</section", "</article" };
            for (blocks) |b| {
                if (findCI(html, b, i) == i) {
                    s.append(alloc, '\n') catch {};
                    break;
                }
            }
            // drop the tag
            if (std.mem.indexOfScalarPos(u8, html, i, '>')) |e| {
                i = e + 1;
            } else break;
        } else {
            s.append(alloc, html[i]) catch {};
            i += 1;
        }
    }
    // decode entities, then collapse runs of spaces and blank lines
    const decoded = decodeEntities(s.items);
    defer alloc.free(decoded);
    s.deinit(alloc);
    var o: std.ArrayListUnmanaged(u8) = .empty;
    var spaces: usize = 0;
    var newlines: usize = 0;
    for (decoded) |c| {
        if (c == '\n') {
            newlines += 1;
            spaces = 0;
        } else if (c == ' ' or c == '\t' or c == '\r') {
            spaces += 1;
        } else {
            if (newlines > 0) {
                o.appendSlice(alloc, if (newlines >= 2) "\n\n" else "\n") catch {};
                newlines = 0;
            } else if (spaces > 0 and o.items.len > 0) {
                o.append(alloc, ' ') catch {};
            }
            spaces = 0;
            o.append(alloc, c) catch {};
        }
    }
    return o.toOwnedSlice(alloc) catch dupe(decoded);
}

fn boundText(init: std.process.Init, t: []const u8) []const u8 {
    const max = webMax(init);
    return if (t.len > max) t[0..max] else t;
}

// --- verbs -------------------------------------------------------------------

fn doFetch(init: std.process.Init, url: []const u8) u8 {
    const html = curlGet(init, url) orelse {
        warn("web: fetch failed (curl error or timeout)\n");
        return 1;
    };
    defer alloc.free(html);
    const text = htmlToText(html);
    defer alloc.free(text);
    const b = boundText(init, text);
    out(b);
    if (b.len < text.len) out("\n\n… [truncated — raise ZISH_WEB_MAX or fetch a deeper link] …\n");
    out("\n");
    return 0;
}

/// DuckDuckGo HTML scrape: extract result anchors (real URL from the `uddg`
/// redirect param) + their snippets. Falls out gracefully if the markup shifts.
fn doSearch(init: std.process.Init, query: []const u8) u8 {
    // custom backend?
    if (feat.env(init.arena.allocator(), init.io, "ZISH_WEB_SEARCH")) |tmpl| {
        var url: std.ArrayListUnmanaged(u8) = .empty;
        defer url.deinit(alloc);
        if (std.mem.indexOf(u8, tmpl, "{q}")) |at| {
            url.appendSlice(alloc, tmpl[0..at]) catch {};
            urlEncode(&url, query);
            url.appendSlice(alloc, tmpl[at + 3 ..]) catch {};
        } else {
            url.appendSlice(alloc, tmpl) catch {};
            urlEncode(&url, query);
        }
        const body = curlGet(init, url.items) orelse {
            warn("web: search backend fetch failed\n");
            return 1;
        };
        defer alloc.free(body);
        const text = htmlToText(body); // best-effort: print as text (JSON stays JSON)
        defer alloc.free(text);
        out(boundText(init, text));
        out("\n");
        return 0;
    }

    var url: std.ArrayListUnmanaged(u8) = .empty;
    defer url.deinit(alloc);
    url.appendSlice(alloc, "https://html.duckduckgo.com/html/?q=") catch {};
    urlEncode(&url, query);
    const body = curlGet(init, url.items) orelse {
        warn("web: search failed (curl error or timeout)\n");
        return 1;
    };
    defer alloc.free(body);

    var count: usize = 0;
    var pos: usize = 0;
    while (count < MAX_RESULTS) {
        // each result title anchor carries class="result__a"
        const a = findCI(body, "result__a", pos) orelse break;
        const href_at = findCI(body, "href=\"", a) orelse break;
        const hs = href_at + "href=\"".len;
        const he = std.mem.indexOfScalarPos(u8, body, hs, '"') orelse break;
        const raw_href = body[hs..he];
        // title = text between this anchor's '>' and the next '</a>'
        const tgt = std.mem.indexOfScalarPos(u8, body, he, '>') orelse break;
        const tend = findCI(body, "</a>", tgt) orelse break;
        const title_html = body[tgt + 1 .. tend];

        // real URL: decode the uddg= param if present, else use the href
        var real: std.ArrayListUnmanaged(u8) = .empty;
        defer real.deinit(alloc);
        if (std.mem.indexOf(u8, raw_href, "uddg=")) |u| {
            const vs = u + "uddg=".len;
            const ve = std.mem.indexOfScalarPos(u8, raw_href, vs, '&') orelse raw_href.len;
            urlDecode(&real, raw_href[vs..ve]);
        } else urlDecode(&real, raw_href);

        const title = htmlToText(title_html);
        defer alloc.free(title);

        // snippet: next result__snippet after this anchor
        var snip: []u8 = dupe("");
        if (findCI(body, "result__snippet", tend)) |sn| {
            if (std.mem.indexOfScalarPos(u8, body, sn, '>')) |ss| {
                if (findCI(body, "</a>", ss)) |se| {
                    alloc.free(snip);
                    snip = htmlToText(body[ss + 1 .. se]);
                }
            }
        }
        defer alloc.free(snip);

        count += 1;
        var nb: [8]u8 = undefined;
        out(std.fmt.bufPrint(&nb, "{d}. ", .{count}) catch "- ");
        out(std.mem.trim(u8, title, " \n"));
        out("\n   ");
        out(std.mem.trim(u8, real.items, " \n"));
        if (snip.len > 0) {
            out("\n   ");
            const st = std.mem.trim(u8, snip, " \n");
            out(if (st.len > 300) st[0..300] else st);
        }
        out("\n\n");
        pos = tend + 4;
    }
    if (count == 0) {
        warn("web: no results parsed (page markup may have changed; try `web fetch` on a URL)\n");
        return 1;
    }
    return 0;
}

pub fn main(init: std.process.Init) u8 {
    // Full Init installs a no-op SIGPIPE handler; a filter must die on a closed
    // stdout like every other CLI, so restore the default before doing anything.
    feat.restoreSigpipe();

    var it = init.minimal.args.iterate();
    _ = it.next(); // argv0
    const verb = it.next() orelse {
        warn("usage: web search <query> | web fetch <url>\n");
        return 2;
    };
    if (std.mem.eql(u8, verb, "fetch") or std.mem.eql(u8, verb, "get")) {
        const url = it.next() orelse {
            warn("web: fetch needs a URL\n");
            return 2;
        };
        return doFetch(init, url);
    }
    if (std.mem.eql(u8, verb, "search") or std.mem.eql(u8, verb, "s")) {
        var q: std.ArrayListUnmanaged(u8) = .empty;
        defer q.deinit(alloc);
        while (it.next()) |w| {
            if (q.items.len > 0) q.append(alloc, ' ') catch {};
            q.appendSlice(alloc, w) catch {};
        }
        if (q.items.len == 0) {
            warn("web: search needs a query\n");
            return 2;
        }
        return doSearch(init, q.items);
    }
    // bare `web <query...>` → search (verb is the first query word)
    var q: std.ArrayListUnmanaged(u8) = .empty;
    defer q.deinit(alloc);
    q.appendSlice(alloc, verb) catch {};
    while (it.next()) |w| {
        q.append(alloc, ' ') catch {};
        q.appendSlice(alloc, w) catch {};
    }
    return doSearch(init, q.items);
}
