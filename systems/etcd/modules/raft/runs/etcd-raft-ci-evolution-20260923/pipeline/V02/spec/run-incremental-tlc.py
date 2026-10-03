#!/usr/bin/env python3
"""Run one registered, budgeted TLC campaign with all state kept in this run."""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
from pathlib import Path


SPEC = Path(__file__).resolve().parent
WORK = SPEC.parent
RUN = SPEC.parents[2]
PINNED = Path(
    "/home/ubuntu/specula-etcd-ci-init-20260912.FNeLj3NS/Specula-ci-20260915"
)
OUTPUT = SPEC / "output" / "incremental-20260915"
TASK_TMP = RUN / "tmp" / "incremental-modeling"
STATE_ROOT = RUN / "tlc-states" / "incremental-modeling"
RESOURCE_ROOT = RUN / "tmp" / "tlc-resource-state"


def configure_environment() -> None:
    for path in (OUTPUT, TASK_TMP, STATE_ROOT, RESOURCE_ROOT):
        path.mkdir(parents=True, exist_ok=True)
    os.environ.update(
        {
            "SPECULA_ROOT": str(PINNED),
            "SPECULA_WORK_DIR": str(WORK),
            "SPECULA_RUN_DIR": str(RUN),
            "SPECULA_TLC_SCOPE": str(RUN),
            "SPECULA_TLC_MEMORY_LIMIT": "200G",
            "SPECULA_TLC_WORKER_LIMIT": "60",
            "SPECULA_TLC_RESOURCE_DIR": str(RESOURCE_ROOT),
            "TMPDIR": str(TASK_TMP),
            "TLC_STATE_DIR": str(STATE_ROOT),
            "JAVA_TOOL_OPTIONS": f"-Djava.io.tmpdir={TASK_TMP}",
        }
    )
    sys.path.insert(0, str(PINNED / "src"))


async def run(args: argparse.Namespace) -> None:
    from specula.tlc_tasks import start_tlc, wait_tlc

    if args.json_trace:
        os.environ["JSON"] = str(Path(args.json_trace).resolve())
    options = [
        "-m",
        args.heap,
        "-M",
        args.offheap,
        "-w",
        str(args.workers),
        "-t",
        str(args.minutes),
    ]
    if args.depth:
        options += ["-d", str(args.depth)]
    if args.simulate:
        options += ["-S", "-n", "999999999", "-p", str(args.simulation_depth)]
    receipt = await start_tlc(str(SPEC), args.module, args.config, options)
    (OUTPUT / f"{args.label}.receipt.json").write_text(
        json.dumps(receipt, indent=2) + "\n"
    )
    print(json.dumps({"label": args.label, "receipt": receipt}), flush=True)
    if args.start_only:
        return
    while True:
        result = await wait_tlc([receipt["task_id"]], timeout_seconds=55, mode="all")
        if result["outcome"] == "finished":
            break
    (OUTPUT / f"{args.label}.result.json").write_text(
        json.dumps(result, indent=2) + "\n"
    )
    print(json.dumps({"label": args.label, "result": result}), flush=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", required=True)
    parser.add_argument("--module", required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--heap", default="50G")
    parser.add_argument("--offheap", default="50G")
    parser.add_argument("--workers", type=int, default=20)
    parser.add_argument("--minutes", type=int, default=30)
    parser.add_argument("--depth", type=int, default=0)
    parser.add_argument("--simulate", action="store_true")
    parser.add_argument("--simulation-depth", type=int, default=100)
    parser.add_argument("--start-only", action="store_true")
    parser.add_argument("--json-trace")
    return parser.parse_args()


if __name__ == "__main__":
    configure_environment()
    asyncio.run(run(parse_args()))
