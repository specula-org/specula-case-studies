#!/usr/bin/env bash
# Initialize the sharded MongoDB cluster for TxnsMoveRange trace collection.
# Uses range sharding so we can control which shard owns which key.
set -euo pipefail

MONGOS_URI="mongodb://localhost:27217"

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
wait_for_mongod txnmr-configsvr
wait_for_mongod txnmr-shard1
wait_for_mongod txnmr-shard2

echo "Initializing config server replica set..."
docker exec txnmr-configsvr mongosh --quiet --eval '
    rs.initiate({_id: "configRS", configsvr: true, members: [{_id: 0, host: "configsvr:27017"}]})
'
sleep 3

echo "Initializing shard1 replica set..."
docker exec txnmr-shard1 mongosh --quiet --eval '
    rs.initiate({_id: "shard1RS", members: [{_id: 0, host: "shard1:27017"}]})
'
sleep 2

echo "Initializing shard2 replica set..."
docker exec txnmr-shard2 mongosh --quiet --eval '
    rs.initiate({_id: "shard2RS", members: [{_id: 0, host: "shard2:27017"}]})
'
sleep 2

echo "Waiting for mongos..."
wait_for_mongod txnmr-mongos

echo "Adding shards to cluster..."
docker exec txnmr-mongos mongosh --quiet --eval '
    sh.addShard("shard1RS/shard1:27017");
    sh.addShard("shard2RS/shard2:27017");
'
sleep 2

echo "Setting up range-sharded collection..."
# Use range sharding so we can control key placement and trigger moveChunk.
# Keys "k1" and "k2" will initially be on shard1.
docker exec txnmr-mongos mongosh --quiet --eval '
    sh.enableSharding("testdb");
    db.getSiblingDB("testdb").createCollection("items");
    sh.shardCollection("testdb.items", {_id: 1});
'
sleep 1

echo "Inserting seed data..."
docker exec txnmr-mongos mongosh --quiet --eval '
    var db = db.getSiblingDB("testdb");
    db.items.insertMany([
        {_id: "k1", value: "init_k1", ns: "ns1"},
        {_id: "k2", value: "init_k2", ns: "ns1"},
        {_id: "k3", value: "init_k3", ns: "ns1"},
        {_id: "k4", value: "init_k4", ns: "ns1"},
    ]);
'
sleep 1

echo "Verifying shard distribution..."
docker exec txnmr-mongos mongosh --quiet --eval '
    var chunks = db.getSiblingDB("config").chunks.aggregate([
        {$match: {uuid: db.getSiblingDB("testdb").getCollectionInfos({name: "items"})[0].info.uuid}},
        {$group: {_id: "$shard", count: {$sum: 1}}}
    ]).toArray();
    printjson(chunks);
'

echo "Cluster initialized successfully."
echo "  mongos: localhost:27217"
echo "  shard1: shard1RS (txnmr-shard1)"
echo "  shard2: shard2RS (txnmr-shard2)"
