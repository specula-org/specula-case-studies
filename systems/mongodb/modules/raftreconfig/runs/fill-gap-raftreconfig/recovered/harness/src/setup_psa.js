// setup_psa.js — initiate a 5-node set with ONE arbiter (Family 3 / dual-quorum).
//
// rcfg5 (n5) is an arbiter (arbiterOnly:true, votes:1, priority:0); rcfg1..rcfg4 are
// voting data-bearing members. This exercises the config-majority (incl. arbiter)
// vs write-majority (excl. arbiter) dual quorum that base.tla's IsConfigQuorum /
// IsDataQuorum model.
//
// NOTE: this initial config has an arbiter, so it does NOT match Trace.tla's current
// GenesisCfg (no arbiters). The arbiter trace therefore needs a TraceInit_PSA variant
// — see INSTRUMENTATION.md. Run via:
//   docker exec rcfg1 mongosh --quiet --file /scripts/setup_psa.js

var cfg = {
    _id: "rs0",
    version: 1,
    members: [
        {_id: 0, host: "rcfg1:27017", priority: 1, votes: 1},
        {_id: 1, host: "rcfg2:27017", priority: 1, votes: 1},
        {_id: 2, host: "rcfg3:27017", priority: 1, votes: 1},
        {_id: 3, host: "rcfg4:27017", priority: 1, votes: 1},
        {_id: 4, host: "rcfg5:27017", priority: 0, votes: 1, arbiterOnly: true}
    ]
};

try {
    rs.initiate(cfg);
    print("rs.initiate(P-S-A, n5=arbiter) issued");
} catch (e) {
    if (("" + e).indexOf("AlreadyInitialized") >= 0) print("already initialized");
    else { print("initiate error: " + e); }
}
