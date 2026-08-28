// parallel - run a command over many inputs, N at a time.
//
//   parallel [-j N] CMD [ARG...] ::: item1 item2 ...     # items from args
//   printf '%s\n' a b c | parallel [-j N] CMD [ARG...]    # items from stdin
//
//   seq 1 100 | parallel -j8 gzip {}
//   parallel grep ERROR {} ::: *.log
//   ls *.jpg | parallel convert {} {}.png
//
// Why this is a feat, not a shell builtin: it is pure process orchestration —
// fork, exec, wait, across N slots. It needs nothing from the shell's internal
// state, and as a separate process a bug in it cannot corrupt the shell. It
// also inherits whatever sandbox the shell was started under (Landlock,
// seccomp), so every job it fans out is contained for free.
//
// Decisions, fixed once:
//   - {} in the command is replaced by the item; {#} by the 1-based job number.
//     With no {}, the item is appended (like xargs).
//   - The command is exec'd directly as argv — NO shell — so an item with
//     spaces or metacharacters is one argument and cannot inject. For a shell
//     command per job, write `parallel sh -c 'CMD {}' ::: ...` and quote it
//     yourself, deliberately.
//   - Output is GROUPED, not interleaved: each job's stdout+stderr goes to its
//     own temp file, copied out atomically when the job finishes, in input
//     order. Concurrent jobs never scramble each other's lines — the whole
//     reason to prefer this over a bare `cmd & cmd & wait` loop.
//   - Default parallelism is the CPU count; -j0 is unbounded.
//   - Exit status is the number of failed jobs, clamped to 125 (0 = all ok).
//
// Not in v1: {.}/{/}/{//} replacements, completion-order output, retries,
// remote execution, --halt-on-error. Each is a real feature; none is needed to
// be useful. PATH resolution and environment come from libc's execvp.

const std = @import("std");
const linux = std.os.linux;

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

const STDOUT = 1;
const STDERR = 2;
const STDIN = 0;
const SEEK_SET = 0;

fn failed(rc: usize) bool {
    return @as(isize, @bitCast(rc)) < 0;
}

const Job = struct {
    pid: i32 = -1,
    out_fd: i32 = -1,
    done: bool = false,
    failed: bool = false,
    printed: bool = false,
};

// Whether per-job output grouping is available. It needs a writable temp file;
// under a read-only sandbox (`zish --profile readonly`) /tmp is not writable, so
// grouping is impossible. Rather than fail, degrade: jobs inherit stdout/stderr
// directly and their output interleaves, but parallelism still works.
var group = true;

var rng: u64 = 0x9e3779b97f4a7c15;
fn rngNext() u64 {
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return rng;
}

fn writeStr(fd: i32, s: []const u8) void {
    var off: usize = 0;
    while (off < s.len) {
        const rc = linux.write(fd, s.ptr + off, s.len - off);
        if (failed(rc)) return;
        const n: usize = @intCast(@as(isize, @bitCast(rc)));
        if (n == 0) return;
        off += n;
    }
}

fn die(msg: []const u8) noreturn {
    writeStr(STDERR, "parallel: ");
    writeStr(STDERR, msg);
    writeStr(STDERR, "\n");
    linux.exit(2);
}

/// Unlinked temp file: O_EXCL + random name + immediate unlink. No on-disk
/// artifact, no symlink window; the fd keeps the inode alive.
fn makeTempFile() !i32 {
    var name: [64]u8 = undefined;
    var attempt: u8 = 0;
    while (true) {
        const path = std.fmt.bufPrintZ(&name, "/tmp/zish_parallel_{x}", .{rngNext()}) catch return error.NameTooLong;
        const flags = linux.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true };
        const rc = linux.open(path.ptr, flags, 0o600);
        if (!failed(rc)) {
            const fd: i32 = @intCast(@as(isize, @bitCast(rc)));
            _ = linux.unlink(path.ptr);
            return fd;
        }
        attempt += 1;
        if (attempt >= 8) return error.OpenFailed;
    }
}

