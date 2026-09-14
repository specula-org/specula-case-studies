# Copyright (c) 2026, NVIDIA CORPORATION. All rights reserved.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
"""Run original Trace.cfg through experiment-local budgeted TLC task API."""

import asyncio
import hashlib
import json
import os
import pathlib
import re
import sys

out = pathlib.Path(__file__).resolve().parents[2]
root = next(p for p in out.parents if (p / "src/specula/tlc_tasks.py").exists())
sys.path.insert(0, str(root / "src"))
os.environ.setdefault("SPECULA_WORK_DIR", str(out))
os.environ.setdefault("SPECULA_ROOT", str(root))
os.environ.setdefault("SPECULA_TLC_TOOL_OWNER", str(out / "harness/logs/validate.log"))
from specula.tlc_tasks import start_tlc, wait_tlc


async def main():
    results = []
    traces = json.loads((out / "harness/logs/coverage.json").read_text())["traces"]
    for item in traces:
        name = pathlib.Path(item["raw"]).stem
        if len(sys.argv) > 1 and name not in sys.argv[1:]:
            continue
        task = await start_tlc(
            str(out / "harness/validation" / name / "spec"),
            "Trace.tla",
            "Trace.cfg",
            ["-m", "2G", "-M", "1G", "-w", "1", "-t", "2"],
        )
        while True:
            finished = await wait_tlc([task["task_id"]], timeout_seconds=30, mode="all")
            if finished["outcome"] == "finished":
                break
            print("TLC still checking", name, flush=True)
        result = finished["tasks"][0]
        log = pathlib.Path(result["log_path"]).read_text()
        counts = re.findall(r"(\d+) states generated, (\d+) distinct states found, (\d+) states left on queue", log)
        consumed = bool(counts) and int(counts[-1][1]) == item["events"] + 1
        passed = result["exit_code"] == 0 and "Model checking completed. No error has been found." in log and consumed
        row = dict(
            name=name,
            passed=passed,
            trace_events=item["events"],
            complete_cursor=consumed,
            raw_sha256=item["raw_sha256"],
            normalized_sha256=item["normalized_sha256"],
            **result,
        )
        results.append(row)
        print(name, "PASS" if passed else "FAIL", result["task_id"], flush=True)
        (out / "harness/logs/validation-results.json").write_text(json.dumps(results, indent=2) + "\n")
    return 0 if results and all(x["passed"] for x in results) else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
