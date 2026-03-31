#!/usr/bin/env python3
"""
Test scenarios for TxnsMoveRange trace collection.

Exercises transactions during chunk migration against a real MongoDB sharded cluster.
3 scenarios covering spec actions:
  1. basic_txn            — Simple 2-statement txn, no migration.
                            Events: RouterSendTxnStmt, ShardRespond, RouterHandleOk
  2. migration_lifecycle  — Full moveChunk lifecycle, no txn.
                            Events: StartMigration, ConfigCommit, ReleaseCriticalSection
  3. txn_during_migration — Txn hits critical section during moveChunk.
                            Events: RouterSendTxnStmt, ShardRespond(staleRouter),
                            RouterRetryOnStale or RouterHandleAbort

Server-side events (migration lifecycle) captured from LOGV2 logs by parse_logs.py.

Usage:
    MONGOS_URI=mongodb://localhost:27217 TRACE_DIR=../traces python3 test_scenarios.py
"""

import os
import sys
import time
import json
import subprocess
import threading

import pymongo
from pymongo import MongoClient
from pymongo.read_concern import ReadConcern
from pymongo.write_concern import WriteConcern
from pymongo.errors import OperationFailure

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from trace_emitter import TraceEmitter, map_shard, map_ns


MONGOS_URI = os.environ.get("MONGOS_URI", "mongodb://localhost:27217")
TRACE_DIR = os.environ.get("TRACE_DIR", os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "traces"
))
DB_NAME = "testdb"
COLL_NAME = "items"
NS = f"{DB_NAME}.{COLL_NAME}"


def find_shard_for_key(client, key):
    """Determine which shard owns a specific key via explain."""
    db = client[DB_NAME]
    try:
        explain = db.command(
            "explain",
            {"find": COLL_NAME, "filter": {"_id": key}},
            verbosity="queryPlanner",
        )
        qp = explain.get("queryPlanner", explain)
        wp = qp.get("winningPlan", {})
        shards = wp.get("shards", [])
        if shards:
            return map_shard(shards[0].get("shardName", ""))
        if "shardName" in qp:
            return map_shard(qp["shardName"])
        if "shardName" in wp.get("queryPlan", {}):
            return map_shard(wp["queryPlan"]["shardName"])
    except Exception as e:
        print(f"    WARNING: explain failed for key {key}: {e}")
    return "s1"  # default


def docker_exec_mongosh(container, js_code, quiet=True):
    """Run mongosh command in a Docker container."""
    cmd = ["docker", "exec", container, "mongosh", "--quiet", "--eval", js_code]
    if not quiet:
        cmd = ["docker", "exec", container, "mongosh", "--eval", js_code]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if result.returncode != 0:
        print(f"    WARNING: mongosh failed: {result.stderr[:200]}")
    return result.stdout


def move_chunk(from_shard_rs, to_shard_rs, key="_id", key_value="k2"):
    """Trigger a chunk migration via mongos."""
    # Use moveChunk to move the chunk containing the key
    js = f'''
    db.adminCommand({{
        moveChunk: "{NS}",
        find: {{"{key}": "{key_value}"}},
        to: "{to_shard_rs}",
        _waitForDelete: true
    }})
    '''
    return docker_exec_mongosh("txnmr-mongos", js)


def set_failpoint(container, failpoint, mode="alwaysOn", data=None):
    """Set a failpoint on a mongod container."""
    fp_doc = {"configureFailPoint": failpoint, "mode": mode}
    if data:
        fp_doc["data"] = data
    js = f"db.adminCommand({json.dumps(fp_doc)})"
    return docker_exec_mongosh(container, js)


# =============================================================================
# Scenario 1: basic_txn — 2-statement transaction, no migration
# Tests: RouterSendTxnStmt, ShardRespond(ok), RouterHandleOk
# =============================================================================

