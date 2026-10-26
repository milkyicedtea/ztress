const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const libc = b.option(bool, "libc", "Link libc (glibc for *-linux-gnu, musl for *-linux-musl);default: libc-free") orelse false;
    const strip = b.option(bool, "strip", "Strip debug info") orelse (optimize != .debug);

    const exe = b.addExecutable(.{
        .name = "ztress",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ztress.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (libc) true else null,
            .strip = strip,
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run ztress");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module })).step);
}
