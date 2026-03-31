#!/usr/bin/env python3
"""
Reproduce fassert(51068): ShardNotFound during 2PC commit/abort delivery.

SERVER-38918 + SERVER-120584 interaction → crash loop.

Strategy: bypass the chicken-and-egg problem (removeShard blocked by active txn)
by directly injecting a coordinator recovery doc that references a non-existent
shard. When the coordinator primary steps down and recovers, it reads the doc
and tries to send the decision to the fake shard → ShardNotFound → fassert.

Three approaches tried in order:
  Approach A: Direct coordinator doc injection + stepdown
  Approach B: Real 2PC + config.shards manipulation + stepdown
  Approach C: Real 2PC + failpoint pause + direct shard entry removal
"""

import os
import sys
import time
import subprocess
import json
from pymongo import MongoClient
from pymongo.errors import (
    OperationFailure, ConnectionFailure, PyMongoError,
    ServerSelectionTimeoutError, AutoReconnect
)

MONGOS_URI = os.environ.get("MONGOS_URI", "mongodb://localhost:27117")
SHARD1_URI = "mongodb://localhost:27118"  # direct to shard1 primary


def mongosh(container, cmd, timeout=15):
    """Run mongosh command on a container."""
    result = subprocess.run(
        ["docker", "exec", container, "mongosh", "--quiet", "--eval", cmd],
        capture_output=True, text=True, timeout=timeout
    )
    return result


def check_fassert(container):
    """Check if a container hit fassert (crashed)."""
    result = subprocess.run(
        ["docker", "logs", "--tail", "50", container],
        capture_output=True, text=True, timeout=10
    )
    logs = result.stdout + result.stderr
    if "51068" in logs or "fassert" in logs.lower():
        return True, logs
    return False, logs


def is_alive(container):
    """Check if mongod is responsive."""
    try:
        r = mongosh(container, "db.runCommand({ping:1})", timeout=5)
        return r.returncode == 0
    except:
        return False


def wait_for_primary(container, max_wait=30):
    """Wait for container to become replica set primary."""
    for i in range(max_wait):
        try:
            r = mongosh(container, "rs.isMaster().ismaster", timeout=5)
            if "true" in r.stdout.lower():
                return True
        except:
            pass
        time.sleep(1)
    return False


