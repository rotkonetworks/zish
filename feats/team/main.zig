//! team — orchestrate a swarm of agents on one task (the Grok-Heavy shape),
//! bounded by the budget conservation primitive. This is sequencing brick #2 of
//! docs/agent-cloud.md §5: the Captain / worker / critic pattern over the shared
//! agent-to-agent substrate.
//!
//!   team run <root-budget> <task...>
//!
//! Phases (one `agent` call each — the whole loop is single-threaded, spawning
//! is process-level, never threads):
//!   1. Captain decomposes the task into a few independent sub-tasks.
//!   2. Fan-out: per sub-task, carve a budget slice off the root (`budget split`)
//!      and run a worker agent, whose model call is charged (`budget spend`).
//!   3. Critic (mandatory): one agent that cross-checks the workers'
//!      outputs. Collaboration without an adversarial critic lets errors compound
//!      uncaught. Never skipped.
//!   4. Synthesis: the captain combines only what survived the critic.
//!   5. Verify: the org member that actually runs a compiler. It extracts code
//!      from the answer and compile-checks it for real (rustc/zig/gofmt/…, per
//!      what's installed) — a model critic reviews text and can't catch a parse
//!      error. On failure it makes one budget-gated repair against the true
//!      compiler error. Never ships untested code silently. The org advertises
//!      its available checkers to the agents up front (capability discovery).
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
const feat = @import("lib/feat.zig");
const alloc = std.heap.page_allocator;

/// The environment block the kernel handed us, for `execve` to pass on verbatim
/// (a child inherits it, and every worker is such a child). `start.zig` captures
/// envp off the initial stack for the libc and freestanding start paths alike,
/// so this replaces the libc symbol `std.c.environ`. Looking a variable *up* is
/// `feat.env`'s job; nothing here reads this directly. Set at the top of `main`.
var child_envp: [*:null]const ?[*:0]const u8 = @ptrCast(&[1]?[*:0]const u8{null});

const MAX_OUT = 16 * 1024 * 1024;
const MAX_WORKERS = 4;
const COST: i64 = 1; // credits per agent call
const RESERVE: i64 = COST * 2; // critic + synth, always kept back

// ---------------------------------------------------------------------------
// live trace emission — one JSON event per line to ~/.zish/traces/<run>.jsonl,
// appended as things happen. A separate viewer (Deno SSE server + Solid/UnoCSS
// dashboard) tails this to follow the org in real time. team only writes the
// file; it knows nothing about HTTP. Fire-and-forget; no trace file = no-op.
// ---------------------------------------------------------------------------
var g_trace: ?[]const u8 = null;

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

fn emit(comptime fmt: []const u8, args: anytype) void {
    const tp = g_trace orelse return;
    const line = std.fmt.allocPrint(alloc, fmt ++ "\n", args) catch return;
    defer alloc.free(line);
    appendFile(tp, line);
}

/// A JSON-safe copy of `s` (drops quotes/backslashes/controls) — short labels.
fn jclean(s: []const u8) []u8 {
    var o: std.ArrayListUnmanaged(u8) = .empty;
    for (s) |c| if (c >= 0x20 and c != '"' and c != '\\') (o.append(alloc, c) catch {});
    return o.toOwnedSlice(alloc) catch (alloc.dupe(u8, "") catch unreachable);
}

/// Token usage + the model that actually ran, reported via the ZISH_ASK_META
/// sidecar. `model` is the agent's authoritative record of what it called.
const Meta = struct { pt: i64, ct: i64, model: []const u8 = "" };

/// Read a `{pt,ct,model,think}` meta sidecar. Always sets `think_out.*` (owned;
/// caller frees). Missing/invalid → 0 tokens, "", "".
fn readMeta(path: []const u8, think_out: *[]u8) Meta {
    think_out.* = alloc.dupe(u8, "") catch "";
    const c = readFileAlloc(path, MAX_OUT) orelse return .{ .pt = 0, .ct = 0 };
    defer alloc.free(c);
    const p = std.json.parseFromSlice(std.json.Value, alloc, c, .{}) catch return .{ .pt = 0, .ct = 0 };
    defer p.deinit();
    var pt: i64 = 0;
    var ct: i64 = 0;
    var model: []const u8 = "";
    if (p.value == .object) {
        if (p.value.object.get("pt")) |v| if (v == .integer) {
            pt = v.integer;
        };
        if (p.value.object.get("ct")) |v| if (v == .integer) {
            ct = v.integer;
        };
        if (p.value.object.get("model")) |v| if (v == .string) {
            model = alloc.dupe(u8, v.string) catch "";
        };
        if (p.value.object.get("think")) |v| if (v == .string) {
            alloc.free(think_out.*);
            think_out.* = alloc.dupe(u8, v.string) catch (alloc.dupe(u8, "") catch unreachable);
        };
    }
    return .{ .pt = pt, .ct = ct, .model = model };
}

/// Collect any `human_say` messages that were appended to the run's trace (by a
/// person replying in the dashboard) into "- <from>: <text>" lines. Empty if
/// none. This is how a mid-run human reply reaches the org — team folds it into
/// the synthesis so the final answer honors the guidance.
fn collectHumanSays() []u8 {
    var o: std.ArrayListUnmanaged(u8) = .empty;
    const tp = g_trace orelse return (o.toOwnedSlice(alloc) catch &.{});
    const content = readFileAlloc(tp, MAX_OUT) orelse return (o.toOwnedSlice(alloc) catch &.{});
    defer alloc.free(content);
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"ev\":\"human_say\"") == null) continue;
        const p = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        defer p.deinit();
        if (p.value != .object) continue;
        const from = if (p.value.object.get("from")) |v| (if (v == .string) v.string else "human") else "human";
        const text = if (p.value.object.get("text")) |v| (if (v == .string) v.string else "") else "";
        if (text.len == 0) continue;
        o.appendSlice(alloc, "- ") catch {};
        o.appendSlice(alloc, from) catch {};
        o.appendSlice(alloc, ": ") catch {};
        o.appendSlice(alloc, text) catch {};
        o.append(alloc, '\n') catch {};
    }
    return o.toOwnedSlice(alloc) catch (alloc.dupe(u8, "") catch unreachable);
}

// ---------------------------------------------------------------------------
// Prompts are DATA, not baked-in strings. Each role's prompt is a template with
// {placeholders}; the built-in default below ships the current behaviour, and a
// file at ~/.zish/prompts/<name>.txt (editable from the dashboard) overrides it.
// Placeholders per prompt are documented in the defaults; unknown ones pass through.
// ---------------------------------------------------------------------------
const DEFAULT_DECOMPOSE = "{lens}CAPTAIN: decompose the following task into 2-3 short independent sub-tasks, one per line.{caps}{budget} {context}TASK: {task}";
const DEFAULT_WORKER = "{lens}WORKER: complete this sub-task and report the result.{consult}{caps}{budget} {context}Put any code in a fenced block tagged with its language. SUBTASK: {sub}";
const DEFAULT_CRITIC = "{lens}CRITIC: refute and cross-check the worker outputs below; flag contradictions or errors.{budget} BLACKBOARD:\n{blackboard}";
const DEFAULT_SYNTH = "{lens}CAPTAIN SYNTHESIZE: produce the final answer from the blackboard, keeping only claims that survive the critic.{caps}{budget}{human} {context}Put any code in a fenced block tagged with its language. BLACKBOARD:\n{blackboard}";
const DEFAULT_REPAIR = "{lens}The {lang} code below FAILED to compile. Return ONLY the corrected COMPLETE code in a single fenced {lang} block — no prose.{budget}\n\nCOMPILER ERROR:\n{error}\n\nCODE:\n{code}";

