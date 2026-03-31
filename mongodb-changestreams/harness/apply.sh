#!/usr/bin/env bash
#
# Start and initialize the MongoDB sharded cluster for trace collection.
#
# Usage: bash harness/apply.sh
#   (from case-studies/mongodb-changestreams/)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
PROJECT_NAME="cs-trace"
MONGOS_PORT="${MONGOS_PORT:-27117}"

echo "=== Starting MongoDB sharded cluster ==="

# Start containers
docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" up -d --wait 2>/dev/null || \
  docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" up -d

echo "Waiting for containers to be ready..."
sleep 5

# Helper: retry a mongosh command via docker exec
run_mongosh() {
    local container="$1"
    shift
    local max_retries=30
    local i=0
    while [ $i -lt $max_retries ]; do
        if docker exec "$container" mongosh --port 27017 --quiet --eval "$*" 2>/dev/null; then
            return 0
        fi
        i=$((i + 1))
        sleep 2
    done
    echo "ERROR: Failed to run mongosh on $container after $max_retries retries"
    return 1
}

echo "Initializing config server replica set..."
run_mongosh cs-configsvr "rs.initiate({_id:'configRS', configsvr:true, members:[{_id:0, host:'configsvr:27017'}]})" || true
sleep 3

echo "Initializing shard1 replica set..."
run_mongosh cs-shard1 "rs.initiate({_id:'shard1RS', members:[{_id:0, host:'shard1:27017'}]})" || true
sleep 2

echo "Initializing shard2 replica set..."
run_mongosh cs-shard2 "rs.initiate({_id:'shard2RS', members:[{_id:0, host:'shard2:27017'}]})" || true
sleep 2

echo "Waiting for replica sets to elect primaries..."
sleep 5

echo "Adding shards to mongos..."
run_mongosh cs-mongos "sh.addShard('shard1RS/shard1:27017')" || true
sleep 1
run_mongosh cs-mongos "sh.addShard('shard2RS/shard2:27017')" || true
sleep 1

echo "Verifying cluster..."
run_mongosh cs-mongos "JSON.stringify(sh.status())" | head -5

echo ""
echo "=== MongoDB sharded cluster ready ==="
echo "  mongos: localhost:${MONGOS_PORT}"
echo "  Shards: shard1RS, shard2RS"
