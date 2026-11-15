const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "ZVC",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
        }),
    });
    b.installArtifact(exe);
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    // This project manages its own "live" zig version on PATH (see README),
    // so the zig version used to build it can change between runs. Support
    // both the newer `addPassthruArgs` API and the older `b.args` one so
    // `zig build run` keeps working regardless of which is active.
    if (@hasDecl(@TypeOf(run_cmd.*), "addPassthruArgs")) {
        run_cmd.addPassthruArgs();
    } else if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
    for ([_][]const u8{ "tools/check_dist.zig", "tools/release_info.zig" }) |tool| {
        const tool_tests = b.addTest(.{ .root_module = hostTool(b, tool) });
        test_step.dependOn(&b.addRunArtifact(tool_tests).step);
    }

    // The Zig version ZVC was last built and tested with (src/known-good-zig.txt).
    const known_good = std.mem.trim(u8, @embedFile("src/known-good-zig.txt"), " \t\r\n");

    // `zig build check-zig`: fails unless this zig is the known-good version.
    const check_zig_step = b.step("check-zig", "Fail unless the running zig is the known-good version");
    if (!std.mem.eql(u8, builtin.zig_version_string, known_good)) {
        check_zig_step.dependOn(&b.addFail(b.fmt(
            "this is zig {s}; ZVC's known-good zig is {s}",
            .{ builtin.zig_version_string, known_good },
        )).step);
    }

    // Release binaries for every supported target, stripped of debug info, as
    // zig-out/dist/zvc-<arch>-<os>[.exe]. Each embeds the known-good version,
    // so it can set up a machine that has no Zig.
    const dist_step = b.step("dist", "Cross-build stripped release binaries into zig-out/dist");
    const check_dist = b.addRunArtifact(b.addExecutable(.{
        .name = "check_dist",
        .root_module = hostTool(b, "tools/check_dist.zig"),
    }));
    const check_dist_step = b.step("check-dist", "Build dist and fail if a binary embeds a build-machine path");
    check_dist_step.dependOn(&check_dist.step);
    check_dist_step.dependOn(dist_step);
    const dist_targets = [_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .windows },
        .{ .cpu_arch = .aarch64, .os_tag = .windows },
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
    };
    for (dist_targets) |query| {
        const dist_exe = b.addExecutable(.{
            .name = b.fmt("zvc-{t}-{t}", .{ query.cpu_arch.?, query.os_tag.? }),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = b.resolveTargetQuery(query),
                .optimize = .ReleaseSafe,
                .strip = true,
            }),
        });
        const install_dist = b.addInstallArtifact(dist_exe, .{
            .dest_dir = .{ .override = .{ .custom = "dist" } },
            .pdb_dir = .disabled,
            .implib_dir = .disabled,
        });
        dist_step.dependOn(&install_dist.step);
        check_dist.addFileArg(dist_exe.getEmittedBin());
    }

    // `zig build release-info`: the release tag and notes, in zig-out/release/.
    const release_info = b.addRunArtifact(b.addExecutable(.{
        .name = "release_info",
        .root_module = hostTool(b, "tools/release_info.zig"),
    }));
    release_info.addArg(known_good);
    release_info.has_side_effects = true; // dated: rerun every time
    const tag_file = release_info.addOutputFileArg("tag.txt");
    const notes_file = release_info.addOutputFileArg("notes.md");
    const release_info_step = b.step("release-info", "Write the release tag and notes to zig-out/release");
    release_info_step.dependOn(&b.addInstallFile(tag_file, "release/tag.txt").step);
    release_info_step.dependOn(&b.addInstallFile(notes_file, "release/notes.md").step);
}

fn hostTool(b: *std.Build, path: []const u8) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = b.graph.host,
        .optimize = .Debug,
    });
}
