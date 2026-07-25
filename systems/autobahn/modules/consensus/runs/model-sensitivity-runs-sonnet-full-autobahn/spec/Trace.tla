---------------------------- MODULE Trace ----------------------------
(*
 * Trace.tla — Trace Validation wrapper for Autobahn base spec.
 *
 * Category A (Distributed / Message-Passing): single linear trace cursor `l`.
 * Trace file: ../traces/trace.ndjson  (override with env var JSON=path).
 *
 * Each trace event is an NDJSON line emitted by the instrumented Rust code.
 * The spec walks through events in order, calling the matching base spec action
 * and validating the post-state against captured fields.
 *
 * Trace event schema (from instrumentation-spec.md):
 *   { "event": <name>, "node": <id>, "slot": <n>, "view": <n>,
 *     "proposals": <string|null>, "voters": [<id>,...],
 *     "highQCView": <n|null>, "winProposals": <string|null>,
 *     "round": <n>, "parentRound": <n>,
 *     "state": { "nodeView": <n>, "prepareVoted": <bool>,
 *                "confirmVoted": <bool>, "committed": <string|null>,
 *                "hsVotedRound": <n>, "hsVoteCount": <n> } }
 *
 * Preprocessing: null JSON values are replaced with the string "null" before
 * loading, so logline.proposals = "null" means "no proposals for this event".
 *)

EXTENDS autobahn, Sequences, TLC, IOUtils, Json

\* Sequence to set helper
Range(f) == {f[i] : i \in DOMAIN f}

\* Convert a JSON voters sequence (<<"n1","n2">>) to a set of spec Nodes
VotersToSet(seq) == {n \in Nodes : \E i \in DOMAIN seq : seq[i] = ToString(n)}

\* Load trace from file; override with IOEnv.JSON for per-run selection.
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

TraceLog == ndJsonDeserialize(JsonFile)

\* Current trace event
VARIABLE l

logline == TraceLog[l]

\* -----------------------------------------------------------------------
\* BOOTSTRAP / TRACE INIT
\* The trace starts after initialization; we derive the Server set from the trace.

TraceNodes == { logline2.node : logline2 \in Range(TraceLog) }

TraceSlots == { logline2.slot : logline2 \in Range(TraceLog) }

TraceInit ==
    /\ Init
    /\ l = 1

\* -----------------------------------------------------------------------
\* EVENT PREDICATES
\* Node IDs in traces are strings ("n1","n2",...); spec uses model values.
\* ToString(n) converts the model value to its string representation.

IsEvent(name)       == logline.event = name
IsNodeEvent(name, n) == logline.event = name /\ logline.node = ToString(n)
IsSlotViewEvent(name, n, s, v) ==
    /\ logline.event = name
    /\ logline.node = ToString(n)
    /\ logline.slot = s
    /\ logline.view = v

\* -----------------------------------------------------------------------
\* POST-STATE VALIDATION
\* Validators check the PRIMED (post) state against the CURRENT (unprimed) logline.
\* IMPORTANT: never write Validator(...)' — that primes logline too, making it
\* TraceLog[l'] which requires l' to be bound first.  Use primed state vars directly.

\* Validate nodeView'[n, s] matches current trace event
ValidateNodeViewPost(n, s) ==
    nodeView'[n, s] = logline.state.nodeView

\* Validate committed'[s] matches trace (committed-or-not check)
ValidateCommittedPost(s) ==
    (logline.state.committed /= "null") <=> (committed'[s] /= None)

ValidatePrepareVotedPost(n, s, v) ==
    prepareVoted'[n, s, v] = logline.state.prepareVoted

ValidateConfirmVotedPost(n, s, v) ==
    confirmVoted'[n, s, v] = logline.state.confirmVoted

ValidateHSVotedRoundPost(n) ==
    hsVotedRound'[n] = logline.state.hsVotedRound

\* -----------------------------------------------------------------------
\* ACTION WRAPPERS

\* SendPrepare: honest leader broadcasts Prepare message.
\* Byzantine nodes may also log "SendPrepare" (e.g., after view change).
\* Proposal IDs are real hashes; any abstract Proposal value is used.
TraceSendPrepare ==
    \E n \in Nodes, s \in Slots, v \in Views, P \in Proposals :
        /\ logline.event = "SendPrepare"
        /\ logline.node = ToString(n)
        /\ logline.slot = s /\ logline.view = v
        /\ IF n \in HonestNodes
           THEN SendPrepare(n, s, v, P)
           ELSE \* Byzantine node sending a single Prepare (e.g., after TC view change)
                /\ proposalContent[s, v] = None
                /\ v = nodeView[n, s]
                /\ msgs' = msgs \cup {[type |-> "Prepare", sender |-> n,
                                        slot |-> s, view |-> v, proposals |-> P]}
                /\ proposalContent' = [proposalContent EXCEPT ![s, v] = P]
                /\ activeConsensus'  = activeConsensus \cup {<<s, v>>}
                /\ UNCHANGED <<nodeView, committed, prepareVoted, confirmVoted,
                               prepareQC, confirmQC, voteDigest,
                               timeoutSenders, timeoutHighQC, tcFormed,
                               hsVotedRound, hsVoteCount, hsCrashed, hsBlock,
                               hsParentRound, hsCommittedRound, nodeCommitted>>
        /\ l' = l + 1

