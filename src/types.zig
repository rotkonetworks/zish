// secure_types.zig - memory-safe core types and bounds

const std = @import("std");
const compat = @import("compat.zig");

// compile-time security bounds
pub const MAX_COMMAND_LENGTH = 64 * 1024;
pub const MAX_TOKEN_LENGTH = 1024;
pub const MAX_RECURSION_DEPTH = 32;
pub const MAX_ARGS_COUNT = 256;

pub const MAX_PROMPT_LENGTH =
    std.fs.max_path_bytes +
    std.fs.max_name_bytes +
    compat.posix.HOST_NAME_MAX + 265;

// secure integer types to prevent overflow
pub const RecursionDepth = u8;

// bounds-checked operations
pub fn checkedAdd(comptime T: type, a: T, b: T) !T {
    const result = @as(u64, a) + @as(u64, b);
    if (result > std.math.maxInt(T)) return error.IntegerOverflow;
    return @intCast(result);
}

// secure string validation
pub fn validateShellSafe(input: []const u8) !void {
    if (input.len > MAX_COMMAND_LENGTH) return error.InputTooLong;

    for (input) |c| {
        // reject dangerous characters
        switch (c) {
            0...31 => if (c != '\t' and c != '\n') return error.ControlCharacter,
            127 => return error.DeleteCharacter,
            else => {},
        }
    }
}

// error types with security context
pub const SecurityError = error{
    IntegerOverflow,
    InputTooLong,
    ControlCharacter,
    DeleteCharacter,
    RecursionLimitExceeded,
    MemoryLimitExceeded,
    InsufficientCapability,
    UnsafeEnvironmentValue,
    CommandNotAllowed,
    InvalidParserState,
};

// compile-time assertions for security invariants
comptime {
    if (MAX_TOKEN_LENGTH > MAX_COMMAND_LENGTH) {
        @compileError("token length cannot exceed command length");
    }
    if (MAX_RECURSION_DEPTH > 255) {
        @compileError("recursion depth must fit in u8");
    }
}
