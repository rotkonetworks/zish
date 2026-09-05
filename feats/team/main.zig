//! team — orchestrate a swarm of agents on one task (the Grok-Heavy shape),
//! bounded by the budget conservation primitive. This is sequencing brick #2 of
//! docs/agent-cloud.md §5: the Captain / worker / critic pattern over the shared
//! agent-to-agent substrate.
//!
//!   team run <root-budget> <task...>
//!
//! Phases (one `agent` call each — the whole loop is single-threaded, spawning
//! is process-level, never threads):
//!   1. CAPTAIN decomposes the task into a few independent sub-tasks.
//!   2. FAN-OUT: per sub-task, carve a budget slice off the root (`budget split`)
//!      and run a WORKER agent, whose model call is charged (`budget spend`).
//!   3. CRITIC (MANDATORY): one agent that REFUTES/cross-checks the workers'
//!      outputs. Load-bearing — collaboration without an adversarial critic is an
//!      echo chamber that amplifies errors. Never skipped.
//!   4. SYNTHESIS: the Captain combines only what survived the critic.
//!
//! Conservation: every credit spent flows from the root grant. Splits move
//! credits root->child and fail closed when the root is short, so the whole tree
//! can never exceed its root budget. Critic+synth budget is reserved up front, so
//! a run either affords its own critique (>=3 credits) or refuses to start.
//!
//! Contracts consumed (both resolved as feats: ZISH_FEAT_PATH else ~/.zish/feats,
//! standard then extra tier):
//!   budget new <id> <credits>
//!   budget split <parent> <child> <credits>   (nonzero if parent short)
//!   budget spend <id> <credits>               (nonzero if id short)
//!   budget balance <id>                        (prints an integer)
//!   agent [--mock <file>] <prompt>             (stdout = the agent's text)
//! The blackboard — a shared file under ~/.zish — is the collaboration medium:
//! workers append, critic+captain read (the structured agent-to-agent shared file).

const std = @import("std");
const linux = std.os.linux;
const alloc = std.heap.page_allocator;

const MAX_OUT = 16 * 1024 * 1024;
const MAX_WORKERS = 4;
const COST: i64 = 1; // credits per agent call
const RESERVE: i64 = COST * 2; // critic + synth, always kept back

// ---------------------------------------------------------------------------
// small helpers (syscall-shaped, matching feats/aur & feats/gf)
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

fn slurp(fd: i32, cap: usize) []u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var tmp: [65536]u8 = undefined;
    while (buf.items.len < cap) {
        const rc = linux.read(fd, &tmp, tmp.len);
        const n: isize = @bitCast(rc);
        if (n <= 0) break;
        buf.appendSlice(alloc, tmp[0..@intCast(n)]) catch break;
    }
    return buf.toOwnedSlice(alloc) catch &.{};
}

fn readFileAlloc(path: []const u8, cap: usize) ?[]u8 {
    var z: [4096]u8 = undefined;
    const p = toZ(&z, path) orelse return null;
    const fd_rc = linux.open(p, .{ .ACCMODE = .RDONLY }, 0);
    const fd: isize = @bitCast(fd_rc);
    if (fd < 0) return null;
    defer _ = linux.close(@intCast(fd));
    return slurp(@intCast(fd), cap);
}

fn writeFileTrunc(path: []const u8, bytes: []const u8) bool {
    var z: [4096]u8 = undefined;
    const p = toZ(&z, path) orelse return false;
    const fd_rc = linux.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
    const fd: isize = @bitCast(fd_rc);
    if (fd < 0) return false;
    defer _ = linux.close(@intCast(fd));
    writeFd(@intCast(fd), bytes);
    return true;
}

fn appendFile(path: []const u8, bytes: []const u8) void {
    var z: [4096]u8 = undefined;
    const p = toZ(&z, path) orelse return;
    const fd_rc = linux.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o600);
    const fd: isize = @bitCast(fd_rc);
    if (fd < 0) return;
    defer _ = linux.close(@intCast(fd));
    writeFd(@intCast(fd), bytes);
}

fn unlinkPath(path: []const u8) void {
    var z: [4096]u8 = undefined;
    const p = toZ(&z, path) orelse return;
    _ = linux.unlink(p);
}

