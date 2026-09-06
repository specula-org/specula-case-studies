#!/usr/bin/env python3
"""Audit real harness NDJSON shape, event coverage, and replay L2 wiring.

This is a capture/schema audit. TLC, not this script, checks transitions.
"""

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import sys
import time


HARNESS = Path(__file__).resolve().parent
STATE_FIELDS = set("status view lastNormal commit log acks table heard waiting attempts stable svc dvcSent dvc catching nonce responses app applied out".split())
MESSAGE_FIELDS = set("kind src dst view opnum commit start lastNormal nonce hasState log request result".split())
KINDS = set("Request Prepare PrepareOk Commit GetState NewState StartViewChange DoViewChange StartView Recovery RecoveryResponse Reply".split())
REPLICA_EVENTS = {"On" + kind for kind in KINDS - {"Reply"}}
EVENTS = REPLICA_EVENTS | set("Init OnIdle Crash Recover ClientOnRequest ClientOnIdle ClientOnReply Lose Duplicate".split())


def require(value, explanation):
    if not value:
        raise ValueError(explanation)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"duplicate JSON key {key!r}")
        result[key] = value
    return result


def exact_keys(value, keys, label):
    require(isinstance(value, dict) and set(value) == keys, f"{label}: expected keys {sorted(keys)}")


def unique(values, label):
    frozen = [json.dumps(v, sort_keys=True, separators=(",", ":")) for v in values]
    require(len(frozen) == len(set(frozen)), f"{label}: duplicate entries")


def request(value, label):
    exact_keys(value, {"client", "number", "op"}, label)


def messages(values, label):
    require(isinstance(values, list), f"{label}: expected array")
    for index, message in enumerate(values):
        where = f"{label}[{index}]"
        exact_keys(message, MESSAGE_FIELDS, where)
        require(message["kind"] in KINDS, f"{where}: unknown message kind")
        request(message["request"], where + ".request")
        for entry in message["log"]:
            request(entry, where + ".log entry")


def associations(entries, label, value_fields=None):
    require(isinstance(entries, list), f"{label}: expected array")
    for entry in entries:
        exact_keys(entry, {"key", "value"}, label)
        if value_fields:
            exact_keys(entry["value"], value_fields, label + ".value")
    unique([entry["key"] for entry in entries], label + " keys")


def timestamp(value):
    # The emitter uses a real epoch clock. Large decimal values remain strings
    # so TLC's integer decoder does not overflow; timestamps are diagnostic.
    if isinstance(value, (str, int)) and str(value).isdigit():
        number = int(value)
        for scale in (1, 1000, 1000000, 1000000000):
            epoch = number / scale
            if 1577836800 <= epoch <= time.time() + 60:
                return epoch
    if isinstance(value, str):
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
        except ValueError:
            pass
    raise ValueError("ts is not a plausible real epoch timestamp")


def audit_l2(spec):
    text = spec.read_text()
    require('e.tag="trace"' in text, "Trace.tla must filter the mandatory trace tag")
    body = text.split("ValidatePostState(e) ==", 1)[1].split("ValidateInitialState(e) ==", 1)[0]
    checks = ["SnapshotShape(e)", "replicas'=CapturedReplicas(e)", "clients'=CapturedClients(e)",
              "durableView'=CapturedDurable(e)", "live'=CapturedLive(e)",
              "incarnations'=CapturedIncarnations(e)", "usedNonces'=CapturedNonces(e)",
              "network'=BagAdd(EmptyMap,e.network)", "lastOutput'=e.outputs"]
    require(all(check in body for check in checks), "ValidatePostState full comparison is incomplete")
    require("DOMAIN s=DOMAIN NewReplica" in text, "Replica field domain is not enforced")
    require("DOMAIN ClientRows(e)[c].state=DOMAIN NewClient" in text, "Client field domain is not enforced")
    wrappers = re.findall(r"^Trace([A-Za-z]+)(?:\([^\n]*\))? ==\n(.*?)(?=^Trace[A-Za-z]+|\Z)", text, re.M | re.S)
    checked = {}
    for event, wrapper in wrappers:
        if event in EVENTS - {"Init"}:
            require("ValidatePostState(logline)" in wrapper, f"Trace{event}: missing full post-state check")
            checked[event] = "full"
    require(set(checked) == EVENTS - {"Init"}, "Missing action wrappers in Trace.tla")
    require("Init /\\ ValidateInitialState(Header)" in text, "Init must validate full fresh initial state")
    return {"replica_state_fields": sorted(STATE_FIELDS), "wrappers": checked, "initial_snapshot": "full"}


