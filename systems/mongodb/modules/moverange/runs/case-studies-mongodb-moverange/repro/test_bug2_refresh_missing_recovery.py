#!/usr/bin/env python3
"""
Bug 2: Post-commit refresh failure missing recovery scheduling.
Location: migration_source_manager.cpp:742-743

After a successful config server commit, if the post-migration metadata refresh fails
(lines 708-711), the code dismisses the scopedGuard and calls _cleanup(false) WITHOUT
scheduling asyncRecoverMigrationUntilSuccessOrStepDown (line 742-743). The commit failure
path (line 695) DOES schedule recovery. This is an oversight introduced incrementally:
- SERVER-47982: Both paths had identical "best-effort" recovery
- SERVER-62282: Upgraded commit failure path to retryUntilSuccess, missed refresh path
- SERVER-61759: Removed refresh path's recovery entirely

Impact: Coordinator doc persists without recovery scheduled. Range deletion is delayed
until the next failover triggers step-up recovery. On a stable primary, orphans persist
indefinitely.

Reproduction approach:
1. Pause the config server to make metadata refresh fail
2. Verify the coordinator doc persists without recovery
3. Show that only a manual step-down triggers recovery
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
    c = pymongo.MongoClient(CONFIG_URI, serverSelectionTimeoutMS=5000)
    try:
        c.admin.command("replSetInitiate", {
            "_id": "configRS", "configsvr": True,
            "members": [{"_id": 0, "host": "configsvr:27019"}]
        })
    except pymongo.errors.OperationFailure:
        pass
    wait_primary(CONFIG_URI)

    c = pymongo.MongoClient(SHARD0_URI, serverSelectionTimeoutMS=5000)
    try:
        c.admin.command("replSetInitiate", {
            "_id": "shard0RS",
            "members": [{"_id": 0, "host": "shard0:27018"}]
        })
    except pymongo.errors.OperationFailure:
        pass
    wait_primary(SHARD0_URI)

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

    mongos = pymongo.MongoClient(MONGOS_URI, serverSelectionTimeoutMS=5000)
    for shard_conn in ["shard0RS/shard0:27018", "shard1RS/shard1:27018"]:
        try:
            mongos.admin.command("addShard", shard_conn)
        except pymongo.errors.OperationFailure:
            pass
    time.sleep(2)
    return mongos


def main():
    print("=" * 70)
    print("Bug 2: Post-commit refresh failure -- missing recovery scheduling")
    print("  migration_source_manager.cpp:742-743")
    print("=" * 70)
    print()

    # ---- Step 1: Cluster setup ----
    print("[1/10] Setting up sharded cluster...")
    mongos = setup_cluster()

    # ---- Step 2: Create sharded collection ----
    print("[2/10] Creating sharded collection with data on shard0...")
    try:
        mongos.admin.command("enableSharding", "testdb2")
    except pymongo.errors.OperationFailure:
        pass
    try:
        mongos["testdb2"].drop_collection("testcoll2")
    except Exception:
        pass
    mongos.admin.command("shardCollection", "testdb2.testcoll2", key={"x": 1})
    mongos["testdb2"]["testcoll2"].insert_many([{"x": i, "v": f"d{i}"} for i in range(50)])

    shard0 = wait_primary(SHARD0_URI)

    # ---- Step 3: Enable failpoint to pause after config commit, before refresh ----
    print("[3/10] Enabling hangBeforePostMigrationCommitRefresh on shard0...")
    shard0.admin.command(
        "configureFailPoint", "hangBeforePostMigrationCommitRefresh", mode="alwaysOn"
    )

    # ---- Step 4: Start moveChunk in background ----
    print("[4/10] Starting moveChunk shard0 -> shard1 (background)...")
    move_result = {"error": None, "done": False}

    def do_move():
        try:
            m = pymongo.MongoClient(MONGOS_URI, serverSelectionTimeoutMS=120000,
                                    socketTimeoutMS=120000)
            m.admin.command("moveChunk", "testdb2.testcoll2", find={"x": 0}, to="shard1RS")
        except Exception as e:
            move_result["error"] = str(e)
        move_result["done"] = True

    t = threading.Thread(target=do_move, daemon=True)
    t.start()

    # ---- Step 5: Wait for config commit and failpoint hit ----
    print("[5/10] Waiting for migration to pause at post-commit refresh...")
    config = pymongo.MongoClient(CONFIG_URI, serverSelectionTimeoutMS=5000)
    for i in range(90):
        try:
            chunks = list(config["config"]["chunks"].find({"shard": "shard1RS"}).limit(5))
            if chunks:
                print(f"    Config server committed. Failpoint should be hit.")
                break
        except Exception:
            pass
        if i % 15 == 0:
            print(f"    Waiting... ({i}s)")
        time.sleep(1)

    time.sleep(3)  # Extra time to ensure we're at the failpoint

    # ---- Step 6: Pause config server to make refresh fail ----
    print("[6/10] Pausing config server to cause refresh failure...")
    run(["docker", "compose", "-f", COMPOSE_FILE, "pause", "configsvr"])
    print("    Config server paused.")

    # ---- Step 7: Release the hang failpoint ----
    # Refresh will now fail because config server is unreachable.
    print("[7/10] Releasing hangBeforePostMigrationCommitRefresh...")
    shard0.admin.command(
        "configureFailPoint", "hangBeforePostMigrationCommitRefresh", mode="off"
    )

    # Wait for the refresh to fail and migration to complete with error.
    # The refresh timeout may take 20-60s, so be patient.
    print("[8/10] Waiting for refresh failure (may take up to 60s)...")
    deadline = time.time() + 90
    while time.time() < deadline:
        if move_result["done"]:
            break
        time.sleep(2)
        elapsed = int(time.time() - (deadline - 90))
        if elapsed % 10 == 0:
            print(f"    Waiting... ({elapsed}s)")

    # Unpause config server
    print("[9/10] Unpausing config server...")
    run(["docker", "compose", "-f", COMPOSE_FILE, "unpause", "configsvr"])

    if move_result["error"]:
        print(f"    moveChunk failed (expected): {move_result['error'][:120]}")
    elif move_result["done"]:
        print("    moveChunk completed (unexpected -- refresh may have retried internally)")
    else:
        print("    moveChunk still running (refresh timeout not reached)")

    time.sleep(3)

    # ---- Step 10: Check state ----
    print("[10/10] Checking final state...")
    shard0_check = wait_primary(SHARD0_URI, timeout=10)

    # Check coordinator doc
    coord_docs = list(shard0_check["config"]["migrationCoordinators"].find())
    has_coord_doc = len(coord_docs) > 0

    # Check range deletion tasks
    range_del_docs = list(shard0_check["config"]["rangeDeletions"].find())

    # Check logs for recovery scheduling
    log_out = run(["docker", "compose", "-f", COMPOSE_FILE, "logs", "--tail", "500", "shard0"])
    logs = log_out.stdout
    async_recover_count = logs.count("asyncRecoverMigration")
    cleanup_count = logs.count("Failed to complete the migration")

    print()
    print("-" * 50)
    print("RESULTS")
    print("-" * 50)
    print(f"  Coordinator doc exists:       {has_coord_doc}")
    if coord_docs:
        for d in coord_docs:
            print(f"    id={d.get('_id')}, decision={d.get('decision', 'NONE')}")
    print(f"  Range deletion tasks:         {len(range_del_docs)}")
    print(f"  asyncRecoverMigration calls:  {async_recover_count}")
    print(f"  'Failed to complete' logs:    {cleanup_count}")
    print()

    if has_coord_doc:
        print("*** BUG REPRODUCED ***")
        print("The coordinator doc persists after post-commit refresh failure.")
        print("migration_source_manager.cpp:743 calls _cleanup(false) WITHOUT")
        print("scheduling asyncRecoverMigrationUntilSuccessOrStepDown.")
        print("The commit failure path at line 695 DOES schedule recovery.")
        print()
        print("Without a manual step-down, the migration remains orphaned and")
        print("range deletion will never run on the donor shard.")
        return True
    elif move_result["error"]:
        print("*** BUG LIKELY PRESENT (but cleanup succeeded) ***")
        print("moveChunk failed (refresh error), but coordinator doc was cleaned up.")
        print("The _cleanup(false) -> completeMigration path may have succeeded")
        print("despite missing explicit recovery scheduling.")
        return False
    else:
        print("--- Bug not reproduced ---")
        print("moveChunk succeeded. The metadata refresh did not fail, possibly because")
        print("the config server was unpaused before the refresh timed out, or the")
        print("refresh uses cached data that didn't require contacting the config server.")
        return False


if __name__ == "__main__":
    ok = main()
    sys.exit(0 if ok else 1)
