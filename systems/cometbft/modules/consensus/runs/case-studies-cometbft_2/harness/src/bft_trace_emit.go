package consensus

// bft_trace_emit.go — harness-side helpers that emit Byzantine and BFT-related
// trace events (round 2). These run directly from test scenarios; they do not
// alter real consensus state machine logic, but they DO mutate auxiliary
// instrumentation state (cs.byzClock, cs.byzSignedVotes,
// cs.byzPendingEvidence) so that subsequent honest emissions reflect the
// composed adversarial timeline.
//
// Each helper corresponds 1:1 to a wrapper in spec/Trace.tla; the trace
// envelope it produces is what ValidatePostState / ValidateByzVoteSigned read.

// EmitByzEquivocate emits a ByzEquivocate event for signer `signer` at
// (height, round) for value `value`. The caller emits this after the second
// conflicting precommit has been posted to the broadcast queue. Returns the
// emitted byzVote record (for further composition with selective dissem.).
func (cs *State) EmitByzEquivocate(signerNid string, height int64, round int32, value, ve string) {
	cs.byzAddSignedVote(signerNid, "precommit", height, round, value, ve)
	cs.traceLogger.Emit(&TraceEvent{
		Name:  "ByzEquivocate",
		Nid:   signerNid,
		State: cs.captureState(),
		ByzVote: &TraceByzVote{
			VType:  "precommit",
			Height: height,
			Round:  round,
			Value:  value,
			VE:     ve,
		},
	})
}

// EmitByzSelectiveDisseminate emits when a Byzantine has split-broadcast two
// conflicting precommits to disjoint partitions. The state snapshot reflects
// the post-broadcast view; partition is implicit in the `dest` field of the
// underlying messages (recorded as part of the bag).
func (cs *State) EmitByzSelectiveDisseminate(signerNid string, height int64, round int32, value, dest string) {
	cs.traceLogger.Emit(&TraceEvent{
		Name:  "ByzSelectiveDisseminate",
		Nid:   signerNid,
		State: cs.captureState(),
		Msg: &TraceMsgFields{
			Source: signerNid,
			Dest:   dest,
			Type:   "PrecommitMsg",
			Value:  value,
			Round:  round,
		},
		ByzVote: &TraceByzVote{
			VType:  "precommit",
			Height: height,
			Round:  round,
			Value:  value,
		},
	})
}

// EmitByzAmnesia emits when a Byzantine has signed a precommit at (h, r2) for
// a different block than at (h, r1<r2), bypassing privval CheckHRS.
func (cs *State) EmitByzAmnesia(signerNid string, height int64, r2 int32, newValue, ve string) {
	cs.byzAddSignedVote(signerNid, "precommit", height, r2, newValue, ve)
	cs.traceLogger.Emit(&TraceEvent{
		Name:  "ByzAmnesia",
		Nid:   signerNid,
		State: cs.captureState(),
		ByzVote: &TraceByzVote{
			VType:  "precommit",
			Height: height,
			Round:  r2,
			Value:  newValue,
			VE:     ve,
		},
	})
}

// EmitWALTailTruncate emits when repairWalFile has truncated `k` records from
// the tail of the WAL.
func (cs *State) EmitWALTailTruncate(nid string, k int) {
	cs.traceLogger.Emit(&TraceEvent{
		Name:  "WALTailTruncate",
		Nid:   nid,
		State: cs.captureState(),
		K:     intPtr(k),
	})
}

// EmitByzAttachSameVEToBoth emits when a Byzantine attaches the same VE bytes
// to two conflicting precommits at (h, r).
func (cs *State) EmitByzAttachSameVEToBoth(signerNid string, height int64, round int32) {
	cs.traceLogger.Emit(&TraceEvent{
		Name:  "ByzAttachSameVEToBoth",
		Nid:   signerNid,
		State: cs.captureState(),
		ByzVote: &TraceByzVote{
			VType:  "precommit",
			Height: height,
			Round:  round,
		},
	})
}

// EmitByzLateAddPrecommitWithBadVE emits when a Byzantine submits a precommit
// to LastCommit after height h+1 has begun, with an invalid VE.
func (cs *State) EmitByzLateAddPrecommitWithBadVE(signerNid string, height int64, round int32, value, dest string) {
	cs.traceLogger.Emit(&TraceEvent{
		Name:  "ByzLateAddPrecommitWithBadVE",
		Nid:   signerNid,
		State: cs.captureState(),
		Msg: &TraceMsgFields{
			Source:  signerNid,
			Dest:    dest,
			Type:    "PrecommitMsg",
			Value:   value,
			Round:   round,
			VE:      "InvalidVE",
			LateAdd: true,
		},
		ByzVote: &TraceByzVote{
			VType:  "precommit",
			Height: height,
			Round:  round,
			Value:  value,
			VE:     "InvalidVE",
		},
	})
}

