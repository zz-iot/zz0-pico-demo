const std = @import("std");
const microzig = @import("microzig");

const MicroBuild = microzig.MicroBuild(.{
    .rp2xxx = true,
});

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const zidl_dep = b.dependency("zidl", .{
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const zidl_exe = b.option(
        []const u8,
        "zidl",
        "Path to a prebuilt zidl executable",
    );

    const mz_dep = b.dependency("microzig", .{});
    const mb = MicroBuild.init(b, mz_dep) orelse return;
    const raspberrypi = mb.ports.rp2xxx.boards.raspberrypi;

    const gen_counter_types = if (zidl_exe) |path| b.addSystemCommand(&.{path}) else b.addRunArtifact(zidl_dep.artifact("zidl"));
    gen_counter_types.addArgs(&.{ "-b", "zig" });
    gen_counter_types.addArgs(&.{
        "--profile",               "xrce",
        "--no-typeobject-support", "-o",
    });
    const gen_counter_types_dir = gen_counter_types.addOutputDirectoryArg("zz0-pico-demo-generated");
    gen_counter_types.addFileArg(b.path("idl/counter_types.idl"));

    const apps: []const App = &.{
        .{ .name = "pico_zero_ping", .target = raspberrypi.pico },
        .{ .name = "pico2_arm_zero_ping", .target = raspberrypi.pico2_arm },
    };

    for (apps) |app| {
        const firmware = mb.add_firmware(.{
            .name = app.name,
            .target = app.target,
            .optimize = optimize,
            .root_source_file = b.path("src/main.zig"),
        });

        const zz0_client_dep = b.dependency("zz0_client", .{
            .target = b.resolveTargetQuery(firmware.target.zig_target),
            .optimize = optimize,
        });
        firmware.exe.root_module.addImport("zz0_client", zz0_client_dep.module("zz0_client"));

        const net_dep = b.dependency("net", .{
            .target = b.resolveTargetQuery(firmware.target.zig_target),
            .optimize = optimize,
            .mtu = 1500,
            .pbuf_length = 1540,
            .pbuf_header_length = 22,
        });
        firmware.exe.root_module.addImport("net", net_dep.module("net"));

        const zidl_rt_mod = b.createModule(.{
            .root_source_file = zidl_dep.path("packages/zidl-rt/src/root.zig"),
            .target = b.resolveTargetQuery(firmware.target.zig_target),
            .optimize = optimize,
        });
        firmware.exe.root_module.addImport("zidl_rt", zidl_rt_mod);

        const counter_types_mod = b.createModule(.{
            .root_source_file = gen_counter_types_dir.path(b, "counter_types.zig"),
            .target = b.resolveTargetQuery(firmware.target.zig_target),
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zidl_rt", .module = zidl_rt_mod },
            },
        });
        firmware.exe.root_module.addImport("counter_types", counter_types_mod);

        mb.install_firmware(firmware, .{});
        mb.install_firmware(firmware, .{ .format = .elf });
    }
}

const App = struct {
    name: []const u8,
    target: *const microzig.Target,
};
