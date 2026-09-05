//! budget — the conservation primitive for agent spawn trees.
//!
//! The whole design rests on one rule: **spawning is subdivision, not creation.**
//! A child agent gets a SLICE of its parent's budget, never a fresh grant, so a
//! spawn tree of arbitrary depth and fan-out can never spend more than its ROOT
//! grant. This is the fork-bomb / cost-explosion defense for recursive agents
//! (see docs/agent-cloud.md §3): the LLM-call metering an agent goes through is
//! `budget spend`, and the act of spawning a child is `budget split`.
//!
//!   budget new   <id> <credits>              create a root pool (the grant)
//!   budget split <parent> <child> <credits>  carve a child out of the parent
//!   budget spend <id> <credits>              debit (fails closed if short)
//!   budget balance <id>                       print remaining credits
//!   budget tree  <root>                       dump the subtree + its total
//!
//! INVARIANT: at every instant, the sum of live balances in a tree <= the root
//! grant. `new` seeds the pool; `split` moves credits between existing accounts
//! (total unchanged); `spend` only decreases. Every mutation checks
//! balance >= amount BEFORE applying and refuses (nonzero exit, no state change)
//! otherwise — so total is conserved-or-decreasing by construction, never
//! minted. A whole-store flock serializes read-modify-write, so two agents
//! splitting the same parent concurrently cannot both overspend it (a lost
//! update there = minted credits = the hole this feat exists to close).

const std = @import("std");
const linux = std.os.linux;
const alloc = std.heap.page_allocator;

const MAX_STATE = 16 * 1024 * 1024;

const LOCK_SH: c_int = 1;
const LOCK_EX: c_int = 2;
const LOCK_UN: c_int = 8;
extern "c" fn flock(fd: c_int, operation: c_int) c_int;

// ---------------------------------------------------------------------------
// small helpers (feats are standalone; kept syscall-shaped like aur/gf)
// ---------------------------------------------------------------------------

fn getEnv(name: [:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name.ptr) orelse return null;
    return std.mem.span(v);
}

fn toZ(buf: []u8, s: []const u8) ?[*:0]const u8 {
    if (s.len >= buf.len) return null;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return @ptrCast(buf.ptr);
}

fn writeFd(fd: i32, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        const n: isize = @bitCast(rc);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

fn out(bytes: []const u8) void {
    writeFd(1, bytes);
}
fn warn(bytes: []const u8) void {
    writeFd(2, bytes);
}

fn fail(comptime fmt: []const u8, args: anytype) u8 {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "budget: " ++ fmt ++ "\n", args) catch "budget: error\n";
    warn(msg);
    return 1;
}

fn readAllFd(fd: i32) []u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var tmp: [65536]u8 = undefined;
    while (buf.items.len < MAX_STATE) {
        const rc = linux.read(fd, &tmp, tmp.len);
        const n: isize = @bitCast(rc);
        if (n <= 0) break;
        buf.appendSlice(alloc, tmp[0..@intCast(n)]) catch break;
    }
    return buf.toOwnedSlice(alloc) catch &.{};
}

fn readFileAlloc(path: []const u8) ?[]u8 {
    var z: [4096]u8 = undefined;
    const p = toZ(&z, path) orelse return null;
    const fd_rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    const fd: isize = @bitCast(fd_rc);
    if (fd < 0) return null;
    defer _ = linux.close(@intCast(fd));
    return readAllFd(@intCast(fd));
}

fn writeFile600(path: []const u8, bytes: []const u8) bool {
    var z: [4096]u8 = undefined;
    const p = toZ(&z, path) orelse return false;
    const fd_rc = linux.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
    const fd: isize = @bitCast(fd_rc);
    if (fd < 0) return false;
    defer _ = linux.close(@intCast(fd));
    writeFd(@intCast(fd), bytes);
    return true;
}

fn appendJsonStr(o: *std.ArrayListUnmanaged(u8), s: []const u8) void {
    for (s) |c| switch (c) {
        '"' => o.appendSlice(alloc, "\\\"") catch {},
        '\\' => o.appendSlice(alloc, "\\\\") catch {},
        else => if (c >= 0x20) o.append(alloc, c) catch {},
    };
}

