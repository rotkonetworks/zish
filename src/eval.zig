// eval.zig - AST evaluation for zish
const std = @import("std");
const compat = @import("compat.zig");
const ast = @import("ast.zig");
const glob = @import("glob.zig");
const Shell = @import("Shell.zig");
const parser = @import("parser.zig");
const builtins = @import("builtins.zig");
const jobs = @import("jobs.zig");
const foreground = @import("foreground.zig");

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
        // A 19-digit literal can exceed i64. Report "not a fast integer" and
        // let the caller fall back rather than wrapping: unchecked `* 10` here
        // panicked under safety checks and silently produced a wrong number in
        // ReleaseFast (`$(( 9999999999999999999 ))` evaluated to 0).
        result = std.math.mul(i64, result, 10) catch return null;
        result = std.math.add(i64, result, @as(i64, c - '0')) catch return null;
    }

    return if (negative) -result else result;
}

/// Allocator for a freshly forked child that keeps running shell code.
///
/// A forked child must not keep using the parent's GeneralPurposeAllocator: if
/// another thread (ghost inference) held its lock at fork time, the child would
/// deadlock on the first allocation. But it also cannot simply switch to
/// page_allocator, which was the previous approach — the child inherits a heap
/// full of GPA-owned pointers (PWD, variables, aliases), and the first builtin
/// that frees one, e.g. `( cd / )` reaching setVar, hands a GPA pointer to
/// PageAllocator.free. That panics on "incorrect alignment" in a safety build
/// and corrupts memory in ReleaseFast.
///
/// An arena over page_allocator satisfies both: fresh allocations come straight
/// from mmap and are fork-safe, while free() of an inherited pointer is a
/// harmless no-op (an arena only rewinds its own most recent allocation and
/// ignores foreign ones). Nothing is leaked in practice because every caller
/// exits the process shortly after.
fn forkChildArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.heap.page_allocator);
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
        //
        // A process-substitution child is a background-ish helper, not a
        // foreground job: it stays in the shell's pgroup and never touches
        // the terminal. But sigaction dispositions survive fork AND exec, so
        // without this reset the exec'd /bin/sh inherits the interactive
        // shell's SIG_IGN for INT/QUIT/TSTP and can never be interrupted.
        // No setpgid/tcsetpgrp here, so no SIGTTOU ordering hazard.
        jobs.resetChildSignals();
        var child_arena = forkChildArena();
        shell.allocator = child_arena.allocator();

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
pub fn buildEnvironment(shell: *Shell) ![*:null]const ?[*:0]const u8 {
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

    // Add shell variables — ONLY the exported ones. A plain `x=1` is
    // shell-local and must never enter a child's environment.
    {
        var vit = shell.variables.keyIterator();
        while (vit.next()) |k| {
            if (shell.isExported(k.*)) count += 1;
        }
    }

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

    // Add exported shell variables
    var var_iter = shell.variables.iterator();
    while (var_iter.next()) |kv| {
        const name = kv.key_ptr.*;
        if (!shell.isExported(name)) continue;
        // Build "NAME=value\0" string (leaked - child exits after exec)
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
        .negate => evaluateNegate(shell, node),
        .redirect => evaluateRedirect(shell, node),
        .list => evaluateList(shell, node),
        .assignment => evaluateAssignment(shell, node),
        .if_statement => evaluateIf(shell, node),
        .while_loop => evaluateWhile(shell, node),
        .until_loop => evaluateUntil(shell, node),
        .for_loop => evaluateFor(shell, node),
        .c_for_loop => evaluateCForLoop(shell, node),
        .select_loop => evaluateSelect(shell, node),
        .arith_command => evaluateArithCommand(shell, node),
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
        if (arg_count >= 8) return error.BufferTooSmall; // fall back; don't drop args

        const arg = arg_node.value;

        // expandVariableFast only handles bare `$name`. Anything needing the
        // real expander — `${...}` (braced params; note the parser normalizes a
        // double-quoted "$x" to ${x}, so EVERY quoted variable lands here),
        // command substitution `$(...)`, or a single-quoted literal — must fall
        // through to the full path, or the operand keeps stray bytes and the
        // comparison is wrong (`[ "$x" = ok ]` was reporting not-equal).
        if (arg_node.node_type == .string or
            std.mem.indexOf(u8, arg, "${") != null or
            std.mem.indexOf(u8, arg, "$(") != null or
            std.mem.indexOf(u8, arg, "`") != null)
        {
            return error.BufferTooSmall; // fall through to the full expansion path
        }

        const dest = &arg_buffers[arg_count];

        // Fast variable expansion into stack buffer
        const expanded_len = try expandVariableFast(shell, arg, dest);
        arg_slices[arg_count] = dest[0..expanded_len];
        arg_count += 1;
    }

    // Evaluate test expression with stack-allocated args
    const result = evaluateTestExprFlat(shell, arg_slices[0..arg_count]);
    return if (result) 0 else 1;
}

// Flat positional evaluator for the `test` / `[` builtin (POSIX test).
// Handles the binary -o (OR) / -a (AND) connectives with POSIX precedence
// (-a binds tighter than -o), delegating each primary to the evaluator below.
/// Evaluate a flat `test` argument list: unary and binary operators, `!`
/// negation, and `-a`/`-o` grouping.
///
/// Public because builtins.testCmd delegates here. It used to be a second,
/// less capable implementation of the same thing — see the note there.
pub fn evaluateTestExprFlat(shell: *Shell, args: []const []const u8) bool {
    if (args.len == 0) return false;

    // Split on -o first (lowest precedence); the whole expression is true if any
    // -o-separated AND-group is true.
    var start: usize = 0;
    var idx: usize = 0;
    var any = false;
    while (idx <= args.len) : (idx += 1) {
        if (idx == args.len or std.mem.eql(u8, args[idx], "-o")) {
            if (evaluateTestAndGroup(shell, args[start..idx])) any = true;
            start = idx + 1;
        }
    }
    return any;
}

// One -o group: split on -a; every -a-separated primary must be true.
fn evaluateTestAndGroup(shell: *Shell, args: []const []const u8) bool {
    if (args.len == 0) return false;
    var start: usize = 0;
    var idx: usize = 0;
    var all = true;
    while (idx <= args.len) : (idx += 1) {
        if (idx == args.len or std.mem.eql(u8, args[idx], "-a")) {
            if (!evaluateTestPrimaryFlat(shell, args[start..idx])) all = false;
            start = idx + 1;
        }
    }
    return all;
}

// A single test primary (no -a/-o): `!`-negation, a 3-arg binary comparison, a
// 2-arg unary operator, or a bare string. `=` is a literal string compare here
// (unlike [[ ]], which globs).
fn evaluateTestPrimaryFlat(shell: *Shell, args: []const []const u8) bool {
    if (args.len == 0) return false;

    var i: usize = 0;
    var negate = false;
    while (i < args.len and std.mem.eql(u8, args[i], "!")) {
        negate = !negate;
        i += 1;
    }
    if (i >= args.len) return negate;

    const rest = args[i..];
    var result = false;

    if (rest.len >= 3) {
        const left = rest[0];
        const op = rest[1];
        const right = rest[2];
        if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) {
            result = std.mem.eql(u8, left, right);
        } else if (std.mem.eql(u8, op, "!=")) {
            result = !std.mem.eql(u8, left, right);
        } else if (std.mem.eql(u8, op, "-eq") or std.mem.eql(u8, op, "-ne") or
            std.mem.eql(u8, op, "-lt") or std.mem.eql(u8, op, "-gt") or
            std.mem.eql(u8, op, "-le") or std.mem.eql(u8, op, "-ge"))
        {
            const l = fastParseI64(left);
            const r = fastParseI64(right);
            if (l != null and r != null) {
                const lv = l.?;
                const rv = r.?;
                result = if (std.mem.eql(u8, op, "-eq")) lv == rv else if (std.mem.eql(u8, op, "-ne")) lv != rv else if (std.mem.eql(u8, op, "-lt")) lv < rv else if (std.mem.eql(u8, op, "-gt")) lv > rv else if (std.mem.eql(u8, op, "-le")) lv <= rv else lv >= rv;
            }
        } else if (std.mem.eql(u8, op, "-nt") or std.mem.eql(u8, op, "-ot") or std.mem.eql(u8, op, "-ef")) {
            result = fileCompare(op, left, right);
        }
        return if (negate) !result else result;
    }

    if (rest[0].len == 2 and rest[0][0] == '-' and rest.len >= 2) {
        result = evaluateUnaryTest(shell, rest[0][1], rest[1]);
        return if (negate) !result else result;
    }

    result = rest[0].len > 0;
    return if (negate) !result else result;
}

// Field-splitting delimiters ($IFS). An unset $IFS means the default
// whitespace set; an explicitly empty $IFS yields "", and tokenizeAny with an
// empty delimiter set returns the input as a single field (no splitting) —
// which is exactly the POSIX behavior for IFS="".
fn ifsDelimiters(shell: *Shell) []const u8 {
    return shell.variables.get("IFS") orelse " \t\n";
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
    // Escaped-literal sentinels need translating; defer to the full expander.
    if (std.mem.indexOfScalar(u8, input, Shell.LIT_DOLLAR) != null or
        std.mem.indexOfScalar(u8, input, Shell.LIT_BACKTICK) != null)
    {
        return error.BufferTooSmall;
    }
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

            // Handle $$ (shell PID — /tmp/foo.$$ temp files)
            if (input[i] == '$') {
                const s = std.fmt.bufPrint(dest[out_pos..], "{d}", .{compat.posix.getpid()}) catch break;
                out_pos += s.len;
                i += 1;
                continue;
            }

            // Handle $! (PID of the most recent background command)
            if (input[i] == '!') {
                if (shell.last_bg_pid != 0) {
                    const s = std.fmt.bufPrint(dest[out_pos..], "{d}", .{shell.last_bg_pid}) catch break;
                    out_pos += s.len;
                }
                i += 1;
                continue;
            }

            // Handle $# (positional parameter count)
            if (input[i] == '#') {
                const c = shell.variables.get("#") orelse "0";
                if (out_pos + c.len > 256) return error.BufferTooSmall;
                @memcpy(dest[out_pos..][0..c.len], c);
                out_pos += c.len;
                i += 1;
                continue;
            }

            // $@ / $* join all positionals — needs the full (allocating) expander
            if (input[i] == '@' or input[i] == '*') {
                return error.BufferTooSmall;
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
        if (arg_count >= 16) return error.BufferTooSmall; // fall back; don't drop args

        const arg = arg_node.value;
        const dest = &arg_buffers[arg_count];

        // For string nodes (single-quoted), no expansion needed
        if (arg_node.node_type == .string) {
            if (arg.len > dest.len) return error.BufferTooSmall; // don't truncate
            @memcpy(dest[0..arg.len], arg);
            arg_slices[arg_count] = dest[0..arg.len];
        } else {
            const expanded_len = try expandVariableFast(shell, arg, dest);
            // An unquoted $var that expands to nothing produces no field at all
            // (POSIX), so `echo before $empty after` prints one space, not two.
            // A quoted "" or a literal empty word still counts as a field.
            if (expanded_len == 0 and arg_node.node_type != .double_quoted and
                std.mem.indexOfScalar(u8, arg, '$') != null)
            {
                continue;
            }
            arg_slices[arg_count] = dest[0..expanded_len];
        }
        arg_count += 1;
    }

    // Output - batch into single buffer to minimize syscalls
    // SectorLambda-inspired: single write() is faster than multiple
    var out_buf: [4096]u8 = undefined;
    var out_pos: usize = 0;

    var escape_stopped = false; // \c suppresses everything after it
    for (arg_slices[0..arg_count], 0..) |arg, i| {
        if (i > 0) {
            if (out_pos >= out_buf.len) return error.BufferTooSmall; // fall back
            out_buf[out_pos] = ' ';
            out_pos += 1;
        }
        if (interpret_escapes) {
            const w = writeEscapedToBuf(arg, out_buf[out_pos..]);
            out_pos += w.len;
            if (w.stopped) {
                escape_stopped = true;
                break;
            }
            // writeEscapedToBuf caps at the slice it was given; a full buffer
            // means we may have truncated — fall back rather than emit a short line.
            if (out_pos >= out_buf.len and !w.stopped) return error.BufferTooSmall;
        } else {
            if (arg.len > out_buf.len - out_pos) return error.BufferTooSmall; // don't truncate
            @memcpy(out_buf[out_pos..][0..arg.len], arg);
            out_pos += arg.len;
        }
    }
    if (print_newline and !escape_stopped) {
        if (out_pos >= out_buf.len) return error.BufferTooSmall; // no room for '\n'
        out_buf[out_pos] = '\n';
        out_pos += 1;
    }

    // Single write syscall
    try shell.stdout().writeAll(out_buf[0..out_pos]);

    return 0;
}

