#!/usr/bin/env python3
"""
Bug 3: Non-idempotent $inc on orphan count.
Location: range_deletion_util.cpp:549

persistUpdatedNumOrphans uses $inc to update the orphan count. $inc is not idempotent.
If recovery re-executes the commit path, the orphan count gets incremented again.

The commit path in _commitMigrationOnDonorAndRecipient (migration_coordinator.cpp):
  269: persistUpdatedNumOrphans($inc by N)  -- local on donor
  278: deleteRangeDeletionTaskOnRecipient    -- remote to recipient

If deleteRangeDeletionTaskOnRecipient fails (line 278), the exception propagates,
and the coordinator doc persists. On recovery, the commit path re-runs:
  265: retrieveNumOrphansFromShard           -- gets N again (task still exists)
  269: persistUpdatedNumOrphans($inc by N)   -- count is now 2*N!
  278: deleteRangeDeletionTaskOnRecipient    -- succeeds this time

Reproduction: Use failCommand on shard1 to fail the delete command once. This creates
the exact window: orphan count $inc'd, but recipient task not deleted. Recovery $inc's
again, doubling the count.

Impact: Orphan count inflated. Affects BalancerStatsRegistry stats. Not a safety bug.
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
    print("Bug 3: Non-idempotent $inc on orphan count")
    print("  range_deletion_util.cpp:549 -- persistUpdatedNumOrphans")
    print("=" * 70)
    print()

    # ---- Step 1: Cluster setup ----
    print("[1/11] Setting up sharded cluster...")
    mongos = setup_cluster()

    # ---- Step 2: Create sharded collection ----
    print("[2/11] Creating sharded collection with data on shard0...")
    try:
        mongos.admin.command("enableSharding", "testdb3")
    except pymongo.errors.OperationFailure:
        pass
    try:
        mongos["testdb3"].drop_collection("testcoll3")
    except Exception:
        pass
    mongos.admin.command("shardCollection", "testdb3.testcoll3", key={"x": 1})
    mongos["testdb3"]["testcoll3"].insert_many([{"x": i, "v": f"d{i}"} for i in range(100)])

    shard0 = wait_primary(SHARD0_URI)
    shard1 = wait_primary(SHARD1_URI)

    # ---- Step 3: Enable failpoint on shard0 to pause during commit ----
    # hangBeforeSendingCommitDecision fires at line 257, AFTER persistCommitDecision (240)
    # and advanceTransactionOnRecipient (252), but BEFORE retrieveNumOrphans (265).
    print("[3/11] Enabling hangBeforeSendingCommitDecision on shard0...")
    shard0.admin.command(
        "configureFailPoint", "hangBeforeSendingCommitDecision", mode="alwaysOn"
    )

    # ---- Step 4: Start moveChunk ----
    print("[4/11] Starting moveChunk shard0 -> shard1 (background)...")
    move_result = {"error": None, "done": False}

    def do_move():
        try:
            m = pymongo.MongoClient(MONGOS_URI, serverSelectionTimeoutMS=120000,
                                    socketTimeoutMS=120000)
            m.admin.command("moveChunk", "testdb3.testcoll3", find={"x": 0}, to="shard1RS")
        except Exception as e:
            move_result["error"] = str(e)
        move_result["done"] = True

    t = threading.Thread(target=do_move, daemon=True)
    t.start()

    # ---- Step 5: Wait for failpoint ----
    print("[5/11] Waiting for migration to reach failpoint...")
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
    time.sleep(3)

    # ---- Step 6: Set failCommand on shard1 to fail delete on config.rangeDeletions ----
    # This causes deleteRangeDeletionTaskOnRecipient (line 278) to fail.
    # persistUpdatedNumOrphans (line 269) has already $inc'd the count by this point.
    # Result: orphan count set, but recipient task NOT deleted.
    print("[6/11] Setting failCommand on shard1 to fail delete (once)...")
    shard1.admin.command("configureFailPoint", "failCommand", mode={"times": 1}, data={
        "failCommands": ["delete"],
        "namespace": "config.rangeDeletions",
        "errorCode": 11601  # Interrupted
    })
    print("    failCommand set: next delete on config.rangeDeletions will fail.")

    # ---- Step 7: Release failpoint on shard0 ----
    print("[7/11] Releasing hangBeforeSendingCommitDecision on shard0...")
    shard0.admin.command("configureFailPoint", "hangBeforeSendingCommitDecision", mode="off")

    # Wait for migration to fail (delete on recipient will be rejected)
    print("[8/11] Waiting for migration commit to fail...")
    for i in range(30):
        if move_result["done"]:
            break
        time.sleep(1)

    if move_result["error"]:
        print(f"    moveChunk failed (expected): {move_result['error'][:100]}")
    else:
        print("    moveChunk succeeded (delete failure may not have propagated)")

    time.sleep(3)

    # ---- Step 9: Check orphan count BEFORE recovery ----
    print("[9/11] Checking orphan count before recovery...")
    shard0_check = wait_primary(SHARD0_URI, timeout=10)
    range_del_before = list(shard0_check["config"]["rangeDeletions"].find())
    orphan_before = None
    for rd in range_del_before:
        count = rd.get("numOrphanDocs", 0)
        print(f"    Range deletion task: numOrphanDocs={count}")
        orphan_before = count

    # Check coordinator doc exists (should persist because commit didn't finish)
    coord_docs = list(shard0_check["config"]["migrationCoordinators"].find())
    print(f"    Coordinator doc exists: {len(coord_docs) > 0}")

    # ---- Step 10: Step down to trigger recovery ----
    print("[10/11] Stepping down shard0 to trigger recovery...")
    try:
        shard0_check.admin.command("replSetStepDown", 5, force=True,
                                    secondaryCatchUpPeriodSecs=0)
    except Exception:
        pass

    time.sleep(2)

    # Disable failCommand on shard1 (in case it wasn't consumed)
    try:
        shard1_fresh = pymongo.MongoClient(SHARD1_URI, serverSelectionTimeoutMS=2000)
        shard1_fresh.admin.command("configureFailPoint", "failCommand", mode="off")
    except Exception:
        pass

    shard0_after = wait_primary(SHARD0_URI, timeout=30)
    time.sleep(10)  # Let recovery run

    # ---- Step 11: Check orphan count AFTER recovery ----
    print("[11/11] Checking orphan count after recovery...")
    range_del_after = list(shard0_after["config"]["rangeDeletions"].find())
    orphan_after = None
    for rd in range_del_after:
        count = rd.get("numOrphanDocs", 0)
        print(f"    Range deletion task: numOrphanDocs={count}")
        orphan_after = count

    coord_docs_after = list(shard0_after["config"]["migrationCoordinators"].find())
    print(f"    Coordinator doc exists: {len(coord_docs_after) > 0}")

    print()
    print("-" * 50)
    print("RESULTS")
    print("-" * 50)
    print(f"  Orphan count BEFORE recovery: {orphan_before}")
    print(f"  Orphan count AFTER  recovery: {orphan_after}")
    print(f"  Range deletions before:       {len(range_del_before)}")
    print(f"  Range deletions after:        {len(range_del_after)}")
    print()

    if (orphan_before is not None and orphan_after is not None
            and orphan_after > orphan_before and orphan_before > 0):
        ratio = orphan_after / orphan_before
        print(f"*** BUG REPRODUCED: Orphan count inflated from {orphan_before} to {orphan_after} ({ratio:.1f}x) ***")
        print("persistUpdatedNumOrphans uses non-idempotent $inc.")
        print("Recovery re-executed retrieveNumOrphans + persistUpdatedNumOrphans,")
        print("double-counting the orphans.")
        return True
    elif orphan_before is not None and orphan_after is None:
        print("--- Range deletion task was cleaned up during recovery ---")
        print("Recovery completed, consuming the task. Check if count was inflated briefly.")
        return False
    elif orphan_before == 0 and orphan_after is not None and orphan_after > 0:
        print("--- Orphan count set during recovery but not doubled ---")
        print(f"First attempt may not have reached persistUpdatedNumOrphans (count was 0).")
        print("The failpoint fires BEFORE orphan persist. The delete failure may not have")
        print("occurred in the right window. The bug is real per code audit but this test")
        print("could not capture the double-count window.")
        return False
    else:
        print("--- Bug not reproduced ---")
        return False


if __name__ == "__main__":
    ok = main()
    sys.exit(0 if ok else 1)
