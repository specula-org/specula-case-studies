#!/usr/bin/env bash
# Reproduction test for Bug 2: checkDoubleSigningRisk() off-by-one (consensus/state.go:2647).
# Source: artifact/cometbft/consensus/repro_bug2_double_sign_height1_test.go
# Run from the run root:  ./repro/test_bug2_double_sign_height1.sh

set -euo pipefail

ARTIFACT_DIR="$(cd "$(dirname "$0")/../artifact/cometbft" && pwd)"
export PATH="$PATH:/usr/local/go/bin"

echo "=== Bug 2: Double-Sign Check Off-By-One (consensus/state.go:2647) ==="
echo "Running: go test ./consensus/ -run TestBug2 -v -count=1"
echo ""

cd "$ARTIFACT_DIR"
go test ./consensus/ -run "TestBug2" -v -count=1

# Expected output (excerpt):
#   PASS: TestBug2_DoubleSignCheckZeroIterations
#     "BUG CONFIRMED: checkDoubleSigningRisk(height=2, DoubleSignCheckHeight=1) returns nil"
#     "Buggy loop:  for i=1; i<1  → 0 iterations → misses LoadSeenCommit(1)"
#     "FIXED code would find: prior signature in LoadSeenCommit(1)"
#   PASS: TestBug2_LoopIterationCount_AllCases
#     "Key finding: DoubleSignCheckHeight=1 results in ZERO protection at ALL heights"
