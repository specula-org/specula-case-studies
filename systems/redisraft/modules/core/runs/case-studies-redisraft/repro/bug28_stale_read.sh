#!/bin/bash
#
# Bug #28: NoOp not committed before serving non-quorum read
#
# The redisraft.so has been rebuilt with a 2-second delay in AE response
# processing (when entries > 0). This simulates real-world network latency
# and widens the window between becoming leader and committing the noop.
#
# Expected: new leader serves GET while commit_index < current_index.

set -e

REDIS_SERVER="/home/ubuntu/Specula/data/repositories/redis/src/redis-server"
REDIS_CLI="/home/ubuntu/Specula/data/repositories/redis/src/redis-cli"
REDISRAFT_SO="/home/ubuntu/Specula/case-studies/redisraft/artifact/redisraft/redisraft.so"
WORKDIR="/tmp/bug28_test"

cleanup() {
    for port in 5001 5002 5003; do
        $REDIS_CLI -p $port SHUTDOWN NOSAVE 2>/dev/null || true
    done
    rm -rf "$WORKDIR"
}

trap cleanup EXIT
cleanup 2>/dev/null
mkdir -p "$WORKDIR"/{node1,node2,node3}

echo "=== Bug #28: Read Before NoOp Committed ==="
echo ""

# Start 3 nodes
for i in 1 2 3; do
    port=$((5000 + i))
    $REDIS_SERVER --port $port --daemonize yes --dir "$WORKDIR/node$i" \
        --dbfilename redisraft.rdb --loadmodule "$REDISRAFT_SO" \
        --loglevel notice --logfile "$WORKDIR/node$i/redis.log" \
        --protected-mode no --save "" --pidfile "$WORKDIR/node$i/redis.pid"
done
sleep 1

$REDIS_CLI -p 5001 RAFT.CLUSTER INIT > /dev/null 2>&1
sleep 0.5
$REDIS_CLI -p 5002 RAFT.CLUSTER JOIN 127.0.0.1:5001 > /dev/null 2>&1
$REDIS_CLI -p 5003 RAFT.CLUSTER JOIN 127.0.0.1:5001 > /dev/null 2>&1

# Wait for cluster (the initial AE for membership changes will be delayed)
echo "[init] Waiting for cluster formation (delayed AE responses)..."
sleep 15

echo "[info] Cluster state:"
$REDIS_CLI -p 5001 INFO raft 2>&1 | grep -E "role|num_voting|current_index|commit_index"

# Write test data
$REDIS_CLI -p 5001 SET mykey "original_value" > /dev/null 2>&1
sleep 3  # Wait for delayed AE response
echo "[data] mykey = $($REDIS_CLI -p 5001 GET mykey)"

echo ""
echo "[step1] Killing leader (port 5001) to force election..."
LEADER_PID=$(cat "$WORKDIR/node1/redis.pid")
kill -9 $LEADER_PID

# Now poll for new leader election
echo "[step2] Waiting for new leader..."
NEW_LEADER=""
for attempt in $(seq 1 40); do
    for port in 5002 5003; do
        ROLE=$($REDIS_CLI -p $port INFO raft 2>/dev/null | grep "raft_role:leader")
        if [ -n "$ROLE" ]; then
            NEW_LEADER=$port
            break 2
        fi
    done
    sleep 0.25
done

if [ -z "$NEW_LEADER" ]; then
    echo "[FAIL] No new leader elected"
    exit 1
fi

echo "[election] New leader on port $NEW_LEADER!"

# The new leader has sent AE with noop to the other follower.
# Due to the 2-second delay, the response hasn't come back yet.
# The noop is NOT committed. But reads should still be served.

# Immediately check state and read
INFO=$($REDIS_CLI -p $NEW_LEADER INFO raft 2>/dev/null)
CI=$(echo "$INFO" | grep "raft_current_index:" | cut -d: -f2 | tr -d '\r ')
CMI=$(echo "$INFO" | grep "raft_commit_index:" | cut -d: -f2 | tr -d '\r ')
TERM=$(echo "$INFO" | grep "raft_current_term:" | cut -d: -f2 | tr -d '\r ')

echo ""
echo "[state] BEFORE noop committed:"
echo "  current_term:   $TERM"
echo "  current_index:  $CI"
echo "  commit_index:   $CMI"

# Try to read
READ_RESULT=$($REDIS_CLI -p $NEW_LEADER GET mykey 2>&1)
echo "  GET mykey:      \"$READ_RESULT\""

if [ "$CI" != "$CMI" ] && [ -n "$READ_RESULT" ] && [ "$READ_RESULT" != "" ]; then
    echo ""
    echo "*** BUG #28 CONFIRMED ***"
    echo "The new leader served a read (GET mykey = \"$READ_RESULT\")"
    echo "while current_index=$CI > commit_index=$CMI."
    echo "The noop entry has NOT been committed, but the read was served."
    echo ""
    echo "Per Raft Section 8, reads should be rejected until the leader"
    echo "commits an entry from its own term to ensure linearizability."
    echo ""
    echo "Now waiting for noop to commit (AE response arrives)..."
    sleep 3
    INFO2=$($REDIS_CLI -p $NEW_LEADER INFO raft 2>/dev/null)
    CI2=$(echo "$INFO2" | grep "raft_current_index:" | cut -d: -f2 | tr -d '\r ')
    CMI2=$(echo "$INFO2" | grep "raft_commit_index:" | cut -d: -f2 | tr -d '\r ')
    echo "  After waiting: current_index=$CI2, commit_index=$CMI2"
elif [ "$CI" = "$CMI" ]; then
    echo ""
    echo "Noop already committed (CI==CMI). Delay wasn't long enough."
else
    echo ""
    echo "Read returned empty or error: \"$READ_RESULT\""
fi
