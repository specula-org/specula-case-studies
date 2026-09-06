#!/usr/bin/env python3
"""Audit and replay real Rust traces without altering model transitions/checks.

Negative copies are deliberately corrupted checker controls, not implementation
traces. They are stored only under harness/validation/negative/.
"""
from __future__ import annotations

import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import copy
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
SPEC = ROOT.parent / "spec"
TRACES = ROOT.parent / "traces"
OUT = ROOT / "validation"
REVISION = "3ac0104a567092139534c9022205d02281a2da41"
STATE_FIELDS = "replicas durableViews lives phases incarnations clients retiredClients invocations acceptedReplies network replyChannel released applications".split()
REPLICA_FIELDS = "id status view lastNormal commit log acks table heard waiting attempts stable svc dvcSent dvc catching nonce responses out replies app applied results".split()
CLIENT_FIELDS = "view next pending out".split()
WIRE_FIELDS = "kind view opn commit entry log start last nonce hasState client request result".split()
ENVELOPE_FIELDS = "src dst wire incarnation proof".split()
APPLY_FIELDS = "slot entry stateBefore result stateAfter".split()
EVENTS = sorted(set(re.findall(r'IsEvent\("([A-Za-z]+)"\)', (SPEC / "Trace.tla").read_text())))


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def canonical(value) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def exact_keys(value, fields, where):
    if not isinstance(value, dict) or set(value) != set(fields):
        raise ValueError(f"{where}: expected keys {fields}; got {list(value) if isinstance(value, dict) else type(value).__name__}")


def unique(rows, where, key=lambda row: row):
    if not isinstance(rows, list):
        raise ValueError(f"{where}: expected array")
    keys = [canonical(key(row)) for row in rows]
    if len(set(keys)) != len(keys):
        raise ValueError(f"{where}: duplicate set/map keys would be hidden by TLA set normalization")


def envelope(message, where):
    exact_keys(message, ENVELOPE_FIELDS, where)
    exact_keys(message["wire"], WIRE_FIELDS, where + ".wire")
    for field in ("entry", "client"):
        value = message["wire"][field]
        if not isinstance(value, list) or len(value) > 1:
            raise ValueError(f"{where}.wire.{field}: expected [] or [value]")


def snapshot(state, ids, client_ids, where):
    exact_keys(state, STATE_FIELDS, where)
    if [r["id"] for r in state["replicas"]] != ids:
        raise ValueError(f"{where}.replicas: IDs must be exactly header order")
    for field in ("durableViews", "lives", "phases", "incarnations"):
        if len(state[field]) != len(ids):
            raise ValueError(f"{where}.{field}: wrong cluster length")
    for row in state["replicas"]:
        rp = f"{where}.replicas[{row['id']}]"
        exact_keys(row, REPLICA_FIELDS, rp)
        for field, key in (("acks", "slot"), ("table", "client"), ("dvc", "replica"), ("responses", "replica")):
            unique(row[field], rp + "." + field, lambda x, key=key: x[key])
        for ack in row["acks"]:
            exact_keys(ack, ("slot", "replicas"), rp + ".acks")
            unique(ack["replicas"], rp + ".acks.replicas")
        for entry in row["table"]:
            exact_keys(entry, ("client", "request", "hasReply", "reply"), rp + ".table")
        for entry in row["dvc"]:
            exact_keys(entry, ("replica", "last", "log", "commit"), rp + ".dvc")
        for entry in row["responses"]:
            exact_keys(entry, ("replica", "view", "hasState", "log", "commit"), rp + ".responses")
        unique(row["svc"], rp + ".svc")
        for field in ("out", "replies"):
            for msg in row[field]:
                envelope(msg, rp + "." + field)
    unique(state["clients"], where + ".clients", lambda x: x["id"])
    if {x["id"] for x in state["clients"]} != set(client_ids):
        raise ValueError(f"{where}.clients: all declared lifetimes must remain represented")
    for client in state["clients"]:
        exact_keys(client, ("id", "state"), where + ".clients")
        exact_keys(client["state"], CLIENT_FIELDS, where + ".clients.state")
        for msg in client["state"]["out"]:
            envelope(msg, where + ".clients.state.out")
    for field in ("retiredClients", "invocations", "acceptedReplies", "released"):
        unique(state[field], where + "." + field)
    unique(state["invocations"], where + ".invocations identity", lambda x: (x["client"], x["request"]))
    for field in ("acceptedReplies", "released"):
        for msg in state[field]:
            envelope(msg, where + "." + field)
    for field in ("network", "replyChannel"):
        unique(state[field], where + "." + field, lambda x: x["message"])
        for row in state[field]:
            exact_keys(row, ("message", "count"), where + "." + field)
            if type(row["count"]) is not int or row["count"] <= 0:
                raise ValueError(f"{where}.{field}: bag counts must be positive integers")
            envelope(row["message"], where + "." + field + ".message")
    unique(state["applications"], where + ".applications", lambda x: (x["replica"], x["incarnation"]))
    for row in state["applications"]:
        exact_keys(row, ("replica", "incarnation", "entries"), where + ".applications")