// TtyCtl (the controlling-terminal handle) moved to foreground.zig — the
// single owner of foreground job-control discipline.

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
    // Prefix assignments (`FOO=1 cmd`) are exported to the command's environment
    // but only for its duration; track which were already exported so cleanup
    // removes only the marks we added.
    var prefix_was_exported: [16]bool = undefined;
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
        // Export for the command (bash: `FOO=1 cmd` puts FOO in cmd's env).
        prefix_was_exported[i] = shell.isExported(name);
        if (!prefix_was_exported[i]) shell.markExported(name) catch {};
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
            // Undo a temporary export (leave pre-existing exports alone).
            if (!prefix_was_exported[i]) {
                if (shell.exported.fetchRemove(prefix_names[i])) |kv| shell.allocator.free(kv.key);
            }
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
        if (std.mem.eql(u8, raw_cmd, "continue")) {
            shell.loop_continue = 1;
            return 253;
        }
        if (std.mem.eql(u8, raw_cmd, "break")) {
            shell.loop_break = 1;
            return 254;
        }
    }
    // break N / continue N: break out of N enclosing loops
    if ((std.mem.eql(u8, raw_cmd, "break") or std.mem.eql(u8, raw_cmd, "continue")) and cmd_children.len == 2) {
        const n = std.fmt.parseInt(u32, cmd_children[1].value, 10) catch 1;
        const level = if (n == 0) 1 else n;
        if (raw_cmd[0] == 'b') {
            shell.loop_break = level;
            return 254;
        } else {
            shell.loop_continue = level;
            return 253;
        }
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
        // A custom $IFS changes how unquoted $var expansions split into fields;
        // the fast path only handles the default whitespace set, so defer any
        // arg containing an expansion to the full path when IFS is set.
        const ifs_custom = shell.variables.get("IFS") != null;
        for (cmd_children[1..]) |arg_node| {
            const arg = arg_node.value;
            if (ifs_custom and arg_node.node_type != .string and
                std.mem.indexOfScalar(u8, arg, '$') != null)
            {
                needs_full_expansion = true;
                break;
            }
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
            // Special params $#, $@, $* and any braced expansion (incl. ${10}, ${@})
            // are not handled by the fast path.
            if (std.mem.indexOf(u8, arg, "${") != null) {
                needs_full_expansion = true;
                break;
            }
            if (std.mem.indexOfScalar(u8, arg, '$')) |dp| {
                if (dp + 1 < arg.len and (arg[dp + 1] == '#' or arg[dp + 1] == '@' or arg[dp + 1] == '*')) {
                    needs_full_expansion = true;
                    break;
                }
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
                    // Any operator inside ${...} requires the full expansion path:
                    // # % / : [ (substr/strip/subst/array), - + ? = (default/alt/assign/error),
                    // ^ , (case modification).
                    if (c == '#' or c == '%' or c == '/' or c == ':' or c == '[' or
                        c == '-' or c == '+' or c == '?' or c == '=' or
                        c == '^' or c == ',')
                    {
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
    var cmd_name = cmd_name_result.slice;
    // set when `command NAME ...` strips its prefix: NAME then resolves as an
    // external command with functions/aliases bypassed (command's whole point).
    var skip_functions = false;

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

    // Scratch list reused per argument by the shared expansion pipeline.
    var fields: std.ArrayList([]const u8) = .empty;
    defer {
        for (fields.items) |f| shell.allocator.free(f);
        fields.deinit(shell.allocator);
    }

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
            // "$@" is special: one field per positional parameter (not joined).
            if (isQuotedAtParam(arg)) {
                const count = positionalCount(shell);
                var i: usize = 1;
                while (i <= count) : (i += 1) {
                    var nb: [16]u8 = undefined;
                    const ns = std.fmt.bufPrint(&nb, "{d}", .{i}) catch break;
                    const v = shell.variables.get(ns) orelse "";
                    try expanded_args.append(shell.allocator, try shell.allocator.dupeZ(u8, v));
                }
                continue;
            }
            // "${a[@]}" is likewise one field per array element.
            if (quotedArrayAll(arg)) |arr_name| {
                try appendQuotedArrayFields(shell, arr_name, &expanded_args);
                continue;
            }
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

        // Shared brace → var → IFS-split → glob pipeline. This caller's only
        // specific need is NUL-terminated dupes for execvpeZ.
        for (fields.items) |f| shell.allocator.free(f);
        fields.clearRetainingCapacity();
        try expandUnquotedWordInto(shell, arg, &fields);
        for (fields.items) |field| {
            try expanded_args.append(shell.allocator, try shell.allocator.dupeZ(u8, field));
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
    if (builtins.dispatch(shell, cmd_name, expanded_args.items)) |maybe_result| {
        if (maybe_result) |result| return result;
    } else |err| switch (err) {
        // `command NAME args`: NAME is external. Strip the "command" prefix and
        // resolve NAME as an external command below, with functions/aliases
        // bypassed (so `ls() { command ls; }` doesn't recurse).
        error.RunAsCommand => {
            if (expanded_args.items.len >= 2) {
                shell.allocator.free(expanded_args.items[0]);
                _ = expanded_args.orderedRemove(0);
                cmd_name = expanded_args.items[0];
                skip_functions = true;
            } else return 0;
        },
        else => return err,
    }

    if (std.mem.eql(u8, cmd_name, "feat"))
        return try featCmd(shell, expanded_args.items);

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

    // check if it's a function call (skipped after a `command` prefix)
    if (!skip_functions and shell.functions.get(cmd_name) != null) {
        // call function with remaining arguments
        return callFunction(shell, cmd_name, expanded_args.items[1..]) catch |err| {
            if (err == error.FunctionNotFound) {
                // shouldn't happen since we just checked, but handle anyway
            }
            return 1;
        };
    }

    // Feats resolve as plain commands: `calc 2+2`, not `feat run calc 2+2`.
    //
    // This is a *fallback*, deliberately placed after builtins, functions and
    // (below) PATH: a feat must never shadow something the system already
    // provides, or installing one silently changes what an existing script
    // means. It only fires where the alternative was "command not found".
    //
    // `feat run <name>` still works and stays the explicit form; this just
    // removes the ceremony from the common case. A feat nobody can remember
    // how to invoke is a feat nobody uses.
    if (shell.lookupCommand(cmd_name) == null) {
        if (featResolve(shell.allocator, cmd_name)) |f| {
            defer shell.allocator.free(f.bin);
            // Same rule as `feat run`: untrusted extra feats never run as root.
            // Reached by a different path, so the check has to be repeated here
            // rather than assumed.
            if (f.tier == .extra and compat.posix.geteuid() == 0) {
                try shell.stdout().writeAll("feat: refusing to run extra feat as root\n");
                return 126;
            }
            return try featExec(shell, f.tier, f.bin, expanded_args.items[1..]);
        }
    }

    // external command
    // Foreground job-control discipline (terminal handover, pgroups, signal
    // reset, UNTRACED wait) is owned by foreground.Session — this is the
    // reference call site the abstraction was extracted from. See
    // foreground.zig for the full dance and why each step is ordered.
    var fg_session = foreground.Session.begin(shell);
    defer fg_session.end();

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

    // This forked child was created to run exactly this node and nothing else,
    // so exec in place instead of forking again. Any other node still has body
    // left to run after it and must take the fork path below.
    if (shell.exec_in_place_node == node) {
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
        // child: own pgroup + terminal, then default signals — the ordered
        // dance lives in Session.setupChild. This lets TUI apps work and
        // makes the exec'd program Ctrl+C/Ctrl+Z-able.
        fg_session.setupChild();

        // Build environment in child process (after fork, safe from parent interference)
        const envp = buildEnvironment(shell) catch @as([*:null]const ?[*:0]const u8, @ptrCast(std.c.environ));
        compat.posix.execvpeZ(argv[0].?, argv, envp) catch {
            compat.posix.exit(127);
        };
    }

    // parent: also set child's pgrp (race avoidance)
    fg_session.registerChild(pid);

    // Display string in case the child is Ctrl+Z'd and becomes a stopped job.
    var cmd_buf: [512]u8 = undefined;
    const cmd_display = joinArgs(&cmd_buf, expanded_args.items);

    // SIGINT-ignore + waitpid(UNTRACED) + status decode + stopped-job
    // registration + terminal reclaim, all in one owner.
    const out = fg_session.reap(pid, cmd_display, null);
    if (out.exited and out.code == 127) {
        try shell.stdout().print("zish: {s}: command not found\n", .{cmd_name});
        suggestCommand(shell, cmd_name);
    }
    return out.code;
}

// Join argv into a display string for job registration (space-separated,
// truncated to the buffer).
fn joinArgs(buf: []u8, args: []const [:0]const u8) []const u8 {
    var len: usize = 0;
    for (args, 0..) |a, i| {
        if (i > 0 and len < buf.len) {
            buf[len] = ' ';
            len += 1;
        }
        const n = @min(a.len, buf.len - len);
        @memcpy(buf[len .. len + n], a[0..n]);
        len += n;
        if (len >= buf.len) break;
    }
    return buf[0..len];
}

// Register a foreground pipeline that was just stopped by Ctrl+Z as a stopped
// job (all stages), mirroring addStoppedForeground for the single-command path.
fn registerStoppedPipeline(
    shell: *Shell,
    node: *const ast.AstNode,
    pids: []const compat.posix.pid_t,
    stopped: []const bool,
    statuses: []const u32,
) void {
    var cmd_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer cmd_buf.deinit(shell.allocator);
    serializeAst(shell.allocator, &cmd_buf, node) catch {};
    const cmd: []const u8 = if (cmd_buf.items.len > 0) cmd_buf.items else "pipeline";

    // foreground=false, like addStoppedForeground: getPendingNotifications
    // skips foreground jobs, so foreground=true would silence every future
    // notification for this job.
    const job_id = shell.job_table.addPipelineJob(pids, pids[0], cmd, false) catch return;
    if (shell.job_table.getJob(job_id)) |job| {
        job.state = .stopped;
        job.notified = true; // we print our own Stopped notice below
        job.tmodes = compat.posix.tcgetattr(shell.job_table.shell_terminal) catch null;
        for (job.processes.items, 0..) |*proc, i| {
            if (i < statuses.len) proc.status = statuses[i];
            if (i < stopped.len and !stopped[i]) {
                // this stage had already exited before the stop
                proc.completed = true;
                proc.stopped = false;
            } else {
                proc.stopped = true;
                proc.completed = false;
            }
        }
    }
    shell.stdout().print("\n[{d}]+  Stopped\t\t{s}\n", .{ job_id, cmd }) catch {};
    shell.stdout().flush() catch {};
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

    // AST node values (and lookupCommand results) are plain []const u8 — NOT
    // null-terminated. Passing their .ptr straight to execvpeZ reads past the
    // slice into whatever bytes follow in memory, so argv[0] becomes e.g.
    // "/tmp/x.sh\4&\220" and exec fails with 127. Whether the trailing byte
    // happens to be \0 depends on adjacent memory (what the previous pipeline
    // stage left behind), which is why the failure looked left-command
    // dependent. Copy every argument into a local buffer with a real \0.
    var str_buf: [16384]u8 = undefined;
    var str_pos: usize = 0;
    const addZ = struct {
        fn f(buf: []u8, pos: *usize, s: []const u8) ?[*:0]const u8 {
            if (pos.* + s.len + 1 > buf.len) return null;
            @memcpy(buf[pos.*..][0..s.len], s);
            buf[pos.* + s.len] = 0;
            const p: [*:0]const u8 = @ptrCast(buf[pos.*..].ptr);
            pos.* += s.len + 1;
            return p;
        }
    }.f;

    // First arg might need path lookup
    const cmd_name = node.children[0].value;
    const path = if (shell.lookupCommand(cmd_name)) |full_path| full_path else cmd_name;
    argv_buf[0] = addZ(&str_buf, &str_pos, path) orelse compat.posix.exit(127);
    arg_count = 1;

    // Rest of args as-is
    for (node.children[1..]) |child| {
        if (arg_count >= 255) break;
        argv_buf[arg_count] = addZ(&str_buf, &str_pos, child.value) orelse break;
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

    // Job control for pipelines: in the interactive shell, a foreground
    // pipeline must run in its OWN process group with control of the terminal
    // (like the single-command path already does). Without this, the piped
    // program shares the shell's process group and the interactive line
    // editor keeps the tty — so a script run via `curl ... | bash` can't read
    // the controlling tty (/dev/tty) for prompts like "[Y/n]".
    //
    // A background job / command substitution runs this function inside a
    // forked subshell with shell.forked_child already true — skip the handoff
    // there so it doesn't steal the terminal from the parent shell.
    // The controlling tty, not stdin: stdin may be redirected (heredoc,
    // a redirected function call) while a stage still prompts on /dev/tty.
    // The multi-pid variant of the foreground discipline: leader pgid, every
    // stage in the leader's pgroup, reap-all with UNTRACED. Session owns the
    // terminal handover; the reap loop stays here (per-stage $PIPESTATUS /
    // pipefail bookkeeping). reclaim + end run from defers so the terminal
    // comes back on the error path too.
    var fg_session = foreground.Session.begin(shell);
    defer fg_session.end();
    defer fg_session.reclaim();

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
            // Child: join the pipeline's process group (first stage is the
            // leader), then default signal dispositions — the ordered dance
            // lives in Session.setupPipelineStage. Applies both to exec'd
            // programs (dispositions survive exec) and to stages that stay
            // in-process (builtins), so Ctrl+C/Ctrl+Z reach the whole
            // foreground pipeline group.
            fg_session.setupPipelineStage(if (i == 0) 0 else pids[0]);
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

            // Fast path: simple external command - exec directly without evaluateAst.
            // Skip it when the first child is a prefix assignment (`FOO=1 cmd`):
            // that path would exec the assignment as the command AND drop the
            // variable from the child's environment. Fall through to evaluateCommand.
            if (child.node_type == .command and child.children.len > 0 and
                child.children[0].node_type != .assignment)
            {
                const cmd_name = child.children[0].value;
                // Check if it's a simple external command (not a builtin, no
                // special chars) that actually exists in PATH.
                //
                // The PATH check matters: this fast path execs directly and
                // never returns, so a name that is not a real binary — a feat
                // like `calc` — would exec-fail with 127 instead of falling
                // through to the feat resolution in evaluateCommand. That is
                // why `calc 3/2` worked but `echo 1+1 | calc` did not.
                if (!isBuiltin(cmd_name) and !needsExpansion(child) and
                    shell.lookupCommand(cmd_name) != null)
                {
                    execSimpleCommand(shell, child);
                    // execSimpleCommand doesn't return on success
                }
            }

            // Full path for builtins, complex commands, etc. This stage exists
            // to run `child` and nothing else, so `child` — and only `child` —
            // may exec in place.
            shell.forked_child = true;
            shell.exec_in_place_node = child;
            const status = evaluateAst(shell, child) catch 127;
            shell.stdout().flush() catch {};
            std.process.exit(status);
        } else {
            pids[i] = pid;
            // Parent: assign the child to the pipeline's group (both sides
            // call setpgid for race avoidance, as in the single-command path);
            // the foreground leader also gets the terminal.
            fg_session.registerPipelineStage(pid, if (i == 0) 0 else pids[0]);
        }
    }

    for (pipes) |pipe_fds| {
        compat.posix.close(pipe_fds[0]);
        compat.posix.close(pipe_fds[1]);
    }

    // ignore SIGINT in shell while waiting for pipeline (children will receive it)
    var sigint_guard = foreground.SigintGuard.begin();
    defer sigint_guard.end();

    var last_status: u8 = 0;
    var pipefail_status: u8 = 0; // first non-zero status for pipefail

    // Per-stage statuses for $PIPESTATUS (capped; longer pipelines are rare).
    var pstat_bufs: [16][4]u8 = undefined;
    var pstat_vals: [16][]const u8 = undefined;

    // Per-stage stopped flags + raw statuses, so a Ctrl+Z'd pipeline can be
    // registered as a stopped job with accurate per-process state.
    var stage_stopped: [8]bool = @splat(false);
    var stage_status: [8]u32 = @splat(0);
    var any_stopped = false;

    for (pids, 0..) |pid, idx| {
        // UNTRACED: without it a Ctrl+Z'd stage is never noticed and the
        // shell blocks here forever (same fix as the single-command path).
        const result = compat.posix.waitpid(pid, compat.posix.W.UNTRACED);
        if (idx < stage_status.len) stage_status[idx] = result.status;
        var status: u8 = 0;
        if (compat.posix.W.IFSTOPPED(result.status)) {
            // Stage stopped (Ctrl+Z hits the whole foreground group). Keep
            // reaping the remaining stages with UNTRACED — each either exits
            // or stops too — then register the pipeline as a stopped job
            // below. bash behaves the same way.
            any_stopped = true;
            if (idx < stage_stopped.len) stage_stopped[idx] = true;
            status = 148; // 128 + SIGTSTP(20)
        } else if (compat.posix.W.IFEXITED(result.status)) {
            status = compat.posix.W.EXITSTATUS(result.status);
        } else if (compat.posix.W.IFSIGNALED(result.status)) {
            status = @truncate(128 + @as(u32, @intCast(@intFromEnum(compat.posix.W.TERMSIG(result.status)))));
        } else {
            status = 127;
        }
        last_status = status;
        if (idx < pstat_vals.len) {
            pstat_vals[idx] = std.fmt.bufPrint(&pstat_bufs[idx], "{d}", .{status}) catch "0";
        }
        // pipefail: remember first non-zero status
        if (shell.opt_pipefail and status != 0 and pipefail_status == 0) {
            pipefail_status = status;
        }
    }

    // Some stage was stopped by Ctrl+Z: register the whole pipeline as a
    // stopped job so it can be resumed with fg/bg, print the notice, and
    // return 148 (128+SIGTSTP) like bash. The foreground defer above reclaims
    // the terminal and restores the editor's raw mode on return.
    if (any_stopped) {
        registerStoppedPipeline(shell, node, pids, stage_stopped[0..], stage_status[0..]);
        return 148;
    }

    // Expose the per-stage exit statuses as $PIPESTATUS.
    shell.setArray("PIPESTATUS", pstat_vals[0..@min(pids.len, pstat_vals.len)]) catch {};

    // pipefail: return first non-zero status if any command failed
    return if (shell.opt_pipefail and pipefail_status != 0) pipefail_status else last_status;
}

pub fn evaluateNegate(shell: *Shell, node: *const ast.AstNode) !u8 {
    if (node.children.len != 1) return 1;
    const status = try evaluateAst(shell, node.children[0]);
    // control-flow sentinels (break/continue) must pass through untouched
    if (status == 253 or status == 254) return status;
    return if (status == 0) 1 else 0;
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

    // Redirect nodes nest with the LAST parsed (rightmost in source) redirect as
    // the outermost node. To match bash, redirects must be applied strictly
    // left-to-right, so unwind the chain and apply from innermost to outermost.
    var chain: [16]*const ast.AstNode = undefined;
    var n: usize = 0;
    var cur = node;
    while (cur.node_type == .redirect and cur.children.len == 2 and n < chain.len) {
        chain[n] = cur;
        n += 1;
        cur = cur.children[0];
    }
    const command = cur; // the actual command at the bottom of the chain

    // Flush any buffered stdout to the real terminal before swapping fds, so
    // pre-redirect output isn't diverted into the redirect target.
    shell.stdout().flush() catch {};

    // Lazily back up every fd a redirect touches (0-9, saved at >=10 with
    // CLOEXEC) and restore them all afterwards. See FdSaver for why the
    // backups must live outside the user-addressable fd range.
    var saver: FdSaver = .{};
    defer {
        // Builtins write through a buffered writer on fd 1; flush it into the
        // redirect target before restoring the original fds.
        shell.stdout().flush() catch {};
        saver.restoreAll();
    }

    // apply in source order (innermost redirect node = leftmost in source)
    var idx = n;
    while (idx > 0) {
        idx -= 1;
        // A failed redirect (bad fd like `>&9`, unwritable target, …) fails the
        // COMMAND with exit 1 and a diagnostic — it must not abort the whole
        // shell/script. The defer above restores any fds already swapped.
        applyRedirect(shell, chain[idx], &saver) catch |err| {
            shell.stderr().print("zish: {s}\n", .{redirectErrorText(err)}) catch {};
            return 1;
        };
    }

    return evaluateAst(shell, command);
}

fn redirectErrorText(err: anyerror) []const u8 {
    return switch (err) {
        error.BadFileDescriptor => "bad file descriptor",
        error.AccessDenied => "permission denied",
        error.FileNotFound => "no such file or directory",
        error.IsDir => "is a directory",
        else => "redirection error",
    };
}

/// Backs up the shell's fds around a command's redirections so they can be
/// restored afterwards.
///
/// Backups are parked at fd >= 10 with close-on-exec (same pattern as the
/// trace channel in trace.zig). Plain `dup()` backups landed at the lowest
/// free fds — 3, 4, 5 — where a user redirect like `3>file` would clobber
/// them via `dup2(file, 3)`: after "restore", the shell's own stdin was the
/// redirect target for the rest of the session. High CLOEXEC backups can
/// never collide with user redirects (which only address fds 0-9) and never
/// leak into children across exec.
///
/// Saving is lazy and covers every fd a redirect touches, so fds > 2 opened
/// by `3>file` are also restored (closed again) after the command instead of
/// persisting in the shell and leaking into every later child.
const FdSaver = struct {
    const not_saved: i32 = -2;
    const was_closed: i32 = -1;

    saved: [10]i32 = @splat(not_saved),

    /// Record the current state of `fd` before a redirect modifies it.
    /// Call before any dup2-onto-fd or close(fd) in the redirect path.
    fn save(self: *FdSaver, fd: i32) void {
        if (fd < 0 or fd >= self.saved.len) return;
        const i: usize = @intCast(fd);
        if (self.saved[i] != not_saved) return;
        // fcntl in compat treats EBADF as unreachable, so probe first: a
        // closed fd is legitimate here (`3>file` when 3 was never open).
        _ = compat.posix.fstat(fd) catch |err| {
            if (err == error.BadFileDescriptor) self.saved[i] = was_closed;
            // Other fstat failures: leave not_saved. Restoring nothing (a
            // leaked fd) is safer than closing a live fd we never backed up.
            return;
        };
        self.saved[i] = compat.posix.dupHighCloexec(fd) catch return;
    }

    /// Restore every saved fd to its pre-redirect state and release the
    /// backups. Runs on every exit path (defer in evaluateRedirect).
    fn restoreAll(self: *FdSaver) void {
        for (&self.saved, 0..) |*bak, i| {
            const fd: i32 = @intCast(i);
            if (bak.* == not_saved) continue;
            if (bak.* == was_closed) {
                // fd was closed before the redirects; close it again — but
                // only if a redirect actually (re)opened it, since close()
                // on a bad fd is unreachable in compat.
                if (compat.posix.fstat(fd)) |_| {
                    compat.posix.close(fd);
                } else |_| {}
            } else {
                compat.posix.dup2(bak.*, fd) catch {};
                compat.posix.close(bak.*);
            }
            bak.* = not_saved;
        }
    }
};

// Classify an input-redirect target that is one of our internal heredoc temp
// files. Returns null for ordinary files, true if the body needs expansion
// (unquoted delimiter), false if it must be fed literally (quoted delimiter).
fn heredocTempMode(path: []const u8) ?bool {
    const prefix = "/tmp/zish_heredoc_";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    if (path.len <= prefix.len) return null;
    return switch (path[prefix.len]) {
        'e' => true,
        'q' => false,
        else => null,
    };
}

// Feed a heredoc temp file to stdin. For an unquoted delimiter the body is
// expanded now (execution time) and written to a short-lived sibling temp file,
// which is then dup2'd onto stdin. The original raw file is left in place so a
// heredoc inside a loop re-expands with each iteration's values.
fn applyHeredocInput(shell: *Shell, path: []const u8, expand: bool) !void {
    if (!expand) {
        const file = try std.Io.Dir.cwd().openFile(compat.io(), path, .{ .mode = .read_only });
        defer file.close(compat.io());
        try compat.posix.dup2(file.handle, compat.posix.STDIN_FILENO);
        return;
    }

    const raw = std.Io.Dir.cwd().readFileAlloc(compat.io(), path, shell.allocator, .limited(16 * 1024 * 1024)) catch {
        // On read failure, fall back to feeding the file unexpanded.
        const file = try std.Io.Dir.cwd().openFile(compat.io(), path, .{ .mode = .read_only });
        defer file.close(compat.io());
        try compat.posix.dup2(file.handle, compat.posix.STDIN_FILENO);
        return;
    };
    defer shell.allocator.free(raw);

    const exp = try shell.expandVariables(raw);
    defer shell.allocator.free(exp);

    // Materialise the expanded body into a sibling temp file (avoids pipe-buffer
    // deadlock for large bodies, since redirects are applied in the parent before
    // the reader process is forked).
    // Sibling temp file for the expanded body. `path` already carries the
    // random suffix from preprocessHeredoc, so appending here keeps it
    // unguessable; `.exclusive` (O_EXCL) makes the create fail closed rather
    // than follow a planted symlink or clobber a pre-existing file.
    var rnd: [8]u8 = undefined;
    compat.posix.randomBytes(&rnd);
    var name_buf: [160]u8 = undefined;
    const exp_path = std.fmt.bufPrint(&name_buf, "{s}_x{s}", .{ path, std.fmt.bytesToHex(rnd, .lower) }) catch return error.OutOfMemory;

    {
        // 0600: the expanded body holds substituted variable values (possibly
        // secrets); a co-tenant UID must not read it from /tmp.
        const wf = try std.Io.Dir.cwd().createFile(compat.io(), exp_path, .{ .truncate = true, .exclusive = true, .permissions = .fromMode(0o600) });
        defer wf.close(compat.io());
        compat.writeAll(wf, exp) catch {};
    }
    const file = try std.Io.Dir.cwd().openFile(compat.io(), exp_path, .{ .mode = .read_only });
    // Both cleanups must be defers: a failing dup2 previously skipped them,
    // leaking the descriptor and leaving the temp file behind on every error.
    defer std.Io.Dir.deleteFileAbsolute(compat.io(), exp_path) catch {};
    defer file.close(compat.io());
    try compat.posix.dup2(file.handle, compat.posix.STDIN_FILENO);
}

/// Open `target` for a single-fd redirect and dup2 it onto `fd`, saving the
/// original `fd` first. Covers the common "open/create -> defer close ->
/// save -> dup2" shape shared by >, >>, <, 2>, 2>>, and the numbered n>/n>>/n<
/// forms. Redirects that dup2 the same open file onto two fds at once (&>,
/// &>>, >&file) are NOT routed through this helper: opening the target twice
/// would give stdout and stderr independent file offsets instead of the
/// shared one a single open+dup2-twice produces, which is observable for
/// interleaved writes in append mode.
fn redirectFdTo(shell: *Shell, fd: i32, target: []const u8, mode: enum { trunc, append, read }, saver: *FdSaver) !void {
    _ = shell;
    const file = switch (mode) {
        .trunc => try std.Io.Dir.cwd().createFile(compat.io(), target, .{ .truncate = true }),
        .append => try std.Io.Dir.cwd().createFile(compat.io(), target, .{ .truncate = false }),
        .read => try std.Io.Dir.cwd().openFile(compat.io(), target, .{ .mode = .read_only }),
    };
    defer file.close(compat.io());
    if (mode == .append) {
        _ = compat.posix.lseek(file.handle, 0, 2) catch return error.Unseekable; // SEEK_END
    }
    saver.save(fd);
    try compat.posix.dup2(file.handle, fd);
}

fn applyRedirect(shell: *Shell, node: *const ast.AstNode, saver: *FdSaver) !void {
    const target = node.children[1];
    const redirect_type = node.value;

    const expanded_target = if (target.node_type == .string)
        try shell.allocator.dupe(u8, target.value)
    else
        try shell.expandVariables(target.value);
    defer shell.allocator.free(expanded_target);

    if (std.mem.eql(u8, redirect_type, ">") or std.mem.eql(u8, redirect_type, ">|")) {
        try redirectFdTo(shell, compat.posix.STDOUT_FILENO, expanded_target, .trunc, saver);
    } else if (std.mem.eql(u8, redirect_type, ">>")) {
        // create file if doesn't exist, don't truncate if exists
        try redirectFdTo(shell, compat.posix.STDOUT_FILENO, expanded_target, .append, saver);
    } else if (std.mem.eql(u8, redirect_type, "<")) {
        saver.save(compat.posix.STDIN_FILENO);
        // Heredoc bodies are materialised (by preprocessHeredoc) into temp files
        // tagged "_e_" (expand) or "_q_" (literal). Unquoted-delimiter bodies are
        // expanded HERE, at execution time, so they see assignments made earlier on
        // the same line and the current loop iteration's values.
        if (heredocTempMode(expanded_target)) |expand| {
            try applyHeredocInput(shell, expanded_target, expand);
        } else {
            try redirectFdTo(shell, compat.posix.STDIN_FILENO, expanded_target, .read, saver);
        }
    } else if (std.mem.eql(u8, redirect_type, "2>")) {
        try redirectFdTo(shell, compat.posix.STDERR_FILENO, expanded_target, .trunc, saver);
    } else if (std.mem.eql(u8, redirect_type, "2>>")) {
        try redirectFdTo(shell, compat.posix.STDERR_FILENO, expanded_target, .append, saver);
    } else if (std.mem.eql(u8, redirect_type, "2>&1")) {
        saver.save(compat.posix.STDERR_FILENO);
        try compat.posix.dup2(compat.posix.STDOUT_FILENO, compat.posix.STDERR_FILENO);
    } else if (std.mem.eql(u8, redirect_type, ">&2")) {
        saver.save(compat.posix.STDOUT_FILENO);
        try compat.posix.dup2(compat.posix.STDERR_FILENO, compat.posix.STDOUT_FILENO);
    } else if (std.mem.eql(u8, redirect_type, "&>")) {
        const file = try std.Io.Dir.cwd().createFile(compat.io(), expanded_target, .{ .truncate = true });
        defer file.close(compat.io());
        saver.save(compat.posix.STDOUT_FILENO);
        saver.save(compat.posix.STDERR_FILENO);
        try compat.posix.dup2(file.handle, compat.posix.STDOUT_FILENO);
        try compat.posix.dup2(file.handle, compat.posix.STDERR_FILENO);
    } else if (std.mem.eql(u8, redirect_type, "&>>")) {
        const file = try std.Io.Dir.cwd().createFile(compat.io(), expanded_target, .{ .truncate = false });
        defer file.close(compat.io());
        _ = compat.posix.lseek(file.handle, 0, 2) catch return error.Unseekable; // SEEK_END
        saver.save(compat.posix.STDOUT_FILENO);
        saver.save(compat.posix.STDERR_FILENO);
        try compat.posix.dup2(file.handle, compat.posix.STDOUT_FILENO);
        try compat.posix.dup2(file.handle, compat.posix.STDERR_FILENO);
    } else if (std.mem.eql(u8, redirect_type, "<<<")) {
        saver.save(compat.posix.STDIN_FILENO);
        // Here string, materialised into a temp file rather than a pipe.
        //
        // The pipe version deadlocked: redirects are applied in the parent
        // before the reading process is forked, so nothing drains the pipe
        // while we write. Any here-string larger than the pipe buffer (~64 KiB)
        // blocked the shell forever — `cmd <<< "$(...200k...)"` simply hung.
        // It also leaked the write end whenever that write failed. The heredoc
        // path above already uses a temp file for exactly this reason.
        //
        // The file is unlinked immediately after opening, so the open fd keeps
        // it alive and there is nothing left to clean up on any exit path.
        const content_with_newline = try std.fmt.allocPrint(shell.allocator, "{s}\n", .{expanded_target});
        defer shell.allocator.free(content_with_newline);

        // Unguessable name + O_EXCL, for the same reason as the heredoc path:
        // a predictable /tmp name opened without O_EXCL is an arbitrary-file
        // overwrite via a pre-planted symlink.
        var rnd: [8]u8 = undefined;
        var name_buf: [64]u8 = undefined;
        var wf: std.Io.File = undefined;
        var attempt: u8 = 0;
        const tmp_path = while (true) {
            compat.posix.randomBytes(&rnd);
            const p = std.fmt.bufPrint(&name_buf, "/tmp/zish_herestr_{s}", .{std.fmt.bytesToHex(rnd, .lower)}) catch return error.OutOfMemory;
            if (std.Io.Dir.cwd().createFile(compat.io(), p, .{ .truncate = true, .exclusive = true, .permissions = .fromMode(0o600) })) |f| {
                wf = f;
                break p;
            } else |err| {
                attempt += 1;
                if (err == error.PathAlreadyExists and attempt < 8) continue;
                return err;
            }
        };
        {
            defer wf.close(compat.io());
            try compat.writeAll(wf, content_with_newline);
        }

        const rf = try std.Io.Dir.cwd().openFile(compat.io(), tmp_path, .{ .mode = .read_only });
        defer rf.close(compat.io());
        std.Io.Dir.deleteFileAbsolute(compat.io(), tmp_path) catch {};
        try compat.posix.dup2(rf.handle, compat.posix.STDIN_FILENO);
    } else {
        try applyFdRedirect(shell, redirect_type, expanded_target, saver);
    }
}

/// Handle generic fd redirects carried by RedirectFd tokens:
///   >|          force-truncate stdout to file
///   >&word      stdout+stderr to file, or stdout dup of fd `word`
///   n>file n>>file n<file
///   n>&m n<&m    duplicate fd m into fd n
///   n>&-  n<&-   close fd n
fn applyFdRedirect(shell: *Shell, op: []const u8, target: []const u8, saver: *FdSaver) !void {
    const STDOUT = compat.posix.STDOUT_FILENO;
    const STDERR = compat.posix.STDERR_FILENO;

    // Note: ">|" is not handled here. applyRedirect matches ">" and ">|"
    // together before falling through to this function, so this function is
    // never reached with op == ">|" — a dead branch used to sit here.

    if (std.mem.eql(u8, op, ">&")) {
        // >&digit -> dup that fd into stdout; >&file -> both stdout+stderr to file
        if (target.len > 0 and allDigits(target)) {
            const src = std.fmt.parseInt(i32, target, 10) catch return;
            saver.save(STDOUT);
            try compat.posix.dup2(src, STDOUT);
        } else {
            const file = try std.Io.Dir.cwd().createFile(compat.io(), target, .{ .truncate = true });
            defer file.close(compat.io());
            saver.save(STDOUT);
            saver.save(STDERR);
            try compat.posix.dup2(file.handle, STDOUT);
            try compat.posix.dup2(file.handle, STDERR);
        }
        return;
    }

    // op begins with a single fd digit
    if (op.len < 2) return;
    const fd: i32 = @as(i32, op[0] - '0');
    const rest = op[1..];

    if (std.mem.eql(u8, rest, ">")) {
        try redirectFdTo(shell, fd, target, .trunc, saver);
    } else if (std.mem.eql(u8, rest, ">>")) {
        try redirectFdTo(shell, fd, target, .append, saver);
    } else if (std.mem.eql(u8, rest, "<")) {
        try redirectFdTo(shell, fd, target, .read, saver);
    } else if (std.mem.eql(u8, rest, ">&") or std.mem.eql(u8, rest, "<&")) {
        if (target.len == 1 and target[0] == '-') {
            // n>&- / n<&- : close fd n for the command's duration. save()
            // records the original state for restore; probe the CURRENT
            // state (an earlier redirect in the chain may have reopened n)
            // and skip the close if n is not open — close on a bad fd is
            // unreachable in compat.
            saver.save(fd);
            if (compat.posix.fstat(fd)) |_| compat.posix.close(fd) else |_| {}
        } else if (allDigits(target)) {
            const src = std.fmt.parseInt(i32, target, 10) catch return;
            saver.save(fd);
            try compat.posix.dup2(src, fd);
        }
    }
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
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

fn isArraySpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

// Find the end of one raw array element starting at `start`. Element boundaries
// are unquoted whitespace; single/double quotes, backtick and $(...) groups, and
// backslash escapes are skipped so a space inside them does not split the element.
fn scanArrayElementEnd(content: []const u8, start: usize) usize {
    var i = start;
    var paren: u32 = 0;
    while (i < content.len) {
        const c = content[i];
        switch (c) {
            ' ', '\t', '\n', '\r' => {
                if (paren == 0) break;
                i += 1;
            },
            '\'' => {
                i += 1;
                while (i < content.len and content[i] != '\'') i += 1;
                if (i < content.len) i += 1; // closing '
            },
            '"' => {
                i += 1;
                while (i < content.len) {
                    if (content[i] == '"') {
                        i += 1;
                        break;
                    }
                    if (content[i] == '\\' and i + 1 < content.len) {
                        i += 2;
                        continue;
                    }
                    i += 1;
                }
            },
            '`' => {
                i += 1;
                while (i < content.len) {
                    if (content[i] == '`') {
                        i += 1;
                        break;
                    }
                    if (content[i] == '\\' and i + 1 < content.len) {
                        i += 2;
                        continue;
                    }
                    i += 1;
                }
            },
            '\\' => {
                i += if (i + 1 < content.len) @as(usize, 2) else 1;
            },
            '(' => {
                paren += 1;
                i += 1;
            },
            ')' => {
                if (paren > 0) paren -= 1;
                i += 1;
            },
            else => i += 1,
        }
    }
    return i;
}

// Split a raw array-literal body into fields the way bash does:
//   a=("a b" c)       -> "a b", "c"    (quoted whitespace stays one field)
//   a=($x) x="p q"    -> "p", "q"      (unquoted expansion is IFS-split)
//   a=($(echo o t))   -> "o", "t"      (unquoted cmdsubst is IFS-split)
//   a=("$(echo o t)") -> "o t"         (quoted cmdsubst is one field)
//   a=("$HOME")       -> "$HOME"       (quoted var is one field)
fn expandArrayContent(
    shell: *Shell,
    content: []const u8,
    out: *std.ArrayListUnmanaged([]const u8),
) !void {
    var i: usize = 0;
    while (i < content.len) {
        while (i < content.len and isArraySpace(content[i])) i += 1;
        if (i >= content.len) break;
        const elem_start = i;
        i = scanArrayElementEnd(content, i);
        if (i > elem_start) {
            try appendArrayFields(shell, content[elem_start..i], out);
        }
    }
}

// Expand a single raw array element (quotes still attached) into one or more
// fields. Quotes are removed; the content of single quotes is protected from
// expansion; an unquoted $-expansion or command substitution makes the whole
// element subject to IFS word splitting.
fn appendArrayFields(
    shell: *Shell,
    raw: []const u8,
    out: *std.ArrayListUnmanaged([]const u8),
) !void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(shell.allocator);

    var has_unquoted_exp = false;
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        switch (c) {
            '\'' => {
                // single quotes: literal, protect $ and ` from later expansion
                i += 1;
                while (i < raw.len and raw[i] != '\'') {
                    const q = raw[i];
                    if (q == '$') {
                        try buf.append(shell.allocator, Shell.LIT_DOLLAR);
                    } else if (q == '`') {
                        try buf.append(shell.allocator, Shell.LIT_BACKTICK);
                    } else {
                        try buf.append(shell.allocator, q);
                    }
                    i += 1;
                }
                if (i < raw.len) i += 1; // closing '
            },
            '"' => {
                // double quotes: keep $ / ` active for expansion, drop the quotes
                i += 1;
                while (i < raw.len and raw[i] != '"') {
                    if (raw[i] == '\\' and i + 1 < raw.len) {
                        const e = raw[i + 1];
                        switch (e) {
                            '$' => try buf.append(shell.allocator, Shell.LIT_DOLLAR),
                            '`' => try buf.append(shell.allocator, Shell.LIT_BACKTICK),
                            '"', '\\' => try buf.append(shell.allocator, e),
                            else => {
                                try buf.append(shell.allocator, '\\');
                                try buf.append(shell.allocator, e);
                            },
                        }
                        i += 2;
                        continue;
                    }
                    try buf.append(shell.allocator, raw[i]);
                    i += 1;
                }
                if (i < raw.len) i += 1; // closing "
            },
            '\\' => {
                if (i + 1 < raw.len) {
                    const e = raw[i + 1];
                    if (e == '$') {
                        try buf.append(shell.allocator, Shell.LIT_DOLLAR);
                    } else if (e == '`') {
                        try buf.append(shell.allocator, Shell.LIT_BACKTICK);
                    } else {
                        try buf.append(shell.allocator, e);
                    }
                    i += 2;
                } else {
                    try buf.append(shell.allocator, '\\');
                    i += 1;
                }
            },
            '$', '`' => {
                has_unquoted_exp = true;
                try buf.append(shell.allocator, c);
                i += 1;
            },
            else => {
                try buf.append(shell.allocator, c);
                i += 1;
            },
        }
    }

    const expanded = try shell.expandVariables(buf.items);
    defer shell.allocator.free(expanded);

    if (has_unquoted_exp) {
        // Unquoted expansion result undergoes IFS word splitting.
        var it = std.mem.tokenizeAny(u8, expanded, ifsDelimiters(shell));
        while (it.next()) |word| {
            try out.append(shell.allocator, try shell.allocator.dupe(u8, word));
        }
    } else {
        try out.append(shell.allocator, try shell.allocator.dupe(u8, expanded));
    }
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

        // Split the raw body into fields, honouring quotes / substitutions and
        // applying IFS word-splitting for unquoted expansions.
        var elements: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (elements.items) |elem| shell.allocator.free(elem);
            elements.deinit(shell.allocator);
        }

        try expandArrayContent(shell, array_content, &elements);

        if (is_append) {
            try shell.appendArray(name, elements.items);
        } else {
            try shell.setArray(name, elements.items);
        }
        return 0;
    }

    // fast path for pure arithmetic assignments like i=$((i+1))
    if (!is_append and value.len >= 5 and std.mem.startsWith(u8, value, "$((") and value[value.len - 2] == ')' and value[value.len - 1] == ')') {
        const expr = value[3 .. value.len - 2];
        const arith_result = shell.evaluateArithmetic(expr) catch 0;

        var result_buf: [32]u8 = undefined;
        const result_str = std.fmt.bufPrint(&result_buf, "{d}", .{arith_result}) catch return 1;

        // Store safely: free the old value and dupe a fresh buffer. The former
        // in-place @memcpy mutated the variable's existing storage and shrank the
        // slice below its allocation — which corrupts a later wrong-length free,
        // and rewrites any command text still aliasing that storage (a
        // self-referential PROMPT_COMMAND='n=$((n+1))' clobbered itself).
        if (shell.variables.getPtr(name)) |value_ptr| {
            shell.allocator.free(value_ptr.*);
            value_ptr.* = try shell.allocator.dupe(u8, result_str);
        } else {
            const name_copy = try shell.allocator.dupe(u8, name);
            const value_copy = try shell.allocator.dupe(u8, result_str);
            try shell.variables.put(name_copy, value_copy);
        }
        return 0;
    }

    // regular scalar assignment
    const expanded_value = try shell.expandVariables(value);
    defer shell.allocator.free(expanded_value);

    if (shell.variables.getPtr(name)) |value_ptr| {
        if (is_append) {
            // x+=y : append to the existing value
            const combined = try std.mem.concat(shell.allocator, u8, &.{ value_ptr.*, expanded_value });
            shell.allocator.free(value_ptr.*);
            value_ptr.* = combined;
        } else {
            shell.allocator.free(value_ptr.*);
            value_ptr.* = try shell.allocator.dupe(u8, expanded_value);
        }
        return 0;
    }

    // appending to an unset variable is a plain assignment
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

// LoopAction: how the enclosing loop should react to a body's exit status.
const LoopAction = enum { normal, continue_loop, break_loop };

// Consult break/continue sentinels + level counters. Decrements the level so
// that `break N` / `continue N` propagate through N enclosing loops. When this
// loop is the target (level reaches 1) the sentinel is consumed here; otherwise
// the caller must re-propagate the sentinel to the outer loop.
fn loopControl(shell: *Shell, status: u8) LoopAction {
    if (status == 254) { // break
        if (shell.loop_break > 1) {
            shell.loop_break -= 1;
            return .break_loop; // still targeting an outer loop
        }
        shell.loop_break = 0;
        return .break_loop;
    }
    if (status == 253) { // continue
        if (shell.loop_continue > 1) {
            shell.loop_continue -= 1;
            return .break_loop; // outer loop is the continue target: unwind this one
        }
        shell.loop_continue = 0;
        return .continue_loop;
    }
    return .normal;
}

// (( expr )) — evaluate the arithmetic expression(s). Exit status is 0 when the
// (last) result is non-zero, 1 otherwise (bash semantics). `;`-separated parts
// are each evaluated for their side effects.
pub fn evaluateArithCommand(shell: *Shell, node: *const ast.AstNode) !u8 {
    var result: i64 = 0;
    var any = false;
    var it = std.mem.splitScalar(u8, node.value, ';');
    while (it.next()) |part| {
        const e = std.mem.trim(u8, part, " \t");
        if (e.len == 0) continue;
        any = true;
        result = shell.evaluateArithmetic(e) catch return 1;
    }
    if (!any) return 1;
    return if (result != 0) 0 else 1;
}

// for ((init; cond; update)); do body; done — C-style arithmetic for loop.
pub fn evaluateCForLoop(shell: *Shell, node: *const ast.AstNode) !u8 {
    if (node.children.len != 1) return 1;
    const body = node.children[0];

    // Split the header into init/cond/update on ';' (each optional).
    var parts: [3][]const u8 = .{ "", "", "" };
    var idx: usize = 0;
    var it = std.mem.splitScalar(u8, node.value, ';');
    while (it.next()) |part| : (idx += 1) {
        if (idx < 3) parts[idx] = std.mem.trim(u8, part, " \t");
    }
    const init_expr = parts[0];
    const cond_expr = parts[1];
    const update_expr = parts[2];

    if (init_expr.len > 0) _ = shell.evaluateArithmetic(init_expr) catch {};

    var last_status: u8 = 0;
    while (true) {
        // An empty condition is always true (for ((;;)) loops forever).
        if (cond_expr.len > 0) {
            const c = shell.evaluateArithmetic(cond_expr) catch 0;
            if (c == 0) break;
        }
        const body_status = try evaluateAst(shell, body);
        switch (loopControl(shell, body_status)) {
            .break_loop => return if (shell.loop_break > 0 or shell.loop_continue > 0) body_status else 0,
            .continue_loop => last_status = 0, // fall through to the update step
            .normal => last_status = body_status,
        }
        if (update_expr.len > 0) _ = shell.evaluateArithmetic(update_expr) catch {};
    }
    return last_status;
}

pub fn evaluateWhile(shell: *Shell, node: *const ast.AstNode) !u8 {
    if (node.children.len != 2) return 1;

    var last_status: u8 = 0;

    while (true) {
        const condition = try evaluateAst(shell, node.children[0]);
        if (condition != 0) break;

        const body_status = try evaluateAst(shell, node.children[1]);
        switch (loopControl(shell, body_status)) {
            .break_loop => return if (shell.loop_break > 0 or shell.loop_continue > 0) body_status else 0,
            .continue_loop => {
                last_status = 0;
                continue;
            },
            .normal => last_status = body_status,
        }
    }

    return last_status;
}

pub fn evaluateUntil(shell: *Shell, node: *const ast.AstNode) !u8 {
    if (node.children.len != 2) return 1;

    var last_status: u8 = 0;

    while (true) {
        const condition = try evaluateAst(shell, node.children[0]);
        if (condition == 0) break;

        const body_status = try evaluateAst(shell, node.children[1]);
        switch (loopControl(shell, body_status)) {
            .break_loop => return if (shell.loop_break > 0 or shell.loop_continue > 0) body_status else 0,
            .continue_loop => {
                last_status = 0;
                continue;
            },
            .normal => last_status = body_status,
        }
    }

    return last_status;
}

pub fn evaluateFor(shell: *Shell, node: *const ast.AstNode) !u8 {
    // [variable, word0..wordN, body] — the word list may be empty
    // (`for x in; do ...; done` runs zero iterations).
    if (node.children.len < 2) return 1;

    const variable = node.children[0];
    const body = node.children[node.children.len - 1];
    const values = node.children[1 .. node.children.len - 1];

    // bash expands the ENTIRE word list before the first iteration, so a body
    // that mutates a variable referenced by a LATER word still iterates over
    // the pre-loop values. Expanding lazily per-word (as this loop once did)
    // diverges the moment the body has side effects.
    var words: std.ArrayList([]const u8) = .empty;
    defer {
        for (words.items) |w| shell.allocator.free(w);
        words.deinit(shell.allocator);
    }
    try collectWords(shell, values, &words);

    var last_status: u8 = 0;
    for (words.items) |word| {
        try setPlainVar(shell, variable.value, word);
        const body_status = try evaluateAst(shell, body);
        switch (loopControl(shell, body_status)) {
            .break_loop => return if (shell.loop_break > 0 or shell.loop_continue > 0) body_status else 0,
            .continue_loop => {
                last_status = 0;
                continue;
            },
            .normal => last_status = body_status,
        }
    }
    return last_status;
}

// Set a shell variable to an owned copy of `value`, freeing any prior value.
fn setPlainVar(shell: *Shell, name: []const u8, value: []const u8) !void {
    const value_copy = try shell.allocator.dupe(u8, value);
    if (shell.variables.getEntry(name)) |e| {
        shell.allocator.free(e.value_ptr.*);
        e.value_ptr.* = value_copy;
        return;
    }
    const name_copy = try shell.allocator.dupe(u8, name);
    errdefer shell.allocator.free(name_copy);
    try shell.variables.put(name_copy, value_copy);
}

// Expand for/select word nodes into a flat, owned list of strings:
// single-quote literal, double-quote var expansion with "$@" / "${a[@]}"
// special-casing, and the shared unquoted pipeline for everything else.
fn collectWords(shell: *Shell, values: []const *const ast.AstNode, out: *std.ArrayList([]const u8)) !void {
    for (values) |value_node| {
        const raw = value_node.value;

        if (value_node.node_type == .string) {
            try out.append(shell.allocator, try shell.allocator.dupe(u8, raw));
            continue;
        }

        if (value_node.node_type == .double_quoted) {
            // "$@" is special: one field per positional parameter (not joined).
            if (isQuotedAtParam(raw)) {
                const count = positionalCount(shell);
                var i: usize = 1;
                while (i <= count) : (i += 1) {
                    var nb: [16]u8 = undefined;
                    const ns = std.fmt.bufPrint(&nb, "{d}", .{i}) catch break;
                    const v = shell.variables.get(ns) orelse "";
                    try out.append(shell.allocator, try shell.allocator.dupe(u8, v));
                }
                continue;
            }
            // "${a[@]}" is likewise one field per array element.
            if (quotedArrayAll(raw)) |arr_name| {
                const alen = shell.getArrayLen(arr_name) orelse 0;
                var ai: usize = 0;
                while (ai < alen) : (ai += 1) {
                    const elem = shell.getArrayElement(arr_name, ai) orelse "";
                    try out.append(shell.allocator, try shell.allocator.dupe(u8, elem));
                }
                continue;
            }
            const res = try shell.expandVariablesNoTildeZ(raw);
            defer res.deinit(shell.allocator);
            try out.append(shell.allocator, try shell.allocator.dupe(u8, res.slice));
            continue;
        }

        try expandUnquotedWordInto(shell, raw, out);
    }
}

// The single unquoted-word expansion pipeline: brace expansion → variable /
// command substitution → IFS field splitting → glob, appending one heap-owned
// string per resulting field. Shared by evaluateCommand (argument words) and
// collectWords (for/select word lists) — this used to be hand-copied in three
// places, and the copies had drifted apart.
fn expandUnquotedWordInto(shell: *Shell, raw: []const u8, out: *std.ArrayList([]const u8)) !void {
    // Unquoted expansions ($var, ${var}, $(cmd), `cmd`, $((...))) undergo
    // word splitting on IFS (default: space/tab/newline). POSIX: only the
    // RESULT of an unquoted expansion is split — a literal word never is,
    // and a .word node here has no unquoted literal spaces (the lexer split
    // those into separate nodes), so splitting the whole expansion is safe.
    const needs_word_split = hasCommandSubstitution(raw) or
        std.mem.indexOfScalar(u8, raw, '$') != null;

    // Step 1: Brace expansion {a,b,c} or {1..5}
    const brace_results = if (Shell.hasBracePattern(raw))
        try Shell.expandBraces(shell.allocator, raw)
    else
        null;
    defer if (brace_results) |br| Shell.freeBraceResults(shell.allocator, br);
    const brace_items = if (brace_results) |br| br else &[_][]const u8{raw};

    for (brace_items) |item| {
        // Step 2: Variable expansion (includes command substitution and tilde;
        // no-op fast path inside when the item has nothing to expand)
        const var_expanded_result = try shell.expandVariablesZ(item);
        defer var_expanded_result.deinit(shell.allocator);
        const var_expanded = var_expanded_result.slice;

        // Step 3: IFS field splitting, then glob on each field. An expansion
        // that comes back empty yields no fields at all (POSIX).
        if (needs_word_split) {
            var split_iter = std.mem.tokenizeAny(u8, var_expanded, ifsDelimiters(shell));
            while (split_iter.next()) |word| {
                try appendGlobbedField(shell, word, out);
            }
        } else {
            try appendGlobbedField(shell, var_expanded, out);
        }
    }
}

// Step 4 of the pipeline: glob-expand one field, appending each match — or the
// field itself when the pattern matches nothing (bash keeps the pattern).
fn appendGlobbedField(shell: *Shell, word: []const u8, out: *std.ArrayList([]const u8)) !void {
    if (glob.hasGlobChars(word)) {
        const glob_results = try glob.expandGlob(shell.allocator, word);
        defer glob.freeGlobResults(shell.allocator, glob_results);
        if (glob_results.len != 0) {
            for (glob_results) |m| try out.append(shell.allocator, try shell.allocator.dupe(u8, m));
            return;
        }
    }
    try out.append(shell.allocator, try shell.allocator.dupe(u8, word));
}

fn digitCount(n: usize) usize {
    var d: usize = 1;
    var v = n;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

// bash-style indent: advance the cursor from column `from` to `to` using tabs
// (to 8-column tab stops) and spaces, writing into `buf`.
fn selectIndent(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, from_in: usize, to: usize) !void {
    var from = from_in;
    while (from < to) {
        if (to / 8 > from / 8) {
            try buf.append(alloc, '\t');
            from += 8 - (from % 8);
        } else {
            try buf.append(alloc, ' ');
            from += 1;
        }
    }
}

// Render the numbered select menu to stderr, matching bash's column packing.
fn printSelectMenu(shell: *Shell, words: []const []const u8) !void {
    const n = words.len;
    if (n == 0) {
        _ = compat.posix.write(compat.posix.STDERR_FILENO, "\n") catch {};
        return;
    }

    const cols_env = shell.variables.get("COLUMNS") orelse (compat.posix.getenv("COLUMNS") orelse "");
    const term_cols: usize = std.fmt.parseInt(usize, std.mem.trim(u8, cols_env, " \t"), 10) catch 80;

    const indices_len = digitCount(n);
    var max_word: usize = 0;
    for (words) |w| {
        if (w.len > max_word) max_word = w.len;
    }
    // element width = index field + ") " + word, plus a 2-column inter-column gap
    const max_elem_len = max_word + indices_len + 2 + 2;

    var cols = if (max_elem_len > 0) term_cols / max_elem_len else 1;
    if (cols < 1) cols = 1;
    var rows = (n + cols - 1) / cols;
    cols = (n + rows - 1) / rows;
    if (rows == 1) {
        rows = cols;
        cols = 1;
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(shell.allocator);

    var row: usize = 0;
    while (row < rows) : (row += 1) {
        var pos: usize = 0;
        var ind = row;
        var first_in_row = true;
        while (true) {
            const w = words[ind];
            // "%*d) %s" with index field right-justified to indices_len. bash
            // leaves the first column of a multi-column row unpadded (its
            // inter-column indent handles alignment); a single column is padded.
            var numbuf: [24]u8 = undefined;
            const ns = std.fmt.bufPrint(&numbuf, "{d}", .{ind + 1}) catch "";
            const idx_width = if (!first_in_row or cols == 1) indices_len else ns.len;
            var pad = idx_width;
            while (pad > ns.len) : (pad -= 1) try buf.append(shell.allocator, ' ');
            first_in_row = false;
            try buf.appendSlice(shell.allocator, ns);
            try buf.appendSlice(shell.allocator, ") ");
            try buf.appendSlice(shell.allocator, w);

            // Bookkeeping width uses the actual index chars written, matching
            // bash's indent() accounting so tab/space gaps come out identical.
            const elem_len = w.len + idx_width + 2;
            ind += rows;
            if (ind >= n) break;
            try selectIndent(&buf, shell.allocator, pos + elem_len, pos + max_elem_len);
            pos += max_elem_len;
        }
        try buf.append(shell.allocator, '\n');
    }

    _ = compat.posix.write(compat.posix.STDERR_FILENO, buf.items) catch {};
}

// Read one line from stdin (fd 0). Returns null on immediate EOF with no data.
// The returned slice (into `buf`) excludes the trailing newline.
fn readSelectLine(buf: []u8) ?[]const u8 {
    var pos: usize = 0;
    var got_any = false;
    while (pos < buf.len) {
        var c: [1]u8 = undefined;
        const nread = compat.posix.read(compat.posix.STDIN_FILENO, &c) catch return if (got_any) buf[0..pos] else null;
        if (nread == 0) return if (got_any) buf[0..pos] else null;
        got_any = true;
        if (c[0] == '\n') return buf[0..pos];
        buf[pos] = c[0];
        pos += 1;
    }
    return buf[0..pos];
}

pub fn evaluateSelect(shell: *Shell, node: *const ast.AstNode) !u8 {
    if (node.children.len < 3) return 1;

    const variable = node.children[0];
    const body = node.children[node.children.len - 1];
    const value_nodes = node.children[1 .. node.children.len - 1];

    // Expand the word list once, up front — the menu is fixed for the loop.
    var words: std.ArrayList([]const u8) = .empty;
    defer {
        for (words.items) |w| shell.allocator.free(w);
        words.deinit(shell.allocator);
    }
    try collectWords(shell, value_nodes, &words);

    // PS3 prompt (default "#? ")
    const ps3 = shell.variables.get("PS3") orelse (compat.posix.getenv("PS3") orelse "#? ");

    var last_status: u8 = 0;
    var need_menu = true;
    var line_buf: [4096]u8 = undefined;

    // Cook the terminal for the duration of the loop: the line editor leaves it
    // raw, where readSelectLine gets no echo and never sees a line-ending '\n'
    // (Enter arrives as CR), so `select` would hang uninteractably. Same fix as
    // the `read` builtin. Restored on exit.
    const sel_stdin = compat.posix.STDIN_FILENO;
    var sel_orig: ?compat.posix.termios = null;
    if (compat.posix.isatty(sel_stdin)) {
        sel_orig = compat.posix.tcgetattr(sel_stdin) catch null;
        if (sel_orig) |ot| {
            var nt = ot;
            nt.lflag.ICANON = true;
            nt.lflag.ECHO = true;
            nt.lflag.ISIG = true;
            nt.iflag.ICRNL = true;
            compat.posix.tcsetattr(sel_stdin, .NOW, nt) catch {};
        }
    }
    defer if (sel_orig) |ot| {
        compat.posix.tcsetattr(sel_stdin, .NOW, ot) catch {};
    };

    while (true) {
        // Flush any pending buffered stdout so the menu/prompt (written straight
        // to fd 2) interleave with prior body output in the right order.
        shell.stdout().flush() catch {};
        if (need_menu) {
            try printSelectMenu(shell, words.items);
            need_menu = false;
        }
        _ = compat.posix.write(compat.posix.STDERR_FILENO, ps3) catch {};

        const line = readSelectLine(&line_buf) orelse {
            // EOF: bash prints a newline to stderr and exits the loop.
            _ = compat.posix.write(compat.posix.STDERR_FILENO, "\n") catch {};
            break;
        };

        // REPLY holds the raw input line, unmodified (bash does not trim it).
        try setPlainVar(shell, "REPLY", line);

        // A completely empty line reprints the menu and prompts again (no body).
        // A blank-but-nonempty line (spaces) is an invalid selection instead.
        if (line.len == 0) {
            need_menu = true;
            continue;
        }

        // Valid selection is a positive integer within range; else name="".
        const trimmed = std.mem.trim(u8, line, " \t");
        const choice: []const u8 = blk: {
            const num = std.fmt.parseInt(usize, trimmed, 10) catch break :blk "";
            if (num >= 1 and num <= words.items.len) break :blk words.items[num - 1];
            break :blk "";
        };
        try setPlainVar(shell, variable.value, choice);

        last_status = try evaluateAst(shell, body);
        if (last_status == 254) { // break
            switch (loopControl(shell, last_status)) {
                .break_loop => return if (shell.loop_break > 0 or shell.loop_continue > 0) last_status else 0,
                else => return 0,
            }
        }
        if (last_status == 253) { // continue
            if (shell.loop_continue > 1) {
                switch (loopControl(shell, last_status)) {
                    .break_loop => return if (shell.loop_break > 0 or shell.loop_continue > 0) last_status else 0,
                    else => return 0,
                }
            }
            last_status = 0;
        }
    }

    return last_status;
}

pub fn evaluateSubshell(shell: *Shell, node: *const ast.AstNode) !u8 {
    if (node.children.len == 0) return 1;

    // A subshell runs in a forked child so cwd, variables, traps, etc. are
    // isolated from the parent shell (POSIX ( ... ) semantics).
    // Inside an existing pipeline stage we are already a forked child, so run
    // in-process to avoid an extra fork (isolation is already provided).
    if (shell.forked_child) {
        return evaluateAst(shell, node.children[0]);
    }

    // flush buffered output so the child doesn't inherit and re-emit it
    shell.stdout().flush() catch {};

    // Foreground job-control discipline, mirroring the single-command path:
    // cook the terminal for the body, give the subshell its OWN process group
    // with the terminal, and take both back afterwards. Without this
    // (a) `( external )` exec'd in place in the child, cooked the tty via its
    // own path, and the parent never restored raw mode — the line editor was
    // silently broken at the next prompt; (b) the body ran in the SHELL's
    // process group, so Ctrl+Z during `( sleep 30 )` SIGTSTP'd the shell.
    var fg_session = foreground.Session.begin(shell);
    defer fg_session.end();

    const pid = compat.posix.fork() catch {
        try shell.stdout().writeAll("zish: fork failed\n");
        return 1;
    };

    if (pid == 0) {
        // === CHILD ===
        // own process group + terminal, then default signals — in that order
        // (Session.setupChild owns the ordered dance).
        fg_session.setupChild();
        var child_arena = forkChildArena();
        shell.allocator = child_arena.allocator();
        shell.forked_child = true;
        // Only the body itself may exec in place. When the body is a compound
        // ( a; b ) evaluateAst descends into nodes that are not this one, and
        // those correctly fork instead of replacing this process mid-body.
        shell.exec_in_place_node = node.children[0];
        const status = evaluateAst(shell, node.children[0]) catch 127;
        shell.stdout().flush() catch {};
        compat.posix.exit(status);
    }

    // === PARENT ===
    // both sides call setpgid (race avoidance, as in the command path)
    fg_session.registerChild(pid);

    // Display string in case the subshell is Ctrl+Z'd and becomes a job.
    var cmd_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer cmd_buf.deinit(shell.allocator);
    serializeAst(shell.allocator, &cmd_buf, node) catch {};
    const cmd: []const u8 = if (cmd_buf.items.len > 0) cmd_buf.items else "( ... )";

    // SIGINT-ignore + waitpid(UNTRACED) + decode + stopped-job registration
    // + terminal reclaim, all in the owner.
    const out = fg_session.reap(pid, cmd, null);
    return out.code;
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
        // SAFETY: after fork the parent's GPA may be mid-allocation on another
        // thread. See forkChildArena for why this is an arena and not
        // page_allocator directly.
        var child_arena = forkChildArena();
        shell.allocator = child_arena.allocator();

        // set up process group for job control
        jobs.launchProcess(0, 0, false, compat.posix.STDIN_FILENO);

        // This child exists to run `command`; when that is a single external
        // command it may exec in place and avoid a double fork. A compound body
        // ( a; b ) & descends into other nodes, which fork normally.
        shell.forked_child = true;
        shell.exec_in_place_node = command;

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

    // record for $! (PID of the most recent background command)
    shell.last_bg_pid = pid;

    // add job to table
    const job_id = shell.job_table.addJob(pid, cmd_str, false) catch {
        if (compat.posix.isatty(compat.posix.STDIN_FILENO)) {
            var buf: [64]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "[?] {d}\n", .{pid}) catch return 0;
            compat.writeAll(.stderr(), line) catch {};
        }
        return 0;
    };

    // Job notifications are interactive UI, not command output: bash prints
    // them only when interactive, and to stderr. Printing to stdout made
    // `zish -c '( ... ) & wait'` emit "[1] 12345" into the script's output.
    if (compat.posix.isatty(compat.posix.STDIN_FILENO)) {
        var buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "[{d}] {d}\n", .{ job_id, pid }) catch return 0;
        compat.writeAll(.stderr(), line) catch {};
    }
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
        if (case_item.children.len < 1) continue;

        // case_item.children[0] = body, children[1..] = one node per
        // alternation branch. Each branch is its own node (rather than a
        // '|'-joined string) so a literal '|' inside a quoted/word token is
        // never mistaken for the Pipe token that separates real alternatives.
        for (case_item.children[1..]) |branch| {
            // expand variables in the pattern branch
            const expanded_pattern = try shell.expandVariables(branch.value);
            defer shell.allocator.free(expanded_pattern);

            // check if pattern matches
            if (glob.matchGlob(expanded_pattern, expr_value)) {
                // execute the body (case_item.children[0])
                return evaluateAst(shell, case_item.children[0]);
            }
        }
    }

    // no pattern matched
    return 0;
}

