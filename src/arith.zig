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
pub const SourceError = error{ DivideByZero, OutOfMemory };

pub fn evaluateArithSource(sh: *Shell, expr: []const u8) SourceError!i64 {
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

pub fn evaluateArithmetic(self: *Shell, expr: []const u8) !i64 {
    var p = ArithParser{ .shell = self, .src = expr, .pos = 0 };
    p.skipSpace();
    if (p.pos >= p.src.len) return 0;
    const v = p.parseComma() catch |e| switch (e) {
        error.DivideByZero => return error.DivideByZero,
        else => return 0,
    };
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

    const Error = error{ SyntaxError, DivideByZero, OutOfMemory };

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
        if (self.readIdent()) |name| {
            self.skipSpace();
            const c = self.peek();
            const c2 = self.peek2();
            // plain '=' (but not '==')
            if (c == '=' and c2 != '=') {
                self.pos += 1;
                const rhs = try self.parseAssign();
                try self.storeVar(name, rhs);
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
                const cur = self.readVar(name);
                const res = try applyBinary(op, cur, rhs);
                try self.storeVar(name, res);
                return res;
            }
            if ((c == '<' and c2 == '<' and self.peekN(2) == '=') or
                (c == '>' and c2 == '>' and self.peekN(2) == '='))
            {
                const is_left = c == '<';
                self.pos += 3;
                const rhs = try self.parseAssign();
                const cur = self.readVar(name);
                const res = if (is_left) cur << @intCast(@as(u6, @truncate(@as(u64, @bitCast(rhs)))))
                else cur >> @intCast(@as(u6, @truncate(@as(u64, @bitCast(rhs)))));
                try self.storeVar(name, res);
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
            if (self.peek() != ':') return error.SyntaxError;
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
            const name = self.readIdent() orelse return error.SyntaxError;
            const nv = self.readVar(name) +% 1;
            try self.storeVar(name, nv);
            return nv;
        }
        if (c == '-' and self.peek2() == '-') {
            self.pos += 2;
            self.skipSpace();
            const name = self.readIdent() orelse return error.SyntaxError;
            const nv = self.readVar(name) -% 1;
            try self.storeVar(name, nv);
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
            if (self.peek() != ')') return error.SyntaxError;
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
            const name = self.readIdent() orelse return error.SyntaxError;
            // post-increment / post-decrement
            self.skipSpace();
            if (self.peek() == '+' and self.peek2() == '+') {
                self.pos += 2;
                const old = self.readVar(name);
                try self.storeVar(name, old +% 1);
                return old;
            }
            if (self.peek() == '-' and self.peek2() == '-') {
                self.pos += 2;
                const old = self.readVar(name);
                try self.storeVar(name, old -% 1);
                return old;
            }
            return self.readVar(name);
        }
        return error.SyntaxError;
    }

    fn parseNumber(self: *ArithParser) Error!i64 {
        const start = self.pos;
        // hex / explicit octal 0x / 0 prefix
        if (self.peek() == '0' and (self.peek2() == 'x' or self.peek2() == 'X')) {
            self.pos += 2;
            const ds = self.pos;
            while (self.pos < self.src.len and std.ascii.isHex(self.src[self.pos])) self.pos += 1;
            return std.fmt.parseInt(i64, self.src[ds..self.pos], 16) catch error.SyntaxError;
        }
        // read a run of alphanumerics (covers decimal, octal, and base#digits)
        while (self.pos < self.src.len and (std.ascii.isAlphanumeric(self.src[self.pos]) or self.src[self.pos] == '#')) {
            self.pos += 1;
        }
        const tok = self.src[start..self.pos];
        if (std.mem.indexOfScalar(u8, tok, '#')) |h| {
            const base = std.fmt.parseInt(u8, tok[0..h], 10) catch return error.SyntaxError;
            if (base < 2 or base > 36) return error.SyntaxError;
            return parseInBase(tok[h + 1 ..], base) catch error.SyntaxError;
        }
        if (tok.len > 1 and tok[0] == '0') {
            return std.fmt.parseInt(i64, tok[1..], 8) catch error.SyntaxError;
        }
        return std.fmt.parseInt(i64, tok, 10) catch error.SyntaxError;
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

    fn readVar(self: *ArithParser, name: []const u8) i64 {
        const val = self.shell.variables.get(name) orelse
            (compat.posix.getenv(name) orelse return 0);
        // bash: variable value is itself an arithmetic expression
        return self.shell.evaluateArithmetic(val) catch 0;
    }

    fn storeVar(self: *ArithParser, name: []const u8, value: i64) Error!void {
        var buf: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
        if (self.shell.variables.getPtr(name)) |ptr| {
            self.shell.allocator.free(ptr.*);
            ptr.* = try self.shell.allocator.dupe(u8, s);
        } else {
            const nk = try self.shell.allocator.dupe(u8, name);
            const nv = try self.shell.allocator.dupe(u8, s);
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
        else => error.SyntaxError,
    };
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

fn parseInBase(digits: []const u8, base: u8) !i64 {
    var v: i64 = 0;
    for (digits) |c| {
        const d: i64 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'z' => c - 'a' + 10,
            'A'...'Z' => c - 'A' + 10,
            '@' => 62,
            '_' => 63,
            else => return error.InvalidCharacter,
        };
        if (d >= base) return error.InvalidCharacter;
        v = v * base + d;
    }
    return v;
}
