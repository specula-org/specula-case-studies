#!/usr/bin/env bash
# Reproduction harness for CR6: addPendingEvidence non-idempotent counter drift
# via the LCAE branch of CheckEvidence. pool.go:204-218 always re-enters
# addPendingEvidence for LCAEs (isLightEv=true takes the branch even when the
# evidence is already pending); pool.go:307-326 unconditionally
# AddUint32(&evidenceSize, 1) without checking whether the key already existed.
# Result: pool.Size() drifts upward while the underlying DB key count remains 1.
#
# Level: 0 (pure public-API reproduction; no fault injection, no code mods).
# Expected output: pool.Size()=4 after 1 AddEvidence + 3 CheckEvidence calls on
# the same LCAE; len(PendingEvidence)=1.
set -euo pipefail
COMETBFT_ROOT="/home/ubuntu/Specula/case-studies/cometbft/artifact/cometbft"
cd "${COMETBFT_ROOT}"
exec timeout 120 /usr/local/go/bin/go test -run "TestBugRepro_CR6" -count=1 -v ./evidence/
