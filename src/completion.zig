// completion.zig - Tab completion logic for zish
const std = @import("std");
const Shell = @import("Shell.zig");
const tty = @import("tty.zig");
const git = @import("git.zig");
const editor = @import("editor.zig");
const input_mod = @import("input.zig");
const keywords = @import("keywords.zig");
const hist = @import("history.zig");

pub const WordResult = struct {
    word: []const u8,
    start: usize,
    end: usize,
};

pub const CycleDirection = input_mod.CycleDirection;

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
            const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch break :blk word;
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
        var d = std.fs.cwd().openDir(check_path, .{}) catch break :blk word;
        d.close();

        // it's a directory - insert / into buffer and update effective_word
        self.edit_buf.cursor = @intCast(word_end);
        _ = self.edit_buf.insertSlice("/");
        effective_word_end = word_end + 1;
        inserted_slash = true;
        self.skip_next_slash = true; // skip if user types / right after

        // append / conceptually for pattern matching
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
                const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch break :blk dir_part;
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
        const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch break :blk ".";
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
        const t = std.mem.trimLeft(u8, cmd, " \t");
        if (std.mem.startsWith(u8, t, "cd ") or std.mem.startsWith(u8, t, "pushd ") or
            std.mem.startsWith(u8, t, "mkdir ") or std.mem.startsWith(u8, t, "rmdir "))
            break :blk true;
        break :blk false;
    };

    const dir = std.fs.cwd().openDir(search_dir, .{ .iterate = true }) catch return;
    var iter = dir.iterate();
    const show_hidden = pattern.len > 0 and pattern[0] == '.';
    while (try iter.next()) |entry| {
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
                    var d = std.fs.cwd().openDir(full_path, .{}) catch break :blk false;
                    d.close();
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
            try self.stdout().writeAll("\x1b" ++ "7\n\n\x1b" ++ "8");
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
            try self.completion_matches.append(self.allocator, owned);
        }

        self.completion_mode = true;
        self.completion_index = self.completion_matches.items.len;
        self.completion_word_start = word_result.start;
        self.completion_word_end = effective_word_end;
        self.completion_original_len = self.edit_buf.len;
        self.completion_pattern_len = pattern.len;

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
    const environ = std.os.environ;
    for (environ) |env_ptr| {
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

    std.mem.sort([]const u8, matches.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

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
    const trimmed = std.mem.trimLeft(u8, cmd, " \t");
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
    if (std.process.getEnvVarOwned(self.allocator, "HOME")) |home| {
        defer self.allocator.free(home);
        var path_buf: [512]u8 = undefined;

        // SSH config: Host lines
        const config_path = std.fmt.bufPrint(&path_buf, "{s}/.ssh/config", .{home}) catch "";
        if (config_path.len > 0) {
            if (std.fs.cwd().openFile(config_path, .{})) |file| {
                defer file.close();
                var read_buf: [8192]u8 = undefined;
                const n = file.read(&read_buf) catch 0;
                const text = read_buf[0..n];
                var line_start: usize = 0;
                while (line_start < text.len) {
                    const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
                    const line = std.mem.trimLeft(u8, text[line_start..line_end], " \t");
                    line_start = line_end + 1;
                    // Match "Host " (case-insensitive)
                    if (line.len > 5 and (line[0] == 'H' or line[0] == 'h') and
                        (std.mem.startsWith(u8, line, "Host ") or std.mem.startsWith(u8, line, "host ")))
                    {
                        // Can have multiple hosts on one line
                        var rest = std.mem.trimLeft(u8, line[5..], " \t");
                        while (rest.len > 0) {
                            const host_end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
                            const host = rest[0..host_end];
                            rest = if (host_end < rest.len) std.mem.trimLeft(u8, rest[host_end..], " \t") else "";
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
            if (std.fs.cwd().openFile(known_path, .{})) |file| {
                defer file.close();
                var read_buf: [32768]u8 = undefined;
                const n = file.read(&read_buf) catch 0;
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
    const trimmed = std.mem.trimLeft(u8, cmd, " \t");
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
        var child = std.process.Child.init(
            &.{ "/bin/sh", "-c", "ps -eo comm= 2>/dev/null | sort -u" },
            self.allocator,
        );
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        child.spawn() catch return false;

        const stdout = child.stdout.?;
        var read_buf: [8192]u8 = undefined;
        var total: usize = 0;
        while (total < read_buf.len) {
            const n = stdout.read(read_buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        }
        _ = child.wait() catch {};

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
    const trimmed = std.mem.trimLeft(u8, cmd, " \t");
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
    const file = std.fs.cwd().openFile(makefile_name, .{}) catch blk: {
        if (std.mem.eql(u8, makefile_name, "Makefile")) {
            break :blk std.fs.cwd().openFile("makefile", .{}) catch return false;
        }
        return false;
    };
    defer file.close();

    var read_buf: [32768]u8 = undefined;
    const n = file.read(&read_buf) catch return false;
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
    const trimmed = std.mem.trimLeft(u8, cmd, " \t");
    if (!std.mem.startsWith(u8, trimmed, "just ") and !std.mem.eql(u8, trimmed, "just")) return false;
    const pattern = word_result.word;

    // Try justfile, then Justfile
    const file = std.fs.cwd().openFile("justfile", .{}) catch
        std.fs.cwd().openFile("Justfile", .{}) catch return false;
    defer file.close();

    var read_buf: [16384]u8 = undefined;
    const n = file.read(&read_buf) catch return false;
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
    const trimmed = std.mem.trimLeft(u8, cmd, " \t");
    const cmd_end = std.mem.indexOfAny(u8, trimmed, " \t") orelse return false;
    const base_cmd = trimmed[0..cmd_end];

    const is_systemctl = std.mem.eql(u8, base_cmd, "systemctl");
    const is_journalctl = std.mem.eql(u8, base_cmd, "journalctl");
    if (!is_systemctl and !is_journalctl) return false;

    // For journalctl, only complete after -u flag
    if (is_journalctl) {
        const rest = std.mem.trimLeft(u8, trimmed[cmd_end..], " \t");
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
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch continue;
        defer dir.close();
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
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
    const trimmed = std.mem.trimLeft(u8, cmd, " \t");
    const cmd_end = std.mem.indexOfAny(u8, trimmed, " \t") orelse return false;
    const base_cmd = trimmed[0..cmd_end];
    if (!std.mem.eql(u8, base_cmd, "docker") and !std.mem.eql(u8, base_cmd, "podman")) return false;

    // Find subcommand
    const rest = std.mem.trimLeft(u8, trimmed[cmd_end..], " \t");
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

    var child = std.process.Child.init(list_cmd, self.allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;

    const stdout = child.stdout.?;
    var read_buf: [8192]u8 = undefined;
    var total: usize = 0;
    while (total < read_buf.len) {
        const n = stdout.read(read_buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    _ = child.wait() catch {};

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
    const path_env = std.process.getEnvVarOwned(self.allocator, "PATH") catch {
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

        const dir = std.fs.cwd().openDir(path_dir, .{ .iterate = true }) catch continue;
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            if (!std.mem.startsWith(u8, entry.name, pattern)) continue;
            if (seen.contains(entry.name)) continue;

            // check if executable
            const full_path = std.fs.path.join(self.allocator, &.{ path_dir, entry.name }) catch continue;
            defer self.allocator.free(full_path);

            const stat = std.fs.cwd().statFile(full_path) catch continue;
            if (stat.mode & 0o111 == 0) continue;

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
    std.mem.sort([]const u8, matches.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    if (matches.items.len == 1) {
        return try applySingleCompletion(self, matches.items[0], word_result);
    } else {
        return try showCompletionMatches(self, &matches, word_result, pattern);
    }
}

/// Project-aware completions: zig build targets, cargo bins/examples, npm scripts
fn tryProjectCompletion(self: *Shell, cmd: []const u8, word_result: WordResult) !bool {
    const trimmed = std.mem.trimLeft(u8, cmd, " \t");
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
    const file = std.fs.cwd().openFile("build.zig", .{}) catch return false;
    defer file.close();

    var read_buf: [32768]u8 = undefined;
    const n = file.read(&read_buf) catch return false;
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
    if (std.fs.cwd().openDir("src/bin", .{ .iterate = true })) |dir_handle| {
        var dir = dir_handle;
        defer dir.close();
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
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
    if (std.fs.cwd().openDir("examples", .{ .iterate = true })) |dir_handle| {
        var dir = dir_handle;
        defer dir.close();
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
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
    if (std.fs.cwd().openFile("Cargo.toml", .{})) |file| {
        defer file.close();
        var read_buf: [8192]u8 = undefined;
        const n = file.read(&read_buf) catch 0;
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
    const file = std.fs.cwd().openFile("package.json", .{}) catch return false;
    defer file.close();

    var read_buf: [16384]u8 = undefined;
    const n = file.read(&read_buf) catch return false;
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
    var matches = std.ArrayList([]const u8){};
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
    const prefix = std.mem.trimLeft(u8, current_input, " \t");
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
    self.completion_matches.deinit(self.allocator);
    self.completion_matches = .{};
    for (matches.items) |m| {
        const owned = try self.allocator.dupe(u8, m);
        try self.completion_matches.append(self.allocator, owned);
    }
    self.completion_index = 0;
    self.completion_word_start = 0;
    self.completion_word_end = @intCast(self.edit_buf.len);
    self.completion_pattern_len = @intCast(prefix.len);

    try displayCompletions(self);
    return true;
}

fn trySubcommandCompletion(self: *Shell, cmd: []const u8, word_result: WordResult) !bool {
    // only complete subcommands when cursor is on the second word
    const trimmed = std.mem.trimLeft(u8, cmd, " \t");
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
    const rest = std.mem.trimLeft(u8, trimmed[cmd_end..], " \t");
    const sub_end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
    // if there's more text after the subcommand word, we're past subcommand position
    if (sub_end < rest.len) {
        const after_sub = std.mem.trimLeft(u8, rest[sub_end..], " \t");
        if (after_sub.len > 0) return false;
    }

    const pattern = word_result.word;

    // check cache (TTL 5 minutes)
    const now = std.time.timestamp();
    const cache_ttl: i64 = 300;
    const cached = self.subcmd_cache_cmd_len > 0 and
        self.subcmd_cache_cmd_len == base_cmd.len and
        base_cmd.len <= self.subcmd_cache_cmd.len and
        std.mem.eql(u8, self.subcmd_cache_cmd[0..self.subcmd_cache_cmd_len], base_cmd) and
        (now - self.subcmd_cache_ts) < cache_ttl;

    if (!cached) {
        parseSubcmdsFromHelp(self, base_cmd) catch {
            self.subcmd_cache_count = 0;
        };
        self.subcmd_cache_ts = now;
    }

    if (self.subcmd_cache_count == 0) return false;

    var matches = try std.ArrayList([]const u8).initCapacity(self.allocator, 32);
    defer {
        for (matches.items) |m| self.allocator.free(m);
        matches.deinit(self.allocator);
    }

    for (0..self.subcmd_cache_count) |i| {
        const off = self.subcmd_cache_offsets[i];
        const len = self.subcmd_cache_lens[i];
        const subcmd = self.subcmd_cache_buf[off .. off + len];
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

fn parseSubcmdsFromHelp(self: *Shell, base_cmd: []const u8) !void {
    self.subcmd_cache_count = 0;
    if (base_cmd.len > self.subcmd_cache_cmd.len) return;
    @memcpy(self.subcmd_cache_cmd[0..base_cmd.len], base_cmd);
    self.subcmd_cache_cmd_len = base_cmd.len;

    var argv_buf: [128]u8 = undefined;
    var child = std.process.Child.init(
        &.{ "/bin/sh", "-c", std.fmt.bufPrint(&argv_buf, "{s} --help 2>&1", .{base_cmd}) catch return },
        self.allocator,
    );
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    const stdout = child.stdout.?;
    var read_buf: [16384]u8 = undefined;
    var total_read: usize = 0;
    while (total_read < read_buf.len) {
        const n = stdout.read(read_buf[total_read..]) catch break;
        if (n == 0) break;
        total_read += n;
    }
    _ = child.wait() catch {};

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
            const existing = self.subcmd_cache_buf[self.subcmd_cache_offsets[j] .. self.subcmd_cache_offsets[j] + self.subcmd_cache_lens[j]];
            if (std.mem.eql(u8, existing, subcmd)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;

        if (buf_pos + subcmd.len > self.subcmd_cache_buf.len) break;
        @memcpy(self.subcmd_cache_buf[buf_pos .. buf_pos + subcmd.len], subcmd);
        self.subcmd_cache_offsets[count] = @intCast(buf_pos);
        self.subcmd_cache_lens[count] = @intCast(subcmd.len);
        buf_pos += subcmd.len;
        count += 1;
    }

    self.subcmd_cache_count = count;
}

fn tryFlagCompletion(self: *Shell, cmd: []const u8, word_result: WordResult) !bool {
    // extract command + subcommand for tools that use subcommands
    const trimmed = std.mem.trimLeft(u8, cmd, " \t");
    const cmd_end = std.mem.indexOfAny(u8, trimmed, " \t") orelse return false;
    const base_cmd = trimmed[0..cmd_end];
    if (base_cmd.len == 0 or base_cmd.len > 32) return false;

    // for git/docker/cargo/npm/kubectl/zig etc, include subcommand in --help
    const has_subcmds = for ([_][]const u8{ "git", "docker", "cargo", "npm", "kubectl", "zig", "go", "rustup", "apt", "systemctl", "ip", "gh" }) |tool| {
        if (std.mem.eql(u8, base_cmd, tool)) break true;
    } else false;

    var full_cmd_buf: [64]u8 = undefined;
    const command = blk: {
        if (has_subcmds) {
            const rest = std.mem.trimLeft(u8, trimmed[cmd_end..], " \t");
            if (rest.len > 0) {
                const sub_end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
                const sub = rest[0..sub_end];
                // only include if subcommand doesn't start with - (it's a flag not a subcmd)
                if (sub.len > 0 and sub[0] != '-') {
                    break :blk std.fmt.bufPrint(&full_cmd_buf, "{s} {s}", .{ base_cmd, sub }) catch base_cmd;
                }
            }
        }
        break :blk base_cmd;
    };
    if (command.len > 64) return false;

    const pattern = word_result.word;

    // check cache (TTL 5 minutes)
    const now = std.time.timestamp();
    const cache_ttl: i64 = 300; // 5 minutes
    const cached = self.flag_cache_cmd_len > 0 and
        self.flag_cache_cmd_len == command.len and
        std.mem.eql(u8, self.flag_cache_cmd[0..self.flag_cache_cmd_len], command) and
        (now - self.flag_cache_ts) < cache_ttl;

    if (!cached) {
        // run command --help and parse flags
        parseFlagsFromHelp(self, command) catch {
            self.flag_cache_count = 0;
        };
        self.flag_cache_ts = now;
    }

    if (self.flag_cache_count == 0) return false;

    var matches = try std.ArrayList([]const u8).initCapacity(self.allocator, 32);
    defer {
        for (matches.items) |m| self.allocator.free(m);
        matches.deinit(self.allocator);
    }

    // collect matching flag indices for description lookup
    var match_indices: [256]usize = undefined;
    var match_count: usize = 0;

    for (0..self.flag_cache_count) |i| {
        const off = self.flag_cache_offsets[i];
        const len = self.flag_cache_lens[i];
        const flag = self.flag_cache_buf[off .. off + len];
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
            if (self.flag_desc_lens[match_indices[mi]] > 0) {
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

fn parseFlagsFromHelp(self: *Shell, command: []const u8) !void {
    self.flag_cache_count = 0;
    @memcpy(self.flag_cache_cmd[0..command.len], command);
    self.flag_cache_cmd_len = command.len;

    var argv_buf: [128]u8 = undefined;
    var child = std.process.Child.init(
        &.{ "/bin/sh", "-c", std.fmt.bufPrint(&argv_buf, "{s} --help 2>&1", .{command}) catch return },
        self.allocator,
    );
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    const stdout = child.stdout.?;
    var buf_pos: usize = 0;
    var desc_pos: usize = 0;
    var count: usize = 0;

    // read help output and parse flags
    var read_buf: [16384]u8 = undefined;
    var total_read: usize = 0;
    while (total_read < read_buf.len) {
        const n = stdout.read(read_buf[total_read..]) catch break;
        if (n == 0) break;
        total_read += n;
    }

    _ = child.wait() catch {};

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
                    const existing = self.flag_cache_buf[self.flag_cache_offsets[j] .. self.flag_cache_offsets[j] + self.flag_cache_lens[j]];
                    if (std.mem.eql(u8, existing, flag)) {
                        dup = true;
                        break;
                    }
                }
                if (!dup and buf_pos + flag.len <= self.flag_cache_buf.len) {
                    @memcpy(self.flag_cache_buf[buf_pos .. buf_pos + flag.len], flag);
                    self.flag_cache_offsets[count] = @intCast(buf_pos);
                    self.flag_cache_lens[count] = @intCast(flag.len);
                    buf_pos += flag.len;

                    // extract description: skip to end of flag group, then grab description text
                    const desc = extractFlagDescription(text, i);
                    const desc_len = @min(desc.len, 60); // cap at 60 chars
                    if (desc_len > 0 and desc_pos + desc_len <= self.flag_desc_buf.len) {
                        @memcpy(self.flag_desc_buf[desc_pos .. desc_pos + desc_len], desc[0..desc_len]);
                        self.flag_desc_offsets[count] = @intCast(desc_pos);
                        self.flag_desc_lens[count] = @intCast(desc_len);
                        desc_pos += desc_len;
                    } else {
                        self.flag_desc_offsets[count] = 0;
                        self.flag_desc_lens[count] = 0;
                    }

                    count += 1;
                }
            }
        } else {
            i += 1;
        }
    }

    self.flag_cache_count = count;

    // If most flags lack descriptions, try man page as fallback
    if (count > 0) {
        var desc_count: usize = 0;
        for (0..count) |j| {
            if (self.flag_desc_lens[j] > 0) desc_count += 1;
        }
        // Only try man page if less than 30% have descriptions
        if (desc_count * 100 / count < 30) {
            augmentFlagsFromMan(self, command, count, &desc_pos);
        }
    }
}

/// Parse man page output to fill in missing flag descriptions.
/// Only augments flags that already exist in the cache but lack descriptions.
fn augmentFlagsFromMan(self: *Shell, command: []const u8, count: usize, desc_pos: *usize) void {
    // Extract base command (strip subcommands for man page lookup)
    const base_cmd = if (std.mem.indexOfScalar(u8, command, ' ')) |sp| command[0..sp] else command;

    var argv_buf: [128]u8 = undefined;
    const man_cmd = std.fmt.bufPrint(&argv_buf, "COLUMNS=200 man {s} 2>/dev/null | col -bx", .{base_cmd}) catch return;

    var child = std.process.Child.init(
        &.{ "/bin/sh", "-c", man_cmd },
        self.allocator,
    );
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return;

    const stdout = child.stdout.?;
    var read_buf: [32768]u8 = undefined;
    var total_read: usize = 0;
    while (total_read < read_buf.len) {
        const n = stdout.read(read_buf[total_read..]) catch break;
        if (n == 0) break;
        total_read += n;
    }
    _ = child.wait() catch {};

    if (total_read == 0) return;
    const text = read_buf[0..total_read];

    // For each cached flag without a description, search man page text
    for (0..count) |j| {
        if (self.flag_desc_lens[j] > 0) continue; // already has description
        const flag = self.flag_cache_buf[self.flag_cache_offsets[j] .. self.flag_cache_offsets[j] + self.flag_cache_lens[j]];

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
            if (desc_len > 0 and desc_pos.* + desc_len <= self.flag_desc_buf.len) {
                @memcpy(self.flag_desc_buf[desc_pos.* .. desc_pos.* + desc_len], desc[0..desc_len]);
                self.flag_desc_offsets[j] = @intCast(desc_pos.*);
                self.flag_desc_lens[j] = @intCast(desc_len);
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

    // store matches for cycling
    self.completion_matches.deinit(self.allocator);
    self.completion_matches = .{};
    for (matches.items) |m| {
        const owned = try self.allocator.dupe(u8, m);
        try self.completion_matches.append(self.allocator, owned);
    }
    self.completion_index = 0;
    self.completion_word_start = word_result.start;
    self.completion_word_end = word_result.end;
    self.completion_pattern_len = pattern.len;

    // display with descriptions
    const term_width = self.terminal_width;
    const term_height = self.terminal_height;
    const max_menu_height = if (term_height > 3) term_height - 3 else 1;

    try self.stdout().writeAll("\x1b" ++ "7");
    const cmd_rows = self.term_view.term.rows_owned;
    const cursor_row = self.term_view.term.row;
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
        if (self.completion_index < half) break :blk 0;
        if (self.completion_index + half >= matches.items.len) break :blk matches.items.len - items_to_show;
        break :blk self.completion_index - half;
    } else 0;
    const end_idx = @min(start_idx + items_to_show, matches.items.len);

    for (start_idx..end_idx) |idx| {
        const flag = matches.items[idx];
        const cache_idx = if (idx < match_indices.len) match_indices[idx] else 0;
        const desc_len = self.flag_desc_lens[cache_idx];
        const desc = if (desc_len > 0) self.flag_desc_buf[self.flag_desc_offsets[cache_idx] .. self.flag_desc_offsets[cache_idx] + desc_len] else "";

        const display_flag = if (flag.len > 25) flag[0..24] else flag;
        const is_selected = idx == self.completion_index;

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
    }

    if (end_idx < matches.items.len) {
        try self.stdout().print("... ({} more)\n", .{matches.items.len - end_idx});
        self.completion_menu_lines = items_to_show + 1;
    } else if (start_idx > 0) {
        try self.stdout().print("... ({} hidden above)\n", .{start_idx});
        self.completion_menu_lines = items_to_show + 1;
    } else {
        self.completion_menu_lines = items_to_show;
    }

    try self.stdout().writeAll("\x1b" ++ "8");
    try self.stdout().flush();
    self.completion_displayed = true;
    return true;
}

fn getGitBranches(self: *Shell, matches: *std.ArrayList([]const u8), pattern: []const u8) !void {
    // local branches from .git/refs/heads/
    const refs_dir = std.fs.cwd().openDir(".git/refs/heads", .{ .iterate = true }) catch return;
    var dir = refs_dir;
    defer dir.close();

    var local_set: [64][64]u8 = undefined;
    var local_lens: [64]usize = undefined;
    var local_count: usize = 0;

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
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
    const remotes_dir = std.fs.cwd().openDir(".git/refs/remotes", .{ .iterate = true }) catch return;
    var rdir = remotes_dir;
    defer rdir.close();

    var remote_iter = rdir.iterate();
    while (try remote_iter.next()) |remote_entry| {
        if (remote_entry.kind != .directory) continue;
        const remote_name = remote_entry.name;

        var remote_branch_dir = rdir.openDir(remote_name, .{ .iterate = true }) catch continue;
        defer remote_branch_dir.close();

        var branch_iter = remote_branch_dir.iterate();
        while (try branch_iter.next()) |branch_entry| {
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
    const file = std.fs.cwd().openFile(".git/packed-refs", .{}) catch return;
    defer file.close();

    var buf: [8192]u8 = undefined;
    const n = file.read(&buf) catch return;
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

    const tags_dir = std.fs.cwd().openDir(".git/refs/tags", .{ .iterate = true }) catch {
        // no refs/tags dir — try packed-refs only
        readPackedRefs(self, matches, "refs/tags/", pattern, &.{}, &.{}) catch {};
        return;
    };
    var dir = tags_dir;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
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
        try self.completion_matches.append(self.allocator, owned);
    }

    self.completion_mode = true;
    self.completion_index = self.completion_matches.items.len;
    self.completion_word_start = word_result.start;
    self.completion_word_end = word_result.end;
    self.completion_original_len = self.edit_buf.len;
    self.completion_pattern_len = pattern.len;

    try self.renderLine();
    try displayCompletions(self);
    return true;
}

pub fn exitCompletionMode(self: *Shell) void {
    if (!self.completion_mode) return;

    // clear the completion menu if displayed
    if (self.completion_displayed and self.completion_menu_lines > 0) {
        // Use absolute positioning to clear menu area (no relative moves that desync)
        self.stdout().writeAll("\x1b" ++ "7") catch {}; // DECSC
        const menu_row = self.term_view.term.rows_owned + 1;
        self.stdout().print("\x1b[{d};1H\x1b[J", .{menu_row}) catch {}; // go to menu row, clear below
        self.stdout().writeAll("\x1b" ++ "8") catch {}; // DECRC
        self.stdout().flush() catch {};
    }

    for (self.completion_matches.items) |match| {
        self.allocator.free(match);
    }
    self.completion_matches.clearRetainingCapacity();

    self.completion_mode = false;
    self.completion_index = 0;
    self.completion_pattern_len = 0;
    self.completion_menu_lines = 0;
    self.completion_displayed = false;
}

pub fn handleCompletionCycle(self: *Shell, direction: CycleDirection) !void {
    if (self.completion_matches.items.len == 0) return;

    const old_index = self.completion_index;
    const nothing_selected = old_index >= self.completion_matches.items.len;

    // calculate new index first
    var new_index: usize = undefined;
    switch (direction) {
        .forward => {
            if (nothing_selected) {
                new_index = 0;
            } else {
                new_index = (self.completion_index + 1) % self.completion_matches.items.len;
            }
        },
        .backward => {
            if (nothing_selected) {
                new_index = self.completion_matches.items.len - 1;
            } else if (self.completion_index == 0) {
                new_index = self.completion_matches.items.len - 1;
            } else {
                new_index = self.completion_index - 1;
            }
        },
    }

    // zsh-style: if cycling back to same directory (wrapped), drill into it
    if (direction == .forward and !nothing_selected and new_index == old_index) {
        const current_match = self.completion_matches.items[self.completion_index];
        if (std.mem.endsWith(u8, current_match, "/")) {
            exitCompletionMode(self);
            try self.renderLine();
            return try handleTabCompletion(self);
        }
    }

    self.completion_index = new_index;

    try applyCompletion(self, self.completion_pattern_len);

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
    if (self.completion_matches.items.len == 0) return;

    const match = self.completion_matches.items[self.completion_index];
    const comp_str = match[pattern_len..];

    // escape special characters for shell
    const escaped = escapeForShell(self.allocator, comp_str) catch return;
    defer self.allocator.free(escaped);

    self.edit_buf.len = @intCast(self.completion_original_len);
    self.edit_buf.cursor = @intCast(self.completion_word_end);
    _ = self.edit_buf.insertSlice(escaped);

    // log accepted completion for training data
    const pattern = match[0..pattern_len];
    logCompletion(self.edit_buf.slice(), self.completion_word_start, pattern, match);
}

pub fn displayCompletions(self: *Shell) !void {
    if (self.completion_matches.items.len == 0) return;

    const term_width = self.terminal_width;
    const term_height = self.terminal_height;
    const max_menu_height = if (term_height > 3) term_height - 3 else 1;

    // Save cursor, then position at the row below command area
    // Use absolute positioning to avoid \n scroll desync
    try self.stdout().writeAll("\x1b" ++ "7"); // DECSC
    const cmd_rows = self.term_view.term.rows_owned;
    const menu_start_row = cmd_rows + 1; // row right below command

    // Clear everything below command area first
    try self.stdout().print("\x1b[{d};1H\x1b[J", .{menu_start_row});

    if (term_width < 80) {
        const items_to_show = @min(self.completion_matches.items.len, max_menu_height);
        const start_idx = if (self.completion_matches.items.len > items_to_show) blk: {
            const half_window = items_to_show / 2;
            if (self.completion_index < half_window) {
                break :blk 0;
            } else if (self.completion_index + half_window >= self.completion_matches.items.len) {
                break :blk self.completion_matches.items.len - items_to_show;
            } else {
                break :blk self.completion_index - half_window;
            }
        } else 0;

        const end_idx = @min(start_idx + items_to_show, self.completion_matches.items.len);

        for (self.completion_matches.items[start_idx..end_idx], start_idx..) |match, mi| {
            const row = menu_start_row + (mi - start_idx);
            try self.stdout().print("\x1b[{d};1H", .{row});
            if (mi == self.completion_index and self.completion_index < self.completion_matches.items.len) {
                try self.stdout().print("{f}{s}{f}", .{ tty.Style.reverse, match, tty.Style.reset });
            } else {
                try self.stdout().print("{s}", .{match});
            }
        }

        if (end_idx < self.completion_matches.items.len) {
            try self.stdout().print("\x1b[{d};1H... ({} more)", .{ menu_start_row + items_to_show, self.completion_matches.items.len - end_idx });
            self.completion_menu_lines = items_to_show + 1;
        } else if (start_idx > 0) {
            try self.stdout().print("\x1b[{d};1H... ({} hidden above)", .{ menu_start_row + items_to_show, start_idx });
            self.completion_menu_lines = items_to_show + 1;
        } else {
            self.completion_menu_lines = items_to_show;
        }

        try self.stdout().writeAll("\x1b" ++ "8"); // DECRC
        try self.stdout().flush();
        self.completion_displayed = true;
        return;
    }

    const max_item_width: usize = 30;
    var max_len: usize = 0;
    for (self.completion_matches.items) |match| {
        const display_len = @min(match.len, max_item_width);
        if (display_len > max_len) max_len = display_len;
    }
    const col_width = max_len + 2;
    const max_line_width: usize = 120;
    const effective_width = @min(term_width, max_line_width);
    const cols = @max(1, effective_width / col_width);

    const total_menu_lines = (self.completion_matches.items.len + cols - 1) / cols;
    const menu_lines_count = @min(total_menu_lines, max_menu_height);
    self.completion_menu_lines = menu_lines_count;

    const max_items = menu_lines_count * cols;
    const items_to_show = @min(self.completion_matches.items.len, max_items);

    const start_item = if (self.completion_matches.items.len > items_to_show) blk: {
        const half = items_to_show / 2;
        if (self.completion_index < half) {
            break :blk @as(usize, 0);
        } else if (self.completion_index + half >= self.completion_matches.items.len) {
            break :blk self.completion_matches.items.len - items_to_show;
        } else {
            break :blk self.completion_index - half;
        }
    } else 0;
    const end_item = @min(start_item + items_to_show, self.completion_matches.items.len);

    // Draw items using absolute row positioning (no \n scrolling)
    var current_row: usize = menu_start_row;
    var col_pos: usize = 0;
    try self.stdout().print("\x1b[{d};1H", .{current_row});

    for (self.completion_matches.items[start_item..end_item], start_item..) |match, i| {
        const display_name = if (match.len > max_item_width) match[0 .. max_item_width - 1] else match;
        const truncated = match.len > max_item_width;

        if (i == self.completion_index and self.completion_index < self.completion_matches.items.len) {
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
        if (col_pos >= cols or i - start_item == items_to_show - 1) {
            current_row += 1;
            col_pos = 0;
            if (i - start_item < items_to_show - 1) {
                try self.stdout().print("\x1b[{d};1H", .{current_row});
            }
        }
    }

    const hidden = self.completion_matches.items.len - (end_item - start_item);
    if (hidden > 0) {
        try self.stdout().print("\x1b[{d};1H... ({} more matches)", .{ current_row, hidden });
        self.completion_menu_lines += 1;
    }

    // Restore cursor to command line
    try self.stdout().writeAll("\x1b" ++ "8");
    try self.stdout().flush();
    self.completion_displayed = true;
}

// Log accepted completion pairs to ~/.zish/completion_log.jsonl for CTM training data.
// Format: {"ctx":"command text before cursor","pfx":"typed prefix","cmp":"full completion","ts":unix_timestamp}
const CompletionSource = enum { tab, ghost_history, ghost_ctm, history_menu };

fn logCompletionWith(cmd: []const u8, word_start: usize, prefix: []const u8, completion: []const u8, source: CompletionSource) void {
    logCompletionImpl(cmd, word_start, prefix, completion, source);
}

fn logCompletion(cmd: []const u8, word_start: usize, prefix: []const u8, completion: []const u8) void {
    logCompletionImpl(cmd, word_start, prefix, completion, .tab);
}

fn logCompletionImpl(cmd: []const u8, word_start: usize, prefix: []const u8, completion: []const u8, source: CompletionSource) void {
    var path_buf: [512]u8 = undefined;
    const home = std.process.getEnvVarOwned(std.heap.page_allocator, "HOME") catch return;
    defer std.heap.page_allocator.free(home);
    const path = std.fmt.bufPrint(&path_buf, "{s}/.zish/completion_log.jsonl", .{home}) catch return;

    const file = std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch |e| switch (e) {
        error.FileNotFound => std.fs.cwd().createFile(path, .{}) catch return,
        else => return,
    };
    defer file.close();
    file.seekFromEnd(0) catch return;

    const ctx = cmd[0..@min(word_start, cmd.len)];
    const ts: u64 = @bitCast(std.time.timestamp());

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
        .ghost_ctm => "ghost_ctm",
        .history_menu => "hist",
    });
    pos += copySlice(&buf, pos, "\",\"ts\":");
    pos += (std.fmt.bufPrint(buf[pos..], "{d}", .{ts}) catch return).len;
    pos += copySlice(&buf, pos, "}\n");

    _ = file.write(buf[0..pos]) catch {};
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

pub fn updateCompletionHighlight(self: *Shell, old_index: usize) !void {
    const term_width = self.terminal_width;

    // save cursor position on command line
    try self.stdout().writeAll("\x1b" ++ "7");

    if (old_index >= self.completion_matches.items.len) {
        const max_item_width: usize = 30;
        var max_len: usize = 0;
        for (self.completion_matches.items) |match| {
            const display_len = @min(match.len, max_item_width);
            if (display_len > max_len) max_len = display_len;
        }
        const col_width = max_len + 2;
        const max_line_width: usize = 120;
        const effective_width = @min(term_width, max_line_width);
        const cols = @max(1, effective_width / col_width);

        const new_row = self.completion_index / cols;
        const new_col = self.completion_index % cols;

        // move down to menu, then to the item position
        try self.stdout().print("\x1b[{d}B", .{new_row + 1});
        const new_col_pos = new_col * col_width;
        try self.stdout().print("\x1b[{d}G", .{new_col_pos + 1});
        try self.stdout().print("{f}{s}{f}", .{ tty.Style.reverse, self.completion_matches.items[self.completion_index], tty.Style.reset });

        // restore cursor to command line
        try self.stdout().writeAll("\x1b" ++ "8");
        try self.stdout().flush();
        return;
    }

    if (term_width < 80) {
        // narrow terminal - redraw entire menu
        try self.stdout().writeByte('\n');
        try self.stdout().writeAll("\x1b[J");
        // don't use save/restore here since displayCompletions does its own
        try self.stdout().writeAll("\x1b" ++ "8"); // restore first
        try displayCompletions(self);
        return;
    }

    const max_item_width: usize = 30;
    var max_len: usize = 0;
    for (self.completion_matches.items) |match| {
        const display_len = @min(match.len, max_item_width);
        if (display_len > max_len) max_len = display_len;
    }
    const col_width = max_len + 2;
    const max_line_width: usize = 120;
    const effective_width = @min(term_width, max_line_width);
    const cols = @max(1, effective_width / col_width);

    const old_row = old_index / cols;
    const old_col = old_index % cols;
    const new_row = self.completion_index / cols;
    const new_col = self.completion_index % cols;

    // move down to old item and un-highlight it
    try self.stdout().print("\x1b[{d}B", .{old_row + 1});
    const old_col_pos = old_col * col_width;
    try self.stdout().print("\x1b[{d}G", .{old_col_pos + 1});
    try self.stdout().print("{s}", .{self.completion_matches.items[old_index]});

    // move to new item and highlight it
    if (new_row > old_row) {
        try self.stdout().print("\x1b[{d}B", .{new_row - old_row});
    } else if (old_row > new_row) {
        try self.stdout().print("\x1b[{d}A", .{old_row - new_row});
    }
    const new_col_pos = new_col * col_width;
    try self.stdout().print("\x1b[{d}G", .{new_col_pos + 1});
    try self.stdout().print("{f}{s}{f}", .{ tty.Style.reverse, self.completion_matches.items[self.completion_index], tty.Style.reset });

    // restore cursor to command line
    try self.stdout().writeAll("\x1b" ++ "8");
    try self.stdout().flush();
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
        std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return false
    else
        std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return false;
    defer dir.close();

    // Find first match
    var iter = dir.iterate();
    var best: [256]u8 = undefined;
    var best_len: usize = 0;

    while (iter.next() catch null) |entry| {
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
        const n = @min(best_len, self.ghost_buf.len);
        @memcpy(self.ghost_buf[0..n], best[0..n]);
        self.ghost_len = n;
        self.ghost_from_ctm = false;
        return true;
    }
    return false;
}

pub fn updateGhostText(self: *Shell) void {
    self.ghost_len = 0;

    if (!self.opt_autosuggestion) return;

    // only suggest when cursor is at end and we have content
    const cmd = self.edit_buf.slice();
    if (cmd.len < 2 or self.edit_buf.cursor != self.edit_buf.len) return;
    if (self.completion_mode) return;

    // check for CTM inference result (non-blocking)
    const cur_seq = self.ghost_infer_seq.load(.monotonic);
    const res_seq = self.ghost_infer_result_seq.load(.acquire); // acquire: sync with background thread's release store
    if (res_seq == cur_seq and res_seq > 0) {
        const rlen = self.ghost_infer_result_len.load(.monotonic);
        if (rlen > 0) {
            const n = @min(rlen, self.ghost_buf.len);
            @memcpy(self.ghost_buf[0..n], self.ghost_infer_result[0..n]);
            self.ghost_len = n;
            self.ghost_from_ctm = true;
            return; // CTM result takes priority
        }
    }

    // submit new CTM inference request if model configured
    // thread checks staleness — discards result if user typed more during inference
    if (self.ghost_infer_thread != null and cmd.len <= self.ghost_infer_input.len) {
        const new_seq = cur_seq +% 1;
        const len: u32 = @intCast(cmd.len);
        @memcpy(self.ghost_infer_input[0..cmd.len], cmd);
        self.ghost_infer_input_len.store(len, .monotonic);
        self.ghost_infer_seq.store(new_seq, .release);
    }

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
    const now_ts: u32 = @intCast(@min(@as(u64, @intCast(std.time.timestamp())), std.math.maxInt(u32)));

    const MAX_CANDIDATES = 8;
    var cand_scores: [MAX_CANDIDATES]f32 = [_]f32{0} ** MAX_CANDIDATES;
    var cand_idxs: [MAX_CANDIDATES]usize = undefined;
    var cand_count: u8 = 0;

    for (0..items.len) |i| {
        const idx = items.len - 1 - i;
        const entry = items[idx];
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
    self.ghost_candidate_count = cand_count;
    for (0..cand_count) |ci| {
        const command = h.getCommand(items[cand_idxs[ci]]);
        const suffix = command[cmd.len..];
        const n = @min(suffix.len, self.ghost_candidates[ci].len);
        @memcpy(self.ghost_candidates[ci][0..n], suffix[0..n]);
        self.ghost_candidate_lens[ci] = n;
    }

    // Show first candidate
    if (cand_count > 0) {
        // Keep current index if still valid, otherwise reset
        if (self.ghost_candidate_idx >= cand_count) self.ghost_candidate_idx = 0;
        const ci = self.ghost_candidate_idx;
        const n = self.ghost_candidate_lens[ci];
        @memcpy(self.ghost_buf[0..n], self.ghost_candidates[ci][0..n]);
        self.ghost_len = n;
        self.ghost_from_ctm = false;
        return;
    }

    // Strategy 2: match last segment after pipe/semicolon
    // e.g. "git log | grep fo" matches history "grep foo --color" → suggests "o --color"
    const last_seg = blk: {
        var pos = cmd.len;
        while (pos > 0) : (pos -= 1) {
            if (cmd[pos - 1] == '|' or cmd[pos - 1] == ';') {
                break :blk std.mem.trimLeft(u8, cmd[pos..], " \t");
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
            const n = @min(suffix.len, self.ghost_buf.len);
            @memcpy(self.ghost_buf[0..n], suffix[0..n]);
            self.ghost_len = n;
            self.ghost_from_ctm = false;
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
                const n = @min(s.completion.len, self.ghost_buf.len);
                @memcpy(self.ghost_buf[0..n], s.completion[0..n]);
                self.ghost_len = n;
                self.ghost_from_ctm = false;
                return;
            }
        }
    }
}

/// Cycle ghost text to next/previous candidate (Alt+Down / Alt+Up)
pub fn cycleGhostCandidate(self: *Shell, direction: i8) bool {
    if (self.ghost_candidate_count <= 1) return false;
    if (direction > 0) {
        self.ghost_candidate_idx = (self.ghost_candidate_idx + 1) % self.ghost_candidate_count;
    } else {
        self.ghost_candidate_idx = if (self.ghost_candidate_idx == 0) self.ghost_candidate_count - 1 else self.ghost_candidate_idx - 1;
    }
    const ci = self.ghost_candidate_idx;
    const n = self.ghost_candidate_lens[ci];
    @memcpy(self.ghost_buf[0..n], self.ghost_candidates[ci][0..n]);
    self.ghost_len = n;
    return true;
}

/// Start the ghost inference background thread (called when completion_model is configured).
pub fn startGhostInference(self: *Shell, model_path: []const u8) void {
    if (self.ghost_infer_thread != null) return;
    if (model_path.len == 0) return;

    // Copy model path to a stable location (self is heap-allocated, fields are stable)
    var path_buf: [256]u8 = undefined;
    if (model_path.len > path_buf.len) return;
    @memcpy(path_buf[0..model_path.len], model_path);

    const GhostInferCtx = struct {
        shell: *Shell,
        path: [256]u8,
        path_len: usize,
    };

    // Allocate context on heap so thread can reference it
    const ctx = self.allocator.create(GhostInferCtx) catch return;
    ctx.* = .{ .shell = self, .path = path_buf, .path_len = model_path.len };

    self.ghost_infer_thread = std.Thread.spawn(.{}, ghostInferThread, .{ctx}) catch {
        self.allocator.destroy(ctx);
        return;
    };
}

fn ghostInferThread(ctx: anytype) void {
    const shell = ctx.shell;
    const model_path = ctx.path[0..ctx.path_len];
    const alloc = shell.allocator;

    // Spawn ForkServer for inference
    const inference = @import("inference/root.zig");
    var server = inference.ForkServer.spawn(model_path) catch {
        alloc.destroy(ctx);
        return;
    };
    defer server.shutdown();
    alloc.destroy(ctx);

    var last_seq: u32 = 0;

    while (!shell.ghost_infer_stop.load(.monotonic)) {
        // wait for new request
        const seq = shell.ghost_infer_seq.load(.acquire);
        if (seq == last_seq) {
            std.Thread.sleep(20 * std.time.ns_per_ms); // 20ms poll
            continue;
        }
        last_seq = seq;

        // debounce: wait 100ms for input to stabilize before expensive inference
        std.Thread.sleep(100 * std.time.ns_per_ms);
        if (shell.ghost_infer_seq.load(.monotonic) != seq) continue;

        // read input
        const ilen = shell.ghost_infer_input_len.load(.monotonic);
        if (ilen == 0 or ilen > 512) continue;
        var input_buf: [512]u8 = undefined;
        @memcpy(input_buf[0..ilen], shell.ghost_infer_input[0..ilen]);

        // run inference with context-aware prompt
        if (!server.isAlive()) {
            server = inference.ForkServer.spawn(model_path) catch break;
        }
        // Build prompt with context: recent history + cwd + current input
        // More characters typed = more context we can provide
        var prompt_buf: [2048]u8 = undefined;
        var ppos: usize = 0;

        // Add recent command history for context (last 3-5 commands)
        if (shell.history) |h| {
            const n_hist = @min(h.entries.items.len, if (ilen > 10) @as(usize, 5) else 3);
            const start = h.entries.items.len - n_hist;
            for (h.entries.items[start..]) |entry| {
                const hcmd = h.getCommand(entry);
                if (hcmd.len > 0 and ppos + hcmd.len + 4 < prompt_buf.len - 256) {
                    @memcpy(prompt_buf[ppos..][0..2], "$ ");
                    ppos += 2;
                    @memcpy(prompt_buf[ppos..][0..hcmd.len], hcmd);
                    ppos += hcmd.len;
                    prompt_buf[ppos] = '\n';
                    ppos += 1;
                }
            }
        }

        // Add current input as the line to complete
        if (ppos + ilen + 3 < prompt_buf.len) {
            @memcpy(prompt_buf[ppos..][0..2], "$ ");
            ppos += 2;
            @memcpy(prompt_buf[ppos..][0..ilen], input_buf[0..ilen]);
            ppos += ilen;
        }
        const prompt = prompt_buf[0..ppos];

        // Debug log
        const dbg2 = std.fs.openFileAbsolute("/tmp/zish_inference.log", .{ .mode = .write_only }) catch null;
        if (dbg2) |f| {
            f.seekFromEnd(0) catch {};
            f.writeAll("generate: ") catch {};
            f.writeAll(prompt) catch {};
            f.writeAll("\n") catch {};
            f.close();
        }

        const result = server.generate(prompt, 12, 0.0, alloc) catch |err| {
            const dbg3 = std.fs.openFileAbsolute("/tmp/zish_inference.log", .{ .mode = .write_only }) catch null;
            if (dbg3) |f| {
                f.seekFromEnd(0) catch {};
                f.writeAll("generate FAILED: ") catch {};
                f.writeAll(@errorName(err)) catch {};
                f.writeAll("\n") catch {};
                f.close();
            }
            continue;
        };
        defer alloc.free(result);

        // Debug: log result
        {
            const dbg4 = std.fs.openFileAbsolute("/tmp/zish_inference.log", .{ .mode = .write_only }) catch null;
            if (dbg4) |f| {
                f.seekFromEnd(0) catch {};
                var lenbuf: [32]u8 = undefined;
                const lenstr = std.fmt.bufPrint(&lenbuf, "result len={d}: ", .{result.len}) catch "?";
                f.writeAll(lenstr) catch {};
                if (result.len > 0) f.writeAll(result[0..@min(result.len, 100)]) catch {};
                f.writeAll("\n") catch {};
                f.close();
            }
        }

        // check if still current
        if (shell.ghost_infer_seq.load(.monotonic) != seq) continue;

        // Sanitize: only printable ASCII
        var clean_len: u32 = 0;
        var consecutive_junk: u8 = 0;
        for (result) |rc| {
            if (rc == '\n' or rc == '\r') break;
            if (rc >= 0x20 and rc <= 0x7E) {
                if (clean_len < 512) {
                    shell.ghost_infer_result[clean_len] = rc;
                    clean_len += 1;
                }
                consecutive_junk = 0;
            } else {
                consecutive_junk += 1;
                if (consecutive_junk > 2) break;
            }
        }
        const rlen = clean_len;
        shell.ghost_infer_result_len.store(rlen, .monotonic);
        shell.ghost_infer_result_seq.store(seq, .release);
    }
}

/// Stop the ghost inference thread.
pub fn stopGhostInference(self: *Shell) void {
    self.ghost_infer_stop.store(true, .monotonic);
    if (self.ghost_infer_thread) |t| {
        t.join();
        self.ghost_infer_thread = null;
    }
}

/// Accept ghost text — append it to the edit buffer.
/// Returns true if ghost text was accepted.
pub fn acceptGhostText(self: *Shell) bool {
    if (self.ghost_len == 0) return false;
    if (self.edit_buf.cursor != self.edit_buf.len) return false;

    const ghost = self.ghost_buf[0..self.ghost_len];
    _ = self.edit_buf.insertSlice(ghost);
    self.ghost_len = 0;

    // log accepted ghost suggestion with source tracking
    logCompletionWith(self.edit_buf.slice(), 0, "", self.edit_buf.slice(),
        if (self.ghost_from_ctm) .ghost_ctm else .ghost_history);

    return true;
}

/// Accept one word from ghost text (Ctrl+Right).
/// Returns true if a word was accepted.
pub fn acceptGhostWord(self: *Shell) bool {
    if (self.ghost_len == 0) return false;
    if (self.edit_buf.cursor != self.edit_buf.len) return false;

    const ghost = self.ghost_buf[0..self.ghost_len];

    // find end of first word: skip leading spaces, then skip non-spaces
    var i: usize = 0;
    while (i < ghost.len and ghost[i] == ' ') : (i += 1) {}
    while (i < ghost.len and ghost[i] != ' ') : (i += 1) {}

    if (i == 0) return false;

    // insert the word
    _ = self.edit_buf.insertSlice(ghost[0..i]);

    // shift remaining ghost text
    const remaining = self.ghost_len - i;
    if (remaining > 0) {
        std.mem.copyForwards(u8, &self.ghost_buf, self.ghost_buf[i..self.ghost_len]);
    }
    self.ghost_len = remaining;

    return true;
}
