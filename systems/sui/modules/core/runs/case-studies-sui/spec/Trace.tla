--------------------------- MODULE Trace ---------------------------
(*
 * Trace validation specification for Sui Mysticeti consensus.
 *
 * Replays implementation traces against the base spec to verify the
 * spec can reproduce every observed state transition.
 *
 * Trace format: NDJSON with tag="trace" and event records containing:
 *   - event.name: action name (HonestPropose, DeliverBlock, etc.)
 *   - event.nid:  validator ID
 *   - event.state: post-action state snapshot
 *   - event.block: block fields (for block-related events)
 *   - event.slot:  slot fields (for decide events)
 *   - event.leader: leader ref (for linearize events)
 *
 * See instrumentation-spec.md for the full trace event schema.
 *)

EXTENDS base, Json, IOUtils, Sequences, TLC

\* ============================================================================
\* TRACE LOADING
\* ============================================================================

\* Read JSON file path from environment variable or use default.
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

\* Load NDJSON, filter to trace events only.
TraceLog == TLCEval(
    LET all == ndJsonDeserialize(JsonFile)
    IN SelectSeq(all, LAMBDA x :
        /\ "tag" \in DOMAIN x
        /\ x.tag = "trace"
        /\ "event" \in DOMAIN x))

ASSUME Len(TraceLog) > 0

\* ============================================================================
\* TRACE CURSOR
\* ============================================================================

VARIABLE l       \* Current position in TraceLog (1-indexed)

traceVars == <<l>>
allVars == <<vars, l>>

logline == TraceLog[l]

\* ============================================================================
\* SERVER EXTRACTION FROM TRACE
\* ============================================================================

TraceServer == TLCEval(
    UNION { {TraceLog[k].event.nid} : k \in 1..Len(TraceLog) })

ASSUME TraceServer /= {}
ASSUME TraceServer \subseteq Server

\* ============================================================================
\* HELPERS
\* ============================================================================

\* Convert a trace block record to a spec Block.
\* Trace block schema:
\*   { author, round, digest, ancestors: [{author, round, digest}, ...],
\*     timestamp, commitVotes }
TraceBlock(tb) ==
    [author      |-> tb.author,
     round       |-> tb.round,
     digest      |-> tb.digest,
     ancestors   |-> { [author |-> a.author, round |-> a.round, digest |-> a.digest]
                       : a \in { tb.ancestors[k] : k \in 1..Len(tb.ancestors) } },
     timestamp   |-> tb.timestamp,
     commitVotes |-> IF "commitVotes" \in DOMAIN tb
                     THEN { [index |-> cv.index, digest |-> cv.digest]
                            : cv \in { tb.commitVotes[k]
                                       : k \in 1..Len(tb.commitVotes) } }
                     ELSE {}]

\* Convert a trace block ref { author, round, digest } to a spec BlockRef.
TraceBlockRef(tr) ==
    [author |-> tr.author, round |-> tr.round, digest |-> tr.digest]

\* Convert a trace slot { author, round } to a spec Slot.
TraceSlot(ts) ==
    [author |-> ts.author, round |-> ts.round]

\* ============================================================================
\* EVENT PREDICATES
\* ============================================================================

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = name

IsNodeEvent(name, i) ==
    /\ IsEvent(name)
    /\ logline.event.nid = i

\* ============================================================================
\* POST-STATE VALIDATION
\* ============================================================================
\*
\* For each action wrapper, validate the spec variables that the action
\* modifies against the trace's post-state snapshot. The instrumentation
\* spec is the source of truth for which fields are captured.

\* Validate clockRound and gcRound for validator i (after any DAG-touching action).
ValidateClockState(i) ==
    /\ "clockRound" \in DOMAIN logline.event.state =>
         clockRound'[i] = logline.event.state.clockRound
    /\ "gcRound" \in DOMAIN logline.event.state =>
         gcRound'[i] = logline.event.state.gcRound

