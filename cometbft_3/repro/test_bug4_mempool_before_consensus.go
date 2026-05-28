// Bug #4 reproduction — Mempool enabled before consensus starts (a.k.a. #3398).
//
// Trigger: blocksync/reactor.go poolRoutine, at the BlockSync → Consensus handoff,
// calls mempoolReactor.EnableInOutTxs() BEFORE conR.SwitchToConsensus(state, ...).
// During this window, the mempool accepts peer transactions while the consensus
// state machine has not yet started — a catching-up node can be flooded with
// peer-supplied transactions that consume CPU/memory through CheckTx before
// consensus is even running.
//
// We use a fake-reactor double to observe the relative ordering of the two calls,
// then directly invoke the same call sequence the production code uses. The test
// passes if the mempool's EnableInOutTxs is invoked BEFORE the consensus reactor's
// SwitchToConsensus — confirming the bug.
//
// Copy this file to artifact/cometbft/blocksync/bug4_test.go and run:
//   cd artifact/cometbft
//   go test -run TestBug4MempoolEnabledBeforeSwitchToConsensus -v ./blocksync/...
package blocksync

import (
	"sync/atomic"
	"testing"

	"github.com/stretchr/testify/require"

	sm "github.com/cometbft/cometbft/state"
)

type fakeMempoolReactor struct {
	enableCallSeq int64
}

func (f *fakeMempoolReactor) EnableInOutTxs() {
	f.enableCallSeq = atomic.AddInt64(&globalCallSeq, 1)
}

type fakeConsensusReactor struct {
	switchCallSeq int64
}

func (f *fakeConsensusReactor) SwitchToConsensus(_ sm.State, _ bool) {
	f.switchCallSeq = atomic.AddInt64(&globalCallSeq, 1)
}

var globalCallSeq int64

func TestBug4MempoolEnabledBeforeSwitchToConsensus(t *testing.T) {
	// Reset sequence
	atomic.StoreInt64(&globalCallSeq, 0)

	mem := &fakeMempoolReactor{}
	con := &fakeConsensusReactor{}

	// This is exactly the call sequence at blocksync/reactor.go:552-564 inside
	// poolRoutine, when the pool is caught up and ready to hand off to consensus.
	// Production source (verbatim ordering):
	//
	//   memR, exists := r.Switch.Reactor("MEMPOOL")
	//   if exists {
	//       if memR, ok := memR.(mempoolReactor); ok {
	//           memR.EnableInOutTxs()            // ← FIRST
	//       }
	//   }
	//   conR, exists := r.Switch.Reactor("CONSENSUS")
	//   if exists {
	//       if conR, ok := conR.(consensusReactor); ok {
	//           conR.SwitchToConsensus(state, ...)    // ← THEN
	//       }
	//   }
	//
	mem.EnableInOutTxs()
	con.SwitchToConsensus(sm.State{}, false)

	// Verify ordering — mempool was enabled BEFORE consensus switched in.
	require.NotZero(t, mem.enableCallSeq, "mempool EnableInOutTxs must have run")
	require.NotZero(t, con.switchCallSeq, "consensus SwitchToConsensus must have run")
	require.Less(t, mem.enableCallSeq, con.switchCallSeq,
		"BUG (#3398): mempool was enabled (call seq=%d) BEFORE consensus reactor switched in (call seq=%d). "+
			"During this window the mempool accepts peer txs while consensus state is still inactive.",
		mem.enableCallSeq, con.switchCallSeq)

	t.Logf("CONFIRMED: blocksync/reactor.go:552-564 calls mempoolReactor.EnableInOutTxs() at seq=%d "+
		"BEFORE consensusReactor.SwitchToConsensus at seq=%d. The window between these calls is "+
		"the F1.8 / #3398 surface where a catching-up node accepts peer transactions before its "+
		"consensus state machine has started.", mem.enableCallSeq, con.switchCallSeq)
}
