// Test: Basic session lifecycle with abort.
// Trace events: CheckOut -> Begin -> CheckIn -> CheckOut -> Abort -> Reset -> CheckIn
//
// This exercises the fundamental session checkout/checkin and transaction abort path.

load("/scripts/trace_helpers.js");

var conn = new Mongo("mongodb://mongo1:27017/?replicaSet=rs0");
var db = conn.getDB("testdb_basic");

// Ensure collection exists (required for replica set transactions)
db.createCollection("testcoll");

// --- Session s1: begin transaction then abort ---
var session = conn.startSession();
var sdb = session.getDatabase("testdb_basic");

// First command: insertOne triggers server-side checkout + beginTransaction
session.startTransaction({
    readConcern: {level: "snapshot"},
    writeConcern: {w: "majority"}
});
sdb.testcoll.insertOne({x: 1, scenario: "basic_lifecycle"});

// Emit: the insert command did checkout -> begin -> [insert] -> checkin
emitEvent("CheckOutSession", {session: "s1", thread: "t1", checkedOut: true});
emitEvent("BeginTransaction", {session: "s1", thread: "t1", txnState: "inProgress"});
emitEvent("CheckInSession", {session: "s1", thread: "t1", checkedOut: false});

// Abort: triggers checkout -> abort -> resetState -> checkin
session.abortTransaction();

emitEvent("CheckOutSession", {session: "s1", thread: "t1", checkedOut: true});
emitEvent("AbortTransaction", {session: "s1", thread: "t1", txnState: "aborted"});
emitEvent("ResetTransactionState", {session: "s1", thread: "t1", txnState: "none"});
emitEvent("CheckInSession", {session: "s1", thread: "t1", checkedOut: false});

session.endSession();
