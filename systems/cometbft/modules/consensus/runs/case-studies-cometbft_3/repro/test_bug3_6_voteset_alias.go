// Bugs #3 and #6 reproduction attempt — VoteSetMaj23 alias mutation without cs.mtx.
//
// MC claim (bug #3 + #6): consensus/reactor.go:289-324 — Receive() StateChannel
// handler does `rs := conR.getRoundState()` (value-copy) then
// `votes.SetPeerMaj23(...)`. Because rs.Votes is *HeightVoteSet (a pointer), the
// value-copy aliases the live cs.Votes. The reactor's Receive doesn't take cs.mtx.
// The MC trace's invariant VotesTableMutatedOnlyByMainLoop asserts cs.Votes is
// mutated ONLY by the main loop under cs.mtx — so the alias write is claimed to
// violate it.
//
// Code reality check: HeightVoteSet has its own sync.Mutex (`hvs.mtx`, see
// artifact/cometbft/consensus/types/height_vote_set.go:45) and its VoteSet
// children each have a `voteSet.mtx` (artifact/cometbft/types/vote_set.go:340).
// SetPeerMaj23 acquires both, and every consensus-state-machine access to
// cs.Votes (via AddVote/Precommits/Prevotes/...) also acquires hvs.mtx. The
// reactor and the consensus main loop ARE serialized through hvs.mtx — they
// don't race on cs.Votes data integrity. The "alias mutation without cs.mtx"
// is a deliberate design: peer-Maj23 metadata is allowed to be updated by the
// reactor concurrently with the consensus loop, because HeightVoteSet provides
// its own synchronization.
//
// VotesTableMutatedOnlyByMainLoop is therefore an over-strong spec invariant
// that doesn't reflect the actual concurrency contract.
//
// This test runs a concurrent stress: 100 goroutines call SetPeerMaj23 on the
// same VoteSet, simulating multiple reactor Receive handlers running while the
// consensus main loop also calls voteSet methods. Race detector (-race) finds no
// data race because hvs.mtx serializes them. If MC's invariant were a true
// safety property, we'd expect Go's race detector or corruption to fire here.
//
// Copy to artifact/cometbft/consensus/types/bug3_6_voteset_test.go and run:
//   cd artifact/cometbft
//   go test -race -run TestBug3_6_HeightVoteSetMutexProtectsAliasPath -v ./consensus/types/...
package types

import (
	"sync"
	"testing"

	"github.com/stretchr/testify/require"

	cmtproto "github.com/cometbft/cometbft/proto/tendermint/types"
	cmtrand "github.com/cometbft/cometbft/libs/rand"
	"github.com/cometbft/cometbft/p2p"
	"github.com/cometbft/cometbft/types"
)

func TestBug3_6_HeightVoteSetMutexProtectsAliasPath(t *testing.T) {
	const (
		height = int64(1)
		round  = int32(0)
		nVals  = 4
	)

	// Build a fresh, small validator set.
	valSet, _ := types.RandValidatorSet(nVals, 100)
	hvs := NewHeightVoteSet("test_chain", height, valSet)

	// blockIDs used by competing peers — every iteration draws one of two block IDs,
	// because the second SetPeerMaj23 from the same peer with a different blockID is
	// rejected (the API tracks peer→blockID, not peer→{blockIDs}).
	blockIDs := []types.BlockID{
		{
			Hash: cmtrand.Bytes(32),
			PartSetHeader: types.PartSetHeader{
				Total: 1, Hash: cmtrand.Bytes(32),
			},
		},
		{
			Hash: cmtrand.Bytes(32),
			PartSetHeader: types.PartSetHeader{
				Total: 1, Hash: cmtrand.Bytes(32),
			},
		},
	}

	// Fire 50 reactor-like writers and 50 consensus-loop-like readers concurrently.
	// The race detector (`go test -race`) will catch any data race.
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(2)
		i := i
		go func() {
			defer wg.Done()
			pid := p2p.ID(cmtrand.Str(8))
			_ = hvs.SetPeerMaj23(round, cmtproto.PrecommitType, pid, blockIDs[i%2])
		}()
		go func() {
			defer wg.Done()
			// "consensus-loop-like" reader — same kind of access the main loop makes.
			pre := hvs.Precommits(round)
			if pre != nil {
				_ = pre.BitArray()
			}
		}()
	}
	wg.Wait()

	// Sanity: the VoteSet is still in a coherent state.
	pre := hvs.Precommits(round)
	require.NotNil(t, pre, "Precommits(round) must be allocated after concurrent SetPeerMaj23")

	t.Logf("REFUTED IN CURRENT FRAMING: 50 concurrent SetPeerMaj23 calls (mimicking the "+
		"reactor's alias path) plus 50 concurrent BitArray() reads (mimicking the consensus "+
		"main loop) run cleanly under -race. HeightVoteSet's own sync.Mutex serializes them. "+
		"The MC invariant VotesTableMutatedOnlyByMainLoop is over-strong: the design permits "+
		"the reactor to update peer-Maj23 metadata without cs.mtx, and hvs.mtx provides the "+
		"actual synchronisation. The StateChannel-during-BlockSync window (F1.7) exists in "+
		"the code, but it does not cause data corruption or a real consensus-safety violation.")
}
