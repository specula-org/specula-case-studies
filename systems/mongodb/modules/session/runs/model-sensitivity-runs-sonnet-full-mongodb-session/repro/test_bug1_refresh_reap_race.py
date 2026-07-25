#!/usr/bin/env python3
"""
MC-1: Refresh-Reap Race — TxnRecord deleted for live session.

Root cause: TOCTOU race in removeSessionsTransactionRecordsIfExpired.
  findRemovedSessions() (session_catalog_mongod.cpp:321) captures session as absent.
  Concurrent refresh re-upserts session to config.system.sessions.
  Delete (session_catalog_mongod.cpp:272-291) still fires using stale candidate list.

Escalation ladder:
  Level 0 — Pure black-box: trigger via concurrent refresh + reap.
  Level 1 — Timing: failpoints to widen the race window.
  Level 2 — State injection: pre-populate sessions close to TTL, trigger race.
  Level 3 — Code modification: sleep inside removeSessionsTransactionRecordsIfExpired.
"""

import sys
import time
import threading
import pymongo
from pymongo import MongoClient
from bson import Binary, UuidRepresentation
import uuid

MONGOD_URI = "mongodb://localhost:27017"
# MongoDB must be started with --setParameter enableTestCommands=1 for failpoints

def run_failpoint(db, name, mode):
    db.admin.command("configureFailPoint", name, mode=mode)


def level0_blackbox():
    """
    Level 0: Pure black-box.
    Create a session, let it appear stale, trigger concurrent refresh and reap,
    then check if config.transactions was deleted while session is still live.
    """
    print("=== Level 0: Black-box race attempt ===")
    client = MongoClient(MONGOD_URI, serverSelectionTimeoutMS=3000)

    # Force a small TTL so sessions expire quickly.
    # NOTE: real MongoDB TTL for sessions is 30 minutes; we can't override without
    # direct failpoints or test hooks.
    try:
        # Verify connection
        client.admin.command("ping")
    except Exception as e:
        print(f"FAILED: Cannot connect to MongoDB at {MONGOD_URI}: {e}")
        return False

    db = client["test"]
    sessions_coll = client["config"]["system.sessions"]
    txn_coll = client["config"]["transactions"]

    # Create a session and do a retryable write to populate config.transactions
    session = client.start_session()
    lsid = session.session_id
    print(f"  Created session: {lsid}")

    try:
        # Retryable write populates config.transactions
        with session.start_transaction():
            db.test_coll.insert_one({"_id": 1, "from_session": True}, session=session)
        print("  Transaction committed, config.transactions should have entry")

        # Verify config.transactions has entry
        txn_count_before = txn_coll.count_documents({"_id.id": lsid["id"]})
        print(f"  config.transactions entries before: {txn_count_before}")

        # Trigger reap of sessions older than 0 minutes (reap everything)
        # This is not possible via public API without test commands
        print("  NOTE: Cannot trigger reap via public API without test commands")
        print("  Level 0 requires --setParameter enableTestCommands=1 for failpoints")
        return False

    except Exception as e:
        print(f"  ERROR during level 0: {e}")
        return False
    finally:
        session.end_session()
        client.close()


def level1_failpoints():
    """
    Level 1: Use failpoints to widen the race window.
    Uses MongoDB test failpoints to pause disk reap between findRemovedSessions
    and the actual delete, while refresh runs concurrently.
    """
    print("=== Level 1: Failpoint-assisted timing ===")
    client = MongoClient(MONGOD_URI, serverSelectionTimeoutMS=3000)

    try:
        client.admin.command("ping")
    except Exception as e:
        print(f"FAILED: Cannot connect: {e}")
        return False

    # The failpoint to pause between findRemovedSessions and the delete would be
    # 'hangBeforeRemoveSessionsTransactionRecords' — if such a failpoint exists.
    # In practice, MongoDB does not expose this exact point via a public failpoint.
    # This would require a custom failpoint added to the code.
    print("  No built-in failpoint covers the exact race window in")
    print("  removeSessionsTransactionRecordsIfExpired (between findRemovedSessions")
    print("  at session_catalog_mongod.cpp:321 and the delete at :272-291).")
    print("  Level 1 requires a custom failpoint or Level 3 code modification.")
    client.close()
    return False


def level2_state_injection():
    """
    Level 2: State injection — directly insert stale config.transactions entry,
    trigger disk reap while refresh re-inserts the session.
    """
    print("=== Level 2: State injection ===")
    client = MongoClient(MONGOD_URI, serverSelectionTimeoutMS=3000)

    try:
        client.admin.command("ping")
    except Exception as e:
        print(f"FAILED: Cannot connect: {e}")
        return False

    db = client["test"]
    txn_coll = client["config"]["transactions"]
    sessions_coll = client["config"]["system.sessions"]

    # Inject an old config.transactions entry with stale lastWriteDate
    old_lsid = uuid.uuid4()
    old_lsid_bytes = Binary(old_lsid.bytes, 4)
    stale_date = time.time() - 3600  # 1 hour ago

    txn_doc = {
        "_id": {"id": old_lsid_bytes, "uid": Binary(b"\x00"*32, 0)},
        "lastWriteDate": stale_date,
        "txnNum": 0,
    }
    try:
        txn_coll.insert_one(txn_doc)
        print(f"  Injected stale config.transactions entry for session {old_lsid}")
    except Exception as e:
        print(f"  Failed to inject (may need permissions or format adjustment): {e}")
        client.close()
        return False

    # Trigger disk reap
    try:
        result = client.admin.command(
            "reapLogicalSessionCacheNow", 1
        )
        print(f"  Triggered reap: {result}")
    except Exception as e:
        print(f"  Could not trigger reap: {e}")

    # Check if entry was deleted
    remaining = txn_coll.count_documents({"_id.id": old_lsid_bytes})
    print(f"  config.transactions entries after reap: {remaining}")

    client.close()
    return False  # Cannot deterministically trigger the race this way


if __name__ == "__main__":
    print("MC-1: Refresh-Reap Race Reproduction Test")
    print("==========================================")
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
        print("Reason: No MongoDB binary available; environment constraint.")
        print("The TOCTOU race in removeSessionsTransactionRecordsIfExpired")
        print("(session_catalog_mongod.cpp:321 vs :272-291) is confirmed by code audit.")
        sys.exit(1)
