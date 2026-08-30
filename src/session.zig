//! session.zig — host for **session feats** (feat.toml `kind = "session"`).
//!
//! A normal feat is a one-shot filter: fork+exec+argv+stdio, run to completion,
//! reap. A *session feat* is long-lived and speaks a terse newline-delimited
//! JSON frame protocol with zish over a pipe pair. This is the atom of the
//! agent-armor layer: the feat emits request frames, zish executes them through
//! its OWN executor (the same parse→eval→sandbox→fd-3 path everything else
//! uses), and writes result frames back. Single-threaded; a session feat's
//! stdio is pipes, never the terminal.
//!
//! Frame protocol v0.3 (one JSON object per line):
//!   zish → feat, once at session start
//!     {"t":"hello","proto":0,"caps":["say","stream","done",...]}
//!         the session's hostcall capability mask — the guest knows its world
//!         up front and degrades instead of probing by denial
//!   feat → zish
//!     {"t":"run","cmd":"<shell command>"}   execute via zish, capture stdout
//!     {"t":"say","text":"<text>"}           display a line to the human
//!     {"t":"stream","text":"<text>"}        append text (no implied newline)
//!     {"t":"prompt","text":"<question>"}    ask the human; answer arrives as an
//!                                           event frame (async: via the
//!                                           `session answer` builtin)
//!     {"t":"done"}                          end the session
//!   zish → feat
//!     {"t":"result","code":<int>,"out":"<captured stdout>"}   reply to "run"
//!         `code` is the command's REAL exit status (128+sig if signaled;
//!         255 if the status was reaped elsewhere, e.g. a user's bare `wait`)
//!     {"t":"event","kind":"submitted","text":"<answer>"}      reply to "prompt"
//!     {"t":"event","kind":"cancelled"}                        prompt not answerable
//!     {"t":"error","call":"<name>","reason":"denied"}         masked-off hostcall
//!     {"t":"error","call":"run","reason":"busy"}              a run is already in flight
//!     {"t":"error","call":"run","reason":"failed"}            tool child could not spawn
//!
//! `run` semantics (v0.3): the command executes in a FORKED subshell child —
//! same parser/evaluator/sandbox/fd-3 trace, but a snapshot: it sees the
//! shell's live state (cwd, vars, functions) at call time and its mutations do
//! not propagate back (plan #11's per-call snapshot, by construction). The
//! child runs in its own process group with NO terminal claim, stdin from
//! /dev/null, stdout captured to an unlinked temp file. In the async host the
//! child's pidfd joins the input poll set, so the prompt stays live while a
//! tool runs — Ctrl-C at the prompt edits the line and does NOT kill the
//! agent's tool child (deliberate: background work must not die to a
//! line-edit cancel; `session kill` is the kill switch). One run in flight
//! per session (the protocol is lockstep); a second gets reason "busy".
//!
//! Hostcall capability mask: ONE vocabulary, per-session mask (never tiered
//! tables). The mask bounds which CHANNELS the guest gets (execution, human
//! attention); the sandbox bounds what a granted `run` may TOUCH. Denials are
//! loud — a structured `error` frame plus a transcript line — and the mask is
//! a POLICY gate, not containment: a guest denied `run` still sits inside its
//! Landlock jail. v1 derivation: extra tier → {say,stream,done}; standard →
//! everything. Endgame: a parent agent spawning a child session hands it a
//! strictly narrower mask, so delegation narrows authority monotonically down
//! an agent-to-agent tree.
//!
//! Two hosting modes, one protocol:
//!   - **async** (interactive shell, stdout is the tty): `launchSession`
//!     registers the feat in the shell's session table and returns to the
//!     prompt immediately; frames are serviced from the line editor's input
//!     poll (Shell.readNextAction multiplexes {stdin} ∪ {session fds}).
//!     Feat text is sanitized, appended to a transcript file, and echoed above
//!     the live prompt. A `prompt` frame parks as a pending question answered
//!     with `session answer`.
//!   - **sync** (`zish -c`, scripts, command substitution — stdout not a tty):
//!     `hostSessionFeat` blocks servicing frames until done/EOF, as v0 did.
//!     A `prompt` frame is answered `cancelled` (nobody is there to ask).
//!
//! Hostile-input discipline (the feat is untrusted):
//!   - EVERY feat-supplied byte that reaches the terminal or the transcript
//!     passes through sanitize.writeSanitized — no raw ANSI/OSC, ever. Echoed
//!     lines carry a zish-drawn dim `[id:name]` provenance prefix the feat
//!     cannot forge (SGR is stripped from its text).
//!   - Frame lines are capped (MAX_FRAME); an oversized line ends the session.
//!   - Writes to the feat are bounded by a poll timeout; a feat that stops
//!     reading its stdin is killed, never waited on.
//!   - `run` children get stdin = /dev/null: an agent tool-call NEVER reads the
//!     user's terminal (plan #2: no terminal claim).
//!   - done/EOF is end-of-session by protocol: the child is reaped WNOHANG and
//!     SIGKILLed if still alive — no blocking waitpid on an untrusted child.
//!
//! KNOWN v1 LIMIT (named in AGENT_ARMOR_PLAN.md): servicing a `run` frame
//! executes the command synchronously inside the input loop; the prompt is
//! unresponsive until it returns. The fix is pidfd-pollable tool-children in
//! the poll set — the next slice, not optional hardening.
//!
//! v0.1 inherits zish's environment into the feat and applies no extra sandbox
//! narrowing — per-exec Landlock/seccomp and the secrets channel land with the
//! model loop.

const std = @import("std");
const Shell = @import("Shell.zig");
const compat = @import("compat.zig");
const expand = @import("expand.zig");
const eval = @import("eval.zig");
const jobs = @import("jobs.zig");
const sanitize = @import("sanitize.zig");

pub const MAX_SESSIONS = 8;
/// Hostile-input cap: one frame line. A feat sending more without a newline is
/// broken or malicious; the session ends.
const MAX_FRAME = 1 << 20;
/// How long a frame write to the feat may stall before the feat is presumed
/// wedged/hostile and the session is ended.
const WRITE_TIMEOUT_MS = 5000;
/// Cap on captured `run` output copied into the transcript (the transcript is
/// an audit log, not a data channel).
const TRANSCRIPT_RUN_CAP = 64 * 1024;
/// Cap on captured `run` output sent back in the result frame. A tool dumping
/// more than this gets a truncation marker inside `out`.
const RESULT_CAP = 8 * 1024 * 1024;

