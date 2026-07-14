// eval.zig - AST evaluation for zish
const std = @import("std");
const compat = @import("compat.zig");
const ast = @import("ast.zig");
const glob = @import("glob.zig");
const Shell = @import("Shell.zig");
const parser = @import("parser.zig");
const builtins = @import("builtins.zig");
const jobs = @import("jobs.zig");

// ============ "did you mean?" typo suggestions ============

// levenshtein distance for typo detection (stack-allocated, max 32 chars)
fn levenshtein(a: []const u8, b: []const u8) usize {
    if (a.len > 32 or b.len > 32) return 999;
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;

    var prev: [33]usize = undefined;
    var curr: [33]usize = undefined;

    for (0..b.len + 1) |i| prev[i] = i;

    for (a, 0..) |ca, i| {
        curr[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = if (ca == cb) 0 else 1;
            curr[j + 1] = @min(@min(prev[j + 1] + 1, curr[j] + 1), prev[j] + cost);
        }
        @memcpy(prev[0 .. b.len + 1], curr[0 .. b.len + 1]);
    }
    return prev[b.len];
}

// find similar command and print suggestion
fn suggestCommand(shell: *Shell, typo: []const u8) void {
    var best_match: ?[]const u8 = null;
    var best_dist: usize = 999;
    const max_dist: usize = @max(2, typo.len / 3); // allow more typos for longer names

    // check builtins
    const builtin_names = [_][]const u8{
        "cd", "pwd", "echo", "printf", "read", "test", "exit", "export",
        "unset", "alias", "source", "eval", "exec", "type", "which",
        "jobs", "fg", "bg", "wait", "kill", "trap", "set", "shift",
        "pushd", "popd", "dirs", "history", "help", "time", "true", "false",
    };
    for (builtin_names) |cmd| {
        const dist = levenshtein(typo, cmd);
        if (dist < best_dist and dist <= max_dist) {
            best_dist = dist;
            best_match = cmd;
        }
    }

    // check aliases
    var alias_iter = shell.aliases.iterator();
    while (alias_iter.next()) |entry| {
        const dist = levenshtein(typo, entry.key_ptr.*);
        if (dist < best_dist and dist <= max_dist) {
            best_dist = dist;
            best_match = entry.key_ptr.*;
        }
    }

    // check PATH executables (sample common commands for speed)
    const common_cmds = [_][]const u8{
        "git", "ls", "cat", "grep", "find", "make", "vim", "nano",
        "ssh", "scp", "curl", "wget", "tar", "zip", "unzip", "man",
        "top", "htop", "ps", "kill", "sudo", "apt", "pacman", "yum",
        "docker", "python", "python3", "node", "npm", "cargo", "zig",
        "gcc", "clang", "go", "rustc", "java", "mvn", "gradle",
        "systemctl", "journalctl", "mount", "umount", "df", "du",
        "chmod", "chown", "mkdir", "rmdir", "rm", "cp", "mv", "ln",
        "head", "tail", "less", "more", "sort", "uniq", "wc", "awk", "sed",
    };
    for (common_cmds) |cmd| {
        const dist = levenshtein(typo, cmd);
        if (dist < best_dist and dist <= max_dist) {
            best_dist = dist;
            best_match = cmd;
        }
    }

    // print suggestion if found
    if (best_match) |match| {
        shell.stdout().print("       did you mean: {s}?\n", .{match}) catch {};
    }
}

// Fast integer parsing for small numbers - SectorLambda-inspired
// Optimized for the common case of small positive integers (loop counters, etc.)
inline fn fastParseI64(s: []const u8) ?i64 {
    if (s.len == 0 or s.len > 19) return null;

    var i: usize = 0;
    var negative = false;

    if (s[0] == '-') {
        negative = true;
        i = 1;
        if (s.len == 1) return null;
    } else if (s[0] == '+') {
        i = 1;
        if (s.len == 1) return null;
    }

    var result: i64 = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c < '0' or c > '9') return null;
        result = result * 10 + (c - '0');
    }

    return if (negative) -result else result;
}

// Clean up process substitution children - close fds and reap zombies
fn cleanupProcessSubst(shell: *Shell) void {
    for (0..shell.proc_subst_count) |i| {
        if (shell.proc_subst_fds[i] >= 0) {
            compat.posix.close(shell.proc_subst_fds[i]);
            shell.proc_subst_fds[i] = -1;
        }
        if (shell.proc_subst_pids[i] != 0) {
            _ = compat.posix.waitpid(shell.proc_subst_pids[i], compat.posix.W.NOHANG);
            shell.proc_subst_pids[i] = 0;
        }
    }
    shell.proc_subst_count = 0;
}

// Process substitution: <(cmd) or >(cmd)
// Returns /dev/fd/N path for the pipe endpoint, or null if not a process subst
fn expandProcessSubst(shell: *Shell, arg: []const u8) !?[:0]const u8 {
    const is_input = std.mem.startsWith(u8, arg, "<(") and std.mem.endsWith(u8, arg, ")");
    const is_output = std.mem.startsWith(u8, arg, ">(") and std.mem.endsWith(u8, arg, ")");

    if (!is_input and !is_output) return null;

    // extract command between ( and )
    const cmd = arg[2 .. arg.len - 1];
    if (cmd.len == 0) return null;

    // create pipe
    const pipe_fds = compat.posix.pipe() catch return null;

    const pid = compat.posix.fork() catch {
        compat.posix.close(pipe_fds[0]);
        compat.posix.close(pipe_fds[1]);
        return null;
    };

    if (pid == 0) {
        // child process - run command
        shell.allocator = std.heap.page_allocator;

        if (is_input) {
            // <(cmd): redirect stdout to pipe write end
            compat.posix.dup2(pipe_fds[1], compat.posix.STDOUT_FILENO) catch compat.posix.exit(1);
        } else {
            // >(cmd): redirect stdin from pipe read end
            compat.posix.dup2(pipe_fds[0], compat.posix.STDIN_FILENO) catch compat.posix.exit(1);
        }
        compat.posix.close(pipe_fds[0]);
        compat.posix.close(pipe_fds[1]);

        // run command using /bin/sh for simplicity and safety
        const cmd_z = shell.allocator.dupeZ(u8, cmd) catch compat.posix.exit(1);
        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z.ptr, null };
        compat.posix.execvpeZ("/bin/sh", &argv, @ptrCast(std.c.environ)) catch {};
        compat.posix.exit(127);
    }

    // parent - close unused end and return /dev/fd/N
    const fd: compat.posix.fd_t = if (is_input) blk: {
        compat.posix.close(pipe_fds[1]); // close write end
        break :blk pipe_fds[0]; // return read end
    } else blk: {
        compat.posix.close(pipe_fds[0]); // close read end
        break :blk pipe_fds[1]; // return write end
    };

    // track child for later cleanup (best effort)
    shell.proc_subst_pids[shell.proc_subst_count] = pid;
    shell.proc_subst_fds[shell.proc_subst_count] = fd;
    if (shell.proc_subst_count < shell.proc_subst_pids.len - 1) {
        shell.proc_subst_count += 1;
    }

    // return /dev/fd/N path
    var buf: [32]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "/dev/fd/{d}", .{fd}) catch return null;
    return try shell.allocator.dupeZ(u8, path);
}

// Build environment array merging system env with shell variables
// Shell variables override system environment
fn buildEnvironment(shell: *Shell) ![*:null]const ?[*:0]const u8 {
    // Count total entries needed
    var count: usize = 0;

    // Count system env vars (excluding ones we'll override)
    {
        const env_ptr = std.c.environ;
        var ei: usize = 0;
        while (env_ptr[ei]) |entry| : (ei += 1) {
            const entry_slice = std.mem.sliceTo(entry, 0);
            const eq_pos = std.mem.indexOfScalar(u8, entry_slice, '=') orelse continue;
            const name = entry_slice[0..eq_pos];
            // Skip if shell has override
            if (shell.variables.contains(name)) continue;
            count += 1;
        }
    }

    // Add shell variables
    count += shell.variables.count();

    // Allocate array (count + 1 for null terminator)
    var env_ptrs = try shell.allocator.alloc(?[*:0]const u8, count + 1);

    var idx: usize = 0;

    // Add system env vars (not overridden)
    {
        const env_ptr = std.c.environ;
        var ei: usize = 0;
        while (env_ptr[ei]) |entry| : (ei += 1) {
            const entry_slice = std.mem.sliceTo(entry, 0);
            const eq_pos = std.mem.indexOfScalar(u8, entry_slice, '=') orelse continue;
            const name = entry_slice[0..eq_pos];
            if (shell.variables.contains(name)) continue;
            env_ptrs[idx] = entry;
            idx += 1;
        }
    }

    // Add shell variables
    var var_iter = shell.variables.iterator();
    while (var_iter.next()) |kv| {
        // Build "NAME=value\0" string (leaked - child exits after exec)
        const name = kv.key_ptr.*;
        const value = kv.value_ptr.*;
        const env_str = try shell.allocator.alloc(u8, name.len + 1 + value.len + 1);
        @memcpy(env_str[0..name.len], name);
        env_str[name.len] = '=';
        @memcpy(env_str[name.len + 1 ..][0..value.len], value);
        env_str[name.len + 1 + value.len] = 0;
        env_ptrs[idx] = @ptrCast(env_str.ptr);
        idx += 1;
    }

    env_ptrs[idx] = null;
    return @ptrCast(env_ptrs.ptr);
}

pub fn evaluateAst(shell: *Shell, node: *const ast.AstNode) anyerror!u8 {
    return switch (node.node_type) {
        .command => evaluateCommand(shell, node),
        .pipeline => evaluatePipeline(shell, node),
        .logical_and => evaluateLogicalAnd(shell, node),
        .logical_or => evaluateLogicalOr(shell, node),
        .redirect => evaluateRedirect(shell, node),
        .list => evaluateList(shell, node),
        .assignment => evaluateAssignment(shell, node),
        .if_statement => evaluateIf(shell, node),
        .while_loop => evaluateWhile(shell, node),
        .until_loop => evaluateUntil(shell, node),
        .for_loop => evaluateFor(shell, node),
        .subshell => evaluateSubshell(shell, node),
        .test_expression => evaluateTest(shell, node),
        .function_def => evaluateFunctionDef(shell, node),
        .case_statement => evaluateCase(shell, node),
        .background => evaluateBackground(shell, node),
        else => {
            try shell.stdout().writeAll("unsupported AST node type\n");
            return 1;
        },
    };
}