// EmitByzReplaySelfVE emits when a Byzantine re-signs a vote envelope at a
// new round (newR) using the previously-signed VE bytes (oldR).
func (cs *State) EmitByzReplaySelfVE(signerNid string, height int64, oldR, newR int32, value string) {
	cs.byzAddSignedVote(signerNid, "precommit", height, newR, value, "ValidVE")
	cs.traceLogger.Emit(&TraceEvent{
		Name:  "ByzReplaySelfVE",
		Nid:   signerNid,
		State: cs.captureState(),
		ByzVote: &TraceByzVote{
			VType:    "precommit",
			Height:   height,
			Round:    newR,
			OldRound: oldR,
			NewRound: newR,
			Value:    value,
			VE:       "ValidVE",
		},
	})
}

// EmitByzLunaticForkHeader emits when ≥1/3 of nextValidators(h-1) have signed
// a forged header for height h whose LastBlockID does not match the canonical
// chain. The lightClient channel receives the forged HeaderMsg.
func (cs *State) EmitByzLunaticForkHeader(signerNid string, height int64, fakeLastBlock, lightClientDest string) {
	cs.traceLogger.Emit(&TraceEvent{
		Name: "ByzLunaticForkHeader",
		Nid:  signerNid,
		State: TraceStateSnap{
			Height:      height,
			Round:       0,
			Step:        "NewHeight",
			LockedRound: -1,
			LockedValue: "nil",
			ValidRound:  -1,
			ValidValue:  "nil",
		},
		Msg: &TraceMsgFields{
			Source: signerNid,
			Dest:   lightClientDest,
			Type:   "HeaderMsg",
			Value:  fakeLastBlock,
		},
	})
}

// EmitLightClientVerify emits when a light client has updated its trusted
// header (the bug-relevant outcome).
func EmitLightClientVerify(tl *TraceLogger, clientID string, newHeight int64, value string) {
	tl.Emit(&TraceEvent{
		Name: "LightClientVerify",
		Nid:  clientID,
		State: TraceStateSnap{
			Height:      newHeight,
			Round:       0,
			Step:        "NewHeight",
			LockedRound: -1,
			LockedValue: value,
			ValidRound:  -1,
			ValidValue:  "nil",
		},
	})
}

// EmitByzInjectInvalidEvidence emits when a Byzantine sends fabricated
// evidence to peer `dest`.
func (cs *State) EmitByzInjectInvalidEvidence(signerNid, dest string) {
	cs.traceLogger.Emit(&TraceEvent{
		Name:  "ByzInjectInvalidEvidence",
		Nid:   signerNid,
		State: cs.captureState(),
		Msg: &TraceMsgFields{
			Source: signerNid,
			Dest:   dest,
			EvType: "InvalidEv",
		},
	})
}

// EmitByzFloodEvidence emits when a Byzantine floods many valid duplicate-vote
// evidence records.
func (cs *State) EmitByzFloodEvidence(signerNid, dest string, height int64) {
	cs.traceLogger.Emit(&TraceEvent{
		Name:  "ByzFloodEvidence",
		Nid:   signerNid,
		State: cs.captureState(),
		Msg: &TraceMsgFields{
			Source: signerNid,
			Dest:   dest,
			EvType: "DuplicateVoteEv",
		},
	})
}

// EmitEvidenceExpiryRace emits when an honest sender broadcasts evidence its
// reactor filter accepts but the receiver's verifier rejects (height-only vs
// height-AND-time filter divergence).
func (cs *State) EmitEvidenceExpiryRace(sender, receiver string, evHeight int64) {
	cs.traceLogger.Emit(&TraceEvent{
		Name:  "EvidenceExpiryRace",
		Nid:   sender,
		State: cs.captureState(),
		Msg: &TraceMsgFields{
			Source: sender,
			Dest:   receiver,
			EvType: "DuplicateVoteEv",
		},
	})
}

// EmitCrashDuringConsensusBuffer emits when an honest validator crashes
// between ReportConflictingVotes and the next pool.Update.
func (cs *State) EmitCrashDuringConsensusBuffer(nid string) {
	cs.traceLogger.Emit(&TraceEvent{
		Name:  "CrashDuringConsensusBuffer",
		Nid:   nid,
		State: cs.captureState(),
	})
}

// EmitProposerExcludeEvidence emits when a Byzantine proposer fails to
// include pending evidence in the proposal block.
func (cs *State) EmitProposerExcludeEvidence(nid string) {
	cs.traceLogger.Emit(&TraceEvent{
		Name:  "ProposerExcludeEvidence",
		Nid:   nid,
		State: cs.captureState(),
	})
}

