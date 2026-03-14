const std = @import("std");

// High-performance build configuration for zish shell
// Optimized for maximum throughput and minimal latency
pub fn build(b: *std.Build) void {
    // Target options with performance-focused defaults
    const target = b.standardTargetOptions(.{});

    // Default to ReleaseFast for production performance
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const clap = b.dependency("clap", .{});

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
        }),
        .use_llvm = true,
    });

    exe.root_module.addImport("clap", clap.module("clap"));

    // Link libc for dlopen/dlsym (GPU Vulkan compute)
    exe.linkLibC();

    exe.root_module.addAnonymousImport("build.zig.zon", .{
        .root_source_file = b.path("build.zig.zon"),
    });

    // Enable performance optimizations
    if (enable_lto and optimize != .Debug) {
        exe.want_lto = true;
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

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
