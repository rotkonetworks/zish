//! expand.zig — variable / parameter / command / arithmetic expansion.
//!
//! The heavy `$`-expansion implementation lifted out of Shell.zig. `allocOpt`
//! walks a word once, handling `$VAR`, `${VAR...}` in all its bash forms
//! (default/alt/assign/error, prefix/suffix strip, pattern replace, substring,
//! case, length, indirect, array), `$(( ))` arithmetic, `$( )` and backtick
//! command substitution, positional params, and tilde prefixes.
//!
//! These are free functions over `*Shell` rather than methods: the shell struct
//! stays the state owner (variables, exit code, arrays, command capture), while
//! the expansion grammar lives here where it can be read as one unit. Shell.zig
//! keeps thin `expandVariables*` wrappers that fast-path the no-expansion case
//! and delegate here. Circular import with Shell.zig is fine (eval.zig already
//! does it) — no comptime type cycle, only function references.

const std = @import("std");
const Shell = @import("Shell.zig");
const compat = @import("compat.zig");
const paramexp = @import("paramexp.zig");
const lexer = @import("lexer.zig");

/// Append the positional parameters ($1, $2, ...) joined by a single space.
/// Used for unquoted $@ and $*; the count is tracked in the "#" variable.
fn appendPositionalParams(sh: *Shell, result: *std.ArrayList(u8)) !void {
    const count_str = sh.variables.get("#") orelse return;
    const count = std.fmt.parseInt(usize, count_str, 10) catch return;
    var idx: usize = 1;
    while (idx <= count) : (idx += 1) {
        var num_buf: [16]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{idx}) catch continue;
        if (sh.variables.get(num_str)) |val| {
            if (idx > 1) try result.append(sh.allocator, ' ');
            try result.appendSlice(sh.allocator, val);
        }
    }
}

// ${@:offset} / ${@:offset:len} — positional params starting at `offset`
// (1-based, like bash: offset 1 is $1), space-joined. `length` limits count.
fn appendPositionalSlice(sh: *Shell, result: *std.ArrayList(u8), offset: usize, length: ?usize) !void {
    const count_str = sh.variables.get("#") orelse return;
    const count = std.fmt.parseInt(usize, count_str, 10) catch return;
    const start = if (offset == 0) 1 else offset;
    const end = if (length) |l| @min(start + l, count + 1) else count + 1;
    var idx: usize = start;
    var emitted: usize = 0;
    while (idx < end and idx <= count) : (idx += 1) {
        var num_buf: [16]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{idx}) catch continue;
        if (sh.variables.get(num_str)) |val| {
            if (emitted > 0) try result.append(sh.allocator, ' ');
            try result.appendSlice(sh.allocator, val);
            emitted += 1;
        }
    }
}

/// Resolve a tilde-prefix name (the text between '~' and the first '/') to a
/// home/directory path. Returns an owned allocation, or null when the prefix
/// is not a recognised tilde form (caller then leaves the '~' literal).
///   ""     -> $HOME
///   "+"    -> $PWD
///   "-"    -> $OLDPWD
///   "user" -> that user's home via getpwnam
fn tildePrefixHome(sh: *Shell, name: []const u8) ?[]u8 {
    if (name.len == 0) {
        const home = compat.getEnvVarOwned(sh.allocator, "HOME") catch return null;
        return home;
    }
    if (name.len == 1 and name[0] == '+') {
        if (getVarValue(sh, "PWD")) |pwd| return sh.allocator.dupe(u8, pwd) catch null;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = compat.posix.getcwd(&buf) catch return null;
        return sh.allocator.dupe(u8, cwd) catch null;
    }
    if (name.len == 1 and name[0] == '-') {
        const old = getVarValue(sh, "OLDPWD") orelse
            (compat.posix.getenv("OLDPWD") orelse return null);
        return sh.allocator.dupe(u8, old) catch null;
    }
    // ~user via getpwnam
    var name_buf: [256]u8 = undefined;
    if (name.len >= name_buf.len) return null;
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;
    const pw = std.c.getpwnam(name_buf[0..name.len :0]) orelse return null;
    const dir = pw.dir orelse return null;
    return sh.allocator.dupe(u8, std.mem.sliceTo(dir, 0)) catch null;
}

