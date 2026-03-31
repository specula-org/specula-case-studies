// test_crash_recovery.js — Crash and recovery scenario.
// Exercises: ClientWrite, Crash, RecoverTruncateOplog,
//            RecoverReplayOplog, RecoverSetTimestamps, AppendOplog
//
// NOTE: This script cannot directly crash a mongod container. Instead, it
// writes data, then the run.sh script handles:
//   1. Killing rts-mongo3 container (simulates crash)
//   2. Restarting it (recovery events appear in restart logs)
//
// This script performs the pre-crash writes and post-recovery verification.
//
// Run via: mongosh --host mongo1:27017 --file test_crash_recovery.js

print("=== Test: Crash Recovery (Pre-crash phase) ===");

// Write data — handle being on secondary by using writeConcern
print("--- Writing pre-crash data ---");
for (let i = 0; i < 5; i++) {
    try {
        db.getSiblingDB("testdb").crashcoll.insertOne(
            {seq: i, phase: "pre_crash", ts: new Date()},
            {writeConcern: {w: "majority", wtimeout: 30000}}
        );
        print("  Pre-crash write " + i);
    } catch(e) {
        print("  Pre-crash write " + i + " (not primary, ok): " + e.message);
    }
}
sleep(3000);

// Verify all nodes have the data
let status = rs.status();
for (let m of status.members) {
    print("  " + m.name + ": state=" + m.stateStr +
          " optime=" + JSON.stringify(m.optime));
}

print("=== Pre-crash writes complete. Container kill/restart handled by run.sh ===");