pub fn evaluateTest(shell: *Shell, node: *const ast.AstNode) !u8 {
    const result = try evaluateTestNode(shell, node);
    return if (result) 0 else 1;
}

// Recursively evaluate a [[ ]] expression tree built by parsetest.
// The tree uses:
//   - .logical_and / .logical_or (2 children) for && / ||
//   - .test_expression with value "!" (1 child) for negation
//   - .test_expression with value "" (operand children) for a primary
fn evaluateTestNode(shell: *Shell, node: *const ast.AstNode) anyerror!bool {
    switch (node.node_type) {
        .logical_and => {
            if (node.children.len != 2) return false;
            if (!try evaluateTestNode(shell, node.children[0])) return false; // short-circuit
            return try evaluateTestNode(shell, node.children[1]);
        },
        .logical_or => {
            if (node.children.len != 2) return false;
            if (try evaluateTestNode(shell, node.children[0])) return true; // short-circuit
            return try evaluateTestNode(shell, node.children[1]);
        },
        .test_expression => {
            if (node.value.len == 1 and node.value[0] == '!') {
                if (node.children.len != 1) return false;
                return !(try evaluateTestNode(shell, node.children[0]));
            }
            return evaluateTestPrimaryNode(shell, node.children);
        },
        else => return false,
    }
}

