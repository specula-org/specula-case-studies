#!/usr/bin/env bash
# End-to-end: start cluster, init, run scenarios, collect logs, parse traces.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TRACES_DIR="$CASE_DIR/traces"

cd "$SCRIPT_DIR"

echo "=== Step 1: Start cluster ==="
docker compose down -v 2>/dev/null || true
docker compose up -d
sleep 8

echo "=== Step 2: Initialize cluster ==="
# Wait for all nodes
for c in resharding-configsvr resharding-shard1 resharding-shard2; do
    for i in $(seq 1 25); do
        docker exec "$c" mongosh --quiet --eval "db.runCommand({ping:1})" >/dev/null 2>&1 && break
        sleep 1
    done
done

docker exec resharding-configsvr mongosh --quiet --eval \
    'rs.initiate({_id:"configRS",configsvr:true,members:[{_id:0,host:"configsvr:27017"}]})'
sleep 3
docker exec resharding-shard1 mongosh --quiet --eval \
    'rs.initiate({_id:"shard1RS",members:[{_id:0,host:"shard1:27017"}]})'
sleep 2
docker exec resharding-shard2 mongosh --quiet --eval \
    'rs.initiate({_id:"shard2RS",members:[{_id:0,host:"shard2:27017"}]})'
sleep 3

# Wait for mongos
for i in $(seq 1 20); do
    docker exec resharding-mongos mongosh --quiet --eval "db.runCommand({ping:1})" >/dev/null 2>&1 && break
    sleep 1
done

docker exec resharding-mongos mongosh --quiet --eval \
    'sh.addShard("shard1RS/shard1:27017"); sh.addShard("shard2RS/shard2:27017")'
sleep 2
echo "Cluster ready."

echo ""
echo "=== Step 3: Run test scenarios ==="
bash src/test_scenarios.sh

echo ""
echo "=== Step 4: Collect logs ==="
mkdir -p "$TRACES_DIR"

# Copy configsvr log (coordinator runs here)
docker cp resharding-configsvr:/var/log/mongodb/mongod.log "$TRACES_DIR/configsvr_raw.log"
docker cp resharding-shard1:/var/log/mongodb/mongod.log "$TRACES_DIR/shard1_raw.log"
docker cp resharding-shard2:/var/log/mongodb/mongod.log "$TRACES_DIR/shard2_raw.log"

echo ""
echo "=== Step 5: Parse traces ==="
python3 src/parse_resharding_logs.py "$TRACES_DIR/configsvr_raw.log" "$TRACES_DIR/basic_resharding.ndjson"

echo ""
echo "=== Step 6: Summary ==="
for f in "$TRACES_DIR"/*.ndjson; do
    count=$(wc -l < "$f")
    echo "  $f: $count events"
done

echo ""
echo "=== Step 7: Cleanup ==="
docker compose down -v

echo ""
echo "Done. Traces in: $TRACES_DIR/"
