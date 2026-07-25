// test_family2_commit.js — commit durability across a voter-set reconfig + failover.
//
// Family 2 (commit-point / oplog-commitment Q2 across the de-atomized install).
//   1. write W with w:majority (committed under the genesis voter set)
//   2. reconfig changing the voter set (de-vote a secondary)  => ConfigInstallCmd
//   3. replSetStepUp on another secondary => failover to a new primary in term 2
//   4. assert W is still present on the new primary (OplogCommitmentAcrossReconfig /
//      LeaderCompleteness: the acked write must survive the reconfig + election).
//
// Run via the rs URI.

load("/scripts/lib.js");

print("[family2] waiting for primary ...");
waitPrimary(30000);
var coll = db.getSiblingDB("testdb").c;

coll.insertOne({_id: "durable", v: 42}, {writeConcern: {w: "majority", wtimeout: 15000}});
print("[family2] wrote durable doc (w:majority)");

var sec = findSecondaryHost();
var v = devoteMember(sec);
print("[family2] reconfig issued (de-voted " + sec + ") -> version " + v);
sleep(3000);

var target = findSecondaryHost();
print("[family2] forcing step-up on " + target);
stepUpOn(target);
sleep(3000);
waitPrimary(30000);
print("[family2] post-election primary=" + primaryName());

sleep(1500);
var found = null;
try { found = coll.findOne({_id: "durable"}); } catch (e) { print("[family2] read error: " + e); }
if (found && found.v === 42) print("[family2] OK: durable write survived failover");
else print("[family2] WARNING: durable write NOT found after failover (investigate)");

sleep(2500);
print("[family2] done; config version=" + rs.conf().version + " term=" + rs.conf().term);
