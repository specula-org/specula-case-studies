#!/usr/bin/env python3
"""Copy terminal registered TLC receipts and summarize literal coverage facts.

Call only after wait_tlc reports completed jobs; this is not a polling loop.
"""
import argparse
import hashlib
import json
import re
import shutil
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("campaign", type=Path)
parser.add_argument("task_ids", nargs="+")
args = parser.parse_args()
campaign = args.campaign.resolve()
manifest = json.loads((campaign / "campaign.json").read_text())
by_id = {job["task_id"]: job for job in manifest["jobs"]}
for task_id in args.task_ids:
    job = by_id[task_id]
    native = Path(job["result_path"]).parent
    assert (native / "result.json").exists(), "Only collect terminal jobs returned by wait_tlc"
    result = json.loads((native / "result.json").read_text())
    destination = campaign / "tasks" / task_id
    destination.mkdir(parents=True, exist_ok=True)
    for name in ["request.json", "result.json", "stop.json", "worker.json", "worker.log", "launcher.log", "tlc.log"]:
        source = native / name
        if source.exists():
            shutil.copy2(source, destination / name)
    raw = (destination / "tlc.log").read_text() if (destination / "tlc.log").exists() else ""
    request = json.loads((destination / "request.json").read_text())
    job.update(result)
    job["retained_evidence"] = str(destination.relative_to(campaign))
    job["log_sha256"] = hashlib.sha256(raw.encode()).hexdigest()
    job["errors"] = re.findall(r"^Error:.*$", raw, re.M)
    job["runtime_errors"] = re.findall(r"^.*(?:OutOfMemoryError|GC overhead limit|Exception in thread|Semantic errors|Parse Error).*$", raw, re.M)
    job["violations"] = re.findall(r"Invariant (\w+) is violated", raw)
    job["exhaustive_completion_reported"] = "Model checking completed. No error has been found." in raw
    job["elapsed_seconds"] = result.get("finished_at", request["created_at"]) - request["created_at"]
    job["coverage_kind"] = "last periodic sample"
    if job["mode"] == "bfs":
        samples = re.findall(r"Progress\((\d+)\) at ([^:]+:\d+:\d+): ([\d,]+) states generated.*?, ([\d,]+) distinct states found.*?, ([\d,]+) states left on queue\.", raw)
        totals = re.findall(r"([\d,]+) states generated, ([\d,]+) distinct states found, ([\d,]+) states left on queue\.", raw)
        depth = re.findall(r"The depth of the complete state graph search is (\d+)", raw)
        if samples:
            d, at, generated, distinct, queued = samples[-1]
            job["coverage"] = {"depth": int(d), "reported_at": at, "generated": int(generated.replace(",", "")), "distinct": int(distinct.replace(",", "")), "queued": int(queued.replace(",", ""))}
        if totals:
            generated, distinct, queued = totals[-1]
            job["coverage_kind"] = "terminal TLC counters"
            job.setdefault("coverage", {}).update(generated=int(generated.replace(",", "")), distinct=int(distinct.replace(",", "")), queued=int(queued.replace(",", "")))
        if depth:
            job.setdefault("coverage", {})["depth"] = int(depth[-1])
    else:
        samples = re.findall(r"Progress: (\d+) states checked, (\d+) traces generated ([^\n]+)", raw)
        if samples:
            checked, traces, lengths = samples[-1]
            job["coverage"] = {"states_checked": int(checked), "traces_generated": int(traces), "raw_length_statistics": lengths, "configured_depth_cap": 100}
        seed = re.search(r"Running Random Simulation with seed (-?\d+)", raw)
        if seed:
            job["seed"] = int(seed.group(1))
    job["budget_end_reported"] = job["exit_code"] == 124 and "Timed out" in (destination / "launcher.log").read_text()
    options = request["options"]
    if "-j" in options:
        counterexample = Path(request["work_dir"]) / options[options.index("-j") + 1]
        job["counterexample"] = str(counterexample) if counterexample.exists() else None
        if counterexample.exists():
            job["counterexample_sha256"] = hashlib.sha256(counterexample.read_bytes()).hexdigest()
    print(json.dumps({k:job[k] for k in ["config", "mode", "task_id", "status", "exit_code", "elapsed_seconds", "errors", "coverage_kind"]} | {"coverage": job.get("coverage"), "exhaustive_completion_reported":job["exhaustive_completion_reported"]}))
(campaign / "campaign.json").write_text(json.dumps(manifest, indent=2) + "\n")