\* ByzEquivocatePrepare: Byzantine leader sends two conflicting Prepares.
TraceByzEquivocatePrepare ==
    \E n \in ByzNodes, s \in Slots, v \in Views, P1, P2 \in Proposals :
        /\ IsSlotViewEvent("ByzEquivocatePrepare", n, s, v)
        /\ ByzEquivocatePrepare(n, s, v, P1, P2)
        /\ l' = l + 1

\* CastPrepareVote: honest replica casts PrepareVote.
\* Post-state: prepareVoted[n,s,v] = TRUE; nodeView[n,s] possibly updated.
TraceCastPrepareVote ==
    \E n \in HonestNodes, s \in Slots, v \in Views :
        /\ IsSlotViewEvent("CastPrepareVote", n, s, v)
        /\ \/ CastPrepareVote(n, s, v)         \* first vote
           \/ /\ prepareVoted[n, s, v] = TRUE  \* already voted: idempotent no-op
              /\ UNCHANGED allVars
        /\ ValidatePrepareVotedPost(n, s, v)
        /\ ValidateNodeViewPost(n, s)
        /\ l' = l + 1

\* FormPrepareQC: 2f+1 votes collected, QC formed.
\* voters is a JSON array in the trace; convert to a spec set.
TraceFormPrepareQC ==
    \E s \in Slots, v \in Views, P \in Proposals :
        /\ IsEvent("FormPrepareQC")
        /\ logline.slot = s /\ logline.view = v
        /\ LET voters == VotersToSet(logline.voters)
           IN FormPrepareQC(s, v, voters, P)
        /\ l' = l + 1

\* SendConfirm: leader sends Confirm with embedded PrepareQC.
TraceSendConfirm ==
    \E n \in HonestNodes, s \in Slots, v \in Views :
        /\ IsSlotViewEvent("SendConfirm", n, s, v)
        /\ SendConfirm(n, s, v)
        /\ l' = l + 1

\* CastConfirmVote: replica casts ConfirmVote (no equivocation guard per F3).
\* Post-state: confirmVoted[n,s,v] = TRUE.
TraceCastConfirmVote ==
    \E n \in HonestNodes, s \in Slots, v \in Views :
        /\ IsSlotViewEvent("CastConfirmVote", n, s, v)
        /\ CastConfirmVote(n, s, v)
        /\ ValidateConfirmVotedPost(n, s, v)
        /\ l' = l + 1

\* FormConfirmQC: 2f+1 confirm votes collected.
\* voters is a JSON array in the trace; convert to a spec set.
TraceFormConfirmQC ==
    \E s \in Slots, v \in Views :
        /\ IsEvent("FormConfirmQC")
        /\ logline.slot = s /\ logline.view = v
        /\ LET voters == VotersToSet(logline.voters)
           IN FormConfirmQC(s, v, voters)
        /\ l' = l + 1

\* SendCommit: leader sends Commit message.
TraceSendCommit ==
    \E n \in HonestNodes, s \in Slots, v \in Views :
        /\ IsSlotViewEvent("SendCommit", n, s, v)
        /\ SendCommit(n, s, v)
        /\ l' = l + 1

\* ProcessCommit: node commits slot s.
\* The implementation may call process_commit_message multiple times idempotently
\* (once per Commit message received). After first commit nodeCommitted[n,s] /= None;
\* subsequent calls are absorbed as no-ops.
TraceProcessCommit ==
    \E n \in HonestNodes, s \in Slots, v \in Views :
        /\ IsSlotViewEvent("ProcessCommit", n, s, v)
        /\ \/ ProcessCommit(n, s, v)
           \/ /\ nodeCommitted[n, s] /= None    \* already committed: idempotent no-op
              /\ UNCHANGED allVars
        /\ ValidateCommittedPost(s)
        /\ l' = l + 1

\* SendTimeout: honest node times out.
TraceSendTimeout ==
    \E n \in HonestNodes, s \in Slots, v \in Views :
        /\ IsSlotViewEvent("SendTimeout", n, s, v)
        /\ SendTimeout(n, s, v)
        /\ l' = l + 1

