// completion.zig - Tab completion logic for zish
const std = @import("std");
const compat = @import("compat.zig");
const Shell = @import("Shell.zig");
const tty = @import("tty.zig");
const git = @import("git.zig");
const editor = @import("editor.zig");
const input_mod = @import("input.zig");
const keywords = @import("keywords.zig");
const hist = @import("history.zig");

// ============================================================
// CompletionState: all completion-related fields, grouped.
// Lives in Shell as `completion: CompletionState`.
// ============================================================

pub const CompletionState = struct {
    mode: bool = false,
    matches: std.ArrayList([]const u8),
    index: usize = 0,
    word_start: usize = 0,
    word_end: usize = 0,
    original_len: usize = 0,
    pattern_len: usize = 0,
    menu_lines: usize = 0,
    displayed: bool = false,
    skip_next_slash: bool = false,

    pub fn init() CompletionState {
        return .{
            .matches = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 },
        };
    }

    pub fn deinit(self: *CompletionState, allocator: std.mem.Allocator) void {
        for (self.matches.items) |match| {
            allocator.free(match);
        }
        self.matches.deinit(allocator);
        self.mode = false;
        self.index = 0;
        self.displayed = false;
        self.menu_lines = 0;
        self.pattern_len = 0;
        self.skip_next_slash = false;
    }
};

pub const CacheState = struct {
    // flag completion cache (one command at a time, TTL 5 min)
    flag_cmd: [64]u8 = undefined,
    flag_cmd_len: usize = 0,
    flag_buf: [8192]u8 = undefined,
    flag_offsets: [256]u16 = undefined,
    flag_lens: [256]u8 = undefined,
    flag_count: usize = 0,
    flag_ts: i64 = 0,
    // flag description cache (parallel to flags)
    flag_desc_buf: [16384]u8 = undefined,
    flag_desc_offsets: [256]u16 = undefined,
    flag_desc_lens: [256]u8 = undefined,
    // subcommand completion cache (one command at a time, TTL 5 min)
    subcmd_cmd: [32]u8 = undefined,
    subcmd_cmd_len: usize = 0,
    subcmd_buf: [4096]u8 = undefined,
    subcmd_offsets: [128]u16 = undefined,
    subcmd_lens: [128]u8 = undefined,
    subcmd_count: usize = 0,
    subcmd_ts: i64 = 0,
};

pub const WordResult = struct {
    word: []const u8,
    start: usize,
    end: usize,
};

pub const CycleDirection = input_mod.CycleDirection;

/// Alphabetical string comparator for sorting completion matches.
const StringOrder = struct {
    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.order(u8, a, b) == .lt;
    }
};

/// Extract word at cursor position from command string.
/// Recognizes redirect operators (>, >>, <, 2>, 2>>, &>, &>>) at word boundaries
/// and strips them so the word contains only the filename part.
pub fn extractWordAtCursor(cmd: []const u8, cursor: usize) ?WordResult {
    if (cmd.len == 0) return null;

    var start = cursor;
    var end = cursor;

    while (start > 0 and cmd[start - 1] != ' ') start -= 1;
    while (end < cmd.len and cmd[end] != ' ') end += 1;

    // Strip leading redirect operators: &>>, &>, 2>>, 2>, >>, >
    var s = start;
    if (s < end) {
        if (s + 1 < end and cmd[s] == '&' and cmd[s + 1] == '>') {
            s += 2;
            if (s < end and cmd[s] == '>') s += 1; // &>>
        } else if (s + 1 < end and cmd[s] == '2' and cmd[s + 1] == '>') {
            s += 2;
            if (s < end and cmd[s] == '>') s += 1; // 2>>
        } else if (cmd[s] == '>') {
            s += 1;
            if (s < end and cmd[s] == '>') s += 1; // >>
        } else if (cmd[s] == '<') {
            s += 1;
        }
    }

    return WordResult{ .word = cmd[s..end], .start = s, .end = end };
}

/// Escape shell special characters in a filename for safe insertion
fn escapeForShell(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    // O(1) lookup table for chars needing escape (comptime generated)
    const escape_table: [256]bool = comptime blk: {
        var table = [_]bool{false} ** 256;
        // space, tab, newline, carriage return
        for (" \t\n\r") |c| table[c] = true;
        // quotes and backslash
        for ("'\"\\") |c| table[c] = true;
        // brackets and braces
        for ("()[]{}") |c| table[c] = true;
        // shell operators
        for ("$&;|<>") |c| table[c] = true;
        // glob and misc
        for ("*?!#~`") |c| table[c] = true;
        break :blk table;
    };

    // count escapes needed - O(n) with O(1) lookup
    var escape_count: usize = 0;
    for (input) |c| {
        if (escape_table[c]) escape_count += 1;
    }

    if (escape_count == 0) return allocator.dupe(u8, input);

    // allocate and escape
    const result = try allocator.alloc(u8, input.len + escape_count);
    var i: usize = 0;
    for (input) |c| {
        if (escape_table[c]) {
            result[i] = '\\';
            i += 1;
        }
        result[i] = c;
        i += 1;
    }
    return result;
}

pub fn handleTabCompletion(self: *Shell) !void {
    if (self.edit_buf.len == 0) return;

    const cmd = self.edit_buf.slice();
    const word_result = extractWordAtCursor(cmd, self.edit_buf.cursor) orelse return;
    const word = word_result.word;
    const word_end = word_result.end;

    // feat builtin completion (subcommands + feat names)
    if (try tryFeatCompletion(self, cmd, word_result)) return;

    // check for git-aware completion
    if (try tryGitCompletion(self, cmd, word_result)) return;

    // check if we're completing a command (first word or after pipe/semicolon, no path separators)
    const is_command_position = blk: {
        if (std.mem.indexOf(u8, word, "/") != null) break :blk false;
        if (word_result.start == 0) break :blk true;
        // check if preceded by | or ; or && or ||
        var i = word_result.start;
        while (i > 0 and (cmd[i - 1] == ' ' or cmd[i - 1] == '\t')) i -= 1;
        if (i > 0 and (cmd[i - 1] == '|' or cmd[i - 1] == ';')) break :blk true;
        if (i > 1 and cmd[i - 2] == '&' and cmd[i - 1] == '&') break :blk true;
        break :blk false;
    };
    // detect if we're specifically after a pipe for pipe-aware suggestions
    const is_after_pipe = blk: {
        var i = word_result.start;
        while (i > 0 and (cmd[i - 1] == ' ' or cmd[i - 1] == '\t')) i -= 1;
        break :blk (i > 0 and cmd[i - 1] == '|');
    };

    if (is_command_position and word.len > 0) {
        if (try tryCommandCompletion(self, word_result)) return;
    }

    // pipe completion: suggest common pipe targets when typing after |
    if (is_after_pipe and word.len <= 3) {
        if (try tryPipeCompletion(self, word_result)) return;
    }

    // check for variable completion ($VAR)
    if (word.len > 0 and word[0] == '$') {
        if (try tryVariableCompletion(self, word_result)) return;
    }

    // check for subcommand completion (e.g., docker run, cargo build)
    if (word.len > 0 and word[0] != '-' and !is_command_position) {
        if (try trySubcommandCompletion(self, cmd, word_result)) return;
    }

    // check for flag completion (--flag or -f)
    if (word.len > 0 and word[0] == '-' and !is_command_position) {
        if (try tryFlagCompletion(self, cmd, word_result)) return;
    }

    // check for SSH host completion (ssh/scp/rsync + non-flag argument)
    if (!is_command_position and word.len > 0 and word[0] != '-' and word[0] != '/' and word[0] != '.') {
        if (try tryHostCompletion(self, cmd, word_result)) return;
    }

    // check for kill process/signal completion
    if (!is_command_position) {
        if (try tryKillCompletion(self, cmd, word_result)) return;
    }

    // check for make/just target completion
    if (!is_command_position and word.len > 0 and word[0] != '-') {
        if (try tryMakeCompletion(self, cmd, word_result)) return;
        if (try tryJustCompletion(self, cmd, word_result)) return;
    }

    // check for systemctl unit completion
    if (!is_command_position and word.len > 0 and word[0] != '-') {
        if (try trySystemctlCompletion(self, cmd, word_result)) return;
    }

    // check for docker container/image completion
    if (!is_command_position and word.len > 0 and word[0] != '-') {
        if (try tryDockerCompletion(self, cmd, word_result)) return;
    }

    // project-aware completions: zig build targets, cargo bins, npm scripts
    if (!is_command_position and word.len > 0 and word[0] != '-') {
        if (try tryProjectCompletion(self, cmd, word_result)) return;
    }

    // check for history-based completion (full command line prefix match)
    if (is_command_position and word.len >= 2) {
        if (try tryHistoryCompletion(self, cmd)) return;
    }

    // determine base directory and search pattern
    var expanded_dir_buf: [4096]u8 = undefined;
    var expanded_word_buf: [4096]u8 = undefined;

    // track if we inserted a / for directory completion
    var inserted_slash = false;
    var effective_word_end = word_end;

    // check if word (without trailing /) is an existing directory
    // if so, insert / and treat it as if it had trailing / to complete inside
    const effective_word: []const u8 = blk: {
        if (word.len == 0 or std.mem.endsWith(u8, word, "/")) break :blk word;

        // expand ~ for directory check
        const check_path: []const u8 = if (std.mem.startsWith(u8, word, "~")) inner: {
            const home = compat.getEnvVarOwned(self.allocator, "HOME") catch break :blk word;
            defer self.allocator.free(home);
            const rest = word[1..];
            if (home.len + rest.len < expanded_word_buf.len) {
                @memcpy(expanded_word_buf[0..home.len], home);
                @memcpy(expanded_word_buf[home.len..][0..rest.len], rest);
                break :inner expanded_word_buf[0 .. home.len + rest.len];
            }
            break :blk word;
        } else word;

        // check if it's a directory by trying to open it (more reliable than stat)
        var d = std.Io.Dir.cwd().openDir(compat.io(), check_path, .{}) catch break :blk word;
        d.close(compat.io());

        // Before auto-inserting /, check if sibling entries also match this prefix.
        // e.g. typing "papi" with both "papi/" and "papi-console/" should show menu,
        // not descend into papi/.
        const has_siblings = blk2: {
            const parent_dir = if (std.mem.lastIndexOf(u8, check_path, "/")) |slash|
                check_path[0..slash]
            else
                ".";
            const basename = if (std.mem.lastIndexOf(u8, word, "/")) |slash|
                word[slash + 1 ..]
            else
                word;
            var pd = std.Io.Dir.cwd().openDir(compat.io(), parent_dir, .{ .iterate = true }) catch break :blk2 false;
            defer pd.close(compat.io());
            var it = pd.iterate();
            var sibling_count: u8 = 0;
            while (it.next(compat.io()) catch null) |entry| {
                if (entry.name.len > basename.len and std.mem.startsWith(u8, entry.name, basename)) {
                    sibling_count += 1;
                    if (sibling_count > 0) break :blk2 true;
                }
            }
            break :blk2 false;
        };

        if (has_siblings) {
            // Don't descend — let the parent directory completion find both matches
            break :blk word;
        }

        // Only match: insert / and descend into the directory
        self.edit_buf.cursor = @intCast(word_end);
        _ = self.edit_buf.insertSlice("/");
        effective_word_end = word_end + 1;
        inserted_slash = true;
        self.completion.skip_next_slash = true;

        if (word.len + 1 < expanded_word_buf.len) {
            @memcpy(expanded_word_buf[0..word.len], word);
            expanded_word_buf[word.len] = '/';
            break :blk expanded_word_buf[0 .. word.len + 1];
        }
        break :blk word;
    };

    const search_dir: []const u8 = if (std.mem.lastIndexOf(u8, effective_word, "/")) |last_slash| blk: {
        if (last_slash == 0) {
            break :blk "/";
        } else {
            const dir_part = effective_word[0..last_slash];
            if (std.mem.startsWith(u8, dir_part, "~")) {
                const home = compat.getEnvVarOwned(self.allocator, "HOME") catch break :blk dir_part;
                defer self.allocator.free(home);
                const rest = dir_part[1..];
                const expanded_len = home.len + rest.len;
                if (expanded_len < expanded_dir_buf.len) {
                    @memcpy(expanded_dir_buf[0..home.len], home);
                    @memcpy(expanded_dir_buf[home.len..expanded_len], rest);
                    break :blk expanded_dir_buf[0..expanded_len];
                }
            }
            break :blk dir_part;
        }
    } else if (std.mem.eql(u8, effective_word, "~")) blk: {
        const home = compat.getEnvVarOwned(self.allocator, "HOME") catch break :blk ".";
        defer self.allocator.free(home);
        if (home.len < expanded_dir_buf.len) {
            @memcpy(expanded_dir_buf[0..home.len], home);
            break :blk expanded_dir_buf[0..home.len];
        }
        break :blk ".";
    } else ".";

    const pattern = if (std.mem.lastIndexOf(u8, effective_word, "/")) |last_slash|
        effective_word[last_slash + 1 ..]
    else if (std.mem.eql(u8, effective_word, "~"))
        ""
    else
        effective_word;

    // find matches
    var matches = try std.ArrayList([]const u8).initCapacity(self.allocator, 16);
    defer {
        for (matches.items) |match| self.allocator.free(match);
        matches.deinit(self.allocator);
    }

    // collect existing arguments to filter out
    var existing_args = try std.ArrayList([]const u8).initCapacity(self.allocator, 16);
    defer existing_args.deinit(self.allocator);

    var arg_start: usize = 0;
    var in_arg = false;
    for (cmd, 0..) |c, idx| {
        if (c == ' ' or c == '\t' or c == '\n') {
            if (in_arg and idx > arg_start) {
                if (arg_start != word_result.start) {
                    existing_args.append(self.allocator, cmd[arg_start..idx]) catch {};
                }
            }
            in_arg = false;
        } else {
            if (!in_arg) {
                arg_start = idx;
                in_arg = true;
            }
        }
    }
    if (in_arg and arg_start != word_result.start and self.edit_buf.len > arg_start) {
        existing_args.append(self.allocator, cmd[arg_start..self.edit_buf.len]) catch {};
    }

    // detect if we're completing for cd/pushd (dirs only)
    const dirs_only = blk: {
        const t = std.mem.trimStart(u8, cmd, " \t");
        if (std.mem.startsWith(u8, t, "cd ") or std.mem.startsWith(u8, t, "pushd ") or
            std.mem.startsWith(u8, t, "mkdir ") or std.mem.startsWith(u8, t, "rmdir "))
            break :blk true;
        break :blk false;
    };

    var dir = std.Io.Dir.cwd().openDir(compat.io(), search_dir, .{ .iterate = true }) catch return;
    defer dir.close(compat.io());
    var iter = dir.iterate();
    const show_hidden = pattern.len > 0 and pattern[0] == '.';
    while (try iter.next(compat.io())) |entry| {
        // skip dotfiles unless pattern starts with .
        if (!show_hidden and entry.name.len > 0 and entry.name[0] == '.') continue;
        if (std.mem.startsWith(u8, entry.name, pattern)) {
            var already_exists = false;
            for (existing_args.items) |existing| {
                const existing_name = if (std.mem.lastIndexOf(u8, existing, "/")) |slash|
                    existing[slash + 1 ..]
                else
                    existing;

                if (std.mem.eql(u8, entry.name, existing_name)) {
                    already_exists = true;
                    break;
                }
                if (entry.kind == .directory) {
                    const with_slash = std.fmt.allocPrint(self.allocator, "{s}/", .{entry.name}) catch continue;
                    defer self.allocator.free(with_slash);
                    if (std.mem.eql(u8, with_slash, existing_name)) {
                        already_exists = true;
                        break;
                    }
                }
            }

            if (!already_exists) {
                // check if entry is a directory - stat for symlinks and unknown
                const is_dir = if (entry.kind == .directory)
                    true
                else if (entry.kind == .sym_link or entry.kind == .unknown) blk: {
                    // stat the entry to check if target is a directory
                    const full_path = std.fs.path.join(self.allocator, &.{ search_dir, entry.name }) catch break :blk false;
                    defer self.allocator.free(full_path);
                    var d = std.Io.Dir.cwd().openDir(compat.io(), full_path, .{}) catch break :blk false;
                    d.close(compat.io());
                    break :blk true;
                } else false;

                // skip non-directories for cd/pushd/mkdir/rmdir
                if (dirs_only and !is_dir) continue;

                const full_name = if (is_dir)
                    try std.fmt.allocPrint(self.allocator, "{s}/", .{entry.name})
                else
                    try self.allocator.dupe(u8, entry.name);
                try matches.append(self.allocator, full_name);
            }
        }
    }

    if (matches.items.len == 0) {
        // if we inserted a slash for directory, still need to render
        if (inserted_slash) {
            try self.renderLine();
        }
        // empty line hint if directory is empty
        if (pattern.len == 0 and std.mem.endsWith(u8, effective_word, "/")) {
            try self.stdout().writeAll("\n\n\x1b[2A");
            try self.stdout().flush();
        }
        return;
    } else if (matches.items.len == 1) {
        const match = matches.items[0];
        const comp_str = match[pattern.len..];
        // escape special characters for shell
        const escaped = try escapeForShell(self.allocator, comp_str);
        defer self.allocator.free(escaped);
        self.edit_buf.cursor = @intCast(effective_word_end);
        _ = self.edit_buf.insertSlice(escaped);
        // add trailing space for files (not directories)
        if (!std.mem.endsWith(u8, match, "/")) {
            _ = self.edit_buf.insertSlice(" ");
        }
        try self.renderLine();
    } else {
        // multiple matches - first try common prefix completion
        var common_prefix_len: usize = matches.items[0].len;
        for (matches.items[1..]) |match| {
            var i: usize = 0;
            while (i < common_prefix_len and i < match.len and matches.items[0][i] == match[i]) : (i += 1) {}
            common_prefix_len = i;
        }

        if (common_prefix_len > pattern.len) {
            const common_prefix = matches.items[0][0..common_prefix_len];
            const comp_str = common_prefix[pattern.len..];
            // escape special characters for shell
            const escaped = try escapeForShell(self.allocator, comp_str);
            defer self.allocator.free(escaped);
            self.edit_buf.cursor = @intCast(effective_word_end);
            const inserted = self.edit_buf.insertSlice(escaped);
            if (inserted > 0) {
                try self.renderLine();
            }
            return;
        }

        // common prefix equals pattern - enter completion mode
        exitCompletionMode(self);

        for (matches.items) |match| {
            const owned = try self.allocator.dupe(u8, match);
            try self.completion.matches.append(self.allocator, owned);
        }

        self.completion.mode = true;
        self.completion.index = self.completion.matches.items.len;
        self.completion.word_start = word_result.start;
        self.completion.word_end = effective_word_end;
        self.completion.original_len = self.edit_buf.len;
        self.completion.pattern_len = pattern.len;

        try self.renderLine();
        try displayCompletions(self);
    }
}

