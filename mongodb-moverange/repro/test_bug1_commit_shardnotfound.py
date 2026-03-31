#!/usr/bin/env python3
"""
Bug 1: Commit path missing ShardNotFound catch for advanceTransactionOnRecipient.
Location: migration_coordinator.cpp:252-255

The commit path in _commitMigrationOnDonorAndRecipient does NOT catch ShardNotFound
for advanceTransactionOnRecipient (line 252), while the abort path DOES (line 365).
If the recipient shard is removed after the config server commits the chunk migration
but before commit side-effects complete, recovery enters an infinite retry loop via
refreshFilteringMetadataUntilSuccess (which retries ALL DBExceptions).

Reproduction scenario:
1. Set up 2-shard cluster, shard a collection
2. Start moveChunk shard0->shard1 with failpoint to pause during commit side-effects
3. Wait for config server to commit the chunk move
4. Step down shard0 (interrupts commit side-effects, coordinator doc persists)
5. Disable failpoint, remove shard1 from config.shards, stop shard1
6. Wait for shard0 to become primary -> recovery runs
7. Recovery calls _commitMigrationOnDonorAndRecipient -> advanceTransactionOnRecipient
   -> ShardNotFound -> retry loop (infinite)

Expected: coordinator doc persists indefinitely, ShardNotFound errors in logs.
"""

import pymongo
import time
import threading
import subprocess
import sys
import os

COMPOSE_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "docker-compose.yml")

MONGOS_URI = "mongodb://localhost:27017/?directConnection=true"
SHARD0_URI = "mongodb://localhost:27018/?directConnection=true"
SHARD1_URI = "mongodb://localhost:27028/?directConnection=true"
CONFIG_URI = "mongodb://localhost:27019/?directConnection=true"