fn exists(path: []const u8) bool {
    var z: [4096]u8 = undefined;
    const p = toZ(&z, path) orelse return false;
    var stx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, p, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &stx);
    return @as(isize, @bitCast(rc)) == 0;
}

const ExecResult = struct { out: []u8, code: u8 };

/// fork+exec via /usr/bin/env, capturing stdout and the exit code. Returns null
/// only on a spawn/plumbing failure.
fn exec(args: []const []const u8) ?ExecResult {
    var argv: [40]?[*:0]const u8 = undefined;
    var held: [40][]u8 = undefined;
    var nh: usize = 0;
    var n: usize = 0;
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
    defer for (held[0..nh]) |h| alloc.free(h);

    if (!push("env", &held, &nh, &argv, &n)) return null;
    for (args) |a| if (n >= argv.len - 1 or !push(a, &held, &nh, &argv, &n)) return null;
    argv[n] = null;
    const argvz: [*:null]const ?[*:0]const u8 = argv[0..n :null];

    var fds: [2]i32 = undefined;
    if (@as(isize, @bitCast(linux.pipe2(&fds, .{}))) < 0) return null;
    const pid_rc = linux.fork();
    const pid: isize = @bitCast(pid_rc);
    if (pid < 0) {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        return null;
    }
    if (pid == 0) {
        _ = linux.close(fds[0]);
        _ = linux.dup2(fds[1], 1);
        _ = linux.close(fds[1]);
        _ = linux.execve("/usr/bin/env", argvz, @ptrCast(std.c.environ));
        linux.exit(127);
    }
    _ = linux.close(fds[1]);
    const data = slurp(fds[0], MAX_OUT);
    _ = linux.close(fds[0]);
    var status: u32 = 0;
    _ = linux.waitpid(@intCast(pid), &status, 0);
    const code: u8 = if ((status & 0x7f) != 0) 128 else @intCast((status >> 8) & 0xff);
    return .{ .out = data, .code = code };
}

// ---------------------------------------------------------------------------
// feat resolution (same rules as aur/gf/zish)
// ---------------------------------------------------------------------------

fn featRootPath(buf: []u8) ?[]const u8 {
    if (getEnv("ZISH_FEAT_PATH")) |p| return p;
    const home = getEnv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.zish/feats", .{home}) catch null;
}

fn resolveBin(root: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    for ([_][]const u8{ "standard", "extra" }) |tier| {
        const p = std.fmt.bufPrint(buf, "{s}/{s}/{s}/bin/{s}", .{ root, tier, name, name }) catch continue;
        if (exists(p)) return p;
    }
    return null;
}

// ---------------------------------------------------------------------------
// the budget conservation primitive (consumed as the `budget` feat)
// ---------------------------------------------------------------------------

fn budgetNew(bin: []const u8, id: []const u8, credits: i64) bool {
    var cb: [32]u8 = undefined;
    const c = std.fmt.bufPrint(&cb, "{d}", .{credits}) catch return false;
    const r = exec(&.{ bin, "new", id, c }) orelse return false;
    defer alloc.free(r.out);
    return r.code == 0;
}

fn budgetSplit(bin: []const u8, parent: []const u8, child: []const u8, credits: i64) bool {
    var cb: [32]u8 = undefined;
    const c = std.fmt.bufPrint(&cb, "{d}", .{credits}) catch return false;
    const r = exec(&.{ bin, "split", parent, child, c }) orelse return false;
    defer alloc.free(r.out);
    return r.code == 0;
}

fn budgetSpend(bin: []const u8, id: []const u8, credits: i64) bool {
    var cb: [32]u8 = undefined;
    const c = std.fmt.bufPrint(&cb, "{d}", .{credits}) catch return false;
    const r = exec(&.{ bin, "spend", id, c }) orelse return false;
    defer alloc.free(r.out);
    return r.code == 0;
}

fn budgetBalance(bin: []const u8, id: []const u8) ?i64 {
    const r = exec(&.{ bin, "balance", id }) orelse return null;
    defer alloc.free(r.out);
    if (r.code != 0) return null;
    const t = std.mem.trim(u8, r.out, " \t\r\n");
    return std.fmt.parseInt(i64, t, 10) catch null;
}

