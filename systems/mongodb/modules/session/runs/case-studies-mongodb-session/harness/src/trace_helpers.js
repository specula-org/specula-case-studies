// Trace emission helper for TLA+ trace validation.
// Loaded by each test script via: load("/scripts/trace_helpers.js")
//
// Emits NDJSON lines to stdout. Each line has:
//   event: action name (matches Trace.tla IsEvent checks)
//   session: TLA+ Session constant name (s1, s2, ...)
//   thread: TLA+ Thread constant name (t1, t2, ...)
//   ts: real ISO 8601 timestamp
//   txnState, checkedOut, sessionExists: optional post-state fields

function emitEvent(name, fields) {
    var event = {event: name, ts: new Date().toISOString()};
    if (fields) {
        var keys = Object.keys(fields);
        for (var i = 0; i < keys.length; i++) {
            event[keys[i]] = fields[keys[i]];
        }
    }
    print(JSON.stringify(event));
}

// Emit a checkout+action+checkin block for a single MongoDB command.
// In MongoDB, each command on a session does: checkout -> action -> checkin.
function emitCheckoutBlock(thread, session, actionName, actionFields) {
    emitEvent("CheckOutSession", {session: session, thread: thread, checkedOut: true});
    var fields = {session: session, thread: thread};
    if (actionFields) {
        var keys = Object.keys(actionFields);
        for (var i = 0; i < keys.length; i++) {
            fields[keys[i]] = actionFields[keys[i]];
        }
    }
    emitEvent(actionName, fields);
    emitEvent("CheckInSession", {session: session, thread: thread, checkedOut: false});
}

// Wait until a condition is true, with timeout.
function waitUntil(fn, desc, maxWaitMs) {
    maxWaitMs = maxWaitMs || 30000;
    var start = Date.now();
    while (!fn()) {
        if (Date.now() - start > maxWaitMs) {
            throw new Error("Timeout waiting for: " + desc);
        }
        sleep(500);
    }
}
