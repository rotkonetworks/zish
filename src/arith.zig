//! arith.zig — integer arithmetic evaluator for `$(( ))`.
//!
//! Extracted from Shell.zig (it never belonged there): a self-contained
//! recursive-descent parser matching bash arithmetic. Its only coupling to the
//! shell is variable read/write and the recursive re-evaluation of a variable's
//! value, all through the passed *Shell.
const std = @import("std");
const compat = @import("compat.zig");
const expand = @import("expand.zig");
const Shell = @import("Shell.zig");

/// Evaluate arithmetic *source text* — `$(( ))`, `(( ))`, `for (( ;; ))`, an
/// array subscript, `x=$(( ))`. POSIX (and bash) expand the text first —
/// parameter expansion, command substitution, arithmetic expansion — and only
/// then parse the result as an expression. The substitution is *textual*:
/// with x="1+2", `$(( $x * 2 ))` is `1+2*2` = 5, not (1+2)*2 = 6. A bare
/// `x` is different: that is a variable reference the parser resolves, and
/// bash re-evaluates its value as an expression, so `$(( x * 2 ))` is 6.
///
/// Doing the expansion in one place is the whole point: every operator-bearing
/// form (`${x:-0}`, `${#x}`, `$(cmd)`, backticks) works everywhere, and the
/// parser below only ever sees numbers and operators.
///
/// Callers that must NOT expand use `evaluateArithmetic` directly: a
/// variable's own value (bash does not re-expand it) and the fuzzer, which
/// stays free of process side effects.
pub const SourceError = error{ ArithSyntax, DivideByZero, ArithRecursion, OutOfMemory };

/// The recursion limit bash uses (EXPR_NEST_MAX). A variable whose value names
/// another variable is evaluated recursively — `a=b; b=a; $(( a ))` recurses
/// forever — and zish *segfaulted* on it: a stack overflow, reachable from any
/// script that reads two variables pointing at each other.
const max_depth: u16 = 1024;

pub fn evaluateArithSource(sh: *Shell, expr: []const u8) SourceError!i64 {
    return evalSource(sh, expr) catch |e| {
        report(sh, expr, e);
        return e;
    };
}

fn evalSource(sh: *Shell, expr: []const u8) SourceError!i64 {
    const needs = std.mem.indexOfScalar(u8, expr, '$') != null or
        std.mem.indexOfScalar(u8, expr, '`') != null or
        std.mem.indexOfScalar(u8, expr, Shell.LIT_DOLLAR) != null or
        std.mem.indexOfScalar(u8, expr, Shell.LIT_BACKTICK) != null;
    if (!needs) return evaluateArithmetic(sh, expr);
    // Explicit error set, not an inferred one: expand.allocOpt evaluates
    // nested `$(( ))` through this function, and two inferred sets referring
    // to each other is a dependency loop.
    const expanded = expand.allocOpt(sh, expr, false) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return 0, // an expansion that failed evaluates to nothing
    };
    defer sh.allocator.free(expanded);
    return evaluateArithmetic(sh, expanded);
}

/// The one place an arithmetic failure is reported. The evaluator itself stays
/// silent — it is also the engine for a variable's own value and for the
/// fuzzer — so a message here means a *user-written* expression failed, and it
/// names the expression the way bash does. Silence was how `$(( ${x:-0} ))`
/// returning 0 went unnoticed through two releases.
fn report(sh: *Shell, expr: []const u8, e: SourceError) void {
    const what = switch (e) {
        error.ArithSyntax => "arithmetic syntax error",
        error.DivideByZero => "division by 0",
        error.ArithRecursion => "expression recursion level exceeded",
        error.OutOfMemory => return,
    };
    const w = sh.stderr();
    w.print("zish: {s}: {s}\n", .{ std.mem.trim(u8, expr, " \t\n"), what }) catch return;
    w.flush() catch {};
}

/// True for an arithmetic failure that `report` has already put on stderr.
/// The shell's outer boundaries use it to fail the command *quietly*: a second
/// "error executing command: error.ArithSyntax" would say nothing the user
/// does not already know, and would not name the expression.
pub fn reported(e: anyerror) bool {
    return e == error.ArithSyntax or e == error.DivideByZero or e == error.ArithRecursion;
}

