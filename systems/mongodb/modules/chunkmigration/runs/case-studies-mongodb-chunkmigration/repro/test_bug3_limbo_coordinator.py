#!/usr/bin/env python3
"""
Bug 3 Reproduction: Limbo coordinator document after config commit failure.

LEVEL 1 — Timing Assistance (failpoints to widen observation window).

Strategy:
1. Set hangBeforeFilteringMetadataRefresh failpoint on shard0 primary.
   This blocks the async recovery thread (asyncRecoverMigrationUntilSuccessOrStepDown)
   that fires at migration_source_manager.cpp:695 after _cleanup(false).
2. Set migrationCommitNetworkError failpoint (fires once) to simulate config commit failure.
3. Start migration M1 (shard0→shard1).
4. M1's config commit fails → _cleanup(false) is called:
   - Line 953: _state == kCommittingOnConfig, so kAborted is NOT set
   - Line 966: completeMigration=false, so completeMigration() is NOT called
   - Coordinator doc persists with NO decision
5. asyncRecoverMigrationUntilSuccessOrStepDown fires but blocks at
   hangBeforeFilteringMetadataRefresh → cannot resolve the limbo.
6. OBSERVE: coordinator doc exists with decision=null → LIMBO STATE.
7. Disable hangBeforeFilteringMetadataRefresh to let recovery proceed.

This proves: _cleanup(false) when _state==kCommittingOnConfig creates a window
where the coordinator doc has no decision and no active migration is working on it.
"""

