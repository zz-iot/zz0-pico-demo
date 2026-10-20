# Local MicroZig fixes

Baseline: MicroZig 0.17.24, commit
`90139d6e4648dd374751f489738dd4b510d93215`, Zig 0.17.0.
Apply the patches in the order listed in the demo README. They reproduce the
local driver changes; none has been submitted upstream as part of this work.

| Patch | Purpose | Regression |
| --- | --- | --- |
| response-offset | Calculate payload positions independently of whether the control header has already been read; retain upstream BDC padding fix | Padded event decoding and control payload before/after cdc() |
| transmit-regression | Test only: upstream PR #1093 already fixed the SPI command/packet offset | Mock SPI captures header and Ethernet payload |
| receive-capacity | Use full packet-sized buffers for control/join polling and reject insufficient capacity before constructing a word slice or reading SPI | Reject a small buffer without a packet read; accept a 1500-byte frame during join polling |
| join-recovery | Reset stale state, dispatch events interleaved with control replies, preserve early completion and optionally retain automatic reassociation | Interleaved events and full join with automatic reconnect, with opt-in and opt-out cases |

## Suggested upstream contributions

1. **Receive-buffer safety.** Submit independently with the mock SPI regression.
   The radio reports an 11-bit packet length; allocation must include word
   rounding and trailing SPI status. The old pointer-based slice construction
   bypassed buffer capacity checks. Both control response polling and join polling
   can receive Ethernet traffic. Hardware previously faulted during recovery;
   host tests establish the unsafe capacity path without relying on a crash.
2. **Payload access independent of header-read order.** Submit separately from
   the padding correction already merged upstream. Explain that data() previously
   depended on the reader cursor, especially for control packets. Retain both
   regressions to avoid regressing upstream padded-event behavior.
3. **Join recovery.** Review as a coherent state-machine change, potentially
   splitting event dispatch/reset from the automatic reassociation policy if
   maintainers prefer. A command response can be interleaved with WiFi events;
   logging and discarding those events loses join progress. On hardware, a retry
   also completed automatic auth/reassociation/link/key setup during configuration,
   then the redundant set_ssid aborted it. The preservation option defaults off
   and is appropriate only for retries with unchanged network and credentials.
   Discuss whether upstream prefers a dedicated reconnect API over this option.
4. **Transmit regression.** Offer as a test-only follow-up to PR #1093, not as a
   new bug fix. It should remain independent of the functional patches.

Before submission, compare each change with current upstream, match the project's
preferred test placement, and include the regression and minimal reproduction.
The larger join patch currently follows the other WiFi patches for clean
application; extract against the intended upstream base when opening separate PRs.

## Verification

The demo's `zig build test` runs six focused driver tests plus identity and USB
logging tests. Individual driver checks can also be run from the MicroZig root:

```sh
zig test drivers/src/wireless/cyw43439/ioctl.zig --test-filter 'response payload offset'
zig test drivers/src/wireless/cyw43439/wifi.zig --test-filter 'send_zc preserves'
zig test drivers/src/wireless/cyw43439/wifi.zig --test-filter 'receive capacity'
zig test drivers/src/wireless/cyw43439/wifi.zig --test-filter 'control response polling'
zig test drivers/src/wireless/cyw43439/wifi.zig --test-filter 'join preserves automatic'
```

These are focused regressions, not a claim that the complete standalone driver
suite passes: ioctl.zig has older tests that still need writer-API updates.
Pico WH and Pico 2 WH hardware checks cover initial connection, DHCP, publishing,
agent restart, and WiFi loss/rejoin individually and together. Temporary event
tracing and numbered diagnostic firmware artifacts are not required by the fixes.
