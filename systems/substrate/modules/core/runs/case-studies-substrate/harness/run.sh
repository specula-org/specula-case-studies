#!/bin/bash
# Run Substrate GRANDPA trace collection
# Generates real NDJSON traces from instrumented tests.
#
# Prerequisites:
#   - Rust toolchain (stable 1.93+)
#   - wasm32-unknown-unknown target installed
#
# Usage:
#   cd case-studies/substrate && bash harness/run.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(dirname "$SCRIPT_DIR")"
ARTIFACT_DIR="$CASE_DIR/artifact/substrate"
TRACES_DIR="$CASE_DIR/traces"

mkdir -p "$TRACES_DIR"
cd "$ARTIFACT_DIR"

echo "=== Building sc-consensus-grandpa tests ==="
cargo test -p sc-consensus-grandpa --no-run 2>&1 | tail -3

echo ""
echo "=== Collecting basic finalization trace ==="
GRANDPA_TRACE_FILE="$TRACES_DIR/basic_finalization.ndjson" \
  cargo test -p sc-consensus-grandpa -- tests::finalize_3_voters_no_observers --exact 2>&1 | tail -3
echo "  -> $(wc -l < "$TRACES_DIR/basic_finalization.ndjson") events"

echo ""
echo "=== Collecting authority change trace ==="
GRANDPA_TRACE_FILE="$TRACES_DIR/authority_change.ndjson" \
  cargo test -p sc-consensus-grandpa -- tests::transition_3_voters_twice_1_full_observer --exact 2>&1 | tail -3
echo "  -> $(wc -l < "$TRACES_DIR/authority_change.ndjson") events"

echo ""
echo "=== Collecting forced change trace ==="
GRANDPA_TRACE_FILE="$TRACES_DIR/forced_change.ndjson" \
  cargo test -p sc-consensus-grandpa -- tests::force_change_to_new_set --exact 2>&1 | tail -3
echo "  -> $(wc -l < "$TRACES_DIR/forced_change.ndjson") events"

echo ""
echo "=== Validating traces ==="
for trace in "$TRACES_DIR"/*.ndjson; do
  name="$(basename "$trace")"
  count=$(wc -l < "$trace")
  tags=$(head -3 "$trace" | python3 -c "import sys,json; print(','.join(json.loads(l).get('tag','MISSING') for l in sys.stdin))" 2>/dev/null || echo "PARSE_ERROR")
  echo "  $name: $count events, tags=[$tags]"
done

echo ""
echo "=== Done ==="
