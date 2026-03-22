// main.zig - zish shell implementation

const std = @import("std");
const build = @import("build.zig.zon");
const clap = @import("clap");
const Shell = @import("Shell.zig");
const build_options = @import("build_options");

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .allocator = gpa.allocator(),
    }) catch |err| {
        diag.reportToFile(.stderr(), err) catch {};
        return;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        clap.helpToFile(.stdout(), clap.Help, &params, .{}) catch {};
        return;
    }

    if (res.args.version != 0) {
        std.debug.print("zish {s}\n", .{build.version});
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
            std.fs.createFileAbsolute(log_path, .{}) catch |err| {
                std.debug.print("zish: failed to create log file: {}\n", .{err});
                std.process.exit(1);
            }
        else
            std.fs.cwd().createFile(log_path, .{}) catch |err| {
                std.debug.print("zish: failed to create log file: {}\n", .{err});
                std.process.exit(1);
            };
    }

    // --exec mode: run agent query, output JSON result on stdout.
    // Designed for use as a tool by Claude Code or other agents.
    // Example: zish --exec "audit this code" --persona micay
    if (res.args.exec) |query| {
        const personas = @import("personas.zig");
        const agent_log = @import("agent_log.zig");

        // Parse persona (default: hdevalence)
        const persona = if (res.args.persona) |p|
            personas.Persona.fromName(p) orelse .hdevalence
        else
            .hdevalence;

        // Start agent
        shell_instance.agent.start() catch {
            std.debug.print("{{\"error\":\"agent failed to start\"}}\n", .{});
            std.process.exit(1);
        };

        // Build query with persona context
        var qbuf: [8192]u8 = undefined;
        const full_query = std.fmt.bufPrint(&qbuf, "{s}\n\n{s}", .{
            persona.systemPrompt()[0..@min(persona.systemPrompt().len, 500)],
            query,
        }) catch query;

        // Send query
        if (!shell_instance.agent.query(full_query)) {
            std.debug.print("{{\"error\":\"queue full\"}}\n", .{});
            std.process.exit(1);
        }

        // Wait for agent to finish and drain output (plain text, no ANSI)
        const agent_queue = @import("agent_queue.zig");
        var exit_code: u8 = 0;
        while (true) {
            var msg: agent_queue.Msg = undefined;
            if (shell_instance.agent.queues.output.pop(&msg)) {
                switch (msg.kind) {
                    .text_delta => { _ = std.posix.write(std.posix.STDOUT_FILENO, msg.slice()) catch {}; },
                    .error_msg => {
                        _ = std.posix.write(std.posix.STDOUT_FILENO, msg.slice()) catch {};
                        _ = std.posix.write(std.posix.STDOUT_FILENO, "\n") catch {};
                        exit_code = 1;
                    },
                    .tool_call => {}, // skip tool display in exec mode
                    .tool_done => {},
                    .done => break,
                    else => {},
                }
            } else {
                // No message — check if agent is still running
                if (!shell_instance.agent.isBusy()) break;
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }
        }

        // Print structured result footer
        const rl = &shell_instance.agent.bulletin.rate_limit;
        var footer_buf: [256]u8 = undefined;
        const footer = std.fmt.bufPrint(&footer_buf, "\n{{\"persona\":\"{s}\",\"model\":\"{s}\",\"rate_limit\":{d}}}\n", .{
            persona.name(),
            switch (persona.modelTier()) {
                .opus => "opus",
                .sonnet => "sonnet",
                .haiku => "haiku",
            },
            rl.maxUtil(),
        }) catch "";
        _ = std.posix.write(std.posix.STDOUT_FILENO, footer) catch {};

        _ = agent_log;
        std.posix.exit(exit_code);
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

        const exit_code = shell_instance.executeCommand(command) catch |err| {
            std.debug.print("zish: error executing command: {}\n", .{err});
            std.process.exit(1);
        };

        // Flush stdout buffer before exit
        shell_instance.stdout().flush() catch {};
        std.posix.exit(exit_code);
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

        const script_content = std.fs.cwd().readFileAlloc(allocator, script_path, 1024 * 1024) catch |err| {
            std.debug.print("zish: cannot read script '{s}': {}\n", .{ script_path, err });
            std.process.exit(1);
        };
        defer allocator.free(script_content);

        const exit_code = shell_instance.executeCommand(script_content) catch |err| {
            std.debug.print("zish: error executing script: {}\n", .{err});
            std.process.exit(1);
        };
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

const params = clap.parseParamsComptime(
    \\-h,   --help                  Display this help and exit.
    \\-v,   --version               print version and exit.
    \\-l,   --login                 Start as login shell.
    \\-d,   --debug-log-file <str>  file to write a debug info to.
    \\       --exec <str>            Execute agent query, output JSON result.
    \\       --persona <str>         Persona for --exec (default: hdevalence).
    \\-c    <str>                   command to execute.
    \\<str>...
    \\
);

test {
    std.testing.refAllDecls(@This());
}