// Fast path for [ and test builtins - uses stack buffers to avoid allocations
fn evaluateTestBuiltinFast(shell: *Shell, node: *const ast.AstNode) !u8 {
    const is_bracket = node.children[0].value.len == 1 and node.children[0].value[0] == '[';

    // Stack-allocated buffers for expanded arguments (max 8 args, 256 bytes each)
    var arg_buffers: [8][256]u8 = undefined;
    var arg_slices: [8][]const u8 = undefined;
    var arg_count: usize = 0;

    // Skip command name ([ or test) and closing ] if present
    const start_idx: usize = 1;
    var end_idx = node.children.len;

    // For [ command, check for closing ]
    if (is_bracket and end_idx > start_idx) {
        const last = node.children[end_idx - 1].value;
        if (last.len == 1 and last[0] == ']') {
            end_idx -= 1;
        } else {
            try shell.stdout().writeAll("[: missing ]\n");
            return 2;
        }
    }

    // Expand arguments into stack buffers
    for (node.children[start_idx..end_idx]) |arg_node| {
        if (arg_count >= 8) break; // max args

        const arg = arg_node.value;
        const dest = &arg_buffers[arg_count];

        // Fast variable expansion into stack buffer
        const expanded_len = try expandVariableFast(shell, arg, dest);
        arg_slices[arg_count] = dest[0..expanded_len];
        arg_count += 1;
    }

    // Evaluate test expression with stack-allocated args
    const result = evaluateTestExpr(arg_slices[0..arg_count]);
    return if (result) 0 else 1;
}

// Check if string contains command substitution $(cmd) but not $((arith))
fn hasCommandSubstitution(input: []const u8) bool {
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '$' and i + 1 < input.len and input[i + 1] == '(') {
            // Check if it's $((arith)) or $(cmd)
            if (i + 2 < input.len and input[i + 2] == '(') {
                // $((arith)) - skip past it
                i += 3;
                var depth: u32 = 2;
                while (i < input.len and depth > 0) {
                    if (input[i] == '(') depth += 1;
                    if (input[i] == ')') depth -= 1;
                    i += 1;
                }
            } else {
                // $(cmd) - found command substitution
                return true;
            }
        } else if (input[i] == '`') {
            // Backtick command substitution
            return true;
        } else {
            i += 1;
        }
    }
    return false;
}

// Expand $VAR references within arithmetic expressions (no allocation)
// Returns error.BufferTooSmall if result would be truncated
fn expandArithmeticVars(shell: *Shell, expr: []const u8, dest: *[256]u8) !usize {
    var out_pos: usize = 0;
    var i: usize = 0;

    while (i < expr.len) {
        if (expr[i] == '$' and i + 1 < expr.len) {
            i += 1;
            const name_start = i;
            while (i < expr.len and (std.ascii.isAlphanumeric(expr[i]) or expr[i] == '_')) {
                i += 1;
            }
            if (i > name_start) {
                const var_name = expr[name_start..i];
                if (shell.variables.get(var_name)) |value| {
                    if (value.len > 256 - out_pos) return error.BufferTooSmall;
                    @memcpy(dest[out_pos..][0..value.len], value);
                    out_pos += value.len;
                } else if (compat.posix.getenv(var_name)) |value| {
                    if (value.len > 256 - out_pos) return error.BufferTooSmall;
                    @memcpy(dest[out_pos..][0..value.len], value);
                    out_pos += value.len;
                } else {
                    // Unknown variable = 0 in arithmetic
                    if (out_pos >= 256) return error.BufferTooSmall;
                    dest[out_pos] = '0';
                    out_pos += 1;
                }
            } else {
                // Lone $ - copy it
                if (out_pos >= 256) return error.BufferTooSmall;
                dest[out_pos] = '$';
                out_pos += 1;
            }
        } else {
            if (out_pos >= 256) return error.BufferTooSmall;
            dest[out_pos] = expr[i];
            out_pos += 1;
            i += 1;
        }
    }
    return out_pos;
}

// Fast variable expansion that writes to a provided buffer (no allocation)
// Returns error.BufferTooSmall if result would be truncated - caller should fall back to full expansion
fn expandVariableFast(shell: *Shell, input: []const u8, dest: *[256]u8) !usize {
    // Fast path: no variables
    if (std.mem.indexOfScalar(u8, input, '$') == null) {
        if (input.len > 256) return error.BufferTooSmall;
        @memcpy(dest[0..input.len], input);
        return input.len;
    }

    var out_pos: usize = 0;
    var i: usize = 0;

    while (i < input.len and out_pos < 256) {
        if (input[i] == '$' and i + 1 < input.len) {
            i += 1;

            // Handle $? (exit code)
            if (input[i] == '?') {
                const exit_str = std.fmt.bufPrint(dest[out_pos..], "{d}", .{shell.last_exit_code}) catch break;
                out_pos += exit_str.len;
                i += 1;
                continue;
            }

            // Handle $((expr))
            if (i + 1 < input.len and input[i] == '(' and input[i + 1] == '(') {
                i += 2;
                const expr_start = i;
                var paren_count: u32 = 2;
                while (i < input.len and paren_count > 0) {
                    if (input[i] == '(') paren_count += 1;
                    if (input[i] == ')') paren_count -= 1;
                    if (paren_count > 0) i += 1;
                }
                if (paren_count == 0 and i > 0) {
                    const expr = input[expr_start .. i - 1];
                    i += 1; // skip final )
                    // Expand variables within the arithmetic expression first
                    var expr_buf: [256]u8 = undefined;
                    const expanded_expr_len = try expandArithmeticVars(shell, expr, &expr_buf);
                    const arith_result = shell.evaluateArithmetic(expr_buf[0..expanded_expr_len]) catch {
                        std.debug.print("zish: division by 0\n", .{});
                        break;
                    };
                    const result_str = std.fmt.bufPrint(dest[out_pos..], "{d}", .{arith_result}) catch break;
                    out_pos += result_str.len;
                    continue;
                }
            }

            // Simple $VAR
            const name_start = i;
            while (i < input.len and (std.ascii.isAlphanumeric(input[i]) or input[i] == '_')) {
                i += 1;
            }

            if (i > name_start) {
                const var_name = input[name_start..i];
                // Look up in shell variables first, then env
                if (shell.variables.get(var_name)) |value| {
                    if (value.len > 256 - out_pos) return error.BufferTooSmall;
                    @memcpy(dest[out_pos..][0..value.len], value);
                    out_pos += value.len;
                } else if (compat.posix.getenv(var_name)) |value| {
                    if (value.len > 256 - out_pos) return error.BufferTooSmall;
                    @memcpy(dest[out_pos..][0..value.len], value);
                    out_pos += value.len;
                }
            } else {
                // Lone $
                if (out_pos >= 256) return error.BufferTooSmall;
                dest[out_pos] = '$';
                out_pos += 1;
            }
        } else {
            if (out_pos >= 256) return error.BufferTooSmall;
            dest[out_pos] = input[i];
            out_pos += 1;
            i += 1;
        }
    }

    // if we exited because buffer full but input remains, that's truncation
    if (i < input.len) return error.BufferTooSmall;

    return out_pos;
}

// Fast path for echo builtin - uses stack buffers to avoid allocations
fn evaluateEchoBuiltinFast(shell: *Shell, node: *const ast.AstNode) !u8 {
    // Stack-allocated buffers for expanded arguments (max 16 args, 256 bytes each)
    var arg_buffers: [16][256]u8 = undefined;
    var arg_slices: [16][]const u8 = undefined;
    var arg_count: usize = 0;

    var interpret_escapes = false;
    var print_newline = true;
    var arg_start: usize = 1; // skip "echo"

    // Parse flags first
    while (arg_start < node.children.len and arg_count < 16) {
        const arg = node.children[arg_start].value;
        if (arg.len >= 2 and arg[0] == '-') {
            var valid_flag = true;
            var has_e = false;
            var has_n = false;
            for (arg[1..]) |c| {
                switch (c) {
                    'e' => has_e = true,
                    'n' => has_n = true,
                    'E' => {},
                    else => {
                        valid_flag = false;
                        break;
                    },
                }
            }
            if (valid_flag) {
                if (has_e) interpret_escapes = true;
                if (has_n) print_newline = false;
                arg_start += 1;
                continue;
            }
        }
        break;
    }

    // Expand remaining arguments into stack buffers
    for (node.children[arg_start..]) |arg_node| {
        if (arg_count >= 16) break;

        const arg = arg_node.value;
        const dest = &arg_buffers[arg_count];

        // For string nodes (single-quoted), no expansion needed
        if (arg_node.node_type == .string) {
            const len = @min(arg.len, 256);
            @memcpy(dest[0..len], arg[0..len]);
            arg_slices[arg_count] = dest[0..len];
        } else {
            const expanded_len = try expandVariableFast(shell, arg, dest);
            arg_slices[arg_count] = dest[0..expanded_len];
        }
        arg_count += 1;
    }

    // Output - batch into single buffer to minimize syscalls
    // SectorLambda-inspired: single write() is faster than multiple
    var out_buf: [4096]u8 = undefined;
    var out_pos: usize = 0;

    for (arg_slices[0..arg_count], 0..) |arg, i| {
        if (i > 0 and out_pos < out_buf.len) {
            out_buf[out_pos] = ' ';
            out_pos += 1;
        }
        if (interpret_escapes) {
            out_pos += writeEscapedToBuf(arg, out_buf[out_pos..]);
        } else {
            const copy_len = @min(arg.len, out_buf.len - out_pos);
            @memcpy(out_buf[out_pos..][0..copy_len], arg[0..copy_len]);
            out_pos += copy_len;
        }
    }
    if (print_newline and out_pos < out_buf.len) {
        out_buf[out_pos] = '\n';
        out_pos += 1;
    }

    // Single write syscall
    try shell.stdout().writeAll(out_buf[0..out_pos]);

    return 0;
}

