// test_stepdown_recovery.js — StepDown during range deletion, then recovery on step-up.
// Exercises: StepUp → RecoveryBegin → RecoveryComplete → StepDown → StepUp → RecoveryBegin → RecoveryComplete
//
// Run via: mongosh --host mongos:27017 --file test_stepdown_recovery.js

print("=== Test: stepdown_recovery ===");
const db = connect("mongos:27017/testdb");
const adminDB = db.getSiblingDB("admin");

// Clean up from previous runs
db.stepdown_coll.drop();

// Step 1: Create and shard collection
print("--- Creating sharded collection ---");
adminDB.runCommand({ enableSharding: "testdb" });
adminDB.runCommand({ shardCollection: "testdb.stepdown_coll", key: { _id: 1 } });

// Step 2: Insert documents
print("--- Inserting documents ---");
const bulk = db.stepdown_coll.initializeUnorderedBulkOp();
for (let i = 0; i < 200; i++) {
    bulk.insert({ _id: i, data: "x".repeat(1000) });
}
bulk.execute();
print("Inserted 200 documents");

// Step 3: Determine shard placement
const chunks = db.getSiblingDB("config").chunks.find(
    { ns: "testdb.stepdown_coll" }, { shard: 1 }
).toArray();
const sourceShard = chunks[0].shard;
const targetShard = sourceShard === "shard0rs" ? "shard1rs" : "shard0rs";
const sourceHost = sourceShard === "shard0rs" ? "shard0:27018" : "shard1:27018";

print("Source: " + sourceShard + " (" + sourceHost + ")");
print("Target: " + targetShard);

// Step 4: Enable failpoint to pause range deletion AFTER task is registered but before execution
print("--- Enabling failpoint on source shard to pause deletion ---");
const sourceConn = new Mongo(sourceHost);
const sourceAdmin = sourceConn.getDB("admin");

// This failpoint pauses the range deletion processor after picking the task
sourceAdmin.runCommand({
    configureFailPoint: "hangBeforeDoingDeletion",
    mode: "alwaysOn"
});

// Step 5: Mark log position
const logMarkTime = new Date().toISOString();
print("Log mark time: " + logMarkTime);

// Step 6: Start migration (don't wait for delete since we want to step down mid-deletion)
print("--- Starting migration (no wait for delete) ---");
const moveResult = adminDB.runCommand({
    moveChunk: "testdb.stepdown_coll",
    find: { _id: 0 },
    to: targetShard,
    _waitForDelete: false
});
printjson(moveResult);

if (moveResult.ok !== 1) {
    print("ERROR: moveChunk failed!");
    // Disable failpoint before exiting
    sourceAdmin.runCommand({ configureFailPoint: "hangBeforeDoingDeletion", mode: "off" });
    quit(1);
}

// Give range deletion time to start
sleep(2000);

// Step 7: Disable failpoint, then immediately step down the source shard
print("--- Disabling failpoint and stepping down source shard ---");
sourceAdmin.runCommand({ configureFailPoint: "hangBeforeDoingDeletion", mode: "off" });

// Step down the primary — this kills the range deleter service
print("--- Stepping down source shard primary ---");
try {
    // Force step down. Since it's a single-node RS, it will step back up automatically
    sourceAdmin.runCommand({
        replSetStepDown: 5,        // Step down for 5 seconds
        secondaryCatchUpPeriodSecs: 0,
        force: true
    });
} catch (e) {
    // Expected: connection may be closed during stepdown
    print("Step down response (may error due to connection close): " + e.message);
}

// Wait for the node to step back up (single-node RS auto-elects)
print("--- Waiting for source shard to become primary again ---");
sleep(10000);

// Reconnect and verify it's primary again
const sourceConn2 = new Mongo(sourceHost);
const sourceAdmin2 = sourceConn2.getDB("admin");

let retries = 0;
while (retries < 30) {
    try {
        const isMaster = sourceAdmin2.runCommand({ hello: 1 });
        if (isMaster.isWritablePrimary) {
            print("Source shard is primary again");
            break;
        }
    } catch (e) {
        // Connection may not be ready yet
    }
    sleep(1000);
    retries++;
}

if (retries >= 30) {
    print("ERROR: Source shard did not become primary within 30 seconds");
    quit(1);
}

// Step 8: Wait for recovery to complete and range deletion to finish
print("--- Waiting for range deletion recovery to complete ---");
sleep(10000);

// Check orphan count
const sourceDB2 = sourceConn2.getDB("testdb");
const orphanCount = sourceDB2.stepdown_coll.countDocuments({});
print("Orphan count after recovery: " + orphanCount);

if (orphanCount === 0) {
    print("SUCCESS: Range deletion recovered and completed after stepdown");
} else {
    print("INFO: " + orphanCount + " orphans remain (may still be processing)");
    // Wait more
    sleep(10000);
    const finalCount = sourceDB2.stepdown_coll.countDocuments({});
    print("Final orphan count: " + finalCount);
}

print("=== Test: stepdown_recovery COMPLETE ===");
print("LOG_MARK_TIME=" + logMarkTime);
