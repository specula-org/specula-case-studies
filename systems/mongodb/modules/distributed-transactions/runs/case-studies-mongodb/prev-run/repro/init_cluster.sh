#!/usr/bin/env bash
# Initialize the sharded MongoDB 8.0.12 cluster for bug reproduction.
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

echo "Waiting for containers..."
wait_for_mongod repro-configsvr
wait_for_mongod repro-shard1
wait_for_mongod repro-shard2

echo "Initializing config server replica set..."
docker exec repro-configsvr mongosh --quiet --eval '
    rs.initiate({_id: "configRS", configsvr: true, members: [{_id: 0, host: "configsvr:27017"}]})
'
sleep 3

echo "Initializing shard1 replica set..."
docker exec repro-shard1 mongosh --quiet --eval '
    rs.initiate({_id: "shard1RS", members: [{_id: 0, host: "shard1:27017"}]})
'
sleep 2

echo "Initializing shard2 replica set..."
docker exec repro-shard2 mongosh --quiet --eval '
    rs.initiate({_id: "shard2RS", members: [{_id: 0, host: "shard2:27017"}]})
'
sleep 2

echo "Waiting for mongos..."
wait_for_mongod repro-mongos

echo "Adding shards..."
docker exec repro-mongos mongosh --quiet --eval '
    sh.addShard("shard1RS/shard1:27017");
    sh.addShard("shard2RS/shard2:27017");
'
sleep 2

echo "Setting up sharded collections..."
docker exec repro-mongos mongosh --quiet --eval '
    sh.enableSharding("bugrepro");
    db.getSiblingDB("bugrepro").createCollection("data");
    sh.shardCollection("bugrepro.data", {shard_key: 1});

    // Pre-split chunks: shard_key < 100 -> shard1, shard_key >= 100 -> shard2
    sh.splitAt("bugrepro.data", {shard_key: 100});
    sh.moveChunk("bugrepro.data", {shard_key: 0}, "shard1RS");
    sh.moveChunk("bugrepro.data", {shard_key: 100}, "shard2RS");
'
sleep 3

echo "Inserting seed data on both shards..."
docker exec repro-mongos mongosh --quiet --eval '
    var db = db.getSiblingDB("bugrepro");
    // shard1: keys 1-10, shard2: keys 100-110
    for (var i = 1; i <= 10; i++) db.data.insertOne({shard_key: i, value: "init"});
    for (var i = 100; i <= 110; i++) db.data.insertOne({shard_key: i, value: "init"});
'

echo "Verifying chunk distribution..."
docker exec repro-mongos mongosh --quiet --eval '
    var chunks = db.getSiblingDB("config").chunks.aggregate([
        {$match: {ns: "bugrepro.data"}},
        {$group: {_id: "$shard", count: {$sum: 1}}}
    ]).toArray();
    printjson(chunks);
    // Verify data on both shards
    var db = db.getSiblingDB("bugrepro");
    print("shard1 docs: " + db.data.find({shard_key: {$lt: 100}}).count());
    print("shard2 docs: " + db.data.find({shard_key: {$gte: 100}}).count());
'

echo "Cluster initialized. mongos available at localhost:27117"