pub fn evaluateCommand(shell: *Shell, node: *const ast.AstNode) !u8 {
    if (node.children.len == 0) return 1;

    // clean up any process substitution children when command finishes
    defer cleanupProcessSubst(shell);

    // parse prefix assignment count from value field
    const n_prefix: usize = if (node.value.len > 0)
        std.fmt.parseInt(usize, node.value, 10) catch 0
    else
        0;

    // set prefix env vars (temporarily) and track names for cleanup
    var prefix_names: [16][]const u8 = undefined;
    var prefix_had_old: [16]bool = undefined;
    var prefix_old_vals: [16][]const u8 = undefined;
    var prefix_tmp_vals: [16][]const u8 = undefined;
    var prefix_tmp_owned: [16]bool = undefined;
    const actual_prefix = @min(n_prefix, 16);

    for (0..actual_prefix) |i| {
        const assign = node.children[i];
        if (assign.node_type != .assignment or assign.children.len != 2) {
            prefix_had_old[i] = false;
            prefix_names[i] = "";
            prefix_tmp_vals[i] = "";
            prefix_tmp_owned[i] = false;
            continue;
        }
        const name = assign.children[0].value;
        const raw_val = assign.children[1].value;

        // expand variables in the value
        prefix_tmp_owned[i] = true;
        const expanded = shell.expandVariables(raw_val) catch
            shell.allocator.dupe(u8, raw_val) catch blk: {
                // fall back to AST-owned memory; mark non-owned so cleanup skips freeing
                prefix_tmp_owned[i] = false;
                break :blk raw_val;
            };

        prefix_names[i] = name;
        prefix_tmp_vals[i] = expanded;
        if (shell.variables.getPtr(name)) |val_ptr| {
            prefix_had_old[i] = true;
            prefix_old_vals[i] = val_ptr.*;
            val_ptr.* = expanded;
        } else {
            prefix_had_old[i] = false;
            const name_copy = shell.allocator.dupe(u8, name) catch continue;
            shell.variables.put(name_copy, expanded) catch {
                shell.allocator.free(name_copy);
                continue;
            };
        }
    }

    // cleanup: restore or remove prefix vars after command.
    // Iterate in REVERSE so duplicate names (A=1 A=2 cmd) restore innermost
    // first and each allocation is freed exactly once.
    defer {
        var i = actual_prefix;
        while (i > 0) {
            i -= 1;
            if (prefix_names[i].len == 0) continue;
            if (prefix_had_old[i]) {
                // restore old value, free the temp
                if (shell.variables.getPtr(prefix_names[i])) |val_ptr| {
                    val_ptr.* = prefix_old_vals[i];
                }
                if (prefix_tmp_owned[i]) shell.allocator.free(prefix_tmp_vals[i]);
            } else {
                // remove the var we added (fetchRemove frees key for us)
                if (shell.variables.fetchRemove(prefix_names[i])) |kv| {
                    shell.allocator.free(kv.key);
                    // skip free if the stored value is the non-owned AST fallback
                    if (prefix_tmp_owned[i] or kv.value.ptr != prefix_tmp_vals[i].ptr)
                        shell.allocator.free(kv.value);
                }
            }
        }
    }

    // command children start after prefix assignments
    const cmd_children = node.children[n_prefix..];
    if (cmd_children.len == 0) return 0; // bare prefix-only (shouldn't reach here)

    const raw_cmd = cmd_children[0].value;

    // Fast path for simple builtins - no allocation needed
    if (raw_cmd.len <= 8 and cmd_children.len == 1) {
        if (std.mem.eql(u8, raw_cmd, "true") or (raw_cmd.len == 1 and raw_cmd[0] == ':')) return 0;
        if (std.mem.eql(u8, raw_cmd, "false")) return 1;
        if (std.mem.eql(u8, raw_cmd, "continue")) return 253;
        if (std.mem.eql(u8, raw_cmd, "break")) return 254;
    }

    // Fast path for test builtin - avoid allocations in tight loops
    // Falls back to normal path if args too large for stack buffers
    // Skip fast paths when prefix assignments exist (node.children layout differs)
    if (n_prefix == 0 and ((raw_cmd.len == 1 and raw_cmd[0] == '[') or std.mem.eql(u8, raw_cmd, "test"))) {
        if (evaluateTestBuiltinFast(shell, node)) |result| {
            return result;
        } else |err| switch (err) {
            error.BufferTooSmall => {}, // fall through to normal path
            else => return err,
        }
    }

    // Fast path for echo builtin - avoid allocations in tight loops
    // Skip fast path if any arg has command substitution $(cmd) (not $((arith)))
    // Falls back to normal path if args too large for stack buffers
    if (n_prefix == 0 and std.mem.eql(u8, raw_cmd, "echo")) {
        var needs_full_expansion = false;
        for (cmd_children[1..]) |arg_node| {
            const arg = arg_node.value;
            // Check for features that need full expansion path:
            // - Command substitution $(...)
            // - Brace expansion {a,b}
            // - Parameter expansion ${VAR#...}, ${VAR%...}, ${VAR/...}
            if (hasCommandSubstitution(arg)) {
                needs_full_expansion = true;
                break;
            }
            if (Shell.hasBracePattern(arg)) {
                needs_full_expansion = true;
                break;
            }
            // Glob patterns (* ? [) must go through pathname expansion, not the
            // literal fast path — otherwise `echo *` prints the pattern verbatim.
            if (arg_node.node_type != .string and glob.hasGlobChars(arg)) {
                needs_full_expansion = true;
                break;
            }
            // Leading tilde (~ ~/ ~user ~+ ~-) needs the full expansion path.
            if (arg_node.node_type != .string and arg.len > 0 and arg[0] == '~') {
                needs_full_expansion = true;
                break;
            }
            // Check for ${...} with modifiers (contains ${...#, ${...%, ${.../, ${...:, ${...[)
            // Also need full path for array access ${arr[...]}
            if (std.mem.indexOf(u8, arg, "${")) |dollar_brace| {
                const rest = arg[dollar_brace + 2 ..];
                for (rest) |c| {
                    if (c == '}') break;
                    if (c == '#' or c == '%' or c == '/' or c == ':' or c == '[') {
                        needs_full_expansion = true;
                        break;
                    }
                }
                if (needs_full_expansion) break;
            }
        }
        if (!needs_full_expansion and !shell.opt_nounset and !shell.opt_xtrace) {
            if (evaluateEchoBuiltinFast(shell, node)) |result| {
                return result;
            } else |err| switch (err) {
                error.BufferTooSmall => {}, // fall through to normal path
                else => return err,
            }
        }
    }

    // expand command name (for ~/path/to/cmd)
    const cmd_name_result = try shell.expandVariablesZ(raw_cmd);
    defer cmd_name_result.deinit(shell.allocator);
    const cmd_name = cmd_name_result.slice;

    // alias expansion - substitute alias value for command name
    // but prevent infinite recursion for self-referencing aliases like "alias ls='ls --color=auto'"
    if (shell.aliases.get(cmd_name)) |alias_value| {
        // check if alias value starts with the same command (self-reference)
        const first_word_end = std.mem.indexOfScalar(u8, alias_value, ' ') orelse alias_value.len;
        const first_word = alias_value[0..first_word_end];

        // skip expansion if alias is self-referencing (e.g., ls -> ls --color=auto)
        if (!std.mem.eql(u8, first_word, cmd_name)) {
            // build new command: alias_value + remaining args
            var new_cmd: std.ArrayListUnmanaged(u8) = .empty;
            defer new_cmd.deinit(shell.allocator);

            try new_cmd.appendSlice(shell.allocator, alias_value);

            // append remaining arguments
            for (cmd_children[1..]) |arg_node| {
                try new_cmd.append(shell.allocator, ' ');
                try new_cmd.appendSlice(shell.allocator, arg_node.value);
            }

            // recursively execute the expanded command
            return shell.executeCommand(new_cmd.items);
        }
        // for self-referencing aliases, we'll add the extra args below
    }

    // get extra args from self-referencing alias (e.g., "--color=auto" from "ls --color=auto")
    const alias_extra_args = if (shell.aliases.get(cmd_name)) |alias_value| blk: {
        const first_word_end = std.mem.indexOfScalar(u8, alias_value, ' ') orelse alias_value.len;
        const first_word = alias_value[0..first_word_end];
        if (std.mem.eql(u8, first_word, cmd_name) and first_word_end < alias_value.len) {
            break :blk alias_value[first_word_end + 1 ..]; // args after first space
        }
        break :blk @as([]const u8, "");
    } else "";

    // expand glob patterns in arguments
    // IMPORTANT: use dupeZ to create null-terminated strings for execvpeZ
    var expanded_args = try std.ArrayList([:0]const u8).initCapacity(shell.allocator, 16);
    defer {
        for (expanded_args.items) |arg| shell.allocator.free(arg);
        expanded_args.deinit(shell.allocator);
    }

    try expanded_args.append(shell.allocator, try shell.allocator.dupeZ(u8, cmd_name));

    // insert alias extra args (e.g., "--color=auto")
    if (alias_extra_args.len > 0) {
        var iter = std.mem.splitScalar(u8, alias_extra_args, ' ');
        while (iter.next()) |arg| {
            if (arg.len > 0) {
                try expanded_args.append(shell.allocator, try shell.allocator.dupeZ(u8, arg));
            }
        }
    }

    for (cmd_children[1..]) |arg_node| {
        const arg = arg_node.value;

        // Skip all expansion for single-quoted strings
        if (arg_node.node_type == .string) {
            try expanded_args.append(shell.allocator, try shell.allocator.dupeZ(u8, arg));
            continue;
        }

        // Double-quoted strings: expand vars/cmds but no word splitting, glob,
        // or tilde (bash leaves '~' literal inside double quotes).
        if (arg_node.node_type == .double_quoted) {
            const var_expanded_result = try shell.expandVariablesNoTildeZ(arg);
            defer var_expanded_result.deinit(shell.allocator);
            try expanded_args.append(shell.allocator, try shell.allocator.dupeZ(u8, var_expanded_result.slice));
            continue;
        }

        // Step 0: Process substitution <(cmd) or >(cmd)
        if (expandProcessSubst(shell, arg) catch null) |proc_path| {
            try expanded_args.append(shell.allocator, proc_path);
            continue;
        }

        // Check if original arg has command substitution (for word splitting)
        const needs_word_split = hasCommandSubstitution(arg);

        // Step 1: Brace expansion {a,b,c} or {1..5}
        const brace_results = if (Shell.hasBracePattern(arg))
            try Shell.expandBraces(shell.allocator, arg)
        else
            null;
        defer if (brace_results) |br| Shell.freeBraceResults(shell.allocator, br);

        const items_to_expand = if (brace_results) |br| br else &[_][]const u8{arg};

        for (items_to_expand) |item| {
            // Step 2: Variable expansion (includes command substitution)
            const var_expanded_result = try shell.expandVariablesZ(item);
            defer var_expanded_result.deinit(shell.allocator);
            const var_expanded = var_expanded_result.slice;

            // Step 2.5: Word splitting for unquoted command substitution results
            // POSIX: unquoted $() results are split on IFS (default: space/tab/newline)
            if (needs_word_split) {
                var split_iter = std.mem.tokenizeAny(u8, var_expanded, " \t\n");
                var has_any = false;
                while (split_iter.next()) |word| {
                    has_any = true;
                    // Step 3: Glob expansion on each split word
                    if (glob.hasGlobChars(word)) {
                        const glob_results = try glob.expandGlob(shell.allocator, word);
                        defer glob.freeGlobResults(shell.allocator, glob_results);
                        if (glob_results.len == 0) {
                            try expanded_args.append(shell.allocator, try shell.allocator.dupeZ(u8, word));
                        } else {
                            for (glob_results) |match| {
                                try expanded_args.append(shell.allocator, try shell.allocator.dupeZ(u8, match));
                            }
                        }
                    } else {
                        try expanded_args.append(shell.allocator, try shell.allocator.dupeZ(u8, word));
                    }
                }
                // If command substitution produced empty output, skip the argument
                // (POSIX: empty unquoted expansion produces no fields)
                if (!has_any) continue;
            } else {
                // Step 3: Glob expansion (only if pattern contains glob chars)
                if (glob.hasGlobChars(var_expanded)) {
                    const glob_results = try glob.expandGlob(shell.allocator, var_expanded);
                    defer glob.freeGlobResults(shell.allocator, glob_results);

                    if (glob_results.len == 0) {
                        try expanded_args.append(shell.allocator, try shell.allocator.dupeZ(u8, var_expanded));
                    } else {
                        for (glob_results) |match| {
                            try expanded_args.append(shell.allocator, try shell.allocator.dupeZ(u8, match));
                        }
                    }
                } else {
                    try expanded_args.append(shell.allocator, try shell.allocator.dupeZ(u8, var_expanded));
                }
            }
        }
    }

    // xtrace: print expanded command before execution (to stderr)
    if (shell.opt_xtrace) {
        std.debug.print("+ ", .{});
        for (expanded_args.items, 0..) |arg, idx| {
            if (idx > 0) std.debug.print(" ", .{});
            std.debug.print("{s}", .{arg});
        }
        std.debug.print("\n", .{});
    }

    // dispatch to builtins module
    if (try builtins.dispatch(shell, cmd_name, expanded_args.items)) |result| {
        return result;
    }

    if (std.mem.eql(u8, cmd_name, "chpw")) {
        const crypto_mod = @import("crypto.zig");

        // check for flags
        if (expanded_args.items.len > 1) {
            const arg = expanded_args.items[1];
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                // show help
                try shell.stdout().writeAll("usage:\n");
                try shell.stdout().writeAll("  chpw           set password (prompts securely)\n");
                try shell.stdout().writeAll("  chpw -r        remove password protection\n");
                try shell.stdout().writeAll("  chpw -s        show password status\n");
                try shell.stdout().writeAll("  chpw -h        show this help\n");
                return 0;
            } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--remove")) {
                // remove password protection
                if (!crypto_mod.isPasswordModeEnabled(shell.allocator)) {
                    try shell.stdout().writeAll("password protection not enabled\n");
                    return 0;
                }

                // check if history is available
                if (shell.history) |h| {
                    // generate new random key
                    var new_key: [32]u8 = undefined;
                    compat.io().random(&new_key);

                    // re-encrypt history with new key
                    try h.reEncryptWithKey(new_key);

                    // save the new key to disk
                    try crypto_mod.saveKeyDirect(new_key);
                }

                // disable password mode
                try crypto_mod.disablePasswordMode(shell.allocator);

                try shell.stdout().writeAll("password protection removed\n");
                return 0;
            } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--status")) {
                // show status
                if (crypto_mod.isPasswordModeEnabled(shell.allocator)) {
                    try shell.stdout().writeAll("password protection: enabled\n");
                } else {
                    try shell.stdout().writeAll("password protection: disabled\n");
                }
                return 0;
            } else {
                try shell.stdout().writeAll("error: don't pass password as argument (security risk)\n");
                try shell.stdout().writeAll("usage:\n");
                try shell.stdout().writeAll("  chpw           set password (prompts securely)\n");
                try shell.stdout().writeAll("  chpw -r        remove password protection\n");
                try shell.stdout().writeAll("  chpw -s        show password status\n");
                return 1;
            }
        }

        // check if already password protected
        const already_protected = crypto_mod.isPasswordModeEnabled(shell.allocator);
        const log_mod = @import("history_log.zig");

        // if already protected, need old password to decrypt existing history atomically
        var old_entries: ?[]log_mod.EntryData = null;
        defer {
            if (old_entries) |entries| {
                for (entries) |entry| {
                    shell.allocator.free(entry.command);
                }
                shell.allocator.free(entries);
            }
        }

        if (already_protected) {
            const old_password = try crypto_mod.promptPassword(shell.allocator, "current password: ");
            defer shell.allocator.free(old_password);

            if (old_password.len == 0) {
                try shell.stdout().writeAll("password cannot be empty\n");
                return 1;
            }

            // derive old key and read all history entries from disk
            const old_key = try crypto_mod.deriveKeyFromPassword(old_password, shell.allocator);

            // validate old password by reading entries
            old_entries = log_mod.readAllWithKey(shell.allocator, old_key) catch |err| {
                if (err == error.AuthenticationFailed) {
                    try shell.stdout().writeAll("wrong password\n");
                    return 1;
                }
                return err;
            };

            if (old_entries.?.len == 0) {
                try shell.stdout().writeAll("warning: no history entries found (wrong password?)\n");
            }
        }

        // prompt for new password
        const new_password = try crypto_mod.promptPassword(shell.allocator, "new password: ");
        defer shell.allocator.free(new_password);

        if (new_password.len == 0) {
            try shell.stdout().writeAll("password cannot be empty\n");
            return 1;
        }

        // confirm password
        const confirm_password = try crypto_mod.promptPassword(shell.allocator, "confirm password: ");
        defer shell.allocator.free(confirm_password);

        if (!std.mem.eql(u8, new_password, confirm_password)) {
            try shell.stdout().writeAll("passwords don't match\n");
            return 1;
        }

        // derive new key
        const new_key = try crypto_mod.deriveKeyFromPassword(new_password, shell.allocator);

        // check if history is available
        if (shell.history) |h| {
            // if we have old entries from disk, merge them into history first
            if (old_entries) |entries| {
                for (entries) |entry| {
                    h.mergeEntry(entry) catch {};
                }
            }

            // re-encrypt all history with new key
            try h.reEncryptWithKey(new_key);
        }

        // enable password mode
        try crypto_mod.enablePasswordMode(shell.allocator);

        if (already_protected) {
            try shell.stdout().writeAll("password updated\n");
        } else {
            try shell.stdout().writeAll("password protection enabled\n");
        }

        return 0;
    }

    // check if it's a function call
    if (shell.functions.get(cmd_name)) |_| {
        // call function with remaining arguments
        return callFunction(shell, cmd_name, expanded_args.items[1..]) catch |err| {
            if (err == error.FunctionNotFound) {
                // shouldn't happen since we just checked, but handle anyway
            }
            return 1;
        };
    }

    // external command
    // restore terminal to normal mode so child can handle signals properly
    // only do this if stdin is a tty
    const is_tty = compat.posix.isatty(compat.posix.STDIN_FILENO);
    if (is_tty) {
        shell.disableRawMode();
    }
    defer if (is_tty) {
        shell.enableRawMode() catch {};
    };

    // use cached path lookup for faster execution
    if (shell.lookupCommand(cmd_name)) |full_path| {
        // dupe first; only free the original and replace on success
        // (freeing first would leave items[0] dangling for the cleanup defer)
        if (shell.allocator.dupeZ(u8, full_path)) |duped| {
            shell.allocator.free(expanded_args.items[0]);
            expanded_args.items[0] = duped;
        } else |_| {
            return 1;
        }
    }

    // build null-terminated argv on stack
    // expanded_args contains [:0]const u8 (null-terminated slices)
    var argv_buf: [256]?[*:0]const u8 = undefined;
    if (expanded_args.items.len >= argv_buf.len) {
        try shell.stdout().print("zish: too many arguments\n", .{});
        return 1;
    }
    for (expanded_args.items, 0..) |arg, i| {
        argv_buf[i] = arg.ptr;
    }
    argv_buf[expanded_args.items.len] = null;
    const argv = argv_buf[0..expanded_args.items.len :null];

    // In pipeline context, exec directly (we're already forked)
    if (shell.in_pipeline) {
        // Build environment in child process (after fork, safe from parent interference)
        const envp = buildEnvironment(shell) catch @as([*:null]const ?[*:0]const u8, @ptrCast(std.c.environ));
        compat.posix.execvpeZ(argv[0].?, argv, envp) catch {
            compat.posix.exit(127);
        };
        unreachable;
    }

    // Normal context: fork/exec for external command
    // Flush stdout buffer before forking
    shell.stdout().flush() catch {};

    const pid = compat.posix.fork() catch {
        try shell.stdout().print("zish: fork failed\n", .{});
        return 1;
    };

    if (pid == 0) {
        // child: create own process group and take terminal control
        // this allows TUI apps (like claude) to work properly
        const child_pid = std.os.linux.getpid();
        compat.posix.setpgid(0, 0) catch {};
        if (is_tty) {
            jobs.tcsetpgrp(compat.posix.STDIN_FILENO, child_pid) catch {};
        }

        // Build environment in child process (after fork, safe from parent interference)
        const envp = buildEnvironment(shell) catch @as([*:null]const ?[*:0]const u8, @ptrCast(std.c.environ));
        compat.posix.execvpeZ(argv[0].?, argv, envp) catch {
            compat.posix.exit(127);
        };
    }

    // parent: also set child's pgrp (race avoidance)
    compat.posix.setpgid(pid, pid) catch {};

    // parent - ignore SIGINT while child runs
    var old_sigint: compat.posix.Sigaction = undefined;
    const ignore_action = compat.posix.Sigaction{
        .handler = .{ .handler = compat.posix.SIG.IGN },
        .mask = std.mem.zeroes(compat.posix.sigset_t),
        .flags = 0,
    };
    compat.posix.sigaction(compat.posix.SIG.INT, &ignore_action, &old_sigint);
    defer compat.posix.sigaction(compat.posix.SIG.INT, &old_sigint, null);

    // wait for child
    const result = compat.posix.waitpid(pid, 0);

    // take back terminal control
    if (is_tty) {
        const shell_pgid: compat.posix.pid_t = @intCast(std.os.linux.syscall1(.getpgid, 0));
        jobs.tcsetpgrp(compat.posix.STDIN_FILENO, shell_pgid) catch {};
    }

    if (compat.posix.W.IFEXITED(result.status)) {
        const code = compat.posix.W.EXITSTATUS(result.status);
        if (code == 127) {
            try shell.stdout().print("zish: {s}: command not found\n", .{cmd_name});
            suggestCommand(shell, cmd_name);
        }
        return code;
    } else if (compat.posix.W.IFSIGNALED(result.status)) {
        return @truncate(128 + @as(u32, @intCast(@intFromEnum(compat.posix.W.TERMSIG(result.status)))));
    }
    return 127;
}

