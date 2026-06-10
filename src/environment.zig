// environment.zig - environment variable management with memory safety

const std = @import("std");
const compat = @import("compat.zig");
const types = @import("types.zig");

// environment variable management system
pub const Environment = struct {
    arena: std.heap.ArenaAllocator,
    capabilities: std.EnumSet(types.EnvironmentCapability),
    variables: std.HashMap(types.InternedString, []const u8, stringcontext, 80),
    current_dir: []const u8,
    exit_status: i32,

    const Self = @This();
    const stringcontext = struct {
        pub fn hash(_: @This(), s: types.InternedString) u64 {
            return std.hash_map.hashString(s.data);
        }
        pub fn eql(_: @This(), a: types.InternedString, b: types.InternedString) bool {
            return a.eql(b);
        }
    };

    pub fn init(parent_allocator: std.mem.Allocator, caps: std.EnumSet(types.EnvironmentCapability)) !*Self {
        var arena = std.heap.ArenaAllocator.init(parent_allocator);
        const allocator = arena.allocator();

        const env = try allocator.create(Self);
        env.* = .{
            .arena = arena,
            .capabilities = caps,
            .variables = std.HashMap(types.InternedString, []const u8, stringcontext, 80).init(allocator),
            .current_dir = try std.Io.Dir.cwd().realPathFileAlloc(compat.io(), ".", allocator),
            .exit_status = 0,
        };

        // safely import only permitted environment variables
        try env.importsystemenv();
        return env;
    }

    pub fn deinit(self: *Self) void {
        // arena cleanup handles all memory - no double-free possible
        self.arena.deinit();
    }

    pub fn get(self: *Self, name: []const u8) ?[]const u8 {
        const interned = types.InternedString{ .data = name };
        return self.variables.get(interned);
    }

    pub fn set(self: *Self, name: []const u8, value: []const u8) !void {
        try types.validateShellSafe(name);
        try types.validateShellSafe(value);

        if (value.len > types.MAX_ENV_VALUE_LENGTH) {
            return error.EnvironmentValueTooLong;
        }

        const allocator = self.arena.allocator();
        const name_copy = try allocator.dupe(u8, name);
        const value_copy = try allocator.dupe(u8, value);

        const interned_name = types.InternedString{ .data = name_copy };

        // arena-based allocation means no need to free old values
        try self.variables.put(interned_name, value_copy);
    }

    pub fn unset(self: *Self, name: []const u8) bool {
        const interned = types.InternedString{ .data = name };
        return self.variables.remove(interned);
    }

    pub fn getcurrentdir(self: *Self) []const u8 {
        return self.current_dir;
    }

    pub fn setcurrentdir(self: *Self, path: []const u8) !void {
        try types.validateShellSafe(path);

        const allocator = self.arena.allocator();
        const new_path = std.Io.Dir.cwd().realPathFileAlloc(compat.io(), path, allocator) catch |err| {
            return err;
        };

        self.current_dir = new_path;
        try self.set("pwd", new_path);
    }

    pub fn expandvariable(self: *Self, name: []const u8) ![]const u8 {
        // handle special variables with arena allocation - no stack return issues
        const allocator = self.arena.allocator();

        if (std.mem.eql(u8, name, "?")) {
            return std.fmt.allocPrint(allocator, "{}", .{self.exit_status});
        }
        if (std.mem.eql(u8, name, "pwd")) {
            return self.current_dir;
        }

        return self.get(name) orelse "";
    }

    // capability-restricted environment import
    fn importsystemenv(self: *Self) !void {
        if (self.capabilities.contains(.ReadUserInfo)) {
            try self.importsafeenvvars(&[_][]const u8{ "home", "user" });
        }

        if (self.capabilities.contains(.ReadLocale)) {
            try self.importsafeenvvars(&[_][]const u8{ "lang", "lc_all" });
        }

        if (self.capabilities.contains(.ReadTerminal)) {
            try self.importsafeenvvars(&[_][]const u8{ "term" });
        }

        if (self.capabilities.contains(.ReadPath)) {
            // restricted path import - validate each component
            if (compat.posix.getenv("path")) |path_value| {
                const clean_path = try self.sanitizepath(path_value);
                try self.set("path", clean_path);
            }
        }

        // always set safe defaults
        try self.set("pwd", self.current_dir);
        try self.set("shell", "/bin/zish");
    }

    fn importsafeenvvars(self: *Self, var_names: []const []const u8) !void {
        for (var_names) |var_name| {
            if (compat.posix.getenv(var_name)) |value| {
                const clean_value = try self.sanitizeenvvalue(value);
                try self.set(var_name, clean_value);
            }
        }
    }

    fn sanitizeenvvalue(self: *Self, value: []const u8) ![]const u8 {
        // length limit
        if (value.len > types.MAX_ENV_VALUE_LENGTH) {
            return error.EnvironmentValueTooLong;
        }

        // reject dangerous characters
        for (value) |c| {
            switch (c) {
                // allow safe characters
                'a'...'z', 'A'...'Z', '0'...'9', '/', '-', '_', '.', ':' => {},
                // reject everything else including shell metacharacters
                else => return error.UnsafeEnvironmentValue,
            }
        }

        return self.arena.allocator().dupe(u8, value);
    }

    fn sanitizepath(self: *Self, path_value: []const u8) ![]const u8 {
        const allocator = self.arena.allocator();
        var safe_paths: std.ArrayList([]const u8) = .empty;

        var path_iter = std.mem.splitScalar(u8, path_value, ':');
        while (path_iter.next()) |path_component| {
            // only allow safe path components
            if (self.ispathsafe(path_component)) {
                try safe_paths.append(allocator, try allocator.dupe(u8, path_component));
            }
        }

        return std.mem.join(allocator, ":", safe_paths.items);
    }

    fn ispathsafe(self: *Self, path: []const u8) bool {
        _ = self;

        // reject dangerous paths
        if (path.len == 0) return false;
        if (std.mem.startsWith(u8, path, "/tmp")) return false;  // temp dirs unsafe
        if (std.mem.indexOfScalar(u8, path, ' ')) |_| return false;  // spaces unsafe
        if (path[0] == '.') return false;  // relative paths unsafe
        if (path[0] != '/') return false;  // must be absolute

        // basic validation - only standard system paths
        const safe_prefixes = [_][]const u8{
            "/usr/bin", "/usr/local/bin", "/bin", "/sbin",
        };

        for (safe_prefixes) |prefix| {
            if (std.mem.startsWith(u8, path, prefix)) return true;
        }

        return false;
    }

    pub fn setexitstatus(self: *Self, status: i32) void {
        self.exit_status = status;
    }

    pub fn getexitstatus(self: *Self) i32 {
        return self.exit_status;
    }

    // secure environment export for external commands
    pub fn getenvp(self: *Self) ![][*:0]const u8 {
        const allocator = self.arena.allocator();
        var env_array: std.ArrayList([*:0]const u8) = .empty;

        var iterator = self.variables.iterator();
        while (iterator.next()) |entry| {
            // create null-terminated environment string
            const env_str = try std.fmt.allocPrintSentinel(allocator, "{s}={s}", .{
                entry.key_ptr.data,
                entry.value_ptr.*,
            }, 0);
            try env_array.append(allocator, env_str.ptr);
        }

        return env_array.toOwnedSlice(allocator);
    }
};

// compile-time security invariants
comptime {
    // ensure environment cannot be used to bypass security
    if (@sizeOf(types.InternedString) > 16) {
        @compileError("interned strings too large - potential dos vector");
    }
}