/// Evaluate an expression that has already been expanded. Silent by design:
/// see `report`. Every caller either reports through `evaluateArithSource` or
/// is deliberately quiet (readVar, the fuzzer).
pub fn evaluateArithmetic(self: *Shell, expr: []const u8) SourceError!i64 {
    if (self.arith_depth >= max_depth) return error.ArithRecursion;
    self.arith_depth += 1;
    defer self.arith_depth -= 1;

    var p = ArithParser{ .shell = self, .src = expr, .pos = 0 };
    p.skipSpace();
    if (p.pos >= p.src.len) return 0;
    const v = try p.parseComma();
    p.skipSpace();
    // Trailing junk is a syntax error, not a silently truncated expression:
    // `$(( 1 2 ))` and `$(( 1 + ))` must both be loud.
    if (p.pos < p.src.len) return error.ArithSyntax;
    return v;
}

/// Recursive-descent integer arithmetic evaluator matching bash `$(( ))`
/// semantics: full C-style operator set and precedence, assignment (writes
/// back into shell variables), pre/post inc-dec, ternary, comma, and number
/// bases (0x.., 0.. octal, base#n). Bare identifiers resolve to shell
/// variables (recursively evaluated, undefined -> 0).
const ArithParser = struct {
    shell: *Shell,
    src: []const u8,
    pos: usize,

    const Error = SourceError;

    fn skipSpace(self: *ArithParser) void {
        while (self.pos < self.src.len and (self.src[self.pos] == ' ' or
            self.src[self.pos] == '\t' or self.src[self.pos] == '\n' or
            self.src[self.pos] == '\r')) self.pos += 1;
    }

    fn peek(self: *ArithParser) u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else 0;
    }
    fn peek2(self: *ArithParser) u8 {
        return if (self.pos + 1 < self.src.len) self.src[self.pos + 1] else 0;
    }

    // returns true and consumes if the next non-space chars match `s`
    fn eat(self: *ArithParser, s: []const u8) bool {
        self.skipSpace();
        if (self.pos + s.len <= self.src.len and std.mem.eql(u8, self.src[self.pos .. self.pos + s.len], s)) {
            self.pos += s.len;
            return true;
        }
        return false;
    }

    // level 0: comma operator (lowest precedence)
    fn parseComma(self: *ArithParser) Error!i64 {
        var v = try self.parseAssign();
        while (true) {
            self.skipSpace();
            if (self.peek() == ',') {
                self.pos += 1;
                v = try self.parseAssign();
            } else break;
        }
        return v;
    }

    // level 1: assignment (right-assoc). Detect an lvalue followed by an
    // assignment operator; otherwise fall through to ternary.
    fn parseAssign(self: *ArithParser) Error!i64 {
        const save = self.pos;
        self.skipSpace();
        const name_start = self.pos;
        if (try self.readLValue()) |lv| {
            self.skipSpace();
            const c = self.peek();
            const c2 = self.peek2();
            // plain '=' (but not '==')
            if (c == '=' and c2 != '=') {
                self.pos += 1;
                const rhs = try self.parseAssign();
                try self.storeVar(lv, rhs);
                return rhs;
            }
            // compound: += -= *= /= %= &= |= ^= <<= >>=
            const compound: ?u8 = switch (c) {
                '+', '-', '*', '/', '%', '&', '|', '^' => if (c2 == '=') c else null,
                else => null,
            };
            if (compound) |op| {
                self.pos += 2;
                const rhs = try self.parseAssign();
                const cur = try self.readVar(lv);
                const res = try applyBinary(op, cur, rhs);
                try self.storeVar(lv, res);
                return res;
            }
            if ((c == '<' and c2 == '<' and self.peekN(2) == '=') or
                (c == '>' and c2 == '>' and self.peekN(2) == '='))
            {
                const is_left = c == '<';
                self.pos += 3;
                const rhs = try self.parseAssign();
                const cur = try self.readVar(lv);
                const res = if (is_left) cur << @intCast(@as(u6, @truncate(@as(u64, @bitCast(rhs)))))
                else cur >> @intCast(@as(u6, @truncate(@as(u64, @bitCast(rhs)))));
                try self.storeVar(lv, res);
                return res;
            }
            _ = name_start;
        }
        // not an assignment — rewind and parse a ternary
        self.pos = save;
        return self.parseTernary();
    }

    fn peekN(self: *ArithParser, n: usize) u8 {
        return if (self.pos + n < self.src.len) self.src[self.pos + n] else 0;
    }

    // level 2: ternary ?:
    fn parseTernary(self: *ArithParser) Error!i64 {
        const cond = try self.parseLogicalOr();
        self.skipSpace();
        if (self.peek() == '?') {
            self.pos += 1;
            const then_v = try self.parseAssign();
            self.skipSpace();
            if (self.peek() != ':') return error.ArithSyntax;
            self.pos += 1;
            const else_v = try self.parseAssign();
            return if (cond != 0) then_v else else_v;
        }
        return cond;
    }

    fn parseLogicalOr(self: *ArithParser) Error!i64 {
        var v = try self.parseLogicalAnd();
        while (self.eat("||")) {
            const r = try self.parseLogicalAnd();
            v = if (v != 0 or r != 0) 1 else 0;
        }
        return v;
    }
    fn parseLogicalAnd(self: *ArithParser) Error!i64 {
        var v = try self.parseBitOr();
        while (self.eat("&&")) {
            const r = try self.parseBitOr();
            v = if (v != 0 and r != 0) 1 else 0;
        }
        return v;
    }
    fn parseBitOr(self: *ArithParser) Error!i64 {
        var v = try self.parseBitXor();
        while (true) {
            self.skipSpace();
            if (self.peek() == '|' and self.peek2() != '|') {
                self.pos += 1;
                v |= try self.parseBitXor();
            } else break;
        }
        return v;
    }
    fn parseBitXor(self: *ArithParser) Error!i64 {
        var v = try self.parseBitAnd();
        while (true) {
            self.skipSpace();
            if (self.peek() == '^') {
                self.pos += 1;
                v ^= try self.parseBitAnd();
            } else break;
        }
        return v;
    }
    fn parseBitAnd(self: *ArithParser) Error!i64 {
        var v = try self.parseEquality();
        while (true) {
            self.skipSpace();
            if (self.peek() == '&' and self.peek2() != '&') {
                self.pos += 1;
                v &= try self.parseEquality();
            } else break;
        }
        return v;
    }
    fn parseEquality(self: *ArithParser) Error!i64 {
        var v = try self.parseRelational();
        while (true) {
            if (self.eat("==")) {
                v = if (v == try self.parseRelational()) 1 else 0;
            } else if (self.eat("!=")) {
                v = if (v != try self.parseRelational()) 1 else 0;
            } else break;
        }
        return v;
    }
    fn parseRelational(self: *ArithParser) Error!i64 {
        var v = try self.parseShift();
        while (true) {
            if (self.eat("<=")) {
                v = if (v <= try self.parseShift()) 1 else 0;
            } else if (self.eat(">=")) {
                v = if (v >= try self.parseShift()) 1 else 0;
            } else if (self.peek() == '<' and self.peek2() != '<') {
                self.pos += 1;
                v = if (v < try self.parseShift()) 1 else 0;
            } else if (self.peek() == '>' and self.peek2() != '>') {
                self.pos += 1;
                v = if (v > try self.parseShift()) 1 else 0;
            } else break;
        }
        return v;
    }
    fn parseShift(self: *ArithParser) Error!i64 {
        var v = try self.parseAdditive();
        while (true) {
            if (self.eat("<<")) {
                const r = try self.parseAdditive();
                v <<= @intCast(@as(u6, @truncate(@as(u64, @bitCast(r)))));
            } else if (self.eat(">>")) {
                const r = try self.parseAdditive();
                v >>= @intCast(@as(u6, @truncate(@as(u64, @bitCast(r)))));
            } else break;
        }
        return v;
    }
    fn parseAdditive(self: *ArithParser) Error!i64 {
        var v = try self.parseMultiplicative();
        while (true) {
            self.skipSpace();
            const c = self.peek();
            if (c == '+' and self.peek2() != '+') {
                self.pos += 1;
                v +%= try self.parseMultiplicative();
            } else if (c == '-' and self.peek2() != '-') {
                self.pos += 1;
                v -%= try self.parseMultiplicative();
            } else break;
        }
        return v;
    }
    fn parseMultiplicative(self: *ArithParser) Error!i64 {
        var v = try self.parsePower();
        while (true) {
            self.skipSpace();
            const c = self.peek();
            if (c == '*' and self.peek2() != '*') {
                self.pos += 1;
                v *%= try self.parsePower();
            } else if (c == '/') {
                self.pos += 1;
                const r = try self.parsePower();
                if (r == 0) return error.DivideByZero;
                // minInt / -1 has no representable quotient. @divTrunc is
                // illegal behaviour there — a panic under safety checks and
                // silent corruption in ReleaseFast — so wrap like bash does.
                // Every other operator here already wraps (+%, -%, *%).
                v = if (v == std.math.minInt(i64) and r == -1) v else @divTrunc(v, r);
            } else if (c == '%') {
                self.pos += 1;
                const r = try self.parsePower();
                if (r == 0) return error.DivideByZero;
                // Same overflow case; the mathematical remainder is 0.
                v = if (v == std.math.minInt(i64) and r == -1) 0 else @rem(v, r);
            } else break;
        }
        return v;
    }
    // exponentiation (right-assoc, higher than unary in bash)
    fn parsePower(self: *ArithParser) Error!i64 {
        const base = try self.parseUnary();
        if (self.eat("**")) {
            const exp = try self.parsePower();
            return ipow(base, exp);
        }
        return base;
    }
    fn parseUnary(self: *ArithParser) Error!i64 {
        self.skipSpace();
        const c = self.peek();
        if (c == '+' and self.peek2() != '+') {
            self.pos += 1;
            return self.parseUnary();
        }
        if (c == '-' and self.peek2() != '-') {
            self.pos += 1;
            return -%(try self.parseUnary());
        }
        if (c == '!') {
            self.pos += 1;
            return if ((try self.parseUnary()) == 0) 1 else 0;
        }
        if (c == '~') {
            self.pos += 1;
            return ~(try self.parseUnary());
        }
        // pre-increment / pre-decrement
        if (c == '+' and self.peek2() == '+') {
            self.pos += 2;
            self.skipSpace();
            const lv = (try self.readLValue()) orelse return error.ArithSyntax;
            const nv = try self.readVar(lv) +% 1;
            try self.storeVar(lv, nv);
            return nv;
        }
        if (c == '-' and self.peek2() == '-') {
            self.pos += 2;
            self.skipSpace();
            const lv = (try self.readLValue()) orelse return error.ArithSyntax;
            const nv = try self.readVar(lv) -% 1;
            try self.storeVar(lv, nv);
            return nv;
        }
        return self.parsePrimary();
    }
    fn parsePrimary(self: *ArithParser) Error!i64 {
        self.skipSpace();
        const c = self.peek();
        if (c == '(') {
            self.pos += 1;
            const v = try self.parseComma();
            self.skipSpace();
            if (self.peek() != ')') return error.ArithSyntax;
            self.pos += 1;
            return v;
        }
        if (std.ascii.isDigit(c)) {
            return self.parseNumber();
        }
        // No `$` or backtick can appear here. Arithmetic *source text* is
        // expanded before it is parsed (evaluateArithSource above), which is
        // what bash does and what makes `${x:-0}`, `${#x}`, `$(cmd)` and
        // adjacent expansions (`${x}${x}` is one number) work. A `$` reaching
        // the parser means a caller passed raw source text: that is a syntax
        // error, not a second, half-built expander living down here.
        if (std.ascii.isAlphabetic(c) or c == '_') {
            const lv = (try self.readLValue()) orelse return error.ArithSyntax;
            // post-increment / post-decrement
            self.skipSpace();
            if (self.peek() == '+' and self.peek2() == '+') {
                self.pos += 2;
                const old = try self.readVar(lv);
                try self.storeVar(lv, old +% 1);
                return old;
            }
            if (self.peek() == '-' and self.peek2() == '-') {
                self.pos += 2;
                const old = try self.readVar(lv);
                try self.storeVar(lv, old -% 1);
                return old;
            }
            return self.readVar(lv);
        }
        return error.ArithSyntax;
    }

    fn parseNumber(self: *ArithParser) Error!i64 {
        const start = self.pos;
        // hex / explicit octal 0x / 0 prefix
        if (self.peek() == '0' and (self.peek2() == 'x' or self.peek2() == 'X')) {
            self.pos += 2;
            const ds = self.pos;
            while (self.pos < self.src.len and std.ascii.isHex(self.src[self.pos])) self.pos += 1;
            return parseDigits(self.src[ds..self.pos], 16);
        }
        // read a run of alphanumerics (covers decimal, octal, and base#digits)
        // '@' and '_' are digits 62 and 63 in a base-64 literal, so they are
        // part of the token — everywhere else they fail the digit check below.
        while (self.pos < self.src.len and (std.ascii.isAlphanumeric(self.src[self.pos]) or
            self.src[self.pos] == '#' or self.src[self.pos] == '@' or self.src[self.pos] == '_'))
        {
            self.pos += 1;
        }
        const tok = self.src[start..self.pos];
        if (std.mem.indexOfScalar(u8, tok, '#')) |h| {
            const base = std.fmt.parseInt(u8, tok[0..h], 10) catch return error.ArithSyntax;
            // bash allows up to base 64, where '@' is 62 and '_' is 63.
            if (base < 2 or base > 64) return error.ArithSyntax;
            return parseDigits(tok[h + 1 ..], base);
        }
        if (tok.len > 1 and tok[0] == '0') {
            return parseDigits(tok[1..], 8);
        }
        return parseDigits(tok, 10);
    }

    fn readIdent(self: *ArithParser) ?[]const u8 {
        self.skipSpace();
        const start = self.pos;
        if (self.pos >= self.src.len) return null;
        if (!(std.ascii.isAlphabetic(self.src[self.pos]) or self.src[self.pos] == '_')) return null;
        self.pos += 1;
        while (self.pos < self.src.len and (std.ascii.isAlphanumeric(self.src[self.pos]) or self.src[self.pos] == '_')) {
            self.pos += 1;
        }
        return self.src[start..self.pos];
    }

    /// What an assignment, an increment or a plain read names: a variable, or
    /// one element of an array. `a`, `a[0]`, `a[i+1]` are the same concept with
    /// and without a subscript, so they are one type here — otherwise every
    /// operator (`=`, `+=`, `++`, a bare read) grows its own array special case.
    const LValue = struct {
        name: []const u8,
        index: ?i64 = null,
    };

    /// An identifier, plus a subscript if one follows. The subscript is a full
    /// arithmetic expression (bash), and any `$` inside it was already expanded
    /// by evaluateArithSource, so parseComma is all that is needed.
    fn readLValue(self: *ArithParser) Error!?LValue {
        const name = self.readIdent() orelse return null;
        if (self.peek() != '[') return LValue{ .name = name };
        self.pos += 1;
        const idx = try self.parseComma();
        self.skipSpace();
        if (self.peek() != ']') return error.ArithSyntax;
        self.pos += 1;
        return LValue{ .name = name, .index = idx };
    }

    /// bash: a negative subscript counts from the end (`a[-1]` is the last
    /// element). Out of range in either direction is an unset element, not an
    /// error, and unset is 0 in arithmetic.
    fn resolveIndex(self: *ArithParser, name: []const u8, idx: i64) ?usize {
        if (idx >= 0) return @intCast(idx);
        const len = self.shell.getArrayLen(name) orelse return null;
        const from_end = @as(i64, @intCast(len)) + idx;
        if (from_end < 0) return null;
        return @intCast(from_end);
    }

    /// A variable's value is itself an arithmetic expression (bash), so this
    /// recurses — and an error from down there is the user's error, not a 0.
    /// `a=b; b=a` recurses until `max_depth` stops it.
    fn readVar(self: *ArithParser, lv: LValue) Error!i64 {
        const val = blk: {
            if (lv.index) |idx| {
                const i = self.resolveIndex(lv.name, idx) orelse return 0;
                // A scalar is its own element 0 in bash (`x=5; $(( x[0] ))`).
                break :blk self.shell.getArrayElement(lv.name, i) orelse
                    (if (i == 0) self.shell.variables.get(lv.name) orelse return 0 else return 0);
            }
            break :blk self.shell.variables.get(lv.name) orelse
                (compat.posix.getenv(lv.name) orelse return 0);
        };
        return self.shell.evaluateArithmetic(val);
    }

    fn storeVar(self: *ArithParser, lv: LValue, value: i64) Error!void {
        var buf: [24]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
        if (lv.index) |idx| {
            const i = self.resolveIndex(lv.name, idx) orelse return error.ArithSyntax;
            try self.shell.setArrayElement(lv.name, i, str);
            return;
        }
        if (self.shell.variables.getPtr(lv.name)) |ptr| {
            self.shell.allocator.free(ptr.*);
            ptr.* = try self.shell.allocator.dupe(u8, str);
        } else {
            const nk = try self.shell.allocator.dupe(u8, lv.name);
            const nv = try self.shell.allocator.dupe(u8, str);
            try self.shell.variables.put(nk, nv);
        }
    }
};

