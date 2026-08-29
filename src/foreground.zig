// foreground.zig - THE single owner of foreground job-control discipline.
//
// Every place the shell runs a child in the foreground must perform the same
// dance, and getting any step wrong produces a subtly broken shell (a child
// that can't be Ctrl+C'd, a Ctrl+Z that wedges the shell, a prompt left in
// cooked mode). Before this module the dance was hand-copied at five sites and
// `fg` used a sixth divergent mechanism; two copies had already regressed.
// The discipline now lives here, structurally, and the call sites only choose
// what the child *body* does.
//
// The dance, in full (mirrors the known-correct single-external-command path):
//
//   parent, before fork:   TtyCtl.acquire -> cooked (canonical input, ISIG)
//   child, after fork:     setpgid(0,pgid) -> tcsetpgrp -> resetChildSignals
//                          (IN THAT ORDER - see jobs.resetChildSignals: the
//                          child's tcsetpgrp from its brand-new background
//                          pgroup only succeeds while SIGTTOU is still ignored)
//   parent, after fork:    setpgid(pid,pgid) (race avoidance - both sides set)
//   parent, wait:          SIGINT ignored around waitpid(W.UNTRACED)
//   parent, decode:        exited -> code; signaled -> 128+sig;
//                          stopped -> register stopped job, print notice, 148
//   parent, reclaim:       tcsetpgrp back to the shell's pgroup
//   parent, at scope exit: restoreRaw (line editor's raw mode) -> release
//
// All terminal manipulation is gated on `tty.fd != null and !shell.forked_child`
// - a forked child (background job body, pipeline stage, command substitution)
// must never touch the terminal: tcsetattr/tcsetpgrp from a background process
// group raises SIGTTOU and stops the child before it ever execs (the
// "born-stopped" bug).
//
// Two child gates exist ON PURPOSE - do not unify them:
//   * Session.setupChild (single command / subshell / feat): the child gets
//     its own pgroup ONLY when this session is foreground. A command
//     substitution or background-job body must keep its children in its own
//     pgroup so a Ctrl+C aimed at the foreground group still reaches them.
//   * Session.setupPipelineStage: stages join the pipeline's pgroup whenever
//     the shell has a tty AT ALL, even when the pipeline itself runs in the
//     background - preserved from the reference pipeline path.

const std = @import("std");
const compat = @import("compat.zig");
const jobs = @import("jobs.zig");
const Shell = @import("Shell.zig");

/// Controlling-terminal handle for foreground job control.
///
/// Job control must key off the session's controlling terminal, not stdin:
/// stdin can be redirected (heredoc, `< file`, a redirected function call)
/// while the command still prompts on /dev/tty (age, ssh, sudo). Gating the
/// tcsetpgrp handover on isatty(0) while calling setpgid unconditionally left
/// such children in an orphaned background process group whose /dev/tty reads
/// fail with EIO (SIGTTIN is inherited as SIG_IGN through exec) - the user's
/// keystroke then landed in the shell's own line editor instead.
pub const TtyCtl = struct {
    /// fd of the controlling tty (stdin when it IS the tty, else /dev/tty),
    /// or null when the shell has no controlling terminal (scripts, CI).
    fd: ?compat.posix.fd_t,
    opened: bool, // fd was opened here and must be closed on release

    pub fn acquire() TtyCtl {
        if (compat.posix.isatty(compat.posix.STDIN_FILENO))
            return .{ .fd = compat.posix.STDIN_FILENO, .opened = false };
        const fd = compat.posix.open("/dev/tty", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0) catch
            return .{ .fd = null, .opened = false };
        return .{ .fd = fd, .opened = true };
    }

    /// Cooked terminal for the child (canonical input, echo, ISIG).
    pub fn cooked(self: TtyCtl, shell: *Shell) void {
        const fd = self.fd orelse return;
        if (!self.opened) {
            shell.disableRawMode();
        } else if (shell.original_termios) |orig| {
            compat.posix.tcsetattr(fd, .NOW, orig) catch {};
        }
    }

    /// Back to the line editor's raw mode (mirrors Shell.enableRawMode).
    pub fn restoreRaw(self: TtyCtl, shell: *Shell) void {
        const fd = self.fd orelse return;
        if (!self.opened) {
            shell.enableRawMode() catch {};
        } else if (shell.original_termios) |orig| {
            var raw = orig;
            raw.lflag.ICANON = false;
            raw.lflag.ECHO = false;
            raw.lflag.ISIG = false;
            raw.iflag.ICRNL = false;
            raw.iflag.IXON = false;
            raw.cc[@intFromEnum(compat.posix.V.MIN)] = 1;
            raw.cc[@intFromEnum(compat.posix.V.TIME)] = 0;
            compat.posix.tcsetattr(fd, .NOW, raw) catch {};
        }
    }

    pub fn release(self: TtyCtl) void {
        if (self.opened) compat.posix.close(self.fd.?);
    }
};

