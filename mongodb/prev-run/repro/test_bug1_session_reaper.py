#!/usr/bin/env python3
"""
Bug 1 Reproduction: Session Reaper Destroys Prepared Transaction (SERVER-105751)

Target: MongoDB 8.0.12 (fixed in 8.0.13)

Scenario from MC counterexample (26 states):
1. Start a multi-shard transaction writing to both shard1 and shard2
2. The coordinator starts 2PC — both shards prepare
3. Session reaper fires and destroys the prepared session on one shard
4. Coordinator treats NoSuchTransaction as success → torn commit

Approach:
- Start a cross-shard transaction via mongos
- Use configureFailPoint to pause the coordinator AFTER prepare but BEFORE commit
- Lower logicalSessionRefreshMillis to trigger the reaper quickly
- Check if the transaction ends up in a torn state (one shard committed, other lost)

Note: We set logicalSessionRefreshMillis=5000 (5s) in docker-compose to speed
up the reaper cycle. TransactionRecordMinimumLifetimeMinutes=0 makes sessions
eligible for reaping immediately after they become idle.
"""

import os
import sys
import time
import threading
from pymongo import MongoClient
from pymongo.read_concern import ReadConcern
from pymongo.write_concern import WriteConcern
from pymongo.errors import (
    OperationFailure, ConnectionFailure, PyMongoError, ServerSelectionTimeoutError
)

MONGOS_URI = os.environ.get("MONGOS_URI", "mongodb://localhost:27117")
DB_NAME = "bugrepro"
COLL_NAME = "data"
NUM_ATTEMPTS = 20  # Run multiple attempts to hit the race


def get_direct_shard_client(host, port=27017):
    """Connect directly to a shard (bypassing mongos)."""
    return MongoClient(host, port, directConnection=True)


def setup_failpoints(shard_container, enable=True):
    """
    Configure failpoints on a shard to pause 2PC between prepare and commit.

    hangAfterCollectionDrop is not useful here. Instead we use:
    - hangBeforeSendingCommitDecision: pauses coordinator after collecting
      prepare votes but before sending commit to participants.
    """
    import subprocess
    if enable:
        cmd = '''
            db.adminCommand({
                configureFailPoint: "hangBeforeSendingCommitDecision",
                mode: "alwaysOn"
            })
        '''
    else:
        cmd = '''
            db.adminCommand({
                configureFailPoint: "hangBeforeSendingCommitDecision",
                mode: "off"
            })
        '''
    result = subprocess.run(
        ["docker", "exec", shard_container, "mongosh", "--quiet", "--eval", cmd],
        capture_output=True, text=True, timeout=10
    )
    return result.returncode == 0


def force_reap_sessions(shard_container):
    """Force the logical session cache to reap sessions on a shard."""
    import subprocess
    cmd = '''
        db.adminCommand({refreshLogicalSessionCacheNow: 1})
    '''
    result = subprocess.run(
        ["docker", "exec", shard_container, "mongosh", "--quiet", "--eval", cmd],
        capture_output=True, text=True, timeout=10
    )
    return result


def check_transaction_state(shard_container, desc=""):
    """Check for prepared transactions on a shard."""
    import subprocess
    cmd = '''
        var txns = db.getSiblingDB("config").transactions.find().toArray();
        print("Transactions on " + db.adminCommand({replSetGetStatus:1}).set + ": " + txns.length);
        txns.forEach(function(t) {
            print("  txnNum=" + t.txnNum + " state=" + (t.state || "active"));
        });
        var prepared = db.adminCommand({currentOp: true, "$all": true}).inprog.filter(
            function(op) { return op.transaction && op.transaction.parameters; }
        );
        print("Active transaction ops: " + prepared.length);
        prepared.forEach(function(op) {
            print("  lsid=" + JSON.stringify(op.lsid) +
                  " txnNumber=" + op.transaction.parameters.txnNumber +
                  " state=" + (op.transaction.timePreparedMicros ? "prepared" : "active"));
        });
    '''
    result = subprocess.run(
        ["docker", "exec", shard_container, "mongosh", "--quiet", "--eval", cmd],
        capture_output=True, text=True, timeout=10
    )
    if desc:
        print(f"\n--- {desc} ---")
    print(result.stdout)
    if result.stderr:
        print(f"STDERR: {result.stderr}")


