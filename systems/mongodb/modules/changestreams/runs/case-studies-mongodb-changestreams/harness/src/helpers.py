"""
Shared helpers for MongoDB change streams trace harness.
"""

import os
import sys
import time
import pymongo


# Shard key split point: x < SPLIT maps to shard1RS (s1), x >= SPLIT maps to shard2RS (s2)
SPLIT_POINT = 1000
MONGOS_URI = os.environ.get("MONGOS_URI", "mongodb://localhost:27117")
TRACE_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "traces")

# TLA+ shard identifiers
SHARD_MAP = {"shard1RS": "s1", "shard2RS": "s2"}
SHARDS = ["s1", "s2"]


def get_mongos_client():
    """Connect to mongos router."""
    client = pymongo.MongoClient(MONGOS_URI, serverSelectionTimeoutMS=30000)
    # Verify connection
    client.admin.command("ping")
    return client


def setup_sharded_collection(client, db_name, col_name):
    """Create a sharded collection with chunks on both shards.

    Shard key: {x: 1}, ranged.
    Chunk split at x = SPLIT_POINT.
    shard1RS gets [-inf, SPLIT_POINT), shard2RS gets [SPLIT_POINT, +inf).
    """
    ns = f"{db_name}.{col_name}"
    admin = client.admin
    db = client[db_name]

    # Drop existing collection for clean state
    db[col_name].drop()
    time.sleep(0.5)

    # Shard the collection
    try:
        admin.command("shardCollection", ns, key={"x": 1})
    except pymongo.errors.OperationFailure as e:
        if "already sharded" not in str(e).lower():
            raise
    time.sleep(0.5)

    # Split at the boundary
    try:
        admin.command("split", ns, middle={"x": SPLIT_POINT})
    except pymongo.errors.OperationFailure:
        pass  # Already split
    time.sleep(0.5)

    # Move chunks to correct shards (ignore if already there)
    for find_doc, to_shard in [
        ({"x": 0}, "shard1RS"),
        ({"x": SPLIT_POINT}, "shard2RS"),
    ]:
        try:
            admin.command("moveChunk", ns, find=find_doc, to=to_shard)
        except pymongo.errors.OperationFailure:
            pass

    time.sleep(1)
    print(f"  Sharded collection {ns} ready (split at x={SPLIT_POINT})")
    return db[col_name]


def identify_shard(event):
    """Determine TLA+ shard ID from a change stream event.

    Uses the shard key value for CRUD ops.
    For DDL ops (drop, rename), attributes to s1 (primary shard).
    """
    op = event["operationType"]
    if op in ("insert", "update", "delete", "replace"):
        doc_key = event.get("documentKey", {})
        x = doc_key.get("x", 0)
        return "s1" if x < SPLIT_POINT else "s2"
    elif op in ("drop", "rename"):
        return "s1"  # Primary shard for DB
    elif op == "invalidate":
        return None  # Synthetic event, no shard
    return "s1"


def trace_path(scenario_name):
    """Return the trace file path for a scenario."""
    os.makedirs(TRACE_DIR, exist_ok=True)
    return os.path.join(TRACE_DIR, f"{scenario_name}.ndjson")


def count_trace_lines(path):
    """Count lines in a trace file."""
    with open(path) as f:
        return sum(1 for _ in f)