\* Same as ValidateClockState but uses unprimed state. Used in the idempotent
\* DeliverBlock branch where the action is a no-op and UNCHANGED vars holds,
\* so trace's recorded post-state must equal the current (unchanged) state.
\* Using unprimed avoids TLC's identifier-resolution issue when UNCHANGED on
\* the nested `vars` tuple isn't evaluated before primed access.
ValidateClockStateUnchanged(i) ==
    /\ "clockRound" \in DOMAIN logline.event.state =>
         clockRound[i] = logline.event.state.clockRound
    /\ "gcRound" \in DOMAIN logline.event.state =>
         gcRound[i] = logline.event.state.gcRound

\* Validate that lastProposedRound was updated for validator i.
ValidateProposeState(i) ==
    /\ "lastProposedRound" \in DOMAIN logline.event.state =>
         lastProposedRound'[i] = logline.event.state.lastProposedRound

\* Validate signedHistory cardinality: the trace records the cardinality
\* (state.signedHistorySize) so we don't have to deserialize the full set.
ValidateSignedHistory(i) ==
    /\ "signedHistorySize" \in DOMAIN logline.event.state =>
         Cardinality(signedHistory'[i]) = logline.event.state.signedHistorySize

\* Validate that block b is now in dag[i].
ValidateBlockAccepted(i, b) ==
    b \in dag'[i]

\* Validate decided[i][slot] == expected outcome tag.
ValidateDecided(i, slot, expectedTag) ==
    /\ slot \in DOMAIN decided'[i]
    /\ decided'[i][slot].tag = expectedTag

\* Validate committedSeq cardinality update.
ValidateCommitSeqLen(i, expectedLen) ==
    Len(committedSeq'[i]) = expectedLen

\* ============================================================================
\* STEP TRACE CURSOR
\* ============================================================================

StepTrace == l' = l + 1

\* ============================================================================
\* ACTION WRAPPERS
\* ============================================================================

\* --- HonestPropose ---
\* Trace: { name: "HonestPropose", nid: i, block: {...}, state: {...} }
HonestProposeIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("HonestPropose", i)
        /\ HonestPropose(i)
        /\ ValidateBlockAccepted(i, TraceBlock(logline.event.block))
        /\ ValidateProposeState(i)
        /\ ValidateSignedHistory(i)
        /\ StepTrace

\* --- ByzPropose ---
\* Trace: { name: "ByzPropose", nid: i, block: {...} }
\*
\* Inline the block construction directly from the trace, bypassing
\* base.tla::ByzPropose's nondeterministic `\E ancRefs \in SUBSET ...` and
\* `\E ts \in 1..MaxTimestamp`. Both existentials would force TLC to
\* enumerate 2^|Messages| * MaxTimestamp branches just to pick the unique
\* trace-matching combination — which timed out at depth ~37 with 17+
\* messages in the equivocation trace. Pinning the post-state directly
\* skips the enumeration.
ByzProposeIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ByzPropose", i)
        /\ i \in Byzantine
        /\ LET tb == logline.event.block
               specBlock == TraceBlock(tb)
               r == specBlock.round
               d == specBlock.digest
           IN /\ r \in 1..MaxRound
              /\ d \in Digest
              /\ ~ \E b \in Messages :
                    b.author = i /\ b.round = r /\ b.digest = d
              /\ \A ar \in specBlock.ancestors : ar.round < r
              /\ Messages' = Messages \cup {specBlock}
              /\ dag' = [dag EXCEPT ![i] = @ \cup {specBlock}]
              /\ signedHistory' = [signedHistory EXCEPT ![i] =
                     @ \cup {[round |-> r, digest |-> d]}]
              /\ UNCHANGED <<clockRound, gcRound, commitVars,
                             lastKnownProposed, crashed,
                             lastIncludedAncestors, lastProposedRound,
                             certifiedCommitRound>>
              /\ ValidateSignedHistory(i)
              /\ StepTrace

\* --- DeliverBlock ---
\* Trace: { name: "DeliverBlock", nid: i, block: {...}, state: {...} }
\* Idempotent w.r.t. already-accepted blocks: when a Byzantine validator's
\* own block was added to its dag via ByzPropose (impl: accept_block called
\* before emit_byz_propose), a later DeliverBlock event for that same block
\* to the same nid is a no-op in the implementation (accept_block returns
\* without changes). We model that as a stuttering step on protocol state
\* while still advancing the trace cursor and validating the post-state.
DeliverBlockIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("DeliverBlock", i)
        /\ \E b \in Messages :
            /\ b = TraceBlock(logline.event.block)
            /\ \/ /\ b \notin dag[i]
                  /\ DeliverBlock(i, b)
                  /\ ValidateBlockAccepted(i, b)
                  /\ ValidateClockState(i)
               \/ /\ b \in dag[i]
                  /\ ValidateClockStateUnchanged(i)
                  /\ UNCHANGED vars
        /\ StepTrace

\* --- TryDirectDecide ---
\* Trace: { name: "TryDirectDecide", nid: i, slot: {...},
\*          outcome: "Commit"|"Skip"|"Undecided", state: {...} }
TryDirectDecideIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("TryDirectDecide", i)
        /\ LET slot == TraceSlot(logline.event.slot) IN
            /\ TryDirectDecide(i, slot)
            /\ slot \in DOMAIN decided'[i]
            /\ "outcome" \in DOMAIN logline.event =>
                 decided'[i][slot].tag = logline.event.outcome
            /\ StepTrace

\* --- TryIndirectDecide ---
\* Trace: { name: "TryIndirectDecide", nid: i, slot: {...},
\*          anchor: {...}, outcome: ... }
TryIndirectDecideIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("TryIndirectDecide", i)
        /\ LET slot == TraceSlot(logline.event.slot)
               anchorRef == TraceBlockRef(logline.event.anchor)
           IN /\ TryIndirectDecide(i, slot, anchorRef)
              /\ slot \in DOMAIN decided'[i]
              /\ "outcome" \in DOMAIN logline.event =>
                   decided'[i][slot].tag = logline.event.outcome
              /\ StepTrace

\* --- Linearize ---
\* Trace: { name: "Linearize", nid: i, leader: {...},
\*          state: { commitSeqLen, gcRound } }
LinearizeIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("Linearize", i)
        /\ LET leaderRef == TraceBlockRef(logline.event.leader) IN
            /\ Linearize(i, leaderRef)
            /\ "commitSeqLen" \in DOMAIN logline.event.state =>
                 ValidateCommitSeqLen(i, logline.event.state.commitSeqLen)
            /\ "gcRound" \in DOMAIN logline.event.state =>
                 gcRound'[i] = logline.event.state.gcRound
            /\ StepTrace

\* --- Crash ---
\* Trace: { name: "Crash", nid: i }
CrashIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("Crash", i)
        /\ Crash(i)
        /\ crashed'[i] = TRUE
        /\ StepTrace

\* --- RecoverAmnesia ---
\* Trace: { name: "RecoverAmnesia", nid: i,
\*          state: { lastKnownProposed } }
\*
\* Abstraction gap: the harness emits an explicit `lastKnownProposed` value
\* (0 to simulate the F2 underreport bug), bypassing the modeled peer-report
\* protocol. The spec's RecoverAmnesia requires honest peers to report their
\* actual HonestReport(p, s), which would be ≥ s's true highest round and not
\* 0 in the trace's setup. For trace replay we therefore use a relaxed
\* recovery: directly set lastKnownProposed to the trace's value.
\* Bug hunting (MC) uses the strict RecoverAmnesia from base.tla unchanged.
RecoverAmnesiaIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("RecoverAmnesia", i)
        /\ crashed[i]
        /\ "lastKnownProposed" \in DOMAIN logline.event.state
        /\ lastKnownProposed' = [lastKnownProposed EXCEPT ![i] =
                                   logline.event.state.lastKnownProposed]
        /\ crashed' = [crashed EXCEPT ![i] = FALSE]
        /\ UNCHANGED <<Messages, dag, clockRound, gcRound, commitVars,
                       signedHistory, proposerVars>>
        /\ StepTrace

