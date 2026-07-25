#!/usr/bin/env python3
"""
Test scenarios that exercise MongoDB cross-shard transactions.
Each scenario runs real transactions against a sharded cluster and
emits client-side trace events. Server-side events come from mongod logs.
"""

import json
import os
import sys
import time
from pymongo import MongoClient, ReadPreference
from pymongo.read_concern import ReadConcern
from pymongo.write_concern import WriteConcern
from pymongo.errors import OperationFailure, WriteConcernError


MONGOS_URI = os.environ.get("MONGOS_URI", "mongodb://localhost:27017")
TRACE_DIR = os.environ.get("TRACE_DIR", os.path.join(os.path.dirname(__file__), "..", "..", "traces"))

# Global shard name mapping — must match parse_logs.py
GLOBAL_SHARD_MAP = {"shard1RS": "s1", "shard2RS": "s2"}


class TraceEmitter:
    """Emits client-side (router-level) trace events as NDJSON."""

    def __init__(self, filepath):
        os.makedirs(os.path.dirname(filepath), exist_ok=True)
        self.fp = open(filepath, "w")
        self.tid_counter = 0
        self.tid_map = {}  # lsid+txnNumber -> "t1", "t2", ...
        self.shard_map = dict(GLOBAL_SHARD_MAP)  # Use global mapping
        self.router_id = "r1"

    def close(self):
        self.fp.flush()
        self.fp.close()

    def _get_tid(self, session):
        """Map a pymongo session to a TLA+ transaction ID."""
        lsid = str(session.session_id["id"])
        txn_num = session._server_session._transaction_id if hasattr(session._server_session, '_transaction_id') else 0
        key = f"{lsid}:{txn_num}"
        if key not in self.tid_map:
            self.tid_counter += 1
            self.tid_map[key] = f"t{self.tid_counter}"
        return self.tid_map[key]

    def _get_shard(self, shard_name):
        """Map a MongoDB shard name to a TLA+ shard ID."""
        if shard_name not in self.shard_map:
            n = len(self.shard_map) + 1
            self.shard_map[shard_name] = f"s{n}"
        return self.shard_map[shard_name]

    def _ts(self):
        """Real timestamp in nanoseconds."""
        return str(int(time.time_ns()))

    def _emit(self, event):
        line = json.dumps({"tag": "trace", "ts": self._ts(), "event": event},
                          separators=(",", ":"))
        self.fp.write(line + "\n")
        self.fp.flush()

    def emit_config(self, shards, router="r1"):
        """Emit config line with cluster topology."""
        shard_ids = [self._get_shard(s) for s in shards]
        line = json.dumps({
            "tag": "config",
            "ts": self._ts(),
            "config": {"shards": shard_ids, "routers": [router]}
        }, separators=(",", ":"))
        self.fp.write(line + "\n")
        self.fp.flush()

    def router_txn_start(self, session, read_ts=1):
        tid = self._get_tid(session)
        self._emit({
            "name": "RouterTxnStart",
            "nid": self.router_id,
            "ntype": "router",
            "tid": tid,
            "readTs": read_ts
        })

    def router_txn_op(self, session, shard, key, op):
        tid = self._get_tid(session)
        self._emit({
            "name": "RouterTxnOp",
            "nid": self.router_id,
            "ntype": "router",
            "tid": tid,
            "shard": self._get_shard(shard),
            "key": key,
            "op": op
        })

    def router_txn_coordinate_commit(self, session, coordinator_shard):
        tid = self._get_tid(session)
        self._emit({
            "name": "RouterTxnCoordinateCommit",
            "nid": self.router_id,
            "ntype": "router",
            "tid": tid,
            "shard": self._get_shard(coordinator_shard)
        })

    def router_txn_commit_single_shard(self, session, shard):
        tid = self._get_tid(session)
        self._emit({
            "name": "RouterTxnCommitSingleShard",
            "nid": self.router_id,
            "ntype": "router",
            "tid": tid,
            "shard": self._get_shard(shard)
        })

    def router_txn_commit_read_only(self, session):
        tid = self._get_tid(session)
        self._emit({
            "name": "RouterTxnCommitReadOnly",
            "nid": self.router_id,
            "ntype": "router",
            "tid": tid
        })

    def router_txn_abort(self, session):
        tid = self._get_tid(session)
        self._emit({
            "name": "RouterTxnAbort",
            "nid": self.router_id,
            "ntype": "router",
            "tid": tid
        })

    def _emit_meta(self, key, value):
        """Emit a metadata line (for log parser to correlate sessions)."""
        line = json.dumps({"tag": "meta", key: value}, separators=(",", ":"))
        self.fp.write(line + "\n")
        self.fp.flush()