fn buildArgv(
    arena: std.mem.Allocator,
    template: []const []const u8,
    item: []const u8,
    job_no: usize,
) ![:null]?[*:0]const u8 {
    var out = std.ArrayList(?[*:0]const u8).empty;
    var saw_brace = false;
    var num_buf: [20]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{job_no}) catch "0";

    for (template) |tok| {
        const has_item = std.mem.indexOf(u8, tok, "{}") != null;
        const has_num = std.mem.indexOf(u8, tok, "{#}") != null;
        if (has_item or has_num) {
            if (has_item) saw_brace = true;
            var acc = std.ArrayList(u8).empty;
            var i: usize = 0;
            while (i < tok.len) {
                if (i + 1 < tok.len and tok[i] == '{' and tok[i + 1] == '}') {
                    try acc.appendSlice(arena, item);
                    i += 2;
                } else if (i + 2 < tok.len and tok[i] == '{' and tok[i + 1] == '#' and tok[i + 2] == '}') {
                    try acc.appendSlice(arena, num_str);
                    i += 3;
                } else {
                    try acc.append(arena, tok[i]);
                    i += 1;
                }
            }
            try out.append(arena, try arena.dupeZ(u8, acc.items));
        } else {
            try out.append(arena, try arena.dupeZ(u8, tok));
        }
    }
    if (!saw_brace) try out.append(arena, try arena.dupeZ(u8, item));
    try out.append(arena, null);
    const slice = try out.toOwnedSlice(arena);
    return slice[0 .. slice.len - 1 :null];
}

pub fn main(init: std.process.Init) void {
    const alloc = init.gpa;
    const args = init.minimal.args.toSlice(alloc) catch die("out of memory");

    var seed: [8]u8 = undefined;
    _ = linux.getrandom(&seed, seed.len, 0);
    rng ^= std.mem.readInt(u64, &seed, .little);
    rng ^= @as(u64, @bitCast(@as(i64, linux.getpid()))) << 20;

    // options
    var jobs: usize = 0;
    var jobs_set = false;
    var idx: usize = 1;
    while (idx < args.len) : (idx += 1) {
        const a = args[idx];
        if (std.mem.eql(u8, a, "--")) {
            idx += 1;
            break;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            writeStr(STDOUT, help_text);
            return;
        } else if (std.mem.eql(u8, a, "-j")) {
            idx += 1;
            if (idx >= args.len) die("-j needs a number");
            jobs = std.fmt.parseInt(usize, args[idx], 10) catch die("-j needs a number");
            jobs_set = true;
        } else if (std.mem.startsWith(u8, a, "-j")) {
            jobs = std.fmt.parseInt(usize, a[2..], 10) catch die("-j needs a number");
            jobs_set = true;
        } else if (a.len > 1 and a[0] == '-' and a[1] != '-') {
            die("unknown option (only -j N and -- are supported)");
        } else break;
    }

    var template = std.ArrayList([]const u8).empty;
    var arg_items = std.ArrayList([]const u8).empty;
    var in_items = false;
    while (idx < args.len) : (idx += 1) {
        if (!in_items and std.mem.eql(u8, args[idx], ":::")) {
            in_items = true;
            continue;
        }
        (if (in_items) &arg_items else &template).append(alloc, args[idx]) catch die("out of memory");
    }
    if (template.items.len == 0) die("no command given");

    if (!jobs_set) jobs = std.Thread.getCpuCount() catch 4;
    if (jobs == 0) jobs = std.math.maxInt(usize);

    var items = std.ArrayList([]const u8).empty;
    if (in_items or arg_items.items.len > 0) {
        items.appendSlice(alloc, arg_items.items) catch die("out of memory");
    } else {
        readStdinItems(alloc, &items) catch die("reading stdin");
    }
    if (items.items.len == 0) return;

    // Probe once whether we can create a scratch temp file. If not (read-only
    // sandbox), run ungrouped rather than failing.
    if (makeTempFile()) |fd| {
        _ = linux.close(fd);
    } else |_| {
        group = false;
    }

    runAll(alloc, template.items, items.items, jobs) catch die("out of memory");
}

fn readStdinItems(alloc: std.mem.Allocator, items: *std.ArrayList([]const u8)) !void {
    var buf: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const rc = linux.read(STDIN, &chunk, chunk.len);
        if (failed(rc)) break;
        const n: usize = @intCast(@as(isize, @bitCast(rc)));
        if (n == 0) break;
        try buf.appendSlice(alloc, chunk[0..n]);
    }
    var it = std.mem.splitScalar(u8, buf.items, '\n');
    while (it.next()) |line| {
        const t = std.mem.trimEnd(u8, line, "\r");
        if (t.len == 0) continue;
        try items.append(alloc, t);
    }
}

