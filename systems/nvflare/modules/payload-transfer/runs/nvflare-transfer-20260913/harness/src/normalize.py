# Copyright (c) 2026, NVIDIA CORPORATION. All rights reserved.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
"""Lossless semantic projection to the pre-existing custom Trace.tla envelope.

Raw NDJSON retains real timestamps and thread identity. No event filtering,
reordering, state correction or missing-field substitution is permitted.
"""

import collections
import hashlib
import json
import pathlib
import sys

out = pathlib.Path(__file__).resolve().parents[2]
actions = {x["name"]: x for x in json.loads((out / "spec/action-map.json").read_text())}
coverage = collections.Counter()
manifest = []
for path in sorted((out / "traces").glob("*.ndjson")):
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    assert rows and rows[0]["tag"] == "config" and rows[0]["event"] == "init"
    header = dict(rows[0])
    header["tag"] = "nvflare-transfer"
    header.pop("ts")
    normalized = [header]
    counts = collections.Counter()
    prev_ts = rows[0]["ts"]
    for i, row in enumerate(rows[1:], 1):
        assert row["tag"] == "trace" and row["n"] == i and row["tx"] == header["tx"]
        assert isinstance(row["ts"], int) and row["ts"] >= prev_ts and row["ts"] > 10**18
        prev_ts = row["ts"]
        e = row["event"]
        a = actions[e["name"]]
        assert set(e["state"]) == set(a["fields"]), (path, i, e["name"], set(e["state"]), a["fields"])
        assert set(e["msg"]) == {p[0] for p in a["params"]}
        counts[e["name"]] += 1
        normalized.append(
            dict(tag="nvflare-transfer", tx=row["tx"], n=i, event=e["name"], args=e["msg"], post=e["state"])
        )
    assert counts, "an init-only file is not a trace"
    dest = path.parent / "normalized" / path.name
    dest.parent.mkdir(exist_ok=True)
    dest.write_text("".join(json.dumps(x, separators=(",", ":")) + "\n" for x in normalized))
    work = out / "harness/validation" / path.stem / "spec"
    work.mkdir(parents=True, exist_ok=True)
    for name in ("Trace.tla", "Trace.cfg", "base.tla"):
        link = work / name
        if not link.exists():
            link.symlink_to(out / "spec" / name)
    link = work.parent / "traces" / "trace.ndjson"
    link.parent.mkdir(exist_ok=True)
    if not link.exists():
        link.symlink_to(dest)
    coverage.update(counts)
    manifest.append(
        dict(
            raw=str(path),
            normalized=str(dest),
            events=sum(counts.values()),
            event_types=len(counts),
            threads=sorted({x["thread"]["name"] for x in rows[1:]}),
            raw_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
            normalized_sha256=hashlib.sha256(dest.read_bytes()).hexdigest(),
            counts=dict(counts),
        )
    )
report = dict(
    traces=manifest,
    covered=dict(sorted(coverage.items())),
    missing=sorted(set(actions) - set(coverage)),
    total_actions=len(actions),
    transformation="Envelope only; retain every event/arg/post in order; raw is timestamp/thread audit source.",
)
(out / "harness/logs/coverage.json").write_text(json.dumps(report, indent=2) + "\n")
for item in manifest:
    print(pathlib.Path(item["raw"]).name, item["events"], "events", item["event_types"], "types")
print("Coverage:", len(coverage), "/", len(actions), "actions")
print("Missing:", ", ".join(report["missing"]))
