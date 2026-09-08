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

    // Stage the standard feat set beside the binary so it ships WITH zish:
    // <prefix>/share/zish/feats/standard/<name>/{bin/<name>, feat.toml}. The
    // resolver searches this system tier in addition to the writable
    // ~/.zish/feats, so gf and the standard feats are present out of the box
    // (like curl on $PATH) while user installs still land in $HOME. `zig build
    // --prefix $out` ships them for nix; `make feats` stays the local-dev path
    // into ~/.zish.
    const feat_names = [_][]const u8{
        "cnt",  "pk",    "frq",    "snf",    "jls", "calc", "para", "agent",
        "gf",   "aur",   "budget", "verify", "ask", "team", "web",
    };
    const feat_libc = [_][]const u8{ "para", "agent", "gf", "aur", "budget", "verify", "ask", "team", "web" };
    for (feat_names) |name| {
        var needs_libc = false;
        for (feat_libc) |l| {
            if (std.mem.eql(u8, l, name)) needs_libc = true;
        }
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
            .dest_dir = .{ .override = .{ .custom = b.fmt("share/zish/feats/standard/{s}/bin", .{name}) } },
        });
        b.getInstallStep().dependOn(&bin_inst.step);
        const toml_inst = b.addInstallFileWithDir(
            b.path(b.fmt("feats/{s}/feat.toml", .{name})),
            .{ .custom = b.fmt("share/zish/feats/standard/{s}", .{name}) },
            "feat.toml",
        );
        b.getInstallStep().dependOn(&toml_inst.step);
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
}
