#!/usr/bin/env bash
# Reproduction harness for T4: pool.go:277-285 uses ageNumBlocks AND ageDuration
# for expiry; reactor.go:187-206 uses only ageNumBlocks for gossip-eligibility.
# Asymmetric — evidence past the block-count threshold but not past the time
# threshold is pool-actionable but gossip-suppressed. Level: 0.
set -euo pipefail
COMETBFT_ROOT="/home/ubuntu/Specula/case-studies/cometbft/artifact/cometbft"
cd "${COMETBFT_ROOT}"
exec timeout 120 /usr/local/go/bin/go test -run TestBugRepro_T4_ExpiryAsymmetry -count=1 -v ./evidence/
