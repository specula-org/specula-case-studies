package consensus

import (
	"os"
	"strings"

	cstypes "github.com/cometbft/cometbft/consensus/types"
	tlatrace "github.com/cometbft/cometbft/libs/tla_trace"
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

func stepName(s cstypes.RoundStepType) string {
	switch s {
	case cstypes.RoundStepNewHeight:
		return "StepNewHeight"
	case cstypes.RoundStepNewRound:
		return "StepNewRound"
	case cstypes.RoundStepPropose:
		return "StepPropose"
	case cstypes.RoundStepPrevote:
		return "StepPrevote"
	case cstypes.RoundStepPrevoteWait:
		return "StepPrevoteWait"
	case cstypes.RoundStepPrecommit:
		return "StepPrecommit"
	case cstypes.RoundStepPrecommitWait:
		return "StepPrecommitWait"
	case cstypes.RoundStepCommit:
		return "StepCommit"
	default:
		// fall back to the impl string with a "Step" prefix matching MC.cfg
		return "Step" + strings.TrimPrefix(s.String(), "RoundStep")
	}
}

// emitEnter fires after a round-step transition (cs.Step has been mutated).
// CONTRACT: caller holds cs.mtx (the receiveRoutine loop is single-threaded).
func (cs *State) emitEnter(name string) {
	if !tlatrace.IsEnabled() {
		return
	}
	st := tlatrace.NewState().
		Set("height", cs.Height).
		Set("round", int(cs.Round)).
		Set("step", stepName(cs.Step))
	tlatrace.EmitState(name, localServerID, st)
}

// ----- F1.7 SwitchToConsensus four-step split --------------------------------

func (conR *Reactor) emitSwitchStep(name string, mode string, waitSync, consensusStarted bool) {
	if !tlatrace.IsEnabled() {
		return
	}
	st := tlatrace.NewState().
		Set("mode", mode).
		Set("waitSync", waitSync).
		Set("consensusStarted", consensusStarted)
	tlatrace.EmitState(name, localServerID, st)
}

// ----- F3 Reactor cached round-state events ----------------------------------

func (conR *Reactor) emitEventVoteBroadcast(vh int64, vr int32, vt string, idx int32) {
	if !tlatrace.IsEnabled() {
		return
	}
	msg := tlatrace.NewMsg().
		Set("height", vh).
		Set("round", int(vr)).
		Set("voteType", vt).
		Set("idx", int(idx))
	st := tlatrace.NewState().Set("pendingRSUpdate", true)
	tlatrace.EmitMsg("EventVote_Broadcast", localServerID, st, msg)
}

func (conR *Reactor) emitEventVoteUpdateCachedRS(cachedHeight int64) {
	if !tlatrace.IsEnabled() {
		return
	}
	st := tlatrace.NewState().
		Set("cachedHeight", cachedHeight).
		Set("pendingRSUpdate", false)
	tlatrace.EmitState("EventVote_UpdateCachedRS", localServerID, st)
}

func (conR *Reactor) emitEventNewRoundStepUpdate(cachedHeight int64, h int64, r int32, step cstypes.RoundStepType) {
	if !tlatrace.IsEnabled() {
		return
	}
	st := tlatrace.NewState().
		Set("cachedHeight", cachedHeight).
		Set("height", h).
		Set("round", int(r)).
		Set("step", stepName(step))
	tlatrace.EmitState("EventNewRoundStep_Update", localServerID, st)
}

// ----- MempoolEnable shim ----------------------------------------------------

// EmitMempoolEnable is exported so node/setup.go can fire it without depending
// on consensus internals (instrumentation point is in node, not consensus).
func EmitMempoolEnable(nid string, enabled, consensusStarted bool, mode string) {
	if !tlatrace.IsEnabled() {
		return
	}
	st := tlatrace.NewState().
		Set("mempoolEnabled", enabled).
		Set("mode", mode).
		Set("consensusStarted", consensusStarted)
	tlatrace.EmitState("MempoolEnable", nid, st)
}
