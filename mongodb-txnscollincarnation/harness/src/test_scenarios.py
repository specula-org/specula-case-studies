#!/usr/bin/env python3
"""
Test scenarios for MongoDB TxnsCollectionIncarnation trace collection.

Drives DDL operations and transactions against a sharded cluster, emitting
client-side trace events for router/shard actions. DDL phase transitions
are captured from server logs by parse_logs.py.

Each scenario writes a "_client.ndjson" file with client-side events.
parse_logs.py later merges these with server-side DDL events to produce
the final trace file.
"""

import json
import os
import sys
import time
from datetime import datetime, timezone
from pymongo import MongoClient
from pymongo.read_concern import ReadConcern
from pymongo.write_concern import WriteConcern
from pymongo.errors import OperationFailure


MONGOS_URI = os.environ.get("MONGOS_URI", "mongodb://localhost:27217")
TRACE_DIR = os.environ.get("TRACE_DIR",
    os.path.join(os.path.dirname(__file__), "..", "..", "traces"))


class TraceEmitter:
    """Emits client-side trace events as NDJSON matching Trace.tla format."""

    def __init__(self, filepath):
        os.makedirs(os.path.dirname(filepath), exist_ok=True)
        self.fp = open(filepath, "w")
        self.events = []

    def close(self):
        self.fp.flush()
        self.fp.close()

    def _ts(self):
        return datetime.now(timezone.utc).isoformat()

    def emit(self, event_name, **fields):
        """Emit a trace event. Fields are top-level in the JSON object."""
        entry = {"event": event_name, "ts": self._ts()}
        entry.update(fields)
        self.events.append(entry)
        self.fp.write(json.dumps(entry, separators=(",", ":")) + "\n")
        self.fp.flush()

    def emit_meta(self, **fields):
        """Emit a metadata line (for parse_logs.py to use)."""
        entry = {"_meta": True}
        entry.update(fields)
        self.fp.write(json.dumps(entry, separators=(",", ":")) + "\n")
        self.fp.flush()

    def emit_timestamp_marker(self, label):
        """Emit a timestamp marker for log window filtering."""
        entry = {"_marker": label, "ts": self._ts()}
        self.fp.write(json.dumps(entry, separators=(",", ":")) + "\n")
        self.fp.flush()


def find_keys_on_same_shard(client, db_name, coll_name, target_shard, count=2):
    """Find keys that live on target_shard via explain."""
    db = client.get_database(db_name)
    found = []
    for i in range(200):
        key = f"key{i}"
        try:
            explain = db.command(
                "explain",
                {"find": coll_name, "filter": {"_id": key}},
                verbosity="queryPlanner"
            )
            plan = explain.get("queryPlanner", {}).get("winningPlan", {})
            shards = plan.get("shards", [])
            if shards:
                shard = shards[0].get("shardName", "")
            else:
                shard = plan.get("shardName", "")

            if shard == target_shard:
                found.append(key)
                if len(found) >= count:
                    return found
        except Exception:
            continue
    raise RuntimeError(f"Could not find {count} keys on {target_shard}")


def get_primary_shard(client, db_name):
    """Get the primary shard for a database."""
    db_info = client.get_database("config").databases.find_one({"_id": db_name})
    if db_info:
        return db_info.get("primary", "unknown")
    return "unknown"


def scenario_basic_create_txn(client, trace_dir):
    """
    Scenario: Create tracked collection → 2-statement transaction → drop.

    Exercises:
      DDL: CreateTrackedAcquireLock, CreateTrackedEnterCS,
           CreateTrackedCommitMetadata, CreateTrackedExitCS
      Txn: RouterSendTxnStmt (×2), ShardResponse (×2),
           RouterHandleOK (×2), RouterSendCommit
      DDL: DropAcquireLock, DropEnterCS, DropCommitMetadata, DropExitCS
    """
    print("\n=== Scenario: basic_create_txn ===")
    emitter = TraceEmitter(os.path.join(trace_dir, "basic_create_txn_client.ndjson"))
    ns = "test.coll1"
    txn_label = "txn0"
    db_name, coll_name = ns.split(".", 1)

    try:
        db = client.get_database(db_name)

        # Phase 1: Create tracked (sharded) collection
        emitter.emit_timestamp_marker("pre_create")
        time.sleep(0.5)

        print("  Creating sharded collection test.coll1...")
        try:
            client.admin.command("enableSharding", db_name)
        except OperationFailure:
            pass  # Already enabled
        client.admin.command("shardCollection", ns, key={"_id": "hashed"})
        time.sleep(1)

        emitter.emit_timestamp_marker("post_create")

        # Phase 2: Seed data so we can find keys on a specific shard
        print("  Seeding data...")
        docs = [{"_id": f"key{i}", "value": f"init{i}"} for i in range(100)]
        db[coll_name].insert_many(docs)
        time.sleep(0.5)

        # Find the primary shard for the database
        primary_shard = get_primary_shard(client, db_name)
        print(f"  Primary shard: {primary_shard}")

        # Find 2 keys on the primary shard (so all txn traffic goes to 1 shard)
        keys = find_keys_on_same_shard(client, db_name, coll_name, primary_shard, 2)
        print(f"  Keys on {primary_shard}: {keys}")

        # Phase 3: Run 2-statement transaction
        print("  Running transaction...")
        with client.start_session() as session:
            session.start_transaction(
                read_concern=ReadConcern("majority"),
                write_concern=WriteConcern("majority")
            )

            # Statement 1
            emitter.emit("RouterSendTxnStmt", txn=txn_label, ns=ns)
            db[coll_name].update_one(
                {"_id": keys[0]},
                {"$set": {"value": "updated_stmt1"}},
                session=session
            )
            emitter.emit("ShardResponse", shard=primary_shard, txn=txn_label,
                         responseStatus="ok")
            emitter.emit("RouterHandleOK", txn=txn_label, stmt=1)
            print(f"    Stmt 1: updated {keys[0]} on {primary_shard}")

            # Statement 2
            emitter.emit("RouterSendTxnStmt", txn=txn_label, ns=ns)
            db[coll_name].update_one(
                {"_id": keys[1]},
                {"$set": {"value": "updated_stmt2"}},
                session=session
            )
            emitter.emit("ShardResponse", shard=primary_shard, txn=txn_label,
                         responseStatus="ok")
            emitter.emit("RouterHandleOK", txn=txn_label, stmt=2)
            print(f"    Stmt 2: updated {keys[1]} on {primary_shard}")

            # Commit
            emitter.emit("RouterSendCommit", txn=txn_label)
            session.commit_transaction()
            print("    Transaction committed")

        time.sleep(1)

        # Phase 4: Drop collection
        emitter.emit_timestamp_marker("pre_drop")
        time.sleep(0.5)

        print("  Dropping collection test.coll1...")
        db[coll_name].drop()
        time.sleep(1)

        emitter.emit_timestamp_marker("post_drop")

    except Exception as e:
        print(f"  ERROR: {e}")
        import traceback
        traceback.print_exc()
        raise
    finally:
        emitter.close()

    return primary_shard


