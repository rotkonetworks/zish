//! jevx, built on its own: `zig build` in this directory.
//!
//! Inside zish, jevx is also built by zish's root build.zig as a feat; this
//! file exists so the directory stands alone — the read-only mirror
//! (rotkonetworks/jevx) is this directory, published by zish's
//! scripts/mirror-jevx.sh.
//!
//!   zig build                         zig-out/bin/jevx
//!   zig build -Doptimize=ReleaseSafe  the shipped build
//!   zig build test                    the unit tests
//!   zig build suite                   tests/jevx_test.sh against zig-out/bin/jevx
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .Debug,
    });
    const exe = b.addExecutable(.{ .name = "jevx", .root_module = mod });
    b.installArtifact(exe);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(tests).step);

    // The suite lives at tests/jevx_test.sh in the mirror, and at
    // ../../tests/jevx_test.sh inside zish; whichever exists.
    const suite = b.addSystemCommand(&.{ "sh", "-c", "s=tests/jevx_test.sh; [ -f \"$s\" ] || s=../../tests/jevx_test.sh; JEVX=\"$(realpath \"$1\")\" bash \"$s\"", "suite" });
    suite.addArtifactArg(exe);
    b.step("suite", "Run the binary suite").dependOn(&suite.step);
}
