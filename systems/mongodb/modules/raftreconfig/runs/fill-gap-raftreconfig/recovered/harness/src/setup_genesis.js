// setup_genesis.js — initiate the GENESIS 5-node replica set.
//
// All five members are voting (votes:1), data-bearing (no arbiterOnly), priority:1.
// This is exactly Trace.tla's GenesisCfg: version 1, all of Server voting, no
// arbiters. Run via:  docker exec rcfg1 mongosh --quiet --file /scripts/setup_genesis.js
//
// After the first election + automatic optimized step-up reconfig, the steady state
// is (config version 1, configTerm 1, election term 1, one primary) — the state
// TraceInit assumes. The trace window begins AFTER this bootstrap settles.

// All five members are EQUAL (votes:1, priority:1) so the bootstrap is a single
// clean term-1 election with NO priority takeover. Whichever node wins is mapped to
// n1 by the parser (genesis primary -> n1), so the trace is deterministic in TLA+
// node space regardless of which physical container won. Genesis voters = all of
// Server, arbiters = {} == base.tla's GenesisCfg.
var cfg = {
    _id: "rs0",
    version: 1,
    members: [
        {_id: 0, host: "rcfg1:27017", priority: 1, votes: 1},
        {_id: 1, host: "rcfg2:27017", priority: 1, votes: 1},
        {_id: 2, host: "rcfg3:27017", priority: 1, votes: 1},
        {_id: 3, host: "rcfg4:27017", priority: 1, votes: 1},
        {_id: 4, host: "rcfg5:27017", priority: 1, votes: 1}
    ]
};

try {
    rs.initiate(cfg);
    print("rs.initiate(genesis 5-node) issued");
} catch (e) {
    if (("" + e).indexOf("AlreadyInitialized") >= 0) print("already initialized");
    else { print("initiate error: " + e); }
}
