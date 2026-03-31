#!/bin/bash
# SERVER-38918 Reproduction Attempt
# Tries to trigger fassert(51068) by removing a shard during 2PC commit phase
set -e

MONGOS="docker exec repro-mongos-1 mongosh --quiet --eval"
SHARD1="docker exec repro-shard1-1 mongosh --quiet --eval"
SHARD2="docker exec repro-shard2-1 mongosh --quiet --eval"

echo "=== SERVER-38918 Reproduction Attempt ==="
echo ""

# Step 1: Set failpoint on shard1 to pause coordinator before sending commit
echo "Step 1: Setting hangBeforeSendingCommit failpoint on shard1..."
$SHARD1 '
db.adminCommand({
    configureFailPoint: "hangBeforeSendingCommit",
    mode: "alwaysOn"
})
'

# Step 2: Start cross-shard transaction and commit (in background — will block)
echo "Step 2: Starting cross-shard transaction and committing (will block at failpoint)..."
docker exec repro-mongos-1 mongosh --quiet --eval '
var session = db.getMongo().startSession();
var sdb = session.getDatabase("testdb");
session.startTransaction();
sdb.testcol.updateOne({x: -1}, {$set: {val: "txn_shard1_v2"}});
sdb.testcol.updateOne({x: 1}, {$set: {val: "txn_shard2_v2"}});
print("Committing cross-shard transaction...");
try {
    session.commitTransaction();
    print("COMMIT SUCCEEDED");
} catch(e) {
    print("COMMIT ERROR (may be expected): " + e.message);
}
session.endSession();
' &
COMMIT_PID=$!
echo "Commit running in background (PID: $COMMIT_PID)"

# Wait for the failpoint to be hit
echo "Step 3: Waiting for coordinator to hit failpoint..."
sleep 5

# Check if failpoint was hit by looking at shard1 logs
echo "Checking shard1 logs for failpoint hit..."
docker exec repro-shard1-1 mongosh --quiet --eval '
var log = db.adminCommand({getLog: "global"});
var hits = log.log.filter(function(l) { return l.indexOf("hangBeforeSendingCommit") >= 0; });
print("Failpoint hits in log: " + hits.length);
if (hits.length > 0) print(hits[hits.length-1]);
'

# Step 4: Move data off shard2 and remove it
echo ""
echo "Step 4: Moving chunk from shard2 to shard1..."
docker exec repro-mongos-1 mongosh --quiet --eval '
var admin = db.getSiblingDB("admin");
// Move the chunk containing x>=0 back to shard1
var r = admin.runCommand({moveChunk: "testdb.testcol", find: {x: 1}, to: "shard1RS"});
printjson(r);
'
sleep 2

echo "Step 5: Removing shard2..."
for i in $(seq 1 30); do
    RESULT=$(docker exec repro-mongos-1 mongosh --quiet --eval '
        var r = db.adminCommand({removeShard: "shard2RS"});
        print(r.state || "unknown");
    ' 2>&1)
    echo "  removeShard attempt $i: state=$RESULT"
    if [[ "$RESULT" == *"completed"* ]]; then
        echo "  Shard2 removed successfully!"
        break
    fi
    sleep 2
done

# Step 6: Disable failpoint — coordinator should now try to reach removed shard2
echo ""
echo "Step 6: Disabling failpoint — coordinator will try to reach removed shard2..."
$SHARD1 '
db.adminCommand({configureFailPoint: "hangBeforeSendingCommit", mode: "off"})
' 2>/dev/null || echo "  (shard1 may already be down from fassert)"

sleep 5

# Step 7: Check if shard1 is still alive
echo ""
echo "Step 7: Checking shard1 health..."
$SHARD1 'db.adminCommand({ping: 1})' 2>/dev/null
PING_STATUS=$?
if [ $PING_STATUS -ne 0 ]; then
    echo "*** SHARD1 IS DOWN — possible fassert(51068)! ***"
    echo "Checking container status..."
    docker inspect repro-shard1-1 --format '{{.State.Status}} exit={{.State.ExitCode}}'
else
    echo "Shard1 is still alive. fassert was NOT triggered."
fi

# Check shard1 logs for fassert
echo ""
echo "Step 8: Checking shard1 logs for fassert(51068)..."
docker logs repro-shard1-1 2>&1 | grep -i "fassert\|51068\|ShardNotFound\|fatal" | tail -20

# Wait for commit to finish
echo ""
echo "Waiting for commit background process..."
wait $COMMIT_PID 2>/dev/null || true

echo ""
echo "=== Reproduction attempt complete ==="