// Evaluate a primary: a sequence of operand nodes.
// Variables are expanded on every operand. The RHS of ==/!=/=~ keeps its glob/
// regex metacharacters (it is a pattern), unless the operand was quoted, in which
// case it is matched literally.
fn evaluateTestPrimaryNode(shell: *Shell, operands: []const *const ast.AstNode) !bool {
    if (operands.len == 0) return false;

    var args = try std.ArrayList([]const u8).initCapacity(shell.allocator, operands.len);
    defer {
        for (args.items) |arg| shell.allocator.free(arg);
        args.deinit(shell.allocator);
    }
    for (operands) |child| {
        const expanded = try shell.expandVariables(child.value);
        try args.append(shell.allocator, expanded);
    }

    // Leading `!` may still ride along inside a primary (e.g. `[[ ! -f x ]]`
    // where `!` is folded into the primary rather than a separate unary node).
    var base: usize = 0;
    var negate = false;
    while (base < args.items.len and std.mem.eql(u8, args.items[base], "!")) {
        negate = !negate;
        base += 1;
    }
    const view = args.items[base..];
    const op_nodes = operands[base..];

    const result = try evaluateTestPrimary(shell, view, op_nodes);
    return if (negate) !result else result;
}

fn testRhsIsQuoted(node: *const ast.AstNode) bool {
    return node.node_type == .double_quoted or node.node_type == .string;
}

