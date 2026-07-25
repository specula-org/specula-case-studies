// test_basic_consensus.js — Basic consensus scenario
// Exercises: election, client writes, commit point propagation
//
// Run via: mongosh --host mongo1:27017 --file test_basic_consensus.js

print("=== Test: Basic Consensus ===");

// Connect to the primary
const primary = db.getMongo();

// Check replica set status
let status = rs.status();
let primaryHost = null;
for (let m of status.members) {
    if (m.stateStr === "PRIMARY") {
        primaryHost = m.name;
        break;
    }
}
print("Primary: " + primaryHost);
print("Term: " + status.term);

// Perform writes that exercise commit point propagation
print("--- Writing documents ---");
for (let i = 0; i < 5; i++) {
    let result = db.getSiblingDB("testdb").testcoll.insertOne(
        {seq: i, ts: new Date(), data: "basic_consensus_" + i},
        {writeConcern: {w: "majority", wtimeout: 30000}}
    );
    print("  Write " + i + ": " + JSON.stringify(result.insertedId));
}

// Wait for replication to propagate
sleep(2000);

// Check replication status
status = rs.status();
for (let m of status.members) {
    print("  " + m.name + ": state=" + m.stateStr +
          " optime=" + JSON.stringify(m.optime) +
          " optimeDate=" + m.optimeDate);
}

// Verify commit point
let replInfo = db.adminCommand({replSetGetStatus: 1});
print("Commit point: " + JSON.stringify(replInfo.optimes.lastCommittedOpTime));
print("Last applied: " + JSON.stringify(replInfo.optimes.appliedOpTime));
print("Last durable: " + JSON.stringify(replInfo.optimes.durableOpTime));
print("Last written: " + JSON.stringify(replInfo.optimes.writtenOpTime));

print("=== Basic Consensus Complete ===");