/// Ignore SIGINT in the shell for the duration of a foreground wait: the
/// child receives the Ctrl+C directly, and the shell must not die with it.
pub const SigintGuard = struct {
    old: compat.posix.Sigaction,

    pub fn begin() SigintGuard {
        var old: compat.posix.Sigaction = undefined;
        const ignore_action = compat.posix.Sigaction{
            .handler = .{ .handler = compat.posix.SIG.IGN },
            .mask = std.mem.zeroes(compat.posix.sigset_t),
            .flags = 0,
        };
        compat.posix.sigaction(compat.posix.SIG.INT, &ignore_action, &old);
        return .{ .old = old };
    }

    pub fn end(self: *const SigintGuard) void {
        compat.posix.sigaction(compat.posix.SIG.INT, &self.old, null);
    }
};

/// Decoded result of a foreground wait.
pub const Outcome = struct {
    /// Shell-visible status: exit code, 128+signal, or 148 (128+SIGTSTP).
    code: u8,
    /// Child was stopped (Ctrl+Z); it has been registered as a stopped job
    /// and the "[n]+ Stopped" notice printed.
    stopped: bool,
    /// Child exited normally (so `code` is its real exit status - the
    /// "command not found" message must only fire on exited && code==127,
    /// never on the unreachable-decode fallback).
    exited: bool,
};

