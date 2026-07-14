// parser.zig - typestate parser with bounds checking

const std = @import("std");
const types = @import("types.zig");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");

// parser state machine - makes invalid states unrepresentable
pub const parserstate = enum {
    initial,
    hascurrent,
    hasboth,
    complete,
    error_state,
};

pub const parsererror = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidSyntax,
    ParserFinished,
    InvalidParserState,
    OutOfMemory,
    ExpansionTooLong,
    UnterminatedParameterExpansion,
    SubstitutionTooLong,
    UnterminatedCommandSubstitution,
    StringTooLong,
    UnterminatedString,
    UnterminatedExpansion,
    NumberTooLong,
    TokenTooLong,
    EmptyToken,
    TooManyCommands,
    TooManyPipelineCommands,
    TooManyArguments,
    EmptyCommand,
    EmptyInput,
    InvalidPipeline,
    EmptySubshell,
    AstTooComplex,
    ParseTooDeep,
    TooManyChildren,
    RecursionLimitExceeded,
} || types.SecurityError;

// typestate-based parser
pub const Parser = struct {
    lexer: lexer.Lexer,
    builder: ast.AstBuilder,
    state: parserstate,
    current_token: lexer.Token,
    peek_token: lexer.Token,
    recursion_depth: types.RecursionDepth,

    const Self = @This();

    pub fn init(input: []const u8, allocator: std.mem.Allocator) !Self {
        const lex = try lexer.Lexer.init(input);

        return Self{
            .lexer = lex,
            .builder = ast.AstBuilder.init(allocator),
            .state = .initial,
            .current_token = lexer.Token.EMPTY,
            .peek_token = lexer.Token.EMPTY,
            .recursion_depth = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.builder.deinit();
    }

    // state-safe token advancement
    pub fn nextToken(self: *Self) !void {
        switch (self.state) {
            .initial => {
                self.current_token = try self.lexer.nextToken();
                self.peek_token = try self.lexer.nextToken();
                self.state = .hasboth;
            },
            .hasboth => {
                self.current_token = self.peek_token;
                self.peek_token = try self.lexer.nextToken();
            },
            .complete, .error_state => return error.ParserFinished,
            else => return error.InvalidParserState,
        }
    }

    // main parsing entry point with security checks
    pub fn parse(self: *Self) !*const ast.AstNode {
        // prime the parser
        try self.nextToken();

        const root = try self.parsecommandlist();

        self.state = .complete;

        // validate the resulting ast for security
        try ast.validateast(root);

        return root;
    }

    fn parsecommandlist(self: *Self) parsererror!*const ast.AstNode {
        if (self.state != .hasboth) return error.InvalidParserState;

        var commands = try std.ArrayList(*const ast.AstNode).initCapacity(self.builder.arena.allocator(), 32);

        while (self.current_token.ty != .Eof) {
            // skip empty statements
            if (self.current_token.ty == .Semicolon or self.current_token.ty == .NewLine) {
                try self.nextToken();
                continue;
            }

            // stop at control structure closing keywords
            switch (self.current_token.ty) {
                .Done, .Fi, .Else, .Elif, .Esac, .Then, .RightBrace, .RightParen, .DoubleSemi => break,
                else => {},
            }

            // prevent dos via massive command lists
            if (commands.items.len >= types.MAX_ARGS_COUNT) {
                return error.TooManyCommands;
            }

            var cmd = try self.parseandor();

            // handle & (background) - acts as both modifier AND separator
            if (self.current_token.ty == .Background) {
                const line = self.current_token.line;
                const column = self.current_token.column;
                try self.nextToken(); // consume &
                cmd = try self.builder.createbackground(cmd, line, column);
                // & acts as separator, no further separator check needed
            } else if (self.current_token.ty == .Semicolon or self.current_token.ty == .NewLine) {
                // explicit separator
                try self.nextToken();
            } else {
                // no separator - must be at EOF or closing keyword
                switch (self.current_token.ty) {
                    .Eof, .Done, .Fi, .Else, .Elif, .Esac, .Then, .RightBrace, .RightParen, .DoubleSemi => {},
                    else => return error.UnexpectedToken, // syntax error: missing separator
                }
            }

            // single append point - all paths lead here
            try commands.append(self.builder.arena.allocator(), cmd);
        }

        if (commands.items.len == 0) {
            return error.EmptyInput;
        }

        if (commands.items.len == 1) {
            return commands.items[0];
        }

        return self.builder.createlist(
            commands.items,
            commands.items[0].line,
            commands.items[0].column,
        );
    }

    // and-or list: pipelines joined by && / ||. POSIX gives these operators
    // EQUAL precedence and LEFT associativity, so parse them in one flat loop.
    fn parseandor(self: *Self) parsererror!*const ast.AstNode {
        var left = try self.parsepipeline();

        while (self.current_token.ty == .And or self.current_token.ty == .Or) {
            const is_and = self.current_token.ty == .And;
            const op_line = self.current_token.line;
            const op_column = self.current_token.column;
            try self.nextToken(); // consume && or ||

            // newlines are allowed after && / || (continuation)
            while (self.current_token.ty == .NewLine) try self.nextToken();

            const right = try self.parsepipeline();
            left = if (is_and)
                try self.builder.createlogicaland(left, right, op_line, op_column)
            else
                try self.builder.createlogicalor(left, right, op_line, op_column);
        }

        return left;
    }

    fn parsepipeline(self: *Self) parsererror!*const ast.AstNode {
        // leading `!` negates the pipeline's exit status
        var negate = false;
        while (self.current_token.ty == .Word and
            self.current_token.value.len == 1 and self.current_token.value[0] == '!')
        {
            negate = !negate;
            try self.nextToken(); // consume '!'
        }

        var pipeline_commands = try std.ArrayList(*const ast.AstNode).initCapacity(self.builder.arena.allocator(), 32);

        // Parse first command
        const first_cmd = try self.parsecommand();
        try pipeline_commands.append(self.builder.arena.allocator(), first_cmd);

        // Parse additional commands connected by pipes
        while (self.current_token.ty == .Pipe) {
            try self.nextToken(); // consume pipe token

            if (pipeline_commands.items.len >= types.MAX_ARGS_COUNT) {
                return error.TooManyPipelineCommands;
            }

            const next_cmd = try self.parsecommand();
            try pipeline_commands.append(self.builder.arena.allocator(), next_cmd);
        }

        // Create result (pipeline or single command)
        const result = if (pipeline_commands.items.len == 1)
            pipeline_commands.items[0]
        else
            try self.builder.createpipeline(
                pipeline_commands.items,
                pipeline_commands.items[0].line,
                pipeline_commands.items[0].column,
            );

        // Note: & is handled in parsecommandlist as it acts as separator
        if (negate) {
            return self.builder.createnegate(result, result.line, result.column);
        }
        return result;
    }

    fn parsecommand(self: *Self) parsererror!*const ast.AstNode {
        // recursion depth check
        if (self.recursion_depth >= types.MAX_RECURSION_DEPTH) {
            return error.RecursionLimitExceeded;
        }

        self.recursion_depth = try types.checkedAdd(types.RecursionDepth, self.recursion_depth, 1);
        defer self.recursion_depth -= 1;

        return switch (self.current_token.ty) {
            .If => self.parseif(),
            .While => self.parsewhile(),
            .Until => self.parseuntil(),
            .For => self.parsefor(),
            .Case => self.parsecase(),
            .LeftBrace => self.parsegroup(),
            .LeftParen => self.parsesubshell(),
            .Function => self.parsefunction(),
            .TestOpen => self.parsetest(),
            else => self.parsesimplecommand(),
        };
    }

    fn parsesimplecommand(self: *Self) parsererror!*const ast.AstNode {
        var words = try std.ArrayList(*const ast.AstNode).initCapacity(self.builder.arena.allocator(), 32);

        // collect leading assignments (VAR=value prefix syntax)
        var prefix_assignments = try std.ArrayList(*const ast.AstNode).initCapacity(self.builder.arena.allocator(), 4);

        while (self.current_token.ty != .Eof) {
            switch (self.current_token.ty) {
                .Word => {
                    // Check for POSIX function definition: name() { ... }
                    if (words.items.len == 0 and prefix_assignments.items.len == 0 and self.peek_token.ty == .LeftParen) {
                        const name_token = self.current_token;
                        try self.nextToken(); // consume name
                        if (self.current_token.ty == .LeftParen) {
                            try self.nextToken(); // consume '('
                            if (self.current_token.ty == .RightParen) {
                                try self.nextToken(); // consume ')'
                                if (self.current_token.ty == .LeftBrace) {
                                    // This is a function definition
                                    const body = try self.parsegroup();
                                    return self.builder.createfunctiondef(name_token.value, body, name_token.line, name_token.column);
                                }
                            }
                        }
                        // Not a function definition, treat as command - restore parsing
                        const word = try self.builder.createword(name_token.value, name_token.line, name_token.column);
                        try words.append(self.builder.arena.allocator(), word);
                        continue;
                    }

                    // Check if this word is an assignment (contains =)
                    // Only treat as assignment if no command words yet
                    if (words.items.len == 0 and std.mem.indexOfScalar(u8, self.current_token.value, '=') != null) {
                        const eq_pos = std.mem.indexOfScalar(u8, self.current_token.value, '=').?;
                        const token = self.current_token;

                        const name = token.value[0..eq_pos];
                        const value = token.value[eq_pos + 1 ..];

                        const assignment = try self.builder.createassignment(name, value, token.line, token.column);
                        try self.nextToken();

                        // collect as prefix — don't return yet, there may be a command following
                        try prefix_assignments.append(self.builder.arena.allocator(), assignment);
                        continue;
                    } else {
                        // Regular word (or assignment as argument to a command)
                        const word = try self.parseword();
                        try words.append(self.builder.arena.allocator(), word);
                    }
                },
                .String, .DoubleQuotedString => {
                    // Check if this quoted token is an assignment (VAR="value")
                    // Only treat as assignment if no command words yet
                    if (words.items.len == 0 and std.mem.indexOfScalar(u8, self.current_token.value, '=') != null) {
                        const eq_pos = std.mem.indexOfScalar(u8, self.current_token.value, '=').?;
                        const token = self.current_token;

                        const name = token.value[0..eq_pos];
                        const value = token.value[eq_pos + 1 ..];

                        const assignment = try self.builder.createassignment(name, value, token.line, token.column);
                        try self.nextToken();

                        // collect as prefix
                        try prefix_assignments.append(self.builder.arena.allocator(), assignment);
                        continue;
                    } else {
                        const word = try self.parseword();
                        try words.append(self.builder.arena.allocator(), word);
                    }
                },
                // process substitution <(cmd) or >(cmd)
                .ProcessSubstIn, .ProcessSubstOut => {
                    const token = self.current_token;
                    // store with marker prefix so eval can identify it
                    const prefix: []const u8 = if (token.ty == .ProcessSubstIn) "<(" else ">(";
                    const marked = try std.fmt.allocPrint(self.builder.arena.allocator(), "{s}{s})", .{ prefix, token.value });
                    const word = try self.builder.createword(marked, token.line, token.column);
                    try words.append(self.builder.arena.allocator(), word);
                    try self.nextToken();
                },
                // keywords can be used as arguments (e.g., "echo done")
                .Done, .Fi, .Else, .Elif, .Then, .Do, .In, .For, .While, .Until, .If, .Case, .Esac, .Function => {
                    if (words.items.len > 0) {
                        // treat keyword as word when it's an argument
                        const token = self.current_token;
                        const word = try self.builder.createword(token.value, token.line, token.column);
                        try words.append(self.builder.arena.allocator(), word);
                        try self.nextToken();
                    } else {
                        break; // keyword at start of command - not a simple command
                    }
                },
                else => break,
            }
        }

        // bare assignments with no command following — return as-is
        if (words.items.len == 0 and prefix_assignments.items.len > 0) {
            if (prefix_assignments.items.len == 1) {
                return prefix_assignments.items[0];
            }
            return self.builder.createlist(
                prefix_assignments.items,
                prefix_assignments.items[0].line,
                prefix_assignments.items[0].column,
            );
        }

        if (words.items.len == 0) {
            return error.EmptyCommand;
        }

        // if we have prefix assignments, build combined children:
        // [assign1, assign2, ..., word0, word1, ...]
        // and store assignment count in value field
        if (prefix_assignments.items.len > 0) {
            const allocator = self.builder.arena.allocator();
            const n_prefix = prefix_assignments.items.len;
            const total = n_prefix + words.items.len;

            var children = try allocator.alloc(*const ast.AstNode, total);
            @memcpy(children[0..n_prefix], prefix_assignments.items);
            @memcpy(children[n_prefix..total], words.items);

            // encode prefix count as value string
            var count_buf: [16]u8 = undefined;
            const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{n_prefix}) catch "0";

            var cmd = try self.builder.createnode(
                .command,
                count_str,
                children,
                children[n_prefix].line,
                children[n_prefix].column,
            );

            cmd = try self.parseredirects(cmd);
            return cmd;
        }

        var cmd = try self.builder.createcommand(
            words.items,
            words.items[0].line,
            words.items[0].column,
        );

        // parse any redirects attached to this command
        cmd = try self.parseredirects(cmd);

        return cmd;
    }

    fn parseredirects(self: *Self, base_cmd: *const ast.AstNode) parsererror!*const ast.AstNode {
        var cmd = base_cmd;

        while (true) {
            const redirect_type = switch (self.current_token.ty) {
                .RedirectOutput => ">",
                .RedirectAppend => ">>",
                .RedirectInput => "<",
                .RedirectStderr => "2>",
                .RedirectStderrAppend => "2>>",
                .RedirectBoth => "2>&1",
                .RedirectToStderr => ">&2",
                .RedirectAll => "&>",
                .RedirectAllAppend => "&>>",
                .RedirectHereDoc => "<<<",
                .RedirectHereDocLiteral => "<<",
                else => break,
            };

            const line = self.current_token.line;
            const column = self.current_token.column;
            try self.nextToken(); // consume redirect token

            // fd duplications don't need a target
            if (std.mem.eql(u8, redirect_type, "2>&1") or std.mem.eql(u8, redirect_type, ">&2")) {
                // create dummy target node for consistency
                const target = try self.builder.createword("", line, column);
                cmd = try self.builder.createredirect(cmd, redirect_type, target, line, column);
                continue;
            }

            // parse target (filename or fd)
            const target = try self.parseword();

            // wrap command in redirect node
            cmd = try self.builder.createredirect(cmd, redirect_type, target, line, column);
        }

        return cmd;
    }

    fn parseword(self: *Self) parsererror!*const ast.AstNode {
        if (self.state != .hasboth) return error.InvalidParserState;

        const token = self.current_token;

        // create node BEFORE nextToken to avoid buffer overwrite
        // (nextToken may reuse the buffer that token.value points to)
        const node = switch (token.ty) {
            .Word => try self.builder.createword(token.value, token.line, token.column),
            .DoubleQuotedString => try self.builder.createdoublequoted(token.value, token.line, token.column),
            .String => try self.builder.createstring(token.value, token.line, token.column),
            .ProcessSubstIn => blk: {
                const marked = try std.fmt.allocPrint(self.builder.arena.allocator(), "<({s})", .{token.value});
                break :blk try self.builder.createword(marked, token.line, token.column);
            },
            .ProcessSubstOut => blk: {
                const marked = try std.fmt.allocPrint(self.builder.arena.allocator(), ">({s})", .{token.value});
                break :blk try self.builder.createword(marked, token.line, token.column);
            },
            else => return error.UnexpectedToken,
        };

        try self.nextToken();
        return node;
    }

    // control structure parsing with bounds checking
    // Parse a condition (for if/while/until) as a full and-or list, allowing
    // pipelines, && / ||, [[ ]], and `!` negation. Consumes ; / newline
    // separators and stops at the terminator keyword (then / do).
    fn parseconditionlist(self: *Self, terminator: lexer.TokenType) parsererror!*const ast.AstNode {
        var commands = try std.ArrayList(*const ast.AstNode).initCapacity(self.builder.arena.allocator(), 8);

        while (true) {
            // skip empty statements
            while (self.current_token.ty == .Semicolon or self.current_token.ty == .NewLine) {
                try self.nextToken();
            }
            if (self.current_token.ty == terminator or self.current_token.ty == .Eof) break;

            const cmd = try self.parseandor();
            try commands.append(self.builder.arena.allocator(), cmd);

            // require a separator unless the terminator follows directly
            if (self.current_token.ty == .Semicolon or self.current_token.ty == .NewLine) {
                try self.nextToken();
            } else if (self.current_token.ty != terminator) {
                return error.UnexpectedToken;
            }
        }

        if (commands.items.len == 0) return error.EmptyCommand;
        if (commands.items.len == 1) return commands.items[0];
        return self.builder.createlist(
            commands.items,
            commands.items[0].line,
            commands.items[0].column,
        );
    }

    fn parseif(self: *Self) parsererror!*const ast.AstNode {
        const if_token = self.current_token;
        try self.nextToken(); // consume 'if'

        // parse condition (full and-or list up to 'then')
        const condition = try self.parseconditionlist(.Then);

        // expect 'then'
        if (self.current_token.ty != .Then) {
            return error.UnexpectedToken;
        }
        try self.nextToken(); // consume 'then'

        // parse then branch
        const then_branch = try self.parsecommandlist();

        var else_branch: ?*const ast.AstNode = null;

        // handle elif/else clause
        if (self.current_token.ty == .Elif) {
            // elif is like a nested if in the else branch
            else_branch = try self.parseif();
        } else if (self.current_token.ty == .Else) {
            try self.nextToken(); // consume 'else'
            else_branch = try self.parsecommandlist();

            // expect 'fi' after else
            if (self.current_token.ty != .Fi) {
                return error.UnexpectedToken;
            }
            try self.nextToken(); // consume 'fi'
        } else {
            // no else/elif, expect 'fi'
            if (self.current_token.ty != .Fi) {
                return error.UnexpectedToken;
            }
            try self.nextToken(); // consume 'fi'
        }

        return self.builder.createif(
            condition,
            then_branch,
            else_branch,
            if_token.line,
            if_token.column,
        );
    }

    fn parsewhile(self: *Self) parsererror!*const ast.AstNode {
        const while_token = self.current_token;
        try self.nextToken(); // consume 'while'

        const condition = try self.parseconditionlist(.Do);

        if (self.current_token.ty != .Do) {
            return error.UnexpectedToken;
        }
        try self.nextToken(); // consume 'do'

        const body = try self.parsecommandlist();

        if (self.current_token.ty != .Done) {
            return error.UnexpectedToken;
        }
        try self.nextToken(); // consume 'done'

        return self.builder.createwhile(
            condition,
            body,
            while_token.line,
            while_token.column,
        );
    }

    fn parseuntil(self: *Self) parsererror!*const ast.AstNode {
        const until_token = self.current_token;
        try self.nextToken(); // consume 'until'

        const condition = try self.parseconditionlist(.Do);

        if (self.current_token.ty != .Do) {
            return error.UnexpectedToken;
        }
        try self.nextToken(); // consume 'do'

        const body = try self.parsecommandlist();

        if (self.current_token.ty != .Done) {
            return error.UnexpectedToken;
        }
        try self.nextToken(); // consume 'done'

        return self.builder.createuntil(
            condition,
            body,
            until_token.line,
            until_token.column,
        );
    }

    fn parsefor(self: *Self) parsererror!*const ast.AstNode {
        const for_token = self.current_token;
        try self.nextToken(); // consume 'for'

        // parse variable name
        const variable = try self.parseword();

        var values = try std.ArrayList(*const ast.AstNode).initCapacity(self.builder.arena.allocator(), 32);

        // `for x; do ...` / `for x do ...` (no `in`) iterates over "$@"
        if (self.current_token.ty != .In) {
            if (self.current_token.ty == .Semicolon or self.current_token.ty == .NewLine or self.current_token.ty == .Do) {
                const at = try self.builder.createword("\"$@\"", for_token.line, for_token.column);
                try values.append(self.builder.arena.allocator(), at);
                // skip optional separator, then expect 'do'
                if (self.current_token.ty == .Semicolon or self.current_token.ty == .NewLine) {
                    try self.nextToken();
                }
                if (self.current_token.ty != .Do) {
                    return error.UnexpectedToken;
                }
                try self.nextToken(); // consume 'do'
                const body = try self.parsecommandlist();
                if (self.current_token.ty != .Done) {
                    return error.UnexpectedToken;
                }
                try self.nextToken(); // consume 'done'
                return self.builder.createfor(variable, values.items, body, for_token.line, for_token.column);
            }
            return error.UnexpectedToken;
        }
        try self.nextToken(); // consume 'in'

        // parse value list
        while (self.current_token.ty != .Semicolon and
            self.current_token.ty != .NewLine and
            self.current_token.ty != .Do and
            self.current_token.ty != .Eof)
        {
            if (values.items.len >= types.MAX_ARGS_COUNT) {
                return error.TooManyArguments;
            }

            const value = try self.parseword();
            try values.append(self.builder.arena.allocator(), value);
        }

        // skip optional separator
        if (self.current_token.ty == .Semicolon or self.current_token.ty == .NewLine) {
            try self.nextToken();
        }

        if (self.current_token.ty != .Do) {
            return error.UnexpectedToken;
        }
        try self.nextToken(); // consume 'do'

        const body = try self.parsecommandlist();

        if (self.current_token.ty != .Done) {
            return error.UnexpectedToken;
        }
        try self.nextToken(); // consume 'done'

        return self.builder.createfor(
            variable,
            values.items,
            body,
            for_token.line,
            for_token.column,
        );
    }

    fn parsecase(self: *Self) parsererror!*const ast.AstNode {
        const case_token = self.current_token;
        try self.nextToken(); // consume 'case'

        const expr = try self.parseword();

        if (self.current_token.ty != .In) {
            return error.UnexpectedToken;
        }
        try self.nextToken(); // consume 'in'

        // skip newlines after 'in'
        while (self.current_token.ty == .NewLine) {
            try self.nextToken();
        }

        // collect case items: [expr, item1, item2, ...]
        var children = try std.ArrayList(*const ast.AstNode).initCapacity(self.builder.arena.allocator(), 32);
        try children.append(self.builder.arena.allocator(), expr);

        // parse case items until esac
        while (self.current_token.ty != .Esac and self.current_token.ty != .Eof) {
            // skip whitespace/newlines between items
            while (self.current_token.ty == .NewLine or self.current_token.ty == .Semicolon) {
                try self.nextToken();
            }

            if (self.current_token.ty == .Esac) break;

            // parse case item
            const item = try self.parsecaseitem();
            try children.append(self.builder.arena.allocator(), item);
        }

        if (self.current_token.ty != .Esac) {
            return error.UnexpectedToken;
        }
        try self.nextToken(); // consume 'esac'

        return self.builder.createnode(
            .case_statement,
            "",
            children.items,
            case_token.line,
            case_token.column,
        );
    }

    fn parsecaseitem(self: *Self) parsererror!*const ast.AstNode {
        const item_token = self.current_token;
        const allocator = self.builder.arena.allocator();

        // optional leading '('
        if (self.current_token.ty == .LeftParen) {
            try self.nextToken();
        }

        // parse pattern(s) separated by '|'
        var pattern_buf = try std.ArrayList(u8).initCapacity(allocator, 64);

        // first pattern
        if (self.current_token.ty != .Word and self.current_token.ty != .String and
            self.current_token.ty != .DoubleQuotedString and self.current_token.ty != .ParameterExpansion)
        {
            return error.UnexpectedToken;
        }
        try pattern_buf.appendSlice(allocator, self.current_token.value);
        try self.nextToken();

        // additional patterns separated by '|'
        while (self.current_token.ty == .Pipe) {
            try self.nextToken(); // consume '|'
            try pattern_buf.append(allocator, '|');
            if (self.current_token.ty != .Word and self.current_token.ty != .String and
                self.current_token.ty != .DoubleQuotedString and self.current_token.ty != .ParameterExpansion)
            {
                return error.UnexpectedToken;
            }
            try pattern_buf.appendSlice(allocator, self.current_token.value);
            try self.nextToken();
        }

        // expect ')' after pattern
        if (self.current_token.ty != .RightParen) {
            return error.UnexpectedToken;
        }
        try self.nextToken(); // consume ')'

        // parse body (command list until ';;' or 'esac')
        const body = try self.parsecommandlist();

        // expect ';;' to terminate case item (optional before esac)
        if (self.current_token.ty == .DoubleSemi) {
            try self.nextToken(); // consume ';;'
        }

        return self.builder.createnode(
            .case_item,
            pattern_buf.items,
            &[_]*const ast.AstNode{body},
            item_token.line,
            item_token.column,
        );
    }

    fn parsegroup(self: *Self) parsererror!*const ast.AstNode {
        const brace_token = self.current_token;
        try self.nextToken(); // consume '{'

        const body = try self.parsecommandlist();

        if (self.current_token.ty != .RightBrace) {
            return error.UnexpectedToken;
        }
        try self.nextToken(); // consume '}'

        return self.builder.createnode(
            .list,
            "",
            &[_]*const ast.AstNode{body},
            brace_token.line,
            brace_token.column,
        );
    }

    fn parsesubshell(self: *Self) parsererror!*const ast.AstNode {
        const paren_token = self.current_token;
        try self.nextToken(); // consume '('

        const body = try self.parsecommandlist();

        if (self.current_token.ty != .RightParen) {
            return error.UnexpectedToken;
        }
        try self.nextToken(); // consume ')'

        return self.builder.createnode(
            .subshell,
            "",
            &[_]*const ast.AstNode{body},
            paren_token.line,
            paren_token.column,
        );
    }

    fn parsefunction(self: *Self) parsererror!*const ast.AstNode {
        const func_token = self.current_token;
        try self.nextToken(); // consume 'function'

        // expect function name
        if (self.current_token.ty != .Word) {
            return error.UnexpectedToken;
        }
        const name = self.current_token.value;
        try self.nextToken();

        // optional ()
        if (self.current_token.ty == .LeftParen) {
            try self.nextToken(); // consume '('
            if (self.current_token.ty != .RightParen) {
                return error.UnexpectedToken;
            }
            try self.nextToken(); // consume ')'
        }

        // expect { body }
        if (self.current_token.ty != .LeftBrace) {
            return error.UnexpectedToken;
        }
        const body = try self.parsegroup();

        return self.builder.createfunctiondef(name, body, func_token.line, func_token.column);
    }

    fn parsetest(self: *Self) parsererror!*const ast.AstNode {
        const test_token = self.current_token;
        try self.nextToken(); // consume '[['

        // collect all words until ]]
        var words = try std.ArrayList(*const ast.AstNode).initCapacity(self.builder.arena.allocator(), 16);

        while (self.current_token.ty != .TestClose and self.current_token.ty != .Eof) {
            switch (self.current_token.ty) {
                .Word, .String, .DoubleQuotedString, .ParameterExpansion, .CommandSubstitution, .ProcessSubstIn, .ProcessSubstOut => {
                    const word = try self.parseword();
                    try words.append(self.builder.arena.allocator(), word);
                },
                .NewLine => {
                    try self.nextToken();
                },
                else => {
                    // unexpected token in test expression
                    return error.UnexpectedToken;
                },
            }
        }

        if (self.current_token.ty != .TestClose) {
            return error.UnexpectedToken; // expected ]]
        }
        try self.nextToken(); // consume ']]'

        // store test expression as space-separated string
        var expr_buf: [1024]u8 = undefined;
        var expr_len: usize = 0;
        for (words.items, 0..) |word, i| {
            if (i > 0 and expr_len < expr_buf.len) {
                expr_buf[expr_len] = ' ';
                expr_len += 1;
            }
            const to_copy = @min(word.value.len, expr_buf.len - expr_len);
            @memcpy(expr_buf[expr_len..][0..to_copy], word.value[0..to_copy]);
            expr_len += to_copy;
        }

        return self.builder.createnode(
            .test_expression,
            expr_buf[0..expr_len],
            words.items,
            test_token.line,
            test_token.column,
        );
    }
};

// Parser size is acceptable for this use case
// Contains lexer state, arena allocator, and recursion tracking