// ---------------------------------------------------------------------------
// the agent seam (consumed as the `agent` feat; role is encoded in the prompt)
// ---------------------------------------------------------------------------

/// Invoke the agent with `prompt`; return its stdout (owned) or null on failure.
/// Passes --mock through when ZISH_JUDGE_MOCK is set, so a test can stay offline.
fn callAgent(bin: []const u8, prompt: []const u8) ?[]u8 {
    const r = if (getEnv("ZISH_JUDGE_MOCK")) |m|
        exec(&.{ bin, "--mock", m, "--ask", prompt })
    else
        exec(&.{ bin, "--ask", prompt });
    const rr = r orelse return null;
    if (rr.code != 0) {
        alloc.free(rr.out);
        return null;
    }
    return rr.out;
}

// --- parallel fan-out + hybrid (per-worker model) ---------------------------
// Workers run CONCURRENTLY (process-level, per the single-threaded-core rule —
// fork many, wait all, never threads). `ZISH_TEAM_MODELS` ("m1@backend, m2, ...")
// is a per-worker roster team rotates across workers, so you can mix a free-but-
// serial LOCAL model with genuinely-parallel HOSTED ones in one org (the hybrid).
const WorkerModel = struct { model: ?[]const u8, backend: ?[]const u8 };

fn loadModels(list: *std.ArrayListUnmanaged(WorkerModel)) void {
    const spec = getEnv("ZISH_TEAM_MODELS") orelse return; // env memory is stable
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |raw| {
        const e = std.mem.trim(u8, raw, " \t");
        if (e.len == 0) continue;
        if (std.mem.indexOfScalar(u8, e, '@')) |at|
            list.append(alloc, .{ .model = std.mem.trim(u8, e[0..at], " \t"), .backend = std.mem.trim(u8, e[at + 1 ..], " \t") }) catch {}
        else
            list.append(alloc, .{ .model = e, .backend = null }) catch {};
    }
}

fn modelFor(models: []const WorkerModel, idx: usize) WorkerModel {
    if (models.len == 0) return .{ .model = null, .backend = null };
    return models[idx % models.len];
}

/// fork+exec `env [ZISH_AGENT_BACKEND=..] agent [-m model] [--mock M] --ask
/// <prompt>` with stdout → `out_path`; returns the child pid WITHOUT waiting.
fn spawnAgentToFile(bin: []const u8, prompt: []const u8, out_path: []const u8, wm: WorkerModel) ?i32 {
    var argv: [16]?[*:0]const u8 = undefined;
    var held: [16][]u8 = undefined;
    var nh: usize = 0;
    var n: usize = 0;
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
    defer for (held[0..nh]) |h| alloc.free(h);
    if (!push("env", &held, &nh, &argv, &n)) return null;
    if (wm.backend) |b| {
        var bb: [256]u8 = undefined;
        const asg = std.fmt.bufPrint(&bb, "ZISH_AGENT_BACKEND={s}", .{b}) catch return null;
        if (!push(asg, &held, &nh, &argv, &n)) return null; // `env` consumes NAME=VAL
    }
    if (!push(bin, &held, &nh, &argv, &n)) return null;
    if (wm.model) |m| {
        if (!push("-m", &held, &nh, &argv, &n)) return null;
        if (!push(m, &held, &nh, &argv, &n)) return null;
    }
    if (getEnv("ZISH_JUDGE_MOCK")) |mock| {
        if (!push("--mock", &held, &nh, &argv, &n)) return null;
        if (!push(mock, &held, &nh, &argv, &n)) return null;
    }
    if (!push("--ask", &held, &nh, &argv, &n)) return null;
    if (!push(prompt, &held, &nh, &argv, &n)) return null;
    argv[n] = null;
    const argvz: [*:null]const ?[*:0]const u8 = argv[0..n :null];

    var oz: [4096]u8 = undefined;
    const op = toZ(&oz, out_path) orelse return null;
    const pid_rc = linux.fork();
    const cpid: isize = @bitCast(pid_rc);
    if (cpid < 0) return null;
    if (cpid == 0) {
        const fd: isize = @bitCast(linux.open(op, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600));
        if (fd >= 0) {
            _ = linux.dup2(@intCast(fd), 1);
            _ = linux.close(@intCast(fd));
        }
        _ = linux.execve("/usr/bin/env", argvz, @ptrCast(std.c.environ));
        linux.exit(127);
    }
    return @intCast(cpid);
}