fn objStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    const o = switch (v) {
        .object => |ob| ob,
        else => return null,
    };
    return switch (o.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn objInt(v: std.json.Value, key: []const u8) ?i64 {
    const o = switch (v) {
        .object => |ob| ob,
        else => return null,
    };
    return switch (o.get(key) orelse return null) {
        .integer => |i| i,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// paths
// ---------------------------------------------------------------------------

fn budgetDir(buf: []u8) ?[]const u8 {
    if (getEnv("ZISH_BUDGET_DIR")) |d| return d;
    const home = getEnv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.zish/budget", .{home}) catch null;
}

fn ensureDirs() void {
    // best-effort mkdir of $HOME/.zish then the budget dir (linux.mkdir, no -p)
    const home = getEnv("HOME") orelse return;
    var zb: [4096]u8 = undefined;
    if (std.fmt.bufPrint(&zb, "{s}/.zish", .{home})) |p| {
        var z: [4096]u8 = undefined;
        if (toZ(&z, p)) |pz| _ = linux.mkdir(pz, 0o700);
    } else |_| {}
    var db: [4096]u8 = undefined;
    if (budgetDir(&db)) |d| {
        var z: [4096]u8 = undefined;
        if (toZ(&z, d)) |dz| _ = linux.mkdir(dz, 0o700);
    }
}

fn statePath(buf: []u8) ?[]const u8 {
    var db: [4096]u8 = undefined;
    const d = budgetDir(&db) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/ledger", .{d}) catch null;
}

/// Acquire the whole-store lock (a sibling .lock file). Held for the op's
/// duration so read-modify-write is atomic across concurrent invocations.
fn acquire(shared: bool) ?i32 {
    ensureDirs();
    var db: [4096]u8 = undefined;
    const d = budgetDir(&db) orelse return null;
    var lb: [4096]u8 = undefined;
    const lp = std.fmt.bufPrint(&lb, "{s}/.lock", .{d}) catch return null;
    var z: [4096]u8 = undefined;
    const pz = toZ(&z, lp) orelse return null;
    const fd_rc = linux.open(pz, .{ .ACCMODE = .RDWR, .CREAT = true }, 0o600);
    const fd: isize = @bitCast(fd_rc);
    if (fd < 0) return null;
    if (flock(@intCast(fd), if (shared) LOCK_SH else LOCK_EX) != 0) {
        _ = linux.close(@intCast(fd));
        return null;
    }
    return @intCast(fd);
}

fn release(fd: i32) void {
    _ = flock(fd, LOCK_UN);
    _ = linux.close(fd);
}

// ---------------------------------------------------------------------------
// the account store
// ---------------------------------------------------------------------------

const Account = struct { id: []const u8, bal: u64, parent: []const u8 };

fn dupe(s: []const u8) []const u8 {
    return alloc.dupe(u8, s) catch "";
}

fn load(list: *std.ArrayListUnmanaged(Account)) void {
    var sb: [4096]u8 = undefined;
    const sp = statePath(&sb) orelse return;
    const content = readFileAlloc(sp) orelse return; // absent = empty store
    defer alloc.free(content);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |ln| {
        const line = std.mem.trim(u8, ln, " \t\r");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        defer parsed.deinit();
        const id = objStr(parsed.value, "id") orelse continue;
        const bal = objInt(parsed.value, "bal") orelse continue;
        if (bal < 0) continue;
        const parent = objStr(parsed.value, "parent") orelse "";
        // dupe BEFORE parsed.deinit() frees the json backing store
        list.append(alloc, .{ .id = dupe(id), .bal = @intCast(bal), .parent = dupe(parent) }) catch {};
    }
}

fn findIdx(list: *std.ArrayListUnmanaged(Account), id: []const u8) ?usize {
    for (list.items, 0..) |a, i| if (std.mem.eql(u8, a.id, id)) return i;
    return null;
}

fn persist(list: *std.ArrayListUnmanaged(Account)) bool {
    var b: std.ArrayListUnmanaged(u8) = .empty;
    defer b.deinit(alloc);
    for (list.items) |a| {
        b.appendSlice(alloc, "{\"id\":\"") catch return false;
        appendJsonStr(&b, a.id);
        b.appendSlice(alloc, "\",\"bal\":") catch return false;
        var nb: [24]u8 = undefined;
        b.appendSlice(alloc, std.fmt.bufPrint(&nb, "{d}", .{a.bal}) catch return false) catch return false;
        b.appendSlice(alloc, ",\"parent\":\"") catch return false;
        appendJsonStr(&b, a.parent);
        b.appendSlice(alloc, "\"}\n") catch return false;
    }
    var sb: [4096]u8 = undefined;
    const sp = statePath(&sb) orelse return false;
    return writeFile600(sp, b.items);
}

fn parseCredits(s: []const u8) ?u64 {
    return std.fmt.parseInt(u64, s, 10) catch null;
}

// ---------------------------------------------------------------------------
// operations
// ---------------------------------------------------------------------------

fn cmdNew(id: []const u8, credits: u64) u8 {
    const fd = acquire(false) orelse return fail("could not lock the budget store", .{});
    defer release(fd);
    var list: std.ArrayListUnmanaged(Account) = .empty;
    load(&list);
    if (findIdx(&list, id) != null) return fail("account '{s}' already exists", .{id});
    list.append(alloc, .{ .id = dupe(id), .bal = credits, .parent = dupe("") }) catch return fail("oom", .{});
    if (!persist(&list)) return fail("could not write the budget store", .{});
    return 0;
}

fn cmdSplit(parent: []const u8, child: []const u8, credits: u64) u8 {
    const fd = acquire(false) orelse return fail("could not lock the budget store", .{});
    defer release(fd);
    var list: std.ArrayListUnmanaged(Account) = .empty;
    load(&list);
    const pi = findIdx(&list, parent) orelse return fail("no such parent '{s}'", .{parent});
    if (findIdx(&list, child) != null) return fail("account '{s}' already exists", .{child});
    // subdivision, not creation: refuse to carve out more than the parent holds
    if (list.items[pi].bal < credits)
        return fail("insufficient: '{s}' has {d}, cannot split {d} (conservation)", .{ parent, list.items[pi].bal, credits });
    list.items[pi].bal -= credits;
    list.append(alloc, .{ .id = dupe(child), .bal = credits, .parent = dupe(parent) }) catch return fail("oom", .{});
    if (!persist(&list)) return fail("could not write the budget store", .{});
    return 0;
}

fn cmdSpend(id: []const u8, credits: u64) u8 {
    const fd = acquire(false) orelse return fail("could not lock the budget store", .{});
    defer release(fd);
    var list: std.ArrayListUnmanaged(Account) = .empty;
    load(&list);
    const i = findIdx(&list, id) orelse return fail("no such account '{s}'", .{id});
    if (list.items[i].bal < credits)
        return fail("insufficient: '{s}' has {d}, cannot spend {d}", .{ id, list.items[i].bal, credits });
    list.items[i].bal -= credits;
    if (!persist(&list)) return fail("could not write the budget store", .{});
    return 0;
}

fn cmdBalance(id: []const u8) u8 {
    const fd = acquire(true) orelse return fail("could not lock the budget store", .{});
    defer release(fd);
    var list: std.ArrayListUnmanaged(Account) = .empty;
    load(&list);
    const i = findIdx(&list, id) orelse return fail("no such account '{s}'", .{id});
    var nb: [32]u8 = undefined;
    out(std.fmt.bufPrint(&nb, "{d}\n", .{list.items[i].bal}) catch "0\n");
    return 0;
}

/// Is `id` in the subtree rooted at `root` (root itself, or any descendant)?
fn inSubtree(list: *std.ArrayListUnmanaged(Account), idx: usize, root: []const u8) bool {
    var cur = idx;
    var guard: usize = 0;
    while (guard < list.items.len + 1) : (guard += 1) {
        if (std.mem.eql(u8, list.items[cur].id, root)) return true;
        const p = list.items[cur].parent;
        if (p.len == 0) return false;
        cur = findIdx(list, p) orelse return false;
    }
    return false; // cycle guard
}

fn cmdTree(root: []const u8) u8 {
    const fd = acquire(true) orelse return fail("could not lock the budget store", .{});
    defer release(fd);
    var list: std.ArrayListUnmanaged(Account) = .empty;
    load(&list);
    if (findIdx(&list, root) == null) return fail("no such account '{s}'", .{root});
    var total: u64 = 0;
    var b: std.ArrayListUnmanaged(u8) = .empty;
    defer b.deinit(alloc);
    for (list.items, 0..) |a, i| {
        if (!inSubtree(&list, i, root)) continue;
        total += a.bal;
        var lb: [512]u8 = undefined;
        const parent = if (a.parent.len == 0) "-" else a.parent;
        b.appendSlice(alloc, std.fmt.bufPrint(&lb, "{s}\t{d}\t{s}\n", .{ a.id, a.bal, parent }) catch "") catch {};
    }
    var tb: [64]u8 = undefined;
    b.appendSlice(alloc, std.fmt.bufPrint(&tb, "total\t{d}\n", .{total}) catch "") catch {};
    out(b.items);
    return 0;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

fn usage() u8 {
    out(
        \\budget — conservation ledger for agent spawn trees (spawn = subdivide).
        \\
        \\  budget new   <id> <credits>              create a root pool
        \\  budget split <parent> <child> <credits>  carve a child out of the parent
        \\  budget spend <id> <credits>              debit (fails closed if short)
        \\  budget balance <id>                       print remaining credits
        \\  budget tree  <root>                       dump the subtree and its total
        \\
    );
    return 1;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next(); // argv0
    const verb = args.next() orelse return usage();

    if (std.mem.eql(u8, verb, "-h") or std.mem.eql(u8, verb, "--help")) {
        _ = usage();
        return 0;
    }

    if (std.mem.eql(u8, verb, "new")) {
        const id = args.next() orelse return fail("usage: budget new <id> <credits>", .{});
        const cs = args.next() orelse return fail("usage: budget new <id> <credits>", .{});
        if (args.next() != null) return fail("unexpected extra argument", .{});
        const c = parseCredits(cs) orelse return fail("credits must be a non-negative integer", .{});
        return cmdNew(id, c);
    }
    if (std.mem.eql(u8, verb, "split")) {
        const parent = args.next() orelse return fail("usage: budget split <parent> <child> <credits>", .{});
        const child = args.next() orelse return fail("usage: budget split <parent> <child> <credits>", .{});
        const cs = args.next() orelse return fail("usage: budget split <parent> <child> <credits>", .{});
        if (args.next() != null) return fail("unexpected extra argument", .{});
        const c = parseCredits(cs) orelse return fail("credits must be a non-negative integer", .{});
        return cmdSplit(parent, child, c);
    }
    if (std.mem.eql(u8, verb, "spend")) {
        const id = args.next() orelse return fail("usage: budget spend <id> <credits>", .{});
        const cs = args.next() orelse return fail("usage: budget spend <id> <credits>", .{});
        if (args.next() != null) return fail("unexpected extra argument", .{});
        const c = parseCredits(cs) orelse return fail("credits must be a non-negative integer", .{});
        return cmdSpend(id, c);
    }
    if (std.mem.eql(u8, verb, "balance")) {
        const id = args.next() orelse return fail("usage: budget balance <id>", .{});
        if (args.next() != null) return fail("unexpected extra argument", .{});
        return cmdBalance(id);
    }
    if (std.mem.eql(u8, verb, "tree")) {
        const root = args.next() orelse return fail("usage: budget tree <root>", .{});
        if (args.next() != null) return fail("unexpected extra argument", .{});
        return cmdTree(root);
    }
    return fail("unknown verb '{s}'", .{verb});
}