/// Which hostcalls a session may use. say/stream/done are always granted — a
/// guest that cannot even speak or exit cleanly has no useful failure mode.
/// A feat may effectively hold LESS by never emitting a call; it can never
/// hold more than its tier grants (narrowing composes, fail-closed).
pub const Caps = struct {
    run: bool,
    prompt: bool,

    pub fn forTier(untrusted: bool) Caps {
        return .{ .run = !untrusted, .prompt = !untrusted };
    }
};

const ERR_RUN_DENIED = "{\"t\":\"error\",\"call\":\"run\",\"reason\":\"denied\"}\n";
const ERR_PROMPT_DENIED = "{\"t\":\"error\",\"call\":\"prompt\",\"reason\":\"denied\"}\n";
const ERR_RUN_BUSY = "{\"t\":\"error\",\"call\":\"run\",\"reason\":\"busy\"}\n";
const ERR_RUN_FAILED = "{\"t\":\"error\",\"call\":\"run\",\"reason\":\"failed\"}\n";

/// One in-flight `run` command: a forked subshell child, awaited via its pidfd
/// in the input poll set (async) or a blocking waitpid (sync host).
pub const ToolChild = struct {
    pid: compat.posix.pid_t,
    pidfd: compat.posix.fd_t, // -1 if pidfd_open failed (completion still works via waitpid)
    cap_fd: compat.posix.fd_t, // unlinked temp file holding the child's stdout
};

/// One live async session.
pub const Session = struct {
    id: u32,
    name: []u8, // owned; display + transcript naming
    pid: compat.posix.pid_t,
    r: compat.posix.fd_t, // feat stdout → zish (O_NONBLOCK, CLOEXEC)
    w: compat.posix.fd_t, // zish → feat stdin (CLOEXEC)
    transcript_fd: compat.posix.fd_t,
    transcript_path: []u8, // owned
    caps: Caps,
    buf: std.ArrayListUnmanaged(u8) = .empty, // unparsed frame bytes
    echo: std.ArrayListUnmanaged(u8) = .empty, // sanitized text awaiting a full line
    pending_q: ?[]u8 = null, // sanitized question awaiting `session answer`
    tool: ?ToolChild = null, // the in-flight run, if any
};

// ---------------------------------------------------------------------------
// spawn — shared fork/exec for both hosting modes
// ---------------------------------------------------------------------------

const Spawned = struct { pid: compat.posix.pid_t, r: compat.posix.fd_t, w: compat.posix.fd_t };

fn spawn(shell: *Shell, bin_path: []const u8, args: []const []const u8, untrusted: bool) !Spawned {
    const alloc = shell.allocator;

    // to_feat: zish writes → feat's stdin.  from_feat: feat's stdout → zish reads.
    const to_feat = try compat.posix.pipe();
    const from_feat = try compat.posix.pipe();

    // null-terminated argv (argv0 = bin_path), like featExec.
    if (1 + args.len >= 250) return error.TooManyArgs;
    var argv: [250]?[*:0]const u8 = undefined;
    var held: std.ArrayList([:0]u8) = .empty;
    defer {
        for (held.items) |h| alloc.free(h);
        held.deinit(alloc);
    }
    const argv0 = try alloc.dupeZ(u8, bin_path);
    try held.append(alloc, argv0);
    argv[0] = argv0.ptr;
    var n: usize = 1;
    for (args) |a| {
        const dz = try alloc.dupeZ(u8, a);
        try held.append(alloc, dz);
        argv[n] = dz.ptr;
        n += 1;
    }
    argv[n] = null;
    const argv_ptr: [*:null]const ?[*:0]const u8 = argv[0..n :null];
    // Untrusted (extra-tier) session feats cross a trust boundary: no shell
    // environment leaks into them, same rule featExec applies to one-shots.
    const envp: [*:null]const ?[*:0]const u8 = if (untrusted)
        strippedEnv(alloc) orelse return error.ForkFailed
    else
        @ptrCast(std.c.environ);

    shell.stdout().flush() catch {};

    const pid = compat.posix.fork() catch {
        closePair(to_feat);
        closePair(from_feat);
        return error.ForkFailed;
    };
    if (pid == 0) {
        // child: wire stdin ← to_feat[0], stdout → from_feat[1], drop all pipe fds.
        compat.posix.dup2(to_feat[0], compat.posix.STDIN_FILENO) catch compat.posix.exit(127);
        compat.posix.dup2(from_feat[1], compat.posix.STDOUT_FILENO) catch compat.posix.exit(127);
        closePair(to_feat);
        closePair(from_feat);
        compat.posix.execveZ(argv0.ptr, argv_ptr, envp) catch {};
        compat.posix.exit(127);
    }

    // parent: close the child's ends; CLOEXEC ours so no later child (feat
    // tool-runs included) inherits a handle on the session pipes — a tool
    // child holding `w` could forge frames into its own session.
    compat.posix.close(to_feat[0]);
    compat.posix.close(from_feat[1]);
    setCloexec(to_feat[1]);
    setCloexec(from_feat[0]);
    return .{ .pid = pid, .r = from_feat[0], .w = to_feat[1] };
}

/// Minimal envp for untrusted `extra` session feats: HOME + a shrunk PATH,
/// nothing else crosses the boundary. Allocations are process-lifetime — they
/// must survive fork and stay valid until exec in the child.
fn strippedEnv(alloc: std.mem.Allocator) ?[*:null]const ?[*:0]const u8 {
    const home = compat.getEnvVarOwned(alloc, "HOME") catch return null;
    const home_s = std.fmt.allocPrint(alloc, "HOME={s}", .{home}) catch return null;
    const home_env = alloc.dupeZ(u8, home_s) catch return null;
    const path_env = alloc.dupeZ(u8, "PATH=/usr/local/bin:/usr/bin:/bin") catch return null;
    const envp = alloc.alloc(?[*:0]const u8, 3) catch return null;
    envp[0] = home_env.ptr;
    envp[1] = path_env.ptr;
    envp[2] = null;
    return @ptrCast(envp.ptr);
}