fn reap(cpid: i32) void {
    var status: u32 = 0;
    _ = linux.waitpid(cpid, &status, 0);
}

// ---------------------------------------------------------------------------
// persona lenses (DATA, not code) — each role embodies a distinct STYLE, not a
// biography. Diversity across workers is the point: different lenses catch
// different failures. Loaded from lenses.toml (ZISH_LENS_FILE, else
// ZISH_RUBRIC_DIR/lenses.toml, else ~/.zish/rubrics/lenses.toml). Fail-open: no
// file → plain role prompts, unchanged behaviour. Never CODE — just prompt data.
// ---------------------------------------------------------------------------
const Lens = struct { role: []const u8, name: []const u8, style: []const u8 };

fn lensPath(buf: []u8) ?[]const u8 {
    if (getEnv("ZISH_LENS_FILE")) |p| return p;
    if (getEnv("ZISH_RUBRIC_DIR")) |d| return std.fmt.bufPrint(buf, "{s}/lenses.toml", .{d}) catch null;
    const home = getEnv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.zish/rubrics/lenses.toml", .{home}) catch null;
}

/// Parse `[[lens]]` blocks (role/name/style keys). Returns the owning content
/// buffer (Lens slices point into it — keep it alive), or null if no file.
fn loadLenses(list: *std.ArrayListUnmanaged(Lens)) ?[]u8 {
    var pb: [4096]u8 = undefined;
    const path = lensPath(&pb) orelse return null;
    const content = readFileAlloc(path, MAX_OUT) orelse return null;
    var role: []const u8 = "";
    var name: []const u8 = "";
    var style: []const u8 = "";
    var open = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \t\r");
        if (t.len == 0 or t[0] == '#') continue;
        if (std.mem.startsWith(u8, t, "[[lens]]")) {
            if (open and name.len > 0 and style.len > 0 and role.len > 0)
                list.append(alloc, .{ .role = role, .name = name, .style = style }) catch {};
            role = "";
            name = "";
            style = "";
            open = true;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
        const k = std.mem.trim(u8, t[0..eq], " \t");
        var v = std.mem.trim(u8, t[eq + 1 ..], " \t");
        if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') v = v[1 .. v.len - 1];
        if (std.mem.eql(u8, k, "role")) role = v else if (std.mem.eql(u8, k, "name")) name = v else if (std.mem.eql(u8, k, "style")) style = v;
    }
    if (open and name.len > 0 and style.len > 0 and role.len > 0)
        list.append(alloc, .{ .role = role, .name = name, .style = style }) catch {};
    return content;
}

/// The idx-th lens for `role` (rotating), or null. Rotation across workers is
/// what makes the swarm diverse rather than N clones.
fn lensFor(lenses: []const Lens, role: []const u8, idx: usize) ?Lens {
    var count: usize = 0;
    for (lenses) |l| if (std.mem.eql(u8, l.role, role)) {
        count += 1;
    };
    if (count == 0) return null;
    const pick = idx % count;
    var seen: usize = 0;
    for (lenses) |l| if (std.mem.eql(u8, l.role, role)) {
        if (seen == pick) return l;
        seen += 1;
    };
    return null;
}

/// The "you approach this like X: <style>" preamble (owned), or "" when no lens.
fn lensIntro(lens: ?Lens) []u8 {
    if (lens) |l|
        return std.fmt.allocPrint(alloc, "You approach this like {s}: {s}\n\n", .{ l.name, l.style }) catch (alloc.dupe(u8, "") catch unreachable);
    return alloc.dupe(u8, "") catch unreachable;
}

// ---------------------------------------------------------------------------
// org experts — persistent specialists any worker can CONSULT (a lateral
// information edge, not authority: the worker doesn't command the expert, it
// asks). A worker emits `BTW-ASK <name>: <question>`; team routes it to that
// expert and drops the answer on the blackboard. The org pays for the round-trip
// (charged to root, budget-gated so a consult can never breach the grant or the
// critic/synth reserve). Data-driven + fail-open, same as lenses:
// experts.toml (ZISH_EXPERTS_FILE / ZISH_RUBRIC_DIR / ~/.zish/rubrics).
// ---------------------------------------------------------------------------
const Expert = struct { name: []const u8, style: []const u8 };

