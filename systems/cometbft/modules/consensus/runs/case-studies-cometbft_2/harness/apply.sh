#!/bin/bash
# apply.sh — install the CometBFT round-2 (BFT) trace instrumentation onto the artifact.
#
# Idempotent: revert prior runs via `git checkout -- .` then re-patch.
#
# Strategy:
#   1. Copy harness/src/{trace_emit.go,bft_trace_emit.go,byz_state.go} into
#      artifact/cometbft/consensus/ — these are standalone Go source files.
#   2. Copy harness/src/scenario_bft_trace_test.go into the consensus package.
#   3. Patch artifact/cometbft/consensus/state.go to:
#        - add the `encoding/hex` import
#        - add the traceLogger / byz-state fields to *State
#        - add SetTraceLogger / SetTraceDir methods
#        - insert Emit calls at the 14+ honest-event sites in state.go

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT_DIR="$(cd "$SCRIPT_DIR/../../artifact/cometbft" && pwd)"
CONSENSUS_DIR="$ARTIFACT_DIR/consensus"
SRC_DIR="$SCRIPT_DIR/src"

cd "$ARTIFACT_DIR"

echo "==> Resetting artifact to clean state"
git checkout -- consensus/state.go 2>/dev/null || true
rm -f "$CONSENSUS_DIR/trace_emit.go"
rm -f "$CONSENSUS_DIR/bft_trace_emit.go"
rm -f "$CONSENSUS_DIR/byz_state.go"
rm -f "$CONSENSUS_DIR/scenario_bft_trace_test.go"

echo "==> Copying trace module files"
cp "$SRC_DIR/trace_emit.go"            "$CONSENSUS_DIR/trace_emit.go"
cp "$SRC_DIR/bft_trace_emit.go"        "$CONSENSUS_DIR/bft_trace_emit.go"
cp "$SRC_DIR/byz_state.go"             "$CONSENSUS_DIR/byz_state.go"
cp "$SRC_DIR/scenario_bft_trace_test.go" "$CONSENSUS_DIR/scenario_bft_trace_test.go"

echo "==> Patching consensus/state.go"
python3 "$SCRIPT_DIR/patch_state.py" "$CONSENSUS_DIR/state.go"

echo "==> Tidying go modules"
go mod tidy >/dev/null 2>&1 || true

echo "==> Done"
