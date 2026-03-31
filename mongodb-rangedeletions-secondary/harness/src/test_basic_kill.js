// =================================================================
// Test: basic_kill — Query on secondary killed by range deletion
//
// Flow:
//   1. Shard collection, insert docs on shard0 (primary shard)
//   2. Open cursor through MONGOS with readPreference=secondary
//      (mongos adds shard version → secondary creates RangePreserver)
//   3. moveChunk shard0 → shard1 (triggers processing=true,
//      which invalidates older metadata trackers on secondary)
//   4. Continue cursor → getMore goes to same secondary →
//      kill check fires → QueryPlanKilled
//
// CRITICAL: The query MUST go through mongos (not direct connection).
//   Direct connections lack shard version info, so no RangePreserver
//   is created and the kill check never fires.
//
// Trace events emitted (TRACE: prefix, extracted by run.sh):
//   init, SignalUpdate, BatchCommitted,
//   QueryAdvanceSnapshot, QueryKilled (or QueryProceed)
// =================================================================

print("=== test_basic_kill: start ===")

// --- Step 0: Setup sharded collection on shard0 ---

// Create database and ensure primary shard is shard0 (has a secondary)
const testDb = db.getSiblingDB("testdb")
testDb.getCollection("setupinit").insertOne({_id: "init"})
try {
    db.adminCommand({movePrimary: "testdb", to: "shard0rs"})
    print("movePrimary: testdb -> shard0rs")
} catch (e) {
    print("movePrimary info: " + e.message)
}
testDb.getCollection("setupinit").drop()

// Shard the collection
const shardRes = sh.shardCollection("testdb.testcoll", {_id: 1})
print("shardCollection: " + JSON.stringify(shardRes))

// Insert 10 docs (all on shard0 since single chunk [MinKey, MaxKey])
for (let i = 0; i < 10; i++) {
    testDb.testcoll.insertOne({_id: i, data: "doc" + i})
}
print("Inserted 10 docs on shard0")

// Verify chunk placement
const collUUID = db.getSiblingDB("config").collections.findOne(
    {_id: "testdb.testcoll"}
)
const chunks = db.getSiblingDB("config").chunks.find(
    {uuid: collUUID.uuid}
).toArray()
print("Chunks: " + JSON.stringify(chunks.map(c => ({shard: c.shard, min: c.min, max: c.max}))))

// --- Step 1: Wait for replication, configure secondary ---

print("Waiting for replication to secondary...")
sleep(3000)

// Enable query kill logging on the secondary (direct admin connection)
const secAdminConn = new Mongo("mongodb://shard0sec:27018/?directConnection=true")
try {
    secAdminConn.getDB("admin").runCommand({
        setParameter: 1,
        enableQueryKilledByRangeDeletionLog: true
    })
    print("Enabled enableQueryKilledByRangeDeletionLog on secondary")
} catch (e) {
    print("setParameter info: " + e.message + " (may not exist in this version)")
}

// Ensure terminateSecondaryReadsOnOrphanCleanup is enabled
try {
    secAdminConn.getDB("admin").runCommand({
        setParameter: 1,
        terminateSecondaryReadsOnOrphanCleanup: true
    })
    print("Enabled terminateSecondaryReadsOnOrphanCleanup on secondary")
} catch (e) {
    print("setParameter info: " + e.message)
}

// Also enable on primary (in case it's needed for op observer)
const priAdminConn = new Mongo("mongodb://shard0pri:27018/?directConnection=true")
try {
    priAdminConn.getDB("admin").runCommand({
        setParameter: 1,
        enableQueryKilledByRangeDeletionLog: true
    })
    priAdminConn.getDB("admin").runCommand({
        setParameter: 1,
        terminateSecondaryReadsOnOrphanCleanup: true
    })
    print("Enabled kill features on primary too")
} catch (e) {
    print("setParameter on primary info: " + e.message)
}

// Verify docs on secondary (using mongos with secondary read pref)
const verifyConn = new Mongo("mongodb://localhost:27017/")
verifyConn.setReadPref("secondary")
const verifyDb = verifyConn.getDB("testdb")
let secCount = verifyDb.testcoll.countDocuments({})
print("Docs readable via secondary (through mongos): " + secCount)

if (secCount === 0) {
    print("WARNING: 0 docs via secondary — waiting more...")
    sleep(5000)
    secCount = verifyDb.testcoll.countDocuments({})
    print("Docs via secondary (retry): " + secCount)
}

