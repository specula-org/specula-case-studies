// lib.js — shared mongosh helpers for the reconfig scenarios. `load()`-ed at the top
// of each scenario (run via the replica-set URI, so db routes to the primary).

function waitPrimary(maxMs) {
    var t0 = Date.now();
    while (Date.now() - t0 < (maxMs || 30000)) {
        try { if (db.adminCommand({hello: 1}).isWritablePrimary) return true; } catch (e) {}
        sleep(300);
    }
    return false;
}

function primaryName() {
    try { return db.adminCommand({hello: 1}).primary; } catch (e) { return null; }
}

// A SECONDARY that is a non-arbiter voting member (safe to de-vote or to step up).
function findSecondaryHost() {
    var s = db.adminCommand({replSetGetStatus: 1});
    var c = db.adminCommand({replSetGetConfig: 1}).config;
    var ok = {};
    c.members.forEach(function (m) { ok[m.host] = (m.votes > 0 && !m.arbiterOnly); });
    for (var i = 0; i < s.members.length; i++) {
        var m = s.members[i];
        if (m.stateStr === "SECONDARY" && ok[m.name]) return m.name;
    }
    return null;
}

// Single voting-member change: drop `host` from the voter set (votes:0, priority:0).
function devoteMember(host) {
    var c = rs.conf();
    for (var i = 0; i < c.members.length; i++) {
        if (c.members[i].host === host) { c.members[i].votes = 0; c.members[i].priority = 0; }
    }
    c.version = c.version + 1;
    rs.reconfig(c);
    return c.version;
}

// Force an election won by `host` (term+1). The current primary learns the higher
// term via heartbeat and steps down (LOGV2 21475 -> CompleteStepDown).
function stepUpOn(host) {
    var conn = new Mongo(host);
    return conn.getDB("admin").runCommand({replSetStepUp: 1});
}

// Set a cluster-wide default write concern so a voter-set reconfig is not blocked by
// the implicit-default-write-concern protection (needed for PSA / arbiter configs).
function setDefaultWMajority() {
    try {
        db.adminCommand({setDefaultRWConcern: 1, defaultWriteConcern: {w: "majority"}});
        return true;
    } catch (e) { print("setDefaultRWConcern: " + ("" + e).slice(0, 80)); return false; }
}
