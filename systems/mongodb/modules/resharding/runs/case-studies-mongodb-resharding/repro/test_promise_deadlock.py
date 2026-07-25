#!/usr/bin/env python3
"""
Reproduce RS-1: Observer Promise Deadlock on Early Abort

Target: MongoDB 8.2.6 (latest)

Scenario from MC counterexample (7 states):
1. Start reshardCollection
2. Coordinator reaches kPreparingToDonate
3. Before participants are notified (flush), abort is triggered
4. Coordinator enters kAborting, sends abort to participants
5. Observer's sequential promise check blocks on empty/early promises
6. Done-promises stay pending forever → coordinator hangs

Approach:
- Use reshardingPauseCoordinatorAfterPreparingToDonate failpoint
- While paused, send abortReshardCollection command
- Monitor coordinator state — if it gets stuck in kAborting, bug confirmed
"""

import subprocess
import time
import sys
import threading

MONGOS = "resharding-mongos"
CONFIGSVR = "resharding-configsvr"


def mongosh(container, cmd, timeout=30):
    r = subprocess.run(
        ["docker", "exec", container, "mongosh", "--quiet", "--eval", cmd],
        capture_output=True, text=True, timeout=timeout
    )
    return r


def setup_cluster():
    """Start and initialize cluster."""
    print("Starting cluster...")
    subprocess.run(["docker", "compose", "-f", "../harness/docker-compose.yml", "up", "-d"],
                   capture_output=True, timeout=60)
    time.sleep(8)

    # Init RS
    for c in [CONFIGSVR, "resharding-shard1", "resharding-shard2"]:
        for i in range(25):
            r = mongosh(c, "db.runCommand({ping:1})")
            if r.returncode == 0:
                break
            time.sleep(1)

    mongosh(CONFIGSVR, 'rs.initiate({_id:"configRS",configsvr:true,members:[{_id:0,host:"configsvr:27017"}]})')
    time.sleep(3)
    mongosh("resharding-shard1", 'rs.initiate({_id:"shard1RS",members:[{_id:0,host:"shard1:27017"}]})')
    time.sleep(2)
    mongosh("resharding-shard2", 'rs.initiate({_id:"shard2RS",members:[{_id:0,host:"shard2:27017"}]})')
    time.sleep(3)

    for i in range(20):
        r = mongosh(MONGOS, "db.runCommand({ping:1})")
        if r.returncode == 0:
            break
        time.sleep(1)

    mongosh(MONGOS, 'sh.addShard("shard1RS/shard1:27017"); sh.addShard("shard2RS/shard2:27017")')
    time.sleep(2)

    # Create sharded collection
    mongosh(MONGOS, '''
        sh.enableSharding("deadlocktest");
        db.getSiblingDB("deadlocktest").createCollection("coll");
        sh.shardCollection("deadlocktest.coll", {x: 1});
        sh.splitAt("deadlocktest.coll", {x: 100});
        sh.moveChunk("deadlocktest.coll", {x: 0}, "shard1RS");
        sh.moveChunk("deadlocktest.coll", {x: 100}, "shard2RS");
        var d = db.getSiblingDB("deadlocktest");
        for (var i = 0; i < 200; i++) d.coll.insertOne({x: i, data: "pad_" + i});
        for (var i = 100; i < 300; i++) d.coll.insertOne({x: i, data: "pad_" + i});
    ''')
    print("Cluster ready.")


def run_test():
    """Execute the test scenario."""

    print("\n=== Step 1: Enable failpoint to pause after kPreparingToDonate ===")
    r = mongosh(CONFIGSVR, '''
        db.adminCommand({
            configureFailPoint: "reshardingPauseCoordinatorAfterPreparingToDonate",
            mode: "alwaysOn"
        });
    ''')
    print(f"  Failpoint: {r.stdout.strip()[:80]}")

    print("\n=== Step 2: Start resharding (will pause at failpoint) ===")
    reshard_result = {"done": False, "output": ""}

    def do_reshard():
        r = mongosh(MONGOS, '''
            db.adminCommand({
                reshardCollection: "deadlocktest.coll",
                key: {data: "hashed"}
            });
        ''', timeout=120)
        reshard_result["done"] = True
        reshard_result["output"] = r.stdout[:200]

    t = threading.Thread(target=do_reshard, daemon=True)
    t.start()

    print("  Waiting 15s for coordinator to reach failpoint...")
    time.sleep(15)

    # Verify coordinator is paused
    r = mongosh(CONFIGSVR, '''
        var ops = db.getSiblingDB("config").reshardingOperations.find().toArray();
        print(ops.length + " ops");
        if (ops.length > 0) print("state: " + ops[0].state);
    ''')
    print(f"  Coordinator: {r.stdout.strip()}")

    print("\n=== Step 3: Send abort while coordinator is paused ===")
    r = mongosh(MONGOS, '''
        db.adminCommand({abortReshardCollection: "deadlocktest.coll"});
    ''', timeout=30)
    print(f"  Abort: {r.stdout.strip()[:100]}")

    print("\n=== Step 4: Release failpoint ===")
    mongosh(CONFIGSVR, '''
        db.adminCommand({
            configureFailPoint: "reshardingPauseCoordinatorAfterPreparingToDonate",
            mode: "off"
        });
    ''')

    print("\n=== Step 5: Monitor coordinator state ===")
    hung = False
    for i in range(30):
        time.sleep(5)
        r = mongosh(CONFIGSVR, '''
            var ops = db.getSiblingDB("config").reshardingOperations.find().toArray();
            if (ops.length === 0) { print("COMPLETED"); }
            else { print("state=" + ops[0].state + " abortReason=" + (ops[0].abortReason ? "yes" : "no")); }
        ''')
        state = r.stdout.strip()
        elapsed = (i + 1) * 5
        print(f"  [{elapsed}s] {state}")

        if "COMPLETED" in state:
            print(f"\n  Resharding completed (abort processed) in {elapsed}s")
            break

        if "aborting" in state.lower() and elapsed > 60:
            print(f"\n  *** COORDINATOR STUCK IN ABORTING FOR {elapsed}s ***")
            hung = True
            break

    if hung:
        print("\n========================================")
        print("BUG REPRODUCED: Coordinator hung in kAborting")
        print("========================================")

        # Collect evidence
        print("\nCollecting coordinator logs...")
        r = subprocess.run(
            ["docker", "exec", CONFIGSVR, "grep", "-i",
             "5343001\\|5093707\\|promise\\|deadlock\\|abort\\|aborting",
             "/var/log/mongodb/mongod.log"],
            capture_output=True, text=True, timeout=10
        )
        for line in r.stdout.strip().split('\n')[-10:]:
            print(f"  {line[:250]}")
    else:
        if reshard_result["done"]:
            print(f"\n  Resharding command returned: {reshard_result['output'][:100]}")
        print("\n  Bug NOT reproduced in this run")
        print("  The abort may have been processed before reaching the deadlock window")

    t.join(10)


def cleanup():
    subprocess.run(["docker", "compose", "-f", "../harness/docker-compose.yml", "down", "-v"],
                   capture_output=True, timeout=30)


if __name__ == "__main__":
    try:
        setup_cluster()
        run_test()
    finally:
        cleanup()
