#!/usr/bin/env bash
#
# Install the TLA+ trace-generation harness into the agave artifact.  The
# harness is a single integration-test file that drives real `solana-core`
# APIs (Tower, FileTowerStorage, VoteSimulator) and emits NDJSON trace events.
#
# Idempotent: re-running the script overwrites any prior copy.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "$HARNESS_DIR/../.." && pwd)"
ARTIFACT="$CASE_DIR/artifact/agave"
TEST_DST="$ARTIFACT/core/tests/tla_trace_scenarios.rs"

if [[ ! -d "$ARTIFACT/core/tests" ]]; then
    echo "apply.sh: agave artifact missing at $ARTIFACT" >&2
    exit 1
fi

cp "$HARNESS_DIR/src/tla_trace_scenarios.rs" "$TEST_DST"
echo "apply.sh: installed $TEST_DST"
