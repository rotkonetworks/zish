// git.zig - git integration for prompt and completion
const std = @import("std");
const compat = @import("compat.zig");

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
