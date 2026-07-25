package statesync

import (
	"os"

	tlatrace "github.com/cometbft/cometbft/libs/tla_trace"
	"github.com/cometbft/cometbft/p2p"
)

var localServerID = func() string {
	if v := os.Getenv("TLA_TRACE_LOCAL_NID"); v != "" {
		return v
	}
	return "s1"
}()

// SetTraceNodeID overrides the local server ID baked into emitted events.
func SetTraceNodeID(id string) { localServerID = id }

// TraceNodeID returns the local server ID.
func TraceNodeID() string { return localServerID }

// emitOfferSnapshot fires after offerSnapshot returned ACCEPT for a snapshot.
func emitOfferSnapshot(peerID p2p.ID, snap *snapshot) {
	if !tlatrace.IsEnabled() || snap == nil {
		return
	}
	pr := tlatrace.NewPeer().
		Set("id", string(peerID)).
		Set("height", int64(snap.Height)).
		Set("hash", tlatrace.HexOrNil(snap.Hash))
	st := tlatrace.NewState().
		Set("persistStage", "none").
		Set("acceptedSnapshot", true)
	tlatrace.EmitPeer("OfferSnapshot", localServerID, st, pr)
}

// emitApplyChunk fires after a chunk has been applied. Variant depends on
// whether the chunk's sender is tagged Byzantine.
func emitApplyChunk(chunk *chunk) {
	if !tlatrace.IsEnabled() || chunk == nil {
		return
	}
	pr := tlatrace.NewPeer().
		Set("id", string(chunk.Sender)).
		Set("idx", int(chunk.Index)).
		Set("bytes", len(chunk.Chunk))
	name := "ApplyChunk"
	if tlatrace.IsPeerByz(string(chunk.Sender)) {
		name = "ByzCorruptChunk"
	}
	tlatrace.EmitPeer(name, localServerID, nil, pr)
}

// emitVerifyAppFails fires when verifyApp returned an error.
func emitVerifyAppFails() {
	if !tlatrace.IsEnabled() {
		return
	}
	st := tlatrace.NewState().
		Set("persistStage", "none").
		Set("acceptedSnapshot", nil)
	tlatrace.EmitState("VerifyAppFails", localServerID, st)
}

// emitByzOrHonestSnapshotAdd fires after the snapshot pool accepted an offer.
// Emits ByzOfferBogusSnapshot only when the sender is tagged as Byzantine.
func emitByzOrHonestSnapshotAdd(peerID p2p.ID, snap *snapshot) {
	if !tlatrace.IsEnabled() || snap == nil {
		return
	}
	if !tlatrace.IsPeerByz(string(peerID)) {
		return
	}
	pr := tlatrace.NewPeer().
		Set("id", string(peerID)).
		Set("height", int64(snap.Height)).
		Set("hash", tlatrace.HexOrNil(snap.Hash))
	tlatrace.EmitPeer("ByzOfferBogusSnapshot", localServerID, nil, pr)
}
