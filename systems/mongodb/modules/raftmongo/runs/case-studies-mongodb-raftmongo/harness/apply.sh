#!/bin/bash
# apply.sh — Set up Docker 3-node replica set for RaftMongo replication tracing.
#
# No source code patching is needed — we capture trace events from MongoDB's
# built-in structured logging (LOGV2) at replication verbosity 3.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_DIR="$SCRIPT_DIR/src"

echo "=== Starting MongoDB 3-node replica set ==="
cd "$COMPOSE_DIR"
docker compose -f docker-compose.yml down -v 2>/dev/null || true
docker compose -f docker-compose.yml up -d

echo "=== Waiting for containers ==="
sleep 5

# Wait for mongod processes to be ready
wait_for_mongod() {
    local container=$1
    local port=${2:-27017}
    local max_retries=30
    local retry=0
    while [ $retry -lt $max_retries ]; do
        if docker exec "$container" mongosh --port "$port" --eval "db.runCommand({ping: 1})" --quiet 2>/dev/null | grep -q '"ok"'; then
            echo "  $container is ready"
            return 0
        fi
        sleep 1
        retry=$((retry + 1))
    done
    echo "  WARNING: $container may not be ready yet, continuing..."
    return 0
}

wait_for_mongod rm-mongo1
wait_for_mongod rm-mongo2
wait_for_mongod rm-mongo3

echo "=== Initializing replica set ==="

docker exec rm-mongo1 mongosh --port 27017 --eval '
try {
    rs.initiate({
        _id: "raftrs",
        members: [
            {_id: 0, host: "mongo1:27017"},
            {_id: 1, host: "mongo2:27017"},
            {_id: 2, host: "mongo3:27017"}
        ]
    });
} catch(e) {
    if (e.codeName !== "AlreadyInitialized") throw e;
    print("Replica set already initialized");
}
' --quiet 2>/dev/null || true

sleep 5

# Wait for primary to be elected
echo "=== Waiting for primary election ==="
retries=0
while [ $retries -lt 60 ]; do
    has_primary=$(docker exec rm-mongo1 mongosh --port 27017 --eval '
        let s = rs.status();
        let found = false;
        for (let m of s.members) {
            if (m.stateStr === "PRIMARY") { found = true; break; }
        }
        print(found);
    ' --quiet 2>/dev/null || echo "false")
    if echo "$has_primary" | grep -q "true"; then
        echo "  Primary elected"
        break
    fi
    sleep 1
    retries=$((retries + 1))
done

# Print status
echo "=== Replica set status ==="
docker exec rm-mongo1 mongosh --port 27017 --eval '
let s = rs.status();
print("Term: " + s.term);
for (let m of s.members) {
    print("  " + m.name + ": " + m.stateStr);
}
' --quiet 2>/dev/null || true

echo "=== Cluster setup complete ==="