def attempt_reproduction(attempt_num):
    """
    Single attempt to reproduce Bug 1.

    Strategy:
    1. Start a cross-shard transaction (writes to both shard1 and shard2)
    2. Use a failpoint to pause the coordinator after prepare
    3. Force the session reaper to fire while the txn is prepared
    4. Release the failpoint and check for torn commit
    """
    print(f"\n{'='*60}")
    print(f"Attempt {attempt_num}")
    print(f"{'='*60}")

    client = MongoClient(MONGOS_URI)
    db = client[DB_NAME]
    coll = db[COLL_NAME]

    # Unique values for this attempt
    val1 = f"bug1_attempt{attempt_num}_s1"
    val2 = f"bug1_attempt{attempt_num}_s2"

    # Enable failpoint on shard1 (will be coordinator for keys < 100)
    print("Enabling failpoint on shard1 (coordinator)...")
    setup_failpoints("repro-shard1", enable=True)

    txn_error = None
    session = client.start_session()

    def run_transaction():
        nonlocal txn_error
        try:
            session.start_transaction(
                read_concern=ReadConcern("snapshot"),
                write_concern=WriteConcern(w="majority")
            )
            # Write to shard1 (key < 100) and shard2 (key >= 100)
            coll_s = session.client[DB_NAME][COLL_NAME]
            coll_s.update_one({"shard_key": 1}, {"$set": {"value": val1}}, session=session)
            coll_s.update_one({"shard_key": 100}, {"$set": {"value": val2}}, session=session)
            # commitTransaction will block at the failpoint
            session.commit_transaction()
            print("  Transaction committed successfully")
        except Exception as e:
            txn_error = e
            print(f"  Transaction error: {e}")

    # Run transaction in a thread (it will block at failpoint)
    txn_thread = threading.Thread(target=run_transaction)
    txn_thread.start()

    # Wait for the transaction to reach the prepared state
    print("Waiting for transaction to reach prepared state...")
    time.sleep(3)

    # Check prepared state on both shards
    check_transaction_state("repro-shard1", "Shard1 state (coordinator)")
    check_transaction_state("repro-shard2", "Shard2 state (participant)")

    # Force session reaper on shard2 (participant)
    print("\nForcing session reaper on shard2 (participant)...")
    for i in range(5):
        force_reap_sessions("repro-shard2")
        time.sleep(1)

    # Check state after reaping
    check_transaction_state("repro-shard2", "Shard2 state AFTER reaping")

    # Release failpoint to let coordinator proceed
    print("\nReleasing failpoint on shard1...")
    setup_failpoints("repro-shard1", enable=False)

    # Wait for transaction thread to complete
    txn_thread.join(timeout=30)

    # Check final state
    time.sleep(2)
    check_transaction_state("repro-shard1", "Shard1 FINAL state")
    check_transaction_state("repro-shard2", "Shard2 FINAL state")

    # Verify data consistency
    print("\n--- Data consistency check ---")
    doc1 = coll.find_one({"shard_key": 1})
    doc2 = coll.find_one({"shard_key": 100})
    s1_committed = doc1 and doc1.get("value") == val1
    s2_committed = doc2 and doc2.get("value") == val2

    print(f"  shard1 (key=1):   value={doc1.get('value') if doc1 else 'MISSING'} "
          f"{'COMMITTED' if s1_committed else 'NOT committed'}")
    print(f"  shard2 (key=100): value={doc2.get('value') if doc2 else 'MISSING'} "
          f"{'COMMITTED' if s2_committed else 'NOT committed'}")

    if s1_committed != s2_committed:
        print(f"\n  *** BUG REPRODUCED: TORN COMMIT ***")
        print(f"  shard1 committed: {s1_committed}, shard2 committed: {s2_committed}")
        return True
    elif s1_committed and s2_committed:
        print(f"  Both committed (no bug this attempt)")
    else:
        print(f"  Both not committed (transaction aborted cleanly)")

    session.end_session()
    client.close()
    return False


