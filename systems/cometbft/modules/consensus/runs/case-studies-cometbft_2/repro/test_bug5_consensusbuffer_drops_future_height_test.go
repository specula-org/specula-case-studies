// Reproduction of TV-2 / CR-3 (Modeling brief §6.2, §6.3):
//   evidence/pool.go:processConsensusBuffer drops conflicting-vote pairs
//   whose height is GREATER than state.LastBlockHeight (lines 502-509),
//   and then unconditionally resets the in-memory consensusBuffer (line
//   538). The result: any conflicting vote pair seen at a height the
//   pool considers "in the future" is silently discarded — no evidence
//   is produced, no error is surfaced.
//
// Two separate hygiene gaps, both in evidence/pool.go:
//   * `consensusBuffer` is purely in-memory (pool.go:49) and reset by
//     `processConsensusBuffer` (pool.go:538) every time Update runs.
//   * The "future height" branch at pool.go:502-509 is `continue`
//     without preserving the buffer entry.
//
// Test approach (Level 0 — public API only):
//   1. Build a default test pool whose state is at LastBlockHeight = H.
//   2. Construct conflicting votes A, B for height H+5 (above LastBlockHeight)
//      using NewMockDuplicateVoteEvidenceWithValidator (public helper).
//   3. Call pool.ReportConflictingVotes(A, B) — adds to consensusBuffer.
//   4. Bump state to LastBlockHeight = H+1 and call pool.Update.
//   5. Observe: PendingEvidence is empty (the entry was dropped), and
//      the buffer has been reset (re-calling Report afterward repopulates).
//
// Observable harm:
//   * The evidence is lost — there is no retry path; the buffer's
//     entry was both unprocessed *and* unconditionally cleared.
//   * If the validator legitimately observed a conflicting precommit
//     pair at a height slightly ahead of its own block height (e.g.,
//     during a fast-sync or a brief network partition), the protocol
//     would never form `DuplicateVoteEvidence` from those votes.

package repro_test

import (
	"testing"
	"time"

	"github.com/stretchr/testify/mock"
	"github.com/stretchr/testify/require"

	dbm "github.com/cometbft/cometbft-db"

	"github.com/cometbft/cometbft/evidence"
	"github.com/cometbft/cometbft/evidence/mocks"
	"github.com/cometbft/cometbft/libs/log"
	sm "github.com/cometbft/cometbft/state"
	smmocks "github.com/cometbft/cometbft/state/mocks"
	"github.com/cometbft/cometbft/types"
)

func TestConsensusBufferDropsFutureHeightVotes(t *testing.T) {
	const chainID = "repro-cr3-tv2"
	startTime := time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC)
	currentHeight := int64(10)

	val := types.NewMockPV()
	pubKey, err := val.GetPubKey()
	require.NoError(t, err)
	validator := &types.Validator{
		Address:     pubKey.Address(),
		VotingPower: 10,
		PubKey:      pubKey,
	}
	valSet := &types.ValidatorSet{
		Validators: []*types.Validator{validator},
		Proposer:   validator,
	}

	// Build a state store that returns a state with LastBlockHeight = currentHeight
	// and the validator set.
	state := sm.State{
		ChainID:         chainID,
		LastBlockHeight: currentHeight,
		LastBlockTime:   startTime,
		Validators:      valSet,
		LastValidators:  valSet,
		ConsensusParams: *types.DefaultConsensusParams(),
	}
	stateStore := &smmocks.Store{}
	stateStore.On("Load").Return(state, nil)
	stateStore.On("LoadValidators", mock.AnythingOfType("int64")).Return(valSet, nil)

	blockStore := &mocks.BlockStore{}
	blockStore.On("LoadBlockMeta", mock.AnythingOfType("int64")).Return(
		&types.BlockMeta{Header: types.Header{Time: startTime}},
	)

	pool, err := evidence.NewPool(dbm.NewMemDB(), stateStore, blockStore)
	require.NoError(t, err)
	pool.SetLogger(log.TestingLogger())

	// Conflicting precommits at a FUTURE height (currentHeight + 5).
	futureHeight := currentHeight + 5
	ev, err := types.NewMockDuplicateVoteEvidenceWithValidator(
		futureHeight, startTime, val, chainID)
	require.NoError(t, err)

	// Step 1: Report the conflict; this lands in the in-memory consensusBuffer.
	pool.ReportConflictingVotes(ev.VoteA, ev.VoteB)

	// Sanity check: nothing in the pending list yet (buffer hasn't been flushed).
	evList, _ := pool.PendingEvidence(1000)
	require.Empty(t, evList, "expected empty pending list before Update")
	t.Logf("After ReportConflictingVotes (height=%d, state.LastBlockHeight=%d):", futureHeight, currentHeight)
	t.Logf("  pending evidence list size: %d (buffer not yet flushed)", len(evList))

	// Step 2: Advance state to height currentHeight + 1 (still < futureHeight)
	// and call Update. processConsensusBuffer should reject the future-height
	// entry and reset the buffer.
	newState := state
	newState.LastBlockHeight = currentHeight + 1
	newState.LastBlockTime = startTime.Add(1 * time.Minute)
	pool.Update(newState, []types.Evidence{})

	evList, _ = pool.PendingEvidence(1000)
	t.Logf("After Update(state.LastBlockHeight=%d):", newState.LastBlockHeight)
	t.Logf("  pending evidence list size: %d", len(evList))
	if len(evList) != 0 {
		t.Logf("Pending evidence (unexpectedly non-empty): %v", evList)
	}

	// Step 3: At this point the buffer has been reset, even though the votes
	// for futureHeight have NOT been processed. They are lost. We verify by
	// updating state once more *to* futureHeight without re-reporting:
	// no evidence should appear.
	newerState := newState
	newerState.LastBlockHeight = futureHeight
	newerState.LastBlockTime = startTime.Add(2 * time.Minute)
	pool.Update(newerState, []types.Evidence{})

	evList, _ = pool.PendingEvidence(1000)
	t.Logf("After Update(state.LastBlockHeight=%d): pending list size %d", futureHeight, len(evList))

	if len(evList) == 0 {
		t.Logf("BUG REPRODUCED: conflict-vote pair reported at height=%d while", futureHeight)
		t.Logf("state.LastBlockHeight=%d was silently dropped by processConsensusBuffer.", currentHeight)
		t.Logf("Root cause: evidence/pool.go:502-509 logs and continues; line 538")
		t.Logf("unconditionally resets the consensusBuffer. The future-height entry")
		t.Logf("is never retried, even after state catches up to that height.")
		t.FailNow()
	}
	t.Logf("Reproduction did not trigger; pending list non-empty after final Update.")
}