// Check if command name is a builtin - delegate to builtins module
fn isBuiltin(name: []const u8) bool {
    return builtins.isBuiltin(name);
}

// Check if any argument needs variable/glob expansion
fn needsExpansion(node: *const ast.AstNode) bool {
    for (node.children) |child| {
        for (child.value) |c| {
            if (c == '$' or c == '`' or c == '*' or c == '?' or c == '[' or c == '~') return true;
        }
    }
    return false;
}

// Exec a simple command directly (no variable expansion needed)
fn execSimpleCommand(shell: *Shell, node: *const ast.AstNode) void {
    var argv_buf: [256]?[*:0]const u8 = undefined;
    var arg_count: usize = 0;

    // First arg might need path lookup
    const cmd_name = node.children[0].value;
    if (shell.lookupCommand(cmd_name)) |full_path| {
        argv_buf[0] = @ptrCast(full_path.ptr);
    } else {
        argv_buf[0] = @ptrCast(cmd_name.ptr);
    }
    arg_count = 1;

    // Rest of args as-is
    for (node.children[1..]) |child| {
        if (arg_count >= 255) break;
        argv_buf[arg_count] = @ptrCast(child.value.ptr);
        arg_count += 1;
    }
    argv_buf[arg_count] = null;

    const argv = argv_buf[0..arg_count :null];
    const envp = buildEnvironment(shell) catch @as([*:null]const ?[*:0]const u8, @ptrCast(std.c.environ));
    compat.posix.execvpeZ(argv[0].?, argv, envp) catch {};
    compat.posix.exit(127);
}