fn getVarValue(sh: *Shell, key: []const u8) ?[]const u8 {
    return sh.variables.get(key);
}

/// Expand every `$`/backtick construct in `input`, allocating the result.
/// `expand_tilde` controls whether a leading `~` is treated as a home prefix
/// (false inside double quotes, where bash leaves `~` literal).
pub fn allocOpt(sh: *Shell, input: []const u8, expand_tilde: bool) ![]const u8 {

    // Simple variable expansion - replace $VAR with variable value
    var result = try std.ArrayList(u8).initCapacity(sh.allocator, input.len);
    defer result.deinit(sh.allocator);

    var i: usize = 0;

    // Tilde expansion at start of input: ~ ~/ ~user ~+ ~-
    if (expand_tilde and input.len > 0 and input[0] == '~') {
        // the prefix runs to the first '/' (or end of word)
        const slash = std.mem.indexOfScalar(u8, input, '/') orelse input.len;
        const name = input[1..slash]; // text between '~' and '/'
        if (tildePrefixHome(sh, name)) |home| {
            defer sh.allocator.free(home);
            try result.appendSlice(sh.allocator, home);
            i = slash; // continue after the prefix (keep the '/')
        }
    }

    while (i < input.len) {
        if (input[i] == '$' and i + 1 < input.len) {
            // Found variable expansion
            i += 1; // skip $

            // Handle special single-character variables first
            if (i < input.len and input[i] == '?') {
                var exit_code_buf: [8]u8 = undefined;
                const exit_code_str = std.fmt.bufPrint(&exit_code_buf, "{d}", .{sh.last_exit_code}) catch "0";
                try result.appendSlice(sh.allocator, exit_code_str);
                i += 1; // consume the ?
                continue;
            }

            // $# - number of positional parameters
            if (i < input.len and input[i] == '#') {
                const count = sh.variables.get("#") orelse "0";
                try result.appendSlice(sh.allocator, count);
                i += 1;
                continue;
            }

            // $@ and $* - all positional parameters joined with a space
            if (i < input.len and (input[i] == '@' or input[i] == '*')) {
                try appendPositionalParams(sh, &result);
                i += 1;
                continue;
            }

            // $$ - shell process ID (temp-file idiom: /tmp/foo.$$)
            if (i < input.len and input[i] == '$') {
                var buf: [16]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{compat.posix.getpid()}) catch "0";
                try result.appendSlice(sh.allocator, s);
                i += 1;
                continue;
            }

            // $! - PID of the most recent background command
            if (i < input.len and input[i] == '!') {
                if (sh.last_bg_pid != 0) {
                    var buf: [16]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "{d}", .{sh.last_bg_pid}) catch "";
                    try result.appendSlice(sh.allocator, s);
                }
                i += 1;
                continue;
            }

            // Check for $((arithmetic)) first
            if (i + 1 < input.len and input[i] == '(' and input[i+1] == '(') {
                i += 2; // skip ((
                const expr_start = i;

                // Find matching ))
                var paren_count: u32 = 2;
                while (i < input.len and paren_count > 0) {
                    if (input[i] == '(') {
                        paren_count += 1;
                    } else if (input[i] == ')') {
                        paren_count -= 1;
                        if (paren_count == 0) break;
                    }
                    i += 1;
                }

                if (paren_count == 0) {
                    const expr = input[expr_start..i-1];
                    i += 1; // consume final ) (first one was consumed in loop)

                    // Evaluate arithmetic expression
                    const arith_result = try sh.evaluateArithmetic(expr);
                    var buf: [32]u8 = undefined;
                    const result_str = std.fmt.bufPrint(&buf, "{d}", .{arith_result}) catch "0";
                    try result.appendSlice(sh.allocator, result_str);
                    continue;
                }
            }

            // Handle command substitution $(command)
            if (i < input.len and input[i] == '(') {
                i += 1; // skip (
                const cmd_start = i;

                // Find matching closing paren
                var paren_count: u32 = 1;
                while (i < input.len and paren_count > 0) {
                    switch (input[i]) {
                        '(' => paren_count += 1,
                        ')' => paren_count -= 1,
                        else => {},
                    }
                    if (paren_count > 0) i += 1;
                }

                if (paren_count == 0) {
                    const command = input[cmd_start..i];
                    i += 1; // consume )

                    // Execute command and capture output
                    const cmd_output = sh.executeCommandAndCapture(command) catch "";
                    defer if (cmd_output.len > 0) sh.allocator.free(cmd_output);
                    try result.appendSlice(sh.allocator, std.mem.trimEnd(u8, cmd_output, "\n\r"));
                    continue;
                } else {
                    // Unmatched parens, treat as regular text
                    try result.append(sh.allocator, '$');
                    try result.append(sh.allocator, '(');
                    i = cmd_start;
                    continue;
                }
            }

            // Handle ${VAR} and ${VAR:-default} syntax
            if (i < input.len and input[i] == '{') {
                i += 1; // skip {

                // ${!name} - indirect expansion: the value of `name` names the
                // variable to expand (e.g. ref=v; ${!ref} yields $v).
                if (i < input.len and input[i] == '!') {
                    const after = if (i + 1 < input.len) input[i + 1] else 0;
                    // Only plain ${!name} here; leave ${!} ($!) and the
                    // ${!prefix*}/${!arr[@]} forms to fall through unchanged.
                    if (after != '}' and after != 0) {
                        i += 1; // skip !
                        const ref_start = i;
                        while (i < input.len and input[i] != '}') i += 1;
                        const ref_name = input[ref_start..i];
                        if (i < input.len and input[i] == '}') i += 1;

                        const indirect = sh.variables.get(ref_name) orelse "";
                        if (indirect.len > 0) {
                            if (sh.variables.get(indirect)) |v| {
                                try result.appendSlice(sh.allocator, v);
                            } else if (compat.getEnvVarOwned(sh.allocator, indirect)) |val| {
                                try result.appendSlice(sh.allocator, val);
                                sh.allocator.free(val);
                            } else |_| {}
                        }
                        continue;
                    }
                }

                // Check for ${#VAR} or ${#arr[@]} length expansion
                if (i < input.len and input[i] == '#') {
                    i += 1; // skip #
                    const name_start = i;
                    while (i < input.len and input[i] != '}') {
                        i += 1;
                    }
                    const var_name = input[name_start..i];
                    if (i < input.len and input[i] == '}') i += 1;

                    // ${#} is the positional-parameter count ($#), not a length.
                    if (var_name.len == 0) {
                        const count = sh.variables.get("#") orelse "0";
                        try result.appendSlice(sh.allocator, count);
                        continue;
                    }

                    var var_len: usize = 0;

                    // check for array length: ${#arr[@]} or ${#arr[*]}
                    if (std.mem.endsWith(u8, var_name, "[@]") or std.mem.endsWith(u8, var_name, "[*]")) {
                        const arr_name = var_name[0 .. var_name.len - 3];
                        if (sh.getArrayLen(arr_name)) |len| {
                            var_len = len;
                        }
                    } else if (std.mem.indexOfScalar(u8, var_name, '[')) |bracket_pos| {
                        // ${#arr[n]} - length of element
                        const arr_name = var_name[0..bracket_pos];
                        if (std.mem.indexOfScalar(u8, var_name[bracket_pos..], ']')) |close_offset| {
                            const index_str = var_name[bracket_pos + 1 .. bracket_pos + close_offset];
                            const idx = std.fmt.parseInt(usize, index_str, 10) catch 0;
                            if (sh.getArrayElement(arr_name, idx)) |elem| {
                                var_len = elem.len;
                            }
                        }
                    } else {
                        // regular variable length
                        if (sh.variables.get(var_name)) |value| {
                            var_len = value.len;
                        } else if (compat.getEnvVarOwned(sh.allocator, var_name)) |val| {
                            var_len = val.len;
                            sh.allocator.free(val);
                        } else |_| {}
                    }

                    var len_buf: [20]u8 = undefined;
                    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{var_len}) catch "0";
                    try result.appendSlice(sh.allocator, len_str);
                    continue;
                }

                // ${@} and ${*} - all positional parameters
                if (i < input.len and (input[i] == '@' or input[i] == '*')) {
                    i += 1;
                    if (i < input.len and input[i] == '}') {
                        i += 1;
                        try appendPositionalParams(sh, &result);
                        continue;
                    }
                    // ${@:offset} / ${@:offset:len} - positional-parameter slice.
                    if (i < input.len and input[i] == ':') {
                        i += 1;
                        const off_start = i;
                        while (i < input.len and input[i] != '}' and input[i] != ':') i += 1;
                        const off_str = std.mem.trim(u8, input[off_start..i], " ");
                        var length: ?usize = null;
                        if (i < input.len and input[i] == ':') {
                            i += 1;
                            const len_start = i;
                            while (i < input.len and input[i] != '}') i += 1;
                            length = std.fmt.parseInt(usize, std.mem.trim(u8, input[len_start..i], " "), 10) catch null;
                        }
                        if (i < input.len and input[i] == '}') i += 1;
                        const offset = std.fmt.parseInt(usize, off_str, 10) catch 0;
                        try appendPositionalSlice(sh, &result, offset, length);
                        continue;
                    }
                    // Not a plain ${@}/${*}; rewind and fall through.
                    i -= 1;
                }

                const name_start = i;

                // Find end of variable name or modifier.
                // Stop at: } : - + ? = # % / ^ , (but not '[' so array subscripts stay
                // part of the name)
                while (i < input.len and input[i] != '}' and input[i] != ':' and
                    input[i] != '-' and input[i] != '+' and input[i] != '?' and
                    input[i] != '=' and input[i] != '#' and input[i] != '%' and
                    input[i] != '/' and input[i] != '^' and input[i] != ',')
                {
                    i += 1;
                }

                const var_name = input[name_start..i];

                // Look up variable value first (needed for all modifiers)
                var var_value: ?[]const u8 = null;
                var owned_value: ?[]const u8 = null;
                defer if (owned_value) |v| sh.allocator.free(v);

                // check for array expansion: ${arr[@]} or ${arr[*]} or ${arr[n]}
                if (std.mem.endsWith(u8, var_name, "[@]") or std.mem.endsWith(u8, var_name, "[*]")) {
                    // expand all array elements
                    const arr_name = var_name[0 .. var_name.len - 3];
                    if (sh.getArrayAll(arr_name)) |elements| {
                        // skip to closing brace
                        while (i < input.len and input[i] != '}') i += 1;
                        if (i < input.len and input[i] == '}') i += 1;

                        // join elements with spaces
                        for (elements, 0..) |elem, idx| {
                            if (idx > 0) try result.append(sh.allocator, ' ');
                            try result.appendSlice(sh.allocator, elem);
                        }
                        continue;
                    }
                } else if (std.mem.indexOfScalar(u8, var_name, '[')) |bracket_pos| {
                    // array element: ${arr[n]}
                    const arr_name = var_name[0..bracket_pos];
                    if (std.mem.indexOfScalar(u8, var_name[bracket_pos..], ']')) |close_offset| {
                        const index_str = var_name[bracket_pos + 1 .. bracket_pos + close_offset];
                        const idx = std.fmt.parseInt(usize, index_str, 10) catch 0;
                        if (sh.getArrayElement(arr_name, idx)) |elem| {
                            var_value = elem;
                        }
                    }
                } else {
                    // regular scalar variable
                    if (sh.variables.get(var_name)) |value| {
                        var_value = value;
                    } else {
                        const env_value = compat.getEnvVarOwned(sh.allocator, var_name) catch null;
                        if (env_value) |val| {
                            owned_value = val;
                            var_value = val;
                        }
                    }
                }

                // Handle different modifiers
                if (i < input.len and input[i] == '#') {
                    // ${VAR#pattern} or ${VAR##pattern} - remove prefix
                    i += 1;
                    const greedy = i < input.len and input[i] == '#';
                    if (greedy) i += 1;

                    const pattern_start = i;
                    while (i < input.len and input[i] != '}') i += 1;
                    const raw_pattern = input[pattern_start..i];
                    if (i < input.len and input[i] == '}') i += 1;

                    // The pattern may reference variables (${f#$PREFIX}).
                    const pat_expanded = if (std.mem.indexOfScalar(u8, raw_pattern, '$') != null)
                        allocOpt(sh, raw_pattern, false) catch null
                    else
                        null;
                    defer if (pat_expanded) |p| sh.allocator.free(p);
                    const pattern = pat_expanded orelse raw_pattern;

                    if (var_value) |v| {
                        const stripped = paramexp.stripPrefix(v, pattern, greedy);
                        try result.appendSlice(sh.allocator, stripped);
                    }
                } else if (i < input.len and input[i] == '%') {
                    // ${VAR%pattern} or ${VAR%%pattern} - remove suffix
                    i += 1;
                    const greedy = i < input.len and input[i] == '%';
                    if (greedy) i += 1;

                    const pattern_start = i;
                    while (i < input.len and input[i] != '}') i += 1;
                    const raw_pattern = input[pattern_start..i];
                    if (i < input.len and input[i] == '}') i += 1;

                    // The pattern may reference variables (${f%$EXT}).
                    const pat_expanded = if (std.mem.indexOfScalar(u8, raw_pattern, '$') != null)
                        allocOpt(sh, raw_pattern, false) catch null
                    else
                        null;
                    defer if (pat_expanded) |p| sh.allocator.free(p);
                    const pattern = pat_expanded orelse raw_pattern;

                    if (var_value) |v| {
                        const stripped = paramexp.stripSuffix(v, pattern, greedy);
                        try result.appendSlice(sh.allocator, stripped);
                    }
                } else if (i < input.len and input[i] == '/') {
                    // ${VAR/pattern/replacement}   - replace first match
                    // ${VAR//pattern/replacement}  - replace all matches
                    // ${VAR/#pattern/replacement}  - anchor at start
                    // ${VAR/%pattern/replacement}  - anchor at end
                    i += 1;
                    const replace_all = i < input.len and input[i] == '/';
                    if (replace_all) i += 1;

                    var anchor: u8 = 0; // 0 = none, '#' = start, '%' = end
                    if (!replace_all and i < input.len and (input[i] == '#' or input[i] == '%')) {
                        anchor = input[i];
                        i += 1;
                    }

                    const pattern_start = i;
                    while (i < input.len and input[i] != '/' and input[i] != '}') i += 1;
                    const pattern = input[pattern_start..i];

                    var replacement: []const u8 = "";
                    if (i < input.len and input[i] == '/') {
                        i += 1;
                        const repl_start = i;
                        while (i < input.len and input[i] != '}') i += 1;
                        replacement = input[repl_start..i];
                    }
                    if (i < input.len and input[i] == '}') i += 1;

                    if (var_value) |v| {
                        const replaced = try paramexp.patternReplaceAnchored(sh.allocator, v, pattern, replacement, replace_all, anchor);
                        defer sh.allocator.free(replaced);
                        try result.appendSlice(sh.allocator, replaced);
                    }
                } else if (i < input.len and input[i] == ':' and paramexp.isSubstringOffset(input[i + 1 ..])) {
                    // ${VAR:offset} or ${VAR:offset:length} - substring.
                    // Note: ${VAR:-x}, ${VAR:=x}, ${VAR:+x}, ${VAR:?x} are default/alt/assign/error
                    // operators, NOT substring; a negative offset must be written as `${VAR: -n}`
                    // (with a space) or `${VAR:(-n)}`.
                    i += 1;
                    // Skip optional leading whitespace before the offset expression.
                    while (i < input.len and (input[i] == ' ' or input[i] == '\t')) i += 1;
                    const offset = paramexp.parseOffsetExpr(input, &i);

                    var length: ?i64 = null;
                    if (i < input.len and input[i] == ':') {
                        i += 1;
                        while (i < input.len and (input[i] == ' ' or input[i] == '\t')) i += 1;
                        length = paramexp.parseOffsetExpr(input, &i);
                    }
                    if (i < input.len and input[i] == '}') i += 1;

                    if (var_value) |v| {
                        // Handle negative offset (from end).
                        var start: usize = 0;
                        if (offset < 0) {
                            const abs_offset: usize = @intCast(-offset);
                            start = if (abs_offset > v.len) 0 else v.len - abs_offset;
                        } else {
                            start = @min(@as(usize, @intCast(offset)), v.len);
                        }

                        var end = v.len;
                        if (length) |l| {
                            if (l < 0) {
                                // Negative length: offset from end of string.
                                const from_end: usize = @intCast(-l);
                                end = if (from_end > v.len) start else @max(start, v.len - from_end);
                            } else {
                                end = @min(start + @as(usize, @intCast(l)), v.len);
                            }
                        }
                        try result.appendSlice(sh.allocator, v[start..end]);
                    }
                } else if (i < input.len and (input[i] == '^' or input[i] == ',')) {
                    // ${VAR^} ${VAR^^} ${VAR,} ${VAR,,} - case modification (bash).
                    const op = input[i];
                    i += 1;
                    const all = i < input.len and input[i] == op;
                    if (all) i += 1;
                    // Optional pattern (only the pattern's matching chars are converted); we
                    // support the common no-pattern form and treat any pattern as "match all".
                    while (i < input.len and input[i] != '}') i += 1;
                    if (i < input.len and input[i] == '}') i += 1;

                    if (var_value) |v| {
                        const upper = op == '^';
                        if (all) {
                            for (v) |ch| {
                                try result.append(sh.allocator, if (upper) std.ascii.toUpper(ch) else std.ascii.toLower(ch));
                            }
                        } else {
                            for (v, 0..) |ch, idx| {
                                if (idx == 0) {
                                    try result.append(sh.allocator, if (upper) std.ascii.toUpper(ch) else std.ascii.toLower(ch));
                                } else {
                                    try result.append(sh.allocator, ch);
                                }
                            }
                        }
                    }
                } else {
                    // Original modifier handling: ${VAR:-default}, ${VAR:+alt}, ${VAR:?error}
                    var modifier: u8 = 0;
                    var has_colon = false;
                    var default_value: []const u8 = "";

                    if (i < input.len and input[i] == ':') {
                        has_colon = true;
                        i += 1;
                    }

                    if (i < input.len and (input[i] == '-' or input[i] == '+' or input[i] == '?' or input[i] == '=')) {
                        modifier = input[i];
                        i += 1;

                        // Find the default/alternate value up to closing }
                        const val_start = i;
                        var brace_depth: u32 = 1;
                        while (i < input.len and brace_depth > 0) {
                            if (input[i] == '{') brace_depth += 1;
                            if (input[i] == '}') brace_depth -= 1;
                            if (brace_depth > 0) i += 1;
                        }
                        default_value = input[val_start..i];
                    }

                    // Skip closing }
                    if (i < input.len and input[i] == '}') i += 1;

                    // Apply modifier
                    const is_set = var_value != null;
                    const is_empty = if (var_value) |v| v.len == 0 else true;
                    const use_default = if (has_colon) !is_set or is_empty else !is_set;

                    switch (modifier) {
                        '-' => {
                            // ${VAR:-default} or ${VAR-default}
                            if (use_default) {
                                // Recursively expand the default value
                                const expanded_default = try allocOpt(sh, default_value, true);
                                defer sh.allocator.free(expanded_default);
                                try result.appendSlice(sh.allocator, expanded_default);
                            } else if (var_value) |v| {
                                try result.appendSlice(sh.allocator, v);
                            }
                        },
                        '+' => {
                            // ${VAR:+alternate} or ${VAR+alternate}
                            if (!use_default) {
                                const expanded_alt = try allocOpt(sh, default_value, true);
                                defer sh.allocator.free(expanded_alt);
                                try result.appendSlice(sh.allocator, expanded_alt);
                            }
                        },
                        '=' => {
                            // ${VAR:=word} or ${VAR=word} - assign default if unset (or empty w/ colon)
                            if (use_default) {
                                const expanded_default = try allocOpt(sh, default_value, expand_tilde);
                                // Assign to the shell variable, then use it.
                                const name_copy = try sh.allocator.dupe(u8, var_name);
                                if (sh.variables.fetchRemove(name_copy)) |old| {
                                    sh.allocator.free(old.key);
                                    sh.allocator.free(old.value);
                                }
                                sh.variables.put(name_copy, expanded_default) catch {
                                    sh.allocator.free(name_copy);
                                    sh.allocator.free(expanded_default);
                                };
                                try result.appendSlice(sh.allocator, expanded_default);
                            } else if (var_value) |v| {
                                try result.appendSlice(sh.allocator, v);
                            }
                        },
                        '?' => {
                            // ${VAR:?error} or ${VAR?error}
                            if (use_default) {
                                std.debug.print("zish: {s}: {s}\n", .{ var_name, if (default_value.len > 0) default_value else "parameter not set" });
                                return error.ParameterNotSet;
                            } else if (var_value) |v| {
                                try result.appendSlice(sh.allocator, v);
                            }
                        },
                        else => {
                            // No modifier, just ${VAR}
                            if (var_value) |v| {
                                try result.appendSlice(sh.allocator, v);
                            } else if (sh.opt_nounset) {
                                std.debug.print("zish: {s}: unbound variable\n", .{var_name});
                                return error.UnboundVariable;
                            }
                        },
                    }
                }
            } else {
                // Simple $VAR without braces
                const name_start = i;
                // Find end of variable name (alphanumeric + underscore)
                while (i < input.len and (std.ascii.isAlphanumeric(input[i]) or input[i] == '_')) {
                    i += 1;
                }

                if (i > name_start) {
                    const var_name = input[name_start..i];

                    // Look up variable
                    if (sh.variables.get(var_name)) |value| {
                        try result.appendSlice(sh.allocator, value);
                    } else {
                        // Try environment variable
                        const env_value = compat.getEnvVarOwned(sh.allocator, var_name) catch null;
                        if (env_value) |val| {
                            defer sh.allocator.free(val);
                            try result.appendSlice(sh.allocator, val);
                        } else if (sh.opt_nounset) {
                            // nounset: error on unbound variable
                            std.debug.print("zish: {s}: unbound variable\n", .{var_name});
                            return error.UnboundVariable;
                        }
                        // If no variable found and nounset not set, leave empty
                    }
                } else {
                    // Just a lone $, keep it
                    try result.append(sh.allocator, '$');
                }
            }
        } else if (input[i] == '`') {
            // Handle backtick command substitution
            i += 1; // skip `
            const cmd_start = i;

            // Find matching closing backtick
            while (i < input.len and input[i] != '`') {
                i += 1;
            }

            if (i < input.len) {
                const command = input[cmd_start..i];
                i += 1; // consume closing `

                // Execute command and capture output
                const cmd_output = sh.executeCommandAndCapture(command) catch "";
                defer if (cmd_output.len > 0) sh.allocator.free(cmd_output);
                try result.appendSlice(sh.allocator, std.mem.trimEnd(u8, cmd_output, "\n\r"));
            } else {
                // Unmatched backtick, treat as regular text
                try result.append(sh.allocator, '`');
                i = cmd_start;
            }
        } else if (input[i] == lexer.LIT_DOLLAR) {
            // Escaped '$' - emit literally, do not expand.
            try result.append(sh.allocator, '$');
            i += 1;
        } else if (input[i] == lexer.LIT_BACKTICK) {
            // Escaped '`' - emit literally, do not run as command substitution.
            try result.append(sh.allocator, '`');
            i += 1;
        } else {
            try result.append(sh.allocator, input[i]);
            i += 1;
        }
    }

    return try result.toOwnedSlice(sh.allocator);
}
