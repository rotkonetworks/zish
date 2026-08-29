//! Zig 0.16 compatibility layer.
//!
//! 0.16 moved file/dir APIs behind an explicit `std.Io` parameter and removed
//! most process-level functions from `std.posix`. zish is a synchronous,
//! linux-only program that does raw fd work for job control, so:
//!
//! - `compat.io()` exposes one global `std.Io` for the whole process,
//!   wired from `std.process.Init` in main (lazy `Io.Threaded` fallback
//!   for tests).
//! - `compat.posix` re-exports what survives in `std.posix` and lifts the
//!   removed functions from the 0.15.2 stdlib (libc-backed, linux paths only),
//!   keeping the old error-union signatures so call sites stay unchanged.

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;

// ---------------------------------------------------------------------------
// Global Io
// ---------------------------------------------------------------------------

var io_instance: std.Io = undefined;
var io_initialized = false;
var threaded_fallback: std.Io.Threaded = undefined;

/// Called once from main() with std.process.Init.io before anything else runs.
pub fn setIo(io_: std.Io) void {
    io_instance = io_;
    io_initialized = true;
}

/// Global Io accessor. Lazy Threaded fallback covers unit tests and any
/// code path that runs before main wires up Init.io. Not thread-safe on
/// first call — main calls setIo before threads spawn.
pub fn io() std.Io {
    if (!io_initialized) {
        threaded_fallback = std.Io.Threaded.init(std.heap.page_allocator, .{});
        io_instance = threaded_fallback.io();
        io_initialized = true;
    }
    return io_instance;
}

// ---------------------------------------------------------------------------
// Time (std.time.timestamp/milliTimestamp/nanoTimestamp, Thread.sleep, Timer
// were removed in 0.16 — clocks now live behind Io)
// ---------------------------------------------------------------------------

fn nowNs(clock: std.Io.Clock) i96 {
    return std.Io.Clock.now(clock, io()).nanoseconds;
}

/// std.time.timestamp() — seconds since epoch.
pub fn timestamp() i64 {
    return @intCast(@divFloor(nowNs(.real), std.time.ns_per_s));
}

/// std.time.milliTimestamp().
pub fn milliTimestamp() i64 {
    return @intCast(@divFloor(nowNs(.real), std.time.ns_per_ms));
}

/// std.time.nanoTimestamp().
pub fn nanoTimestamp() i128 {
    return @intCast(nowNs(.real));
}

/// std.Thread.sleep(ns).
pub fn sleep(ns: u64) void {
    const dur: std.Io.Clock.Duration = .{
        .raw = .fromNanoseconds(@intCast(ns)),
        .clock = .awake,
    };
    dur.sleep(io()) catch {};
}

/// std.time.Timer replacement (monotonic — `.awake` is CLOCK_MONOTONIC on linux).
pub const Timer = struct {
    start_ns: i96,

    pub fn start() error{TimerUnsupported}!Timer {
        return .{ .start_ns = nowNs(.awake) };
    }

    pub fn read(self: *Timer) u64 {
        return @intCast(nowNs(.awake) - self.start_ns);
    }

    pub fn reset(self: *Timer) void {
        self.start_ns = nowNs(.awake);
    }
};

// ---------------------------------------------------------------------------
// 0.15 File.readAll / File.writeAll replacements (sequential, work on pipes
// and regular files alike)
// ---------------------------------------------------------------------------

/// Sequential read until buffer full or EOF; returns bytes read.
pub fn readAll(file: std.Io.File, buf: []u8) !usize {
    var n: usize = 0;
    while (n < buf.len) {
        const r = try file.readStreaming(io(), &.{buf[n..]});
        if (r == 0) break;
        n += r;
    }
    return n;
}

/// Sequential write of all bytes.
pub fn writeAll(file: std.Io.File, bytes: []const u8) !void {
    return file.writeStreamingAll(io(), bytes);
}

// ---------------------------------------------------------------------------
// Env access (std.posix.getenv / std.process.getEnvVarOwned replacements)
// ---------------------------------------------------------------------------