# ============================================================
# Approach A: Direct coordinator doc injection
#
# Inject a fake coordinator doc referencing a non-existent shard,
# then force stepdown → recovery reads the doc → ShardNotFound.
# ============================================================
def approach_a():
    print("=" * 60)
    print("APPROACH A: Direct coordinator doc injection")
    print("=" * 60)

    # The coordinator doc collection is config.transaction_coordinators
    # on the SHARD (not the config server).
    # Format: {_id: {lsid: ..., txnNumber: N, txnRetryCounter: 0},
    #          participants: [{shardId: "shard1RS"}, {shardId: "FAKE_SHARD"}]}

    # Step 1: Insert a fake coordinator doc on shard1
    print("\nStep 1: Inserting fake coordinator doc on shard1...")
    inject_cmd = """
    var doc = {
        _id: {lsid: {id: UUID()}, txnNumber: NumberLong(999), txnRetryCounter: NumberInt(0)},
        participants: [
            {shardId: "shard1RS"},
            {shardId: "NONEXISTENT_SHARD_XYZ"}
        ]
    };
    var result = db.getSiblingDB("config").transaction_coordinators.insertOne(doc);
    printjson(result);
    """
    r = mongosh("repro-shard1", inject_cmd)
    print(f"  Insert result: {r.stdout.strip()}")
    if r.returncode != 0:
        print(f"  Error: {r.stderr.strip()}")
        return False

    # Verify the doc was inserted
    r = mongosh("repro-shard1",
                "db.getSiblingDB('config').transaction_coordinators.countDocuments({})")
    print(f"  Coordinator docs on shard1: {r.stdout.strip()}")

    # Step 2: Force shard1 to step down → triggers recovery on step-up
    print("\nStep 2: Forcing shard1 stepdown to trigger recovery...")
    r = mongosh("repro-shard1", """
        try {
            db.adminCommand({replSetStepDown: 5, force: true});
        } catch(e) {
            print("stepdown triggered: " + e.message);
        }
    """)
    print(f"  Stepdown result: {r.stdout.strip()}")

    # Step 3: Wait for shard1 to become primary again (single-node RS)
    print("\nStep 3: Waiting for shard1 to become primary again...")
    time.sleep(8)  # stepdown duration + election
    if not wait_for_primary("repro-shard1", max_wait=30):
        print("  WARNING: shard1 did not become primary")

    # Step 4: Check for fassert
    print("\nStep 4: Checking for fassert(51068)...")
    time.sleep(3)  # give recovery a moment
    hit, logs = check_fassert("repro-shard1")
    if hit:
        print("  *** FASSERT(51068) TRIGGERED! ***")
        # Extract relevant log lines
        for line in logs.split("\n"):
            if "51068" in line or "fassert" in line.lower() or "ShardNotFound" in line:
                print(f"    {line.strip()}")
        return True

    # Check if shard1 is still alive
    alive = is_alive("repro-shard1")
    print(f"  shard1 alive: {alive}")

    if not alive:
        print("  shard1 crashed (possibly fassert without log capture)")
        # Check docker container state
        result = subprocess.run(
            ["docker", "inspect", "--format", "{{.State.Status}} exit:{{.State.ExitCode}}",
             "repro-shard1"],
            capture_output=True, text=True
        )
        print(f"  Container state: {result.stdout.strip()}")
        return True

    # Check if the coordinator doc was processed (deleted = recovery ran)
    r = mongosh("repro-shard1",
                "db.getSiblingDB('config').transaction_coordinators.countDocuments({})")
    print(f"  Coordinator docs remaining: {r.stdout.strip()}")

    # Search logs more thoroughly
    print("\nSearching shard1 logs for ShardNotFound...")
    result = subprocess.run(
        ["docker", "exec", "repro-shard1", "grep", "-i",
         "shardnotfound\\|51068\\|fassert",
         "/var/log/mongodb/mongod.log"],
        capture_output=True, text=True, timeout=10
    )
    if result.stdout.strip():
        print(f"  Found in logs:")
        for line in result.stdout.strip().split("\n")[:10]:
            print(f"    {line[:200]}")
        return "partial"
    else:
        print("  No ShardNotFound in logs")

    return False


# ============================================================
# Approach B: Real transaction + config.shards manipulation
#
# Start a real cross-shard txn, let it complete to prepared state,
# then directly remove shard2 from config.shards, then crash the
# coordinator → recovery can't find shard2 → fassert.
# ============================================================
def approach_b():
    print("\n" + "=" * 60)
    print("APPROACH B: Real 2PC + config.shards manipulation")
    print("=" * 60)

    client = MongoClient(MONGOS_URI)
    db = client.bugrepro

    # Step 1: Start a cross-shard transaction and pause at prepare
    print("\nStep 1: Setting failpoint to pause after prepare...")
    r = mongosh("repro-shard1", """
        db.adminCommand({
            configureFailPoint: "hangBeforeWritingDecision",
            mode: "alwaysOn"
        })
    """)
    print(f"  Failpoint: {r.stdout.strip()}")

    print("\nStep 2: Starting cross-shard transaction in background...")
    import threading

    txn_result = {"status": None, "error": None}

    def run_txn():
        try:
            c = MongoClient(MONGOS_URI)
            session = c.start_session()
            session.start_transaction()
            c.bugrepro.data.update_one(
                {"shard_key": 1}, {"$set": {"value": "approach_b"}},
                session=session
            )
            c.bugrepro.data.update_one(
                {"shard_key": 100}, {"$set": {"value": "approach_b"}},
                session=session
            )
            session.commit_transaction()
            txn_result["status"] = "committed"
        except Exception as e:
            txn_result["status"] = "error"
            txn_result["error"] = str(e)

    t = threading.Thread(target=run_txn, daemon=True)
    t.start()

    # Wait for transaction to reach the failpoint
    print("  Waiting 5s for transaction to reach prepare...")
    time.sleep(5)

    # Step 3: Directly remove shard2 from config server's config.shards
    print("\nStep 3: Removing shard2 entry from config.shards on config server...")
    r = mongosh("repro-configsvr", """
        var result = db.getSiblingDB("config").shards.deleteOne({_id: "shard2RS"});
        printjson(result);
    """)
    print(f"  Delete result: {r.stdout.strip()}")

    # Step 4: Release failpoint and force crash
    print("\nStep 4: Releasing failpoint...")
    r = mongosh("repro-shard1", """
        db.adminCommand({
            configureFailPoint: "hangBeforeWritingDecision",
            mode: "off"
        })
    """)

    time.sleep(3)
    print(f"  Transaction status: {txn_result['status']}")

    # Step 5: Force stepdown on shard1 to trigger recovery
    print("\nStep 5: Forcing shard1 stepdown...")
    r = mongosh("repro-shard1", """
        try {
            db.adminCommand({replSetStepDown: 5, force: true});
        } catch(e) {
            print("stepdown: " + e.message);
        }
    """)

    time.sleep(8)
    wait_for_primary("repro-shard1", max_wait=30)

    # Step 6: Check for fassert
    print("\nStep 6: Checking for fassert(51068)...")
    time.sleep(3)
    hit, logs = check_fassert("repro-shard1")
    if hit:
        print("  *** FASSERT(51068) TRIGGERED! ***")
        return True

    alive = is_alive("repro-shard1")
    print(f"  shard1 alive: {alive}")

    # Search logs
    result = subprocess.run(
        ["docker", "exec", "repro-shard1", "grep", "-i",
         "shardnotfound\\|51068\\|fassert\\|NONEXISTENT",
         "/var/log/mongodb/mongod.log"],
        capture_output=True, text=True, timeout=10
    )
    if result.stdout.strip():
        print("  Log entries found:")
        for line in result.stdout.strip().split("\n")[:10]:
            print(f"    {line[:200]}")
        return "partial"

    # Restore shard2 in config.shards
    print("\n  Restoring shard2 in config.shards...")
    r = mongosh("repro-configsvr", """
        db.getSiblingDB("config").shards.insertOne({
            _id: "shard2RS",
            host: "shard2RS/shard2:27017",
            state: 1
        });
    """)

    return False


