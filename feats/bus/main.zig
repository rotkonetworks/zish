// bus — a durable, offset-addressable message log between agents.
//
//   bus pub <channel> [--from LABEL] [text...]    append one message
//   bus read <channel> [flags]                    print messages, oldest first
//
// read flags:
//   --after <name>     only messages after this one (resume a cursor)
//   --follow           keep printing as new messages arrive
//   --json             the stored record verbatim, instead of ts/from/text
//   --print-cursor     write the last message's name to stderr
//
// Why a log and not a socket: a subscriber that was not connected still gets the
// history. IRC loses anything said while you were away, and needs a bouncer to
// fix that; a directory of append-only records gives replay for free, needs no
// broker process, and is the same shape the shell already uses for session
// registries and transcripts — files another process can read without asking.
//
// One message is one file, created with O_EXCL and written in a single call. A
// publish is therefore atomic without any locking, two writers can never
// interleave a record, and a reader never sees a half-written message. The name
// is <16-digit-microseconds>-<seq>, so lexicographic order is chronological
// order and a cursor is just "the last name I saw".
//
// A channel is a directory, so `ls ~/.zish/bus` is the channel list and
// `ls ~/.zish/bus/#tasks` is that channel's history. No index to keep in sync.

const std = @import("std");
const feat = @import("lib/feat.zig");

/// Cap on a single message's text. A message is written with one write() into an
/// O_EXCL file, and keeping it small is what makes "a reader never sees a partial
/// message" true by construction rather than by luck.
const MAX_TEXT = 8 * 1024;

/// Cap on reading one stored message.
const MAX_RECORD = MAX_TEXT * 4;

/// How long `--follow` waits between polls.
const POLL_NS: u64 = 200 * 1000 * 1000;

/// The bus root: `$ZISH_BUS`, else `$HOME/.zish/bus`. Values come from the
/// arena, so nothing here is freed.
fn busDir(arena: std.mem.Allocator, io: std.Io) ?[]const u8 {
    if (feat.env(arena, io, "ZISH_BUS")) |p| {
        if (p.len > 0) return p;
    }
    const home = feat.env(arena, io, "HOME") orelse return null;
    if (home.len == 0) return null;
    return std.fmt.allocPrint(arena, "{s}/.zish/bus", .{home}) catch null;
}

/// A channel name is one path component. Anything that could escape the bus
/// directory is rejected rather than sanitized: a bus is addressed by name, and
/// silently rewriting a name would route a message somewhere the sender did not
/// choose.
///
/// `#` is deliberately not allowed even though it is a valid filename byte: in
/// every shell that will call this, an unquoted `#` starts a comment, so
/// `bus pub #tasks hi` would pass no arguments and fail in a way that looks like
/// a bus bug.
///
/// The name must also *start* alphanumeric. That is not cosmetic: a channel
/// called `-x` would be indistinguishable from a flag to every caller that
/// forwards its own argv, and `--after` is already a real flag. Forbidding a
/// leading `-` makes that ambiguity unrepresentable rather than a parsing
/// convention to remember.
///
/// Convention (not enforced): lowercase words, and `.` for hierarchy —
/// `tasks`, `team-a`, `team-a.inbox`. One directory level either way, so `ls`
/// stays readable.
fn validChannel(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    switch (name[0]) {
        'a'...'z', 'A'...'Z', '0'...'9' => {},
        else => return false,
    }
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
        else => return false,
    };
    return true;
}

fn channelPath(arena: std.mem.Allocator, dir: []const u8, channel: []const u8) ?[]const u8 {
    if (!validChannel(channel)) return null;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, channel }) catch null;
}

/// Who is speaking. `$ZISH_BUS_FROM` lets an agent name itself (its session,
/// its role); otherwise the user. Attribution here is a claim, not a credential —
/// every writer on the bus is the same uid, so attestation would need the socket
/// layer, not a bigger string.
fn senderLabel(arena: std.mem.Allocator, io: std.Io) []const u8 {
    if (feat.env(arena, io, "ZISH_BUS_FROM")) |v| {
        if (v.len > 0) return v;
    }
    if (feat.env(arena, io, "USER")) |v| {
        if (v.len > 0) return v;
    }
    return "anon";
}

