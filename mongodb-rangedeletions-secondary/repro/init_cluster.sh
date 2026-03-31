#!/bin/bash
# Initialize the sharding cluster for bug reproduction tests
set -e

COMPOSE_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$COMPOSE_DIR"

echo "=== Starting containers ==="
docker compose up -d
sleep 5

echo "=== Initializing config server RS ==="
docker exec rds-configsvr mongosh --quiet --eval '
rs.initiate({_id: "configRS", members: [{_id: 0, host: "configsvr:27017"}]})
'
sleep 3

echo "=== Initializing shard0 RS (2-node for step-up tests) ==="
docker exec rds-shard0a mongosh --quiet --eval '
rs.initiate({
  _id: "shard0RS",
  members: [
    {_id: 0, host: "shard0a:27017", priority: 2},
    {_id: 1, host: "shard0b:27017", priority: 1}
  ]
})
'
sleep 5

echo "=== Initializing shard1 RS ==="
docker exec rds-shard1 mongosh --quiet --eval '
rs.initiate({_id: "shard1RS", members: [{_id: 0, host: "shard1:27017"}]})
'
sleep 3

echo "=== Adding shards ==="
docker exec rds-mongos mongosh --quiet --eval '
sh.addShard("shard0RS/shard0a:27017,shard0b:27017")
'
sleep 1
docker exec rds-mongos mongosh --quiet --eval '
sh.addShard("shard1RS/shard1:27017")
'
sleep 2

echo "=== Verifying cluster ==="
docker exec rds-mongos mongosh --quiet --eval '
db.adminCommand({listShards: 1}).shards.forEach(function(s) {
  print("Shard: " + s._id + " -> " + s.host);
});
'

echo "=== Checking shard0 RS members ==="
docker exec rds-shard0a mongosh --quiet --eval '
rs.status().members.forEach(function(m) {
  print(m.name + " " + m.stateStr);
});
'

echo "=== Cluster ready ==="
