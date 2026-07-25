// setup_cluster.js — Initialize the sharded cluster for range deletion testing.
// Run via: mongosh --host localhost:27017 --file setup_cluster.js
//
// Prerequisites: docker compose up must be running with configsvr, shard0, shard1, mongos.

// Step 1: Initialize config server replica set
print("=== Initializing config server replica set ===");
const configConn = new Mongo("configsvr:27019");
try {
    configConn.getDB("admin").runCommand({
        replSetInitiate: {
            _id: "configrs",
            configsvr: true,
            members: [{ _id: 0, host: "configsvr:27019" }]
        }
    });
} catch (e) {
    print("Config RS may already be initialized: " + e.message);
}
sleep(3000);

// Step 2: Initialize shard0 replica set
print("=== Initializing shard0 replica set ===");
const shard0Conn = new Mongo("shard0:27018");
try {
    shard0Conn.getDB("admin").runCommand({
        replSetInitiate: {
            _id: "shard0rs",
            members: [{ _id: 0, host: "shard0:27018" }]
        }
    });
} catch (e) {
    print("Shard0 RS may already be initialized: " + e.message);
}
sleep(3000);

// Step 3: Initialize shard1 replica set
print("=== Initializing shard1 replica set ===");
const shard1Conn = new Mongo("shard1:27018");
try {
    shard1Conn.getDB("admin").runCommand({
        replSetInitiate: {
            _id: "shard1rs",
            members: [{ _id: 0, host: "shard1:27018" }]
        }
    });
} catch (e) {
    print("Shard1 RS may already be initialized: " + e.message);
}
sleep(5000);

// Step 4: Add shards via mongos
print("=== Adding shards to cluster ===");
const mongosConn = new Mongo("mongos:27017");
const adminDB = mongosConn.getDB("admin");

let res = adminDB.runCommand({ addShard: "shard0rs/shard0:27018" });
printjson(res);

res = adminDB.runCommand({ addShard: "shard1rs/shard1:27018" });
printjson(res);

sleep(2000);

// Step 5: Enable sharding on test database
print("=== Enabling sharding on test database ===");
res = adminDB.runCommand({ enableSharding: "testdb" });
printjson(res);

// Step 6: Verify cluster state
print("=== Cluster status ===");
res = adminDB.runCommand({ listShards: 1 });
printjson(res);

print("=== Cluster setup complete ===");
