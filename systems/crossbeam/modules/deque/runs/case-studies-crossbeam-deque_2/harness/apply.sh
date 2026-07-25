#!/usr/bin/env bash
# Apply trace instrumentation to the crossbeam-deque artifact.
# Idempotent: rerunning is safe, the patch script no-ops if already applied.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="$(cd "$HARNESS_DIR/../../artifact/crossbeam" && pwd)"
DEQUE_SRC="$ARTIFACT_DIR/crossbeam-deque/src"
DEQUE_TESTS="$ARTIFACT_DIR/crossbeam-deque/tests"

echo "[apply] artifact: $ARTIFACT_DIR"

# 1. Clean any previous instrumentation so the patch script is idempotent.
( cd "$ARTIFACT_DIR" && git checkout -- crossbeam-deque/src/lib.rs crossbeam-deque/src/deque.rs )
rm -f "$DEQUE_SRC/tla_trace.rs"
rm -f "$DEQUE_TESTS/trace_scenarios.rs"

# 2. Copy the trace module + the test scenarios into the crate.
cp "$HARNESS_DIR/src/tla_trace.rs"        "$DEQUE_SRC/tla_trace.rs"
cp "$HARNESS_DIR/src/trace_scenarios.rs"  "$DEQUE_TESTS/trace_scenarios.rs"

# 3. Apply source patches (lib.rs adds `pub mod tla_trace;`, deque.rs gets
#    the trace_emit calls at every instrumentation point).
python3 "$HARNESS_DIR/instrument.py" \
    "$DEQUE_SRC/lib.rs" \
    "$DEQUE_SRC/deque.rs"

echo "[apply] instrumentation applied."
