// test_basic_commit.js — Single moveChunk that commits successfully.
// Exercises the full commit lifecycle: StartMigration → AdvanceToConfigCommit →
// ConfigCommitSucceed → all commit cleanup sub-steps → CleanupComplete.
//
// Run via: mongosh --port 27017 --file /scripts/test_basic_commit.js

print("=== test_basic_commit: starting ===");

const db = connect("mongodb://localhost:27017/testdb");
const admin = db.getSiblingDB("admin");
const configDB = db.getSiblingDB("config");

// Enable sharding on testdb
admin.runCommand({enableSharding: "testdb"});

// Create and shard a collection with _id as shard key
db.basic_coll.drop();
sh.shardCollection("testdb.basic_coll", {_id: 1});

// Insert documents so there's data to migrate (produces orphans on donor)
const bulk = db.basic_coll.initializeUnorderedBulkOp();
for (let i = 0; i < 100; i++) {
    bulk.insert({_id: i, value: "doc_" + i});
}
bulk.execute();
print("Inserted 100 documents into testdb.basic_coll");

// Get collection UUID for chunk lookup (MongoDB 8 uses uuid, not ns)
const collInfo = configDB.collections.findOne({_id: "testdb.basic_coll"});
const collUUID = collInfo.uuid;
print("Collection UUID: " + collUUID);

// Find chunk by UUID
const chunks = configDB.chunks.find({uuid: collUUID}).toArray();
print("Found " + chunks.length + " chunks");

if (chunks.length === 0) {
    print("ERROR: No chunks found, cannot proceed");
    quit(1);
}

const sourceShard = chunks[0].shard;
const targetShard = sourceShard === "shard0rs" ? "shard1rs" : "shard0rs";
print("Moving chunk from " + sourceShard + " to " + targetShard);

// Move the chunk — this triggers the full migration lifecycle
const result = admin.runCommand({
    moveChunk: "testdb.basic_coll",
    find: {_id: 0},
    to: targetShard,
    _waitForDelete: true  // wait for range deletion to complete on donor
});

if (result.ok) {
    print("moveChunk succeeded");
} else {
    print("moveChunk result: " + JSON.stringify(result));
}

// Verify chunk moved
const newChunks = configDB.chunks.find({uuid: collUUID}).toArray();
print("After move - chunks on: " + JSON.stringify(newChunks.map(c => c.shard)));

// Verify documents are accessible
const count = db.basic_coll.countDocuments();
print("Document count after migration: " + count);

print("=== test_basic_commit: done ===");
