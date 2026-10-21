#!/usr/bin/env python3

"""Extract one real Asterinas console trace and preserve timebox overlap."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

TRACE_PREFIX = "SPECULA_TRACE "


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("scenario")
    parser.add_argument("log", type=Path)
    parser.add_argument("trace_dir", type=Path)
    return parser.parse_args()


def extract_events(log: Path, scenario: str) -> list[dict[str, object]]:
    text = log.read_text(errors="replace")
    if f"SPECULA_SCENARIO_PASS {scenario}" not in text:
        raise SystemExit(f"{log}: scenario did not report success")
    if "SPECULA_TRACE_ERROR" in text:
        errors = [line for line in text.splitlines() if "SPECULA_TRACE_ERROR" in line]
        raise SystemExit(f"{log}: trace producer error: {errors}")
    if "SPECULA_TRACE_BEGIN" not in text or "SPECULA_TRACE_END" not in text:
        raise SystemExit(f"{log}: incomplete trace fence")

    events: list[dict[str, object]] = []
    for line in text.splitlines():
        marker = line.find(TRACE_PREFIX)
        if marker < 0:
            continue
        event = json.loads(line[marker + len(TRACE_PREFIX) :])
        if event.get("tag") != "trace":
            raise SystemExit(f"{log}: invalid trace tag")
        if event.get("tid") not in {"t1", "t2"}:
            raise SystemExit(f"{log}: invalid actor {event.get('tid')!r}")
        if not isinstance(event.get("event"), str):
            raise SystemExit(f"{log}: missing event name")
        if not isinstance(event.get("args"), dict) or not isinstance(event.get("state"), dict):
            raise SystemExit(f"{log}: args/state must be JSON objects")
        start = event.get("start")
        end = event.get("end")
        if not isinstance(start, int) or not isinstance(end, int) or start > end:
            raise SystemExit(f"{log}: invalid timebox {start!r}..{end!r}")
        events.append(event)

    if not events:
        raise SystemExit(f"{log}: no trace events")
    return events


def compress_timestamps(events: list[dict[str, object]]) -> None:
    boundaries = sorted({int(event[key]) for event in events for key in ("start", "end")})
    compressed = {value: index + 1 for index, value in enumerate(boundaries)}
    for event in events:
        event["start"] = compressed[int(event["start"])]
        event["end"] = compressed[int(event["end"])]


def main() -> None:
    args = parse_args()
    events = extract_events(args.log, args.scenario)
    raw_events = json.loads(json.dumps(events))
    compress_timestamps(events)

    args.trace_dir.mkdir(parents=True, exist_ok=True)
    raw_dir = args.trace_dir / "raw"
    raw_dir.mkdir(parents=True, exist_ok=True)
    for actor in ("t1", "t2"):
        actor_raw = raw_dir / f"{args.scenario}-{actor}.ndjson"
        actor_raw.write_text(
            "".join(
                json.dumps(event, separators=(",", ":")) + "\n"
                for event in raw_events
                if event["tid"] == actor
            )
        )

    merged = {
        "traces": {
            actor: [event for event in events if event["tid"] == actor]
            for actor in ("t1", "t2")
        }
    }
    output = args.trace_dir / f"{args.scenario}.ndjson"
    output.write_text(json.dumps(merged, separators=(",", ":")) + "\n")
    print(f"collected {len(events)} events in {output}")


if __name__ == "__main__":
    main()
