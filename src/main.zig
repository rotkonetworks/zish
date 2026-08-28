// main.zig - zish shell implementation

const std = @import("std");
const build = @import("build.zig.zon");
const cli = @import("cli.zig");
const Shell = @import("Shell.zig");
const build_options = @import("build_options");
const compat = @import("compat.zig");
const trace = @import("trace.zig");

pub fn main(init: std.process.Init) void {
    compat.setIo(init.io);
    trace.init();
    const allocator = init.gpa;

    const argv = init.minimal.args.toSlice(allocator) catch {
        std.debug.print("zish: cannot read arguments\n", .{});
        std.process.exit(1);
    };

    const res = cli.parse(&params, argv) catch |err| {
        var eb: [256]u8 = undefined;
        const msg = switch (err) {
            error.MissingValue => std.fmt.bufPrint(&eb, "zish: option requires an argument: {s}\n", .{res_bad(argv)}) catch "zish: bad arguments\n",
            else => std.fmt.bufPrint(&eb, "zish: unrecognized option: {s}\n", .{res_bad(argv)}) catch "zish: bad arguments\n",
        };
        compat.writeAll(.stderr(), msg) catch {};
        std.process.exit(2);
    };

    if (res.isSet("help")) {
        var hbuf: [1024]u8 = undefined;
        const text = cli.renderHelp(&params, "usage: zish [options] [script [args...]]", &hbuf);
        compat.writeAll(.stdout(), text) catch {};
        return;
    }

    if (res.isSet("version")) {
        var vbuf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&vbuf, "zish {s}\n", .{build.version}) catch "zish\n";
        compat.writeAll(.stdout(), line) catch {};
        return;
    }

    // determine if interactive mode
    const is_interactive = res.value("c") == null and res.positionals.len == 0;
    const load_config = is_interactive or res.isSet("login");

    // initialize shell (load config for interactive or login mode)
    const shell_instance = (if (load_config)
        Shell.init(allocator)
    else
        Shell.initNonInteractive(allocator)) catch |err| {
        std.debug.print("zish: failed to initialize shell: {}\n", .{err});
        std.process.exit(1);
    };
    defer shell_instance.deinit();

    if (res.value("debug-log-file")) |log_path| {
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

    if (res.value("c")) |command| {
        setPositionals(shell_instance, allocator, res.positionals);
        // $# = count of $1..$n ($0 excluded). Without this $#/$@/$* were empty.
        const exit_code = shell_instance.executeCommand(command) catch |err| {
            std.debug.print("zish: error executing command: {}\n", .{err});
            std.process.exit(1);
        };

        // Run any EXIT trap, then flush before exit.
        shell_instance.runExitTrap();
        shell_instance.stdout().flush() catch {};
        std.process.exit(exit_code);
    } else if (res.positionals.len > 0) {
        // script file mode
        const script_path = res.positionals[0];
        setPositionals(shell_instance, allocator, res.positionals);

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

// Bind positional parameters: $0 is the command or script name, $1.. are its
// arguments, and $# is the count excluding $0. Without $#, `$@`/`$*`/`$#` and
// `for a in "$@"` were all empty in -c and script modes.
//
// clap returned positionals as a *tuple* of slices, which forced an `inline
// for` and the `idx * 100 + arg_idx` key arithmetic. A flat slice makes this a
// plain loop.
fn setPositionals(shell: *Shell, allocator: std.mem.Allocator, positionals: []const []const u8) void {
    for (positionals, 0..) |arg, i| {
        var kbuf: [16]u8 = undefined;
        const key = std.fmt.bufPrint(&kbuf, "{d}", .{i}) catch continue;
        const key_copy = allocator.dupe(u8, key) catch continue;
        const val_copy = allocator.dupe(u8, arg) catch {
            allocator.free(key_copy);
            continue;
        };
        shell.variables.put(key_copy, val_copy) catch {
            allocator.free(key_copy);
            allocator.free(val_copy);
        };
    }

    const n = if (positionals.len > 0) positionals.len - 1 else 0;
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

const params = [_]cli.Flag{
    .{ .short = 'h', .long = "help", .help = "Display this help and exit." },
    .{ .short = 'v', .long = "version", .help = "Print version and exit." },
    .{ .short = 'l', .long = "login", .help = "Start as a login shell." },
    .{ .short = 'd', .long = "debug-log-file", .help = "File to write debug info to.", .takes_value = true, .value_name = "FILE" },
    .{ .short = 'c', .help = "Command to execute.", .takes_value = true, .value_name = "CMD" },
};

/// Best-effort "which argument was bad" for the error message. cli.parse
/// reports it in the Result, but the Result is gone on the error path, so
/// find the first thing that looks like an unknown option.
fn res_bad(argv: []const []const u8) []const u8 {
    for (argv[1..]) |a| {
        if (a.len >= 2 and a[0] == '-' and !std.mem.eql(u8, a, "--")) return a;
    }
    return "";
}

test {
    std.testing.refAllDecls(@This());
}
