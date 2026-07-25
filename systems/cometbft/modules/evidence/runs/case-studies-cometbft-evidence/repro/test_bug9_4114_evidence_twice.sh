#!/usr/bin/env bash
# Reproduction harness for issue #4114: same evidence in two consecutive blocks
# permanently breaks blocksync for fresh nodes.
#
# Two Go tests cover the two halves of the bug:
#   #4114-a: a recovering Pool that lost its committed marker via the
#            EmptyEvidencePool replay path (consensus/replay.go:529 +
#            state/services.go:66) accepts the same evidence again. This is
#            "how the duplicate gets onto the chain". Level: 2 (state injection
#            via direct DB Delete of the committed key).
#   #4114-b: a freshly-syncing Pool sees both blocks via CheckEvidence and
#            rejects the second block with "evidence was already committed".
#            This is "the permanent failure". Level: 0 (pure public-API).
#
# Upstream issue: https://github.com/cometbft/cometbft/issues/4114
# Status: closed not_planned 2026-01. Confirmed on v0.38.7, v0.38.12, v1.0.
# jchappelow: "If you cannot or fail to rollback the block, it permanently
# prevents block sync."
set -euo pipefail
COMETBFT_ROOT="/home/ubuntu/Specula/case-studies/cometbft/artifact/cometbft"
cd "${COMETBFT_ROOT}"
exec timeout 120 /usr/local/go/bin/go test -run "TestBugRepro_4114" -count=1 -v ./evidence/