/// The built-in default template for a prompt name (for loading + for the API to
/// advertise). Unknown name → "".
fn defaultPrompt(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "decompose")) return DEFAULT_DECOMPOSE;
    if (std.mem.eql(u8, name, "worker")) return DEFAULT_WORKER;
    if (std.mem.eql(u8, name, "critic")) return DEFAULT_CRITIC;
    if (std.mem.eql(u8, name, "synth")) return DEFAULT_SYNTH;
    if (std.mem.eql(u8, name, "repair")) return DEFAULT_REPAIR;
    return "";
}

/// Load a prompt template: ~/.zish/prompts/<name>.txt if it exists and is
/// non-empty, else the built-in default. Owned; caller frees.
fn loadPrompt(io: std.Io, name: []const u8) []u8 {
    const def = defaultPrompt(name);
    const home = getEnv(io, "HOME") orelse return alloc.dupe(u8, def) catch (alloc.dupe(u8, "") catch unreachable);
    var pb: [4096]u8 = undefined;
    if (std.fmt.bufPrint(&pb, "{s}/.zish/prompts/{s}.txt", .{ home, name })) |path| {
        if (readFileAlloc(path, MAX_OUT)) |c| {
            defer alloc.free(c);
            const t = std.mem.trim(u8, c, " \t\r\n");
            if (t.len > 0) return alloc.dupe(u8, t) catch (alloc.dupe(u8, def) catch "");
        }
    } else |_| {}
    return alloc.dupe(u8, def) catch (alloc.dupe(u8, "") catch unreachable);
}

/// Substitute {key} placeholders in `template` from `pairs`. Single pass, so a
/// value that itself contains braces is never re-scanned; unknown keys pass through.
fn renderTemplate(template: []const u8, pairs: []const [2][]const u8) []u8 {
    var o: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{') {
            if (std.mem.indexOfScalarPos(u8, template, i, '}')) |end| {
                const key = template[i + 1 .. end];
                var matched = false;
                for (pairs) |p| {
                    if (std.mem.eql(u8, p[0], key)) {
                        o.appendSlice(alloc, p[1]) catch {};
                        matched = true;
                        break;
                    }
                }
                if (matched) {
                    i = end + 1;
                    continue;
                }
                // unknown placeholder — leave it literal
            }
        }
        o.append(alloc, template[i]) catch {};
        i += 1;
    }
    return o.toOwnedSlice(alloc) catch (alloc.dupe(u8, "") catch unreachable);
}

const PROMPT_NAMES = [_][]const u8{ "decompose", "worker", "critic", "synth", "repair" };

/// Print the editable prompts as a JSON array of {name, default, current}.
fn printPrompts(io: std.Io) void {
    out("[");
    for (PROMPT_NAMES, 0..) |name, i| {
        if (i > 0) out(",");
        const cur = loadPrompt(io, name);
        defer alloc.free(cur);
        const de = jesc(defaultPrompt(name), 100000);
        defer alloc.free(de);
        const ce = jesc(cur, 100000);
        defer alloc.free(ce);
        const line = std.fmt.allocPrint(alloc, "{{\"name\":\"{s}\",\"default\":\"{s}\",\"current\":\"{s}\"}}", .{ name, de, ce }) catch continue;
        defer alloc.free(line);
        out(line);
    }
    out("]\n");
}

/// Proper JSON string escaping that keeps content readable (newlines→\n etc.),
/// truncated to `max` bytes — for the actual generated text an agent produced.
fn jesc(s: []const u8, max: usize) []u8 {
    var o: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    for (s) |c| {
        if (i >= max) {
            o.appendSlice(alloc, "\\u2026") catch {};
            break;
        }
        switch (c) {
            '"' => o.appendSlice(alloc, "\\\"") catch {},
            '\\' => o.appendSlice(alloc, "\\\\") catch {},
            '\n' => o.appendSlice(alloc, "\\n") catch {},
            '\r' => {},
            '\t' => o.appendSlice(alloc, "\\t") catch {},
            else => if (c >= 0x20) (o.append(alloc, c) catch {}),
        }
        i += 1;
    }
    return o.toOwnedSlice(alloc) catch (alloc.dupe(u8, "") catch unreachable);
}

// ---------------------------------------------------------------------------
// small helpers (syscall-shaped, matching feats/aur & feats/gf)
// ---------------------------------------------------------------------------

