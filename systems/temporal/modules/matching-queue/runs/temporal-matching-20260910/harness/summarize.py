#!/usr/bin/env python3
import collections
import datetime
import hashlib
import json
import re
from pathlib import Path

h = Path(__file__).resolve().parent
trace_dir = h.parent / "traces"
verification = json.loads((h / "logs/validation-results.json").read_text())
runs = []
for d in sorted((h / "model-checks").iterdir()):
    if not (d / "run.json").exists():
        continue
    meta = json.loads((d / "run.json").read_text())
    text = (d / "output.log").read_text()
    code = int((d / "exit-code").read_text()) if (d / "exit-code").exists() else None
    superseded = (d / "superseded.json").exists()
    limited = (d / "stop-request.json").exists() or code in (124, 130, 137, 143)
    violation = re.findall(r"Error: (Invariant .*? violated\.|Temporal .*?violated\.)", text)
    complete = code == 0 and "Model checking completed. No error" in text and not limited and not superseded
    status = "VIOLATION" if violation else ("PASS" if complete else ("RUNNING" if code is None else "INCOMPLETE"))
    final = re.findall(r"^([\d,]+) states generated, ([\d,]+) distinct states found, ([\d,]+) states left on queue\.", text, re.M)
    progress = re.findall(r"Progress\((\d+)\) at ([^:]+ \d\d:\d\d:\d\d): ([\d,]+) states generated.*?, ([\d,]+) distinct states found.*?, ([\d,]+) states left on queue\.", text)
    row = dict(meta, directory=d.name, status=status, exit_code=code, superseded=superseded)
    if final:
        row.update(zip(("generated", "distinct", "queued"), (int(x.replace(",", "")) for x in final[-1])))
        row["counts_origin"] = "final TLC statistics"
    elif progress:
        row.update(zip(("generated", "distinct", "queued"), (int(x.replace(",", "")) for x in progress[-1][2:])))
        row["counts_origin"] = "last logged progress; lower bounds for generated/distinct"
        row["last_progress_utc"] = progress[-1][1]
    depth = re.findall(r"The depth of the complete state graph search is (\d+)\.", text)
    if depth or progress:
        row["depth_reached"] = int(depth[-1] if depth else progress[-1][0])
    duration = re.findall(r"Finished in (.+?) at", text)
    row["reported_duration"] = duration[-1] if duration else None
    if (d / "stop-request.json").exists():
        row["stop"] = json.loads((d / "stop-request.json").read_text())
    cfg_text = (d / meta["config"]).read_text()
    row["invariants"] = [name for line in cfg_text.splitlines() if line.startswith("INVARIANT") for name in line.split()[1:]]
    runs.append(row)
(h / "logs/model-check-results.json").write_text(json.dumps(runs, indent=2) + "\n")
positive = [x for x in verification["traces"] if x["status"] == "PASS"]
negative = [x for x in verification["traces"] if x["status"] == "REJECTED"]
lines = [
    "# temporal-matching harness results",
    "",
    f"Source: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`. Updated {datetime.datetime.now(datetime.timezone.utc).isoformat()}.",
    "",
    f"**{len(positive)} complete Matching + file-backed SQLite traces passed strict replay. {len(negative)} corrupted implementation-trace controls were rejected.** Coverage is {verification['covered_actions']}/{verification['model_actions']} model actions: 77 of the supplied 81 plus the observed `SignalIfFatal` action. This is action-type coverage, not product coverage or coverage of every parameter/interleaving.",
    "",
    "The one-command runner was executed from `.specula-output/`. A pristine detached checkout accepted the instrumentation patch; the narrow clean script restored a clean checkout. Race-enabled runs passed. Repository `make lint-code-fast GOLANGCI_LINT_BASE_REV=HEAD` reported 0 issues. The original priority backlog suite passed 19 applicable subtests and skipped 10 existing non-applicable cases.",
    "",
    "The scenarios use the real Matching engine, physical queue, priority writer/reader/matcher and both real task-store factories (V2 only for initial empty draining setup). History remains a controlled interface fixture. The non-expiry validator loop is parked; its missing model path is documented. Process crash/transport teardown and real History obsolescence are unvalidated. No Temporal implementation bug is confirmed by this harness.",
    "",
    "## Complete traces",
    "",
    "| Scenario | Records, including bootstrap/seal | Ending SQL range / ack | Retained task IDs |",
    "|---|---:|---|---|",
]
for result in positive:
    p = trace_dir / (result["name"] + ".ndjson")
    events = [json.loads(line)["record"] for line in p.read_text().splitlines()]
    durable = events[-1]["post"]["durable"]
    lines.append(f"| [{result['name']}](../traces/{p.name}) | {len(events)} | {durable['range']} / {durable['ack']} | `{durable['rows']}` |")
