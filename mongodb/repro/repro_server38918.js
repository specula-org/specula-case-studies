// Reproduction attempt for SERVER-38918: ShardNotFound fassert(51068) during 2PC commit/abort
//
// Scenario from MC counterexample:
// 1. Start cross-shard txn on {shard1, shard2}
// 2. Pause coordinator before sending commit decision (hangBeforeSendingCommit)
// 3. Remove shard2 from topology
// 4. Resume coordinator → ShardNotFound during commit/abort → fassert(51068)
//
// Usage: mongosh --host localhost:27117 repro_server38918.js

print("=== SERVER-38918 Reproduction Attempt ===");
print("Goal: Trigger fassert(51068) via ShardNotFound during 2PC commit/abort phase");
print("");

var admin = db.getSiblingDB("admin");
var testdb = db.getSiblingDB("testdb");

// Verify cluster state
print("=== Step 0: Verify cluster state ===");
var shards = admin.runCommand({listShards: 1});
printjson(shards);
assert(shards.shards.length >= 2, "Need at least 2 shards");

print("Data distribution:");
printjson(testdb.testcol.find().toArray());

// Step 1: Enable failpoint to pause coordinator before sending commit decision
print("\n=== Step 1: Set failpoint on shard1 (coordinator) to pause before sending commit ===");
var s1Conn = new Mongo("shard1:27017");
var s1Admin = s1Conn.getDB("admin");

// hangBeforeSendingCommit pauses the coordinator after persisting the decision
// but before sending commit/abort to participants
var fpResult = s1Admin.runCommand({
    configureFailPoint: "hangBeforeSendingCommit",
    mode: "alwaysOn"
});
print("Failpoint result: " + tojson(fpResult));

// Step 2: Start cross-shard transaction
print("\n=== Step 2: Start cross-shard transaction ===");
var session = db.getMongo().startSession();
var sessionDb = session.getDatabase("testdb");
var sessionCol = sessionDb.testcol;

session.startTransaction();

// Touch both shards
var r1 = sessionCol.updateOne({x: -1}, {$set: {val: "updated_shard1"}});
print("Update on shard1: " + tojson(r1));

var r2 = sessionCol.updateOne({x: 1}, {$set: {val: "updated_shard2"}});
print("Update on shard2: " + tojson(r2));

// Step 3: Commit the transaction (this will hang at the failpoint)
print("\n=== Step 3: Committing transaction (will hang at failpoint) ===");
print("Committing in background... coordinator will pause before sending commit to participants");

// We need to commit async. Use a parallel shell or just commit and
// handle the timeout. Since mongosh doesn't have easy async, we'll
// set a short socket timeout and catch the error.
//
// Alternative approach: just commit. If the failpoint works, the commit
// will hang and we'll need a separate connection to proceed.
// Let's use a time-limited approach.

// Actually, the simplest approach: commit synchronously.
// The coordinator is on shard1. The failpoint pauses it.
// We need a separate connection to do the removeShard.

print("NOTE: The commit call will block due to failpoint.");
print("In a real reproduction, you would run removeShard from a parallel session.");
print("We'll use maxTimeMS to avoid hanging forever.");

try {
    // commitTransaction with a timeout so we can proceed
    var commitResult = session.commitTransaction_forTesting ?
        session.commitTransaction_forTesting() :
        admin.runCommand({
            commitTransaction: 1,
            lsid: session.getSessionId(),
            txnNumber: NumberLong(1),
            autocommit: false,
            maxTimeMS: 5000
        });
    print("Commit result: " + tojson(commitResult));
} catch(e) {
    print("Commit timed out or failed (expected if failpoint active): " + e);
}

// Step 4: While coordinator is paused, remove shard2
print("\n=== Step 4: Removing shard2 while coordinator is paused ===");

// First, move all chunks from shard2 to shard1
print("Moving chunks off shard2...");
var moveResult = admin.runCommand({
    moveChunk: "testdb.testcol",
    find: {x: 1},
    to: "shard1RS"
});
print("moveChunk result: " + tojson(moveResult));
sleep(3000);

// Now remove shard2
print("Initiating removeShard...");
var removeResult = admin.runCommand({removeShard: "shard2RS"});
print("removeShard result: " + tojson(removeResult));

// Keep calling removeShard until complete
for (var i = 0; i < 30; i++) {
    sleep(2000);
    removeResult = admin.runCommand({removeShard: "shard2RS"});
    print("removeShard attempt " + (i+1) + ": state=" + removeResult.state);
    if (removeResult.state === "completed") {
        print("Shard2 removed successfully!");
        break;
    }
}

// Step 5: Disable failpoint to let coordinator proceed
print("\n=== Step 5: Disabling failpoint — coordinator will try to reach removed shard2 ===");
fpResult = s1Admin.runCommand({
    configureFailPoint: "hangBeforeSendingCommit",
    mode: "off"
});
print("Failpoint disabled: " + tojson(fpResult));

// Step 6: Check if shard1 (coordinator) is still alive
print("\n=== Step 6: Checking coordinator health ===");
sleep(5000);

try {
    var pingResult = s1Admin.runCommand({ping: 1});
    print("Shard1 ping: " + tojson(pingResult));
    if (pingResult.ok) {
        print("RESULT: Coordinator survived — fassert(51068) was NOT triggered.");
        print("This could mean:");
        print("  1. The failpoint didn't pause at the right phase");
        print("  2. Shard2 removal wasn't complete before coordinator resumed");
        print("  3. The coordinator decided to abort (prepare-phase ShardNotFound) and handled it");
    }
} catch(e) {
    print("Shard1 ping failed: " + e);
    print("RESULT: Coordinator may have hit fassert(51068)!");
    print("Check shard1 logs for: fassert(51068)");
}

// Check shard1 logs
print("\n=== Checking shard1 logs for fassert ===");
try {
    var logResult = s1Admin.runCommand({getLog: "global"});
    var logs = logResult.log;
    var fassertLogs = logs.filter(function(l) { return l.indexOf("51068") >= 0 || l.indexOf("fassert") >= 0; });
    if (fassertLogs.length > 0) {
        print("FOUND fassert in logs:");
        fassertLogs.forEach(function(l) { print(l); });
    } else {
        print("No fassert(51068) found in recent logs.");
    }
} catch(e) {
    print("Could not retrieve logs (coordinator may be down): " + e);
}

print("\n=== Reproduction attempt complete ===");
session.endSession();
