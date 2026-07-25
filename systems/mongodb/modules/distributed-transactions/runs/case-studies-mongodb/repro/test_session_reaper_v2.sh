#!/bin/bash
# SERVER-105751 Reproduction Test: Session Reaper vs Prepared Transactions
# Tests whether prepared transactions survive: (A) session expiry, (B) killSessions, (C) step-down
# Expected: All safeguards hold in MongoDB 8.2.6

set -e

mongosh_() {
    docker exec "$1" mongosh --quiet --eval "$2" 2>/dev/null
}

check_prepared() {
    local container=$1
    mongosh_ "$container" '
        var ss = db.serverStatus().transactions;
        print("PREPARED=" + (ss ? ss.currentPrepared : 0));
    '
}

echo "============================================================"
echo "SERVER-105751 Reproduction: Session Reaper vs Prepared Txns"
echo "MongoDB $(docker exec repro-mongos mongosh --quiet --eval 'db.version()' 2>/dev/null)"
echo "============================================================"

##############################################################################
echo ""
echo "=== TEST A: Session Expiry vs Prepared Transaction ==="
echo "Setting transactionLifetimeLimitSeconds=10 on both shards..."
##############################################################################

for c in repro-shard1a repro-shard2; do
    mongosh_ $c "db.adminCommand({setParameter:1, transactionLifetimeLimitSeconds:10})"
done

echo "Enabling hangBeforeSendingCommit failpoint..."
mongosh_ repro-shard1a 'db.adminCommand({configureFailPoint:"hangBeforeSendingCommit",mode:"alwaysOn"})'

echo "Starting cross-shard transaction..."
docker exec repro-mongos mongosh --quiet --eval '
var s = db.getMongo().startSession();
var d = s.getDatabase("testdb");
s.startTransaction({readConcern:{level:"snapshot"},writeConcern:{w:"majority"}});
d.txncoll.updateOne({key:1},{$set:{val:"testA_s1"}});
d.txncoll.updateOne({key:200},{$set:{val:"testA_s2"}});
s.commitTransaction();
print("RESULT:COMMITTED");
s.endSession();
' &
BGPID=$!

echo "Waiting 10s for prepare phase..."
sleep 10

BEFORE=$(check_prepared repro-shard2)
echo "Before expiry: $BEFORE"

echo "Waiting 20s for session lifetime to expire (limit=10s)..."
sleep 20

AFTER=$(check_prepared repro-shard2)
echo "After expiry: $AFTER"

AFTER_NUM=$(echo "$AFTER" | grep -oP 'PREPARED=\K\d+')
if [ "$AFTER_NUM" -ge 1 ] 2>/dev/null; then
    echo ">> TEST A PASS: Prepared transaction SURVIVED session expiry"
    TEST_A="PASS"
else
    echo ">> TEST A FAIL: Prepared transaction was KILLED!"
    TEST_A="FAIL"
fi

# Cleanup
mongosh_ repro-shard1a 'db.adminCommand({configureFailPoint:"hangBeforeSendingCommit",mode:"off"})'
wait $BGPID 2>/dev/null || true
for c in repro-shard1a repro-shard2; do
    mongosh_ $c "db.adminCommand({setParameter:1, transactionLifetimeLimitSeconds:60})"
done
sleep 3

##############################################################################
echo ""
echo "=== TEST B: killSessions vs Prepared Transaction ==="
##############################################################################

echo "Enabling hangBeforeSendingCommit failpoint..."
mongosh_ repro-shard1a 'db.adminCommand({configureFailPoint:"hangBeforeSendingCommit",mode:"alwaysOn"})'

echo "Starting cross-shard transaction..."
docker exec repro-mongos mongosh --quiet --eval '
var s = db.getMongo().startSession();
var d = s.getDatabase("testdb");
s.startTransaction({readConcern:{level:"snapshot"},writeConcern:{w:"majority"}});
d.txncoll.updateOne({key:1},{$set:{val:"testB_s1"}});
d.txncoll.updateOne({key:200},{$set:{val:"testB_s2"}});
s.commitTransaction();
print("RESULT:COMMITTED");
s.endSession();
' &
BGPID=$!

echo "Waiting 10s for prepare phase..."
sleep 10

BEFORE=$(check_prepared repro-shard2)
echo "Before killSessions: $BEFORE"

