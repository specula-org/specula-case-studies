// test_basic_consensus.js — Basic replication consensus scenario.
// Exercises: ClientWrite, AppendOplog, PersistOplog, ApplyOplog,
//            AdvanceCommitPoint, LearnCommitPoint
//
// Run via: mongosh --host mongo1:27017 --file test_basic_consensus.js

print("=== Test: Basic Consensus ===");

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

// Write documents with w:majority to exercise full replication pipeline
print("--- Writing documents with w:majority ---");
for (let i = 0; i < 5; i++) {
    let result = db.getSiblingDB("testdb").testcoll.insertOne(
        {seq: i, ts: new Date(), data: "basic_consensus_" + i},
        {writeConcern: {w: "majority", wtimeout: 30000}}
    );
    print("  Write " + i + ": " + JSON.stringify(result.insertedId));
}

// Wait for replication and durability propagation
sleep(3000);

// Capture final state from all members
status = rs.status();
for (let m of status.members) {
    print("  " + m.name + ": state=" + m.stateStr +
          " optime=" + JSON.stringify(m.optime) +
          " optimeDate=" + m.optimeDate);
}

let replInfo = db.adminCommand({replSetGetStatus: 1});
print("Commit point: " + JSON.stringify(replInfo.optimes.lastCommittedOpTime));
print("Last applied: " + JSON.stringify(replInfo.optimes.appliedOpTime));
print("Last durable: " + JSON.stringify(replInfo.optimes.durableOpTime));
print("Last written: " + JSON.stringify(replInfo.optimes.writtenOpTime));

print("=== Basic Consensus Complete ===");
