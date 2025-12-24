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
    };

    const cross_step = b.step("cross", "Build for all deployment targets");

    for (cross_targets) |ct| {
        const resolved_target = b.resolveTargetQuery(ct.target);

        const cross_xev = b.dependency("libxev", .{
            .target = resolved_target,
            .optimize = .ReleaseSafe,
        });

        const cross_exe = b.addExecutable(.{
            .name = b.fmt("rtach-{s}", .{ct.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = resolved_target,
                .optimize = .ReleaseSafe,
                .strip = true,
                .link_libc = true,
            }),
        });

        cross_exe.root_module.addImport("xev", cross_xev.module("xev"));

        const cross_install = b.addInstallArtifact(cross_exe, .{});
        cross_step.dependOn(&cross_install.step);
    }
}
