#!/usr/bin/env python3
"""Invoke the installed run_trace_validation handler with budgeted TLC launch.

The MCP trace tools are not exposed in this phase, so use their local handler.
Only its launcher is adapted to the experiment's required resource wrapper.
"""
import asyncio
import hashlib
import json
import os
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parents[1]
ROOT = Path("/home/ubuntu/nvflare-runs-20260913/specula")
sys.path.insert(0, str(ROOT / "tools/trace_debugger/src"))
from tla_mcp.handlers.trace_validation import TraceValidationHandler


class BudgetedValidation(TraceValidationHandler):
    def _build_command(self, args, tla_jar, community_jar):
        return [
            "timeout",
            "120",
            "bash",
            str(ROOT / "scripts/tlc/run_model_check.sh"),
            "-s",
            args["spec_file"],
            "-c",
            args["config_file"],
            "-m",
            "1G",
            "-M",
            "1G",
            "-w",
            "1",
            "-t",
            "1",
            "-D",
            "-o",
            args["log_file"],
        ]


async def main():
    os.environ["SPECULA_ROOT"] = str(ROOT)
    os.environ["TMPDIR"] = "/home/ubuntu/nvflare-runs-20260913/scratch/fedavg/harness-tmp"
    os.environ["TLC_STATE_DIR"] = "/home/ubuntu/nvflare-runs-20260913/scratch/fedavg/tlc"
    os.environ["SPECULA_TLC_MEMORY_LIMIT"] = "128G"
    os.environ["SPECULA_TLC_WORKER_LIMIT"] = "40"
    traces = (
        [HERE.parent / "traces" / f"{name}.ndjson" for name in sys.argv[1:]]
        if len(sys.argv) > 1
        else sorted((HERE.parent / "traces").glob("*.ndjson"))
    )
    results = []
    for trace in traces:
        log = HERE / "reports" / f"{trace.stem}.tlc.log"
        args = dict(
            spec_file="Trace.tla",
            config_file="Trace.cfg",
            trace_file=str(trace),
            work_dir=str(HERE.parent / "spec"),
            timeout=130,
            log_file=str(log),
        )
        result = await BudgetedValidation().execute(args)
        result["trace"] = trace.name
        result["traceSha256"] = hashlib.sha256(trace.read_bytes()).hexdigest()
        result["specHashes"] = {
            name: hashlib.sha256((HERE.parent / "spec" / name).read_bytes()).hexdigest()
            for name in ["base.tla", "Trace.tla", "Trace.cfg"]
        }
        result["resourceBudget"] = dict(heap="1G", offheap="1G", workers=1, timeoutSeconds=120)
        (HERE / "reports" / f"{trace.stem}.validation.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps({k: v for k, v in result.items() if k not in ["raw_output", "specHashes"]}), flush=True)
        results.append(result)
    (HERE / "reports/validation-summary.json").write_text(json.dumps(results, indent=2) + "\n")
    return int(any(r["status"] != "success" for r in results))


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
