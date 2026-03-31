#!/usr/bin/env python3
"""
Test scenario: Resume change stream from a previously saved token.
Exercises: GenerateEvent, MergeNextNormal, InitiateResume

Flow:
  1. Open change stream on sharded collection
  2. Insert 2 docs on s1
  3. Read 1 event, save resume token
  4. Close change stream
  5. Open new change stream with resumeAfter
  6. Read remaining event

Trace structure:
  GenerateEvent(s1) x2 → AdvanceShardClock(s2) x3 → MergeNextNormal
  → InitiateResume → MergeNextNormal

The second MergeNextNormal consumes an already-generated event (no new
GenerateEvent needed, the spec already has it in shardEvents).
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
    print("=== test_resume ===")
    tf = trace_path("resume")
    client = get_mongos_client()
    col = setup_sharded_collection(client, "testdb", "testcol_resume")

    emitter = TraceEmitter(tf, SHARDS)

    # Open change stream
    cursor = col.watch(max_await_time_ms=10000)

    # Insert 2 docs on s1 (same shard for simplicity)
    col.insert_one({"x": 1, "data": "doc1"})
    time.sleep(0.2)
    col.insert_one({"x": 2, "data": "doc2"})
    time.sleep(0.3)

    # Generate both events in the trace (both exist on shard before any merge)
    emitter.emit_generate_event("s1", "insert")
    emitter.emit_generate_event("s1", "insert")

    # Advance s2 past s1's max clock so MergeNextNormal can pick s1
    emitter.ensure_shard_clock("s2", emitter.spec_clocks["s1"] + 1)

    # Read first event and save resume token
    event1 = cursor.next()
    resume_token = event1["_id"]
    shard1 = identify_shard(event1)
    print(f"  Event 1: {event1['operationType']} on {shard1} (saved token)")
    emitter.emit_merge_normal(event1["operationType"])

    cursor.close()

    # Resume from saved token
    print(f"  Resuming from token...")
    emitter.emit_initiate_resume()

    cursor2 = col.watch(resume_after=resume_token, max_await_time_ms=10000)

    # Read the remaining event (no new GenerateEvent needed)
    event2 = cursor2.next()
    shard2 = identify_shard(event2)
    print(f"  Event 2: {event2['operationType']} on {shard2} (after resume)")
    emitter.emit_merge_normal(event2["operationType"])

    cursor2.close()
    client.close()
    emitter.close()

    n = count_trace_lines(tf)
    print(f"  Trace: {tf} ({n} events)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