// EmitAdvanceClock emits when a validator's local clock advances by one tick.
// The validatorClock is sourced from cs.byzClock; callers must increment
// cs.byzClock before calling.
func (cs *State) EmitAdvanceClock(nid string) {
	cs.traceLogger.Emit(&TraceEvent{
		Name:  "AdvanceClock",
		Nid:   nid,
		State: cs.captureState(),
	})
}

// EmitCommitEvidence emits when pending evidence becomes committed at the
// honest proposer of the next height.
func (cs *State) EmitCommitEvidence(nid string) {
	cs.traceLogger.Emit(&TraceEvent{
		Name:  "CommitEvidence",
		Nid:   nid,
		State: cs.captureState(),
	})
}

// EmitDetectEquivocation emits when consensus tryAddVote catches a
// ConflictingVotes error and forwards it to evpool.ReportConflictingVotes.
func (cs *State) EmitDetectEquivocation(nid string, offender string, height int64, round int32) {
	cs.traceLogger.Emit(&TraceEvent{
		Name:  "DetectEquivocation",
		Nid:   nid,
		State: cs.captureState(),
		Msg: &TraceMsgFields{
			Source: offender,
			Dest:   nid,
			EvType: "DuplicateVoteEv",
			Round:  round,
		},
		ByzVote: &TraceByzVote{
			VType:  "precommit",
			Height: height,
			Round:  round,
		},
	})
}

// EmitProcessConsensusBuffer emits each iteration of the inner flush loop in
// evpool.processConsensusBuffer.
func (cs *State) EmitProcessConsensusBuffer(nid string) {
	cs.traceLogger.Emit(&TraceEvent{
		Name:  "ProcessConsensusBuffer",
		Nid:   nid,
		State: cs.captureState(),
	})
}

// EmitByzProposeAlternating emits when a Byzantine proposer offers a chosen
// block (bypassing validValue reuse).
func (cs *State) EmitByzProposeAlternating(signerNid string, blockChoice string, dest string) {
	cs.traceLogger.Emit(&TraceEvent{
		Name:  "ByzProposeAlternating",
		Nid:   signerNid,
		State: cs.captureState(),
		Msg: &TraceMsgFields{
			Source:   signerNid,
			Dest:     dest,
			Type:     "ProposalMsg",
			Value:    blockChoice,
			Round:    cs.Round,
			PolRound: -1,
		},
	})
}

// EmitByzPolkaForUnknownBlock emits when a Byzantine subset sends prevotes
// for a block the target validator does not have.
func EmitByzPolkaForUnknownBlock(tl *TraceLogger, sourceNid, dest string, height int64, round int32, blockX string) {
	tl.Emit(&TraceEvent{
		Name: "ByzPolkaForUnknownBlock",
		Nid:  sourceNid,
		State: TraceStateSnap{
			Height:      height,
			Round:       round,
			Step:        "Prevote",
			LockedRound: -1,
			LockedValue: "nil",
			ValidRound:  -1,
			ValidValue:  "nil",
		},
		Msg: &TraceMsgFields{
			Source: sourceNid,
			Dest:   dest,
			Type:   "PrevoteMsg",
			Value:  blockX,
			Round:  round,
		},
	})
}

// EmitByzPOLRoundGtRound emits when a Byzantine proposer sets POLRound ≥ Round.
func (cs *State) EmitByzPOLRoundGtRound(signerNid string, dest, value string, badPolRound int32) {
	cs.traceLogger.Emit(&TraceEvent{
		Name:  "ByzPOLRoundGtRound",
		Nid:   signerNid,
		State: cs.captureState(),
		Msg: &TraceMsgFields{
			Source:   signerNid,
			Dest:     dest,
			Type:     "ProposalMsg",
			Value:    value,
			Round:    cs.Round,
			PolRound: badPolRound,
		},
	})
}

// EmitCrash emits a Crash event for nid.
func (cs *State) EmitCrash(nid string) {
	cs.traceLogger.Emit(&TraceEvent{
		Name:  "Crash",
		Nid:   nid,
		State: cs.captureState(),
	})
}

// EmitRecover emits a Recover event for nid.
func (cs *State) EmitRecover(nid string) {
	cs.traceLogger.Emit(&TraceEvent{
		Name:  "Recover",
		Nid:   nid,
		State: cs.captureState(),
	})
}

// EmitRoundSkip emits a RoundSkip event (prevote- or precommit-driven).
func (cs *State) EmitRoundSkip(nid string) {
	cs.traceLogger.Emit(&TraceEvent{
		Name:  "RoundSkip",
		Nid:   nid,
		State: cs.captureState(),
	})
}