fn tryVariableCompletion(self: *Shell, word_result: WordResult) !bool {
    const word = word_result.word;
    if (word.len < 1 or word[0] != '$') return false;

    const pattern = word[1..]; // skip the $

    var matches = try std.ArrayList([]const u8).initCapacity(self.allocator, 32);
    defer {
        for (matches.items) |m| self.allocator.free(m);
        matches.deinit(self.allocator);
    }

    var seen = std.StringHashMap(void).init(self.allocator);
    defer seen.deinit();

    // get shell variables
    var var_iter = self.variables.iterator();
    while (var_iter.next()) |entry| {
        const name = entry.key_ptr.*;
        if (std.mem.startsWith(u8, name, pattern)) {
            const full = std.fmt.allocPrint(self.allocator, "${s}", .{name}) catch continue;
            seen.put(name, {}) catch {};
            matches.append(self.allocator, full) catch {
                self.allocator.free(full);
                continue;
            };
        }
    }

    // get environment variables
    var environ = std.c.environ;
    while (environ[0]) |env_ptr| : (environ += 1) {
        const env: [*:0]const u8 = env_ptr;
        var len: usize = 0;
        while (env[len] != 0) : (len += 1) {}
        const env_str = env[0..len];
        const eq_pos = std.mem.indexOfScalar(u8, env_str, '=') orelse continue;
        const name = env_str[0..eq_pos];
        if (name.len == 0) continue;
        if (seen.contains(name)) continue;
        if (std.mem.startsWith(u8, name, pattern)) {
            const full = std.fmt.allocPrint(self.allocator, "${s}", .{name}) catch continue;
            seen.put(name, {}) catch {};
            matches.append(self.allocator, full) catch {
                self.allocator.free(full);
                continue;
            };
        }
    }

    if (matches.items.len == 0) return false;

    std.mem.sort([]const u8, matches.items, {}, StringOrder.lessThan);

    if (matches.items.len == 1) {
        const match = matches.items[0];
        const comp_str = match[word.len..];
        self.edit_buf.cursor = @intCast(word_result.end);
        _ = self.edit_buf.insertSlice(comp_str);
        try self.renderLine();
        return true;
    } else {
        return try showCompletionMatches(self, &matches, word_result, word);
    }
}

fn tryHostCompletion(self: *Shell, cmd: []const u8, word_result: WordResult) !bool {
    // only complete hosts for ssh/scp/rsync/sftp commands
    const trimmed = std.mem.trimStart(u8, cmd, " \t");
    const cmd_end = std.mem.indexOfAny(u8, trimmed, " \t") orelse return false;
    const base_cmd = trimmed[0..cmd_end];
    const is_ssh_cmd = for ([_][]const u8{ "ssh", "scp", "rsync", "sftp", "sshfs", "mosh" }) |tool| {
        if (std.mem.eql(u8, base_cmd, tool)) break true;
    } else false;
    if (!is_ssh_cmd) return false;

    const pattern = word_result.word;

    var matches = try std.ArrayList([]const u8).initCapacity(self.allocator, 32);
    defer {
        for (matches.items) |m| self.allocator.free(m);
        matches.deinit(self.allocator);
    }

    var seen = std.StringHashMap(void).init(self.allocator);
    defer seen.deinit();

    // Parse ~/.ssh/config for Host entries
    if (compat.getEnvVarOwned(self.allocator, "HOME")) |home| {
        defer self.allocator.free(home);
        var path_buf: [512]u8 = undefined;

        // SSH config: Host lines
        const config_path = std.fmt.bufPrint(&path_buf, "{s}/.ssh/config", .{home}) catch "";
        if (config_path.len > 0) {
            if (std.Io.Dir.cwd().openFile(compat.io(), config_path, .{})) |file| {
                defer file.close(compat.io());
                var read_buf: [8192]u8 = undefined;
                const n = compat.posix.read(file.handle, &read_buf) catch 0;
                const text = read_buf[0..n];
                var line_start: usize = 0;
                while (line_start < text.len) {
                    const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
                    const line = std.mem.trimStart(u8, text[line_start..line_end], " \t");
                    line_start = line_end + 1;
                    // Match "Host " (case-insensitive)
                    if (line.len > 5 and (line[0] == 'H' or line[0] == 'h') and
                        (std.mem.startsWith(u8, line, "Host ") or std.mem.startsWith(u8, line, "host ")))
                    {
                        // Can have multiple hosts on one line
                        var rest = std.mem.trimStart(u8, line[5..], " \t");
                        while (rest.len > 0) {
                            const host_end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
                            const host = rest[0..host_end];
                            rest = if (host_end < rest.len) std.mem.trimStart(u8, rest[host_end..], " \t") else "";
                            // Skip wildcard patterns
                            if (std.mem.indexOf(u8, host, "*") != null) continue;
                            if (std.mem.indexOf(u8, host, "?") != null) continue;
                            if (host.len == 0) continue;
                            if (std.mem.startsWith(u8, host, pattern) and !seen.contains(host)) {
                                const owned = self.allocator.dupe(u8, host) catch continue;
                                seen.put(owned, {}) catch {};
                                matches.append(self.allocator, owned) catch {
                                    self.allocator.free(owned);
                                    continue;
                                };
                            }
                        }
                    }
                }
            } else |_| {}
        }

        // SSH known_hosts: hostname entries
        const known_path = std.fmt.bufPrint(&path_buf, "{s}/.ssh/known_hosts", .{home}) catch "";
        if (known_path.len > 0) {
            if (std.Io.Dir.cwd().openFile(compat.io(), known_path, .{})) |file| {
                defer file.close(compat.io());
                var read_buf: [32768]u8 = undefined;
                const n = compat.posix.read(file.handle, &read_buf) catch 0;
                const text = read_buf[0..n];
                var line_start: usize = 0;
                while (line_start < text.len) {
                    const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
                    const line = text[line_start..line_end];
                    line_start = line_end + 1;
                    if (line.len == 0 or line[0] == '#' or line[0] == '|') continue; // skip comments and hashed
                    // First field is comma-separated hostnames (may have [host]:port)
                    const field_end = std.mem.indexOfAny(u8, line, " \t") orelse continue;
                    const hosts_field = line[0..field_end];
                    var host_start: usize = 0;
                    while (host_start < hosts_field.len) {
                        const comma = std.mem.indexOfScalarPos(u8, hosts_field, host_start, ',') orelse hosts_field.len;
                        var host = hosts_field[host_start..comma];
                        host_start = comma + 1;
                        // Strip []:port notation
                        if (host.len > 0 and host[0] == '[') {
                            if (std.mem.indexOfScalar(u8, host, ']')) |close| {
                                host = host[1..close];
                            }
                        }
                        if (host.len == 0) continue;
                        if (std.mem.startsWith(u8, host, pattern) and !seen.contains(host)) {
                            const owned = self.allocator.dupe(u8, host) catch continue;
                            seen.put(owned, {}) catch {};
                            matches.append(self.allocator, owned) catch {
                                self.allocator.free(owned);
                                continue;
                            };
                        }
                    }
                }
            } else |_| {}
        }
    } else |_| {}

    if (matches.items.len == 0) return false;
    if (matches.items.len == 1) {
        return try applySingleCompletion(self, matches.items[0], word_result);
    } else {
        return try showCompletionMatches(self, &matches, word_result, pattern);
    }
}

