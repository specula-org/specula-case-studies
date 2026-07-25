// Setup script for sharded cluster — run against mongos
// Usage: mongosh --host localhost:27117 setup_cluster.js

// Wait for config server to be ready
print("=== Initializing config server RS ===");
var configConn = new Mongo("configsvr:27017");
var configAdmin = configConn.getDB("admin");
try {
    configAdmin.runCommand({replSetInitiate: {_id: "configRS", configsvr: true, members: [{_id: 0, host: "configsvr:27017"}]}});
} catch(e) { print("configRS init: " + e); }
sleep(3000);

print("=== Initializing shard1 RS ===");
var s1Conn = new Mongo("shard1:27017");
var s1Admin = s1Conn.getDB("admin");
try {
    s1Admin.runCommand({replSetInitiate: {_id: "shard1RS", members: [{_id: 0, host: "shard1:27017"}]}});
} catch(e) { print("shard1RS init: " + e); }
sleep(3000);

print("=== Initializing shard2 RS ===");
var s2Conn = new Mongo("shard2:27017");
var s2Admin = s2Conn.getDB("admin");
try {
    s2Admin.runCommand({replSetInitiate: {_id: "shard2RS", members: [{_id: 0, host: "shard2:27017"}]}});
} catch(e) { print("shard2RS init: " + e); }
sleep(5000);

print("=== Adding shards ===");
var mongosAdmin = db.getSiblingDB("admin");
printjson(mongosAdmin.runCommand({addShard: "shard1RS/shard1:27017"}));
sleep(1000);
printjson(mongosAdmin.runCommand({addShard: "shard2RS/shard2:27017"}));
sleep(2000);

print("=== Enabling sharding ===");
printjson(mongosAdmin.runCommand({enableSharding: "testdb"}));
sleep(1000);

print("=== Creating sharded collection ===");
var testdb = db.getSiblingDB("testdb");
printjson(mongosAdmin.runCommand({shardCollection: "testdb.testcol", key: {x: 1}}));
sleep(1000);

// Split at x=0 so we have chunks on both shards
print("=== Splitting chunks ===");
printjson(mongosAdmin.runCommand({split: "testdb.testcol", middle: {x: 0}}));
sleep(1000);

// Move one chunk to shard2
print("=== Moving chunk to shard2 ===");
printjson(mongosAdmin.runCommand({moveChunk: "testdb.testcol", find: {x: 1}, to: "shard2RS"}));
sleep(2000);

print("=== Inserting test data ===");
testdb.testcol.insertOne({x: -1, val: "on_shard1"});
testdb.testcol.insertOne({x: 1, val: "on_shard2"});

print("=== Verifying data distribution ===");
printjson(mongosAdmin.runCommand({getShardMap: 1}));
printjson(testdb.testcol.find().toArray());

print("=== Cluster setup complete ===");
