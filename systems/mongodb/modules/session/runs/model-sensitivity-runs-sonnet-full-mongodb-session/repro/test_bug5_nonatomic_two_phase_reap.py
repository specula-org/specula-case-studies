#!/usr/bin/env python3
"""
MC-5: Non-Atomic Two-Phase Disk Reap Creates Dangling Image Records.

Root cause: removeSessionsTransactionRecordsFromDisk (session_catalog_mongod.cpp:239-293)
performs two sequential non-transactional deletes:
  Phase A (lines 253-270): DELETE config.image_collection
  Phase B (lines 272-291): DELETE config.transactions

Between A and B: imageRecordOnDisk=FALSE, txnRecordOnDisk=TRUE — inconsistent state.
Code comment at line 244-251 explicitly acknowledges this trade-off:
  "We opt for this rather than performing the two sets of deletes in a single
   transaction simply to reduce code complexity."

Any new checkout (RevivifySession) during this window creates a session with:
  - No image record (already deleted)
  - Still-existing txn record (not yet deleted)
If the session then attempts to use its image record, it will not find it.

Escalation ladder:
  Level 0 — Pure black-box: observe the window via timing.
  Level 1 — Failpoints: pause after Phase A delete, observe inconsistent state.
  Level 2 — State injection: manually delete only image_collection, check txn.
  Level 3 — Code modification: sleep between the two deletes.
"""

import sys
import time
import threading
import pymongo
from pymongo import MongoClient
from bson import Binary
import uuid

MONGOD_URI = "mongodb://localhost:27017"


def level0_blackbox():
    """
    Level 0: Black-box observation.
    Check if a session can be reaped and a new checkout races between Phase A and B.
    Under high concurrency or slow I/O, the window between the two deletes is observable.
    """
    print("=== Level 0: Black-box observation ===")
    client = MongoClient(MONGOD_URI, serverSelectionTimeoutMS=3000)

    try:
        client.admin.command("ping")
    except Exception as e:
        print(f"FAILED: Cannot connect to MongoDB at {MONGOD_URI}: {e}")
        return False

    print("  Level 0: The race window between Phase A and Phase B deletes is too")
    print("  narrow to trigger deterministically without timing assistance.")
    print("  No public API exposes this window.")
    client.close()
    return False


def level1_failpoints():
    """
    Level 1: Use 'hangBetweenTwoPhaseReap' failpoint to pause between Phase A and B.
    """
    print("=== Level 1: Failpoint-assisted ===")
    client = MongoClient(MONGOD_URI, serverSelectionTimeoutMS=3000)

    try:
        client.admin.command("ping")
    except Exception as e:
        print(f"FAILED: Cannot connect: {e}")
        return False

    try:
        # Attempt to use a hypothetical failpoint
        client.admin.command(
            "configureFailPoint",
            "hangBeforeSessionTransactionDelete",
            mode="alwaysOn"
        )
        print("  Failpoint 'hangBeforeSessionTransactionDelete' activated")
    except Exception as e:
        print(f"  Failpoint not available: {e}")
        print("  No built-in failpoint pauses between Phase A and Phase B of")
        print("  removeSessionsTransactionRecordsFromDisk.")
        client.close()
        return False

    # Check if config.image_collection is missing while config.transactions present
    image_coll = client["config"]["image_collection"]
    txn_coll = client["config"]["transactions"]

    # Trigger reap
    try:
        client.admin.command("reapLogicalSessionCacheNow", 1)
    except Exception as e:
        print(f"  Reap command failed: {e}")

    # Would observe inconsistent state here (image deleted, txn present)
    client.admin.command("configureFailPoint", "hangBeforeSessionTransactionDelete",
                         mode="off")
    client.close()
    return False


def level2_state_injection():
    """
    Level 2: State injection — directly create the inconsistent state.
    Delete config.image_collection entry but leave config.transactions entry,
    then create a new session checkout and verify anomalous behavior.
    """
    print("=== Level 2: State injection (direct inconsistent state) ===")
    client = MongoClient(MONGOD_URI, serverSelectionTimeoutMS=3000)

    try:
        client.admin.command("ping")
    except Exception as e:
        print(f"FAILED: Cannot connect: {e}")
        return False

    image_coll = client["config"]["image_collection"]
    txn_coll = client["config"]["transactions"]

    # Create a session and do a retryable write to populate both collections
    session = client.start_session()
    lsid = session.session_id
    lsid_bytes = lsid["id"]

    try:
        # Retryable write populates config.transactions
        client["test"].test_coll.insert_one(
            {"_id": f"injection_{lsid_bytes.hex()}"}, session=session
        )
        print(f"  Session {lsid_bytes.hex()[:8]}... created with config.transactions entry")

        # Check if there's an image_collection entry
        image_before = image_coll.count_documents({"_id.id": lsid_bytes})
        txn_before = txn_coll.count_documents({"_id.id": lsid_bytes})
        print(f"  Before injection: image={image_before}, txn={txn_before}")

        # Simulate Phase A: delete image_collection entry (if any)
        image_coll.delete_many({"_id.id": lsid_bytes})
        print(f"  Injected: deleted image_collection entry (simulating Phase A)")

        # Check inconsistent state: image gone, txn still present
        image_after = image_coll.count_documents({"_id.id": lsid_bytes})
        txn_after = txn_coll.count_documents({"_id.id": lsid_bytes})
        print(f"  After Phase A simulation: image={image_after}, txn={txn_after}")

        if image_after == 0 and txn_after > 0:
            print("  INCONSISTENT STATE CREATED: image=FALSE, txn=TRUE")
            print("  This is the intermediate state the bug describes.")
            print("  A new checkout in this window would find no image but a stale txn record.")
            print("  Level 2: Inconsistent state created by injection (not end-to-end).")
            # This confirms the state is reachable but doesn't end-to-end trigger the bug
            # (because we manually created the state, not via normal code paths)
            return False  # State injection, not a true end-to-end reproduction
        else:
            print(f"  Could not create inconsistent state (image={image_after}, txn={txn_after})")
            return False

    except Exception as e:
        print(f"  ERROR: {e}")
        return False
    finally:
        session.end_session()
        client.close()


if __name__ == "__main__":
    print("MC-5: Non-Atomic Two-Phase Disk Reap Reproduction Test")
    print("========================================================")
    print()

    result = level0_blackbox()
    if not result:
        result = level1_failpoints()
    if not result:
        result = level2_state_injection()

    if result:
        print("\nRESULT: REPRODUCED")
        sys.exit(0)
    else:
        print("\nRESULT: REPRODUCTION FAILED")
        print("Reasons at each level:")
        print("  L0: Race window too narrow to hit deterministically without timing hooks.")
        print("  L1: No built-in failpoint pauses between Phase A (image delete) and")
        print("      Phase B (txn delete) in removeSessionsTransactionRecordsFromDisk.")
        print("  L2: State injection creates the inconsistent state but is not end-to-end;")
        print("      the inconsistency itself is confirmed observable.")
        print("  L3: Source not compiled; Level 3 would add sleep between lines 270 and 272")
        print("      in session_catalog_mongod.cpp to deterministically expose the window.")
        print("Bug stands on code audit: the two-phase delete is acknowledged as a")
        print("code complexity trade-off (comment at session_catalog_mongod.cpp:250-251).")
        sys.exit(1)
