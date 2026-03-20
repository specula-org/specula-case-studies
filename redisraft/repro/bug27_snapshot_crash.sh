#!/bin/bash
#
# Bug #27: Snapshot loading crash window
#
# The redisraft.so has been rebuilt with a 3-second delay between
# raft_begin_load_snapshot() and raft_end_load_snapshot().
# This widens the crash window so we can SIGKILL the node during loading.
#
# Expected result: after restart, the node has inconsistent state
# (logOffset > snapshotLastIdx) and either PANICs or behaves incorrectly.

set -e

REDIS_SERVER="/home/ubuntu/Specula/data/repositories/redis/src/redis-server"
REDIS_CLI="/home/ubuntu/Specula/data/repositories/redis/src/redis-cli"
REDISRAFT_SO="/home/ubuntu/Specula/case-studies/redisraft/artifact/redisraft/redisraft.so"
WORKDIR="/tmp/bug27_test"

cleanup() {
    for port in 6001 6002 6003; do
        $REDIS_CLI -p $port SHUTDOWN NOSAVE 2>/dev/null || true
    done
    sleep 0.3
}

trap cleanup EXIT
cleanup 2>/dev/null
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"/{node1,node2,node3}

echo "=== Bug #27: Snapshot Loading Crash Window ==="
echo ""

# Start 3 nodes
for i in 1 2 3; do
    port=$((6000 + i))
    $REDIS_SERVER --port $port --daemonize yes --dir "$WORKDIR/node$i" \
        --dbfilename redisraft.rdb --loadmodule "$REDISRAFT_SO" \
        --loglevel notice --logfile "$WORKDIR/node$i/redis.log" \
        --protected-mode no --save "" --pidfile "$WORKDIR/node$i/redis.pid"
done
sleep 1

# Initialize cluster
$REDIS_CLI -p 6001 RAFT.CLUSTER INIT > /dev/null 2>&1
sleep 0.5
$REDIS_CLI -p 6002 RAFT.CLUSTER JOIN 127.0.0.1:6001 > /dev/null 2>&1
$REDIS_CLI -p 6003 RAFT.CLUSTER JOIN 127.0.0.1:6001 > /dev/null 2>&1
sleep 5

echo "[init] Cluster formed (3 nodes, all voting)"
$REDIS_CLI -p 6001 INFO raft 2>&1 | grep -E "num_voting|current_index|commit_index"

# Write enough data
echo "[data] Writing 200 keys..."
for i in $(seq 1 200); do
    $REDIS_CLI -p 6001 SET "key$i" "value$i" > /dev/null 2>&1
done
sleep 1

echo "[info] After writes:"
$REDIS_CLI -p 6001 INFO raft 2>&1 | grep -E "current_index|commit_index|snapshot"

# Stop node 3, write more, then compact (so node 3 falls behind snapshot)
echo ""
echo "[step1] Stopping node 3..."
NODE3_PID=$(cat "$WORKDIR/node3/redis.pid")
kill -9 $NODE3_PID 2>/dev/null
sleep 1

echo "[step2] Writing 100 more keys while node 3 is down..."
for i in $(seq 201 300); do
    $REDIS_CLI -p 6001 SET "key$i" "value$i" > /dev/null 2>&1
done
sleep 1

# Take snapshot on leader (compacts the log)
echo "[step3] Taking snapshot on leader (RAFT.DEBUG COMPACT)..."
$REDIS_CLI -p 6001 RAFT.DEBUG COMPACT 2>&1
sleep 2

echo "[info] After compact:"
$REDIS_CLI -p 6001 INFO raft 2>&1 | grep -E "current_index|commit_index|log_entries|snapshot_last"

# Restart node 3 — it will need a snapshot (its last index < snapshot boundary)
echo ""
echo "[step4] Restarting node 3 (will receive InstallSnapshot)..."
$REDIS_SERVER --port 6003 --daemonize yes --dir "$WORKDIR/node3" \
    --dbfilename redisraft.rdb --loadmodule "$REDISRAFT_SO" \
    --loglevel notice --logfile "$WORKDIR/node3/redis.log" \
    --protected-mode no --save "" --pidfile "$WORKDIR/node3/redis.pid"

