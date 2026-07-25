#!/usr/bin/env bash
# Build and run crossbeam-epoch TLA+ trace harness.
#
# Usage: cd case-studies/crossbeam-epoch && bash harness/run.sh
#
# This script:
#   1. Applies instrumentation (harness/apply.sh)
#   2. Builds the instrumented crate
#   3. Runs each test scenario with a separate trace file
#   4. Generates per-trace .cfg files with thread/node mappings
#   5. Reports trace statistics

set -euo pipefail

CASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACT_DIR="$CASE_DIR/artifact/crossbeam"
TRACES_DIR="$CASE_DIR/traces"
HARNESS_DIR="$CASE_DIR/harness"

# Scenarios to run (test function name -> trace file name)
SCENARIOS=(
    "tla_test_basic_pin:basic_pin"
    "tla_test_nested_pin:nested_pin"
    "tla_test_epoch_advance:epoch_advance"
    "tla_test_concurrent_epoch:concurrent_epoch"
    "tla_test_finalize:finalize"
)

echo "=== crossbeam-epoch Trace Harness ==="
echo ""

# Step 1: Apply instrumentation
echo "--- Step 1: Apply instrumentation ---"
bash "$HARNESS_DIR/apply.sh"
echo ""

# Step 2: Build
echo "--- Step 2: Build instrumented crate ---"
(cd "$ARTIFACT_DIR" && cargo test -p crossbeam-epoch --test tla_trace_scenarios --no-run 2>&1) | tee "$TRACES_DIR/build.log"
echo "Build OK"
echo ""

# Step 3: Run each scenario
echo "--- Step 3: Run test scenarios ---"
mkdir -p "$TRACES_DIR"

for entry in "${SCENARIOS[@]}"; do
    test_name="${entry%%:*}"
    trace_name="${entry##*:}"
    trace_file="$TRACES_DIR/${trace_name}.ndjson"

    echo -n "  Running $test_name -> $trace_name.ndjson ... "

    (cd "$ARTIFACT_DIR" && \
    CROSSBEAM_TRACE_FILE="$trace_file" \
    cargo test -p crossbeam-epoch \
        --test tla_trace_scenarios \
        "$test_name" \
        -- --nocapture --test-threads=1) \
        > "$TRACES_DIR/${trace_name}.test.log" 2>&1 \
    || {
        echo "FAILED (see $TRACES_DIR/${trace_name}.test.log)"
        continue
    }

    if [ -f "$trace_file" ]; then
        lines=$(wc -l < "$trace_file")
        echo "OK ($lines events)"
    else
        echo "FAILED (no trace file produced)"
    fi
done
echo ""

# Step 4: Generate per-trace .cfg files with thread/node mappings
echo "--- Step 4: Generate trace configs ---"

generate_cfg() {
    local trace_file="$1"
    local cfg_file="$2"
    local trace_name="$3"

    if [ ! -f "$trace_file" ]; then
        return
    fi

    # Extract unique thread IDs and node IDs from the trace
    local info
    info=$(python3 -c "
import json, sys
threads = set()
nodes = set()
with open('$trace_file') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            if 'thread' in obj:
                threads.add(obj['thread'])
            if 'node' in obj:
                nodes.add(obj['node'])
            if 'qHead' in obj:
                nodes.add(obj['qHead'])
            if 'qTail' in obj:
                nodes.add(obj['qTail'])
        except json.JSONDecodeError:
            pass
# Always include N0 as sentinel
nodes.add('N0')
# Ensure at least a few extra node constants
for i in range(4):
    nodes.add('N' + str(i))
print('THREADS=' + ','.join('\"' + t + '\"' for t in sorted(threads)))
print('NODES=' + ','.join('\"' + n + '\"' for n in sorted(nodes)))
" 2>/dev/null)

    if [ -z "$info" ]; then
        echo "  Warning: no threads found in $trace_name"
        return
    fi

    local thread_set node_set
    thread_set=$(echo "$info" | grep '^THREADS=' | sed 's/^THREADS=//')
    node_set=$(echo "$info" | grep '^NODES=' | sed 's/^NODES=//')

    cat > "$cfg_file" <<CFGEOF
\\* Auto-generated trace config for $trace_name

SPECIFICATION TraceSpec

CONSTANTS
    Nil = "Nil"
    Sentinel = "N0"
    Thread = {${thread_set}}
    Node = {${node_set}}

INVARIANTS
    TypeOK
    SafeReclamation
    PinnedConsistency

CFGEOF

    echo "  Generated $cfg_file"
}

for entry in "${SCENARIOS[@]}"; do
    trace_name="${entry##*:}"
    trace_file="$TRACES_DIR/${trace_name}.ndjson"
    cfg_file="$CASE_DIR/spec/Trace_${trace_name}.cfg"
    generate_cfg "$trace_file" "$cfg_file" "$trace_name"
done
echo ""

# Step 5: Summary
echo "--- Summary ---"
echo "Traces in: $TRACES_DIR/"
for entry in "${SCENARIOS[@]}"; do
    trace_name="${entry##*:}"
    trace_file="$TRACES_DIR/${trace_name}.ndjson"
    if [ -f "$trace_file" ]; then
        lines=$(wc -l < "$trace_file")
        printf "  %-25s %5d events\n" "${trace_name}.ndjson" "$lines"
    else
        printf "  %-25s %s\n" "${trace_name}.ndjson" "MISSING"
    fi
done
echo ""
echo "To validate a trace:"
echo "  cd spec && java -jar ../../lib/tla2tools.jar -config Trace_basic_pin.cfg Trace -DJSON=../traces/basic_pin.ndjson"
echo ""
echo "=== Done ==="
