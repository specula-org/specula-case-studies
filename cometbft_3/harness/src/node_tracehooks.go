package node

import (
	"os"

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

func emitBootstrap(persistedH int64) {
	if !tlatrace.IsEnabled() {
		return
	}
	st := tlatrace.NewState().
		Set("persistStage", "stateOnly").
		Set("persistedStateH", persistedH)
	tlatrace.EmitState("PerformStateSync_Bootstrap", localServerID, st)
}

func emitSaveSeenCommit(seenH int64) {
	if !tlatrace.IsEnabled() {
		return
	}
	st := tlatrace.NewState().
		Set("persistStage", "commitSaved").
		Set("seenCommitHeight", seenH)
	tlatrace.EmitState("PerformStateSync_SaveSeenCommit", localServerID, st)
}

func emitEnableBlockSync(storeH int64) {
	if !tlatrace.IsEnabled() {
		return
	}
	st := tlatrace.NewState().
		Set("persistStage", "enabled").
		Set("blockStoreHeight", storeH).
		Set("mode", "blocksync")
	tlatrace.EmitState("PerformStateSync_EnableBlockSync", localServerID, st)
}

func emitClearOfflineMarker() {
	if !tlatrace.IsEnabled() {
		return
	}
	st := tlatrace.NewState().Set("offlineMarker", 0)
	tlatrace.EmitState("ClearOfflineMarker", localServerID, st)
}

func emitMempoolEnable(enabled bool) {
	if !tlatrace.IsEnabled() {
		return
	}
	st := tlatrace.NewState().
		Set("mempoolEnabled", enabled).
		Set("mode", "consensus").
		Set("consensusStarted", true)
	tlatrace.EmitState("MempoolEnable", localServerID, st)
}
