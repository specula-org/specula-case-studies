#!/usr/bin/env python3
"""Format, schema, timestamp, state, and event-coverage checks."""

import argparse
import json
from pathlib import Path
from typing import Dict, Set

REQUIRED_COVERAGE = {
    "HandleRebootRequestAccept",
    "HostServiceIssueRebootAccept",
    "HostServiceTransportFailure",
    "WaitForPlatformRebootStart",
    "PlatformRebootDeadline",
    "HandleRebootFinishJoinable",
    "FastRebootBegin",
    "EnableWarmRestart",
    "RegisterWarmComponent",
    "WarmComponentReconciled",
    "FinalizerTimeoutAsReady",
    "FinalizerDeadline",
    "FinalizeNamespace",
    "FinalizeGlobal",
    "SaveDatabase",
}

ALL_INSTRUMENTED = REQUIRED_COVERAGE | {
    "StartThreadLaunchFailure",
    "HandleRebootFinishNonJoinable",
    "HostServiceIssueRebootReject",
    "HostComplete",
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace_dir", type=Path)
    args = parser.parse_args()
    coverage: Dict[str, Set[str]] = {}

    traces = sorted(args.trace_dir.glob("*.ndjson"))
    if not traces:
        raise SystemExit("no enriched traces found")
    for trace in traces:
        names: Set[str] = set()
        with trace.open(encoding="utf-8") as stream:
            for line_number, line in enumerate(stream, 1):
                record = json.loads(line)
                if record.get("tag") != "trace":
                    raise ValueError(f"{trace}:{line_number}: missing tag=trace")
                event = record.get("event", {})
                if not isinstance(event.get("monotonic_ns"), int) or event["monotonic_ns"] < 1_000_000_000:
                    raise ValueError(f"{trace}:{line_number}: timestamp is not a real monotonic clock value")
                if not event.get("state"):
                    raise ValueError(f"{trace}:{line_number}: missing complete modified state record")
                if not event.get("observed"):
                    raise ValueError(f"{trace}:{line_number}: missing raw observed fields")
                names.add(event["name"])
        if not names:
            raise ValueError(f"{trace}: empty trace")
        coverage[trace.name] = names

    all_names = set().union(*coverage.values())
    missing = REQUIRED_COVERAGE - all_names
    if missing:
        raise ValueError(f"required event coverage missing: {sorted(missing)}")

    print("event coverage by trace:")
    for name, names in coverage.items():
        print(f"  {name}: {', '.join(sorted(names))}")
    intentionally_uncovered = ALL_INSTRUMENTED - all_names
    if intentionally_uncovered:
        print("instrumented but environment-limited (documented): " + ", ".join(sorted(intentionally_uncovered)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