/// One foreground execution: owns the terminal handover for the lifetime of
/// one foreground child (or job). Usage:
///
///     var fg = foreground.Session.begin(shell);
///     defer fg.end();
///     shell.stdout().flush() catch {};        // caller: flush before fork
///     const pid = fork();
///     if (pid == 0) { fg.setupChild(); ...child body... }
///     fg.registerChild(pid);
///     const out = fg.reap(pid, cmd_display_string);
///     return out.code;
///
/// end() restores the line editor's raw mode and releases the tty; reap()
/// has already reclaimed the terminal (tcsetpgrp) before end() runs.
pub const Session = struct {
    shell: *Shell,
    tty: TtyCtl,
    /// This session actually owns the terminal: the shell has a controlling
    /// tty AND this process is the top-level shell, not a forked child.
    is_foreground: bool,

    /// Parent side, before fork: acquire the controlling tty and cook it
    /// (canonical input, echo, ISIG) so the child sees a normal terminal.
    pub fn begin(shell: *Shell) Session {
        const tty = TtyCtl.acquire();
        const fg = tty.fd != null and !shell.forked_child;
        if (fg) tty.cooked(shell);
        return .{ .shell = shell, .tty = tty, .is_foreground = fg };
    }

    /// Parent side, at scope exit (defer this right after begin): restore
    /// the line editor's raw mode and release the tty handle.
    pub fn end(self: *const Session) void {
        if (self.is_foreground) self.tty.restoreRaw(self.shell);
        self.tty.release();
    }

    /// The terminal fd this session may manipulate, or null when it must
    /// not touch the terminal at all (no tty, or we ARE a forked child).
    pub fn ttyFd(self: *const Session) ?compat.posix.fd_t {
        return if (self.is_foreground) self.tty.fd else null;
    }

    // ---- child side (call immediately after fork, in the child) ----

    /// Foreground-child setup for a single-bodied child (external command,
    /// subshell body, feat, timed command): own pgroup + terminal when this
    /// session is foreground, then default signal dispositions. The order
    /// setpgid -> tcsetpgrp -> resetChildSignals is load-bearing (see
    /// jobs.resetChildSignals).
    pub fn setupChild(self: *const Session) void {
        if (self.ttyFd()) |fd| {
            compat.posix.setpgid(0, 0) catch {};
            jobs.tcsetpgrp(fd, compat.posix.getpid()) catch {};
        }
        jobs.resetChildSignals();
    }

    /// Pipeline-stage setup: join the pipeline's process group (leader_pgid
    /// == 0 means "I am the leader"). Stages join a pgroup whenever the
    /// shell has a tty at all - even for a background pipeline - but only a
    /// foreground leader takes the terminal.
    pub fn setupPipelineStage(self: *const Session, leader_pgid: compat.posix.pid_t) void {
        if (self.tty.fd) |fd| {
            if (leader_pgid == 0) {
                compat.posix.setpgid(0, 0) catch {};
                if (self.is_foreground) {
                    const mypid: compat.posix.pid_t = @intCast(compat.posix.getpid());
                    jobs.tcsetpgrp(fd, mypid) catch {};
                }
            } else {
                compat.posix.setpgid(0, leader_pgid) catch {};
            }
        }
        jobs.resetChildSignals();
    }

    // ---- parent side (call immediately after fork, in the parent) ----

    /// Race-avoidance setpgid for a single foreground child (both parent
    /// and child call setpgid; whichever runs first establishes the group).
    pub fn registerChild(self: *const Session, pid: compat.posix.pid_t) void {
        if (self.ttyFd() != null) compat.posix.setpgid(pid, pid) catch {};
    }

    /// Race-avoidance setpgid for pipeline stage `pid`; leader_pgid == 0
    /// means this pid IS the leader (and gets the terminal if foreground).
    pub fn registerPipelineStage(self: *const Session, pid: compat.posix.pid_t, leader_pgid: compat.posix.pid_t) void {
        if (self.tty.fd) |fd| {
            const pgid = if (leader_pgid == 0) pid else leader_pgid;
            _ = compat.posix.setpgid(pid, pgid) catch {};
            if (leader_pgid == 0 and self.is_foreground) {
                jobs.tcsetpgrp(fd, pid) catch {};
            }
        }
    }

    /// Take the terminal back from the child('s pgroup). reap() calls this;
    /// multi-pid callers (pipeline) call it themselves after reaping all
    /// stages, from a defer, so it also runs on the error path.
    pub fn reclaim(self: *const Session) void {
        if (self.ttyFd()) |fd| {
            const shell_pgid: compat.posix.pid_t = compat.posix.getProcessGroup(0);
            jobs.tcsetpgrp(fd, shell_pgid) catch {};
        }
    }

    /// Wait for a single foreground child and decode the result.
    /// SIGINT is ignored around the wait; the wait is UNTRACED so a Ctrl+Z'd
    /// child returns control here instead of wedging the shell; the terminal
    /// is reclaimed before the stopped-job registration (whose tcgetattr must
    /// capture the child's cooked modes BEFORE end()'s restoreRaw runs).
    ///
    /// `cmd` is the display string used if the child stops and becomes a job.
    /// `rusage` (optional) routes the wait through wait4 for `time`.
    pub fn reap(self: *const Session, pid: compat.posix.pid_t, cmd: []const u8, rusage: ?*anyopaque) Outcome {
        var guard = SigintGuard.begin();
        defer guard.end();

        var status: u32 = 0;
        if (rusage) |ru| {
            // wait4 for rusage; retry on EINTR like compat.posix.waitpid does.
            while (true) {
                const rc = compat.posix.waitRusage(pid, &status, compat.posix.W.UNTRACED, ru);
                if (rc >= 0) break;
                if (std.posix.errno(rc) != .INTR) break;
            }
        } else {
            const result = compat.posix.waitpid(pid, compat.posix.W.UNTRACED);
            status = result.status;
        }

        self.reclaim();

        if (compat.posix.W.IFSTOPPED(status)) {
            const job_id = self.shell.job_table.addStoppedForeground(pid, cmd);
            self.shell.stdout().print("\n[{d}]+  Stopped\t\t{s}\n", .{ job_id, cmd }) catch {};
            self.shell.stdout().flush() catch {};
            return .{ .code = 148, .stopped = true, .exited = false }; // 128 + SIGTSTP(20)
        }
        if (compat.posix.W.IFEXITED(status)) {
            return .{ .code = compat.posix.W.EXITSTATUS(status), .stopped = false, .exited = true };
        }
        if (compat.posix.W.IFSIGNALED(status)) {
            const code: u8 = @truncate(128 + @as(u32, @intCast(@intFromEnum(compat.posix.W.TERMSIG(status)))));
            return .{ .code = code, .stopped = false, .exited = false };
        }
        return .{ .code = 127, .stopped = false, .exited = false };
    }
};

