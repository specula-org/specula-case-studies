# Copyright (c) 2026, NVIDIA CORPORATION. All rights reserved.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
"""Audit L2 wiring, current run receipts, trace provenance and applied probe lines."""

import ast
import hashlib
import json
import os
import pathlib
import re
import subprocess

out = pathlib.Path(__file__).resolve().parents[2]
harness = out / "harness"
source = pathlib.Path(os.environ.get("NVFLARE_SOURCE", "/home/ubuntu/nvflare-runs-20260913/source-transfer"))
sha = "53ba7ee567468ea7971dad4faccef13c6cb35dc2"
assert subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip() == sha
mapping = json.loads((out / "spec/action-map.json").read_text())
text = (out / "spec/Trace.tla").read_text()
assert "DOMAIN captured = required" in text
assert "st'[field] = captured[field]" in text and r"\A field \in required" in text
assert not re.search(r"ValidatePostState[^=]*==\s*TRUE", text)
for action in mapping:
    name = action["name"]
    field_match = re.search(r'name = "' + name + r'" -> \{([^}]+)\}', text)
    assert set(re.findall(r'"([^"]+)"', field_match[1])) == set(action["fields"])
    wrapper = text.split("Trace" + name + " ==", 1)[1].split("\n\n", 1)[0]
    assert f'ValidatePostState("{name}")' in wrapper
    assert re.search(r"/\\ " + name + r"(?:\(|\s)", wrapper)
coverage = json.loads((harness / "logs/coverage.json").read_text())
assert not coverage["missing"]
validation = {x["name"]: x for x in json.loads((harness / "logs/validation-results.json").read_text())}
for trace in coverage["traces"]:
    name = pathlib.Path(trace["raw"]).stem
    verdict = validation[name]
    assert verdict["passed"] and verdict["complete_cursor"]
    for mode in ("raw", "normalized"):
        actual = hashlib.sha256(pathlib.Path(trace[mode]).read_bytes()).hexdigest()
        assert actual == trace[f"{mode}_sha256"] == verdict[f"{mode}_sha256"]
assert all(x["exit_code"] == 0 for x in json.loads((harness / "logs/test-results.json").read_text()))
assert "11 passed" in (harness / "logs/profiles.log").read_text()
assert all(x["rejected"] for x in json.loads((harness / "logs/negative-controls.json").read_text()))
# Preserve exact after-apply lines for every physical source hook; the recorder
# itself supplies callback-pool queue, custom release and minimal caller hooks.
points = []
for file in [
    source / "nvflare/fuel/f3/streaming/download_service.py",
    source / "nvflare/client/cell/api.py",
    harness / "src/specula_trace.py",
    harness / "src/test_transfer_traces.py",
]:
    for node in ast.walk(ast.parse(file.read_text())):
        if (
            isinstance(node, ast.Call)
            and isinstance(node.func, ast.Attribute)
            and node.func.attr in ("point", "value", "emit")
        ):
            if node.args and isinstance(node.args[0], ast.Constant) and isinstance(node.args[0].value, str):
                points.append(dict(file=str(file), line=node.lineno, call=node.func.attr, name=node.args[0].value))
(harness / "logs/instrumentation-points.json").write_text(json.dumps(points, indent=2) + "\n")
lines = [
    "# Physical instrumentation points after apply",
    "",
    "Source pins and original semantic ranges remain in `spec/action-map.json`. These are current physical hook lines.",
    "",
    "| Hook or event | File | Line |",
    "|---|---|---|",
]
for p in points:
    label = pathlib.Path(p["file"]).name
    lines.append(f"| `{p['name']}` | `{label}` | {p['line']} |")
(harness / "POINTS.md").write_text("\n".join(lines) + "\n")
files = [
    *sorted((harness / "src").glob("*.py")),
    harness / "apply.sh",
    harness / "run.sh",
    harness / "patches/instrumentation.patch",
    *[out / "spec" / n for n in ("base.tla", "Trace.tla", "Trace.cfg", "action-map.json")],
    source / "nvflare/fuel/f3/streaming/download_service.py",
    source / "nvflare/fuel/f3/streaming/specula_trace.py",
    source / "nvflare/client/cell/api.py",
]
report = dict(
    source_sha=sha,
    state_validation="exact required domain and every captured field checked by original ValidatePostState",
    trace_count=len(coverage["traces"]),
    event_count=sum(t["events"] for t in coverage["traces"]),
    events_covered=len(coverage["covered"]),
    model_actions=len(mapping),
    validation="all complete cursor + original invariants + TraceMatched",
    upstream_and_caller_profile_tests=11,
    negative_controls=3,
    sha256={str(f): hashlib.sha256(f.read_bytes()).hexdigest() for f in files},
)
(harness / "logs/audit.json").write_text(json.dumps(report, indent=2) + "\n")
print(
    f"Audit passed: {report['trace_count']} traces, {report['event_count']} events, {report['events_covered']}/{len(mapping)} actions"
)
