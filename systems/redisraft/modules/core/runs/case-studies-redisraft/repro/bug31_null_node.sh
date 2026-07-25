#!/bin/bash
#
# Bug #31: handleAEResponse NULL node dereference
#
# One-shot delay strategy:
#   All nodes run the same .so, but the delay is triggered by a file.
#   1. Form cluster normally (no delays)
#   2. Create trigger file /tmp/bug31_delay_trigger
#   3. SET key → leader sends AE to all. Node3 hits the trigger → delays 2s ONE TIME
#   4. RAFT.NODE REMOVE node3 → node2 responds instantly → REMOVE committed & applied
#   5. Node3's ONE-SHOT delayed AE response arrives → raft_get_node = NULL → BUG
#   6. (The REMOVE AE to node3 proceeds at normal speed since trigger was consumed)

REDIS_SERVER="/home/ubuntu/Specula/data/repositories/redis/src/redis-server"
REDIS_CLI="/home/ubuntu/Specula/data/repositories/redis/src/redis-cli"
REDISRAFT_SO="/home/ubuntu/Specula/case-studies/redisraft/artifact/redisraft/redisraft.so"
WORKDIR="/tmp/bug31_test"

cleanup() {
    for port in 7001 7002 7003; do
        $REDIS_CLI -p $port SHUTDOWN NOSAVE 2>/dev/null || true
    done
    rm -f /tmp/bug31_delay_trigger
    rm -rf "$WORKDIR"
}

trap cleanup EXIT
cleanup 2>/dev/null
mkdir -p "$WORKDIR"/{node1,node2,node3}

echo "=== Bug #31: handleAEResponse NULL Node Dereference ==="
echo ""

# Start all nodes with reconnect-interval=10000 (10s) to prevent early connection reaping
for i in 1 2 3; do
    port=$((7000 + i))
    $REDIS_SERVER --port $port --daemonize yes --dir "$WORKDIR/node$i" \
        --dbfilename redisraft.rdb \
        --loadmodule "$REDISRAFT_SO" reconnect-interval=10000 \
        --loglevel notice --logfile "$WORKDIR/node$i/redis.log" \
        --protected-mode no --save "" --pidfile "$WORKDIR/node$i/redis.pid"
done
echo "[init] All nodes started (reconnect-interval=10000ms)"
sleep 1

# Form cluster normally (no trigger file → no delays)
$REDIS_CLI -p 7001 RAFT.CLUSTER INIT > /dev/null 2>&1
sleep 0.5
$REDIS_CLI -p 7002 RAFT.CLUSTER JOIN 127.0.0.1:7001 > /dev/null 2>&1
$REDIS_CLI -p 7003 RAFT.CLUSTER JOIN 127.0.0.1:7001 > /dev/null 2>&1

echo "[wait] Waiting for cluster formation..."
sleep 10

VOTING=$($REDIS_CLI -p 7001 INFO raft 2>&1 | grep "raft_num_voting_nodes:" | cut -d: -f2 | tr -d '\r ')
echo "[info] Voting nodes: $VOTING/3"

if [ "$VOTING" != "3" ]; then
    echo "[wait] Waiting more..."
    sleep 15
    VOTING=$($REDIS_CLI -p 7001 INFO raft 2>&1 | grep "raft_num_voting_nodes:" | cut -d: -f2 | tr -d '\r ')
    echo "[info] Voting nodes: $VOTING/3"
fi

NODE3_ID=$($REDIS_CLI -p 7001 INFO raft 2>&1 | grep "port=7003" | grep -oP 'id=\K[0-9]+')
echo "[info] Node 3 raft ID: $NODE3_ID"

if [ -z "$NODE3_ID" ]; then
    echo "[FAIL] Cannot find node3"
    exit 1
fi

echo ""
echo "[info] Current cluster state:"
$REDIS_CLI -p 7001 INFO raft 2>&1 | grep -E "node|current_index|commit_index"
echo ""

