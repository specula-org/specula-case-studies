#!/usr/bin/env python3
"""
Bug 3 Reproduction: Router Abort Races with 2PC Commit (SERVER-66067)

Target: MongoDB 8.0.12 (SERVER-66067 was fixed earlier, likely pre-8.0)

Scenario from MC counterexample (32 states):
1. Router starts a multi-shard transaction
2. Router sends best-effort abort (e.g., client timeout/disconnect)
3. Concurrently, the 2PC coordinator collects votes and commits
4. The abort arrives at a participant AFTER commit is decided
5. Result: one shard commits, the other aborts — torn commit

Approach:
- Start a cross-shard transaction
- Use configureFailPoint to pause 2PC at prepare stage
- From a separate connection, abort the transaction
- Release failpoint and race the commit against the abort
- Check for torn commit

Note: This bug is likely fixed in 8.0.x. This test documents the
reproduction approach; if it doesn't reproduce, we provide the
detailed test plan for running against an older version.
"""

import os
import sys
import time
import threading
import subprocess
from pymongo import MongoClient
from pymongo.read_concern import ReadConcern
from pymongo.write_concern import WriteConcern
from pymongo.errors import OperationFailure, PyMongoError

MONGOS_URI = os.environ.get("MONGOS_URI", "mongodb://localhost:27117")
DB_NAME = "bugrepro"
COLL_NAME = "data"
NUM_ATTEMPTS = 10


def setup_failpoint(container, failpoint, mode="alwaysOn"):
    """Configure a failpoint on a MongoDB container."""
    cmd = f'db.adminCommand({{configureFailPoint: "{failpoint}", mode: "{mode}"}})'
    result = subprocess.run(
        ["docker", "exec", container, "mongosh", "--quiet", "--eval", cmd],
        capture_output=True, text=True, timeout=10
    )
    return result.returncode == 0


def attempt_reproduction(attempt_num):
    """
    Attempt to reproduce the router abort race.

    The race condition:
    - RouterTxnAbort sends abort msg to participants
    - Coordinator independently collects votes and writes commit decision
    - Abort msg arrives at participant after commit decision is persisted
    """
    print(f"\n{'='*60}")
    print(f"Attempt {attempt_num}")
    print(f"{'='*60}")

    client = MongoClient(MONGOS_URI)
    db = client[DB_NAME]
    coll = db[COLL_NAME]

    val1 = f"bug3_attempt{attempt_num}_s1"
    val2 = f"bug3_attempt{attempt_num}_s2"

    # Enable failpoint: pause coordinator after writing participant list
    # but before sending prepare messages
    print("Enabling failpoint: hangAfterCollectingParticipantList...")
    # Different failpoints to try (availability depends on version):
    # - hangBeforeCommittingTwoPhaseCommitTransaction
    # - hangBeforeSendingCommitDecision
    # - hangAfterStartingCoordinateCommit
    setup_failpoint("repro-shard1", "hangBeforeSendingCommitDecision")

    session = client.start_session()
    txn_result = {"done": False, "error": None}

    def run_transaction():
        try:
            session.start_transaction(
                read_concern=ReadConcern("snapshot"),
                write_concern=WriteConcern(w="majority")
            )
            coll_s = session.client[DB_NAME][COLL_NAME]
            # Write to both shards
            coll_s.update_one({"shard_key": 1}, {"$set": {"value": val1}}, session=session)
            coll_s.update_one({"shard_key": 100}, {"$set": {"value": val2}}, session=session)
            # Commit — will hang at failpoint
            session.commit_transaction()
            txn_result["done"] = True
            print("  Transaction committed")
        except Exception as e:
            txn_result["error"] = e
            print(f"  Transaction error: {e}")

    # Start transaction in background
    txn_thread = threading.Thread(target=run_transaction)
    txn_thread.start()

    # Wait for transaction to reach the failpoint (coordinator paused)
    time.sleep(3)

    # Now try to abort the transaction from a separate client connection.
    # This simulates the router's implicitAbort() triggered by client disconnect.
    print("Sending abort from separate connection...")
    try:
        # Use the same session ID but from a different client connection
        # to simulate what implicitAbort does
        abort_client = MongoClient(MONGOS_URI)
        # We can't easily share a session across clients in pymongo,
        # but we can kill the session
        lsid = session.session_id
        print(f"  Session ID: {lsid}")

        # Send killSessions to all shards via mongos
        try:
            abort_client.admin.command("killSessions", [lsid])
            print("  killSessions sent successfully")
        except OperationFailure as e:
            print(f"  killSessions error (expected): {e}")
        abort_client.close()
    except Exception as e:
        print(f"  Abort attempt error: {e}")

    # Release failpoint to let coordinator proceed
    time.sleep(1)
    print("Releasing failpoint...")
    setup_failpoint("repro-shard1", "hangBeforeSendingCommitDecision", mode="off")

    # Wait for transaction to complete
    txn_thread.join(timeout=30)

    # Check data consistency
    time.sleep(2)
    fresh_client = MongoClient(MONGOS_URI)
    fresh_coll = fresh_client[DB_NAME][COLL_NAME]
    doc1 = fresh_coll.find_one({"shard_key": 1})
    doc2 = fresh_coll.find_one({"shard_key": 100})
    s1_committed = doc1 and doc1.get("value") == val1
    s2_committed = doc2 and doc2.get("value") == val2

    print(f"\n--- Data consistency check ---")
    print(f"  shard1 (key=1):   value={doc1.get('value') if doc1 else 'MISSING'} "
          f"{'COMMITTED' if s1_committed else 'NOT committed'}")
    print(f"  shard2 (key=100): value={doc2.get('value') if doc2 else 'MISSING'} "
          f"{'COMMITTED' if s2_committed else 'NOT committed'}")

    torn = s1_committed != s2_committed
    if torn:
        print(f"\n  *** BUG REPRODUCED: TORN COMMIT ***")
    elif s1_committed and s2_committed:
        print(f"  Both committed (abort lost or rejected — fix may be present)")
    else:
        print(f"  Both not committed (abort won the race, or txn was cleanly aborted)")

    session.end_session()
    client.close()
    fresh_client.close()
    return torn


def main():
    print("=" * 60)
    print("Bug 3 Reproduction: Router Abort Races with 2PC Commit")
    print("SERVER-66067")
    print("=" * 60)

    client = MongoClient(MONGOS_URI)
    build_info = client.admin.command("buildInfo")
    version = build_info["version"]
    print(f"MongoDB version: {version}")
    print("NOTE: SERVER-66067 was fixed pre-8.0. This test is expected to")
    print("NOT reproduce on 8.0.x. Included for completeness.")
    client.close()

    reproduced = False
    for i in range(1, NUM_ATTEMPTS + 1):
        if attempt_reproduction(i):
            reproduced = True
            break

    print("\n" + "=" * 60)
    if reproduced:
        print("RESULT: BUG REPRODUCED — torn cross-shard commit detected")
    else:
        print("RESULT: Bug not reproduced (expected on 8.0.x — fix is present)")
        print("  To reproduce, use MongoDB 4.4-5.0 era versions.")
    print("=" * 60)


if __name__ == "__main__":
    main()
