#!/usr/bin/env python3
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
"""Run one nvflare-job trace scenario and write traces/<scenario>.ndjson.

Usage: python run_scenario.py <scenario> --out <trace.ndjson> [--root <tmpdir>] [--report <report.json>]

The instrumented nvflare copy must come first on PYTHONPATH (harness/run.sh sets it up); this script refuses to run
against any other nvflare package.
"""

import argparse
import hashlib
import json
import logging
import os
import sys
import tempfile
import threading
import time
import traceback
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import nvflare  # noqa: E402

EXPECTED = os.environ.get("NVF_INSTRUMENTED_ROOT")
if not EXPECTED or not Path(nvflare.__file__).resolve().is_relative_to(Path(EXPECTED).resolve()):
    sys.exit(f"refusing to run: nvflare imported from {nvflare.__file__}, expected the instrumented copy under {EXPECTED}")

from nvflare.fuel.utils import tla_hooks  # noqa: E402

import nvf_scenarios  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("scenario")
    ap.add_argument("--out", required=True)
    ap.add_argument("--root", default=None)
    ap.add_argument("--report", default=None)
    ap.add_argument("--verbose", action="store_true")
    a = ap.parse_args()
    logging.basicConfig(
        level=logging.INFO if a.verbose else logging.WARNING,
        format="%(asctime)s %(threadName)s %(name)s %(levelname)s %(message)s",
    )
    root = os.path.abspath(a.root) if a.root else tempfile.mkdtemp(prefix=f"nvf-{a.scenario}-")
    a.out = os.path.abspath(a.out)
    fn = nvf_scenarios.SCENARIOS.get(a.scenario)
    if fn is None:
        sys.exit(f"unknown scenario {a.scenario}; known: {sorted(nvf_scenarios.SCENARIOS)}")
    harness = Path(HERE).parent
    source_files = [*Path(HERE).glob("*.py"), *harness.glob("*.sh"), harness / "patches/instrumentation.patch"]
    report = {"scenario": a.scenario, "root": root, "nvflare": nvflare.__file__,
              "python": sys.executable, "python_version": sys.version, "command": [sys.executable, *sys.argv],
              "started_ns": time.time_ns(),
              "build_provenance": (harness / "build/PROVENANCE").read_text(),
              "harness_sha256": {str(p.relative_to(harness)): hashlib.sha256(p.read_bytes()).hexdigest()
                                 for p in sorted(source_files)}}
    t0 = time.time()
    env = None
    rc = 0
    try:
        env = fn(root, a.out)
        report["result"] = "ok"
    except Exception as e:
        rc = 1
        report["result"] = f"FAILED: {type(e).__name__}: {e}"
        report["traceback"] = traceback.format_exc()
        sys.stderr.write(report["traceback"])
        env = getattr(e, "env", None) or nvf_scenarios.LAST_ENV.get("env")
    report["seconds"] = round(time.time() - t0, 2)
    if env is not None:
        tr = env.tracer
        # Stop admissions through the real stop flag, settle deliveries, then freeze the writer.
        # Sleeping product threads/fake crash waiters are ended by the process boundary below.
        env.runner.stop()
        report["network_quiesced"] = env.net.quiesce(timeout=15.0)
        tla_hooks.uninstall()
        tr.close()
        report["events"] = tr.count()
        report["harness_errors"] = tr.errors
        report["thread_deaths"] = tr.thread_deaths
        report["runner_exception"] = getattr(env, "runner_result", {}).get("exception")
        expected = {"delete_held_job_kills_runner": "AttributeError:",
                    "delete_during_scan": "StorageException:"}.get(a.scenario)
        report["expected_runner_exception"] = expected
        errors = []
        observed = report["runner_exception"]
        if expected:
            if not observed or not observed.startswith(expected) or env.runner_thread.is_alive():
                errors.append(f"expected completed runner failure {expected}, got {observed!r}")
        elif observed:
            errors.append(f"unexpected runner failure: {observed}")
        if tr.thread_deaths:
            errors.append(f"unexpected thread deaths: {tr.thread_deaths}")
        if not report["network_quiesced"]:
            errors.append("network handlers did not settle")
        report["assertion_errors"] = errors
        if errors:
            rc = rc or 2
        report["resource_observation"] = {"checks": env.resource_observer.checks,
                                        "mismatches": env.resource_observer.mismatches,
                                        "calls": env.resource_observer.calls}
        report["scenario_config"] = env.cfg
        report["network_observation"] = env.net.audit
        report["final_status"] = {env.jname(j): (env.read_meta(j) or {}).get("status", "DELETED")
                                  for j in env.job_ids}
        report["traced_prefix_end"] = "after scenario assertions and network drain; not global shutdown"
        names = {}
        for e in tr.events:
            names[e["name"]] = names.get(e["name"], 0) + 1
        report["event_counts"] = names
        if tr.errors:
            rc = rc or 2
    if Path(a.out).is_file():
        report["trace_sha256"] = hashlib.sha256(Path(a.out).read_bytes()).hexdigest()
    report["finished_ns"] = time.time_ns()
    report["exit_code"] = rc
    if rc and report["result"] == "ok":
        report["result"] = "FAILED: harness/result assertions (see report)"
    text = json.dumps(report, indent=2, default=str)
    print(text)
    if a.report:
        with open(a.report, "w") as f:
            f.write(text + "\n")
    sys.stdout.flush()
    sys.stderr.flush()
    # product threads (runner, completion, expiry, waiters) are non-daemon and never stop by themselves
    os._exit(rc)


if __name__ == "__main__":
    main()
