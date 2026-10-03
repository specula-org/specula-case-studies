#!/usr/bin/env python3
"""Run one nvflare-job trace scenario and write traces/<scenario>.ndjson.

Usage: python run_scenario.py <scenario> --out <trace.ndjson> [--root <tmpdir>] [--report <report.json>]

The instrumented nvflare copy must come first on PYTHONPATH (harness/run.sh sets it up); this script refuses to run
against any other nvflare package.
"""

import argparse
import json
import logging
import os
import sys
import tempfile
import threading
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import nvflare  # noqa: E402

EXPECTED = os.environ.get("NVF_INSTRUMENTED_ROOT")
if not EXPECTED or not os.path.realpath(nvflare.__file__).startswith(os.path.realpath(EXPECTED)):
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
    report = {"scenario": a.scenario, "root": root, "nvflare": nvflare.__file__}
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
        # settle: give in-flight deliveries a moment, then stop tracing so late threads cannot write
        env.net.quiesce(timeout=3.0)
        time.sleep(0.3)
        tla_hooks.uninstall()
        report["events"] = tr.count()
        report["harness_errors"] = tr.errors
        report["thread_deaths"] = tr.thread_deaths
        report["runner_exception"] = getattr(env, "runner_result", {}).get("exception")
        names = {}
        for e in tr.events:
            names[e["name"]] = names.get(e["name"], 0) + 1
        report["event_counts"] = names
        tr.close()
        if tr.errors:
            rc = rc or 2
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