/// Announce the session's world to the guest: protocol version + granted
/// hostcalls, first frame on its stdin. Returns false if the write failed.
fn sendHello(w: compat.posix.fd_t, caps: Caps) bool {
    var buf: [160]u8 = undefined;
    var fbs: std.Io.Writer = .fixed(&buf);
    fbs.writeAll("{\"t\":\"hello\",\"proto\":0,\"caps\":[\"say\",\"stream\",\"done\"") catch return false;
    if (caps.run) fbs.writeAll(",\"run\"") catch return false;
    if (caps.prompt) fbs.writeAll(",\"prompt\"") catch return false;
    fbs.writeAll("]}\n") catch return false;
    return writeFrame(w, fbs.buffered());
}

fn closePair(p: [2]compat.posix.fd_t) void {
    compat.posix.close(p[0]);
    compat.posix.close(p[1]);
}

fn setCloexec(fd: compat.posix.fd_t) void {
    _ = compat.posix.fcntl(fd, 2, 1) catch {}; // F_SETFD, FD_CLOEXEC
}

fn setNonblock(fd: compat.posix.fd_t) void {
    const F_GETFL = 3;
    const F_SETFL = 4;
    const flags = compat.posix.fcntl(fd, F_GETFL, 0) catch return;
    const nb: usize = @as(u32, @bitCast(compat.posix.O{ .NONBLOCK = true }));
    _ = compat.posix.fcntl(fd, F_SETFL, flags | nb) catch {};
}

// ---------------------------------------------------------------------------
// sync host — blocking loop (non-interactive contexts)
// ---------------------------------------------------------------------------

