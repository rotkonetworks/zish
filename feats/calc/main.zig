// calc - arithmetic the shell can't do.
//   calc '2^0.5'          1.4142135623730951
//   calc '(1+2)*3'        9
//   calc 'sqrt(2)/2'      0.7071067811865476
//   echo '1/3' | calc     0.3333333333333333
//
// bash's $(( )) is integer-only: $((3/2)) is 1 and $((2**0.5)) is a syntax
// error. That is why every shell script eventually shells out to bc, awk or
// python. This is that, without a 30ms interpreter start.
//
// Semantics, decided once and documented so they cannot drift:
//   - one numeric type: f64. No integer/float distinction, no promotion rules.
//   - division is real division. 3/2 is 1.5, not 1.
//   - output prints as an integer when the value is exactly integral and fits,
//     so `calc '2*3'` is "6" and not "6.0e0" — the common case reads like the
//     shell's own arithmetic.
//   - errors go to stderr and exit 1. Nothing partial is ever printed, so
//     `x=$(calc ...)` is either a number or empty.
//
// Deliberately not in v1: exact rationals, units, variables, complex numbers.
// Each is a real design commitment; adding one later is easy, removing is not.
const std = @import("std");

const Error = error{ SyntaxError, UnknownName, DivideByZero, Overflow };

