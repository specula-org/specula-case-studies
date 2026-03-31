#!/usr/bin/env bash
# Run all bug reproduction tests for MongoDB distributed transactions.
# Prerequisites: Docker, pymongo
set -euo pipefail
cd "$(dirname "$0")"

echo "=== Starting MongoDB 8.0.12 cluster ==="
docker compose down -v 2>/dev/null || true
docker compose up -d

echo "=== Initializing cluster ==="
sleep 5
bash init_cluster.sh

echo ""
echo "=== Running Bug 1: Session Reaper (SERVER-105751) ==="
python3 test_bug1_session_reaper.py 2>&1 | tee output_bug1.log

echo ""
echo "=== Running Bug 2: Stale Router Cache ==="
python3 test_bug2_stale_router.py 2>&1 | tee output_bug2.log

echo ""
echo "=== Running Bug 3: Router Abort Race (SERVER-66067) ==="
python3 test_bug3_router_abort_race.py 2>&1 | tee output_bug3.log

echo ""
echo "=== Running Bug 4: Coordinator Failover ==="
python3 test_bug4_coordinator_failover.py 2>&1 | tee output_bug4.log

echo ""
echo "=== Collecting logs ==="
mkdir -p logs
for container in repro-shard1 repro-shard2 repro-configsvr repro-mongos; do
    docker logs "$container" > "logs/${container}.log" 2>&1 || true
done

echo ""
echo "=== All tests complete ==="
echo "Logs in: $(pwd)/logs/"
echo "Results in: output_bug*.log"

echo ""
echo "=== Cleaning up ==="
docker compose down -v