/// Fork+exec `bin_path` and service its frames until {"t":"done"} or EOF.
/// Blocks; used when there is no interactive input loop to poll from.
pub fn hostSessionFeat(shell: *Shell, bin_path: []const u8, args: []const []const u8, untrusted: bool) !u8 {
    const alloc = shell.allocator;
    const caps = Caps.forTier(untrusted);
    const sp = spawn(shell, bin_path, args, untrusted) catch {
        try shell.stdout().print("zish: session spawn failed\n", .{});
        return 1;
    };
    defer compat.posix.close(sp.w);
    defer compat.posix.close(sp.r);
    if (!sendHello(sp.w, caps)) {
        reapSessionChild(sp.pid);
        return 1;
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    var tmp: [4096]u8 = undefined;

    outer: while (true) {
        while (std.mem.indexOfScalar(u8, buf.items, '\n') == null) {
            const got = compat.posix.read(sp.r, &tmp) catch break :outer;
            if (got == 0) break :outer; // feat closed stdout
            try buf.appendSlice(alloc, tmp[0..got]);
            if (buf.items.len > MAX_FRAME) break :outer; // hostile: oversized frame
        }
        while (std.mem.indexOfScalar(u8, buf.items, '\n')) |nl| {
            const line = buf.items[0..nl];
            const stop = handleSyncFrame(shell, line, sp.w, caps) catch false;
            const rest = buf.items[nl + 1 ..];
            std.mem.copyForwards(u8, buf.items, rest);
            buf.items.len = rest.len;
            if (stop) break :outer;
        }
    }

    reapSessionChild(sp.pid);
    return 0;
}

/// Dispatch one frame in sync mode. Returns true when the session should end.
fn handleSyncFrame(shell: *Shell, line: []const u8, w: compat.posix.fd_t, caps: Caps) !bool {
    const alloc = shell.allocator;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch return false;
    defer parsed.deinit();
    const t = frameType(parsed.value) orelse return false;

    if (std.mem.eql(u8, t, "done")) return true;

    if (std.mem.eql(u8, t, "say") or std.mem.eql(u8, t, "stream")) {
        const text = frameStr(parsed.value, "text");
        try sanitize.writeSanitized(shell.stdout(), text);
        if (t[1] == 'a') try shell.stdout().writeAll("\n"); // say implies newline
        shell.stdout().flush() catch {};
        return false;
    }

    if (std.mem.eql(u8, t, "prompt")) {
        if (!caps.prompt) return !writeFrame(w, ERR_PROMPT_DENIED);
        // Nobody to ask in sync mode: refuse, don't hang the script.
        return !writeFrame(w, "{\"t\":\"event\",\"kind\":\"cancelled\"}\n");
    }

    if (std.mem.eql(u8, t, "run")) {
        if (!caps.run) return !writeFrame(w, ERR_RUN_DENIED);
        // Same fork-isolated execution as the async host, waited for in place
        // (blocking is the sync host's whole nature).
        const tool = spawnToolChild(shell, frameStr(parsed.value, "cmd")) catch
            return !writeFrame(w, ERR_RUN_FAILED);
        const r = completeTool(shell, tool);
        defer alloc.free(r.out);
        return !replyResult(shell, w, r.code, r.out);
    }

    return false; // unknown frame type: ignore (forward-compat)
}

// ---------------------------------------------------------------------------
// async host — session table serviced from the input poll
// ---------------------------------------------------------------------------

/// Start `bin_path` as a background session and return to the caller
/// immediately; frames are serviced from Shell.readNextAction's poll.
pub fn launchSession(shell: *Shell, name: []const u8, bin_path: []const u8, args: []const []const u8, untrusted: bool) !u8 {
    const alloc = shell.allocator;
    if (shell.sessions.items.len >= MAX_SESSIONS) {
        try shell.stdout().print("zish: session limit ({d}) reached\n", .{MAX_SESSIONS});
        return 1;
    }
    const caps = Caps.forTier(untrusted);
    const sp = spawn(shell, bin_path, args, untrusted) catch {
        try shell.stdout().print("zish: session spawn failed\n", .{});
        return 1;
    };
    setNonblock(sp.r);
    if (!sendHello(sp.w, caps)) {
        compat.posix.close(sp.w);
        compat.posix.close(sp.r);
        reapSessionChild(sp.pid);
        try shell.stdout().print("zish: session hello failed\n", .{});
        return 1;
    }

    const id = shell.next_session_id;
    shell.next_session_id += 1;

    const tr: Transcript = openTranscript(shell, id, name) catch .{ .fd = -1, .path = try alloc.dupe(u8, "(none)") };

    try shell.sessions.append(alloc, .{
        .id = id,
        .name = try alloc.dupe(u8, name),
        .pid = sp.pid,
        .r = sp.r,
        .w = sp.w,
        .transcript_fd = tr.fd,
        .transcript_path = tr.path,
        .caps = caps,
    });

    writeMeta(shell, &shell.sessions.items[shell.sessions.items.len - 1]);
    try shell.stdout().print("[sess {d}:{s}] started \xc2\xb7 transcript {s}\n", .{ id, name, tr.path });
    shell.stdout().flush() catch {};
    return 0;
}

const Transcript = struct { fd: compat.posix.fd_t, path: []u8 };

/// Fill `buf` with ~/.zish/sessions, creating ~/.zish and ~/.zish/sessions if
/// absent (a fresh HOME has neither; EEXIST is fine). Returns the dir path.
/// This directory is the file-based org registry: transcripts, per-session
/// `.meta` records, and control FIFOs all live here.
pub fn sessionsDir(alloc: std.mem.Allocator, buf: []u8) ![]const u8 {
    const home = compat.getEnvVarOwned(alloc, "HOME") catch return error.NoHome;
    defer alloc.free(home);
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const parent = try std.fmt.bufPrintZ(&pbuf, "{s}/.zish", .{home});
    _ = std.c.mkdir(parent.ptr, 0o700);
    const dir = try std.fmt.bufPrint(buf, "{s}/.zish/sessions", .{home});
    var dz: [std.fs.max_path_bytes]u8 = undefined;
    const dirz = try std.fmt.bufPrintZ(&dz, "{s}", .{dir});
    _ = std.c.mkdir(dirz.ptr, 0o700);
    return dir;
}

/// Session identity is namespaced by hosting-shell pid so concurrent shells
/// never collide: the meta/ctl/transcript basename is <hostpid>-<id>.
fn metaPath(alloc: std.mem.Allocator, id: u32) ?[]u8 {
    var dbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = sessionsDir(alloc, &dbuf) catch return null;
    return std.fmt.allocPrint(alloc, "{s}/{d}-{d}.meta", .{ dir, std.c.getpid(), id }) catch null;
}

/// The org registry record for one session: a single-line JSON file any
/// process can read (`session list` scans the dir). Rewritten on every state
/// change, removed on finish. State is derived from tool/pending fields.
fn writeMeta(shell: *Shell, s: *const Session) void {
    const alloc = shell.allocator;
    const path = metaPath(alloc, s.id) orelse return;
    defer alloc.free(path);
    const state: []const u8 = if (s.pending_q != null) "awaiting" else if (s.tool != null) "tool" else "running";

    var b: std.ArrayListUnmanaged(u8) = .empty;
    defer b.deinit(alloc);
    b.appendSlice(alloc, "{\"id\":") catch return;
    var nb: [16]u8 = undefined;
    b.appendSlice(alloc, std.fmt.bufPrint(&nb, "{d}", .{s.id}) catch return) catch return;
    b.appendSlice(alloc, ",\"host\":") catch return;
    b.appendSlice(alloc, std.fmt.bufPrint(&nb, "{d}", .{std.c.getpid()}) catch return) catch return;
    b.appendSlice(alloc, ",\"name\":\"") catch return;
    appendJsonEscaped(&b, alloc, s.name) catch return;
    b.appendSlice(alloc, "\",\"state\":\"") catch return;
    b.appendSlice(alloc, state) catch return;
    b.appendSlice(alloc, "\",\"transcript\":\"") catch return;
    appendJsonEscaped(&b, alloc, s.transcript_path) catch return;
    b.appendSlice(alloc, "\",\"q\":\"") catch return;
    if (s.pending_q) |q| appendJsonEscaped(&b, alloc, q) catch return;
    b.appendSlice(alloc, "\"}\n") catch return;

    var pz: [std.fs.max_path_bytes]u8 = undefined;
    const pathz = std.fmt.bufPrintZ(&pz, "{s}", .{path}) catch return;
    const fd = compat.posix.openZ(pathz.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600) catch return;
    defer compat.posix.close(fd);
    writeAllFd(fd, b.items);
}

fn removeMeta(shell: *Shell, id: u32) void {
    const alloc = shell.allocator;
    const path = metaPath(alloc, id) orelse return;
    defer alloc.free(path);
    var pz: [std.fs.max_path_bytes]u8 = undefined;
    const pathz = std.fmt.bufPrintZ(&pz, "{s}", .{path}) catch return;
    std.Io.Dir.deleteFileAbsolute(compat.io(), pathz) catch {};
}

/// Transcripts live flat under ~/.zish/sessions/, named
/// <shellpid>-<id>-<name>.log so concurrent shells never collide. Everything
/// written to one is already sanitized: `cat transcript` is terminal-safe.
fn openTranscript(shell: *Shell, id: u32, name: []const u8) !Transcript {
    const alloc = shell.allocator;
    var dbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try sessionsDir(alloc, &dbuf);

    var safe: [32]u8 = undefined;
    const nlen = @min(name.len, safe.len);
    for (name[0..nlen], 0..) |c, i| {
        safe[i] = if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') c else '_';
    }

    const path = try std.fmt.allocPrint(alloc, "{s}/{d}-{d}-{s}.log", .{ dir, std.c.getpid(), id, safe[0..nlen] });
    errdefer alloc.free(path);
    var zbuf: [std.fs.max_path_bytes]u8 = undefined;
    const pathz = try std.fmt.bufPrintZ(&zbuf, "{s}", .{path});
    const fd = try compat.posix.openZ(pathz.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o600);

    var hdr: [160]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "# zish session {d} \xc2\xb7 feat {s} \xc2\xb7 t={d}\n", .{ id, safe[0..nlen], compat.timestamp() }) catch "";
    writeAllFd(fd, h);
    return .{ .fd = fd, .path = path };
}

