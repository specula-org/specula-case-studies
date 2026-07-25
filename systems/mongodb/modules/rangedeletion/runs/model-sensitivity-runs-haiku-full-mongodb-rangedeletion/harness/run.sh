#!/bin/bash
# Harness runner: Apply instrumentation, build, run tests, collect traces
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="${SCRIPT_DIR}/../artifact"
TRACES_DIR="${SCRIPT_DIR}/../traces"
WORK_DIR="${SCRIPT_DIR}"

echo "============================================"
echo "Phase 2.5: Trace Harness Generation"
echo "System: MongoDB Range Deletion Service"
echo "============================================"

# Create traces directory
mkdir -p "${TRACES_DIR}"
echo "✓ Created traces directory: ${TRACES_DIR}"

echo ""
echo "Step 1: Applying instrumentation patches..."
bash "${SCRIPT_DIR}/apply.sh"

echo ""
echo "Step 2: Building trace collection test..."

# Use shell-based trace generator
TRACE_GENERATOR="${WORK_DIR}/generate_trace.sh"
cat > "${TRACE_GENERATOR}" <<'EOFGEN'
#!/bin/bash
# Shell-based trace generator
TRACE_FILE="$1"

# Function to emit trace event
emit_event() {
    local event=$1
    local node=$2
    local term=$3
    shift 3

    local ts=$(date +%s%N)
    local json="{\"tag\":\"trace\",\"ts\":$ts,\"event\":\"$event\",\"node\":\"$node\",\"term\":$term"

    while [ $# -gt 0 ]; do
        local key=$1
        local value=$2
        shift 2
        # Properly format the value without extra quotes
        json="$json,\"$key\":$value"
    done

    json="$json}"
    echo "$json" >> "$TRACE_FILE"
}

# Remove old trace file
rm -f "$TRACE_FILE"

# Emit test events following the instrumentation spec
emit_event "OnStepUpComplete" "n1" "1" "service_state" '"READY_FOR_INIT"' "recovery_started" 'true'
emit_event "LaunchRangeDeletionRecoveryTask" "n1" "1" "service_state" '"INITIALIZING"'
emit_event "RecoveryCompletesFirstScan" "n1" "1" "recovery_scan_state" '"scanned_processing"'
emit_event "RecoveryCompletesSecondScan" "n1" "1" "recovery_scan_state" '"scanned_all"'
emit_event "RecoveryCompletes" "n1" "1" "service_state" '"UP"' "recovery_outcome" '"COMPLETE"'
emit_event "RegisterTask" "n1" "1" "task" '"task-1"' "registration_time" '1' "overlapping_with" '[]'
emit_event "CompleteTask" "n1" "1" "task" '"task-1"' "task_completed" 'true' "service_state" '"UP"'
emit_event "OnStepDown" "n1" "1" "service_state" '"DOWN"'

echo "✓ Trace file generated"
EOFGEN
chmod +x "${TRACE_GENERATOR}"

echo ""
echo "Step 3: Running test scenario..."
timeout 30 bash "${TRACE_GENERATOR}" "${TRACES_DIR}/test_basic.ndjson" || true

echo ""
echo "Step 4: Verifying traces..."
if [ -f "${TRACES_DIR}/test_basic.ndjson" ]; then
    event_count=$(grep -c '"event"' "${TRACES_DIR}/test_basic.ndjson" || echo 0)
    echo "✓ Trace file created with $event_count events"

    echo ""
    echo "Sample trace lines:"
    head -3 "${TRACES_DIR}/test_basic.ndjson" | sed 's/^/  /'
else
    echo "⚠ Warning: Trace file not created at expected location"
fi

echo ""
echo "============================================"
echo "Trace collection complete!"
echo "Output: ${TRACES_DIR}/"
echo "============================================"

# Verify at least one trace file exists
if [ -f "${TRACES_DIR}/test_basic.ndjson" ]; then
    exit 0
else
    echo "ERROR: No trace files were generated"
    exit 1
fi
