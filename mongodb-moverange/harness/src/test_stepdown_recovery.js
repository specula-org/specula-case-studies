// test_stepdown_recovery.js — Stepdown and recovery of migration coordinator.
//
// Does a normal migration, then triggers a stepdown on shard0 to exercise
// the recovery code path (resumeMigrationCoordinationsOnStepUp).
//
// With a single-node replica set, stepdown causes a brief SECONDARY state
// followed by immediate re-election as PRIMARY. This exercises the full
// recovery path including StepUp and RecoverMigration (if a coordinator doc
// is found).

print("=== test_stepdown_recovery: starting ===");

db = db.getSiblingDB("admin");

// Step 1: Enable sharding
sh.enableSharding("testmr_sd");

// Step 2: Create sharded collection
db.adminCommand({
    shardCollection: "testmr_sd.data",
    key: { _id: 1 }
});

// Step 3: Insert data
db = db.getSiblingDB("testmr_sd");
for (var i = 0; i < 50; i++) {
    db.data.insertOne({ _id: i, val: "stepdown_test_" + i });
}
print("Inserted 50 documents");

// Step 4: Ensure chunk is on shard0
db = db.getSiblingDB("admin");
try {
    db.adminCommand({
        moveChunk: "testmr_sd.data",
        find: { _id: 0 },
        to: "shard0rs"
    });
} catch(e) {
    print("Chunk may already be on shard0: " + e.message);
}
sleep(3000);

// Step 5: Do a normal migration (shard0 -> shard1)
print("Running migration shard0 -> shard1...");
var result = db.adminCommand({
    moveChunk: "testmr_sd.data",
    find: { _id: 0 },
    to: "shard1rs"
});
print("Migration result ok: " + result.ok);
sleep(2000);

// Step 6: Move chunk back to shard0 for the stepdown test
print("Moving chunk back shard1 -> shard0...");
result = db.adminCommand({
    moveChunk: "testmr_sd.data",
    find: { _id: 0 },
    to: "shard0rs"
});
print("Move-back result ok: " + result.ok);
sleep(2000);

// Step 7: Trigger a stepdown on shard0
// The migration coordinator step-up recovery will fire when shard0 re-elects.
// Even if there's no active migration, StepUp (4798510) will be logged.
print("Triggering stepdown on shard0...");
var shard0Conn = new Mongo("shard0:27018");
var shard0Admin = shard0Conn.getDB("admin");
try {
    shard0Admin.runCommand({ replSetStepDown: 5, force: true });
} catch(e) {
    // Expected: connection may be closed during stepdown
    print("Stepdown triggered (expected network error)");
}

// Step 8: Wait for re-election
print("Waiting for re-election (15s)...");
sleep(15000);

// Step 9: Verify shard0 is primary again
var retries = 0;
while (retries < 30) {
    try {
        shard0Conn = new Mongo("shard0:27018");
        shard0Admin = shard0Conn.getDB("admin");
        var isMaster = shard0Admin.runCommand({ isMaster: 1 });
        if (isMaster.ismaster) {
            print("Shard0 is primary again");
            break;
        }
    } catch(e) {
        // Connection might fail during recovery
    }
    sleep(1000);
    retries++;
}

// Step 10: Do one final migration to verify post-recovery operation
print("Running post-recovery migration shard0 -> shard1...");
sleep(3000);
try {
    result = db.adminCommand({
        moveChunk: "testmr_sd.data",
        find: { _id: 0 },
        to: "shard1rs"
    });
    print("Post-recovery migration result ok: " + result.ok);
} catch(e) {
    print("Post-recovery migration error: " + e.message);
}

sleep(5000);

print("=== test_stepdown_recovery: done ===");
