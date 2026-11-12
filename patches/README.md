# Local MicroZig fixes

Baseline: [MicroZig 0.17.37](https://github.com/ZigEmbeddedGroup/microzig/releases/tag/0.17.37),
commit `03edc03149ea7432a35b8aa4c3ee2302b7348cc6`, Zig 0.17.1.
Apply the patches in the order listed in the demo README.

| Patch | Purpose | Regression |
| --- | --- | --- |
| transmit-regression | Test only: upstream PR #1093 already fixed the SPI command/packet offset | Mock SPI captures the header and Ethernet payload |
| join-recovery | Reset stale state, dispatch events interleaved with control replies, preserve early completion and optionally retain automatic reassociation | Interleaved events and automatic reconnect with the option enabled and disabled |

## Upstream status

The receive-capacity and response-offset fixes are included in this release via
[PR #1094](https://github.com/ZigEmbeddedGroup/microzig/pull/1094) and
[PR #1095](https://github.com/ZigEmbeddedGroup/microzig/pull/1095).
Their local patch files have been removed.

Join recovery is pending in
[PR #1108](https://github.com/ZigEmbeddedGroup/microzig/pull/1108).
The local patch includes its smaller revised tests. Refreshing the demo baseline
does not change that PR's branch. The WiFi driver itself is unchanged between
MicroZig 0.17.30 and 0.17.37.

The transmit regression remains an unsubmitted test-only follow-up to
[PR #1093](https://github.com/ZigEmbeddedGroup/microzig/pull/1093).
It is independent of the join recovery changes.

## Verification

The demo's `zig build test` runs the focused driver regressions plus identity and
USB logging tests. Individual driver checks can also be run from the patched
MicroZig root with Zig 0.17.1:

```sh
zig test drivers/src/wireless/cyw43439/ioctl.zig --test-filter 'response payload offset'
zig test drivers/src/wireless/cyw43439/wifi.zig --test-filter 'send_zc preserves'
zig test drivers/src/wireless/cyw43439/wifi.zig --test-filter 'receive capacity'
zig test drivers/src/wireless/cyw43439/wifi.zig --test-filter 'control response polling'
zig test drivers/src/wireless/cyw43439/wifi.zig --test-filter 'join preserves automatic'
```

These are focused regressions, not a claim that the complete standalone driver
suite passes. The previous Pico WH and Pico 2 WH hardware acceptance runs used
older firmware. Repeat initial connection, DHCP, publishing, agent restart, and
WiFi loss/rejoin checks with the new MicroZig/compiler images before considering
the upgrade qualified on hardware.
