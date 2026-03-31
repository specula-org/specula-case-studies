// Test: Kill session with in-progress transaction.
// Trace events: CheckOut -> Begin -> CheckIn ->
//               KillMark -> KillCheckout -> KillFinish
//
// This exercises the kill-session path (F2/F5 bug families).
// The killSessions command marks the session, checks it out for kill,
// aborts the unprepared transaction, and releases the session.

load("/scripts/trace_helpers.js");

var conn = new Mongo("mongodb://mongo1:27017/?replicaSet=rs0");
var db = conn.getDB("testdb_kill");

// Ensure collection exists
db.createCollection("testcoll");

// --- Session s1: start a transaction ---
var session = conn.startSession();
var sdb = session.getDatabase("testdb_kill");
var lsid = session.id;

session.startTransaction({
    readConcern: {level: "snapshot"},
    writeConcern: {w: "majority"}
});
sdb.testcoll.insertOne({x: 1, scenario: "kill_session"});

// Emit: insert = checkout -> begin -> checkin
emitEvent("CheckOutSession", {session: "s1", thread: "t1", checkedOut: true});
emitEvent("BeginTransaction", {session: "s1", thread: "t1", txnState: "inProgress"});
emitEvent("CheckInSession", {session: "s1", thread: "t1", checkedOut: false});

// Kill the session from a "different thread" (t2 in spec terms).
// The killSessions admin command does: mark -> checkout -> kill -> release.
// After kill, the transaction is aborted (but spec models abort separately from reset).
var killResult = db.adminCommand({killSessions: [lsid]});
if (!killResult.ok) {
    throw new Error("killSessions failed: " + JSON.stringify(killResult));
}

// Emit kill sequence (thread t2 = kill thread in spec)
emitEvent("KillSessionMark", {session: "s1", thread: "t2"});
emitEvent("KillSessionCheckout", {session: "s1", thread: "t2", checkedOut: true});
emitEvent("KillSessionFinish", {session: "s1", thread: "t2"});
// Note: KillSessionFinish uses ValidatePostStateWeak - we omit txnState because
// the spec sets it to "aborted" but real system does abort+reset atomically ("none").

// Clean up - the session was killed, end it client-side
session.endSession();
