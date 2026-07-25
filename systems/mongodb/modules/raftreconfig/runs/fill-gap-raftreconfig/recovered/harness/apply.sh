#!/bin/bash
# apply.sh — bring up a FRESH 5-node replica set and initialize it.
#
# No source patching / recompilation: MongoRaftReconfig traces are produced by parsing
# MongoDB's logv2 structured logs (replication verbosity 3). "Applying instrumentation"
# here means: start the cluster, copy the poller + setup scripts in, run rs.initiate,
# and wait for a stable primary.
#
# Usage:  bash harness/apply.sh [setup_genesis.js|setup_psa.js]
#         (default: setup_genesis.js)
#
# Re-runnable: tears down any previous cluster (down -v) first, so every scenario
# starts from a pristine genesis (version 1) state.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/src"
COMPOSE="$SRC/docker-compose.yml"
SETUP="${1:-setup_genesis.js}"
NODES="rcfg1 rcfg2 rcfg3 rcfg4 rcfg5"

echo "=== [apply] fresh cluster (setup=$SETUP) ==="
docker compose -f "$COMPOSE" down -v 2>/dev/null || true
docker compose -f "$COMPOSE" up -d

echo "=== [apply] waiting for mongod processes ==="
for c in $NODES; do
    for i in $(seq 1 40); do
        if docker exec "$c" mongosh --port 27017 --quiet --eval 'db.runCommand({ping:1}).ok' 2>/dev/null | grep -q 1; then
            echo "  $c ready"; break
        fi
        sleep 1
        [ "$i" = 40 ] && echo "  WARNING: $c not ready after 40s"
    done
done

echo "=== [apply] copying scripts into containers ==="
for c in $NODES; do
    docker exec "$c" mkdir -p /scripts 2>/dev/null || true
    docker cp "$SRC/poller.js" "$c:/scripts/poller.js"
done
# setup + scenarios + shared lib run from rcfg1
for f in lib.js setup_genesis.js setup_psa.js test_baseline_reconfig.js test_family1_term.js test_family2_commit.js test_family3_arbiter.js; do
    docker cp "$SRC/$f" "rcfg1:/scripts/$f"
done

echo "=== [apply] initiating replica set ($SETUP) ==="
docker exec rcfg1 mongosh --port 27017 --quiet --file "/scripts/$SETUP" || true

echo "=== [apply] waiting for a stable primary ==="
PRIMARY=""
for i in $(seq 1 60); do
    for c in $NODES; do
        ip=$(docker exec "$c" mongosh --port 27017 --quiet --eval 'db.adminCommand({hello:1}).isWritablePrimary' 2>/dev/null || echo false)
        if echo "$ip" | grep -q true; then PRIMARY="$c"; break; fi
    done
    [ -n "$PRIMARY" ] && break
    sleep 1
done
if [ -n "$PRIMARY" ]; then echo "  primary = $PRIMARY"; else echo "  WARNING: no primary after 60s"; fi

echo "=== [apply] (re)asserting replication verbosity 3 ==="
for c in $NODES; do
    docker exec "$c" mongosh --port 27017 --quiet --eval \
      'db.adminCommand({setParameter:1, logComponentVerbosity:{replication:{verbosity:3}}})' >/dev/null 2>&1 || true
done

# Wait for STEADY genesis: exactly one primary, its optimized step-up done
# (election term == config term), and every member converged to the same
# (configVersion, configTerm). Only then does run.sh open the trace window — so the
# bootstrap election + step-up + their heartbeat propagation are all EXCLUDED and the
# window begins from the (v1,t1) steady state TraceInit assumes.
echo "=== [apply] waiting for steady genesis (step-up done, configs converged) ==="
STEADY_CHECK='
var s = db.adminCommand({replSetGetStatus: 1});
var c = db.adminCommand({replSetGetConfig: 1}).config;
var prim = s.members.filter(function(m){return m.stateStr=="PRIMARY";}).length;
var vs = Array.from(new Set(s.members.map(function(m){return m.configVersion;})));
var ts = Array.from(new Set(s.members.map(function(m){return m.configTerm;})));
if (prim==1 && vs.length==1 && ts.length==1 && s.term==c.term) print("STEADY");
else print("NOT prim="+prim+" vs="+JSON.stringify(vs)+" ts="+JSON.stringify(ts)+" t="+s.term+" ct="+c.term);
'
if [ -n "$PRIMARY" ]; then
    for i in $(seq 1 40); do
        st=$(docker exec "$PRIMARY" mongosh --port 27017 --quiet --eval "$STEADY_CHECK" 2>/dev/null || echo "ERR")
        if echo "$st" | grep -q STEADY; then echo "  steady after ${i}s"; break; fi
        sleep 1
        [ "$i" = 40 ] && echo "  WARNING: not steady after 40s ($st)"
    done
fi
sleep 3   # extra stability margin before the window opens
echo "=== [apply] cluster ready ==="