/// A session fd (or its HUP) came up readable in the input poll: drain it and
/// process complete frames. Ends the session on EOF, error, done, an oversized
/// frame, or a stalled write.
pub fn serviceByFd(shell: *Shell, fd: compat.posix.fd_t) void {
    const idx = findByFd(shell, fd) orelse return;
    const alloc = shell.allocator;
    var ended = false;

    {
        const s = &shell.sessions.items[idx];
        var tmp: [4096]u8 = undefined;
        while (true) {
            const got = compat.posix.read(s.r, &tmp) catch |err| {
                if (err == error.WouldBlock) break;
                ended = true;
                break;
            };
            if (got == 0) {
                ended = true;
                break;
            }
            s.buf.appendSlice(alloc, tmp[0..got]) catch {
                ended = true;
                break;
            };
            if (s.buf.items.len > MAX_FRAME) {
                ended = true; // hostile: oversized frame line
                break;
            }
        }
        while (std.mem.indexOfScalar(u8, s.buf.items, '\n')) |nl| {
            const line = s.buf.items[0..nl];
            const stop = handleAsyncFrame(shell, s, line) catch false;
            const rest = s.buf.items[nl + 1 ..];
            std.mem.copyForwards(u8, s.buf.items, rest);
            s.buf.items.len = rest.len;
            if (stop) {
                ended = true;
                break;
            }
        }
    }

    if (ended) finishSession(shell, idx);
}

/// Dispatch one frame in async mode. Returns true when the session should end.
fn handleAsyncFrame(shell: *Shell, s: *Session, line: []const u8) !bool {
    const alloc = shell.allocator;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch return false;
    defer parsed.deinit();
    const t = frameType(parsed.value) orelse return false;

    if (std.mem.eql(u8, t, "done")) return true;

    if (std.mem.eql(u8, t, "say") or std.mem.eql(u8, t, "stream")) {
        const text = frameStr(parsed.value, "text");
        var clean: std.ArrayListUnmanaged(u8) = .empty;
        defer clean.deinit(alloc);
        try sanitize.writeSanitized(listWriter(&clean, alloc), text);
        if (t[1] == 'a') try clean.append(alloc, '\n'); // say implies newline
        writeAllFd(s.transcript_fd, clean.items);
        try s.echo.appendSlice(alloc, clean.items);
        echoCompleteLines(shell, s);
        return false;
    }

    if (std.mem.eql(u8, t, "prompt")) {
        if (!s.caps.prompt) return denyHostcall(shell, s, "prompt", ERR_PROMPT_DENIED);
        var clean: std.ArrayListUnmanaged(u8) = .empty;
        errdefer clean.deinit(alloc);
        try sanitize.writeSanitized(listWriter(&clean, alloc), frameStr(parsed.value, "text"));
        // single line: a question that needs layout can use say first
        if (std.mem.indexOfScalar(u8, clean.items, '\n')) |p| clean.items.len = p;

        writeAllFd(s.transcript_fd, "? ");
        writeAllFd(s.transcript_fd, clean.items);
        writeAllFd(s.transcript_fd, "\n");

        if (s.pending_q) |old| alloc.free(old);
        const q = try clean.toOwnedSlice(alloc);
        s.pending_q = q;

        writeMeta(shell, s); // state → awaiting; visible to `session list` cross-process
        var note = beginAbovePrompt(shell);
        note.print("\x1b[2m[sess {d}:{s}]\x1b[0m asks: {s}\n        \x1b[2mreply:\x1b[0m session answer {d} <text>\n", .{ s.id, s.name, q, s.id }) catch {};
        endAbovePrompt(shell);
        return false;
    }

    if (std.mem.eql(u8, t, "run")) {
        if (!s.caps.run) return denyHostcall(shell, s, "run", ERR_RUN_DENIED);
        if (s.tool != null) {
            // lockstep protocol: one run in flight per session
            writeAllFd(s.transcript_fd, "! run refused: tool already in flight\n");
            return !writeFrame(s.w, ERR_RUN_BUSY);
        }
        const cmd = frameStr(parsed.value, "cmd");

        // Audit trail BEFORE execution, so a tool killed mid-run still left
        // its line. The command string is model-composed text — sanitize it.
        writeAllFd(s.transcript_fd, "$ ");
        var cmdclean: std.ArrayListUnmanaged(u8) = .empty;
        defer cmdclean.deinit(alloc);
        try sanitize.writeSanitized(listWriter(&cmdclean, alloc), cmd);
        writeAllFd(s.transcript_fd, cmdclean.items);
        writeAllFd(s.transcript_fd, "\n");

        // Spawn and park: the reply is sent by finishTool when the child's
        // pidfd fires in the input poll — the prompt stays live meanwhile.
        s.tool = spawnToolChild(shell, cmd) catch
            return !writeFrame(s.w, ERR_RUN_FAILED);
        writeMeta(shell, s); // state → tool
        return false;
    }

    return false; // unknown frame type: ignore (forward-compat)
}

/// A masked-off hostcall: attest it in the transcript, show it to the human,
/// send the structured error frame back — never a silent drop. Returns true
/// (end session) only if the error reply itself failed to write.
fn denyHostcall(shell: *Shell, s: *Session, call: []const u8, err_frame: []const u8) bool {
    writeAllFd(s.transcript_fd, "! hostcall denied: ");
    writeAllFd(s.transcript_fd, call);
    writeAllFd(s.transcript_fd, "\n");
    var note = beginAbovePrompt(shell);
    note.print("\x1b[2m[sess {d}:{s}] hostcall denied: {s}\x1b[0m\n", .{ s.id, s.name, call }) catch {};
    endAbovePrompt(shell);
    return !writeFrame(s.w, err_frame);
}