fn tryKillCompletion(self: *Shell, cmd: []const u8, word_result: WordResult) !bool {
    const trimmed = std.mem.trimStart(u8, cmd, " \t");
    const cmd_end = std.mem.indexOfAny(u8, trimmed, " \t") orelse return false;
    const base_cmd = trimmed[0..cmd_end];
    if (!std.mem.eql(u8, base_cmd, "kill") and !std.mem.eql(u8, base_cmd, "killall")) return false;

    const word = word_result.word;

    // Signal completion: kill -<tab>
    if (word.len > 0 and word[0] == '-' and std.mem.eql(u8, base_cmd, "kill")) {
        const pattern = word[1..]; // strip leading -
        const signals = [_][]const u8{
            "HUP", "INT", "QUIT", "ILL", "TRAP", "ABRT", "BUS", "FPE",
            "KILL", "USR1", "SEGV", "USR2", "PIPE", "ALRM", "TERM",
            "STKFLT", "CHLD", "CONT", "STOP", "TSTP", "TTIN", "TTOU",
        };
        var matches = try std.ArrayList([]const u8).initCapacity(self.allocator, 16);
        defer {
            for (matches.items) |m| self.allocator.free(m);
            matches.deinit(self.allocator);
        }
        for (&signals) |sig| {
            if (pattern.len == 0 or std.mem.startsWith(u8, sig, pattern)) {
                const full = std.fmt.allocPrint(self.allocator, "-{s}", .{sig}) catch continue;
                matches.append(self.allocator, full) catch {
                    self.allocator.free(full);
                    continue;
                };
            }
        }
        if (matches.items.len == 0) return false;
        if (matches.items.len == 1) {
            return try applySingleCompletion(self, matches.items[0], word_result);
        }
        return try showCompletionMatches(self, &matches, word_result, word);
    }

    // Process name completion for killall
    if (std.mem.eql(u8, base_cmd, "killall") and word.len > 0) {
        // Use ps to get running process names
        var child = std.process.spawn(compat.io(), .{
            .argv = &.{ "/bin/sh", "-c", "ps -eo comm= 2>/dev/null | sort -u" },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch return false;

        const stdout = child.stdout.?;
        var read_buf: [8192]u8 = undefined;
        var total: usize = 0;
        while (total < read_buf.len) {
            const n = compat.posix.read(stdout.handle, read_buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        }
        if (child.stdout) |*s| { s.close(compat.io()); child.stdout = null; }
        _ = child.wait(compat.io()) catch {};

        var matches = try std.ArrayList([]const u8).initCapacity(self.allocator, 32);
        defer {
            for (matches.items) |m| self.allocator.free(m);
            matches.deinit(self.allocator);
        }

        const text = read_buf[0..total];
        var line_start: usize = 0;
        while (line_start < text.len) {
            const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
            const proc = std.mem.trim(u8, text[line_start..line_end], " \t\r");
            line_start = line_end + 1;
            if (proc.len == 0) continue;
            if (std.mem.startsWith(u8, proc, word)) {
                const owned = self.allocator.dupe(u8, proc) catch continue;
                matches.append(self.allocator, owned) catch {
                    self.allocator.free(owned);
                    continue;
                };
            }
        }

        if (matches.items.len == 0) return false;
        if (matches.items.len == 1) {
            return try applySingleCompletion(self, matches.items[0], word_result);
        }
        return try showCompletionMatches(self, &matches, word_result, word);
    }

    return false;
}

fn tryMakeCompletion(self: *Shell, cmd: []const u8, word_result: WordResult) !bool {
    // only complete targets for make/gmake
    const trimmed = std.mem.trimStart(u8, cmd, " \t");
    const cmd_end = std.mem.indexOfAny(u8, trimmed, " \t") orelse return false;
    const base_cmd = trimmed[0..cmd_end];
    if (!std.mem.eql(u8, base_cmd, "make") and !std.mem.eql(u8, base_cmd, "gmake")) return false;

    const pattern = word_result.word;

    // Check for -f flag to determine which makefile to parse
    var makefile_name: []const u8 = "Makefile";
    {
        var i: usize = cmd_end;
        while (i < cmd.len) {
            while (i < cmd.len and (cmd[i] == ' ' or cmd[i] == '\t')) i += 1;
            if (i + 1 < cmd.len and cmd[i] == '-' and cmd[i + 1] == 'f') {
                i += 2;
                while (i < cmd.len and (cmd[i] == ' ' or cmd[i] == '\t')) i += 1;
                const arg_start = i;
                while (i < cmd.len and cmd[i] != ' ' and cmd[i] != '\t') i += 1;
                if (i > arg_start) makefile_name = cmd[arg_start..i];
                break;
            }
            while (i < cmd.len and cmd[i] != ' ' and cmd[i] != '\t') i += 1;
        }
    }

    // Try Makefile, then makefile
    const file = std.Io.Dir.cwd().openFile(compat.io(), makefile_name, .{}) catch blk: {
        if (std.mem.eql(u8, makefile_name, "Makefile")) {
            break :blk std.Io.Dir.cwd().openFile(compat.io(), "makefile", .{}) catch return false;
        }
        return false;
    };
    defer file.close(compat.io());

    var read_buf: [32768]u8 = undefined;
    const n = compat.posix.read(file.handle, &read_buf) catch return false;
    const text = read_buf[0..n];

    var matches = try std.ArrayList([]const u8).initCapacity(self.allocator, 32);
    defer {
        for (matches.items) |m| self.allocator.free(m);
        matches.deinit(self.allocator);
    }

    var seen = std.StringHashMap(void).init(self.allocator);
    defer seen.deinit();

    // Parse target: lines — "target: deps" where target starts at column 0
    var line_start: usize = 0;
    while (line_start < text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
        const line = text[line_start..line_end];
        line_start = line_end + 1;

        // Skip empty, comments, tabs (recipe lines), variable assignments
        if (line.len == 0 or line[0] == '#' or line[0] == '\t' or line[0] == ' ') continue;
        if (line[0] == '.') continue; // skip .PHONY, .DEFAULT, etc

        // Find colon (but not ::= which is assignment)
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (colon == 0) continue;
        if (colon + 1 < line.len and line[colon + 1] == '=') continue; // := assignment
        if (colon > 0 and line[colon - 1] == '?') continue; // ?= through other path

        // Check for variable references in target name — skip those
        const target_part = line[0..colon];
        if (std.mem.indexOf(u8, target_part, "$") != null) continue;
        if (std.mem.indexOf(u8, target_part, "%") != null) continue; // pattern rules

        // Can have multiple targets: "foo bar: deps"
        var tstart: usize = 0;
        while (tstart < target_part.len) {
            while (tstart < target_part.len and (target_part[tstart] == ' ' or target_part[tstart] == '\t')) tstart += 1;
            const tend = std.mem.indexOfAnyPos(u8, target_part, tstart, " \t") orelse target_part.len;
            if (tend > tstart) {
                const target = target_part[tstart..tend];
                if (std.mem.startsWith(u8, target, pattern) and !seen.contains(target)) {
                    const owned = self.allocator.dupe(u8, target) catch continue;
                    seen.put(owned, {}) catch {};
                    matches.append(self.allocator, owned) catch {
                        self.allocator.free(owned);
                        continue;
                    };
                }
            }
            tstart = tend;
        }
    }

    if (matches.items.len == 0) return false;
    if (matches.items.len == 1) {
        return try applySingleCompletion(self, matches.items[0], word_result);
    }
    return try showCompletionMatches(self, &matches, word_result, pattern);
}

/// Complete `just` recipes from justfile
fn tryJustCompletion(self: *Shell, cmd: []const u8, word_result: WordResult) !bool {
    const trimmed = std.mem.trimStart(u8, cmd, " \t");
    if (!std.mem.startsWith(u8, trimmed, "just ") and !std.mem.eql(u8, trimmed, "just")) return false;
    const pattern = word_result.word;

    // Try justfile, then Justfile
    const file = std.Io.Dir.cwd().openFile(compat.io(), "justfile", .{}) catch
        std.Io.Dir.cwd().openFile(compat.io(), "Justfile", .{}) catch return false;
    defer file.close(compat.io());

    var read_buf: [16384]u8 = undefined;
    const n = compat.posix.read(file.handle, &read_buf) catch return false;
    const text = read_buf[0..n];

    var matches = try std.ArrayList([]const u8).initCapacity(self.allocator, 16);
    defer {
        for (matches.items) |m| self.allocator.free(m);
        matches.deinit(self.allocator);
    }

    // Parse recipes: lines starting with alpha at column 0, followed by ':'
    // justfile format: recipe_name arg1 arg2: deps
    var line_start: usize = 0;
    while (line_start < text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
        const line = text[line_start..line_end];
        line_start = line_end + 1;

        if (line.len == 0) continue;
        // recipes start at column 0 with alpha or @
        if (line[0] == ' ' or line[0] == '\t' or line[0] == '#') continue;

        // find recipe name (first word before space or colon)
        const name_start: usize = if (line[0] == '@') 1 else 0; // @ prefix for quiet
        var name_end = name_start;
        while (name_end < line.len and line[name_end] != ' ' and line[name_end] != ':' and line[name_end] != '(') : (name_end += 1) {}
        if (name_end <= name_start) continue;

        // verify there's a colon somewhere on this line (it's a recipe, not an assignment)
        if (std.mem.indexOfScalar(u8, line, ':') == null) continue;

        const name = line[name_start..name_end];
        // skip if it looks like a variable assignment
        if (std.mem.indexOf(u8, name, ":=") != null or std.mem.indexOf(u8, name, "=") != null) continue;

        if (std.mem.startsWith(u8, name, pattern)) {
            var dup = false;
            for (matches.items) |m| {
                if (std.mem.eql(u8, m, name)) { dup = true; break; }
            }
            if (!dup) {
                const owned = try self.allocator.dupe(u8, name);
                try matches.append(self.allocator, owned);
            }
        }
    }

    if (matches.items.len == 0) return false;
    if (matches.items.len == 1) return try applySingleCompletion(self, matches.items[0], word_result);
    return try showCompletionMatches(self, &matches, word_result, pattern);
}

fn trySystemctlCompletion(self: *Shell, cmd: []const u8, word_result: WordResult) !bool {
    // only for systemctl (+ journalctl -u) commands
    const trimmed = std.mem.trimStart(u8, cmd, " \t");
    const cmd_end = std.mem.indexOfAny(u8, trimmed, " \t") orelse return false;
    const base_cmd = trimmed[0..cmd_end];

    const is_systemctl = std.mem.eql(u8, base_cmd, "systemctl");
    const is_journalctl = std.mem.eql(u8, base_cmd, "journalctl");
    if (!is_systemctl and !is_journalctl) return false;

    // For journalctl, only complete after -u flag
    if (is_journalctl) {
        const rest = std.mem.trimStart(u8, trimmed[cmd_end..], " \t");
        // Check if the previous arg is -u
        var prev_is_u = false;
        var i: usize = 0;
        while (i < rest.len) {
            while (i < rest.len and (rest[i] == ' ' or rest[i] == '\t')) i += 1;
            const arg_start = i;
            while (i < rest.len and rest[i] != ' ' and rest[i] != '\t') i += 1;
            const arg = rest[arg_start..i];
            if (arg.ptr == word_result.word.ptr) break;
            prev_is_u = std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--unit");
        }
        if (!prev_is_u) return false;
    }

    const pattern = word_result.word;

    var matches = try std.ArrayList([]const u8).initCapacity(self.allocator, 32);
    defer {
        for (matches.items) |m| self.allocator.free(m);
        matches.deinit(self.allocator);
    }

    var seen = std.StringHashMap(void).init(self.allocator);
    defer seen.deinit();

    // Scan systemd unit directories
    const dirs = [_][]const u8{
        "/usr/lib/systemd/system",
        "/etc/systemd/system",
        "/run/systemd/system",
    };
    for (&dirs) |dir_path| {
        var dir = std.Io.Dir.cwd().openDir(compat.io(), dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(compat.io());
        var iter = dir.iterate();
        while (try iter.next(compat.io())) |entry| {
            const name = entry.name;
            // Only .service, .timer, .socket, .mount, .target, .path, .slice, .scope
            const is_unit = std.mem.endsWith(u8, name, ".service") or
                std.mem.endsWith(u8, name, ".timer") or
                std.mem.endsWith(u8, name, ".socket") or
                std.mem.endsWith(u8, name, ".mount") or
                std.mem.endsWith(u8, name, ".target") or
                std.mem.endsWith(u8, name, ".path") or
                std.mem.endsWith(u8, name, ".slice") or
                std.mem.endsWith(u8, name, ".scope");
            if (!is_unit) continue;
            if (!std.mem.startsWith(u8, name, pattern)) continue;
            if (seen.contains(name)) continue;
            const owned = self.allocator.dupe(u8, name) catch continue;
            seen.put(owned, {}) catch {};
            matches.append(self.allocator, owned) catch {
                self.allocator.free(owned);
                continue;
            };
        }
    }

    if (matches.items.len == 0) return false;
    if (matches.items.len == 1) {
        return try applySingleCompletion(self, matches.items[0], word_result);
    }
    return try showCompletionMatches(self, &matches, word_result, pattern);
}

fn tryDockerCompletion(self: *Shell, cmd: []const u8, word_result: WordResult) !bool {
    const trimmed = std.mem.trimStart(u8, cmd, " \t");
    const cmd_end = std.mem.indexOfAny(u8, trimmed, " \t") orelse return false;
    const base_cmd = trimmed[0..cmd_end];
    if (!std.mem.eql(u8, base_cmd, "docker") and !std.mem.eql(u8, base_cmd, "podman")) return false;

    // Find subcommand
    const rest = std.mem.trimStart(u8, trimmed[cmd_end..], " \t");
    const sub_end = std.mem.indexOfAny(u8, rest, " \t") orelse return false;
    const subcmd = rest[0..sub_end];

    // Determine what to complete
    const needs_container = for ([_][]const u8{
        "start", "stop", "restart", "rm", "logs", "exec", "attach", "inspect",
        "kill", "pause", "unpause", "top", "stats", "cp", "diff", "export",
        "port", "rename", "update", "wait",
    }) |s| {
        if (std.mem.eql(u8, subcmd, s)) break true;
    } else false;

    const needs_image = for ([_][]const u8{
        "run", "create", "rmi", "tag", "push", "save", "history",
    }) |s| {
        if (std.mem.eql(u8, subcmd, s)) break true;
    } else false;

    if (!needs_container and !needs_image) return false;

    const pattern = word_result.word;
    const list_cmd = if (needs_container)
        &[_][]const u8{ "/bin/sh", "-c", "docker ps -a --format '{{.Names}}' 2>/dev/null" }
    else
        &[_][]const u8{ "/bin/sh", "-c", "docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null" };

    var child = std.process.spawn(compat.io(), .{
        .argv = list_cmd,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return false;

    const stdout = child.stdout.?;
    var read_buf: [8192]u8 = undefined;
    var total: usize = 0;
    while (total < read_buf.len) {
        const n = compat.posix.read(stdout.handle, read_buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    if (child.stdout) |*s| { s.close(compat.io()); child.stdout = null; }
    _ = child.wait(compat.io()) catch {};

    var matches = try std.ArrayList([]const u8).initCapacity(self.allocator, 32);
    defer {
        for (matches.items) |m| self.allocator.free(m);
        matches.deinit(self.allocator);
    }

    var seen = std.StringHashMap(void).init(self.allocator);
    defer seen.deinit();

    const text = read_buf[0..total];
    var line_start: usize = 0;
    while (line_start < text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
        const name = std.mem.trim(u8, text[line_start..line_end], " \t\r'");
        line_start = line_end + 1;
        if (name.len == 0) continue;
        if (std.mem.startsWith(u8, name, pattern) and !seen.contains(name)) {
            const owned = self.allocator.dupe(u8, name) catch continue;
            seen.put(owned, {}) catch {};
            matches.append(self.allocator, owned) catch {
                self.allocator.free(owned);
                continue;
            };
        }
    }

    if (matches.items.len == 0) return false;
    if (matches.items.len == 1) {
        return try applySingleCompletion(self, matches.items[0], word_result);
    }
    return try showCompletionMatches(self, &matches, word_result, pattern);
}

// use centralized builtins list from keywords.zig
const builtins = keywords.shell_builtins;

fn tryCommandCompletion(self: *Shell, word_result: WordResult) !bool {
    const pattern = word_result.word;

    var matches = try std.ArrayList([]const u8).initCapacity(self.allocator, 32);
    defer {
        for (matches.items) |m| self.allocator.free(m);
        matches.deinit(self.allocator);
    }

    var seen = std.StringHashMap(void).init(self.allocator);
    defer seen.deinit();

    // add matching builtins first
    for (builtins) |builtin| {
        if (std.mem.startsWith(u8, builtin, pattern)) {
            const name = self.allocator.dupe(u8, builtin) catch continue;
            seen.put(name, {}) catch {
                self.allocator.free(name);
                continue;
            };
            matches.append(self.allocator, name) catch {
                self.allocator.free(name);
                continue;
            };
        }
    }

    // add matching aliases
    var alias_iter = self.aliases.iterator();
    while (alias_iter.next()) |entry| {
        if (std.mem.startsWith(u8, entry.key_ptr.*, pattern) and !seen.contains(entry.key_ptr.*)) {
            const name = self.allocator.dupe(u8, entry.key_ptr.*) catch continue;
            seen.put(name, {}) catch {
                self.allocator.free(name);
                continue;
            };
            matches.append(self.allocator, name) catch {
                self.allocator.free(name);
                continue;
            };
        }
    }

    // search PATH directories for matching executables
    const path_env = compat.getEnvVarOwned(self.allocator, "PATH") catch {
        if (matches.items.len > 0) {
            return if (matches.items.len == 1)
                try applySingleCompletion(self, matches.items[0], word_result)
            else
                try showCompletionMatches(self, &matches, word_result, pattern);
        }
        return false;
    };
    defer self.allocator.free(path_env);

    var path_iter = std.mem.splitScalar(u8, path_env, ':');
    while (path_iter.next()) |path_dir| {
        if (path_dir.len == 0) continue;

        var dir = std.Io.Dir.cwd().openDir(compat.io(), path_dir, .{ .iterate = true }) catch continue;
        defer dir.close(compat.io());
        var iter = dir.iterate();
        while (iter.next(compat.io()) catch null) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            if (!std.mem.startsWith(u8, entry.name, pattern)) continue;
            if (seen.contains(entry.name)) continue;

            // check if executable
            const full_path = std.fs.path.join(self.allocator, &.{ path_dir, entry.name }) catch continue;
            defer self.allocator.free(full_path);

            const stat = std.Io.Dir.cwd().statFile(compat.io(), full_path, .{}) catch continue;
            if (stat.permissions.toMode() & 0o111 == 0) continue;

            const name = self.allocator.dupe(u8, entry.name) catch continue;
            seen.put(name, {}) catch {
                self.allocator.free(name);
                continue;
            };
            matches.append(self.allocator, name) catch {
                self.allocator.free(name);
                continue;
            };
        }
    }

    if (matches.items.len == 0) return false;

    // sort matches alphabetically
    std.mem.sort([]const u8, matches.items, {}, StringOrder.lessThan);

    if (matches.items.len == 1) {
        return try applySingleCompletion(self, matches.items[0], word_result);
    } else {
        return try showCompletionMatches(self, &matches, word_result, pattern);
    }
}

/// Project-aware completions: zig build targets, cargo bins/examples, npm scripts
fn tryProjectCompletion(self: *Shell, cmd: []const u8, word_result: WordResult) !bool {
    const trimmed = std.mem.trimStart(u8, cmd, " \t");
    const pattern = word_result.word;

    // zig build <target> — parse build.zig for addExecutable/addTest/step names
    if (std.mem.startsWith(u8, trimmed, "zig build ")) {
        return try tryZigBuildTargetCompletion(self, pattern, word_result);
    }

    // cargo run --bin <name> / cargo run --example <name>
    if (std.mem.startsWith(u8, trimmed, "cargo run ") or
        std.mem.startsWith(u8, trimmed, "cargo test ") or
        std.mem.startsWith(u8, trimmed, "cargo bench "))
    {
        // check if previous arg was --bin or --example
        const rest = trimmed[std.mem.indexOfScalar(u8, trimmed, ' ').? + 1 ..];
        if (std.mem.indexOf(u8, rest, "--bin ") != null or
            std.mem.indexOf(u8, rest, "--example ") != null)
        {
            return try tryCargoBinCompletion(self, trimmed, pattern, word_result);
        }
    }

    // npm run <script> / yarn <script> / pnpm run <script>
    if (std.mem.startsWith(u8, trimmed, "npm run ") or
        std.mem.startsWith(u8, trimmed, "pnpm run ") or
        std.mem.startsWith(u8, trimmed, "yarn "))
    {
        return try tryNpmScriptCompletion(self, pattern, word_result);
    }

    return false;
}

/// Complete zig build targets by parsing build.zig for step/exe names
fn tryZigBuildTargetCompletion(self: *Shell, pattern: []const u8, word_result: WordResult) !bool {
    const file = std.Io.Dir.cwd().openFile(compat.io(), "build.zig", .{}) catch return false;
    defer file.close(compat.io());

    var read_buf: [32768]u8 = undefined;
    const n = compat.posix.read(file.handle, &read_buf) catch return false;
    const text = read_buf[0..n];

    var matches = try std.ArrayList([]const u8).initCapacity(self.allocator, 16);
    defer {
        for (matches.items) |m| self.allocator.free(m);
        matches.deinit(self.allocator);
    }

    // Parse: b.step("name", ...) patterns
    var i: usize = 0;
    while (i < text.len) {
        // Look for .step(" or addExecutable(.{ .name = "
        const step_marker = std.mem.indexOfPos(u8, text, i, ".step(\"") orelse break;
        const name_start = step_marker + 7; // skip .step("
        const name_end = std.mem.indexOfScalarPos(u8, text, name_start, '"') orelse break;
        const name = text[name_start..name_end];
        i = name_end + 1;

        if (name.len > 0 and std.mem.startsWith(u8, name, pattern)) {
            // deduplicate
            var dup = false;
            for (matches.items) |m| {
                if (std.mem.eql(u8, m, name)) { dup = true; break; }
            }
            if (!dup) {
                const owned = try self.allocator.dupe(u8, name);
                try matches.append(self.allocator, owned);
            }
        }
    }

    // Also parse addExecutable(.{ .name = "xxx" patterns
    i = 0;
    while (i < text.len) {
        const marker = std.mem.indexOfPos(u8, text, i, "addExecutable(") orelse break;
        // find .name = " after this
        const search_end = @min(marker + 200, text.len);
        const name_key = std.mem.indexOfPos(u8, text, marker, ".name = \"") orelse {
            i = marker + 14;
            continue;
        };
        if (name_key >= search_end) { i = marker + 14; continue; }
        const name_start = name_key + 9;
        const name_end = std.mem.indexOfScalarPos(u8, text, name_start, '"') orelse { i = name_start; continue; };
        const name = text[name_start..name_end];
        i = name_end + 1;

        if (name.len > 0 and std.mem.startsWith(u8, name, pattern)) {
            var dup = false;
            for (matches.items) |m| {
                if (std.mem.eql(u8, m, name)) { dup = true; break; }
            }
            if (!dup) {
                const owned = try self.allocator.dupe(u8, name);
                try matches.append(self.allocator, owned);
            }
        }
    }

    if (matches.items.len == 0) return false;
    if (matches.items.len == 1) return try applySingleCompletion(self, matches.items[0], word_result);
    return try showCompletionMatches(self, &matches, word_result, pattern);
}

/// Complete cargo --bin and --example names from Cargo.toml + directory scan
fn tryCargoBinCompletion(self: *Shell, cmd: []const u8, pattern: []const u8, word_result: WordResult) !bool {
    _ = cmd;
    var matches = try std.ArrayList([]const u8).initCapacity(self.allocator, 16);
    defer {
        for (matches.items) |m| self.allocator.free(m);
        matches.deinit(self.allocator);
    }

    // Scan src/bin/ for binary names
    if (std.Io.Dir.cwd().openDir(compat.io(), "src/bin", .{ .iterate = true })) |dir_handle| {
        var dir = dir_handle;
        defer dir.close(compat.io());
        var iter = dir.iterate();
        while (try iter.next(compat.io())) |entry| {
            if (entry.kind != .file) continue;
            // strip .rs extension
            const name = if (std.mem.endsWith(u8, entry.name, ".rs"))
                entry.name[0 .. entry.name.len - 3]
            else
                entry.name;
            if (name.len > 0 and std.mem.startsWith(u8, name, pattern)) {
                const owned = try self.allocator.dupe(u8, name);
                try matches.append(self.allocator, owned);
            }
        }
    } else |_| {}

    // Scan examples/ for example names
    if (std.Io.Dir.cwd().openDir(compat.io(), "examples", .{ .iterate = true })) |dir_handle| {
        var dir = dir_handle;
        defer dir.close(compat.io());
        var iter = dir.iterate();
        while (try iter.next(compat.io())) |entry| {
            if (entry.kind != .file) continue;
            const name = if (std.mem.endsWith(u8, entry.name, ".rs"))
                entry.name[0 .. entry.name.len - 3]
            else
                entry.name;
            if (name.len > 0 and std.mem.startsWith(u8, name, pattern)) {
                const owned = try self.allocator.dupe(u8, name);
                try matches.append(self.allocator, owned);
            }
        }
    } else |_| {}

    // Also parse Cargo.toml for [[bin]] names
    if (std.Io.Dir.cwd().openFile(compat.io(), "Cargo.toml", .{})) |file| {
        defer file.close(compat.io());
        var read_buf: [8192]u8 = undefined;
        const n = compat.posix.read(file.handle, &read_buf) catch 0;
        const text = read_buf[0..n];
        // Simple parse: look for name = "xxx" after [[bin]] or [[example]]
        var pos: usize = 0;
        while (pos < text.len) {
            const name_key = std.mem.indexOfPos(u8, text, pos, "name = \"") orelse break;
            const name_start = name_key + 8;
            const name_end = std.mem.indexOfScalarPos(u8, text, name_start, '"') orelse break;
            const name = text[name_start..name_end];
            pos = name_end + 1;
            if (name.len > 0 and std.mem.startsWith(u8, name, pattern)) {
                var dup = false;
                for (matches.items) |m| {
                    if (std.mem.eql(u8, m, name)) { dup = true; break; }
                }
                if (!dup) {
                    const owned = try self.allocator.dupe(u8, name);
                    try matches.append(self.allocator, owned);
                }
            }
        }
    } else |_| {}

    if (matches.items.len == 0) return false;
    if (matches.items.len == 1) return try applySingleCompletion(self, matches.items[0], word_result);
    return try showCompletionMatches(self, &matches, word_result, pattern);
}

/// Complete npm/yarn/pnpm script names from package.json
fn tryNpmScriptCompletion(self: *Shell, pattern: []const u8, word_result: WordResult) !bool {
    const file = std.Io.Dir.cwd().openFile(compat.io(), "package.json", .{}) catch return false;
    defer file.close(compat.io());

    var read_buf: [16384]u8 = undefined;
    const n = compat.posix.read(file.handle, &read_buf) catch return false;
    const text = read_buf[0..n];

    // Find "scripts": { ... } section and extract keys
    const scripts_key = std.mem.indexOf(u8, text, "\"scripts\"") orelse return false;
    const brace_start = std.mem.indexOfScalarPos(u8, text, scripts_key, '{') orelse return false;

    var matches = try std.ArrayList([]const u8).initCapacity(self.allocator, 16);
    defer {
        for (matches.items) |m| self.allocator.free(m);
        matches.deinit(self.allocator);
    }

    // Parse keys within the scripts object
    var pos = brace_start + 1;
    var depth: i32 = 1;
    while (pos < text.len and depth > 0) {
        if (text[pos] == '{') {
            depth += 1;
            pos += 1;
        } else if (text[pos] == '}') {
            depth -= 1;
            pos += 1;
        } else if (text[pos] == '"' and depth == 1) {
            // this should be a key
            const key_start = pos + 1;
            const key_end = std.mem.indexOfScalarPos(u8, text, key_start, '"') orelse break;
            const key = text[key_start..key_end];
            pos = key_end + 1;

            // skip past ": "value"
            const colon = std.mem.indexOfScalarPos(u8, text, pos, ':') orelse break;
            pos = colon + 1;

            if (key.len > 0 and std.mem.startsWith(u8, key, pattern)) {
                const owned = try self.allocator.dupe(u8, key);
                try matches.append(self.allocator, owned);
            }
        } else {
            pos += 1;
        }
    }

    if (matches.items.len == 0) return false;
    if (matches.items.len == 1) return try applySingleCompletion(self, matches.items[0], word_result);
    return try showCompletionMatches(self, &matches, word_result, pattern);
}

fn tryGitCompletion(self: *Shell, cmd: []const u8, word_result: WordResult) !bool {
    if (!std.mem.startsWith(u8, cmd, "git ")) return false;
    if (!git.isRepo()) return false;

    const after_git = cmd[4..];
    var parts = std.mem.splitScalar(u8, after_git, ' ');
    const subcommand = parts.next() orelse return false;

    var matches = try std.ArrayList([]const u8).initCapacity(self.allocator, 32);
    defer {
        for (matches.items) |m| self.allocator.free(m);
        matches.deinit(self.allocator);
    }

    const pattern = word_result.word;

    // check if cursor is on the subcommand word itself (completing git sub<tab>)
    const is_subcommand_pos = parts.next() == null and std.mem.eql(u8, subcommand, pattern);
    if (is_subcommand_pos) {
        const git_subcommands = [_][]const u8{
            "add",      "bisect",   "blame",    "branch",   "checkout",
            "cherry-pick", "clean", "clone",    "commit",   "config",
            "diff",     "fetch",    "grep",     "init",     "log",
            "merge",    "mv",       "pull",     "push",     "rebase",
            "remote",   "reset",    "restore",  "revert",   "rm",
            "show",     "stash",    "status",   "switch",   "tag",
            "worktree",
        };
        for (&git_subcommands) |sc| {
            if (std.mem.startsWith(u8, sc, pattern)) {
                const owned = try self.allocator.dupe(u8, sc);
                try matches.append(self.allocator, owned);
            }
        }
        if (matches.items.len == 0) return false;
        if (matches.items.len == 1) {
            return try applySingleCompletion(self, matches.items[0], word_result);
        } else {
            return try showCompletionMatches(self, &matches, word_result, pattern);
        }
    }

    if (std.mem.eql(u8, subcommand, "add") or
        std.mem.eql(u8, subcommand, "restore") or
        std.mem.eql(u8, subcommand, "diff"))
    {
        if (git.getStatus(self.allocator)) |s| {
            var status = s;
            defer status.deinit();

            for (status.modified.items) |file| {
                if (std.mem.startsWith(u8, file, pattern)) {
                    matches.append(self.allocator, self.allocator.dupe(u8, file) catch continue) catch {};
                }
            }
            for (status.deleted.items) |file| {
                if (std.mem.startsWith(u8, file, pattern)) {
                    matches.append(self.allocator, self.allocator.dupe(u8, file) catch continue) catch {};
                }
            }
            for (status.untracked.items) |file| {
                if (std.mem.startsWith(u8, file, pattern)) {
                    matches.append(self.allocator, self.allocator.dupe(u8, file) catch continue) catch {};
                }
            }
        }
    } else if (std.mem.eql(u8, subcommand, "checkout") or
        std.mem.eql(u8, subcommand, "switch") or
        std.mem.eql(u8, subcommand, "merge") or
        std.mem.eql(u8, subcommand, "rebase") or
        std.mem.eql(u8, subcommand, "log") or
        std.mem.eql(u8, subcommand, "show"))
    {
        try getGitBranches(self, &matches, pattern);
    } else if (std.mem.eql(u8, subcommand, "branch")) {
        var has_delete = false;
        while (parts.next()) |part| {
            if (std.mem.eql(u8, part, "-d") or std.mem.eql(u8, part, "-D") or
                std.mem.eql(u8, part, "--delete"))
            {
                has_delete = true;
                break;
            }
        }
        if (has_delete) {
            try getGitBranches(self, &matches, pattern);
        }
    } else if (std.mem.eql(u8, subcommand, "tag")) {
        // git tag completion — complete existing tags for -d, otherwise show tags for reference
        try getGitTags(self, &matches, pattern);
    } else if (std.mem.eql(u8, subcommand, "stash")) {
        // git stash subcommands
        const stash_cmds = [_][]const u8{ "apply", "drop", "list", "pop", "push", "show", "clear" };
        for (stash_cmds) |sc| {
            if (std.mem.startsWith(u8, sc, pattern)) {
                const owned = try self.allocator.dupe(u8, sc);
                try matches.append(self.allocator, owned);
            }
        }
    } else if (std.mem.eql(u8, subcommand, "remote")) {
        // git remote subcommands
        const remote_cmds = [_][]const u8{ "add", "remove", "rename", "show", "prune", "get-url", "set-url" };
        for (remote_cmds) |rc| {
            if (std.mem.startsWith(u8, rc, pattern)) {
                const owned = try self.allocator.dupe(u8, rc);
                try matches.append(self.allocator, owned);
            }
        }
    } else {
        return false;
    }

    if (matches.items.len == 0) return false;

    if (matches.items.len == 1) {
        return try applySingleCompletion(self, matches.items[0], word_result);
    } else {
        return try showCompletionMatches(self, &matches, word_result, pattern);
    }
}

/// Suggest full commands from history matching the current input prefix.
/// Shows unique matching commands, most recent first.
/// Pipe completion: suggest common pipe targets (grep, sort, head, jq, etc.)
/// Triggers when user types `| <tab>` or `| gr<tab>` with short prefix.
fn tryPipeCompletion(self: *Shell, word_result: WordResult) !bool {
    const pipe_targets = [_][]const u8{
        "grep", "sort", "head", "tail", "wc", "uniq", "cut", "tr",
        "awk", "sed", "jq", "tee", "xargs", "less", "more",
        "cat", "rev", "column", "paste", "fold", "fmt",
        "base64", "md5sum", "sha256sum",
    };

    const pattern = word_result.word;
    var matches: std.ArrayList([]const u8) = .empty;
    defer matches.deinit(self.allocator);

    for (&pipe_targets) |target| {
        if (pattern.len == 0 or std.mem.startsWith(u8, target, pattern)) {
            matches.append(self.allocator, target) catch continue;
        }
    }

    if (matches.items.len == 0) return false;

    if (matches.items.len == 1) {
        _ = try applySingleCompletion(self, matches.items[0], word_result);
        return true;
    }

    // show multi-column menu
    _ = try showCompletionMatches(self, &matches, word_result, pattern);
    return true;
}

fn tryHistoryCompletion(self: *Shell, current_input: []const u8) !bool {
    const h = self.history orelse return false;
    const prefix = std.mem.trimStart(u8, current_input, " \t");
    if (prefix.len < 2) return false;

    var matches = try std.ArrayList([]const u8).initCapacity(self.allocator, 32);
    defer {
        for (matches.items) |m| self.allocator.free(m);
        matches.deinit(self.allocator);
    }

    // scan history in reverse (most recent first), collect unique prefix matches
    var seen_buf: [8192]u8 = undefined;
    var seen_pos: usize = 0;
    var seen_offsets: [64]u16 = undefined;
    var seen_lens: [64]u16 = undefined;
    var seen_count: usize = 0;

    const items = h.entries.items;
    var idx: usize = items.len;
    while (idx > 0) {
        idx -= 1;
        const entry = items[idx];
        // Never suggest a line that was "command not found" (127). It failed
        // every time it ran; replaying it is offering the user their own typo.
        if (entry.exit_code == 127) continue;
        const cmd_text = h.getCommand(entry);
        if (cmd_text.len <= prefix.len) continue;
        if (!std.mem.startsWith(u8, cmd_text, prefix)) continue;
        // skip exact match
        if (cmd_text.len == prefix.len) continue;

        // deduplicate
        var is_dup = false;
        for (0..seen_count) |si| {
            const seen_cmd = seen_buf[seen_offsets[si] .. seen_offsets[si] + seen_lens[si]];
            if (std.mem.eql(u8, seen_cmd, cmd_text)) {
                is_dup = true;
                break;
            }
        }
        if (is_dup) continue;

        // track in seen buffer
        if (seen_count < 64 and seen_pos + cmd_text.len <= seen_buf.len) {
            @memcpy(seen_buf[seen_pos .. seen_pos + cmd_text.len], cmd_text);
            seen_offsets[seen_count] = @intCast(seen_pos);
            seen_lens[seen_count] = @intCast(cmd_text.len);
            seen_pos += cmd_text.len;
            seen_count += 1;
        }

        const owned = try self.allocator.dupe(u8, cmd_text);
        try matches.append(self.allocator, owned);

        if (matches.items.len >= 20) break; // cap at 20 suggestions
    }

    if (matches.items.len == 0) return false;

    if (matches.items.len == 1) {
        // replace entire input with the history match
        self.edit_buf.clear();
        _ = self.edit_buf.insertSlice(matches.items[0]);
        logCompletionWith(self.edit_buf.slice(), 0, prefix, matches.items[0], .history_menu);
        try self.renderLine();
        return true;
    }

    // show as completion menu — use full command as match
    // (free old owned strings first)
    for (self.completion.matches.items) |old| {
        self.allocator.free(old);
    }
    self.completion.matches.deinit(self.allocator);
    self.completion.matches = .empty;
    for (matches.items) |m| {
        const owned = try self.allocator.dupe(u8, m);
        try self.completion.matches.append(self.allocator, owned);
    }
    self.completion.mode = true;
    self.completion.index = 0;
    self.completion.word_start = 0;
    self.completion.word_end = @intCast(self.edit_buf.len);
    self.completion.original_len = self.edit_buf.len;
    self.completion.pattern_len = @intCast(prefix.len);

    try displayCompletions(self);
    return true;
}

fn trySubcommandCompletion(self: *Shell, cmd: []const u8, word_result: WordResult) !bool {
    // only complete subcommands when cursor is on the second word
    const trimmed = std.mem.trimStart(u8, cmd, " \t");
    const cmd_end = std.mem.indexOfAny(u8, trimmed, " \t") orelse return false;
    const base_cmd = trimmed[0..cmd_end];

    // check this is a tool that uses subcommands
    const subcmd_tools = [_][]const u8{ "docker", "cargo", "npm", "kubectl", "zig", "go", "rustup", "apt", "systemctl", "ip", "gh", "podman", "helm", "terraform", "yarn", "pnpm", "pipx", "uv" };
    var is_subcmd_tool = false;
    for (&subcmd_tools) |tool| {
        if (std.mem.eql(u8, base_cmd, tool)) {
            is_subcmd_tool = true;
            break;
        }
    }
    if (!is_subcmd_tool) return false;

    // check we're on the subcommand position (second word, cursor at/within it)
    const rest = std.mem.trimStart(u8, trimmed[cmd_end..], " \t");
    const sub_end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
    // if there's more text after the subcommand word, we're past subcommand position
    if (sub_end < rest.len) {
        const after_sub = std.mem.trimStart(u8, rest[sub_end..], " \t");
        if (after_sub.len > 0) return false;
    }

    const pattern = word_result.word;

    // check cache (TTL 5 minutes)
    const now = compat.timestamp();
    const cache_ttl: i64 = 300;
    const cached = self.cache.subcmd_cmd_len > 0 and
        self.cache.subcmd_cmd_len == base_cmd.len and
        base_cmd.len <= self.cache.subcmd_cmd.len and
        std.mem.eql(u8, self.cache.subcmd_cmd[0..self.cache.subcmd_cmd_len], base_cmd) and
        (now - self.cache.subcmd_ts) < cache_ttl;

    if (!cached) {
        parseSubcmdsFromHelp(self, base_cmd) catch {
            self.cache.subcmd_count = 0;
        };
        self.cache.subcmd_ts = now;
    }

    if (self.cache.subcmd_count == 0) return false;

    var matches = try std.ArrayList([]const u8).initCapacity(self.allocator, 32);
    defer {
        for (matches.items) |m| self.allocator.free(m);
        matches.deinit(self.allocator);
    }

    for (0..self.cache.subcmd_count) |i| {
        const off = self.cache.subcmd_offsets[i];
        const len = self.cache.subcmd_lens[i];
        const subcmd = self.cache.subcmd_buf[off .. off + len];
        if (std.mem.startsWith(u8, subcmd, pattern)) {
            const owned = try self.allocator.dupe(u8, subcmd);
            try matches.append(self.allocator, owned);
        }
    }

    if (matches.items.len == 0) return false;
    if (matches.items.len == 1) {
        return try applySingleCompletion(self, matches.items[0], word_result);
    } else {
        return try showCompletionMatches(self, &matches, word_result, pattern);
    }
}

/// Strict allowlist for names completion is willing to execute.
///
/// Completion probes run on TAB — before the user has committed to running
/// anything — so the bar here is "obviously inert", not "probably fine". A
/// name must be a bare PATH lookup: no '/' (blocks ./relative and absolute
/// paths), no leading '-' (the callee would parse it as a flag), no leading
/// '.', and nothing outside a conservative character set. Every shell
/// metacharacter is rejected as a side effect.
///
/// This is defense in depth. Callers below no longer invoke a shell at all,
/// so metacharacters are already inert; this keeps them inert even if some
/// future caller reintroduces one.
fn isSafeProbeName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    if (name[0] == '-' or name[0] == '.') return false;
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c)) continue;
        if (c == '_' or c == '-' or c == '.' or c == '+') continue;
        return false;
    }
    return true;
}

/// Spawn `argv` with stdout and stderr merged into a single pipe and read up
/// to `buf.len` bytes of it. Returns the byte count (0 on any failure).
///
/// The merge reproduces the `2>&1` that the old `/bin/sh -c "..."` string
/// provided — many tools print --help to stderr — but without a shell in the
/// loop, so argv elements reach execve verbatim and are never parsed as shell
/// syntax.
///
/// If the child outputs more than `buf.len` we stop reading and close the read
/// end; the child then takes EPIPE/SIGPIPE and exits, rather than blocking
/// forever on write while we block in wait().
fn captureMerged(argv: []const []const u8, buf: []u8) usize {
    const fds = compat.posix.pipe() catch return 0;
    // compat.posix.pipe() returns blocking fds; say so explicitly.
    const write_end: std.Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };

    var child = std.process.spawn(compat.io(), .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .{ .file = write_end },
        .stderr = .{ .file = write_end },
    }) catch {
        compat.posix.close(fds[0]);
        compat.posix.close(fds[1]);
        return 0;
    };

    // Parent must drop its copy of the write end or the read below never
    // observes EOF once the child exits.
    compat.posix.close(fds[1]);

    var total: usize = 0;
    while (total < buf.len) {
        const n = compat.posix.read(fds[0], buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }

    compat.posix.close(fds[0]);
    _ = child.wait(compat.io()) catch {};
    return total;
}

fn parseSubcmdsFromHelp(self: *Shell, base_cmd: []const u8) !void {
    self.cache.subcmd_count = 0;
    if (base_cmd.len > self.cache.subcmd_cmd.len) return;
    if (!isSafeProbeName(base_cmd)) return;
    @memcpy(self.cache.subcmd_cmd[0..base_cmd.len], base_cmd);
    self.cache.subcmd_cmd_len = base_cmd.len;

    var read_buf: [16384]u8 = undefined;
    const total_read = captureMerged(&.{ base_cmd, "--help" }, &read_buf);

    // parse subcommands: lines starting with 2+ spaces followed by a word (no dash prefix)
    const text = read_buf[0..total_read];
    var line_start: usize = 0;
    var buf_pos: usize = 0;
    var count: usize = 0;

    while (line_start < text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
        const line = text[line_start..line_end];
        line_start = line_end + 1;

        if (line.len < 3) continue;
        var indent: usize = 0;
        while (indent < line.len and (line[indent] == ' ' or line[indent] == '\t')) : (indent += 1) {}
        if (indent < 2 or indent >= line.len) continue;
        if (!std.ascii.isAlphabetic(line[indent])) continue;

        var wend = indent;
        while (wend < line.len and (std.ascii.isAlphanumeric(line[wend]) or line[wend] == '-' or line[wend] == '_')) : (wend += 1) {}
        const subcmd = line[indent..wend];
        if (subcmd.len < 2 or subcmd.len > 30) continue;
        if (count >= 128) break;

        // deduplicate
        var dup = false;
        for (0..count) |j| {
            const existing = self.cache.subcmd_buf[self.cache.subcmd_offsets[j] .. self.cache.subcmd_offsets[j] + self.cache.subcmd_lens[j]];
            if (std.mem.eql(u8, existing, subcmd)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;

        if (buf_pos + subcmd.len > self.cache.subcmd_buf.len) break;
        @memcpy(self.cache.subcmd_buf[buf_pos .. buf_pos + subcmd.len], subcmd);
        self.cache.subcmd_offsets[count] = @intCast(buf_pos);
        self.cache.subcmd_lens[count] = @intCast(subcmd.len);
        buf_pos += subcmd.len;
        count += 1;
    }

    self.cache.subcmd_count = count;
}

fn tryFlagCompletion(self: *Shell, cmd: []const u8, word_result: WordResult) !bool {
    // extract command + subcommand for tools that use subcommands
    const trimmed = std.mem.trimStart(u8, cmd, " \t");
    const cmd_end = std.mem.indexOfAny(u8, trimmed, " \t") orelse return false;
    const base_cmd = trimmed[0..cmd_end];
    if (base_cmd.len == 0 or base_cmd.len > 32) return false;

    // for git/docker/cargo/npm/kubectl/zig etc, include subcommand in --help
    const has_subcmds = for ([_][]const u8{ "git", "docker", "cargo", "npm", "kubectl", "zig", "go", "rustup", "apt", "systemctl", "ip", "gh" }) |tool| {
        if (std.mem.eql(u8, base_cmd, tool)) break true;
    } else false;

    var sub_opt: ?[]const u8 = null;
    if (has_subcmds) {
        const rest = std.mem.trimStart(u8, trimmed[cmd_end..], " \t");
        if (rest.len > 0) {
            const sub_end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
            const sub = rest[0..sub_end];
            // only include if subcommand doesn't start with - (it's a flag not a subcmd)
            if (sub.len > 0 and sub[0] != '-') sub_opt = sub;
        }
    }

    // `command` is a cache key only — it is compared and copied, never executed.
    // base_cmd and sub_opt reach execve as separate argv elements.
    var full_cmd_buf: [64]u8 = undefined;
    const command = blk: {
        if (sub_opt) |s| {
            break :blk std.fmt.bufPrint(&full_cmd_buf, "{s} {s}", .{ base_cmd, s }) catch {
                // Joined key doesn't fit: probe the base command alone so the
                // cache key and the probe stay in agreement.
                sub_opt = null;
                break :blk base_cmd;
            };
        }
        break :blk base_cmd;
    };
    if (command.len > full_cmd_buf.len) return false;

    const pattern = word_result.word;

    // check cache (TTL 5 minutes)
    const now = compat.timestamp();
    const cache_ttl: i64 = 300; // 5 minutes
    const cached = self.cache.flag_cmd_len > 0 and
        self.cache.flag_cmd_len == command.len and
        std.mem.eql(u8, self.cache.flag_cmd[0..self.cache.flag_cmd_len], command) and
        (now - self.cache.flag_ts) < cache_ttl;

    if (!cached) {
        // run command --help and parse flags
        parseFlagsFromHelp(self, command, base_cmd, sub_opt) catch {
            self.cache.flag_count = 0;
        };
        self.cache.flag_ts = now;
    }

    if (self.cache.flag_count == 0) return false;

    var matches = try std.ArrayList([]const u8).initCapacity(self.allocator, 32);
    defer {
        for (matches.items) |m| self.allocator.free(m);
        matches.deinit(self.allocator);
    }

    // collect matching flag indices for description lookup
    var match_indices: [256]usize = undefined;
    var match_count: usize = 0;

    for (0..self.cache.flag_count) |i| {
        const off = self.cache.flag_offsets[i];
        const len = self.cache.flag_lens[i];
        const flag = self.cache.flag_buf[off .. off + len];
        if (std.mem.startsWith(u8, flag, pattern)) {
            const owned = try self.allocator.dupe(u8, flag);
            try matches.append(self.allocator, owned);
            if (match_count < 256) {
                match_indices[match_count] = i;
                match_count += 1;
            }
        }
    }

    if (matches.items.len == 0) return false;
    if (matches.items.len == 1) {
        return try applySingleCompletion(self, matches.items[0], word_result);
    } else {
        // check if any match has a description
        var has_descs = false;
        for (0..match_count) |mi| {
            if (self.cache.flag_desc_lens[match_indices[mi]] > 0) {
                has_descs = true;
                break;
            }
        }
        if (has_descs) {
            return try showFlagCompletionsWithDesc(self, &matches, match_indices[0..match_count], word_result, pattern);
        }
        return try showCompletionMatches(self, &matches, word_result, pattern);
    }
}

/// Probe `base [sub] --help` and parse flags out of the output.
///
/// `base` and `sub` are passed as separate argv elements rather than joined
/// into one string, so a space (or any other character) inside `sub` can never
/// split into extra arguments. `cache_key` is only ever compared and copied,
/// never executed.
fn parseFlagsFromHelp(self: *Shell, cache_key: []const u8, base: []const u8, sub: ?[]const u8) !void {
    self.cache.flag_count = 0;
    if (cache_key.len > self.cache.flag_cmd.len) return;
    if (!isSafeProbeName(base)) return;
    @memcpy(self.cache.flag_cmd[0..cache_key.len], cache_key);
    self.cache.flag_cmd_len = cache_key.len;

    var buf_pos: usize = 0;
    var desc_pos: usize = 0;
    var count: usize = 0;

    // read help output and parse flags (cap at 16K to avoid OOM)
    var read_buf: [16384]u8 = undefined;
    const total_read = if (sub) |s|
        captureMerged(&.{ base, s, "--help" }, &read_buf)
    else
        captureMerged(&.{ base, "--help" }, &read_buf);

    // parse flags from help text — extract flag + description
    const text = read_buf[0..total_read];
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '-' and i + 1 < text.len and
            (i == 0 or text[i - 1] == ' ' or text[i - 1] == '\t' or text[i - 1] == '\n' or text[i - 1] == ',' or text[i - 1] == '['))
        {
            const flag_start = i;
            i += 1;
            if (i < text.len and text[i] == '-') i += 1; // --
            // require at least one alpha char
            if (i >= text.len or !std.ascii.isAlphabetic(text[i])) {
                continue;
            }
            while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '-' or text[i] == '_')) : (i += 1) {}
            const flag = text[flag_start..i];
            // skip single dash alone, require -X or --word (min 2 chars)
            if (flag.len > 1 and flag.len < 255 and count < 256) {
                // deduplicate
                var dup = false;
                for (0..count) |j| {
                    const existing = self.cache.flag_buf[self.cache.flag_offsets[j] .. self.cache.flag_offsets[j] + self.cache.flag_lens[j]];
                    if (std.mem.eql(u8, existing, flag)) {
                        dup = true;
                        break;
                    }
                }
                if (!dup and buf_pos + flag.len <= self.cache.flag_buf.len) {
                    @memcpy(self.cache.flag_buf[buf_pos .. buf_pos + flag.len], flag);
                    self.cache.flag_offsets[count] = @intCast(buf_pos);
                    self.cache.flag_lens[count] = @intCast(flag.len);
                    buf_pos += flag.len;

                    // extract description: skip to end of flag group, then grab description text
                    const desc = extractFlagDescription(text, i);
                    const desc_len = @min(desc.len, 60); // cap at 60 chars
                    if (desc_len > 0 and desc_pos + desc_len <= self.cache.flag_desc_buf.len) {
                        @memcpy(self.cache.flag_desc_buf[desc_pos .. desc_pos + desc_len], desc[0..desc_len]);
                        self.cache.flag_desc_offsets[count] = @intCast(desc_pos);
                        self.cache.flag_desc_lens[count] = @intCast(desc_len);
                        desc_pos += desc_len;
                    } else {
                        self.cache.flag_desc_offsets[count] = 0;
                        self.cache.flag_desc_lens[count] = 0;
                    }

                    count += 1;
                }
            }
        } else {
            i += 1;
        }
    }

    self.cache.flag_count = count;

    // If most flags lack descriptions, try man page as fallback
    if (count > 0) {
        var desc_count: usize = 0;
        for (0..count) |j| {
            if (self.cache.flag_desc_lens[j] > 0) desc_count += 1;
        }
        // Only try man page if less than 30% have descriptions
        if (desc_count * 100 / count < 30) {
            augmentFlagsFromMan(self, base, count, &desc_pos);
        }
    }
}

