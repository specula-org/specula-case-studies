// test_baseline_reconfig.js — committed (non-force) reconfig, no election.
//
// Exercises ConfigInstallCmd (primary command path, Q1/Q2 gate) + ConfigInstallHB
// (the other four nodes install via heartbeat). Single voting-member change: a
// SECONDARY (chosen dynamically, never the primary) goes votes:1 -> votes:0. It stays
// data-bearing (keeps replicating + logging). No force, no newlyAdded.
//
// Run via the rs URI:  docker exec rcfg1 mongosh "<rsuri>" --quiet --file /scripts/test_baseline_reconfig.js

load("/scripts/lib.js");

print("[baseline] waiting for primary ...");
waitPrimary(30000);
print("[baseline] primary=" + primaryName());

var coll = db.getSiblingDB("testdb").c;
coll.insertOne({_id: "pre-reconfig", phase: 0}, {writeConcern: {w: "majority", wtimeout: 15000}});
print("[baseline] wrote pre-reconfig doc (w:majority)");

var sec = findSecondaryHost();
print("[baseline] de-voting secondary " + sec);
var v = devoteMember(sec);
print("[baseline] reconfig issued -> version " + v);

sleep(4000);   // commit + heartbeat propagation to the secondaries

coll.insertOne({_id: "post-reconfig", phase: 1}, {writeConcern: {w: "majority", wtimeout: 15000}});
print("[baseline] wrote post-reconfig doc (w:majority)");

sleep(2000);
print("[baseline] done; final config version=" + rs.conf().version);
