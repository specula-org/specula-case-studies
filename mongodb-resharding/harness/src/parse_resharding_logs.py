#!/usr/bin/env python3
"""
Parse MongoDB structured logs to extract resharding coordinator state transitions.
Produces NDJSON traces compatible with Trace.tla.

Input: MongoDB mongod log file (JSON structured log, one JSON object per line)
Output: NDJSON trace file with tag="trace" events

Key log IDs:
  5343001 — Coordinator state transition (newState, oldState)
  9307800 — TransactionCoordinatorService initialization (step-up indicator)
  5093707 — Abort with participants
"""

import json
import sys
import os

# Log IDs we care about
LOG_COORD_TRANSITION = 5343001  # "Transitioned resharding coordinator state"
LOG_STEP_UP = 9307800           # "Starting TransactionCoordinatorService initialization"
LOG_ABORT_PARTICIPANTS = 5093707 # "Resharding coordinator encountered transient error while aborting"

# MongoDB state enum string → Trace event name
# MongoDB 8.2+ logs use lowercase without 'k' prefix
STATE_TO_EVENT = {
    ("unused", "initializing"): "CoordInitialize",
    ("initializing", "preparing-to-donate"): "CoordPrepare",
    ("preparing-to-donate", "cloning"): "CoordTransitionToCloning",
    ("cloning", "applying"): "CoordTransitionToApplying",
    ("applying", "blocking-writes"): "CoordTransitionToBlocking",
    ("blocking-writes", "committing"): "CoordCommit",
    # Abort transitions
    ("preparing-to-donate", "aborting"): "CoordAbortPersist",
    ("cloning", "aborting"): "CoordAbortPersist",
    ("applying", "aborting"): "CoordAbortPersist",
    ("blocking-writes", "aborting"): "CoordAbortPersist",
    ("initializing", "aborting"): "CoordAbortPersist",
    # Finish transitions
    ("committing", "quiesced"): "CoordFinish",
    ("committing", "done"): "CoordFinish",
    ("aborting", "quiesced"): "CoordFinish",
    ("aborting", "done"): "CoordFinish",
    ("initializing", "done"): "CoordFinish",
    ("quiesced", "done"): "CoordFinish",
}


def parse_log_line(line):
    """Parse a single MongoDB structured log line."""
    line = line.strip()
    if not line:
        return None
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        return None

    # Must have id field
    if "id" not in obj:
        return None

    return obj


def extract_trace_events(log_file):
    """Extract resharding trace events from a MongoDB log file."""
    events = []

    with open(log_file, 'r') as f:
        for line in f:
            obj = parse_log_line(line)
            if obj is None:
                continue

            log_id = obj.get("id")
            ts = obj.get("t", {}).get("$date", "")
            attr = obj.get("attr", {})

            if log_id == LOG_COORD_TRANSITION:
                old_state = attr.get("oldState", "unknown")
                new_state = attr.get("newState", "unknown")
                key = (old_state, new_state)

                event_name = STATE_TO_EVENT.get(key)
                if event_name is None:
                    # Unknown transition — emit as generic
                    event_name = f"CoordTransition_{old_state}_to_{new_state}"

                event = {
                    "tag": "trace",
                    "ts": ts,
                    "event": {
                        "name": event_name,
                        "state": {
                            "coordState": new_state,
                            "oldState": old_state,
                        }
                    }
                }

                # Include abort reason if present
                resharding_uuid = attr.get("reshardingUUID", "")
                if resharding_uuid:
                    event["event"]["reshardingUUID"] = resharding_uuid

                events.append(event)

    return events


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <mongod_log_file> [output_ndjson]", file=sys.stderr)
        print(f"  Parses MongoDB structured log and extracts resharding coordinator trace events.", file=sys.stderr)
        sys.exit(1)

    log_file = sys.argv[1]
    output_file = sys.argv[2] if len(sys.argv) > 2 else None

    if not os.path.exists(log_file):
        print(f"Error: {log_file} not found", file=sys.stderr)
        sys.exit(1)

    events = extract_trace_events(log_file)

    if not events:
        print(f"Warning: No resharding coordinator events found in {log_file}", file=sys.stderr)

    # Output
    out = open(output_file, 'w') if output_file else sys.stdout
    for event in events:
        out.write(json.dumps(event) + '\n')

    if output_file:
        out.close()
        print(f"Wrote {len(events)} events to {output_file}", file=sys.stderr)
    else:
        print(f"Extracted {len(events)} events", file=sys.stderr)


if __name__ == "__main__":
    main()
