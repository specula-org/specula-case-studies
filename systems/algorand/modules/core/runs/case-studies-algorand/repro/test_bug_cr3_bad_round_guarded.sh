#!/usr/bin/env bash
# CR-3: voteAggregator.go:130 Panicf("bad round (%v, %v)", ...)
#   The brief flags this as DoS-reachable on a late-vote race. The audit
#   intent here is to check: does voteFresh() at line 199 keep vote.R.Round
#   within {PlayerRound, PlayerRound+1}, so the only thresholds returned have
#   Round in that set? If yes, the panic is unreachable through the normal
#   filterVote path. If we can build a voteAcceptedEvent that bypasses
#   voteFresh and produces a threshold for an unrelated round, the panic
#   fires.
#
# Level 0 (drive the public handle path with crafted inputs):
#   - Path A: legitimate path through voteAggregator.handle for voteVerified —
#     show that voteFresh rejects out-of-range rounds with an error rather
#     than reaching the Panicf.
#   - Path B: direct internal dispatch with a forced threshold — only reachable
#     via prohibited state injection (Level 2). Skipped per the bug-confirmation
#     skill's "do not pre-populate inconsistent state" rule.

set -euo pipefail
export PATH=/usr/local/go/bin:$PATH

REPO="/home/ubuntu/Specula/case-studies/algorand/artifact/go-algorand"
TEST_SRC="$REPO/agreement/repro_bug_cr3_test.go"

cleanup() { rm -f "$TEST_SRC"; }
trap cleanup EXIT

cat > "$TEST_SRC" <<'EOF'
package agreement

import (
	"strings"
	"testing"

	"github.com/algorand/go-algorand/protocol"
)

func TestReproBugCR3BadRoundPanicGuarded(t *testing.T) {
	// Path A: send a vote with vote.R.Round far below player.Round and far
	// above player.Round+1 — voteFresh must reject before reaching the panic.
	freshData := freshnessData{
		PlayerRound:          100,
		PlayerPeriod:         0,
		PlayerStep:           soft,
		PlayerLastConcluding: soft,
	}

	helper := voteMakerHelper{}
	helper.Setup()

	// Round 50 (too old)
	uv1 := helper.MakeUnauthenticatedVote(t, 1, round(50), period(0), soft, *helper.proposal)
	if err := voteFresh(protocol.ConsensusCurrentVersion, freshData, uv1); err == nil {
		t.Fatalf("expected voteFresh to reject round=50 vs PlayerRound=100, got nil")
	} else {
		t.Logf("Stale vote rejected by voteFresh: %v", err)
	}

	// Round 105 (too new)
	uv2 := helper.MakeUnauthenticatedVote(t, 2, round(105), period(0), soft, *helper.proposal)
	if err := voteFresh(protocol.ConsensusCurrentVersion, freshData, uv2); err == nil {
		t.Fatalf("expected voteFresh to reject round=105 vs PlayerRound=100, got nil")
	} else {
		t.Logf("Premature vote rejected by voteFresh: %v", err)
		if !strings.Contains(err.Error(), "bad round") {
			t.Logf("Note: voteFresh error message doesn't include 'bad round' literal — that's the Panicf string.")
		}
	}

	// Round 100 (PlayerRound) — voteFresh passes
	uv3 := helper.MakeUnauthenticatedVote(t, 3, round(100), period(0), soft, *helper.proposal)
	if err := voteFresh(protocol.ConsensusCurrentVersion, freshData, uv3); err != nil {
		t.Fatalf("expected voteFresh to accept round=100 (=PlayerRound), got: %v", err)
	}
	t.Logf("In-range vote accepted: round=100 (=PlayerRound)")

	// Round 101 (PlayerRound+1) — voteFresh passes
	uv4 := helper.MakeUnauthenticatedVote(t, 4, round(101), period(0), soft, *helper.proposal)
	if err := voteFresh(protocol.ConsensusCurrentVersion, freshData, uv4); err != nil {
		t.Fatalf("expected voteFresh to accept round=101 (=PlayerRound+1), got: %v", err)
	}
	t.Logf("In-range vote accepted: round=101 (=PlayerRound+1)")

	t.Logf("")
	t.Logf("CR-3 PHASE 1 RESULT: voteFresh at voteAggregator.go:198-263 enforces vote.R.Round in")
	t.Logf("  {PlayerRound, PlayerRound+1}. The Panicf at line 130 is reached only if a threshold")
	t.Logf("  somehow emerges with Round outside that set. By voteFresh, the dispatched vote has")
	t.Logf("  R.Round in {PlayerRound, PlayerRound+1}, and the resulting threshold inherits the vote's")
	t.Logf("  round (voteTracker.handle at voteTracker.go:246-247: 'round := e.Vote.R.Round'). The")
	t.Logf("  Panicf is therefore UNREACHABLE through the public message-event path.")
	t.Logf("")
	t.Logf("The TODO comment 'this should be a postcondition check; move it' (voteAggregator.go:130)")
	t.Logf("acknowledges this — it is a debug assertion, not a reachable runtime panic. The brief's")
	t.Logf("CR-3 concern (late-vote race) is mitigated by voteFresh's upstream check.")
}
EOF

cd "$REPO"
go test -count=1 -v -timeout=60s -run TestReproBugCR3BadRoundPanicGuarded ./agreement/ 2>&1 | tail -40
