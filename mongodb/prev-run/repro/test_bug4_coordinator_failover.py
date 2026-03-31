#!/usr/bin/env python3
"""
Bug 4 Reproduction: 2PC Atomicity Violation Under Coordinator Failover

Target: MongoDB 8.0.12 (SERVER-106075 fixed in 8.0.16)

Scenario from MC counterexample (29 states):
1. Multi-shard transaction writes to s1 (coordinator) and s2
2. 2PC: coordinator writes participant list, both shards prepare
3. Both shards crash (Restart(s2), then Restart(s1))
4. Coordinator recovers from coordDoc, re-adds txn to shardTxns
5. BUT shardPreparedTxns is NOT restored → ShardTxnAbort can fire
6. Abort fires on coordinator's own shard (as participant)
7. Coordinator re-collects votes and writes commit decision
8. Result: coordDoc says "commit" but coordinator shard has aborted

Approach:
- Start a cross-shard transaction
- Use failpoint to pause after prepare
- Stop shard2, then shard1 (simulating double crash)
- Restart both shards
- Check if transaction state is consistent after recovery
"""

import os
import sys
import time
import threading
import subprocess
from pymongo import MongoClient
from pymongo.read_concern import ReadConcern
from pymongo.write_concern import WriteConcern
from pymongo.errors import (
    OperationFailure, ConnectionFailure, PyMongoError,
    ServerSelectionTimeoutError, AutoReconnect
)

MONGOS_URI = os.environ.get("MONGOS_URI", "mongodb://localhost:27117")
DB_NAME = "bugrepro"
COLL_NAME = "data"
NUM_ATTEMPTS = 5


def docker_cmd(container, mongo_cmd, timeout=10):
    """Run a mongosh command on a container."""
    result = subprocess.run(
        ["docker", "exec", container, "mongosh", "--quiet", "--eval", mongo_cmd],
        capture_output=True, text=True, timeout=timeout
    )
    return result


def setup_failpoint(container, failpoint, mode="alwaysOn"):
    """Configure a failpoint."""
    cmd = f'db.adminCommand({{configureFailPoint: "{failpoint}", mode: "{mode}"}})'
    return docker_cmd(container, cmd)


def stop_container(container):
    """Stop a Docker container (simulates crash)."""
    result = subprocess.run(
        ["docker", "stop", "-t", "2", container],
        capture_output=True, text=True, timeout=15
    )
    print(f"  Stopped {container}: {result.stdout.strip()}")
    return result.returncode == 0


def start_container(container):
    """Start a Docker container (simulates restart)."""
    result = subprocess.run(
        ["docker", "start", container],
        capture_output=True, text=True, timeout=15
    )
    print(f"  Started {container}: {result.stdout.strip()}")
    return result.returncode == 0


def wait_for_container(container, max_wait=30):
    """Wait for a container's mongod to become available."""
    for i in range(max_wait):
        try:
            result = subprocess.run(
                ["docker", "exec", container, "mongosh", "--quiet",
                 "--eval", "db.runCommand({ping:1})"],
                capture_output=True, text=True, timeout=5
            )
            if result.returncode == 0:
                return True
        except subprocess.TimeoutExpired:
            pass
        time.sleep(1)
    return False


def wait_for_primary(container, max_wait=60):
    """Wait for a replica set member to become primary."""
    for i in range(max_wait):
        try:
            result = docker_cmd(container,
                'var st = rs.status(); print(st.myState);', timeout=5)
            if result.stdout.strip() == "1":  # PRIMARY
                return True
        except Exception:
            pass
        time.sleep(1)
    return False


def check_coordinator_docs(container, desc=""):
    """Check coordinator documents on a shard."""
    cmd = '''
        var docs = db.getSiblingDB("config").getCollection("transaction_coordinators").find().toArray();
        print("Coordinator docs: " + docs.length);
        docs.forEach(function(d) {
            print("  id=" + JSON.stringify(d._id) + " state=" + d.state);
        });
    '''
    result = docker_cmd(container, cmd)
    if desc:
        print(f"\n--- {desc} ---")
    print(result.stdout)


