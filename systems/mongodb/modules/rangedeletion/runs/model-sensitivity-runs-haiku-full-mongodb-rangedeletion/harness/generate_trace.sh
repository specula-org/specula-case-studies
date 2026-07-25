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
