//! Development DDS subscriber for Pico CounterStatus samples forwarded by the agent.
const std = @import("std");
pub const std_options: std.Options = .{ .log_level = .warn };
const dds = @import("zzdds");
const DDS = dds.DDS;
const T = @import("counter_types").CounterStatus;
const rt = @import("zidl_rt");
pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer args.deinit();
    _ = args.skip();
    var publish_fixture = false;
    var domain: i32 = 0;
    var topic_name: []const u8 = "CounterStatusTopic";
    var type_name: []const u8 = "CounterStatus";
    var board: ?[]const u8 = null;
    var count: usize = 10;
    var timeout_s: u32 = 30;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("counter-consumer [--domain=N] [--topic=NAME] [--type=NAME] [--board=NAME] [--count=N] [--timeout=N] [--publish-fixture]\n", .{});
            return;
        } else if (std.mem.eql(u8, arg, "--publish-fixture")) {
            publish_fixture = true;
        } else if (std.mem.startsWith(u8, arg, "--domain=")) {
            domain = try std.fmt.parseInt(i32, arg[9..], 10);
        } else if (std.mem.startsWith(u8, arg, "--topic=")) {
            topic_name = arg[8..];
        } else if (std.mem.startsWith(u8, arg, "--type=")) {
            type_name = arg[7..];
        } else if (std.mem.startsWith(u8, arg, "--board=")) {
            board = arg[8..];
        } else if (std.mem.startsWith(u8, arg, "--count=")) {
            count = try std.fmt.parseInt(usize, arg[8..], 10);
        } else if (std.mem.startsWith(u8, arg, "--timeout=")) {
            timeout_s = try std.fmt.parseInt(u32, arg[10..], 10);
        } else return error.UnknownOption;
    }
    if (domain < 0 or domain > 232 or count == 0 or count > 256 or timeout_s == 0 or topic_name.len == 0 or type_name.len == 0) return error.InvalidOptions;
    var factory = try dds.createFactory();
    defer factory.deinit();
    const f = factory.toDDSFactory();
    const dp = f.create_participant(@intCast(domain), .{}, null, 0);
    if (dp.ptr == dds.dcps.NIL_PTR) return error.ParticipantCreationFailed;
    defer cleanup(f.delete_participant(dp));
    var ts_alloc = alloc;
    if (!dds.registerTypeSupport(dp, type_name, .{ .ctx = &ts_alloc, .compute_key_hash = T.computeKeyHashFromCdr, .compute_key_hash_key_only = T.computeKeyHashFromCdrKeyOnly, .has_key = T.has_key })) return error.TypeRegistrationFailed;
    const topic = dp.create_topic(try alloc.dupeSentinel(u8, topic_name, 0), try alloc.dupeSentinel(u8, type_name, 0), .{}, null, 0);
    if (topic.ptr == dds.dcps.NIL_PTR) return error.TopicCreationFailed;
    defer cleanup(dp.delete_topic(topic));
    if (publish_fixture) return publishFixture(init.io, alloc, dp, topic, count, timeout_s, board orelse "host-fixture");
    const sub = dp.create_subscriber(.{}, null, 0);
    if (sub.ptr == dds.dcps.NIL_PTR) return error.SubscriberCreationFailed;
    defer cleanup(dp.delete_subscriber(sub));
    var representation = [_]i16{2};
    var qos: DDS.DataReaderQos = .{};
    qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    qos.data_representation.value = .{ ._maximum = 1, ._length = 1, ._buffer = &representation, ._release = false };
    qos.resource_limits = .{ .max_samples = 256, .max_instances = 256, .max_samples_per_instance = 1 };
    const reader = sub.create_datareader(dp.lookup_topicdescription(try alloc.dupeSentinel(u8, topic_name, 0)), qos, null, 0);
    if (reader.ptr == dds.dcps.NIL_PTR) return error.ReaderCreationFailed;
    defer cleanup(sub.delete_datareader(reader));
    std.debug.print("counter-consumer: domain={d} topic={s} type={s} encoding=XCDR2/XTypes-1.3\n", .{ domain, topic_name, type_name });
    const start = std.Io.Clock.awake.now(init.io).nanoseconds;
    const budget: i96 = @as(i96, timeout_s) * std.time.ns_per_s;
    var received: usize = 0;
    while (std.Io.Clock.awake.now(init.io).nanoseconds - start < budget) {
        if (dds.takeRaw(reader)) |raw| {
            defer raw.deinit();
            if (!raw.info.valid_data) continue;
            if (raw.data.len < 4 or raw.data[0] != 0 or (raw.data[1] != 6 and raw.data[1] != 7)) return error.UnexpectedEncoding;
            var cdr = try rt.CdrReader.init(raw.data);
            var value: T = undefined;
            try T.deserializeInto(&value, &cdr, alloc);
            if (cdr.pos != cdr.data.len) return error.TrailingSampleBytes;
            if (board) |wanted| {
                if (!std.mem.eql(u8, wanted, value.board.slice())) continue;
            }
            received += 1;
            std.debug.print("sample board={s} counter={d} payload={x}\n", .{ value.board.slice(), value.counter, value.payload.slice() });
            if (received == count) {
                std.debug.print("counter-consumer: received {d} samples\n", .{received});
                return;
            }
        } else try (std.Io.Clock.Duration{ .clock = .awake, .raw = std.Io.Duration.fromMilliseconds(10) }).sleep(init.io);
    }
    return error.SampleTimeout;
}
fn cleanup(rc: DDS.ReturnCode_t) void {
    if (rc != DDS.RETCODE_OK) std.debug.print("counter-consumer: cleanup failed: {d}\n", .{rc});
}