/// `fg`: put an existing job back in the foreground and wait for it - the
/// same discipline as launching a fresh foreground child, just with the
/// child(ren) already alive. Replaces JobTable.putJobInForeground, which used
/// a separately-captured `shell_tmodes` (cooked-or-raw depending on session
/// history) and was hardwired to STDIN_FILENO; this goes through the same
/// TtyCtl + restoreRaw owner as every other foreground site.
///
/// With no controlling tty the terminal handover is silently skipped (job
/// control is meaningless without one) - the old code errored out of `fg`.
pub fn resumeJobForeground(shell: *Shell, job: *jobs.Job, cont: bool) u8 {
    var fg = Session.begin(shell);
    defer fg.end();

    if (fg.ttyFd()) |fd| {
        // hand the terminal to the job's pgroup
        jobs.tcsetpgrp(fd, job.pgid) catch {};
        // restore the terminal modes the job was stopped with
        if (cont) {
            if (job.tmodes) |tm| compat.posix.tcsetattr(fd, .FLUSH, tm) catch {};
        }
    }

    if (cont) {
        compat.posix.kill(-job.pgid, compat.posix.SIG.CONT) catch {};
    }

    job.foreground = true;
    job.state = .running;
    // Clear stale per-process stopped flags (bash's mark_job_as_running):
    // they were set when the job stopped, and waitForJob's loop condition
    // checks isStopped() - with the flags still set it returned immediately
    // instead of waiting, so `fg` gave the prompt back while the resumed
    // job was still running.
    for (job.processes.items) |*proc| {
        if (!proc.completed) proc.stopped = false;
    }

    var guard = SigintGuard.begin();
    const status = shell.job_table.waitForJob(job);
    guard.end();

    fg.reclaim();

    if (job.isStopped()) {
        // Stopped again (Ctrl+Z): capture the modes it was running with
        // BEFORE end()'s restoreRaw, mark it background so future state
        // changes notify, print our own notice, return 148 like bash.
        if (fg.ttyFd()) |fd| job.tmodes = compat.posix.tcgetattr(fd) catch null;
        job.state = .stopped;
        job.foreground = false;
        job.notified = true; // we print our own Stopped notice
        shell.stdout().print("\n[{d}]+  Stopped\t\t{s}\n", .{ job.id, job.command }) catch {};
        shell.stdout().flush() catch {};
        return 148;
    }

    return @truncate(@as(u32, @bitCast(status)));
}
