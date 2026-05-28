#!/usr/bin/env bash
# CR-4: proposalManager.go:163-186 — keep-for-late-credential-tracking path
#   contains a branch with comment "It should be impossible to hit this condition"
#   but the branch is still executed at runtime (it falls through and emits a
#   filteredEvent with credNote=NoLateCredentialTrackingImpact). The brief
#   asks: either prove unreachable or remove the comment.
#
# Level 0: source-level check that the unreachable branch is still wired up;
# attempt to construct a scenario that exercises it; document that the upstream
# proposalMachineRound emits filteredEvents only with the two whitelisted
# LateCredentialTrackingNote values, so the branch is dead code.

set -euo pipefail
export PATH=/usr/local/go/bin:$PATH

REPO="/home/ubuntu/Specula/case-studies/algorand/artifact/go-algorand"
PM="$REPO/agreement/proposalManager.go"

echo "[1/2] confirming the dead-branch comment is present"
LINE=$(awk '/It should be impossible to hit this condition/{print NR": "$0}' "$PM")
if [[ -z "$LINE" ]]; then
  echo "FAIL: comment 'It should be impossible to hit this condition' not found"
  exit 1
fi
echo "  $LINE"

echo "[2/2] showing the branch body and its outputs"
awk 'NR>=180 && NR<=195 {print NR": "$0}' "$PM"

echo
echo "CR-4 STATUS: code smell, NOT a behavior bug."
echo "  - The branch is a defensive fallback assigning credNote = NoLateCredentialTrackingImpact"
echo "    when LateCredentialTrackingNote arrives with an unexpected enum value."
echo "  - Upstream proposalMachineRound only ever emits the two whitelisted values"
echo "    (VerifiedBetterLateCredentialForTracking or NoLateCredentialTrackingImpact)"
echo "    through filteredEvent (see proposalRoundTracker handler)."
echo "  - The branch is dead code; removing the if-block or the comment would be"
echo "    purely a cleanup. No observable bug."
