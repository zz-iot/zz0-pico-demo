#!/usr/bin/env python3
"""Check the DDS consumer with its host publisher fixture over localhost."""
import argparse
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--consumer", type=Path, default=Path("zig-out/bin/counter-consumer"))
    parser.add_argument("--logs", required=True, type=Path)
    parser.add_argument("--domain", type=int, default=191)
    args = parser.parse_args()
    if not 0 <= args.domain <= 232:
        parser.error("domain must be between 0 and 232")
    args.logs.mkdir(parents=True, exist_ok=True)
    consumer_log = args.logs / "consumer.log"
    publisher_log = args.logs / "publisher.log"
    command = [str(args.consumer.resolve()), f"--domain={args.domain}",
               "--board=host-fixture", "--count=3", "--timeout=15"]
    processes = []
    with consumer_log.open("w") as receiver_out, publisher_log.open("w") as publisher_out:
        try:
            processes.append(subprocess.Popen(command, stdout=receiver_out, stderr=receiver_out))
            # The fixture publisher waits for a reader match before sending.
            processes.append(subprocess.Popen(command + ["--publish-fixture"],
                                              stdout=publisher_out, stderr=publisher_out))
            for process in processes:
                if process.wait(timeout=25) != 0:
                    raise RuntimeError(f"DDS fixture failed; see {args.logs}")
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
    output = consumer_log.read_text()
    for counter in range(3):
        if f"sample board=host-fixture counter={counter} payload=010203" not in output:
            raise RuntimeError(f"missing or incorrect sample {counter}; see {consumer_log}")
    if "counter-consumer: received 3 samples" not in output:
        raise RuntimeError(f"consumer did not finish; see {consumer_log}")
    print("PASS: DDS consumer received all three fixture samples with expected fields")


if __name__ == "__main__":
    main()
