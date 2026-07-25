// test_concurrent_migrations.js — Two sequential migrations on different collections,
// exercising overlap checking and multiple task lifecycles.
//
// Run via: mongosh --host mongos:27017 --file test_concurrent_migrations.js

print("=== Test: concurrent_migrations ===");
const db = connect("mongos:27017/testdb");
const adminDB = db.getSiblingDB("admin");
const configDB = db.getSiblingDB("config");

// Clean up from previous runs
db.conc_collA.drop();
db.conc_collB.drop();

// Step 1: Create and shard two collections
print("--- Creating sharded collections ---");
adminDB.runCommand({ enableSharding: "testdb" });
adminDB.runCommand({ shardCollection: "testdb.conc_collA", key: { _id: 1 } });
adminDB.runCommand({ shardCollection: "testdb.conc_collB", key: { _id: 1 } });

// Step 2: Insert test documents
print("--- Inserting documents ---");
let bulkA = db.conc_collA.initializeUnorderedBulkOp();
let bulkB = db.conc_collB.initializeUnorderedBulkOp();
for (let i = 0; i < 50; i++) {
    bulkA.insert({ _id: i, data: "collA_" + i });
    bulkB.insert({ _id: i, data: "collB_" + i });
}
bulkA.execute();
bulkB.execute();
print("Inserted 50 documents in each collection");

// Step 3: Determine shard placement
const collInfoA = configDB.collections.findOne({ _id: "testdb.conc_collA" });
const collInfoB = configDB.collections.findOne({ _id: "testdb.conc_collB" });

const chunksA = configDB.chunks.find({ uuid: collInfoA.uuid }, { shard: 1 }).toArray();
const chunksB = configDB.chunks.find({ uuid: collInfoB.uuid }, { shard: 1 }).toArray();

const sourceA = chunksA[0].shard;
const targetA = sourceA === "shard0rs" ? "shard1rs" : "shard0rs";
const sourceB = chunksB[0].shard;
const targetB = sourceB === "shard0rs" ? "shard1rs" : "shard0rs";

print("CollA: " + sourceA + " -> " + targetA);
print("CollB: " + sourceB + " -> " + targetB);

// Step 4: Mark log position
const logMarkTime = new Date().toISOString();
print("Log mark time: " + logMarkTime);

// Step 5: Move chunk for collection A (first migration)
print("--- Moving chunk for collA ---");
let res = adminDB.runCommand({
    moveChunk: "testdb.conc_collA",
    find: { _id: 0 },
    to: targetA,
    _waitForDelete: true
});
printjson(res);
if (res.ok !== 1) {
    print("ERROR: moveChunk for collA failed!");
    quit(1);
}

// Step 6: Move chunk for collection B (second migration, may overlap in processor queue)
print("--- Moving chunk for collB ---");
res = adminDB.runCommand({
    moveChunk: "testdb.conc_collB",
    find: { _id: 0 },
    to: targetB,
    _waitForDelete: true
});
printjson(res);
if (res.ok !== 1) {
    print("ERROR: moveChunk for collB failed!");
    quit(1);
}

// Step 7: Verify cleanup
print("--- Verifying cleanup ---");
for (const [name, source] of [["conc_collA", sourceA], ["conc_collB", sourceB]]) {
    const host = source === "shard0rs" ? "shard0:27018" : "shard1:27018";
    const conn = new Mongo(host);
    const cnt = conn.getDB("testdb")[name].countDocuments({});
    print(name + " orphans on " + source + ": " + cnt);
}

print("=== Test: concurrent_migrations COMPLETE ===");
print("LOG_MARK_TIME=" + logMarkTime);
