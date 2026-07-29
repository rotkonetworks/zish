// lexer.zig - flat state machine lexer for zish
// Design: one loop, one switch, explicit state transitions

const std = @import("std");
const types = @import("types.zig");

// Sentinel bytes for backslash-escaped characters that must survive expansion as
// literals. The expander converts these back to '$' / '`' in its output and never
// treats them as expansion triggers. Chosen from the control range so they cannot
// appear in normal shell input (validateShellSafe rejects raw control bytes).
pub const LIT_DOLLAR: u8 = 0x01;
pub const LIT_BACKTICK: u8 = 0x02;

pub const TokenType = enum {
    Word,
    String,              // quoted string content (for highlighting)
    DoubleQuotedString,  // double-quoted content

    // operators
    Pipe,           // |
    And,            // &&
    Or,             // ||
    Background,     // &
    Semicolon,      // ;
    DoubleSemi,     // ;;
    NewLine,        // \n

    // redirects
    RedirectInput,       // <
    RedirectOutput,      // >
    RedirectAppend,      // >>
    RedirectHereDoc,     // <<<
    RedirectHereDocLiteral, // <<
    RedirectStderr,      // 2>
    RedirectStderrAppend, // 2>>
    RedirectBoth,        // 2>&1
    RedirectToStderr,    // >&2
    RedirectAll,         // &>
    RedirectAllAppend,   // &>>
    RedirectFd,          // generic: n>, n>>, n<, n>&m, n<&m, n>&-, >|, >&word

    // process substitution
    ProcessSubstIn,      // <(
    ProcessSubstOut,     // >(

    // grouping
    LeftParen,      // (
    RightParen,     // )
    LeftBrace,      // {
    RightBrace,     // }
    TestOpen,       // [[
    TestClose,      // ]]
    ArithCommand,   // (( ... )) — value holds the inner expression text

    // keywords
    If, Then, Else, Elif, Fi,
    For, While, Until, Do, Done, In,
    Case, Esac, Function,

    // special
    Dollar,
    ParameterExpansion,
    CommandSubstitution,
    ArithmeticExpansion,
    Eof,
};

pub const Token = struct {
    ty: TokenType,
    value: []const u8,
    line: u32,
    column: u32,

    pub const EMPTY = Token{ .ty = .Eof, .value = "", .line = 0, .column = 0 };
};

// All lexer states - explicit and visible
const State = enum {
    normal,
    word,
    // single quote
    sq,
    // double quote
    dq,
    dq_esc,
    dq_dollar,
    dq_dollar_brace,
    dq_dollar_paren,
    // unquoted dollar
    dollar,
    dollar_brace,
    dollar_paren,
    dollar_dparen,  // $((
    dollar_sq,      // $'...' ANSI-C quoting
    // backtick
    tick,
    tick_esc,
    // comment
    comment,
    // operators
    pipe,
    amp,
    gt,
    lt,
    lt_lt,
    // escape
    esc,
    // bracket
    lbracket,
    rbracket,
    // fd redirect (e.g., 2>)
    fd_num,
    // URL (e.g., https://example.com?a=1&b=2)
    url,
};

