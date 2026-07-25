#!/usr/bin/env python3
"""
Bug 1 Reproduction v2: Session Reaper Destroys Prepared Transaction (SERVER-105751)

Target: MongoDB 8.0.12 (fixed in 8.0.13)

Key insight: We need to pause 2PC BETWEEN prepare (both shards prepared) and
commit decision. Then kill the session on the participant shard to simulate
the reaper.

Uses failpoint: hangBeforeWritingDecision (pauses after votes collected,
before writing commit/abort decision). This ensures both shards are in
prepared state when we kill the session.
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


def docker_cmd(container, cmd, timeout=10):
    result = subprocess.run(
        ["docker", "exec", container, "mongosh", "--quiet", "--eval", cmd],
        capture_output=True, text=True, timeout=timeout
    )
    return result


def set_failpoint(container, fp, mode="alwaysOn"):
    r = docker_cmd(container, f'db.adminCommand({{configureFailPoint: "{fp}", mode: "{mode}"}})')
    return r


def find_prepared_txns(container):
    """Find all prepared transactions on a shard."""
    r = docker_cmd(container, '''
        var ops = db.adminCommand({currentOp: true, "$all": true}).inprog.filter(
            function(op) {
                return op.transaction && op.transaction.timePreparedMicros;
            }
        );
        ops.forEach(function(op) {
            print("PREPARED:" + JSON.stringify({
                lsid: op.lsid,
                txnNumber: op.transaction.parameters.txnNumber,
                autocommit: op.transaction.parameters.autocommit
            }));
        });
        if (ops.length == 0) print("NONE");
    ''')
    return r.stdout


def kill_session_on_shard(container, lsid_json):
    """Kill a specific session directly on a shard (simulates reaper)."""
    cmd = f'''
        var lsid = {lsid_json};
        var result = db.adminCommand({{killSessions: [lsid]}});
        print("KILL_RESULT:" + JSON.stringify(result));
    '''
    r = docker_cmd(container, cmd)
    return r.stdout


def check_data(key, expected_val):
    """Check data on a specific key through mongos."""
    client = MongoClient(MONGOS_URI)
    doc = client[DB_NAME][COLL_NAME].find_one({"shard_key": key})
    client.close()
    if doc and doc.get("value") == expected_val:
        return True, doc.get("value")
    return False, doc.get("value") if doc else "MISSING"


def attempt(attempt_num):
    print(f"\n{'='*60}")
    print(f"Attempt {attempt_num}")
    print(f"{'='*60}")

    val_s1 = f"bug1v2_a{attempt_num}_s1"
    val_s2 = f"bug1v2_a{attempt_num}_s2"

    # Enable hangBeforeWritingDecision on BOTH shards (in case either is coordinator)
    print("Setting failpoint hangBeforeWritingDecision on both shards...")
    set_failpoint("repro-shard1", "hangBeforeWritingDecision")
    set_failpoint("repro-shard2", "hangBeforeWritingDecision")

    client = MongoClient(MONGOS_URI)
    session = client.start_session()
    txn_result = {"done": False, "error": None, "committed": False}

    def run_txn():
        try:
            session.start_transaction(
                read_concern=ReadConcern("snapshot"),
                write_concern=WriteConcern(w="majority")
            )
            coll = session.client[DB_NAME][COLL_NAME]
            # Write to both shards
            coll.update_one({"shard_key": 1}, {"$set": {"value": val_s1}}, session=session)
            coll.update_one({"shard_key": 100}, {"$set": {"value": val_s2}}, session=session)
            session.commit_transaction()
            txn_result["committed"] = True
            print("  [TXN] Committed successfully")
        except Exception as e:
            txn_result["error"] = e
            print(f"  [TXN] Error: {type(e).__name__}: {e}")
        txn_result["done"] = True

    txn_thread = threading.Thread(target=run_txn, daemon=True)
    txn_thread.start()

    # Wait for the transaction to be blocked at the failpoint
    # (both shards should be prepared by now)
    print("Waiting for transaction to reach prepared state (6s)...")
    time.sleep(6)

    if txn_result["done"]:
        print("  Transaction completed before failpoint! Wrong failpoint or coordinator.")
        set_failpoint("repro-shard1", "hangBeforeWritingDecision", "off")
        set_failpoint("repro-shard2", "hangBeforeWritingDecision", "off")
        client.close()
        return False

    # Check for prepared transactions on both shards
    print("\nChecking for prepared transactions...")
    s1_prepared = find_prepared_txns("repro-shard1")
    s2_prepared = find_prepared_txns("repro-shard2")
    print(f"  shard1: {s1_prepared.strip()}")
    print(f"  shard2: {s2_prepared.strip()}")

    # Find which shard has a prepared transaction we can kill
    # Kill the session on the PARTICIPANT shard (not the coordinator)
    target_shard = None
    target_lsid = None

    for line in s2_prepared.strip().split("\n"):
        if line.startswith("PREPARED:"):
            import json
            info = json.loads(line.replace("PREPARED:", ""))
            target_lsid = json.dumps(info["lsid"])
            target_shard = "repro-shard2"
            break

    if not target_shard:
        for line in s1_prepared.strip().split("\n"):
            if line.startswith("PREPARED:"):
                import json
                info = json.loads(line.replace("PREPARED:", ""))
                target_lsid = json.dumps(info["lsid"])
                target_shard = "repro-shard1"
                break

    if not target_shard:
        print("  No prepared transactions found! Aborting attempt.")
        set_failpoint("repro-shard1", "hangBeforeWritingDecision", "off")
        set_failpoint("repro-shard2", "hangBeforeWritingDecision", "off")
        txn_thread.join(timeout=15)
        try:
            session.end_session()
        except Exception:
            pass
        client.close()
        return False

    # Kill the session on the target shard (simulates session reaper)
    print(f"\n*** Killing session on {target_shard} (simulates reaper) ***")
    print(f"  LSID: {target_lsid}")
    kill_result = kill_session_on_shard(target_shard, target_lsid)
    print(f"  Result: {kill_result.strip()}")

    # Wait a moment for the kill to take effect
    time.sleep(1)

    # Check if the prepared transaction is gone
    print(f"\nChecking prepared transactions on {target_shard} after kill...")
    after_kill = find_prepared_txns(target_shard)
    print(f"  {target_shard}: {after_kill.strip()}")

    # Release the failpoint to let the coordinator proceed
    print("\nReleasing failpoints...")
    set_failpoint("repro-shard1", "hangBeforeWritingDecision", "off")
    set_failpoint("repro-shard2", "hangBeforeWritingDecision", "off")

    # Wait for transaction to complete
    txn_thread.join(timeout=30)

    # Check data consistency
    time.sleep(2)
    s1_ok, s1_val = check_data(1, val_s1)
    s2_ok, s2_val = check_data(100, val_s2)

    print(f"\n--- Data consistency check ---")
    print(f"  shard1 (key=1):   value={s1_val} {'COMMITTED' if s1_ok else 'NOT committed'}")
    print(f"  shard2 (key=100): value={s2_val} {'COMMITTED' if s2_ok else 'NOT committed'}")

    if s1_ok != s2_ok:
        print(f"\n  *** BUG REPRODUCED: TORN COMMIT ***")
        print(f"  One shard committed, the other did not!")
        return True
    elif s1_ok and s2_ok:
        print(f"  Both committed (session kill may have been rejected or too late)")
    else:
        print(f"  Both not committed (transaction was cleanly aborted)")
        if txn_result["error"]:
            print(f"  Error: {txn_result['error']}")

    try:
        session.end_session()
    except Exception:
        pass
    client.close()
    return False


def main():
    print("=" * 60)
    print("Bug 1 v2: Session Reaper vs Prepared Transaction")
    print("SERVER-105751 (Fixed 8.0.13, testing on 8.0.12)")
    print("=" * 60)

    client = MongoClient(MONGOS_URI)
    version = client.admin.command("buildInfo")["version"]
    print(f"MongoDB version: {version}")
    if version >= "8.0.13":
        print("WARNING: Fix is present. Bug unlikely to reproduce.")
    else:
        print(f"Version {version} is vulnerable (fix is in 8.0.13)")
    client.close()

    for i in range(1, 11):
        if attempt(i):
            print("\n*** REPRODUCTION SUCCESSFUL ***")
            return

    print("\n" + "=" * 60)
    print("RESULT: Bug not reproduced in 10 attempts")
    print("  The killSessions command may not destroy prepared")
    print("  transactions on 8.0.12. The reaper's TransactionParticipant")
    print("  destructor path may be different from killSessions.")
    print("=" * 60)


if __name__ == "__main__":
    main()
