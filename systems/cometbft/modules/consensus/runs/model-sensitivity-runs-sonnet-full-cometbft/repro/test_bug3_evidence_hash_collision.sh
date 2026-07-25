#!/usr/bin/env bash
# Reproduction test for Bug 3: LightClientAttackEvidence.Hash() 31-byte truncation.
# Source: artifact/cometbft/types/repro_bug3_evidence_hash_collision_test.go
# Run from the run root:  ./repro/test_bug3_evidence_hash_collision.sh

set -euo pipefail

ARTIFACT_DIR="$(cd "$(dirname "$0")/../artifact/cometbft" && pwd)"
export PATH="$PATH:/usr/local/go/bin"

echo "=== Bug 3: Evidence Pool Hash Collision (types/evidence.go:326) ==="
echo "Running: go test ./types/ -run TestBug3 -v -count=1"
echo ""

cd "$ARTIFACT_DIR"
go test ./types/ -run "TestBug3" -v -count=1

# Expected output (excerpt):
#   PASS: TestBug3_HashTruncatesLastByte
#     "BUG CONFIRMED: ConflictingBlock.Hash()[31] = 0x?? is DROPPED from the evidence key"
#     "actualHash (buggy):  ..." != "correctHash (fixed): ..."
#   PASS: TestBug3_EvidencePoolKeyCollision
#     "COLLISION CONFIRMED"
#     "key(E1) = ..." == "key(E1prime) = ..."  (same despite different bh[31])
