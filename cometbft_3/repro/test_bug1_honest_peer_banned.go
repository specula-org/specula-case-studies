// Bug #1 reproduction — Honest peer banned as collateral after VerifyCommit chain failure.
//
// Trigger:
//   - Peer P_bad delivers a malformed block for height h.
//   - Peer P_good delivers a *canonical* block for height h+1.
//   - blocksync verifies block h via block(h+1).LastCommit; verification fails.
//   - reactor.handleValidationFailure(blockA, blockB) bans whoever delivered block at
//     blockA.Height AND whoever delivered block at blockB.Height. Since they're different
//     peers, P_good is banned even though it delivered the canonical block at h+1.
//
// This file is a standalone Go test that exercises the relevant Pool APIs to confirm
// the ban list ends up containing the honest peer. The test does not modify any product
// code — it constructs the exact in-pool state that the production poolRoutine would
// see after two different peers each deliver one block of the consecutive pair.
//
// Copy this file to artifact/cometbft/blocksync/bug1_test.go and run:
//   cd artifact/cometbft
//   go test -run TestBug1HonestPeerBannedAsCollateral -v ./blocksync/...
package blocksync

import (
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/cometbft/cometbft/libs/log"
	"github.com/cometbft/cometbft/p2p"
)

func TestBug1HonestPeerBannedAsCollateral(t *testing.T) {
	requestsCh := make(chan BlockRequest, 10)
	errorsCh := make(chan peerError, 10)

	pool := NewBlockPool(1, requestsCh, errorsCh)
	pool.SetLogger(log.TestingLogger())

	// Register two peers, both with the same range so each is eligible to be
	// the deliverer for some height.
	const (
		pidBad  = p2p.ID("badpeer")
		pidGood = p2p.ID("goodpeer")
	)
	pool.SetPeerRange(pidBad, 1, 100)
	pool.SetPeerRange(pidGood, 1, 100)
	require.False(t, pool.IsPeerBanned(pidBad), "badpeer must start unbanned")
	require.False(t, pool.IsPeerBanned(pidGood), "goodpeer must start unbanned")

	// Install two requesters and mark each as having received a block from a different peer.
	// We're modelling the in-pool state right after both deliveries completed:
	//   requester[H]    : gotBlockFromPeerID = pidBad      (malformed block)
	//   requester[H+1]  : gotBlockFromPeerID = pidGood     (canonical block)
	const H = int64(1)
	pool.mtx.Lock()
	reqA := newBPRequester(pool, H)
	reqA.peerID = pidBad
	reqA.gotBlockFrom = pidBad
	pool.requesters[H] = reqA

	reqB := newBPRequester(pool, H+1)
	reqB.peerID = pidGood
	reqB.gotBlockFrom = pidGood
	pool.requesters[H+1] = reqB
	pool.mtx.Unlock()

	// Simulate what reactor.handleValidationFailure(blockA, blockB) does when
	// VerifyCommit(state.Validators, blockA.ID, blockB.LastCommit) fails — see
	// artifact/cometbft/blocksync/reactor.go:749-770.
	idA := pool.RemovePeerAndRedoAllPeerRequests(H)
	idB := pool.RemovePeerAndRedoAllPeerRequests(H + 1)

	require.Equal(t, pidBad, idA, "blockA deliverer should be the bad peer")
	require.Equal(t, pidGood, idB, "blockB deliverer should be the good peer")
	require.NotEqual(t, idA, idB, "different peers — the collateral case")

	// Both peers are now in the ban list — the bug: the good peer is banned even
	// though it delivered the canonical block at h+1.
	require.True(t, pool.IsPeerBanned(pidBad), "bad peer must be banned")
	require.True(t, pool.IsPeerBanned(pidGood),
		"BUG: good peer was banned even though it delivered the canonical block at H+1")

	t.Logf("CONFIRMED: blocksync's handleValidationFailure bans both peer-A (delivered bad block at h) "+
		"and peer-B (delivered canonical block at h+1) on commit-chain verification failure: "+
		"badpeer banned=%v, goodpeer banned=%v", pool.IsPeerBanned(pidBad), pool.IsPeerBanned(pidGood))
}
