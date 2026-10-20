//! Best-effort USB logging: terminal backpressure must never stop the demo.
const std = @import("std");

pub fn write(serial: anytype, bytes: []const u8, poll: anytype) void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const sent = serial.write(remaining);
        // The host may not have opened the serial port, or may have stopped
        // reading. Drop the remainder instead of waiting for USB completion.
        if (sent == 0) return;
        remaining = remaining[sent..];
        poll();
    }
    // A pending transfer can finish during subsequent USB polling. Do not wait.
    _ = serial.flush();
    poll();
}

test "USB logging returns when the host stops reading and resumes later" {
    const Mock = struct {
        blocked: bool = true,
        writes: usize = 0,
        flushes: usize = 0,
        received: usize = 0,
        pub fn write(self: *@This(), bytes: []const u8) usize {
            self.writes += 1;
            if (self.blocked) return 0;
            const n = @min(bytes.len, 4);
            self.received += n;
            return n;
        }
        pub fn flush(self: *@This()) bool {
            self.flushes += 1;
            return !self.blocked;
        }
        fn poll() void {}
    };
    var serial: Mock = .{};
    write(&serial, "startup message", Mock.poll);
    try std.testing.expectEqual(@as(usize, 1), serial.writes);
    try std.testing.expectEqual(@as(usize, 0), serial.flushes);
    serial.blocked = false;
    write(&serial, "later message", Mock.poll);
    try std.testing.expectEqual(@as(usize, 13), serial.received);
    try std.testing.expectEqual(@as(usize, 1), serial.flushes);
}

test "USB logging does not wait for a pending flush" {
    const Mock = struct {
        flushes: usize = 0,
        pub fn write(_: *@This(), bytes: []const u8) usize {
            return bytes.len;
        }
        pub fn flush(self: *@This()) bool {
            self.flushes += 1;
            return false;
        }
        fn poll() void {}
    };
    var serial: Mock = .{};
    write(&serial, "message", Mock.poll);
    try std.testing.expectEqual(@as(usize, 1), serial.flushes);
}
