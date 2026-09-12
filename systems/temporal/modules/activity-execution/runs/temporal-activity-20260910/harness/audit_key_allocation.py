#!/usr/bin/env python3
"""Check independent pre/post key snapshots; never produce a model successor."""

import argparse
import copy
import datetime
import hashlib
import json
from pathlib import Path
import re

MS = 1_000_000


def nanoseconds(value):
    match = re.fullmatch(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d{1,9}))?Z", value)
    assert match, ("unsupported timestamp", value)
    seconds = int(datetime.datetime.fromisoformat(match[1] + "+00:00").timestamp())
    return seconds * 1_000_000_000 + int((match[2] or "").ljust(9, "0"))


def check_pair(before, after):
    observation = after["observation"]
    now = nanoseconds(observation["allocationTime"])
    minimum = nanoseconds(observation["minScheduledTime"])
    assert minimum % MS == 0, "minimum scheduled time must be a millisecond"
    assert minimum >= (now // MS) * MS, "minimum scheduled time precedes allocation clock"
    old = before["observation"]["mutation"]["Tasks"]
    new = observation["request"]["UpdateWorkflowMutation"]["Tasks"]
    assert old.keys() == new.keys(), "key assignment changed categories"
    rows = []
    for category, tasks in new.items():
        assert len(old[category]) == len(tasks), "key assignment changed task count"
        for index, task in enumerate(tasks):
            previous = old[category][index]
            due = nanoseconds(previous["VisibilityTimestamp"])
            actual = nanoseconds(task["VisibilityTimestamp"])
            scheduled = "type:Scheduled" in category
            rounded = ((due + MS) // MS) * MS
            moved = scheduled and rounded < minimum
            expected = (minimum + MS if moved else rounded) if scheduled else now
            assert actual == expected, f"visibility mismatch at raw seq {after['seq']}, task {task['TaskID']}"
            assert task["TaskID"] > 0, "allocated task has no ID"
            unchanged = lambda t: {k: v for k, v in t.items() if k not in {"TaskID", "VisibilityTimestamp"}}
            assert unchanged(previous) == unchanged(task), "key assignment changed task identity/payload"
            rows.append(
                {
                    "closeRawSeq": before["seq"],
                    "allocationRawSeq": after["seq"],
                    "category": category,
                    "taskId": task["TaskID"],
                    "before": previous["VisibilityTimestamp"],
                    "after": task["VisibilityTimestamp"],
                    "allocationTime": observation["allocationTime"],
                    "minScheduledTime": observation["minScheduledTime"],
                    "timerProcessorMaxTimeShiftNs": observation["timerProcessorMaxTimeShift"],
                    "cursorAheadNs": minimum - now,
                    "scheduled": scheduled,
                    "movedPastCursor": moved,
                    "visibilityDeltaNs": actual - due,
                }
            )
    return rows


def audit(path):
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    closes = {}
    checked = []
    controls = []
    for row in rows:
        event = row.get("event")
        if event == "CloseTransactionAsMutation":
            closes[row["observation"]["mutation"]["DBRecordVersion"]] = row
        elif event == "SetAndTrackTaskKeys":
            version = row["observation"]["request"]["UpdateWorkflowMutation"]["DBRecordVersion"]
            before = closes[version]
            results = check_pair(before, row)
            checked.extend(results)
            if results and not controls:
                for kind in ["wrong_visibility", "missing_minimum", "changed_payload"]:
                    corrupted = copy.deepcopy(row)
                    obs = corrupted["observation"]
                    task = next(t for ts in obs["request"]["UpdateWorkflowMutation"]["Tasks"].values() for t in ts)
                    if kind == "wrong_visibility":
                        task["VisibilityTimestamp"] = "2001-01-01T00:00:00Z"
                    elif kind == "missing_minimum":
                        del obs["minScheduledTime"]
                    else:
                        task["Version"] = 123456789
                    try:
                        check_pair(before, corrupted)
                    except (AssertionError, KeyError) as error:
                        controls.append({"kind": kind, "status": "REJECTED", "reason": str(error)})
                    else:
                        raise AssertionError("corruption accepted: " + kind)
    assert checked, "no key allocations checked"
    return {
        "scenario": path.stem,
        "rawSHA256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "status": "PASS",
        "checks": checked,
        "controls": controls,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("run", type=Path)
    args = parser.parse_args()
    scenarios = [audit(path) for path in sorted((args.run / "raw").glob("*.jsonl"))]
    checks = [check for scenario in scenarios for check in scenario["checks"]]
    result = {
        "status": "PASS",
        "scope": "independent raw task-key observations only; no complete TLA+ replay",
        "scenarios": scenarios,
        "scenarioCount": len(scenarios),
        "taskCount": len(checks),
        "scheduledTaskCount": sum(c["scheduled"] for c in checks),
        "movedPastCursorCount": sum(c["movedPastCursor"] for c in checks),
        "maxCursorAheadNs": max(c["cursorAheadNs"] for c in checks),
        "corruptionsRejected": sum(len(s["controls"]) for s in scenarios),
    }
    (args.run / "key-allocation-audit.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: v for k, v in result.items() if k != "scenarios"}, indent=2))


if __name__ == "__main__":
    main()
