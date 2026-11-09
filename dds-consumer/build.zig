const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dds = b.dependency("zzdds", .{ .target = target, .optimize = optimize });
    const gen = b.addRunArtifact(dds.artifact("zidl"));
    gen.addArgs(&.{ "-b", "zig", "--generate-zzdds-wrappers", "-o" });
    const dir = gen.addOutputDirectoryArg("counter-generated");
    gen.addFileArg(.{ .cwd_relative = b.option([]const u8, "counter-idl", "CounterStatus IDL path") orelse "../idl/counter_types.idl" });
    const sample = b.createModule(.{ .root_source_file = dir.path(b, "counter_types.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "zidl_rt", .module = dds.module("zidl_rt") }, .{ .name = "zzdds", .module = dds.module("zzdds") } } });
    const exe = b.addExecutable(.{ .name = "counter-consumer", .root_module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "zzdds", .module = dds.module("zzdds") }, .{ .name = "counter_types", .module = sample }, .{ .name = "zidl_rt", .module = dds.module("zidl_rt") } },
    }) });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the DDS CounterStatus consumer").dependOn(&run.step);
}
