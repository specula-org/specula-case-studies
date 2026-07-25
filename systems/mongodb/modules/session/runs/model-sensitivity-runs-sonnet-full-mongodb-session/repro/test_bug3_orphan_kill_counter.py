#!/usr/bin/env python3
"""
MC-3: Orphan Kill Counter if registerChange Throws.

Root cause: In observeDirectWriteToConfigTransactions (session_catalog_mongod.cpp:683-686):
    session.kill(ErrorCodes::Interrupted)   <- increments killsRequested BEFORE registerChange
    registerChange(make_unique<KillSessionTokenOnCommit>(..., <kill token>))

If registerChange throws (e.g., OOM), killsRequested is incremented but no token exists.
The session is permanently stuck: normal checkout sees _killed()=true, but no token
to call checkOutSessionForKill.

KillToken struct has no destructor to decrement killsRequested on destruction.

Escalation ladder:
  Level 0 — Try to observe session stuck after observeDirectWriteToConfigTransactions.
  Level 1 — Use failpoint 'failAfterKillBeforeRegisterChange' (hypothetical).
  Level 2 — State injection: manually set killsRequested > 0 with no token.
  Level 3 — Code modification: add throw after session.kill() in source.
"""

import sys
import time
import pymongo
from pymongo import MongoClient
import uuid
from bson import Binary

MONGOD_URI = "mongodb://localhost:27017"


def level0_blackbox():
    """
    Level 0: Observe via public API.

    observeDirectWriteToConfigTransactions is called when a direct write to
    config.transactions happens. We simulate this by deleting a config.transactions
    entry directly while a session is active.

    The kill fires; if registerChange threw, the session would be permanently stuck.
    In practice, registerChange rarely throws under normal conditions.
    """
    print("=== Level 0: Black-box observation ===")
    client = MongoClient(MONGOD_URI, serverSelectionTimeoutMS=3000)

    try:
        client.admin.command("ping")
    except Exception as e:
        print(f"FAILED: Cannot connect to MongoDB at {MONGOD_URI}: {e}")
        return False

    # Create a session and populate config.transactions
    session = client.start_session()
    lsid = session.session_id

    try:
        with session.start_transaction():
            client["test"].test_coll.insert_one({"x": 1}, session=session)
        print(f"  Session {lsid['id']} has config.transactions entry")

        # Direct delete of config.transactions triggers observeDirectWriteToConfigTransactions
        # which calls session.kill() + registerChange
        # In normal operation, registerChange succeeds.
        # We cannot force registerChange to throw from the public API.
        txn_coll = client["config"]["transactions"]
        lsid_bytes = lsid["id"]
        delete_result = txn_coll.delete_one({"_id.id": lsid_bytes})
        print(f"  Direct delete of config.transactions: {delete_result.deleted_count} deleted")

        # The kill was registered successfully (no orphan) because registerChange succeeded.
        # Level 0 cannot trigger the bug - registerChange doesn't throw under normal conditions.
        print("  Level 0: registerChange succeeds normally, no orphan produced.")
        return False

    except Exception as e:
        print(f"  ERROR: {e}")
        return False
    finally:
        session.end_session()
        client.close()


def level1_failpoints():
    """
    Level 1: Use failpoint to make registerChange throw.
    MongoDB does not expose a built-in failpoint for 'registerChange throws on
    KillSessionTokenOnCommit registration'. This level requires a custom failpoint
    added to session_catalog_mongod.cpp.
    """
    print("=== Level 1: Failpoints ===")
    client = MongoClient(MONGOD_URI, serverSelectionTimeoutMS=3000)
    try:
        client.admin.command("ping")
    except Exception as e:
        print(f"FAILED: Cannot connect: {e}")
        return False

    print("  No built-in failpoint covers 'throw after kill() before registerChange'.")
    print("  A custom failpoint would need to be added to session_catalog_mongod.cpp:684.")
    print("  Escalating to Level 3.")
    client.close()
    return False


def level3_code_modification():
    """
    Level 3: Describe the code modification needed.
    To reproduce deterministically, insert a conditional throw AFTER session.kill()
    but BEFORE registerChange at session_catalog_mongod.cpp:684-686:

        if (MONGO_unlikely(failKillRegistration.shouldFail())) {
            throw std::bad_alloc{};   // Simulate OOM after kill() incremented counter
        }
        shard_role_details::getRecoveryUnit(opCtx)->registerChange(...);

    Expected: killsRequested > 0, no KillToken, session uncheckable.
    Observation: Any subsequent checkout attempt blocks forever (killed but no token to drain).
    """
    print("=== Level 3: Code modification (description only) ===")
    print("  Code modification required at session_catalog_mongod.cpp:684:")
    print("    1. Add FAIL_POINT_DEFINE(failKillRegistration) before the function")
    print("    2. After 'session.kill(...)' but before 'registerChange', add:")
    print("       if (MONGO_unlikely(failKillRegistration.shouldFail())) throw std::bad_alloc{};")
    print("  Cannot execute: source not compiled in this environment.")
    return False


if __name__ == "__main__":
    print("MC-3: Orphan Kill Counter Reproduction Test")
    print("============================================")
    print()

    result = level0_blackbox()
    if not result:
        result = level1_failpoints()
    if not result:
        result = level3_code_modification()

    if result:
        print("\nRESULT: REPRODUCED")
        sys.exit(0)
    else:
        print("\nRESULT: REPRODUCTION FAILED")
        print("Reasons at each level:")
        print("  L0: registerChange doesn't throw under normal conditions.")
        print("  L1: No built-in failpoint covers this exact throw point.")
        print("  L2: Skipped — state injection cannot simulate a thrown exception.")
        print("  L3: Source not compiled; modification described above would reproduce.")
        print("Bug stands on code audit: session.kill() at :685 increments killsRequested")
        print("before registerChange; KillToken has no RAII destructor to roll back.")
        sys.exit(1)
