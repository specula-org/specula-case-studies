#!/bin/bash
# apply.sh — Set up Docker 3-node replica set for RaftMongoReplTimestamp tracing.
#
# No C++ instrumentation needed — we capture trace events from MongoDB's
# built-in LOGV2 structured logging at replication verbosity 3.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_DIR="$SCRIPT_DIR/src"

echo "=== Starting MongoDB 3-node replica set ==="
cd "$COMPOSE_DIR"
docker compose -f docker-compose.yml down -v 2>/dev/null || true
docker compose -f docker-compose.yml up -d

echo "=== Waiting for containers ==="
sleep 5

wait_for_mongod() {
    local container=$1
    local max_retries=30
    local retry=0
    while [ $retry -lt $max_retries ]; do
        if docker exec "$container" mongosh --port 27017 --eval "db.runCommand({ping: 1})" --quiet 2>/dev/null | grep -q '"ok"'; then
            echo "  $container is ready"
            return 0
        fi
        sleep 1
        retry=$((retry + 1))
    done
    echo "  WARNING: $container may not be ready after ${max_retries}s"
    return 0
}

wait_for_mongod rts-mongo1
wait_for_mongod rts-mongo2
wait_for_mongod rts-mongo3

echo "=== Initializing replica set ==="

docker exec rts-mongo1 mongosh --port 27017 --eval '
try {
    rs.initiate({
        _id: "rtsrs",
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

echo "=== Waiting for primary election ==="
retries=0
while [ $retries -lt 60 ]; do
    has_primary=$(docker exec rts-mongo1 mongosh --port 27017 --eval '
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

echo "=== Replica set status ==="
docker exec rts-mongo1 mongosh --port 27017 --eval '
let s = rs.status();
print("Term: " + s.term);
for (let m of s.members) {
    print("  " + m.name + ": " + m.stateStr);
}
' --quiet 2>/dev/null || true

echo "=== Cluster setup complete ==="
