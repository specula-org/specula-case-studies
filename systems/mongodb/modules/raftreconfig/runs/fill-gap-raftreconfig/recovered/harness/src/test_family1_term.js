// test_family1_term.js — election / term change via network partition (Family 1).
//
// This script does only the pre-partition write; run.sh then PARTITIONS the genesis
// primary off the network (host-level `docker network disconnect`), which drives the
// faithful Family-1 sequence:
//   - majority side elects a NEW primary in term 2:
//        BecomeLeader (t2) -> CompletePrimaryDrain -> StepUpReconfig (configTerm 1->2)
//   - the new primary's (v,t2) config propagates by heartbeat
//        => ConfigInstallHB with state.term=1 but cfg.term=2  (the decoupling)
//   - the old primary, on RECONNECT, learns t2 via heartbeat while it still believes
//     it is primary => StepDown (LOGV2 21475 -> CompleteStepDown) -> UpdateTerm.
//
// Run via the rs URI.

load("/scripts/lib.js");

print("[family1] waiting for primary ...");
waitPrimary(30000);
var coll = db.getSiblingDB("testdb").c;
coll.insertOne({_id: "f1-pre", phase: 0}, {writeConcern: {w: "majority", wtimeout: 15000}});
print("[family1] pre-partition primary=" + primaryName() + " (run.sh now partitions it)");