/// In-process replacement for `col -bx` over roff output.
///
/// man emits overstrike sequences for styling: "X\bX" for bold, "_\bX" for
/// underline. A backspace means "the next character overwrites the previous
/// one", so the plain-text rendering keeps the last character written to each
/// column — what `col -b` does. Tabs become spaces (`col -x`). Rewrites in
/// place and returns the shortened prefix.
fn stripOverstrike(buf: []u8) []u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        const c = buf[i];
        if (c == '\x08') {
            // Backspace discards the character it overwrites. The overwriting
            // character is emitted normally on the next iteration.
            if (out > 0) out -= 1;
            continue;
        }
        buf[out] = if (c == '\t') ' ' else c;
        out += 1;
    }
    return buf[0..out];
}

/// Parse man page output to fill in missing flag descriptions.
/// Only augments flags that already exist in the cache but lack descriptions.
fn augmentFlagsFromMan(self: *Shell, base_cmd: []const u8, count: usize, desc_pos: *usize) void {
    if (!isSafeProbeName(base_cmd)) return;

    // `man` is spawned directly instead of through `sh -c "... | col -bx"`.
    // The pipeline's only job was stripping roff overstrike sequences, which
    // stripOverstrike does in-process below — one less process and no shell.
    var read_buf: [32768]u8 = undefined;
    const raw_len = captureMerged(&.{ "man", base_cmd }, &read_buf);
    if (raw_len == 0) return;
    const text = stripOverstrike(read_buf[0..raw_len]);
    if (text.len == 0) return;

    // For each cached flag without a description, search man page text
    for (0..count) |j| {
        if (self.cache.flag_desc_lens[j] > 0) continue; // already has description
        const flag = self.cache.flag_buf[self.cache.flag_offsets[j] .. self.cache.flag_offsets[j] + self.cache.flag_lens[j]];

        // Search for the flag in man page text
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, text, pos, flag)) |found| {
            // Verify it's a word boundary (preceded by whitespace/newline, followed by space/comma/=)
            if (found > 0 and text[found - 1] != ' ' and text[found - 1] != '\t' and text[found - 1] != '\n') {
                pos = found + 1;
                continue;
            }
            const after = found + flag.len;
            if (after < text.len and text[after] != ' ' and text[after] != '\t' and
                text[after] != ',' and text[after] != '=' and text[after] != '\n' and
                text[after] != '[' and text[after] != '<')
            {
                pos = found + 1;
                continue;
            }

            // Try to extract description from this position
            const desc = extractFlagDescription(text, after);
            const desc_len = @min(desc.len, 60);
            if (desc_len > 0 and desc_pos.* + desc_len <= self.cache.flag_desc_buf.len) {
                @memcpy(self.cache.flag_desc_buf[desc_pos.* .. desc_pos.* + desc_len], desc[0..desc_len]);
                self.cache.flag_desc_offsets[j] = @intCast(desc_pos.*);
                self.cache.flag_desc_lens[j] = @intCast(desc_len);
                desc_pos.* += desc_len;
                break;
            }
            pos = found + 1;
        }
    }
}

