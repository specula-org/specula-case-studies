#!/usr/bin/env bash
set -euo pipefail

REPO="/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/confirmation/MC-2/worktree"
EVIDENCE_DIR="/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/evidence/identity"
BIN="$EVIDENCE_DIR/temporal-reset-file-final.test"
RUN_LOG="$(mktemp /tmp/bugMC2-reset-run.XXXXXX.log)"

cleanup() {
  rm -f "$RUN_LOG"
}
trap cleanup EXIT

cd "$REPO"
test "$(git rev-parse HEAD)" = "0c010ce5fe8c0180aa7573c72fe8fc87c6df7025"
test -x "$BIN"
echo "MC2_REPO_HEAD=$(git rev-parse HEAD)"
sha256sum "$BIN" "$EVIDENCE_DIR/reset_identity_analysis_test.go" tests/reset_identity_analysis_test.go

set +e
timeout 3m "$BIN" \
  -test.run '^TestWorkflowResetTestSuite/TestAnalysisExactResetReplay/same-running/(response-received|response-lost)$' \
  -test.v \
  -test.timeout 2m \
  -test.parallel 1 \
  -persistenceType sql \
  -persistenceDriver sqlite \
  > "$RUN_LOG" 2>&1
status=$?
set -e

cat "$RUN_LOG"
echo "MC2_TEST_BINARY_EXIT=$status"

if [[ "$status" -eq 0 ]]; then
  echo "BUG_MC2_NOT_REPRODUCED: upstream behavior returned the original run for identical Reset retries"
  exit 1
fi

if ! rg -q 'mode=same-running reset_request_id=.* first=[0-9a-f-]+ second=[0-9a-f-]+ current=' "$RUN_LOG"; then
  echo "BUG_MC2_PARSE_FAILED: missing first/second/current Reset identity log" >&2
  exit 1
fi

if ! rg -q 'response_loss=verified observed_error=analysis: successful Reset response discarded' "$RUN_LOG"; then
  echo "BUG_MC2_PARSE_FAILED: missing response-loss confirmation log" >&2
  exit 1
fi

if ! rg -q 'identical immediately repeated Reset must return the original reset run' "$RUN_LOG"; then
  echo "BUG_MC2_PARSE_FAILED: missing expected-identity assertion failure" >&2
  exit 1
fi

echo "BUG_MC2_REPRODUCED: identical Reset request was executed through FrontendClient twice; both response-received and response-lost paths produced a second run instead of returning the first reset run."