/// Fork a subshell child that evaluates `cmd` through zish's own executor
/// (plan #2's tool-call execution context: no terminal claim, captured stdout,
/// stdin from /dev/null, own process group, state-isolated by the fork).
/// The parent gets a ToolChild to await — pollable via pidfd or blocking.
fn spawnToolChild(shell: *Shell, cmd: []const u8) !ToolChild {
    const cap_fd = try expand.createCaptureFile();
    errdefer compat.posix.close(cap_fd);

    // The evaluator may reference `cmd`, which can point into the session's
    // frame buffer — but the child's copy of that memory is stable (fork).
    shell.stdout().flush() catch {};
    const pid = try compat.posix.fork();
    if (pid == 0) {
        // === CHILD === (mirrors evaluateBackground's child, minus job table)
        var child_arena = eval.forkChildArena();
        shell.allocator = child_arena.allocator();
        // own process group + default signals, NO terminal handover
        jobs.launchProcess(0, 0, false, compat.posix.STDIN_FILENO);
        // Close every session's fds: they are CLOEXEC, but a builtin-only
        // command never execs, and a lingering copy of a pipe write end would
        // keep a finished session's feat alive on a phantom stdin.
        for (shell.sessions.items) |*os| {
            compat.posix.close(os.r);
            compat.posix.close(os.w);
            if (os.transcript_fd >= 0) compat.posix.close(os.transcript_fd);
            if (os.tool) |ot| {
                if (ot.pidfd >= 0) compat.posix.close(ot.pidfd);
                compat.posix.close(ot.cap_fd);
            }
        }
        // stdio: /dev/null in (never the user's terminal), capture out
        const devnull = compat.posix.openZ("/dev/null", .{ .ACCMODE = .RDONLY }, 0) catch compat.posix.exit(127);
        compat.posix.dup2(devnull, compat.posix.STDIN_FILENO) catch compat.posix.exit(127);
        compat.posix.close(devnull);
        compat.posix.dup2(cap_fd, compat.posix.STDOUT_FILENO) catch compat.posix.exit(127);
        compat.posix.close(cap_fd);
        shell.forked_child = true;
        const status = shell.executeCommandInternal(cmd) catch 127;
        shell.stdout().flush() catch {};
        compat.posix.exit(status);
    }

    // === PARENT ===
    return .{ .pid = pid, .pidfd = pidfdOpen(pid), .cap_fd = cap_fd };
}

fn pidfdOpen(pid: compat.posix.pid_t) compat.posix.fd_t {
    // pidfd_open fds are CLOEXEC by default. Verified: the seccomp denylist
    // blocks only pidfd_getfd, not pidfd_open.
    const rc = std.os.linux.pidfd_open(pid, 0);
    const signed: isize = @bitCast(rc);
    if (signed < 0) return -1; // completion degrades to blocking waitpid
    return @intCast(rc);
}

const ToolResult = struct { code: u8, out: []u8 };

/// Reap the tool child and read its captured output; closes the tool's fds.
/// In the async path the pidfd has already signalled exit, so the waitpid
/// returns immediately; the sync host blocks here on purpose.
fn completeTool(shell: *Shell, t: ToolChild) ToolResult {
    const alloc = shell.allocator;
    const res = compat.posix.waitpid(t.pid, 0);
    // res.pid == -1 (ECHILD): status was reaped elsewhere — e.g. the user ran
    // bare `wait`, whose waitpid(-1) collects every child. The pidfd already
    // told us it is dead; only the status is lost. Never block retrying.
    const code: u8 = if (res.pid == t.pid) decodeWaitStatus(res.status) else 255;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    _ = compat.posix.lseek(t.cap_fd, 0, 0) catch {};
    var tmp: [4096]u8 = undefined;
    while (out.items.len < RESULT_CAP) {
        const n = compat.posix.read(t.cap_fd, &tmp) catch break;
        if (n == 0) break;
        const room = RESULT_CAP - out.items.len;
        out.appendSlice(alloc, tmp[0..@min(n, room)]) catch break;
        if (n > room) {
            out.appendSlice(alloc, "\n[output truncated]") catch {};
            break;
        }
    }
    compat.posix.close(t.cap_fd);
    if (t.pidfd >= 0) compat.posix.close(t.pidfd);
    return .{ .code = code, .out = out.toOwnedSlice(alloc) catch &.{} };
}

fn decodeWaitStatus(status: u32) u8 {
    if ((status & 0x7f) == 0) return @truncate((status >> 8) & 0xff); // exited
    return @truncate(128 + (status & 0x7f)); // killed by signal, shell convention
}

/// Reply a captured `run` result with the child's real exit code. Returns
/// false if the write failed (stalled or dead feat) — caller ends the session.
fn replyResult(shell: *Shell, w: compat.posix.fd_t, code: u8, out: []const u8) bool {
    const alloc = shell.allocator;
    var frame: std.ArrayListUnmanaged(u8) = .empty;
    defer frame.deinit(alloc);
    var hdr: [48]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "{{\"t\":\"result\",\"code\":{d},\"out\":\"", .{code}) catch return false;
    frame.appendSlice(alloc, h) catch return false;
    appendJsonEscaped(&frame, alloc, out) catch return false;
    frame.appendSlice(alloc, "\"}\n") catch return false;
    return writeFrame(w, frame.items);
}

/// A session's tool-child pidfd fired: reap it, audit the output, send the
/// result frame the feat has been waiting on.
fn finishTool(shell: *Shell, idx: usize) void {
    const alloc = shell.allocator;
    const s = &shell.sessions.items[idx];
    const t = s.tool orelse return;
    s.tool = null;

    const r = completeTool(shell, t);
    defer alloc.free(r.out);

    // audit trail: sanitized, capped output + the real exit code
    var outclean: std.ArrayListUnmanaged(u8) = .empty;
    defer outclean.deinit(alloc);
    const capped = r.out[0..@min(r.out.len, TRANSCRIPT_RUN_CAP)];
    sanitize.writeSanitized(listWriter(&outclean, alloc), capped) catch {};
    writeAllFd(s.transcript_fd, outclean.items);
    if (r.out.len > capped.len) writeAllFd(s.transcript_fd, "\n[transcript: output truncated]");
    if (outclean.items.len == 0 or outclean.items[outclean.items.len - 1] != '\n')
        writeAllFd(s.transcript_fd, "\n");
    if (r.code != 0) {
        var cb: [24]u8 = undefined;
        const cl = std.fmt.bufPrint(&cb, "[exit {d}]\n", .{r.code}) catch "";
        writeAllFd(s.transcript_fd, cl);
    }

    if (!replyResult(shell, s.w, r.code, r.out)) {
        finishSession(shell, idx);
    } else {
        writeMeta(shell, s); // state → running (tool cleared)
    }
}