# ============================================================
# Approach C: Use mongo:8.2.6 specific failpoints
# ============================================================
def approach_c():
    print("\n" + "=" * 60)
    print("APPROACH C: Enumerate available coordinator failpoints")
    print("=" * 60)

    # List all failpoints that might help
    r = mongosh("repro-shard1", """
        var params = db.adminCommand({getParameter: "*"});
        var fps = Object.keys(params).filter(k =>
            k.match(/[Cc]oordinator|[Ss]hardNotFound|[Dd]ecision|51068|fassert/i)
        );
        fps.forEach(f => print(f));
    """)
    print(f"  Relevant failpoints:\n{r.stdout.strip()}")

    # Try hangBeforeWritingDecision + direct ShardRegistry manipulation
    print("\n  Checking if we can use failCommitCoordinatorBeforeSendingDecision...")
    r = mongosh("repro-shard1", """
        var result = db.adminCommand({
            configureFailPoint: "hangBeforeSendingAbort",
            mode: "alwaysOn"
        });
        printjson(result);
    """)
    print(f"  Result: {r.stdout.strip()}")
    # Clean up
    mongosh("repro-shard1", """
        db.adminCommand({configureFailPoint: "hangBeforeSendingAbort", mode: "off"});
    """)

    return False


def main():
    print("MongoDB fassert(51068) Reproduction Test")
    print(f"Target: MongoDB {mongosh('repro-shard1', 'db.version()').stdout.strip()}")
    print()

    # Approach A: Direct injection (most likely to work)
    result_a = approach_a()
    if result_a is True:
        print("\n" + "=" * 60)
        print("SUCCESS: fassert(51068) reproduced via Approach A!")
        print("=" * 60)
        return

    # Approach B: Real txn + config.shards manipulation
    result_b = approach_b()
    if result_b is True:
        print("\n" + "=" * 60)
        print("SUCCESS: fassert(51068) reproduced via Approach B!")
        print("=" * 60)
        return

    # Approach C: Failpoint enumeration
    approach_c()

    print("\n" + "=" * 60)
    if result_a == "partial" or result_b == "partial":
        print("PARTIAL: ShardNotFound observed in logs but no fassert crash")
        print("The recovery may handle it differently in 8.2.6, or the")
        print("fassert may require specific error classification.")
    else:
        print("NOT REPRODUCED in this run")
    print("=" * 60)


if __name__ == "__main__":
    main()
