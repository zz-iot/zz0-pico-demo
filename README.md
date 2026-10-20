# Zenzen Zero Pico Demo

MicroZig firmware application demonstrating the Zenzen Zero DDS-XRCE client.

Current scope:

- Build the same app for Pico WH/RP2040 and Pico 2 WH/RP2350 ARM targets.
- Import the reusable `zz0_client` XRCE core.
- Join WiFi with MicroZig's CYW43/lwIP stack.
- Send a DDS-XRCE `CREATE_CLIENT` UDP datagram to `zz0_agent`.
- Create a by-reference participant/topic/publisher/datawriter chain after the session opens.
- Publish a periodic XRCE `WRITE_DATA` sample using the generated `CounterStatus` fixture type.
- Decode `STATUS_AGENT` responses with the reusable `zz0_client` session core.
- Emit logs over USB CDC on `/dev/ttyACM*`, including network status every five seconds.

WiFi credentials and agent endpoint settings live in ignored `src/secrets.zig`.
Start from `src/secrets.zig.template`.

Build with Zig 0.17.0:

```sh
zig build
zig build test
```

The build generates `CounterStatus` Zig typesupport from
`idl/counter_types.idl` using the pinned zidl 0.3.21 release. The build compiles
the generator for the host and uses the runtime from the same package for the
firmware targets. Override the generator with `-Dzidl=/path/to/zidl` if needed.

LED diagnostics on the CYW43 LED:

- `1` short pulse repeating: booted, attempting WiFi join
- `2` short pulses repeating: WiFi join failed
- `3` short pulses repeating: WiFi joined, waiting for link/IP readiness
- steady 2 Hz blink: sending `CREATE_CLIENT`, waiting for `STATUS_AGENT`
- solid on: received `STATUS_AGENT`
- `4` fast pulses repeating: UDP bind failed
- `5` fast pulses repeating: configured agent IP could not be parsed

WiFi joins are retried indefinitely. Transient `Cyw43Authentication`,
`Cyw43WpaHandshake`, and join-timeout failures no longer require reflashing; the
firmware clears stale join state and retries the join loop automatically.

The firmware also recovers from WiFi disconnects and agent-side restarts. WiFi
join attempts and XRCE agent/session retries use exponential backoff starting at
1 second and capped at 5 minutes. If an XRCE request times out or the agent
rejects a previously valid demo write after a restart, the firmware resets its
local XRCE session state, recreates the by-reference participant/topic/publisher/
datawriter path, and resumes publishing.

The current development layout expects sibling checkouts of `zz0_client`
and `microzig` (the Zig 0.17.0-compatible revision). zidl is fetched automatically.
Copy `src/secrets.zig.template` to `src/secrets.zig` and
configure it locally. Both Pico firmware targets are built by `zig build`;
UF2 and ELF outputs are installed under `zig-out/`.

The MicroZig 0.17.24 baseline (Zig 0.17.0) is commit
`90139d6e4648dd374751f489738dd4b510d93215` with the local patches below.
Apply them in order from this directory to a clean checkout at that revision:

```sh
git -C ../microzig apply ../zz0-pico-demo/patches/microzig-wifi-response-offset.patch
git -C ../microzig apply ../zz0-pico-demo/patches/microzig-wifi-transmit-regression.patch
git -C ../microzig apply ../zz0-pico-demo/patches/microzig-wifi-receive-capacity.patch
git -C ../microzig apply ../zz0-pico-demo/patches/microzig-wifi-join-recovery.patch
```

See [patches/README.md](patches/README.md) for scope, regression tests and
upstream submission considerations. MicroZig 0.17.24 already includes the
BDC-padding and transmit-offset fixes from
[PR #1093](https://github.com/ZigEmbeddedGroup/microzig/pull/1093).

## Board identity and flashing

| Board | UF2 under `zig-out/firmware/` | Sample label | USB serial string |
| --- | --- | --- | --- |
| Pico WH (RP2040) | `zz0_pico_w.uf2` | `pico-wh` | `zenzen-zero-pico-wh` |
| Pico 2 WH (RP2350 ARM) | `zz0_pico2_w_arm.uf2` | `pico2-wh` | `zenzen-zero-pico2-wh` |

Each radio's MAC address is hashed to a stable nonzero 32-bit XRCE client key,
which is logged at startup and preserved when the local session resets. This
lets multiple boards of either type use the agent without sharing resources.
Object IDs are intentionally reused across boards: the agent scopes them to a
client session. USB names distinguish board types; they do not identify multiple
units of the same type.

Hold BOOTSEL while applying power, then copy the matching UF2 to `RPI-RP2`
(Pico WH) or `RP2350` (Pico 2 WH). GPIO power can keep a board alive when USB is
unplugged, so enter BOOTSEL from a full power cycle or a reset with BOOTSEL held.
Use a USB data cable; a charge-only cable cannot enumerate the bootloader.

After flashing, identify the CDC port with `ls -l /dev/serial/by-id/` on the Pi.
Open it with `stty -F /dev/ttyACM0 115200 raw -echo` and `cat /dev/ttyACM0`
(adjust the device name). Logging uses USB CDC; UART baud settings do not govern
flashing. The firmware logs link/IP state and packet counters every five seconds.
USB logging is best effort: it drops output when the host is not reading rather
than blocking WiFi, LED updates or publishing. Opening a terminal is optional.
Startup allows up to two seconds for USB enumeration; it does not wait for a
terminal to open. Under backpressure, log lines may be missing or partial.

To repeat the simultaneous-client acceptance run, flash both images, then restart the
updated agent with `--write-log=summary`. Verify distinct client keys, the correct
board labels, independent increasing counters, and recovery after an agent
restart. The older shared-key images can replace each other's sessions on the
updated agent, so they should not be used for the simultaneous-client test.

## Hardware validation

Pico WH and Pico 2 WH have passed WiFi/DHCP, simultaneous decoded publishing
with independent client sessions, recovery after agent restarts, and WiFi
loss/rejoin both individually and together. USB logging was also verified with
a data cable and no open terminal, a terminal attached later, and a cable that
supplies power without a working data connection. These checks were completed
on 2026-10-19/20 with Zig 0.17.0 and the patched MicroZig baseline.

The agent currently validates and logs samples; DDS forwarding is not yet
implemented. Repeated fault cycles and extended soak tests are optional further
confidence checks.

`zig build test` runs the host identity and USB logging tests and the six focused driver
regressions supplied by the MicroZig patches. Firmware builds still require the
local `src/secrets.zig` configuration.
