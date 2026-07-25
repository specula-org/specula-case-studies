#!/bin/bash
# apply.sh — Set up the Docker environment for MongoDB MoveRange tracing.
#
# Starts the sharded MongoDB cluster and initializes it.
# No source code patching needed — we capture trace events from MongoDB's
# built-in structured logging (logv2) at debug verbosity level 3 for migration.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Starting MongoDB sharded cluster ==="
cd "$SCRIPT_DIR/src"
docker compose -f docker-compose.yml down -v 2>/dev/null || true
docker compose -f docker-compose.yml up -d

echo "=== Waiting for containers to be healthy ==="
sleep 5

# Wait for mongod processes to be ready
wait_for_mongod() {
    local container=$1
    local port=$2
    local max_retries=30
    local retry=0
    while [ $retry -lt $max_retries ]; do
        if docker exec "$container" mongosh --port "$port" --eval "db.runCommand({ping: 1})" --quiet 2>/dev/null | grep -q '"ok" : 1\|"ok":1'; then
            echo "  $container is ready"
            return 0
        fi
        sleep 1
        retry=$((retry + 1))
    done
    echo "  WARNING: $container may not be ready yet, continuing..."
    return 0
}

wait_for_mongod mr-configsvr 27019
wait_for_mongod mr-shard0 27018
wait_for_mongod mr-shard1 27018

echo "=== Initializing replica sets ==="

# Initialize config server RS
docker exec mr-configsvr mongosh --port 27019 --eval '
try {
    rs.initiate({_id: "configrs", configsvr: true, members: [{_id: 0, host: "configsvr:27019"}]});
} catch(e) {
    if (e.codeName !== "AlreadyInitialized") throw e;
    print("Config RS already initialized");
}
' --quiet 2>/dev/null || true

sleep 3

# Initialize shard0 RS
docker exec mr-shard0 mongosh --port 27018 --eval '
try {
    rs.initiate({_id: "shard0rs", members: [{_id: 0, host: "shard0:27018"}]});
} catch(e) {
    if (e.codeName !== "AlreadyInitialized") throw e;
    print("Shard0 RS already initialized");
}
' --quiet 2>/dev/null || true

sleep 3

# Initialize shard1 RS
docker exec mr-shard1 mongosh --port 27018 --eval '
try {
    rs.initiate({_id: "shard1rs", members: [{_id: 0, host: "shard1:27018"}]});
} catch(e) {
    if (e.codeName !== "AlreadyInitialized") throw e;
    print("Shard1 RS already initialized");
}
' --quiet 2>/dev/null || true

sleep 5

# Wait for primaries to be elected
echo "=== Waiting for primaries ==="
for container in mr-configsvr mr-shard0 mr-shard1; do
    port=$( [ "$container" = "mr-configsvr" ] && echo 27019 || echo 27018 )
    retries=0
    while [ $retries -lt 30 ]; do
        is_primary=$(docker exec "$container" mongosh --port "$port" --eval 'rs.isMaster().ismaster' --quiet 2>/dev/null || echo "false")
        if echo "$is_primary" | grep -q "true"; then
            echo "  $container is primary"
            break
        fi
        sleep 1
        retries=$((retries + 1))
    done
done

# Wait for mongos to be ready
sleep 3
wait_for_mongod mr-mongos 27017

echo "=== Adding shards ==="
docker exec mr-mongos mongosh --port 27017 --eval '
sh.addShard("shard0rs/shard0:27018");
sh.addShard("shard1rs/shard1:27018");
' --quiet 2>/dev/null || true

sleep 3

# Verify cluster
echo "=== Cluster status ==="
docker exec mr-mongos mongosh --port 27017 --eval '
const shards = db.adminCommand({listShards: 1});
print("Shards: " + shards.shards.length);
shards.shards.forEach(s => print("  " + s._id + " -> " + s.host));
' --quiet 2>/dev/null || true

echo "=== Cluster setup complete ==="