def attempt_low_level_reproduction(attempt_num):
    """
    Alternative approach: Use direct shard connections to simulate the reaper.

    Strategy:
    1. Start a cross-shard transaction via mongos
    2. Pause coordinator between prepare and commit via failpoint
    3. Connect directly to participant shard
    4. Kill the session holding the prepared transaction
    5. Release failpoint and check for torn commit
    """
    import subprocess

    print(f"\n{'='*60}")
    print(f"Attempt {attempt_num} (direct session kill)")
    print(f"{'='*60}")

    client = MongoClient(MONGOS_URI)
    db = client[DB_NAME]
    coll = db[COLL_NAME]

    val1 = f"bug1b_attempt{attempt_num}_s1"
    val2 = f"bug1b_attempt{attempt_num}_s2"

    # Enable failpoint on shard1
    setup_failpoints("repro-shard1", enable=True)

    txn_error = None
    session = client.start_session()

    def run_transaction():
        nonlocal txn_error
        try:
            session.start_transaction(
                read_concern=ReadConcern("snapshot"),
                write_concern=WriteConcern(w="majority")
            )
            coll_s = session.client[DB_NAME][COLL_NAME]
            coll_s.update_one({"shard_key": 1}, {"$set": {"value": val1}}, session=session)
            coll_s.update_one({"shard_key": 100}, {"$set": {"value": val2}}, session=session)
            session.commit_transaction()
            print("  Transaction committed successfully")
        except Exception as e:
            txn_error = e
            print(f"  Transaction error: {e}")

    txn_thread = threading.Thread(target=run_transaction)
    txn_thread.start()

    # Wait for prepared state
    time.sleep(3)

    # Get the session ID of the prepared transaction on shard2
    print("Looking for prepared transaction on shard2...")
    cmd = '''
        var ops = db.adminCommand({currentOp: true, "$all": true}).inprog.filter(
            function(op) { return op.transaction && op.transaction.timePreparedMicros; }
        );
        if (ops.length > 0) {
            var lsid = ops[0].lsid;
            print("LSID:" + JSON.stringify(lsid));
            // Kill the session (simulates what the reaper does)
            var result = db.adminCommand({killSessions: [{id: lsid.id}]});
            print("killSessions result: " + JSON.stringify(result));
        } else {
            print("NO_PREPARED_TXN");
        }
    '''
    result = subprocess.run(
        ["docker", "exec", "repro-shard2", "mongosh", "--quiet", "--eval", cmd],
        capture_output=True, text=True, timeout=10
    )
    print(f"  shard2 kill output: {result.stdout.strip()}")

    if "NO_PREPARED_TXN" in result.stdout:
        print("  No prepared transaction found on shard2, skipping")
        setup_failpoints("repro-shard1", enable=False)
        txn_thread.join(timeout=15)
        session.end_session()
        client.close()
        return False

    # Release failpoint
    time.sleep(1)
    setup_failpoints("repro-shard1", enable=False)
    txn_thread.join(timeout=30)

    # Check consistency
    time.sleep(2)
    doc1 = coll.find_one({"shard_key": 1})
    doc2 = coll.find_one({"shard_key": 100})
    s1_committed = doc1 and doc1.get("value") == val1
    s2_committed = doc2 and doc2.get("value") == val2

    print(f"\n--- Data consistency check ---")
    print(f"  shard1 (key=1):   value={doc1.get('value') if doc1 else 'MISSING'} "
          f"{'COMMITTED' if s1_committed else 'NOT committed'}")
    print(f"  shard2 (key=100): value={doc2.get('value') if doc2 else 'MISSING'} "
          f"{'COMMITTED' if s2_committed else 'NOT committed'}")

    if s1_committed != s2_committed:
        print(f"\n  *** BUG REPRODUCED: TORN COMMIT ***")
        return True
    elif s1_committed and s2_committed:
        print(f"  Both committed (no bug this attempt)")
    else:
        print(f"  Both not committed (aborted cleanly, likely the session kill was rejected)")
        if txn_error:
            print(f"  Transaction error: {txn_error}")

    session.end_session()
    client.close()
    return False


def main():
    print("=" * 60)
    print("Bug 1 Reproduction: Session Reaper vs Prepared Transaction")
    print("SERVER-105751 (Fixed 8.0.13, testing on 8.0.12)")
    print("=" * 60)

    # Verify MongoDB version
    client = MongoClient(MONGOS_URI)
    build_info = client.admin.command("buildInfo")
    version = build_info["version"]
    print(f"MongoDB version: {version}")

    if version >= "8.0.13":
        print("WARNING: This version has the fix. Bug may not reproduce.")
    else:
        print(f"Version {version} is vulnerable (fix is in 8.0.13)")

    client.close()

    # Approach 1: Force session reaping
    reproduced = False
    for i in range(1, NUM_ATTEMPTS + 1):
        if attempt_reproduction(i):
            reproduced = True
            break

    if not reproduced:
        print("\n\nApproach 1 (force reaping) did not reproduce. Trying approach 2 (direct session kill)...")
        for i in range(1, NUM_ATTEMPTS + 1):
            if attempt_low_level_reproduction(i):
                reproduced = True
                break

    print("\n" + "=" * 60)
    if reproduced:
        print("RESULT: BUG REPRODUCED — torn cross-shard commit detected")
    else:
        print("RESULT: Bug not reproduced in this run")
        print("  The race window may be too narrow, or the reaper")
        print("  timing does not align with the 2PC window.")
        print("  See test plan in README for manual reproduction steps.")
    print("=" * 60)


if __name__ == "__main__":
    main()
