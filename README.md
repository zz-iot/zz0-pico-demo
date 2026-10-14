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
- Emit logs over USB CDC on `/dev/ttyACM*`.

WiFi credentials and agent endpoint settings live in ignored `src/secrets.zig`.
Start from `src/secrets.zig.template`.

Build with Zig 0.15.1:

```sh
zig build
```

The build generates `CounterStatus` Zig typesupport from
`idl/counter_types.idl` using a prebuilt local `zidl` binary. By default it uses
`../zidl/zig-out/bin/zidl`; override that with
`-Dzidl=/path/to/zidl` if needed.

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

The current development layout expects sibling checkouts of `zz0_client`,
`microzig` (the Zig 0.15.1-compatible revision), and `zidl`. Build `zidl` before
building the firmware. Copy `src/secrets.zig.template` to `src/secrets.zig` and
configure it locally. Both Pico firmware targets are built by `zig build`;
UF2 and ELF outputs are installed under `zig-out/`.

The tested MicroZig baseline is commit
`3edec7f593c33b527d945b5a44f07c8cd67d7fdc` plus
[the WiFi retry patch](patches/microzig-wifi-join-reset.patch). For a fresh checkout
at that revision, apply it from this directory:

```sh
git -C ../microzig apply ../zz0-pico-demo/patches/microzig-wifi-join-reset.patch
```

The patch clears stale join state before retrying WiFi authentication.
