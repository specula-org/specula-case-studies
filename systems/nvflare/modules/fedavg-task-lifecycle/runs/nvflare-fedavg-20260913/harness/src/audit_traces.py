#!/usr/bin/env python3
"""Check actual trace envelopes, full-state shape, action/L2 coverage and provenance."""
import ast
from collections import Counter, defaultdict
import hashlib
import importlib.metadata
import json
from pathlib import Path
import platform
import re
import subprocess

HERE = Path(__file__).resolve().parents[1]
SOURCE = Path("/home/ubuntu/nvflare-runs-20260913/source-fedavg")
SPEC = HERE.parent / "spec"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def shape(value):
    if isinstance(value, dict):
        return {k: shape(v) for k, v in value.items()}
    if isinstance(value, list):
        return "array"
    return type(value).__name__


def main():
    trace_spec = (SPEC / "Trace.tla").read_text()
    action_pattern = r"^Trace_([A-Za-z0-9]+) =="
    expected = set(re.findall(action_pattern, trace_spec, re.M))
    wrappers = re.split(action_pattern, trace_spec, flags=re.M)
    assert len(expected) == 80
    assert "s' = DecodeState(logline.state)" in trace_spec
    for i in range(1, len(wrappers), 2):
        assert "/\\ ValidatePostState" in wrappers[i + 1], wrappers[i]
    assert re.search(r"PROPERTIES\s+TraceMatched", (SPEC / "Trace.cfg").read_text())
    by_event, counts, trace_info = defaultdict(list), Counter(), []
    for path in sorted((HERE.parent / "traces").glob("*.ndjson")):
        rows = [json.loads(line) for line in path.read_text().splitlines()]
        meta = [r for r in rows if r["tag"] == "specula-meta"]
        assert len(meta) == 1 and rows[0] is meta[0] and meta[0]["origin"] == "implementation"
        assert meta[0]["sourceHead"] == "53ba7ee567468ea7971dad4faccef13c6cb35dc2"
        events = [r for r in rows if r["tag"] == "trace"]
        assert events
        timestamps = [r["ts"] for r in rows]
        assert all(isinstance(t, int) and t > 10**9 for t in timestamps)
        assert all(a < b for a, b in zip(timestamps, timestamps[1:]))
        seen = Counter()
        for seq, row in enumerate(events, 1):
            event = row["event"]
            assert set(event) == {"name", "nid", "args", "seq", "state"}
            assert event["seq"] == seq and event["name"] in expected
            assert shape(event["state"]) == shape(meta[0]["initial"])
            for group in ["task", "ct", "net", "used"]:
                assert len(event["state"][group]) == meta[0]["config"]["NumRounds"]
            seen[event["name"]] += 1
        for name in seen:
            by_event[name].append(path.name)
        counts.update(seen)
        runtime = json.loads((HERE / "reports" / f"{path.stem}.json").read_text())
        assert runtime["events"] == len(events)
        assert runtime["finalState"] == events[-1]["event"]["state"]
        trace_info.append(
            dict(
                trace=path.name,
                lines=len(rows),
                events=len(events),
                sha256=sha(path),
                outcome=runtime["outcome"],
                abort=runtime["abort"],
                config=meta[0]["config"],
            )
        )
    missing = sorted(expected - set(counts))
    report = dict(
        category="A",
        traceCount=len(trace_info),
        eventCount=sum(counts.values()),
        expectedEventTypes=len(expected),
        coveredEventTypes=len(counts),
        missingEvents=missing,
        fullPostStateValidation=True,
        traceMatched=True,
        traces=trace_info,
        eventCoverage={n: dict(count=counts[n], traces=by_event[n]) for n in sorted(expected)},
    )
    (HERE / "reports/coverage.json").write_text(json.dumps(report, indent=2) + "\n")
    lines = [
        "# Trace coverage",
        "",
        f"{len(trace_info)} implementation traces; {sum(counts.values())} action events; {len(counts)}/{len(expected)} action names observed.",
        "",
        "Every wrapper retains complete post-state equality and TraceMatched. Action-name coverage is not branch or interleaving exhaustiveness.",
        "",
        "| Action | Count | Scenarios |",
        "|---|---:|---|",
    ]
    lines += [
        f"| {name} | {counts[name]} | " + ", ".join(p.removesuffix(".ndjson") for p in by_event[name]) + " |"
        for name in sorted(expected)
    ]
    (HERE / "reports/coverage.md").write_text("\n".join(lines) + "\n")
    manifest = json.loads((HERE / "applied.json").read_text())
    hooks = []
    for name in manifest:
        if name.endswith("_specula_trace.py"):
            continue
        file = SOURCE / name
        for node in ast.walk(ast.parse(file.read_text())):
            if (
                isinstance(node, ast.Call)
                and isinstance(node.func, ast.Attribute)
                and isinstance(node.func.value, ast.Name)
                and node.func.value.id == "_st"
            ):
                label = node.args[0].value if node.args and isinstance(node.args[0], ast.Constant) else node.func.attr
                hooks.append((name, node.lineno, node.func.attr, label))
    (HERE / "reports/source-hooks.tsv").write_text(
        "file\tline\tkind\thook\n" + "".join("\t".join(map(str, x)) + "\n" for x in sorted(hooks))
    )
    provenance = dict(
        sourceHead=subprocess.check_output(["git", "-C", str(SOURCE), "rev-parse", "HEAD"], text=True).strip(),
        python=platform.python_version(),
        packages=dict(
            nvflare="pinned source checkout; no installed distribution metadata",
            **{p: importlib.metadata.version(p) for p in ["pytest", "numpy"]},
        ),
        sourceFiles={name: sha(SOURCE / name) for name in manifest},
        specification={
            name: sha(SPEC / name) for name in ["base.tla", "Trace.tla", "Trace.cfg", "instrumentation-spec.md"]
        },
        harnessFiles={
            str(p.relative_to(HERE)): sha(p)
            for p in sorted(HERE.rglob("*"))
            if p.is_file() and ("src" in p.parts or p.name.endswith(".sh")) and "__pycache__" not in p.parts
        },
        transport="Local FOBS encode/decode and synchronous delivery through actual runners; configured reply loss or queued sends at the adapter boundary.",
        save="Real FedAvg FOBS file save and reload; preserved under reports/models/<scenario>/round-N.fobs.",
        scheduler="Real workflow/monitor threads; controlled pauses; original protocol locks retained.",
        time="Upstream FakeClock, 30-second ticks; emitted timestamps use real time.monotonic_ns().",
    )
    assert provenance["sourceFiles"] == manifest
    (HERE / "reports/provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    print(json.dumps({k: v for k, v in report.items() if k not in ["traces", "eventCoverage"]}))
    assert not missing, missing


if __name__ == "__main__":
    main()
