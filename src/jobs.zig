// jobs.zig - Job control for zish
const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");
const posix = compat.posix;

/// The TIOCSPGRP ioctl request number for this target.
///
/// Taken from the platform's own table when it has one. macOS exposes a `T`
/// struct but omits IOCSPGRP, so the BSD encoding is computed instead:
/// _IOW(g, n, t) = IOC_IN | (sizeof(t) << 16) | (g << 8) | n, which for
/// ('t', 118, c_int) is 0x80047476.
const tiocspgrp: u32 = blk: {
    const T = std.posix.system.T;
    if (@hasDecl(T, "IOCSPGRP")) break :blk @intCast(T.IOCSPGRP);
    break :blk switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => 0x80000000 |
            (@as(u32, @sizeOf(c_int)) << 16) | (@as(u32, 't') << 8) | 118,
        else => @compileError("TIOCSPGRP is unknown for this target; add it here"),
    };
};

/// tcsetpgrp via ioctl — std.posix.tcsetpgrp does not compile on 0.16 (it
/// calls a std.c.tcsetpgrp that does not exist), so the ioctl stays.
///
/// The request number is taken from the target's own T table rather than
/// hardcoded. It was `0x5410`, the Linux value: on any other platform that
/// number names a *different* ioctl, so the call would compile and then do
/// something unrelated at runtime — the worst kind of portability bug, because
/// the build stays green. Same pattern as TIOCGWINSZ in Shell.zig.
pub fn tcsetpgrp(fd: posix.fd_t, pgrp: posix.pid_t) posix.TermioSetPgrpError!void {
    // The request is bit-cast because macOS types the ioctl request as a
    // signed c_int, and 0x80047476 does not fit in one as a positive value.
    const rc = std.posix.system.ioctl(fd, @bitCast(tiocspgrp), @intFromPtr(&pgrp));
    switch (std.posix.errno(rc)) {
        .SUCCESS => return,
        // Not unreachable: `fd` is whatever the shell recorded as its terminal
        // and `pgrp` can name a group that has already exited, so both of these
        // are reachable from ordinary races (terminal closed under us, job
        // reaped between lookup and call). Asserting turned a recoverable job
        // control error into a shell crash.
        .BADF => return error.NotATerminal,
        .INVAL => return error.NotAPgrpMember,
        .NOTTY => return error.NotATerminal,
        .PERM => return error.NotAPgrpMember,
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

/// waitpid wrapper that retries on EINTR
/// returns {.pid = 0, .status = 0} on ECHILD or other errors
fn waitpidRetry(pid: posix.pid_t, flags: u32) struct { pid: posix.pid_t, status: u32 } {
    while (true) {
        // libc waitpid rather than the raw Linux syscall: the syscall wrapper
        // compiles for any target but only *works* on Linux. EINTR is still
        // visible, just through errno instead of a negative return.
        var status: c_int = 0;
        const rc = std.c.waitpid(pid, &status, @intCast(flags));

        if (rc > 0) return .{ .pid = rc, .status = @bitCast(status) };
        if (rc == 0) return .{ .pid = 0, .status = 0 }; // WNOHANG, none ready
        if (std.posix.errno(rc) == .INTR) continue; // retry on signal
        return .{ .pid = 0, .status = 0 }; // ECHILD or other error
    }
}

pub const JobState = enum {
    running,
    stopped,
    done,

    pub fn symbol(self: JobState) []const u8 {
        return switch (self) {
            .running => "Running",
            .stopped => "Stopped",
            .done => "Done",
        };
    }
};

pub const Process = struct {
    pid: posix.pid_t,
    status: u32 = 0, // wait status
    completed: bool = false,
    stopped: bool = false,
};

pub const Job = struct {
    id: u32, // job number [1], [2], etc.
    pgid: posix.pid_t, // process group id (first process pid)
    command: []const u8, // command string for display
    state: JobState,
    processes: std.ArrayListUnmanaged(Process), // all processes in job (for pipelines)
    foreground: bool, // is this job in foreground?
    notified: bool, // have we notified user of state change?
    start_time: i64, // when job started (unix timestamp)
    tmodes: ?posix.termios, // saved terminal modes (for stopped jobs)

    pub fn deinit(self: *Job, allocator: std.mem.Allocator) void {
        allocator.free(self.command);
        self.processes.deinit(allocator);
    }

    /// Check if all processes in job have completed
    pub fn isCompleted(self: *const Job) bool {
        for (self.processes.items) |proc| {
            if (!proc.completed) return false;
        }
        return true;
    }

    /// Check if any process in job is stopped
    pub fn isStopped(self: *const Job) bool {
        for (self.processes.items) |proc| {
            if (proc.stopped and !proc.completed) return true;
        }
        return false;
    }

    /// Get the last process in the job (for exit status)
    pub fn lastProcess(self: *const Job) ?*const Process {
        if (self.processes.items.len == 0) return null;
        return &self.processes.items[self.processes.items.len - 1];
    }
};

pub const JobTable = struct {
    jobs: std.ArrayListUnmanaged(Job),
    allocator: std.mem.Allocator,
    next_id: u32,
    shell_pgid: posix.pid_t, // shell's process group
    shell_terminal: posix.fd_t, // terminal fd
    shell_tmodes: posix.termios, // shell's terminal modes
    current_job: ?u32, // most recent job (for %% and %+)
    previous_job: ?u32, // previous job (for %-)

    // Pending notifications for async display
    notifications: std.ArrayListUnmanaged(Notification),

    pub const Notification = struct {
        job_id: u32,
        state: JobState,
        command: []const u8,
        exit_status: u8,
    };

    pub fn init(allocator: std.mem.Allocator) JobTable {
        const terminal = posix.STDIN_FILENO;
        const tmodes = posix.tcgetattr(terminal) catch std.mem.zeroes(posix.termios);

        // get actual process group - tcgetpgrp returns the foreground pgrp,
        // but we want our own pgrp which we can get via getpgid(0)
        const shell_pgid = posix.getProcessGroup(0);
        const pgid: posix.pid_t = if (shell_pgid < 0)
            posix.getpid() // fallback if getpgid fails
        else
            shell_pgid;

        return JobTable{
            .jobs = .empty,
            .allocator = allocator,
            .next_id = 1,
            .shell_pgid = pgid,
            .shell_terminal = terminal,
            .shell_tmodes = tmodes,
            .current_job = null,
            .previous_job = null,
            .notifications = .empty,
        };
    }

    pub fn deinit(self: *JobTable) void {
        for (self.jobs.items) |*job| {
            job.deinit(self.allocator);
        }
        self.jobs.deinit(self.allocator);
        for (self.notifications.items) |notif| {
            self.allocator.free(notif.command);
        }
        self.notifications.deinit(self.allocator);
    }

    /// Add a new job with a single process
    pub fn addJob(self: *JobTable, pid: posix.pid_t, command: []const u8, foreground: bool) !u32 {
        const job_id = self.next_id;
        self.next_id += 1;

        const cmd_copy = try self.allocator.dupe(u8, command);
        errdefer self.allocator.free(cmd_copy);

        var processes = std.ArrayListUnmanaged(Process).empty;
        errdefer processes.deinit(self.allocator);
        try processes.append(self.allocator, .{ .pid = pid });

        try self.jobs.append(self.allocator, .{
            .id = job_id,
            .pgid = pid, // first process is the group leader
            .command = cmd_copy,
            .state = .running,
            .processes = processes,
            .foreground = foreground,
            .notified = foreground, // foreground jobs don't need notification
            .start_time = compat.timestamp(),
            .tmodes = null,
        });

        // Update current/previous job
        if (self.current_job) |curr| {
            self.previous_job = curr;
        }
        self.current_job = job_id;

        return job_id;
    }

    /// Register a foreground process that was just stopped by SIGTSTP (Ctrl+Z).
    /// Adds it as a background job in the stopped state so it can be resumed
    /// with `fg`/`bg`. Saves the terminal modes the child was using so `fg`
    /// can restore them. Returns the new job id (0 on allocation failure).
    pub fn addStoppedForeground(self: *JobTable, pid: posix.pid_t, command: []const u8) u32 {
        const job_id = self.addJob(pid, command, false) catch return 0;
        if (self.getJob(job_id)) |job| {
            job.state = .stopped;
            job.notified = true; // caller prints its own "Stopped" message
            if (job.processes.items.len > 0) {
                job.processes.items[0].stopped = true;
                job.processes.items[0].completed = false;
            }
            job.tmodes = posix.tcgetattr(self.shell_terminal) catch null;
        }
        return job_id;
    }

    /// Add a pipeline job with multiple processes
    pub fn addPipelineJob(self: *JobTable, pids: []const posix.pid_t, pgid: posix.pid_t, command: []const u8, foreground: bool) !u32 {
        const job_id = self.next_id;
        self.next_id += 1;

        const cmd_copy = try self.allocator.dupe(u8, command);
        errdefer self.allocator.free(cmd_copy);

        var processes = std.ArrayListUnmanaged(Process).empty;
        errdefer processes.deinit(self.allocator);

        for (pids) |pid| {
            try processes.append(self.allocator, .{ .pid = pid });
        }

        try self.jobs.append(self.allocator, .{
            .id = job_id,
            .pgid = pgid,
            .command = cmd_copy,
            .state = .running,
            .processes = processes,
            .foreground = foreground,
            .notified = foreground,
            .start_time = compat.timestamp(),
            .tmodes = null,
        });

        if (self.current_job) |curr| {
            self.previous_job = curr;
        }
        self.current_job = job_id;

        return job_id;
    }

    pub fn getJob(self: *JobTable, job_id: u32) ?*Job {
        for (self.jobs.items) |*job| {
            if (job.id == job_id) return job;
        }
        return null;
    }

    pub fn getJobByPgid(self: *JobTable, pgid: posix.pid_t) ?*Job {
        for (self.jobs.items) |*job| {
            if (job.pgid == pgid) return job;
        }
        return null;
    }

    pub fn getJobByPid(self: *JobTable, pid: posix.pid_t) ?*Job {
        for (self.jobs.items) |*job| {
            for (job.processes.items) |proc| {
                if (proc.pid == pid) return job;
            }
        }
        return null;
    }

    pub fn getCurrentJob(self: *JobTable) ?*Job {
        if (self.current_job) |id| {
            return self.getJob(id);
        }
        // Fall back to most recent stopped job, then most recent running
        var stopped: ?*Job = null;
        var running: ?*Job = null;
        for (self.jobs.items) |*job| {
            if (job.state == .stopped) stopped = job;
            if (job.state == .running) running = job;
        }
        return stopped orelse running;
    }

    pub fn removeJob(self: *JobTable, job_id: u32) void {
        var i: usize = 0;
        while (i < self.jobs.items.len) {
            if (self.jobs.items[i].id == job_id) {
                var job = self.jobs.orderedRemove(i);
                job.deinit(self.allocator);

                // Update current/previous
                if (self.current_job == job_id) {
                    self.current_job = self.previous_job;
                    self.previous_job = null;
                } else if (self.previous_job == job_id) {
                    self.previous_job = null;
                }
                return;
            }
            i += 1;
        }
    }

    /// Update job state based on a wait result
    pub fn markProcessStatus(self: *JobTable, pid: posix.pid_t, status: u32) void {
        for (self.jobs.items) |*job| {
            for (job.processes.items) |*proc| {
                if (proc.pid == pid) {
                    proc.status = status;

                    if (posix.W.IFSTOPPED(status)) {
                        proc.stopped = true;
                        proc.completed = false;
                    } else {
                        proc.completed = true;
                        proc.stopped = false;
                    }

                    // Update job state
                    if (job.isStopped()) {
                        job.state = .stopped;
                        job.notified = false;
                    } else if (job.isCompleted()) {
                        job.state = .done;
                        job.notified = false;
                    }
                    return;
                }
            }
        }
    }

    /// Non-blocking check for child status changes (call from main loop)
    /// Only reaps children belonging to tracked jobs to avoid stealing
    /// children from subshells or command substitution
    pub fn updateJobStatuses(self: *JobTable) void {
        for (self.jobs.items) |*job| {
            if (job.state == .done) continue; // already done

            // wait on this job's process group specifically with WNOHANG
            while (true) {
                const result = waitpidRetry(-job.pgid, posix.W.NOHANG | posix.W.UNTRACED);
                if (result.pid <= 0) break;
                self.markProcessStatus(result.pid, result.status);
            }
        }
    }

    /// Get pending notifications and clear them
    pub fn getPendingNotifications(self: *JobTable) ![]Notification {
        var pending = std.ArrayListUnmanaged(Notification).empty;
        errdefer {
            // clean up any allocations made before error
            for (pending.items) |notif| {
                self.allocator.free(notif.command);
            }
            pending.deinit(self.allocator);
        }

        for (self.jobs.items) |*job| {
            if (!job.notified and !job.foreground) {
                const exit_status: u8 = if (job.lastProcess()) |proc|
                    @truncate(posix.W.EXITSTATUS(proc.status))
                else
                    0;

                const cmd_copy = try self.allocator.dupe(u8, job.command);
                errdefer self.allocator.free(cmd_copy);

                try pending.append(self.allocator, .{
                    .job_id = job.id,
                    .state = job.state,
                    .command = cmd_copy,
                    .exit_status = exit_status,
                });
                job.notified = true;
            }
        }

        return pending.toOwnedSlice(self.allocator);
    }

    /// Clean up completed jobs that have been notified
    pub fn cleanupDoneJobs(self: *JobTable) void {
        var i: usize = 0;
        while (i < self.jobs.items.len) {
            const job = &self.jobs.items[i];
            if (job.state == .done and job.notified) {
                var removed = self.jobs.orderedRemove(i);
                removed.deinit(self.allocator);
            } else {
                i += 1;
            }
        }
    }

    /// Put a job in the foreground
    pub fn putJobInForeground(self: *JobTable, job: *Job, cont: bool) !i32 {
        // give terminal control to the job's process group
        tcsetpgrp(self.shell_terminal, job.pgid) catch |err| {
            std.debug.print("zish: tcsetpgrp to job failed: {}\n", .{err});
            return error.TerminalControlFailed;
        };

        // restore job's terminal modes if it was stopped
        if (cont and job.tmodes != null) {
            posix.tcsetattr(self.shell_terminal, .FLUSH, job.tmodes.?) catch {};
        }

        // send SIGCONT if continuing a stopped job
        if (cont) {
            posix.kill(-job.pgid, posix.SIG.CONT) catch |err| {
                std.debug.print("zish: SIGCONT to job failed: {}\n", .{err});
                // not fatal, job may have exited
            };
        }

        job.foreground = true;
        job.state = .running;

        // wait for job to complete or stop
        const status = self.waitForJob(job);

        // put shell back in foreground - this must succeed
        tcsetpgrp(self.shell_terminal, self.shell_pgid) catch |err| {
            std.debug.print("zish: tcsetpgrp back to shell failed: {}\n", .{err});
            // try to continue anyway
        };

        // save job's terminal modes
        job.tmodes = posix.tcgetattr(self.shell_terminal) catch null;

        // restore shell's terminal modes
        posix.tcsetattr(self.shell_terminal, .FLUSH, self.shell_tmodes) catch {};

        return status;
    }

    /// Put a job in the background
    pub fn putJobInBackground(self: *JobTable, job: *Job, cont: bool) void {
        _ = self; // self not needed but kept for API consistency
        if (cont) {
            _ = posix.kill(-job.pgid, posix.SIG.CONT) catch {};
        }
        job.foreground = false;
        job.state = .running;
    }

    /// Wait for a job to stop or complete
    /// wait for a job to stop or complete, handling EINTR
    fn waitForJob(self: *JobTable, job: *Job) i32 {
        while (!job.isStopped() and !job.isCompleted()) {
            // waitpid with EINTR retry loop
            const result = waitpidRetry(-job.pgid, posix.W.UNTRACED);
            if (result.pid > 0) {
                self.markProcessStatus(result.pid, result.status);
            } else {
                // ECHILD or other error - no more children to wait for
                break;
            }
        }

        if (job.lastProcess()) |proc| {
            return @as(i32, posix.W.EXITSTATUS(proc.status));
        }
        return 0;
    }

    /// Format job for display
    pub fn formatJob(self: *JobTable, job: *const Job, writer: anytype, verbose: bool) !void {
        const current_marker: u8 = if (self.current_job == job.id) '+' else if (self.previous_job == job.id) '-' else ' ';

        if (verbose) {
            // Verbose format with PIDs
            try writer.print("[{d}]{c} ", .{ job.id, current_marker });
            for (job.processes.items, 0..) |proc, i| {
                if (i > 0) try writer.writeAll(" | ");
                try writer.print("{d}", .{proc.pid});
            }
            try writer.print(" {s}\t{s}\n", .{ job.state.symbol(), job.command });
        } else {
            // Standard format
            try writer.print("[{d}]{c}  {s}\t\t{s}\n", .{
                job.id,
                current_marker,
                job.state.symbol(),
                job.command
            });
        }
    }
};

/// Set up process for job control (call in child after fork)
/// pid should be 0 when called from child (will use getpid())
/// pgid should be 0 for first process in pipeline (becomes group leader)
pub fn launchProcess(pid: posix.pid_t, pgid: posix.pid_t, foreground: bool, terminal: posix.fd_t) void {
    // in child, pid=0 means use our own pid
    const our_pid: posix.pid_t = if (pid == 0)
        @intCast(posix.getpid())
    else
        pid;

    // pgid=0 means we're the group leader, use our pid
    const actual_pgid = if (pgid == 0) our_pid else pgid;

    // put process in its own process group
    // errors here are not fatal but indicate a problem
    posix.setpgid(our_pid, actual_pgid) catch |err| {
        // EACCES means child already exec'd, ESRCH means process gone
        // both can happen in race conditions and are ignorable
        if (err != error.PermissionDenied and err != error.ProcessNotFound) {
            std.debug.print("zish: setpgid failed: {}\n", .{err});
        }
    };

    // if foreground, give it the terminal
    if (foreground) {
        tcsetpgrp(terminal, actual_pgid) catch |err| {
            std.debug.print("zish: tcsetpgrp failed: {}\n", .{err});
        };
    }

    // restore default signal handlers - child should respond to signals normally
    const default_action = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = 0,
    };
    _ = posix.sigaction(posix.SIG.INT, &default_action, null);
    _ = posix.sigaction(posix.SIG.QUIT, &default_action, null);
    _ = posix.sigaction(posix.SIG.TSTP, &default_action, null);
    _ = posix.sigaction(posix.SIG.TTIN, &default_action, null);
    _ = posix.sigaction(posix.SIG.TTOU, &default_action, null);
    _ = posix.sigaction(posix.SIG.CHLD, &default_action, null);
}
