#!/bin/bash
# run.sh — Build and run CometBFT round-2 (BFT) trace scenarios.
#
# One-command pipeline:
#   1. apply.sh — install instrumentation patches into the artifact
#   2. go test — exercise consensus + Byzantine harness paths
#   3. preprocess_trace.py — map hex addresses to TLA+ server IDs
#
# Output traces are written to .specula-output/traces/*.ndjson (raw) and
# *_mapped.ndjson (post-processing).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT_DIR="$(cd "$SCRIPT_DIR/../../artifact/cometbft" && pwd)"
TRACE_DIR="$SCRIPT_DIR/../traces"

mkdir -p "$TRACE_DIR"
export TRACE_DIR

export PATH=/usr/local/go/bin:$HOME/go/bin:/usr/bin:$PATH

echo "==> Applying instrumentation"
bash "$SCRIPT_DIR/apply.sh"

echo "==> Building consensus package"
cd "$ARTIFACT_DIR"
timeout 300 go build ./consensus/... 1>/dev/null

# Clean go test cache so test bodies run again (env-var changes don't
# invalidate cache, so cached PASS would skip writing trace files).
go clean -testcache

echo "==> Running trace scenarios"
SCENARIOS=(
  BasicConsensus
  TimeoutPropose
  LockAndRelock
  Equivocation
  ByzAmnesia
  VEReuse
  LunaticFork
  ProposerExclude
  EvidenceRace
  ByzProposer
)

# Clean prior traces.
rm -f "$TRACE_DIR"/*.ndjson 2>/dev/null || true

for s in "${SCENARIOS[@]}"; do
    echo "--- Scenario: $s"
    if timeout 180 go test -run "TestScenario${s}$" -timeout 120s ./consensus/ 2>&1 | tail -3; then
        echo "PASS: $s"
    else
        echo "FAIL: $s"
    fi
done

echo ""
echo "==> Raw traces:"
ls -la "$TRACE_DIR"/*.ndjson 2>/dev/null || echo "(no traces found)"

echo ""
echo "==> Post-processing traces (hex -> sN, hash -> vN)"
for f in "$TRACE_DIR"/*.ndjson; do
    [ -e "$f" ] || continue
    base="${f%.ndjson}"
    case "$f" in
        *_mapped.ndjson) continue ;;
    esac
    python3 "$SCRIPT_DIR/preprocess_trace.py" "$f" "${base}_mapped.ndjson"
done

echo ""
echo "==> Final trace file summary:"
for f in "$TRACE_DIR"/*_mapped.ndjson; do
    [ -e "$f" ] || continue
    n=$(wc -l < "$f")
    events=$(awk -F'"name":"' '{print $2}' "$f" | awk -F'"' '{print $1}' | sort -u | paste -sd ',' -)
    echo "  $(basename "$f"): $n lines"
    echo "    events: $events"
done

echo "Done."