fn getEnv(io: std.Io, name: []const u8) ?[]const u8 {
    return feat.env(alloc, io, name);
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

/// merge_err folds the child's stderr into the captured output (a compiler
/// writes diagnostics there); timeout_s > 0 wraps the child in `timeout <n>` so
/// model-generated code can't hang a build. Defaults reproduce plain stdout capture.
const ExecOpts = struct { merge_err: bool = false, timeout_s: u32 = 0, stdin: ?[]const u8 = null };

/// fork+exec via /usr/bin/env, capturing stdout and the exit code. Returns null
/// only on a spawn/plumbing failure.
fn exec(args: []const []const u8, opts: ExecOpts) ?ExecResult {
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
    if (opts.timeout_s > 0) { // env timeout <n> <cmd…> — a build must not hang the org
        if (!push("timeout", &held, &nh, &argv, &n)) return null;
        var tb: [16]u8 = undefined;
        const ts = std.fmt.bufPrint(&tb, "{d}", .{opts.timeout_s}) catch return null;
        if (!push(ts, &held, &nh, &argv, &n)) return null;
    }
    for (args) |a| if (n >= argv.len - 1 or !push(a, &held, &nh, &argv, &n)) return null;
    argv[n] = null;
    const argvz: [*:null]const ?[*:0]const u8 = argv[0..n :null];

    var fds: [2]i32 = undefined;
    if (@as(isize, @bitCast(linux.pipe2(&fds, .{}))) < 0) return null;
    // optional input pipe: feed opts.stdin to the child's fd 0. No deadlock even
    // for large inputs — a checker reads all of stdin before it writes any output.
    var in_fds: [2]i32 = undefined;
    const has_in = opts.stdin != null;
    if (has_in and @as(isize, @bitCast(linux.pipe2(&in_fds, .{}))) < 0) {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        return null;
    }
    const pid_rc = linux.fork();
    const pid: isize = @bitCast(pid_rc);
    if (pid < 0) {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        if (has_in) {
            _ = linux.close(in_fds[0]);
            _ = linux.close(in_fds[1]);
        }
        return null;
    }
    if (pid == 0) {
        _ = linux.close(fds[0]);
        _ = linux.dup2(fds[1], 1);
        if (opts.merge_err) _ = linux.dup2(fds[1], 2);
        _ = linux.close(fds[1]);
        if (has_in) {
            _ = linux.close(in_fds[1]);
            _ = linux.dup2(in_fds[0], 0);
            _ = linux.close(in_fds[0]);
        }
        _ = linux.execve("/usr/bin/env", argvz, child_envp);
        linux.exit(127);
    }
    _ = linux.close(fds[1]);
    if (has_in) {
        _ = linux.close(in_fds[0]);
        if (opts.stdin) |sin| writeFd(in_fds[1], sin);
        _ = linux.close(in_fds[1]); // EOF to the child
    }
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

fn featRootPath(io: std.Io, buf: []u8) ?[]const u8 {
    if (getEnv(io, "ZISH_FEAT_PATH")) |p| return p;
    const home = getEnv(io, "HOME") orelse return null;
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
    const r = exec(&.{ bin, "new", id, c }, .{}) orelse return false;
    defer alloc.free(r.out);
    return r.code == 0;
}

fn budgetSplit(bin: []const u8, parent: []const u8, child: []const u8, credits: i64) bool {
    var cb: [32]u8 = undefined;
    const c = std.fmt.bufPrint(&cb, "{d}", .{credits}) catch return false;
    const r = exec(&.{ bin, "split", parent, child, c }, .{}) orelse return false;
    defer alloc.free(r.out);
    return r.code == 0;
}

fn budgetSpend(bin: []const u8, id: []const u8, credits: i64) bool {
    var cb: [32]u8 = undefined;
    const c = std.fmt.bufPrint(&cb, "{d}", .{credits}) catch return false;
    const r = exec(&.{ bin, "spend", id, c }, .{}) orelse return false;
    defer alloc.free(r.out);
    return r.code == 0;
}

fn budgetBalance(bin: []const u8, id: []const u8) ?i64 {
    const r = exec(&.{ bin, "balance", id }, .{}) orelse return null;
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
/// Call the agent one-shot. When `meta_path` is non-empty, the agent writes its
/// token usage + thinking there (via ZISH_ASK_META, injected as an `env` NAME=VAL).
fn callAgent(io: std.Io, bin: []const u8, prompt: []const u8, meta_path: []const u8, cap_n: usize) ?[]u8 {
    var masg_buf: [4096]u8 = undefined;
    const masg: []const u8 = if (meta_path.len > 0)
        (std.fmt.bufPrint(&masg_buf, "ZISH_ASK_META={s}", .{meta_path}) catch "")
    else
        "";
    var cap_buf: [64]u8 = undefined;
    const cap = std.fmt.bufPrint(&cap_buf, "ZISH_AGENT_MAX_TOKENS={d}", .{cap_n}) catch "";
    var args: [10][]const u8 = undefined;
    var n: usize = 0;
    if (masg.len > 0) {
        args[n] = masg;
        n += 1;
    }
    if (cap.len > 0) {
        args[n] = cap;
        n += 1;
    }
    args[n] = bin;
    n += 1;
    if (getEnv(io, "ZISH_JUDGE_MOCK")) |m| {
        args[n] = "--mock";
        n += 1;
        args[n] = m;
        n += 1;
    }
    args[n] = "--ask";
    n += 1;
    args[n] = prompt;
    n += 1;
    const rr = exec(args[0..n], .{}) orelse return null;
    if (rr.code != 0) {
        alloc.free(rr.out);
        return null;
    }
    return rr.out;
}

// --- parallel fan-out + hybrid (per-worker model) ---------------------------
// Workers run concurrently (process-level, per the single-threaded-core rule —
// fork many, wait all, never threads). `ZISH_TEAM_MODELS` ("m1@backend, m2, ...")
// is a per-worker roster team rotates across workers, so you can mix a free-but-
// serial local model with genuinely-parallel hosted ones in one org (the hybrid).
const WorkerModel = struct { model: ?[]const u8, backend: ?[]const u8 };

fn loadModels(io: std.Io, list: *std.ArrayListUnmanaged(WorkerModel)) void {
    const spec = getEnv(io, "ZISH_TEAM_MODELS") orelse return; // a process-lifetime value
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

// agent's own DEFAULT_MODEL — mirrored so `worker_start` can name the model a
// worker will actually use when no roster/-m is given, instead of the old lie
// "local". Keep in sync with feats/agent DEFAULT_MODEL. The agent still reports
// the authoritative model back via its meta sidecar (worker_done), so a drift
// here only affects the pre-call label, never the recorded truth.
const AGENT_DEFAULT_MODEL = "deepseek/deepseek-v4-flash-0731";

/// The model a worker will actually run with: explicit roster model → the
/// process-wide ZISH_AGENT_MODEL → the agent default. Never "local".
fn intendedModel(io: std.Io, wm: WorkerModel) []const u8 {
    if (wm.model) |m| return m;
    if (getEnv(io, "ZISH_AGENT_MODEL")) |m| return m;
    return AGENT_DEFAULT_MODEL;
}

fn envUint(io: std.Io, name: []const u8) ?usize {
    const v = getEnv(io, name) orelse return null;
    if (v.len == 0 or v.len >= 8) return null;
    for (v) |c| if (c < '0' or c > '9') return null;
    return std.fmt.parseInt(usize, v, 10) catch null;
}

/// Base per-call completion cap in tokens — the hard cost bound the org hands the
/// many fan-out calls (workers, decompose, critic, consults), where runaway cost
/// lives. Budget credits bound the number of calls; this bounds each call's size.
/// Override ZISH_TEAM_MAX_TOKENS; default 2048.
fn capBase(io: std.Io) usize {
    return envUint(io, "ZISH_TEAM_MAX_TOKENS") orelse 2048;
}

/// Workers run the tool-using `agent solo` loop (real shell/web/checker access)
/// instead of tool-less `--ask` when ZISH_TEAM_TOOLS=1. This is what a long-form,
/// evidence-gathering run (e.g. formal-verification research) needs.
fn teamToolsMode(io: std.Io) bool {
    const v = getEnv(io, "ZISH_TEAM_TOOLS") orelse return false;
    return std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
}

/// Cap for the synthesis (and repair) — the final deliverable. Capping the one
/// answer call to the same tight budget as fan-out truncates the product
/// mid-output; it's a single call per run, so give it real room to finish.
/// Override ZISH_TEAM_SYNTH_MAX_TOKENS; default 4× the base cap.
fn capSynth(io: std.Io) usize {
    return envUint(io, "ZISH_TEAM_SYNTH_MAX_TOKENS") orelse (capBase(io) * 4);
}

/// fork+exec `env [ZISH_AGENT_BACKEND=..] agent [-m model] [--mock M] --ask
/// <prompt>` with stdout → `out_path`; returns the child pid without waiting.
fn spawnAgentToFile(io: std.Io, bin: []const u8, prompt: []const u8, out_path: []const u8, wm: WorkerModel) ?i32 {
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
    { // tokens + thinking sidecar the worker writes, next to its output file
        var mb: [4096]u8 = undefined;
        const masg = std.fmt.bufPrint(&mb, "ZISH_ASK_META={s}.meta", .{out_path}) catch return null;
        if (!push(masg, &held, &nh, &argv, &n)) return null;
    }
    { // completion cap — the hard per-call cost bound (agent's max_tokens)
        var cb: [64]u8 = undefined;
        const casg = std.fmt.bufPrint(&cb, "ZISH_AGENT_MAX_TOKENS={d}", .{capBase(io)}) catch return null;
        if (!push(casg, &held, &nh, &argv, &n)) return null;
    }
    if (!push(bin, &held, &nh, &argv, &n)) return null;
    // ZISH_TEAM_TOOLS=1 → workers run the tool-using `solo` loop (read files, web,
    // run checkers) instead of tool-less `--ask`. Costs more (multiple calls per
    // worker) but does real work. The verb goes right after the bin.
    const tools = teamToolsMode(io);
    if (tools) {
        if (!push("solo", &held, &nh, &argv, &n)) return null;
    }
    if (wm.model) |m| {
        if (!push("-m", &held, &nh, &argv, &n)) return null;
        if (!push(m, &held, &nh, &argv, &n)) return null;
    }
    if (getEnv(io, "ZISH_JUDGE_MOCK")) |mock| {
        if (!push("--mock", &held, &nh, &argv, &n)) return null;
        if (!push(mock, &held, &nh, &argv, &n)) return null;
    }
    if (!tools) {
        if (!push("--ask", &held, &nh, &argv, &n)) return null;
    }
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
        _ = linux.execve("/usr/bin/env", argvz, child_envp);
        linux.exit(127);
    }
    return @intCast(cpid);
}

/// Reap any finished child, returning its pid (or -1) — so parallel workers get
/// their true finish times as they complete, not clustered at collect.
fn waitAny() i32 {
    var status: u32 = 0;
    const r: isize = @bitCast(linux.waitpid(-1, &status, 0));
    return if (r < 0) -1 else @intCast(r);
}

fn reap(cpid: i32) void {
    var status: u32 = 0;
    _ = linux.waitpid(cpid, &status, 0);
}

// ---------------------------------------------------------------------------
// persona lenses (data, not code) — each role embodies a distinct style, not a
// biography. Diversity across workers is the point: different lenses catch
// failures. Loaded from lenses.toml: ZISH_LENS_FILE if set, else
// feat.rubricFile (ZISH_RUBRIC_DIR, then ~/.zish/rubrics, then the feat's own
// rubrics/ beside the binary). Fail-open: no file → plain role prompts,
// unchanged behaviour. Never code — just prompt data.
// ---------------------------------------------------------------------------
const Lens = struct { role: []const u8, name: []const u8, style: []const u8 };

fn lensPath(io: std.Io, buf: []u8) ?[]const u8 {
    if (getEnv(io, "ZISH_LENS_FILE")) |p| return p;
    return feat.rubricFile(alloc, io, buf, "lenses.toml");
}

/// Parse `[[lens]]` blocks (role/name/style keys). Returns the owning content
/// buffer (Lens slices point into it — keep it alive), or null if no file.
fn loadLenses(io: std.Io, list: *std.ArrayListUnmanaged(Lens)) ?[]u8 {
    var pb: [4096]u8 = undefined;
    const path = lensPath(io, &pb) orelse return null;
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
// org experts — persistent specialists any worker can consult (a lateral
// information edge, not authority: the worker doesn't command the expert, it
// asks). A worker emits `BTW-ASK <name>: <question>`; team routes it to that
// expert and drops the answer on the blackboard. The org pays for the round-trip
// (charged to root, budget-gated so a consult can never breach the grant or the
// critic/synth reserve). Data-driven + fail-open, same as lenses:
// experts.toml (ZISH_EXPERTS_FILE if set, else feat.rubricFile).
// ---------------------------------------------------------------------------
const Expert = struct { name: []const u8, style: []const u8 };

fn expertsPath(io: std.Io, buf: []u8) ?[]const u8 {
    if (getEnv(io, "ZISH_EXPERTS_FILE")) |p| return p;
    return feat.rubricFile(alloc, io, buf, "experts.toml");
}

fn loadExperts(io: std.Io, list: *std.ArrayListUnmanaged(Expert)) ?[]u8 {
    var pb: [4096]u8 = undefined;
    const path = expertsPath(io, &pb) orelse return null;
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

/// Service the first `BTW-ASK <expert>: <question>` in a worker's output: route
/// it to the named expert, charge the org (root, budget-gated), append the answer
/// to the blackboard. One consult per worker keeps the cost bounded.
fn serviceBtwAsk(io: std.Io, agent_bin: []const u8, budget_bin: []const u8, root_id: []const u8, bb_path: []const u8, experts: []const Expert, wout: []const u8, worker_idx: usize) void {
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
        var emeta_buf: [4096]u8 = undefined;
        const emp = std.fmt.bufPrint(&emeta_buf, "{s}.consult.meta", .{bb_path}) catch "";
        const eout = callAgent(io, agent_bin, eprompt, emp, capBase(io)) orelse {
            const e = std.fmt.allocPrint(alloc, "(expert {s} unavailable)\n", .{exp.name}) catch return;
            defer alloc.free(e);
            appendFile(bb_path, e);
            return;
        };
        defer alloc.free(eout);
        const entry = std.fmt.allocPrint(alloc, "## expert {s} (consulted by worker {d})\nQ: {s}\n{s}\n", .{ exp.name, worker_idx, q, std.mem.trim(u8, eout, " \t\r\n") }) catch return;
        defer alloc.free(entry);
        appendFile(bb_path, entry);
        const ec = jclean(exp.name);
        defer alloc.free(ec);
        const qesc = jesc(q, 2000);
        defer alloc.free(qesc);
        const aesc = jesc(std.mem.trim(u8, eout, " \t\r\n"), 8000);
        defer alloc.free(aesc);
        var ethink: []u8 = undefined;
        const etok = readMeta(emp, &ethink);
        alloc.free(ethink);
        unlinkPath(emp);
        emit("{{\"t\":{d},\"ev\":\"consult\",\"worker\":{d},\"expert\":\"{s}\",\"pt\":{d},\"ct\":{d},\"q\":\"{s}\",\"a\":\"{s}\"}}", .{ nowMs(), worker_idx, ec, etok.pt, etok.ct, qesc, aesc });
        return; // one consult per worker
    }
}

// ---------------------------------------------------------------------------
// verifier member — the org member that actually runs a compiler. A model critic
// reviews text and cannot catch `idx -= ;`. team delegates the compile-check to
// the `verify` feat (a reusable primitive: `verify caps`, `verify <lang> <code`);
// team owns only the orchestration — extract code, gate, one repair round. So the
// compiler knowledge lives in one place, usable outside team too.
// ---------------------------------------------------------------------------

/// Ask the verify feat which checkers this host has (for the capability line the
/// org shows its agents). Empty if the feat is missing or has none.
fn capsFromFeat(verify_bin: []const u8, buf: []u8) []const u8 {
    const r = exec(&.{ verify_bin, "caps" }, .{}) orelse return "";
    defer alloc.free(r.out);
    const t = std.mem.trim(u8, r.out, " \t\r\n");
    const n = @min(t.len, buf.len);
    @memcpy(buf[0..n], t[0..n]);
    return buf[0..n];
}

const TagCode = struct { tag: []u8, code: []u8 }; // both owned

/// Distinct fenced ```<tag> blocks in `text`, concatenating same-tag bodies
/// (models split code across blocks). Caller frees via freeTagged.
fn extractTagged(text: []const u8) []TagCode {
    var list: std.ArrayListUnmanaged(TagCode) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "```")) |open| {
        const after = open + 3;
        const nl = std.mem.indexOfScalarPos(u8, text, after, '\n') orelse break;
        const tag = std.mem.trim(u8, text[after..nl], " \t\r");
        const close = std.mem.indexOfPos(u8, text, nl + 1, "```") orelse break;
        const body = text[nl + 1 .. close];
        i = close + 3;
        if (tag.len == 0) continue; // an untagged block isn't code we can route
        var merged = false;
        for (list.items) |*tc| if (std.ascii.eqlIgnoreCase(tc.tag, tag)) {
            const m = std.fmt.allocPrint(alloc, "{s}{s}\n", .{ tc.code, body }) catch {
                merged = true;
                break;
            };
            alloc.free(tc.code);
            tc.code = m;
            merged = true;
            break;
        };
        if (merged) continue;
        const c = std.fmt.allocPrint(alloc, "{s}\n", .{body}) catch continue;
        const t = alloc.dupe(u8, tag) catch {
            alloc.free(c);
            continue;
        };
        list.append(alloc, .{ .tag = t, .code = c }) catch {
            alloc.free(c);
            alloc.free(t);
        };
    }
    return list.toOwnedSlice(alloc) catch &.{};
}

fn freeTagged(items: []TagCode) void {
    for (items) |tc| {
        alloc.free(tc.tag);
        alloc.free(tc.code);
    }
    alloc.free(items);
}

const VStatus = enum { ok, fail, skip_lang, skip_unknown };
const VResult = struct { status: VStatus, err: []u8 }; // err owned; caller frees

/// Compile-check `code` (tagged `tag`) by execing the verify feat, code on stdin.
/// Exit → status: 0 ok, 1 fail (diagnostics in err), 4 known-lang-no-toolchain,
/// 3/other unknown tag (not code we claim to check).
fn verifyViaFeat(verify_bin: []const u8, tag: []const u8, code: []const u8) VResult {
    const r = exec(&.{ verify_bin, tag }, .{ .merge_err = true, .timeout_s = 70, .stdin = code }) orelse
        return .{ .status = .skip_unknown, .err = alloc.dupe(u8, "(verify feat spawn failed)") catch (alloc.dupe(u8, "") catch unreachable) };
    const err = alloc.dupe(u8, std.mem.trim(u8, r.out, " \t\r\n")) catch (alloc.dupe(u8, "") catch unreachable);
    alloc.free(r.out);
    const st: VStatus = switch (r.code) {
        0 => .ok,
        1 => .fail,
        4 => .skip_lang,
        else => .skip_unknown,
    };
    return .{ .status = st, .err = err };
}

/// Pull the corrected code for `tag` out of a repair answer (else the raw text).
fn codeForTag(text: []const u8, tag: []const u8) []u8 {
    const tagged = extractTagged(text);
    defer freeTagged(tagged);
    for (tagged) |tc| if (std.ascii.eqlIgnoreCase(tc.tag, tag))
        return alloc.dupe(u8, tc.code) catch (alloc.dupe(u8, text) catch "");
    return alloc.dupe(u8, text) catch "";
}

/// Surface a compile failure on stdout AND the blackboard — broken code is never
/// presented as if it were done.
fn printVerifyFail(bb_path: []const u8, lname: []const u8, err: []const u8) void {
    const msg = std.fmt.allocPrint(alloc, "\n[verify] {s}: DOES NOT COMPILE:\n{s}\n", .{ lname, err }) catch return;
    defer alloc.free(msg);
    out(msg);
    appendFile(bb_path, msg);
}

/// The verifier phase: for every tagged code block in the synth answer, ask the
/// verify feat to compile-check it; on failure make one budget-gated repair
/// against the real compiler error, then re-verify. Always prints the compile
/// status — this is what stops the org from committing untested code.
fn verifyAndGate(io: std.Io, agent_bin: []const u8, budget_bin: []const u8, verify_bin: []const u8, root_id: []const u8, bb_path: []const u8, cap_intro: []const u8, final_text: []const u8) void {
    const tagged = extractTagged(final_text);
    defer freeTagged(tagged);
    for (tagged) |tc| {
        const vr = verifyViaFeat(verify_bin, tc.tag, tc.code);
        defer alloc.free(vr.err);
        switch (vr.status) {
            .skip_unknown => {}, // a ```json/```text/… block — not code we gate; stay silent
            .skip_lang => {
                const msg = std.fmt.allocPrint(alloc, "\n[verify] {s}: SKIPPED — no toolchain installed\n", .{tc.tag}) catch continue;
                defer alloc.free(msg);
                out(msg);
                appendFile(bb_path, msg);
                emit("{{\"t\":{d},\"ev\":\"verify\",\"lang\":\"{s}\",\"level\":\"syntax\",\"ok\":null,\"skipped\":true,\"repaired\":false,\"err\":\"no toolchain\"}}", .{ nowMs(), jclean(tc.tag) });
            },
            .ok => {
                const msg = std.fmt.allocPrint(alloc, "\n[verify] {s}: OK — compiles (syntax)\n", .{tc.tag}) catch continue;
                defer alloc.free(msg);
                out(msg);
                appendFile(bb_path, msg);
                emit("{{\"t\":{d},\"ev\":\"verify\",\"lang\":\"{s}\",\"level\":\"syntax\",\"ok\":true,\"repaired\":false,\"err\":\"\"}}", .{ nowMs(), jclean(tc.tag) });
            },
            .fail => {
                {
                    const eesc = jesc(vr.err, 4000);
                    defer alloc.free(eesc);
                    emit("{{\"t\":{d},\"ev\":\"verify\",\"lang\":\"{s}\",\"level\":\"syntax\",\"ok\":false,\"repaired\":false,\"err\":\"{s}\"}}", .{ nowMs(), jclean(tc.tag), eesc });
                }
                // one repair round, budget-gated (an agent call costs like any other)
                if ((budgetBalance(budget_bin, root_id) orelse 0) < COST or !budgetSpend(budget_bin, root_id, COST)) {
                    printVerifyFail(bb_path, tc.tag, vr.err);
                    continue;
                }
                var rbud_buf: [160]u8 = undefined;
                const rbud = std.fmt.bufPrint(&rbud_buf, " Keep within ~{d} output tokens (reasoning included, hard-cut) — return the code, minimal reasoning.", .{capSynth(io)}) catch "";
                const rtmpl = loadPrompt(io, "repair");
        defer alloc.free(rtmpl);
        const rprompt = renderTemplate(rtmpl, &.{ .{ "lens", cap_intro }, .{ "lang", tc.tag }, .{ "budget", rbud }, .{ "error", vr.err }, .{ "code", tc.code } });
                defer alloc.free(rprompt);
                var rmeta_buf: [4096]u8 = undefined;
                const rmp = std.fmt.bufPrint(&rmeta_buf, "{s}.repair.meta", .{bb_path}) catch "";
                const fixed = callAgent(io, agent_bin, rprompt, rmp, capSynth(io)) orelse {
                    printVerifyFail(bb_path, tc.tag, vr.err);
                    continue;
                };
                defer alloc.free(fixed);
                var rthink: []u8 = undefined;
                const rtok = readMeta(rmp, &rthink);
                alloc.free(rthink);
                unlinkPath(rmp);

                const code2 = codeForTag(fixed, tc.tag);
                defer alloc.free(code2);
                const vr2 = verifyViaFeat(verify_bin, tc.tag, code2);
                defer alloc.free(vr2.err);
                const ok2 = vr2.status == .ok;
                {
                    const e2 = jesc(vr2.err, 4000);
                    defer alloc.free(e2);
                    emit("{{\"t\":{d},\"ev\":\"verify\",\"lang\":\"{s}\",\"level\":\"syntax\",\"ok\":{s},\"repaired\":true,\"pt\":{d},\"ct\":{d},\"err\":\"{s}\"}}", .{ nowMs(), jclean(tc.tag), if (ok2) "true" else "false", rtok.pt, rtok.ct, e2 });
                }
                if (ok2) {
                    const msg = std.fmt.allocPrint(alloc, "\n[verify] {s}: FAILED → repaired, now compiles. Corrected code:\n```{s}\n{s}\n```\n", .{ tc.tag, tc.tag, std.mem.trim(u8, code2, " \t\r\n") }) catch continue;
                    defer alloc.free(msg);
                    out(msg);
                    appendFile(bb_path, msg);
                } else {
                    printVerifyFail(bb_path, tc.tag, vr2.err);
                }
            },
        }
    }
}

// ---------------------------------------------------------------------------
// orchestration
// ---------------------------------------------------------------------------

fn teamRun(io: std.Io, root_budget: i64, task: []const u8, context: []const u8) u8 {
    // A dispatched run can carry the topic's prior conversation for continuity.
    // It is prepended to the decompose + synth prompts (workers get only their
    // subtask). Rendered into the {context} slot; empty = no preamble.
    const ctx_block: []const u8 = if (context.len > 0)
        std.fmt.allocPrint(alloc, "PRIOR CONVERSATION (context for continuity; the NEW request is last, act on it):\n{s}\n\n", .{context}) catch ""
    else
        "";
    defer if (ctx_block.len > 0) alloc.free(ctx_block);
    var rb: [4096]u8 = undefined;
    const root = featRootPath(io, &rb) orelse {
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
    // The verifier is a feat (reusable compiler gate). Fail-open: if it isn't
    // installed the org still runs, just without the compile gate.
    var vbin: [4096]u8 = undefined;
    const verify_bin: []const u8 = resolveBin(root, "verify", &vbin) orelse "";
    // ask feat: with ZISH_TEAM_CONFIRM set, the org checks its plan with the human
    // (routed to the dashboard) before fanning out. Opt-in; fail-open if absent.
    var abin: [4096]u8 = undefined;
    const ask_bin: []const u8 = resolveBin(root, "ask", &abin) orelse "";

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

    const home = getEnv(io, "HOME") orelse "";
    // ~/.zish/traces holds the whole run: the event stream (.jsonl) AND the full
    // transcript (.md). Both PERSIST — the point is to read what every agent
    // generated, live and after. (No unlink.)
    if (home.len > 0) {
        var dbuf: [4096]u8 = undefined;
        if (std.fmt.bufPrint(&dbuf, "{s}/.zish/traces", .{home})) |dir| {
            var dz: [4096]u8 = undefined;
            if (toZ(&dz, dir)) |dp| _ = linux.mkdir(dp, 0o700);
        } else |_| {}
    }
    var pathbuf: [4096]u8 = undefined;
    const bb_path = std.fmt.bufPrint(&pathbuf, "{s}/.zish/traces/{d}.md", .{ home, pid }) catch return 2;
    _ = writeFileTrunc(bb_path, "# team transcript\n");

    var trbuf: [4096]u8 = undefined;
    if (home.len > 0) {
        if (std.fmt.bufPrint(&trbuf, "{s}/.zish/traces/{d}.jsonl", .{ home, pid })) |tp| g_trace = tp else |_| {}
    }
    const run_started = nowMs();
    {
        const tc = jclean(task);
        defer alloc.free(tc);
        emit("{{\"t\":{d},\"ev\":\"run_start\",\"run\":{d},\"task\":\"{s}\",\"budget\":{d}}}", .{ nowMs(), pid, tc, root_budget });
    }

    // 1. captain decompose (charged to root)
    if (!budgetSpend(budget_bin, root_id, COST)) {
        warn("team: cannot afford captain\n");
        return 2;
    }
    // persona lenses (fail-open): captain/worker/critic each embody a style, not
    // a biography. No lens file ⇒ cap_intro/etc are "" and prompts are unchanged.
    var lenses: std.ArrayListUnmanaged(Lens) = .empty;
    defer lenses.deinit(alloc);
    const lens_content = loadLenses(io, &lenses);
    defer if (lens_content) |c| alloc.free(c);
    const cap_intro = lensIntro(lensFor(lenses.items, "captain", 0));
    defer alloc.free(cap_intro);

    // org experts a worker may consult via `BTW-ASK <name>: ...` (fail-open)
    var experts: std.ArrayListUnmanaged(Expert) = .empty;
    defer experts.deinit(alloc);
    const experts_content = loadExperts(io, &experts);
    defer if (experts_content) |c| alloc.free(c);
    var enames: std.ArrayListUnmanaged(u8) = .empty;
    defer enames.deinit(alloc);
    for (experts.items, 0..) |e, i| {
        if (i > 0) enames.appendSlice(alloc, ", ") catch {};
        enames.appendSlice(alloc, e.name) catch {};
    }

    // Advertise what the verifier can actually compile-check, so agents pick a
    // language the org can verify (or flag up front that they need a toolchain /
    // pinned environment outside this set) — capability discovery, not restriction.
    var capbuf: [256]u8 = undefined;
    const caps = if (verify_bin.len > 0) capsFromFeat(verify_bin, &capbuf) else "";
    var capline_buf: [384]u8 = undefined;
    const capline = if (caps.len > 0)
        (std.fmt.bufPrint(&capline_buf, " The org can compile-verify code in: {s} — prefer these and tag each code block with its language; if a solution needs a language or pinned toolchain outside that set, say so instead of emitting code that can't be checked.", .{caps}) catch "")
    else
        "";

    // Tell the agent its output budget UP FRONT. A hard max_tokens cutoff the
    // model doesn't know about is a guillotine — a thinking model spends the
    // whole budget reasoning and gets truncated before the answer. Communicating
    // the number (and that reasoning counts toward it) lets the model allocate.
    const bmsg = " OUTPUT BUDGET: keep your COMPLETE response within ~{d} tokens (~{d} words). Any reasoning/thinking counts toward this limit and it is HARD-CUT at the end — so reason briefly and make sure your final answer is fully written before you reach it.";
    var budgetline_buf: [320]u8 = undefined;
    const cap_n = capBase(io); // workers / decompose / critic
    const budgetline = std.fmt.bufPrint(&budgetline_buf, bmsg, .{ cap_n, cap_n * 3 / 4 }) catch "";
    var sbudget_buf: [320]u8 = undefined; // synthesis gets its own, larger budget
    const scap_n = capSynth(io);
    const sbudgetline = std.fmt.bufPrint(&sbudget_buf, bmsg, .{ scap_n, scap_n * 3 / 4 }) catch "";

    const dtmpl = loadPrompt(io, "decompose");
    defer alloc.free(dtmpl);
    const dprompt = renderTemplate(dtmpl, &.{ .{ "lens", cap_intro }, .{ "caps", capline }, .{ "budget", budgetline }, .{ "context", ctx_block }, .{ "task", task } });
    defer alloc.free(dprompt);
    var dmeta_buf: [4096]u8 = undefined;
    const dmp = std.fmt.bufPrint(&dmeta_buf, "{s}.dec.meta", .{bb_path}) catch "";
    const decomp = callAgent(io, agent_bin, dprompt, dmp, capBase(io)) orelse {
        warn("team: captain (decompose) call failed\n");
        return 1;
    };
    defer alloc.free(decomp);
    var dthink: []u8 = undefined;
    const dtok = readMeta(dmp, &dthink);
    alloc.free(dthink);
    unlinkPath(dmp);

    var subs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer subs.deinit(alloc);
    var lines = std.mem.splitScalar(u8, decomp, '\n');
    while (lines.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \t\r");
        if (t.len == 0) continue;
        subs.append(alloc, t) catch {};
        if (subs.items.len >= MAX_WORKERS) break;
    }
    emit("{{\"t\":{d},\"ev\":\"decompose\",\"n\":{d},\"pt\":{d},\"ct\":{d}}}", .{ nowMs(), subs.items.len, dtok.pt, dtok.ct });

    // 1b. human checkpoint (opt-in): show the plan and let the human abort before
    //     spending the fan-out budget. Fail-open — no ask feat, no answer, or a
    //     timeout all proceed; only an explicit "Abort" stops the run.
    if (getEnv(io, "ZISH_TEAM_CONFIRM") != null and ask_bin.len > 0 and subs.items.len > 0) {
        var qb: std.ArrayListUnmanaged(u8) = .empty;
        defer qb.deinit(alloc);
        qb.appendSlice(alloc, "Captain's plan — ") catch {};
        var nbuf: [16]u8 = undefined;
        qb.appendSlice(alloc, std.fmt.bufPrint(&nbuf, "{d}", .{subs.items.len}) catch "?") catch {};
        qb.appendSlice(alloc, " sub-tasks: ") catch {};
        for (subs.items, 0..) |s, i| {
            if (i > 0) qb.appendSlice(alloc, "; ") catch {};
            var ib: [16]u8 = undefined;
            qb.appendSlice(alloc, std.fmt.bufPrint(&ib, "{d}) ", .{i + 1}) catch "") catch {};
            qb.appendSlice(alloc, s) catch {};
        }
        qb.appendSlice(alloc, ". Proceed?") catch {};
        emit("{{\"t\":{d},\"ev\":\"await_human\",\"q\":\"{s}\"}}", .{ nowMs(), jclean(qb.items) });
        // ask blocks (its own -t timeout) until the dashboard answers
        const ans = exec(&.{ ask_bin, "-t", "600", qb.items, "Proceed", "Abort" }, .{}) ;
        if (ans) |r| {
            defer alloc.free(r.out);
            const a = std.mem.trim(u8, r.out, " \t\r\n");
            if (std.ascii.eqlIgnoreCase(a, "Abort")) {
                warn("team: run aborted by human at the plan checkpoint\n");
                emit("{{\"t\":{d},\"ev\":\"run_done\",\"spent\":1,\"remaining\":0,\"workers\":0,\"dur\":{d},\"aborted\":true}}", .{ nowMs(), nowMs() - run_started });
                return 0;
            }
        }
    }

    // 2. fan-out workers, in parallel — the whole point of a team is horizontal
    //    bandwidth. Split each affordable slice and spawn its worker without
    //    waiting; they run concurrently (process-level, never threads). Then
    //    wait all and collect. Conservation is unchanged: slices are carved
    //    up-front, RESERVE is kept for the critic + synthesis.
    var models: std.ArrayListUnmanaged(WorkerModel) = .empty;
    defer models.deinit(alloc);
    loadModels(io, &models); // ZISH_TEAM_MODELS → per-worker (hybrid local+hosted)

    const Spawn = struct { cpid: i32, out_path: []u8, sub: []const u8, idx: usize, t0: i64, tf: i64 };
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
        const wtmpl = loadPrompt(io, "worker");
        defer alloc.free(wtmpl);
        const wprompt = renderTemplate(wtmpl, &.{ .{ "lens", w_intro }, .{ "consult", btw }, .{ "caps", capline }, .{ "budget", budgetline }, .{ "context", ctx_block }, .{ "sub", sub } });
        defer alloc.free(wprompt);
        const out_path = std.fmt.allocPrint(alloc, "{s}/.zish/.team-{d}-w{d}.out", .{ home, pid, i }) catch continue;
        {
            const mc = jclean(intendedModel(io, modelFor(models.items, i)));
            defer alloc.free(mc);
            const sc = jclean(sub);
            defer alloc.free(sc);
            emit("{{\"t\":{d},\"ev\":\"worker_start\",\"i\":{d},\"model\":\"{s}\",\"sub\":\"{s}\"}}", .{ nowMs(), i, mc, sc });
        }
        const cpid = spawnAgentToFile(io, agent_bin, wprompt, out_path, modelFor(models.items, i)) orelse {
            alloc.free(out_path);
            appendFile(bb_path, "(worker spawn failed)\n");
            continue;
        };
        spawns.append(alloc, .{ .cpid = cpid, .out_path = out_path, .sub = sub, .idx = i, .t0 = nowMs(), .tf = 0 }) catch {
            reap(cpid);
            unlinkPath(out_path);
            alloc.free(out_path);
        };
    }

    // Phase B: reap workers as they finish (waitpid -1), stamping each true
    // finish time — so per-worker duration and the parallelism metric are real.
    {
        var reaped: usize = 0;
        while (reaped < spawns.items.len) : (reaped += 1) {
            const rpid = waitAny();
            if (rpid < 0) break;
            for (spawns.items) |*sp| if (sp.cpid == rpid) {
                sp.tf = nowMs();
                break;
            };
        }
    }

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
        const oesc = jesc(trimmed, 8000);
        defer alloc.free(oesc);
        var think: []u8 = undefined;
        var meta = Meta{ .pt = 0, .ct = 0 };
        var mpath: [4096]u8 = undefined;
        if (std.fmt.bufPrint(&mpath, "{s}.meta", .{s.out_path})) |mp| {
            meta = readMeta(mp, &think);
            unlinkPath(mp);
        } else |_| {
            think = alloc.dupe(u8, "") catch "";
        }
        defer alloc.free(think);
        const tesc = jesc(think, 6000);
        defer alloc.free(tesc);
        const wdur = if (s.tf > s.t0) s.tf - s.t0 else nowMs() - s.t0;
        // the model the agent actually ran (from its meta) — authoritative; falls
        // back to the intended model if the sidecar didn't report one.
        const amodel = if (meta.model.len > 0) meta.model else intendedModel(io, modelFor(models.items, s.idx));
        const mesc = jclean(amodel);
        defer alloc.free(mesc);
        emit("{{\"t\":{d},\"ev\":\"worker_done\",\"i\":{d},\"t0\":{d},\"dur\":{d},\"chars\":{d},\"pt\":{d},\"ct\":{d},\"model\":\"{s}\",\"think\":\"{s}\",\"out\":\"{s}\"}}", .{ nowMs(), s.idx, s.t0, wdur, trimmed.len, meta.pt, meta.ct, mesc, tesc, oesc });
        // a worker may consult an org expert (lateral info edge, org-funded)
        serviceBtwAsk(io, agent_bin, budget_bin, root_id, bb_path, experts.items, wout, s.idx);
        spawned += 1;
    }

    // 3. critic — mandatory. Runs on every path; a worker-only run is a bug. The
    //    spend is reserved, so it succeeds; even if accounting were exhausted we
    //    still run the critic (fail-open on the safety check), and the ledger
    //    can never go negative because `budget spend` fails closed.
    _ = budgetSpend(budget_bin, root_id, COST);
    emit("{{\"t\":{d},\"ev\":\"critic_start\"}}", .{nowMs()});
    const bb1 = readFileAlloc(bb_path, MAX_OUT) orelse alloc.dupe(u8, "") catch return 1;
    defer alloc.free(bb1);
    const crit_intro = lensIntro(lensFor(lenses.items, "critic", 0));
    defer alloc.free(crit_intro);
    const ctmpl = loadPrompt(io, "critic");
    defer alloc.free(ctmpl);
    const cprompt = renderTemplate(ctmpl, &.{ .{ "lens", crit_intro }, .{ "budget", budgetline }, .{ "blackboard", bb1 } });
    defer alloc.free(cprompt);
    var cmeta_buf: [4096]u8 = undefined;
    const cmp = std.fmt.bufPrint(&cmeta_buf, "{s}.crit.meta", .{bb_path}) catch "";
    const crit = callAgent(io, agent_bin, cprompt, cmp, capBase(io)) orelse alloc.dupe(u8, "(critic unavailable)") catch return 1;
    defer alloc.free(crit);
    const centry = std.fmt.allocPrint(alloc, "## critic\n{s}\n", .{std.mem.trim(u8, crit, " \t\r\n")}) catch return 1;
    defer alloc.free(centry);
    appendFile(bb_path, centry);
    {
        var cthink: []u8 = undefined;
        const ctok = readMeta(cmp, &cthink);
        defer alloc.free(cthink);
        unlinkPath(cmp);
        const cesc = jesc(std.mem.trim(u8, crit, " \t\r\n"), 8000);
        defer alloc.free(cesc);
        const ctesc = jesc(cthink, 6000);
        defer alloc.free(ctesc);
        emit("{{\"t\":{d},\"ev\":\"critic_done\",\"pt\":{d},\"ct\":{d},\"think\":\"{s}\",\"text\":\"{s}\"}}", .{ nowMs(), ctok.pt, ctok.ct, ctesc, cesc });
    }

    // 4. synthesis — the captain keeps only what survived the critic.
    _ = budgetSpend(budget_bin, root_id, COST);
    emit("{{\"t\":{d},\"ev\":\"synth_start\"}}", .{nowMs()});
    const bb2 = readFileAlloc(bb_path, MAX_OUT) orelse alloc.dupe(u8, "") catch return 1;
    defer alloc.free(bb2);
    // fold in any human replies sent mid-run (from the dashboard) as guidance
    const says = collectHumanSays();
    defer alloc.free(says);
    var human_block_buf: [8192]u8 = undefined;
    const human_block = if (says.len > 0)
        (std.fmt.bufPrint(&human_block_buf, " The human(s) sent guidance DURING the run — honor it over the workers where they conflict:\n{s}", .{says}) catch "")
    else
        "";
    const stmpl = loadPrompt(io, "synth");
    defer alloc.free(stmpl);
    const sprompt = renderTemplate(stmpl, &.{ .{ "lens", cap_intro }, .{ "caps", capline }, .{ "budget", sbudgetline }, .{ "human", human_block }, .{ "context", ctx_block }, .{ "blackboard", bb2 } });
    defer alloc.free(sprompt);
    var smeta_buf: [4096]u8 = undefined;
    const smp = std.fmt.bufPrint(&smeta_buf, "{s}.synth.meta", .{bb_path}) catch "";
    const final = callAgent(io, agent_bin, sprompt, smp, capSynth(io)) orelse {
        warn("team: synthesis call failed\n");
        return 1;
    };
    defer alloc.free(final);
    out(std.mem.trim(u8, final, " \t\r\n"));
    out("\n");
    {
        var sthink: []u8 = undefined;
        const stok = readMeta(smp, &sthink);
        defer alloc.free(sthink);
        unlinkPath(smp);
        const fesc = jesc(std.mem.trim(u8, final, " \t\r\n"), 12000);
        defer alloc.free(fesc);
        const stesc = jesc(sthink, 6000);
        defer alloc.free(stesc);
        const smodel = if (stok.model.len > 0) stok.model else intendedModel(io, modelFor(models.items, 0));
        const smesc = jclean(smodel);
        defer alloc.free(smesc);
        emit("{{\"t\":{d},\"ev\":\"synth_done\",\"pt\":{d},\"ct\":{d},\"model\":\"{s}\",\"think\":\"{s}\",\"text\":\"{s}\"}}", .{ nowMs(), stok.pt, stok.ct, smesc, stesc, fesc });
    }

    // 5. verify — the member that actually runs a compiler. Compile any code in
    //    the answer for real; repair once against the true error. Never ship
    //    untested code silently. No-op on a prose (no-code) answer.
    if (verify_bin.len > 0)
        verifyAndGate(io, agent_bin, budget_bin, verify_bin, root_id, bb_path, cap_intro, final);

    // stderr summary: make the conservation visible — how the root grant was
    // spent across the org (captain + workers + critic + synth).
    const final_bal = budgetBalance(budget_bin, root_id) orelse 0;
    var sb: [256]u8 = undefined;
    warn(std.fmt.bufPrint(&sb, "team: root {s} — budget {d}, spent {d}, remaining {d} ({d} workers)\n", .{ root_id, root_budget, root_budget - final_bal, final_bal, spawned }) catch "");
    emit("{{\"t\":{d},\"ev\":\"run_done\",\"spent\":{d},\"remaining\":{d},\"workers\":{d},\"dur\":{d}}}", .{ nowMs(), root_budget - final_bal, final_bal, spawned, nowMs() - run_started });
    return 0;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) u8 {
    // Full Init installs a no-op SIGPIPE handler; a filter must die on a closed
    // stdout like every other CLI, so restore the default before doing anything.
    feat.restoreSigpipe();
    // `std.process.Init` is the only io this feat has: everything that reads an
    // environment variable takes it as an argument. The environment block itself
    // is captured once — it is a kernel-provided constant, not a service with a
    // lifetime — because execve needs it verbatim to give each child its env.
    child_envp = @ptrCast(init.minimal.environ.block.slice.ptr);
    return run(init.io, init.minimal.args);
}

fn run(io: std.Io, args: std.process.Args) u8 {
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
    if (std.mem.eql(u8, verb, "prompts")) {
        // print the editable prompts as JSON {name, default, current} — the
        // single source of truth the dashboard reads (no duplicated defaults).
        printPrompts(io);
        return 0;
    }
    if (!std.mem.eql(u8, verb, "run")) {
        warn("team: unknown verb (expected 'run' or 'prompts')\n");
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

    // remaining args = the task (joined with spaces); `-c <file>` supplies a
    // conversation-context file (thread continuity), also via $ZISH_TEAM_CONTEXT.
    var ctx_path: ?[]const u8 = getEnv(io, "ZISH_TEAM_CONTEXT");
    var task: std.ArrayListUnmanaged(u8) = .empty;
    defer task.deinit(alloc);
    var first = true;
    while (it.next()) |w| {
        if (std.mem.eql(u8, w, "-c")) {
            ctx_path = it.next() orelse {
                warn("team: -c needs a file path\n");
                return 2;
            };
            continue;
        }
        if (!first) task.append(alloc, ' ') catch {};
        first = false;
        task.appendSlice(alloc, w) catch {};
    }
    if (task.items.len == 0) {
        warn("team: no task given\n");
        return 2;
    }
    const context: []const u8 = if (ctx_path) |p| (readFileAlloc(p, MAX_OUT) orelse "") else "";
    return teamRun(io, root_budget, task.items, context);
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
