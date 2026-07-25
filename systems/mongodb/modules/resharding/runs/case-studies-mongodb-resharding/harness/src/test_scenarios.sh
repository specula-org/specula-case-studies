#!/usr/bin/env bash
# Test scenarios for resharding trace collection.
# Each scenario triggers a resharding operation and collects coordinator logs.
set -euo pipefail

MONGOS="resharding-mongos"

mongosh_eval() {
    docker exec "$MONGOS" mongosh --quiet --eval "$1"
}

wait_mongos() {
    for i in $(seq 1 30); do
        docker exec "$MONGOS" mongosh --quiet --eval "db.runCommand({ping:1})" >/dev/null 2>&1 && return 0
        sleep 1
    done
    echo "ERROR: mongos not ready" >&2
    return 1
}

# ============================================================
# Scenario 1: Basic successful resharding
# Exercises: kUnused → kInitializing → kPreparingToDonate →
#            kCloning → kApplying → kBlockingWrites →
#            kCommitting → kDone
# ============================================================
scenario_basic_resharding() {
    echo "=== Scenario 1: Basic successful resharding ==="

    # Setup: create sharded collection with data
    mongosh_eval '
        sh.enableSharding("tracetest");
        db.getSiblingDB("tracetest").createCollection("coll1");
        sh.shardCollection("tracetest.coll1", {x: 1});
        sh.splitAt("tracetest.coll1", {x: 100});
        sh.moveChunk("tracetest.coll1", {x: 0}, "shard1RS");
        sh.moveChunk("tracetest.coll1", {x: 100}, "shard2RS");
        var d = db.getSiblingDB("tracetest");
        for (var i = 0; i < 50; i++) d.coll1.insertOne({x: i, data: "padding_" + i});
        for (var i = 100; i < 150; i++) d.coll1.insertOne({x: i, data: "padding_" + i});
        print("Setup done: " + d.coll1.countDocuments() + " docs");
    '

    # Reshard: change shard key from {x:1} to {data:"hashed"}
    # Using a completely different key to avoid redundancy detection
    echo "  Starting resharding..."
    mongosh_eval '
        db.adminCommand({
            reshardCollection: "tracetest.coll1",
            key: {data: "hashed"}
        });
    ' || echo "  Resharding command returned (may be async)"

    # Wait for completion
    echo "  Waiting for resharding to complete..."
    for i in $(seq 1 120); do
        state=$(mongosh_eval '
            var ops = db.getSiblingDB("config").reshardingOperations.find().toArray();
            if (ops.length === 0) { print("done"); }
            else { print(ops[0].state); }
        ' 2>/dev/null || echo "error")
        if [ "$state" = "done" ]; then
            echo "  Resharding completed successfully"
            return 0
        fi
        sleep 2
    done
    echo "  WARNING: Resharding may not have completed within timeout"
}

# ============================================================
# Scenario 2: Resharding with user-initiated abort
# Exercises: kUnused → ... → kBlockingWrites → kAborting → kDone
# ============================================================
scenario_abort_resharding() {
    echo "=== Scenario 2: Resharding with abort ==="

    # Setup fresh collection
    mongosh_eval '
        db.getSiblingDB("tracetest").coll2.drop();
        db.getSiblingDB("tracetest").createCollection("coll2");
        sh.shardCollection("tracetest.coll2", {a: 1});
        sh.splitAt("tracetest.coll2", {a: 500});
        sh.moveChunk("tracetest.coll2", {a: 0}, "shard1RS");
        sh.moveChunk("tracetest.coll2", {a: 500}, "shard2RS");
        var d = db.getSiblingDB("tracetest");
        for (var i = 0; i < 100; i++) d.coll2.insertOne({a: i, b: "data"});
        for (var i = 500; i < 600; i++) d.coll2.insertOne({a: i, b: "data"});
        print("Setup done: " + d.coll2.countDocuments() + " docs");
    '

    # Start resharding with a failpoint to pause at kApplying
    echo "  Setting failpoint to pause at kApplying..."
    docker exec resharding-configsvr mongosh --quiet --eval '
        db.adminCommand({
            configureFailPoint: "reshardingPauseCoordinatorBeforeBlockingWrites",
            mode: "alwaysOn"
        });
    '

    # Start resharding in background
    echo "  Starting resharding (will pause)..."
    mongosh_eval '
        db.adminCommand({
            reshardCollection: "tracetest.coll2",
            key: {a: 1, b: 1}
        });
    ' &
    local reshard_pid=$!

    # Wait for it to reach the failpoint
    echo "  Waiting for resharding to reach failpoint..."
    sleep 15

    # Abort
    echo "  Sending abort..."
    mongosh_eval '
        db.adminCommand({abortReshardCollection: "tracetest.coll2"});
    ' || echo "  Abort sent (may error if already aborting)"

    # Release failpoint
    docker exec resharding-configsvr mongosh --quiet --eval '
        db.adminCommand({
            configureFailPoint: "reshardingPauseCoordinatorBeforeBlockingWrites",
            mode: "off"
        });
    '

    # Wait for completion
    echo "  Waiting for abort to complete..."
    for i in $(seq 1 60); do
        state=$(mongosh_eval '
            var ops = db.getSiblingDB("config").reshardingOperations.find().toArray();
            if (ops.length === 0) { print("done"); }
            else { print(ops[0].state); }
        ' 2>/dev/null || echo "error")
        if [ "$state" = "done" ]; then
            echo "  Abort completed"
            break
        fi
        sleep 2
    done

    wait $reshard_pid 2>/dev/null || true
}

# ============================================================
# Main
# ============================================================
echo "Waiting for mongos..."
wait_mongos
echo "Running test scenarios..."
scenario_basic_resharding
echo ""
scenario_abort_resharding
echo ""
echo "All scenarios complete."
