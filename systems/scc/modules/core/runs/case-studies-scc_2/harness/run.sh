#!/usr/bin/env bash
# Apply instrumentation, build the trace driver, run all scenarios, merge per-
# thread NDJSON files into the JSON format expected by Trace.tla.
#
# Run from the case-studies/scc_2 root:
#     bash .specula-output/harness/run.sh

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$HARNESS_DIR/.." && pwd)"
ARTIFACT="$CASE_DIR/../artifact/scc"
RAW_DIR="$HARNESS_DIR/raw-traces"
OUT_DIR="$CASE_DIR/traces"
DRIVER_DIR="$HARNESS_DIR/src/trace_driver"

echo "================================================"
echo "  scc — TLA+ Trace Harness"
echo "================================================"
echo "Case dir:   $CASE_DIR"
echo "Artifact:   $ARTIFACT"
echo "Raw traces: $RAW_DIR"
echo "Output:     $OUT_DIR"
echo ""

# ---- Step 1: Apply instrumentation ----
bash "$HARNESS_DIR/apply.sh"

# ---- Step 2: Build the trace driver (release for fewer probe-effect cycles) ----
echo ""
echo "=== Building trace driver ==="
(cd "$DRIVER_DIR" && cargo build --release 2>&1 | tail -5)

# ---- Step 3: Run scenarios ----
echo ""
echo "=== Running scenarios ==="

mkdir -p "$RAW_DIR"
rm -f "$RAW_DIR"/*.ndjson

export SCC_TRACE_DIR="$RAW_DIR"
"$DRIVER_DIR/target/release/scc_trace_driver"

# ---- Step 4: Preprocess (merge per-thread NDJSON → single JSON per scenario) ----
echo ""
echo "=== Preprocessing ==="
mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR"/*.ndjson

python3 "$HARNESS_DIR/preprocess.py" "$RAW_DIR" "$OUT_DIR"

# ---- Step 5: Report ----
echo ""
echo "=== Trace summary ==="
for f in "$OUT_DIR"/*.ndjson; do
    [ -e "$f" ] || continue
    name=$(basename "$f" .ndjson)
    nthreads=$(python3 -c "import json,sys;d=json.load(open('$f'));print(len(d['threads']))")
    nevents=$(python3 -c "import json,sys;d=json.load(open('$f'));print(sum(len(v) for v in d['events'].values()))")
    echo "  $name: $nthreads threads, $nevents events"
done

echo ""
echo "================================================"
echo "  Done. JSON traces in $OUT_DIR/"
echo "================================================"