lines += [
    "",
    "Observed distinctions: committed-but-error writes remain durable and retries can create a second record for the same work; replacement succeeds before original acknowledgement; stale range conditions roll back the real SQL transaction; an old owner's captured GC can delete under a newer lease because deletion has no range fence. Out-of-order completion, duplicate reads and stale gaps are followed through completion and reload.",
    "",
    "In `expiry-retained`, read filtering retains two expired SQL rows and leaves ack at 0; in `expiry-matcher-gc`, the actual validator completion path acknowledges and deletes them. This is an observed cleanup-path distinction, not a claim of eligible-work loss.",
    "",
    "The five rejected controls corrupt stored work identity, queue/subqueue identity, SELECT upper bound, a required post-state field, and the independently observed History request alias. All were rejected by `TraceMatched`, not by an unrelated build or parser error.",
    "",
    "## Bounded model checking",
    "",
    "Every current run uses the exact replay-validated `validation/base.tla` and `validation/MC.tla` hashes. Original input configurations are unchanged; the additional owner baseline uses one work/one Add/one allocated record, two owner lifetimes, one takeover and no injected faults. It enables all core/priority safety checks plus structural checks.",
    "",
    "**The two-work/two-record core baseline completed.** `MC_core_baseline.cfg` checks two Add attempts and two reserved records with one stable owner/poller, range size 2, read batch 3/reload 1, GC batch 2, no injected faults and no sync matching. It completed 24,938,594 generated / 5,447,053 distinct states, depth 74, zero queued, in 1 minute 54 seconds (8 GiB heap, 8 workers). All listed core/priority and structural invariants passed within that scope. It does not establish fault, ownership-change or liveness guarantees.",
    "",
    "The supplied `MC_smoke.cfg` is a complete **small normal-operation baseline**: one owner/work/Add/record, no faults or takeover. It is not completion of the requested three-work/six-record baseline. All larger runs retain their explicit resource frontiers and are reported incomplete if stopped with unexplored states.",
    "",
    "Counts for incomplete searches are the exact **last logged samples**, not final totals; generated/distinct counts are lower bounds. The final periodic sample is approximately one minute before timeout.",
    "",
    "| Current configuration | Result | Generated | Distinct | Queued | Depth reached | Time | Heap / workers |",
    "|---|---|---:|---:|---:|---:|---|---|",
]
for r in runs:
    if not r["directory"].startswith("current-"):
        continue
    def number(k):
        return f"{r[k]:,}" if k in r else "—"
    elapsed = r.get("reported_duration") or (f"{r['stop']['elapsed_seconds_at_request']}s at stop request" if r.get("stop") else ("1800s cap" if r["exit_code"] == 124 else ("superseded" if r["superseded"] else "running")))
    lines.append(f"| [{r['config']}](model-checks/{r['directory']}/{r['config']}) | [{r['status']}](model-checks/{r['directory']}/output.log) | {number('generated')} | {number('distinct')} | {number('queued')} | {number('depth_reached')} | {elapsed} | {r['heap']} / {r['workers']} |")
lines += [
    "",
    "All six larger current searches reached the 1,800-second outer limit and exited 124. No violation was reported before termination. The optional JMX controller produced no stop receipts, so no final-counter capture is claimed; the table uses last-progress samples. These outcomes are INCOMPLETE, including the requested three-work/six-record baseline and the additional ownership baseline.",
    "",
    "Earlier attempts were superseded when independent flag/matcher observations required model corrections. Their configurations, hashes and logs are retained and are not counted as current results; the setup-only core run is likewise superseded. Conditional liveness and fairness V2 have not been verified. No convergence claim follows from an incomplete BFS or from trace replay.",
    "",
    "Exact counters, statuses, invariant lists and model/config hashes: [model-check-results.json](logs/model-check-results.json). Trace hashes and coverage: [validation-results.json](logs/validation-results.json). Applied source/model changes and adjustment instructions: [INSTRUMENTATION.md](INSTRUMENTATION.md).",
    "",
    "## Reproduce a bounded search",
    "",
    "From a selected `harness/model-checks/current-*/` snapshot directory, run the command recorded by its `run.json`:",
    "",
    "```sh",
    'timeout -s INT -k 15 1800 java -XX:+UseParallelGC -Xmx8g -cp "$TLC_JAR" tlc2.TLC -workers 3 -config MC.cfg MC > rerun.log 2>&1',
    "```",
    "",
    "Use that directory's actual cfg filename and its recorded heap/workers (smoke: 2g/2; owner baseline: 8g/6; core baseline: 8g/8). A timeout remains INCOMPLETE. Generated TLC scratch queues were removed after all process receipts completed; snapshots, logs, counters and SQLite evidence are retained. No resumable checkpoint is claimed.",
]
(h / "RESULTS.md").write_text("\n".join(lines) + "\n")
print(f"Wrote RESULTS.md: {len(positive)} traces, {len(negative)} controls, {len(runs)} model-check snapshots.")
