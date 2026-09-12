#!/usr/bin/env python3
import collections
import copy
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

harness = Path(__file__).resolve().parent
traces = Path(sys.argv[1]).resolve()
logs = Path(os.environ.get("SPECULA_VERIFY_LOGS", str(harness / "logs")))
logs.mkdir(parents=True, exist_ok=True)
validation = harness.parent / "spec"
jar = os.environ.get("TLC_JAR", "/home/ubuntu/Specula-incremental-etcd-20260814/tools/tla2tools.jar")
community = os.environ.get("COMMUNITY_JAR", "/home/ubuntu/Specula-incremental-etcd-20260814/tools/CommunityModules-deps.jar")
keys = json.loads((harness / "post-keys.json").read_text())
coverage = collections.Counter()
results = []
files = sorted(traces.glob("*.ndjson"))
if not files:
    raise SystemExit("No implementation traces.")
assert 'DecodeGroup(e.post,k) = ModelGroup(k)\'' in (validation / "Trace.tla").read_text()
assert "PROPERTIES TraceMatched" in (validation / "Trace.cfg").read_text()
def validate(path, name, negative=False):
    out = logs / ("trace-" + name + ".log")
    env = dict(os.environ, JSON=str(path.resolve()))
    module = "TraceValidator" if path.stem.startswith("validator-") else "Trace"
    with out.open("w") as stream:
        run = subprocess.run(
            ["timeout", "120", "java", "-XX:+UseParallelGC", "-Xmx2g", "-cp", jar + ":" + community,
             "tlc2.TLC", "-workers", "1", "-config", module + ".cfg", module],
            cwd=validation, env=env, stdout=stream, stderr=subprocess.STDOUT)
    text = out.read_text()
    counts = re.findall(r"([\d,]+) states generated, ([\d,]+) distinct states found, ([\d,]+) states left on queue", text)
    passed = (run.returncode == 0 and "Model checking completed. No error" in text
              and bool(counts) and int(counts[-1][1].replace(",", "")) > 0
              and int(counts[-1][2].replace(",", "")) == 0)
    expected_bootstrap = name.startswith("bad-bootstrap-")
    rejected = (run.returncode != 0 and
                (("Invalid trace bootstrap provenance or configuration" in text or "Trace bootstrap does not match implementation Init" in text)
                 if expected_bootstrap else "Temporal property TraceMatched was violated" in text))
    result = {"name": name, "exit_code": run.returncode, "status": "PASS" if passed else ("REJECTED" if rejected else "FAIL"),
              "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "log": os.path.relpath(out, harness)}
    if counts:
        result.update(dict(zip(("generated", "distinct", "queued"), map(lambda x: int(x.replace(",", "")), counts[-1]))))
    results.append(result)
    if not (rejected if negative else passed):
        raise RuntimeError(f"{name}: validation failed; see {out}")
for path in files:
    events = []
    previous = None
    for i, line in enumerate(path.read_text().splitlines()):
        outer = json.loads(line)
        assert set(outer) == {"tag", "ts", "record"} and outer["tag"] == "trace", path
        ts = datetime.datetime.fromisoformat(outer["ts"].replace("Z", "+00:00"))
        assert ts.year >= 2026 and (previous is None or ts >= previous), (path, i)
        previous = ts
        e = outer["record"]
        assert e["seq"] == i and e["tag"] == "temporal-matching", (path, i)
        if i == 0:
            assert e["event"] == "bootstrap" and e["source"] == "implementation"
        else:
            expected_keys = set(keys[e["event"]])
            if path.stem.startswith("validator-") and e["event"] == "TraceEnd": expected_keys.add("validationHolds")
            assert set(e["post"]) == expected_keys, (path, i)
            coverage[e["event"]] += 1
        events.append(e)
    assert events[-1]["event"] == "TraceEnd", path
    for suffix in (".owner-readback.json", ".evidence.json"):
        assert Path(str(path) + suffix).is_file(), (path, "missing independent readback")
    validate(path, path.stem)
    print(f"{path.name}: {len(events)} records; strict replay PASS", flush=True)
# Corrupt real executions, preserving their timestamps and all unrelated state.
control_dir = logs / "controls"
control_dir.mkdir(exist_ok=True)
normal = [json.loads(l) for l in (traces / "normal.ndjson").read_text().splitlines()]
overlap = [json.loads(l) for l in (traces / "overlap.ndjson").read_text().splitlines()]
def control(name, original, event, mutate):
    data = copy.deepcopy(original)
    target = next(x["record"] for x in data if x["record"]["event"] == event)
    mutate(target)
    p = control_dir / (name + ".ndjson")
    p.write_text("".join(json.dumps(x, separators=(",", ":")) + "\n" for x in data))
    validate(p, name, negative=True)
    print(f"{name}: corrupted implementation trace rejected", flush=True)
control("bad-stored-work", normal, "CreateTasksCommit",
        lambda e: e["args"]["tasks"][0].update(work=normal[0]["record"]["config"]["work"][1]))
control("bad-queue", normal, "CreateTasksCommit", lambda e: e["queue"].update(subqueue=1))
control("bad-bound", overlap, "GetTasksSnapshot", lambda e: e["args"].update(max=e["args"]["max"] + 1))
control("missing-post-field", normal, "CreateTasksReturn", lambda e: e["post"]["owner"][0].pop("cachedAck"))
control("bad-history-request", normal, "RecordTaskStarted", lambda e: e["args"].update(request=32))
control("bad-bootstrap-ack", normal, "bootstrap", lambda e: e["post"]["durable"].update(ack=1))
control("bad-bootstrap-revision", normal, "bootstrap", lambda e: e.update(revision="wrong"))
control("bad-bootstrap-evidence", normal, "bootstrap", lambda e: e.update(source="synthetic"))
report = {"traces": results, "event_counts": dict(sorted(coverage.items())),
          "covered_actions": len(set(coverage) - {"TraceEnd"}),
          "model_actions": len(keys) - 1, "uncovered_actions": sorted(set(keys) - set(coverage)),
          "scope": "Matching implementation plus SQL V1 SQLite; controlled History interface fixture",
          "model_sha256": {n: hashlib.sha256((validation / n).read_bytes()).hexdigest() for n in ("base.tla", "Trace.tla", "Trace.cfg", "MC.tla", "ValidatorBase.tla", "TraceValidator.tla", "TraceValidator.cfg")}}
(logs / "validation-results.json").write_text(json.dumps(report, indent=2) + "\n")
print(f"Coverage: {report['covered_actions']}/{report['model_actions']} actions")