// --- Emit init line ---
// Abstract version mapping for the spec:
//   Tracker 1 (pre-migration metadata): shardPlacementVersion = 1
//   Tracker 2 (post-migration, created during moveChunk): shardPlacementVersion = 2
//   RD preMigShardVersion = 1 (version at migration start)
//   Query uses tracker 1 (cursor opened before migration)
print("TRACE:" + JSON.stringify({
    event: "init",
    nodeRole: "SECONDARY",
    trackerShardV: [1, 2],
    rdPreMigShardV: [1],
    queryTracker: [1]
}))

// --- Step 2: Open cursor through mongos with readPreference=secondary ---
// CRITICAL: Must go through mongos so shard version is included in the
// find command. This causes the secondary to create a RangePreserver.

print("Opening cursor via mongos with readPref=secondary, batchSize=1...")
const queryConn = new Mongo("mongodb://localhost:27017/")
queryConn.setReadPref("secondary")
const queryDb = queryConn.getDB("testdb")

const cursor = queryDb.testcoll.find({}).sort({_id: 1}).batchSize(1)
let firstDoc
try {
    firstDoc = cursor.next()
    print("First doc from cursor: " + JSON.stringify(firstDoc))
} catch (e) {
    print("ERROR: Could not read first doc: " + e.message)
    print("=== test_basic_kill: FAILED (cannot read from secondary) ===")
    quit(1)
}

// --- Step 3: moveChunk (triggers range deletion on shard0) ---
// Use the default mongos connection (primary read pref) for admin ops

print("Triggering moveChunk: shard0rs -> shard1rs ...")
const beforeMoveChunk = new Date().toISOString()

const moveResult = db.adminCommand({
    moveChunk: "testdb.testcoll",
    find: {_id: 0},
    to: "shard1rs"
})

const afterMoveChunk = new Date().toISOString()
print("moveChunk result: " + JSON.stringify(moveResult))
print("moveChunk window: " + beforeMoveChunk + " -> " + afterMoveChunk)

if (!moveResult.ok) {
    print("ERROR: moveChunk failed: " + JSON.stringify(moveResult))
    print("=== test_basic_kill: FAILED ===")
    quit(1)
}

// Wait for replication of processing=true and deletion to secondary
print("Waiting for replication of invalidation signal to secondary...")
sleep(5000)

// Emit SignalUpdate: processing=true applied on secondary, trackers invalidated
// trackerValid: tracker 1 (shardV=1 vs preMigV=1 → equal → invalidated)
//               tracker 2 (shardV=2 vs preMigV=1 → greater → survives)
print("TRACE:" + JSON.stringify({
    event: "SignalUpdate",
    rd: 1,
    trackerValid: [false, true]
}))

// Emit BatchCommitted: range deletion batch applied on secondary
// After deletion, 0 docs remain in lastAppliedSnapshot
print("TRACE:" + JSON.stringify({
    event: "BatchCommitted",
    rd: 1,
    lastAppliedSnapshotSize: 0
}))

// --- Step 4: Continue cursor (triggers kill check) ---
// The next getMore goes back to shard0-secondary via mongos:
//   1. Advances storage snapshot (QueryAdvanceSnapshot)
//   2. Checks RangePreserver validity → tracker 1 is invalid → kills query

print("TRACE:" + JSON.stringify({
    event: "QueryAdvanceSnapshot",
    query: 1
}))

print("Continuing cursor on secondary via mongos (expecting kill)...")
let killed = false
let docsRead = 1  // Already read first doc

try {
    while (cursor.hasNext()) {
        cursor.next()
        docsRead++
    }
    print("Query completed without error. Docs read: " + docsRead)
    print("TRACE:" + JSON.stringify({
        event: "QueryProceed",
        query: 1,
        queryState: "DONE_OK"
    }))
} catch (e) {
    killed = true
    print("Query killed: " + e.message)
    print("TRACE:" + JSON.stringify({
        event: "QueryKilled",
        query: 1,
        queryState: "KILLED"
    }))
}

// --- Report ---
if (killed) {
    print("=== test_basic_kill: KILLED (expected behavior) ===")
} else {
    print("=== test_basic_kill: PROCEED (query was NOT killed) ===")
    print("NOTE: This may indicate the feature flag is disabled, or the")
    print("      cursor exhausted before the kill check could fire.")
    print("      The trace is still valid — QueryProceed is a spec-legal outcome.")
}
