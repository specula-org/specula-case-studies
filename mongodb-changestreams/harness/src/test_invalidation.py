#!/usr/bin/env python3
"""
Test scenario: Drop collection triggers invalidation event sequence.
Exercises: GenerateEvent, MergeNextNormal, GenerateInvalidatingEvent,
           MergeNextInvalidating, DeliverInvalidation

Flow:
  1. Open change stream on sharded collection
  2. Insert 1 doc on s1
  3. Read insert event
  4. Drop collection
  5. Read drop event → MergeNextInvalidating
  6. Read invalidate event → DeliverInvalidation
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
    print("=== test_invalidation ===")
    tf = trace_path("invalidation")
    client = get_mongos_client()
    col = setup_sharded_collection(client, "testdb", "testcol_inval")

    emitter = TraceEmitter(tf, SHARDS)

    # Open change stream
    cursor = col.watch(max_await_time_ms=10000)

    # Insert one document on s1
    col.insert_one({"x": 1, "data": "pre-drop"})
    time.sleep(0.3)

    # Read the insert event
    event = cursor.next()
    shard = identify_shard(event)
    print(f"  Event 1: {event['operationType']} on {shard}")
    emitter.generate_and_merge(shard, event["operationType"])

    # Drop the collection (triggers invalidation)
    client.testdb.testcol_inval.drop()
    time.sleep(0.5)

    # Read the drop event
    event = cursor.next()
    assert event["operationType"] == "drop", f"Expected drop, got {event['operationType']}"
    print(f"  Event 2: drop on s1")
    emitter.invalidate_and_merge("s1", "drop")

    # Read the synthetic invalidation event
    event = cursor.next()
    assert event["operationType"] == "invalidate", (
        f"Expected invalidate, got {event['operationType']}"
    )
    print(f"  Event 3: invalidate (synthetic)")
    emitter.emit_deliver_invalidation()

    cursor.close()
    client.close()
    emitter.close()

    n = count_trace_lines(tf)
    print(f"  Trace: {tf} ({n} events)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
