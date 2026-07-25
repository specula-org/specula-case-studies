#!/usr/bin/env python3
"""
Test scenarios for MongoDB v3 trace collection.

Exercises transaction router decision logic against a real MongoDB sharded cluster.
4 scenarios covering the commit type selection paths modeled by the v3 spec:
  1. basic_2pc_commit   — cross-shard writes → CT_2pc
  2. single_shard       — single shard write → CT_single + DirectCommit
  3. read_only          — cross-shard reads → CT_readOnly + DirectCommit
  4. sws_commit         — 1 read + 1 write shard → CT_sws

Server-side coordinator events are captured from MongoDB LOGV2 logs by parse_logs.py.

Usage:
    MONGOS_URI=mongodb://localhost:27017 TRACE_DIR=../traces python3 test_scenarios.py
"""

import os
import sys
import time
import json

import pymongo
from pymongo import MongoClient
from pymongo.read_concern import ReadConcern
from pymongo.write_concern import WriteConcern

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from trace_emitter import TraceEmitter, map_shard, infer_commit_type


def find_keys_on_different_shards(client, db_name="testdb", coll_name="items", count=2):
    """Find keys that hash to different shards. Returns list of (key, tla_shard_id) tuples."""
    db = client[db_name]
    coll = db[coll_name]

    shard_keys = {}  # tla_shard_id -> key
    for doc in coll.find().limit(200):
        key = doc["_id"]
        explain = db.command(
            "explain",
            {"find": coll_name, "filter": {"_id": key}},
            verbosity="queryPlanner",
        )
        shard_name = _extract_shard(explain)
        if shard_name is None:
            continue
        tla_id = map_shard(shard_name)
        if tla_id not in shard_keys:
            shard_keys[tla_id] = key
        if len(shard_keys) >= count:
            break

    if len(shard_keys) < count:
        raise RuntimeError(
            f"Could not find keys on {count} different shards. Found: {shard_keys}"
        )

    result = [(v, k) for k, v in sorted(shard_keys.items())]
    return result


def _extract_shard(explain):
    """Extract shard name from explain output."""
    qp = explain.get("queryPlanner", explain)
    wp = qp.get("winningPlan", {})
    shards = wp.get("shards", [])
    if shards:
        return shards[0].get("shardName")
    if "shardName" in qp:
        return qp["shardName"]
    if "shardName" in wp.get("queryPlan", {}):
        return wp["queryPlan"]["shardName"]
    return None


def find_key_on_shard(client, target_tla_shard, db_name="testdb", coll_name="items"):
    """Find a single key on the specified shard."""
    db = client[db_name]
    coll = db[coll_name]
    for doc in coll.find().limit(200):
        key = doc["_id"]
        explain = db.command(
            "explain",
            {"find": coll_name, "filter": {"_id": key}},
            verbosity="queryPlanner",
        )
        shard_name = _extract_shard(explain)
        if shard_name and map_shard(shard_name) == target_tla_shard:
            return key
    raise RuntimeError(f"No key found on shard {target_tla_shard}")


# =============================================================================
# Scenario 1: Cross-shard 2PC commit (CT_2pc)
# Both shards are write participants → router selects 2PC.
# =============================================================================

