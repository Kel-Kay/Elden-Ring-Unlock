const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = .{
        .os_tag = .windows,
        .os_version_min = .{ .windows = .win10 },
        .cpu_arch = .x86_64,
    };

    const optimize = .ReleaseFast;

    const exe = b.addExecutable(.{
        .name = "Elden Ring Unlock",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.linkLibC();

    b.installArtifact(exe);
}
