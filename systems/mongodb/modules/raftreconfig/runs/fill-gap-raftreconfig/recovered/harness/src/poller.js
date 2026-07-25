// poller.js — per-node self-status poller for MongoRaftReconfig trace capture.
//
// Runs INSIDE a container via:  docker exec rcfgK mongosh --quiet --file /scripts/poller.js
// (the host redirects its stdout to status_nK.ndjson and backgrounds it).
//
// Each iteration prints one NDJSON line with this node's OWN authoritative view of
// the spec state variables. parse_logs.py joins the nearest poll to every LOGV2
// event to fill state fields the log line itself does not carry (role, commitIndex,
// and — for heartbeat installs — the node's election term, which is decoupled from
// the installed configTerm).
//
//   { "ts":"<ISO8601>", "host":"rcfgK:27017",
//     "term":<electionTerm>, "myState":<int>,        // 1=PRIMARY 2=SECONDARY
//     "commitTsSec":<int>, "commitTsInc":<int>,       // lastCommittedOpTime.ts
//     "configVersion":<int>, "configTerm":<int> }
//
// Polls every ~150 ms; self-terminates after a cap (safety: scenarios are short).

var INTERVAL_MS = 150;
var MAX_ITERS = 4000; // ~10 min hard cap

for (var k = 0; k < MAX_ITERS; k++) {
    var rec = {ts: new Date().toISOString()};
    try {
        var s = db.adminCommand({replSetGetStatus: 1});
        if (s && s.ok === 1) {
            rec.term = (typeof s.term === "number") ? s.term
                       : (s.term ? Number(s.term) : null);
            rec.myState = s.myState;
            var self = null;
            if (s.members) { for (var i = 0; i < s.members.length; i++) { if (s.members[i].self) { self = s.members[i]; break; } } }
            rec.host = self ? self.name : null;
            var lco = s.optimes ? s.optimes.lastCommittedOpTime : null;
            if (lco && lco.ts) {
                try { rec.commitTsSec = lco.ts.getTime(); rec.commitTsInc = lco.ts.getInc(); }
                catch (e1) { try { rec.commitTsSec = lco.ts.t; rec.commitTsInc = lco.ts.i; } catch (e2) {} }
                rec.commitTerm = (typeof lco.t === "number") ? lco.t : null;
            }
        }
    } catch (e) { rec.statusErr = ("" + e).slice(0, 120); }
    try {
        var cfg = db.adminCommand({replSetGetConfig: 1});
        if (cfg && cfg.ok === 1 && cfg.config) {
            rec.configVersion = cfg.config.version;
            rec.configTerm = cfg.config.term;
        }
    } catch (e) { rec.confErr = ("" + e).slice(0, 120); }
    print(JSON.stringify(rec));
    sleep(INTERVAL_MS);
}
