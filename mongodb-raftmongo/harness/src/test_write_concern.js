// test_write_concern.js — Write concern and commit point propagation scenario
// Exercises: different write concern levels, commit point advancement,
// journal-based vs written-based agreement
//
// Run via: mongosh --host mongo1:27017 --file test_write_concern.js

print("=== Test: Write Concern + Commit Point ===");

let status = rs.status();
print("Term: " + status.term);
for (let m of status.members) {
    if (m.stateStr === "PRIMARY") {
        print("Primary: " + m.name);
    }
}

const testdb = db.getSiblingDB("testdb");

// Phase 1: w:1 writes (fast, no majority wait)
print("--- Phase 1: w:1 writes ---");
for (let i = 0; i < 3; i++) {
    testdb.wccoll.insertOne(
        {seq: i, phase: "w1", ts: new Date()},
        {writeConcern: {w: 1}}
    );
}
print("  3 w:1 writes complete");

// Check commit point — should NOT have advanced for these yet
sleep(500);
let replInfo = db.adminCommand({replSetGetStatus: 1});
print("  Commit point after w:1: " + JSON.stringify(replInfo.optimes.lastCommittedOpTime));
print("  Last written: " + JSON.stringify(replInfo.optimes.writtenOpTime));

// Phase 2: w:majority writes (triggers commit point advancement)
print("--- Phase 2: w:majority writes ---");
for (let i = 0; i < 3; i++) {
    testdb.wccoll.insertOne(
        {seq: i + 10, phase: "majority", ts: new Date()},
        {writeConcern: {w: "majority", wtimeout: 30000}}
    );
}
print("  3 w:majority writes complete");

sleep(1000);
replInfo = db.adminCommand({replSetGetStatus: 1});
print("  Commit point after majority: " + JSON.stringify(replInfo.optimes.lastCommittedOpTime));
print("  Last written: " + JSON.stringify(replInfo.optimes.writtenOpTime));
print("  Last applied: " + JSON.stringify(replInfo.optimes.appliedOpTime));
print("  Last durable: " + JSON.stringify(replInfo.optimes.durableOpTime));

// Phase 3: w:majority + j:true (ensures journal persistence)
print("--- Phase 3: w:majority j:true writes ---");
for (let i = 0; i < 2; i++) {
    testdb.wccoll.insertOne(
        {seq: i + 20, phase: "journaled", ts: new Date()},
        {writeConcern: {w: "majority", j: true, wtimeout: 30000}}
    );
}
print("  2 w:majority+j:true writes complete");

sleep(1000);
replInfo = db.adminCommand({replSetGetStatus: 1});
print("  Commit point final: " + JSON.stringify(replInfo.optimes.lastCommittedOpTime));

// Final: check all members' optimes
status = rs.status();
for (let m of status.members) {
    print("  " + m.name + ": " + m.stateStr +
          " written=" + JSON.stringify(m.optime) +
          " optimeDurable=" + JSON.stringify(m.optimeDurable));
}

print("=== Write Concern + Commit Point Complete ===");