def read_audit(path):
    rows = []
    for line_number, line in enumerate(path.read_text().splitlines(), 1):
        row = json.loads(line)
        if row.get("tag") != "trace":
            raise ValueError(f"{path.name}:{line_number}: mandatory tag must be trace")
        stamp = int(row["ts"])
        if not 1577836800 * 10**9 <= stamp <= time.time_ns() + 300 * 10**9:
            raise ValueError(f"{path.name}:{line_number}: expected real Unix nanoseconds in ts")
        if row.get("event") not in EVENTS + ["Init"]:
            raise ValueError(f"{path.name}:{line_number}: unknown event {row.get('event')}")
        rows.append(row)
    if len(rows) < 2 or rows[0]["event"] != "Init" or any(r["event"] == "Init" for r in rows[1:]):
        raise ValueError(f"{path.name}: exactly one Init followed by transitions is required")
    header = rows[0]
    if header["revision"] != REVISION or header["workload"] != "register-put-old-v1":
        raise ValueError(f"{path.name}: wrong revision or application workload")
    ids, client_ids = header["replicas"], header["clients"]
    if ids != list(range(len(ids))) or set(ids) & set(client_ids):
        raise ValueError(f"{path.name}: replica/client identity namespaces are invalid")
    unique(client_ids, path.name + ".header.clients")
    counts, branches, incoming = Counter(), Counter(), Counter()
    applies = 0
    for k, row in enumerate(rows, 1):
        where = f"{path.name}:{k}"
        snapshot(row["state"], ids, client_ids, where + ".state")
        if k == 1:
            continue
        counts[row["event"]] += 1
        if "message" in row:
            envelope(row["message"], where + ".message")
        if row["event"] == "ReplicaOnMessage":
            incoming[row["message"]["wire"]["kind"]] += 1
        if "branch" in row:
            branches[row["event"] + ":" + row["branch"]] += 1
        if not isinstance(row["applies"], list):
            raise ValueError(where + ": applies must be an ordered array")
        for item in row["applies"]:
            exact_keys(item, APPLY_FIELDS, where + ".applies")
        applies += len(row["applies"])
    return rows, {"trace": str(path), "sha256": digest(path), "lines": len(rows), "transitions": len(rows) - 1,
                  "events": dict(counts), "branches": dict(branches), "incoming_message_kinds": dict(incoming), "apply_calls": applies}