fn nowNs(io: std.Io) i128 {
    return std.Io.Clock.now(.real, io).nanoseconds;
}

fn nap(io: std.Io) void {
    const dur: std.Io.Clock.Duration = .{
        .raw = .fromNanoseconds(@intCast(POLL_NS)),
        .clock = .awake,
    };
    dur.sleep(io) catch {};
}

fn writesFail(io: std.Io, what: []const u8) u8 {
    _ = feat.eprint(io, "bus: {s} failed\n", .{what});
    return feat.EXIT_FAIL;
}

/// A sender label, `--from`. Deliberately *not* `validChannel`: a label is an
/// identity, not an address, so `@alice` must work — and rejecting it here
/// silently refused the publish, which is how this was found. The only real
/// constraint is that it cannot contain a control byte, because the terse
/// render is tab-separated and a tab in a label would shift a reader's columns.
fn validLabel(label: []const u8) bool {
    if (label.len == 0 or label.len > 64) return false;
    for (label) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

/// A thread id groups an exchange *within* a channel. It is a record field and
/// never part of the channel name: threading by name gives you `tasks.42`,
/// `tasks.43`, … one channel per exchange, and then "subscribe to the
/// conversation" becomes impossible — you could only follow one thread. As a
/// field, `bus read tasks` yields the whole topic and `--thread 42` filters.
fn validThread(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

/// Append one message. The timestamp gives ordering; the sequence resolves two
/// publishes inside the same microsecond, and O_EXCL makes the retry a real
/// race-resolution rather than a guess.
fn cmdPub(arena: std.mem.Allocator, io: std.Io, args: []const []const u8) u8 {
    var channel: ?[]const u8 = null;
    var from: ?[]const u8 = null;
    var thread: ?[]const u8 = null;
    var text: std.ArrayListUnmanaged(u8) = .empty;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--from")) {
            i += 1;
            if (i >= args.len) return feat.EXIT_USAGE;
            from = args[i];
            continue;
        }
        if (std.mem.eql(u8, a, "--thread")) {
            i += 1;
            if (i >= args.len) return feat.EXIT_USAGE;
            thread = args[i];
            if (!validThread(thread.?)) {
                _ = feat.err(io, "bus: invalid thread id\n");
                return feat.EXIT_USAGE;
            }
            continue;
        }
        if (channel == null) {
            channel = a;
            continue;
        }
        // Remaining arguments are the message, joined by spaces: `bus pub tasks
        // hello world` should read as one message, and requiring quotes for a
        // two-word message would be a spec bug.
        if (text.items.len > 0) text.append(arena, ' ') catch return writesFail(io, "append");
        text.appendSlice(arena, a) catch return writesFail(io, "append");
    }

    const chan = channel orelse {
        _ = feat.err(io, "bus: usage: bus pub <channel> [--from LABEL] [--thread ID] [text...]\n");
        return feat.EXIT_USAGE;
    };
    if (from) |f| {
        if (!validLabel(f)) {
            _ = feat.err(io, "bus: invalid --from label\n");
            return feat.EXIT_USAGE;
        }
    }
    if (text.items.len == 0) {
        // Never block an agent on a prompt nobody can answer.
        if (feat.stdinIsTty(io)) {
            _ = feat.err(io, "bus: no message (stdin is a terminal)\n");
            return feat.EXIT_USAGE;
        }
        const piped = feat.slurpStdin(arena, io) catch return writesFail(io, "read stdin");
        const trimmed = std.mem.trimEnd(u8, piped, "\n");
        if (trimmed.len == 0) {
            _ = feat.err(io, "bus: empty message\n");
            return feat.EXIT_USAGE;
        }
        text.appendSlice(arena, trimmed) catch return writesFail(io, "append");
    }
    if (text.items.len > MAX_TEXT) {
        _ = feat.eprint(io, "bus: message too long ({d} > {d} bytes)\n", .{ text.items.len, MAX_TEXT });
        return feat.EXIT_USAGE;
    }

    const dir = busDir(arena, io) orelse {
        _ = feat.err(io, "bus: no HOME (set ZISH_BUS)\n");
        return feat.EXIT_FAIL;
    };
    const cdir = channelPath(arena, dir, chan) orelse {
        _ = feat.eprint(io, "bus: invalid channel '{s}'\n", .{chan});
        return feat.EXIT_USAGE;
    };
    std.Io.Dir.cwd().createDirPath(io, cdir) catch return writesFail(io, "create channel");

    // The record is JSON for the same reason the transcript is: it is read by
    // programs, and one escaping rule everywhere beats a per-feature dialect.
    const ns = nowNs(io);
    const ts: i64 = @intCast(@divFloor(ns, std.time.ns_per_s));
    const micros: i128 = @divFloor(ns, 1000);

    var rec: std.ArrayListUnmanaged(u8) = .empty;
    var nb: [40]u8 = undefined;
    rec.appendSlice(arena, "{\"ts\":") catch return writesFail(io, "build record");
    rec.appendSlice(arena, std.fmt.bufPrint(&nb, "{d}", .{ts}) catch return writesFail(io, "build record")) catch return writesFail(io, "build record");
    rec.appendSlice(arena, ",\"from\":\"") catch return writesFail(io, "build record");
    feat.jsonEscape(&rec, arena, from orelse senderLabel(arena, io)) catch return writesFail(io, "build record");
    // Written only when set: a field that is empty on every message is bytes
    // every reader pays for and no reader uses.
    if (thread) |t| {
        rec.appendSlice(arena, "\",\"thread\":\"") catch return writesFail(io, "build record");
        feat.jsonEscape(&rec, arena, t) catch return writesFail(io, "build record");
    }
    rec.appendSlice(arena, "\",\"text\":\"") catch return writesFail(io, "build record");
    feat.jsonEscape(&rec, arena, text.items) catch return writesFail(io, "build record");
    rec.appendSlice(arena, "\"}\n") catch return writesFail(io, "build record");

    var seq: usize = 0;
    while (seq < 1024) : (seq += 1) {
        var name_buf: [64]u8 = undefined;
        // Unsigned, because Zig's formatter emits a `+` for a signed integer
        // under a fill spec — the names came out `+1789105746139731-000`.
        // Zero-padded to a fixed width so lexicographic order is chronological.
        const micros_u: u128 = @intCast(micros);
        const name = std.fmt.bufPrint(&name_buf, "{d:0>16}-{d:0>3}", .{ micros_u, seq }) catch return writesFail(io, "name");
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ cdir, name }) catch return writesFail(io, "path");
        feat.publish(io, path, rec.items) catch |e| switch (e) {
            error.PathAlreadyExists => continue, // someone published in this microsecond
            else => return writesFail(io, "publish"),
        };
        _ = feat.print(io, "{s}\n", .{name}); // the cursor to hand to `read --after`
        return feat.EXIT_OK;
    }
    _ = feat.err(io, "bus: could not allocate a message name\n");
    return feat.EXIT_FAIL;
}

