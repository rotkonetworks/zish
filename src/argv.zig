//! argv.zig — the one owner for building an `execvpe` argument vector.
//!
//! The argument count of a command is unbounded: a glob expands to however many
//! paths match, and there is no length at which a shell may decide the user did
//! not really mean it. A fixed array therefore cannot be correct here. The
//! 256-slot buffers this replaces did not merely refuse a longer argv — one of
//! them silently dropped the tail of the argument list, so a command ran with
//! arguments the user never chose to omit, and the error text for the other
//! went to stdout where a pipeline read it as data. Allocating argv at its
//! exact size makes "too many arguments" a state this shell cannot reach.

const std = @import("std");

pub const Argv = struct {
    /// `args.len + 1` pointers; the last is the null terminator.
    ptrs: []?[*:0]const u8,
    /// Owned NUL-terminated copies. Empty when the input was already terminated.
    arena: []u8,
    alloc: std.mem.Allocator,

    /// The `[*:null]` view `execvpeZ` takes.
    pub fn view(self: Argv) [*:null]const ?[*:0]const u8 {
        return @ptrCast(self.ptrs.ptr);
    }

    pub fn deinit(self: Argv) void {
        self.alloc.free(self.ptrs);
        if (self.arena.len != 0) self.alloc.free(self.arena);
    }
};

/// Build argv from slices that are already NUL-terminated — the parser's tokens
/// and the expansion output — so only the pointer array is allocated.
pub fn fromSentinel(alloc: std.mem.Allocator, args: []const [:0]const u8) !Argv {
    const ptrs = try alloc.alloc(?[*:0]const u8, args.len + 1);
    errdefer alloc.free(ptrs);
    for (args, 0..) |arg, i| ptrs[i] = arg.ptr;
    ptrs[args.len] = null;
    return .{ .ptrs = ptrs, .arena = &.{}, .alloc = alloc };
}

/// Build argv from raw slices, copying each into one owned, NUL-terminated
/// arena. Use this whenever the input is a plain slice: AST node values and
/// manifest fields are *not* terminated, and handing their `.ptr` to
/// `execvpeZ` reads past the slice into whatever bytes follow in memory.
pub fn fromSlices(alloc: std.mem.Allocator, args: []const []const u8) !Argv {
    var total: usize = 0;
    for (args) |arg| total += arg.len + 1;
    const arena = try alloc.alloc(u8, total);
    errdefer alloc.free(arena);
    const ptrs = try alloc.alloc(?[*:0]const u8, args.len + 1);
    errdefer alloc.free(ptrs);

    var pos: usize = 0;
    for (args, 0..) |arg, i| {
        @memcpy(arena[pos..][0..arg.len], arg);
        arena[pos + arg.len] = 0;
        ptrs[i] = @ptrCast(arena[pos..].ptr);
        pos += arg.len + 1;
    }
    ptrs[args.len] = null;
    return .{ .ptrs = ptrs, .arena = arena, .alloc = alloc };
}