def attempt_reproduction(attempt_num):
    """
    Attempt to reproduce Bug 4.

    The key race: after double crash and recovery, the coordinator
    recovers from coordDoc but the participant prepared state is not
    protected from spontaneous abort.
    """
    print(f"\n{'='*60}")
    print(f"Attempt {attempt_num}")
    print(f"{'='*60}")

    client = MongoClient(MONGOS_URI, serverSelectionTimeoutMS=5000)
    db = client[DB_NAME]
    coll = db[COLL_NAME]

    val1 = f"bug4_attempt{attempt_num}_s1"
    val2 = f"bug4_attempt{attempt_num}_s2"

    # Step 1: Enable failpoint to pause coordinator after prepare votes
    # collected but before commit decision is written.
    # This creates the window where prepared txns exist but no commit
    # decision is persisted yet.
    print("Step 1: Enabling failpoint on shard1 (coordinator)...")
    fp_result = setup_failpoint("repro-shard1",
                                "hangBeforeSendingCommitDecision")
    print(f"  Failpoint result: {fp_result.stdout.strip()}")

    # Step 2: Start cross-shard transaction
    print("Step 2: Starting cross-shard transaction...")
    session = client.start_session()
    txn_result = {"done": False, "error": None}

    def run_transaction():
        try:
            session.start_transaction(
                read_concern=ReadConcern("snapshot"),
                write_concern=WriteConcern(w="majority")
            )
            coll_s = session.client[DB_NAME][COLL_NAME]
            coll_s.update_one({"shard_key": 1}, {"$set": {"value": val1}},
                              session=session)
            coll_s.update_one({"shard_key": 100}, {"$set": {"value": val2}},
                              session=session)
            session.commit_transaction()
            txn_result["done"] = True
            print("  Transaction committed")
        except Exception as e:
            txn_result["error"] = e
            print(f"  Transaction error: {type(e).__name__}: {e}")

    txn_thread = threading.Thread(target=run_transaction)
    txn_thread.start()

    # Wait for prepared state
    time.sleep(4)
    print("  Transaction should be in prepared state (blocked at failpoint)")

    # Step 3: Check prepared transactions
    check_coordinator_docs("repro-shard1", "Coordinator docs on shard1")

    # Step 4: Crash shard2 first (participant), then shard1 (coordinator)
    # This matches the counterexample: Restart(s2) then Restart(s1)
    print("\nStep 4: Crashing shards (double failure)...")
    print("  Stopping shard2 (participant)...")
    stop_container("repro-shard2")
    time.sleep(1)

    print("  Stopping shard1 (coordinator)...")
    stop_container("repro-shard1")
    time.sleep(2)

    # The transaction thread will get a connection error
    txn_thread.join(timeout=15)
    if txn_result["error"]:
        print(f"  Transaction thread terminated: {type(txn_result['error']).__name__}")

    # Step 5: Restart both shards
    print("\nStep 5: Restarting shards...")
    start_container("repro-shard1")
    start_container("repro-shard2")

    print("  Waiting for shard1 to become primary...")
    if not wait_for_primary("repro-shard1", max_wait=60):
        print("  ERROR: shard1 did not become primary")
        return False

    print("  Waiting for shard2 to become primary...")
    if not wait_for_primary("repro-shard2", max_wait=60):
        print("  ERROR: shard2 did not become primary")
        return False

    # Wait for coordinator recovery to run
    print("  Waiting for coordinator recovery (5s)...")
    time.sleep(5)

    # Step 6: Check coordinator docs and transaction state after recovery
    check_coordinator_docs("repro-shard1", "Coordinator docs after recovery")

    # Step 7: Check data consistency
    print("\nStep 7: Checking data consistency...")
    time.sleep(3)  # Allow recovery to complete

    # Reconnect to mongos
    try:
        fresh_client = MongoClient(MONGOS_URI, serverSelectionTimeoutMS=10000)
        fresh_coll = fresh_client[DB_NAME][COLL_NAME]

        doc1 = fresh_coll.find_one({"shard_key": 1})
        doc2 = fresh_coll.find_one({"shard_key": 100})
        s1_val = doc1.get("value") if doc1 else "MISSING"
        s2_val = doc2.get("value") if doc2 else "MISSING"
        s1_committed = s1_val == val1
        s2_committed = s2_val == val2

        print(f"  shard1 (key=1):   value={s1_val} "
              f"{'COMMITTED' if s1_committed else 'NOT committed'}")
        print(f"  shard2 (key=100): value={s2_val} "
              f"{'COMMITTED' if s2_committed else 'NOT committed'}")

        if s1_committed != s2_committed:
            print(f"\n  *** BUG REPRODUCED: TORN COMMIT ***")
            fresh_client.close()
            return True
        elif s1_committed and s2_committed:
            print(f"  Both committed (recovery completed successfully)")
        else:
            print(f"  Both not committed (transaction aborted or still recovering)")

        # Also check the coordinator doc state
        print("\n  Checking coordinator doc final state on shard1...")
        cmd = '''
            var docs = db.getSiblingDB("config").getCollection("transaction_coordinators").find().toArray();
            docs.forEach(function(d) {
                print("  coord_doc: " + JSON.stringify(d));
            });
        '''
        docker_cmd("repro-shard1", cmd)

        fresh_client.close()
    except Exception as e:
        print(f"  Connection error during consistency check: {e}")

    try:
        session.end_session()
    except Exception:
        pass
    client.close()
    return False


def main():
    print("=" * 60)
    print("Bug 4 Reproduction: Coordinator Failover Atomicity Violation")
    print("SERVER-106075 (Fixed 8.0.16, testing on 8.0.12)")
    print("=" * 60)

    client = MongoClient(MONGOS_URI)
    build_info = client.admin.command("buildInfo")
    version = build_info["version"]
    print(f"MongoDB version: {version}")

    if version >= "8.0.16":
        print("WARNING: This version has the fix. Bug may not reproduce.")
    else:
        print(f"Version {version} is potentially vulnerable (fix is in 8.0.16)")
    client.close()

    reproduced = False
    for i in range(1, NUM_ATTEMPTS + 1):
        if attempt_reproduction(i):
            reproduced = True
            break

        # Re-verify cluster is healthy before next attempt
        print("\nVerifying cluster health...")
        time.sleep(3)
        try:
            c = MongoClient(MONGOS_URI, serverSelectionTimeoutMS=10000)
            c.admin.command("ping")
            c.close()
            print("  Cluster healthy")
        except Exception as e:
            print(f"  Cluster unhealthy, waiting: {e}")
            time.sleep(10)

    print("\n" + "=" * 60)
    if reproduced:
        print("RESULT: BUG REPRODUCED — torn commit after coordinator failover")
    else:
        print("RESULT: Bug not reproduced in this run")
        print("  The recovery protocol may have sufficient safeguards in 8.0.12,")
        print("  or the race window is too narrow. SERVER-106075 (fixed 8.0.16)")
        print("  addresses a specific error classification issue; the general")
        print("  coordinator failover race may require specific error conditions.")
    print("=" * 60)


if __name__ == "__main__":
    main()