pub fn evaluatePipeline(shell: *Shell, node: *const ast.AstNode) !u8 {
    if (node.children.len < 2) return 1;

    const num_commands = node.children.len;

    // Use stack allocation for small pipelines (up to 8 commands)
    var stack_pipes: [7][2]compat.posix.fd_t = undefined;
    var stack_pids: [8]compat.posix.pid_t = undefined;

    const pipes = if (num_commands <= 8)
        stack_pipes[0 .. num_commands - 1]
    else
        try shell.allocator.alloc([2]compat.posix.fd_t, num_commands - 1);
    defer if (num_commands > 8) shell.allocator.free(pipes);

    const pids = if (num_commands <= 8)
        stack_pids[0..num_commands]
    else
        try shell.allocator.alloc(compat.posix.pid_t, num_commands);
    defer if (num_commands > 8) shell.allocator.free(pids);

    // initialize to invalid fd for safe cleanup on error
    for (pipes) |*pipe_fds| {
        pipe_fds.*[0] = -1;
        pipe_fds.*[1] = -1;
    }

    for (pipes) |*pipe_fds| {
        pipe_fds.* = try compat.posix.pipe();
    }

    // initialize pids to 0 so we can track which children were forked
    for (pids) |*pid| {
        pid.* = 0;
    }

    // cleanup pipes and kill already-forked children on error
    // NOTE: if a child is in D-state (uninterruptible sleep, e.g. blocked on
    // NFS or stuck disk I/O), signals cannot interrupt it and the final
    // blocking waitpid may hang until the kernel operation completes or fails.
    // this is a fundamental unix limitation, not solvable in userspace.
    errdefer {
        // close all pipe fds first (children have their own copies via dup2)
        for (pipes) |pipe_fds| {
            if (pipe_fds[0] != -1) compat.posix.close(pipe_fds[0]);
            if (pipe_fds[1] != -1) compat.posix.close(pipe_fds[1]);
        }
        // kill and reap any children that were already forked
        // use WNOHANG to avoid blocking forever on stuck children
        for (pids) |pid| {
            if (pid != 0) {
                compat.posix.kill(pid, compat.posix.SIG.TERM) catch {};
            }
        }
        // brief sleep to let children handle SIGTERM
        compat.sleep(10 * std.time.ns_per_ms);
        // reap with WNOHANG, escalate to SIGKILL if needed
        for (pids) |pid| {
            if (pid != 0) {
                const result = compat.posix.waitpid(pid, compat.posix.W.NOHANG);
                if (result.pid == 0) {
                    // child still running, force kill
                    compat.posix.kill(pid, compat.posix.SIG.KILL) catch {};
                    _ = compat.posix.waitpid(pid, 0);
                }
            }
        }
    }

    // Flush stdout buffer before forking to prevent buffered data from
    // being written to pipes (causing jq parse errors, etc.)
    shell.stdout().flush() catch {};

    for (node.children, 0..) |child, i| {
        const pid = try compat.posix.fork();
        if (pid == 0) {
            // Setup pipes first
            if (i > 0) {
                try compat.posix.dup2(pipes[i - 1][0], compat.posix.STDIN_FILENO);
            }
            if (i < num_commands - 1) {
                try compat.posix.dup2(pipes[i][1], compat.posix.STDOUT_FILENO);
            }
            for (pipes) |pipe_fds| {
                compat.posix.close(pipe_fds[0]);
                compat.posix.close(pipe_fds[1]);
            }

            // Fast path: simple external command - exec directly without evaluateAst
            if (child.node_type == .command and child.children.len > 0) {
                const cmd_name = child.children[0].value;
                // Check if it's a simple external command (not a builtin, no special chars)
                if (!isBuiltin(cmd_name) and !needsExpansion(child)) {
                    execSimpleCommand(shell, child);
                    // execSimpleCommand doesn't return on success
                }
            }

            // Full path for builtins, complex commands, etc.
            shell.in_pipeline = true;
            const status = evaluateAst(shell, child) catch 127;
            shell.stdout().flush() catch {};
            std.process.exit(status);
        } else {
            pids[i] = pid;
        }
    }

    for (pipes) |pipe_fds| {
        compat.posix.close(pipe_fds[0]);
        compat.posix.close(pipe_fds[1]);
    }

    // ignore SIGINT in shell while waiting for pipeline (children will receive it)
    var old_sigint: compat.posix.Sigaction = undefined;
    const ignore_action = compat.posix.Sigaction{
        .handler = .{ .handler = compat.posix.SIG.IGN },
        .mask = std.mem.zeroes(compat.posix.sigset_t),
        .flags = 0,
    };
    compat.posix.sigaction(compat.posix.SIG.INT, &ignore_action, &old_sigint);
    defer compat.posix.sigaction(compat.posix.SIG.INT, &old_sigint, null);

    var last_status: u8 = 0;
    var pipefail_status: u8 = 0; // first non-zero status for pipefail

    for (pids) |pid| {
        const result = compat.posix.waitpid(pid, 0);
        var status: u8 = 0;
        if (compat.posix.W.IFEXITED(result.status)) {
            status = compat.posix.W.EXITSTATUS(result.status);
        } else if (compat.posix.W.IFSIGNALED(result.status)) {
            status = @truncate(128 + @as(u32, @intCast(@intFromEnum(compat.posix.W.TERMSIG(result.status)))));
        } else {
            status = 127;
        }
        last_status = status;
        // pipefail: remember first non-zero status
        if (shell.opt_pipefail and status != 0 and pipefail_status == 0) {
            pipefail_status = status;
        }
    }

    // pipefail: return first non-zero status if any command failed
    return if (shell.opt_pipefail and pipefail_status != 0) pipefail_status else last_status;
}

pub fn evaluateLogicalAnd(shell: *Shell, node: *const ast.AstNode) !u8 {
    if (node.children.len != 2) return 1;

    const left_status = try evaluateAst(shell, node.children[0]);
    if (left_status == 0) {
        return evaluateAst(shell, node.children[1]);
    }
    return left_status;
}

pub fn evaluateLogicalOr(shell: *Shell, node: *const ast.AstNode) !u8 {
    if (node.children.len != 2) return 1;

    const left_status = try evaluateAst(shell, node.children[0]);
    if (left_status != 0) {
        return evaluateAst(shell, node.children[1]);
    }
    return left_status;
}

pub fn evaluateRedirect(shell: *Shell, node: *const ast.AstNode) !u8 {
    if (node.children.len != 2) return 1;

    const command = node.children[0];
    const target = node.children[1];
    const redirect_type = node.value;

    const expanded_target = if (target.node_type == .string)
        try shell.allocator.dupe(u8, target.value)
    else
        try shell.expandVariables(target.value);
    defer shell.allocator.free(expanded_target);

    const stdin_backup = try compat.posix.dup(compat.posix.STDIN_FILENO);
    const stdout_backup = try compat.posix.dup(compat.posix.STDOUT_FILENO);
    const stderr_backup = try compat.posix.dup(compat.posix.STDERR_FILENO);
    defer {
        compat.posix.dup2(stdin_backup, compat.posix.STDIN_FILENO) catch {};
        compat.posix.dup2(stdout_backup, compat.posix.STDOUT_FILENO) catch {};
        compat.posix.dup2(stderr_backup, compat.posix.STDERR_FILENO) catch {};
        compat.posix.close(stdin_backup);
        compat.posix.close(stdout_backup);
        compat.posix.close(stderr_backup);
    }

    if (std.mem.eql(u8, redirect_type, ">")) {
        const file = try std.Io.Dir.cwd().createFile(compat.io(), expanded_target, .{ .truncate = true });
        defer file.close(compat.io());
        try compat.posix.dup2(file.handle, compat.posix.STDOUT_FILENO);
    } else if (std.mem.eql(u8, redirect_type, ">>")) {
        // create file if doesn't exist, don't truncate if exists
        const file = try std.Io.Dir.cwd().createFile(compat.io(), expanded_target, .{ .truncate = false });
        defer file.close(compat.io());
        if (std.c.lseek(file.handle, 0, std.c.SEEK.END) < 0) return error.Unseekable;
        try compat.posix.dup2(file.handle, compat.posix.STDOUT_FILENO);
    } else if (std.mem.eql(u8, redirect_type, "<")) {
        const file = try std.Io.Dir.cwd().openFile(compat.io(), expanded_target, .{ .mode = .read_only });
        defer file.close(compat.io());
        try compat.posix.dup2(file.handle, compat.posix.STDIN_FILENO);
    } else if (std.mem.eql(u8, redirect_type, "2>")) {
        const file = try std.Io.Dir.cwd().createFile(compat.io(), expanded_target, .{ .truncate = true });
        defer file.close(compat.io());
        try compat.posix.dup2(file.handle, compat.posix.STDERR_FILENO);
    } else if (std.mem.eql(u8, redirect_type, "2>>")) {
        const file = try std.Io.Dir.cwd().createFile(compat.io(), expanded_target, .{ .truncate = false });
        defer file.close(compat.io());
        if (std.c.lseek(file.handle, 0, std.c.SEEK.END) < 0) return error.Unseekable;
        try compat.posix.dup2(file.handle, compat.posix.STDERR_FILENO);
    } else if (std.mem.eql(u8, redirect_type, "2>&1")) {
        try compat.posix.dup2(compat.posix.STDOUT_FILENO, compat.posix.STDERR_FILENO);
    } else if (std.mem.eql(u8, redirect_type, ">&2")) {
        try compat.posix.dup2(compat.posix.STDERR_FILENO, compat.posix.STDOUT_FILENO);
    } else if (std.mem.eql(u8, redirect_type, "&>")) {
        const file = try std.Io.Dir.cwd().createFile(compat.io(), expanded_target, .{ .truncate = true });
        defer file.close(compat.io());
        try compat.posix.dup2(file.handle, compat.posix.STDOUT_FILENO);
        try compat.posix.dup2(file.handle, compat.posix.STDERR_FILENO);
    } else if (std.mem.eql(u8, redirect_type, "&>>")) {
        const file = try std.Io.Dir.cwd().createFile(compat.io(), expanded_target, .{ .truncate = false });
        defer file.close(compat.io());
        if (std.c.lseek(file.handle, 0, std.c.SEEK.END) < 0) return error.Unseekable;
        try compat.posix.dup2(file.handle, compat.posix.STDOUT_FILENO);
        try compat.posix.dup2(file.handle, compat.posix.STDERR_FILENO);
    } else if (std.mem.eql(u8, redirect_type, "<<<")) {
        // here string: create pipe, write string, connect to stdin
        const pipe_fds = try compat.posix.pipe();
        defer compat.posix.close(pipe_fds[0]);

        // write string to write end of pipe
        const content_with_newline = try std.fmt.allocPrint(shell.allocator, "{s}\n", .{expanded_target});
        defer shell.allocator.free(content_with_newline);
        _ = try compat.posix.write(pipe_fds[1], content_with_newline);
        compat.posix.close(pipe_fds[1]);

        // connect read end to stdin
        try compat.posix.dup2(pipe_fds[0], compat.posix.STDIN_FILENO);
    }

    return evaluateAst(shell, command);
}

