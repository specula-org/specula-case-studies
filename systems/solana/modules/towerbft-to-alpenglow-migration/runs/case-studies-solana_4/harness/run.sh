#!/usr/bin/env bash
# Apply instrumentation, build harness scenarios, run them, and collect traces.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_ROOT="$(cd "$HARNESS_DIR/.." && pwd)"
ARTIFACT="$(cd "$OUTPUT_ROOT/../artifact/agave" && pwd)"
TRACES_DIR="$OUTPUT_ROOT/traces"
SCENARIOS_DIR="$HARNESS_DIR/scenarios"

echo "[run] HARNESS_DIR=$HARNESS_DIR"
echo "[run] ARTIFACT=$ARTIFACT"
echo "[run] TRACES_DIR=$TRACES_DIR"

bash "$HARNESS_DIR/apply.sh"

mkdir -p "$TRACES_DIR"

echo "[run] Building scenarios crate (votor-messages + harness binaries)..."
timeout 600 cargo build --manifest-path "$SCENARIOS_DIR/Cargo.toml" \
    --bins --release 2>&1 | tail -40

run_scenario() {
    local name="$1"
    local bin="$SCENARIOS_DIR/target/release/$name"
    local out="$TRACES_DIR/$name.ndjson"
    if [[ ! -x "$bin" ]]; then
        echo "[run] ERROR: binary $bin not found"
        return 1
    fi
    echo "[run] Scenario $name -> $out"
    rm -f "$out"
    TLA_TRACE_FILE="$out" timeout 60 "$bin"
    local nlines
    nlines=$(wc -l <"$out" || echo 0)
    echo "[run]   $out: $nlines lines"
}

run_scenario happy-path
run_scenario startup-poh-race
run_scenario panic-paths

echo "[run] Trace generation complete."
echo "[run] Summary:"
for f in "$TRACES_DIR"/*.ndjson; do
    echo "  $f $(wc -l <"$f") lines"
done