const Parser = struct {
    src: []const u8,
    pos: usize = 0,

    fn skipSpace(p: *Parser) void {
        while (p.pos < p.src.len and (p.src[p.pos] == ' ' or p.src[p.pos] == '\t' or
            p.src[p.pos] == '\n' or p.src[p.pos] == '\r')) p.pos += 1;
    }

    fn peek(p: *Parser) u8 {
        return if (p.pos < p.src.len) p.src[p.pos] else 0;
    }

    fn eat(p: *Parser, s: []const u8) bool {
        p.skipSpace();
        if (p.pos + s.len > p.src.len) return false;
        if (!std.mem.eql(u8, p.src[p.pos..][0..s.len], s)) return false;
        p.pos += s.len;
        return true;
    }

    // expr := term (('+' | '-') term)*
    fn parseExpr(p: *Parser) Error!f64 {
        var v = try p.parseTerm();
        while (true) {
            p.skipSpace();
            // Check '-' before '->' style tokens is unnecessary here; only
            // single-character additive operators exist.
            if (p.eat("+")) {
                v += try p.parseTerm();
            } else if (p.eat("-")) {
                v -= try p.parseTerm();
            } else break;
        }
        return v;
    }

    // term := unary (('*' | '/' | '%') unary)*
    fn parseTerm(p: *Parser) Error!f64 {
        var v = try p.parseUnary();
        while (true) {
            p.skipSpace();
            // '**' is exponentiation, handled in parseUnary's operand; do not
            // consume the first '*' of it here.
            if (p.peek() == '*' and p.pos + 1 < p.src.len and p.src[p.pos + 1] == '*') break;
            if (p.eat("*")) {
                v *= try p.parseUnary();
            } else if (p.eat("/")) {
                const d = try p.parseUnary();
                if (d == 0) return Error.DivideByZero;
                v /= d;
            } else if (p.eat("%")) {
                const d = try p.parseUnary();
                if (d == 0) return Error.DivideByZero;
                v = @mod(v, d);
            } else break;
        }
        return v;
    }

    fn parseUnary(p: *Parser) Error!f64 {
        p.skipSpace();
        if (p.eat("-")) return -(try p.parseUnary());
        if (p.eat("+")) return p.parseUnary();
        return p.parsePower();
    }

    // power := primary (('^' | '**') unary)     -- right associative
    fn parsePower(p: *Parser) Error!f64 {
        const base = try p.parsePrimary();
        p.skipSpace();
        if (p.eat("**") or p.eat("^")) {
            const exp = try p.parseUnary();
            return std.math.pow(f64, base, exp);
        }
        return base;
    }

    fn parsePrimary(p: *Parser) Error!f64 {
        p.skipSpace();
        if (p.eat("(")) {
            const v = try p.parseExpr();
            if (!p.eat(")")) return Error.SyntaxError;
            return v;
        }

        const c = p.peek();
        if (std.ascii.isDigit(c) or c == '.') return p.parseNumber();
        if (std.ascii.isAlphabetic(c) or c == '_') return p.parseName();
        return Error.SyntaxError;
    }

    fn parseNumber(p: *Parser) Error!f64 {
        const start = p.pos;
        // 0x / 0b integer literals are worth having: shells deal in masks and
        // permissions constantly.
        if (p.peek() == '0' and p.pos + 1 < p.src.len) {
            const n = p.src[p.pos + 1];
            if (n == 'x' or n == 'X' or n == 'b' or n == 'B') {
                const base: u8 = if (n == 'x' or n == 'X') 16 else 2;
                p.pos += 2;
                const ds = p.pos;
                while (p.pos < p.src.len and std.ascii.isAlphanumeric(p.src[p.pos])) p.pos += 1;
                if (p.pos == ds) return Error.SyntaxError;
                const iv = std.fmt.parseInt(i64, p.src[ds..p.pos], base) catch return Error.SyntaxError;
                return @floatFromInt(iv);
            }
        }
        while (p.pos < p.src.len and (std.ascii.isDigit(p.src[p.pos]) or p.src[p.pos] == '.')) p.pos += 1;
        // exponent form: 1e9, 2.5e-3
        if (p.pos < p.src.len and (p.src[p.pos] == 'e' or p.src[p.pos] == 'E')) {
            const save = p.pos;
            p.pos += 1;
            if (p.pos < p.src.len and (p.src[p.pos] == '+' or p.src[p.pos] == '-')) p.pos += 1;
            if (p.pos < p.src.len and std.ascii.isDigit(p.src[p.pos])) {
                while (p.pos < p.src.len and std.ascii.isDigit(p.src[p.pos])) p.pos += 1;
            } else {
                p.pos = save; // not an exponent after all
            }
        }
        return std.fmt.parseFloat(f64, p.src[start..p.pos]) catch Error.SyntaxError;
    }

    fn parseName(p: *Parser) Error!f64 {
        const start = p.pos;
        while (p.pos < p.src.len and (std.ascii.isAlphanumeric(p.src[p.pos]) or p.src[p.pos] == '_')) p.pos += 1;
        const name = p.src[start..p.pos];

        if (std.mem.eql(u8, name, "pi")) return std.math.pi;
        if (std.mem.eql(u8, name, "e")) return std.math.e;
        if (std.mem.eql(u8, name, "inf")) return std.math.inf(f64);

        // function call
        if (!p.eat("(")) return Error.UnknownName;
        const a = try p.parseExpr();
        // two-argument forms
        if (p.eat(",")) {
            const b = try p.parseExpr();
            if (!p.eat(")")) return Error.SyntaxError;
            if (std.mem.eql(u8, name, "min")) return @min(a, b);
            if (std.mem.eql(u8, name, "max")) return @max(a, b);
            if (std.mem.eql(u8, name, "pow")) return std.math.pow(f64, a, b);
            if (std.mem.eql(u8, name, "atan2")) return std.math.atan2(a, b);
            if (std.mem.eql(u8, name, "log")) {
                if (a <= 0 or b <= 0) return Error.SyntaxError;
                return @log(b) / @log(a); // log(base, x)
            }
            return Error.UnknownName;
        }
        if (!p.eat(")")) return Error.SyntaxError;

        if (std.mem.eql(u8, name, "sqrt")) return @sqrt(a);
        if (std.mem.eql(u8, name, "abs")) return @abs(a);
        if (std.mem.eql(u8, name, "floor")) return @floor(a);
        if (std.mem.eql(u8, name, "ceil")) return @ceil(a);
        if (std.mem.eql(u8, name, "round")) return @round(a);
        if (std.mem.eql(u8, name, "trunc")) return @trunc(a);
        if (std.mem.eql(u8, name, "ln")) return @log(a);
        if (std.mem.eql(u8, name, "log2")) return @log2(a);
        if (std.mem.eql(u8, name, "log10")) return @log10(a);
        if (std.mem.eql(u8, name, "exp")) return @exp(a);
        if (std.mem.eql(u8, name, "sin")) return @sin(a);
        if (std.mem.eql(u8, name, "cos")) return @cos(a);
        if (std.mem.eql(u8, name, "tan")) return @tan(a);
        return Error.UnknownName;
    }
};

pub fn eval(src: []const u8) Error!f64 {
    var p = Parser{ .src = src };
    const v = try p.parseExpr();
    p.skipSpace();
    // Trailing junk is an error, not something to ignore: `calc '2+2 oops'`
    // silently returning 4 is how wrong numbers end up in scripts.
    if (p.pos != p.src.len) return Error.SyntaxError;
    return v;
}

