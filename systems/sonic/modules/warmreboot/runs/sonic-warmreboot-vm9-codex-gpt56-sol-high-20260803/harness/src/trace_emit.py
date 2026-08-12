#!/usr/bin/env python3
"""CLI adapter used by instrumented shell scripts."""

import argparse
import json
from typing import Any

from specula_trace import emit


def parse_value(value: str) -> Any:
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("name")
    parser.add_argument("source")
    parser.add_argument("--asic")
    parser.add_argument("--component")
    parser.add_argument("fields", nargs="*")
    args = parser.parse_intermixed_args()

    observed = {}
    for field in args.fields:
        if "=" not in field:
            parser.error(f"observed field must be key=value: {field}")
        key, value = field.split("=", 1)
        observed[key] = parse_value(value)

    emit(
        args.name,
        args.source,
        observed,
        asic=args.asic,
        component=args.component,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
