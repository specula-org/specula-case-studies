#!/usr/bin/env python3
"""Print a TLC JSON counterexample (-dumptrace json) as per-step field diffs.

ReactiveNext steps are reported by TLC as the MCNext disjunct, so the changed
fields are what identify the base action that fired.

Usage: cex_summary.py TRACE_JSON [--full-last]
"""

import json
import sys


def flatten(value, prefix=""):
    if isinstance(value, dict):
        items = value.items()
    elif isinstance(value, list) and not all(not isinstance(v, (dict, list)) for v in value):
        # TLA+ functions over 1..n arrive as lists; show 1-based indices.
        items = ((i + 1, v) for i, v in enumerate(value))
    else:
        yield prefix, value
        return
    for key, child in items:
        yield from flatten(child, f"{prefix}.{key}" if prefix else str(key))


def main() -> None:
    data = json.load(open(sys.argv[1]))
    steps = data["counterexample"]["action"]
    first = steps[0][0][1]
    print("initial state:", json.dumps(first)[:300], "...")
    for source, action, target in steps:
        before = dict(flatten(source[1]))
        after = dict(flatten(target[1]))
        name = action.get("name")
        context = action.get("context", {})
        changes = [
            f"{path}: {json.dumps(before.get(path))} -> {json.dumps(after.get(path))}"
            for path in sorted(set(before) | set(after))
            if before.get(path) != after.get(path)
        ]
        print(f"\n[{source[0]}->{target[0]}] {name} {json.dumps(context) if context else ''}")
        for change in changes:
            print("   ", change)
    if "--full-last" in sys.argv:
        print("\nlast state:")
        for path, value in flatten(steps[-1][2][1]):
            print("   ", path, "=", json.dumps(value))


if __name__ == "__main__":
    main()
