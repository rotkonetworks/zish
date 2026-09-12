const std = @import("std");

// High-performance build configuration for zish shell
// Optimized for maximum throughput and minimal latency
pub fn build(b: *std.Build) void {
    // Target options with performance-focused defaults
    const target = b.standardTargetOptions(.{});

    // No preferred_optimize_mode: setting it makes standardOptimizeOption
    // *ignore* `--release=<mode>`, so `zig build --release=safe` would silently
    // produce a ReleaseFast binary. Safety matters more than speed here:
    // ReleaseFast removes the bounds, overflow and alignment checks that turn a
    // memory bug into a clean abort instead of undefined behaviour — in a shell
    // an agent drives, those checks are the difference between a crash and an
    // exploitable primitive.
    //
    // Releases build with `--release=safe`. Measured cost: still 1.19-1.80x
    // faster than bash across the whole bench.sh suite, versus 1.30-2.01x
    // unchecked. The large penalty (1.78x) shows up only in a tight pure
    // arithmetic loop, which is not a shape real shell work takes.
    const optimize = b.standardOptimizeOption(.{});

    // Performance build options
    const enable_simd = b.option(bool, "simd", "Enable SIMD optimizations") orelse true;
    const enable_lto = b.option(bool, "lto", "Enable Link Time Optimization") orelse (optimize != .Debug);
    const profile_guided = b.option(bool, "pgo", "Enable Profile Guided Optimization") orelse false;
    // Strip debug symbols. Off by default so local/dev builds stay debuggable;
    // release artifacts pass -Dstrip=true — release=safe's runtime checks are
    // unaffected (strip removes symbols, not check code), it just drops the
    // debug info end users don't need (~8.3M -> ~1.5M).
    const strip_symbols = b.option(bool, "strip", "Strip debug symbols (for release artifacts)") orelse false;

    const mod = b.addModule("zish", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "zish",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip_symbols,
            // Link libc for dlopen/dlsym (GPU Vulkan compute)
            .link_libc = true,
        }),
        .use_llvm = true,
    });


    exe.root_module.addAnonymousImport("build.zig.zon", .{
        .root_source_file = b.path("build.zig.zon"),
    });

    // Enable performance optimizations
    if (enable_lto and optimize != .Debug) {
        exe.lto = .full;
    }

    // Add performance-focused compile flags
    if (optimize == .ReleaseFast or optimize == .ReleaseSmall) {
        // Performance optimizations are enabled through -Doptimize=ReleaseFast
        // Additional target-specific optimizations can be added here as needed
    }

    // Define performance-related build options as compile-time constants
    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_simd", enable_simd);
    build_options.addOption(bool, "profile_guided", profile_guided);
    build_options.addOption(bool, "release_build", optimize != .Debug);

    exe.root_module.addOptions("build_options", build_options);

    b.installArtifact(exe);

    // Ship the feat set beside the binary — the lean base, grown with the
    // package manager (Arch = base + pacman, not everything preinstalled). Core
    // is the zero-dep unix utilities plus gf; the heavy/situational feats
    // (agent, team, web, aur, budget, verify, ask, bus) are published to the gf
    // index by `make dist-all` and installed on demand, so the base carries no
    // LLM-agent stack and the nix closure stays small. The resolver searches
    // this system tier plus the writable ~/.zish/feats (where gf installs), so
    // core is present out of the box like curl on $PATH.
    //
    // Which set ships: "core" (default) or "all". ONE list, one owner — this is
    // the only place that decides a feat exists, whether it links libc, and
    // where it installs.
    //
    // It has to be: the Makefile carried a second copy and the suites a third,
    // and they had drifted three ways — the Makefile shipped `bus` which this
    // list omitted, this list linked libc for eight feats the Makefile said
    // needed none, and the per-suite `zig build-exe` calls compiled a different
    // binary than either installed. So the suites were validating something
    // other than what ships.
    const feat_set = b.option([]const u8, "feats", "feat set to ship: 'core' (default) or 'all'") orelse "core";
    // Where a feat lands relative to --prefix:
    //   system   <prefix>/share/zish/feats/standard/<name>/  the shell's own
    //            system root — what a package or the nix derivation installs
    //   registry <prefix>/standard/<name>/                   a feat registry
    //            root — so `--prefix ~/.zish/feats -Dfeat-layout=registry` is
    //            the local-dev staging that `make feats` used to do in shell
    const feat_layout = b.option([]const u8, "feat-layout", "feat layout: 'system' (default) or 'registry'") orelse "system";
    const registry_layout = std.mem.eql(u8, feat_layout, "registry");

    const core_feats = [_][]const u8{ "cnt", "pk", "frq", "snf", "jls", "calc", "para", "gf" };
    const all_feats = [_][]const u8{
        "cnt", "pk",  "frq",    "snf",    "jls", "calc", "para", "agent",
        "gf",  "aur", "budget", "verify", "ask", "team", "web",  "bus",
    };
    // -Dfeats takes "core" (default), "all", or an explicit comma-separated list
    // ("agent,aur") so a packaging step builds exactly what it packs instead of
    // a whole set to throw most of it away. An unknown name fails the build
    // here rather than shipping a set that is quietly missing a member.
    var explicit: std.ArrayListUnmanaged([]const u8) = .empty;
    const feat_names: []const []const u8 = if (std.mem.eql(u8, feat_set, "all"))
        &all_feats
    else if (std.mem.eql(u8, feat_set, "core"))
        &core_feats
    else blk: {
        var it = std.mem.splitScalar(u8, feat_set, ',');
        while (it.next()) |raw| {
            const n = std.mem.trim(u8, raw, " \t");
            if (n.len == 0) continue;
            var known = false;
            for (all_feats) |f| {
                if (std.mem.eql(u8, f, n)) known = true;
            }
            if (!known) std.debug.panic("unknown feat '{s}': -Dfeats takes 'core', 'all', or comma-separated names from all_feats", .{n});
            explicit.append(b.allocator, n) catch @panic("OOM");
        }
        if (explicit.items.len == 0) std.debug.panic("-Dfeats={s} names no feat", .{feat_set});
        break :blk explicit.items;
    };
    // Only `para` links libc, and only for execvp (PATH search + environ). Every
    // other feat reaches the environment through feats/lib/feat.zig, which reads
    // /proc/self/environ. bus_test and agent_test assert that property, so a
    // regression fails loudly instead of quietly re-growing a libc dependency.
    const feat_libc = [_][]const u8{"para"};

    const install_feats = b.step("install-feats", "Install the feat set (-Dfeats, -Dfeat-layout)");
    b.getInstallStep().dependOn(install_feats);

    const test_feats = b.step("test-feats", "Run each feat's own unit tests");

    for (feat_names) |name| {
        var needs_libc = false;
        for (feat_libc) |l| {
            if (std.mem.eql(u8, l, name)) needs_libc = true;
        }
        const special = if (registry_layout)
            b.fmt("standard/{s}", .{name})
        else
            b.fmt("share/zish/feats/standard/{s}", .{name});
        const feat_exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("feats/{s}/main.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .strip = strip_symbols,
                .link_libc = needs_libc,
            }),
        });
        const bin_inst = b.addInstallArtifact(feat_exe, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("{s}/bin", .{special}) } },
        });
        install_feats.dependOn(&bin_inst.step);
        const toml_inst = b.addInstallFileWithDir(
            b.path(b.fmt("feats/{s}/feat.toml", .{name})),
            .{ .custom = special },
            "feat.toml",
        );
        install_feats.dependOn(&toml_inst.step);

        // The feat's unit tests, compiled from the same module with the same
        // link decision — so `zig build test-feats` cannot test a differently
        // built binary than the one that installs.
        const feat_tests = b.addTest(.{
            .name = b.fmt("{s}-test", .{name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("feats/{s}/main.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .link_libc = needs_libc,
            }),
        });
        test_feats.dependOn(&b.addRunArtifact(feat_tests).step);
    }

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    // Fuzz targets over the pure parsing/eval surfaces. Rooted at its own file
    // rather than main.zig so it needs neither clap nor build_options.
    // `zig build fuzz` runs each target once (a smoke test); `zig build fuzz
    // --fuzz` searches continuously.
    const fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
    const fuzz_step = b.step("fuzz", "Fuzz lexer/parser/arithmetic/glob (add --fuzz to search)");
    fuzz_step.dependOn(&run_fuzz_tests.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_fuzz_tests.step);
    // The feats' own unit tests live here too: they were two hand-written lines
    // in the Makefile, which is why only two of sixteen feats had any.
    test_step.dependOn(test_feats);
}
