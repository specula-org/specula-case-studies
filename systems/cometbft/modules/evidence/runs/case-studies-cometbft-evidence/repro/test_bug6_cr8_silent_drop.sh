#!/usr/bin/env bash
# Reproduction harness for CR8: pool.go:518-528 silently drops conflicting votes
# whose height > state.LastBlockHeight. The developer comment at pool.go:519-521
# acknowledges this. Reproduction in bugrepro_test.go calls ReportConflictingVotes
# at a future height, advances state past it, and observes the votes were lost.
# Level: 0 (pure public-API).
set -euo pipefail
COMETBFT_ROOT="/home/ubuntu/Specula/case-studies/cometbft/artifact/cometbft"
cd "${COMETBFT_ROOT}"
exec timeout 120 /usr/local/go/bin/go test -run TestBugRepro_CR8_SilentDropFutureHeight -count=1 -v ./evidence/
