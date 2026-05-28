#!/usr/bin/env python3
"""Preprocess NDJSON trace files for TLA+ trace validation (cometbft_3).

Rewrites concrete implementation identifiers into the abstract names declared
in `spec/Trace.cfg`:

  * The local node ID (`event.nid`) is mapped to a server slot (`s1`, `s2`, …)
    in first-seen order.
  * Honest peer IDs appearing in `event.peer.id` or `event.msg.source` are also
    mapped to server slots — Trace.tla expects them to be in `Server`.
  * Peer IDs that the harness flagged Byzantine (collected from event names
    starting with `Byz`) get mapped to ByzPeer slots (`b1`, `b2`, …).
  * Block / snapshot hashes appearing in `peer.hash`, `peer.block`,
    `msg.value` are mapped to `v1`, `v2`, … with `nil`/empty preserved.

Usage:  preprocess_trace.py <input.ndjson> [output.ndjson]
"""
import json
import sys
from collections import OrderedDict


BYZ_EVENT_PREFIXES = ("Byz",)  # any event name starting with Byz tags its peer as Byzantine


def is_byz_event(event_name: str) -> bool:
    return any(event_name.startswith(p) for p in BYZ_EVENT_PREFIXES)


def first_pass(events):
    """Walk events to collect the ID/value sets and Byzantine peer set."""
    byz_peers = set()
    server_order = OrderedDict()  # candidate honest server / peer IDs
    byz_order = OrderedDict()      # confirmed Byzantine peer IDs
    value_order = OrderedDict()    # block / snapshot hashes

    def record_peer(raw_id, byz: bool):
        if raw_id in (None, "", "nil"):
            return
        if byz:
            byz_peers.add(raw_id)
            if raw_id not in byz_order:
                byz_order[raw_id] = f"b{len(byz_order) + 1}"
            # also remove from server set
            server_order.pop(raw_id, None)
        else:
            if raw_id in byz_peers:
                return
            if raw_id not in server_order:
                server_order[raw_id] = None  # placeholder; numbered in second pass

    for evt in events:
        e = evt.get("event", {})
        name = e.get("name", "")
        nid = e.get("nid")
        record_peer(nid, byz=False)  # the local node is always honest

        byz = is_byz_event(name)

        peer = e.get("peer") or {}
        if "id" in peer:
            record_peer(peer["id"], byz=byz)

        msg = e.get("msg") or {}
        if "source" in msg:
            record_peer(msg["source"], byz=byz)
        if "dest" in msg:
            record_peer(msg["dest"], byz=False)

        # values
        for path in (("peer", "hash"), ("peer", "block"), ("msg", "value")):
            container = peer if path[0] == "peer" else msg
            v = container.get(path[1])
            if v in (None, "", "nil", "null"):
                continue
            if isinstance(v, str) and v not in value_order:
                # treat "block" tag as a placeholder if it's the literal "block"
                if v == "block":
                    continue
                value_order[v] = f"v{len(value_order) + 1}"

    # Number the server slots in stable order.
    servers = OrderedDict()
    for raw in server_order:
        servers[raw] = f"s{len(servers) + 1}"

    return servers, dict(byz_order), value_order


def remap(events, servers, byz, values):
    def map_id(raw):
        if raw in (None, "", "nil"):
            return raw
        if raw in byz:
            return byz[raw]
        if raw in servers:
            return servers[raw]
        return raw

    def map_val(v):
        if v in (None, "", "nil", "null"):
            return v
        return values.get(v, v)

    for evt in events:
        e = evt.get("event", {})
        if "nid" in e:
            e["nid"] = map_id(e["nid"])

        peer = e.get("peer")
        if peer:
            if "id" in peer:
                peer["id"] = map_id(peer["id"])
            for k in ("hash", "block"):
                if k in peer:
                    peer[k] = map_val(peer[k])

        msg = e.get("msg")
        if msg:
            for k in ("source", "dest", "validator"):
                if k in msg:
                    msg[k] = map_id(msg[k])
            if "value" in msg:
                msg["value"] = map_val(msg["value"])

    return events


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        sys.exit(1)

    in_path = sys.argv[1]
    out_path = sys.argv[2] if len(sys.argv) > 2 else None

    with open(in_path) as f:
        events = [json.loads(line) for line in f if line.strip()]

    if not events:
        print("(empty trace, nothing to remap)", file=sys.stderr)
        if out_path:
            open(out_path, "w").close()
        return

    servers, byz, values = first_pass(events)
    print(f"Server mapping ({len(servers)}): {dict(servers)}", file=sys.stderr)
    print(f"Byz mapping ({len(byz)}): {byz}", file=sys.stderr)
    print(f"Value mapping ({len(values)}): {dict(values)}", file=sys.stderr)

    remapped = remap(events, servers, byz, values)

    out = open(out_path, "w") if out_path else sys.stdout
    try:
        for evt in remapped:
            out.write(json.dumps(evt, separators=(",", ":")) + "\n")
    finally:
        if out_path:
            out.close()


if __name__ == "__main__":
    main()
