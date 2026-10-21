#!/usr/bin/env python3
"""Summarize round-2 TLC logs into spec/output/tlc-runs-round2.json.

Usage: run_index.py OUT_JSON LOG...
"""

import json
import re
import sys
from pathlib import Path


def last(pattern: str, text: str):
    found = re.findall(pattern, text)
    return found[-1] if found else None


def summarize(log: Path) -> dict:
    text = log.read_text(errors="replace")
    mode = "simulation" if "Running Random Simulation" in text else "bfs"
    entry = {"log": str(log), "mode": mode}
    violated = re.findall(r"Invariant (\w+) is violated", text)
    temporal = re.findall(r"Temporal propert(?:y (\w+) was|ies were) violated", text)
    if violated:
        entry["outcome"] = "INVARIANT_VIOLATION"
        entry["invariant"] = violated[0]
        entry["trace_states"] = len(re.findall(r"^State \d+:", text, re.M))
    elif temporal:
        entry["outcome"] = "TEMPORAL_VIOLATION"
    elif "Model checking completed. No error has been found" in text:
        entry["outcome"] = "COMPLETE_NO_VIOLATION"
    else:
        entry["outcome"] = "BUDGET_EXHAUSTED_NO_VIOLATION"
    if mode == "bfs":
        stats = last(r"([\d,]+) states generated.*?([\d,]+) distinct states found.*?([\d,]+) states left on queue", text)
        if stats:
            entry["generated"], entry["distinct"], entry["queued"] = (int(v.replace(",", "")) for v in stats)
        depth = last(r"depth of the complete state graph search is (\d+)", text) or last(r"Progress\((\d+)\)", text)
        entry["depth"] = int(depth) if depth else None
    else:
        sim = last(r"([\d,]+) states checked, ([\d,]+) traces generated \(trace length: mean=(\d+)", text)
        if sim:
            entry["states_checked"], entry["traces"], entry["mean_trace_length"] = (int(v.replace(",", "")) for v in sim)
    return entry


def main() -> None:
    out = Path(sys.argv[1])
    runs = {Path(arg).name: summarize(Path(arg)) for arg in sys.argv[2:]}
    out.write_text(json.dumps(runs, indent=1) + "\n")
    for name, entry in runs.items():
        print(name, {k: v for k, v in entry.items() if k != "log"})


if __name__ == "__main__":
    main()