fn evaluateTestPrimary(shell: *Shell, args: []const []const u8, op_nodes: []const *const ast.AstNode) !bool {
    if (args.len == 0) return false;

    const first = args[0];

    // binary operators (checked first so `==`, `<`, `=~` are not mistaken for unary)
    if (args.len >= 3) {
        const left = args[0];
        const op = args[1];
        const right = args[2];
        const rhs_literal = testRhsIsQuoted(op_nodes[2]);

        if (std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "=")) {
            if (rhs_literal) return std.mem.eql(u8, left, right);
            return glob.matchGlob(right, left);
        } else if (std.mem.eql(u8, op, "!=")) {
            if (rhs_literal) return !std.mem.eql(u8, left, right);
            return !glob.matchGlob(right, left);
        } else if (std.mem.eql(u8, op, "=~")) {
            return matchRegex(right, left);
        } else if (std.mem.eql(u8, op, "<")) {
            return std.mem.order(u8, left, right) == .lt;
        } else if (std.mem.eql(u8, op, ">")) {
            return std.mem.order(u8, left, right) == .gt;
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
        } else if (std.mem.eql(u8, op, "-nt") or std.mem.eql(u8, op, "-ot") or std.mem.eql(u8, op, "-ef")) {
            return fileCompare(op, left, right);
        }
    }

    // unary operators: -<c> operand
    if (first.len == 2 and first[0] == '-' and args.len >= 2) {
        return evaluateUnaryTest(shell, first[1], args[1]);
    }

    // single arg: non-empty string is true
    return first.len > 0;
}

