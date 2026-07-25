/**
 * Reproduction: Bug 1 — deleteRangeDeletionTaskLocally missing migrationId filter
 *
 * Demonstrates that a recovery-replayed abort from migration M1 can delete the
 * range deletion task document belonging to migration M2, because
 * deleteRangeDeletionTaskLocally() queries by (collectionUuid, range) without
 * including migrationId.
 *
 * Scenario:
 *   1. Move chunk [0, MaxKey) from shard0 to shard1 (migration M1)
 *   2. Pause M1's abort AFTER deleteRangeDeletionTaskLocally but BEFORE forgetMigration
 *   3. Force stepdown to crash the abort flow, leaving M1's coordinator doc
 *   4. Move the same chunk back: shard1 → shard0, then shard0 → shard1 again (migration M2)
 *   5. M2 commits, creating a new range deletion task doc on shard0
 *   6. Step up triggers recovery of M1's coordinator doc → replays abort
 *   7. deleteRangeDeletionTaskLocally(collUUID, range) matches M2's doc and deletes it
 *   8. M2's range deletion task is now orphaned (in-memory state exists, persistent doc gone)
 *
 * Expected: M2's task doc should NOT be deleted by M1's abort replay.
 * Actual:   M2's task doc IS deleted because the query lacks migrationId.
 *
 * Prerequisites: Run with resmoke.py against a MongoDB build (v8.1+)
 *   resmoke.py run --suites=sharding bug1_migrationid_filter.js
 *
 * @tags: [requires_sharding, requires_persistence]
 */

(function() {
'use strict';

load("jstests/libs/fail_point_util.js");

const st = new ShardingTest({shards: 2, rs: {nodes: 2}});

const dbName = 'testDB';
const collName = 'testColl';
const ns = dbName + '.' + collName;
const db = st.getDB(dbName);

// Setup: shard the collection with shard0 as primary
assert.commandWorked(
    st.s.adminCommand({enableSharding: dbName, primaryShard: st.shard0.shardName}));
assert.commandWorked(st.s.adminCommand({shardCollection: ns, key: {_id: 1}}));

// Create a chunk and insert data
assert.commandWorked(st.s.adminCommand({split: ns, middle: {_id: 0}}));
const coll = db[collName];
let bulk = coll.initializeUnorderedBulkOp();
for (let i = 0; i < 100; i++) {
    bulk.insert({_id: i});
}
assert.commandWorked(bulk.execute());

// Step 1: Move chunk [0, MaxKey) from shard0 to shard1 (this will be M1)
// Use a failpoint to pause the abort flow AFTER deleting the local range deletion task
// but BEFORE forgetMigration removes the coordinator doc
let hangBeforeForget =
    configureFailPoint(st.shard0, "hangBeforeForgettingMigrationAfterAbortDecision");

// Configure M1 to abort by pausing during clone phase and then forcing abort
let hangDuringClone = configureFailPoint(st.shard1, "migrateThreadHangAtStep3");

jsTestLog("Starting migration M1 (will be aborted)...");
let m1Thread = new Thread(function(mongosHost, ns) {
    const mongos = new Mongo(mongosHost);
    // This migration will be aborted
    assert.commandFailed(
        mongos.adminCommand({moveChunk: ns, find: {_id: 1}, to: 'shard0001', maxTimeMS: 10000}));
}, st.s.host, ns);
m1Thread.start();

// Wait for migration to reach clone phase, then abort it
hangDuringClone.wait();

// Abort M1 by stepping down the donor (which triggers cleanup with abort decision)
jsTestLog("Aborting M1 by turning off the clone failpoint and letting it timeout...");
hangDuringClone.off();
m1Thread.join();

// M1's abort is now paused at hangBeforeForgettingMigration
// The coordinator doc still exists with abort decision
hangBeforeForget.wait();

jsTestLog("M1 abort paused before forgetMigration. Coordinator doc still exists.");

// Verify M1's coordinator doc exists
let coordDocs = st.shard0.getDB("config").getCollection("migrationCoordinators").find().toArray();
jsTestLog("Coordinator docs after M1 abort: " + tojson(coordDocs));
assert.gte(coordDocs.length, 1, "M1 coordinator doc should exist");

// Step 2: Force stepdown to prevent forgetMigration from completing
jsTestLog("Stepping down shard0 primary to prevent forgetMigration...");
hangBeforeForget.off();
try {
    assert.commandWorked(
        st.rs0.getPrimary().adminCommand({replSetStepDown: 10, force: true}));
} catch (e) {
    // Stepdown may throw network error, that's fine
    jsTestLog("Stepdown threw (expected): " + e);
}
st.rs0.awaitNodesAgreeOnPrimary();

// Wait for new primary to be ready
let newPrimary = st.rs0.getPrimary();
jsTestLog("New shard0 primary: " + newPrimary.host);

// Step 3: Move chunk back and forth to create M2 on the same range
// First, the chunk should already be on shard0 since M1 was aborted
jsTestLog("Moving chunk to create M2's range deletion task...");

// The chunk [0, MaxKey) is still on shard0 (M1 was aborted)
// Move it to shard1 successfully this time
assert.commandWorked(
    st.s.adminCommand({moveChunk: ns, find: {_id: 1}, to: st.shard1.shardName}));

jsTestLog("M2 committed. Checking range deletion task docs...");

// Step 4: Verify the range deletion task doc from M2 exists
let rdDocs = st.rs0.getPrimary().getDB("config").getCollection("rangeDeletions").find().toArray();
jsTestLog("Range deletion docs after M2 commit: " + tojson(rdDocs));

// Check: M2's task doc should exist
let m2TaskExists = rdDocs.some(doc => {
    return doc.collectionUuid !== undefined;
});

if (m2TaskExists) {
    jsTestLog("SUCCESS: M2's range deletion task doc exists.");
} else {
    jsTestLog("BUG TRIGGERED: M2's range deletion task doc was deleted by M1's abort recovery!");
}

// Step 5: Check if M1's coordinator doc was recovered and replayed
// After step-up, resumeMigrationCoordinationsOnStepUp replays unfinished migrations
coordDocs = st.rs0.getPrimary().getDB("config").getCollection("migrationCoordinators").find().toArray();
jsTestLog("Coordinator docs after recovery: " + tojson(coordDocs));

// Wait for recovery to complete
sleep(5000);

// Final check: is M2's range deletion task doc still there?
rdDocs = st.rs0.getPrimary().getDB("config").getCollection("rangeDeletions").find().toArray();
jsTestLog("Range deletion docs after recovery replay: " + tojson(rdDocs));

let finalM2TaskExists = rdDocs.length > 0;
if (!finalM2TaskExists) {
    jsTestLog("BUG CONFIRMED: M2's range deletion task doc was deleted by M1's abort recovery " +
              "because deleteRangeDeletionTaskLocally does not filter by migrationId!");
    // The in-memory RangeDeleterService still thinks the task exists, but the persistent doc is gone.
    // This means: if the shard steps down again, the range deletion task will be lost entirely,
    // leaving orphaned documents permanently on the donor shard.
} else {
    jsTestLog("M2's task doc survived recovery. Bug may not have triggered in this run.");
}

st.stop();
})();
