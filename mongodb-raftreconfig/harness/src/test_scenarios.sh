#!/usr/bin/env bash
# Test scenarios for MongoRaftReconfig trace collection.
# Each scenario exercises specific replication/reconfig code paths.
# Client-side events (ShutDown, ClientRequest) emitted to per-scenario NDJSON.
set -euo pipefail

TRACE_DIR="${TRACE_DIR:-$(cd "$(dirname "$0")/../.." && pwd)/traces}"
mkdir -p "$TRACE_DIR"

# Helper: get current epoch nanoseconds
ts_ns() {
    date +%s%N
}

# Helper: emit a client-side trace event
emit_event() {
    local file="$1"
    local name="$2"
    local node="$3"
    shift 3
    local extra="$*"
    local ts
    ts=$(ts_ns)
    echo "{\"tag\":\"trace\",\"ts\":\"$ts\",\"event\":{\"name\":\"$name\",\"node\":\"$node\"${extra:+,$extra}}}" >> "$file"
}

# Helper: find current primary container name (with retries)
find_primary() {
    local max_attempts=${1:-30}
    for attempt in $(seq 1 "$max_attempts"); do
        for c in mongo-rs0-1 mongo-rs0-2 mongo-rs0-3 mongo-rs0-4 mongo-rs0-5; do
            local is_primary
            is_primary=$(docker exec "$c" mongosh --quiet --eval 'print(db.isMaster().ismaster)' 2>/dev/null || echo "false")
            if [ "$is_primary" = "true" ]; then
                echo "$c"
                return 0
            fi
        done
        sleep 1
    done
    echo ""
    return 1
}

# Helper: map container name to TLA+ server ID
container_to_sid() {
    case "$1" in
        mongo-rs0-1) echo "s1" ;;
        mongo-rs0-2) echo "s2" ;;
        mongo-rs0-3) echo "s3" ;;
        mongo-rs0-4) echo "s4" ;;
        mongo-rs0-5) echo "s5" ;;
        *) echo "unknown" ;;
    esac
}

# Helper: wait for a condition
wait_for() {
    local desc="$1"
    local cmd="$2"
    local max=${3:-30}
    echo "  Waiting for $desc..."
    for i in $(seq 1 "$max"); do
        if eval "$cmd" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "  WARNING: Timed out waiting for $desc"
    return 1
}

###############################################################################
# Scenario 1: election_drain
# Step down primary -> new election -> drain mode -> config term bump
###############################################################################
scenario_election_drain() {
    echo ""
    echo "=== Scenario: election_drain ==="
    local trace_file="$TRACE_DIR/election_drain_client.ndjson"
    > "$trace_file"

    # Find current primary
    local primary
    primary=$(find_primary)
    local primary_sid
    primary_sid=$(container_to_sid "$primary")
    echo "  Current primary: $primary ($primary_sid)"

    # Insert some data first
    echo "  Inserting data on primary..."
    docker exec "$primary" mongosh --quiet --eval '
        db.getSiblingDB("testdb").testcoll.insertMany([
            {key: "election_drain_1", ts: new Date()},
            {key: "election_drain_2", ts: new Date()}
        ]);
    '
    sleep 2

    # Step down the primary
    echo "  Stepping down primary $primary..."
    docker exec "$primary" mongosh --quiet --eval '
        try { db.adminCommand({replSetStepDown: 30, force: true}); }
        catch(e) { print("stepDown: " + e.message); }
    ' 2>/dev/null || true

    # Wait for new primary (with retries)
    echo "  Waiting for new primary election..."
    sleep 3
    local new_primary
    new_primary=$(find_primary 30) || true
    if [ -z "$new_primary" ]; then
        echo "  WARNING: No primary found after stepdown, waiting more..."
        sleep 10
        new_primary=$(find_primary 30) || true
    fi
    if [ -z "$new_primary" ]; then
        echo "  ERROR: No primary elected after stepdown"
        return 1
    fi
    local new_primary_sid
    new_primary_sid=$(container_to_sid "$new_primary")
    echo "  New primary: $new_primary ($new_primary_sid)"

    # Insert data on new primary to confirm it's writable (drain complete)
    sleep 5
    echo "  Inserting data on new primary..."
    docker exec "$new_primary" mongosh --quiet --eval '
        db.getSiblingDB("testdb").testcoll.insertOne({key: "post_election", ts: new Date()});
    ' || echo "  WARNING: insert failed (primary may still be draining)"

    echo "  election_drain scenario complete."
}

