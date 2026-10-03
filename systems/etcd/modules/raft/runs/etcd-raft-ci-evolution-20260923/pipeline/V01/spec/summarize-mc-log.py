#!/usr/bin/env python3
"""Retain literal TLC execution facts; missing completion is never a pass."""
import argparse
import hashlib
import json
import re
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("log", type=Path)
args = parser.parse_args()
log = args.log.resolve()
raw = log.read_text()
label = log.stem
exit_file = log.with_suffix(".exit")
record = {
    "log": str(log),
    "log_sha256": hashlib.sha256(log.read_bytes()).hexdigest(),
    "exit_status": int(exit_file.read_text()) if exit_file.exists() else None,
    "mode": "simulation" if "Running Random Simulation" in raw else "bfs",
    "errors_reported": re.findall(r"^Error:.*$", raw, re.M),
    "natural_exhaustive_completion_reported": "Model checking completed. No error has been found." in raw,
    "statistics_kind": "last periodic sample; not final totals",
}
if record["mode"] == "bfs":
    samples = re.findall(
        r"Progress\((\d+)\) at ([^:]+:\d+:\d+): ([\d,]+) states generated.*?, "
        r"([\d,]+) distinct states found.*?, ([\d,]+) states left on queue\.", raw)
    if samples:
        depth, timestamp, generated, distinct, queued = samples[-1]
        record["last_periodic_sample"] = {
            "timestamp": timestamp, "depth": int(depth),
            "states_generated": int(generated.replace(",", "")),
            "distinct_states": int(distinct.replace(",", "")),
            "states_queued": int(queued.replace(",", "")),
        }
else:
    samples = re.findall(r"Progress: (\d+) states checked, (\d+) traces generated ([^\n]+)", raw)
    if samples:
        checked, traces, length = samples[-1]
        record["last_periodic_sample"] = {
            "states_checked": int(checked), "traces_generated": int(traces),
            "raw_trace_length_statistics": length,
            "depth_interpretation": "Configured cap only; mean/variance reporting has documented integer-truncation error. Observed maximum unavailable.",
        }
    seed = re.search(r"Running Random Simulation with seed (-?\d+)", raw)
    record["seed"] = int(seed.group(1)) if seed else None
    record["natural_exhaustive_completion_reported"] = False
cex = log.with_name(label + "-counterexample.json")
record["counterexample_file"] = str(cex) if cex.exists() else None
record["interpretation"] = (
    "Review reported errors/counterexample before classification."
    if record["errors_reported"] or record["counterexample_file"] else
    "No violation reported in this log; absence alone does not establish convergence or exhaustive safety."
)
destination = log.with_name(label + "-execution-facts.json")
destination.write_text(json.dumps(record, indent=2) + "\n")
print(json.dumps(record, indent=2))
