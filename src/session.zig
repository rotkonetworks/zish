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
//! Frame protocol v0.2 (one JSON object per line):
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
//!     {"t":"event","kind":"submitted","text":"<answer>"}      reply to "prompt"
//!     {"t":"event","kind":"cancelled"}                        prompt not answerable
//!     {"t":"error","call":"<name>","reason":"denied"}         masked-off hostcall
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
const sanitize = @import("sanitize.zig");

pub const MAX_SESSIONS = 8;
/// Hostile-input cap: one frame line. A feat sending more without a newline is
/// broken or malicious; the session ends.
const MAX_FRAME = 1 << 20;
/// How long a frame write to the feat may stall before the feat is presumed
/// wedged/hostile and the session is ended.
const WRITE_TIMEOUT_MS = 5000;
/// Cap on captured `run` output copied into the transcript (the frame reply is
/// not capped — the feat gets everything; the transcript is an audit log).
const TRANSCRIPT_RUN_CAP = 64 * 1024;

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
        const out = runCaptured(shell, frameStr(parsed.value, "cmd")) catch try alloc.dupe(u8, "");
        defer alloc.free(out);
        return !replyResult(shell, w, out);
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

    try shell.stdout().print("[sess {d}:{s}] started \xc2\xb7 transcript {s}\n", .{ id, name, tr.path });
    shell.stdout().flush() catch {};
    return 0;
}

const Transcript = struct { fd: compat.posix.fd_t, path: []u8 };

/// Transcripts live flat under ~/.zish/sessions/, named
/// <shellpid>-<id>-<name>.log so concurrent shells never collide. Everything
/// written to one is already sanitized: `cat transcript` is terminal-safe.
fn openTranscript(shell: *Shell, id: u32, name: []const u8) !Transcript {
    const alloc = shell.allocator;
    const home = compat.getEnvVarOwned(alloc, "HOME") catch return error.NoHome;
    defer alloc.free(home);

    // create ~/.zish then ~/.zish/sessions (a fresh HOME has neither);
    // EEXIST is fine, any other failure makes the open below fail closed
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const parent = try std.fmt.bufPrintZ(&pbuf, "{s}/.zish", .{home});
    _ = std.c.mkdir(parent.ptr, 0o700);
    var dbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dbuf, "{s}/.zish/sessions", .{home});
    _ = std.c.mkdir(dir.ptr, 0o700);

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

        var note = beginAbovePrompt(shell);
        note.print("\x1b[2m[sess {d}:{s}]\x1b[0m asks: {s}\n        \x1b[2mreply:\x1b[0m session answer {d} <text>\n", .{ s.id, s.name, q, s.id }) catch {};
        endAbovePrompt(shell);
        return false;
    }

    if (std.mem.eql(u8, t, "run")) {
        if (!s.caps.run) return denyHostcall(shell, s, "run", ERR_RUN_DENIED);
        const cmd = frameStr(parsed.value, "cmd");

        // audit trail: the command string is model-composed text — sanitize it
        writeAllFd(s.transcript_fd, "$ ");
        var cmdclean: std.ArrayListUnmanaged(u8) = .empty;
        defer cmdclean.deinit(alloc);
        try sanitize.writeSanitized(listWriter(&cmdclean, alloc), cmd);
        writeAllFd(s.transcript_fd, cmdclean.items);
        writeAllFd(s.transcript_fd, "\n");

        const out = runCaptured(shell, cmd) catch try alloc.dupe(u8, "");
        defer alloc.free(out);

        var outclean: std.ArrayListUnmanaged(u8) = .empty;
        defer outclean.deinit(alloc);
        const capped = out[0..@min(out.len, TRANSCRIPT_RUN_CAP)];
        try sanitize.writeSanitized(listWriter(&outclean, alloc), capped);
        writeAllFd(s.transcript_fd, outclean.items);
        if (out.len > capped.len) writeAllFd(s.transcript_fd, "\n[transcript: output truncated]");
        if (outclean.items.len == 0 or outclean.items[outclean.items.len - 1] != '\n')
            writeAllFd(s.transcript_fd, "\n");

        return !replyResult(shell, s.w, out);
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

/// Run one command through zish's own executor with stdout captured and stdin
/// redirected to /dev/null: same parse→eval→sandbox→trace path as everything
/// else, but the child can never read the user's terminal.
fn runCaptured(shell: *Shell, cmd: []const u8) ![]const u8 {
    const devnull = compat.posix.openZ("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch
        return expand.executeCommandAndCapture(shell, cmd); // no /dev/null: degrade, don't fail
    defer compat.posix.close(devnull);
    const stdin_backup = compat.posix.dupHighCloexec(compat.posix.STDIN_FILENO) catch
        return expand.executeCommandAndCapture(shell, cmd);
    defer compat.posix.close(stdin_backup);
    compat.posix.dup2(devnull, compat.posix.STDIN_FILENO) catch {};
    defer compat.posix.dup2(stdin_backup, compat.posix.STDIN_FILENO) catch {};
    return expand.executeCommandAndCapture(shell, cmd);
}

/// Reply a captured `run` result. Returns false if the write failed (stalled
/// or dead feat) — caller ends the session.
fn replyResult(shell: *Shell, w: compat.posix.fd_t, out: []const u8) bool {
    const alloc = shell.allocator;
    var frame: std.ArrayListUnmanaged(u8) = .empty;
    defer frame.deinit(alloc);
    frame.appendSlice(alloc, "{\"t\":\"result\",\"code\":0,\"out\":\"") catch return false;
    appendJsonEscaped(&frame, alloc, out) catch return false;
    frame.appendSlice(alloc, "\"}\n") catch return false;
    return writeFrame(w, frame.items);
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
    return 0;
}

/// End the session at `idx`: close fds, reap without ever blocking on an
/// untrusted child (WNOHANG, then SIGKILL), close the transcript, notify.
pub fn finishSession(shell: *Shell, idx: usize) void {
    const alloc = shell.allocator;
    var s = shell.sessions.orderedRemove(idx);

    // flush any partial echoed line so the terminal isn't left mid-line
    if (s.echo.items.len > 0) {
        s.echo.append(alloc, '\n') catch {};
        echoCompleteLines(shell, &s);
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
