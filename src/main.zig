// main.zig - zish shell implementation

const std = @import("std");
const build = @import("build.zig.zon");
const clap = @import("clap");
const Shell = @import("Shell.zig");
const build_options = @import("build_options");
const compat = @import("compat.zig");
const trace = @import("trace.zig");

pub fn main(init: std.process.Init) void {
    compat.setIo(init.io);
    trace.init();
    const allocator = init.gpa;

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, init.minimal.args, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.reportToFile(init.io, .stderr(), err) catch {};
        return;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        clap.helpToFile(init.io, .stdout(), clap.Help, &params, .{}) catch {};
        return;
    }

    if (res.args.version != 0) {
        var vbuf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&vbuf, "zish {s}\n", .{build.version}) catch "zish\n";
        compat.writeAll(.stdout(), line) catch {};
        return;
    }

    // determine if interactive mode
    const is_interactive = res.args.c == null and (res.positionals.len == 0 or res.positionals[0].len == 0);
    const load_config = is_interactive or res.args.login != 0;

    // initialize shell (load config for interactive or login mode)
    const shell_instance = (if (load_config)
        Shell.init(allocator)
    else
        Shell.initNonInteractive(allocator)) catch |err| {
        std.debug.print("zish: failed to initialize shell: {}\n", .{err});
        std.process.exit(1);
    };
    defer shell_instance.deinit();

    if (res.args.@"debug-log-file") |log_path| {
        shell_instance.log_file = if (std.fs.path.isAbsolute(log_path))
            std.Io.Dir.createFileAbsolute(compat.io(), log_path, .{}) catch |err| {
                std.debug.print("zish: failed to create log file: {}\n", .{err});
                std.process.exit(1);
            }
        else
            std.Io.Dir.cwd().createFile(compat.io(), log_path, .{}) catch |err| {
                std.debug.print("zish: failed to create log file: {}\n", .{err});
                std.process.exit(1);
            };
    }

    if (res.args.c) |command| {
        // set positional parameters if provided
        inline for (res.positionals, 0..) |positional_slice, idx| {
            for (positional_slice, 0..) |arg, arg_idx| {
                var buf: [32]u8 = undefined;
                const key = std.fmt.bufPrint(&buf, "{d}", .{idx * 100 + arg_idx}) catch continue;
                const key_copy = allocator.dupe(u8, key) catch continue;
                const val_copy = allocator.dupe(u8, arg) catch continue;
                shell_instance.variables.put(key_copy, val_copy) catch {};
            }
        }
        // $# = count of $1..$n ($0 excluded). Without this $#/$@/$* were empty.
        setPositionalCount(shell_instance, allocator, res.positionals);

        const exit_code = shell_instance.executeCommand(command) catch |err| {
            std.debug.print("zish: error executing command: {}\n", .{err});
            std.process.exit(1);
        };

        // Run any EXIT trap, then flush before exit.
        shell_instance.runExitTrap();
        shell_instance.stdout().flush() catch {};
        std.process.exit(exit_code);
    } else if (res.positionals.len > 0 and res.positionals[0].len > 0) {
        // script file mode
        const script_path = res.positionals[0][0];

        // set positional parameters: $0 is script name, $1+ are args
        inline for (res.positionals, 0..) |positional_slice, idx| {
            for (positional_slice, 0..) |arg, arg_idx| {
                var buf: [32]u8 = undefined;
                const key = std.fmt.bufPrint(&buf, "{d}", .{idx * 100 + arg_idx}) catch continue;
                const key_copy = allocator.dupe(u8, key) catch continue;
                const val_copy = allocator.dupe(u8, arg) catch continue;
                shell_instance.variables.put(key_copy, val_copy) catch {};
            }
        }
        // $# = count of $1..$n ($0/script name excluded).
        setPositionalCount(shell_instance, allocator, res.positionals);

        const script_content = std.Io.Dir.cwd().readFileAlloc(compat.io(), script_path, allocator, .limited(1024 * 1024)) catch |err| {
            std.debug.print("zish: cannot read script '{s}': {}\n", .{ script_path, err });
            std.process.exit(1);
        };
        defer allocator.free(script_content);

        const exit_code = shell_instance.executeCommand(script_content) catch |err| {
            std.debug.print("zish: error executing script: {}\n", .{err});
            std.process.exit(1);
        };
        shell_instance.runExitTrap();
        shell_instance.stdout().flush() catch {};
        std.process.exit(exit_code);
    } else {
        // interactive mode
        shell_instance.run() catch |err| {
            std.debug.print("zish: error in interactive mode: {}\n", .{err});
            std.process.exit(1);
        };
    }
}

// Set $# to the number of positional parameters ($1..$n). The loops above key
// arguments as $0 (command/script name), $1, $2, … so the count is the total
// number of arguments minus one. Without $#, $@/$*/$# and `for a in "$@"` were
// all empty in -c and script modes.
fn setPositionalCount(shell: *Shell, allocator: std.mem.Allocator, positionals: anytype) void {
    var total: usize = 0;
    inline for (positionals) |ps| total += ps.len;
    const n = if (total > 0) total - 1 else 0;
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
    const key = allocator.dupe(u8, "#") catch return;
    const val = allocator.dupe(u8, s) catch {
        allocator.free(key);
        return;
    };
    shell.variables.put(key, val) catch {
        allocator.free(key);
        allocator.free(val);
    };
}

const params = clap.parseParamsComptime(
    \\-h, --help                  Display this help and exit.
    \\-v, --version               print version and exit.
    \\-l, --login                 Start as login shell.
    \\-d, --debug-log-file <str>  file to write a debug info to.
    \\-c  <str>                   command to execute.
    \\<str>...
    \\
);

test {
    std.testing.refAllDecls(@This());
}