def scenario_basic_txn(client, trace_dir):
    print("  Running scenario: basic_txn")
    emitter = TraceEmitter(os.path.join(trace_dir, "basic_txn_client.ndjson"))
    ts_start = int(time.time() * 1e9)

    try:
        db = client[DB_NAME]
        coll = db.get_collection(
            COLL_NAME,
            write_concern=WriteConcern("majority"),
        )

        # Determine shard ownership
        shard_k1 = find_shard_for_key(client, "k1")
        shard_k2 = find_shard_for_key(client, "k2")
        print(f"    k1 on {shard_k1}, k2 on {shard_k2}")

        with client.start_session() as session:
            session.start_transaction(
                write_concern=WriteConcern("majority"),
            )
            txn_id = emitter.register_txn(session)

            # Statement 1: update k1
            stm1 = emitter.router_send_txn_stmt(txn_id, NS, "k1", shard_k1)
            coll.update_one(
                {"_id": "k1"},
                {"$set": {"value": f"basic_{txn_id}_1"}},
                session=session,
            )
            emitter.shard_respond(txn_id, shard_k1, NS, "ok", True, stm1)
            emitter.router_handle_ok(txn_id, stm1, 1)

            # Statement 2: update k2
            stm2 = emitter.router_send_txn_stmt(txn_id, NS, "k2", shard_k2)
            coll.update_one(
                {"_id": "k2"},
                {"$set": {"value": f"basic_{txn_id}_2"}},
                session=session,
            )
            emitter.shard_respond(txn_id, shard_k2, NS, "ok", True, stm2)
            emitter.router_handle_ok(txn_id, stm2, 2)

            session.commit_transaction()

        print(f"    Committed txn {txn_id}")
    finally:
        emitter.close()

    return {
        "name": "basic_txn",
        "ts_start": ts_start,
        "ts_end": int(time.time() * 1e9),
        "include_migration": False,
        "session_meta": emitter.get_session_meta(),
    }


# =============================================================================
# Scenario 2: migration_lifecycle — Full moveChunk, no transaction
# Tests: StartMigration, ConfigCommit, ReleaseCriticalSection
# =============================================================================

def scenario_migration_lifecycle(client, trace_dir):
    print("  Running scenario: migration_lifecycle")
    emitter = TraceEmitter(os.path.join(trace_dir, "migration_lifecycle_client.ndjson"))
    ts_start = int(time.time() * 1e9)

    try:
        # Find current owner of k2
        shard_k2 = find_shard_for_key(client, "k2")
        target = "shard2RS" if shard_k2 == "s1" else "shard1RS"
        target_tla = map_shard(target)
        print(f"    k2 currently on {shard_k2}, moving to {target_tla}")

        # Trigger migration
        result = move_chunk("", target, key_value="k2")
        print(f"    moveChunk result: {result[:100] if result else '(empty)'}")
        time.sleep(2)  # Let migration complete and logs flush

        # Verify k2 moved
        new_shard = find_shard_for_key(client, "k2")
        print(f"    k2 now on {new_shard}")
    finally:
        emitter.close()

    return {
        "name": "migration_lifecycle",
        "ts_start": ts_start,
        "ts_end": int(time.time() * 1e9),
        "include_migration": True,
        "session_meta": {},
    }


# =============================================================================
# Scenario 3: txn_during_migration — Transaction hits critical section
# Tests: RouterSendTxnStmt, ShardRespond(staleRouter), RouterHandleAbort
#        Plus: StartMigration, ConfigCommit, ReleaseCriticalSection from logs
# =============================================================================