/// Print integral values without a decimal point so the common case reads like
/// shell arithmetic: `calc '2*3'` is "6", not "6e0".
pub fn format(v: f64, buf: []u8) []const u8 {
    if (std.math.isNan(v)) return "nan";
    if (std.math.isInf(v)) return if (v > 0) "inf" else "-inf";
    if (v == @trunc(v) and @abs(v) < 1e15) {
        const i: i64 = @intFromFloat(v);
        return std.fmt.bufPrint(buf, "{d}", .{i}) catch "0";
    }
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch "0";
}

pub fn main(init: std.process.Init) void {
    const alloc = init.gpa;
    const argv = init.minimal.args.toSlice(alloc) catch return;

    var ob: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &ob);

    var expr_buf: [8192]u8 = undefined;
    var expr: []const u8 = undefined;

    if (argv.len > 1) {
        // Join argv so `calc 2 + 3` works as well as `calc '2 + 3'` — the
        // shell will have split on spaces either way.
        var n: usize = 0;
        for (argv[1..], 0..) |a, idx| {
            if (idx > 0 and n < expr_buf.len) {
                expr_buf[n] = ' ';
                n += 1;
            }
            if (n + a.len > expr_buf.len) break;
            @memcpy(expr_buf[n..][0..a.len], a);
            n += a.len;
        }
        expr = expr_buf[0..n];
    } else {
        // Never block on a terminal: an agent running `calc` with no argument
        // should get an error, not a hung process.
        if (std.Io.File.stdin().isTty(init.io) catch false) {
            fail(init, "calc: no expression (stdin is a terminal)");
            return;
        }
        const n = std.posix.read(0, &expr_buf) catch 0;
        expr = std.mem.trim(u8, expr_buf[0..n], " \t\r\n");
    }

    if (expr.len == 0) {
        fail(init, "calc: empty expression");
        return;
    }

    const v = eval(expr) catch |e| {
        fail(init, switch (e) {
            Error.DivideByZero => "calc: division by zero",
            Error.UnknownName => "calc: unknown name or function",
            Error.Overflow => "calc: overflow",
            else => "calc: syntax error",
        });
        return;
    };

    var nb: [64]u8 = undefined;
    w.interface.writeAll(format(v, &nb)) catch {};
    w.interface.writeAll("\n") catch {};
    w.flush() catch {};
}

fn fail(init: std.process.Init, msg: []const u8) void {
    var eb: [256]u8 = undefined;
    var ew = std.Io.File.stderr().writer(init.io, &eb);
    ew.interface.writeAll(msg) catch {};
    ew.interface.writeAll("\n") catch {};
    ew.flush() catch {};
    std.process.exit(1);
}

// ============================================================
// Tests
// ============================================================

fn expectEval(src: []const u8, want: f64) !void {
    const got = try eval(src);
    try std.testing.expectApproxEqAbs(want, got, 1e-12);
}

test "arithmetic bash cannot do" {
    try expectEval("3/2", 1.5);
    try expectEval("2^0.5", std.math.sqrt2);
    try expectEval("1/3", 1.0 / 3.0);
}

test "precedence and associativity" {
    try expectEval("1+2*3", 7);
    try expectEval("(1+2)*3", 9);
    try expectEval("2**3**2", 512); // right associative
    try expectEval("-2^2", -4); // unary minus binds looser than ^
    try expectEval("10-2-3", 5); // left associative
}

test "functions and constants" {
    try expectEval("sqrt(16)", 4);
    try expectEval("min(3,7)", 3);
    try expectEval("max(3,7)", 7);
    try expectEval("log(2,8)", 3);
    try expectEval("floor(2.7)", 2);
    try expectEval("abs(0-5)", 5);
}

test "number forms" {
    try expectEval("0xff", 255);
    try expectEval("0b1010", 10);
    try expectEval("2.5e3", 2500);
    try expectEval(".5", 0.5);
}

test "errors are errors, not wrong answers" {
    try std.testing.expectError(Error.DivideByZero, eval("1/0"));
    try std.testing.expectError(Error.SyntaxError, eval("2+2 oops"));
    try std.testing.expectError(Error.SyntaxError, eval("(1+2"));
    try std.testing.expectError(Error.UnknownName, eval("nope(1)"));
    try std.testing.expectError(Error.SyntaxError, eval("+"));
}

test "integral values print without a decimal point" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("6", format(6.0, &buf));
    try std.testing.expectEqualStrings("-4", format(-4.0, &buf));
    try std.testing.expectEqualStrings("1.5", format(1.5, &buf));
    try std.testing.expectEqualStrings("inf", format(std.math.inf(f64), &buf));
}
