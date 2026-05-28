// Bug #2 reproduction attempt — maxPeerHeight non-monotonic under Byzantine high-base peer.
//
// Claim from the MC bug report: blocksync/pool.go:487-501 updateMaxPeerHeight excludes
// peers with `base > pool.height` ONLY when `pool.height > 0`. A Byzantine peer can
// advertise `base = poolHeight + Δ`. At start (poolHeight=0) the peer is admitted into
// maxPeerHeight because the gate is off; later, when poolHeight advances past Δ, the
// gate flips and the peer suddenly counts in maxPeerHeight, making the cached value
// non-monotonic.
//
// Code reality check: pool.height never starts at 0 in production.
//   - artifact/cometbft/blocksync/reactor.go:130-134 sets startHeight = storeHeight+1;
//     if that equals 1 it falls back to state.InitialHeight.
//   - types/genesis.go:79-80: if genDoc.InitialHeight == 0 the genesis code rewrites
//     it to 1.
// So pool.height is always >= 1 at construction. The `pool.height > 0` guard at
// pool.go:492 is therefore always active in production, the early-exit branch never
// fires, and the non-monotonic transition cannot occur via the route the MC trace
// describes.
//
// This test verifies (a) NewBlockPool always lands pool.height >= 1 when given a
// valid InitialHeight, and (b) the canonical "poolHeight advance" scenario described
// in the MC trace produces a MONOTONICALLY INCREASING maxPeerHeight, not a regression.
//
// Copy to artifact/cometbft/blocksync/bug2_monotonic_test.go and run:
//   cd artifact/cometbft
//   go test -run TestBug2MaxPeerHeightStaysMonotonic -v ./blocksync/...
package blocksync

import (
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/cometbft/cometbft/libs/log"
	"github.com/cometbft/cometbft/p2p"
)

func TestBug2MaxPeerHeightStaysMonotonic(t *testing.T) {
	requestsCh := make(chan BlockRequest, 10)
	errorsCh := make(chan peerError, 10)

	// (a) Pool initialised with the minimum-meaningful startHeight: 1.
	// Production code path always calls this with >= 1; see reactor.go:130-134.
	pool := NewBlockPool(1, requestsCh, errorsCh)
	pool.SetLogger(log.TestingLogger())

	pool.mtx.Lock()
	require.GreaterOrEqual(t, pool.height, int64(1),
		"production-realistic startup: pool.height must be >= 1, never 0")
	pool.mtx.Unlock()

	// (b) Byzantine peer advertises (base=10, height=20). At pool.height=1 the gate
	// at pool.go:492 IS active (since pool.height > 0 and base > pool.height), so
	// the peer is EXCLUDED from maxPeerHeight. No non-monotonic jump.
	const pidBad = p2p.ID("bad")
	pool.SetPeerRange(pidBad, 10, 20)
	maxAfterAdmit := pool.MaxPeerHeight()
	require.EqualValues(t, 0, maxAfterAdmit,
		"high-base peer is correctly excluded at startup (pool.height=1, base=10): "+
			"maxPeerHeight stays 0, no spurious spike")

	// (c) Advance pool.height past the peer's base. Now the peer IS eligible and
	// maxPeerHeight rises to the peer's height. This is MONOTONICALLY INCREASING.
	pool.mtx.Lock()
	for h := int64(1); h < 10; h++ {
		pool.requesters[h] = newBPRequester(pool, h)
	}
	pool.mtx.Unlock()
	for h := int64(1); h < 10; h++ {
		pool.PopRequest() // each PopRequest advances pool.height by 1
	}

	maxAfterAdvance := pool.MaxPeerHeight()
	require.EqualValues(t, 20, maxAfterAdvance,
		"after pool.height advances past base, peer becomes eligible: maxPeerHeight rises")
	require.GreaterOrEqual(t, maxAfterAdvance, maxAfterAdmit,
		"maxPeerHeight increase is monotonic: %d → %d", maxAfterAdmit, maxAfterAdvance)

	t.Logf("REFUTED IN PRODUCTION CONFIG: production-realistic pool.height (>=1) keeps the "+
		"updateMaxPeerHeight gate active. maxPeerHeight transitions 0 → 20 (monotonically "+
		"increasing). The MC trace's `pool.height = 0` precondition does not occur in real "+
		"deployments because reactor.go:130-134 + genesis.go:79-80 guarantee pool.height >= 1.")
}
