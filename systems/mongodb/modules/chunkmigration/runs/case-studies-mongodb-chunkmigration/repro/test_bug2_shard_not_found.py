#!/usr/bin/env python3
"""
Bug 2 Reproduction: Commit path missing ShardNotFound exception handling.

LEVEL 2 — State Injection.

Strategy:
1. Start M1 (shard0→shard1) with hangBeforeForgettingMigrationAfterCommitDecision.
   M1's commit cleanup is done, forgetMigration hasn't run.
2. Capture M1's coordinator doc (has all required fields).
3. Disable failpoint, let M1 complete normally (coordinator doc deleted).
4. Re-insert a COPY of the coordinator doc, but with recipientShardId changed to
   "nonexistent_shard_xyz" (a shard that doesn't exist in config.shards).
5. Step down shard0 to trigger recovery.
6. Recovery calls _commitMigrationOnDonorAndRecipient, which calls:
   - persistCommitDecision: OK (local update, catches NoMatchingDocument)
   - _waitForReleaseRecipientCriticalSectionFutureIgnoreShardNotFound: catches ShardNotFound
   - advanceTransactionOnRecipient: ShardNotFound NOT caught → THROWS
7. Recovery fails, retries forever. Coordinator doc persists.
8. Observable: coordinator doc still exists after 15s → infinite retry loop → BUG.

This proves the asymmetry: the abort path (migration_coordinator.cpp:361-375) catches
ShardNotFound, but the commit path (line 252-282) does NOT.
"""

import time
import sys
import copy
import uuid
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


def get_coordinator_docs(client):
    """Read migration coordinator documents."""
    return list(client["config"].migrationCoordinators.find({}))


def main():
    print("=" * 70)
    print("Bug 2: Commit path missing ShardNotFound exception handling")
    print("Level 2 — State Injection")
    print("=" * 70)

    mongos = MongoClient("mongos", 27017, uuidRepresentation="standard")

    # Step 1: Ensure chunk on shard0
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

    # Step 2: Set failpoint, start M1, capture coordinator doc
    print("\n[Step 2] Starting M1 with failpoint to capture coordinator doc...")
    shard0_primary, primary_host = get_shard0_primary()
    if not shard0_primary:
        print("  FAILED: No shard0 primary")
        sys.exit(1)
    print(f"  shard0 primary: {primary_host}")

    shard0_primary.admin.command("configureFailPoint",
                                 "hangBeforeForgettingMigrationAfterCommitDecision",
                                 mode="alwaysOn")

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

    # Wait for failpoint
    print("  Waiting for M1 to hit failpoint...")
    captured_doc = None
    for i in range(60):
        time.sleep(1)
        shard0_primary, _ = get_shard0_primary()
        if shard0_primary:
            docs = get_coordinator_docs(shard0_primary)
            committed = [d for d in docs if d.get("decision") == "committed"]
            if committed:
                captured_doc = committed[0]
                print(f"  M1 hit failpoint after {i+1}s")
                print(f"  Captured coordinator doc: recipientShardId={captured_doc.get('recipientShardId')}")
                break
    else:
        print("  TIMEOUT")
        shard0_primary.admin.command("configureFailPoint",
                                     "hangBeforeForgettingMigrationAfterCommitDecision", mode="off")
        sys.exit(1)

    # Step 3: Disable failpoint, let M1 complete, capture the doc
    print("\n[Step 3] Letting M1 complete...")
    shard0_primary, _ = get_shard0_primary()
    shard0_primary.admin.command("configureFailPoint",
                                 "hangBeforeForgettingMigrationAfterCommitDecision", mode="off")
    m1_thread.join(timeout=30)
    if m1_result["error"]:
        print(f"  M1 error: {m1_result['error'][:100]}")
    else:
        print("  M1 completed successfully")

    time.sleep(3)

    # Verify coordinator doc is gone
    shard0_primary, primary_host = get_shard0_primary()
    docs_after = get_coordinator_docs(shard0_primary)
    print(f"  Coordinator docs after M1 complete: {len(docs_after)}")
    if docs_after:
        print("  WARNING: Coordinator doc still present. Waiting...")
        time.sleep(10)

    # Step 4: Create modified coordinator doc with non-existent recipient
    print("\n[Step 4] Injecting coordinator doc with non-existent recipient shard...")

    # Deep copy the captured doc and modify it
    injected_doc = copy.deepcopy(captured_doc)
    injected_doc["_id"] = uuid.uuid4()  # New migration ID
    injected_doc["recipientShardId"] = "nonexistent_shard_xyz"
    # Remove MongoDB internal fields
    injected_doc.pop("__v", None)

    w_majority = WriteConcern(w="majority", wtimeout=10000)
    config_db = shard0_primary["config"].with_options(write_concern=w_majority)
    config_db.migrationCoordinators.insert_one(injected_doc)
    print(f"  Injected doc: _id={injected_doc['_id']}, recipient=nonexistent_shard_xyz")
    print(f"  Decision: {injected_doc.get('decision')}")

    # Step 5: Step down to trigger recovery
    print("\n[Step 5] Stepping down shard0 primary to trigger recovery...")
    try:
        shard0_primary.admin.command("replSetStepDown", 60, force=True)
    except Exception as e:
        print(f"  Stepdown: {type(e).__name__} (expected)")

    time.sleep(5)

    # Step 6: Find new primary
    print("\n[Step 6] Finding new primary...")
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

    # Step 7: Check if coordinator doc persists (recovery stuck)
    print("\n[Step 7] Checking if coordinator doc persists (recovery stuck on ShardNotFound)...")
    doc_persisted = False
    for check in range(3):
        time.sleep(5)
        docs = get_coordinator_docs(new_primary)
        injected = [d for d in docs if d.get("recipientShardId") == "nonexistent_shard_xyz"]
        if injected:
            print(f"  [{(check+1)*5}s] Coordinator doc STILL PRESENT (recovery stuck)")
            print(f"    _id={injected[0]['_id']}, decision={injected[0].get('decision')}, "
                  f"recipient={injected[0].get('recipientShardId')}")
            doc_persisted = True
        else:
            print(f"  [{(check+1)*5}s] Coordinator doc gone (recovery succeeded somehow)")
            doc_persisted = False

    # Print result
    print("\n" + "=" * 70)
    if doc_persisted:
        print("RESULT: BUG REPRODUCED")
        print()
        print("The coordinator doc with a non-existent recipient shard persists indefinitely.")
        print("Recovery calls advanceTransactionOnRecipient('nonexistent_shard_xyz'), which")
        print("throws ShardNotFound. This exception is NOT caught on the commit path")
        print("(migration_coordinator.cpp:252-255), so recovery fails and retries forever.")
        print()
        print("The abort path (line 361-375) correctly catches ShardNotFound:")
        print("  catch (const ExceptionFor<ErrorCodes::ShardNotFound>&) { ... }")
        print("The commit path has NO such catch.")
        print()
        print("Impact: coordinator doc persists forever, blocking future migrations on this range.")
    else:
        print("RESULT: Bug NOT triggered (recovery completed)")
    print("=" * 70)

    # Cleanup: delete the stuck coordinator doc
    print("\n[Cleanup] Removing injected coordinator doc...")
    try:
        new_primary["config"].migrationCoordinators.delete_many(
            {"recipientShardId": "nonexistent_shard_xyz"})
        print("  Cleaned up")
    except Exception as e:
        print(f"  Cleanup error: {e}")

    mongos.close()
    if new_primary:
        new_primary.close()


if __name__ == "__main__":
    main()