def scenario_move_primary_txn(client, trace_dir):
    """
    Scenario: Create collection → movePrimary → transaction with stale detection.

    Exercises:
      DDL: CreateTracked phases
      DDL: MovePrimaryAcquireLock, MovePrimaryEnterCS,
           MovePrimaryCommitMetadata, MovePrimaryExitCS
      Txn: RouterSendTxnStmt, ShardResponse, RouterHandleOK, RouterSendCommit
    """
    print("\n=== Scenario: move_primary_txn ===")
    emitter = TraceEmitter(os.path.join(trace_dir, "move_primary_txn_client.ndjson"))
    ns = "test2.coll2"
    txn_label = "txn0"
    db_name, coll_name = ns.split(".", 1)

    try:
        db = client.get_database(db_name)

        # Phase 1: Create untracked collection on default primary shard
        emitter.emit_timestamp_marker("pre_create")
        time.sleep(0.5)

        print("  Creating collection test2.coll2...")
        db.create_collection(coll_name)
        time.sleep(1)

        emitter.emit_timestamp_marker("post_create")

        # Seed data
        docs = [{"_id": f"key{i}", "value": f"init{i}"} for i in range(10)]
        db[coll_name].insert_many(docs)
        time.sleep(0.5)

        # Determine primary shard and target shard
        primary_shard = get_primary_shard(client, db_name)
        target_shard = "shard0001" if primary_shard == "shard0000" else "shard0000"
        print(f"  Primary shard: {primary_shard}, moving to: {target_shard}")

        # Phase 2: MovePrimary
        emitter.emit_timestamp_marker("pre_move_primary")
        time.sleep(0.5)

        print(f"  Moving primary to {target_shard}...")
        client.admin.command("movePrimary", db_name, to=target_shard)
        time.sleep(1)

        emitter.emit_timestamp_marker("post_move_primary")

        # Phase 3: Run transaction against new primary
        print("  Running transaction after movePrimary...")
        with client.start_session() as session:
            session.start_transaction(
                read_concern=ReadConcern("majority"),
                write_concern=WriteConcern("majority")
            )

            emitter.emit("RouterSendTxnStmt", txn=txn_label, ns=ns)
            db[coll_name].update_one(
                {"_id": "key0"},
                {"$set": {"value": "updated_after_move_stmt1"}},
                session=session
            )
            emitter.emit("ShardResponse", shard=target_shard, txn=txn_label,
                         responseStatus="ok")
            emitter.emit("RouterHandleOK", txn=txn_label, stmt=1)
            print(f"    Stmt 1: updated key0 on {target_shard}")

            emitter.emit("RouterSendTxnStmt", txn=txn_label, ns=ns)
            db[coll_name].update_one(
                {"_id": "key1"},
                {"$set": {"value": "updated_after_move_stmt2"}},
                session=session
            )
            emitter.emit("ShardResponse", shard=target_shard, txn=txn_label,
                         responseStatus="ok")
            emitter.emit("RouterHandleOK", txn=txn_label, stmt=2)
            print(f"    Stmt 2: updated key1 on {target_shard}")

            emitter.emit("RouterSendCommit", txn=txn_label)
            session.commit_transaction()
            print("    Transaction committed")

    except Exception as e:
        print(f"  ERROR: {e}")
        import traceback
        traceback.print_exc()
        raise
    finally:
        emitter.close()


def run_all_scenarios():
    print(f"Connecting to {MONGOS_URI}...")
    client = MongoClient(MONGOS_URI, directConnection=False)

    status = client.admin.command("serverStatus")
    print(f"Connected to MongoDB {status.get('version', 'unknown')}")

    os.makedirs(TRACE_DIR, exist_ok=True)

    # Clean any leftover collections
    for db_name in ["test", "test2"]:
        try:
            client.drop_database(db_name)
        except Exception:
            pass
    time.sleep(1)

    scenario_basic_create_txn(client, TRACE_DIR)
    scenario_move_primary_txn(client, TRACE_DIR)

    client.close()
    print("\nAll scenarios completed.")


if __name__ == "__main__":
    run_all_scenarios()