/// Extract description text after a flag from help output.
/// Handles common formats:
///   -f, --flag          Description text here
///   -f, --flag=VALUE    Description text here
///   --flag              Description text here
///       Description continues on next indented line
fn extractFlagDescription(text: []const u8, flag_end: usize) []const u8 {
    var i = flag_end;

    // skip past any =VALUE, [VALUE], <VALUE>, or comma-separated short/long variants
    while (i < text.len and text[i] != '\n') {
        if (text[i] == ',' and i + 1 < text.len and text[i + 1] == ' ') {
            // skip ", -x" or ", --long" (another flag variant)
            i += 2;
            while (i < text.len and text[i] != ' ' and text[i] != '\t' and text[i] != '\n') : (i += 1) {}
        } else if (text[i] == '=' or text[i] == '[' or text[i] == '<') {
            // skip value placeholder
            while (i < text.len and text[i] != ' ' and text[i] != '\t' and text[i] != '\n') : (i += 1) {}
        } else if (text[i] == ' ' or text[i] == '\t') {
            break;
        } else {
            i += 1;
        }
    }

    // skip whitespace between flag and description (often 2+ spaces or tab)
    var spaces: usize = 0;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) {
        if (text[i] == '\t') spaces += 4 else spaces += 1;
        i += 1;
    }

    // need at least 2 spaces gap to be a description (not a continuation flag)
    if (spaces < 2 or i >= text.len or text[i] == '\n') return "";

    // capture until end of line
    const desc_start = i;
    while (i < text.len and text[i] != '\n') : (i += 1) {}

    // trim trailing whitespace
    var end = i;
    while (end > desc_start and (text[end - 1] == ' ' or text[end - 1] == '\t')) end -= 1;

    if (end <= desc_start) return "";
    return text[desc_start..end];
}

