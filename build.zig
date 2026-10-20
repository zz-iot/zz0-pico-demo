const std = @import("std");
const microzig = @import("microzig");

const MicroBuild = microzig.MicroBuild(.{
    .rp2xxx = true,
});

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const identity_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/identity.zig"),
        .target = b.graph.host,
    }) });
    const test_step = b.step("test", "Test demo identity, USB logging and local WiFi fixes");
    test_step.dependOn(&b.addRunArtifact(identity_tests).step);
    const usb_log_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/usb_log.zig"),
        .target = b.graph.host,
    }) });
    test_step.dependOn(&b.addRunArtifact(usb_log_tests).step);
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
    const driver_checks = .{
        .{ "drivers/src/wireless/cyw43439/ioctl.zig", "response payload offset" },
        .{ "drivers/src/wireless/cyw43439/wifi.zig", "send_zc preserves" },
        .{ "drivers/src/wireless/cyw43439/wifi.zig", "receive capacity" },
        .{ "drivers/src/wireless/cyw43439/wifi.zig", "control response polling" },
        .{ "drivers/src/wireless/cyw43439/wifi.zig", "join preserves automatic" },
    };
    inline for (driver_checks) |check| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{ .root_source_file = mz_dep.path(check[0]), .target = b.graph.host }),
            .filters = &.{check[1]},
        });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
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
        .{ .name = "zz0_pico_w", .board_name = "pico-wh", .target = raspberrypi.pico },
        .{ .name = "zz0_pico2_w_arm", .board_name = "pico2-wh", .target = raspberrypi.pico2_arm },
    };

    for (apps) |app| {
        const firmware = mb.add_firmware(.{
            .name = app.name,
            .target = app.target,
            .optimize = optimize,
            .root_source_file = b.path("src/main.zig"),
        });

        const demo_options = b.addOptions();
        demo_options.addOption([]const u8, "board_name", app.board_name);
        demo_options.addOption([]const u8, "usb_serial", b.fmt("zenzen-zero-{s}", .{app.board_name}));
        firmware.exe.root_module.addOptions("demo_options", demo_options);

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
    board_name: []const u8,
    target: *const microzig.Target,
};
