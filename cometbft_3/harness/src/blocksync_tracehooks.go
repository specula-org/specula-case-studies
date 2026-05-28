package blocksync

import (
	"os"

	tlatrace "github.com/cometbft/cometbft/libs/tla_trace"
	"github.com/cometbft/cometbft/p2p"
)

// localServerID is the TLA+ ID for the node owning the BlockPool. Test scenarios
// call SetTraceNodeID to bind the pool to a server slot before exercising it.
//
// We can't pull it off the pool itself (the pool is a sub-component shared by
// many tests), so a package-global keeps the patches one-liners.
var localServerID = func() string {
	if v := os.Getenv("TLA_TRACE_LOCAL_NID"); v != "" {
		return v
	}
	return "s1"
}()

// SetTraceNodeID overrides the server ID baked into emitted events.
func SetTraceNodeID(id string) { localServerID = id }

// TraceNodeID returns the current local server ID.
func TraceNodeID() string { return localServerID }

// emitSetPeerRange fires after pool.updateMaxPeerHeight returns. The state
// snapshot captures the pool's post-call view of pool height, max peer height,
// and number of banned peers.
func (pool *BlockPool) emitSetPeerRange(peerID p2p.ID, base int64, height int64) {
	if !tlatrace.IsEnabled() {
		return
	}
	st := tlatrace.NewState().
		Set("poolHeight", pool.height).
		Set("maxPeerHeight", pool.maxPeerHeight).
		Set("bannedCount", len(pool.bannedPeers))
	pr := tlatrace.NewPeer().
		Set("id", string(peerID)).
		Set("base", base).
		Set("height", height)
	name := "SetPeerRange"
	if tlatrace.IsPeerByz(string(peerID)) {
		name = "ByzPeerAdvertiseRange"
	}
	tlatrace.EmitPeer(name, localServerID, st, pr)
}

// emitAdvancePoolHeight fires after pool.height++ and updateMaxPeerHeight.
func (pool *BlockPool) emitAdvancePoolHeight() {
	if !tlatrace.IsEnabled() {
		return
	}
	st := tlatrace.NewState().
		Set("poolHeight", pool.height).
		Set("maxPeerHeight", pool.maxPeerHeight)
	tlatrace.EmitState("AdvancePoolHeight", localServerID, st)
}

// emitDeliverBlock fires after the first block delivery for a requester.
// CONTRACT: called from setBlock with no locks held; pool.mtx may be held by
// the AddBlock caller. We must NOT call methods that re-acquire pool.mtx —
// hence we read pool fields directly without locking (the values may be
// slightly stale but that is acceptable for a trace snapshot).
func (bpr *bpRequester) emitDeliverBlock(peerID p2p.ID, blockTag string) {
	if !tlatrace.IsEnabled() {
		return
	}
	pr := tlatrace.NewPeer().
		Set("id", string(peerID)).
		Set("height", bpr.height).
		Set("block", blockTag)
	name := "HonestPeerDeliverBlock"
	if tlatrace.IsPeerByz(string(peerID)) {
		name = "ByzPeerDeliverBlock"
	}
	st := tlatrace.NewState().
		Set("poolHeight", bpr.pool.height).
		Set("maxPeerHeight", bpr.pool.maxPeerHeight)
	tlatrace.Emit(tlatrace.Event{
		Name:  name,
		Nid:   localServerID,
		State: st,
		Peer:  pr,
	})
}
