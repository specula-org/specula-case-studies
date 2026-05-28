#!/usr/bin/env bash
# Reproduction harness for CR5: markEvidenceAsCommitted's two unbatched DB writes
# (pool.go:330-358 — removePendingEvidence + Set(keyCommitted, ...)) can be torn by
# a crash, leaving evidence in neither pending nor committed.
#
# The actual test is bugrepro_test.go::TestBugRepro_CR5_TornCommit, which sits
# next to evidence_test.go because it uses the package's internal helpers
# (defaultTestPool, initializeValidatorState, initializeBlockStore). This harness
# runs that test. Level: 2 (state-injection via a wrapper dbm.DB that fails the
# second Set per evidence-hash).
#
# Expected output: 'PASS: TestBugRepro_CR5_TornCommit'. The buggy behavior is
# observed in the log lines:
#   1. "Deleted pending evidence"               (Delete succeeded)
#   2. "Unable to save committed evidence err=simulated crash: write of committed
#      key dropped"                              (Set failed — the crash window)
#   3. "Verified new evidence of byzantine behavior" after NewPool re-init
#      (evidence is re-acceptable because no committed marker exists)
set -euo pipefail
COMETBFT_ROOT="/home/ubuntu/Specula/case-studies/cometbft/artifact/cometbft"
cd "${COMETBFT_ROOT}"
exec timeout 120 /usr/local/go/bin/go test -run TestBugRepro_CR5_TornCommit -count=1 -v ./evidence/