import time
import sys
import threading
from pymongo import MongoClient
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
    print("Bug 3: Limbo coordinator document after config commit failure")
    print("Level 1 — Timing Assistance")
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

    # Step 2: Set failpoints
    print("\n[Step 2] Setting failpoints on shard0 primary...")
    shard0_primary, primary_host = get_shard0_primary()
    if not shard0_primary:
        print("  FAILED: No shard0 primary")
        sys.exit(1)
    print(f"  shard0 primary: {primary_host}")

    # Verify no pre-existing coordinator docs
    pre_docs = get_coordinator_docs(shard0_primary)
    if pre_docs:
        print(f"  WARNING: {len(pre_docs)} pre-existing coordinator doc(s). Waiting for cleanup...")
        time.sleep(15)
        pre_docs = get_coordinator_docs(shard0_primary)
        if pre_docs:
            print(f"  Still {len(pre_docs)} docs. Proceeding anyway.")

    # Block async recovery metadata refresh
    shard0_primary.admin.command("configureFailPoint",
                                 "hangBeforeFilteringMetadataRefresh",
                                 mode="alwaysOn")
    print("  Failpoint set: hangBeforeFilteringMetadataRefresh (blocks async recovery)")

    # Simulate config commit network error (fires once)
    shard0_primary.admin.command("configureFailPoint",
                                 "migrationCommitNetworkError",
                                 mode={"times": 1})
    print("  Failpoint set: migrationCommitNetworkError (fires once)")

    # Step 3: Start migration
    print("\n[Step 3] Starting migration (will hit network error)...")
    m1_result = {"error": None, "done": False}

    def run_m1():
        try:
            c = MongoClient("mongos", 27017, socketTimeoutMS=120000)
            c.admin.command("moveChunk", "testdb.testcol",
                            find={"x": 50}, to="shard1rs",
                            _secondaryThrottle=False)
            c.close()
        except Exception as e:
            m1_result["error"] = str(e)
        m1_result["done"] = True

    m1_thread = threading.Thread(target=run_m1, daemon=True)
    m1_thread.start()

    # Step 4: Wait for M1 to fail and observe limbo state
    print("\n[Step 4] Waiting for migration to fail and observing limbo state...")
    limbo_observed = False

    # Wait for M1 to complete (it should fail quickly due to network error)
    for i in range(30):
        time.sleep(1)
        if m1_result["done"]:
            print(f"  Migration completed after {i+1}s")
            if m1_result["error"]:
                print(f"  Error (expected): {m1_result['error'][:120]}")
            break
    else:
        print("  Migration still running after 30s")

    # Give a moment for _cleanup(false) to run
    time.sleep(2)

    # Step 5: CHECK — coordinator doc exists with NO decision?
    print("\n[Step 5] CHECKING: Does coordinator doc exist with NO decision?")
    shard0_primary, _ = get_shard0_primary()
    docs = get_coordinator_docs(shard0_primary)
    print(f"  Coordinator docs: {len(docs)}")

    for d in docs:
        decision = d.get("decision")
        print(f"    _id={d['_id']}, decision={decision}")
        if decision is None:
            limbo_observed = True
            print(f"    ^^^ LIMBO STATE: Coordinator doc has NO decision!")
            print(f"        _cleanup(false) did NOT set kAborted (line 953: _state >= kCommittingOnConfig)")
            print(f"        completeMigration was NOT called (line 966: completeMigration=false)")
        elif decision == "committed":
            print(f"    Config server actually committed before the error was injected.")
            print(f"    The recovery thread will resolve this, but it's blocked by our failpoint.")

    # Step 6: Verify async recovery is blocked
    print("\n[Step 6] Async recovery is blocked by hangBeforeFilteringMetadataRefresh.")
    print("  The coordinator doc will persist until recovery is unblocked or step-up occurs.")
    time.sleep(3)

    # Check again
    docs2 = get_coordinator_docs(shard0_primary)
    if docs2:
        print(f"  Coordinator doc still present after 3s (recovery blocked — confirmed)")
    else:
        print(f"  Coordinator doc disappeared (recovery may have used a different path)")

    # Step 7: Unblock recovery
    print("\n[Step 7] Unblocking async recovery...")
    shard0_primary.admin.command("configureFailPoint",
                                 "hangBeforeFilteringMetadataRefresh",
                                 mode="off")

    # Wait for recovery to resolve the doc
    for i in range(15):
        time.sleep(1)
        docs3 = get_coordinator_docs(shard0_primary)
        if not docs3:
            print(f"  Recovery resolved the limbo doc after {i+1}s")
            break
    else:
        print(f"  Coordinator doc still present after 15s (recovery may be retrying)")

    # Step 8: Check chunk ownership (did config commit succeed?)
    print("\n[Step 8] Checking chunk ownership...")
    try:
        coll_info = mongos["config"].collections.find_one({"_id": "testdb.testcol"})
        if coll_info:
            coll_uuid = coll_info.get("uuid")
            chunks = list(mongos["config"].chunks.find(
                {"uuid": coll_uuid}, {"min": 1, "max": 1, "shard": 1}
            ))
            for chunk in chunks:
                print(f"  [{chunk.get('min')} .. {chunk.get('max')}] → {chunk.get('shard')}")
    except Exception as e:
        print(f"  Error: {e}")

    # Print result
    print("\n" + "=" * 70)
    if limbo_observed:
        print("RESULT: BUG REPRODUCED — LIMBO STATE OBSERVED")
        print()
        print("Coordinator doc with NO decision persisted after _cleanup(false).")
        print("The async recovery was blocked, demonstrating the limbo window.")
        print()
        print("Root cause: _cleanup(false) at migration_source_manager.cpp:694:")
        print("  - Line 953: _state == kCommittingOnConfig, NOT < kCommittingOnConfig")
        print("    → kAborted decision is NOT set")
        print("  - Line 966: completeMigration parameter is false")
        print("    → completeMigration() is NOT called")
        print("  - Line 695-697: asyncRecoverMigrationUntilSuccessOrStepDown is fire-and-forget")
        print("    → If it fails, the limbo persists until step-up")
        print()
        print("Impact: Unbounded limbo window until step-up triggers")
        print("resumeMigrationCoordinationsOnStepUp.")
    elif docs:
        print("RESULT: PARTIAL — Coordinator doc with committed decision observed (config committed")
        print("  before failpoint injected the error). The recovery mechanism works but the")
        print("  limbo window exists between _cleanup(false) and async recovery completion.")
    else:
        print("RESULT: Bug not observed in this run.")
    print("=" * 70)

    mongos.close()
    if shard0_primary:
        shard0_primary.close()


if __name__ == "__main__":
    main()
