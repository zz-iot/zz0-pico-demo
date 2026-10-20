const std = @import("std");
const microzig = @import("microzig");
const zz0_client = @import("zz0_client");
const net = @import("net");
const zidl_rt = @import("zidl_rt");
const counter_types = @import("counter_types");
const secrets = @import("secrets.zig");
const demo_options = @import("demo_options");
const identity = @import("identity.zig");

const rp2xxx = microzig.hal;
const usb = microzig.core.usb;
const gpio = rp2xxx.gpio;
const time = rp2xxx.time;
const drivers = rp2xxx.drivers;
const log = std.log.scoped(.zz0_pico_demo);
const USB_Device = rp2xxx.usb.Polled(.{});
const USB_Serial = usb.drivers.CDC;
const demo = zz0_client.demo;

comptime {
    _ = @import("lwip_exports.zig");
}

var usb_device: USB_Device = undefined;
var usb_tx_buf: [1024]u8 = undefined;

var usb_controller: usb.DeviceController(.{
    .bcd_usb = USB_Device.max_supported_bcd_usb,
    .device_triple = .unspecified,
    .vendor = USB_Device.default_vendor_id,
    .product = USB_Device.default_product_id,
    .bcd_device = .v1_00,
    .serial = demo_options.usb_serial,
    .max_supported_packet_size = USB_Device.max_supported_packet_size,
    .configurations = &.{.{
        .attributes = .{ .self_powered = false },
        .max_current_ma = 50,
        .Drivers = struct {
            serial: USB_Serial,
            reset: rp2xxx.usb.ResetDriver(null, 0),
        },
    }},
}, .{.{
    .serial = .{
        .itf_notifi = "Zenzen Zero CDC",
        .itf_data = "Zenzen Zero CDC Data",
    },
    .reset = "",
}}) = .init;

fn usbLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (usb_controller.drivers()) |usb_drivers| {
        const prefix = comptime switch (scope) {
            .default => level.asText() ++ ": ",
            else => level.asText() ++ " (" ++ @tagName(scope) ++ "): ",
        };
        usbCdcWrite(&usb_drivers.serial, prefix ++ format ++ "\r\n", args);
    }
}

pub const std_options = microzig.std_options(.{
    .log_level = .debug,
    .log_scope_levels = &.{
        .{ .scope = .usb_dev, .level = .warn },
        .{ .scope = .usb_ctrl, .level = .warn },
        .{ .scope = .usb_cdc, .level = .warn },
    },
    .logFn = usbLog,
});

pub const panic = microzig.panic;
comptime {
    _ = microzig.export_startup();
}

const ClientSession = zz0_client.session.ClientSession;
var client_key: [4]u8 = @splat(0);

fn initClientSession() ClientSession {
    return ClientSession.init(.{
        .client_key = client_key,
        .session_id = 0x81,
    });
}

const AppState = struct {
    session: ClientSession = undefined,
    led_stage: LedStage = .joining_wifi,
    awaiting_status_agent: bool = false,
    awaiting_create_status: bool = false,
    awaiting_write_status: bool = false,
    connected: bool = false,
    created_entity_count: usize = 0,
    wifi_join_attempts: u32 = 0,
    create_client_attempts: u32 = 0,
    create_resource_attempts: u32 = 0,
    write_data_attempts: u32 = 0,
    published_samples: u32 = 0,
    next_counter: u32 = 1,
    pending_counter: ?u32 = null,
    agent_retry_delay_ms: u32 = retry_initial_delay_ms,
    agent_retry_not_before_us: u64 = 0,
    last_agent_request_us: u64 = 0,
};

var app_state: AppState = .{};

const retry_initial_delay_ms: u32 = 1_000;
const retry_max_delay_ms: u32 = 5 * 60 * 1000;
const wifi_join_timeout_ms: u32 = 30_000;
const agent_request_timeout_us: u64 = 5_000_000;
const publish_interval_us: u64 = 1_000_000;

const LedStage = enum {
    joining_wifi,
    wifi_join_failed,
    waiting_for_ip,
    udp_bind_failed,
    invalid_agent_endpoint,
    waiting_for_agent,
    connected,
};