def audit_file(path):
    rows = []
    for line_number, line in enumerate(path.read_text().splitlines(), 1):
        require(bool(line.strip()), f"{path}:{line_number}: blank NDJSON line")
        try:
            row = json.loads(line, object_pairs_hook=unique_object)
            require(row.get("tag") == "trace", "implementation trace files may only contain protocol events")
            require(row.get("event") in EVENTS, "unrecognized event name")
            timestamp(row.get("ts"))
        except (ValueError, AttributeError) as error:
            raise ValueError(f"{path}:{line_number}: {error}") from error
        rows.append(row)
    require(rows and rows[0]["event"] == "Init", f"{path}: no Init bootstrap")
    require(all(row["event"] != "Init" for row in rows[1:]), f"{path}: mixed scenarios")
    header = rows[0]
    servers = header["servers"]
    clients = header["clientIds"]
    require(servers == list(range(len(servers))) and len(servers) >= 2, "Expected contiguous membership with N >= 2")
    unique(clients, "clientIds")
    unique(header["operations"], "operations")
    require(clients and all(isinstance(client, str) and client for client in clients), "Invalid clientIds")
    for line_number, row in enumerate(rows, 1):
        label = f"{path.name}:{line_number} {row['event']}"
        require(len(row["replicas"]) == len(servers), label + ": replica row count")
        require({replica["id"] for replica in row["replicas"]} == set(servers), label + ": replica IDs")
        require(len(row["clients"]) == len(clients), label + ": client row count")
        require({client["id"] for client in row["clients"]} == set(clients), label + ": client IDs")
        for replica in row["replicas"]:
            exact_keys(replica, {"id", "live", "durableView", "incarnation", "usedNonces", "state"}, label + " replica")
            unique(replica["usedNonces"], label + " usedNonces")
            state = replica["state"]
            exact_keys(state, STATE_FIELDS, label + " state")
            associations(state["acks"], label + " acks")
            for ack in state["acks"]:
                unique(ack["value"], label + " ack set")
            associations(state["table"], label + " table", {"number", "hasReply", "result"})
            associations(state["dvc"], label + " dvc", {"lastNormal", "log", "commit"})
            associations(state["responses"], label + " responses", {"view", "hasState", "log", "commit"})
            unique(state["svc"], label + " svc")
            require(state["out"] == [], label + ": outboxes must be drained")
            for entry in state["log"] + state["applied"]:
                request(entry, label + " log/applied entry")
        for client in row["clients"]:
            exact_keys(client, {"id", "state"}, label + " client")
            exact_keys(client["state"], {"view", "next", "pending"}, label + " client state")
            require(len(client["state"]["pending"]) <= 1, label + ": multiple outstanding requests")
            for entry in client["state"]["pending"]:
                request(entry, label + " pending")
        messages(row["network"], label + " network")
        messages(row["outputs"], label + " outputs")
        event = row["event"]
        if event in REPLICA_EVENTS | {"ClientOnReply", "Lose", "Duplicate"}:
            messages([row["message"]], label + " input")
        if event in REPLICA_EVENTS | {"OnIdle", "Crash", "Recover"}:
            require(row["node"] in servers, label + ": unknown node")
        if event.startswith("Client"):
            require(row["client"] in clients, label + ": unknown client")
        if event == "ClientOnRequest":
            require(row["op"] in header["operations"], label + ": operation not declared")
    times = [timestamp(row["ts"]) for row in rows]
    require(max(times) > min(times), f"{path}: all timestamps are identical")
    completion = path.with_suffix(".complete.json")
    require(completion.exists(), f"{completion}: missing scenario completion marker")
    marker = json.loads(completion.read_text(), object_pairs_hook=unique_object)
    require(marker.get("completed") is True, f"{completion}: incomplete scenario")
    require(marker.get("event_count") == len(rows), f"{completion}: event count mismatch")
    native_events = REPLICA_EVENTS | {"OnIdle", "ClientOnRequest", "ClientOnIdle", "ClientOnReply"}
    require(marker.get("native_callback_count") == sum(row["event"] in native_events for row in rows),
            f"{completion}: native callback count mismatch")
    complete = "event and native callback counts checked"
    return {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "events": len(rows), "event_counts": dict(sorted(Counter(row["event"] for row in rows).items())),
            "timestamp_span_seconds": max(times) - min(times), "completion_marker": complete}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("traces", nargs="*", type=Path)
    parser.add_argument("--require-all-events", action="store_true")
    parser.add_argument("--spec", type=Path, default=HARNESS.parent / "spec" / "Trace.tla")
    args = parser.parse_args()
    paths = args.traces or sorted((HARNESS.parent / "traces").glob("*.ndjson"))
    require(paths, "No implementation trace files found")
    l2 = audit_l2(args.spec)
    files = [audit_file(path.resolve()) for path in paths]
    counts = Counter()
    for file in files:
        counts.update(file["event_counts"])
    missing = sorted(EVENTS - set(counts))
    if args.require_all_events:
        require(not missing, f"Uncovered instrumented event types: {missing}")
    json.dump({"generated_at": datetime.now(timezone.utc).isoformat(), "status": "PASS",
               "l2": l2, "files": files, "event_counts": dict(sorted(counts.items())),
               "missing_events": missing,
               "scope": "Schema and L2 wiring audit; TLC separately checks full transitions. Timestamp plausibility is not a provenance proof."}, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, IndexError) as error:
        print(f"Trace audit FAILED: {error}", file=sys.stderr)
        sys.exit(1)
