#!/usr/bin/env bash
# CR-6: proposalTracker.handle for softThreshold/certThreshold blindly sets
#   t.Staging = e.Proposal (proposalTracker.go:203-211) without comparing the
#   incoming proposal to the existing t.Staging. The brief flags this as a
#   potential safety concern.
#
# Phase 1 audit: each proposalTracker instance is scoped to a single
# (round, period). The voteTracker (voteMachineStep) emits at most one
# softThreshold *per step* and at most one certThreshold *per period*.
# softThreshold and certThreshold for the same period can both fire (cert
# only forms if the soft staging value reaches cert quorum), but they share
# the same proposal value (cert votes are for the staged value).
#
# So in honest execution, even though Staging is overwritten, the value
# never changes between writes — t.Staging = X then t.Staging = X.
#
# Under Byzantine equivocation, the voteTracker is supposed to filter via
# the Voters map (proposalTracker.go:164-168) so a sender can only emit one
# proposal-vote per (round, period) at the proposalTracker level. Once a
# threshold is reached, the tracker emits a single accepted event.
#
# Level 0 test: drive proposalTracker.handle with two thresholdEvents for
# DIFFERENT proposals (which can only happen if the upstream voteTracker
# is buggy). Observe that Staging is silently overwritten — confirming the
# behavior the brief identified, while documenting the upstream guarantee.

set -euo pipefail
export PATH=/usr/local/go/bin:$PATH

REPO="/home/ubuntu/Specula/case-studies/algorand/artifact/go-algorand"
TEST_SRC="$REPO/agreement/repro_bug_cr6_test.go"

cleanup() { rm -f "$TEST_SRC"; }
trap cleanup EXIT

cat > "$TEST_SRC" <<'EOF'
package agreement

import (
	"testing"

	"github.com/algorand/go-algorand/logging"
	"github.com/algorand/go-algorand/protocol"
)

func TestReproBugCR6StagingOverwriteOnThreshold(t *testing.T) {
	helper := voteMakerHelper{}
	helper.Setup()
	pA := *helper.proposal
	pB := *helper.MakeRandomProposalValue()

	tracker := &proposalTracker{}
	trc := &tracer{log: serviceLogger{logging.Base()}}
	router := &rootRouter{}
	rH := routerHandle{t: trc, r: router, src: proposalMachinePeriod}
	pl := player{Round: 1, Period: 0}

	// First softThreshold sets Staging = pA
	ev1 := thresholdEvent{T: softThreshold, Round: round(1), Period: period(0), Step: soft, Proposal: pA, Proto: protocol.ConsensusCurrentVersion}
	_ = tracker.handle(rH, pl, ev1)
	if tracker.Staging != pA {
		t.Fatalf("after first softThreshold, expected Staging = pA, got %v", tracker.Staging)
	}
	t.Logf("After 1st softThreshold: Staging = pA")

	// Second softThreshold (e.g., from an adversarial duplicate threshold
	// event injected by a Byzantine network path) — silently OVERWRITES
	// Staging to pB without any freshness check.
	ev2 := thresholdEvent{T: softThreshold, Round: round(1), Period: period(0), Step: soft, Proposal: pB, Proto: protocol.ConsensusCurrentVersion}
	_ = tracker.handle(rH, pl, ev2)
	if tracker.Staging != pB {
		t.Fatalf("CR-6 REPRO FAILED: Staging not overwritten — got %v, expected %v", tracker.Staging, pB)
	}
	t.Logf("After 2nd softThreshold with DIFFERENT proposal: Staging = pB (overwritten silently)")
	t.Logf("")
	t.Logf("CR-6 BEHAVIOR CONFIRMED: proposalTracker.go:203-211 always assigns t.Staging = e.Proposal")
	t.Logf("without comparing to existing value.")
	t.Logf("")
	t.Logf("Upstream guarantee that keeps this benign: each proposalTracker is per-(round, period)")
	t.Logf("and the voteTracker emits softThreshold/certThreshold at most once per step within that")
	t.Logf("period. In honest execution, the second threshold cannot carry a different proposal.")
	t.Logf("To produce two distinct softThresholds for the same period requires Byzantine vote-")
	t.Logf("tracker behavior or a flaw in voteAuxiliary's caching, neither of which the upstream")
	t.Logf("voteTracker permits (Voters map filters duplicate senders).")
}
EOF

cd "$REPO"
go test -count=1 -v -timeout=60s -run TestReproBugCR6StagingOverwriteOnThreshold ./agreement/ 2>&1 | tail -30
