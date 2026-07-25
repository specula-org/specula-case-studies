#!/usr/bin/env python3
"""Compress real digests and timestamps in a Mysticeti trace to small spec integers.

The harness emits NDJSON traces where:
  * BlockDigest is a u64 (first 8 bytes of the 32-byte digest).
  * BlockTimestampMs is a u64 in milliseconds.

The TLA+ spec uses:
  * digest in 1..MaxDigest (typically 2 to allow equivocation).
  * timestamp in 0..MaxTimestamp (typically 5).

This script rewrites a trace file in place so digests and timestamps are
remappable to the spec's domain. Mapping rules:
  * For each (author, round) slot, the first u64 digest seen becomes 1,
    the second becomes 2 (Byzantine equivocation), etc. — capped at
    MaxDigest. The mapping is applied to every BlockRef occurrence
    (top-level block, ancestors, leader, anchor, commitRef).
  * Timestamps are sorted globally; each unique value receives a rank in
    1..MaxTimestamp (preserving order). Values beyond MaxTimestamp are
    truncated to MaxTimestamp.

Usage: preprocess_trace.py <input.ndjson> <output.ndjson>
"""

import json
import sys
from collections import defaultdict

MAX_DIGEST = 2
MAX_TIMESTAMP = 5

def remap_digests_and_timestamps(events):
    # Pass 1: collect (author, round, raw_digest) tuples for every BlockRef
    # that appears anywhere in the trace.
    slot_digests: dict = defaultdict(list)  # (author, round) -> [digest_u64, ...] in first-seen order
    timestamps: set = set()

    def walk_block_refs(node, visit):
        """Recursively visit every dict that looks like a BlockRef (has
        author + round + digest)."""
        if isinstance(node, dict):
            if {"author", "round", "digest"}.issubset(node.keys()):
                visit(node)
            for v in node.values():
                walk_block_refs(v, visit)
        elif isinstance(node, list):
            for v in node:
                walk_block_refs(v, visit)

    def collect(ref):
        key = (ref["author"], int(ref["round"]))
        d = int(ref["digest"])
        if d not in slot_digests[key]:
            slot_digests[key].append(d)

    for ev in events:
        walk_block_refs(ev, collect)
        # Timestamps live on full Block records.
        def collect_ts(node):
            if isinstance(node, dict):
                if "timestamp" in node and isinstance(node["timestamp"], int):
                    timestamps.add(int(node["timestamp"]))
                for v in node.values():
                    collect_ts(v)
            elif isinstance(node, list):
                for v in node:
                    collect_ts(v)
        collect_ts(ev)

    # Build digest mapping: slot -> {raw -> remapped}.
    digest_map: dict = {}
    for slot, raws in slot_digests.items():
        digest_map[slot] = {raw: min(idx + 1, MAX_DIGEST) for idx, raw in enumerate(raws)}

    # Build timestamp mapping: sorted unique values get ranks 1..MAX_TIMESTAMP.
    sorted_ts = sorted(timestamps)
    ts_map: dict = {}
    if sorted_ts:
        n = len(sorted_ts)
        for i, t in enumerate(sorted_ts):
            # Map first value to 1, last value to MAX_TIMESTAMP (or fewer if n < MAX_TIMESTAMP).
            if n == 1:
                ts_map[t] = 1
            else:
                rank = 1 + (i * (MAX_TIMESTAMP - 1)) // (n - 1)
                ts_map[t] = min(rank, MAX_TIMESTAMP)
    # Genesis timestamp is always 0 in the spec; map raw 0 -> 0.
    ts_map[0] = 0

    # Pass 2: rewrite every BlockRef and timestamp in place.
    def rewrite(node):
        if isinstance(node, dict):
            if {"author", "round", "digest"}.issubset(node.keys()):
                key = (node["author"], int(node["round"]))
                d = int(node["digest"])
                node["digest"] = digest_map[key][d]
            if "timestamp" in node and isinstance(node["timestamp"], int):
                node["timestamp"] = ts_map.get(node["timestamp"], 0)
            for v in node.values():
                rewrite(v)
        elif isinstance(node, list):
            for v in node:
                rewrite(v)

    for ev in events:
        rewrite(ev)
    return events


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    in_path, out_path = sys.argv[1], sys.argv[2]
    with open(in_path, "r") as f:
        events = [json.loads(line) for line in f if line.strip()]
    events = remap_digests_and_timestamps(events)
    with open(out_path, "w") as f:
        for ev in events:
            f.write(json.dumps(ev, separators=(",", ":")) + "\n")
    print(f"[preprocess] {in_path} -> {out_path}: {len(events)} events", file=sys.stderr)


if __name__ == "__main__":
    main()
