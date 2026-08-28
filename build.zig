const std = @import("std");

// High-performance build configuration for zish shell
// Optimized for maximum throughput and minimal latency
pub fn build(b: *std.Build) void {
    // Target options with performance-focused defaults
    const target = b.standardTargetOptions(.{});

    // No preferred_optimize_mode.
    //
    // It used to be `.preferred_optimize_mode = .ReleaseFast`, which makes
    // standardOptimizeOption *ignore* `--release=<mode>` entirely: `zig build
    // --release=safe` silently produced a ReleaseFast binary. The Makefile had
    // been asking for safety checks and never getting them, and neither did
    // anyone building from source.
    //
    // That matters more than speed here. ReleaseFast removes the bounds,
    // overflow and alignment checks that turn a memory bug into a clean abort
    // instead of undefined behaviour — in a shell an agent drives, those checks
    // are the difference between a crash and an exploitable primitive.
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
