// Bug #5 reproduction — ApplyHasVoteMessage blindly trusts peer's claim.
//
// Trigger: A peer sends HasVoteMessage{Height: H, Round: R, Type: T, Index: I}. The
// honest server's ApplyHasVoteMessage in consensus/reactor.go:1607-1617 forwards the
// claimed index to ps.setHasVote without any verification that the peer actually has
// (or has been sent) the vote at index I. The peer's bit-array of "votes the peer
// has seen" is then corrupted with the forged index, and the gossip routines will
// skip sending vote I to that peer thereafter.
//
// We don't need any networking — we instantiate a PeerState directly, prime its
// PRS to match the message height/round (otherwise ApplyHasVoteMessage early-
// returns), and call ApplyHasVoteMessage with an arbitrary index. The post-state
// shows the bit set, even though no actual vote at that index was ever observed.
//
// Copy to artifact/cometbft/consensus/bug5_hasvote_test.go and run:
//   cd artifact/cometbft
//   go test -run TestBug5HasVoteMessageForgesPeerKnowledge -v ./consensus/...
package consensus

import (
	"testing"

	"github.com/stretchr/testify/require"

	cmtproto "github.com/cometbft/cometbft/proto/tendermint/types"
)

func TestBug5HasVoteMessageForgesPeerKnowledge(t *testing.T) {
	// A PeerState — no Peer wired up; the bug path does not touch the wire.
	ps := NewPeerState(nil)

	const (
		H            = int64(7)
		R            = int32(0)
		ForgedIndex  = int32(3)
		NumValidator = 5
	)

	// First we need to advance the peer's PRS to match the message's height/round —
	// otherwise ApplyHasVoteMessage's early return at consensus/reactor.go:1612
	// will skip the forged-claim path. In production this happens naturally:
	// peer p sends NewRoundStepMessage first, then HasVoteMessage. We simulate the
	// NewRoundStep step by calling ApplyNewRoundStepMessage with a legal payload.
	nrs := &NewRoundStepMessage{
		Height:                H,
		Round:                 R,
		Step:                  1, // RoundStepNewHeight value (>0, valid)
		SecondsSinceStartTime: 1,
		LastCommitRound:       -1,
	}
	ps.ApplyNewRoundStepMessage(nrs)
	ps.EnsureVoteBitArrays(H, NumValidator)

	// Snapshot the BEFORE state: no vote has actually been seen for ForgedIndex.
	preBitSet := ps.PRS.Prevotes.GetIndex(int(ForgedIndex))
	require.False(t, preBitSet,
		"precondition: peer's Prevotes[%d] must start unset (no vote actually seen)", ForgedIndex)

	// Now the peer sends a HasVoteMessage CLAIMING it has vote index `ForgedIndex`.
	// This message is what a Byzantine peer would inject — no proof, no signature,
	// just a claim. ApplyHasVoteMessage at consensus/reactor.go:1607-1617 trusts it
	// outright.
	forged := &HasVoteMessage{
		Height: H,
		Round:  R,
		Type:   cmtproto.PrevoteType,
		Index:  ForgedIndex,
	}
	ps.ApplyHasVoteMessage(forged)

	// Post-state: peer's Prevotes bit-array now records the forged claim.
	postBitSet := ps.PRS.Prevotes.GetIndex(int(ForgedIndex))
	require.True(t, postBitSet,
		"BUG: peer's Prevotes[%d] bit was set purely on the peer's say-so, with no provenance check",
		ForgedIndex)

	t.Logf("CONFIRMED: ApplyHasVoteMessage at consensus/reactor.go:1607-1617 trusts the peer's claim "+
		"of index %d outright. Gossip routines that consult ps.PRS.Prevotes will now skip sending "+
		"vote index %d to this peer, even though we have no evidence the peer actually has it.",
		ForgedIndex, ForgedIndex)
}