fn expertsPath(buf: []u8) ?[]const u8 {
    if (getEnv("ZISH_EXPERTS_FILE")) |p| return p;
    if (getEnv("ZISH_RUBRIC_DIR")) |d| return std.fmt.bufPrint(buf, "{s}/experts.toml", .{d}) catch null;
    const home = getEnv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.zish/rubrics/experts.toml", .{home}) catch null;
}

fn loadExperts(list: *std.ArrayListUnmanaged(Expert)) ?[]u8 {
    var pb: [4096]u8 = undefined;
    const path = expertsPath(&pb) orelse return null;
    const content = readFileAlloc(path, MAX_OUT) orelse return null;
    var name: []const u8 = "";
    var style: []const u8 = "";
    var open = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \t\r");
        if (t.len == 0 or t[0] == '#') continue;
        if (std.mem.startsWith(u8, t, "[[expert]]")) {
            if (open and name.len > 0 and style.len > 0)
                list.append(alloc, .{ .name = name, .style = style }) catch {};
            name = "";
            style = "";
            open = true;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
        const k = std.mem.trim(u8, t[0..eq], " \t");
        var v = std.mem.trim(u8, t[eq + 1 ..], " \t");
        if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') v = v[1 .. v.len - 1];
        if (std.mem.eql(u8, k, "name")) name = v else if (std.mem.eql(u8, k, "style")) style = v;
    }
    if (open and name.len > 0 and style.len > 0)
        list.append(alloc, .{ .name = name, .style = style }) catch {};
    return content;
}

fn expertFor(experts: []const Expert, name: []const u8) ?Expert {
    for (experts) |e| if (std.ascii.eqlIgnoreCase(e.name, name)) return e;
    return null;
}

/// Service the FIRST `BTW-ASK <expert>: <question>` in a worker's output: route
/// it to the named expert, charge the org (root, budget-gated), append the answer
/// to the blackboard. One consult per worker keeps the cost bounded.
fn serviceBtwAsk(agent_bin: []const u8, budget_bin: []const u8, root_id: []const u8, bb_path: []const u8, experts: []const Expert, wout: []const u8, worker_idx: usize) void {
    if (experts.len == 0) return;
    var lines = std.mem.splitScalar(u8, wout, '\n');
    while (lines.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \t\r");
        if (!std.mem.startsWith(u8, t, "BTW-ASK ")) continue;
        const rest = t["BTW-ASK ".len..];
        const colon = std.mem.indexOfScalar(u8, rest, ':') orelse continue;
        const name = std.mem.trim(u8, rest[0..colon], " \t");
        const q = std.mem.trim(u8, rest[colon + 1 ..], " \t");
        if (name.len == 0 or q.len == 0) continue;
        const exp = expertFor(experts, name) orelse {
            const e = std.fmt.allocPrint(alloc, "(btw from worker {d}: unknown expert '{s}')\n", .{ worker_idx, name }) catch return;
            defer alloc.free(e);
            appendFile(bb_path, e);
            return;
        };
        // budget gate: the org pays; never spend into the critic/synth reserve
        const bal = budgetBalance(budget_bin, root_id) orelse 0;
        if (bal - COST < RESERVE) {
            appendFile(bb_path, "(expert consult skipped: reserving critic+synth budget)\n");
            return;
        }
        if (!budgetSpend(budget_bin, root_id, COST)) {
            appendFile(bb_path, "(expert consult skipped: spend failed)\n");
            return;
        }
        const eprompt = std.fmt.allocPrint(alloc, "You are the org's {s} expert: {s}\n\nA teammate asks: {s}\nAnswer concisely and concretely.", .{ exp.name, exp.style, q }) catch return;
        defer alloc.free(eprompt);
        const eout = callAgent(agent_bin, eprompt) orelse {
            const e = std.fmt.allocPrint(alloc, "(expert {s} unavailable)\n", .{exp.name}) catch return;
            defer alloc.free(e);
            appendFile(bb_path, e);
            return;
        };
        defer alloc.free(eout);
        const entry = std.fmt.allocPrint(alloc, "## expert {s} (consulted by worker {d})\nQ: {s}\n{s}\n", .{ exp.name, worker_idx, q, std.mem.trim(u8, eout, " \t\r\n") }) catch return;
        defer alloc.free(entry);
        appendFile(bb_path, entry);
        return; // one consult per worker
    }
}

