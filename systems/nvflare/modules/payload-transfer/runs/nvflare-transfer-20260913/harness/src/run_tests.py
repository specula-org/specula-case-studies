# Copyright (c) 2026, NVIDIA CORPORATION. All rights reserved.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
"""Each scenario gets a fresh process (Cell and StatsPoolManager are global)."""

import ast
import json
import os
import pathlib
import subprocess
import sys
import time

harness = pathlib.Path(__file__).resolve().parents[1]
source = os.environ.get("NVFLARE_SOURCE", "/home/ubuntu/nvflare-runs-20260913/source-transfer")
test = harness / "src/test_transfer_traces.py"
names = [
    n.name for n in ast.parse(test.read_text()).body if isinstance(n, ast.FunctionDef) and n.name.startswith("test_")
]
if len(sys.argv) > 1:
    names = sys.argv[1:]
results = []
for name in names:
    log = harness / "logs" / f'{name.removeprefix("test_")}.log'
    start = time.monotonic()
    with log.open("w") as f:
        result = subprocess.run(
            ["timeout", "120", sys.executable, "-m", "pytest", f"{test}::{name}", "-q", "--tb=short"],
            cwd=source,
            stdout=f,
            stderr=subprocess.STDOUT,
        )
    results.append(
        dict(test=name, exit_code=result.returncode, seconds=round(time.monotonic() - start, 3), log=str(log))
    )
    print(name, "PASS" if result.returncode == 0 else f"FAIL ({result.returncode})", flush=True)
    if result.returncode == 124:
        print("Outer timeout fired. Preserve evidence; do not automatically retry.", flush=True)
        break
(harness / "logs/test-results.json").write_text(json.dumps(results, indent=2) + "\n")
sys.exit(1 if any(r["exit_code"] for r in results) else 0)
