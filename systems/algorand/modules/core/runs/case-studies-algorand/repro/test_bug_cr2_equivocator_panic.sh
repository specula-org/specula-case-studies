#!/usr/bin/env bash
# CR-2: voteTracker.go:189 Panicf("too many equivocators for step %d: %d", ...)
#   is reachable when an attacker submits enough equivocating votes (>=quorum)
#   for the same step. Requires Byzantine majority equivocation — under which
#   the protocol is already broken — but adds a process-abort DoS surface:
#   any honest node observing the equivocators panics, requiring restart.
#
# Level 0: drive voteTracker.handle() with crafted equivocating voteAcceptedEvents
# using the in-package voteMakerHelper.

set -euo pipefail
export PATH=/usr/local/go/bin:$PATH

REPO="/home/ubuntu/Specula/case-studies/algorand/artifact/go-algorand"
TEST_SRC="$REPO/agreement/repro_bug_cr2_test.go"

cleanup() { rm -f "$TEST_SRC"; }
trap cleanup EXIT

cat > "$TEST_SRC" <<'EOF'
package agreement

import (
	"fmt"
	"strings"
	"testing"

	"github.com/algorand/go-algorand/config"
	"github.com/algorand/go-algorand/logging"
	"github.com/algorand/go-algorand/protocol"
)

func TestReproBugCR2EquivocatorPanic(t *testing.T) {
	proto := config.Consensus[protocol.ConsensusCurrentVersion]
	quorum := soft.threshold(proto)
	t.Logf("soft step quorum threshold = %d", quorum)

	helper := voteMakerHelper{}
	helper.Setup()
	proposalA := *helper.proposal
	proposalB := *helper.MakeRandomProposalValue()

	tracker := new(voteTracker)
	trc := &tracer{log: serviceLogger{logging.Base()}}
	router := &rootRouter{}
	rH := routerHandle{t: trc, r: router, src: voteMachineStep}
	pl := player{Round: 0, Period: 8}

	// First, demonstrate that a SINGLE equivocator does NOT trigger the panic.
	tracker.handle(rH, pl, voteAcceptedEvent{
		Vote:  helper.MakeVerifiedVote(t, 0, round(0), period(8), soft, proposalA),
		Proto: protocol.ConsensusCurrentVersion,
	})
	tracker.handle(rH, pl, voteAcceptedEvent{
		Vote:  helper.MakeVerifiedVote(t, 0, round(0), period(8), soft, proposalB),
		Proto: protocol.ConsensusCurrentVersion,
	})
	t.Logf("After single equivocator: EquivocatorsCount=%d (no panic yet, %d < quorum=%d)",
		tracker.EquivocatorsCount, tracker.EquivocatorsCount, quorum)

	// Now drive `quorum-1` more distinct equivocators (each weight=1).
	caughtPanic := ""
	func() {
		defer func() {
			if r := recover(); r != nil {
				caughtPanic = strings.TrimSpace(fmt.Sprintf("%v", r))
			}
		}()
		for i := 1; uint64(i) < quorum; i++ {
			tracker.handle(rH, pl, voteAcceptedEvent{
				Vote:  helper.MakeVerifiedVote(t, i, round(0), period(8), soft, proposalA),
				Proto: protocol.ConsensusCurrentVersion,
			})
			tracker.handle(rH, pl, voteAcceptedEvent{
				Vote:  helper.MakeVerifiedVote(t, i, round(0), period(8), soft, proposalB),
				Proto: protocol.ConsensusCurrentVersion,
			})
		}
	}()
	if caughtPanic == "" {
		t.Fatalf("CR-2 REPRO FAILED: no panic after %d equivocators (EquivocatorsCount=%d)",
			quorum, tracker.EquivocatorsCount)
	}
	t.Logf("CR-2 REPRODUCED: voteTracker.go:189 panic fired — %q", caughtPanic)
	if !strings.Contains(caughtPanic, "too many equivocators") {
		t.Fatalf("Wrong panic message — got %q", caughtPanic)
	}
}
EOF

cd "$REPO"
go test -count=1 -v -timeout=120s -run TestReproBugCR2EquivocatorPanic ./agreement/ 2>&1 | tail -50