def scenario_basic_2pc_commit(client, emitter, trace_dir):
    print("  Running scenario: basic_2pc_commit")
    db = client["testdb"]
    coll = db.get_collection(
        "items",
        read_concern=ReadConcern("snapshot"),
        write_concern=WriteConcern("majority"),
    )

    keys = find_keys_on_different_shards(client)
    key1, shard1 = keys[0]
    key2, shard2 = keys[1]
    participants = {shard1: "PK_wr", shard2: "PK_wr"}
    commit_type = infer_commit_type(participants)
    print(f"    Key {key1} on {shard1}, key {key2} on {shard2} -> {commit_type}")

    with client.start_session() as session:
        session.start_transaction(
            read_concern=ReadConcern("snapshot"),
            write_concern=WriteConcern("majority"),
        )
        txn_id = emitter.register_txn(session)

        # Emit RouterStartTxn
        emitter.router_start_txn(txn_id, participants)

        # Write to both shards (both become PK_wr)
        coll.update_one({"_id": key1}, {"$set": {"v": f"2pc_{txn_id}_1"}}, session=session)
        coll.update_one({"_id": key2}, {"$set": {"v": f"2pc_{txn_id}_2"}}, session=session)

        # Emit RouterCommitTxn (commit type selected)
        emitter.router_commit_txn(txn_id, commit_type)

        # Commit — triggers 2PC via coordinator
        session.commit_transaction()

        # After 2PC completes, router receives result
        # Server-side events (CoordDecide*, CoordPersistAndSend,
        # CoordSendDecisionToShard, CoordFinish) come from LOGV2 logs.
        emitter.router_receive_2pc_result(txn_id, "RP_done")

    print(f"    Committed 2PC txn {txn_id}")

    return {
        "name": "basic_2pc_commit",
        "txn_id": txn_id,
        "participants": participants,
        "commit_type": commit_type,
        "session_meta": emitter.get_session_meta(),
    }


# =============================================================================
# Scenario 2: Single-shard commit (CT_single)
# Only 1 shard → router sends commit directly, no coordinator.
# =============================================================================

def scenario_single_shard(client, emitter, trace_dir):
    print("  Running scenario: single_shard")
    db = client["testdb"]
    coll = db.get_collection(
        "items",
        read_concern=ReadConcern("snapshot"),
        write_concern=WriteConcern("majority"),
    )

    key = find_key_on_shard(client, "s1")
    participants = {"s1": "PK_wr"}
    commit_type = infer_commit_type(participants)
    print(f"    Key {key} on s1 -> {commit_type}")

    with client.start_session() as session:
        session.start_transaction(
            read_concern=ReadConcern("snapshot"),
            write_concern=WriteConcern("majority"),
        )
        txn_id = emitter.register_txn(session)

        emitter.router_start_txn(txn_id, participants)

        coll.update_one({"_id": key}, {"$set": {"v": f"single_{txn_id}"}}, session=session)

        emitter.router_commit_txn(txn_id, commit_type)

        session.commit_transaction()

        # Single shard: direct commit, no coordinator
        emitter.direct_commit(txn_id)

    print(f"    Committed single-shard txn {txn_id}")

    return {
        "name": "single_shard",
        "txn_id": txn_id,
        "participants": participants,
        "commit_type": commit_type,
        "session_meta": emitter.get_session_meta(),
    }


# =============================================================================
# Scenario 3: Read-only commit (CT_readOnly)
# Cross-shard but only reads → router sends commit directly to all.
# =============================================================================

def scenario_read_only(client, emitter, trace_dir):
    print("  Running scenario: read_only")
    db = client["testdb"]
    coll = db.get_collection(
        "items",
        read_concern=ReadConcern("snapshot"),
        write_concern=WriteConcern("majority"),
    )

    keys = find_keys_on_different_shards(client)
    key1, shard1 = keys[0]
    key2, shard2 = keys[1]
    participants = {shard1: "PK_ro", shard2: "PK_ro"}
    commit_type = infer_commit_type(participants)
    print(f"    Key {key1} on {shard1}, key {key2} on {shard2} -> {commit_type}")

    with client.start_session() as session:
        session.start_transaction(
            read_concern=ReadConcern("snapshot"),
            write_concern=WriteConcern("majority"),
        )
        txn_id = emitter.register_txn(session)

        emitter.router_start_txn(txn_id, participants)

        # Read-only operations on both shards
        coll.find_one({"_id": key1}, session=session)
        coll.find_one({"_id": key2}, session=session)

        emitter.router_commit_txn(txn_id, commit_type)

        session.commit_transaction()

        # Read-only: direct commit to all shards
        emitter.direct_commit(txn_id)

    print(f"    Committed read-only txn {txn_id}")

    return {
        "name": "read_only",
        "txn_id": txn_id,
        "participants": participants,
        "commit_type": commit_type,
        "session_meta": emitter.get_session_meta(),
    }