def audit_l2():
    text = (SPEC / "Trace.tla").read_text()
    wrappers = {}
    for event in EVENTS:
        body = text.split("Trace" + event + " ==", 1)[1].split("\nTrace", 1)[0].split("\n\\*", 1)[0]
        applies = "ValidateApplies(i)" if event in ("ReplicaOnMessage", "ReplicaOnIdle") else "ValidateNoApply"
        wrappers[event] = {"full_post_state_equality": "ValidatePostState" in body,
                           "applies_check": applies, "applies_checked": applies in body}
    whole = "ValidatePostState == NormalizeSnapshot(logline.state)=Snapshot'" in text
    result = {"passed": whole and all(v["full_post_state_equality"] and v["applies_checked"] for v in wrappers.values()),
              "full_equality": whole, "wrappers": wrappers,
              "captured_state_fields": STATE_FIELDS, "captured_replica_fields": REPLICA_FIELDS,
              "captured_client_fields": CLIENT_FIELDS, "captured_apply_fields": APPLY_FIELDS,
              "field_check": "All captured snapshot fields are compared by complete record equality. Extra or missing record keys fail equality. Logs, output queues, results, and applied histories retain sequence order.",
              "normalization": "Only documented set arrays and min(attempts,10)/min(stable,PrimaryTimeout). Python audit rejects duplicate set/map keys before TLC.",
              "metadata": "ts is observer clock metadata, validated for plausibility by this audit. Revision/workload/header identities are checked by TraceInit.",
              "silent_actions": False}
    return result


def negatives(all_rows):
    controls = []
    recipes = [
        ("postcommit", lambda r: r.get("event") == "ReplicaOnMessage" and r["message"]["wire"]["kind"] == "Request"),
        ("apply-result", lambda r: bool(r.get("applies"))),
        ("packet-offset", lambda r: r.get("event") == "ReplicaOnMessage" and r["message"]["wire"]["kind"] == "NewState"),
        ("omitted-persist", lambda r: r.get("event") == "PersistView"),
    ]
    directory = OUT / "negative"
    directory.mkdir(parents=True, exist_ok=True)
    for name, predicate in recipes:
        found = next(((path, rows, k) for path, rows in all_rows for k, row in enumerate(rows) if predicate(row)), None)
        if found is None:
            raise ValueError(f"Cannot construct {name} control: required real event is absent")
        path, rows, k = found
        changed = copy.deepcopy(rows)
        if name == "postcommit":
            changed[k]["state"]["replicas"][changed[k]["node"]]["commit"] += 1
        elif name == "apply-result":
            changed[k]["applies"][0]["result"] += 1
        elif name == "packet-offset":
            changed[k]["message"]["wire"]["start"] += 1
        else:
            del changed[k]
        target = directory / (name + ".ndjson")
        target.write_text("".join(canonical(row) + "\n" for row in changed))
        controls.append({"name": "negative-" + name, "path": str(target), "kind": "negative",
                         "source": str(path), "source_sha256": digest(path), "sha256": digest(target), "first_changed_line": k + 1})
    return controls