for round in $(seq 1 10); do
    echo "--- Round $round ---"

    # Step 1: Plant the trigger ONLY on node3
    # The trigger file is on the shared filesystem, so ALL nodes can see it.
    # But only the first node to process an AE with entries will consume it.
    # We need to make sure node3 consumes it, not node2.
    #
    # Strategy: node2 won't see any entries if we send the AE when node2
    # is already caught up. But actually, the leader sends AE to all nodes.
    # The trigger will be consumed by whichever node processes the AE first.
    #
    # Better approach: create the trigger, then immediately SET a key.
    # Both node2 and node3 will receive the AE. One of them will consume
    # the trigger. If node2 consumes it, node2 delays instead of node3.
    # That's not what we want.
    #
    # Workaround: put the trigger on node3's specific path.
    # Actually, let's just try it and see. If node3 consumes it, great.
    # If not, try again. With 50% chance per round, we should hit it.

    touch /tmp/bug31_delay_trigger

    # Step 2: Write key to trigger AE
    $REDIS_CLI -p 7001 SET "attack_key_$round" "v" > /dev/null 2>&1 &
    SET_PID=$!

    # Step 3: Brief pause then remove node3
    sleep 0.1
    $REDIS_CLI -p 7001 RAFT.NODE REMOVE $NODE3_ID > /dev/null 2>&1

    # Step 4: Wait for delayed response
    sleep 3

    wait $SET_PID 2>/dev/null

    # Check for BUG31
    if grep -q "BUG31_REPRO.*raft_get_node returned NULL" "$WORKDIR/node1/redis.log" 2>/dev/null; then
        echo ""
        echo "*** BUG #31 CONFIRMED ***"
        echo ""
        grep "BUG31_REPRO" "$WORKDIR/node1/redis.log"
        exit 0
    fi

    # Clean up trigger if not consumed
    rm -f /tmp/bug31_delay_trigger

    # Check who consumed the trigger
    for port in 7001 7002 7003; do
        if grep -q "BUG31_REPRO.*ONE-SHOT delay" "$WORKDIR/node$((port-7000))/redis.log" 2>/dev/null; then
            LATEST=$(grep "BUG31_REPRO.*ONE-SHOT delay" "$WORKDIR/node$((port-7000))/redis.log" | wc -l)
            echo "  Trigger consumed by node$((port-7000)) (port $port) [$LATEST times total]"
        fi
    done

    # Check if leader is alive
    if ! $REDIS_CLI -p 7001 PING 2>/dev/null | grep -q PONG; then
        echo "  Leader crashed!"
        tail -10 "$WORKDIR/node1/redis.log"
        exit 0
    fi

    # Re-add node3 for next round
    if ! $REDIS_CLI -p 7003 PING 2>/dev/null | grep -q PONG; then
        $REDIS_SERVER --port 7003 --daemonize yes --dir "$WORKDIR/node3" \
            --dbfilename redisraft.rdb --loadmodule "$REDISRAFT_SO" reconnect-interval=10000 \
            --loglevel notice --logfile "$WORKDIR/node3/redis.log" \
            --protected-mode no --save "" --pidfile "$WORKDIR/node3/redis.pid"
        sleep 1
    fi
    $REDIS_CLI -p 7003 RAFT.CLUSTER JOIN 127.0.0.1:7001 > /dev/null 2>&1
    sleep 8

    NODE3_ID=$($REDIS_CLI -p 7001 INFO raft 2>&1 | grep "port=7003" | grep -oP 'id=\K[0-9]+')
    if [ -z "$NODE3_ID" ]; then
        echo "  Node3 didn't rejoin, waiting more..."
        sleep 10
        NODE3_ID=$($REDIS_CLI -p 7001 INFO raft 2>&1 | grep "port=7003" | grep -oP 'id=\K[0-9]+')
    fi

    if [ -z "$NODE3_ID" ]; then
        echo "  Node3 still not back. Skipping."
        continue
    fi
done

echo ""
echo "=== Final analysis ==="
echo ""
echo "--- Leader log (BUG31 markers) ---"
grep "BUG31" "$WORKDIR/node1/redis.log" 2>/dev/null | tail -10 || echo "(none)"
echo ""
echo "--- Node2 log (BUG31 markers) ---"
grep "BUG31" "$WORKDIR/node2/redis.log" 2>/dev/null | tail -10 || echo "(none)"
echo ""
echo "--- Node3 log (BUG31 markers) ---"
grep "BUG31" "$WORKDIR/node3/redis.log" 2>/dev/null | tail -10 || echo "(none)"
