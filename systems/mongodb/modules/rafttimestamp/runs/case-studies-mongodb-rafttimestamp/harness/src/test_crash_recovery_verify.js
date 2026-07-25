// test_crash_recovery_verify.js — Post-recovery verification.
// Run after rts-mongo3 has been killed and restarted.

print("=== Test: Crash Recovery (Post-recovery verification) ===");

// Wait for the recovered node to rejoin
sleep(5000);

let status = rs.status();
for (let m of status.members) {
    print("  " + m.name + ": state=" + m.stateStr +
          " optime=" + JSON.stringify(m.optime));
}

// Write more data to verify cluster is healthy post-recovery
print("--- Writing post-recovery data ---");
for (let i = 0; i < 3; i++) {
    try {
        db.getSiblingDB("testdb").crashcoll.insertOne(
            {seq: i, phase: "post_recovery", ts: new Date()},
            {writeConcern: {w: "majority", wtimeout: 30000}}
        );
        print("  Post-recovery write " + i);
    } catch(e) {
        print("  Post-recovery write " + i + " failed: " + e.message);
    }
}

sleep(2000);

// Verify all 3 nodes are healthy
status = rs.status();
let healthy = 0;
for (let m of status.members) {
    if (m.stateStr === "PRIMARY" || m.stateStr === "SECONDARY") {
        healthy++;
    }
    print("  " + m.name + ": " + m.stateStr);
}
print("Healthy members: " + healthy + "/3");

let replInfo = db.adminCommand({replSetGetStatus: 1});
print("Commit point: " + JSON.stringify(replInfo.optimes.lastCommittedOpTime));
print("Last applied: " + JSON.stringify(replInfo.optimes.appliedOpTime));
print("Last durable: " + JSON.stringify(replInfo.optimes.durableOpTime));

print("=== Crash Recovery Complete ===");
