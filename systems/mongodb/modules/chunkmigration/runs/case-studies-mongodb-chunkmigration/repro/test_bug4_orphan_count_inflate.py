#!/usr/bin/env python3
"""
Bug 4 Reproduction: Non-idempotent orphan count increment on recovery replay.

LEVEL 2 — State Injection.

Strategy:
1. Start M1 (shard0→shard1) with hangBeforeSendingCommitDecision failpoint.
   At this failpoint:
   - persistCommitDecision: DONE (coordinator doc has decision=committed)
   - advanceTransactionOnRecipient: DONE
   - retrieveNumOrphansFromShard: NOT YET DONE
   - persistUpdatedNumOrphans: NOT YET DONE
   The recipient's range deletion task still exists (deleteRangeDeletionTaskOnRecipient not called).

2. Read the orphan count from the RECIPIENT's range deletion task (N).
3. On the DONOR (shard0), manually $inc the donor's range deletion task numOrphanDocs by N.
   This simulates one successful execution of persistUpdatedNumOrphans.
   Write with w:majority.

4. Step down shard0. The coordinator doc persists (forgetMigration never ran).
   The thread is stuck at hangBeforeSendingCommitDecision (not interruptible, no opCtx).

5. New primary steps up → recovery replays _commitMigrationOnDonorAndRecipient:
   - persistCommitDecision: idempotent
   - advanceTransactionOnRecipient: idempotent
   - retrieveNumOrphansFromShard: returns N (recipient task still exists!)
   - persistUpdatedNumOrphans: $inc by N → total becomes 2N (BUG!)

6. Observable: numOrphanDocs = 2N instead of N.

This proves: persistUpdatedNumOrphans (range_deletion_util.cpp:549) uses $inc which is
non-idempotent. After K stepdowns during commit cleanup, orphan count inflates by K*N.
"""

import time
import sys
import threading
from pymongo import MongoClient, WriteConcern
from pymongo.errors import OperationFailure


def get_shard0_primary():
    """Find current primary of shard0rs."""
    for host in ["shard0a:27018", "shard0b:27018"]:
        try:
            c = MongoClient(host, directConnection=True, serverSelectionTimeoutMS=3000,
                            uuidRepresentation="standard")
            if c.admin.command("hello").get("isWritablePrimary", False):
                return c, host
            c.close()
        except Exception:
            pass
    return None, None


def get_range_deletion_tasks(client, coll_uuid=None):
    """Read range deletion tasks from config.rangeDeletions."""
    query = {} if coll_uuid is None else {"collectionUuid": coll_uuid}
    return list(client["config"].rangeDeletions.find(query))


def get_coordinator_docs(client):
    """Read migration coordinator documents."""
    return list(client["config"].migrationCoordinators.find({}))