pub fn evaluateList(shell: *Shell, node: *const ast.AstNode) !u8 {
    var last_status: u8 = 0;
    for (node.children) |child| {
        last_status = try evaluateAst(shell, child);
        shell.last_exit_code = last_status;
        // propagate break/continue signals up
        if (last_status == 253 or last_status == 254) return last_status;
        // errexit: exit on non-zero status (but not for conditionals/loops)
        if (shell.opt_errexit and last_status != 0) {
            return last_status;
        }
    }
    return last_status;
}

pub fn evaluateAssignment(shell: *Shell, node: *const ast.AstNode) !u8 {
    if (node.children.len != 2) return 1;

    var name = node.children[0].value;
    const value = node.children[1].value;

    // check for array append syntax: arr+=(values)
    const is_append = name.len > 0 and name[name.len - 1] == '+';
    if (is_append) {
        name = name[0 .. name.len - 1];
    }

    // check for array element assignment: arr[n]=value
    if (std.mem.indexOfScalar(u8, name, '[')) |bracket_pos| {
        if (std.mem.indexOfScalar(u8, name[bracket_pos..], ']')) |close_offset| {
            const arr_name = name[0..bracket_pos];
            const index_str = name[bracket_pos + 1 .. bracket_pos + close_offset];

            // parse index (can be arithmetic expression)
            const index = if (index_str.len > 0)
                @as(usize, @intCast(@max(0, shell.evaluateArithmetic(index_str) catch 0)))
            else
                0;

            const expanded_value = try shell.expandVariables(value);
            defer shell.allocator.free(expanded_value);

            try shell.setArrayElement(arr_name, index, expanded_value);
            return 0;
        }
    }

    // check for array assignment: arr=(a b c)
    if (value.len >= 2 and value[0] == '(' and value[value.len - 1] == ')') {
        const array_content = value[1 .. value.len - 1];

        // parse array elements (space-separated, respecting quotes)
        var elements: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (elements.items) |elem| shell.allocator.free(elem);
            elements.deinit(shell.allocator);
        }

        var i: usize = 0;
        while (i < array_content.len) {
            // skip whitespace
            while (i < array_content.len and (array_content[i] == ' ' or array_content[i] == '\t')) {
                i += 1;
            }
            if (i >= array_content.len) break;

            const elem_start = i;
            var in_quote: u8 = 0;

            // parse element (handle quotes)
            while (i < array_content.len) {
                const c = array_content[i];
                if (in_quote != 0) {
                    if (c == in_quote) in_quote = 0;
                } else if (c == '"' or c == '\'') {
                    in_quote = c;
                } else if (c == ' ' or c == '\t') {
                    break;
                }
                i += 1;
            }

            if (i > elem_start) {
                var elem = array_content[elem_start..i];
                // strip quotes if present
                if (elem.len >= 2 and ((elem[0] == '"' and elem[elem.len - 1] == '"') or
                    (elem[0] == '\'' and elem[elem.len - 1] == '\'')))
                {
                    elem = elem[1 .. elem.len - 1];
                }
                // expand variables in element
                const expanded = try shell.expandVariables(elem);
                try elements.append(shell.allocator, expanded);
            }
        }

        if (is_append) {
            try shell.appendArray(name, elements.items);
        } else {
            try shell.setArray(name, elements.items);
        }
        return 0;
    }

    // fast path for pure arithmetic assignments like i=$((i+1))
    if (value.len >= 5 and std.mem.startsWith(u8, value, "$((") and value[value.len - 2] == ')' and value[value.len - 1] == ')') {
        const expr = value[3 .. value.len - 2];
        const arith_result = shell.evaluateArithmetic(expr) catch 0;

        var result_buf: [32]u8 = undefined;
        const result_str = std.fmt.bufPrint(&result_buf, "{d}", .{arith_result}) catch return 1;

        if (shell.variables.getPtr(name)) |value_ptr| {
            const old_value = value_ptr.*;
            if (result_str.len <= old_value.len) {
                const writable: [*]u8 = @ptrCast(@constCast(old_value.ptr));
                @memcpy(writable[0..result_str.len], result_str);
                value_ptr.* = writable[0..result_str.len];
            } else {
                shell.allocator.free(old_value);
                value_ptr.* = try shell.allocator.dupe(u8, result_str);
            }
            return 0;
        }

        const name_copy = try shell.allocator.dupe(u8, name);
        const value_copy = try shell.allocator.dupe(u8, result_str);
        try shell.variables.put(name_copy, value_copy);
        return 0;
    }

    // regular scalar assignment
    const expanded_value = try shell.expandVariables(value);
    defer shell.allocator.free(expanded_value);

    if (shell.variables.getPtr(name)) |value_ptr| {
        shell.allocator.free(value_ptr.*);
        value_ptr.* = try shell.allocator.dupe(u8, expanded_value);
        return 0;
    }

    const name_copy = try shell.allocator.dupe(u8, name);
    const value_copy = try shell.allocator.dupe(u8, expanded_value);
    try shell.variables.put(name_copy, value_copy);
    return 0;
}

pub fn evaluateIf(shell: *Shell, node: *const ast.AstNode) !u8 {
    if (node.children.len < 2) return 1;

    const condition = try evaluateAst(shell, node.children[0]);

    if (condition == 0) {
        return evaluateAst(shell, node.children[1]);
    } else if (node.children.len > 2) {
        return evaluateAst(shell, node.children[2]);
    }

    return 0;
}

pub fn evaluateWhile(shell: *Shell, node: *const ast.AstNode) !u8 {
    if (node.children.len != 2) return 1;

    var last_status: u8 = 0;
    var iterations: u32 = 0;
    const max_iterations: u32 = 10000;

    while (iterations < max_iterations) {
        const condition = try evaluateAst(shell, node.children[0]);
        if (condition != 0) break;

        last_status = try evaluateAst(shell, node.children[1]);
        if (last_status == 254) break; // break
        if (last_status == 253) { // continue
            last_status = 0;
            iterations += 1;
            continue;
        }
        iterations += 1;
    }

    if (iterations >= max_iterations) {
        try shell.stdout().writeAll("while: iteration limit reached\n");
        return 1;
    }

    return if (last_status == 254) 0 else last_status;
}

pub fn evaluateUntil(shell: *Shell, node: *const ast.AstNode) !u8 {
    if (node.children.len != 2) return 1;

    var last_status: u8 = 0;
    var iterations: u32 = 0;
    const max_iterations: u32 = 10000;

    while (iterations < max_iterations) {
        const condition = try evaluateAst(shell, node.children[0]);
        if (condition == 0) break;

        last_status = try evaluateAst(shell, node.children[1]);
        if (last_status == 254) break; // break
        if (last_status == 253) { // continue
            last_status = 0;
            iterations += 1;
            continue;
        }
        iterations += 1;
    }

    if (iterations >= max_iterations) {
        try shell.stdout().writeAll("until: iteration limit reached\n");
        return 1;
    }

    return last_status;
}

