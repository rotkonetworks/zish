// git.zig - git integration for prompt and completion
const std = @import("std");
const compat = @import("compat.zig");

pub const GitInfo = struct {
    branch: []const u8,
    commit: []const u8,
    dirty: bool,
    staged: bool,
    owns_branch: bool,

    pub fn deinit(self: *GitInfo, allocator: std.mem.Allocator) void {
        if (self.owns_branch and self.branch.len > 0) allocator.free(self.branch);
        if (self.commit.len > 0) allocator.free(self.commit);
    }
};

pub const GitStatus = struct {
    modified: std.ArrayListUnmanaged([]const u8),
    deleted: std.ArrayListUnmanaged([]const u8),
    untracked: std.ArrayListUnmanaged([]const u8),
    staged: std.ArrayListUnmanaged([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GitStatus {
        return .{
            .modified = .empty,
            .deleted = .empty,
            .untracked = .empty,
            .staged = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GitStatus) void {
        for (self.modified.items) |item| self.allocator.free(item);
        for (self.deleted.items) |item| self.allocator.free(item);
        for (self.untracked.items) |item| self.allocator.free(item);
        for (self.staged.items) |item| self.allocator.free(item);
        self.modified.deinit(self.allocator);
        self.deleted.deinit(self.allocator);
        self.untracked.deinit(self.allocator);
        self.staged.deinit(self.allocator);
    }
};

/// get basic git info for prompt (branch, commit, dirty)
pub fn getInfo(allocator: std.mem.Allocator) ?GitInfo {
    // read HEAD for branch/commit
    const head_file = std.Io.Dir.cwd().openFile(compat.io(), ".git/HEAD", .{}) catch return null;
    defer head_file.close(compat.io());

    var head_buf: [256]u8 = undefined;
    const head_len = compat.readAll(head_file, &head_buf) catch return null;
    const head_content = std.mem.trim(u8, head_buf[0..head_len], " \t\r\n");

    var branch: []const u8 = "HEAD";
    var commit: []const u8 = "";
    var owns_branch: bool = false;

    if (std.mem.startsWith(u8, head_content, "ref: refs/heads/")) {
        if (allocator.dupe(u8, head_content[16..])) |owned| {
            branch = owned;
            owns_branch = true;
        } else |_| {
            branch = "HEAD";
        }

        // read commit from refs/heads/<branch>
        var ref_path_buf: [512]u8 = undefined;
        const ref_path = std.fmt.bufPrint(&ref_path_buf, ".git/refs/heads/{s}", .{branch}) catch return null;

        if (std.Io.Dir.cwd().openFile(compat.io(), ref_path, .{})) |ref_file| {
            defer ref_file.close(compat.io());
            var commit_buf: [64]u8 = undefined;
            const commit_len = compat.readAll(ref_file, &commit_buf) catch 0;
            if (commit_len >= 7) {
                commit = allocator.dupe(u8, commit_buf[0..7]) catch "";
            }
        } else |_| {
            // might be in packed-refs, just skip commit for now
        }
    } else if (head_content.len >= 7) {
        // detached HEAD
        commit = allocator.dupe(u8, head_content[0..7]) catch "";
        branch = "detached";
    }

    // check dirty: compare index mtime vs HEAD commit time
    const dirty = blk: {
        const index_stat = std.Io.Dir.cwd().statFile(compat.io(), ".git/index", .{}) catch break :blk false;
        const head_stat = std.Io.Dir.cwd().statFile(compat.io(), ".git/HEAD", .{}) catch break :blk false;
        break :blk index_stat.mtime.nanoseconds > head_stat.mtime.nanoseconds;
    };

    return GitInfo{
        .branch = branch,
        .commit = commit,
        .dirty = dirty,
        .staged = false,
        .owns_branch = owns_branch,
    };
}

/// get git status for completion (modified, deleted, untracked files)
pub fn getStatus(allocator: std.mem.Allocator) ?GitStatus {
    // run git status --porcelain
    var child = std.process.spawn(compat.io(), .{
        .argv = &.{ "git", "status", "--porcelain" },
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;

    var status = GitStatus.init(allocator);
    errdefer status.deinit();

    const stdout = child.stdout orelse return null;
    var buf: [4096]u8 = undefined;
    const len = compat.readAll(stdout, &buf) catch return null;

    // Close pipe before wait — prevents deadlock if output exceeds buffer
    if (child.stdout) |s| { s.close(compat.io()); child.stdout = null; }
    _ = child.wait(compat.io()) catch return null;

    // parse porcelain output
    var lines = std.mem.splitScalar(u8, buf[0..len], '\n');
    while (lines.next()) |line| {
        if (line.len < 3) continue;

        const status_code = line[0..2];
        const file = std.mem.trim(u8, line[3..], " ");
        if (file.len == 0) continue;

        const file_copy = allocator.dupe(u8, file) catch continue;

        if (status_code[0] == '?') {
            status.untracked.append(allocator, file_copy) catch {
                allocator.free(file_copy);
            };
        } else if (status_code[0] == 'D' or status_code[1] == 'D') {
            status.deleted.append(allocator, file_copy) catch {
                allocator.free(file_copy);
            };
        } else if (status_code[0] == 'M' or status_code[1] == 'M') {
            status.modified.append(allocator, file_copy) catch {
                allocator.free(file_copy);
            };
        } else if (status_code[0] == 'A') {
            status.staged.append(allocator, file_copy) catch {
                allocator.free(file_copy);
            };
        } else {
            allocator.free(file_copy);
        }
    }

    return status;
}

/// check if in a git repo
pub fn isRepo() bool {
    const dir = std.Io.Dir.cwd().openDir(compat.io(), ".git", .{}) catch return false;
    dir.close(compat.io());
    return true;
}
