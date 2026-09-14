# Copyright (c) 2026, NVIDIA CORPORATION. All rights reserved.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
"""Mutate copies of an actual trace to test L2 and cursor rejection.

These are validator controls under harness/, never collected runtime traces.
"""

import asyncio
import copy
import hashlib
import json
import pathlib
import re
import sys

from validate import out, start_tlc, wait_tlc


async def main():
    path = out / "traces/normalized/confirmed_success.ndjson"
    original = [json.loads(x) for x in path.read_text().splitlines()]
    reports = []
    for kind in ("wrong_post", "missing_post", "unknown_event"):
        rows = copy.deepcopy(original)
        first = rows[1]
        assert first["event"] == "DownloadObjectStart"
        if kind == "wrong_post":
            values = first["post"]["futureStarted"]["entries"]
            next(e for e in values if e["key"] == first["args"]["p"])["value"] = False
        elif kind == "missing_post":
            del first["post"]["futureStarted"]
        else:
            first["event"] = "UnknownSourceEvent"
        base = out / "harness/controls" / kind
        work = base / "spec"
        work.mkdir(parents=True, exist_ok=True)
        for name in ("base.tla", "Trace.tla", "Trace.cfg"):
            link = work / name
            if not link.exists():
                link.symlink_to(out / "spec" / name)
        target = base / "traces/trace.ndjson"
        target.parent.mkdir(exist_ok=True)
        target.write_text("".join(json.dumps(x, separators=(",", ":")) + "\n" for x in rows))
        task = await start_tlc(str(work), "Trace.tla", "Trace.cfg", ["-m", "2G", "-M", "1G", "-w", "1", "-t", "2"])
        finished = await wait_tlc([task["task_id"]], timeout_seconds=30, mode="all")
        while finished["outcome"] != "finished":
            print("Waiting for control", kind, flush=True)
            finished = await wait_tlc([task["task_id"]], timeout_seconds=30, mode="all")
        result = finished["tasks"][0]
        log = pathlib.Path(result["log_path"]).read_text()
        rejected = result["exit_code"] != 0 and "Temporal properties were violated" in log
        assert rejected, (kind, result)
        reports.append(
            dict(
                control=kind,
                expected_rejection=True,
                rejected=rejected,
                original_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                **result,
            )
        )
        print(kind, "REJECTED as expected", flush=True)
    (out / "harness/logs/negative-controls.json").write_text(json.dumps(reports, indent=2) + "\n")


if __name__ == "__main__":
    asyncio.run(main())
