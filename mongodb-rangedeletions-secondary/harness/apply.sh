#!/bin/bash
# Start MongoDB sharding cluster for RangeDeletionsSecondaryNodes testing.
# Topology: configsvr (1-node RS), shard0 (2-node RS), shard1 (1-node RS), mongos
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE="$SCRIPT_DIR/src/docker-compose.yml"

echo "=== Starting MongoDB sharding cluster ==="
docker compose -f "$COMPOSE" down -v 2>/dev/null || true
docker compose -f "$COMPOSE" up -d

wait_ready() {
    local ctr=$1 port=$2
    for i in $(seq 1 30); do
        if docker exec "$ctr" mongosh --port "$port" --quiet --eval "db.runCommand({ping:1})" &>/dev/null; then
            echo "  $ctr ready"
            return 0
        fi
        sleep 1
    done
    echo "ERROR: $ctr not ready after 30s"; return 1
}

echo "Waiting for processes..."
wait_ready rdsec-configsvr 27019
wait_ready rdsec-shard0pri 27018
wait_ready rdsec-shard0sec 27018
wait_ready rdsec-shard1 27018

echo "Init configsvr RS..."
docker exec rdsec-configsvr mongosh --port 27019 --quiet --eval '
  rs.initiate({_id: "configrs", configsvr: true, members: [{_id: 0, host: "configsvr:27019"}]})
'
sleep 3

echo "Init shard0 RS (primary + secondary)..."
docker exec rdsec-shard0pri mongosh --port 27018 --quiet --eval '
  rs.initiate({_id: "shard0rs", members: [
    {_id: 0, host: "shard0pri:27018", priority: 2},
    {_id: 1, host: "shard0sec:27018", priority: 0}
  ]})
'

echo "Init shard1 RS..."
docker exec rdsec-shard1 mongosh --port 27018 --quiet --eval '
  rs.initiate({_id: "shard1rs", members: [{_id: 0, host: "shard1:27018"}]})
'

echo "Waiting for elections..."
sleep 5

for i in $(seq 1 30); do
    IS_PRI=$(docker exec rdsec-shard0pri mongosh --port 27018 --quiet --eval 'rs.isMaster().ismaster' 2>/dev/null || echo false)
    if [ "$IS_PRI" = "true" ]; then
        echo "  shard0 primary elected"
        break
    fi
    sleep 1
done

# Wait for shard0sec to be SECONDARY
for i in $(seq 1 30); do
    IS_SEC=$(docker exec rdsec-shard0sec mongosh --port 27018 --quiet --eval 'rs.isMaster().secondary' 2>/dev/null || echo false)
    if [ "$IS_SEC" = "true" ]; then
        echo "  shard0 secondary ready"
        break
    fi
    sleep 1
done

wait_ready rdsec-mongos 27017

echo "Adding shards..."
docker exec rdsec-mongos mongosh --quiet --eval '
  sh.addShard("shard0rs/shard0pri:27018,shard0sec:27018")
  sh.addShard("shard1rs/shard1:27018")
'
sleep 2

echo "Verifying cluster..."
docker exec rdsec-mongos mongosh --quiet --eval 'sh.status()' | head -20
echo "=== Cluster ready ==="