def check_tlc(check, jars, seconds):
    name = check["name"]
    log = OUT / (name + ".log")
    cmd = ["java", "-XX:+UseParallelGC", "-Xmx1g", "-cp", os.pathsep.join(map(str, jars)), "tlc2.TLC",
           "-noGenerateSpecTE", "-difftrace", "-workers", "1", "-config", "Trace.cfg", "-metadir", str(OUT / "states" / name), "Trace"]
    start = time.monotonic()
    timed_out = False
    with log.open("w") as stream:
        try:
            proc = subprocess.run(cmd, cwd=SPEC, env=os.environ | {"JSON": check["path"]},
                                  stdout=stream, stderr=subprocess.STDOUT, timeout=seconds)
            code = proc.returncode
        except subprocess.TimeoutExpired:
            code, timed_out = None, True
    data = log.read_text()
    completed = code == 0 and "Model checking completed. No error has been found." in data
    rejected = code != 0 and "Temporal property TraceMatched was violated." in data and "unexpected exception" not in data
    ok = not timed_out and (completed if check["kind"] == "positive" else rejected)
    cursors = [int(x) for x in re.findall(r"/\\ l = (\d+)", data)]
    errors = [line for line in data.splitlines() if line.startswith("Error:")]
    state_counts = re.findall(r"[\d,]+ states generated, [\d,]+ distinct states found, [\d,]+ states left on queue\.", data)
    result = check | {"passed": ok, "returncode": code, "timed_out": timed_out, "elapsed_seconds": round(time.monotonic() - start, 3),
                      "timeout_seconds": seconds, "command": cmd, "cwd": str(SPEC), "JSON": check["path"], "log": str(log),
                      "errors": errors, "last_counterexample_cursor": max(cursors, default=None), "state_counts": state_counts[-1:]}
    print(f"{name}: {'PASS' if ok else 'FAIL'} ({result['elapsed_seconds']:.2f}s)", flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("traces", nargs="*", type=Path)
    parser.add_argument("--timeout", type=int, default=180, help="Seconds per TLC invocation; timeout is failure, never retried")
    parser.add_argument("--jobs", type=int, choices=(1, 2, 3), default=2)
    parser.add_argument("--audit-only", action="store_true")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    paths = [p.resolve() for p in (args.traces or sorted(TRACES.glob("*.ndjson")))]
    if not paths:
        raise ValueError("No real implementation traces found")
    read = [(path, *read_audit(path)) for path in paths]
    coverage = [item[2] for item in read]
    observed = set().union(*(set(item["events"]) for item in coverage))
    l2 = audit_l2()
    (OUT / "l2-audit.json").write_text(json.dumps(l2, indent=2) + "\n")
    (OUT / "coverage.json").write_text(json.dumps({"traces": coverage, "instrumented_events": EVENTS,
                                                "observed_events": sorted(observed), "uncovered_events": sorted(set(EVENTS) - observed)}, indent=2) + "\n")
    if not l2["passed"]:
        raise ValueError("L2 audit failed: a wrapper lacks full snapshot or applies validation")
    print(f"Schema/L2 audit: PASS; {len(read)} traces, {sum(x['transitions'] for x in coverage)} transitions; {len(observed)}/{len(EVENTS)} event types", flush=True)
    if args.audit_only:
        return 0
    jar = Path(os.environ.get("TLA_JAR", "/home/ubuntu/Specula-incremental-dataset-20260815/tools/tla2tools.jar"))
    community = Path(os.environ.get("COMMUNITY_JAR", str(jar.with_name("CommunityModules-deps.jar"))))
    for path in (jar, community):
        if not path.is_file():
            raise ValueError(f"Missing tool jar: {path}; set TLA_JAR and COMMUNITY_JAR")
    positive = [{"name": "positive-" + path.stem, "path": str(path), "kind": "positive", "sha256": digest(path)} for path in paths]
    controls = negatives([(path, rows) for path, rows, _ in read])
    (OUT / "negative-manifest.json").write_text(json.dumps(controls, indent=2) + "\n")
    checks = positive + controls
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(lambda check: check_tlc(check, (jar, community), args.timeout), checks))
    report = {"created_utc": datetime.now(timezone.utc).isoformat(), "source_revision": REVISION,
              "tool_sha256": {str(path): digest(path) for path in (jar, community)},
              "spec_sha256": {str(path): digest(path) for path in (SPEC / "Trace.tla", SPEC / "Trace.cfg", SPEC / "base.tla")},
              "l2_passed": l2["passed"], "checks": results, "all_passed": all(x["passed"] for x in results),
              "interpretation": "Real implementation trace replay checks only the recorded schedules. Negative controls establish rejection of changed observations; they are not implementation runs. This is neither exhaustive correctness verification nor a general liveness proof."}
    (OUT / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    lines = ["# Real implementation trace validation", "", report["interpretation"], "",
             "| Check | Result | TLC exit | Seconds |", "|---|---|---:|---:|"]
    lines += [f"| {r['name']} | {'PASS' if r['passed'] else 'FAIL'} | {r['returncode']} | {r['elapsed_seconds']} |" for r in results]
    lines += ["", "Every run uses the unrelaxed Trace.cfg invariants and TraceMatched property. Positive passes require completed TLC with zero errors. Negative passes require rejection specifically by TraceMatched; parser errors, invariant failures, exceptions, and timeouts do not count.",
              "", "results.json records exact commands, hashes, exit codes, errors and log paths. coverage.json records events/branches and missing coverage; l2-audit.json records field/wrapper checks. Corrupted copies reside under negative/ only."]
    (OUT / "README.md").write_text("\n".join(lines) + "\n")
    return 0 if report["all_passed"] else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, KeyError, json.JSONDecodeError) as error:
        print(f"Validation audit failed: {error}", file=sys.stderr)
        sys.exit(1)
