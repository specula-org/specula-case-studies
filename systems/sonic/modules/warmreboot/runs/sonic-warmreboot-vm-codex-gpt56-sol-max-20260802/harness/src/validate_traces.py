#!/usr/bin/env python3
"""Run a quick TLC replay for every trace without requiring the MCP server."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import tempfile
from pathlib import Path

from verify_traces import TRACE_NAMES


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--spec-dir", required=True, type=Path)
    parser.add_argument("--trace-dir", required=True, type=Path)
    parser.add_argument("--specula-root", required=True, type=Path)
    args = parser.parse_args()

    classpath = os.pathsep.join(
        [
            str(args.specula_root / "lib/tla2tools.jar"),
            str(args.specula_root / "lib/CommunityModules-deps.jar"),
        ]
    )
    for entry in classpath.split(os.pathsep):
        if not Path(entry).is_file():
            raise SystemExit(f"missing TLA+ runtime: {entry}")

    for trace_name in TRACE_NAMES:
        trace = (args.trace_dir / trace_name).resolve()
        env = os.environ.copy()
        env["JSON"] = str(trace)
        with tempfile.TemporaryDirectory(prefix="tlc-warmreboot-") as metadir:
            command = [
                "java",
                "-XX:+UseParallelGC",
                "-Xmx2G",
                "-cp",
                classpath,
                "tlc2.TLC",
                "-config",
                "Trace.cfg",
                "Trace.tla",
                "-lncheck",
                "final",
                "-metadir",
                metadir,
                "-fpmem",
                "0.9",
            ]
            result = subprocess.run(
                command,
                cwd=args.spec_dir,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=120,
                check=False,
            )
        if result.returncode != 0 or "Model checking completed. No error has been found." not in result.stdout:
            print(result.stdout)
            raise SystemExit(f"TLC trace validation failed: {trace_name}")
        states = re.search(r"([0-9]+) states generated", result.stdout)
        print(f"TLC PASS: {trace_name} ({states.group(1) if states else '?'} states generated)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
