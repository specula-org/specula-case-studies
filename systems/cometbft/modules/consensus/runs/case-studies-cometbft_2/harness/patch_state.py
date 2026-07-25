#!/usr/bin/env python3
"""Patch artifact consensus/state.go for round-2 BFT trace instrumentation.

Insertions are idempotent: the script first checks for marker comments
("// TLA+ trace:") and rewrites only if absent.

Patches:
  1. Add `encoding/hex` import.
  2. Add traceLogger / byzClock / byzSignedVotes fields to *State struct.
  3. Add SetTraceLogger method.
  4. Insert Emit calls at:
       - handleTimeout switch (HandleTimeoutPropose / Prevote / Precommit)
       - enterNewRound (after eventBus.PublishEventNewRound)
       - enterPropose (defer block)
       - enterPrevote (defer block)
       - enterPrevoteWait (defer block)
       - enterPrecommit (defer block)
       - enterPrecommitWait (defer block)
       - enterCommit (defer block)
       - finalizeCommit (after updateToState)
       - defaultSetProposal (after `cs.Proposal = proposal`)
       - tryAddVote (DetectEquivocation after ReportConflictingVotes)
       - addVote (ReceivePrevote / ReceivePrecommit after switch)
"""
import re
import sys

if len(sys.argv) != 2:
    sys.exit("Usage: patch_state.py <state.go>")

path = sys.argv[1]
with open(path) as f:
    src = f.read()

if "// TLA+ trace:" in src:
    print("(state.go already patched; skipping)")
    sys.exit(0)


def insert_after(text, anchor, payload):
    """Insert `payload` after the line containing `anchor`. Errors on miss."""
    idx = text.find(anchor)
    if idx < 0:
        raise SystemExit(f"anchor not found: {anchor!r}")
    line_end = text.find("\n", idx)
    return text[: line_end + 1] + payload + text[line_end + 1 :]


def replace_once(text, pattern, replacement):
    n_replaced = 0

    def sub_fn(m):
        nonlocal n_replaced
        n_replaced += 1
        return replacement

    new = re.sub(pattern, sub_fn, text, count=1)
    if n_replaced != 1:
        raise SystemExit(f"pattern not matched exactly once: {pattern!r}")
    return new


# --- 1. encoding/hex import ----------------------------------------------------
src = src.replace(
    '\t"errors"\n',
    '\t"encoding/hex"\n\t"errors"\n',
    1,
)
if '"encoding/hex"' not in src:
    raise SystemExit("failed to add encoding/hex import")

# --- 2. struct fields + SetTraceLogger ----------------------------------------
struct_anchor = "offlineStateSyncHeight int64"
src = insert_after(
    src,
    struct_anchor,
    """
\t// traceLogger emits NDJSON events for TLA+ trace validation (round 2).
\ttraceLogger *TraceLogger

\t// byzClock is a harness-driven local clock (Family 5 evidence-expiry race).
\tbyzClock int64

\t// byzSignedVotes shadows VoteRecord(...) in spec/base.tla — every vote
\t// (honest or Byzantine) the harness has observed being signed by `signer`.
\tbyzSignedVotes map[string][]byzSignedVote
""",
)

# Add SetTraceLogger / accessor methods after the existing SetEventBus method.
set_eventbus_end = src.find("func (cs *State) SetEventBus(")
end_brace = src.find("\n}\n", set_eventbus_end) + 3
methods_block = """
// SetTraceLogger installs the NDJSON trace emitter (round-2 harness).
func (cs *State) SetTraceLogger(tl *TraceLogger) {
\tcs.traceLogger = tl
}

// ByzClock returns the current harness clock counter (Family 5).
func (cs *State) ByzClock() int64 { return cs.byzClock }

// ByzAdvanceClockAndEmit advances the harness clock by one tick and emits an
// AdvanceClock trace event from the caller's perspective.
func (cs *State) ByzAdvanceClockAndEmit() {
\tcs.byzAdvanceClock()
\tcs.EmitAdvanceClock(cs.traceNodeID())
}

"""
src = src[:end_brace] + methods_block + src[end_brace:]

