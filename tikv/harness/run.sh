#!/usr/bin/env bash
# End-to-end: apply instrumentation, build, run tests, collect traces.
#
# Usage: cd case-studies/tikv && bash harness/run.sh
#
# Outputs:
#   traces/basic_consensus.ndjson
#   traces/prevote_election.ndjson
#   traces/leader_transfer.ndjson

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT="$CASE_DIR/artifact/raft-rs"
TRACES_DIR="$CASE_DIR/traces"

# Ensure Rust toolchain is available
if ! command -v cargo &>/dev/null; then
    if [ -f "$HOME/.cargo/env" ]; then
        source "$HOME/.cargo/env"
    else
        echo "ERROR: cargo not found. Install Rust: https://rustup.rs"
        exit 1
    fi
fi

# Step 1: Apply instrumentation
echo "=== Step 1: Applying instrumentation ==="
bash "$SCRIPT_DIR/apply.sh"

# Step 2: Build
echo ""
echo "=== Step 2: Building ==="
cd "$ARTIFACT"
cargo build -p harness --tests 2>&1 | tail -5
echo "Build successful."

# Step 3: Run tests and collect traces
echo ""
echo "=== Step 3: Running test scenarios ==="
mkdir -p "$TRACES_DIR"

SCENARIOS=("tla_basic_consensus" "tla_prevote_election" "tla_leader_transfer")
TRACE_NAMES=("basic_consensus" "prevote_election" "leader_transfer")

for i in "${!SCENARIOS[@]}"; do
    scenario="${SCENARIOS[$i]}"
    trace_name="${TRACE_NAMES[$i]}"
    trace_file="$TRACES_DIR/${trace_name}.ndjson"

    echo ""
    echo "--- Running $scenario ---"
    RAFT_TRACE_FILE="$trace_file" \
        cargo test -p harness --test tla_trace_test "$scenario" \
        -- --nocapture --test-threads=1 2>&1 | tail -5

    if [ -f "$trace_file" ]; then
        lines=$(wc -l < "$trace_file")
        echo "  -> $trace_file: $lines lines"
    else
        echo "  -> WARNING: $trace_file not created"
    fi
done

# Step 4: Verify traces
echo ""
echo "=== Step 4: Trace verification ==="
all_ok=true
for trace_name in "${TRACE_NAMES[@]}"; do
    trace_file="$TRACES_DIR/${trace_name}.ndjson"
    if [ ! -f "$trace_file" ]; then
        echo "MISSING: $trace_file"
        all_ok=false
        continue
    fi

    lines=$(wc -l < "$trace_file")
    if [ "$lines" -eq 0 ]; then
        echo "EMPTY: $trace_file"
        all_ok=false
        continue
    fi

    # Verify each line is valid JSON
    if python3 -c "
import json, sys
with open('$trace_file') as f:
    for i, line in enumerate(f, 1):
        try:
            obj = json.loads(line)
            if 'event' not in obj:
                print(f'Line {i}: missing event field', file=sys.stderr)
                sys.exit(1)
            if 'node' not in obj:
                print(f'Line {i}: missing node field', file=sys.stderr)
                sys.exit(1)
        except json.JSONDecodeError as e:
            print(f'Line {i}: invalid JSON: {e}', file=sys.stderr)
            sys.exit(1)
" 2>&1; then
        echo "OK: $trace_file ($lines lines)"
        # Show first 3 events
        head -3 "$trace_file" | python3 -c "
import json, sys
for line in sys.stdin:
    obj = json.loads(line)
    print(f'    event={obj[\"event\"]:40s} node={obj[\"node\"]}')
" 2>/dev/null || true
    else
        echo "INVALID: $trace_file"
        all_ok=false
    fi
done

echo ""
if $all_ok; then
    echo "=== All traces collected successfully ==="
else
    echo "=== Some traces had issues ==="
    exit 1
fi
