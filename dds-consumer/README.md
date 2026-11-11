# CounterStatus DDS consumer

A small host-only zzdds application for the Pico demo. It reads the same
`../idl/counter_types.idl` as the firmware, explicitly selects XCDR2 and prints
board, counter and payload. It is separate from the firmware build; MicroZig and
WiFi secrets are not needed.

Use Zig 0.17.0. The consumer pins zzdds 0.3.11 and uses that package's
zidl 0.3.27 generator/runtime; sibling zzdds and zidl checkouts are not required.
Override the IDL path with
`-Dcounter-idl=/path/to/counter_types.idl` if needed.

```sh
cd zz0-pico-demo/dds-consumer
zig build
zig build run -- --domain=0 --topic=CounterStatusTopic --type=CounterStatus --count=10 --timeout=30
```

Topic/type names must match the agent's configured DDS entities; XRCE catalog
references such as `MyLibrary::CounterStatusTopic` are not necessarily DDS topic
names. `--board=NAME` counts only samples from that board. Count is 1–256, timeout
is positive seconds. Reception is volatile/best-effort with finite reader limits,
so start the consumer before publishing. Success prints `received N samples` and
exits zero; missing samples or malformed/incorrectly encoded data fail nonzero.
The tool does not prove reliable delivery or general type support.

## Host-only smoke test

Run the automated host-only check after building the consumer:

```sh
python3 smoke.py --logs /tmp/pico-dds-consumer-smoke
```

It starts a subscriber and fixture publisher, checks all three samples' board,
counter and payload, and saves their logs. CI runs this check. The optional fixture
source publishes CounterStatus through zzdds, without XRCE. To run it manually:

```sh
# Terminal 1
zig build run -- --domain=191 --board=host-fixture --count=3 --timeout=10
# Terminal 2
zig build run -- --publish-fixture --domain=191 --board=host-fixture --count=3 --timeout=10
```

The publisher waits for a reader match, then sends three samples with counters
0–2 and payload `010203`. Local Linux testing received and decoded all three.
This validates the tool's DDS path, not the expanded agent.

## Publishing acceptance

The agent now forwards through its real DDS backend using an explicit configuration
and generated typesupport library. Its
`interop/dds_smoke.py` exercises a host XRCE client through UDP to this consumer,
including client deletion and bounded agent shutdown. Current Pico firmware sends
the modern binary CREATE path. Both-board forwarding and recovery were also
reported on hardware with the earlier built-in startup; see the results below.
The configured startup pass was also reported successful on 2026-11-11 with the
previous firmware images; see the newer result below. Independent XRCE/DDS
implementations, hardware malformed-data injection and longer soak tests remain further work.

## Pico forwarding check

Build the agent's explicit CounterStatus fixture library, the normal agent and
this consumer with Zig 0.17.0 (commands from `zz-dev`):

```sh
cd zz0_agent
zig build fixtures -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseSafe
cd ../zz0-pico-demo/dds-consumer
zig build -Doptimize=ReleaseSafe
cd ../..
```

Boards already using the current binary CREATE/plain-XCDR2 firmware need no reflash
for the startup change alone. Start the agent and both consumers in separate
terminals before powering up the boards (commands from `zz-dev`):

```sh
./zz0_agent/zig-out/bin/zz0_agent \
  --config zz0_agent/examples/counter/agent.toml \
  --library counter=zz0_agent/zig-out/lib/libcounter_types.so --write-log=summary
```

In another terminal:

```sh
./zz0-pico-demo/dds-consumer/zig-out/bin/counter-consumer --board=pico-wh --count=10 --timeout=30
```

Use `--board=pico2-wh` in a second consumer for Pico 2 W. The command uses the
Linux library filename; resources resolve relative to the manifest and the library
path resolves from the invocation directory. `--check-config` checks the files
offline; `--inspect` also loads/checks the provider without opening a listener.
The example selects domain 0 and XCDR2. Agent logs now show generic acceptance,
while this consumer decodes CounterStatus fields. Check that the consumer prints
the expected board and increasing counters, then exits with `received 10 samples`. The firmware
payload contains the counter's low two bytes followed by `a55a` (counter 1 prints
`payload=0100a55a`).
Agent STATUS/log output alone does not prove DDS receipt. Run both boards together
with one consumer per board filter to check independent clients.

Repeat after restarting the agent, resetting each board, and disconnecting and
restoring WiFi. Restart the agent with the same explicit configuration/library
arguments. Restart the consumer before each trial; it exits after its sample
count or timeout. Confirm each board resumes without interrupting the other.
The example writer has finite limits (256 keyed instances), so keep each trial
short and restart the agent between trials. A longer soak needs explicit instance
lifecycle/configuration work.

## Release-pin validation (2026-11-09)

The isolated DDS forwarding branch was checked against the documented patched
MicroZig 0.17.24 baseline. Both Pico targets produced UF2 and ELF outputs using
placeholder WiFi configuration, and all nine host/driver tests passed. Firmware
uses zidl 0.3.27 and the merged client commit; this consumer pins zzdds 0.3.11.

The automated DDS-only fixture received all three expected samples. The merged
agent's `interop/dds_smoke.py` also delivered three samples through XRCE, UDP,
the agent and this consumer, including RESET, client deletion and clean shutdown.
These are host checks. The board observations below are from earlier firmware;
they are not a hardware rerun of these dependency pins.


## Hardware results (2026-11-04)

Operator-reported results with Pico WH and Pico 2 WH, the default DDS-forwarding
agent and one consumer filtered for each board. Both consumers received 10 samples
and exited successfully in each scenario:

| Scenario | Observation |
| --- | --- |
| Both boards publishing | Consumers started after publishing began; each received 10 samples for its board. |
| Agent stopped and restarted | Both boards showed reconnect activity, recovered, and forwarded again; counters remained high because neither board reset. |
| Pico WH reset, agent and Pico 2 WH left running | Pico WH samples restarted at counter 1; Pico 2 WH samples retained high counters. |
| Access point disabled and restored | After a fresh agent start and both boards reconnecting, WiFi was interrupted and restored; each consumer received 10 samples again. |

These are reported DDS consumer observations, not just XRCE acknowledgements.
No raw logs were captured in this record. They establish bounded forwarding and
these recovery scenarios with our own DDS stack; they do not establish long-run
resource behavior or independent-vendor interoperability.


## Configured startup hardware results (2026-11-11)

The operator reports that the configured agent passed the documented acceptance
checks with the previous Pico/Pico2 firmware images, without reflashing. Both
board-filtered consumers met the documented 10-sample checks, including recovery
after agent restart, resetting either board while leaving the other running, and
access-point loss/restoration.

This is operator-reported evidence; raw logs, per-trial counter values and artifact
hashes were not supplied. It qualifies the explicit configuration/library startup
path with unchanged firmware. The 2026-11-04 record above remains evidence for the
older built-in startup. Longer soaks and independent-vendor DDS remain separate work.
