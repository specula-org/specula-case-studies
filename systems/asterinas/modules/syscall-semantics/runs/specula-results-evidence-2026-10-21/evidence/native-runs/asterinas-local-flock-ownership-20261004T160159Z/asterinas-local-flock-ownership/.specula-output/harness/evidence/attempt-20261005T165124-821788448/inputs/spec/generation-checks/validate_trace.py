#!/usr/bin/env python3
"""Translate TLC witness search into Specula's Phase 3 validation statuses."""

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess

JAVA = "/nix/store/vymiz4fvnc1s8k19kz2lqvkv3g2k0ys6-openjdk-headless-21.0.12.1+1/bin/java"
CP = ("/home/chin39/Documents/play/Specula/lib/tla2tools.jar:"
      "/home/chin39/Documents/play/Specula/lib/CommunityModules-deps.jar")
SPEC = Path(__file__).resolve().parents[1]


def validate(trace_file):
    trace = Path(trace_file).resolve()
    name = trace.stem
    log = SPEC / "generation-checks" / ("trace-" + name + ".log")
    attempt = 1
    while log.exists():
        attempt += 1
        log = SPEC / "generation-checks" / (f"trace-{name}-{attempt}.log")
    metadata = SPEC.parent / "states" / ("trace-" + name)
    cmd = ["timeout", "1800", JAVA, "-Xmx3g", "-XX:+UseParallelGC",
           "-DTLA-Library=.", "-cp", CP, "tlc2.TLC", "-workers", "2",
           "-noGenerateSpecTE", "-metadir", str(metadata),
           "-config", "Trace.cfg", "Trace.tla"]
    with log.open("w") as stream:
        run = subprocess.run(cmd, cwd=SPEC, env={**os.environ, "JSON": str(trace)},
                             stdout=stream, stderr=subprocess.STDOUT)
    output = log.read_text()
    errors = [line for line in output.splitlines() if line.startswith("Error:")]
    witness = any(line.startswith("Error: Invariant TraceNoWitness is violated")
                  for line in errors)
    other_errors = [line for line in errors if not (
        line.startswith("Error: Invariant TraceNoWitness is violated") or
        line == "Error: The behavior up to this point is:")]
    if witness and run.returncode == 12 and not other_errors:
        status, outcome = "success", "ACCEPTED"
    elif run.returncode == 0 and not errors and (
            "Model checking completed. No error has been found." in output):
        status, outcome = "trace_mismatch", "REJECTED"
    else:
        status = "error"
        outcome = "INCOMPLETE" if run.returncode in (124, 137) else "ERROR"
    counts = re.findall(r"([\d,]+) states generated, ([\d,]+) distinct states found, "
                        r"([\d,]+) states left on queue", output)
    result = {"status": status, "outcome": outcome, "tlc_exit": run.returncode,
              "trace_file": str(trace), "log": str(log),
              "command": "cd " + shlex.quote(str(SPEC)) + " && JSON=" +
              shlex.quote(str(trace)) + " " + shlex.join(cmd)}
    if counts:
        result.update(zip(("states_generated", "distinct_states", "queue"),
                          (int(x.replace(",", "")) for x in counts[-1])))
    result["witness_states"] = len(re.findall(r"^State \d+:", output, re.M))
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace_file")
    args = parser.parse_args()
    result = validate(args.trace_file)
    print(json.dumps(result, indent=2))
    raise SystemExit({"success": 0, "trace_mismatch": 1, "error": 2}[result["status"]])
