// main.zig - zish shell implementation

const std = @import("std");
const builtin = @import("builtin");
const build = @import("build.zig.zon");
const cli = @import("cli.zig");
const sandbox = @import("sandbox.zig");
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

    // Capability restriction, applied before anything runs.
    //
    // Session-scoped rather than per-command, because Landlock is inherited
    // across exec and cannot be relaxed: restricting the shell restricts
    // everything it will ever spawn, with no way for a child to opt out. That
    // is the property an agent actually wants — "this whole session may not
    // write outside here" — and it is stronger than anything a per-command
    // flag could offer.
    //
    // Fail closed. If restriction was requested and the kernel cannot enforce
    // it, refuse to run rather than running unrestricted: a caller that asked
    // for a sandbox and silently did not get one is worse off than one that
    // never asked.
    if (res.value("profile")) |pname| {
        const profile = sandbox.Profile.fromString(pname) orelse {
            var eb: [128]u8 = undefined;
            const m = std.fmt.bufPrint(&eb, "zish: unknown profile '{s}' (none|readonly|workdir)\n", .{pname}) catch "zish: unknown profile\n";
            compat.writeAll(.stderr(), m) catch {};
            std.process.exit(2);
        };

        // Write roots: the working directory for `workdir`, plus anything
        // `--allow-write` named. Wrapping an agent harness is the motivating
        // case — the harness needs its own state directory writable (`~/.claude`,
        // `$HERMES_HOME`, a cache dir) or it breaks in ways that look like bugs
        // in the harness rather than the sandbox.
        var root_bufs: [max_write_roots][std.fs.max_path_bytes]u8 = undefined;
        var roots: [max_write_roots][*:0]const u8 = undefined;
        var n: usize = 0;

        if (profile == .workdir) {
            const cwd = compat.posix.getcwd(&root_bufs[0]) catch |err| {
                var eb: [96]u8 = undefined;
                const m = std.fmt.bufPrint(&eb, "zish: cannot read working directory: {s}\n", .{@errorName(err)}) catch "zish: cannot read working directory\n";
                compat.writeAll(.stderr(), m) catch {};
                std.process.exit(1);
            };
            root_bufs[0][cwd.len] = 0;
            roots[0] = @ptrCast(&root_bufs[0]);
            n = 1;
        }

        if (res.value("allow-write")) |list| {
            // Only meaningful when something is being restricted. Silently
            // accepting it under `none` would tell a caller their write roots
            // were honoured when nothing was ever enforced.
            if (profile == .unrestricted) {
                compat.writeAll(.stderr(), "zish: --allow-write needs a restrictive --profile (readonly|workdir)\n") catch {};
                std.process.exit(2);
            }
            var it = std.mem.splitScalar(u8, list, ':');
            while (it.next()) |seg| {
                if (seg.len == 0) continue; // trailing or doubled ':'
                if (n == max_write_roots) {
                    compat.writeAll(.stderr(), "zish: too many --allow-write paths (max 8)\n") catch {};
                    std.process.exit(2);
                }
                if (seg.len >= std.fs.max_path_bytes) {
                    compat.writeAll(.stderr(), "zish: --allow-write path too long\n") catch {};
                    std.process.exit(2);
                }
                @memcpy(root_bufs[n][0..seg.len], seg);
                root_bufs[n][seg.len] = 0;
                const pathz: [*:0]const u8 = @ptrCast(&root_bufs[n]);
                // A path that cannot be granted is fatal, not skipped. The
                // caller asked for it by name; quietly narrowing the sandbox
                // hands them a session that fails later, somewhere else.
                if (compat.posix.statPath(pathz, true) == null) {
                    var eb: [256]u8 = undefined;
                    const m = std.fmt.bufPrint(&eb, "zish: --allow-write path does not exist: {s}\n", .{seg}) catch "zish: --allow-write path does not exist\n";
                    compat.writeAll(.stderr(), m) catch {};
                    std.process.exit(2);
                }
                roots[n] = pathz;
                n += 1;
            }
        }

        sandbox.apply(profile, roots[0..n]) catch |err| {
            var eb: [160]u8 = undefined;
            const m = std.fmt.bufPrint(&eb, "zish: cannot enforce --profile {s}: {s}\n", .{ pname, @errorName(err) }) catch "zish: cannot enforce profile\n";
            compat.writeAll(.stderr(), m) catch {};
            std.process.exit(1);
        };
    } else if (res.isSet("allow-write")) {
        compat.writeAll(.stderr(), "zish: --allow-write needs a restrictive --profile (readonly|workdir)\n") catch {};
        std.process.exit(2);
    }

    if (res.isSet("version")) {
        // The build mode is part of the version because it changes the
        // security properties, not just the speed: ReleaseFast removes the
        // bounds, overflow and alignment checks that turn a memory bug into a
        // clean abort. Anyone filing a bug — or deciding whether to let an
        // agent drive this — needs to know which one they are running.
        var vbuf: [96]u8 = undefined;
        const line = std.fmt.bufPrint(&vbuf, "zish {s} ({s})\n", .{ build.version, @tagName(builtin.mode) }) catch "zish\n";
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
    .{ .long = "profile", .help = "Restrict what commands may touch: none|readonly|workdir.", .takes_value = true, .value_name = "NAME" },
    .{ .long = "allow-write", .help = "Extra writable paths for --profile, ':'-separated.", .takes_value = true, .value_name = "PATHS" },
};

/// Write roots the sandbox will accept. One for the working directory plus
/// room for the handful a wrapped program needs; past that the command line
/// is describing a policy that wants a file, not a flag.
const max_write_roots = 8;

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
