#!/usr/bin/env bash
# Initialize the sharded MongoDB cluster.
# Called by apply.sh after docker compose up.
set -euo pipefail

MONGOS_URI="mongodb://localhost:27017"

wait_for_mongod() {
    local container=$1
    local max_attempts=60
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
wait_for_mongod mongo-configsvr
wait_for_mongod mongo-shard1
wait_for_mongod mongo-shard2

echo "Initializing config server replica set..."
docker exec mongo-configsvr mongosh --quiet --eval '
    rs.initiate({_id: "configRS", configsvr: true, members: [{_id: 0, host: "configsvr:27017"}]})
'
sleep 3

echo "Initializing shard1 replica set..."
docker exec mongo-shard1 mongosh --quiet --eval '
    rs.initiate({_id: "shard1RS", members: [{_id: 0, host: "shard1:27017"}]})
'
sleep 2

echo "Initializing shard2 replica set..."
docker exec mongo-shard2 mongosh --quiet --eval '
    rs.initiate({_id: "shard2RS", members: [{_id: 0, host: "shard2:27017"}]})
'
sleep 2

echo "Waiting for mongos..."
wait_for_mongod mongo-mongos

echo "Adding shards to cluster..."
docker exec mongo-mongos mongosh --quiet --eval '
    sh.addShard("shard1RS/shard1:27017");
    sh.addShard("shard2RS/shard2:27017");
'
sleep 2

echo "Setting up sharded collection..."
docker exec mongo-mongos mongosh --quiet --eval '
    sh.enableSharding("testdb");
    db.getSiblingDB("testdb").createCollection("items");
    sh.shardCollection("testdb.items", {_id: "hashed"});
'
sleep 1

echo "Inserting seed data so both shards have chunks..."
docker exec mongo-mongos mongosh --quiet --eval '
    var db = db.getSiblingDB("testdb");
    var bulk = db.items.initializeUnorderedBulkOp();
    for (var i = 0; i < 200; i++) {
        bulk.insert({_id: "key" + i, value: "init"});
    }
    bulk.execute();
'

echo "Verifying shard distribution..."
docker exec mongo-mongos mongosh --quiet --eval '
    var chunks = db.getSiblingDB("config").chunks.aggregate([
        {$match: {ns: "testdb.items"}},
        {$group: {_id: "$shard", count: {$sum: 1}}}
    ]).toArray();
    printjson(chunks);
'

echo "Cluster initialized successfully."