\* SendTimeout logged for a Byzantine node: map to ByzSendTimeout.
\* The harness uses "SendTimeout" for all nodes regardless of Byzantine status.
TraceSendTimeoutByz ==
    \E n \in ByzNodes, s \in Slots, v \in Views :
        /\ IsSlotViewEvent("SendTimeout", n, s, v)
        /\ LET fake_v == IF logline.highQCView = "null" THEN None
                         ELSE logline.highQCView
           IN ByzSendTimeout(n, s, v, fake_v)
        /\ l' = l + 1

\* ByzSendTimeout: Byzantine node sends forged timeout (explicit event).
TraceByzSendTimeout ==
    \E n \in ByzNodes, s \in Slots, v \in Views :
        /\ IsSlotViewEvent("ByzSendTimeout", n, s, v)
        /\ LET fake_v == IF logline.highQCView = "null" THEN None
                         ELSE logline.highQCView
           IN ByzSendTimeout(n, s, v, fake_v)
        /\ l' = l + 1

\* FormTC: TC formed with (potentially buggy) winning proposals.
TraceFormTC ==
    \E s \in Slots, v \in Views :
        /\ IsEvent("FormTC")
        /\ logline.slot = s /\ logline.view = v
        /\ FormTC(s, v)
        /\ l' = l + 1

\* ProcessTC: node advances view based on TC.
\* The trace records view=<new_view> (after advancing), not the TC's view.
\* TC view = trace_view - 1. Handles both honest and Byzantine nodes.
TraceProcessTC ==
    \E n \in Nodes, s \in Slots, v \in Views :
        /\ logline.event = "ProcessTC"
        /\ logline.node = ToString(n)
        /\ logline.slot = s /\ logline.view = v
        /\ v > MinView   \* new view > 1 implies TC view = v-1 >= MinView
        /\ LET tc_view == v - 1 IN
           \* Check TC message existence: tcFormed[s,tc_view]=None is ambiguous
           \* (means both "not formed" and "formed with no winning proposals").
           \* Use msgs to verify the TC was actually broadcast.
           /\ \E m \in msgs : m.type = "TC" /\ m.slot = s /\ m.view = tc_view
           /\ tc_view >= nodeView[n, s]
           /\ nodeView' = [nodeView EXCEPT ![n, s] = v]
           /\ UNCHANGED <<msgs, committed, prepareVoted, confirmVoted,
                          prepareQC, confirmQC, proposalContent, voteDigest,
                          timeoutSenders, timeoutHighQC, tcFormed,
                          hsVotedRound, hsVoteCount, hsCrashed, hsBlock,
                          hsParentRound, hsCommittedRound, activeConsensus, nodeCommitted>>
        /\ ValidateNodeViewPost(n, s)
        /\ l' = l + 1

\* HSMakeVote: HotStuff node votes for a round.
\* Post-state: hsVotedRound[n] updated.
\* Note: hsVoteCount is a ghost variable tracking cumulative votes; the trace
\* records in-memory count (reset on crash), so we only validate hsVotedRound.
TraceHSMakeVote ==
    \E n \in HonestNodes, r \in HSRounds :
        /\ IsEvent("HSMakeVote")
        /\ logline.node = ToString(n) /\ logline.round = r
        /\ HSMakeVote(n, r)
        /\ ValidateHSVotedRoundPost(n)
        /\ l' = l + 1

\* HSProcessBlock: node processes block, applies (buggy) 2-chain check.
TraceHSProcessBlock ==
    \E n \in HonestNodes, r \in HSRounds :
        /\ IsEvent("HSProcessBlock")
        /\ logline.node = ToString(n) /\ logline.round = r
        /\ HSProcessBlock(n, r)
        /\ l' = l + 1

\* HSCrashRecover: node crashes and recovers (in-memory voted round resets).
\* Post-state: hsVotedRound[n] = 0.
TraceHSCrashRecover ==
    \E n \in HonestNodes :
        /\ IsEvent("HSCrashRecover")
        /\ logline.node = ToString(n)
        /\ HSCrashRecover(n)
        /\ ValidateHSVotedRoundPost(n)
        /\ l' = l + 1

\* CleanSlotPeriods: GC runs after commit (buggy predicate).
TraceCleanSlotPeriods ==
    \E s \in Slots :
        /\ IsEvent("CleanSlotPeriods")
        /\ logline.slot = s
        /\ CleanSlotPeriods(s)
        /\ l' = l + 1

\* -----------------------------------------------------------------------
\* SILENT ACTIONS
\* Fire base spec actions that do not emit trace events, or whose preconditions
\* must be established before the traced action can fire. Tightly constrained
\* to prevent state-space explosion.