def main():
    print("=" * 70)
    print("Bug 4: Non-idempotent orphan count increment on recovery replay")
    print("Level 2 — State Injection")
    print("=" * 70)

    mongos = MongoClient("mongos", 27017, uuidRepresentation="standard")

    # Step 1: Ensure chunk on shard0 and insert data
    print("\n[Step 1] Ensuring chunk [50, +inf) is on shard0rs...")
    for attempt in range(5):
        try:
            mongos.admin.command("moveChunk", "testdb.testcol",
                                 find={"x": 50}, to="shard0rs")
            time.sleep(3)
            break
        except OperationFailure as e:
            msg = str(e).lower()
            if "already" in msg or "destination shard" in msg:
                print("  Chunk already on shard0rs")
                break
            elif "orphans" in msg or "exceeded" in msg:
                print(f"  Waiting for orphan cleanup (attempt {attempt+1}/5)...")
                time.sleep(15)
            else:
                raise

    # Ensure data exists in the range (so there will be orphans after migration)
    db = mongos["testdb"]
    existing = db.testcol.count_documents({"x": {"$gte": 50}})
    print(f"  Documents in range [50, +inf): {existing}")
    if existing < 10:
        db.testcol.insert_many([{"x": i, "data": f"orphan_{i}"} for i in range(50, 60)])
        existing = db.testcol.count_documents({"x": {"$gte": 50}})
        print(f"  After insert: {existing} documents")

    # Get collection UUID
    coll_info = mongos["testdb"].command("listCollections", filter={"name": "testcol"})
    coll_uuid = coll_info["cursor"]["firstBatch"][0]["info"]["uuid"]
    print(f"  Collection UUID: {coll_uuid}")

    # Step 2: Set failpoints
    print("\n[Step 2] Setting failpoints...")
    shard0_primary, primary_host = get_shard0_primary()
    if not shard0_primary:
        print("  FAILED: No shard0 primary")
        sys.exit(1)
    print(f"  shard0 primary: {primary_host}")

    # Suspend range deletion on ALL shard0 nodes so we can observe the task after recovery
    for host in ["shard0a:27018", "shard0b:27018"]:
        try:
            c = MongoClient(host, directConnection=True, serverSelectionTimeoutMS=2000)
            c.admin.command("configureFailPoint", "suspendRangeDeletion", mode="alwaysOn")
            print(f"  {host}: suspendRangeDeletion=alwaysOn")
            c.close()
        except Exception as e:
            print(f"  {host}: failed to set suspendRangeDeletion: {e}")

    shard0_primary.admin.command("configureFailPoint",
                                 "hangBeforeSendingCommitDecision",
                                 mode="alwaysOn")
    print("  Failpoint set: hangBeforeSendingCommitDecision")
    print("  (pauses AFTER advanceTxn, BEFORE retrieveNumOrphansFromShard)")

    # Step 3: Start M1
    print("\n[Step 3] Starting M1: chunk [50, +inf) from shard0 to shard1...")
    m1_result = {"error": None}

    def run_m1():
        try:
            c = MongoClient("mongos", 27017)
            c.admin.command("moveChunk", "testdb.testcol",
                            find={"x": 50}, to="shard1rs",
                            _secondaryThrottle=False)
            c.close()
        except Exception as e:
            m1_result["error"] = str(e)

    m1_thread = threading.Thread(target=run_m1, daemon=True)
    m1_thread.start()

    # Wait for failpoint (coordinator doc has committed decision)
    print("  Waiting for M1 to hit failpoint...")
    for i in range(60):
        time.sleep(1)
        shard0_primary, _ = get_shard0_primary()
        if shard0_primary:
            docs = get_coordinator_docs(shard0_primary)
            if any(d.get("decision") == "committed" for d in docs):
                print(f"  M1 hit failpoint after {i+1}s")
                break
    else:
        print("  TIMEOUT")
        shard0_primary.admin.command("configureFailPoint",
                                     "hangBeforeSendingCommitDecision", mode="off")
        sys.exit(1)

    # Step 4: Read state and inject orphan count
    print("\n[Step 4] Reading state and injecting orphan count...")

    # Read donor's range deletion task
    shard0_primary, primary_host = get_shard0_primary()
    donor_tasks = get_range_deletion_tasks(shard0_primary, coll_uuid)
    print(f"  Donor (shard0) range deletion tasks: {len(donor_tasks)}")
    donor_task = None
    for t in donor_tasks:
        print(f"    _id={t['_id']}, numOrphanDocs={t.get('numOrphanDocs', 0)}, pending={t.get('pending', 'ABSENT')}")
        donor_task = t

    if not donor_task:
        print("  FAILED: No donor range deletion task found")
        shard0_primary.admin.command("configureFailPoint",
                                     "hangBeforeSendingCommitDecision", mode="off")
        sys.exit(1)

    # Read recipient's range deletion task to get the orphan count
    shard1 = MongoClient("shard1", 27018, directConnection=True, uuidRepresentation="standard")
    recip_tasks = get_range_deletion_tasks(shard1, coll_uuid)
    print(f"  Recipient (shard1) range deletion tasks: {len(recip_tasks)}")
    orphan_count_from_recipient = 0
    for t in recip_tasks:
        orphan_count_from_recipient = t.get("numOrphanDocs", 0)
        print(f"    _id={t['_id']}, numOrphanDocs={orphan_count_from_recipient}")

    # If recipient has no orphan count, use the document count as the orphan count
    # (after migration, all docs in the range on the donor are orphans)
    if orphan_count_from_recipient == 0:
        orphan_count_from_recipient = existing  # Use doc count
        print(f"  Recipient numOrphanDocs=0, using doc count ({existing}) as simulated orphan count")

    # Inject: manually $inc donor's task by the orphan count (simulates one persistUpdatedNumOrphans)
    print(f"\n  INJECTING: $inc numOrphanDocs by {orphan_count_from_recipient} on donor task...")
    w_majority = WriteConcern(w="majority", wtimeout=10000)
    config_db = shard0_primary["config"].with_options(write_concern=w_majority)
    update_result = config_db.rangeDeletions.update_one(
        {"_id": donor_task["_id"]},
        {"$inc": {"numOrphanDocs": orphan_count_from_recipient}}
    )
    print(f"  Updated: matched={update_result.matched_count}, modified={update_result.modified_count}")

    # Verify
    donor_tasks_after = get_range_deletion_tasks(shard0_primary, coll_uuid)
    for t in donor_tasks_after:
        initial_orphans = t.get("numOrphanDocs", 0)
        print(f"  After injection: numOrphanDocs = {initial_orphans}")
        print(f"  Expected after recovery: numOrphanDocs = {initial_orphans + orphan_count_from_recipient} (doubled)")

    # Step 5: Step down shard0 (thread stuck at failpoint, not interruptible)
    print("\n[Step 5] Stepping down shard0 primary...")
    try:
        shard0_primary.admin.command("replSetStepDown", 60, force=True)
    except Exception as e:
        print(f"  Stepdown: {type(e).__name__} (expected)")

    time.sleep(5)

    # Step 6: Find new primary and wait for recovery
    print("\n[Step 6] Finding new primary and waiting for recovery...")
    new_primary = None
    for i in range(30):
        new_primary, new_host = get_shard0_primary()
        if new_primary:
            print(f"  New primary: {new_host}")
            break
        time.sleep(1)
    else:
        print("  FAILED: No new primary")
        sys.exit(1)

    # Wait for recovery to complete
    print("  Waiting for recovery...")
    for i in range(30):
        time.sleep(1)
        docs = get_coordinator_docs(new_primary)
        if not docs:
            print(f"  Recovery completed after {i+1}s")
            break
    else:
        print(f"  Recovery did not complete in 30s (coordinator doc still present)")

    # Step 7: CHECK — has orphan count been doubled?
    print("\n[Step 7] CHECKING: Was orphan count doubled?")
    final_tasks = get_range_deletion_tasks(new_primary, coll_uuid)
    print(f"  Range deletion tasks on new primary: {len(final_tasks)}")

    bug_triggered = False
    for t in final_tasks:
        final_orphans = t.get("numOrphanDocs", 0)
        expected_correct = orphan_count_from_recipient  # Should be N (set once)
        expected_buggy = orphan_count_from_recipient * 2  # Bug: $inc applied twice → 2N

        print(f"    _id={t['_id']}, numOrphanDocs={final_orphans}")
        print(f"    Injected (simulating first persist): {orphan_count_from_recipient}")
        print(f"    Expected if correct ($set): {expected_correct}")
        print(f"    Expected if buggy ($inc twice): {expected_buggy}")

        if final_orphans >= expected_buggy:
            print(f"    ^^^ BUG TRIGGERED: orphan count = {final_orphans} >= 2 * {orphan_count_from_recipient}")
            bug_triggered = True
        elif final_orphans > expected_correct:
            print(f"    ^^^ PARTIAL: orphan count inflated ({final_orphans} > {expected_correct})")
            bug_triggered = True

    if not final_tasks:
        print("  No tasks found (may have been processed by range deleter)")
        print("  Check logs for $inc operations on numOrphanDocs")

    # Print result
    print("\n" + "=" * 70)
    if bug_triggered:
        print("RESULT: BUG REPRODUCED — orphan count inflated by double $inc")
        print()
        print("persistUpdatedNumOrphans (range_deletion_util.cpp:549) uses:")
        print('  $inc << BSON(kNumOrphanDocsFieldName << changeInOrphans)')
        print()
        print("$inc is NOT idempotent. When recovery replays the commit cleanup,")
        print("retrieveNumOrphansFromShard returns N (recipient task still exists),")
        print("and $inc adds N again → total becomes 2N.")
        print()
        print("Fix: Use $set instead of $inc to make the update idempotent.")
    else:
        print("RESULT: Bug not triggered (orphan count not doubled)")
        print("  Recovery may not have replayed persistUpdatedNumOrphans, or")
        print("  retrieveNumOrphansFromShard returned 0 (recipient task deleted).")
    print("=" * 70)

    # Cleanup: disable all failpoints
    print("\n[Cleanup] Disabling failpoints...")
    for host in ["shard0a:27018", "shard0b:27018"]:
        try:
            c = MongoClient(host, directConnection=True, serverSelectionTimeoutMS=2000)
            c.admin.command("configureFailPoint",
                            "hangBeforeSendingCommitDecision", mode="off")
            c.admin.command("configureFailPoint",
                            "suspendRangeDeletion", mode="off")
            c.close()
        except Exception:
            pass

    m1_thread.join(timeout=15)

    mongos.close()
    shard1.close()
    if new_primary:
        new_primary.close()


if __name__ == "__main__":
    main()
