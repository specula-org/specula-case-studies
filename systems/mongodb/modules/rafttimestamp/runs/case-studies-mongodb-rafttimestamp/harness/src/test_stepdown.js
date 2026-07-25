// test_stepdown.js — Stepdown and re-election scenario.
// Exercises: ClientWrite, Stepdown, BecomePrimary, UpdateTerm,
//            AppendOplog, LearnCommitPoint
//
// Run via: mongosh --host mongo1:27017 --file test_stepdown.js

print("=== Test: Stepdown + Re-election ===");

// Phase 1: Write some data on current primary
print("--- Phase 1: Writing on current primary ---");
let status = rs.status();
let originalPrimary = null;
for (let m of status.members) {
    if (m.stateStr === "PRIMARY") {
        originalPrimary = m.name;
        break;
    }
}
print("Original primary: " + originalPrimary);

for (let i = 0; i < 3; i++) {
    db.getSiblingDB("testdb").stepcoll.insertOne(
        {seq: i, phase: "before_stepdown", ts: new Date()},
        {writeConcern: {w: "majority", wtimeout: 30000}}
    );
    print("  Pre-stepdown write " + i);
}
sleep(2000);

// Phase 2: Force stepdown
print("--- Phase 2: Forcing stepdown ---");
try {
    db.adminCommand({replSetStepDown: 10, force: true});
} catch(e) {
    // Expected: connection drops during stepdown
    print("  Stepdown issued (connection may reset): " + e.message);
}
sleep(5000);

// Phase 3: Reconnect and find new primary
print("--- Phase 3: Finding new primary ---");
let retries = 0;
let newPrimary = null;
while (retries < 30) {
    try {
        status = rs.status();
        for (let m of status.members) {
            if (m.stateStr === "PRIMARY") {
                newPrimary = m.name;
                break;
            }
        }
        if (newPrimary) break;
    } catch(e) {
        // May fail while reconnecting
    }
    sleep(1000);
    retries++;
}
print("New primary: " + (newPrimary || "NONE (election in progress)"));
print("New term: " + (status ? status.term : "?"));

// Phase 4: Write on new primary (may need to connect to it)
print("--- Phase 4: Writing on new primary ---");
sleep(2000);
try {
    for (let i = 0; i < 3; i++) {
        db.getSiblingDB("testdb").stepcoll.insertOne(
            {seq: i, phase: "after_stepdown", ts: new Date()},
            {writeConcern: {w: "majority", wtimeout: 30000}}
        );
        print("  Post-stepdown write " + i);
    }
} catch(e) {
    print("  Post-stepdown writes may have gone to new primary: " + e.message);
}

sleep(3000);

// Final state
try {
    status = rs.status();
    for (let m of status.members) {
        print("  " + m.name + ": state=" + m.stateStr +
              " term=" + (m.electionTime ? "has_election" : "no_election"));
    }
    let replInfo = db.adminCommand({replSetGetStatus: 1});
    print("Commit point: " + JSON.stringify(replInfo.optimes.lastCommittedOpTime));
} catch(e) {
    print("  Could not read final state: " + e.message);
}

print("=== Stepdown + Re-election Complete ===");
