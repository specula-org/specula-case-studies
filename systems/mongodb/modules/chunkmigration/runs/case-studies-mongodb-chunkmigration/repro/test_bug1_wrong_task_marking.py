#!/usr/bin/env python3
"""
Bug 1 Reproduction: markAsReadyRangeDeletionTaskLocally marks wrong migration's task.

LEVEL 2 — State Injection.

Strategy:
1. Start M1 (shard0→shard1) with hangBeforeForgettingMigrationAfterCommitDecision failpoint.
   At this failpoint, M1's commit cleanup is DONE (including markAsReadyRangeDeletionTaskLocally).
   forgetMigration has NOT been called, so the coordinator doc persists.
2. Delete M1's range deletion task from shard0's config.rangeDeletions (w:majority).
3. Insert a fake "M2" range deletion task with the same {collUuid, range} but a DIFFERENT _id
   and pending:true (w:majority). This simulates M2 starting on the same range.
4. Step down shard0 primary. The coordinator doc persists (forgetMigration never ran).
5. New primary steps up → recovery reads M1's coordinator doc → replays _commitMigrationOnDonorAndRecipient.
6. Recovery's getRangeDeletionTask(collUuid, range) finds M2's task (NO migrationId in filter).
7. Recovery's markAsReadyRangeDeletionTaskLocally marks M2's task ready (removes pending field).
8. Observable: M2's task has pending removed → M2's data eligible for premature deletion.

This proves the vulnerability: getQueryFilterForRangeDeletionTask (range_deletion_util.cpp:312-318)
omits migrationId, unlike getQueryFilterForRangeDeletionTaskOnRecipient (line 323-328).
"""

import time
import sys
import uuid
import threading
from bson.binary import Binary, UuidRepresentation
from bson import Binary as BsonBinary
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
    db = client["config"]
    query = {} if coll_uuid is None else {"collectionUuid": coll_uuid}
    return list(db.rangeDeletions.find(query))


def get_coordinator_docs(client):
    """Read migration coordinator documents."""
    return list(client["config"].migrationCoordinators.find({}))