pub fn main() !void {
    usb_device = .init();
    waitForUsbEnumeration(2_000);

    log.info("starting Zenzen Zero XRCE publisher on {s}", .{demo_options.board_name});

    var wifi_driver: drivers.WiFi = .{};
    var wifi = try wifi_driver.init(.{});
    client_key = identity.clientKey(wifi.mac);
    app_state.session = initClientSession();
    log.info("board={s} client_key={x} mac={x}", .{ demo_options.board_name, client_key, wifi.mac });
    var led = wifi.gpio(0);
    led.put(0);

    var wifi_backoff = RetryBackoff{};
    joinWifiWithRetry(wifi, &led, &wifi_backoff);

    var nic: net.Interface = .{ .link = wifi.link() };
    try nic.init(wifi.mac, try secrets.nic_options());
    app_state.led_stage = .waiting_for_ip;

    var udp: net.Udp = try .init(&nic);
    udp.bind(0, onRecv) catch |err| {
        log.err("UDP bind failed: {}", .{err});
        app_state.led_stage = .udp_bind_failed;
        blinkForever(&led);
    };

    const agent_endpoint = net.Endpoint.parse(secrets.agent_ip, secrets.agent_port) catch |err| {
        log.err("agent endpoint parse failed: {}", .{err});
        app_state.led_stage = .invalid_agent_endpoint;
        blinkForever(&led);
    };
    log.info("agent endpoint {f}", .{agent_endpoint});

    var last_write_send_us: u64 = time.get_time_since_boot().to_us();
    var last_status_log_us: u64 = 0;

    while (true) {
        pollUsb();
        nic.poll() catch |err| {
            log.err("network poll failed: {}", .{err});
        };

        const now = time.get_time_since_boot();
        const now_us: u64 = @intCast(now.to_us());
        updateLed(&led, now);

        // Keep boot/network stalls observable even when USB logging is opened late.
        if (elapsedUs(now_us, last_status_log_us) >= 5 * std.time.us_per_s) {
            last_status_log_us = now_us;
            const ip: [4]u8 = @bitCast(nic.netif.ip_addr.u_addr.ip4.addr);
            log.info("network status: wifi_joined={} ready={} flags=0x{x} ipv4={d}.{d}.{d}.{d} rx={} tx={}", .{
                wifi.is_joined(), nic.ready(),           nic.netif.flags,
                ip[0],            ip[1],                 ip[2],
                ip[3],            nic.stat.recv_packets, nic.stat.send_packets,
            });
        }

        if (!wifi.is_joined()) {
            log.warn("WiFi disconnected, restarting join loop", .{});
            resetAgentConnection(now_us, "wifi disconnect");
            joinWifiWithRetry(wifi, &led, &wifi_backoff);
            app_state.led_stage = .waiting_for_ip;
            continue;
        }

        if (!nic.ready()) {
            app_state.led_stage = .waiting_for_ip;
            resetAgentConnection(now_us, "network not ready");
            app_state.led_stage = .waiting_for_ip;
            continue;
        }

        wifi_backoff.reset();
        if (checkAgentTimeout(now_us)) continue;
        if (hasPendingAgentRequest()) continue;
        if (!agentRetryReady(now_us)) continue;

        if (!app_state.connected) {
            sendCreateClient(&udp, agent_endpoint, now_us) catch |err| {
                log.err("CREATE_CLIENT send failed: {}", .{err});
                scheduleAgentRetry(now_us, "CREATE_CLIENT send failure");
            };
            continue;
        }

        if (app_state.created_entity_count < demo.publish_path_entities.len) {
            sendNextCreate(&udp, agent_endpoint, now_us) catch |err| {
                log.err("CREATE send failed: {}", .{err});
                scheduleAgentRetry(now_us, "CREATE send failure");
            };
            continue;
        }

        const publish_due = !app_state.awaiting_write_status and elapsedUs(now_us, last_write_send_us) > publish_interval_us;
        if (publish_due) {
            last_write_send_us = now_us;
            sendCounterSample(&udp, agent_endpoint, now_us) catch |err| {
                log.err("WRITE_DATA send failed: {}", .{err});
                scheduleAgentRetry(now_us, "WRITE_DATA send failure");
            };
        }
    }
}

fn sendCreateClient(udp: *net.Udp, agent_endpoint: net.Endpoint, now_us: u64) !void {
    var request: [zz0_client.xrce.CreateClient.message_len]u8 = undefined;
    const bytes = try app_state.session.encodeCreateClient(&request);
    try udp.send(bytes, agent_endpoint);
    app_state.create_client_attempts += 1;
    app_state.led_stage = .waiting_for_agent;
    app_state.awaiting_status_agent = true;
    app_state.last_agent_request_us = now_us;
    log.info(
        "sent CREATE_CLIENT attempt {} to {f}",
        .{ app_state.create_client_attempts, agent_endpoint },
    );
}