fn runAll(alloc: std.mem.Allocator, template: []const []const u8, items: []const []const u8, max_parallel: usize) !void {
    const jobs = try alloc.alloc(Job, items.len);
    for (jobs) |*j| j.* = .{};

    var launched: usize = 0;
    var active: usize = 0;
    var reaped: usize = 0;
    var next_print: usize = 0;
    var failures: usize = 0;

    while (reaped < items.len) {
        while (active < max_parallel and launched < items.len) {
            try launchJob(alloc, &jobs[launched], template, items[launched], launched + 1);
            launched += 1;
            active += 1;
        }
        var status: u32 = 0;
        const wrc = linux.waitpid(-1, &status, 0);
        if (failed(wrc)) break;
        const wpid: i32 = @intCast(@as(isize, @bitCast(wrc)));
        for (jobs[0..launched]) |*j| {
            if (j.pid == wpid and !j.done) {
                j.done = true;
                j.failed = !(linux.W.IFEXITED(status) and linux.W.EXITSTATUS(status) == 0);
                if (j.failed) failures += 1;
                active -= 1;
                reaped += 1;
                break;
            }
        }
        while (next_print < items.len and jobs[next_print].done and !jobs[next_print].printed) {
            flushJob(&jobs[next_print]);
            next_print += 1;
        }
    }
    while (next_print < items.len) : (next_print += 1) {
        if (jobs[next_print].done and !jobs[next_print].printed) flushJob(&jobs[next_print]);
    }
    linux.exit(@intCast(@min(failures, 125)));
}

fn launchJob(alloc: std.mem.Allocator, job: *Job, template: []const []const u8, item: []const u8, job_no: usize) !void {
    // In grouped mode each job writes to its own temp file; ungrouped, it
    // inherits our stdout/stderr (out_fd stays -1 and flushJob is a no-op).
    const fd: i32 = if (group) (makeTempFile() catch -1) else -1;
    var arena = std.heap.ArenaAllocator.init(alloc);
    const argv = try buildArgv(arena.allocator(), template, item, job_no);

    const frc = linux.fork();
    if (failed(frc)) {
        arena.deinit();
        if (fd >= 0) _ = linux.close(fd);
        return error.ForkFailed;
    }
    const pid: i32 = @intCast(@as(isize, @bitCast(frc)));
    if (pid == 0) {
        if (fd >= 0) {
            // Group stdout+stderr into the temp file.
            _ = linux.dup2(fd, STDOUT);
            _ = linux.dup2(fd, STDERR);
        }
        _ = execvp(argv[0].?, argv.ptr);
        linux.exit(127); // exec failed
    }
    arena.deinit();
    job.* = .{ .pid = pid, .out_fd = fd };
}

fn flushJob(job: *Job) void {
    job.printed = true;
    if (job.out_fd < 0) return; // ungrouped: output already went to stdout live
    _ = linux.lseek(job.out_fd, 0, SEEK_SET);
    var buf: [8192]u8 = undefined;
    while (true) {
        const rc = linux.read(job.out_fd, &buf, buf.len);
        if (failed(rc)) break;
        const n: usize = @intCast(@as(isize, @bitCast(rc)));
        if (n == 0) break;
        writeStr(STDOUT, buf[0..n]);
    }
    _ = linux.close(job.out_fd);
}

const help_text =
    \\usage: parallel [-j N] CMD [ARG...] ::: item...
    \\       ... | parallel [-j N] CMD [ARG...]
    \\
    \\Run CMD once per item, up to N at a time (default: CPU count; -j0 = unbounded).
    \\{} in CMD is replaced by the item; {#} by the job number. With no {}, the item
    \\is appended. CMD is exec'd directly (no shell): an item is always one argument.
    \\Output is grouped per job, in input order. Exit status = number of failed jobs.
    \\
    \\  seq 1 100 | parallel -j8 gzip {}
    \\  parallel grep ERROR {} ::: *.log
    \\
;