/// Dispatch a ready fd from the input poll: a session's pipe or a tool
/// child's pidfd.
pub fn serviceFd(shell: *Shell, fd: compat.posix.fd_t) void {
    if (findByFd(shell, fd) != null) return serviceByFd(shell, fd);
    for (shell.sessions.items, 0..) |*s, i| {
        if (s.tool) |t| {
            if (t.pidfd == fd) return finishTool(shell, i);
        }
    }
}

/// Print the file-based org registry: every `.meta` under ~/.zish/sessions,
/// across all hosting shells (this is what makes `session list` work from a
/// separate process — a Claude Code / IRC front-end reads the same records).
/// A record whose host process is gone is shown as `[stale]` and its file is
/// swept, so a crashed shell leaves no permanent ghost.
pub fn listRegistry(shell: *Shell) !void {
    const alloc = shell.allocator;
    const out = shell.stdout();
    var dbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = sessionsDir(alloc, &dbuf) catch {
        try out.writeAll("session: no registry\n");
        return;
    };
    var dir = std.Io.Dir.cwd().openDir(compat.io(), dir_path, .{ .iterate = true }) catch {
        try out.writeAll("session: none active\n");
        return;
    };
    defer dir.close(compat.io());

    var found = false;
    var iter = dir.iterate();
    while (try iter.next(compat.io())) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".meta")) continue;
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const full = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        const content = std.Io.Dir.cwd().readFileAlloc(compat.io(), full, alloc, .limited(64 * 1024)) catch continue;
        defer alloc.free(content);
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, content, .{}) catch continue;
        defer parsed.deinit();

        const host: i64 = objInt(parsed.value, "host") orelse 0;
        const id: i64 = objInt(parsed.value, "id") orelse 0;
        const name = objStr(parsed.value, "name") orelse "?";
        const state = objStr(parsed.value, "state") orelse "?";
        const transcript = objStr(parsed.value, "transcript") orelse "";
        const q = objStr(parsed.value, "q") orelse "";

        // liveness: kill(host, 0) — 0 or EPERM = exists, ESRCH = gone.
        const alive = host > 0 and hostAlive(@intCast(host));
        if (!alive) {
            std.Io.Dir.deleteFileAbsolute(compat.io(), full) catch {};
            try out.print("[{d}] {s}  [stale host {d}, swept]\n", .{ id, name, host });
            found = true;
            continue;
        }
        try out.print("[{d}] {s}  {s}  host={d}  {s}\n", .{ id, name, state, host, transcript });
        if (q.len > 0) try out.print("    ? {s}\n", .{q});
        found = true;
    }
    if (!found) try out.writeAll("session: none active\n");
}