/// Show flag completions with descriptions in single-column layout
fn showFlagCompletionsWithDesc(self: *Shell, matches: *std.ArrayList([]const u8), match_indices: []const usize, word_result: WordResult, pattern: []const u8) !bool {
    if (matches.items.len == 0) return false;

    // store matches for cycling (free old owned strings first)
    for (self.completion.matches.items) |old| {
        self.allocator.free(old);
    }
    self.completion.matches.deinit(self.allocator);
    self.completion.matches = .empty;
    for (matches.items) |m| {
        const owned = try self.allocator.dupe(u8, m);
        try self.completion.matches.append(self.allocator, owned);
    }
    self.completion.mode = true;
    self.completion.index = 0;
    self.completion.word_start = word_result.start;
    self.completion.word_end = word_result.end;
    self.completion.original_len = self.edit_buf.len;
    self.completion.pattern_len = pattern.len;

    // display with descriptions
    const term_width = self.terminal_width;
    const term_height = self.terminal_height;
    const max_menu_height = if (term_height > 3) term_height - 3 else 1;

    const cmd_rows = self.term_view.term.rows_owned;
    const cursor_row = self.term_view.term.row;
    const cursor_col = self.term_view.term.col;
    const rows_below_cursor = if (cmd_rows > cursor_row + 1) cmd_rows - cursor_row - 1 else 0;
    if (rows_below_cursor > 0) {
        try self.stdout().print("\x1b[{d}B", .{rows_below_cursor});
    }
    try self.stdout().writeByte('\n');

    // find max flag length for alignment
    var max_flag_len: usize = 0;
    for (matches.items) |m| {
        if (m.len > max_flag_len) max_flag_len = m.len;
    }
    max_flag_len = @min(max_flag_len, 25);

    const items_to_show = @min(matches.items.len, max_menu_height);
    const start_idx: usize = if (matches.items.len > items_to_show) blk: {
        const half = items_to_show / 2;
        if (self.completion.index < half) break :blk 0;
        if (self.completion.index + half >= matches.items.len) break :blk matches.items.len - items_to_show;
        break :blk self.completion.index - half;
    } else 0;
    const end_idx = @min(start_idx + items_to_show, matches.items.len);

    var lines_emitted: usize = 0;
    for (start_idx..end_idx) |idx| {
        const flag = matches.items[idx];
        const cache_idx = if (idx < match_indices.len) match_indices[idx] else 0;
        const desc_len = self.cache.flag_desc_lens[cache_idx];
        const desc = if (desc_len > 0) self.cache.flag_desc_buf[self.cache.flag_desc_offsets[cache_idx] .. self.cache.flag_desc_offsets[cache_idx] + desc_len] else "";

        const display_flag = if (flag.len > 25) flag[0..24] else flag;
        const is_selected = idx == self.completion.index;

        if (is_selected) {
            try self.stdout().print("{f}", .{tty.Style.reverse});
        }
        try self.stdout().print("{s}", .{display_flag});
        if (flag.len > 25) try self.stdout().writeByte('~');
        if (is_selected) {
            try self.stdout().print("{f}", .{tty.Style.reset});
        }

        // pad to alignment column
        const actual_len = if (flag.len > 25) @as(usize, 25) else flag.len;
        const padding = if (max_flag_len + 2 > actual_len) max_flag_len + 2 - actual_len else 1;
        var p: usize = 0;
        while (p < padding) : (p += 1) try self.stdout().writeByte(' ');

        // description in dim
        if (desc.len > 0) {
            const max_desc = if (term_width > max_flag_len + 4) term_width - max_flag_len - 4 else 20;
            const show_desc = if (desc.len > max_desc) desc[0..max_desc] else desc;
            try self.stdout().print("\x1b[2m{s}\x1b[22m", .{show_desc});
        }
        try self.stdout().writeByte('\n');
        lines_emitted += 1;
    }

    if (end_idx < matches.items.len) {
        try self.stdout().print("... ({} more)\n", .{matches.items.len - end_idx});
        self.completion.menu_lines = items_to_show + 1;
        lines_emitted += 1;
    } else if (start_idx > 0) {
        try self.stdout().print("... ({} hidden above)\n", .{start_idx});
        self.completion.menu_lines = items_to_show + 1;
        lines_emitted += 1;
    } else {
        self.completion.menu_lines = items_to_show;
    }

    // Move cursor back: menu lines + 1 (the \n into menu area) + rows_below
    const total_up = lines_emitted + 1 + rows_below_cursor;
    try self.stdout().print("\x1b[{d}A", .{total_up});
    if (cursor_col > 0) {
        try self.stdout().print("\x1b[{d}G", .{cursor_col + 1});
    } else {
        try self.stdout().writeAll("\r");
    }
    try self.stdout().flush();
    self.completion.displayed = true;
    return true;
}

fn getGitBranches(self: *Shell, matches: *std.ArrayList([]const u8), pattern: []const u8) !void {
    // local branches from .git/refs/heads/
    const refs_dir = std.Io.Dir.cwd().openDir(compat.io(), ".git/refs/heads", .{ .iterate = true }) catch return;
    var dir = refs_dir;
    defer dir.close(compat.io());

    var local_set: [64][64]u8 = undefined;
    var local_lens: [64]usize = undefined;
    var local_count: usize = 0;

    var iter = dir.iterate();
    while (try iter.next(compat.io())) |entry| {
        if (entry.kind == .file and std.mem.startsWith(u8, entry.name, pattern)) {
            const branch = try self.allocator.dupe(u8, entry.name);
            try matches.append(self.allocator, branch);
            // track local branch names to avoid duplicating as remote
            if (local_count < 64 and entry.name.len < 64) {
                @memcpy(local_set[local_count][0..entry.name.len], entry.name);
                local_lens[local_count] = entry.name.len;
                local_count += 1;
            }
        }
    }

    // remote branches from .git/refs/remotes/*/
    const remotes_dir = std.Io.Dir.cwd().openDir(compat.io(), ".git/refs/remotes", .{ .iterate = true }) catch return;
    var rdir = remotes_dir;
    defer rdir.close(compat.io());

    var remote_iter = rdir.iterate();
    while (try remote_iter.next(compat.io())) |remote_entry| {
        if (remote_entry.kind != .directory) continue;
        const remote_name = remote_entry.name;

        var remote_branch_dir = rdir.openDir(compat.io(), remote_name, .{ .iterate = true }) catch continue;
        defer remote_branch_dir.close(compat.io());

        var branch_iter = remote_branch_dir.iterate();
        while (try branch_iter.next(compat.io())) |branch_entry| {
            if (branch_entry.kind != .file) continue;
            if (std.mem.eql(u8, branch_entry.name, "HEAD")) continue;
            if (!std.mem.startsWith(u8, branch_entry.name, pattern)) continue;

            // skip if already in local branches
            var is_local = false;
            for (0..local_count) |li| {
                if (local_lens[li] == branch_entry.name.len and
                    std.mem.eql(u8, local_set[li][0..local_lens[li]], branch_entry.name))
                {
                    is_local = true;
                    break;
                }
            }
            if (is_local) continue;

            const branch = try self.allocator.dupe(u8, branch_entry.name);
            try matches.append(self.allocator, branch);
        }
    }

    // also read packed-refs for branches that have been packed by git gc
    readPackedRefs(self, matches, "refs/heads/", pattern, local_set[0..local_count], local_lens[0..local_count]) catch {};
}

/// Parse .git/packed-refs for refs matching a prefix (e.g. "refs/heads/", "refs/tags/")
fn readPackedRefs(self: *Shell, matches: *std.ArrayList([]const u8), ref_prefix: []const u8, pattern: []const u8, existing: [][64]u8, existing_lens: []usize) !void {
    const file = std.Io.Dir.cwd().openFile(compat.io(), ".git/packed-refs", .{}) catch return;
    defer file.close(compat.io());

    var buf: [8192]u8 = undefined;
    const n = compat.posix.read(file.handle, &buf) catch return;
    const text = buf[0..n];

    var line_start: usize = 0;
    while (line_start < text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
        const line = text[line_start..line_end];
        line_start = line_end + 1;

        // skip comments and peeled refs (^)
        if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;

        // format: <hash> <ref>
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const ref = line[space + 1 ..];

        if (!std.mem.startsWith(u8, ref, ref_prefix)) continue;
        const branch_name = ref[ref_prefix.len..];
        if (!std.mem.startsWith(u8, branch_name, pattern)) continue;

        // deduplicate against existing matches
        var is_dup = false;
        for (0..existing.len) |ei| {
            if (existing_lens[ei] == branch_name.len and
                std.mem.eql(u8, existing[ei][0..existing_lens[ei]], branch_name))
            {
                is_dup = true;
                break;
            }
        }
        if (is_dup) continue;

        // also check already-added matches
        for (matches.items) |m| {
            if (std.mem.eql(u8, m, branch_name)) {
                is_dup = true;
                break;
            }
        }
        if (is_dup) continue;

        const owned = try self.allocator.dupe(u8, branch_name);
        try matches.append(self.allocator, owned);
    }
}

fn getGitTags(self: *Shell, matches: *std.ArrayList([]const u8), pattern: []const u8) !void {
    var existing_set: [64][64]u8 = undefined;
    var existing_lens: [64]usize = undefined;
    var existing_count: usize = 0;

    const tags_dir = std.Io.Dir.cwd().openDir(compat.io(), ".git/refs/tags", .{ .iterate = true }) catch {
        // no refs/tags dir — try packed-refs only
        readPackedRefs(self, matches, "refs/tags/", pattern, &.{}, &.{}) catch {};
        return;
    };
    var dir = tags_dir;
    defer dir.close(compat.io());

    var iter = dir.iterate();
    while (try iter.next(compat.io())) |entry| {
        if (entry.kind == .file and std.mem.startsWith(u8, entry.name, pattern)) {
            const tag = try self.allocator.dupe(u8, entry.name);
            try matches.append(self.allocator, tag);
            if (existing_count < 64 and entry.name.len < 64) {
                @memcpy(existing_set[existing_count][0..entry.name.len], entry.name);
                existing_lens[existing_count] = entry.name.len;
                existing_count += 1;
            }
        }
    }

    // also check packed-refs
    readPackedRefs(self, matches, "refs/tags/", pattern, existing_set[0..existing_count], existing_lens[0..existing_count]) catch {};
}

fn applySingleCompletion(self: *Shell, match: []const u8, word_result: WordResult) !bool {
    const pattern = word_result.word;
    const word_end = word_result.end;
    const comp_str = match[pattern.len..];

    // escape special characters for shell
    const escaped = try escapeForShell(self.allocator, comp_str);
    defer self.allocator.free(escaped);

    self.edit_buf.cursor = @intCast(word_end);
    _ = self.edit_buf.insertSlice(escaped);

    // log accepted completion for training data
    logCompletion(self.edit_buf.slice(), word_result.start, pattern, match);

    try self.renderLine();
    return true;
}

fn showCompletionMatches(self: *Shell, matches: *std.ArrayList([]const u8), word_result: WordResult, pattern: []const u8) !bool {
    if (matches.items.len == 0) return false;

    // sort matches alphabetically for predictable display and cycling order
    if (matches.items.len > 1) {
        std.mem.sort([]const u8, matches.items, {}, StringOrder.lessThan);
    }

    var common_prefix_len: usize = matches.items[0].len;
    for (matches.items[1..]) |match| {
        var i: usize = 0;
        while (i < common_prefix_len and i < match.len and matches.items[0][i] == match[i]) : (i += 1) {}
        common_prefix_len = i;
    }

    if (common_prefix_len > pattern.len) {
        const common_prefix = matches.items[0][0..common_prefix_len];
        const comp_str = common_prefix[pattern.len..];
        // escape special characters for shell
        const escaped = try escapeForShell(self.allocator, comp_str);
        defer self.allocator.free(escaped);
        self.edit_buf.cursor = @intCast(word_result.end);
        const inserted = self.edit_buf.insertSlice(escaped);
        if (inserted > 0) {
            try self.renderLine();
        }
        return true;
    }

    // enter completion mode
    exitCompletionMode(self);

    for (matches.items) |match| {
        const owned = try self.allocator.dupe(u8, match);
        try self.completion.matches.append(self.allocator, owned);
    }

    self.completion.mode = true;
    self.completion.index = self.completion.matches.items.len;
    self.completion.word_start = word_result.start;
    self.completion.word_end = word_result.end;
    self.completion.original_len = self.edit_buf.len;
    self.completion.pattern_len = pattern.len;

    try self.renderLine();
    try displayCompletions(self);
    return true;
}

