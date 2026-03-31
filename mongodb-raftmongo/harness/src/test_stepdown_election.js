// test_stepdown_election.js — Stepdown and re-election scenario
// Exercises: stepdown, term update, election, commit point with new leader
//
// Run via: mongosh --host mongo1:27017 --file test_stepdown_election.js

print("=== Test: Stepdown + Re-election ===");

// Get current primary and term
let status = rs.status();
let primaryHost = null;
let currentTerm = status.term;
for (let m of status.members) {
    if (m.stateStr === "PRIMARY") {
        primaryHost = m.name;
        break;
    }
}
print("Initial primary: " + primaryHost + " (term " + currentTerm + ")");

// Write some data first
print("--- Writing initial documents ---");
for (let i = 0; i < 3; i++) {
    db.getSiblingDB("testdb").stepcoll.insertOne(
        {seq: i, phase: "before_stepdown"},
        {writeConcern: {w: "majority", wtimeout: 30000}}
    );
}
print("  3 documents written with w:majority");

sleep(1000);

// Force stepdown
print("--- Forcing stepdown ---");
try {
    db.adminCommand({replSetStepDown: 10, force: true});
} catch(e) {
    // Expected: connection closes on stepdown
    print("  Stepdown triggered (connection reset expected): " + e.message);
}

// Wait for new election
print("--- Waiting for new election ---");
sleep(5000);

// Reconnect and check status
try {
    status = rs.status();
    let newPrimary = null;
    let newTerm = status.term;
    for (let m of status.members) {
        if (m.stateStr === "PRIMARY") {
            newPrimary = m.name;
            break;
        }
    }
    print("New primary: " + newPrimary + " (term " + newTerm + ")");

    // Write more data on new primary
    print("--- Writing documents after re-election ---");
    for (let i = 0; i < 3; i++) {
        try {
            db.getSiblingDB("testdb").stepcoll.insertOne(
                {seq: i + 10, phase: "after_election"},
                {writeConcern: {w: "majority", wtimeout: 30000}}
            );
        } catch(e2) {
            print("  Write " + i + " failed (may need to reconnect to new primary): " + e2.message);
        }
    }

    sleep(2000);

    // Final status
    status = rs.status();
    for (let m of status.members) {
        print("  " + m.name + ": state=" + m.stateStr +
              " optime=" + JSON.stringify(m.optime));
    }

    let replInfo = db.adminCommand({replSetGetStatus: 1});
    print("Commit point: " + JSON.stringify(replInfo.optimes.lastCommittedOpTime));

} catch(e) {
    print("  Post-stepdown status check failed: " + e.message);
}

print("=== Stepdown + Re-election Complete ===");