/// Names in one channel, sorted. Directive order is not chronological, and a
/// reader's cursor is only meaningful in time order.
fn listChannel(arena: std.mem.Allocator, io: std.Io, cdir: []const u8) ?std.ArrayListUnmanaged([]const u8) {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var dir = std.Io.Dir.cwd().openDir(io, cdir, .{ .iterate = true }) catch return out; // no channel yet
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const copy = arena.dupe(u8, entry.name) catch return out;
        out.append(arena, copy) catch return out;
    }
    std.mem.sort([]const u8, out.items, {}, lessThanName);
    return out;
}

fn lessThanName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// One stored message, rendered. Returns false when it was filtered out, so the
/// caller's cursor still advances past messages it chose not to show.
/// `--json` emits the bytes exactly as stored: a consumer that speaks JSON pays
/// no re-encoding and loses no precision.
fn printMessage(arena: std.mem.Allocator, io: std.Io, path: []const u8, json: bool, want_thread: ?[]const u8) bool {
    const raw = feat.readFile(arena, io, path, MAX_RECORD) catch return false;

    const parsed = std.json.parseFromSlice(std.json.Value, arena, raw, .{}) catch return false;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return false,
    };
    const thread = switch (obj.get("thread") orelse .null) {
        .string => |s| s,
        else => "",
    };
    if (want_thread) |w| {
        if (!std.mem.eql(u8, w, thread)) return false;
    }
    if (json) return feat.out(io, raw);

    const ts: i64 = switch (obj.get("ts") orelse return false) {
        .integer => |n| n,
        else => return false,
    };
    const from = switch (obj.get("from") orelse return false) {
        .string => |s| s,
        else => "",
    };
    const text = switch (obj.get("text") orelse return false) {
        .string => |s| s,
        else => "",
    };
    // <ts>\t<from>\t<thread>\t<text>, split on the first three tabs. The thread
    // column is empty for an unthreaded message but always present, so the
    // column count never changes and `text` may contain tabs freely.
    return feat.print(io, "{d}\t{s}\t{s}\t{s}\n", .{ ts, from, thread, text });
}