fn evaluateUnaryTest(shell: *Shell, opc: u8, operand: []const u8) bool {
    const cwd = std.Io.Dir.cwd();
    return switch (opc) {
        'z' => operand.len == 0,
        'n' => operand.len > 0,
        'e', 'a' => blk: {
            cwd.access(compat.io(), operand, .{}) catch break :blk false;
            break :blk true;
        },
        'f' => blk: {
            const stat = cwd.statFile(compat.io(), operand, .{}) catch break :blk false;
            break :blk stat.kind == .file;
        },
        'd' => blk: {
            const stat = cwd.statFile(compat.io(), operand, .{}) catch break :blk false;
            break :blk stat.kind == .directory;
        },
        'h', 'L' => isSymlink(operand),
        'p' => statKindIs(cwd, operand, .named_pipe),
        'S' => statKindIs(cwd, operand, .unix_domain_socket),
        'b' => statKindIs(cwd, operand, .block_device),
        'c' => statKindIs(cwd, operand, .character_device),
        'r' => blk: {
            cwd.access(compat.io(), operand, .{ .read = true }) catch break :blk false;
            break :blk true;
        },
        'w' => blk: {
            cwd.access(compat.io(), operand, .{ .write = true }) catch break :blk false;
            break :blk true;
        },
        'x' => blk: {
            // stat, don't open: open(2) on a FIFO with no writer blocks forever,
            // so `[ -x fifo ]` used to hang the shell. statPosix never opens.
            const st = statPosix(operand) orelse break :blk false;
            break :blk (st.mode & 0o111) != 0;
        },
        's' => blk: {
            const stat = cwd.statFile(compat.io(), operand, .{}) catch break :blk false;
            break :blk stat.size > 0;
        },
        'g' => statModeBit(operand, 0o2000),
        'u' => statModeBit(operand, 0o4000),
        'k' => statModeBit(operand, 0o1000),
        'O' => blk: {
            const st = statPosix(operand) orelse break :blk false;
            break :blk st.uid == compat.posix.geteuid();
        },
        'G' => blk: {
            const st = statPosix(operand) orelse break :blk false;
            break :blk st.gid == compat.posix.getegid();
        },
        'v' => shell.variables.contains(operand),
        'o' => isShellOption(shell, operand),
        else => false,
    };
}

