// test_basic_commit.js — Basic chunk migration commit path.
//
// Migrates a chunk from shard0 (s1) to shard1 (s2).
// Exercises: StartMigration, RecipientEnterCriticalSection, DonorEnterCriticalSection,
//            CommitOnConfigServer, PersistCommitDecision, CommitBumpRecipientTxn,
//            CommitDeleteRecipientRangeDel, CommitMarkDonorRangeDelReady,
//            CommitForgetMigration, DeleteRange

print("=== test_basic_commit: starting ===");

db = db.getSiblingDB("admin");

// Step 1: Enable sharding on test database
sh.enableSharding("testmr_basic");

// Step 2: Create sharded collection with range key (not hashed, for predictable chunks)
db.adminCommand({
    shardCollection: "testmr_basic.data",
    key: { _id: 1 }
});

// Step 3: Insert some data
db = db.getSiblingDB("testmr_basic");
for (var i = 0; i < 50; i++) {
    db.data.insertOne({ _id: i, val: "test_" + i });
}
print("Inserted 50 documents");

// Step 4: Determine which shard currently owns the chunk
// With range sharding and no splits, there's one chunk [MinKey, MaxKey) on some shard
db = db.getSiblingDB("admin");
var status = sh.status();

// Try to move the chunk: we want shard0->shard1
// First ensure it's on shard0
print("Ensuring chunk is on shard0rs...");
try {
    db.adminCommand({
        moveChunk: "testmr_basic.data",
        find: { _id: 0 },
        to: "shard0rs"
    });
    print("  Moved to shard0rs");
} catch(e) {
    print("  Chunk may already be on shard0rs: " + e.message);
}
sleep(3000);

// Step 5: Move chunk from shard0 to shard1 (THIS is the migration we want to trace)
print("Moving chunk from shard0rs to shard1rs...");
var result = db.adminCommand({
    moveChunk: "testmr_basic.data",
    find: { _id: 0 },
    to: "shard1rs"
});
print("moveChunk result ok: " + result.ok);

// Step 6: Wait for range deletion to complete
sleep(5000);

print("=== test_basic_commit: done ===");
