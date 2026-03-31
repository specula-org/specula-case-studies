// Test: Prepared transaction lifecycle (prepare + commit).
// Trace events: CheckOut -> Begin -> CheckIn ->
//               CheckOut -> Prepare -> CheckIn ->
//               CheckOut -> CommitPrepared -> Reset -> CheckIn
//
// This exercises the 2PC prepare path which is central to F1/F3 bug families.
// Requires enableTestCommands=1 for prepareTransaction command.

load("/scripts/trace_helpers.js");

var conn = new Mongo("mongodb://mongo1:27017/?replicaSet=rs0");
var db = conn.getDB("testdb_prepare");

// Ensure collection exists
db.createCollection("testcoll");

// --- Session s1: begin -> prepare -> commit ---
var session = conn.startSession();
var sdb = session.getDatabase("testdb_prepare");

// Start transaction and insert
session.startTransaction({
    readConcern: {level: "snapshot"},
    writeConcern: {w: "majority"}
});
sdb.testcoll.insertOne({x: 1, scenario: "prepare_commit"});

// Emit: insert command = checkout -> begin -> checkin
emitEvent("CheckOutSession", {session: "s1", thread: "t1", checkedOut: true});
emitEvent("BeginTransaction", {session: "s1", thread: "t1", txnState: "inProgress"});
emitEvent("CheckInSession", {session: "s1", thread: "t1", checkedOut: false});

// Prepare the transaction (internal command, requires enableTestCommands=1)
var adminDb = session.getDatabase("admin");
var prepareResult = adminDb.adminCommand({
    prepareTransaction: 1,
    writeConcern: {w: "majority"}
});
if (!prepareResult.ok) {
    throw new Error("prepareTransaction failed: " + JSON.stringify(prepareResult));
}
var prepareTimestamp = prepareResult.prepareTimestamp;

// Emit: prepare command = checkout -> prepare -> checkin
emitEvent("CheckOutSession", {session: "s1", thread: "t1", checkedOut: true});
emitEvent("PrepareTransaction", {session: "s1", thread: "t1", txnState: "prepared"});
emitEvent("CheckInSession", {session: "s1", thread: "t1", checkedOut: false});

// Commit the prepared transaction (must pass commitTimestamp)
var commitResult = adminDb.adminCommand({
    commitTransaction: 1,
    commitTimestamp: prepareTimestamp
});
if (!commitResult.ok) {
    throw new Error("commitTransaction failed: " + JSON.stringify(commitResult));
}

// Emit: commit command = checkout -> commitPrepared -> reset -> checkin
emitEvent("CheckOutSession", {session: "s1", thread: "t1", checkedOut: true});
emitEvent("CommitPreparedTransaction", {session: "s1", thread: "t1", txnState: "committed"});
emitEvent("ResetTransactionState", {session: "s1", thread: "t1", txnState: "none"});
emitEvent("CheckInSession", {session: "s1", thread: "t1", checkedOut: false});

session.endSession();