# --- 3. handleTimeout: emit for Propose/Prevote/Precommit timeouts ------------
src = src.replace(
    """\t\tcs.enterPrevote(ti.Height, ti.Round)

\tcase cstypes.RoundStepPrevoteWait:""",
    """\t\t// TLA+ trace: HandleTimeoutPropose
\t\tcs.traceLogger.Emit(&TraceEvent{
\t\t\tName:  "HandleTimeoutPropose",
\t\t\tNid:   cs.traceNodeID(),
\t\t\tState: cs.captureState(),
\t\t})

\t\tcs.enterPrevote(ti.Height, ti.Round)

\tcase cstypes.RoundStepPrevoteWait:""",
    1,
)
src = src.replace(
    """\t\tcs.enterPrecommit(ti.Height, ti.Round)

\tcase cstypes.RoundStepPrecommitWait:""",
    """\t\t// TLA+ trace: HandleTimeoutPrevote
\t\tcs.traceLogger.Emit(&TraceEvent{
\t\t\tName:  "HandleTimeoutPrevote",
\t\t\tNid:   cs.traceNodeID(),
\t\t\tState: cs.captureState(),
\t\t})

\t\tcs.enterPrecommit(ti.Height, ti.Round)

\tcase cstypes.RoundStepPrecommitWait:""",
    1,
)
src = src.replace(
    """\t\tcs.emitPrecommitTimeoutMetrics(ti.Round)
\t\tcs.enterPrecommit(ti.Height, ti.Round)
\t\tcs.enterNewRound(ti.Height, ti.Round+1)""",
    """\t\t// TLA+ trace: HandleTimeoutPrecommit
\t\tcs.traceLogger.Emit(&TraceEvent{
\t\t\tName:  "HandleTimeoutPrecommit",
\t\t\tNid:   cs.traceNodeID(),
\t\t\tState: cs.captureState(),
\t\t})

\t\tcs.emitPrecommitTimeoutMetrics(ti.Round)
\t\tcs.enterPrecommit(ti.Height, ti.Round)
\t\tcs.enterNewRound(ti.Height, ti.Round+1)""",
    1,
)

# --- 4. enterNewRound -- emit after eventBus.PublishEventNewRound -------------
src = src.replace(
    """\tif err := cs.eventBus.PublishEventNewRound(cs.NewRoundEvent()); err != nil {
\t\tcs.Logger.Error("failed publishing new round", "err", err)
\t}""",
    """\t// TLA+ trace: EnterNewRound
\tcs.traceLogger.Emit(&TraceEvent{
\t\tName:  "EnterNewRound",
\t\tNid:   cs.traceNodeID(),
\t\tState: cs.captureState(),
\t})

\tif err := cs.eventBus.PublishEventNewRound(cs.NewRoundEvent()); err != nil {
\t\tcs.Logger.Error("failed publishing new round", "err", err)
\t}""",
    1,
)

# --- 5. enterPropose defer block ----------------------------------------------
src = src.replace(
    """\tdefer func() {
\t\t// Done enterPropose:
\t\tcs.updateRoundStep(round, cstypes.RoundStepPropose)
\t\tcs.newStep()

\t\t// If we have the whole proposal + POL, then goto Prevote now.""",
    """\tdefer func() {
\t\t// Done enterPropose:
\t\tcs.updateRoundStep(round, cstypes.RoundStepPropose)
\t\tcs.newStep()

\t\t// TLA+ trace: EnterPropose
\t\tcs.traceLogger.Emit(&TraceEvent{
\t\t\tName:  "EnterPropose",
\t\t\tNid:   cs.traceNodeID(),
\t\t\tState: cs.captureState(),
\t\t})

\t\t// If we have the whole proposal + POL, then goto Prevote now.""",
    1,
)

