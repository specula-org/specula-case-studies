#!/usr/bin/env python3
"""
preprocess_trace.py — Sort and filter libomp traces for TLA+ validation.

1. Sort events by (timestamp, tid) for deterministic ordering
2. Fix schedule/steal ordering (ScheduleTask must precede StealTask for same task)
3. Remove events before the first barrier entry (from fork barrier)
4. Keep only the first barrier round (per-thread BarrierDone tracking)
5. Replace JSON null with "Nil" string (TLA+ cannot deserialize null)
6. Write the processed trace to stdout or a file
"""

import json
import sys

def preprocess(input_path, output_path=None):
    events = []
    with open(input_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                if obj.get("tag") == "trace":
                    events.append(obj)
            except json.JSONDecodeError:
                pass

    # Sort by (timestamp, tid)
    events.sort(key=lambda e: (e.get("ts", 0), e.get("tid", -1)))

    # Fix schedule/steal ordering: __kmp_push_task pushes to the deque
    # BEFORE the ScheduleTask trace event is emitted (race with trace mutex).
    # Another thread can steal a task before the schedule event is logged.
    # Reorder: move each ScheduleTask/ScheduleDetachTask before the first
    # StealTask/ExecuteTask that references the same task.
    schedule_events = {"ScheduleTask", "ScheduleDetachTask"}
    task_ref_events = {"StealTask", "ExecuteTask"}
    first_ref = {}  # task -> index of first steal/execute reference
    sched_idx = {}  # task -> index of schedule event
    for i, e in enumerate(events):
        ev = e.get("event", "")
        task = e.get("task")
        if task and ev in schedule_events and task not in sched_idx:
            sched_idx[task] = i
        if task and ev in task_ref_events and task not in first_ref:
            first_ref[task] = i

    # Find schedule events that appear after their first reference
    moves = []  # (from_idx, to_idx)
    for task, si in sched_idx.items():
        if task in first_ref and first_ref[task] < si:
            moves.append((si, first_ref[task]))

    if moves:
        # Sort by from_idx descending so removals don't shift indices
        moves.sort(key=lambda x: -x[0])
        for from_idx, to_idx in moves:
            evt = events.pop(from_idx)
            events.insert(to_idx, evt)

    # Find the first barrier entry event (any thread)
    # This filters out fork barrier events that happen before explicit barriers
    barrier_entry_events = {"PrimaryEnterBarrier", "WorkerEnterBarrier", "ScheduleTask", "ScheduleDetachTask"}
    start_idx = 0
    for i, e in enumerate(events):
        if e.get("event") in barrier_entry_events:
            start_idx = i
            break

    # Keep only events from the first barrier onward
    events = events[start_idx:]

    # Filter out fork barrier TaskTeamSync events that leaked through.
    # These are TaskTeamSync events for threads that haven't yet entered
    # the explicit barrier (no prior WorkerEnterBarrier/PrimaryEnterBarrier).
    threads_entered = set()
    clean = []
    for e in events:
        event_name = e.get("event", "")
        tid = e.get("tid", -1)
        if event_name in ("WorkerEnterBarrier", "PrimaryEnterBarrier"):
            threads_entered.add(tid)
        if event_name == "TaskTeamSync" and tid not in threads_entered:
            continue
        clean.append(e)
    events = clean

    # Keep only the first barrier round:
    # - Track per-thread: include events up to and including first BarrierDone
    # - Remove StartNextRound events (round transition not modeled in single-round trace)
    threads_done = set()
    filtered = []
    for e in events:
        event_name = e.get("event", "")
        tid = e.get("tid", -1)

        # Skip StartNextRound (no tid, marks round transition)
        if event_name == "StartNextRound":
            continue

        # Skip events from threads that have completed their BarrierDone
        if tid in threads_done:
            continue

        filtered.append(e)

        if event_name == "BarrierDone":
            threads_done.add(tid)

    events = filtered

    # Replace JSON null with "Nil" string (TLA+ cannot deserialize null)
    def replace_nulls(obj):
        if isinstance(obj, dict):
            return {k: replace_nulls(v) for k, v in obj.items()}
        if isinstance(obj, list):
            return [replace_nulls(v) for v in obj]
        if obj is None:
            return "Nil"
        return obj
    events = [replace_nulls(e) for e in events]

    # Write output
    out = open(output_path, "w") if output_path else sys.stdout
    for e in events:
        out.write(json.dumps(e, separators=(",", ":")) + "\n")
    if output_path:
        out.close()
        print(f"Preprocessed: {input_path} -> {output_path} ({len(events)} events)", file=sys.stderr)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: preprocess_trace.py <input.ndjson> [output.ndjson]", file=sys.stderr)
        sys.exit(1)
    input_path = sys.argv[1]
    output_path = sys.argv[2] if len(sys.argv) > 2 else None
    preprocess(input_path, output_path)
