// test_back_to_back.js — Two sequential migrations on different collections.
// Exercises back-to-back migration with two migration IDs (m1, m2).
// Both are commit paths — shard0 → shard1.
//
// Run via: mongosh --port 27017 --file /scripts/test_back_to_back.js

print("=== test_back_to_back: starting ===");

const db = connect("mongodb://localhost:27017/testdb");
const admin = db.getSiblingDB("admin");
const configDB = db.getSiblingDB("config");

// Enable sharding
admin.runCommand({enableSharding: "testdb"});

// Helper: move a collection's chunk from source to target
function migrateCollection(collName, docCount) {
    const coll = db.getCollection(collName);
    coll.drop();
    sh.shardCollection("testdb." + collName, {_id: 1});

    const bulk = coll.initializeUnorderedBulkOp();
    for (let i = 0; i < docCount; i++) {
        bulk.insert({_id: i, value: collName + "_" + i});
    }
    bulk.execute();
    print("Inserted " + docCount + " docs into " + collName);

    // Get collection UUID (MongoDB 8 uses uuid for chunk lookup)
    const collInfo = configDB.collections.findOne({_id: "testdb." + collName});
    const collUUID = collInfo.uuid;
    const chunks = configDB.chunks.find({uuid: collUUID}).toArray();

    if (chunks.length === 0) {
        print("ERROR: No chunks found for " + collName);
        return false;
    }

    const sourceShard = chunks[0].shard;
    const targetShard = sourceShard === "shard0rs" ? "shard1rs" : "shard0rs";
    print("Moving " + collName + " chunk from " + sourceShard + " to " + targetShard);

    const result = admin.runCommand({
        moveChunk: "testdb." + collName,
        find: {_id: 0},
        to: targetShard,
        _waitForDelete: true
    });

    print(collName + " moveChunk: " + (result.ok ? "ok" : JSON.stringify(result)));
    return result.ok;
}

// --- Migration 1: coll_a ---
print("\n--- Migration 1: coll_a ---");
migrateCollection("coll_a", 50);

// Small delay to separate log entries
sleep(1000);

// --- Migration 2: coll_b ---
print("\n--- Migration 2: coll_b ---");
migrateCollection("coll_b", 50);

// Verify
const countA = db.coll_a.countDocuments();
const countB = db.coll_b.countDocuments();
print("\nFinal counts: coll_a=" + countA + ", coll_b=" + countB);

print("=== test_back_to_back: done ===");
