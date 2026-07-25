package types

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

// emitVerifyCommitTrustingEarly fires when the trusting verifier returned nil
// via the early-exit path. validCount is the number of verified sigs that
// reached threshold; forgedCount is the number of trailing un-verified sigs.
func emitVerifyCommitTrustingEarly(height int64, validCount, forgedCount int) {
	if !tlatrace.IsEnabled() {
		return
	}
	msg := tlatrace.NewMsg().
		Set("height", height).
		Set("validCount", validCount).
		Set("forgedCount", forgedCount)
	tlatrace.EmitMsg("VerifyCommit_TrustingEarly", localServerID, nil, msg)
}

// emitVerifyCommitAllSignatures fires when the strict path returned nil.
func emitVerifyCommitAllSignatures(height int64, validCount int) {
	if !tlatrace.IsEnabled() {
		return
	}
	msg := tlatrace.NewMsg().
		Set("height", height).
		Set("validCount", validCount)
	tlatrace.EmitMsg("VerifyCommit_AllSignatures", localServerID, nil, msg)
}

// emitByzCommitFlood fires when a commit's signature count exceeds a
// conservative threshold (2*ValidatorSet size).
func emitByzCommitFlood(source string, height int64, numForged int) {
	if !tlatrace.IsEnabled() {
		return
	}
	msg := tlatrace.NewMsg().
		Set("source", source).
		Set("height", height).
		Set("numForged", numForged)
	tlatrace.EmitMsg("ByzCommitFlood", localServerID, nil, msg)
}

// emitIncrementProposerPriorityClip fires when safeAddClip/safeSubClip
// saturated. validator is the validator address whose priority hit the clip.
func emitIncrementProposerPriorityClip(validator string) {
	if !tlatrace.IsEnabled() {
		return
	}
	msg := tlatrace.NewMsg().Set("validator", validator)
	tlatrace.EmitMsg("IncrementProposerPriority_Clip", localServerID, nil, msg)
}
