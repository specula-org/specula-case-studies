#!/bin/bash
# Start a 3-node MongoDB replica set for session lifecycle trace collection.
# Initializes RS with mongo1 as preferred primary.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/src"

echo "=== Stopping any existing cluster ==="
docker compose down -v 2>/dev/null || true

echo "=== Starting MongoDB replica set ==="
docker compose up -d

# Wait for a single mongod to accept connections
wait_for_mongo() {
    local container=$1
    local max_retries=30
    for i in $(seq 1 $max_retries); do
        if docker exec "$container" mongosh --quiet --eval "db.adminCommand('ping').ok" 2>/dev/null | grep -q "1"; then
            echo "  $container is ready"
            return 0
        fi
        sleep 1
    done
    echo "ERROR: $container did not start within ${max_retries}s"
    docker logs "$container" 2>&1 | tail -20
    return 1
}

echo "Waiting for MongoDB nodes..."
wait_for_mongo session-mongo1
wait_for_mongo session-mongo2
wait_for_mongo session-mongo3

echo "=== Initializing replica set ==="
docker exec session-mongo1 mongosh --quiet --eval '
rs.initiate({
    _id: "rs0",
    members: [
        {_id: 0, host: "mongo1:27017", priority: 2},
        {_id: 1, host: "mongo2:27017", priority: 1},
        {_id: 2, host: "mongo3:27017", priority: 1}
    ]
});
'

echo "Waiting for primary election..."
for i in $(seq 1 60); do
    IS_PRIMARY=$(docker exec session-mongo1 mongosh --quiet --eval 'rs.isMaster().ismaster' 2>/dev/null || echo "false")
    if [ "$IS_PRIMARY" = "true" ]; then
        echo "  mongo1 elected as primary"
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "ERROR: No primary elected within 60s"
        docker exec session-mongo1 mongosh --quiet --eval 'rs.status()' || true
        exit 1
    fi
    sleep 1
done

# Verify test commands are enabled
echo "Verifying enableTestCommands..."
VERIFY=$(docker exec session-mongo1 mongosh --quiet --eval '
try {
    var r = db.adminCommand({getParameter: 1, enableTestCommands: 1});
    r.enableTestCommands;
} catch(e) { "error"; }
' 2>/dev/null)
if [ "$VERIFY" = "1" ]; then
    echo "  enableTestCommands=1 confirmed"
else
    echo "WARNING: enableTestCommands may not be enabled (got: $VERIFY)"
fi

echo "=== Cluster ready ==="