// ---------------------------------------------------------------------------
// orchestration
// ---------------------------------------------------------------------------

fn teamRun(root_budget: i64, task: []const u8) u8 {
    var rb: [4096]u8 = undefined;
    const root = featRootPath(&rb) orelse {
        warn("team: no feat root (HOME unset)\n");
        return 2;
    };
    var ab: [4096]u8 = undefined;
    const agent_bin = resolveBin(root, "agent", &ab) orelse {
        warn("team: agent feat not installed\n");
        return 2;
    };
    var bbin: [4096]u8 = undefined;
    const budget_bin = resolveBin(root, "budget", &bbin) orelse {
        warn("team: budget feat not installed\n");
        return 2;
    };

    // Fail closed: a team that can't afford its own captain+critic+synth
    // shouldn't run — the critic is not optional.
    if (root_budget < COST * 3) {
        warn("team: root budget too small — need >= 3 credits (captain + critic + synth)\n");
        return 2;
    }

    const pid = linux.getpid();
    var idbuf: [64]u8 = undefined;
    const root_id = std.fmt.bufPrint(&idbuf, "team-{d}", .{pid}) catch return 2;
    if (!budgetNew(budget_bin, root_id, root_budget)) {
        warn("team: budget new failed\n");
        return 2;
    }

    const home = getEnv("HOME") orelse "";
    var pathbuf: [4096]u8 = undefined;
    const bb_path = std.fmt.bufPrint(&pathbuf, "{s}/.zish/.team-{d}.md", .{ home, pid }) catch return 2;
    _ = writeFileTrunc(bb_path, "# team blackboard\n");
    defer unlinkPath(bb_path);

    // 1. CAPTAIN decompose (charged to root)
    if (!budgetSpend(budget_bin, root_id, COST)) {
        warn("team: cannot afford captain\n");
        return 2;
    }
    // persona lenses (fail-open): captain/worker/critic each embody a style, not
    // a biography. No lens file ⇒ cap_intro/etc are "" and prompts are unchanged.
    var lenses: std.ArrayListUnmanaged(Lens) = .empty;
    defer lenses.deinit(alloc);
    const lens_content = loadLenses(&lenses);
    defer if (lens_content) |c| alloc.free(c);
    const cap_intro = lensIntro(lensFor(lenses.items, "captain", 0));
    defer alloc.free(cap_intro);

    // org experts a worker may consult via `BTW-ASK <name>: ...` (fail-open)
    var experts: std.ArrayListUnmanaged(Expert) = .empty;
    defer experts.deinit(alloc);
    const experts_content = loadExperts(&experts);
    defer if (experts_content) |c| alloc.free(c);
    var enames: std.ArrayListUnmanaged(u8) = .empty;
    defer enames.deinit(alloc);
    for (experts.items, 0..) |e, i| {
        if (i > 0) enames.appendSlice(alloc, ", ") catch {};
        enames.appendSlice(alloc, e.name) catch {};
    }

    const dprompt = std.fmt.allocPrint(alloc, "{s}CAPTAIN: decompose the following task into 2-3 short independent sub-tasks, one per line. TASK: {s}", .{ cap_intro, task }) catch return 2;
    defer alloc.free(dprompt);
    const decomp = callAgent(agent_bin, dprompt) orelse {
        warn("team: captain (decompose) call failed\n");
        return 1;
    };
    defer alloc.free(decomp);

    var subs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer subs.deinit(alloc);
    var lines = std.mem.splitScalar(u8, decomp, '\n');
    while (lines.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \t\r");
        if (t.len == 0) continue;
        subs.append(alloc, t) catch {};
        if (subs.items.len >= MAX_WORKERS) break;
    }

    // 2. FAN-OUT workers, IN PARALLEL — the whole point of a team is horizontal
    //    bandwidth. Split each affordable slice and SPAWN its worker without
    //    waiting; they run concurrently (process-level, never threads). Then
    //    wait all and collect. Conservation is unchanged: slices are carved
    //    up-front, RESERVE is kept for the critic + synthesis.
    var models: std.ArrayListUnmanaged(WorkerModel) = .empty;
    defer models.deinit(alloc);
    loadModels(&models); // ZISH_TEAM_MODELS → per-worker (hybrid local+hosted)

    const Spawn = struct { cpid: i32, out_path: []u8, sub: []const u8, idx: usize };
    var spawns: std.ArrayListUnmanaged(Spawn) = .empty;
    defer {
        for (spawns.items) |s| {
            unlinkPath(s.out_path);
            alloc.free(s.out_path);
        }
        spawns.deinit(alloc);
    }

    // Phase A: carve each affordable slice and spawn its worker (non-blocking)
    for (subs.items, 0..) |sub, i| {
        const bal = budgetBalance(budget_bin, root_id) orelse 0;
        if (bal - COST < RESERVE) {
            appendFile(bb_path, "(worker skipped: reserving critic+synth budget)\n");
            break;
        }
        var cidbuf: [80]u8 = undefined;
        const child = std.fmt.bufPrint(&cidbuf, "team-{d}-w{d}", .{ pid, i }) catch continue;
        if (!budgetSplit(budget_bin, root_id, child, COST)) {
            appendFile(bb_path, "(worker skipped: budget split failed)\n");
            continue;
        }
        if (!budgetSpend(budget_bin, child, COST)) {
            appendFile(bb_path, "(worker skipped: slice spend failed)\n");
            continue;
        }
        const w_intro = lensIntro(lensFor(lenses.items, "worker", i));
        defer alloc.free(w_intro);
        const btw = if (experts.items.len > 0)
            (std.fmt.allocPrint(alloc, " If you genuinely need domain input, emit ONE line `BTW-ASK <expert>: <question>` (experts: {s}); otherwise proceed and state any assumption.", .{enames.items}) catch (alloc.dupe(u8, "") catch unreachable))
        else
            (alloc.dupe(u8, "") catch unreachable);
        defer alloc.free(btw);
        const wprompt = std.fmt.allocPrint(alloc, "{s}WORKER: complete this sub-task and report the result.{s} SUBTASK: {s}", .{ w_intro, btw, sub }) catch continue;
        defer alloc.free(wprompt);
        const out_path = std.fmt.allocPrint(alloc, "{s}/.zish/.team-{d}-w{d}.out", .{ home, pid, i }) catch continue;
        const cpid = spawnAgentToFile(agent_bin, wprompt, out_path, modelFor(models.items, i)) orelse {
            alloc.free(out_path);
            appendFile(bb_path, "(worker spawn failed)\n");
            continue;
        };
        spawns.append(alloc, .{ .cpid = cpid, .out_path = out_path, .sub = sub, .idx = i }) catch {
            reap(cpid);
            unlinkPath(out_path);
            alloc.free(out_path);
        };
    }

    // Phase B: wait for all concurrently-running workers to finish
    for (spawns.items) |s| reap(s.cpid);

    // Phase C: collect outputs in order → blackboard, then service any consults
    var spawned: usize = 0;
    for (spawns.items) |s| {
        const wout = readFileAlloc(s.out_path, MAX_OUT) orelse {
            appendFile(bb_path, "(worker output missing)\n");
            continue;
        };
        defer alloc.free(wout);
        const trimmed = std.mem.trim(u8, wout, " \t\r\n");
        const entry = std.fmt.allocPrint(alloc, "## worker {d}\nsubtask: {s}\n{s}\n", .{ s.idx, s.sub, trimmed }) catch continue;
        defer alloc.free(entry);
        appendFile(bb_path, entry);
        // a worker may consult an org expert (lateral info edge, org-funded)
        serviceBtwAsk(agent_bin, budget_bin, root_id, bb_path, experts.items, wout, s.idx);
        spawned += 1;
    }

    // 3. CRITIC — MANDATORY. Runs on every path; a worker-only run is a bug. The
    //    spend is reserved, so it succeeds; even if accounting were exhausted we
    //    still run the critic (fail-open on the safety check), and the ledger
    //    can never go negative because `budget spend` fails closed.
    _ = budgetSpend(budget_bin, root_id, COST);
    const bb1 = readFileAlloc(bb_path, MAX_OUT) orelse alloc.dupe(u8, "") catch return 1;
    defer alloc.free(bb1);
    const crit_intro = lensIntro(lensFor(lenses.items, "critic", 0));
    defer alloc.free(crit_intro);
    const cprompt = std.fmt.allocPrint(alloc, "{s}CRITIC: refute and cross-check the worker outputs below; flag contradictions or errors. BLACKBOARD:\n{s}", .{ crit_intro, bb1 }) catch return 1;
    defer alloc.free(cprompt);
    const crit = callAgent(agent_bin, cprompt) orelse alloc.dupe(u8, "(critic unavailable)") catch return 1;
    defer alloc.free(crit);
    const centry = std.fmt.allocPrint(alloc, "## critic\n{s}\n", .{std.mem.trim(u8, crit, " \t\r\n")}) catch return 1;
    defer alloc.free(centry);
    appendFile(bb_path, centry);

    // 4. SYNTHESIS — the Captain keeps only what survived the critic.
    _ = budgetSpend(budget_bin, root_id, COST);
    const bb2 = readFileAlloc(bb_path, MAX_OUT) orelse alloc.dupe(u8, "") catch return 1;
    defer alloc.free(bb2);
    const sprompt = std.fmt.allocPrint(alloc, "{s}CAPTAIN SYNTHESIZE: produce the final answer from the blackboard, keeping only claims that survive the critic. BLACKBOARD:\n{s}", .{ cap_intro, bb2 }) catch return 1;
    defer alloc.free(sprompt);
    const final = callAgent(agent_bin, sprompt) orelse {
        warn("team: synthesis call failed\n");
        return 1;
    };
    defer alloc.free(final);
    out(std.mem.trim(u8, final, " \t\r\n"));
    out("\n");

    // stderr summary: make the conservation visible — how the root grant was
    // spent across the org (captain + workers + critic + synth).
    const final_bal = budgetBalance(budget_bin, root_id) orelse 0;
    var sb: [256]u8 = undefined;
    warn(std.fmt.bufPrint(&sb, "team: root {s} — budget {d}, spent {d}, remaining {d} ({d} workers)\n", .{ root_id, root_budget, root_budget - final_bal, final_bal, spawned }) catch "");
    return 0;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init.Minimal) u8 {
    return run(init.args);
}

