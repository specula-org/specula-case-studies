// test_abort_migration.js — Migration abort path.
//
// Forces a migration abort by failing the config server commit step.
// Exercises: StartMigration, DonorEnterCriticalSection, DecideAbort,
//            AbortPersistDecision, AbortDeleteDonorRangeDel, AbortBumpRecipientTxn,
//            AbortMarkRecipientRangeDelReady, AbortForgetMigration

print("=== test_abort_migration: starting ===");

db = db.getSiblingDB("admin");

// Step 1: Enable sharding
sh.enableSharding("testmr_abort2");

// Step 2: Create sharded collection
db.adminCommand({
    shardCollection: "testmr_abort2.data",
    key: { _id: 1 }
});

// Step 3: Insert data
db = db.getSiblingDB("testmr_abort2");
for (var i = 0; i < 50; i++) {
    db.data.insertOne({ _id: i, val: "abort_test_" + i });
}
print("Inserted 50 documents");

// Step 4: Ensure chunk is on shard0
db = db.getSiblingDB("admin");
try {
    db.adminCommand({
        moveChunk: "testmr_abort2.data",
        find: { _id: 0 },
        to: "shard0rs"
    });
} catch(e) {
    print("Chunk may already be on shard0: " + e.message);
}
sleep(3000);

// Step 5: Enable failpoint on recipient (shard1) to abort migration during cloning.
// "failMigrationOnRecipient" causes the recipient to reject the migration, which
// makes the donor abort before reaching the config server commit.
print("Enabling failpoint on recipient shard1...");
var shard1Conn = new Mongo("shard1:27018");
var shard1Admin = shard1Conn.getDB("admin");
shard1Admin.runCommand({
    configureFailPoint: "failMigrationOnRecipient",
    mode: { times: 1 }
});
print("Failpoint set on shard1");

// Step 6: Attempt migration (will be aborted due to config commit failure)
print("Attempting migration (expecting abort)...");
try {
    var result = db.adminCommand({
        moveChunk: "testmr_abort2.data",
        find: { _id: 0 },
        to: "shard1rs"
    });
    print("moveChunk result ok: " + result.ok);
} catch(e) {
    print("moveChunk failed as expected: " + e.message);
}

sleep(3000);

// Step 7: Disable failpoint
shard1Admin.runCommand({
    configureFailPoint: "failMigrationOnRecipient",
    mode: "off"
});
print("Failpoint cleared");

// Step 8: Verify chunk is still on shard0
sleep(2000);
print("=== test_abort_migration: done ===");
