#!/bin/bash
# Build + run + collect traces for the aptosbft round-2 harness.
#
# Usage:
#   bash harness/run.sh
# or from .specula-output/:
#   bash harness/run.sh
#
# Produces:
#   traces/normal.ndjson
#   traces/timeout.ndjson
#   traces/opt.ndjson
#   traces/epoch_change.ndjson

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT_DIR="$(cd "$SCRIPT_DIR/../../artifact/aptos-core" && pwd)"
TRACES_DIR="$(cd "$SCRIPT_DIR/../traces" && pwd)"

# Ensure cargo is available.
if ! command -v cargo &>/dev/null; then
    if [ -f "$HOME/.cargo/env" ]; then
        # shellcheck disable=SC1091
        . "$HOME/.cargo/env"
    else
        echo "ERROR: cargo not found.  Install Rust first." >&2
        exit 1
    fi
fi

echo "=== aptosbft round-2 trace harness ==="
echo "artifact dir: $ARTIFACT_DIR"
echo "traces dir:   $TRACES_DIR"

# --- Apply instrumentation --------------------------------------------------
bash "$SCRIPT_DIR/apply.sh"

# --- Build the safety-rules test binary -------------------------------------
cd "$ARTIFACT_DIR"

echo ""
echo "--- cargo test --no-run -p aptos-safety-rules ---"
timeout 1200 cargo test \
    --no-run \
    -p aptos-safety-rules \
    --features testing \
    --tests \
    2>&1 | tail -40

# --- Run each scenario, one per trace file ----------------------------------
mkdir -p "$TRACES_DIR"

run_scenario() {
    local name="$1"
    local out="$TRACES_DIR/${name}.ndjson"
    echo ""
    echo "--- running tla_trace_${name}_flow → ${out} ---"
    rm -f "$out"
    TLA_TRACE_FILE="$out" \
        RUST_LOG=info \
        timeout 600 cargo test \
            -p aptos-safety-rules \
            --features testing \
            --tests \
            --no-fail-fast \
            -- "tla_trace_${name}_flow" \
            --nocapture \
            --test-threads=1 \
            2>&1 | tail -20 || true
    if [ -f "$out" ]; then
        local lines
        lines=$(wc -l < "$out")
        echo "    ✓ ${name}: ${lines} lines"
    else
        echo "    ✗ ${name}: no trace produced"
    fi
}

run_scenario normal
run_scenario timeout
run_scenario opt
run_scenario epoch_change

# --- Summary ----------------------------------------------------------------
echo ""
echo "=== Trace summary ==="
for f in "$TRACES_DIR"/*.ndjson; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    lines=$(wc -l < "$f")
    types=$(python3 -c "
import json, sys
seen = {}
for line in open(sys.argv[1]):
    try:
        rec = json.loads(line)
    except Exception:
        continue
    if rec.get('tag') != 'trace':
        continue
    name = rec.get('event', {}).get('name')
    seen[name] = seen.get(name, 0) + 1
print(', '.join(f'{k}={v}' for k, v in sorted(seen.items())))
" "$f" 2>/dev/null || echo "")
    echo "  $name ($lines lines): $types"
done

echo ""
echo "=== Done ==="