\* --- AddCertifiedCommit ---
\* Trace: { name: "AddCertifiedCommit", nid: i, round: r,
\*          state: { clockRound, certifiedCommitRound } }
AddCertifiedCommitIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("AddCertifiedCommit", i)
        /\ AddCertifiedCommit(i, logline.event.round)
        /\ certifiedCommitRound'[i] = logline.event.round
        /\ "clockRound" \in DOMAIN logline.event.state =>
             clockRound'[i] = logline.event.state.clockRound
        /\ StepTrace

\* --- ForcePropose ---
\* Trace: { name: "ForcePropose", nid: i, block: {...}, state: {...} }
ForceProposeIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ForcePropose", i)
        /\ ForcePropose(i)
        /\ ValidateBlockAccepted(i, TraceBlock(logline.event.block))
        /\ ValidateProposeState(i)
        /\ StepTrace

\* ============================================================================
\* SILENT ACTIONS
\* ============================================================================
\*
\* Silent actions handle implementation state changes that occur without
\* trace events. Tightly constrained to prevent state explosion.

\* --- Silent DeliverBlock for non-observed validators ---
\* Mysticeti's gossip ensures every honest validator eventually has every
\* block — but we may not log every reception. Fire only when the next
\* trace event needs blocks that are missing from non-observed dag[s].
SilentDeliverBlock ==
    /\ l <= Len(TraceLog)
    \* Only when the next event is a decide / linearize that needs blocks
    /\ logline.event.name \in {"TryDirectDecide", "TryIndirectDecide", "Linearize"}
    /\ \E s \in Server, b \in Messages :
         /\ s /= logline.event.nid
         /\ b \notin dag[s]
         /\ DeliverBlock(s, b)
         /\ UNCHANGED l

