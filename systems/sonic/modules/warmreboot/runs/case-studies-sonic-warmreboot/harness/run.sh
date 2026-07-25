#!/bin/bash
# Run SONiC Warm Reboot trace generation harness.
#
# Produces NDJSON trace files in traces/ for TLA+ trace validation.
#
# Usage:
#   cd .specula-output && bash harness/run.sh
#
# Scenarios:
#   1. happy_path        — Full warm reboot with successful reconciliation
#   2. toctou_race       — Family 2: Events arrive after READY reply
#   3. apply_view_fail   — Family 3: APPLY_VIEW Stage 2 failure
#   4. timer_race        — Family 4: Timer fires before all entries replayed
#   5. ordering_violation— Family 1: vxlanmgrd reconciles prematurely

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_SRC="$SCRIPT_DIR/src"
SPECULA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TRACE_DIR="$SPECULA_DIR/traces"

echo "============================================"
echo "  SONiC Warm Reboot — Trace Harness"
echo "============================================"
echo ""

# Step 1: Apply instrumentation (Python driver, no source mods needed)
echo "--- Step 1: Apply instrumentation ---"
bash "$SCRIPT_DIR/apply.sh"
echo ""

# Step 2: Clean previous traces
echo "--- Step 2: Clean previous traces ---"
rm -f "$TRACE_DIR"/*.ndjson
mkdir -p "$TRACE_DIR"
echo "  Cleaned $TRACE_DIR"
echo ""

# Step 3: Run test scenarios
echo "--- Step 3: Run test scenarios ---"
cd "$HARNESS_SRC"
python3 test_scenarios.py
echo ""

# Step 4: Report trace coverage
echo "--- Step 4: Trace file summary ---"
total_lines=0
for f in "$TRACE_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        name=$(basename "$f")
        lines=$(wc -l < "$f")
        trace_lines=$(grep -c '"tag":"trace"' "$f" || true)
        total_lines=$((total_lines + trace_lines))
        echo "  $name: $lines lines ($trace_lines trace events)"
    fi
done
echo ""
echo "  Total trace events: $total_lines"
echo ""

# Step 5: Verify trace format
echo "--- Step 5: Trace format verification ---"
errors=0
for f in "$TRACE_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        name=$(basename "$f")
        # Check each line is valid JSON
        if python3 -c "
import json, sys
fname = '$name'
with open('$f') as fh:
    for i, line in enumerate(fh, 1):
        try:
            obj = json.loads(line)
            if obj.get('tag') == 'trace':
                assert 'event' in obj, f'line {i}: missing event'
                assert 'name' in obj['event'], f'line {i}: missing event.name'
                assert 'component' in obj['event'], f'line {i}: missing event.component'
                assert 'state' in obj['event'], f'line {i}: missing event.state'
        except (json.JSONDecodeError, AssertionError) as e:
            print(f'  {fname} line {i}: {e}', file=sys.stderr)
            sys.exit(1)
" 2>&1; then
            echo "  $name: VALID"
        else
            echo "  $name: INVALID"
            errors=$((errors + 1))
        fi
    fi
done
echo ""

# Step 6: Check event type coverage
echo "--- Step 6: Event type coverage ---"
expected_events=(
    "StartWarmReboot"
    "CompleteSanityChecks"
    "ComponentReceiveFreeze"
    "ComponentQuiesce"
    "OrchCheckReady"
    "OrchSendReadyReply"
    "EventArrivalAfterReady"
    "OrchDrainRingBuffer"
    "OrchFreeze"
    "EnterCheckpointPhase"
    "ComponentCheckpoint"
    "EnterRebootPhase"
    "SystemReboot"
    "OrchWarmRestore"
    "OrchSendApplyView"
    "SyncdReceiveInitView"
    "ApplyViewStage1"
    "ApplyViewStage2"
    "ApplyViewComplete"
    "ApplyViewStage2Fail"
    "OrchReconcileComplete"
    "ComponentStartReconcileTimer"
    "ComponentReadTable"
    "ReplayEntry"
    "ReconcileTimerFire"
    "ReconcileComponent"
    "ReconcileComponentWithoutTimer"
)
missing=0
for event in "${expected_events[@]}"; do
    count=$(grep -r "\"$event\"" "$TRACE_DIR"/*.ndjson 2>/dev/null | wc -l || echo 0)
    if [ "$count" -eq 0 ]; then
        echo "  MISSING: $event"
        missing=$((missing + 1))
    else
        echo "  OK: $event ($count occurrences)"
    fi
done
echo ""
echo "  Coverage: $((${#expected_events[@]} - missing))/${#expected_events[@]} event types"
echo ""

# Step 7: Check timestamps are real (not sequential integers)
echo "--- Step 7: Timestamp validation ---"
for f in "$TRACE_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        name=$(basename "$f")
        # Check that timestamps contain 'T' (ISO 8601)
        bad=$(grep '"tag":"trace"' "$f" | grep -cv '"timestamp":"[^"]*T' || true)
        if [ "$bad" -eq 0 ]; then
            echo "  $name: timestamps OK (ISO 8601)"
        else
            echo "  $name: $bad lines with bad timestamps"
            errors=$((errors + 1))
        fi
    fi
done
echo ""

if [ "$errors" -gt 0 ]; then
    echo "ERRORS: $errors format issues found"
    exit 1
fi

echo "============================================"
echo "  Traces ready for validation"
echo "  Directory: $TRACE_DIR"
echo "============================================"
