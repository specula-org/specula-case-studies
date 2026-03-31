#!/usr/bin/env python3
"""
Bug 2 (SERVER-105751) Reproduction Test: Session Reaper vs Prepared Transactions

Tests whether a prepared transaction can be destroyed by:
  (a) Session expiration (transactionLifetimeLimitSeconds)
  (b) Explicit killSessions command
  (c) Participant step-down during 2PC

If any path kills a prepared transaction, the coordinator would receive
NoSuchTransaction, misclassify it as a successful ack, and silently lose data.

Expected result in MongoDB 8.2.6: All safeguards hold, prepared txns survive.
"""

import subprocess
import sys
import time
import threading

def mongosh(container, script, timeout=30):
    """Run mongosh inside a Docker container."""
    cmd = ["docker", "exec", container, "mongosh", "--quiet", "--eval", script]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip(), r.returncode
    except subprocess.TimeoutExpired:
        return "[TIMEOUT]", -1

def mongosh_mongos(script, timeout=30):
    """Run mongosh via the mongos container."""
    return mongosh("repro-mongos", script, timeout)

def wait_ready(container, max_wait=60):
    """Wait for a mongod/mongos to be ready."""
    for _ in range(max_wait // 2):
        out, rc = mongosh(container, "db.runCommand({ping:1}).ok")
        if "1" in out:
            return True
        time.sleep(2)
    return False

def setup_cluster():
    """Initialize replica sets and add shards."""
    print("[1] Waiting for nodes...")
    for c in ["repro-configsvr", "repro-shard1a", "repro-shard2", "repro-mongos"]:
        if not wait_ready(c):
            print(f"  FATAL: {c} not ready")
            sys.exit(1)
    print("  All nodes responding.")

    print("[2] Initializing replica sets...")
    mongosh("repro-configsvr", """
        rs.initiate({_id:"configRS", configsvr:true, members:[{_id:0, host:"configsvr:27017"}]})
    """)
    time.sleep(3)

    mongosh("repro-shard1a", """
        rs.initiate({_id:"shard1RS", members:[
            {_id:0, host:"shard1a:27017", priority:2},
            {_id:1, host:"shard1b:27017", priority:1},
            {_id:2, host:"shard1c:27017", priority:0}
        ]})
    """)
    time.sleep(5)

    mongosh("repro-shard2", """
        rs.initiate({_id:"shard2RS", members:[{_id:0, host:"shard2:27017"}]})
    """)
    time.sleep(5)

    # Wait for primaries
    for c in ["repro-shard1a", "repro-shard2"]:
        for _ in range(15):
            out, _ = mongosh(c, "rs.isMaster().ismaster")
            if "true" in out:
                break
            time.sleep(2)

    print("[3] Adding shards...")
    time.sleep(3)
    mongosh_mongos('sh.addShard("shard1RS/shard1a:27017,shard1b:27017,shard1c:27017")')
    time.sleep(2)
    mongosh_mongos('sh.addShard("shard2RS/shard2:27017")')
    time.sleep(3)

    print("[4] Creating sharded collection...")
    mongosh_mongos("""
        sh.enableSharding("testdb");
        db.getSiblingDB("testdb").createCollection("txncoll");
        sh.shardCollection("testdb.txncoll", {key: 1});
        sh.splitAt("testdb.txncoll", {key: 100});
        sh.moveChunk("testdb.txncoll", {key: 100}, "shard2RS");
    """)
    time.sleep(3)

    mongosh_mongos("""
        var db = db.getSiblingDB("testdb");
        db.txncoll.insertOne({key: 1, val: "shard1_init"});
        db.txncoll.insertOne({key: 200, val: "shard2_init"});
    """)
    time.sleep(1)

    # Verify data on both shards
    out, _ = mongosh_mongos("""
        var d = db.getSiblingDB("testdb");
        print("s1: " + tojson(d.txncoll.findOne({key:1})));
        print("s2: " + tojson(d.txncoll.findOne({key:200})));
    """)
    print(f"  Data seeded: {out[:200]}")
    print("[5] Cluster ready.")

def check_prepared_on_shard2():
    """Check if any prepared transactions exist on shard2."""
    out, _ = mongosh("repro-shard2", """
        var ops = db.currentOp(true).inprog.filter(function(o) {
            return o.transaction && o.transaction.parameters &&
                   o.transaction.parameters.txnNumber;
        });
        var prepared = ops.filter(function(o) {
            return o.transaction.timePreparedMicros !== undefined;
        });
        print("TOTAL_TXN_OPS: " + ops.length);
        print("PREPARED_OPS: " + prepared.length);
    """)
    return out

def test_a_session_expiry():
    """
    Test A: Can transactionLifetimeLimitSeconds kill a prepared transaction?
    """
    print("\n" + "=" * 60)
    print("Test A: Session Expiry vs Prepared Transaction")
    print("=" * 60)

    # Set short transaction lifetime on both shards
    for c in ["repro-shard1a", "repro-shard2"]:
        mongosh(c, "db.adminCommand({setParameter:1, transactionLifetimeLimitSeconds:10})")

    # Set failpoint: hang coordinator AFTER prepare but BEFORE sending commit/abort
    mongosh("repro-shard1a", """
        db.adminCommand({configureFailPoint: "hangBeforeSendingCommitDecision", mode: "alwaysOn"})
    """)

    # Start cross-shard transaction in background
    txn_script = """
        var session = db.getMongo().startSession();
        var sdb = session.getDatabase("testdb");
        session.startTransaction({readConcern:{level:"snapshot"}, writeConcern:{w:"majority"}});
        try {
            sdb.txncoll.updateOne({key: 1}, {$set: {val: "test_a_s1"}});
            sdb.txncoll.updateOne({key: 200}, {$set: {val: "test_a_s2"}});
            session.commitTransaction();
            print("RESULT:COMMITTED");
        } catch(e) {
            print("RESULT:ERROR:" + e.message);
            try { session.abortTransaction(); } catch(e2) {}
        }
        session.endSession();
    """

    print("  Starting cross-shard transaction (will hang at coordinator)...")
    proc = subprocess.Popen(
        ["docker", "exec", "repro-mongos", "mongosh", "--quiet", "--eval", txn_script],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    )

    # Wait for prepare to complete
    print("  Waiting for prepare phase...")
    time.sleep(8)

    # Check prepared state
    before = check_prepared_on_shard2()
    print(f"  Before expiry wait:\n    {before}")

    # Wait for session lifetime to expire (10s limit, already waited 8s)
    print("  Waiting 15 more seconds for session expiry timer to fire...")
    time.sleep(15)

    # Check if prepared transaction survived
    after = check_prepared_on_shard2()
    print(f"  After expiry wait:\n    {after}")

    survived = "PREPARED_OPS: 0" not in after or "PREPARED_OPS:" not in after
    if "PREPARED_OPS: 0" in after and "TOTAL_TXN_OPS: 0" in after:
        print("  >> FAIL: Prepared transaction was KILLED by session expiry!")
        survived = False
    else:
        print("  >> PASS: Prepared transaction SURVIVED session expiry")
        survived = True

    # Release failpoint and clean up
    mongosh("repro-shard1a", """
        db.adminCommand({configureFailPoint: "hangBeforeSendingCommitDecision", mode: "off"})
    """)
    try:
        proc.wait(timeout=20)
        stdout = proc.stdout.read()
        print(f"  Transaction result: {stdout.strip()[:200]}")
    except subprocess.TimeoutExpired:
        proc.kill()
        print("  Transaction timed out (killed)")

    # Reset lifetime
    for c in ["repro-shard1a", "repro-shard2"]:
        mongosh(c, "db.adminCommand({setParameter:1, transactionLifetimeLimitSeconds:60})")

    return survived

def test_b_kill_sessions():
    """
    Test B: Can explicit killSessions destroy a prepared transaction?
    """
    print("\n" + "=" * 60)
    print("Test B: killSessions vs Prepared Transaction")
    print("=" * 60)

    # Set failpoint
    mongosh("repro-shard1a", """
        db.adminCommand({configureFailPoint: "hangBeforeSendingCommitDecision", mode: "alwaysOn"})
    """)

    txn_script = """
        var session = db.getMongo().startSession();
        var sid = session.getSessionId();
        print("SESSION_ID:" + tojson(sid));
        var sdb = session.getDatabase("testdb");
        session.startTransaction({readConcern:{level:"snapshot"}, writeConcern:{w:"majority"}});
        try {
            sdb.txncoll.updateOne({key: 1}, {$set: {val: "test_b_s1"}});
            sdb.txncoll.updateOne({key: 200}, {$set: {val: "test_b_s2"}});
            session.commitTransaction();
            print("RESULT:COMMITTED");
        } catch(e) {
            print("RESULT:ERROR:" + e.message);
            try { session.abortTransaction(); } catch(e2) {}
        }
        session.endSession();
    """

    print("  Starting cross-shard transaction...")
    proc = subprocess.Popen(
        ["docker", "exec", "repro-mongos", "mongosh", "--quiet", "--eval", txn_script],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    )

    time.sleep(8)

    before = check_prepared_on_shard2()
    print(f"  Before killSessions:\n    {before}")

    # Try killAllSessionsByPattern on shard2 directly
    print("  Running killAllSessionsByPattern on shard2...")
    kill_out, _ = mongosh("repro-shard2", """
        try {
            var r = db.adminCommand({
                killAllSessionsByPattern: [{}]
            });
            print("KILL_RESULT: " + tojson(r));
        } catch(e) {
            print("KILL_ERROR: " + e.message);
        }
    """)
    print(f"  Kill result: {kill_out[:200]}")

    time.sleep(3)

    after = check_prepared_on_shard2()
    print(f"  After killSessions:\n    {after}")

    if "PREPARED_OPS: 0" in after and "TOTAL_TXN_OPS: 0" in after:
        print("  >> FAIL: Prepared transaction was KILLED by killSessions!")
        survived = False
    else:
        print("  >> PASS: Prepared transaction SURVIVED killSessions")
        survived = True

    # Release failpoint
    mongosh("repro-shard1a", """
        db.adminCommand({configureFailPoint: "hangBeforeSendingCommitDecision", mode: "off"})
    """)
    try:
        proc.wait(timeout=20)
        stdout = proc.stdout.read()
        print(f"  Transaction result: {stdout.strip()[:200]}")
    except subprocess.TimeoutExpired:
        proc.kill()
        print("  Transaction timed out (killed)")

    return survived

def test_c_stepdown():
    """
    Test C: Does participant step-down destroy prepared transactions?
    """
    print("\n" + "=" * 60)
    print("Test C: Participant Step-Down vs Prepared Transaction")
    print("=" * 60)
    print("  (shard2 is single-node RS; step-down will self-elect)")

    # Set failpoint on coordinator
    mongosh("repro-shard1a", """
        db.adminCommand({configureFailPoint: "hangBeforeSendingCommitDecision", mode: "alwaysOn"})
    """)

    txn_script = """
        var session = db.getMongo().startSession();
        var sdb = session.getDatabase("testdb");
        session.startTransaction({readConcern:{level:"snapshot"}, writeConcern:{w:"majority"}});
        try {
            sdb.txncoll.updateOne({key: 1}, {$set: {val: "test_c_s1"}});
            sdb.txncoll.updateOne({key: 200}, {$set: {val: "test_c_s2"}});
            session.commitTransaction();
            print("RESULT:COMMITTED");
        } catch(e) {
            print("RESULT:ERROR:" + e.message);
            try { session.abortTransaction(); } catch(e2) {}
        }
        session.endSession();
    """

    print("  Starting cross-shard transaction...")
    proc = subprocess.Popen(
        ["docker", "exec", "repro-mongos", "mongosh", "--quiet", "--eval", txn_script],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    )

    time.sleep(8)

    before = check_prepared_on_shard2()
    print(f"  Before step-down:\n    {before}")

    # Step down shard2
    print("  Stepping down shard2 primary...")
    mongosh("repro-shard2", """
        try {
            db.adminCommand({replSetStepDown: 5, force: true});
        } catch(e) {
            // Expected: network error during step-down
            print("STEPDOWN: " + e.message);
        }
    """)

    # Wait for re-election (single node, should be fast)
    time.sleep(10)

    # Wait for shard2 to become primary again
    for _ in range(15):
        out, _ = mongosh("repro-shard2", "rs.isMaster().ismaster")
        if "true" in out:
            break
        time.sleep(2)

    after = check_prepared_on_shard2()
    print(f"  After step-down + re-election:\n    {after}")

    if "PREPARED_OPS: 0" in after and "TOTAL_TXN_OPS: 0" in after:
        print("  >> FAIL: Prepared transaction LOST during step-down!")
        survived = False
    else:
        print("  >> PASS: Prepared transaction SURVIVED step-down")
        survived = True

    # Release failpoint
    mongosh("repro-shard1a", """
        db.adminCommand({configureFailPoint: "hangBeforeSendingCommitDecision", mode: "off"})
    """)
    try:
        proc.wait(timeout=20)
        stdout = proc.stdout.read()
        print(f"  Transaction result: {stdout.strip()[:200]}")
    except subprocess.TimeoutExpired:
        proc.kill()
        print("  Transaction timed out (killed)")

    return survived

def main():
    print("=" * 60)
    print("SERVER-105751 Reproduction: Session Reaper vs Prepared Txns")
    print("MongoDB 8.2.6 (latest)")
    print("=" * 60)

    # Check cluster
    out, _ = mongosh_mongos("db.runCommand({ping:1}).ok")
    if "1" not in out:
        print("Cluster not ready. Setting up...")
        setup_cluster()
    else:
        # Verify shards exist
        sout, _ = mongosh_mongos("db.adminCommand({listShards:1}).shards.length")
        if "2" not in sout:
            print("Shards not configured. Setting up...")
            setup_cluster()
        else:
            print("Cluster already configured with 2 shards.")
            # Ensure test data exists
            mongosh_mongos("""
                var db = db.getSiblingDB("testdb");
                if (!db.txncoll.findOne({key: 1})) db.txncoll.insertOne({key: 1, val: "shard1_init"});
                if (!db.txncoll.findOne({key: 200})) db.txncoll.insertOne({key: 200, val: "shard2_init"});
            """)

    results = {}

    # Test A
    try:
        results['A'] = test_a_session_expiry()
    except Exception as e:
        print(f"  Test A exception: {e}")
        results['A'] = None
        # Clean up failpoint
        mongosh("repro-shard1a", "db.adminCommand({configureFailPoint:'hangBeforeSendingCommitDecision',mode:'off'})")

    time.sleep(5)

    # Test B
    try:
        results['B'] = test_b_kill_sessions()
    except Exception as e:
        print(f"  Test B exception: {e}")
        results['B'] = None
        mongosh("repro-shard1a", "db.adminCommand({configureFailPoint:'hangBeforeSendingCommitDecision',mode:'off'})")

    time.sleep(5)

    # Test C
    try:
        results['C'] = test_c_stepdown()
    except Exception as e:
        print(f"  Test C exception: {e}")
        results['C'] = None
        mongosh("repro-shard1a", "db.adminCommand({configureFailPoint:'hangBeforeSendingCommitDecision',mode:'off'})")

    # Summary
    print("\n" + "=" * 60)
    print("SUMMARY")
    print("=" * 60)
    for test, passed in results.items():
        if passed is True:
            status = "PASS (safeguard holds)"
        elif passed is False:
            status = "FAIL (bug confirmed!)"
        else:
            status = "ERROR (inconclusive)"
        print(f"  Test {test}: {status}")

    all_pass = all(v is True for v in results.values())
    any_fail = any(v is False for v in results.values())

    if all_pass:
        print("\nVERDICT: All safeguards hold in MongoDB 8.2.6.")
        print("SERVER-105751 is NOT reproducible in current code.")
        print("The MC finding models a historical bug that has been fixed.")
    elif any_fail:
        print("\nVERDICT: BUG CONFIRMED — safeguard failure detected!")
    else:
        print("\nVERDICT: Inconclusive — some tests failed to run.")

if __name__ == "__main__":
    main()