pub fn evaluateFor(shell: *Shell, node: *const ast.AstNode) !u8 {
    if (node.children.len < 3) return 1;

    const variable = node.children[0];
    const body = node.children[node.children.len - 1];
    const values = node.children[1 .. node.children.len - 1];

    var last_status: u8 = 0;
    var should_break = false;

    // SectorLambda-inspired: cache variable pointer to avoid repeated hash lookups
    // Pre-allocate loop variable with generous buffer to avoid reallocation
    var cached_value_ptr: ?*[]const u8 = null;
    var loop_buf: [256]u8 = undefined; // stack buffer for small values
    var heap_buf: ?[]u8 = null;
    defer if (heap_buf) |hb| shell.allocator.free(hb);

    // Pre-existing heap value: take ownership so we can free it exactly once
    // when the loop is done (setForVariableFast overwrites the slot without freeing).
    // EXCEPT when an enclosing for-loop uses the same variable name: then the
    // current value points at THAT frame's stack buffer and must not be freed.
    var pre_existing_value: ?[]const u8 = null;
    const var_is_active_scratch = blk: {
        for (shell.for_scratch_names[0..shell.for_scratch_depth]) |n| {
            if (std.mem.eql(u8, n, variable.value)) break :blk true;
        }
        break :blk false;
    };

    // Ensure variable exists with preallocated buffer
    if (shell.variables.getPtr(variable.value)) |ptr| {
        cached_value_ptr = ptr;
        if (!var_is_active_scratch) pre_existing_value = ptr.*;
    } else {
        // Create new variable with stack buffer backing
        const name_copy = try shell.allocator.dupe(u8, variable.value);
        try shell.variables.put(name_copy, loop_buf[0..0]);
        cached_value_ptr = shell.variables.getPtr(variable.value);
    }

    // Mark this variable as scratch for the duration of the loop
    const pushed_scratch = shell.for_scratch_depth < shell.for_scratch_names.len;
    if (pushed_scratch) {
        shell.for_scratch_names[shell.for_scratch_depth] = variable.value;
        shell.for_scratch_depth += 1;
    }
    defer if (pushed_scratch) {
        shell.for_scratch_depth -= 1;
    };

    // On EVERY exit path (normal or error): the map value points at
    // loop_buf/heap_buf, which die with this frame. Replace it with a heap
    // dupe of the final value so no dangling slice escapes, then free the
    // pre-existing value we took ownership of above.
    // NOTE: runs before the heap_buf defer (LIFO), so the source is still alive.
    defer {
        if (shell.variables.getPtr(variable.value)) |ptr| {
            ptr.* = shell.allocator.dupe(u8, ptr.*) catch "";
        }
        if (pre_existing_value) |old| shell.allocator.free(old);
    }

    outer: for (values) |value_node| {
        const raw_value = value_node.value;

        // Skip all expansion for single-quoted strings
        if (value_node.node_type == .string) {
            setForVariableFast(cached_value_ptr.?, raw_value, &loop_buf, &heap_buf, shell.allocator);
            last_status = try evaluateAst(shell, body);
            if (last_status == 254) {
                should_break = true;
                break :outer;
            }
            if (last_status == 253) last_status = 0;
            continue;
        }

        // Double-quoted: expand vars/cmds but no word splitting or tilde
        if (value_node.node_type == .double_quoted) {
            const var_expanded_res = try shell.expandVariablesNoTildeZ(raw_value);
            defer var_expanded_res.deinit(shell.allocator);
            const var_expanded = var_expanded_res.slice;
            setForVariableFast(cached_value_ptr.?, var_expanded, &loop_buf, &heap_buf, shell.allocator);
            last_status = try evaluateAst(shell, body);
            if (last_status == 254) {
                should_break = true;
                break :outer;
            }
            if (last_status == 253) last_status = 0;
            continue;
        }

        const has_brace = Shell.hasBracePattern(raw_value);
        const has_tilde = raw_value.len > 0 and raw_value[0] == '~';
        const needs_var_expansion = has_tilde or std.mem.indexOfScalar(u8, raw_value, '$') != null;
        const has_glob = glob.hasGlobChars(raw_value);
        const needs_word_split = hasCommandSubstitution(raw_value);

        // Fast path: no special expansion needed
        if (!has_brace and !needs_var_expansion and !has_glob) {
            setForVariableFast(cached_value_ptr.?, raw_value, &loop_buf, &heap_buf, shell.allocator);
            last_status = try evaluateAst(shell, body);
            if (last_status == 254) {
                should_break = true;
                break :outer;
            }
            if (last_status == 253) last_status = 0;
            continue;
        }

        // Step 1: Brace expansion
        const brace_results = if (has_brace)
            try Shell.expandBraces(shell.allocator, raw_value)
        else
            null;
        defer if (brace_results) |br| Shell.freeBraceResults(shell.allocator, br);

        const brace_items = if (brace_results) |br| br else &[_][]const u8{raw_value};

        for (brace_items) |brace_item| {
            // Step 2: Variable expansion
            const var_expanded = if (needs_var_expansion or (brace_results != null))
                try shell.expandVariables(brace_item)
            else
                try shell.allocator.dupe(u8, brace_item);
            defer shell.allocator.free(var_expanded);

            // Step 2.5: Word splitting for unquoted command substitution
            if (needs_word_split) {
                var split_iter = std.mem.tokenizeAny(u8, var_expanded, " \t\n");
                while (split_iter.next()) |word| {
                    // Step 3: Glob expansion on each split word
                    if (glob.hasGlobChars(word)) {
                        const glob_results = try glob.expandGlob(shell.allocator, word);
                        defer glob.freeGlobResults(shell.allocator, glob_results);
                        const items = if (glob_results.len == 0)
                            &[_][]const u8{word}
                        else
                            glob_results;
                        for (items) |item| {
                            setForVariableFast(cached_value_ptr.?, item, &loop_buf, &heap_buf, shell.allocator);
                            last_status = try evaluateAst(shell, body);
                            if (last_status == 254) { should_break = true; break :outer; }
                            if (last_status == 253) { last_status = 0; continue; }
                        }
                    } else {
                        setForVariableFast(cached_value_ptr.?, word, &loop_buf, &heap_buf, shell.allocator);
                        last_status = try evaluateAst(shell, body);
                        if (last_status == 254) { should_break = true; break :outer; }
                        if (last_status == 253) { last_status = 0; continue; }
                    }
                }
                continue;
            }

            // Step 3: Glob expansion
            if (glob.hasGlobChars(var_expanded)) {
                const glob_results = try glob.expandGlob(shell.allocator, var_expanded);
                defer glob.freeGlobResults(shell.allocator, glob_results);

                const items = if (glob_results.len == 0)
                    &[_][]const u8{var_expanded}
                else
                    glob_results;

                for (items) |item| {
                    setForVariableFast(cached_value_ptr.?, item, &loop_buf, &heap_buf, shell.allocator);
                    last_status = try evaluateAst(shell, body);
                    if (last_status == 254) {
                        should_break = true;
                        break :outer;
                    }
                    if (last_status == 253) {
                        last_status = 0;
                        continue;
                    }
                }
            } else {
                setForVariableFast(cached_value_ptr.?, var_expanded, &loop_buf, &heap_buf, shell.allocator);
                last_status = try evaluateAst(shell, body);
                if (last_status == 254) {
                    should_break = true;
                    break :outer;
                }
                if (last_status == 253) {
                    last_status = 0;
                }
            }
        }
    }

    return if (should_break) 0 else last_status;
}

// Ultra-fast variable assignment using cached pointer - no hash lookup per iteration
// SectorLambda-inspired: minimize per-iteration overhead
inline fn setForVariableFast(
    value_ptr: *[]const u8,
    value: []const u8,
    stack_buf: *[256]u8,
    heap_buf: *?[]u8,
    allocator: std.mem.Allocator,
) void {
    if (value.len <= 256) {
        // Use stack buffer - zero allocations
        @memcpy(stack_buf[0..value.len], value);
        value_ptr.* = stack_buf[0..value.len];
    } else {
        // Need heap for large values (rare)
        if (heap_buf.*) |hb| {
            if (value.len <= hb.len) {
                @memcpy(hb[0..value.len], value);
                value_ptr.* = hb[0..value.len];
                return;
            }
            allocator.free(hb);
        }
        heap_buf.* = allocator.dupe(u8, value) catch return;
        value_ptr.* = heap_buf.*.?;
    }
}

// Helper for for-loop variable assignment - reuses existing storage when possible
fn setForVariable(shell: *Shell, name: []const u8, value: []const u8) !void {
    // Try to update existing variable in-place
    if (shell.variables.getPtr(name)) |value_ptr| {
        const old_value = value_ptr.*;
        // Reuse buffer if it fits
        if (value.len <= old_value.len) {
            const writable: [*]u8 = @ptrCast(@constCast(old_value.ptr));
            @memcpy(writable[0..value.len], value);
            value_ptr.* = writable[0..value.len];
        } else {
            shell.allocator.free(old_value);
            value_ptr.* = try shell.allocator.dupe(u8, value);
        }
        return;
    }

    // New variable
    const name_copy = try shell.allocator.dupe(u8, name);
    const value_copy = try shell.allocator.dupe(u8, value);
    try shell.variables.put(name_copy, value_copy);
}

pub fn evaluateSubshell(shell: *Shell, node: *const ast.AstNode) !u8 {
    if (node.children.len == 0) return 1;
    return evaluateAst(shell, node.children[0]);
}

pub fn evaluateBackground(shell: *Shell, node: *const ast.AstNode) !u8 {
    if (node.children.len == 0) return 1;

    const command = node.children[0];

    // get command string for job display by serializing AST
    var cmd_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer cmd_buf.deinit(shell.allocator);
    serializeAst(shell.allocator, &cmd_buf, command) catch {};
    const cmd_str = if (cmd_buf.items.len > 0) cmd_buf.items else command.value;

    // flush stdout buffer before forking to prevent double-writes
    shell.stdout().flush() catch {};

    // fork to run command in background
    const pid = compat.posix.fork() catch {
        try shell.stdout().writeAll("zish: fork failed\n");
        return 1;
    };

    if (pid == 0) {
        // === CHILD PROCESS ===
        // SAFETY: After fork, parent's GPA state may be inconsistent if fork
        // occurred during an allocation. Switch to page_allocator immediately.
        // This allocator is stateless and safe to use post-fork.
        shell.allocator = std.heap.page_allocator;

        // set up process group for job control
        jobs.launchProcess(0, 0, false, compat.posix.STDIN_FILENO);

        // Mark as in_pipeline so external commands exec directly
        // instead of forking again (avoids double-fork for bg jobs)
        shell.in_pipeline = true;

        // evaluate command and exit with its status
        const status = evaluateAst(shell, command) catch 127;
        shell.stdout().flush() catch {};
        compat.posix.exit(status);
    }

    // === PARENT PROCESS ===
    // both parent and child call setpgid to avoid race condition
    // (whichever runs first establishes the group)
    compat.posix.setpgid(pid, pid) catch |err| {
        // EACCES: child already exec'd (fine, it set its own pgrp)
        // ESRCH: child already exited (fine, we'll reap it)
        if (err != error.PermissionDenied and err != error.ProcessNotFound) {
            std.debug.print("zish: setpgid({d}): {}\n", .{ pid, err });
        }
    };

    // add job to table
    const job_id = shell.job_table.addJob(pid, cmd_str, false) catch {
        try shell.stdout().print("[?] {d}\n", .{pid});
        return 0;
    };

    try shell.stdout().print("[{d}] {d}\n", .{ job_id, pid });
    return 0;
}

pub fn evaluateCase(shell: *Shell, node: *const ast.AstNode) !u8 {
    // case structure: children[0] = expr, children[1..] = case_items
    if (node.children.len < 1) return 1;

    // expand the expression being matched
    const expr_value = try shell.expandVariables(node.children[0].value);
    defer shell.allocator.free(expr_value);

    // iterate through case items (children[1..])
    for (node.children[1..]) |case_item| {
        if (case_item.node_type != .case_item) continue;

        // patterns are stored in case_item.value, separated by '|'
        const patterns = case_item.value;
        var pattern_iter = std.mem.splitScalar(u8, patterns, '|');

        while (pattern_iter.next()) |pattern| {
            // expand variables in pattern
            const expanded_pattern = try shell.expandVariables(pattern);
            defer shell.allocator.free(expanded_pattern);

            // check if pattern matches
            if (glob.matchGlob(expanded_pattern, expr_value)) {
                // execute the body (case_item.children[0])
                if (case_item.children.len > 0) {
                    return evaluateAst(shell, case_item.children[0]);
                }
                return 0;
            }
        }
    }

    // no pattern matched
    return 0;
}

pub fn evaluateTest(shell: *Shell, node: *const ast.AstNode) !u8 {
    // expand variables in children
    var args = try std.ArrayList([]const u8).initCapacity(shell.allocator, 16);
    defer {
        for (args.items) |arg| shell.allocator.free(arg);
        args.deinit(shell.allocator);
    }

    for (node.children) |child| {
        const expanded = try shell.expandVariables(child.value);
        try args.append(shell.allocator, expanded);
    }

    const result = evaluateTestExpr(args.items);
    return if (result) 0 else 1;
}

fn evaluateTestExpr(args: []const []const u8) bool {
    if (args.len == 0) return false;

    var i: usize = 0;
    var negate = false;

    // check for negation
    if (args.len > 0 and std.mem.eql(u8, args[0], "!")) {
        negate = true;
        i = 1;
    }

    if (i >= args.len) return negate;

    const result = evaluateTestPrimary(args[i..]);
    return if (negate) !result else result;
}