pub const GetEnvVarOwnedError = error{ OutOfMemory, EnvironmentVariableNotFound, InvalidWtf8 };

pub fn getEnvVarOwned(allocator: mem.Allocator, key: []const u8) GetEnvVarOwnedError![]u8 {
    const v = posix.getenv(key) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, v);
}

// ---------------------------------------------------------------------------
// posix compatibility namespace
// ---------------------------------------------------------------------------

pub const posix = struct {
    const system = std.c;

    // --- re-exports still present in 0.16 std.posix ---
    pub const fd_t = std.posix.fd_t;
    pub const pid_t = std.posix.pid_t;
    pub const mode_t = std.posix.mode_t;
    pub const O = std.posix.O;
    pub const SIG = std.posix.SIG;
    pub const W = std.posix.W;
    pub const POLL = std.posix.POLL;
    pub const pollfd = std.posix.pollfd;
    pub const poll = std.posix.poll;
    pub const sigset_t = std.posix.sigset_t;
    pub const Sigaction = std.posix.Sigaction;
    pub const sigaction = std.posix.sigaction;
    pub const sigprocmask = std.posix.sigprocmask;
    pub const sigemptyset = std.posix.sigemptyset;
    pub const sigfillset = std.posix.sigfillset;
    pub const termios = std.posix.termios;
    pub const tcgetattr = std.posix.tcgetattr;
    pub const tcsetattr = std.posix.tcsetattr;
    pub const tcgetpgrp = std.posix.tcgetpgrp;
    pub const tcsetpgrp = std.posix.tcsetpgrp;
    pub const TermioSetPgrpError = std.posix.TermioSetPgrpError;
    pub const T = std.posix.T;
    pub const V = std.posix.V;
    pub const winsize = std.posix.winsize;
    pub const timeval = std.posix.timeval;
    pub const STDIN_FILENO = std.posix.STDIN_FILENO;
    pub const STDOUT_FILENO = std.posix.STDOUT_FILENO;
    pub const STDERR_FILENO = std.posix.STDERR_FILENO;
    pub const PATH_MAX = std.posix.PATH_MAX;
    pub const HOST_NAME_MAX = std.posix.HOST_NAME_MAX;
    pub const gethostname = std.posix.gethostname;
    pub const kill = std.posix.kill;
    pub const read = std.posix.read;
    pub const mmap = std.posix.mmap;
    pub const munmap = std.posix.munmap;
    pub const madvise = std.posix.madvise;
    pub const MAP = std.posix.MAP;
    pub const PROT = std.posix.PROT;
    pub const MADV = std.posix.MADV;
    pub const errno = std.posix.errno;
    pub const unexpectedErrno = std.posix.unexpectedErrno;
    pub const E = std.posix.E;
    /// 0.16 made std.posix.Stat void on linux; Statx keeps the same field
    /// names for the common members (size, mode, uid, gid, ino, nlink).
    // statx is Linux-only. Everywhere else this is the libc stat struct;
    // both expose `.size`, which is all callers use.
    pub const Stat = if (builtin.os.tag == .linux) std.os.linux.Statx else std.c.Stat;
    pub const ReadError = std.posix.ReadError;

    // --- lifted from zig 0.15.2 std.posix (libc-backed, linux only) ---

    pub fn getenv(key: []const u8) ?[:0]const u8 {
        if (mem.indexOfScalar(u8, key, '=') != null) return null;
        var ptr = std.c.environ;
        while (ptr[0]) |line| : (ptr += 1) {
            var line_i: usize = 0;
            while (line[line_i] != 0) : (line_i += 1) {
                if (line_i == key.len) break;
                if (line[line_i] != key[line_i]) break;
            }
            if ((line_i != key.len) or (line[line_i] != '=')) continue;
            return mem.sliceTo(line + line_i + 1, 0);
        }
        return null;
    }

    pub fn getenvZ(key: [*:0]const u8) ?[:0]const u8 {
        const value = system.getenv(key) orelse return null;
        return mem.sliceTo(value, 0);
    }

    pub fn close(fd: fd_t) void {
        switch (errno(system.close(fd))) {
            .BADF => unreachable, // always a race condition
            .INTR => return, // still a success, see ziglang/zig#2425
            else => return,
        }
    }

    /// Reposition the file offset. `whence` is SEEK_SET(0)/CUR(1)/END(2).
    /// Returns the resulting offset. Used to rewind a capture temp file after
    /// a command has written to it, before reading it back.
    pub fn lseek(fd: fd_t, offset: i64, whence: u32) !i64 {
        if (builtin.os.tag == .linux) {
            const rc = std.os.linux.lseek(fd, offset, whence);
            if (@as(isize, @bitCast(rc)) < 0) return error.SeekFailed;
            return @intCast(rc);
        } else {
            const rc = std.c.lseek(fd, @intCast(offset), @enumFromInt(whence));
            if (rc < 0) return error.SeekFailed;
            return @intCast(rc);
        }
    }

    pub fn dup(old_fd: fd_t) !fd_t {
        const rc = system.dup(old_fd);
        return switch (errno(rc)) {
            .SUCCESS => @intCast(rc),
            .MFILE => error.ProcessFdQuotaExceeded,
            .BADF => unreachable,
            else => |err| unexpectedErrno(err),
        };
    }

    pub fn dup2(old_fd: fd_t, new_fd: fd_t) !void {
        while (true) {
            switch (errno(system.dup2(old_fd, new_fd))) {
                .SUCCESS => return,
                .BUSY, .INTR => continue,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .INVAL => unreachable,
                .BADF => unreachable,
                else => |err| return unexpectedErrno(err),
            }
        }
    }

    pub const WriteError = error{
        DiskQuota,
        FileTooBig,
        InputOutput,
        NoSpaceLeft,
        DeviceBusy,
        InvalidArgument,
        AccessDenied,
        PermissionDenied,
        BrokenPipe,
        SystemResources,
        OperationAborted,
        NotOpenForWriting,
        LockViolation,
        WouldBlock,
        ConnectionResetByPeer,
        ProcessNotFound,
        NoDevice,
        MessageTooBig,
        Unexpected,
    };

    pub fn write(fd: fd_t, bytes: []const u8) WriteError!usize {
        if (bytes.len == 0) return 0;
        while (true) {
            const rc = system.write(fd, bytes.ptr, @min(bytes.len, std.math.maxInt(isize)));
            switch (errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .INVAL => return error.InvalidArgument,
                .FAULT => unreachable,
                .AGAIN => return error.WouldBlock,
                .BADF => return error.NotOpenForWriting,
                .DESTADDRREQ => unreachable,
                .DQUOT => return error.DiskQuota,
                .FBIG => return error.FileTooBig,
                .IO => return error.InputOutput,
                .NOSPC => return error.NoSpaceLeft,
                .ACCES => return error.AccessDenied,
                .PERM => return error.PermissionDenied,
                .PIPE => return error.BrokenPipe,
                .NXIO => return error.NoDevice,
                .NODEV => return error.NoDevice,
                .SRCH => return error.ProcessNotFound,
                .CONNRESET => return error.ConnectionResetByPeer,
                .BUSY => return error.DeviceBusy,
                else => |err| return unexpectedErrno(err),
            }
        }
    }

    pub const OpenError = error{
        AccessDenied,
        PermissionDenied,
        FileTooBig,
        IsDir,
        SymLinkLoop,
        ProcessFdQuotaExceeded,
        NameTooLong,
        SystemFdQuotaExceeded,
        NoDevice,
        FileNotFound,
        ProcessNotFound,
        SystemResources,
        NoSpaceLeft,
        NotDir,
        PathAlreadyExists,
        DeviceBusy,
        BadPathName,
        Unexpected,
    };

    pub fn open(file_path: []const u8, flags: O, perm: mode_t) OpenError!fd_t {
        const file_path_c = toPosixPath(file_path) catch return error.NameTooLong;
        return openZ(&file_path_c, flags, perm);
    }

    pub fn openZ(file_path: [*:0]const u8, flags: O, perm: mode_t) OpenError!fd_t {
        while (true) {
            const rc = system.open(file_path, flags, perm);
            switch (errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .FAULT => unreachable,
                .INVAL => return error.BadPathName,
                .ACCES => return error.AccessDenied,
                .FBIG => return error.FileTooBig,
                .OVERFLOW => return error.FileTooBig,
                .ISDIR => return error.IsDir,
                .LOOP => return error.SymLinkLoop,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NAMETOOLONG => return error.NameTooLong,
                .NFILE => return error.SystemFdQuotaExceeded,
                .NODEV => return error.NoDevice,
                .NOENT => return error.FileNotFound,
                .SRCH => return error.ProcessNotFound,
                .NOMEM => return error.SystemResources,
                .NOSPC => return error.NoSpaceLeft,
                .NOTDIR => return error.NotDir,
                .PERM => return error.PermissionDenied,
                .EXIST => return error.PathAlreadyExists,
                .BUSY => return error.DeviceBusy,
                else => |err| return unexpectedErrno(err),
            }
        }
    }

    pub const PipeError = error{
        SystemFdQuotaExceeded,
        ProcessFdQuotaExceeded,
        Unexpected,
    };

    pub fn pipe() PipeError![2]fd_t {
        var fds: [2]fd_t = undefined;
        switch (errno(system.pipe(&fds))) {
            .SUCCESS => return fds,
            .INVAL => unreachable,
            .FAULT => unreachable,
            .NFILE => return error.SystemFdQuotaExceeded,
            .MFILE => return error.ProcessFdQuotaExceeded,
            else => |err| return unexpectedErrno(err),
        }
    }

    pub const FcntlError = error{
        Locked,
        FileBusy,
        PermissionDenied,
        ProcessFdQuotaExceeded,
        DeadLock,
        LockedRegionLimitExceeded,
        Unexpected,
    };

    pub fn fcntl(fd: fd_t, cmd: i32, arg: usize) FcntlError!usize {
        while (true) {
            const rc = system.fcntl(fd, cmd, arg);
            switch (errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .AGAIN, .ACCES => return error.Locked,
                .BADF => unreachable,
                .BUSY => return error.FileBusy,
                .INVAL => unreachable,
                .PERM => return error.PermissionDenied,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NOTDIR => unreachable,
                .DEADLK => return error.DeadLock,
                .NOLCK => return error.LockedRegionLimitExceeded,
                else => |err| return unexpectedErrno(err),
            }
        }
    }

    /// Duplicate `fd` to a descriptor >= 10 with close-on-exec set.
    ///
    /// Used for the shell's internal fd bookkeeping (redirect backups, capture
    /// backups, the trace channel): user redirects can only target fds 0-9, so
    /// a backup parked at >=10 can never be clobbered by `3>file`, and CLOEXEC
    /// keeps it from leaking into any child the shell execs.
    pub fn dupHighCloexec(fd: fd_t) FcntlError!fd_t {
        const F_DUPFD_CLOEXEC = 1030;
        return @intCast(try fcntl(fd, F_DUPFD_CLOEXEC, 10));
    }

    pub const FStatError = error{ SystemResources, AccessDenied, BadFileDescriptor, Unexpected };

    pub fn fstat(fd: fd_t) FStatError!Stat {
        var stat = mem.zeroes(Stat);
        if (builtin.os.tag != .linux) {
            switch (std.posix.errno(std.c.fstat(fd, &stat))) {
                .SUCCESS => return stat,
                .BADF => return error.BadFileDescriptor,
                .NOMEM => return error.SystemResources,
                .ACCES => return error.AccessDenied,
                else => |err| return unexpectedErrno(err),
            }
        }
        const linux = std.os.linux;
        switch (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &stat))) {
            .SUCCESS => return stat,
            .INVAL => unreachable,
            // Not "always a race condition": fstat on a descriptor that was
            // never opened is how you *probe* for one, which is exactly what
            // the session trace does for fd 3. Asserting here turned "no
            // harness attached" into a panic on every plain `zish -c`.
            .BADF => return error.BadFileDescriptor,
            .NOMEM => return error.SystemResources,
            .ACCES => return error.AccessDenied,
            else => |err| return unexpectedErrno(err),
        }
    }

    pub fn isatty(handle: fd_t) bool {
        return system.isatty(handle) != 0;
    }

    /// The subset of stat(2) the shell's file-test operators need, in a shape
    /// that does not depend on the platform's struct layout.
    ///
    /// Necessary because the two sides disagree: 0.16 dropped std.c.Stat on
    /// linux in favour of statx, while statx does not exist anywhere else.
    /// Callers ([ -O ], [ -G ], [ -ef ], [ -nt ], [ -ot ], [ -L ]) should not
    /// have to care which one they are compiled against.
    pub const FileStat = struct {
        dev: u64,
        ino: u64,
        uid: u32,
        gid: u32,
        mode: u32,
        mtime_ns: i128,
    };

    // Wrapped in a namespace rather than renamed: an unprefixed `stat` at this
    // scope collides with the local of that name in fstat below, but renaming
    // the extern renames the *symbol* and the link then fails on _c_stat.
    const libc = struct {
        extern "c" fn lstat(path: [*:0]const u8, buf: *std.c.Stat) c_int;
        extern "c" fn stat(path: [*:0]const u8, buf: *std.c.Stat) c_int;
    };

    /// stat a path. `follow` = false is lstat (do not follow symlinks).
    /// Returns null when the path cannot be stat'd, for any reason.
    pub fn statPath(pathz: [*:0]const u8, follow: bool) ?FileStat {
        if (builtin.os.tag == .linux) {
            const linux = std.os.linux;
            var st: linux.Statx = undefined;
            const mask: linux.STATX = .{ .TYPE = true, .MODE = true, .UID = true, .GID = true, .INO = true, .MTIME = true };
            const flags: u32 = if (follow) 0 else linux.AT.SYMLINK_NOFOLLOW;
            if (linux.statx(linux.AT.FDCWD, pathz, flags, mask, &st) != 0) return null;
            return .{
                // statx splits the device into major/minor; recombine so the
                // field means the same thing as st_dev does elsewhere.
                .dev = (@as(u64, st.dev_major) << 32) | @as(u64, st.dev_minor),
                .ino = st.ino,
                .uid = st.uid,
                .gid = st.gid,
                .mode = st.mode,
                .mtime_ns = @as(i128, st.mtime.sec) * std.time.ns_per_s + @as(i128, st.mtime.nsec),
            };
        }
        var cst: std.c.Stat = undefined;
        const rc = if (follow) libc.stat(pathz, &cst) else libc.lstat(pathz, &cst);
        if (rc != 0) return null;
        const st = cst;
        const ts = st.mtime();
        return .{
            .dev = @intCast(@as(i64, st.dev)),
            .ino = @intCast(st.ino),
            .uid = st.uid,
            .gid = st.gid,
            .mode = st.mode,
            .mtime_ns = @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec),
        };
    }

    pub fn getpid() pid_t {
        return system.getpid();
    }

    /// Fill `buf` with cryptographically-strong random bytes. Used to make
    /// temp-file names unguessable so an attacker cannot pre-create or
    /// pre-symlink one (the security against a symlink clobber comes from
    /// O_EXCL; this closes the pre-creation DoS and any guessing). Best-effort:
    /// on failure the buffer is left as-is, and the O_EXCL create still fails
    /// closed on a collision.
    pub fn randomBytes(buf: []u8) void {
        if (builtin.os.tag == .linux) {
            var off: usize = 0;
            while (off < buf.len) {
                const rc = std.os.linux.getrandom(buf[off..].ptr, buf.len - off, 0);
                const n: isize = @bitCast(rc);
                if (n <= 0) return;
                off += @intCast(n);
            }
        } else {
            std.crypto.random.bytes(buf);
        }
    }

    // libc-backed and therefore portable, unlike the raw std.os.linux syscall
    // wrappers these replaced. A raw `syscall1(.getpgid, 0)` compiles for any
    // target but emits a Linux syscall, so it is wrong at runtime everywhere
    // else rather than failing to build.

    // Zig 0.16 has no std.c binding for these two, so declare them. Going
    // through libc rather than a raw syscall is what makes them portable: a
    // std.os.linux.syscall1 compiles for any target but emits a Linux syscall,
    // so it is silently wrong elsewhere instead of failing to build.
    extern "c" fn getpgid(pid: pid_t) pid_t;
    extern "c" fn wait4(pid: pid_t, status: ?*c_int, options: c_int, usage: ?*anyopaque) pid_t;

    pub fn getProcessGroup(pid: pid_t) pid_t {
        return getpgid(pid);
    }

    pub fn geteuid() std.posix.uid_t {
        return system.geteuid();
    }

    pub fn getegid() std.posix.gid_t {
        return system.getegid();
    }

    /// waitpid plus resource usage. Used by the `time` builtin.
    pub fn waitRusage(pid: pid_t, status: *u32, options: u32, usage: ?*anyopaque) pid_t {
        return wait4(pid, @ptrCast(status), @intCast(options), usage);
    }

    pub fn exit(status: u8) noreturn {
        std.c.exit(status);
    }

    pub const ForkError = error{ SystemResources, Unexpected };

    pub fn fork() ForkError!pid_t {
        const rc = system.fork();
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .AGAIN => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            else => |err| return unexpectedErrno(err),
        }
    }

    pub const WaitPidResult = struct {
        pid: pid_t,
        status: u32,
    };

    pub fn waitpid(pid: pid_t, flags: u32) WaitPidResult {
        var status: c_int = undefined;
        while (true) {
            const rc = system.waitpid(pid, &status, @intCast(flags));
            switch (errno(rc)) {
                .SUCCESS => return .{ .pid = @intCast(rc), .status = @bitCast(status) },
                .INTR => continue,
                // No (more) children. Callers signal this via pid <= 0 (e.g. the
                // `wait` builtin's reap loop); crashing here aborted the whole
                // shell on `sleep 0.1 & wait`.
                .CHILD => return .{ .pid = -1, .status = 0 },
                .INVAL => unreachable, // invalid flags (we only pass 0 / NOHANG)
                else => return .{ .pid = -1, .status = 0 },
            }
        }
    }

    pub const GetCwdError = error{ CurrentWorkingDirectoryUnlinked, NameTooLong, Unexpected };

    pub fn getcwd(out_buffer: []u8) GetCwdError![]u8 {
        const c_err = if (std.c.getcwd(out_buffer.ptr, out_buffer.len)) |_| 0 else std.c._errno().*;
        const err: E = @enumFromInt(c_err);
        switch (err) {
            .SUCCESS => return mem.sliceTo(out_buffer, 0),
            .FAULT => unreachable,
            .INVAL => unreachable,
            .NOENT => return error.CurrentWorkingDirectoryUnlinked,
            .RANGE => return error.NameTooLong,
            else => return unexpectedErrno(err),
        }
    }

    pub const ChangeCurDirError = error{
        AccessDenied,
        FileSystem,
        SymLinkLoop,
        NameTooLong,
        FileNotFound,
        SystemResources,
        NotDir,
        BadPathName,
        Unexpected,
    };

    pub fn chdir(dir_path: []const u8) ChangeCurDirError!void {
        const dir_path_c = toPosixPath(dir_path) catch return error.NameTooLong;
        return chdirZ(&dir_path_c);
    }

    pub fn chdirZ(dir_path: [*:0]const u8) ChangeCurDirError!void {
        switch (errno(system.chdir(dir_path))) {
            .SUCCESS => return,
            .ACCES => return error.AccessDenied,
            .FAULT => unreachable,
            .IO => return error.FileSystem,
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT => return error.FileNotFound,
            .NOMEM => return error.SystemResources,
            .NOTDIR => return error.NotDir,
            else => |err| return unexpectedErrno(err),
        }
    }

    pub const SetPgidError = error{
        ProcessAlreadyExec,
        InvalidProcessGroupId,
        PermissionDenied,
        ProcessNotFound,
        Unexpected,
    };

    pub fn setpgid(pid: pid_t, pgid: pid_t) SetPgidError!void {
        switch (errno(system.setpgid(pid, pgid))) {
            .SUCCESS => return,
            .ACCES => return error.ProcessAlreadyExec,
            .INVAL => return error.InvalidProcessGroupId,
            .PERM => return error.PermissionDenied,
            .SRCH => return error.ProcessNotFound,
            else => |err| return unexpectedErrno(err),
        }
    }

    pub const ExecveError = error{
        SystemResources,
        AccessDenied,
        PermissionDenied,
        InvalidExe,
        FileSystem,
        IsDir,
        FileNotFound,
        NotDir,
        FileBusy,
        ProcessFdQuotaExceeded,
        SystemFdQuotaExceeded,
        NameTooLong,
        Unexpected,
    };

    pub fn execveZ(
        path: [*:0]const u8,
        child_argv: [*:null]const ?[*:0]const u8,
        envp: [*:null]const ?[*:0]const u8,
    ) ExecveError {
        switch (errno(system.execve(path, child_argv, envp))) {
            .SUCCESS => unreachable,
            .FAULT => unreachable,
            .@"2BIG" => return error.SystemResources,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NAMETOOLONG => return error.NameTooLong,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .INVAL => return error.InvalidExe,
            .NOEXEC => return error.InvalidExe,
            .IO => return error.FileSystem,
            .LOOP => return error.FileSystem,
            .ISDIR => return error.IsDir,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .TXTBSY => return error.FileBusy,
            else => |err| {
                // ELIBBAD is Linux-only. Looked up by name rather than written
                // as `.LIBBAD` so this compiles on platforms whose errno enum
                // does not define it.
                const ErrT = @TypeOf(err);
                if (comptime @hasField(ErrT, "LIBBAD")) {
                    if (err == @field(ErrT, "LIBBAD")) return error.InvalidExe;
                }
                return unexpectedErrno(err);
            },
        }
    }

    pub fn execvpeZ(
        file: [*:0]const u8,
        argv_ptr: [*:null]const ?[*:0]const u8,
        envp: [*:null]const ?[*:0]const u8,
    ) ExecveError {
        const file_slice = mem.sliceTo(file, 0);
        if (mem.indexOfScalar(u8, file_slice, '/') != null) return execveZ(file, argv_ptr, envp);

        const PATH = getenvZ("PATH") orelse "/usr/local/bin:/bin/:/usr/bin";
        var path_buf: [PATH_MAX]u8 = undefined;
        var it = mem.tokenizeScalar(u8, PATH, ':');
        var seen_eacces = false;
        var err: ExecveError = error.FileNotFound;

        while (it.next()) |search_path| {
            const path_len = search_path.len + file_slice.len + 1;
            if (path_buf.len < path_len + 1) return error.NameTooLong;
            @memcpy(path_buf[0..search_path.len], search_path);
            path_buf[search_path.len] = '/';
            @memcpy(path_buf[search_path.len + 1 ..][0..file_slice.len], file_slice);
            path_buf[path_len] = 0;
            const full_path = path_buf[0..path_len :0].ptr;
            err = execveZ(full_path, argv_ptr, envp);
            switch (err) {
                error.AccessDenied => seen_eacces = true,
                error.FileNotFound, error.NotDir => {},
                else => |e| return e,
            }
        }
        if (seen_eacces) return error.AccessDenied;
        return err;
    }

    pub fn toPosixPath(file_path: []const u8) error{NameTooLong}![PATH_MAX - 1:0]u8 {
        var path_with_null: [PATH_MAX - 1:0]u8 = undefined;
        if (file_path.len >= PATH_MAX) return error.NameTooLong;
        @memcpy(path_with_null[0..file_path.len], file_path);
        path_with_null[file_path.len] = 0;
        return path_with_null;
    }
};

test "compat getenv finds PATH" {
    try std.testing.expect(posix.getenv("PATH") != null);
    try std.testing.expect(posix.getenv("ZISH_DEFINITELY_NOT_SET_12345") == null);
}

test "compat getcwd works" {
    var buf: [4096]u8 = undefined;
    const cwd = try posix.getcwd(&buf);
    try std.testing.expect(cwd.len > 0);
}
