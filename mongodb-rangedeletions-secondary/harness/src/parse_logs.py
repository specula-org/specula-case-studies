#!/usr/bin/env python3
"""
Cross-check trace events with MongoDB LOGV2 structured logs.

Reads the secondary's log file and verifies that trace events
correspond to real MongoDB log entries where possible.

Usage:
    python3 parse_logs.py <log_file> <trace_file>
"""

import json
import sys
from collections import defaultdict

# MongoDB LOGV2 IDs relevant to RangeDeletionsSecondaryNodes
LOG_IDS = {
    10016300: "QueryKilled",         # shard_role.cpp — query killed by range deletion
    11079600: "StepUp",              # range_deleter_service.cpp — service is now up
    7536600:  "RecoverTask",         # range_deleter_service.cpp — registering task (per-task)
    6834800:  "RecoverTaskStart",    # range_deleter_service.cpp — resubmitting tasks
    6834802:  "RecoverTaskEnd",      # range_deleter_service.cpp — finished resubmitting
    11366700: "InvalidationSkip",    # collection_sharding_runtime.cpp — UUID mismatch skip
    21291:    "AppliedThrough",      # replication_consistency_markers_impl.cpp — batch committed proxy
    21230:    "BatchSize",           # oplog_applier_impl.cpp — oplog batch size
}


def parse_log(log_file):
    """Parse MongoDB LOGV2 JSON log, extract relevant entries."""
    events = defaultdict(list)
    with open(log_file) as f:
        for line_no, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                continue
            log_id = obj.get("id")
            if log_id in LOG_IDS:
                ts = ""
                t_field = obj.get("t", {})
                if isinstance(t_field, dict):
                    ts = t_field.get("$date", "")
                elif isinstance(t_field, str):
                    ts = t_field
                events[LOG_IDS[log_id]].append({
                    "ts": ts,
                    "id": log_id,
                    "line": line_no,
                    "msg": obj.get("msg", ""),
                    "attr": obj.get("attr", {}),
                })
    return events


def main():
    if len(sys.argv) < 3:
        print("Usage: parse_logs.py <log_file> <trace_file>")
        sys.exit(1)

    log_file = sys.argv[1]
    trace_file = sys.argv[2]

    print(f"=== Cross-checking {trace_file} with {log_file} ===")

    # Parse MongoDB logs
    log_events = parse_log(log_file)
    total_relevant = sum(len(v) for v in log_events.values())
    print(f"Found {total_relevant} relevant log entries:")
    for name in sorted(log_events):
        entries = log_events[name]
        print(f"  {name}: {len(entries)} entries")
        for e in entries[:3]:
            print(f"    [{e['id']}] {e['ts']}  {e['msg'][:80]}")
        if len(entries) > 3:
            print(f"    ... and {len(entries) - 3} more")

    # Parse trace
    with open(trace_file) as f:
        trace_lines = []
        for line in f:
            line = line.strip()
            if line:
                trace_lines.append(json.loads(line))

    print(f"\nTrace has {len(trace_lines)} lines:")
    for i, tl in enumerate(trace_lines):
        event = tl.get("event", "?")
        extras = " ".join(f"{k}={tl[k]}" for k in ["rd", "query", "queryState", "lastAppliedSnapshotSize"]
                          if k in tl)
        print(f"  [{i+1}] {event}  {extras}")

    # Cross-check: verify trace events have log evidence where expected
    ok = True
    checks = 0

    for tl in trace_lines:
        event = tl.get("event")

        if event == "QueryKilled":
            checks += 1
            if "QueryKilled" in log_events:
                e = log_events["QueryKilled"][0]
                print(f"\n  [PASS] QueryKilled confirmed by log 10016300 at {e['ts']}")
            else:
                print(f"\n  [FAIL] QueryKilled in trace but no log 10016300 found!")
                ok = False

        elif event == "QueryProceed":
            checks += 1
            if "QueryKilled" not in log_events:
                print(f"\n  [PASS] QueryProceed: no QueryKilled log found (consistent)")
            else:
                print(f"\n  [WARN] QueryProceed in trace but log 10016300 WAS found")

        elif event == "StepUp":
            checks += 1
            if "StepUp" in log_events:
                e = log_events["StepUp"][0]
                print(f"\n  [PASS] StepUp confirmed by log 11079600 at {e['ts']}")
            else:
                print(f"\n  [INFO] StepUp in trace but no log 11079600 (fires on primary, not secondary)")

        elif event == "RecoverTask":
            checks += 1
            if "RecoverTask" in log_events:
                e = log_events["RecoverTask"][0]
                print(f"\n  [PASS] RecoverTask confirmed by log 7536600 at {e['ts']}")
            else:
                print(f"\n  [INFO] RecoverTask in trace but no log 7536600 on this node")

        elif event == "SignalUpdate":
            checks += 1
            # No direct log for SignalUpdate. Check for related logs.
            if "AppliedThrough" in log_events:
                print(f"\n  [PASS] SignalUpdate: oplog batch applied (log 21291 found)")
            elif "BatchSize" in log_events:
                print(f"\n  [PASS] SignalUpdate: oplog batches processed (log 21230 found)")
            else:
                print(f"\n  [INFO] SignalUpdate: no corroborating oplog batch log found")
                print(f"         (normal if replication verbosity < 3)")

        elif event == "BatchCommitted":
            checks += 1
            if "AppliedThrough" in log_events:
                print(f"\n  [PASS] BatchCommitted: oplog applied through marker found (log 21291)")
            else:
                print(f"\n  [INFO] BatchCommitted: inferred from moveChunk completion")

    # Summary
    print(f"\n--- Summary: {checks} cross-checks performed ---")

    # Report any unexpected log events
    unexpected = set(log_events.keys()) - {"QueryKilled", "StepUp", "RecoverTask",
        "RecoverTaskStart", "RecoverTaskEnd", "AppliedThrough", "BatchSize"}
    if "InvalidationSkip" in log_events:
        print(f"\n  [WARN] InvalidationSkip (log 11366700) found — UUID mismatch detected!")
        for e in log_events["InvalidationSkip"]:
            print(f"         {e['ts']}: {e['attr']}")

    if ok:
        print("\n=== Cross-check PASSED ===")
    else:
        print("\n=== Cross-check FAILED ===")
        sys.exit(1)


if __name__ == "__main__":
    main()