echo "Running killAllSessionsByPattern on shard2..."
KILL_RESULT=$(mongosh_ repro-shard2 '
    try {
        var r = db.adminCommand({killAllSessionsByPattern: [{}]});
        print("kill_ok=" + r.ok);
    } catch(e) {
        print("kill_error=" + e.message);
    }
')
echo "Kill result: $KILL_RESULT"

sleep 5

AFTER=$(check_prepared repro-shard2)
echo "After killSessions: $AFTER"

AFTER_NUM=$(echo "$AFTER" | grep -oP 'PREPARED=\K\d+')
if [ "$AFTER_NUM" -ge 1 ] 2>/dev/null; then
    echo ">> TEST B PASS: Prepared transaction SURVIVED killSessions"
    TEST_B="PASS"
else
    echo ">> TEST B FAIL: Prepared transaction was KILLED!"
    TEST_B="FAIL"
fi

# Cleanup
mongosh_ repro-shard1a 'db.adminCommand({configureFailPoint:"hangBeforeSendingCommit",mode:"off"})'
wait $BGPID 2>/dev/null || true
sleep 3

##############################################################################
echo ""
echo "=== TEST C: Participant Step-Down vs Prepared Transaction ==="
echo "(shard2 is single-node RS; will self-elect after stepdown)"
##############################################################################

echo "Enabling hangBeforeSendingCommit failpoint..."
mongosh_ repro-shard1a 'db.adminCommand({configureFailPoint:"hangBeforeSendingCommit",mode:"alwaysOn"})'

echo "Starting cross-shard transaction..."
docker exec repro-mongos mongosh --quiet --eval '
var s = db.getMongo().startSession();
var d = s.getDatabase("testdb");
s.startTransaction({readConcern:{level:"snapshot"},writeConcern:{w:"majority"}});
d.txncoll.updateOne({key:1},{$set:{val:"testC_s1"}});
d.txncoll.updateOne({key:200},{$set:{val:"testC_s2"}});
s.commitTransaction();
print("RESULT:COMMITTED");
s.endSession();
' &
BGPID=$!

echo "Waiting 10s for prepare phase..."
sleep 10

BEFORE=$(check_prepared repro-shard2)
echo "Before step-down: $BEFORE"

echo "Stepping down shard2..."
mongosh_ repro-shard2 '
    try { db.adminCommand({replSetStepDown: 5, force: true}); }
    catch(e) { print("stepdown: " + e.message); }
' || true

echo "Waiting 15s for re-election..."
sleep 15

# Wait for shard2 to be primary again
for i in $(seq 1 15); do
    IS_PRIMARY=$(mongosh_ repro-shard2 'print(rs.isMaster().ismaster)')
    if echo "$IS_PRIMARY" | grep -q "true"; then
        echo "shard2 is primary again (attempt $i)"
        break
    fi
    sleep 2
done

AFTER=$(check_prepared repro-shard2)
echo "After step-down + re-election: $AFTER"

AFTER_NUM=$(echo "$AFTER" | grep -oP 'PREPARED=\K\d+')
if [ "$AFTER_NUM" -ge 1 ] 2>/dev/null; then
    echo ">> TEST C PASS: Prepared transaction SURVIVED step-down"
    TEST_C="PASS"
else
    echo ">> TEST C FAIL: Prepared transaction was LOST!"
    TEST_C="FAIL"
fi

# Cleanup
mongosh_ repro-shard1a 'db.adminCommand({configureFailPoint:"hangBeforeSendingCommit",mode:"off"})'
wait $BGPID 2>/dev/null || true

##############################################################################
echo ""
echo "============================================================"
echo "SUMMARY"
echo "============================================================"
echo "Test A (Session Expiry): $TEST_A"
echo "Test B (killSessions):   $TEST_B"
echo "Test C (Step-Down):      $TEST_C"

if [ "$TEST_A" = "PASS" ] && [ "$TEST_B" = "PASS" ] && [ "$TEST_C" = "PASS" ]; then
    echo ""
    echo "VERDICT: All safeguards hold. SERVER-105751 NOT reproducible in MongoDB 8.2.6."
    echo "The MC finding is a FALSE POSITIVE — spec allows SessionReaperFire on prepared"
    echo "transactions, but the real code does not permit this."
elif [ "$TEST_A" = "FAIL" ] || [ "$TEST_B" = "FAIL" ] || [ "$TEST_C" = "FAIL" ]; then
    echo ""
    echo "VERDICT: BUG CONFIRMED — at least one safeguard FAILED!"
fi
echo "============================================================"
