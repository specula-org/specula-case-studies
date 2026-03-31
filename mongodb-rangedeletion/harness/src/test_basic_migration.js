// test_basic_migration.js — Basic moveChunk scenario that exercises the full range deletion lifecycle.
//
// Produces trace events: StepUp → RecoveryBegin → RecoveryComplete → StartMigration →
//   CommitMigration → ClearPending → CheckOverlap → QueriesDrained → ProcessorPickTask → CompleteTask
//
// Run via: mongosh --host mongos:27017 --file test_basic_migration.js

print("=== Test: basic_migration ===");
const db = connect("mongos:27017/testdb");
const adminDB = db.getSiblingDB("admin");
const configDB = db.getSiblingDB("config");

// Clean up from previous runs
db.basic_coll.drop();

// Step 1: Create and shard the collection
print("--- Creating sharded collection ---");
adminDB.runCommand({ enableSharding: "testdb" });
adminDB.runCommand({
    shardCollection: "testdb.basic_coll",
    key: { _id: 1 }
});

// Step 2: Insert test documents
print("--- Inserting documents ---");
const bulk = db.basic_coll.initializeUnorderedBulkOp();
for (let i = 0; i < 100; i++) {
    bulk.insert({ _id: i, data: "test_" + i });
}
bulk.execute();
print("Inserted 100 documents");

// Step 3: Get collection UUID and find chunks
print("--- Initial chunk distribution ---");
const collInfo = configDB.collections.findOne({ _id: "testdb.basic_coll" });
const collUUID = collInfo.uuid;
print("Collection UUID: " + collUUID);

const chunks = configDB.chunks.find(
    { uuid: collUUID },
    { shard: 1, min: 1, max: 1 }
).toArray();
printjson(chunks);

// Determine which shard owns the data
const sourceShard = chunks[0].shard;
const targetShard = sourceShard === "shard0rs" ? "shard1rs" : "shard0rs";
print("Source shard: " + sourceShard);
print("Target shard: " + targetShard);

// Step 4: Clear logs before migration (we'll extract logs after)
print("--- Marking log position ---");
const logMarkTime = new Date().toISOString();
print("Log mark time: " + logMarkTime);

// Step 5: Move the chunk — this triggers the full range deletion lifecycle on the donor
print("--- Moving chunk from " + sourceShard + " to " + targetShard + " ---");
const moveResult = adminDB.runCommand({
    moveChunk: "testdb.basic_coll",
    find: { _id: 0 },
    to: targetShard,
    _waitForDelete: true  // Wait for range deletion to complete
});
printjson(moveResult);

if (moveResult.ok !== 1) {
    print("ERROR: moveChunk failed!");
    quit(1);
}

// Step 6: Verify migration completed
print("--- Post-migration chunk distribution ---");
const newChunks = configDB.chunks.find(
    { uuid: collUUID },
    { shard: 1, min: 1, max: 1 }
).toArray();
printjson(newChunks);

// Step 7: Verify range deletion completed (no orphans on source)
print("--- Verifying orphan cleanup ---");
const sourceHost = sourceShard === "shard0rs" ? "shard0:27018" : "shard1:27018";
const sourceConn = new Mongo(sourceHost);
const sourceDB = sourceConn.getDB("testdb");
const orphanCount = sourceDB.basic_coll.countDocuments({});
print("Orphan count on source shard: " + orphanCount);

if (orphanCount > 0) {
    print("WARNING: " + orphanCount + " orphaned documents remain on source shard");
} else {
    print("SUCCESS: All orphaned documents cleaned up");
}

// Step 8: Verify data on target
const targetHost = targetShard === "shard0rs" ? "shard0:27018" : "shard1:27018";
const targetConn = new Mongo(targetHost);
const targetDB = targetConn.getDB("testdb");
const targetCount = targetDB.basic_coll.countDocuments({});
print("Document count on target shard: " + targetCount);

print("=== Test: basic_migration COMPLETE ===");
print("LOG_MARK_TIME=" + logMarkTime);