def get_shard_for_key(client, db_name, coll_name, key):
    """Determine which shard owns a given key via the config database."""
    config = client.get_database("config")
    # For hashed shard key, we query where the doc actually lives
    try:
        result = client.admin.command("splitVector", f"{db_name}.{coll_name}",
                                       keyPattern={"_id": "hashed"},
                                       maxChunkSizeBytes=1)
    except Exception:
        pass
    # Use $explain or direct approach: just check which shard has the doc
    db = client.get_database(db_name)
    explain = db.command("explain", {"find": coll_name, "filter": {"_id": key}})
    # Navigate explain output to find shard
    if "queryPlanner" in explain and "winningPlan" in explain["queryPlanner"]:
        plan = explain["queryPlanner"]["winningPlan"]
        if "shards" in plan:
            for s in plan["shards"]:
                if "shardName" in s:
                    return s["shardName"]
    # Fallback: check shardVersion from the collection stats
    return None


def discover_key_shard_mapping(client, db_name, coll_name, keys):
    """Discover which shard each key lives on by reading from each shard."""
    mapping = {}
    for key in keys:
        explain = client.get_database(db_name).command(
            "explain",
            {"find": coll_name, "filter": {"_id": key}},
            verbosity="queryPlanner"
        )
        # Parse the explain plan to find shard name
        plan = explain.get("queryPlanner", {}).get("winningPlan", {})
        shards = plan.get("shards", [])
        if shards:
            mapping[key] = shards[0].get("shardName", "unknown")
        else:
            # Non-sharded or targeted query
            shard_name = explain.get("queryPlanner", {}).get("winningPlan", {}).get("shardName")
            if shard_name:
                mapping[key] = shard_name
    return mapping


def _extract_shard_from_explain(explain):
    """Extract shard name from explain plan output (handles multiple formats)."""
    plan = explain.get("queryPlanner", {}).get("winningPlan", {})
    # Format 1: SINGLE_SHARD with shards array
    shards = plan.get("shards", [])
    if shards:
        return shards[0].get("shardName")
    # Format 2: direct shardName on winningPlan
    if "shardName" in plan:
        return plan["shardName"]
    # Format 3: nested in queryPlanner directly
    return explain.get("queryPlanner", {}).get("shardName")


def find_two_keys_different_shards(client, db_name, coll_name):
    """Find two keys that live on different shards."""
    db = client.get_database(db_name)
    shard_keys = {}
    # Check known keys directly (avoid broad find which may be targeted)
    for i in range(100):
        key = f"key{i}"
        explain = db.command(
            "explain",
            {"find": coll_name, "filter": {"_id": key}},
            verbosity="queryPlanner"
        )
        shard = _extract_shard_from_explain(explain)
        if shard is None:
            continue
        if shard not in shard_keys:
            shard_keys[shard] = key
        if len(shard_keys) >= 2:
            break
    if len(shard_keys) < 2:
        raise RuntimeError(f"Could not find keys on 2 different shards. Found: {shard_keys}")
    items = list(shard_keys.items())
    return (items[0][1], items[0][0]), (items[1][1], items[1][0])


def scenario_basic_commit(client, trace_dir):
    """
    Cross-shard read+write transaction that commits via 2PC.
    Exercises: RouterTxnStart, RouterTxnOp x2, RouterTxnCoordinateCommit,
    ShardTxnStart x2, ShardTxnRead, ShardTxnWrite, ShardTxnPrepare x2,
    ShardTxnCoordinateCommit, RecvCommitVote x2, WriteCommitDecision,
    SendCommit, ShardTxnCommit x2.
    """
    print("\n=== Scenario: basic_commit (cross-shard 2PC) ===")
    emitter = TraceEmitter(os.path.join(trace_dir, "basic_commit_client.ndjson"))

    try:
        # Find two keys on different shards
        (key1, shard1), (key2, shard2) = find_two_keys_different_shards(
            client, "testdb", "items")
        print(f"  key1={key1} on {shard1}, key2={key2} on {shard2}")

        shard_names = sorted(set([shard1, shard2]))
        emitter.emit_config(shard_names)

        # Start transaction
        with client.start_session() as session:
            session.start_transaction(
                read_concern=ReadConcern("snapshot"),
                write_concern=WriteConcern("majority")
            )
            emitter.router_txn_start(session, read_ts=1)

            # Record lsid for log filtering
            # Force session materialization by accessing _server_session
            lsid_str = str(session.session_id["id"].as_uuid())
            emitter._emit_meta("lsid", lsid_str)
            emitter._emit_meta("txnNumber", session._server_session._transaction_id)

            db = session.client.get_database("testdb")

            # Write to shard1 (to trigger full 2PC — both shards need writes)
            db.items.update_one(
                {"_id": key1},
                {"$set": {"value": "updated_by_basic_commit_s1"}},
                session=session
            )
            emitter.router_txn_op(session, shard1, "k1", "write")
            print(f"  Write to {shard1}: key1 updated")

            # Write to shard2
            db.items.update_one(
                {"_id": key2},
                {"$set": {"value": "updated_by_basic_commit_s2"}},
                session=session
            )
            emitter.router_txn_op(session, shard2, "k2", "write")
            print(f"  Write to {shard2}: key2 updated")

            # Commit (cross-shard with writes on both => full 2PC)
            first_shard = shard1  # First participant is coordinator
            emitter.router_txn_coordinate_commit(session, first_shard)
            session.commit_transaction()
            print("  Transaction committed via 2PC")

    except Exception as e:
        print(f"  ERROR: {e}")
        raise
    finally:
        emitter.close()

    return emitter.tid_map, emitter.shard_map


