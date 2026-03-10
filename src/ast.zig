// secure_ast.zig - immutable ast with arena allocation

const std = @import("std");

// immutable node types
pub const NodeType = enum {
    command,
    pipeline,
    logical_and, // &&
    logical_or, // ||
    list,
    subshell,
    background, // &
    if_statement,
    while_loop,
    until_loop,
    for_loop,
    case_statement,
    case_item,  // pattern) body;;
    function_def,
    assignment,
    redirect, // >, >>, <, 2>, 2>>, 2>&1, >&2, &>, &>>
    test_expression, // [[ ... ]]
    word,
    double_quoted, // double-quoted string: expand vars/cmds but no word splitting or glob
    string,
    number,
};

// immutable ast node - no cleanup needed, arena handles lifetime
pub const AstNode = struct {
    node_type: NodeType,
    value: []const u8,  // slice into arena memory
    children: []const *const AstNode,  // const pointers to const data
    line: u32,
    column: u32,

    // const empty node for safe defaults
    pub const empty = AstNode{
        .node_type = .word,
        .value = "",
        .children = &[_]*const AstNode{},
        .line = 0,
        .column = 0,
    };

    pub fn iscommand(self: *const AstNode) bool {
        return self.node_type == .command;
    }

    pub fn iscontrol(self: *const AstNode) bool {
        return switch (self.node_type) {
            .if_statement, .while_loop, .until_loop, .for_loop, .case_statement => true,
            else => false,
        };
    }

    // safe child access with bounds checking
    pub fn getchild(self: *const AstNode, index: usize) ?*const AstNode {
        if (index >= self.children.len) return null;
        return self.children[index];
    }

    pub fn childcount(self: *const AstNode) usize {
        return self.children.len;
    }

    // Deep clone AST node into a different allocator (for persistent storage)
    pub fn clone(self: *const AstNode, allocator: std.mem.Allocator) !*AstNode {
        // Clone value
        const value_copy = try allocator.dupe(u8, self.value);
        errdefer allocator.free(value_copy);

        // Clone children recursively
        const children_copy = try allocator.alloc(*const AstNode, self.children.len);
        errdefer allocator.free(children_copy);

        for (self.children, 0..) |child, i| {
            children_copy[i] = try child.clone(allocator);
        }

        // Create new node
        const node = try allocator.create(AstNode);
        node.* = .{
            .node_type = self.node_type,
            .value = value_copy,
            .children = children_copy,
            .line = self.line,
            .column = self.column,
        };
        return node;
    }

    // Free a cloned AST node and all its children
    pub fn destroy(self: *const AstNode, allocator: std.mem.Allocator) void {
        // Free children first (recursively)
        for (self.children) |child| {
            child.destroy(allocator);
        }
        allocator.free(self.children);
        allocator.free(self.value);
        // Cast away const to free (safe because we allocated this)
        const mutable_self: *AstNode = @constCast(self);
        allocator.destroy(mutable_self);
    }
};