fn evaluateTestPrimary(args: []const []const u8) bool {
    if (args.len == 0) return false;

    const first = args[0];

    // unary file tests: -x, -f, -d, -e, -r, -w, -s
    if (first.len == 2 and first[0] == '-' and args.len >= 2) {
        const path = args[1];
        const cwd = std.Io.Dir.cwd();

        return switch (first[1]) {
            'e', 'a' => blk: {
                // file exists (-e or -a)
                cwd.access(compat.io(), path, .{}) catch break :blk false;
                break :blk true;
            },
            'f' => blk: {
                // regular file
                const stat = cwd.statFile(compat.io(), path, .{}) catch break :blk false;
                break :blk stat.kind == .file;
            },
            'd' => blk: {
                // directory
                const stat = cwd.statFile(compat.io(), path, .{}) catch break :blk false;
                break :blk stat.kind == .directory;
            },
            'r' => blk: {
                // readable
                cwd.access(compat.io(), path, .{ .read = true }) catch break :blk false;
                break :blk true;
            },
            'w' => blk: {
                // writable
                cwd.access(compat.io(), path, .{ .write = true }) catch break :blk false;
                break :blk true;
            },
            'x' => blk: {
                // executable - check if file exists and has execute permission
                const file = cwd.openFile(compat.io(), path, .{}) catch break :blk false;
                defer file.close(compat.io());
                const stat = file.stat(compat.io()) catch break :blk false;
                // check execute bit for owner
                break :blk (stat.permissions.toMode() & 0o100) != 0;
            },
            's' => blk: {
                // file exists and has size > 0
                const stat = cwd.statFile(compat.io(), path, .{}) catch break :blk false;
                break :blk stat.size > 0;
            },
            'z' => blk: {
                // string is empty (unary on second arg)
                break :blk args[1].len == 0;
            },
            'n' => blk: {
                // string is non-empty
                break :blk args[1].len > 0;
            },
            else => false,
        };
    }

    // binary operators: ==, !=, -eq, -ne, -lt, -gt, -le, -ge
    if (args.len >= 3) {
        const left = args[0];
        const op = args[1];
        const right = args[2];

        if (std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "=")) {
            return std.mem.eql(u8, left, right);
        } else if (std.mem.eql(u8, op, "!=")) {
            return !std.mem.eql(u8, left, right);
        } else if (std.mem.eql(u8, op, "-eq")) {
            const l = fastParseI64(left) orelse return false;
            const r = fastParseI64(right) orelse return false;
            return l == r;
        } else if (std.mem.eql(u8, op, "-ne")) {
            const l = fastParseI64(left) orelse return false;
            const r = fastParseI64(right) orelse return false;
            return l != r;
        } else if (std.mem.eql(u8, op, "-lt")) {
            const l = fastParseI64(left) orelse return false;
            const r = fastParseI64(right) orelse return false;
            return l < r;
        } else if (std.mem.eql(u8, op, "-gt")) {
            const l = fastParseI64(left) orelse return false;
            const r = fastParseI64(right) orelse return false;
            return l > r;
        } else if (std.mem.eql(u8, op, "-le")) {
            const l = fastParseI64(left) orelse return false;
            const r = fastParseI64(right) orelse return false;
            return l <= r;
        } else if (std.mem.eql(u8, op, "-ge")) {
            const l = fastParseI64(left) orelse return false;
            const r = fastParseI64(right) orelse return false;
            return l >= r;
        }
    }

    // single arg: non-empty string is true
    return first.len > 0;
}

fn setShellVar(shell: *Shell, name: []const u8, value: []const u8) !void {
    const value_copy = try shell.allocator.dupe(u8, value);
    errdefer shell.allocator.free(value_copy);

    // check if key exists
    if (shell.variables.getKey(name)) |existing_key| {
        // key exists, just update value
        if (try shell.variables.fetchPut(existing_key, value_copy)) |old| {
            shell.allocator.free(old.value);
        }
    } else {
        // new key, need to dupe it
        const name_copy = try shell.allocator.dupe(u8, name);
        try shell.variables.put(name_copy, value_copy);
    }
}

pub fn evaluateFunctionDef(shell: *Shell, node: *const ast.AstNode) !u8 {
    // node.value = function name, node.children[0] = body
    if (node.children.len == 0) return 1;

    const func_name = node.value;
    const body = node.children[0];

    // Clone AST into shell's allocator for persistent storage
    const body_clone = try body.clone(shell.allocator);
    errdefer body_clone.destroy(shell.allocator);

    // store function
    const name_copy = try shell.allocator.dupe(u8, func_name);
    errdefer shell.allocator.free(name_copy);

    if (try shell.functions.fetchPut(name_copy, body_clone)) |old| {
        // free old value but not key (fetchPut reuses key slot)
        shell.allocator.free(name_copy); // we don't need the new key copy
        old.value.destroy(shell.allocator); // free old AST
    }

    return 0;
}

fn serializeAst(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), node: *const ast.AstNode) !void {
    switch (node.node_type) {
        .command => {
            for (node.children, 0..) |child, i| {
                if (i > 0) try buf.append(allocator, ' ');
                try buf.appendSlice(allocator, child.value);
            }
        },
        .list => {
            for (node.children, 0..) |child, i| {
                if (i > 0) try buf.appendSlice(allocator, "; ");
                try serializeAst(allocator, buf, child);
            }
        },
        .pipeline => {
            for (node.children, 0..) |child, i| {
                if (i > 0) try buf.appendSlice(allocator, " | ");
                try serializeAst(allocator, buf, child);
            }
        },
        .logical_and => {
            if (node.children.len >= 2) {
                try serializeAst(allocator, buf, node.children[0]);
                try buf.appendSlice(allocator, " && ");
                try serializeAst(allocator, buf, node.children[1]);
            }
        },
        .logical_or => {
            if (node.children.len >= 2) {
                try serializeAst(allocator, buf, node.children[0]);
                try buf.appendSlice(allocator, " || ");
                try serializeAst(allocator, buf, node.children[1]);
            }
        },
        .test_expression => {
            try buf.appendSlice(allocator, "[[ ");
            try buf.appendSlice(allocator, node.value);
            try buf.appendSlice(allocator, " ]]");
        },
        else => {
            try buf.appendSlice(allocator, node.value);
        },
    }
}

pub fn callFunction(shell: *Shell, name: []const u8, args: []const []const u8) !u8 {
    const body = shell.functions.get(name) orelse return error.FunctionNotFound;

    // set positional parameters $1, $2, etc.
    for (args, 1..) |arg, i| {
        var num_buf: [16]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch continue;
        try setShellVar(shell, num_str, arg);
    }

    // execute function body directly from stored AST (no re-parsing!)
    const result = evaluateAst(shell, body) catch |err| {
        // clear positional parameters
        for (args, 1..) |_, i| {
            var num_buf: [16]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch continue;
            _ = shell.variables.fetchRemove(num_str);
        }
        return err;
    };

    // clear positional parameters
    for (args, 1..) |_, i| {
        var num_buf: [16]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch continue;
        if (shell.variables.fetchRemove(num_str)) |kv| {
            shell.allocator.free(kv.key);
            shell.allocator.free(kv.value);
        }
    }

    return result;
}

// helper for echo -e escape sequences
fn writeEscaped(writer: anytype, input: []const u8) !void {
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            const next = input[i + 1];
            switch (next) {
                'n' => {
                    try writer.writeByte('\n');
                    i += 2;
                },
                't' => {
                    try writer.writeByte('\t');
                    i += 2;
                },
                'r' => {
                    try writer.writeByte('\r');
                    i += 2;
                },
                '\\' => {
                    try writer.writeByte('\\');
                    i += 2;
                },
                'a' => {
                    try writer.writeByte(0x07); // bell
                    i += 2;
                },
                'b' => {
                    try writer.writeByte(0x08); // backspace
                    i += 2;
                },
                'e' => {
                    try writer.writeByte(0x1b); // escape
                    i += 2;
                },
                'f' => {
                    try writer.writeByte(0x0c); // form feed
                    i += 2;
                },
                'v' => {
                    try writer.writeByte(0x0b); // vertical tab
                    i += 2;
                },
                '0' => {
                    // octal escape \0nnn
                    var val: u8 = 0;
                    var j: usize = i + 2;
                    var digits: usize = 0;
                    while (j < input.len and digits < 3) {
                        const c = input[j];
                        if (c >= '0' and c <= '7') {
                            val = val * 8 + (c - '0');
                            j += 1;
                            digits += 1;
                        } else break;
                    }
                    try writer.writeByte(val);
                    i = j;
                },
                'x' => {
                    // hex escape \xHH
                    if (i + 3 < input.len) {
                        const hex = input[i + 2 .. i + 4];
                        if (std.fmt.parseInt(u8, hex, 16)) |val| {
                            try writer.writeByte(val);
                            i += 4;
                            continue;
                        } else |_| {}
                    }
                    try writer.writeByte(input[i]);
                    i += 1;
                },
                else => {
                    try writer.writeByte(input[i]);
                    i += 1;
                },
            }
        } else {
            try writer.writeByte(input[i]);
            i += 1;
        }
    }
}

// Buffer-based escape sequence writer - returns bytes written
fn writeEscapedToBuf(input: []const u8, buf: []u8) usize {
    var out_pos: usize = 0;
    var i: usize = 0;

    while (i < input.len and out_pos < buf.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            const next = input[i + 1];
            const c: u8 = switch (next) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '\\' => '\\',
                'a' => 0x07,
                'b' => 0x08,
                'e' => 0x1b,
                'f' => 0x0c,
                'v' => 0x0b,
                '0' => blk: {
                    // octal escape
                    var val: u8 = 0;
                    var j: usize = i + 2;
                    var digits: usize = 0;
                    while (j < input.len and digits < 3) {
                        const ch = input[j];
                        if (ch >= '0' and ch <= '7') {
                            val = val * 8 + (ch - '0');
                            j += 1;
                            digits += 1;
                        } else break;
                    }
                    i = j;
                    break :blk val;
                },
                'x' => blk: {
                    // hex escape
                    if (i + 3 < input.len) {
                        const hex = input[i + 2 .. i + 4];
                        if (std.fmt.parseInt(u8, hex, 16)) |val| {
                            i += 4;
                            break :blk val;
                        } else |_| {}
                    }
                    buf[out_pos] = input[i];
                    out_pos += 1;
                    i += 1;
                    continue;
                },
                else => {
                    buf[out_pos] = input[i];
                    out_pos += 1;
                    i += 1;
                    continue;
                },
            };
            buf[out_pos] = c;
            out_pos += 1;
            if (next != '0' and next != 'x') i += 2;
        } else {
            buf[out_pos] = input[i];
            out_pos += 1;
            i += 1;
        }
    }

    return out_pos;
}