fn isSymlink(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const pathz: [*:0]const u8 = @ptrCast(&buf);
    // Was statx, which is Linux-only: everywhere else this silently returned
    // false, so `[ -L link ]` was never true rather than erroring.
    const st = compat.posix.statPath(pathz, false) orelse return false;
    return (st.mode & 0o170000) == 0o120000; // S_IFLNK
}

fn statKindIs(cwd: std.Io.Dir, path: []const u8, kind: std.Io.File.Kind) bool {
    const stat = cwd.statFile(compat.io(), path, .{}) catch return false;
    return stat.kind == kind;
}

fn statModeBit(path: []const u8, bit: u32) bool {
    // stat, don't open — an open on a FIFO/device can block; -g/-u/-k are pure
    // mode-bit checks that statPosix answers without touching the file.
    const st = statPosix(path) orelse return false;
    return (st.mode & bit) != 0;
}

/// stat(2) via libc. Portable, unlike the statx it replaced — std.c.Stat
/// exposes dev/ino/uid/gid and a uniform mtime() accessor on every target,
/// where statx is Linux-only and made -O/-G/-ef/-nt/-ot silently false
/// everywhere else.
fn statPosix(path: []const u8) ?compat.posix.FileStat {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const pathz: [*:0]const u8 = @ptrCast(&buf);
    return compat.posix.statPath(pathz, true);
}

fn isShellOption(shell: *Shell, name: []const u8) bool {
    if (std.mem.eql(u8, name, "errexit")) return shell.opt_errexit;
    if (std.mem.eql(u8, name, "nounset")) return shell.opt_nounset;
    if (std.mem.eql(u8, name, "xtrace")) return shell.opt_xtrace;
    if (std.mem.eql(u8, name, "pipefail")) return shell.opt_pipefail;
    return false;
}

// -nt / -ot / -ef file comparisons
fn fileCompare(op: []const u8, a: []const u8, b: []const u8) bool {
    const sa = statPosix(a);
    const sb = statPosix(b);
    if (std.mem.eql(u8, op, "-ef")) {
        if (sa == null or sb == null) return false;
        return sa.?.dev == sb.?.dev and sa.?.ino == sb.?.ino;
    }
    const ta: i128 = if (sa) |s| mtimeNs(s) else if (std.mem.eql(u8, op, "-ot")) std.math.maxInt(i128) else std.math.minInt(i128);
    const tb: i128 = if (sb) |s| mtimeNs(s) else if (std.mem.eql(u8, op, "-nt")) std.math.maxInt(i128) else std.math.minInt(i128);
    if (std.mem.eql(u8, op, "-nt")) return ta > tb;
    return ta < tb; // -ot
}

fn mtimeNs(st: compat.posix.FileStat) i128 {
    return st.mtime_ns;
}

// Minimal POSIX ERE matcher for the `=~` operator. Supports: literals, `.`,
// anchors `^`/`$`, character classes `[...]`/`[^...]` (with ranges), and the
// quantifiers `*`, `+`, `?` applied to the preceding atom. Returns true if the
// pattern matches any substring of `text` (unanchored, like bash). Grouping `()`
// and alternation `|` are NOT supported and are treated as literals.
fn matchRegex(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return true;
    if (pattern[0] == '^') {
        return reMatchHere(pattern[1..], text);
    }
    var i: usize = 0;
    while (true) {
        if (reMatchHere(pattern, text[i..])) return true;
        if (i >= text.len) return false;
        i += 1;
    }
}

// Match pattern anchored at the start of text.
fn reMatchHere(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return true;
    if (pattern.len == 1 and pattern[0] == '$') return text.len == 0;

    // determine the length of the first atom (a single char, `.`, or `[...]`)
    const atom_len = reAtomLen(pattern);
    const has_quant = atom_len < pattern.len and (pattern[atom_len] == '*' or pattern[atom_len] == '+' or pattern[atom_len] == '?');

    if (has_quant) {
        const quant = pattern[atom_len];
        const rest = pattern[atom_len + 1 ..];
        return reMatchQuant(pattern[0..atom_len], quant, rest, text);
    }

    if (text.len > 0 and reAtomMatches(pattern[0..atom_len], text[0])) {
        return reMatchHere(pattern[atom_len..], text[1..]);
    }
    return false;
}

fn reMatchQuant(atom: []const u8, quant: u8, rest: []const u8, text: []const u8) bool {
    switch (quant) {
        '?' => {
            if (text.len > 0 and reAtomMatches(atom, text[0])) {
                if (reMatchHere(rest, text[1..])) return true;
            }
            return reMatchHere(rest, text);
        },
        '*', '+' => {
            var count: usize = 0;
            while (count < text.len and reAtomMatches(atom, text[count])) : (count += 1) {}
            // for `+` require at least one match
            var n = count;
            const min: usize = if (quant == '+') 1 else 0;
            while (n + 1 > min) : (n -= 1) {
                if (reMatchHere(rest, text[n..])) return true;
                if (n == 0) break;
            }
            if (min == 0) return reMatchHere(rest, text);
            return false;
        },
        else => return false,
    }
}

// Length in bytes of the first regex atom in pattern.
fn reAtomLen(pattern: []const u8) usize {
    if (pattern.len == 0) return 0;
    if (pattern[0] == '\\' and pattern.len >= 2) return 2;
    if (pattern[0] == '[') {
        var j: usize = 1;
        if (j < pattern.len and pattern[j] == '^') j += 1;
        if (j < pattern.len and pattern[j] == ']') j += 1; // ] as first member
        while (j < pattern.len and pattern[j] != ']') j += 1;
        if (j < pattern.len) j += 1; // include closing ]
        return j;
    }
    return 1;
}

fn reAtomMatches(atom: []const u8, ch: u8) bool {
    if (atom.len == 0) return false;
    if (atom[0] == '\\' and atom.len >= 2) return atom[1] == ch;
    if (atom[0] == '.') return true;
    if (atom[0] == '[') return reClassMatches(atom, ch);
    return atom[0] == ch;
}

fn reClassMatches(class: []const u8, ch: u8) bool {
    // class is like "[...]" or "[^...]"
    if (class.len < 2) return false;
    var i: usize = 1;
    var negate = false;
    if (i < class.len and class[i] == '^') {
        negate = true;
        i += 1;
    }
    const end = class.len - 1; // index of closing ]
    var matched = false;
    while (i < end) {
        // range a-b
        if (i + 2 < end and class[i + 1] == '-') {
            if (ch >= class[i] and ch <= class[i + 2]) matched = true;
            i += 3;
        } else {
            if (class[i] == ch) matched = true;
            i += 1;
        }
    }
    return matched != negate;
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
            try serializeTestInner(allocator, buf, node);
            try buf.appendSlice(allocator, " ]]");
        },
        else => {
            try buf.appendSlice(allocator, node.value);
        },
    }
}

fn serializeTestInner(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), node: *const ast.AstNode) !void {
    switch (node.node_type) {
        .logical_and => {
            try serializeTestInner(allocator, buf, node.children[0]);
            try buf.appendSlice(allocator, " && ");
            try serializeTestInner(allocator, buf, node.children[1]);
        },
        .logical_or => {
            try serializeTestInner(allocator, buf, node.children[0]);
            try buf.appendSlice(allocator, " || ");
            try serializeTestInner(allocator, buf, node.children[1]);
        },
        .test_expression => {
            if (node.value.len == 1 and node.value[0] == '!') {
                try buf.appendSlice(allocator, "! ");
                try serializeTestInner(allocator, buf, node.children[0]);
            } else {
                for (node.children, 0..) |child, i| {
                    if (i > 0) try buf.append(allocator, ' ');
                    try buf.appendSlice(allocator, child.value);
                }
            }
        },
        else => {},
    }
}

// --- local variable scoping ------------------------------------------------

// Begin a new local scope (one per function call).
pub fn pushLocalScope(shell: *Shell) !void {
    try shell.local_scopes.append(shell.allocator, .empty);
}

// End the current local scope, restoring every variable that `local` shadowed.
pub fn popLocalScope(shell: *Shell) void {
    var frame = shell.local_scopes.pop() orelse return;
    // Restore in reverse declaration order.
    var i = frame.items.len;
    while (i > 0) {
        i -= 1;
        const sv = frame.items[i];
        if (sv.existed) {
            setShellVar(shell, sv.name, sv.value) catch {};
        } else if (shell.variables.fetchRemove(sv.name)) |kv| {
            shell.allocator.free(kv.key);
            shell.allocator.free(kv.value);
        }
        shell.allocator.free(sv.name);
        shell.allocator.free(sv.value);
    }
    frame.deinit(shell.allocator);
}

// Mark `name` as local to the current function call, saving its prior state so
// popLocalScope can restore it. No-op (returns false) outside any function.
pub fn declareLocal(shell: *Shell, name: []const u8) !bool {
    if (shell.local_scopes.items.len == 0) return false;
    const frame = &shell.local_scopes.items[shell.local_scopes.items.len - 1];
    // Only the first `local x` in a frame records the caller's value.
    for (frame.items) |sv| {
        if (std.mem.eql(u8, sv.name, name)) return true;
    }
    const existed = shell.variables.get(name);
    try frame.append(shell.allocator, .{
        .name = try shell.allocator.dupe(u8, name),
        .existed = existed != null,
        .value = try shell.allocator.dupe(u8, existed orelse ""),
    });
    return true;
}

// Number of positional parameters ($#), 0 if unset.
fn positionalCount(shell: *Shell) usize {
    const c = shell.variables.get("#") orelse return 0;
    return std.fmt.parseInt(usize, c, 10) catch 0;
}

// True if a double-quoted node is exactly "$@" (which expands to one field per
// positional parameter, unlike "$*" which joins them into a single field).
fn isQuotedAtParam(v: []const u8) bool {
    return std.mem.eql(u8, v, "$@") or std.mem.eql(u8, v, "${@}");
}

// If v is exactly "${NAME[@]}" — a quoted array-all expansion, which expands to
// one field per element — return NAME; else null. "${NAME[*]}" joins into a
// single field, so it is intentionally excluded here.
fn quotedArrayAll(v: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, v, "${") or !std.mem.endsWith(u8, v, "[@]}")) return null;
    const name = v[2 .. v.len - 4];
    if (name.len == 0) return null;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return null;
    }
    return name;
}

// Append every element of array `name` as its own field (for "${a[@]}").
fn appendQuotedArrayFields(shell: *Shell, name: []const u8, out: *std.ArrayList([:0]const u8)) !void {
    const len = shell.getArrayLen(name) orelse 0;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const elem = shell.getArrayElement(name, i) orelse "";
        try out.append(shell.allocator, try shell.allocator.dupeZ(u8, elem));
    }
}

// Remove positional parameters $1..$99 (freeing their storage).
fn clearPositionals(shell: *Shell) void {
    var i: usize = 1;
    while (i <= 99) : (i += 1) {
        var nb: [16]u8 = undefined;
        const ns = std.fmt.bufPrint(&nb, "{d}", .{i}) catch break;
        if (shell.variables.fetchRemove(ns)) |kv| {
            shell.allocator.free(kv.key);
            shell.allocator.free(kv.value);
        } else break;
    }
}

// Set $1..$n and $# from a slice of arguments.
fn setPositionals(shell: *Shell, args: []const []const u8) !void {
    for (args, 1..) |arg, i| {
        var nb: [16]u8 = undefined;
        const ns = std.fmt.bufPrint(&nb, "{d}", .{i}) catch continue;
        try setShellVar(shell, ns, arg);
    }
    var cb: [16]u8 = undefined;
    const cs = std.fmt.bufPrint(&cb, "{d}", .{args.len}) catch "0";
    try setShellVar(shell, "#", cs);
}

// Save the caller's $1..$# into `out` (dupes; caller frees). One owner for the
// "install my own positionals, restore the caller's on return" pattern shared by
// callFunction and `source`.
pub fn savePositionals(shell: *Shell, out: *std.ArrayList([]u8)) !void {
    const count = positionalCount(shell);
    var i: usize = 1;
    while (i <= count) : (i += 1) {
        var nb: [16]u8 = undefined;
        const ns = std.fmt.bufPrint(&nb, "{d}", .{i}) catch break;
        const v = shell.variables.get(ns) orelse "";
        try out.append(shell.allocator, try shell.allocator.dupe(u8, v));
    }
}