fn run(args: std.process.Args) u8 {
    var it = args.iterate();
    _ = it.next(); // argv[0]
    const verb = it.next() orelse {
        printHelp();
        return 1;
    };
    if (std.mem.eql(u8, verb, "-h") or std.mem.eql(u8, verb, "--help")) {
        printHelp();
        return 0;
    }
    if (!std.mem.eql(u8, verb, "run")) {
        warn("team: unknown verb (expected 'run')\n");
        return 2;
    }
    const budget_arg = it.next() orelse {
        warn("team: usage: team run <root-budget> <task...>\n");
        return 2;
    };
    const root_budget = std.fmt.parseInt(i64, budget_arg, 10) catch {
        warn("team: root-budget must be a positive integer\n");
        return 2;
    };
    if (root_budget <= 0) {
        warn("team: root-budget must be a positive integer\n");
        return 2;
    }

    // remaining args = the task (joined with spaces)
    var task: std.ArrayListUnmanaged(u8) = .empty;
    defer task.deinit(alloc);
    var first = true;
    while (it.next()) |w| {
        if (!first) task.append(alloc, ' ') catch {};
        first = false;
        task.appendSlice(alloc, w) catch {};
    }
    if (task.items.len == 0) {
        warn("team: no task given\n");
        return 2;
    }
    return teamRun(root_budget, task.items);
}

fn printHelp() void {
    out(
        \\team — a budget-bounded agent swarm (Captain / workers / critic / synth).
        \\
        \\  team run <root-budget> <task...>
        \\      decompose the task, fan out workers (each carved from the root
        \\      budget), run a mandatory adversarial critic, then synthesize.
        \\      The tree can never spend more than <root-budget> credits.
        \\      Needs the `agent` and `budget` feats installed.
        \\
    );
}
