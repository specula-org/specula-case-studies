# Copyright (c) 2026, NVIDIA CORPORATION.  All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""Audit the frozen continuation suite. Does not run TLC or product code."""

import ast
import collections
import hashlib
import json
import os
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from trace_contract import known_events, validate_trace


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads(path.read_text())


def run(command, cwd=None):
    p = subprocess.run(command, cwd=cwd, text=True, capture_output=True, timeout=30, check=False)
    return {"command": command, "exit_code": p.returncode, "stdout": p.stdout, "stderr": p.stderr}


def main():
    harness = Path(__file__).resolve().parents[1]
    out = harness.parent
    source = Path(os.environ["NVF_SOURCE"])
    root = Path(os.environ.get("NVF_CONTINUATION_ROOT", source.parent))
    evidence = harness / "evidence/continuation"
    frozen = evidence / "fresh-suite"
    replay = {Path(r["trace"]).stem: r for r in read(evidence / "suite-replay.json")}
    counts = collections.Counter()
    rows = []
    projection_checks = 0
    resource_calls = collections.Counter()
    for trace in sorted((frozen / "traces").glob("*.ndjson")):
        report_path = frozen / "reports" / (trace.stem + ".json")
        report = read(report_path)
        integrity = validate_trace(trace, out / "spec", report_path)
        assert (frozen / "reports" / (trace.stem + ".exitcode")).read_text().strip() == "0"
        assert not report["assertion_errors"]
        assert not report["resource_observation"]["mismatches"]
        projection_checks += report["resource_observation"]["checks"]
        resource_calls.update(call["operation"] for call in report["resource_observation"]["calls"])
        counts.update(integrity["event_counts"])
        r = replay[trace.stem]
        assert r["result"] == "PASS" and r["outcome"]["exit_code"] == 0
        assert r["integrity"]["sha256"] == integrity["sha256"]
        log = Path(r["outcome"]["log_path"])
        assert "Model checking completed. No error has been found" in log.read_text()
        assert "Error:" not in log.read_text()
        for name, sha in r["spec_sha256"].items():
            assert digest(out / "spec" / name) == sha, name
        rows.append({"scenario": trace.stem, "events": integrity["events"],
                     "trace": str(trace), "trace_sha256": integrity["sha256"],
                     "report": str(report_path), "report_sha256": digest(report_path),
                     "started_utc": datetime.fromtimestamp(report["started_ns"] / 1e9, timezone.utc).isoformat(),
                     "finished_utc": datetime.fromtimestamp(report["finished_ns"] / 1e9, timezone.utc).isoformat(),
                     "expected_runner_exception": report["expected_runner_exception"],
                     "projection_checks": report["resource_observation"]["checks"],
                     "task_id": r["outcome"]["task_id"], "tlc_log": str(log), "tlc_log_sha256": digest(log),
                     "statistics": r["statistics"]})
    assert len(rows) == len(replay) == 32
    actions = known_events(out / "spec")
    assert actions - counts.keys() == {"CpStartAllocateAppMissing"}

    unit = read(evidence / "unit-tests/results.json")
    assert unit["all_passed"] and unit["identical_outcomes"]
    unit_counts = {r["mode"]: len(r["outcomes"]) for r in unit["runs"]}
    assert set(unit_counts.values()) == {392}
    negative = read(evidence / "negative-controls/results.json")
    assertions = read(evidence / "scenario-assertions.json")
    assert negative["checks_passed"] and assertions["checks_passed"]

    spec_before = read(evidence / "spec-before.json")
    assert all(digest(out / name) == sha for name, sha in spec_before.items())
    original = root / "handoff/full/run/nvflare-job/.specula-output"
    manifest = read(root / "handoff/asset-manifest.json")
    mismatches = [r["path"] for r in manifest if not (original / r["path"]).is_file()
                  or (original / r["path"]).stat().st_size != r["bytes"]
                  or digest(original / r["path"]) != r["sha256"]]
    assert not mismatches, mismatches
    index = read(root / "handoff/conversations/index.json")
    assert all(digest(root / "handoff" / r["raw"]) == r["sha256"] for r in index)
    assert digest(harness / "patches/instrumentation.patch") == digest(original / "harness/patches/instrumentation.patch")
    runtime = read(frozen / "runtime/index.json")
    assert all(digest(Path(r["path"])) == r["sha256"] for r in runtime)
    for row in rows:
        report = read(Path(row["report"]))
        for version in runtime:
            if row["scenario"] in version["scenarios"]:
                assert report["harness_sha256"]["src/" + version["name"]] == version["sha256"]

    head = run(["git", "rev-parse", "HEAD"], source)
    status = run(["git", "status", "--short"], source)
    assert head["stdout"].strip() == "53ba7ee567468ea7971dad4faccef13c6cb35dc2"
    assert status["stdout"] == "?? .agents/\n", status
    pyfiles = sorted((harness / "src").glob("*.py"))
    for path in pyfiles:
        ast.parse(path.read_bytes(), filename=str(path))
    shell = [run(["bash", "-n", str(p)]) for p in sorted(harness.glob("*.sh"))]
    assert all(r["exit_code"] == 0 for r in shell)
    patch_paths = re.findall(r"^\+\+\+ b/(.*)$", (harness / "patches/instrumentation.patch").read_text(), re.M)
    build = harness / "build/nvflare_src"
    for name in patch_paths:
        ast.parse((build / name).read_bytes(), filename=name)
        assert (build / name).read_bytes() == (original / "harness/build/nvflare_src" / name).read_bytes()
    result = {
        "phase": "2.5", "kind": "Fresh harness evidence; no convergence/confirmation verdict",
        "checked_utc": datetime.now(timezone.utc).isoformat(), "checks_passed": True,
        "traces": len(rows), "events": sum(counts.values()), "event_types": len(counts),
        "trace_event_types": len(actions), "uncovered_events": sorted(actions - counts.keys()),
        "event_counts": dict(sorted(counts.items())), "scenarios": rows,
        "allocation_projection_checks": projection_checks, "projection_mismatches": 0,
        "observed_resource_calls": dict(resource_calls), "unit_test_outcomes": unit_counts,
        "scenario_assertions": len(assertions["checks"]), "negative_control_checks": len(negative["controls"]),
        "source_head": head, "source_status": status,
        "original_assets_hash_checked": len(manifest), "raw_conversations_hash_checked": len(index),
        "spec_files_unchanged": len(spec_before), "patched_files_match_supplied_patch": len(patch_paths),
        "runtime_versions": runtime, "python_syntax_checked": [str(p) for p in pyfiles], "shell_syntax": shell,
        "style_check": "See style-check.log; unavailable black dependency, no full style PASS claimed.",
        "limits": "See INSTRUMENTATION.md and adoption/model-audit.md V01-V10. Finite, scheduled traces with stubs."
    }
    (evidence / "final-audit.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: result[k] for k in ("checks_passed", "traces", "events", "event_types",
                     "trace_event_types", "allocation_projection_checks", "observed_resource_calls",
                     "unit_test_outcomes", "original_assets_hash_checked", "raw_conversations_hash_checked",
                     "spec_files_unchanged")}, indent=2))


if __name__ == "__main__":
    main()
