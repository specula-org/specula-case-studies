// Test: Reaper interaction with prepared transaction.
// Trace events:
//   s1: CheckOut -> Begin -> CheckIn -> CheckOut -> Prepare -> CheckIn
//   s2: (exists from Init, no txn -> reapable)
//   Reaper: EndSession(s2) -> ReaperScanMemory -> ReaperDeleteImages -> ReaperDeleteTxnRecords
//
// This exercises the F1 bug family: reaper must not destroy sessions with prepared txns.
// Session s1 has a prepared txn (not reapable). Session s2 has no txn (reapable).
// The reaper should reap s2 but not s1.

load("/scripts/trace_helpers.js");

var conn = new Mongo("mongodb://mongo1:27017/?replicaSet=rs0");
var db = conn.getDB("testdb_reaper");

// Ensure collection exists
db.createCollection("testcoll");

// --- Session s1: begin + prepare (holds prepared txn) ---
var session1 = conn.startSession();
var s1db = session1.getDatabase("testdb_reaper");

session1.startTransaction({
    readConcern: {level: "snapshot"},
    writeConcern: {w: "majority"}
});
s1db.testcoll.insertOne({x: 1, scenario: "reaper_s1"});

emitEvent("CheckOutSession", {session: "s1", thread: "t1", checkedOut: true});
emitEvent("BeginTransaction", {session: "s1", thread: "t1", txnState: "inProgress"});
emitEvent("CheckInSession", {session: "s1", thread: "t1", checkedOut: false});

// Prepare
var adminDb1 = session1.getDatabase("admin");
var prepRes = adminDb1.adminCommand({prepareTransaction: 1, writeConcern: {w: "majority"}});
if (!prepRes.ok) {
    throw new Error("prepareTransaction failed: " + JSON.stringify(prepRes));
}
var prepareTs = prepRes.prepareTimestamp;

emitEvent("CheckOutSession", {session: "s1", thread: "t1", checkedOut: true});
emitEvent("PrepareTransaction", {session: "s1", thread: "t1", txnState: "prepared"});
emitEvent("CheckInSession", {session: "s1", thread: "t1", checkedOut: false});

// --- Session s2: create and use, then end ---
var session2 = conn.startSession();
var s2db = session2.getDatabase("testdb_reaper");
// Use the session so it gets registered server-side
s2db.testcoll.insertOne({x: 2, scenario: "reaper_s2"});
var lsid2 = session2.id;

// End session s2: removes from config.system.sessions
// This is the endSessions path (F5 / MC-3: doesn't check for prepared txns)
db.adminCommand({endSessions: [lsid2]});

emitEvent("EndSession", {session: "s2"});

// Trigger the reaper via refreshLogicalSessionCacheNow.
// This runs the full refresh+reap cycle. The reaper will:
//   1. Find s2 is not in config.system.sessions -> candidate for reap
//   2. Check canBeReaped(s2) -> true (no open txn)
//   3. Remove s2 from in-memory catalog
//   4. Delete s2's image and txn records from disk
// s1 survives because canBeReaped(s1) -> false (prepared txn)
db.adminCommand({refreshLogicalSessionCacheNow: 1});

// Emit reaper events (thread t3 = reaper thread in spec)
emitEvent("ReaperScanMemory", {thread: "t3"});
emitEvent("ReaperDeleteImages", {thread: "t3"});
emitEvent("ReaperDeleteTxnRecords", {thread: "t3"});

// Clean up: commit the prepared transaction on s1
var commitRes = adminDb1.adminCommand({
    commitTransaction: 1,
    commitTimestamp: prepareTs
});
// Commit may fail if session was unexpectedly reaped (that would be a bug!)
if (commitRes.ok) {
    // Normal path: prepared txn survived reaper
} else {
    // Bug path: reaper destroyed the prepared txn (SERVER-105751 pattern)
    emitEvent("ERROR_PreparedTxnDestroyed", {
        session: "s1",
        error: commitRes.errmsg || "unknown"
    });
}

session1.endSession();
session2.endSession();
