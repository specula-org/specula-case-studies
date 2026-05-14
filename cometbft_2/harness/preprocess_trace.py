#!/usr/bin/env python3
"""Preprocess NDJSON trace files for TLA+ trace validation.

Round-2 (BFT) version. Maps concrete hex IDs to abstract TLA+ server IDs
following the spec's Faulty / Honest partition.

Mapping policy:
  - Honest-path nids (event.nid in EnterX / FinalizeCommit / Receive* / Crash/Recover)
    are assigned to s1, s2, s3 in first-appearance order.
  - Any nid that ever appears as `event.nid` of a Byzantine action
    (event.name starts with "Byz") is mapped to s4 (per Trace.cfg
    Faulty = {"s4"}).
  - LightClient nids (c1, c2, ...) are passed through unchanged.
  - Block hashes seen in msg.value / state.lockedValue / state.validValue
    / byzVote.value are mapped to v1, v2, ... (values from Trace.cfg).

This deterministic policy ensures the trace is replayable against the spec
even if test scenarios touch only a subset of validators.
"""
import json
import sys
from collections import OrderedDict


LIGHT_CLIENT_PREFIX = "c"


def is_light_client(nid):
    return (
        isinstance(nid, str)
        and nid.startswith(LIGHT_CLIENT_PREFIX)
        and nid[1:].isdigit()
    )


def is_sentinel(val):
    return val in (
        None, "", "nil", "Nil", "NilVote",
        "NoVE", "ValidVE", "InvalidVE",
        "DuplicateVoteEv", "LightClientAttackEv", "InvalidEv",
    )


def looks_like_hash(val):
    """Hash strings are >= 16 hex characters."""
    if not isinstance(val, str):
        return False
    if len(val) < 16:
        return False
    return all(c in "0123456789abcdef" for c in val.lower())


def looks_like_address(val):
    """Validator addresses are typically 40 hex characters."""
    return isinstance(val, str) and len(val) >= 16 and looks_like_hash(val)


def collect_ids(events):
    """Two-pass collection of servers and values.

    Pass 1: identify Byzantine signers (always nids of Byz* events) → s4.
    Pass 2: assign s1, s2, s3 to honest nids in first-appearance order.
    """
    byzantine_signers = set()
    for evt in events:
        e = evt["event"]
        name = e.get("name", "")
        if name.startswith("Byz"):
            nid = e.get("nid")
            if nid and not is_light_client(nid):
                byzantine_signers.add(nid)

    servers = OrderedDict()  # impl ID -> spec name
    next_honest = 1

    def remember_server(nid):
        nonlocal next_honest
        if not nid or is_light_client(nid):
            return
        if nid in servers:
            return
        if nid in byzantine_signers:
            servers[nid] = "s4"
            return
        servers[nid] = f"s{next_honest}"
        next_honest += 1
        # Skip s4 — it's reserved for Byzantine.
        if next_honest == 4:
            next_honest = 5

    values = OrderedDict()

    def remember_value(val):
        if is_sentinel(val):
            return
        if not isinstance(val, str):
            return
        if val in values:
            return
        if val.startswith("v") and val[1:].isdigit():
            return
        if not looks_like_hash(val):
            return
        values[val] = f"v{len(values) + 1}"

    for evt in events:
        e = evt["event"]
        remember_server(e.get("nid"))

        if "msg" in e:
            msg = e["msg"]
            remember_server(msg.get("source"))
            remember_server(msg.get("dest"))
            remember_value(msg.get("value"))

        if "byzVote" in e:
            bv = e["byzVote"]
            remember_value(bv.get("value"))

        if "state" in e and isinstance(e["state"], dict):
            state = e["state"]
            remember_value(state.get("lockedValue"))
            remember_value(state.get("validValue"))

    return servers, values


def remap_value(val, values):
    if is_sentinel(val):
        return val
    return values.get(val, val)


def remap_server(s, servers):
    if not s or is_light_client(s):
        return s
    return servers.get(s, s)


def remap_event(evt, servers, values):
    e = evt["event"]
    e["nid"] = remap_server(e.get("nid"), servers)

    if "state" in e and isinstance(e["state"], dict):
        state = e["state"]
        for f in ("lockedValue", "validValue"):
            if f in state:
                state[f] = remap_value(state.get(f), values)

    if "msg" in e:
        msg = e["msg"]
        for f in ("source", "dest"):
            if f in msg:
                msg[f] = remap_server(msg.get(f), servers)
        if "value" in msg:
            msg["value"] = remap_value(msg.get("value"), values)

    if "byzVote" in e:
        bv = e["byzVote"]
        if "value" in bv:
            bv["value"] = remap_value(bv.get("value"), values)

    return evt


def main():
    if len(sys.argv) < 2:
        print("Usage: preprocess_trace.py <input.ndjson> [output.ndjson]",
              file=sys.stderr)
        sys.exit(1)

    input_path = sys.argv[1]
    output_path = sys.argv[2] if len(sys.argv) > 2 else None

    with open(input_path) as f:
        events = [json.loads(line) for line in f if line.strip()]

    servers, values = collect_ids(events)

    print(f"Server mapping: {dict(servers)}", file=sys.stderr)
    print(f"Value mapping:  {dict(values)}", file=sys.stderr)

    remapped = [remap_event(evt, servers, values) for evt in events]

    if output_path:
        with open(output_path, "w") as f:
            for evt in remapped:
                f.write(json.dumps(evt, separators=(",", ":")) + "\n")
    else:
        for evt in remapped:
            print(json.dumps(evt, separators=(",", ":")))


if __name__ == "__main__":
    main()
