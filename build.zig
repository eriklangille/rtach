const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Import libxev as a dependency
    const xev_dep = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    });

    // Main rtach executable
    const exe = b.addExecutable(.{
        .name = "rtach",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    exe.root_module.addImport("xev", xev_dep.module("xev"));
    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run rtach");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const test_exe = b.addTest(.{
        .name = "rtach-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    test_exe.root_module.addImport("xev", xev_dep.module("xev"));

    const run_unit_tests = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Integration tests (requires bun) - functional tests only
    // Run with: zig build integration-test
    const integration_test_step = b.step("integration-test", "Run functional integration tests (requires bun)");
    integration_test_step.dependOn(b.getInstallStep()); // Build first

    const bun_test = b.addSystemCommand(&.{ "bun", "test", "functional.test.ts" });
    bun_test.setCwd(b.path("tests"));
    bun_test.step.dependOn(b.getInstallStep());
    integration_test_step.dependOn(&bun_test.step);

    // Benchmarks (manual, not part of CI)
    // Run with: zig build benchmark
    const benchmark_step = b.step("benchmark", "Run performance benchmarks (manual)");
    benchmark_step.dependOn(b.getInstallStep());

    const bun_bench = b.addSystemCommand(&.{ "bun", "test", "benchmark.test.ts" });
    bun_bench.setCwd(b.path("tests"));
    bun_bench.step.dependOn(b.getInstallStep());
    benchmark_step.dependOn(&bun_bench.step);

    // Full test: unit + functional integration
    const full_test_step = b.step("test-all", "Run unit and functional integration tests");
    full_test_step.dependOn(&run_unit_tests.step);
    full_test_step.dependOn(&bun_test.step);

    // Cross-compilation targets for deployment
    const CrossTarget = struct {
        name: []const u8,
        target: std.Target.Query,
    };

    const cross_targets = [_]CrossTarget{
        .{ .name = "x86_64-linux-gnu", .target = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu } },
        .{ .name = "x86_64-linux-musl", .target = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl } },
        .{ .name = "aarch64-linux-gnu", .target = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu } },
        .{ .name = "aarch64-linux-musl", .target = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl } },
        .{ .name = "x86_64-macos", .target = .{ .cpu_arch = .x86_64, .os_tag = .macos } },
        .{ .name = "aarch64-macos", .target = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
    };

    const cross_step = b.step("cross", "Build for all deployment targets");

    // Destination for iOS app resources
    const clauntty_resources_path = "../clauntty/Clauntty/Resources/rtach/";

    for (cross_targets) |ct| {
        const resolved_target = b.resolveTargetQuery(ct.target);

        const cross_xev = b.dependency("libxev", .{
            .target = resolved_target,
            .optimize = optimize, // Use command-line optimize option
        });

        const cross_exe = b.addExecutable(.{
            .name = b.fmt("rtach-{s}", .{ct.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = resolved_target,
                .optimize = optimize, // Use command-line optimize option
                .strip = optimize != .Debug, // Only strip in release builds
                .link_libc = true,
            }),
        });

        cross_exe.root_module.addImport("xev", cross_xev.module("xev"));

        const cross_install = b.addInstallArtifact(cross_exe, .{});
        cross_step.dependOn(&cross_install.step);

        // Copy to clauntty resources directory
        const copy_cmd = b.addSystemCommand(&.{
            "cp",
            b.fmt("zig-out/bin/rtach-{s}", .{ct.name}),
            b.fmt("{s}rtach-{s}", .{ clauntty_resources_path, ct.name }),
        });
        copy_cmd.step.dependOn(&cross_install.step);
        cross_step.dependOn(&copy_cmd.step);
    }
}