// typestate-based ast builder with security guarantees
pub const AstBuilder = struct {
    arena: std.heap.ArenaAllocator,
    depth: u8,
    node_count: u32,  // prevent ast explosion

    const max_nodes = 1024;  // prevent dos via massive asts
    const Self = @This();

    pub fn init(parent_allocator: std.mem.Allocator) Self {
        return Self{
            .arena = std.heap.ArenaAllocator.init(parent_allocator),
            .depth = 0,
            .node_count = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        // arena cleanup handles everything - no double-free possible
        self.arena.deinit();
    }

    pub fn createnode(
        self: *Self,
        node_type: NodeType,
        value: []const u8,
        children: []const *const AstNode,
        line: u32,
        column: u32,
    ) !*const AstNode {
        // prevent ast explosion attacks
        if (self.node_count >= max_nodes) {
            return error.AstTooComplex;
        }

        // prevent stack overflow in traversal
        if (self.depth >= 64) {
            return error.ParseTooDeep;
        }

        const allocator = self.arena.allocator();

        // bounds check children array
        if (children.len > 256) {
            return error.TooManyChildren;
        }

        const node = try allocator.create(AstNode);
        node.* = AstNode{
            .node_type = node_type,
            .value = try allocator.dupe(u8, value),  // copy into arena
            .children = try allocator.dupe(*const AstNode, children),  // copy array
            .line = line,
            .column = column,
        };

        self.node_count += 1;
        return node;
    }

    pub fn createword(self: *Self, value: []const u8, line: u32, column: u32) !*const AstNode {
        // TODO: add validation if needed
        return self.createnode(.word, value, &[_]*const AstNode{}, line, column);
    }

    pub fn createdoublequoted(self: *Self, value: []const u8, line: u32, column: u32) !*const AstNode {
        return self.createnode(.double_quoted, value, &[_]*const AstNode{}, line, column);
    }

    pub fn createstring(self: *Self, value: []const u8, line: u32, column: u32) !*const AstNode {
        return self.createnode(.string, value, &[_]*const AstNode{}, line, column);
    }

    pub fn createcommand(self: *Self, words: []const *const AstNode, line: u32, column: u32) !*const AstNode {
        if (words.len == 0) return error.EmptyCommand;
        return self.createnode(.command, "", words, line, column);
    }

    pub fn createassignment(self: *Self, name: []const u8, value: []const u8, line: u32, column: u32) !*const AstNode {
        // Create variable name and value nodes
        const name_node = try self.createword(name, line, column);
        const value_node = try self.createstring(value, line, column);

        const children = [_]*const AstNode{ name_node, value_node };
        return self.createnode(.assignment, "", &children, line, column);
    }

    pub fn createif(self: *Self, condition: *const AstNode, then_branch: *const AstNode, else_branch: ?*const AstNode, line: u32, column: u32) !*const AstNode {
        self.depth += 1;
        defer self.depth -= 1;

        var children_buf: [3]*const AstNode = undefined;
        var child_count: usize = 2;

        children_buf[0] = condition;
        children_buf[1] = then_branch;

        if (else_branch) |else_node| {
            children_buf[2] = else_node;
            child_count = 3;
        }

        return self.createnode(.if_statement, "", children_buf[0..child_count], line, column);
    }

    pub fn createwhile(self: *Self, condition: *const AstNode, body: *const AstNode, line: u32, column: u32) !*const AstNode {
        self.depth += 1;
        defer self.depth -= 1;

        const children = [_]*const AstNode{ condition, body };
        return self.createnode(.while_loop, "", &children, line, column);
    }

    pub fn createfor(self: *Self, variable: *const AstNode, values: []const *const AstNode, body: *const AstNode, line: u32, column: u32) !*const AstNode {
        self.depth += 1;
        defer self.depth -= 1;

        const allocator = self.arena.allocator();

        // create children array: [variable, value1, value2, ..., body]
        var children = try allocator.alloc(*const AstNode, values.len + 2);
        children[0] = variable;
        @memcpy(children[1..values.len + 1], values);
        children[children.len - 1] = body;

        return self.createnode(.for_loop, "", children, line, column);
    }

    pub fn createpipeline(self: *Self, commands: []const *const AstNode, line: u32, column: u32) !*const AstNode {
        if (commands.len < 2) return error.InvalidPipeline;
        return self.createnode(.pipeline, "", commands, line, column);
    }

    pub fn createlogicaland(self: *Self, left: *const AstNode, right: *const AstNode, line: u32, column: u32) !*const AstNode {
        const children = [_]*const AstNode{ left, right };
        return self.createnode(.logical_and, "&&", &children, line, column);
    }

    pub fn createlogicalor(self: *Self, left: *const AstNode, right: *const AstNode, line: u32, column: u32) !*const AstNode {
        const children = [_]*const AstNode{ left, right };
        return self.createnode(.logical_or, "||", &children, line, column);
    }

    pub fn createbackground(self: *Self, command: *const AstNode, line: u32, column: u32) !*const AstNode {
        const children = [_]*const AstNode{command};
        return self.createnode(.background, "&", &children, line, column);
    }

    pub fn createredirect(self: *Self, command: *const AstNode, redirect_type: []const u8, target: *const AstNode, line: u32, column: u32) !*const AstNode {
        const children = [_]*const AstNode{ command, target };
        return self.createnode(.redirect, redirect_type, &children, line, column);
    }

    pub fn createlist(self: *Self, commands: []const *const AstNode, line: u32, column: u32) !*const AstNode {
        return self.createnode(.list, "", commands, line, column);
    }

    pub fn createfunctiondef(self: *Self, name: []const u8, body: *const AstNode, line: u32, column: u32) !*const AstNode {
        const children = [_]*const AstNode{body};
        return self.createnode(.function_def, name, &children, line, column);
    }

    // secure ast traversal with stack overflow protection
    pub fn traverse(node: *const AstNode, visitor: *const astvisitor, depth: u8) !void {
        if (depth >= 64) {
            return error.traversaltooDeep;
        }

        try visitor.visit(node);

        for (node.children) |child| {
            try traverse(child, visitor, depth + 1);
        }
    }
};

// visitor pattern for safe ast traversal
pub const astvisitor = struct {
    visit_fn: *const fn (node: *const AstNode) anyerror!void,

    pub fn visit(self: *const astvisitor, node: *const AstNode) !void {
        return self.visit_fn(node);
    }
};

// security-focused ast validation
pub fn validateast(root: *const AstNode) !void {
    const validator = astvisitor{
        .visit_fn = validatenode,
    };

    try AstBuilder.traverse(root, &validator, 0);
}

fn validatenode(node: *const AstNode) !void {
    // validate node structure
    switch (node.node_type) {
        .command => {
            if (node.children.len == 0) return error.EmptyCommand;
            // parse prefix assignment count from value field
            const n_prefix: usize = if (node.value.len > 0)
                std.fmt.parseInt(usize, node.value, 10) catch 0
            else
                0;
            // first non-prefix child must be a word (command name)
            if (n_prefix < node.children.len) {
                const cmd_child = node.children[n_prefix];
                if (cmd_child.node_type != .word and cmd_child.node_type != .double_quoted and cmd_child.node_type != .string) {
                    return error.InvalidCommandName;
                }
            }
        },
        .if_statement => {
            if (node.children.len < 2) return error.InvalidIf;
        },
        .while_loop, .until_loop => {
            if (node.children.len != 2) return error.InvalidLoop;
        },
        .for_loop => {
            if (node.children.len < 3) return error.InvalidFor;
        },
        .pipeline => {
            if (node.children.len < 2) return error.InvalidPipeline;
        },
        else => {},
    }

    // validate value content for security
    // TODO: add validation if needed
}

// compile-time security checks
comptime {
    if (@sizeOf(AstNode) > 64) {
        @compileError("ast node too large - potential memory exhaustion");
    }
}