// Restore positionals previously captured by savePositionals.
pub fn restorePositionals(shell: *Shell, saved: []const []u8) void {
    clearPositionals(shell);
    if (saved.len > 0) {
        setPositionals(shell, saved) catch {};
    } else {
        setShellVar(shell, "#", "0") catch {};
    }
}

// Install `args` as $1..$n / $# for the duration of a sourced script or function
// body, having saved the caller's set. Callers pair this with restorePositionals.
pub fn installPositionals(shell: *Shell, args: []const []const u8) !void {
    clearPositionals(shell);
    try setPositionals(shell, args);
}

pub fn callFunction(shell: *Shell, name: []const u8, args: []const []const u8) !u8 {
    const body = shell.functions.get(name) orelse return error.FunctionNotFound;

    // A function gets its own $1..$#, restored on return (POSIX).
    var saved: std.ArrayList([]u8) = .empty;
    defer {
        for (saved.items) |s| shell.allocator.free(s);
        saved.deinit(shell.allocator);
    }
    try savePositionals(shell, &saved);
    try installPositionals(shell, args);

    // Give the body its own local-variable scope (restored on return).
    try pushLocalScope(shell);
    defer popLocalScope(shell);

    const result = evaluateAst(shell, body);

    restorePositionals(shell, saved.items);
    return result;
}

// Buffer-based escape sequence writer for the echo fast path. Decodes via the
// single shared decoder (builtins.parseEscape, echo dialect) so the fast path
// and the echo builtin can never disagree. `stopped` = a \c was hit, which in
// bash suppresses all further output including the trailing newline.
const EscapedWrite = struct { len: usize, stopped: bool };

fn writeEscapedToBuf(input: []const u8, buf: []u8) EscapedWrite {
    var out_pos: usize = 0;
    var i: usize = 0;

    while (i < input.len and out_pos < buf.len) {
        if (input[i] == '\\') {
            const esc = builtins.parseEscape(input[i + 1 ..], .echo);
            if (esc.stop) return .{ .len = out_pos, .stopped = true };
            buf[out_pos] = esc.char;
            out_pos += 1;
            i += 1 + esc.len;
        } else {
            buf[out_pos] = input[i];
            out_pos += 1;
            i += 1;
        }
    }

    return .{ .len = out_pos, .stopped = false };
}

// ============================================================================
// feat — python-replacement feats.
// A feat is a standalone static binary zish execs (no plugin ABI). The tier is
// the trust model: standard (shipped, exec'd) vs extra (untrusted, exec'd with
// a stripped env and never as root).
// ============================================================================

const FeatTier = enum { standard, extra };
const FEAT_TIER_NAMES = [_][]const u8{ "standard", "extra" };

fn featRoot(alloc: std.mem.Allocator, buf: []u8) ?[]const u8 {
    if (compat.getEnvVarOwned(alloc, "ZISH_FEAT_PATH")) |p| {
        defer alloc.free(p);
        if (p.len < buf.len) {
            @memcpy(buf[0..p.len], p);
            return buf[0..p.len];
        }
        return null;
    } else |_| {}
    const home = compat.getEnvVarOwned(alloc, "HOME") catch return null;
    defer alloc.free(home);
    return std.fmt.bufPrint(buf, "{s}/.zish/feats", .{home}) catch null;
}

/// Terse, hostile-input manifest field: returns the value of `key = "value"`
/// on its own line, or null. Unknown fields are ignored (never parsed).
fn featManifestField(content: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, key)) continue;
        const after_key = line[key.len..];
        const eq_rel = std.mem.indexOfScalar(u8, after_key, '=') orelse continue;
        // allow whitespace around '=' (TOML: key = "value")
        if (std.mem.trim(u8, after_key[0..eq_rel], " \t").len != 0) continue;
        const rest = std.mem.trim(u8, after_key[eq_rel + 1 ..], " \t");
        if (rest.len < 2 or rest[0] != '"') continue;
        const end = std.mem.indexOfScalar(u8, rest[1..], '"') orelse continue;
        return rest[1 .. end + 1];
    }
    return null;
}

/// Parse a feat reference (name, or tier/name). Rejects traversal and any
/// extra path segments. tier is null when not specified (resolve standard then
/// extra).
fn featParseRef(raw: []const u8) ?struct { tier: ?FeatTier, name: []const u8 } {
    if (raw.len == 0 or std.mem.indexOf(u8, raw, "..") != null) return null;
    if (std.mem.indexOfScalar(u8, raw, '/')) |slash| {
        const tier_s = raw[0..slash];
        const name = raw[slash + 1 ..];
        if (name.len == 0) return null;
        if (std.mem.indexOfScalar(u8, name, '/') != null) return null;
        const tier: FeatTier = if (std.mem.eql(u8, tier_s, "standard"))
            .standard
        else if (std.mem.eql(u8, tier_s, "extra"))
            .extra
        else
            return null;
        return .{ .tier = tier, .name = name };
    }
    return .{ .tier = null, .name = raw };
}

/// Resolve a feat reference to an absolute executable path + tier, or null.
fn featResolve(alloc: std.mem.Allocator, raw: []const u8) ?struct { tier: FeatTier, bin: []u8 } {
    const parsed = featParseRef(raw) orelse return null;

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = featRoot(alloc, &root_buf) orelse return null;

    var candidates: [2]FeatTier = undefined;
    var ncand: usize = 0;
    if (parsed.tier) |t| {
        candidates[ncand] = t;
        ncand += 1;
    } else {
        candidates[0] = .standard;
        candidates[1] = .extra;
        ncand = 2;
    }

    var k: usize = 0;
    while (k < ncand) : (k += 1) {
        const tier = candidates[k];
        const tier_name = if (tier == .standard) "standard" else "extra";

        var tier_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tier_dir = std.fmt.bufPrint(&tier_buf, "{s}/{s}", .{ root, tier_name }) catch continue;

        var bin_buf: [std.fs.max_path_bytes]u8 = undefined;
        const bin_path = std.fmt.bufPrint(&bin_buf, "{s}/{s}/bin/{s}", .{ tier_dir, parsed.name, parsed.name }) catch continue;
        // default bin name == feat name; honor an opt-in `bin` manifest field.
        var mf_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const mf_path = std.fmt.bufPrint(&mf_path_buf, "{s}/{s}/feat.toml", .{ tier_dir, parsed.name }) catch continue;
        if (std.Io.Dir.cwd().readFileAlloc(compat.io(), mf_path, alloc, .limited(16 * 1024))) |content| {
            defer alloc.free(content);
            if (featManifestField(content, "bin")) |b| {
                if (b.len > 0 and std.mem.indexOfScalar(u8, b, '/') == null and std.mem.indexOf(u8, b, "..") == null) {
                    const w = std.fmt.bufPrint(&bin_buf, "{s}/{s}/bin/{s}", .{ tier_dir, parsed.name, b }) catch bin_path;
                    _ = w;
                }
            }
        } else |_| {}

        // must exist and be a regular file
        const f = std.Io.Dir.cwd().openFile(compat.io(), bin_path, .{}) catch continue;
        f.close(compat.io());
        return .{ .tier = tier, .bin = alloc.dupe(u8, bin_path) catch return null };
    }
    return null;
}

/// Minimal stripped envp for untrusted `extra` feats: HOME + a shrunk PATH.
/// No other variables leak across the trust boundary.
// NOTE: returned envp strings live for the process lifetime (like
// buildEnvironment): they survive fork and stay valid until exec in the child.
// envp strings + pointer array are process-lifetime (like buildEnvironment): they
// survive fork and stay valid until exec in the child.
fn featStrippedEnv(alloc: std.mem.Allocator, tier_dir: []const u8) ?[*:null]const ?[*:0]const u8 {
    const home = compat.getEnvVarOwned(alloc, "HOME") catch return null;
    const home_s = std.fmt.allocPrint(alloc, "HOME={s}", .{home}) catch return null;
    const home_env = alloc.dupeZ(u8, home_s) catch return null;
    const path_s = std.fmt.allocPrint(alloc, "PATH={s}/bin:/usr/local/bin:/usr/bin:/bin", .{tier_dir}) catch return null;
    const path_env = alloc.dupeZ(u8, path_s) catch return null;

    const envp = alloc.alloc(?[*:0]const u8, 3) catch return null;
    envp[0] = home_env.ptr;
    envp[1] = path_env.ptr;
    envp[2] = null;
    return @ptrCast(envp.ptr);
}

fn featExec(shell: *Shell, tier: FeatTier, bin_path: []const u8, sub_args: []const []const u8) !u8 {
    // null-terminated argv
    if (1 + sub_args.len >= 250) return 1;
    var argv: [250]?[*:0]const u8 = undefined;
    var held: std.ArrayList([:0]u8) = .empty;
    defer held.deinit(shell.allocator);

    const argv0 = try shell.allocator.dupeZ(u8, bin_path);
    try held.append(shell.allocator, argv0);
    argv[0] = argv0.ptr;
    var n: usize = 1;
    for (sub_args) |a| {
        const dz = try shell.allocator.dupeZ(u8, a);
        try held.append(shell.allocator, dz);
        argv[n] = dz.ptr;
        n += 1;
    }
    argv[n] = null;

    const envp = if (tier == .extra)
        featStrippedEnv(shell.allocator, "") orelse @as([*:null]const ?[*:0]const u8, @ptrCast(std.c.environ))
    else
        buildEnvironment(shell) catch @as([*:null]const ?[*:0]const u8, @ptrCast(std.c.environ));

    const argv_ptr: [*:null]const ?[*:0]const u8 = argv[0..n :null];

    // A feat is an external foreground command and gets the same job-control
    // discipline as one (previously it forked with the terminal still in raw
    // mode, in the shell's own process group, with signals ignored, and a
    // non-UNTRACED wait — so a feat prompting on the tty couldn't be Ctrl+C'd
    // and a Ctrl+Z hung the shell).
    var fg_session = foreground.Session.begin(shell);
    defer fg_session.end();

    shell.stdout().flush() catch {};

    const pid = compat.posix.fork() catch {
        try shell.stdout().print("zish: fork failed\n", .{});
        return 1;
    };
    if (pid == 0) {
        // own pgroup + terminal, THEN default signals (Session.setupChild)
        fg_session.setupChild();
        compat.posix.execveZ(argv0.ptr, argv_ptr, envp) catch {
            compat.posix.exit(127);
        };
    }

    // parent: also set child's pgrp (race avoidance), then the owned
    // SIGINT-ignore + UNTRACED wait + decode + reclaim.
    fg_session.registerChild(pid);
    const out = fg_session.reap(pid, bin_path, null);
    return out.code;
}

fn featList(shell: *Shell, alloc: std.mem.Allocator) !u8 {
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = featRoot(alloc, &root_buf) orelse return 1;

    for (FEAT_TIER_NAMES) |tier_name| {
        var tier_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tier_dir = std.fmt.bufPrint(&tier_buf, "{s}/{s}", .{ root, tier_name }) catch continue;
        var dir = std.Io.Dir.cwd().openDir(compat.io(), tier_dir, .{ .iterate = true }) catch continue;
        defer dir.close(compat.io());

        var iter = dir.iterate();
        while (try iter.next(compat.io())) |entry| {
            if (entry.kind != .directory) continue;
            if (entry.name.len == 0 or entry.name[0] == '.') continue;

            var mf_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const mf_path = std.fmt.bufPrint(&mf_path_buf, "{s}/{s}/feat.toml", .{ tier_dir, entry.name }) catch continue;
            const content = std.Io.Dir.cwd().readFileAlloc(compat.io(), mf_path, alloc, .limited(16 * 1024)) catch continue;
            defer alloc.free(content);
            const help = featManifestField(content, "help") orelse "";
            try shell.stdout().print("{s}\t{s}\t{s}\n", .{ tier_name, entry.name, help });
        }
    }
    return 0;
}

fn featHelp(shell: *Shell, alloc: std.mem.Allocator, raw: []const u8) !u8 {
    const resolved = featResolve(alloc, raw) orelse {
        try shell.stdout().writeAll("feat: not found\n");
        return 1;
    };
    defer alloc.free(resolved.bin);

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = featRoot(alloc, &root_buf) orelse return 1;
    const parsed = featParseRef(raw) orelse return 1;
    const tier_name = if (resolved.tier == .standard) "standard" else "extra";
    var mf_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const mf_path = std.fmt.bufPrint(&mf_path_buf, "{s}/{s}/{s}/feat.toml", .{ root, tier_name, parsed.name }) catch return 1;
    const content = std.Io.Dir.cwd().readFileAlloc(compat.io(), mf_path, alloc, .limited(16 * 1024)) catch return 1;
    defer alloc.free(content);
    const help = featManifestField(content, "help") orelse "";
    const usage_str = featManifestField(content, "usage") orelse "";
    try shell.stdout().print("{s}  {s}\n", .{ parsed.name, help });
    if (usage_str.len > 0) try shell.stdout().print("usage: {s}\n", .{usage_str});
    return 0;
}

fn featCmd(shell: *Shell, args: []const []const u8) !u8 {
    const alloc = shell.allocator;
    if (args.len < 2) {
        try shell.stdout().writeAll("feat: usage: feat list | help <name> | run <name> [args...]\n");
        return 2;
    }
    const sub = args[1];
    if (std.mem.eql(u8, sub, "list")) return try featList(shell, alloc);
    if (std.mem.eql(u8, sub, "help")) {
        if (args.len < 3) return 2;
        return try featHelp(shell, alloc, args[2]);
    }
    if (std.mem.eql(u8, sub, "run")) {
        if (args.len < 3) return 2;
        const resolved = featResolve(alloc, args[2]) orelse {
            try shell.stdout().writeAll("feat: not found\n");
            return 127;
        };
        defer alloc.free(resolved.bin);
        // redshiftzero rule: untrusted extra feats never run as root.
        if (resolved.tier == .extra and compat.posix.geteuid() == 0) {
            try shell.stdout().writeAll("feat: refusing to run extra feat as root\n");
            return 126;
        }
        return try featExec(shell, resolved.tier, resolved.bin, args[3..]);
    }
    try shell.stdout().writeAll("feat: unknown subcommand\n");
    return 2;
}
