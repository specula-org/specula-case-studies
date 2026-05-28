#!/usr/bin/env bash
# apply.sh — copy the Specula evidence trace harness into the cometbft artifact
# and patch the source files with trace-emit calls. Idempotent: re-running
# discards prior changes inside the evidence/ package and reapplies.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$SCRIPT_DIR"
ARTIFACT_DIR="${ARTIFACT_DIR:-/home/ubuntu/Specula/case-studies/cometbft/artifact/cometbft}"
EVIDENCE_DIR="$ARTIFACT_DIR/evidence"

echo "[apply] ARTIFACT_DIR=$ARTIFACT_DIR"
echo "[apply] HARNESS_DIR=$HARNESS_DIR"

if [[ ! -d "$EVIDENCE_DIR" ]]; then
  echo "[apply] error: evidence dir not found: $EVIDENCE_DIR" >&2
  exit 1
fi

# Discard any prior patches we may have applied to evidence/*.go (keep prior-pass
# instrumentation outside the evidence/ folder intact).
(cd "$ARTIFACT_DIR" && git checkout -- evidence/ 2>/dev/null || true)
# Drop any harness files left over from a previous run.
rm -f "$EVIDENCE_DIR/trace_tla.go" "$EVIDENCE_DIR/trace_tla_scenarios_test.go"

# Copy the harness sources into the evidence/ package.
cp "$HARNESS_DIR/src/trace_tla.go" "$EVIDENCE_DIR/trace_tla.go"
cp "$HARNESS_DIR/src/trace_tla_scenarios_test.go" "$EVIDENCE_DIR/trace_tla_scenarios_test.go"
echo "[apply] copied trace_tla.go and trace_tla_scenarios_test.go into $EVIDENCE_DIR"

# Patch evidence/pool.go using a Python helper. The helper is idempotent: it
# inserts marker-tagged trace calls and skips lines that already contain them.
python3 "$HARNESS_DIR/patch_pool.py" "$EVIDENCE_DIR/pool.go"
echo "[apply] patched pool.go"

echo "[apply] done."