# --- 6. enterPrevote defer block ----------------------------------------------
src = src.replace(
    """\tdefer func() {
\t\t// Done enterPrevote:
\t\tcs.updateRoundStep(round, cstypes.RoundStepPrevote)
\t\tcs.newStep()
\t}()""",
    """\tdefer func() {
\t\t// Done enterPrevote:
\t\tcs.updateRoundStep(round, cstypes.RoundStepPrevote)
\t\tcs.newStep()

\t\t// TLA+ trace: EnterPrevote
\t\tcs.traceLogger.Emit(&TraceEvent{
\t\t\tName:  "EnterPrevote",
\t\t\tNid:   cs.traceNodeID(),
\t\t\tState: cs.captureState(),
\t\t})
\t}()""",
    1,
)

# --- 7. enterPrevoteWait defer block ------------------------------------------
src = src.replace(
    """\tdefer func() {
\t\t// Done enterPrevoteWait:
\t\tcs.updateRoundStep(round, cstypes.RoundStepPrevoteWait)
\t\tcs.newStep()
\t}()""",
    """\tdefer func() {
\t\t// Done enterPrevoteWait:
\t\tcs.updateRoundStep(round, cstypes.RoundStepPrevoteWait)
\t\tcs.newStep()

\t\t// TLA+ trace: EnterPrevoteWait
\t\tcs.traceLogger.Emit(&TraceEvent{
\t\t\tName:  "EnterPrevoteWait",
\t\t\tNid:   cs.traceNodeID(),
\t\t\tState: cs.captureState(),
\t\t})
\t}()""",
    1,
)

# --- 8. enterPrecommit defer block --------------------------------------------
src = src.replace(
    """\tdefer func() {
\t\t// Done enterPrecommit:
\t\tcs.updateRoundStep(round, cstypes.RoundStepPrecommit)
\t\tcs.newStep()
\t}()""",
    """\tdefer func() {
\t\t// Done enterPrecommit:
\t\tcs.updateRoundStep(round, cstypes.RoundStepPrecommit)
\t\tcs.newStep()

\t\t// TLA+ trace: EnterPrecommit
\t\tcs.traceLogger.Emit(&TraceEvent{
\t\t\tName:  "EnterPrecommit",
\t\t\tNid:   cs.traceNodeID(),
\t\t\tState: cs.captureState(),
\t\t})
\t}()""",
    1,
)

# --- 9. enterPrecommitWait defer block ----------------------------------------
src = src.replace(
    """\tdefer func() {
\t\t// Done enterPrecommitWait:
\t\tcs.TriggeredTimeoutPrecommit = true
\t\tcs.newStep()
\t}()""",
    """\tdefer func() {
\t\t// Done enterPrecommitWait:
\t\tcs.TriggeredTimeoutPrecommit = true
\t\tcs.newStep()

\t\t// TLA+ trace: EnterPrecommitWait
\t\tcs.traceLogger.Emit(&TraceEvent{
\t\t\tName:  "EnterPrecommitWait",
\t\t\tNid:   cs.traceNodeID(),
\t\t\tState: cs.captureState(),
\t\t})
\t}()""",
    1,
)

# --- 10. enterCommit defer block ----------------------------------------------
src = src.replace(
    """\t\tcs.newStep()

\t\t// Maybe finalize immediately.
\t\tcs.tryFinalizeCommit(height)
\t}()""",
    """\t\tcs.newStep()

\t\t// TLA+ trace: EnterCommit
\t\tcs.traceLogger.Emit(&TraceEvent{
\t\t\tName:  "EnterCommit",
\t\t\tNid:   cs.traceNodeID(),
\t\t\tState: cs.captureState(),
\t\t})

\t\t// Maybe finalize immediately.
\t\tcs.tryFinalizeCommit(height)
\t}()""",
    1,
)

# --- 11. finalizeCommit -- emit after updateToState ---------------------------
src = src.replace(
    """\tfail.Fail() // XXX

\t// Private validator might have changed it's key pair => refetch pubkey.""",
    """\t// TLA+ trace: FinalizeCommit (after updateToState)
\tcs.traceLogger.Emit(&TraceEvent{
\t\tName:  "FinalizeCommit",
\t\tNid:   cs.traceNodeID(),
\t\tState: cs.captureState(),
\t})

\tfail.Fail() // XXX

\t// Private validator might have changed it's key pair => refetch pubkey.""",
    1,
)