fn cmdRead(arena: std.mem.Allocator, io: std.Io, args: []const []const u8) u8 {
    var channel: ?[]const u8 = null;
    var after: ?[]const u8 = null;
    var want_thread: ?[]const u8 = null;
    var follow = false;
    var json = false;
    var print_cursor = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--after")) {
            i += 1;
            if (i >= args.len) return feat.EXIT_USAGE;
            after = args[i];
            continue;
        }
        if (std.mem.eql(u8, a, "--thread")) {
            i += 1;
            if (i >= args.len) return feat.EXIT_USAGE;
            if (!validThread(args[i])) {
                _ = feat.err(io, "bus: invalid thread id\n");
                return feat.EXIT_USAGE;
            }
            want_thread = args[i];
            continue;
        }
        if (std.mem.eql(u8, a, "--json")) {
            json = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--follow")) {
            follow = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--print-cursor")) {
            print_cursor = true;
            continue;
        }
        if (channel == null) {
            channel = a;
            continue;
        }
        _ = feat.eprint(io, "bus: unknown argument '{s}'\n", .{a});
        return feat.EXIT_USAGE;
    }

    const chan = channel orelse {
        _ = feat.err(io, "bus: usage: bus read <channel> [--after NAME] [--thread ID] [--follow] [--json] [--print-cursor]\n");
        return feat.EXIT_USAGE;
    };
    const dir = busDir(arena, io) orelse {
        _ = feat.err(io, "bus: no HOME (set ZISH_BUS)\n");
        return feat.EXIT_FAIL;
    };
    const cdir = channelPath(arena, dir, chan) orelse {
        _ = feat.eprint(io, "bus: invalid channel '{s}'\n", .{chan});
        return feat.EXIT_USAGE;
    };

    // High-water mark is a name, not an index: names sort chronologically, so a
    // cursor survives messages being deleted or a channel being recreated.
    var cursor: ?[]const u8 = after;
    var last: ?[]const u8 = null;
    while (true) {
        const names = listChannel(arena, io, cdir) orelse return feat.EXIT_FAIL;
        for (names.items) |name| {
            if (cursor) |c| {
                if (std.mem.order(u8, name, c) != .gt) continue;
            }
            var pb: [std.fs.max_path_bytes]u8 = undefined;
            const path = std.fmt.bufPrint(&pb, "{s}/{s}", .{ cdir, name }) catch continue;
            if (!printMessage(arena, io, path, json, want_thread)) continue;
            last = name;
        }
        if (last) |l| cursor = l;
        if (!follow) break;
        nap(io);
    }

    if (print_cursor) {
        if (last) |l| {
            _ = feat.eprint(io, "{s}\n", .{l});
        }
    }
    return feat.EXIT_OK;
}

pub fn main(init: std.process.Init) void {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = init.minimal.args.toSlice(arena) catch {
        std.process.exit(feat.EXIT_FAIL);
    };

    const code: u8 = blk: {
        if (argv.len < 2) {
            _ = feat.err(io, "bus: usage: bus pub <channel> [text...] | bus read <channel> [flags]\n");
            break :blk feat.EXIT_USAGE;
        }
        const sub = argv[1];
        if (std.mem.eql(u8, sub, "pub")) break :blk cmdPub(arena, io, argv[2..]);
        if (std.mem.eql(u8, sub, "read")) break :blk cmdRead(arena, io, argv[2..]);
        _ = feat.eprint(io, "bus: unknown subcommand '{s}'\n", .{sub});
        break :blk feat.EXIT_USAGE;
    };
    std.process.exit(code);
}
