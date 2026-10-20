const std = @import("std");

/// Stable XRCE identity for a radio. This is an identifier, not authentication.
pub fn clientKey(mac: [6]u8) [4]u8 {
    const hash = std.hash.Fnv1a_32.hash(&mac);
    var key: [4]u8 = undefined;
    std.mem.writeInt(u32, &key, if (hash == 0) 1 else hash, .big);
    return key;
}

test "client keys are stable, nonzero and distinguish radios" {
    const first = clientKey(.{ 0x28, 0xcd, 0xc1, 0, 0, 1 });
    const second = clientKey(.{ 0x28, 0xcd, 0xc1, 0, 0, 2 });
    try std.testing.expectEqual(first, clientKey(.{ 0x28, 0xcd, 0xc1, 0, 0, 1 }));
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
    try std.testing.expect(!std.mem.eql(u8, &first, &@as([4]u8, @splat(0))));
}