# --- 12. defaultSetProposal -- emit after `cs.Proposal = proposal` ------------
src = src.replace(
    """\tcs.Logger.Info("received proposal", "proposal", proposal, "proposer", pubKey.Address())
\treturn nil
}""",
    """\tcs.Logger.Info("received proposal", "proposal", proposal, "proposer", pubKey.Address())

\t// TLA+ trace: ReceiveProposal
\tcs.traceLogger.Emit(&TraceEvent{
\t\tName:  "ReceiveProposal",
\t\tNid:   cs.traceNodeID(),
\t\tState: cs.captureState(),
\t\tMsg: &TraceMsgFields{
\t\t\tSource:   hex.EncodeToString(pubKey.Address()),
\t\t\tDest:     cs.traceNodeID(),
\t\t\tType:     "ProposalMsg",
\t\t\tValue:    blockHashStr(proposal.BlockID.Hash),
\t\t\tRound:    proposal.Round,
\t\t\tPolRound: proposal.POLRound,
\t\t},
\t})

\treturn nil
}""",
    1,
)

# --- 13. tryAddVote -- DetectEquivocation after ReportConflictingVotes --------
src = src.replace(
    """\t\t\t// report conflicting votes to the evidence pool
\t\t\tcs.evpool.ReportConflictingVotes(voteErr.VoteA, voteErr.VoteB)""",
    """\t\t\t// report conflicting votes to the evidence pool
\t\t\tcs.evpool.ReportConflictingVotes(voteErr.VoteA, voteErr.VoteB)

\t\t\t// TLA+ trace: DetectEquivocation
\t\t\tcs.EmitDetectEquivocation(
\t\t\t\tcs.traceNodeID(),
\t\t\t\thex.EncodeToString(vote.ValidatorAddress),
\t\t\t\tvote.Height,
\t\t\t\tvote.Round,
\t\t\t)""",
    1,
)

# --- 14. addVote -- emit ReceivePrevote / ReceivePrecommit after FireEvent ----
src = src.replace(
    """\tcs.evsw.FireEvent(types.EventVote, vote)

\tswitch vote.Type {
\tcase cmtproto.PrevoteType:""",
    """\tcs.evsw.FireEvent(types.EventVote, vote)

\t// TLA+ trace: ReceivePrevote / ReceivePrecommit
\tif vote.Type == cmtproto.PrevoteType {
\t\tcs.traceLogger.Emit(&TraceEvent{
\t\t\tName:  "ReceivePrevote",
\t\t\tNid:   cs.traceNodeID(),
\t\t\tState: cs.captureState(),
\t\t\tMsg: &TraceMsgFields{
\t\t\t\tSource: hex.EncodeToString(vote.ValidatorAddress),
\t\t\t\tDest:   cs.traceNodeID(),
\t\t\t\tType:   "PrevoteMsg",
\t\t\t\tValue:  blockHashStr(vote.BlockID.Hash),
\t\t\t\tRound:  vote.Round,
\t\t\t},
\t\t})
\t} else if vote.Type == cmtproto.PrecommitType {
\t\tveSentinel := "NoVE"
\t\tif vote.BlockID.Hash != nil {
\t\t\tveSentinel = "ValidVE"
\t\t}
\t\tcs.traceLogger.Emit(&TraceEvent{
\t\t\tName:  "ReceivePrecommit",
\t\t\tNid:   cs.traceNodeID(),
\t\t\tState: cs.captureState(),
\t\t\tMsg: &TraceMsgFields{
\t\t\t\tSource: hex.EncodeToString(vote.ValidatorAddress),
\t\t\t\tDest:   cs.traceNodeID(),
\t\t\t\tType:   "PrecommitMsg",
\t\t\t\tValue:  blockHashStr(vote.BlockID.Hash),
\t\t\t\tRound:  vote.Round,
\t\t\t\tVE:     veSentinel,
\t\t\t},
\t\t})
\t}

\tswitch vote.Type {
\tcase cmtproto.PrevoteType:""",
    1,
)

with open(path, "w") as f:
    f.write(src)

print("(patched: state.go)")
