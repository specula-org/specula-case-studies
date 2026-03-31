#!/bin/bash
# apply.sh — Set up the Docker environment for MongoDB chunk migration tracing.
#
# Starts a sharded MongoDB cluster and initializes it.
# No source code patching — we capture trace events from MongoDB's built-in
# LOGV2 structured logging at debug verbosity level 3.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Starting MongoDB sharded cluster ==="
cd "$SCRIPT_DIR/src"
docker compose -f docker-compose.yml down -v 2>/dev/null || true
docker compose -f docker-compose.yml up -d

echo "=== Waiting for containers ==="
sleep 5

# Wait for mongod to accept connections
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

wait_for_mongod cm-configsvr 27019
wait_for_mongod cm-shard0 27018
wait_for_mongod cm-shard1 27018

echo "=== Initializing replica sets ==="

# Config server RS
docker exec cm-configsvr mongosh --port 27019 --eval '
try {
    rs.initiate({_id: "configrs", configsvr: true, members: [{_id: 0, host: "configsvr:27019"}]});
} catch(e) {
    if (e.codeName !== "AlreadyInitialized") throw e;
    print("Config RS already initialized");
}
' --quiet 2>/dev/null || true

sleep 3

# Shard0 RS
docker exec cm-shard0 mongosh --port 27018 --eval '
try {
    rs.initiate({_id: "shard0rs", members: [{_id: 0, host: "shard0:27018"}]});
} catch(e) {
    if (e.codeName !== "AlreadyInitialized") throw e;
    print("Shard0 RS already initialized");
}
' --quiet 2>/dev/null || true

sleep 3

# Shard1 RS
docker exec cm-shard1 mongosh --port 27018 --eval '
try {
    rs.initiate({_id: "shard1rs", members: [{_id: 0, host: "shard1:27018"}]});
} catch(e) {
    if (e.codeName !== "AlreadyInitialized") throw e;
    print("Shard1 RS already initialized");
}
' --quiet 2>/dev/null || true

sleep 5

# Wait for primaries
echo "=== Waiting for primaries ==="
for container in cm-configsvr cm-shard0 cm-shard1; do
    port=$( [ "$container" = "cm-configsvr" ] && echo 27019 || echo 27018 )
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

# Wait for mongos
sleep 3
wait_for_mongod cm-mongos 27017

echo "=== Adding shards ==="
docker exec cm-mongos mongosh --port 27017 --eval '
sh.addShard("shard0rs/shard0:27018");
sh.addShard("shard1rs/shard1:27018");
' --quiet 2>/dev/null || true

sleep 3

# Verify
echo "=== Cluster status ==="
docker exec cm-mongos mongosh --port 27017 --eval '
const shards = db.adminCommand({listShards: 1});
print("Shards: " + shards.shards.length);
shards.shards.forEach(s => print("  " + s._id + " -> " + s.host));
' --quiet 2>/dev/null || true

echo "=== Cluster setup complete ==="
