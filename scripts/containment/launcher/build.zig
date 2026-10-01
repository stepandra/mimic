const std = @import("std");
pub fn build(b: *std.Build) void {
    if (!std.mem.eql(u8, @import("builtin").zig_version_string, "0.16.0")) @panic("requires Zig 0.16.0");
    const target = b.standardTargetOptions(.{});
    const exe = b.addExecutable(.{ .name = "launch", .root_module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = b.standardOptimizeOption(.{}),
        .link_libc = false,
    }) });
    b.installArtifact(exe);
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("policy.zig"),
        .target = b.graph.host,
    }) });
    b.step("test", "Pure parser and BPF tests; never installs restrictions or executes a target").dependOn(&b.addRunArtifact(tests).step);
}

// Compiler pinned deliberately; no downloads or external packages.