# =============================================================================
# Scenario 4: Single-write-shard commit (CT_sws)
# 1 read-only shard + 1 write shard → SWS optimization path.
# Router commits read-only shards first, then write shard.
# =============================================================================

def scenario_sws_commit(client, emitter, trace_dir):
    print("  Running scenario: sws_commit")
    db = client["testdb"]
    coll = db.get_collection(
        "items",
        read_concern=ReadConcern("snapshot"),
        write_concern=WriteConcern("majority"),
    )

    keys = find_keys_on_different_shards(client)
    key1, shard1 = keys[0]
    key2, shard2 = keys[1]
    # shard1 = read-only, shard2 = write
    participants = {shard1: "PK_ro", shard2: "PK_wr"}
    commit_type = infer_commit_type(participants)
    print(f"    Key {key1} on {shard1} (ro), key {key2} on {shard2} (wr) -> {commit_type}")

    with client.start_session() as session:
        session.start_transaction(
            read_concern=ReadConcern("snapshot"),
            write_concern=WriteConcern("majority"),
        )
        txn_id = emitter.register_txn(session)

        emitter.router_start_txn(txn_id, participants)

        # Read from shard1 (read-only participant)
        coll.find_one({"_id": key1}, session=session)

        # Write to shard2 (write participant)
        coll.update_one({"_id": key2}, {"$set": {"v": f"sws_{txn_id}"}}, session=session)

        emitter.router_commit_txn(txn_id, commit_type)

        session.commit_transaction()

        # SWS: read-only shards committed first, then write shard
        emitter.sws_commit_read_only(txn_id)
        emitter.sws_commit_write(txn_id)

    print(f"    Committed SWS txn {txn_id}")

    return {
        "name": "sws_commit",
        "txn_id": txn_id,
        "participants": participants,
        "commit_type": commit_type,
        "session_meta": emitter.get_session_meta(),
    }


# =============================================================================
# Main
# =============================================================================

def main():
    mongos_uri = os.environ.get("MONGOS_URI", "mongodb://localhost:27017")
    trace_dir = os.environ.get("TRACE_DIR", os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "..", "traces"
    ))
    os.makedirs(trace_dir, exist_ok=True)

    print(f"Connecting to {mongos_uri}")
    client = MongoClient(mongos_uri, directConnection=False)

    status = client.admin.command("serverStatus")
    print(f"Connected to MongoDB {status.get('version', 'unknown')}")

    scenarios = []
    prev_emitter = None

    scenario_funcs = [
        ("basic_2pc_commit", scenario_basic_2pc_commit),
        ("single_shard", scenario_single_shard),
        ("read_only", scenario_read_only),
        ("sws_commit", scenario_sws_commit),
    ]

    for name, func in scenario_funcs:
        emitter = TraceEmitter(os.path.join(trace_dir, f"{name}_client.ndjson"))
        # Carry forward txn counter and session metadata across scenarios
        if prev_emitter:
            emitter._txn_counter = prev_emitter._txn_counter
            emitter._txn_map = dict(prev_emitter._txn_map)
            emitter._session_meta = dict(prev_emitter._session_meta)
        try:
            result = func(client, emitter, trace_dir)
            scenarios.append(result)
        finally:
            emitter.close()
        prev_emitter = emitter
        time.sleep(1)  # Let server logs flush

    # Write scenario metadata for parse_logs.py
    meta_path = os.path.join(trace_dir, "scenario_meta.json")
    with open(meta_path, "w") as f:
        json.dump(scenarios, f, indent=2)
    print(f"\nScenario metadata written to {meta_path}")

    client.close()
    print("Test scenarios complete.")


if __name__ == "__main__":
    main()