\* ============================================================================
\* TRACE INIT
\* ============================================================================

TraceInit ==
    /\ l = 1
    /\ Init

\* ============================================================================
\* TRACE NEXT
\* ============================================================================

TraceDone ==
    /\ l > Len(TraceLog)
    /\ UNCHANGED <<l, vars>>

TraceNext ==
    \* Stuttering after trace consumed
    \/ TraceDone
    \* Action wrappers (consume one trace event each)
    \/ HonestProposeIfLogged
    \/ ByzProposeIfLogged
    \/ DeliverBlockIfLogged
    \/ TryDirectDecideIfLogged
    \/ TryIndirectDecideIfLogged
    \/ LinearizeIfLogged
    \/ CrashIfLogged
    \/ RecoverAmnesiaIfLogged
    \/ AddCertifiedCommitIfLogged
    \/ ForceProposeIfLogged
    \* SilentDeliverBlock removed: no longer needed because DeliverBlock no
    \* longer requires ancestor presence (matches harness's direct
    \* accept_block calls). Keeping it would let TLC stutter through
    \* delivery alternatives at trace boundaries, violating TraceMatched.

\* ============================================================================
\* SPEC AND PROPERTIES
\* ============================================================================

\* Weak fairness on TraceNext ensures TLC doesn't stutter when a trace action
\* is enabled — required for the liveness property TraceMatched to hold under
\* `[][Next]_vars` semantics (stuttering would otherwise be a valid behavior
\* that never advances the cursor).
TraceSpec == TraceInit /\ [][TraceNext]_allVars /\ WF_allVars(TraceNext)

TraceView == <<vars, l>>

\* Property: entire trace was consumed
TraceMatched == <>(l > Len(TraceLog))

\* ============================================================================
\* ALIAS (for debugging trace failures)
\* ============================================================================

TraceAlias ==
    [
        cursor       |-> l,
        traceLen     |-> Len(TraceLog),
        event        |-> IF l <= Len(TraceLog) THEN logline.event.name ELSE "DONE",
        nid          |-> IF l <= Len(TraceLog) THEN logline.event.nid ELSE "DONE",
        clockRound   |-> clockRound,
        gcRound      |-> gcRound,
        commitSeqLen |-> [s \in Server |-> Len(committedSeq[s])],
        crashed      |-> crashed,
        lastKnownProposed |-> lastKnownProposed,
        msgCount     |-> Cardinality(Messages),
        decided      |-> decided,
        committedBlocksCard |-> [s \in Server |-> Cardinality(committedBlocks[s])],
        dagCardForS2 |-> Cardinality(dag["s2"]),
        s4Round3Blocks |-> [s \in Server |->
            { b \in dag[s] : b.author = "s4" /\ b.round = 3 }]
    ]

====
