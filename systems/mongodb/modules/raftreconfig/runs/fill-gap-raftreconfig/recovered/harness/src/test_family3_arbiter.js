// test_family3_arbiter.js — arbiter / PSA dual-quorum reconfig (Family 3).
//
// Cluster initiated by setup_psa.js (rcfg5 = arbiter). Sequence:
//   1. set a cluster-wide default write concern (a voter-set reconfig on a PSA set is
//      otherwise blocked by the implicit-default-write-concern protection)
//   2. committed write (needs a DATA quorum that EXCLUDES the arbiter)
//   3. single voting-member change among the DATA members: a data SECONDARY -> votes:0
//      => ConfigInstallCmd / ConfigInstallHB whose cfg.arbiters = [<arbiter nid>]
//
// The installed configs carry arbiters, exercising ValidateConfig's arbiter check and
// the dual quorum ($configMajority incl. arbiter vs $majority excl. arbiter).
// NOTE: the PSA initial config has an arbiter, so it needs a TraceInit_PSA variant
// (GenesisCfg with arbiters = {<arbiter nid>}) — see INSTRUMENTATION.md. Run via rs URI.

load("/scripts/lib.js");

print("[family3] waiting for primary ...");
waitPrimary(30000);
setDefaultWMajority();
var coll = db.getSiblingDB("testdb").c;

coll.insertOne({_id: "psa-pre"}, {writeConcern: {w: "majority", wtimeout: 15000}});
print("[family3] wrote psa-pre (w:majority over data quorum, arbiter excluded)");

var c = rs.conf();
print("[family3] config has arbiter? " + c.members.some(function (m) { return m.arbiterOnly; }));

var sec = findSecondaryHost();   // a DATA secondary (excludes the arbiter)
print("[family3] de-voting data secondary " + sec);
var v = devoteMember(sec);
print("[family3] reconfig issued -> version " + v);
sleep(4000);

coll.insertOne({_id: "psa-post"}, {writeConcern: {w: "majority", wtimeout: 15000}});
print("[family3] wrote psa-post (w:majority)");
sleep(2000);
print("[family3] done; config version=" + rs.conf().version);