fn objInt(v: std.json.Value, key: []const u8) ?i64 {
    const o = switch (v) {
        .object => |ob| ob,
        else => return null,
    };
    return switch (o.get(key) orelse return null) {
        .integer => |iv| iv,
        else => null,
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

fn hostAlive(host: compat.posix.pid_t) bool {
    // signal 0 probes existence: ok/EPERM = alive, ESRCH = gone.
    if (std.c.kill(host, @enumFromInt(0)) == 0) return true;
    return std.c._errno().* == @intFromEnum(std.c.E.PERM); // exists, not ours
}

/// Answer a session's pending question (the `session answer` builtin).
pub fn answerSession(shell: *Shell, id: u32, text: []const u8) !u8 {
    const idx = findById(shell, id) orelse {
        try shell.stderr().print("session: no session {d}\n", .{id});
        return 1;
    };
    const s = &shell.sessions.items[idx];
    if (s.pending_q == null) {
        try shell.stderr().print("session: {d} has no pending question\n", .{id});
        return 1;
    }
    const alloc = shell.allocator;
    var frame: std.ArrayListUnmanaged(u8) = .empty;
    defer frame.deinit(alloc);
    try frame.appendSlice(alloc, "{\"t\":\"event\",\"kind\":\"submitted\",\"text\":\"");
    try appendJsonEscaped(&frame, alloc, text);
    try frame.appendSlice(alloc, "\"}\n");

    writeAllFd(s.transcript_fd, "> ");
    var clean: std.ArrayListUnmanaged(u8) = .empty;
    defer clean.deinit(alloc);
    try sanitize.writeSanitized(listWriter(&clean, alloc), text);
    writeAllFd(s.transcript_fd, clean.items);
    writeAllFd(s.transcript_fd, "\n");

    alloc.free(s.pending_q.?);
    s.pending_q = null;

    if (!writeFrame(s.w, frame.items)) {
        finishSession(shell, idx);
        return 1;
    }
    writeMeta(shell, s); // state → running (question answered)
    return 0;
}

/// End the session at `idx`: close fds, reap without ever blocking on an
/// untrusted child (WNOHANG, then SIGKILL), close the transcript, notify.
pub fn finishSession(shell: *Shell, idx: usize) void {
    const alloc = shell.allocator;
    var s = shell.sessions.orderedRemove(idx);
    removeMeta(shell, s.id); // drop the registry record

    // flush any partial echoed line so the terminal isn't left mid-line
    if (s.echo.items.len > 0) {
        s.echo.append(alloc, '\n') catch {};
        echoCompleteLines(shell, &s);
    }

    // A tool still in flight dies with its session: the child leads its own
    // process group, so the whole tree goes.
    if (s.tool) |t| {
        s.tool = null;
        _ = compat.posix.kill(-t.pid, compat.posix.SIG.KILL) catch {};
        const r = completeTool(shell, t); // reap + close fds
        alloc.free(r.out);
        writeAllFd(s.transcript_fd, "! tool killed with session\n");
    }

    compat.posix.close(s.w);
    compat.posix.close(s.r);
    reapSessionChild(s.pid);
    if (s.transcript_fd >= 0) {
        writeAllFd(s.transcript_fd, "# session ended\n");
        compat.posix.close(s.transcript_fd);
    }

    if (shell.running) {
        var note = beginAbovePrompt(shell);
        note.print("\x1b[2m[sess {d}:{s}] ended \xc2\xb7 transcript {s}\x1b[0m\n", .{ s.id, s.name, s.transcript_path }) catch {};
        endAbovePrompt(shell);
    }

    alloc.free(s.name);
    alloc.free(s.transcript_path);
    s.buf.deinit(alloc);
    s.echo.deinit(alloc);
    if (s.pending_q) |q| alloc.free(q);
}

/// Kill and reap every live session (shell exit / deinit). Fail-closed: an
/// exiting shell leaves no orphaned agent running unattended.
pub fn shutdownAll(shell: *Shell) void {
    while (shell.sessions.items.len > 0) {
        const s = &shell.sessions.items[0];
        _ = compat.posix.kill(s.pid, compat.posix.SIG.KILL) catch {};
        finishSession(shell, 0);
    }
}

fn reapSessionChild(pid: compat.posix.pid_t) void {
    // done/EOF is end-of-session by protocol: a child that lingers after it is
    // wedged or hostile. Never block the interactive loop waiting for it.
    const res = compat.posix.waitpid(pid, std.posix.W.NOHANG);
    if (res.pid == pid or res.pid == -1) return; // reaped (or nothing to reap)
    _ = compat.posix.kill(pid, compat.posix.SIG.KILL) catch {};
    _ = compat.posix.waitpid(pid, 0); // SIGKILL is unblockable; returns promptly
}

pub fn findByFd(shell: *Shell, fd: compat.posix.fd_t) ?usize {
    for (shell.sessions.items, 0..) |*s, i| {
        if (s.r == fd) return i;
    }
    return null;
}

pub fn findById(shell: *Shell, id: u32) ?usize {
    for (shell.sessions.items, 0..) |*s, i| {
        if (s.id == id) return i;
    }
    return null;
}

// ---------------------------------------------------------------------------
// rendering above the live prompt
// ---------------------------------------------------------------------------

/// Erase the editor's rendered region and position the cursor at its start so
/// arbitrary full lines can be printed; pair with endAbovePrompt.
fn beginAbovePrompt(shell: *Shell) *std.Io.Writer {
    const writer = shell.stdout();
    if (shell.term_view.term.row > 0) {
        writer.print("\x1b[{d}A", .{shell.term_view.term.row}) catch {};
    }
    writer.writeAll("\r\x1b[J") catch {};
    return writer;
}

/// Redraw the prompt + edit line below whatever was just printed.
fn endAbovePrompt(shell: *Shell) void {
    shell.stdout().flush() catch {};
    shell.term_view.term.row = 0;
    shell.term_view.term.col = 0;
    shell.term_view.last_hash = 0; // force full redraw
    shell.renderLine() catch {};
    shell.stdout().flush() catch {};
}

/// Echo every complete line buffered in s.echo above the prompt, each with the
/// zish-drawn dim provenance prefix (unforgeable: the feat's own SGR is
/// stripped, so it cannot paint this chrome).
fn echoCompleteLines(shell: *Shell, s: *Session) void {
    const last_nl = std.mem.lastIndexOfScalar(u8, s.echo.items, '\n') orelse return;
    if (!shell.running) { // no live prompt (exit path): plain writes
        shell.stdout().writeAll(s.echo.items[0 .. last_nl + 1]) catch {};
        shell.stdout().flush() catch {};
    } else {
        const writer = beginAbovePrompt(shell);
        var rest = s.echo.items[0 .. last_nl + 1];
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            writer.print("\x1b[2m[sess {d}:{s}]\x1b[0m ", .{ s.id, s.name }) catch {};
            writer.writeAll(rest[0 .. nl + 1]) catch {};
            rest = rest[nl + 1 ..];
        }
        endAbovePrompt(shell);
    }
    const keep = s.echo.items[last_nl + 1 ..];
    std.mem.copyForwards(u8, s.echo.items, keep);
    s.echo.items.len = keep.len;
}

// ---------------------------------------------------------------------------
// frame plumbing
// ---------------------------------------------------------------------------

fn frameType(v: std.json.Value) ?[]const u8 {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    return switch (obj.get("t") orelse return null) {
        .string => |str| str,
        else => null,
    };
}

fn frameStr(v: std.json.Value, key: []const u8) []const u8 {
    const obj = switch (v) {
        .object => |o| o,
        else => return "",
    };
    return switch (obj.get(key) orelse return "") {
        .string => |str| str,
        else => "",
    };
}

/// Write a frame to the feat, bounded: poll for writability with a timeout so
/// a feat that stops reading can stall us at most WRITE_TIMEOUT_MS. Returns
/// false on stall/error — the caller ends the session.
fn writeFrame(fd: compat.posix.fd_t, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        var pfd = [_]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.OUT, .revents = 0 }};
        const prc = std.c.poll(&pfd, 1, WRITE_TIMEOUT_MS);
        if (prc <= 0) return false; // timeout or error: feat is wedged
        if ((pfd[0].revents & std.c.POLL.OUT) == 0) return false;
        const k = compat.posix.write(fd, bytes[off..]) catch return false;
        if (k == 0) return false;
        off += k;
    }
    return true;
}

fn writeAllFd(fd: compat.posix.fd_t, bytes: []const u8) void {
    if (fd < 0) return;
    var off: usize = 0;
    while (off < bytes.len) {
        const k = compat.posix.write(fd, bytes[off..]) catch return;
        if (k == 0) return;
        off += k;
    }
}

fn appendJsonEscaped(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\r' => try out.appendSlice(alloc, "\\r"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        else => if (c < 0x20) {
            var b: [8]u8 = undefined;
            const e = std.fmt.bufPrint(&b, "\\u{x:0>4}", .{c}) catch continue;
            try out.appendSlice(alloc, e);
        } else try out.append(alloc, c),
    };
}

// A minimal writer adapter so sanitize.writeSanitized (anytype writer with
// writeByte/writeAll) can target an ArrayListUnmanaged.
const ListWriter = struct {
    list: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    pub fn writeByte(self: ListWriter, b: u8) !void {
        try self.list.append(self.alloc, b);
    }
    pub fn writeAll(self: ListWriter, s: []const u8) !void {
        try self.list.appendSlice(self.alloc, s);
    }
};

fn listWriter(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) ListWriter {
    return .{ .list = list, .alloc = alloc };
}
