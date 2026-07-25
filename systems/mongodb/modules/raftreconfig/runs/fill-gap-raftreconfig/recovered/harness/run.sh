#!/bin/bash
# run.sh — one-command MongoRaftReconfig trace harness.
#
#   cd .specula-output && bash harness/run.sh            # all scenarios
#   cd .specula-output && bash harness/run.sh baseline   # one scenario
#
# For each scenario: bring up a FRESH replica set (apply.sh), open a trace window AFTER
# the bootstrap election settles (so the window matches Trace.tla's genesis TraceInit),
# start per-node status pollers, run the scenario via mongosh, extract each node's
# logv2 log, and parse logs+polls into one NDJSON trace.
#
# Prerequisites: docker, docker compose, python3.  Each scenario ~60-90s.

set -uo pipefail   # NOT -e: one scenario failing must not abort the rest

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/src"
TRACES="$(cd "$SCRIPT_DIR/.." && pwd)/traces"
LOGS="$SCRIPT_DIR/logs"
STATUS="$SCRIPT_DIR/status"
CONTAINERS="rcfg1 rcfg2 rcfg3 rcfg4 rcfg5"
RS_URI="mongodb://rcfg1:27017,rcfg2:27017,rcfg3:27017,rcfg4:27017,rcfg5:27017/admin?replicaSet=rs0"

# which container is currently the writable primary (mapped to n1 by the parser)?
detect_primary() {
    for c in $CONTAINERS; do
        if docker exec "$c" mongosh --port 27017 --quiet \
             --eval 'db.adminCommand({hello:1}).isWritablePrimary' 2>/dev/null | grep -q true; then
            echo "$c"; return 0
        fi
    done
    echo ""
}
PYTHON="${PYTHON:-python3}"
WANT="${1:-all}"

mkdir -p "$TRACES" "$LOGS" "$STATUS"

now_iso() { date -u +"%Y-%m-%dT%H:%M:%S.%3N+00:00"; }

run_scenario() {
    local name="$1" setup="$2" js="$3" propagate="${4:-6}" mode="${5:-normal}"
    echo ""
    echo "############################################################"
    echo "# SCENARIO: $name   (setup=$setup, js=$js)"
    echo "############################################################"

    bash "$SCRIPT_DIR/apply.sh" "$setup"

    rm -rf "${LOGS:?}/$name" "${STATUS:?}/$name"
    mkdir -p "$LOGS/$name" "$STATUS/$name"

    # genesis primary at window open -> mapped to n1 by the parser
    local primary
    primary="$(detect_primary)"
    echo ">>> genesis primary = ${primary:-<none>} (-> n1)"

    local wstart wend
    wstart="$(now_iso)"

    # start per-node self-status pollers (named by container; parser maps to nid)
    local pids=()
    for c in $CONTAINERS; do
        docker exec "$c" mongosh --port 27017 --quiet --file /scripts/poller.js \
            > "$STATUS/$name/status_$c.ndjson" 2>/dev/null &
        pids+=($!)
    done
    sleep 1

    echo ">>> running scenario script"
    timeout 180 docker exec rcfg1 mongosh "$RS_URI" --quiet --file "/scripts/$js" \
        || echo "  (scenario $name exited non-zero or timed out — continuing)"

    # Partition mode: isolate the genesis primary so the majority elects a new primary
    # in a higher term; on reconnect the old primary takes the heartbeat-driven
    # stepdown (LOGV2 21475 -> CompleteStepDown). Host-level docker network op.
    if [ "$mode" = "partition" ] && [ -n "$primary" ]; then
        local net
        net="$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$primary" 2>/dev/null | awk '{print $1}')"
        echo ">>> partitioning $primary off $net (majority elects a new primary in term 2)"
        docker network disconnect "$net" "$primary" 2>/dev/null || true
        sleep 15
        echo ">>> reconnecting $primary (expect heartbeat-driven StepDown)"
        docker network connect "$net" "$primary" 2>/dev/null || true
    fi

    echo ">>> waiting ${propagate}s for heartbeat config propagation"
    sleep "$propagate"
    wend="$(now_iso)"

    # stop pollers
    for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
    wait 2>/dev/null || true

    # extract each node's logv2 log
    for c in $CONTAINERS; do
        docker logs "$c" > "$LOGS/$name/$c.log" 2>/dev/null || true
    done

    # parse logs + polls -> NDJSON trace (genesis primary -> n1)
    "$PYTHON" "$SRC/parse_logs.py" \
        --logs-dir "$LOGS/$name" --status-dir "$STATUS/$name" \
        --primary "$primary" --after "$wstart" --before "$wend" \
        --out "$TRACES/$name.ndjson"
    echo "  window: $wstart -> $wend"
}

echo "============================================================"
echo "  MongoRaftReconfig Trace Harness (log parsing, 5-node RS)"
echo "============================================================"

if [ "$WANT" = "all" ] || [ "$WANT" = "baseline" ]; then
    run_scenario "baseline_reconfig" "setup_genesis.js" "test_baseline_reconfig.js" 6
fi
if [ "$WANT" = "all" ] || [ "$WANT" = "family1" ]; then
    run_scenario "family1_term"      "setup_genesis.js" "test_family1_term.js"      8 partition
fi
if [ "$WANT" = "all" ] || [ "$WANT" = "family2" ]; then
    run_scenario "family2_commit"    "setup_genesis.js" "test_family2_commit.js"    8
fi
if [ "$WANT" = "all" ] || [ "$WANT" = "family3" ]; then
    run_scenario "family3_arbiter"   "setup_psa.js"     "test_family3_arbiter.js"   6
fi

echo ""
echo ">>> tearing down cluster"
docker compose -f "$SRC/docker-compose.yml" down -v 2>/dev/null || true

# ---------------------------------------------------------------------------
# Report + coverage
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  Trace collection results"
echo "============================================================"
for f in "$TRACES"/*.ndjson; do
    [ -f "$f" ] || continue
    echo "  $(basename "$f"): $(wc -l < "$f") events"
done

echo ""
echo ">>> Event-type coverage + JSON sanity"
"$PYTHON" - "$TRACES" <<'PY'
import json, os, sys
traces_dir = sys.argv[1]
EXPECTED = ["BecomeLeader","CompletePrimaryDrain","StepUpReconfig",
            "ConfigInstallCmd","ConfigInstallHB","UpdateTerm","StepDown"]
seen = set(); bad = 0; total = 0
for fn in sorted(os.listdir(traces_dir)):
    if not fn.endswith(".ndjson"): continue
    with open(os.path.join(traces_dir, fn)) as fh:
        for i, line in enumerate(fh, 1):
            line = line.strip()
            if not line: continue
            total += 1
            try:
                d = json.loads(line)
                assert d.get("tag") == "trace"
                ev = d["event"]; seen.add(ev["name"])
                assert ev["nid"] and "state" in ev
            except Exception as e:
                bad += 1
                if bad <= 5: print("    %s:%d bad line: %s" % (fn, i, e))
print("  total events: %d   malformed: %d" % (total, bad))
print("  event types seen: %s" % ", ".join(sorted(seen)))
missing = [e for e in EXPECTED if e not in seen]
print("  MISSING types : %s" % (", ".join(missing) if missing else "(none — full coverage)"))
PY

echo ""
echo "============================================================"
echo "  Done. Traces in: $TRACES"
echo "  Quick validation (run separately):"
echo "    run_trace_validation(spec_file='Trace.tla', config_file='Trace.cfg',"
echo "      trace_file='../traces/baseline_reconfig.ndjson', work_dir='spec/')"
echo "============================================================"