pub fn exitCompletionMode(self: *Shell) void {
    if (!self.completion.mode) return;

    // clear the completion menu if displayed
    if (self.completion.displayed and self.completion.menu_lines > 0) {
        // Move past command area, clear menu, move back
        const cmd_rows = self.term_view.term.rows_owned;
        const cursor_row = self.term_view.term.row;
        const cursor_col = self.term_view.term.col;
        const rows_below = if (cmd_rows > cursor_row + 1) cmd_rows - cursor_row - 1 else 0;
        if (rows_below > 0) {
            self.stdout().print("\x1b[{d}B", .{rows_below}) catch {};
        }
        self.stdout().writeAll("\r\n\x1b[J") catch {}; // move to menu area + clear
        // Move back up: 1 (the \n) + rows_below
        const total_up = 1 + rows_below;
        self.stdout().print("\x1b[{d}A", .{total_up}) catch {};
        if (cursor_col > 0) {
            self.stdout().print("\x1b[{d}G", .{cursor_col + 1}) catch {};
        } else {
            self.stdout().writeAll("\r") catch {};
        }
        self.stdout().flush() catch {};
    }

    for (self.completion.matches.items) |match| {
        self.allocator.free(match);
    }
    self.completion.matches.clearRetainingCapacity();

    self.completion.mode = false;
    self.completion.index = 0;
    self.completion.pattern_len = 0;
    self.completion.menu_lines = 0;
    self.completion.displayed = false;
}

pub fn handleCompletionCycle(self: *Shell, direction: CycleDirection) !void {
    if (self.completion.matches.items.len == 0) return;

    const old_index = self.completion.index;
    const nothing_selected = old_index >= self.completion.matches.items.len;

    // calculate new index first
    var new_index: usize = undefined;
    switch (direction) {
        .forward => {
            if (nothing_selected) {
                new_index = 0;
            } else {
                new_index = (self.completion.index + 1) % self.completion.matches.items.len;
            }
        },
        .backward => {
            if (nothing_selected) {
                new_index = self.completion.matches.items.len - 1;
            } else if (self.completion.index == 0) {
                new_index = self.completion.matches.items.len - 1;
            } else {
                new_index = self.completion.index - 1;
            }
        },
    }

    // zsh-style: if cycling back to same directory (wrapped), drill into it
    if (direction == .forward and !nothing_selected and new_index == old_index) {
        const current_match = self.completion.matches.items[self.completion.index];
        if (std.mem.endsWith(u8, current_match, "/")) {
            exitCompletionMode(self);
            try self.renderLine();
            return try handleTabCompletion(self);
        }
    }

    self.completion.index = new_index;

    try applyCompletion(self, self.completion.pattern_len);

    // Always clear from command start to end of screen before redrawing
    if (self.term_view.term.row > 0) {
        try self.stdout().print("\x1b[{d}A", .{self.term_view.term.row});
    }
    try self.stdout().writeAll("\r\x1b[J");
    try self.stdout().flush();
    self.term_view.term.row = 0;
    self.term_view.term.col = 0;
    self.term_view.last_hash = 0;
    try self.renderLine();
    try displayCompletions(self);
}

fn applyCompletion(self: *Shell, pattern_len: usize) !void {
    if (self.completion.matches.items.len == 0) return;

    const match = self.completion.matches.items[self.completion.index];
    const comp_str = match[pattern_len..];

    // escape special characters for shell
    const escaped = escapeForShell(self.allocator, comp_str) catch return;
    defer self.allocator.free(escaped);

    self.edit_buf.len = @intCast(self.completion.original_len);
    self.edit_buf.cursor = @intCast(self.completion.word_end);
    _ = self.edit_buf.insertSlice(escaped);

    // log accepted completion for training data
    const pattern = match[0..pattern_len];
    logCompletion(self.edit_buf.slice(), self.completion.word_start, pattern, match);
}

pub fn displayCompletions(self: *Shell) !void {
    if (self.completion.matches.items.len == 0) return;

    const term_width = self.terminal_width;
    const term_height = self.terminal_height;
    const max_menu_height = if (term_height > 3) term_height - 3 else 1;

    // Move cursor to the end of the command area (past all owned rows)
    const cmd_rows = self.term_view.term.rows_owned;
    const cursor_row = self.term_view.term.row;
    const cursor_col = self.term_view.term.col;
    const rows_below = if (cmd_rows > cursor_row + 1) cmd_rows - cursor_row - 1 else 0;
    if (rows_below > 0) {
        try self.stdout().print("\x1b[{d}B", .{rows_below});
    }
    // Move to column 1, then one line down into the menu area
    try self.stdout().writeAll("\r\n\x1b[J"); // CR + LF + clear below

    // Track total lines emitted so we can move cursor back up
    var lines_emitted: usize = 0;

    if (term_width < 80) {
        const items_to_show = @min(self.completion.matches.items.len, max_menu_height);
        const start_idx = if (self.completion.matches.items.len > items_to_show) blk: {
            const half_window = items_to_show / 2;
            if (self.completion.index < half_window) {
                break :blk 0;
            } else if (self.completion.index + half_window >= self.completion.matches.items.len) {
                break :blk self.completion.matches.items.len - items_to_show;
            } else {
                break :blk self.completion.index - half_window;
            }
        } else 0;

        const end_idx = @min(start_idx + items_to_show, self.completion.matches.items.len);

        for (self.completion.matches.items[start_idx..end_idx], start_idx..) |match, mi| {
            if (mi == self.completion.index and self.completion.index < self.completion.matches.items.len) {
                try self.stdout().print("{f}{s}{f}\r\n", .{ tty.Style.reverse, match, tty.Style.reset });
            } else {
                try self.stdout().print("{s}\r\n", .{match});
            }
            lines_emitted += 1;
        }

        if (end_idx < self.completion.matches.items.len) {
            try self.stdout().print("... ({} more)\r\n", .{self.completion.matches.items.len - end_idx});
            self.completion.menu_lines = items_to_show + 1;
            lines_emitted += 1;
        } else if (start_idx > 0) {
            try self.stdout().print("... ({} hidden above)\r\n", .{start_idx});
            self.completion.menu_lines = items_to_show + 1;
            lines_emitted += 1;
        } else {
            self.completion.menu_lines = items_to_show;
        }

        // Move cursor back: menu lines + 1 (the \n into menu area) + rows_below
        const total_up = lines_emitted + 1 + rows_below;
        try self.stdout().print("\x1b[{d}A", .{total_up});
        // Restore column position
        if (cursor_col > 0) {
            try self.stdout().print("\x1b[{d}G", .{cursor_col + 1}); // 1-based
        } else {
            try self.stdout().writeAll("\r");
        }
        try self.stdout().flush();
        self.completion.displayed = true;
        return;
    }

    const max_item_width: usize = 30;
    var max_len: usize = 0;
    for (self.completion.matches.items) |match| {
        const display_len = @min(match.len, max_item_width);
        if (display_len > max_len) max_len = display_len;
    }
    const col_width = max_len + 2;
    const max_line_width: usize = 120;
    const effective_width = @min(term_width, max_line_width);
    const cols = @max(1, effective_width / col_width);

    const total_menu_lines = (self.completion.matches.items.len + cols - 1) / cols;
    const menu_lines_count = @min(total_menu_lines, max_menu_height);
    self.completion.menu_lines = menu_lines_count;

    const max_items = menu_lines_count * cols;
    const items_to_show = @min(self.completion.matches.items.len, max_items);

    const start_item = if (self.completion.matches.items.len > items_to_show) blk: {
        const half = items_to_show / 2;
        if (self.completion.index < half) {
            break :blk @as(usize, 0);
        } else if (self.completion.index + half >= self.completion.matches.items.len) {
            break :blk self.completion.matches.items.len - items_to_show;
        } else {
            break :blk self.completion.index - half;
        }
    } else 0;
    const end_item = @min(start_item + items_to_show, self.completion.matches.items.len);

    // Draw items in columns, using \r\n for line breaks
    var col_pos: usize = 0;

    for (self.completion.matches.items[start_item..end_item], start_item..) |match, i| {
        const display_name = if (max_item_width > 1 and match.len > max_item_width) match[0 .. max_item_width - 1] else match;
        const truncated = max_item_width > 0 and match.len > max_item_width;

        if (i == self.completion.index and self.completion.index < self.completion.matches.items.len) {
            try self.stdout().print("{f}{s}", .{ tty.Style.reverse, display_name });
            if (truncated) try self.stdout().writeByte('~');
            try self.stdout().print("{f}", .{tty.Style.reset});
        } else {
            try self.stdout().print("{s}", .{display_name});
            if (truncated) try self.stdout().writeByte('~');
        }

        const actual_len = if (truncated) max_item_width else match.len;
        const padding = col_width - actual_len;
        var j: usize = 0;
        while (j < padding) : (j += 1) try self.stdout().writeByte(' ');

        col_pos += 1;
        if (col_pos >= cols) {
            try self.stdout().writeAll("\r\n");
            col_pos = 0;
            lines_emitted += 1;
        }
    }
    // End last row if not already ended
    if (col_pos > 0) {
        try self.stdout().writeAll("\r\n");
        lines_emitted += 1;
    }

    const hidden = self.completion.matches.items.len - (end_item - start_item);
    if (hidden > 0) {
        try self.stdout().print("... ({} more matches)\r\n", .{hidden});
        self.completion.menu_lines += 1;
        lines_emitted += 1;
    }

    // Move cursor back: menu lines + 1 (the \n into menu area) + rows_below
    const total_up = lines_emitted + 1 + rows_below;
    try self.stdout().print("\x1b[{d}A", .{total_up});
    // Restore column position
    if (cursor_col > 0) {
        try self.stdout().print("\x1b[{d}G", .{cursor_col + 1}); // 1-based
    } else {
        try self.stdout().writeAll("\r");
    }
    try self.stdout().flush();
    self.completion.displayed = true;
}

// Log accepted/rejected completions to ~/.zish/completion_log.jsonl for training.
// Accepted: user pressed Tab/Right to accept ghost text → positive signal
// Rejected: user typed a different character while ghost text was visible → negative signal
// Format: {"ctx":"text","pfx":"prefix","cmp":"completion","src":"ghost_h","act":"accept|reject","ts":N}
// This data enables Libratus-style counterfactual regret training:
// the model learns from its mistakes by seeing what the user actually typed.
const CompletionSource = enum { tab, ghost_history, history_menu };

fn logCompletionWith(cmd: []const u8, word_start: usize, prefix: []const u8, completion: []const u8, source: CompletionSource) void {
    logCompletionImpl(cmd, word_start, prefix, completion, source);
}

fn logCompletion(cmd: []const u8, word_start: usize, prefix: []const u8, completion: []const u8) void {
    logCompletionImpl(cmd, word_start, prefix, completion, .tab);
}

fn logCompletionImpl(cmd: []const u8, word_start: usize, prefix: []const u8, completion: []const u8, source: CompletionSource) void {
    var path_buf: [512]u8 = undefined;
    const home = compat.getEnvVarOwned(std.heap.page_allocator, "HOME") catch return;
    defer std.heap.page_allocator.free(home);
    const path = std.fmt.bufPrint(&path_buf, "{s}/.zish/completion_log.jsonl", .{home}) catch return;

    const file = std.Io.Dir.cwd().openFile(compat.io(), path, .{ .mode = .write_only }) catch |e| switch (e) {
        error.FileNotFound => std.Io.Dir.cwd().createFile(compat.io(), path, .{}) catch return,
        else => return,
    };
    defer file.close(compat.io());
    _ = compat.posix.lseek(file.handle, 0, 2) catch {}; // 2 = SEEK_END

    const ctx = cmd[0..@min(word_start, cmd.len)];
    const ts: u64 = @bitCast(compat.timestamp());

    // write JSON with manual escaping
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    pos += copySlice(&buf, pos, "{\"ctx\":\"");
    pos = writeJsonEscaped(&buf, pos, ctx);
    pos += copySlice(&buf, pos, "\",\"pfx\":\"");
    pos = writeJsonEscaped(&buf, pos, prefix);
    pos += copySlice(&buf, pos, "\",\"cmp\":\"");
    pos = writeJsonEscaped(&buf, pos, completion);
    pos += copySlice(&buf, pos, "\",\"src\":\"");
    pos += copySlice(&buf, pos, switch (source) {
        .tab => "tab",
        .ghost_history => "ghost_h",
        .history_menu => "hist",
    });
    pos += copySlice(&buf, pos, "\",\"ts\":");
    pos += (std.fmt.bufPrint(buf[pos..], "{d}", .{ts}) catch return).len;
    pos += copySlice(&buf, pos, "}\n");

    _ = compat.posix.write(file.handle, buf[0..pos]) catch {};
}

fn copySlice(buf: *[4096]u8, pos: usize, s: []const u8) usize {
    if (pos + s.len > buf.len) return 0;
    @memcpy(buf[pos..][0..s.len], s);
    return s.len;
}

fn writeJsonEscaped(buf: *[4096]u8, start: usize, s: []const u8) usize {
    var pos = start;
    for (s) |c| {
        if (pos + 6 > buf.len) break;
        switch (c) {
            '"' => {
                pos += copySlice(buf, pos, "\\\"");
            },
            '\\' => {
                pos += copySlice(buf, pos, "\\\\");
            },
            '\n' => {
                pos += copySlice(buf, pos, "\\n");
            },
            '\r' => {
                pos += copySlice(buf, pos, "\\r");
            },
            '\t' => {
                pos += copySlice(buf, pos, "\\t");
            },
            else => if (c < 0x20) {
                const hex = "0123456789abcdef";
                buf[pos] = '\\';
                buf[pos + 1] = 'u';
                buf[pos + 2] = '0';
                buf[pos + 3] = '0';
                buf[pos + 4] = hex[c >> 4];
                buf[pos + 5] = hex[c & 0xf];
                pos += 6;
            } else {
                buf[pos] = c;
                pos += 1;
            },
        }
    }
    return pos;
}

// ============================================================
// Ghost text autosuggestion (fish-style)
// ============================================================

/// Update ghost text suggestion based on current input.
/// Searches history for a prefix match and stores the suffix in ghost_buf.
/// Try to suggest a file path from CWD as ghost text.
/// Returns true if a suggestion was found and set.
fn ghostFileSuggestion(self: *Shell, partial: []const u8) bool {
    // Split into directory and prefix
    const last_slash = std.mem.lastIndexOfScalar(u8, partial, '/');
    const dir_path = if (last_slash) |s| partial[0 .. s + 1] else "./";
    const file_prefix = if (last_slash) |s| partial[s + 1 ..] else partial;

    if (file_prefix.len == 0) return false;

    // Open directory
    var dir = if (dir_path[0] == '/')
        std.Io.Dir.openDirAbsolute(compat.io(), dir_path, .{ .iterate = true }) catch return false
    else
        std.Io.Dir.cwd().openDir(compat.io(), dir_path, .{ .iterate = true }) catch return false;
    defer dir.close(compat.io());

    // Find first match
    var iter = dir.iterate();
    var best: [256]u8 = undefined;
    var best_len: usize = 0;

    while (iter.next(compat.io()) catch null) |entry| {
        if (entry.name.len > file_prefix.len and
            std.mem.startsWith(u8, entry.name, file_prefix))
        {
            const suffix = entry.name[file_prefix.len..];
            if (best_len == 0 or entry.name.len < best_len + file_prefix.len) {
                const n = @min(suffix.len, best.len);
                @memcpy(best[0..n], suffix[0..n]);
                best_len = n;
                // Append / for directories
                if (entry.kind == .directory and best_len < best.len) {
                    best[best_len] = '/';
                    best_len += 1;
                }
            }
        }
    }

    if (best_len > 0) {
        const n = @min(best_len, self.ghost.buf.len);
        @memcpy(self.ghost.buf[0..n], best[0..n]);
        self.ghost.len = n;
        return true;
    }
    return false;
}

