#!/usr/bin/env bash
# run.sh — apply instrumentation, build sofa-jraft, run trace scenarios, collect NDJSON.
#
# Usage:
#   cd <this harness directory>
#   ./run.sh [ARTIFACT_DIR] [TRACES_DIR]
#
# Produces:
#   $TRACES_DIR/scenario1.ndjson   — normal election + replication
#   $TRACES_DIR/scenario2.ndjson   — leader crash + re-election + restart

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="${1:-"$SCRIPT_DIR/../artifact/sofa-jraft"}"
TRACES_DIR="${2:-"$SCRIPT_DIR/../traces"}"

if [ ! -d "$ARTIFACT_DIR" ]; then
    echo "ERROR: artifact directory not found: $ARTIFACT_DIR" >&2
    exit 1
fi

mkdir -p "$TRACES_DIR"

# ── Step 1: Apply instrumentation ────────────────────────────────────────────
echo "[run] Applying instrumentation..."
"$SCRIPT_DIR/apply.sh" "$ARTIFACT_DIR"

# ── Step 2: Build ─────────────────────────────────────────────────────────────
echo "[run] Building sofa-jraft (tests skipped)..."
cd "$ARTIFACT_DIR"
mvn install -DskipTests -q 2>&1 | tail -5

# ── Step 3: Run trace scenarios ───────────────────────────────────────────────
TRACES_ABS="$(cd "$TRACES_DIR" && pwd)"

echo "[run] Running Scenario 1: normal election + replication..."
mvn -pl jraft-core test \
    -Dtest=TlaTraceScenario1Test \
    -Dtla.trace.dir="$TRACES_ABS" \
    -q 2>&1 | tail -10

echo "[run] Running Scenario 2: leader crash + re-election..."
mvn -pl jraft-core test \
    -Dtest=TlaTraceScenario2Test \
    -Dtla.trace.dir="$TRACES_ABS" \
    -q 2>&1 | tail -10

# ── Step 4: Verify traces ─────────────────────────────────────────────────────
echo "[run] Verifying traces..."
for f in "$TRACES_ABS"/scenario*.ndjson; do
    count=$(wc -l < "$f")
    echo "  $(basename "$f"): $count events"
    if [ "$count" -lt 20 ]; then
        echo "WARNING: $f has fewer than 20 events (got $count)" >&2
    fi
done

echo "[run] Traces written to: $TRACES_ABS"
echo "[run] Done."