# Wait for the BUG27_REPRO log message (the 3-second delay window)
echo "[step5] Monitoring node 3 for snapshot loading..."
for attempt in $(seq 1 60); do
    if grep -q "BUG27_REPRO: crash window open" "$WORKDIR/node3/redis.log" 2>/dev/null; then
        echo "[DETECT] Snapshot loading started — crash window is OPEN!"
        sleep 0.5  # Let begin_load_snapshot complete (log+metadata reset)

        # KILL node 3 during the window
        NODE3_PID=$(cat "$WORKDIR/node3/redis.pid")
        echo "[KILL] SIGKILL node 3 (pid=$NODE3_PID) during snapshot load..."
        kill -9 $NODE3_PID 2>/dev/null
        sleep 0.5
        break
    fi
    sleep 0.2
done

if ! grep -q "BUG27_REPRO: crash window open" "$WORKDIR/node3/redis.log" 2>/dev/null; then
    echo "[FAIL] Never saw snapshot loading. Check logs:"
    tail -20 "$WORKDIR/node3/redis.log"
    exit 1
fi

# Verify the crash happened during the window
echo ""
echo "[check] Node 3 log around crash:"
grep -n "BUG27_REPRO\|begin_load\|end_load\|snapshot" "$WORKDIR/node3/redis.log" | tail -10

# Check: did "crash window closing" appear? (If yes, we missed the window)
if grep -q "BUG27_REPRO: crash window closing" "$WORKDIR/node3/redis.log"; then
    echo "[FAIL] Crash window already closed before kill. Rerun."
    exit 1
fi

echo ""
echo "[step6] Restarting node 3 after crash..."

# Clear the PID file
rm -f "$WORKDIR/node3/redis.pid"

# Rename old log so we can see fresh output
mv "$WORKDIR/node3/redis.log" "$WORKDIR/node3/redis_before_crash.log"

$REDIS_SERVER --port 6003 --daemonize yes --dir "$WORKDIR/node3" \
    --dbfilename redisraft.rdb --loadmodule "$REDISRAFT_SO" \
    --loglevel notice --logfile "$WORKDIR/node3/redis.log" \
    --protected-mode no --save "" --pidfile "$WORKDIR/node3/redis.pid"

sleep 5

echo ""
echo "=== Post-crash analysis ==="
echo ""
echo "[log] Node 3 restart log:"
cat "$WORKDIR/node3/redis.log"

echo ""
echo "[check] Testing if node 3 is reachable..."
PING=$($REDIS_CLI -p 6003 PING 2>&1)
echo "  PING: $PING"

if echo "$PING" | grep -q "PONG"; then
    INFO=$($REDIS_CLI -p 6003 INFO raft 2>&1)
    echo ""
    echo "[info] Node 3 raft state after restart:"
    echo "$INFO" | grep -E "role|state|current_index|commit_index|snapshot_last|log_entries"

    # Check for inconsistency
    SNAP_IDX=$(echo "$INFO" | grep "raft_snapshot_last_idx:" | cut -d: -f2 | tr -d '\r ')
    LOG_ENTRIES=$(echo "$INFO" | grep "raft_log_entries:" | cut -d: -f2 | tr -d '\r ')
    CURR_IDX=$(echo "$INFO" | grep "raft_current_index:" | cut -d: -f2 | tr -d '\r ')

    echo ""
    echo "  snapshot_last_idx:  $SNAP_IDX"
    echo "  log_entries:        $LOG_ENTRIES"
    echo "  current_index:      $CURR_IDX"

    if [ "$SNAP_IDX" = "0" ] && [ "$LOG_ENTRIES" = "0" ]; then
        echo ""
        echo "*** BUG #27 CONFIRMED ***"
        echo "Node has snapshot_last_idx=0 (metadata not updated) but"
        echo "log was already reset by raft_begin_load_snapshot."
        echo "Empty log + no snapshot = data loss / inconsistent state."
    fi
else
    echo ""
    echo "*** BUG #27 CONFIRMED ***"
    echo "Node 3 is UNREACHABLE after restart — crashed or PANICed"
    echo "due to inconsistent snapshot/log state."
    echo ""
    echo "Last lines of crash log:"
    tail -5 "$WORKDIR/node3/redis.log"
fi

echo ""
echo "[files] All logs at: $WORKDIR/"