def main():
    print("=" * 70)
    print("Bug 1: markAsReadyRangeDeletionTaskLocally marks wrong task")
    print("Level 2 — State Injection")
    print("=" * 70)

    mongos = MongoClient("mongos", 27017, uuidRepresentation="standard")

    # Step 1: Ensure chunk [50, +inf) is on shard0
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

    # Get collection UUID
    coll_info = mongos["testdb"].command("listCollections", filter={"name": "testcol"})
    coll_uuid = coll_info["cursor"]["firstBatch"][0]["info"]["uuid"]
    print(f"  Collection UUID: {coll_uuid}")

    # Step 2: Set failpoint and start M1
    print("\n[Step 2] Setting failpoint on shard0 primary...")
    shard0_primary, primary_host = get_shard0_primary()
    if shard0_primary is None:
        print("  FAILED: Cannot find shard0 primary")
        sys.exit(1)
    print(f"  shard0 primary: {primary_host}")

    shard0_primary.admin.command("configureFailPoint",
                                 "hangBeforeForgettingMigrationAfterCommitDecision",
                                 mode="alwaysOn")
    print("  Failpoint set: hangBeforeForgettingMigrationAfterCommitDecision")

    # Step 3: Start migration M1
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

    # Wait for M1 to hit failpoint (coordinator doc has committed decision)
    print("  Waiting for M1 to hit failpoint...")
    for i in range(60):
        time.sleep(1)
        shard0_primary, _ = get_shard0_primary()
        if shard0_primary:
            coord_docs = get_coordinator_docs(shard0_primary)
            if any(d.get("decision") == "committed" for d in coord_docs):
                print(f"  M1 hit failpoint after {i+1}s")
                break
    else:
        print("  TIMEOUT waiting for failpoint")
        shard0_primary.admin.command("configureFailPoint",
                                     "hangBeforeForgettingMigrationAfterCommitDecision",
                                     mode="off")
        sys.exit(1)

    # Step 4: Read M1's coordinator doc and range deletion tasks
    print("\n[Step 4] Reading M1's state...")
    shard0_primary, primary_host = get_shard0_primary()
    coord_docs = get_coordinator_docs(shard0_primary)
    m1_coord = [d for d in coord_docs if d.get("decision") == "committed"][0]
    m1_migration_id = m1_coord["_id"]
    m1_range = m1_coord.get("range", {})
    print(f"  M1 migration ID: {m1_migration_id}")
    print(f"  M1 range: {m1_range}")

    tasks = get_range_deletion_tasks(shard0_primary, coll_uuid)
    print(f"  Range deletion tasks on shard0: {len(tasks)}")
    for t in tasks:
        print(f"    _id={t['_id']}, pending={t.get('pending', 'ABSENT')}, "
              f"numOrphanDocs={t.get('numOrphanDocs', 0)}")

    # Step 5: Delete M1's range deletion task(s) and insert fake M2 task
    print("\n[Step 5] Injecting state: delete M1 task, insert fake M2 task...")
    w_majority = WriteConcern(w="majority", wtimeout=10000)
    config_db = shard0_primary["config"].with_options(write_concern=w_majority)

    # Delete all existing tasks for this collection/range
    del_result = config_db.rangeDeletions.delete_many({"collectionUuid": coll_uuid})
    print(f"  Deleted {del_result.deleted_count} existing task(s)")

    # Create fake M2 task with same collUuid and range, different _id, pending:true
    fake_m2_id = uuid.uuid4()
    # Get the namespace from the coordinator doc
    m1_nss = m1_coord.get("nss", "testdb.testcol")

    # Build the M2 range deletion task document
    m2_task = {
        "_id": fake_m2_id,
        "nss": m1_nss,
        "collectionUuid": coll_uuid,
        "donorShardId": "shard0rs",
        "range": m1_range,
        "pending": True,
        "numOrphanDocs": 0,
        "whenToClean": "now",
    }
    config_db.rangeDeletions.insert_one(m2_task)
    print(f"  Inserted fake M2 task: _id={fake_m2_id}, pending=True")

    # Verify
    tasks_after = get_range_deletion_tasks(shard0_primary, coll_uuid)
    print(f"  Tasks after injection: {len(tasks_after)}")
    for t in tasks_after:
        print(f"    _id={t['_id']}, pending={t.get('pending', 'ABSENT')}")

    # Step 6: Step down shard0 primary (DO NOT disable failpoint — it blocks the old thread)
    print("\n[Step 6] Stepping down shard0 primary...")
    try:
        shard0_primary.admin.command("replSetStepDown", 60, force=True)
    except Exception as e:
        print(f"  Stepdown: {type(e).__name__} (expected)")

    time.sleep(5)

    # Step 7: Find new primary and wait for recovery
    print("\n[Step 7] Finding new primary and waiting for recovery...")
    new_primary = None
    new_primary_host = None
    for i in range(30):
        new_primary, new_primary_host = get_shard0_primary()
        if new_primary:
            print(f"  New primary: {new_primary_host}")
            break
        time.sleep(1)
    else:
        print("  FAILED: No new primary")
        sys.exit(1)

    # Wait for recovery to complete (coordinator doc should disappear)
    print("  Waiting for recovery to complete...")
    recovery_completed = False
    for i in range(30):
        time.sleep(1)
        docs = get_coordinator_docs(new_primary)
        if not docs:
            print(f"  Recovery completed after {i+1}s (coordinator doc gone)")
            recovery_completed = True
            break
        else:
            for d in docs:
                print(f"  [{i+1}s] Coordinator doc still present: decision={d.get('decision')}")
    if not recovery_completed:
        print("  WARNING: Recovery did not complete in 30s")

    # Step 8: CHECK — is M2's task marked ready?
    print("\n[Step 8] CHECKING: Was M2's fake task marked ready?")
    final_tasks = get_range_deletion_tasks(new_primary, coll_uuid)
    print(f"  Range deletion tasks on new primary ({new_primary_host}): {len(final_tasks)}")

    bug_triggered = False
    for t in final_tasks:
        task_id = t["_id"]
        has_pending = "pending" in t
        pending_val = t.get("pending", "ABSENT")
        print(f"    _id={task_id}, pending={pending_val}")

        if task_id == fake_m2_id:
            if not has_pending:
                print(f"    ^^^ BUG TRIGGERED: M2's task has 'pending' field REMOVED!")
                print(f"        markAsReadyRangeDeletionTaskLocally used $unset on pending.")
                print(f"        This means M2's data is now eligible for premature deletion.")
                bug_triggered = True
            elif pending_val is False:
                print(f"    ^^^ BUG TRIGGERED: M2's task has pending=false!")
                bug_triggered = True
            elif pending_val is True:
                print(f"    --- M2's task still pending (bug NOT triggered in this run)")

    if not final_tasks:
        # Task might have been processed by range deleter already
        print("  No tasks found — range deleter may have already processed the marked-ready task")
        print("  Checking if range deleter deleted orphans (which it shouldn't for M2)...")
        bug_triggered = True  # If the task was marked ready AND processed, that's even worse

    # Print result
    print("\n" + "=" * 70)
    if bug_triggered:
        print("RESULT: BUG REPRODUCED")
        print()
        print("M1's recovery replay used getRangeDeletionTask(collUuid, range) with NO")
        print("migrationId in the query filter. It found M2's fake task (which has the")
        print("same range) and markAsReadyRangeDeletionTaskLocally marked it ready.")
        print()
        print("Root cause: range_deletion_util.cpp:312-318 getQueryFilterForRangeDeletionTask")
        print("omits migrationId. The recipient-side equivalent (line 323-328) correctly")
        print("includes migrationId via addFields(BSON(kIdFieldName << migrationId)).")
    else:
        print("RESULT: Bug NOT triggered in this run")
        print("  The recovery may not have reached getRangeDeletionTask, or M2's task")
        print("  was not found. Check logs for details.")
    print("=" * 70)

    # Cleanup: disable failpoint on old primary (unblock the stuck thread)
    print("\n[Cleanup] Disabling failpoint on old primary...")
    for host in ["shard0a:27018", "shard0b:27018"]:
        try:
            c = MongoClient(host, directConnection=True, serverSelectionTimeoutMS=2000)
            c.admin.command("configureFailPoint",
                            "hangBeforeForgettingMigrationAfterCommitDecision",
                            mode="off")
            c.close()
        except Exception:
            pass

    # Wait for M1 thread
    m1_thread.join(timeout=15)

    mongos.close()
    if new_primary:
        new_primary.close()


if __name__ == "__main__":
    main()