###############################################################################
# Scenario 2: basic_reconfig
# Add mongo4 to the replica set, observe config propagation + newlyAdded
###############################################################################
scenario_basic_reconfig() {
    echo ""
    echo "=== Scenario: basic_reconfig ==="
    local trace_file="$TRACE_DIR/basic_reconfig_client.ndjson"
    > "$trace_file"

    # Find current primary
    local primary
    primary=$(find_primary 15) || true
    if [ -z "$primary" ]; then
        echo "  ERROR: No primary found for basic_reconfig"
        return 1
    fi
    local primary_sid
    primary_sid=$(container_to_sid "$primary")
    echo "  Current primary: $primary ($primary_sid)"

    # Add mongo4 to the replica set
    echo "  Adding mongo4 to replica set..."
    docker exec "$primary" mongosh --quiet --eval '
        var cfg = rs.conf();
        cfg.members.push({_id: 3, host: "mongo4:27017"});
        cfg.version = cfg.version + 1;
        rs.reconfig(cfg);
    '

    # Wait for mongo4 to become SECONDARY
    echo "  Waiting for mongo4 to become SECONDARY..."
    wait_for "mongo4 SECONDARY" \
        'docker exec mongo-rs0-4 mongosh --quiet --eval "var s = rs.status().myState; if (s !== 2) throw \"not secondary\";"' \
        60

    # Wait for newlyAdded removal (auto-reconfig by primary)
    echo "  Waiting for newlyAdded removal..."
    sleep 15

    # Insert data to confirm the 4-node RS works
    echo "  Inserting data on primary..."
    docker exec "$primary" mongosh --quiet --eval '
        db.getSiblingDB("testdb").testcoll.insertOne({key: "post_reconfig", ts: new Date()});
    '

    # Show current config
    docker exec "$primary" mongosh --quiet --eval '
        var cfg = rs.conf();
        cfg.members.forEach(function(m) {
            print(m.host + " newlyAdded=" + (m.newlyAdded || false));
        });
    '

    echo "  basic_reconfig scenario complete."
}

###############################################################################
# Scenario 3: force_reconfig
# Force reconfig to remove a node (bypasses safety checks, configTerm=-1)
###############################################################################
scenario_force_reconfig() {
    echo ""
    echo "=== Scenario: force_reconfig ==="
    local trace_file="$TRACE_DIR/force_reconfig_client.ndjson"
    > "$trace_file"

    # Find current primary
    local primary
    primary=$(find_primary 15) || true
    if [ -z "$primary" ]; then
        echo "  ERROR: No primary found for force_reconfig"
        return 1
    fi
    local primary_sid
    primary_sid=$(container_to_sid "$primary")
    echo "  Current primary: $primary ($primary_sid)"

    # Find a secondary to partition (not the primary, not mongo4 which may be just added)
    local partition_target=""
    local partition_sid=""
    for c in mongo-rs0-1 mongo-rs0-2 mongo-rs0-3; do
        if [ "$c" != "$primary" ]; then
            local member_state
            member_state=$(docker exec "$c" mongosh --quiet --eval 'print(rs.status().myState)' 2>/dev/null || echo "0")
            if [ "$member_state" = "2" ]; then  # 2 = SECONDARY
                partition_target="$c"
                partition_sid=$(container_to_sid "$c")
                break
            fi
        fi
    done
    if [ -z "$partition_target" ]; then
        echo "  WARNING: No secondary found to partition, skipping force_reconfig"
        return 0
    fi

    # Get hostname of partition target
    local partition_host
    partition_host=$(docker exec "$partition_target" mongosh --quiet --eval 'print(rs.status().members.filter(m => m.self)[0].name)' 2>/dev/null || echo "unknown")
    echo "  Partitioning $partition_target ($partition_sid, $partition_host)..."

    # Pause the secondary to simulate partition
    docker pause "$partition_target"

    # Emit ShutDown event for partitioned node
    emit_event "$trace_file" "ShutDown" "$partition_sid"

    sleep 3

    # Force reconfig to remove partitioned node
    echo "  Force reconfig: removing $partition_host..."
    docker exec "$primary" mongosh --quiet --eval "
        var cfg = rs.conf();
        cfg.members = cfg.members.filter(m => m.host !== '$partition_host');
        cfg.version = cfg.version + 1;
        rs.reconfig(cfg, {force: true});
    "

    sleep 5

    # Show config after force reconfig
    docker exec "$primary" mongosh --quiet --eval '
        var cfg = rs.conf();
        print("Config version: " + cfg.version + ", term: " + cfg.term);
        cfg.members.forEach(m => print("  " + m.host));
    '

    # Unpause the partitioned node
    echo "  Unpausing $partition_target..."
    docker unpause "$partition_target"

    sleep 5

    echo "  force_reconfig scenario complete."
}

###############################################################################
# Main: run all scenarios sequentially
###############################################################################
echo "===== Running MongoRaftReconfig Test Scenarios ====="

# Give the cluster a moment to stabilize after init
sleep 5

# Scenario 1: election and drain
scenario_election_drain
sleep 5

# Scenario 2: basic reconfig (add node)
scenario_basic_reconfig
sleep 5

# Scenario 3: force reconfig (remove node under partition)
scenario_force_reconfig

echo ""
echo "===== All scenarios complete ====="
