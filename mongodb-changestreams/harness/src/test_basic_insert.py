#!/usr/bin/env python3
"""
Test scenario: Basic inserts across 2 shards, observed via change stream.
Exercises: GenerateEvent, AdvanceShardClock, MergeNextNormal

Flow:
  1. Open change stream on sharded collection
  2. Insert 3 docs: x=1 (s1), x=1001 (s2), x=2 (s1)
  3. Read 3 events from change stream in merge order
  4. Emit trace: GenerateEvent + AdvanceShardClock + MergeNextNormal per event
"""

import sys
import os
import time

sys.path.insert(0, os.path.dirname(__file__))
from trace_emitter import TraceEmitter
from helpers import (
    get_mongos_client,
    setup_sharded_collection,
    identify_shard,
    trace_path,
    count_trace_lines,
    SHARDS,
)


def main():
    print("=== test_basic_insert ===")
    tf = trace_path("basic_insert")
    client = get_mongos_client()
    col = setup_sharded_collection(client, "testdb", "testcol_basic")

    emitter = TraceEmitter(tf, SHARDS)

    # Open change stream BEFORE inserts
    cursor = col.watch(max_await_time_ms=10000)

    # Insert documents targeting different shards
    docs = [
        {"x": 1, "data": "doc1"},  # → s1
        {"x": 1001, "data": "doc2"},  # → s2
        {"x": 2, "data": "doc3"},  # → s1
    ]

    for doc in docs:
        col.insert_one(doc)
        time.sleep(0.2)  # Ensure distinct clusterTimes

    # Read events from change stream in merge order
    for i in range(len(docs)):
        event = cursor.next()
        shard = identify_shard(event)
        op_type = event["operationType"]
        emitter.generate_and_merge(shard, op_type)
        x_val = event.get("documentKey", {}).get("x", "?")
        print(f"  Event {i+1}: {op_type} on {shard} (x={x_val})")

    cursor.close()
    client.close()
    emitter.close()

    n = count_trace_lines(tf)
    print(f"  Trace: {tf} ({n} events)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
