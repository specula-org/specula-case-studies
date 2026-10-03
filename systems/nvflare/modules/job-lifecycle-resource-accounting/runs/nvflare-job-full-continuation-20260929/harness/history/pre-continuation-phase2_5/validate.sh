#!/bin/bash
# Quick TLC trace validation of one or more NDJSON traces against spec/Trace.tla + spec/Trace.cfg.
#   bash harness/validate.sh traces/<name>.ndjson [more traces...]
# Runs TLC directly with a -metadir inside harness/build (the shared /tmp/tlc_validation path is not writable here).
# Resource bounds: one TLC at a time, 1 worker, -Xmx4g (well inside the 64 GiB / 16-worker ceiling).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SPEC_DIR="$OUT_DIR/spec"
LIB="${SPECULA_LIB:-/home/experiment/repos/specula/lib}"
TLA_JAR="${TLA_JAR:-$LIB/tla2tools.jar}"
CM_JAR="${CM_JAR:-$LIB/CommunityModules-deps.jar}"
META="$SCRIPT_DIR/build/tlc-meta"
LOGS="$SCRIPT_DIR/build/validation-logs"
TTRACE="$SCRIPT_DIR/build/tlc-ttrace"   # counterexample trace-explorer specs (kept out of spec/)
mkdir -p "$META" "$LOGS" "$TTRACE"

status=0
for t in "$@"; do
    tr="$(cd "$(dirname "$t")" && pwd)/$(basename "$t")"
    name="$(basename "$t" .ndjson)"
    log="$LOGS/$name.log"
    (cd "$SPEC_DIR" && JSON="$tr" timeout 1800 java -XX:+UseParallelGC -Xmx4g \
        -cp "$TLA_JAR:$CM_JAR" tlc2.TLC -config Trace.cfg Trace.tla \
        -metadir "$META/$name-$$" -teSpecOutDir "$TTRACE" -workers 1 -cleanup > "$log" 2>&1)
    rc=$?
    if grep -q "Model checking completed. No error has been found" "$log"; then
        echo "PASS  $name  ($(grep -m1 'states generated' "$log" | sed 's/^ *//'))"
    else
        echo "FAIL  $name  (rc=$rc, log: $log)"
        grep -E "Error:|violated|is not|Temporal properties|Assumption|Exception" "$log" | head -5 | sed 's/^/      /'
        status=1
    fi
done
exit $status