// Host-only smoke source. It exercises DDS delivery, not XRCE/agent forwarding.
fn publishFixture(io: std.Io, alloc: std.mem.Allocator, dp: DDS.DomainParticipant, topic: DDS.Topic, count: usize, timeout_s: u32, board: []const u8) !void {
    const pub_ = dp.create_publisher(.{}, null, 0);
    if (pub_.ptr == dds.dcps.NIL_PTR) return error.PublisherCreationFailed;
    defer cleanup(dp.delete_publisher(pub_));
    var representation = [_]i16{2};
    var qos: DDS.DataWriterQos = .{};
    qos.data_representation.value = .{ ._maximum = 1, ._length = 1, ._buffer = &representation, ._release = false };
    const writer = pub_.create_datawriter(topic, qos, null, 0);
    if (writer.ptr == dds.dcps.NIL_PTR) return error.WriterCreationFailed;
    defer cleanup(pub_.delete_datawriter(writer));
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    while (true) {
        var matched: DDS.PublicationMatchedStatus = .{};
        if (writer.get_publication_matched_status(&matched) != DDS.RETCODE_OK) return error.StatusFailed;
        if (matched.current_count > 0) break;
        if (std.Io.Clock.awake.now(io).nanoseconds - start > @as(i96, timeout_s) * std.time.ns_per_s) return error.MatchTimeout;
        try (std.Io.Clock.Duration{ .clock = .awake, .raw = std.Io.Duration.fromMilliseconds(20) }).sleep(io);
    }
    var sample: T = .{};
    sample.board = try rt.BoundedArray(u8, 16).fromSlice(board);
    sample.payload = try rt.BoundedArray(u8, 8).fromSlice(&.{ 1, 2, 3 });
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(alloc);
    for (0..count) |i| {
        sample.counter = @intCast(i);
        bytes.clearRetainingCapacity();
        var w = rt.CdrWriter(.xcdr2).init(&bytes, alloc);
        try w.writeEncapHeader();
        try T.serialize(&w, sample);
        try dds.writeRaw(writer, .alive, T.computeKeyHash(&sample), bytes.items);
        try (std.Io.Clock.Duration{ .clock = .awake, .raw = std.Io.Duration.fromMilliseconds(100) }).sleep(io);
    }
    std.debug.print("counter-consumer: fixture published {d} samples\n", .{count});
}