def scenario_single_shard(client, trace_dir):
    """
    Single-shard transaction (no 2PC needed).
    Exercises: RouterTxnStart, RouterTxnOp, RouterTxnCommitSingleShard,
    ShardTxnStart, ShardTxnWrite, ShardTxnCommit.
    """
    print("\n=== Scenario: single_shard ===")
    emitter = TraceEmitter(os.path.join(trace_dir, "single_shard_client.ndjson"))

    try:
        # Find a key and its shard
        db = client.get_database("testdb")
        doc = db.items.find_one()
        key = doc["_id"]
        explain = db.command("explain", {"find": "items", "filter": {"_id": key}},
                             verbosity="queryPlanner")
        shard = _extract_shard_from_explain(explain) or "unknown"
        print(f"  key={key} on {shard}")

        emitter.emit_config([shard])

        with client.start_session() as session:
            session.start_transaction(
                read_concern=ReadConcern("snapshot"),
                write_concern=WriteConcern("majority")
            )
            emitter.router_txn_start(session, read_ts=1)
            # Force session materialization by accessing _server_session
            lsid_str = str(session.session_id["id"].as_uuid())
            emitter._emit_meta("lsid", lsid_str)
            emitter._emit_meta("txnNumber", session._server_session._transaction_id)

            db = session.client.get_database("testdb")
            db.items.update_one(
                {"_id": key},
                {"$set": {"value": "updated_by_single_shard"}},
                session=session
            )
            emitter.router_txn_op(session, shard, "k1", "write")

            emitter.router_txn_commit_single_shard(session, shard)
            session.commit_transaction()
            print("  Transaction committed (single shard)")

    except Exception as e:
        print(f"  ERROR: {e}")
        raise
    finally:
        emitter.close()

    return emitter.tid_map, emitter.shard_map


def scenario_abort(client, trace_dir):
    """
    Transaction that is explicitly aborted.
    Exercises: RouterTxnStart, RouterTxnOp, RouterTxnAbort,
    ShardTxnStart, ShardTxnWrite, ShardTxnAbort.
    """
    print("\n=== Scenario: abort ===")
    emitter = TraceEmitter(os.path.join(trace_dir, "abort_client.ndjson"))

    try:
        db = client.get_database("testdb")
        doc = db.items.find_one()
        key = doc["_id"]
        explain = db.command("explain", {"find": "items", "filter": {"_id": key}},
                             verbosity="queryPlanner")
        shard = _extract_shard_from_explain(explain) or "unknown"
        print(f"  key={key} on {shard}")

        emitter.emit_config([shard])

        with client.start_session() as session:
            session.start_transaction(
                read_concern=ReadConcern("snapshot"),
                write_concern=WriteConcern("majority")
            )
            emitter.router_txn_start(session, read_ts=1)
            # Force session materialization by accessing _server_session
            lsid_str = str(session.session_id["id"].as_uuid())
            emitter._emit_meta("lsid", lsid_str)
            emitter._emit_meta("txnNumber", session._server_session._transaction_id)

            db = session.client.get_database("testdb")
            db.items.update_one(
                {"_id": key},
                {"$set": {"value": "will_be_aborted"}},
                session=session
            )
            emitter.router_txn_op(session, shard, "k1", "write")

            emitter.router_txn_abort(session)
            session.abort_transaction()
            print("  Transaction aborted")

    except Exception as e:
        print(f"  ERROR: {e}")
        raise
    finally:
        emitter.close()

    return emitter.tid_map, emitter.shard_map


def run_all_scenarios():
    print(f"Connecting to {MONGOS_URI}...")
    client = MongoClient(MONGOS_URI, directConnection=False)

    # Verify cluster is sharded
    status = client.admin.command("serverStatus")
    print(f"Connected to MongoDB {status.get('version', 'unknown')}")

    os.makedirs(TRACE_DIR, exist_ok=True)

    results = {}
    results["basic_commit"] = scenario_basic_commit(client, TRACE_DIR)
    results["single_shard"] = scenario_single_shard(client, TRACE_DIR)
    results["abort"] = scenario_abort(client, TRACE_DIR)

    # Write ID mappings for the log parser
    mapping_file = os.path.join(TRACE_DIR, "id_mappings.json")
    mappings = {}
    for name, (tid_map, shard_map) in results.items():
        mappings[name] = {"tid_map": tid_map, "shard_map": shard_map}
    with open(mapping_file, "w") as f:
        json.dump(mappings, f, indent=2)
    print(f"\nID mappings written to {mapping_file}")

    client.close()
    print("\nAll scenarios completed.")


if __name__ == "__main__":
    run_all_scenarios()
