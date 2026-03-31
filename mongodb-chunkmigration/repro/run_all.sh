#!/bin/bash
# Run all reproduction tests for mongodb-chunkmigration bugs.
# Usage: ./run_all.sh [setup|test1|test2|test3|test4|teardown|all]

set -e
cd "$(dirname "$0")"

COMPOSE="docker compose"
TESTRUNNER="cm-testrunner"

setup() {
    echo "=== Starting MongoDB sharded cluster ==="
    $COMPOSE down -v --remove-orphans 2>/dev/null || true
    $COMPOSE up -d
    echo "Waiting 15s for containers to start..."
    sleep 15

    # Start test runner
    docker rm -f $TESTRUNNER 2>/dev/null || true
    docker run --rm -d --name $TESTRUNNER \
        --network repro_mongo-cluster \
        -v "$(pwd):/repro" -w /repro \
        python:3.12-slim sleep infinity
    docker exec $TESTRUNNER pip install pymongo -q

    echo "Initializing cluster..."
    docker exec $TESTRUNNER python3 -u /repro/setup_cluster.py
}

teardown() {
    echo "=== Tearing down cluster ==="
    docker rm -f $TESTRUNNER 2>/dev/null || true
    $COMPOSE down -v --remove-orphans
}

run_test() {
    local test_name=$1
    local test_file=$2
    echo ""
    echo "################################################################"
    echo "# Running: $test_name"
    echo "################################################################"
    docker exec $TESTRUNNER python3 -u /repro/$test_file 2>&1
    echo ""
    echo "# $test_name complete"
    echo "################################################################"
}

case "${1:-all}" in
    setup)
        setup
        ;;
    test1)
        run_test "Bug 1: Wrong task marking" "test_bug1_wrong_task_marking.py"
        ;;
    test2)
        run_test "Bug 2: ShardNotFound on commit" "test_bug2_shard_not_found.py"
        ;;
    test3)
        run_test "Bug 3: Limbo coordinator doc" "test_bug3_limbo_coordinator.py"
        ;;
    test4)
        run_test "Bug 4: Orphan count inflation" "test_bug4_orphan_count_inflate.py"
        ;;
    teardown)
        teardown
        ;;
    all)
        setup
        sleep 5
        run_test "Bug 3: Limbo coordinator doc" "test_bug3_limbo_coordinator.py"
        sleep 10
        run_test "Bug 1: Wrong task marking" "test_bug1_wrong_task_marking.py"
        sleep 10
        run_test "Bug 2: ShardNotFound on commit" "test_bug2_shard_not_found.py"
        sleep 10
        run_test "Bug 4: Orphan count inflation" "test_bug4_orphan_count_inflate.py"
        echo ""
        echo "=== All tests complete ==="
        ;;
    *)
        echo "Usage: $0 [setup|test1|test2|test3|test4|teardown|all]"
        exit 1
        ;;
esac