pub fn updateGhostText(self: *Shell) void {
    self.ghost.len = 0;

    if (!self.ghost.enabled) return;

    // only suggest when cursor is at end and we have content
    const cmd = self.edit_buf.slice();
    if (cmd.len < 2 or self.edit_buf.cursor != self.edit_buf.len) return;
    if (self.completion.mode) return;

    // Strategy 0: CWD-aware file path completion
    // If user is typing a path-like thing (contains / or starts with . or after space)
    if (cmd.len > 0) {
        const last_space = std.mem.lastIndexOfScalar(u8, cmd, ' ');
        const word_start = if (last_space) |s| s + 1 else 0;
        const word = cmd[word_start..];
        if (word.len >= 1 and (word[0] == '.' or word[0] == '/' or word[0] == '~')) {
            // Try file path completion as ghost text
            if (ghostFileSuggestion(self, word)) return;
        }
    }

    // Strategy 1: frecency-ranked history prefix match (collect top N candidates)
    const h = self.history orelse return;
    const items = h.entries.items;
    const now_ts: u32 = @intCast(@min(@as(u64, @intCast(compat.timestamp())), std.math.maxInt(u32)));

    const MAX_CANDIDATES = 8;
    var cand_scores: [MAX_CANDIDATES]f32 = [_]f32{0} ** MAX_CANDIDATES;
    var cand_idxs: [MAX_CANDIDATES]usize = undefined;
    var cand_count: u8 = 0;

    for (0..items.len) |i| {
        const idx = items.len - 1 - i;
        const entry = items[idx];
        if (entry.exit_code == 127) continue; // don't ghost a command-not-found line
        const command = h.getCommand(entry);
        if (command.len > cmd.len and std.mem.startsWith(u8, command, cmd)) {
            const age_secs: f32 = @floatFromInt(if (now_ts > entry.timestamp) now_ts - entry.timestamp else 0);
            const hours = age_secs / 3600.0;
            const decay = @exp(-0.029 * hours);
            const freq: f32 = @floatFromInt(@max(entry.frequency, 1));
            const score = freq * decay;

            // Check for duplicate suffixes
            const suffix = command[cmd.len..];
            var is_dup = false;
            for (0..cand_count) |ci| {
                const existing = h.getCommand(items[cand_idxs[ci]]);
                if (std.mem.eql(u8, existing[cmd.len..], suffix)) {
                    is_dup = true;
                    break;
                }
            }
            if (is_dup) continue;

            // Insert into sorted candidates
            if (cand_count < MAX_CANDIDATES) {
                cand_idxs[cand_count] = idx;
                cand_scores[cand_count] = score;
                cand_count += 1;
            } else if (score > cand_scores[cand_count - 1]) {
                cand_idxs[cand_count - 1] = idx;
                cand_scores[cand_count - 1] = score;
            }
            // Bubble sort to keep sorted
            if (cand_count > 1) {
                var si = cand_count - 1;
                while (si > 0 and cand_scores[si] > cand_scores[si - 1]) {
                    std.mem.swap(f32, &cand_scores[si], &cand_scores[si - 1]);
                    std.mem.swap(usize, &cand_idxs[si], &cand_idxs[si - 1]);
                    si -= 1;
                }
            }
            if (i > 500) break;
        }
    }

    // Store all candidates
    self.ghost.candidate_count = cand_count;
    for (0..cand_count) |ci| {
        const command = h.getCommand(items[cand_idxs[ci]]);
        const suffix = command[cmd.len..];
        const n = @min(suffix.len, self.ghost.candidates[ci].len);
        @memcpy(self.ghost.candidates[ci][0..n], suffix[0..n]);
        self.ghost.candidate_lens[ci] = n;
    }

    // Show first candidate
    if (cand_count > 0) {
        // Keep current index if still valid, otherwise reset
        if (self.ghost.candidate_idx >= cand_count) self.ghost.candidate_idx = 0;
        const ci = self.ghost.candidate_idx;
        const n = self.ghost.candidate_lens[ci];
        @memcpy(self.ghost.buf[0..n], self.ghost.candidates[ci][0..n]);
        self.ghost.len = n;
        return;
    }

    // Strategy 2: match last segment after pipe/semicolon
    // e.g. "git log | grep fo" matches history "grep foo --color" → suggests "o --color"
    const last_seg = blk: {
        var pos = cmd.len;
        while (pos > 0) : (pos -= 1) {
            if (cmd[pos - 1] == '|' or cmd[pos - 1] == ';') {
                break :blk std.mem.trimStart(u8, cmd[pos..], " \t");
            }
        }
        break :blk @as([]const u8, "");
    };
    if (last_seg.len >= 2) {
        var seg_best_idx: ?usize = null;
        var seg_best_freq: u16 = 0;
        var seg_best_ts: u32 = 0;
        for (0..items.len) |i| {
            const idx = items.len - 1 - i;
            const entry = items[idx];
            const command = h.getCommand(entry);
            if (command.len > last_seg.len and std.mem.startsWith(u8, command, last_seg)) {
                if (seg_best_idx == null or entry.frequency > seg_best_freq or
                    (entry.frequency == seg_best_freq and entry.timestamp > seg_best_ts))
                {
                    seg_best_idx = idx;
                    seg_best_freq = entry.frequency;
                    seg_best_ts = entry.timestamp;
                }
                if (i > 500) break;
            }
        }
        if (seg_best_idx) |idx| {
            const command = h.getCommand(items[idx]);
            const suffix = command[last_seg.len..];
            const n = @min(suffix.len, self.ghost.buf.len);
            @memcpy(self.ghost.buf[0..n], suffix[0..n]);
            self.ghost.len = n;
        }
    }

    // Strategy 3: common command subcommand suggestions
    if (cmd.len >= 4) {
        const suggestions = [_]struct { prefix: []const u8, completion: []const u8 }{
            .{ .prefix = "git c", .completion = "ommit" },
            .{ .prefix = "git s", .completion = "tatus" },
            .{ .prefix = "git p", .completion = "ush" },
            .{ .prefix = "git pu", .completion = "ll" },
            .{ .prefix = "git d", .completion = "iff" },
            .{ .prefix = "git l", .completion = "og --oneline" },
            .{ .prefix = "git a", .completion = "dd" },
            .{ .prefix = "git ch", .completion = "eckout" },
            .{ .prefix = "git b", .completion = "ranch" },
            .{ .prefix = "git m", .completion = "erge" },
            .{ .prefix = "git r", .completion = "ebase" },
            .{ .prefix = "git st", .completion = "ash" },
            .{ .prefix = "docker p", .completion = "s" },
            .{ .prefix = "docker r", .completion = "un" },
            .{ .prefix = "docker b", .completion = "uild" },
            .{ .prefix = "docker c", .completion = "ompose" },
            .{ .prefix = "zig b", .completion = "uild" },
            .{ .prefix = "zig t", .completion = "est" },
            .{ .prefix = "cargo b", .completion = "uild" },
            .{ .prefix = "cargo t", .completion = "est" },
            .{ .prefix = "cargo r", .completion = "un" },
            .{ .prefix = "make i", .completion = "nstall" },
            .{ .prefix = "sudo m", .completion = "ake install" },
        };
        for (&suggestions) |s| {
            if (std.mem.startsWith(u8, cmd, s.prefix) and cmd.len == s.prefix.len) {
                const n = @min(s.completion.len, self.ghost.buf.len);
                @memcpy(self.ghost.buf[0..n], s.completion[0..n]);
                self.ghost.len = n;
                return;
            }
        }
    }
}

/// Cycle ghost text to next/previous candidate (Alt+Down / Alt+Up)
pub fn cycleGhostCandidate(self: *Shell, direction: i8) bool {
    if (self.ghost.candidate_count <= 1) return false;
    if (direction > 0) {
        self.ghost.candidate_idx = (self.ghost.candidate_idx + 1) % self.ghost.candidate_count;
    } else {
        self.ghost.candidate_idx = if (self.ghost.candidate_idx == 0) self.ghost.candidate_count - 1 else self.ghost.candidate_idx - 1;
    }
    const ci = self.ghost.candidate_idx;
    const n = self.ghost.candidate_lens[ci];
    @memcpy(self.ghost.buf[0..n], self.ghost.candidates[ci][0..n]);
    self.ghost.len = n;
    return true;
}

/// Start the ghost inference background thread (called when completion_model is configured).
// Model-backed ghost text was removed along with src/inference/.
//
// Ghost text itself still works: the suggestion comes from history prefix
// matching (searchHistoryGhost) and completion candidates, which is where the
// useful suggestions came from anyway — a local model only helped on the tail,
// commands you had not run before.
//
// What went with it: a GGUF parser handling attacker-supplied model files, a
// Vulkan backend loaded by dlopen, a fork-server with its own wire protocol,
// and a CTM implementation. ~7,700 lines whose only job in a shell was to grey
// out a suggestion. The shell executes commands with the user's full authority;
// it should not also be a model runtime.


/// Accept ghost text — append it to the edit buffer.
/// Returns true if ghost text was accepted.
pub fn acceptGhostText(self: *Shell) bool {
    if (self.ghost.len == 0) return false;
    if (self.edit_buf.cursor != self.edit_buf.len) return false;

    const ghost = self.ghost.buf[0..self.ghost.len];
    _ = self.edit_buf.insertSlice(ghost);
    self.ghost.len = 0;

    // log accepted ghost suggestion with source tracking
    logCompletionWith(self.edit_buf.slice(), 0, "", self.edit_buf.slice(),
        .ghost_history);

    return true;
}



/// Accept one character of ghost text (Alt+E).
/// Returns true if a char was accepted.
pub fn acceptGhostChar(self: *Shell) bool {
    if (self.ghost.len == 0) return false;
    if (self.edit_buf.cursor != self.edit_buf.len) return false;

    const ghost = self.ghost.buf[0..self.ghost.len];
    _ = self.edit_buf.insertSlice(ghost[0..1]);
    // shift ghost left by one char
    std.mem.copyForwards(u8, self.ghost.buf[0 .. self.ghost.len - 1], self.ghost.buf[1..self.ghost.len]);
    self.ghost.len -= 1;
    return true;
}

/// Toggle ghost autosuggestion on/off (Ctrl+O).
pub fn toggleGhost(self: *Shell) void {
    self.ghost.enabled = !self.ghost.enabled;
    if (!self.ghost.enabled) self.ghost.len = 0;
}
/// Accept one word from ghost text (Ctrl+Right).
/// Returns true if a word was accepted.
pub fn acceptGhostWord(self: *Shell) bool {
    if (self.ghost.len == 0) return false;
    if (self.edit_buf.cursor != self.edit_buf.len) return false;

    const ghost = self.ghost.buf[0..self.ghost.len];

    // find end of first word: skip leading spaces, then skip non-spaces
    var i: usize = 0;
    while (i < ghost.len and ghost[i] == ' ') : (i += 1) {}
    while (i < ghost.len and ghost[i] != ' ') : (i += 1) {}

    if (i == 0) return false;

    // insert the word
    _ = self.edit_buf.insertSlice(ghost[0..i]);

    // shift remaining ghost text
    const remaining = self.ghost.len - i;
    if (remaining > 0) {
        std.mem.copyForwards(u8, &self.ghost.buf, self.ghost.buf[i..self.ghost.len]);
    }
    self.ghost.len = remaining;

    return true;
}

// -------- feat builtin completion (subcommands + feat names) --------
fn featRegRoot(self: *Shell, buf: []u8) ?[]const u8 {
    if (compat.getEnvVarOwned(self.allocator, "ZISH_FEAT_PATH")) |p| {
        defer self.allocator.free(p);
        if (p.len < buf.len) {
            @memcpy(buf[0..p.len], p);
            return buf[0..p.len];
        }
        return null;
    } else |_| {}
    const home = compat.getEnvVarOwned(self.allocator, "HOME") catch return null;
    defer self.allocator.free(home);
    return std.fmt.bufPrint(buf, "{s}/.zish/feats", .{home}) catch null;
}

fn featCollectNames(self: *Shell, matches: *std.ArrayList([]const u8), pattern: []const u8) !void {
    var seen = std.StringHashMap(void).init(self.allocator);
    defer seen.deinit();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = featRegRoot(self, &root_buf) orelse return;

    const tiers = [_][]const u8{ "standard", "extra" };
    for (tiers) |tier| {
        var tb: [std.fs.max_path_bytes]u8 = undefined;
        const td = std.fmt.bufPrint(&tb, "{s}/{s}", .{ root, tier }) catch continue;
        var dir = std.Io.Dir.cwd().openDir(compat.io(), td, .{ .iterate = true }) catch continue;
        defer dir.close(compat.io());
        var iter = dir.iterate();
        while (iter.next(compat.io()) catch null) |entry| {
            if (entry.kind != .directory) continue;
            const name = entry.name;
            if (name.len == 0 or name[0] == '.') continue;
            if (!std.mem.startsWith(u8, name, pattern)) continue;
            if (seen.contains(name)) continue;
            const dup = self.allocator.dupe(u8, name) catch continue;
            seen.put(dup, {}) catch {
                self.allocator.free(dup);
                continue;
            };
            matches.append(self.allocator, dup) catch {
                self.allocator.free(dup);
                continue;
            };
        }
    }
}

fn tryFeatCompletion(self: *Shell, cmd: []const u8, word_result: WordResult) !bool {
    const trimmed = std.mem.trimStart(u8, cmd, " \t");
    if (!std.mem.startsWith(u8, trimmed, "feat")) return false;
    if (trimmed.len > 4 and trimmed[4] != ' ' and trimmed[4] != '\t') return false;

    // tokenize what's completed before the cursor to find position + previous token
    var prev_token: ?[]const u8 = null;
    var tokens: usize = 0;
    var it = std.mem.tokenizeAny(u8, cmd[0..word_result.start], " \t");
    while (it.next()) |t| {
        prev_token = t;
        tokens += 1;
    }
    const pattern = word_result.word;

    if (tokens == 1) {
        // second word: complete subcommands
        const subcmds = [_][]const u8{ "list", "help", "run" };
        var matches = try std.ArrayList([]const u8).initCapacity(self.allocator, 4);
        defer {
            for (matches.items) |m| self.allocator.free(m);
            matches.deinit(self.allocator);
        }
        for (subcmds) |s| {
            if (std.mem.startsWith(u8, s, pattern))
                matches.append(self.allocator, self.allocator.dupe(u8, s) catch continue) catch continue;
        }
        if (matches.items.len == 0) return false;
        if (matches.items.len == 1) return try applySingleCompletion(self, matches.items[0], word_result);
        return try showCompletionMatches(self, &matches, word_result, pattern);
    }

    if (tokens == 2 and prev_token != null and
        (std.mem.eql(u8, prev_token.?, "run") or std.mem.eql(u8, prev_token.?, "help")))
    {
        // third word after run/help: complete feat names from the registry
        var matches = try std.ArrayList([]const u8).initCapacity(self.allocator, 16);
        defer {
            for (matches.items) |m| self.allocator.free(m);
            matches.deinit(self.allocator);
        }
        try featCollectNames(self, &matches, pattern);
        if (matches.items.len == 0) return false;
        std.mem.sort([]const u8, matches.items, {}, StringOrder.lessThan);
        if (matches.items.len == 1) return try applySingleCompletion(self, matches.items[0], word_result);
        return try showCompletionMatches(self, &matches, word_result, pattern);
    }

    return false;
}
