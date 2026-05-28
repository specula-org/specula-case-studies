#!/usr/bin/env bash
# Driver that copies every test_bugN_*.go file from this repro/ folder into the
# matching package under artifact/cometbft/ and runs `go test` against it. Run
# from this directory, with go on PATH. Exit code = sum of per-test failures.
#
#   PATH=/usr/local/go/bin:$PATH ./run.sh

set -euo pipefail

REPRO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT="$REPRO_DIR/../../artifact/cometbft"

if ! command -v go >/dev/null 2>&1; then
    echo "go binary not found on PATH. Hint: export PATH=/usr/local/go/bin:\$PATH" >&2
    exit 1
fi

# (source, dest-relative-to-artifact)
mappings=(
    "test_bug1_honest_peer_banned.go         blocksync/bug1_collateral_test.go"
    "test_bug2_maxpeerheight_monotonic.go    blocksync/bug2_monotonic_test.go"
    "test_bug4_mempool_before_consensus.go   blocksync/bug4_mempool_test.go"
    "test_bug5_hasvote_forged.go             consensus/bug5_hasvote_test.go"
    "test_bug3_6_voteset_alias.go            consensus/types/bug3_6_voteset_test.go"
    "test_bug7_validator_set_overflow.go     types/bug7_overflow_test.go"
    "test_bug8_light_client_forged_suffix.go types/bug8_trusting_test.go"
)

for m in "${mappings[@]}"; do
    src="$REPRO_DIR/${m%% *}"
    dst="$ARTIFACT/${m##* }"
    install -m 0644 "$src" "$dst"
done

cd "$ARTIFACT"
go test -count=1 -timeout 60s \
    -run "TestBug1HonestPeerBannedAsCollateral|TestBug2MaxPeerHeightStaysMonotonic|TestBug3_6_HeightVoteSetMutexProtectsAliasPath|TestBug4MempoolEnabledBeforeSwitchToConsensus|TestBug5HasVoteMessageForgesPeerKnowledge|TestBug7ProtoOverflowRejectedAtBoundary|TestBug8LightClientAcceptsForgedSuffix" \
    -v ./blocksync/... ./consensus/... ./consensus/types/... ./types/...
