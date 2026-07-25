#!/usr/bin/env bash
# Initialize a 3-node replica set (mongo1, mongo2, mongo3).
# mongo4 and mongo5 are running but NOT in the RS — available for reconfig tests.
set -euo pipefail

wait_for_mongod() {
    local container=$1
    local max_attempts=60
    for i in $(seq 1 $max_attempts); do
        if docker exec "$container" mongosh --quiet --eval "db.runCommand({ping:1})" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "ERROR: $container did not start in ${max_attempts}s"
    return 1
}

echo "Waiting for containers to start..."
wait_for_mongod mongo-rs0-1
wait_for_mongod mongo-rs0-2
wait_for_mongod mongo-rs0-3
wait_for_mongod mongo-rs0-4
wait_for_mongod mongo-rs0-5

echo "Initializing replica set with 3 members..."
docker exec mongo-rs0-1 mongosh --quiet --eval '
    rs.initiate({
        _id: "rs0",
        members: [
            {_id: 0, host: "mongo1:27017"},
            {_id: 1, host: "mongo2:27017"},
            {_id: 2, host: "mongo3:27017"}
        ]
    })
'
sleep 5

echo "Waiting for primary election..."
for i in $(seq 1 30); do
    primary=$(docker exec mongo-rs0-1 mongosh --quiet --eval '
        var st = rs.status();
        var p = st.members.filter(m => m.stateStr === "PRIMARY");
        if (p.length > 0) print(p[0].name); else print("none");
    ' 2>/dev/null || echo "none")
    if [ "$primary" != "none" ] && [ -n "$primary" ]; then
        echo "Primary elected: $primary"
        break
    fi
    sleep 1
done

echo "Replica set initialized."
docker exec mongo-rs0-1 mongosh --quiet --eval 'rs.status().members.forEach(m => print(m.name + " -> " + m.stateStr))'
