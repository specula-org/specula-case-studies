#!/usr/bin/env bash
# Initialize the sharded MongoDB cluster for TxnsCollectionIncarnation traces.
set -euo pipefail

wait_for_mongod() {
    local container=$1
    local max_attempts=30
    for i in $(seq 1 $max_attempts); do
        if docker exec "$container" mongosh --quiet --eval "db.runCommand({ping:1})" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "ERROR: $container did not start in ${max_attempts}s"
    return 1
}

echo "Waiting for containers to start..."
wait_for_mongod tci-configsvr
wait_for_mongod tci-shard0
wait_for_mongod tci-shard1

echo "Initializing config server replica set..."
docker exec tci-configsvr mongosh --quiet --eval '
    rs.initiate({_id: "configRS", configsvr: true, members: [{_id: 0, host: "configsvr:27017"}]})
'
sleep 3

echo "Initializing shard0 replica set (shard0000)..."
docker exec tci-shard0 mongosh --quiet --eval '
    rs.initiate({_id: "shard0000", members: [{_id: 0, host: "shard0:27017"}]})
'
sleep 2

echo "Initializing shard1 replica set (shard0001)..."
docker exec tci-shard1 mongosh --quiet --eval '
    rs.initiate({_id: "shard0001", members: [{_id: 0, host: "shard1:27017"}]})
'
sleep 2

echo "Waiting for mongos..."
wait_for_mongod tci-mongos

echo "Adding shards to cluster..."
docker exec tci-mongos mongosh --quiet --eval '
    sh.addShard("shard0000/shard0:27017");
    sh.addShard("shard0001/shard1:27017");
'
sleep 2

echo "Setting slowms=-1 so all transactions get logged..."
docker exec tci-mongos mongosh --quiet --eval 'db.setProfilingLevel(0, {slowms: -1});'
docker exec tci-shard0 mongosh --quiet --eval 'db.setProfilingLevel(0, {slowms: -1});'
docker exec tci-shard1 mongosh --quiet --eval 'db.setProfilingLevel(0, {slowms: -1});'

echo "Verifying cluster status..."
docker exec tci-mongos mongosh --quiet --eval '
    var status = sh.status();
    print("Shards: " + db.getSiblingDB("config").shards.countDocuments({}));
'

echo "Cluster initialized successfully."