fn sendNextCreate(udp: *net.Udp, agent_endpoint: net.Endpoint, now_us: u64) !void {
    const spec = demo.publish_path_entities[app_state.created_entity_count];
    var request: [128]u8 = undefined;
    const bytes = try app_state.session.encodeCreateByReference(&request, .{
        .object_prefix = spec.object_prefix,
        .object_kind = spec.object_kind,
        .reference = spec.reference,
        .participant_domain_id = spec.participant_domain_id orelse 0,
        .related_object_id = spec.related_object_id,
    });
    try udp.send(bytes, agent_endpoint);
    app_state.create_resource_attempts += 1;
    app_state.awaiting_create_status = true;
    app_state.last_agent_request_us = now_us;
    log.info(
        "sent CREATE {s} attempt {} to {f}",
        .{ spec.label, app_state.create_resource_attempts, agent_endpoint },
    );
}

fn sendCounterSample(udp: *net.Udp, agent_endpoint: net.Endpoint, now_us: u64) !void {
    var cdr_storage: [128]u8 = undefined;
    const counter = app_state.next_counter;
    const sample_bytes = try encodeCounterSample(&cdr_storage, counter);

    var request: [256]u8 = undefined;
    const bytes = try app_state.session.encodeWriteData(&request, .{
        .object_id = demo.datawriter.object_id,
        .serialized_data = sample_bytes,
    });
    try udp.send(bytes, agent_endpoint);
    app_state.write_data_attempts += 1;
    app_state.awaiting_write_status = true;
    app_state.pending_counter = counter;
    app_state.next_counter += 1;
    app_state.last_agent_request_us = now_us;
    log.info(
        "sent WRITE_DATA counter={} attempt {} bytes={} to {f}",
        .{ counter, app_state.write_data_attempts, sample_bytes.len, agent_endpoint },
    );
}

fn onRecv(_: *net.Udp, bytes: []u8, opt: net.Udp.RecvOptions) void {
    if (!opt.last_fragment) {
        log.warn("ignoring fragmented UDP packet from {f}", .{opt.src});
        return;
    }

    const event = app_state.session.handleDatagram(bytes) catch |err| {
        log.err("XRCE response decode failed from {f}: {}", .{ opt.src, err });
        return;
    };

    switch (event) {
        .status_agent => |status| {
            app_state.awaiting_status_agent = false;
            app_state.connected = true;
            app_state.led_stage = .connected;
            markAgentProgress();
            log.info(
                "received STATUS_AGENT after CREATE_CLIENT attempt {} seq={} vendor={x:0>2}{x:0>2}",
                .{
                    app_state.create_client_attempts,
                    status.header.sequence_nr,
                    status.vendor_id[0],
                    status.vendor_id[1],
                },
            );
        },
        .status => |status| {
            const ok = status.result.status == .ok or status.result.status == .ok_matched;

            if (app_state.awaiting_create_status) {
                app_state.awaiting_create_status = false;
                if (ok and app_state.created_entity_count < demo.publish_path_entities.len) {
                    const spec = demo.publish_path_entities[app_state.created_entity_count];
                    app_state.created_entity_count += 1;
                    markAgentProgress();
                    log.info(
                        "CREATE {s} acknowledged as {} ({}/{})",
                        .{ spec.label, status.result.status, app_state.created_entity_count, demo.publish_path_entities.len },
                    );
                } else if (!ok) {
                    resetAgentConnectionFromCallback("CREATE rejected");
                }
            } else if (app_state.awaiting_write_status) {
                app_state.awaiting_write_status = false;
                if (ok) {
                    app_state.published_samples += 1;
                    markAgentProgress();
                    log.info(
                        "WRITE_DATA counter={} acknowledged as {} (published={})",
                        .{ app_state.pending_counter orelse 0, status.result.status, app_state.published_samples },
                    );
                } else {
                    resetAgentConnectionFromCallback("WRITE_DATA rejected");
                }
                app_state.pending_counter = null;
            }
            log.info(
                "received STATUS result={} request={x:0>2}{x:0>2} object={x:0>2}{x:0>2}",
                .{
                    status.result.status,
                    status.related_request.request_id[0],
                    status.related_request.request_id[1],
                    status.related_request.object_id[0],
                    status.related_request.object_id[1],
                },
            );
        },
        .ignored => {
            log.debug("ignored XRCE datagram from {f}", .{opt.src});
        },
    }
}

