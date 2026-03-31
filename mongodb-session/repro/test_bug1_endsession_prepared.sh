#!/bin/bash
# Bug 1 Reproduction: endSessions() removes session from config.system.sessions
# while a prepared transaction is still active on that session.
#
# MC counterexample: 5 states (MC_hunt_endsession.cfg), EndSessionSafety violated.
# Affected code: logical_session_cache_impl.cpp:457-465
#
# The endSessions() function only checks isParentSessionId() — it does NOT check
# whether the session has an active or prepared transaction. During the next
# _refresh() cycle, removeRecords() unconditionally deletes the session from
# config.system.sessions.
#
# Requires: Docker
# Tested on: MongoDB 8.x (mongo:8 Docker image)

set -euo pipefail

CONTAINER_NAME="mongo-bug1-endsession"
MONGO_PORT=27217
IMAGE="mongo:8"

cleanup() {
    echo ""
    echo "=== Cleanup ==="
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

echo "============================================================"
echo "Bug 1: endSessions removes session with prepared transaction"
echo "============================================================"
echo ""

# Remove any leftover container
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

# Start MongoDB with replica set and test commands enabled
echo "[1/5] Starting MongoDB (single-node replica set)..."
docker run -d \
    --name "$CONTAINER_NAME" \
    -p "$MONGO_PORT:27017" \
    "$IMAGE" \
    mongod --replSet rs0 \
    --setParameter enableTestCommands=1 \
    --setParameter logicalSessionRefreshMillis=1000 \
    --quiet

# Wait for MongoDB to accept connections
echo "[2/5] Waiting for MongoDB to start..."
for i in $(seq 1 30); do
    if docker exec "$CONTAINER_NAME" mongosh --quiet --eval "db.runCommand({ping:1})" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

# Initialize replica set
echo "[3/5] Initializing replica set..."
docker exec "$CONTAINER_NAME" mongosh --quiet --eval '
rs.initiate({_id: "rs0", members: [{_id: 0, host: "localhost:27017"}]});
' >/dev/null 2>&1

# Wait for primary
echo "[4/5] Waiting for primary election..."
for i in $(seq 1 30); do
    IS_PRIMARY=$(docker exec "$CONTAINER_NAME" mongosh --quiet --eval 'rs.isMaster().ismaster' 2>/dev/null || echo "false")
    if [ "$IS_PRIMARY" = "true" ]; then
        break
    fi
    sleep 1
done
echo "     Primary ready."
echo ""

# Run the reproduction test
echo "[5/5] Running reproduction test..."
echo ""

docker exec "$CONTAINER_NAME" mongosh --quiet --eval '
// ====================================================================
// Bug 1 Reproduction Test
// endSessions() removes session from config.system.sessions while a
// prepared transaction is still active on that session.
//
// Sequence:
// 1. Create session, vivify with a non-transactional op
// 2. Force refresh -> session written to config.system.sessions
// 3. Start transaction, insert, prepare
// 4. Call endSessions (bug: no txn state check)
// 5. Force refresh -> session removed from config.system.sessions
// 6. Verify: session gone, but prepared txn still active
// ====================================================================

print("--- Step 1: Create session, vivify with non-transactional op ---");

// Pre-create collection (transactions cannot create collections)
db.getSiblingDB("test").getCollection("bug_repro").drop();
db.getSiblingDB("test").createCollection("bug_repro");

const session = db.getMongo().startSession();
const testDB = session.getDatabase("test");
const adminDB = session.getDatabase("admin");
const sidId = session.id.id;  // Binary UUID for querying config.system.sessions

// Vivify session in the logical session cache
testDB.getCollection("bug_repro").insertOne({_id: "vivify"});
print("Non-transactional insert done (session vivified in cache)");

print("");
print("--- Step 2: Ensure session tracked in config.system.sessions ---");

// Force refresh to write session to config.system.sessions
db.adminCommand({refreshLogicalSessionCacheNow: 1});
sleep(2000);

let beforeCount = db.getSiblingDB("config").system.sessions.countDocuments({"_id.id": sidId});
if (beforeCount === 0) {
    // Retry with another refresh
    db.adminCommand({refreshLogicalSessionCacheNow: 1});
    sleep(2000);
    beforeCount = db.getSiblingDB("config").system.sessions.countDocuments({"_id.id": sidId});
}
print("Sessions in config.system.sessions BEFORE: " + beforeCount);
assert(beforeCount > 0, "Session must be tracked before proceeding");

print("");
print("--- Step 3: Start and prepare transaction ---");

session.startTransaction();
testDB.getCollection("bug_repro").insertOne({_id: "txn_data", data: "prepared_txn_test"});
print("Transaction started, insert done");

const prepRes = adminDB.runCommand({prepareTransaction: 1});
if (prepRes.ok !== 1) {
    print("ERROR: prepareTransaction failed: " + JSON.stringify(prepRes));
    quit(1);
}
print("Transaction PREPARED at: " + JSON.stringify(prepRes.prepareTimestamp));

print("");
print("--- Step 4: Call endSessions (THE BUG) ---");
print("   logical_session_cache_impl.cpp:457-465 has no txn state check");

const endRes = db.adminCommand({endSessions: [session.id]});
assert(endRes.ok === 1, "endSessions failed");
print("endSessions accepted session with prepared txn (ok=1)");

print("");
print("--- Step 5: Force refresh to process _endingSessions ---");

db.adminCommand({refreshLogicalSessionCacheNow: 1});
sleep(2000);
db.adminCommand({refreshLogicalSessionCacheNow: 1});
sleep(1000);

print("");
print("--- Step 6: Verify result ---");

const afterCount = db.getSiblingDB("config").system.sessions.countDocuments({"_id.id": sidId});
print("Sessions in config.system.sessions BEFORE: " + beforeCount);
print("Sessions in config.system.sessions AFTER:  " + afterCount);

// Check config.transactions still has the prepared txn
const txnCount = db.getSiblingDB("config").transactions.countDocuments({"_id.id": sidId});
print("Prepared txn record in config.transactions:  " + txnCount);

print("");
print("============================================================");
if (afterCount === 0 && beforeCount > 0) {
    print("RESULT: *** BUG REPRODUCED ***");
    print("");
    print("  endSessions() removed the session from config.system.sessions");
    print("  while a prepared transaction is still active on that session.");
    print("");
    print("  Root cause: logical_session_cache_impl.cpp:457-465");
    print("  endSessions() only checks isParentSessionId() -- no txn state check.");
    print("  _refresh() line 406: removeRecords() unconditionally deletes session.");
    print("  _refresh() line 360-362: skips running ops in explicitlyEndingSessions.");
    print("");
    print("  Contrast: killOldestTransaction (kill_sessions_local.cpp:248)");
    print("  explicitly filters out prepared transactions.");
    print("");
    print("  Impact:");
    print("  - Session no longer tracked in config.system.sessions");
    print("  - Defense in depth violation (canBeReaped is the only remaining guard)");
    print("  - If canBeReaped is bypassed (cf. SERVER-105751), data loss results");
    if (txnCount > 0) {
        print("");
        print("  Inconsistency: config.transactions still has the txn record");
        print("  but config.system.sessions no longer tracks the session.");
    }
} else {
    print("RESULT: Bug NOT reproduced");
    print("  afterCount=" + afterCount + ", beforeCount=" + beforeCount);
}
print("============================================================");

// Cleanup
print("");
print("--- Cleanup ---");
try {
    adminDB.runCommand({abortTransaction: 1, writeConcern: {w: "majority"}});
    print("Prepared transaction aborted OK");
} catch(e) {
    print("Abort: " + e);
}
session.endSession();
print("Done.");
' 2>&1

EXIT_CODE=$?
echo ""
echo "Test exit code: $EXIT_CODE"