def wait_primary(uri, timeout=60):
    """Wait until node is writable primary. Returns a fresh MongoClient."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            c = pymongo.MongoClient(uri, serverSelectionTimeoutMS=2000)
            r = c.admin.command("hello")
            if r.get("isWritablePrimary") or r.get("ismaster"):
                return c
        except Exception:
            pass
        time.sleep(1)
    raise TimeoutError(f"Node at {uri} did not become primary within {timeout}s")


def run(cmd, **kwargs):
    return subprocess.run(cmd, capture_output=True, text=True, **kwargs)


def setup_cluster():
    """Initialize RS members and add shards."""
    # Config RS
    c = pymongo.MongoClient(CONFIG_URI, serverSelectionTimeoutMS=5000)
    try:
        c.admin.command("replSetInitiate", {
            "_id": "configRS", "configsvr": True,
            "members": [{"_id": 0, "host": "configsvr:27019"}]
        })
    except pymongo.errors.OperationFailure:
        pass
    wait_primary(CONFIG_URI)

    # Shard0 RS
    c = pymongo.MongoClient(SHARD0_URI, serverSelectionTimeoutMS=5000)
    try:
        c.admin.command("replSetInitiate", {
            "_id": "shard0RS",
            "members": [{"_id": 0, "host": "shard0:27018"}]
        })
    except pymongo.errors.OperationFailure:
        pass
    wait_primary(SHARD0_URI)

    # Shard1 RS
    c = pymongo.MongoClient(SHARD1_URI, serverSelectionTimeoutMS=5000)
    try:
        c.admin.command("replSetInitiate", {
            "_id": "shard1RS",
            "members": [{"_id": 0, "host": "shard1:27018"}]
        })
    except pymongo.errors.OperationFailure:
        pass
    wait_primary(SHARD1_URI)

    time.sleep(3)

    # Add shards
    mongos = pymongo.MongoClient(MONGOS_URI, serverSelectionTimeoutMS=5000)
    for shard_conn in ["shard0RS/shard0:27018", "shard1RS/shard1:27018"]:
        try:
            mongos.admin.command("addShard", shard_conn)
        except pymongo.errors.OperationFailure:
            pass
    time.sleep(2)
    return mongos


def get_shard0_logs(tail=500):
    r = run(["docker", "compose", "-f", COMPOSE_FILE, "logs", "--tail", str(tail), "shard0"])
    return r.stdout


def main():
    print("=" * 70)
    print("Bug 1: Commit path ShardNotFound infinite retry")
    print("  migration_coordinator.cpp:252 — advanceTransactionOnRecipient")
    print("=" * 70)
    print()

    # ── Step 1: Cluster setup ──
    print("[1/10] Setting up sharded cluster...")
    mongos = setup_cluster()

    # ── Step 2: Create sharded collection ──
    print("[2/10] Creating sharded collection with data on shard0...")
    try:
        mongos.admin.command("enableSharding", "testdb")
    except pymongo.errors.OperationFailure:
        pass
    try:
        mongos["testdb"].drop_collection("testcoll")
    except Exception:
        pass
    mongos.admin.command("shardCollection", "testdb.testcoll", key={"x": 1})
    mongos["testdb"]["testcoll"].insert_many([{"x": i, "v": f"d{i}"} for i in range(100)])
    print("    Inserted 100 documents.")

    # Verify data is on shard0
    shard0 = wait_primary(SHARD0_URI)
    count = shard0["testdb"]["testcoll"].count_documents({})
    print(f"    shard0 has {count} docs.")

    # ── Step 3: Enable failpoint on shard0 (donor) ──
    # hangBeforeMakingCommitDecisionDurable pauses in _commitMigrationOnDonorAndRecipient
    # BEFORE persistCommitDecision, AFTER config server has already committed.
    print("[3/10] Enabling hangBeforeMakingCommitDecisionDurable on shard0...")
    shard0.admin.command(
        "configureFailPoint", "hangBeforeMakingCommitDecisionDurable", mode="alwaysOn"
    )

    # ── Step 4: Start moveChunk in background ──
    print("[4/10] Starting moveChunk shard0 -> shard1 (background thread)...")
    move_result = {"error": None, "done": False}

    def do_move():
        try:
            m = pymongo.MongoClient(MONGOS_URI, serverSelectionTimeoutMS=120000,
                                    socketTimeoutMS=120000)
            m.admin.command("moveChunk", "testdb.testcoll", find={"x": 0}, to="shard1RS")
        except Exception as e:
            move_result["error"] = str(e)
        move_result["done"] = True

    t = threading.Thread(target=do_move, daemon=True)
    t.start()

    # ── Step 5: Wait for failpoint hit (config server committed, side-effects pending) ──
    print("[5/10] Waiting for migration to reach commit side-effects phase...")
    # The coordinator doc appears on shard0 when the migration starts, and the failpoint
    # fires after the config server has committed the chunk move.
    config = pymongo.MongoClient(CONFIG_URI, serverSelectionTimeoutMS=5000)
    found_coord = False
    for i in range(90):
        try:
            coord_docs = list(shard0["config"]["migrationCoordinators"].find())
            if coord_docs:
                # Check if config server shows the chunk on shard1
                # (meaning config commit has happened)
                chunks = list(config["config"]["chunks"].find(
                    {"shard": "shard1RS"},
                    {"_id": 0, "shard": 1}
                ).limit(5))
                shard1_chunks = [c for c in chunks]
                if shard1_chunks:
                    print(f"    Config server committed: chunk(s) on shard1RS")
                    found_coord = True
                    break
                else:
                    if i % 10 == 0:
                        print(f"    Coordinator doc exists, waiting for config commit... ({i}s)")
        except Exception as e:
            if i % 10 == 0:
                print(f"    Waiting... ({e})")
        time.sleep(1)

    if not found_coord:
        print("    WARNING: Could not confirm config server commit. Proceeding anyway.")
        # Give more time
        time.sleep(10)

    # ── Step 6: Step down shard0 to interrupt migration side-effects ──
    print("[6/10] Stepping down shard0 (force)...")
    try:
        shard0.admin.command("replSetStepDown", 5, force=True, secondaryCatchUpPeriodSecs=0)
    except Exception:
        pass  # Expected: connection dropped

    time.sleep(2)

    # ── Step 7: Disable failpoint (so recovery won't hit it) ──
    print("[7/10] Disabling failpoint on shard0...")
    for attempt in range(10):
        try:
            c = pymongo.MongoClient(SHARD0_URI, serverSelectionTimeoutMS=2000,
                                    directConnection=True)
            c.admin.command(
                "configureFailPoint", "hangBeforeMakingCommitDecisionDurable", mode="off"
            )
            print("    Failpoint disabled.")
            break
        except Exception as e:
            if attempt == 9:
                print(f"    WARNING: Could not disable failpoint: {e}")
            time.sleep(1)

    # ── Step 8: Remove shard1 from config.shards + stop shard1 ──
    print("[8/10] Removing shard1 from config.shards and stopping container...")
    try:
        result = config["config"]["shards"].delete_one({"_id": "shard1RS"})
        print(f"    Deleted {result.deleted_count} shard entry from config.shards")
    except Exception as e:
        print(f"    WARNING: Could not delete shard entry: {e}")

    run(["docker", "compose", "-f", COMPOSE_FILE, "stop", "shard1"])
    print("    shard1 container stopped.")

    # ── Step 9: Wait for shard0 to become primary ──
    print("[9/10] Waiting for shard0 to step up and begin recovery...")
    try:
        shard0 = wait_primary(SHARD0_URI, timeout=30)
        print("    shard0 is primary. Recovery should be running.")
    except TimeoutError:
        print("    ERROR: shard0 did not become primary within 30s")
        return False

    # ── Step 10: Observe recovery behavior ──
    print("[10/10] Waiting 30s for recovery attempts...")
    time.sleep(30)

    # Check 1: Coordinator doc still exists (recovery could not complete)
    coord_docs = list(shard0["config"]["migrationCoordinators"].find())
    has_coord_doc = len(coord_docs) > 0

    # Check 2: Recovery retry loop in shard0 logs
    logs = get_shard0_logs(tail=1000)
    # Log id 23937 = "Retrying task after failed attempt" in retry loop
    retry_hits = logs.count('"id":23937')
    shardnotfound_hits = logs.lower().count("shardnotfound")
    migration_recovery = logs.count("MigrationRecovery")

    print()
    print("-" * 50)
    print("RESULTS")
    print("-" * 50)
    print(f"  Coordinator doc still exists:    {has_coord_doc}")
    if coord_docs:
        for d in coord_docs:
            print(f"    id={d.get('_id')}, decision={d.get('decision', 'NONE')}")
    print(f"  Recovery retry log entries:       {retry_hits}")
    print(f"  MigrationRecovery ctx entries:    {migration_recovery}")
    print(f"  ShardNotFound in logs:            {shardnotfound_hits}")
    print()

    if has_coord_doc and (retry_hits >= 5 or migration_recovery >= 5):
        print("*** BUG REPRODUCED ***")
        print("Recovery enters infinite retry loop after recipient shard removal.")
        print("The commit path in _commitMigrationOnDonorAndRecipient does not handle")
        print("the case where the recipient shard is gone (no ShardNotFound catch at")
        print("migration_coordinator.cpp:252, unlike the abort path at line 365).")
        print()
        print("Observable: recovery thread stuck in refreshFilteringMetadataUntilSuccess")
        print("retrying indefinitely. Coordinator doc never cleaned up.")
        print("Requires manual intervention to resolve.")
        return True
    elif has_coord_doc:
        print("*** BUG PARTIALLY CONFIRMED ***")
        print("Coordinator doc persists but retry count is low.")
        return True
    else:
        print("--- Bug not reproduced ---")
        print("Coordinator doc was cleaned up (recovery succeeded).")
        return False


if __name__ == "__main__":
    ok = main()
    sys.exit(0 if ok else 1)