fn encodeCounterSample(out: []u8, counter: u32) ![]const u8 {
    var fba = std.heap.FixedBufferAllocator.init(out);
    var bytes = std.ArrayListUnmanaged(u8).empty;
    const allocator = fba.allocator();

    const board = try zidl_rt.BoundedArray(u8, 16).fromSlice(demo_options.board_name);
    const payload = try zidl_rt.BoundedArray(u8, 8).fromSlice(&.{
        @truncate(counter & 0xff),
        @truncate((counter >> 8) & 0xff),
        0xa5,
        0x5a,
    });
    const sample = counter_types.CounterStatus{
        .counter = counter,
        .board = board,
        .payload = payload,
    };

    var writer = zidl_rt.CdrWriter(.xcdr2).init(&bytes, allocator);
    try counter_types.CounterStatus.serialize(&writer, sample);
    return bytes.items;
}

const RetryBackoff = struct {
    delay_ms: u32 = retry_initial_delay_ms,

    fn reset(self: *RetryBackoff) void {
        self.delay_ms = retry_initial_delay_ms;
    }

    fn nextDelay(self: *RetryBackoff) u32 {
        const delay = self.delay_ms;
        self.delay_ms = nextRetryDelayMs(self.delay_ms);
        return delay;
    }
};

fn joinWifiWithRetry(wifi: *drivers.WiFi.Chip, led: anytype, backoff: *RetryBackoff) void {
    var attempt: u32 = 1;
    attempt_loop: while (true) : (attempt += 1) {
        app_state.wifi_join_attempts = attempt;
        app_state.led_stage = .joining_wifi;
        log.info("joining WiFi SSID {s}, attempt {}", .{ secrets.ssid, attempt });

        var join_options = secrets.join_opt;
        // Every retry in this demo uses the same SSID and credentials.
        join_options.preserve_auto_reconnect = true;
        var join = wifi.join(secrets.ssid, secrets.password, join_options) catch |err| {
            log.err("WiFi join start failed on attempt {}: {}", .{ attempt, err });
            app_state.led_stage = .wifi_join_failed;
            retryDelay(led, backoff.nextDelay());
            continue :attempt_loop;
        };

        const started_us: u64 = @intCast(time.get_time_since_boot().to_us());
        while (true) {
            const still_joining = join.poll() catch |err| {
                log.err("WiFi join poll failed on attempt {}: {}", .{ attempt, err });
                app_state.led_stage = .wifi_join_failed;
                retryDelay(led, backoff.nextDelay());
                continue :attempt_loop;
            };
            if (!still_joining) break;

            pollUsb();
            updateLed(led, time.get_time_since_boot());
            if (elapsedUs(@intCast(time.get_time_since_boot().to_us()), started_us) > @as(u64, wifi_join_timeout_ms) * 1000) {
                log.err("WiFi join timed out on attempt {}", .{attempt});
                app_state.led_stage = .wifi_join_failed;
                retryDelay(led, backoff.nextDelay());
                continue :attempt_loop;
            }
            time.sleep_ms(10);
        }

        if (wifi.is_joined()) {
            backoff.reset();
            log.info("WiFi joined on attempt {}", .{app_state.wifi_join_attempts});
            return;
        }

        log.err("WiFi join attempt {} ended in state {}", .{ attempt, wifi.join_state() });
        app_state.led_stage = .wifi_join_failed;
        retryDelay(led, backoff.nextDelay());
    }
}

fn checkAgentTimeout(now_us: u64) bool {
    if (!hasPendingAgentRequest()) return false;
    if (elapsedUs(now_us, app_state.last_agent_request_us) <= agent_request_timeout_us) return false;

    log.warn(
        "agent request timed out after {} ms",
        .{agent_request_timeout_us / 1000},
    );
    resetAgentConnection(now_us, "agent timeout");
    scheduleAgentRetry(now_us, "agent timeout");
    return true;
}

fn hasPendingAgentRequest() bool {
    return app_state.awaiting_status_agent or
        app_state.awaiting_create_status or
        app_state.awaiting_write_status;
}

fn agentRetryReady(now_us: u64) bool {
    return app_state.agent_retry_not_before_us == 0 or now_us >= app_state.agent_retry_not_before_us;
}