fn applyBinary(op: u8, a: i64, b: i64) ArithParser.Error!i64 {
    return switch (op) {
        '+' => a +% b,
        '-' => a -% b,
        '*' => a *% b,
        '/' => if (b == 0) error.DivideByZero else @divTrunc(a, b),
        '%' => if (b == 0) error.DivideByZero else @rem(a, b),
        '&' => a & b,
        '|' => a | b,
        '^' => a ^ b,
        else => error.ArithSyntax,
    };
}

/// Parse a literal's digits the way bash does: accumulate in 64 unsigned bits,
/// wrapping, then reinterpret. Two reasons, both reachable from a script:
///
///  - `9223372036854775808` is INT_MIN, not an error. INT_MIN's own decimal
///    text is written back into a variable and re-read as an expression
///    (`x=$(( -9223372036854775807 - 1 )); $(( x / -1 ))`), and parsing that as
///    a signed i64 fails. Every operator here already wraps; the literal must.
///  - An over-long literal (`36#zzzzzzzzzzzzzzzz`, `18446744073709551616`) is
///    a wrapped value in bash. With a checked `v * base + d` it was an integer
///    overflow *panic* — a ReleaseSafe abort from a line of arithmetic.
fn parseDigits(digits: []const u8, base: u8) ArithParser.Error!i64 {
    if (digits.len == 0) return error.ArithSyntax;
    var v: u64 = 0;
    for (digits) |c| {
        // Case matters only above base 36, where bash runs out of letters:
        // up to 36 the two cases are the same digit, above it lowercase is
        // 10-35 and uppercase continues at 36-61, then '@' and '_'.
        const d: u64 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'z' => c - 'a' + 10,
            'A'...'Z' => if (base <= 36) c - 'A' + 10 else c - 'A' + 36,
            '@' => 62,
            '_' => 63,
            else => return error.ArithSyntax,
        };
        if (d >= base) return error.ArithSyntax;
        v = v *% base +% d;
    }
    return @bitCast(v);
}

fn ipow(base: i64, exp: i64) i64 {
    if (exp < 0) return 0; // integer arithmetic: negative exponent -> 0
    var result: i64 = 1;
    var b = base;
    var e = exp;
    while (e > 0) : (e >>= 1) {
        if (e & 1 == 1) result *%= b;
        b *%= b;
    }
    return result;
}

