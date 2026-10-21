#!/usr/bin/env python3
"""Classify Trace.tla replay logs and write a JSON summary.

A replay passes only when TLC reports the TraceIncomplete sentinel, no other
invariant or temporal error, and the witness's last cursor map equals each
stream's event count plus one. TraceIncomplete is checked last in Trace.cfg,
so its report implies that the earlier invariants held in that state.

Usage: trace_verdicts.py LOG_DIR TRACE_DIR OUT_JSON
"""

import json
import re
import sys
from collections import Counter
from pathlib import Path

CURSOR_RE = re.compile(r"^/\\ l = \[(.*)\]\s*$")
STATS_RE = re.compile(r"(\d+) states generated, (\d+) distinct states found, (\d+) states left on queue")
DEPTH_RE = re.compile(r"The depth of the complete state graph search is (\d+)")


def stream_lengths(trace: Path) -> dict[str, int]:
    lines = trace.read_text().splitlines()
    events = [json.loads(line) for line in lines[1:] if line.strip()]
    return dict(Counter(event["pid"] for event in events))


def parse_cursor(text: str) -> dict[str, int]:
    cursor = {}
    for item in text.split(","):
        pid, value = item.split("|->")
        cursor[pid.strip()] = int(value.strip())
    return cursor


def classify(log: Path, trace: Path) -> dict:
    text = log.read_text(errors="replace")
    lines = text.splitlines()
    violated = re.findall(r"Invariant (\w+) is violated", text)
    # TLC words this as "Temporal property X was violated" for one property and
    # "Temporal properties were violated" for several.
    temporal_re = re.compile(r"Temporal propert(y \w+ was|ies were) violated")
    temporal = bool(temporal_re.search(text))
    other_errors = [
        line
        for line in lines
        if line.startswith("Error:")
        and "is violated" not in line
        and "The behavior up to this point is" not in line
        and "The following behavior constitutes a counter-example" not in line
        and not temporal_re.search(line)
    ]
    cursors = [parse_cursor(m.group(1)) for line in lines if (m := CURSOR_RE.match(line))]
    expected = {pid: count + 1 for pid, count in stream_lengths(trace).items()}
    stats = STATS_RE.findall(text)
    depth = DEPTH_RE.findall(text)
    result = {
        "log": str(log),
        "violated_invariants": violated,
        "temporal_violation": temporal,
        "other_errors": other_errors,
        "final_cursor": cursors[-1] if cursors else None,
        "expected_cursor": expected,
        "states": stats[-1] if stats else None,
        "depth": depth[-1] if depth else None,
    }
    if violated == ["TraceIncomplete"] and not temporal and not other_errors and cursors and cursors[-1] == expected:
        result["verdict"] = "PASS_COMPLETE_REPLAY"
    elif any(name != "TraceIncomplete" for name in violated):
        result["verdict"] = "FAIL_INVARIANT"
    elif temporal:
        result["verdict"] = "INCONCLUSIVE_TEMPORAL_FAILURE"
    elif other_errors:
        result["verdict"] = "ERROR"
    else:
        result["verdict"] = "NO_COMPLETE_WITNESS"
    return result


def main() -> None:
    log_dir, trace_dir, out_json = (Path(arg) for arg in sys.argv[1:4])
    results = {}
    for log in sorted(log_dir.glob("trace-case-*.out")):
        case_id = log.stem.removeprefix("trace-case-")
        results[case_id] = classify(log, trace_dir / f"case-{case_id}.ndjson")
    out_json.write_text(json.dumps(results, indent=1) + "\n")
    for case_id, result in results.items():
        print(case_id, result["verdict"], result["states"], "depth", result["depth"])


if __name__ == "__main__":
    main()