fn resetAgentConnection(now_us: u64, reason: []const u8) void {
    if (app_state.connected or hasPendingAgentRequest() or app_state.created_entity_count != 0) {
        log.warn("resetting XRCE agent session: {s}", .{reason});
    }
    app_state.session = initClientSession();
    app_state.awaiting_status_agent = false;
    app_state.awaiting_create_status = false;
    app_state.awaiting_write_status = false;
    app_state.connected = false;
    app_state.created_entity_count = 0;
    app_state.pending_counter = null;
    app_state.last_agent_request_us = now_us;
    app_state.led_stage = .waiting_for_agent;
}

fn resetAgentConnectionFromCallback(reason: []const u8) void {
    resetAgentConnection(@intCast(time.get_time_since_boot().to_us()), reason);
    scheduleAgentRetry(@intCast(time.get_time_since_boot().to_us()), reason);
}

fn scheduleAgentRetry(now_us: u64, reason: []const u8) void {
    const delay_ms = app_state.agent_retry_delay_ms;
    app_state.agent_retry_delay_ms = nextRetryDelayMs(app_state.agent_retry_delay_ms);
    app_state.agent_retry_not_before_us = now_us + @as(u64, delay_ms) * 1000;
    app_state.led_stage = .waiting_for_agent;
    log.warn("agent retry delayed {d} ms after {s}", .{ delay_ms, reason });
}

fn markAgentProgress() void {
    app_state.agent_retry_delay_ms = retry_initial_delay_ms;
    app_state.agent_retry_not_before_us = 0;
}

fn nextRetryDelayMs(current: u32) u32 {
    if (current >= retry_max_delay_ms) return retry_max_delay_ms;
    const doubled = current *| 2;
    return @min(doubled, retry_max_delay_ms);
}

fn elapsedUs(now_us: u64, then_us: u64) u64 {
    return now_us -| then_us;
}

fn retryDelay(led: anytype, delay_ms: u32) void {
    log.info("retrying in {} ms", .{delay_ms});
    var remaining = delay_ms;
    while (remaining > 0) : (remaining -|= 10) {
        pollUsb();
        updateLed(led, time.get_time_since_boot());
        time.sleep_ms(@min(@as(u32, 10), remaining));
    }
}

fn updateLed(led: anytype, now: anytype) void {
    led.put(if (ledOnForStage(app_state.led_stage, @intCast(now.to_us()))) 1 else 0);
}

fn blinkForever(led: anytype) noreturn {
    while (true) {
        pollUsb();
        updateLed(led, time.get_time_since_boot());
    }
}

fn ledOnForStage(stage: LedStage, now_us: u64) bool {
    return switch (stage) {
        .joining_wifi => pulseTrain(now_us, 1, 120_000, 120_000, 1_000_000),
        .wifi_join_failed => pulseTrain(now_us, 2, 120_000, 120_000, 1_200_000),
        .waiting_for_ip => pulseTrain(now_us, 3, 120_000, 120_000, 1_400_000),
        .udp_bind_failed => pulseTrain(now_us, 4, 80_000, 80_000, 1_000_000),
        .invalid_agent_endpoint => pulseTrain(now_us, 5, 80_000, 80_000, 1_200_000),
        .waiting_for_agent => (now_us % 500_000) < 250_000,
        .connected => true,
    };
}

fn pulseTrain(now_us: u64, pulses: u8, on_us: u64, gap_us: u64, cycle_us: u64) bool {
    const phase = now_us % cycle_us;
    var start: u64 = 0;
    var i: u8 = 0;
    while (i < pulses) : (i += 1) {
        if (phase >= start and phase < start + on_us) return true;
        start += on_us + gap_us;
    }
    return false;
}

fn pollUsb() void {
    usb_device.poll(&usb_controller);
}

fn waitForUsbEnumeration(timeout_ms: u32) void {
    var remaining = timeout_ms;
    while (remaining > 0) : (remaining -= 10) {
        pollUsb();
        if (usb_controller.drivers() != null) return;
        time.sleep_ms(10);
    }
}

fn usbCdcWrite(serial: *USB_Serial, comptime fmt: []const u8, args: anytype) void {
    const tx = std.fmt.bufPrint(&usb_tx_buf, fmt, args) catch return;
    @import("usb_log.zig").write(serial, tx, pollUsb);
}
