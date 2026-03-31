#!/bin/bash
# SERVER-38918 Reproduction Attempt v2
# Strategy: pause coordinator BEFORE sending prepare via failpoint,
# remove shard2, then resume. Coordinator should get ShardNotFound
# during prepare (safely handled as abort), then fassert when
# trying to send abort to the removed shard.
set -e

MONGOS="docker exec repro-mongos-1 mongosh --quiet --eval"
SHARD1="docker exec repro-shard1-1 mongosh --quiet --eval"
SHARD2="docker exec repro-shard2-1 mongosh --quiet --eval"

echo "=== SERVER-38918 Reproduction v2 ==="
echo "Strategy: pause before prepare, remove shard, resume → ShardNotFound during prepare"
echo "Then coordinator gets abort decision, tries to send abort → fassert(51068)"
echo ""

# Step 1: Set failpoint on shard1 BEFORE sending prepare
echo "Step 1: Setting hangBeforeSendingPrepare on shard1 (coordinator)..."
$SHARD1 'printjson(db.adminCommand({configureFailPoint: "hangBeforeSendingPrepare", mode: "alwaysOn"}))'

# Also set hangBeforeSendingAbort on shard1 so we can verify the abort path is reached
echo "Step 1b: Also setting hangBeforeSendingAbort on shard1..."
$SHARD1 'printjson(db.adminCommand({configureFailPoint: "hangBeforeSendingAbort", mode: "alwaysOn"}))'

# Step 2: Start cross-shard transaction in background
echo ""
echo "Step 2: Starting cross-shard transaction (commit in background)..."
docker exec repro-mongos-1 mongosh --quiet --eval '
var session = db.getMongo().startSession();
var sdb = session.getDatabase("testdb");
session.startTransaction();
print("TXN: updating x=-1 (shard1)...");
sdb.testcol.updateOne({x: -1}, {$set: {val: "txn_v2_shard1"}});
print("TXN: updating x=1 (shard2)...");
sdb.testcol.updateOne({x: 1}, {$set: {val: "txn_v2_shard2"}});
print("TXN: committing (will block at hangBeforeSendingPrepare)...");
try {
    session.commitTransaction();
    print("TXN: COMMIT SUCCEEDED (unexpected if failpoint active!)");
} catch(e) {
    print("TXN: Commit result: " + e.message);
}
session.endSession();
' &
COMMIT_PID=$!
echo "Commit PID: $COMMIT_PID"

# Step 3: Wait for failpoint to be hit
echo ""
echo "Step 3: Waiting for coordinator to hit failpoint..."
for i in $(seq 1 20); do
    sleep 1
    HIT=$(docker logs repro-shard1-1 2>&1 | grep -c "Hit hangBeforeSendingPrepare" || true)
    if [ "$HIT" -gt 0 ]; then
        echo "  Failpoint hit after ${i}s!"
        break
    fi
    echo "  Waiting... (${i}s)"
done

# Verify failpoint was hit
echo ""
echo "Checking shard1 logs for hangBeforeSendingPrepare..."
docker logs repro-shard1-1 2>&1 | grep "hangBeforeSendingPrepare" | tail -3

# Step 4: Now remove shard2 while coordinator is paused before prepare
echo ""
echo "Step 4: Moving chunk from shard2 to shard1..."
docker exec repro-mongos-1 mongosh --quiet --eval '
var admin = db.getSiblingDB("admin");
var r = admin.runCommand({moveChunk: "testdb.testcol", find: {x: 1}, to: "shard1RS"});
printjson(r);
' 2>&1

echo "Step 4b: Removing shard2 from topology..."
REMOVED=false
for i in $(seq 1 60); do
    RESULT=$(docker exec repro-mongos-1 mongosh --quiet --eval '
        var r = db.adminCommand({removeShard: "shard2RS"});
        print(r.state || "error");
    ' 2>&1)
    echo "  removeShard #$i: $RESULT"
    if echo "$RESULT" | grep -q "completed"; then
        echo "  *** Shard2 removed! ***"
        REMOVED=true
        break
    fi
    sleep 2
done

if [ "$REMOVED" != "true" ]; then
    echo "  WARNING: shard2 removal did not complete. Continuing anyway..."
fi

# Verify shard2 is gone from listShards
echo ""
echo "Current shards:"
$MONGOS 'printjson(db.adminCommand({listShards:1}).shards.map(s=>s._id))'

# Step 5: Release the prepare failpoint — coordinator will try to reach removed shard2
echo ""
echo "Step 5: Releasing hangBeforeSendingPrepare — coordinator will discover shard2 is gone..."
$SHARD1 'printjson(db.adminCommand({configureFailPoint: "hangBeforeSendingPrepare", mode: "off"}))' 2>/dev/null || echo "(shard1 unreachable)"

# Wait and check if abort failpoint is hit
echo "Waiting for coordinator to reach abort phase..."
sleep 5

echo "Checking if hangBeforeSendingAbort was hit..."
HIT_ABORT=$(docker logs repro-shard1-1 2>&1 | grep -c "hangBeforeSendingAbort" || true)
echo "hangBeforeSendingAbort hits: $HIT_ABORT"

# Release abort failpoint too (coordinator will now try to send abort to removed shard2)
echo ""
echo "Step 6: Releasing hangBeforeSendingAbort..."
$SHARD1 'printjson(db.adminCommand({configureFailPoint: "hangBeforeSendingAbort", mode: "off"}))' 2>/dev/null || echo "(shard1 unreachable — may have hit fassert!)"

sleep 5

# Step 7: Check coordinator health
echo ""
echo "Step 7: Checking shard1 health..."
$SHARD1 'print("ALIVE: " + db.adminCommand({ping:1}).ok)' 2>/dev/null
PING_RC=$?
if [ $PING_RC -ne 0 ]; then
    echo "*** SHARD1 IS DOWN — likely fassert(51068)! ***"
    docker inspect repro-shard1-1 --format 'Container status: {{.State.Status}}, exit code: {{.State.ExitCode}}' 2>/dev/null
fi

# Step 8: Check logs
echo ""
echo "Step 8: Searching shard1 logs for fassert/ShardNotFound..."
docker logs repro-shard1-1 2>&1 | grep -i "fassert\|ShardNotFound\|51068\|Fatal assertion\|Fatal error" | grep -v "remote.*51068" | tail -20

echo ""
echo "Full relevant log tail:"
docker logs repro-shard1-1 2>&1 | tail -30

# Wait for background process
wait $COMMIT_PID 2>/dev/null || true

echo ""
echo "=== Reproduction attempt v2 complete ==="