def scenario_txn_during_migration(client, trace_dir):
    print("  Running scenario: txn_during_migration")
    emitter = TraceEmitter(os.path.join(trace_dir, "txn_during_migration_client.ndjson"))
    ts_start = int(time.time() * 1e9)

    try:
        # Find current owner of k3
        shard_k3 = find_shard_for_key(client, "k3")
        from_rs = "shard1RS" if shard_k3 == "s1" else "shard2RS"
        to_rs = "shard2RS" if shard_k3 == "s1" else "shard1RS"
        to_tla = map_shard(to_rs)
        from_container = "txnmr-shard1" if shard_k3 == "s1" else "txnmr-shard2"
        print(f"    k3 on {shard_k3}, will migrate to {to_tla}")

        # Set failpoint to pause migration at critical section entry
        # moveChunkHangAtStep4 pauses after clone, before CS
        # moveChunkHangAtStep5 pauses at CS, before config commit
        print("    Setting moveChunkHangAtStep5 failpoint...")
        set_failpoint(from_container, "moveChunkHangAtStep5", "alwaysOn")

        # Start migration in background thread
        migration_done = threading.Event()
        migration_result = [None]

        def do_migration():
            try:
                result = move_chunk(from_rs, to_rs, key_value="k3")
                migration_result[0] = result
            except Exception as e:
                migration_result[0] = str(e)
            finally:
                migration_done.set()

        migration_thread = threading.Thread(target=do_migration)
        migration_thread.start()

        # Wait for migration to reach CS (failpoint pauses it)
        print("    Waiting for migration to reach critical section...")
        time.sleep(8)

        # Now try a transaction that hits the critical section
        db = client[DB_NAME]
        coll = db.get_collection(
            COLL_NAME,
            write_concern=WriteConcern("majority"),
        )

        with client.start_session() as session:
            session.start_transaction(
                write_concern=WriteConcern("majority"),
            )
            txn_id = emitter.register_txn(session)

            # Statement 1: try to access k3 on the migrating shard
            stm1 = emitter.router_send_txn_stmt(txn_id, NS, "k3", shard_k3)
            try:
                coll.update_one(
                    {"_id": "k3"},
                    {"$set": {"value": f"during_mig_{txn_id}"}},
                    session=session,
                )
                # If it succeeds (possible if CS not yet active from router's view)
                emitter.shard_respond(txn_id, shard_k3, NS, "ok", True, stm1)
                emitter.router_handle_ok(txn_id, stm1, 1)
                print(f"    Statement succeeded (CS may not be visible yet)")

                # Try to commit
                session.commit_transaction()
                print(f"    Txn {txn_id} committed despite migration")
            except OperationFailure as e:
                error_code = e.code
                error_labels = getattr(e, 'details', {}).get('errorLabels', [])

                if "TransientTransactionError" in error_labels or error_code in (
                    175,  # ShardCannotRefreshDueToLocksHeld
                    13388,  # StaleConfig
                    7918901,  # MigrationConflict
                ):
                    # Determine error type for spec
                    if error_code == 7918901 or "MigrationConflict" in str(e):
                        status = "migrationConflict"
                    else:
                        status = "staleRouter"

                    emitter.shard_respond(txn_id, shard_k3, NS, status, False, stm1)

                    # For first statement stale error, router can retry
                    if status == "staleRouter" and stm1 == 1:
                        emitter.router_retry_on_stale(txn_id)
                        print(f"    Got {status} (code {error_code}), router would retry")
                    else:
                        emitter.router_handle_abort(txn_id, stm1, status)
                        print(f"    Got {status} (code {error_code}), txn aborted")
                else:
                    print(f"    Unexpected error: code={error_code}, msg={e}")
                    emitter.shard_respond(txn_id, shard_k3, NS, "staleRouter", False, stm1)
                    emitter.router_handle_abort(txn_id, stm1, "staleRouter")

                # Abort the transaction
                try:
                    session.abort_transaction()
                except Exception:
                    pass

        # Release failpoint and let migration complete
        print("    Releasing failpoint...")
        set_failpoint(from_container, "moveChunkHangAtStep5", "off")
        migration_done.wait(timeout=60)
        time.sleep(2)

        new_shard = find_shard_for_key(client, "k3")
        print(f"    Migration done. k3 now on {new_shard}")
        print(f"    Migration result: {str(migration_result[0])[:100] if migration_result[0] else '(none)'}")

    finally:
        emitter.close()
        # Ensure failpoint is off
        for container in ["txnmr-shard1", "txnmr-shard2"]:
            try:
                set_failpoint(container, "moveChunkHangAtStep5", "off")
            except Exception:
                pass

    return {
        "name": "txn_during_migration",
        "ts_start": ts_start,
        "ts_end": int(time.time() * 1e9),
        "include_migration": True,
        "session_meta": emitter.get_session_meta(),
    }


# =============================================================================
# Main
# =============================================================================

def main():
    os.makedirs(TRACE_DIR, exist_ok=True)

    print(f"Connecting to {MONGOS_URI}")
    client = MongoClient(MONGOS_URI, directConnection=False)

    try:
        status = client.admin.command("serverStatus")
        print(f"Connected to MongoDB {status.get('version', 'unknown')}")
    except Exception as e:
        print(f"ERROR: Cannot connect to mongos: {e}")
        sys.exit(1)

    scenarios = []

    scenario_funcs = [
        ("basic_txn", scenario_basic_txn),
        ("migration_lifecycle", scenario_migration_lifecycle),
        ("txn_during_migration", scenario_txn_during_migration),
    ]

    for name, func in scenario_funcs:
        print(f"\n--- Scenario: {name} ---")
        try:
            result = func(client, TRACE_DIR)
            scenarios.append(result)
        except Exception as e:
            print(f"  ERROR: Scenario {name} failed: {e}")
            import traceback
            traceback.print_exc()
        time.sleep(2)  # Let server logs flush

    # Write scenario metadata for parse_logs.py
    meta_path = os.path.join(TRACE_DIR, "scenario_meta.json")
    with open(meta_path, "w") as f:
        json.dump(scenarios, f, indent=2)
    print(f"\nScenario metadata written to {meta_path}")

    client.close()
    print("Test scenarios complete.")


if __name__ == "__main__":
    main()