pub const Lexer = struct {
    input: []const u8,
    pos: usize,
    line: u32,
    column: u32,
    state: State,

    // token building
    token_start: usize,
    token_line: u32,
    token_col: u32,

    // double-buffering for token values (prevents overwrite when peeking)
    buf: [2][types.MAX_TOKEN_LENGTH]u8,
    buf_len: usize,
    buf_idx: u1,  // alternates between 0 and 1
    use_buf: bool,  // true if we're building into buffer

    // nesting counters
    paren_depth: u32,
    brace_depth: u32,

    const Self = @This();

    pub fn init(input: []const u8) !Self {
        try types.validateShellSafe(input);
        return Self{
            .input = input,
            .pos = 0,
            .line = 1,
            .column = 1,
            .state = .normal,
            .token_start = 0,
            .token_line = 1,
            .token_col = 1,
            .buf = undefined,
            .buf_len = 0,
            .buf_idx = 0,
            .use_buf = false,
            .paren_depth = 0,
            .brace_depth = 0,
        };
    }

    fn peek(self: *Self) ?u8 {
        return if (self.pos < self.input.len) self.input[self.pos] else null;
    }

    fn peekN(self: *Self, n: usize) ?u8 {
        const idx = self.pos + n;
        return if (idx < self.input.len) self.input[idx] else null;
    }

    fn advance(self: *Self) ?u8 {
        if (self.pos >= self.input.len) return null;
        const c = self.input[self.pos];
        self.pos += 1;
        if (c == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        return c;
    }

    fn bufAppend(self: *Self, c: u8) void {
        if (self.buf_len < types.MAX_TOKEN_LENGTH) {
            self.buf[self.buf_idx][self.buf_len] = c;
            self.buf_len += 1;
        }
    }

    fn bufAppendSlice(self: *Self, s: []const u8) void {
        for (s) |c| self.bufAppend(c);
    }

    fn startToken(self: *Self) void {
        self.token_start = self.pos;
        self.token_line = self.line;
        self.token_col = self.column;
        self.buf_len = 0;
        self.use_buf = false;
        // alternate buffer for next token (double-buffering)
        self.buf_idx = 1 - self.buf_idx;
    }

    fn makeToken(self: *Self, ty: TokenType) Token {
        const value = if (self.use_buf)
            self.buf[self.buf_idx][0..self.buf_len]
        else
            self.input[self.token_start..self.pos];

        return Token{
            .ty = if (ty == .Word) classifyWord(value) else ty,
            .value = value,
            .line = self.token_line,
            .column = self.token_col,
        };
    }

    // Build a static-lifetime "n<op>" string (e.g. "3>>", "1>&") for fd redirects.
    fn fdOpStr(fd: u8, op: []const u8) []const u8 {
        return switch (fd) {
            '0' => opFor("0", op),
            '1' => opFor("1", op),
            '2' => opFor("2", op),
            '3' => opFor("3", op),
            '4' => opFor("4", op),
            '5' => opFor("5", op),
            '6' => opFor("6", op),
            '7' => opFor("7", op),
            '8' => opFor("8", op),
            '9' => opFor("9", op),
            else => op,
        };
    }
    fn opFor(comptime d: []const u8, op: []const u8) []const u8 {
        if (std.mem.eql(u8, op, ">")) return d ++ ">";
        if (std.mem.eql(u8, op, ">>")) return d ++ ">>";
        if (std.mem.eql(u8, op, ">&")) return d ++ ">&";
        if (std.mem.eql(u8, op, "<")) return d ++ "<";
        if (std.mem.eql(u8, op, "<&")) return d ++ "<&";
        return op;
    }

    fn makeTokenValue(self: *Self, ty: TokenType, value: []const u8) Token {
        return Token{
            .ty = ty,
            .value = value,
            .line = self.token_line,
            .column = self.token_col,
        };
    }

    // collect process substitution <(cmd) or >(cmd)
    fn collectProcessSubst(self: *Self, ty: TokenType) Token {
        _ = self.advance(); // skip opening (
        self.use_buf = true;
        var depth: u32 = 1;

        while (depth > 0) {
            const ch = self.peek() orelse break;
            if (ch == '(') {
                depth += 1;
            } else if (ch == ')') {
                depth -= 1;
                if (depth == 0) {
                    _ = self.advance(); // skip closing )
                    break;
                }
            }
            self.bufAppend(ch);
            _ = self.advance();
        }

        return Token{
            .ty = ty,
            .value = self.buf[self.buf_idx][0..self.buf_len],
            .line = self.token_line,
            .column = self.token_col,
        };
    }

    pub fn nextToken(self: *Self) !Token {
        while (true) {
            const c = self.peek();

            switch (self.state) {
                .normal => {
                    // skip whitespace (but not newlines)
                    if (c) |ch| {
                        if (ch == ' ' or ch == '\t') {
                            _ = self.advance();
                            continue;
                        }
                    }

                    if (c == null) {
                        return Token.EMPTY;
                    }

                    self.startToken();
                    const ch = c.?;

                    switch (ch) {
                        '#' => {
                            self.state = .comment;
                            _ = self.advance();
                        },
                        '\'' => {
                            _ = self.advance(); // skip opening quote
                            self.token_start = self.pos; // start AFTER quote
                            self.buf_len = 0;
                            self.use_buf = true;
                            self.state = .sq;
                        },
                        '"' => {
                            _ = self.advance(); // skip opening quote
                            self.token_start = self.pos; // start AFTER quote
                            self.buf_len = 0;
                            self.use_buf = true;
                            self.state = .dq;
                        },
                        '`' => {
                            self.state = .tick;
                            _ = self.advance();
                        },
                        '$' => {
                            self.state = .dollar;
                            _ = self.advance();
                        },
                        '\\' => {
                            self.state = .esc;
                            _ = self.advance();
                        },
                        '|' => {
                            _ = self.advance();
                            if (self.peek() == @as(u8, '|')) {
                                _ = self.advance();
                                return self.makeTokenValue(.Or, "||");
                            }
                            return self.makeTokenValue(.Pipe, "|");
                        },
                        '&' => {
                            _ = self.advance();
                            if (self.peek() == @as(u8, '&')) {
                                _ = self.advance();
                                return self.makeTokenValue(.And, "&&");
                            }
                            if (self.peek() == @as(u8, '>')) {
                                _ = self.advance(); // >
                                if (self.peek() == @as(u8, '>')) {
                                    _ = self.advance(); // second >
                                    return self.makeTokenValue(.RedirectAllAppend, "&>>");
                                }
                                return self.makeTokenValue(.RedirectAll, "&>");
                            }
                            return self.makeTokenValue(.Background, "&");
                        },
                        ';' => {
                            _ = self.advance();
                            if (self.peek() == @as(u8, ';')) {
                                _ = self.advance();
                                return self.makeTokenValue(.DoubleSemi, ";;");
                            }
                            return self.makeTokenValue(.Semicolon, ";");
                        },
                        '\n' => {
                            _ = self.advance();
                            return self.makeTokenValue(.NewLine, "\n");
                        },
                        '(' => {
                            // "((" (glued) opens an arithmetic command or the
                            // header of a C-style `for ((;;))`. Capture the inner
                            // text up to the matching "))" as one ArithCommand
                            // token; the parser decides how to use it. "( (" (with
                            // a space) stays two LeftParen — a nested subshell.
                            if (self.peekN(1) == @as(u8, '(')) {
                                _ = self.advance(); // first (
                                _ = self.advance(); // second (
                                self.use_buf = true;
                                self.buf_len = 0;
                                var depth: i32 = 0;
                                while (true) {
                                    const cc = self.peek() orelse return error.UnterminatedExpansion;
                                    if (cc == '(') {
                                        depth += 1;
                                        self.bufAppend('(');
                                        _ = self.advance();
                                    } else if (cc == ')') {
                                        if (depth == 0 and self.peekN(1) == @as(u8, ')')) {
                                            _ = self.advance(); // first )
                                            _ = self.advance(); // second )
                                            break;
                                        }
                                        depth -= 1;
                                        self.bufAppend(')');
                                        _ = self.advance();
                                    } else {
                                        self.bufAppend(cc);
                                        _ = self.advance();
                                    }
                                }
                                return self.makeToken(.ArithCommand);
                            }
                            _ = self.advance();
                            return self.makeTokenValue(.LeftParen, "(");
                        },
                        ')' => {
                            _ = self.advance();
                            return self.makeTokenValue(.RightParen, ")");
                        },
                        '{' => {
                            // Check if this is a brace expansion pattern {a,b} or {1..5}
                            // vs command grouping { cmd; }
                            if (self.isBraceExpansion()) {
                                self.brace_depth = 1;
                                self.state = .word;
                                _ = self.advance();
                            } else if (self.peekN(1)) |nxt| {
                                // "{ " (brace + blank) opens a command group.
                                // "{" glued to other characters is a literal word
                                // — e.g. find's {} placeholder, or a bare {}.
                                if (nxt == ' ' or nxt == '\t' or nxt == '\n') {
                                    _ = self.advance();
                                    return self.makeTokenValue(.LeftBrace, "{");
                                }
                                self.state = .word; // lex the whole word (re-reads '{')
                            } else {
                                _ = self.advance();
                                return self.makeTokenValue(.LeftBrace, "{");
                            }
                        },
                        '}' => {
                            _ = self.advance();
                            return self.makeTokenValue(.RightBrace, "}");
                        },
                        '[' => {
                            // '[[' is the test-open keyword.
                            if (self.peekN(1) == @as(u8, '[')) {
                                _ = self.advance();
                                _ = self.advance();
                                return self.makeTokenValue(.TestOpen, "[[");
                            }
                            // A lone '[' followed by whitespace/operator/EOF is the
                            // `test` builtin command word. Otherwise '[' begins a
                            // glob character class (e.g. [abc]*), or a `[[ ]]`
                            // pattern like [0-9]+ — lex the whole word so pathname
                            // expansion / the test evaluator sees the pattern.
                            if (self.peekN(1)) |nxt| {
                                if (isOperator(nxt)) {
                                    _ = self.advance();
                                    return self.makeTokenValue(.Word, "[");
                                }
                                self.state = .word;
                            } else {
                                _ = self.advance();
                                return self.makeTokenValue(.Word, "[");
                            }
                        },
                        ']' => {
                            _ = self.advance();
                            if (self.peek() == @as(u8, ']')) {
                                _ = self.advance();
                                return self.makeTokenValue(.TestClose, "]]");
                            }
                            return self.makeTokenValue(.Word, "]");
                        },
                        '>' => {
                            _ = self.advance();
                            if (self.peek() == @as(u8, '(')) {
                                // >( process substitution - collect until matching )
                                return self.collectProcessSubst(.ProcessSubstOut);
                            }
                            if (self.peek() == @as(u8, '>')) {
                                _ = self.advance();
                                return self.makeTokenValue(.RedirectAppend, ">>");
                            }
                            if (self.peek() == @as(u8, '|')) {
                                // >| force truncate (noclobber override)
                                _ = self.advance();
                                return self.makeTokenValue(.RedirectFd, ">|");
                            }
                            if (self.peek() == @as(u8, '&')) {
                                if (self.peekN(1) == @as(u8, '2')) {
                                    _ = self.advance(); // &
                                    _ = self.advance(); // 2
                                    return self.makeTokenValue(.RedirectToStderr, ">&2");
                                }
                                // >&word or >&digit or >&- : consume '&', target parsed as word
                                _ = self.advance(); // &
                                return self.makeTokenValue(.RedirectFd, ">&");
                            }
                            return self.makeTokenValue(.RedirectOutput, ">");
                        },
                        '<' => {
                            _ = self.advance();
                            if (self.peek() == @as(u8, '(')) {
                                // <( process substitution - collect until matching )
                                return self.collectProcessSubst(.ProcessSubstIn);
                            }
                            if (self.peek() == @as(u8, '<')) {
                                _ = self.advance();
                                if (self.peek() == @as(u8, '<')) {
                                    _ = self.advance();
                                    return self.makeTokenValue(.RedirectHereDoc, "<<<");
                                }
                                return self.makeTokenValue(.RedirectHereDocLiteral, "<<");
                            }
                            return self.makeTokenValue(.RedirectInput, "<");
                        },
                        '0'...'9' => {
                            // fd redirect: n> n>> n>&m n>&- n< n<&m n<&-
                            if (self.peekN(1) == @as(u8, '>') or self.peekN(1) == @as(u8, '<')) {
                                const fd = ch;
                                const is_out = self.peekN(1) == @as(u8, '>');
                                _ = self.advance(); // digit
                                _ = self.advance(); // > or <

                                // keep existing token identities for the common stderr cases
                                if (is_out) {
                                    if (self.peek() == @as(u8, '&') and self.peekN(1) == @as(u8, '1') and fd == '2') {
                                        _ = self.advance();
                                        _ = self.advance();
                                        return self.makeTokenValue(.RedirectBoth, "2>&1");
                                    }
                                    if (self.peek() == @as(u8, '>')) {
                                        _ = self.advance();
                                        if (fd == '2') return self.makeTokenValue(.RedirectStderrAppend, "2>>");
                                        return self.makeTokenValue(.RedirectFd, fdOpStr(fd, ">>"));
                                    }
                                    if (self.peek() == @as(u8, '&')) {
                                        _ = self.advance(); // &
                                        return self.makeTokenValue(.RedirectFd, fdOpStr(fd, ">&"));
                                    }
                                    if (fd == '2') return self.makeTokenValue(.RedirectStderr, "2>");
                                    return self.makeTokenValue(.RedirectFd, fdOpStr(fd, ">"));
                                } else {
                                    if (self.peek() == @as(u8, '&')) {
                                        _ = self.advance(); // &
                                        return self.makeTokenValue(.RedirectFd, fdOpStr(fd, "<&"));
                                    }
                                    return self.makeTokenValue(.RedirectFd, fdOpStr(fd, "<"));
                                }
                            }
                            self.state = .word;
                            _ = self.advance();
                        },
                        else => {
                            self.state = .word;
                            _ = self.advance();
                        },
                    }
                },

                .word => {
                    if (c == null) {
                        self.brace_depth = 0;
                        self.state = .normal;
                        return self.makeToken(.Word);
                    }

                    const ch = c.?;

                    // Handle braces within words (for brace expansion)
                    if (ch == '{') {
                        self.brace_depth += 1;
                        if (self.use_buf) self.bufAppend(ch);
                        _ = self.advance();
                        continue;
                    }
                    if (ch == '}') {
                        if (self.brace_depth > 0) {
                            self.brace_depth -= 1;
                            if (self.use_buf) self.bufAppend(ch);
                            _ = self.advance();
                            // If brace_depth is now 0, check if word continues
                            if (self.brace_depth == 0) {
                                if (self.peek()) |next| {
                                    // Word continues if next char is { (new brace group)
                                    // or a non-operator character
                                    if (next != '{' and isOperator(next)) {
                                        self.state = .normal;
                                        return self.makeToken(.Word);
                                    }
                                } else {
                                    self.state = .normal;
                                    return self.makeToken(.Word);
                                }
                            }
                            continue;
                        } else {
                            // Unmatched }, end word
                            self.state = .normal;
                            return self.makeToken(.Word);
                        }
                    }

                    // Handle array assignment parens: continue collecting if inside array assign
                    if (ch == '(' and self.paren_depth > 0) {
                        self.paren_depth += 1;
                        if (self.use_buf) self.bufAppend(ch);
                        _ = self.advance();
                        continue;
                    }
                    if (ch == ')' and self.paren_depth > 0) {
                        self.paren_depth -= 1;
                        if (self.use_buf) self.bufAppend(ch);
                        _ = self.advance();
                        if (self.paren_depth == 0) {
                            // End of array assignment
                            self.state = .normal;
                            return self.makeToken(.Word);
                        }
                        continue;
                    }

                    // For other operators, only end word if not inside braces and not in array assignment
                    if (isOperator(ch) and self.brace_depth == 0 and self.paren_depth == 0) {
                        // Check for array assignment: var=(...)
                        // If current word ends with `=` and ch is `(`, start array assignment
                        if (ch == '(') {
                            const word_so_far = self.currentTokenValue();
                            if (word_so_far.len > 0 and word_so_far[word_so_far.len - 1] == '=') {
                                self.switchToBuf();
                                self.bufAppend('(');
                                _ = self.advance();
                                self.paren_depth = 1;
                                continue;
                            }
                        }
                        self.state = .normal;
                        return self.makeToken(.Word);
                    }

                    // Check for URL pattern: if we see :// transition to URL mode
                    if (ch == ':' and self.peekN(1) == @as(u8, '/') and self.peekN(2) == @as(u8, '/')) {
                        self.switchToBuf();
                        self.bufAppend(':');
                        _ = self.advance();
                        self.bufAppend('/');
                        _ = self.advance();
                        self.bufAppend('/');
                        _ = self.advance();
                        self.state = .url;
                        continue;
                    }

                    switch (ch) {
                        // quotes continue the word
                        '\'' => {
                            self.switchToBuf();
                            self.state = .sq;
                            _ = self.advance();
                        },
                        '"' => {
                            self.switchToBuf();
                            self.state = .dq;
                            _ = self.advance();
                        },
                        '$' => {
                            self.switchToBuf();
                            self.bufAppend('$');
                            self.state = .dollar;
                            _ = self.advance();
                        },
                        '`' => {
                            self.switchToBuf();
                            self.bufAppend('`');
                            self.state = .tick;
                            _ = self.advance();
                        },
                        '\\' => {
                            self.switchToBuf();
                            self.state = .esc;
                            _ = self.advance();
                        },
                        else => {
                            if (self.use_buf) self.bufAppend(ch);
                            _ = self.advance();
                        },
                    }
                },

                .sq => {
                    // single quote: literal until closing '
                    if (c == null) return error.UnterminatedString;
                    const ch = c.?;
                    if (ch == '\'') {
                        _ = self.advance();
                        // check if word continues
                        if (self.peek()) |next| {
                            if (!isOperator(next)) {
                                self.state = .word;
                                continue;
                            }
                        }
                        self.state = .normal;
                        return self.makeToken(.String);
                    }
                    if (self.use_buf) self.bufAppend(ch);
                    _ = self.advance();
                },

                .dq => {
                    // double quote: process escapes and $
                    if (c == null) return error.UnterminatedString;
                    const ch = c.?;
                    switch (ch) {
                        '"' => {
                            _ = self.advance();
                            // check if word continues
                            if (self.peek()) |next| {
                                if (!isOperator(next)) {
                                    self.state = .word;
                                    continue;
                                }
                            }
                            self.state = .normal;
                            return self.makeToken(.DoubleQuotedString);
                        },
                        '\\' => {
                            self.state = .dq_esc;
                            _ = self.advance();
                        },
                        '$' => {
                            self.state = .dq_dollar;
                            self.bufAppend('$');
                            _ = self.advance();
                        },
                        else => {
                            if (self.use_buf) self.bufAppend(ch);
                            _ = self.advance();
                        },
                    }
                },

                .dq_esc => {
                    if (c == null) return error.UnterminatedString;
                    const ch = c.?;
                    // In double quotes only \$ \` \" \\ (and \newline) are escapes; any
                    // other backslash is kept literally. Escaped $ and ` become sentinels
                    // so the expander leaves them literal.
                    switch (ch) {
                        '$' => self.bufAppend(LIT_DOLLAR),
                        '`' => self.bufAppend(LIT_BACKTICK),
                        '"', '\\' => self.bufAppend(ch),
                        '\n' => {}, // line continuation: drop
                        else => {
                            // Not a recognized escape: keep the backslash literally.
                            self.bufAppend('\\');
                            self.bufAppend(ch);
                        },
                    }
                    self.state = .dq;
                    _ = self.advance();
                },

                .dq_dollar => {
                    // inside double quote, saw $
                    if (c == null) {
                        self.state = .dq;
                        continue;
                    }
                    const ch = c.?;
                    switch (ch) {
                        '{' => {
                            self.bufAppend('{');
                            self.brace_depth = 1;
                            self.state = .dq_dollar_brace;
                            _ = self.advance();
                        },
                        '(' => {
                            self.bufAppend('(');
                            self.paren_depth = 1;
                            self.state = .dq_dollar_paren;
                            _ = self.advance();
                        },
                        'a'...'z', 'A'...'Z', '_' => {
                            // Named variable inside double quotes: the closing quote (or
                            // any non-name char) ends the name. Wrap as ${name} so the
                            // boundary survives quote-stripping (e.g. "$x"c -> ${x}c, not $xc).
                            // A '$' was already appended by the .dq state.
                            self.bufAppend('{');
                            self.bufAppend(ch);
                            _ = self.advance();
                            while (self.peek()) |nc| {
                                if (std.ascii.isAlphanumeric(nc) or nc == '_') {
                                    self.bufAppend(nc);
                                    _ = self.advance();
                                } else break;
                            }
                            self.bufAppend('}');
                            self.state = .dq;
                        },
                        '?', '!', '#', '*', '@', '-', '0'...'9' => {
                            // Single-char special parameters: boundary is implicit (one char).
                            self.bufAppend(ch);
                            _ = self.advance();
                            self.state = .dq;
                        },
                        else => self.state = .dq,
                    }
                },

                .dq_dollar_brace => {
                    if (c == null) return error.UnterminatedExpansion;
                    const ch = c.?;
                    self.bufAppend(ch);
                    if (ch == '{') self.brace_depth += 1;
                    if (ch == '}') {
                        self.brace_depth -= 1;
                        if (self.brace_depth == 0) self.state = .dq;
                    }
                    _ = self.advance();
                },

                .dq_dollar_paren => {
                    if (c == null) return error.UnterminatedExpansion;
                    const ch = c.?;
                    self.bufAppend(ch);
                    if (ch == '(') self.paren_depth += 1;
                    if (ch == ')') {
                        self.paren_depth -= 1;
                        if (self.paren_depth == 0) self.state = .dq;
                    }
                    _ = self.advance();
                },

                .dollar => {
                    // unquoted $
                    if (c == null) {
                        self.state = .normal;
                        return self.makeToken(.Word);
                    }
                    const ch = c.?;
                    switch (ch) {
                        '\'' => {
                            // $'...' ANSI-C quoting: process C escapes, produce literal bytes.
                            // Copy any word prefix but drop the '$' itself.
                            if (!self.use_buf) {
                                const prefix = self.input[self.token_start .. self.pos - 1];
                                @memcpy(self.buf[self.buf_idx][0..prefix.len], prefix);
                                self.buf_len = prefix.len;
                                self.use_buf = true;
                            } else if (self.buf_len > 0 and self.buf[self.buf_idx][self.buf_len - 1] == '$') {
                                self.buf_len -= 1;
                            }
                            self.state = .dollar_sq;
                            _ = self.advance();
                        },
                        '{' => {
                            self.bufAppend('{');
                            self.brace_depth = 1;
                            self.state = .dollar_brace;
                            _ = self.advance();
                        },
                        '(' => {
                            self.bufAppend('(');
                            if (self.peekN(1) == @as(u8, '(')) {
                                _ = self.advance();
                                self.bufAppend('(');
                                self.paren_depth = 2;
                                self.state = .dollar_dparen;
                            } else {
                                self.paren_depth = 1;
                                self.state = .dollar_paren;
                            }
                            _ = self.advance();
                        },
                        'a'...'z', 'A'...'Z', '_' => {
                            self.bufAppend(ch);
                            _ = self.advance();
                            while (self.peek()) |nc| {
                                if (std.ascii.isAlphanumeric(nc) or nc == '_') {
                                    self.bufAppend(nc);
                                    _ = self.advance();
                                } else break;
                            }
                            // check if word continues. Inside an array assignment
                            // (paren_depth > 0) keep collecting so the closing ')'
                            // reaches the word state — else `a=($x)` ended early as
                            // the literal word "a=($x".
                            if (self.peek()) |next| {
                                if (!isOperator(next) or self.paren_depth > 0) {
                                    self.state = .word;
                                    continue;
                                }
                            }
                            self.state = .normal;
                            return self.makeToken(.Word);
                        },
                        '?', '!', '#', '$', '*', '@', '-', '0'...'9' => {
                            self.bufAppend(ch);
                            _ = self.advance();
                            if (self.peek()) |next| {
                                if (!isOperator(next) or self.paren_depth > 0) {
                                    self.state = .word;
                                    continue;
                                }
                            }
                            self.state = .normal;
                            return self.makeToken(.Word);
                        },
                        else => {
                            // lone $
                            if (!isOperator(ch)) {
                                self.state = .word;
                            } else {
                                self.state = .normal;
                                return self.makeToken(.Word);
                            }
                        },
                    }
                },

                .dollar_brace => {
                    if (c == null) return error.UnterminatedExpansion;
                    const ch = c.?;
                    self.bufAppend(ch);
                    if (ch == '{') self.brace_depth += 1;
                    if (ch == '}') {
                        self.brace_depth -= 1;
                        if (self.brace_depth == 0) {
                            _ = self.advance();
                            // Inside an array assignment keep collecting so ')'
                            // reaches the word state (a=(${HOME}) must not end early).
                            if (self.peek()) |next| {
                                if (!isOperator(next) or self.paren_depth > 0) {
                                    self.state = .word;
                                    continue;
                                }
                            }
                            self.state = .normal;
                            return self.makeToken(.Word);
                        }
                    }
                    _ = self.advance();
                },

                .dollar_paren => {
                    if (c == null) return error.UnterminatedExpansion;
                    const ch = c.?;
                    self.bufAppend(ch);
                    if (ch == '(') self.paren_depth += 1;
                    if (ch == ')') {
                        self.paren_depth -= 1;
                        if (self.paren_depth == 0) {
                            _ = self.advance();
                            if (self.peek()) |next| {
                                if (!isOperator(next)) {
                                    self.state = .word;
                                    continue;
                                }
                            }
                            self.state = .normal;
                            return self.makeToken(.Word);
                        }
                    }
                    _ = self.advance();
                },

                .dollar_dparen => {
                    // $(( arithmetic ))
                    if (c == null) return error.UnterminatedExpansion;
                    const ch = c.?;
                    self.bufAppend(ch);
                    if (ch == '(') self.paren_depth += 1;
                    if (ch == ')') {
                        self.paren_depth -= 1;
                        if (self.paren_depth == 0) {
                            _ = self.advance();
                            if (self.peek()) |next| {
                                if (!isOperator(next)) {
                                    self.state = .word;
                                    continue;
                                }
                            }
                            self.state = .normal;
                            return self.makeToken(.Word);
                        }
                    }
                    _ = self.advance();
                },

                .dollar_sq => {
                    // $'...' ANSI-C quoting: decode C escape sequences into literal bytes.
                    if (c == null) return error.UnterminatedString;
                    const ch = c.?;
                    if (ch == '\'') {
                        _ = self.advance();
                        if (self.peek()) |next| {
                            if (!isOperator(next)) {
                                self.state = .word;
                                continue;
                            }
                        }
                        self.state = .normal;
                        return self.makeToken(.String);
                    }
                    if (ch == '\\') {
                        _ = self.advance();
                        const e = self.peek() orelse {
                            self.bufAppend('\\');
                            continue;
                        };
                        switch (e) {
                            'n' => { self.bufAppend('\n'); _ = self.advance(); },
                            't' => { self.bufAppend('\t'); _ = self.advance(); },
                            'r' => { self.bufAppend('\r'); _ = self.advance(); },
                            'a' => { self.bufAppend(0x07); _ = self.advance(); },
                            'b' => { self.bufAppend(0x08); _ = self.advance(); },
                            'f' => { self.bufAppend(0x0C); _ = self.advance(); },
                            'v' => { self.bufAppend(0x0B); _ = self.advance(); },
                            'e', 'E' => { self.bufAppend(0x1B); _ = self.advance(); },
                            '\\' => { self.bufAppend('\\'); _ = self.advance(); },
                            '\'' => { self.bufAppend('\''); _ = self.advance(); },
                            '"' => { self.bufAppend('"'); _ = self.advance(); },
                            '?' => { self.bufAppend('?'); _ = self.advance(); },
                            'x' => {
                                _ = self.advance();
                                var val: u16 = 0;
                                var digits: u8 = 0;
                                while (digits < 2) : (digits += 1) {
                                    const hc = self.peek() orelse break;
                                    const d = hexDigit(hc) orelse break;
                                    val = val * 16 + d;
                                    _ = self.advance();
                                }
                                if (digits == 0) {
                                    self.bufAppend('\\');
                                    self.bufAppend('x');
                                } else {
                                    self.bufAppend(@intCast(val & 0xFF));
                                }
                            },
                            '0'...'7' => {
                                var val: u16 = 0;
                                var digits: u8 = 0;
                                while (digits < 3) : (digits += 1) {
                                    const oc = self.peek() orelse break;
                                    if (oc < '0' or oc > '7') break;
                                    val = val * 8 + (oc - '0');
                                    _ = self.advance();
                                }
                                self.bufAppend(@intCast(val & 0xFF));
                            },
                            else => {
                                // Unknown escape: keep the backslash and the char literally.
                                self.bufAppend('\\');
                                self.bufAppend(e);
                                _ = self.advance();
                            },
                        }
                        continue;
                    }
                    self.bufAppend(ch);
                    _ = self.advance();
                },

                .tick => {
                    if (c == null) return error.UnterminatedString;
                    const ch = c.?;
                    if (self.use_buf) self.bufAppend(ch);
                    if (ch == '`') {
                        _ = self.advance();
                        if (self.peek()) |next| {
                            if (!isOperator(next)) {
                                self.state = .word;
                                continue;
                            }
                        }
                        self.state = .normal;
                        return self.makeToken(.Word);
                    }
                    if (ch == '\\') {
                        self.state = .tick_esc;
                    }
                    _ = self.advance();
                },

                .tick_esc => {
                    if (c == null) return error.UnterminatedString;
                    if (self.use_buf) self.bufAppend(c.?);
                    self.state = .tick;
                    _ = self.advance();
                },

                .esc => {
                    // backslash escape
                    if (c == null) {
                        self.state = .normal;
                        return self.makeToken(.Word);
                    }
                    const ch = c.?;
                    if (ch == '\n') {
                        // line continuation - skip backslash-newline
                        _ = self.advance();
                        if (self.use_buf) {
                            // already building a token in buffer, continue in word mode
                            self.state = .word;
                        } else if (self.pos > self.token_start + 2) {
                            // had content before backslash, need to use buffer
                            // copy content without the backslash
                            const content = self.input[self.token_start .. self.pos - 2];
                            @memcpy(self.buf[self.buf_idx][0..content.len], content);
                            self.buf_len = content.len;
                            self.use_buf = true;
                            self.state = .word;
                        } else {
                            // backslash-newline at start, just skip and restart
                            self.state = .normal;
                        }
                    } else {
                        // A backslash escapes the next char, making it literal. We build
                        // into the buffer, dropping the backslash itself. Chars that would
                        // otherwise trigger later expansion ($, `) are emitted as sentinels
                        // so the expander leaves them literal.
                        if (!self.use_buf) {
                            // Copy any word prefix, excluding the backslash (which sits at
                            // pos-1, since it was already consumed on entry to .esc).
                            const prefix = self.input[self.token_start .. self.pos - 1];
                            @memcpy(self.buf[self.buf_idx][0..prefix.len], prefix);
                            self.buf_len = prefix.len;
                            self.use_buf = true;
                        }
                        switch (ch) {
                            '$' => self.bufAppend(LIT_DOLLAR),
                            '`' => self.bufAppend(LIT_BACKTICK),
                            else => self.bufAppend(ch),
                        }
                        self.state = .word;
                        _ = self.advance();
                    }
                },

                .comment => {
                    if (c == null or c.? == '\n') {
                        self.state = .normal;
                        // don't emit comment as token, just skip
                        continue;
                    }
                    _ = self.advance();
                },

                .url => {
                    // URL mode: allow &, ?, =, etc. until whitespace or shell-specific operators
                    if (c == null) {
                        self.state = .normal;
                        return self.makeToken(.Word);
                    }
                    const ch = c.?;
                    // End URL on whitespace or shell operators that wouldn't appear in URLs
                    if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '|' or
                        ch == ';' or ch == '(' or ch == ')' or ch == '<' or
                        ch == '>' or ch == '`' or ch == '"' or ch == '\'')
                    {
                        self.state = .normal;
                        return self.makeToken(.Word);
                    }
                    // Allow all other chars including & ? = # etc.
                    self.bufAppend(ch);
                    _ = self.advance();
                },

                else => {
                    _ = self.advance();
                    self.state = .normal;
                },
            }
        }
    }

    fn switchToBuf(self: *Self) void {
        if (!self.use_buf) {
            // copy current token content to buffer
            const current = self.input[self.token_start..self.pos];
            @memcpy(self.buf[self.buf_idx][0..current.len], current);
            self.buf_len = current.len;
            self.use_buf = true;
        }
    }

    /// Get the current token value being built (for lookahead checks)
    fn currentTokenValue(self: *Self) []const u8 {
        if (self.use_buf) {
            return self.buf[self.buf_idx][0..self.buf_len];
        } else {
            return self.input[self.token_start..self.pos];
        }
    }

    /// Check if current position starts a brace expansion pattern like {a,b} or {1..5}
    /// vs command grouping { cmd; } (which has whitespace after {)
    fn isBraceExpansion(self: *Self) bool {
        // Look ahead from current position (which is at '{')
        var i = self.pos + 1;
        var depth: u32 = 1;
        var has_comma_or_range = false;

        // Command grouping: { must be followed by whitespace
        // Brace expansion: { is followed by content directly
        if (i < self.input.len and (self.input[i] == ' ' or self.input[i] == '\t' or self.input[i] == '\n')) {
            return false; // command grouping
        }

        while (i < self.input.len and depth > 0) {
            const c = self.input[i];
            switch (c) {
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0 and has_comma_or_range) return true;
                },
                ',' => {
                    if (depth == 1) has_comma_or_range = true;
                },
                '.' => {
                    // Check for .. range pattern
                    if (depth == 1 and i + 1 < self.input.len and self.input[i + 1] == '.') {
                        has_comma_or_range = true;
                    }
                },
                // Shell operators that indicate command grouping, not brace expansion
                ' ', '\t', '\n', ';', '|', '&' => {
                    if (depth == 1) return false;
                },
                else => {},
            }
            i += 1;
        }

        return has_comma_or_range;
    }
};