\* HSPublishBlock has no trace event (leader-side; not instrumented on replica).
\* Allow it only when the NEXT event is one that requires the block to exist.
SilentHSPublishBlock ==
    /\ l <= Len(TraceLog)
    /\ \E r \in HSRounds, pr \in HSRounds \cup {0}, P \in Proposals :
           /\ hsBlock[r] = None
           /\ pr < r
           /\ TraceLog[l].event \in {"HSMakeVote","HSProcessBlock"}
           /\ TraceLog[l].round = r
           /\ HSPublishBlock(r, pr, P)
    /\ UNCHANGED l

\* SendPrepare is often not traced (leader does it before tracing starts).
\* Fire silently when the upcoming trace event needs a Prepare message.
SilentSendPrepare ==
    /\ l <= Len(TraceLog)
    /\ LET ll == TraceLog[l]
           s  == ll.slot
           v  == ll.view
       IN
       /\ ll.event \in {"CastPrepareVote","FormPrepareQC","SendConfirm",
                        "CastConfirmVote","FormConfirmQC","SendCommit","ProcessCommit"}
       /\ s \in Slots /\ v \in Views
       /\ proposalContent[s, v] = None    \* no Prepare sent yet
       /\ \E n \in HonestNodes, P \in Proposals : SendPrepare(n, s, v, P)
    /\ UNCHANGED l

\* Un-traced nodes cast PrepareVote so FormPrepareQC has quorum.
\* Only fires when the upcoming event is FormPrepareQC.
SilentCastPrepareVote ==
    /\ l <= Len(TraceLog)
    /\ LET ll == TraceLog[l]
           s  == ll.slot
           v  == ll.view
       IN
       /\ ll.event = "FormPrepareQC"
       /\ s \in Slots /\ v \in Views
       /\ \E n \in HonestNodes :
              /\ prepareVoted[n, s, v] = FALSE
              /\ hsCrashed[n] = FALSE
              /\ \E m \in msgs : m.type = "Prepare" /\ m.slot = s /\ m.view = v
              /\ CastPrepareVote(n, s, v)
    /\ UNCHANGED l

\* Un-traced nodes cast ConfirmVote so FormConfirmQC has quorum.
\* Only fires when the upcoming event is FormConfirmQC.
SilentCastConfirmVote ==
    /\ l <= Len(TraceLog)
    /\ LET ll == TraceLog[l]
           s  == ll.slot
           v  == ll.view
       IN
       /\ ll.event = "FormConfirmQC"
       /\ s \in Slots /\ v \in Views
       /\ \E n \in HonestNodes :
              /\ confirmVoted[n, s, v] = FALSE    \* only for nodes not yet voted
              /\ hsCrashed[n] = FALSE
              /\ \E m \in msgs : m.type = "Confirm" /\ m.slot = s /\ m.view = v
              /\ CastConfirmVote(n, s, v)
    /\ UNCHANGED l

\* Un-traced honest nodes send Timeout to satisfy FormTC quorum (f+1).
\* Only fires when the upcoming event is FormTC.
SilentSendTimeout ==
    /\ l <= Len(TraceLog)
    /\ LET ll == TraceLog[l]
           s  == ll.slot
           v  == ll.view
       IN
       /\ ll.event = "FormTC"
       /\ s \in Slots /\ v \in Views
       /\ \E n \in HonestNodes :
              /\ ~ (n \in timeoutSenders[s, v])
              /\ SendTimeout(n, s, v)
    /\ UNCHANGED l

\* -----------------------------------------------------------------------
\* TRACE NEXT

TraceNext ==
    /\ l <= Len(TraceLog)
    /\ ( TraceSendPrepare
       \/ TraceByzEquivocatePrepare
       \/ TraceCastPrepareVote
       \/ TraceFormPrepareQC
       \/ TraceSendConfirm
       \/ TraceCastConfirmVote
       \/ TraceFormConfirmQC
       \/ TraceSendCommit
       \/ TraceProcessCommit
       \/ TraceSendTimeout
       \/ TraceSendTimeoutByz
       \/ TraceByzSendTimeout
       \/ TraceFormTC
       \/ TraceProcessTC
       \/ TraceHSMakeVote
       \/ TraceHSProcessBlock
       \/ TraceHSCrashRecover
       \/ TraceCleanSlotPeriods
       \/ SilentHSPublishBlock
       \/ SilentSendPrepare
       \/ SilentCastPrepareVote
       \/ SilentCastConfirmVote
       \/ SilentSendTimeout )

\* Stuttering when trace is fully consumed.
TraceSpec == TraceInit /\ [][TraceNext \/ (l > Len(TraceLog) /\ UNCHANGED <<allVars, l>>)]_<<allVars, l>>
             /\ WF_<<allVars,l>>(TraceNext)

\* Temporal property: trace must be fully consumed.
TraceMatched == <>(l > Len(TraceLog))

=============================================================================