// Operator check using lookup table - faster than switch for hot path
// Inspired by SectorLambda's minimal instruction approach
const operator_table: [256]bool = blk: {
    var table = [_]bool{false} ** 256;
    for ([_]u8{ ' ', '\t', '\n', '|', '&', ';', '(', ')', '<', '>', '{', '}' }) |c| {
        table[c] = true;
    }
    break :blk table;
};

inline fn isOperator(c: u8) bool {
    return operator_table[c];
}

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// Fast keyword classification using length-based dispatch
// SectorLambda-inspired: minimize comparisons by filtering on length first
fn classifyWord(word: []const u8) TokenType {
    return switch (word.len) {
        2 => {
            if (word[0] == 'i') {
                if (word[1] == 'f') return .If;
                if (word[1] == 'n') return .In;
            }
            if (word[0] == 'd' and word[1] == 'o') return .Do;
            if (word[0] == 'f' and word[1] == 'i') return .Fi;
            return .Word;
        },
        3 => {
            if (word[0] == 'f' and word[1] == 'o' and word[2] == 'r') return .For;
            return .Word;
        },
        4 => {
            // Copy to aligned buffer for fast comparison
            var buf: [4]u8 align(4) = undefined;
            @memcpy(&buf, word[0..4]);
            const w = @as(*const u32, @ptrCast(&buf)).*;
            if (w == @as(u32, @bitCast([4]u8{ 't', 'h', 'e', 'n' }))) return .Then;
            if (w == @as(u32, @bitCast([4]u8{ 'e', 'l', 's', 'e' }))) return .Else;
            if (w == @as(u32, @bitCast([4]u8{ 'e', 'l', 'i', 'f' }))) return .Elif;
            if (w == @as(u32, @bitCast([4]u8{ 'c', 'a', 's', 'e' }))) return .Case;
            if (w == @as(u32, @bitCast([4]u8{ 'e', 's', 'a', 'c' }))) return .Esac;
            if (w == @as(u32, @bitCast([4]u8{ 'd', 'o', 'n', 'e' }))) return .Done;
            return .Word;
        },
        5 => {
            // First 4 chars comparison + check 5th
            var buf: [4]u8 align(4) = undefined;
            @memcpy(&buf, word[0..4]);
            const w4 = @as(*const u32, @ptrCast(&buf)).*;
            if (w4 == @as(u32, @bitCast([4]u8{ 'w', 'h', 'i', 'l' })) and word[4] == 'e') return .While;
            if (w4 == @as(u32, @bitCast([4]u8{ 'u', 'n', 't', 'i' })) and word[4] == 'l') return .Until;
            return .Word;
        },
        8 => {
            // Check first char quickly, then do full comparison
            if (word[0] == 'f') {
                var buf: [8]u8 align(4) = undefined;
                @memcpy(&buf, word[0..8]);
                const w1 = @as(*const u32, @ptrCast(&buf)).*;
                const w2 = @as(*const u32, @ptrCast(buf[4..8])).*;
                if (w1 == @as(u32, @bitCast([4]u8{ 'f', 'u', 'n', 'c' })) and
                    w2 == @as(u32, @bitCast([4]u8{ 't', 'i', 'o', 'n' }))) return .Function;
            }
            return .Word;
        },
        else => .Word,
    };
}
