--------------------------- MODULE Trace ---------------------------
(*
 * Trace validation spec for the CometBFT PBTS / ABCI++ / state-sync pass.
 *
 * Replays implementation traces against base.tla. Trace format: NDJSON,
 * each record:
 *   { "tag":"trace",
 *     "event":{
 *       "name": <action name>,
 *       "nid":  <validator ID for the action>,
 *       "state": { ... post-action state snapshot ... },
 *       "msg":   { ... event-specific extras (proposal fields, vote fields) ... }
 *     }
 *   }
 *
 * Action wrappers fire when an event matches AND the base spec action is
 * enabled. Post-state validation checks the fields the action mutates against
 * the snapshot. Silent actions handle internal updates the harness can't
 * always observe (clock ticks, late-arriving non-relevant messages).
 *)

EXTENDS base, Json, IOUtils, Sequences, TLC

\* AppAcceptsVE override for trace replay. The spec's check
\* `vote.extension = NoExtension \/ AppAcceptsVE[vote.extension]` requires
\* AppAcceptsVE to be evaluable even when vote.extension = NoExtension
\* (TLC does not short-circuit \/ when the second disjunct goes out of
\* domain). We bind AppAcceptsVE to a function whose domain includes
\* NoExtension so the lookup never fails; the value at NoExtension is TRUE
\* (a no-op).
AppAcceptsVEAllWithNoExt ==
    [e \in Extensions \cup {NoExtension} |-> TRUE]

\* ============================================================================
\* TRACE LOADING
\* ============================================================================

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

TraceLog == TLCEval(
    LET all == ndJsonDeserialize(JsonFile)
    IN SelectSeq(all, LAMBDA x :
        /\ "tag" \in DOMAIN x
        /\ x.tag = "trace"
        /\ "event" \in DOMAIN x))

ASSUME Len(TraceLog) > 0

\* ============================================================================
\* CURSOR
\* ============================================================================

VARIABLE l

traceVars == <<l>>

logline == TraceLog[l]

\* ============================================================================
\* TRACE-DERIVED SETS
\* ============================================================================

TraceValue(v) == IF v = "" \/ v = "null" \/ v = "nil" THEN Nil ELSE v

TraceServer == TLCEval(
    UNION {
        {TraceLog[k].event.nid}
        \cup (IF "msg" \in DOMAIN TraceLog[k].event
                /\ "proposer" \in DOMAIN TraceLog[k].event.msg
              THEN {TraceLog[k].event.msg.proposer}
              ELSE {})
        : k \in 1..Len(TraceLog)
    })

ASSUME TraceServer /= {}
ASSUME TraceServer \subseteq Servers

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

\* Helper: fetch a sub-field from event.state, returning Nil if absent.
StateField(field, default) ==
    IF "state" \in DOMAIN logline.event /\ field \in DOMAIN logline.event.state
    THEN logline.event.state[field]
    ELSE default

MsgField(field, default) ==
    IF "msg" \in DOMAIN logline.event /\ field \in DOMAIN logline.event.msg
    THEN logline.event.msg[field]
    ELSE default

\* --- Per-action post-state checks ---
\* Each ValidatePost* is action-specific and checks the fields that action
\* mutates in base.tla.

ValidatePostProposeNew(v) ==
    \E pr \in proposalMsg' :
        /\ pr.proposer = v
        /\ pr.height = MsgField("height", 0)
        /\ pr.round = MsgField("round", 0)
        /\ pr.polRound = -1                                    \* state.go:1260, validRound=-1
        /\ pr.block = TraceValue(MsgField("block", ""))
        /\ pr.timestamp = MsgField("timestamp", 0)

ValidatePostProposeValid(v) ==
    \E pr \in proposalMsg' :
        /\ pr.proposer = v
        /\ pr.height = MsgField("height", 0)
        /\ pr.round = MsgField("round", 0)
        /\ pr.polRound >= 0                                    \* F9 mechanism
        /\ pr.block = TraceValue(MsgField("block", ""))
        /\ pr.timestamp = MsgField("timestamp", 0)              \* reused old Header.Time

ValidatePostDeliverProposal(v) ==
    \* The harness records both `state.wallClock` (emit time) and
    \* `state.proposalRecvTime` (the moment the proposal was received).
    \* The spec's DeliverProposal sets `proposalRecvTime' = wallClock[v]`
    \* at the receive moment, so it must equal `state.proposalRecvTime`,
    \* NOT `state.wallClock` (which may have advanced before emit).
    proposalRecvTime'[v][MsgField("height", 0)][MsgField("round", 0)]
        = StateField("proposalRecvTime", 0)

ValidatePostPolkaArms(v) ==
    /\ validBlock'[v] = TraceValue(MsgField("block", ""))
    /\ validRound'[v] = MsgField("round", -1)
    /\ validBlockTime'[v] = MsgField("timestamp", 0)

ValidatePostDecide(h) ==
    /\ decidedBlock'[h] = TraceValue(MsgField("block", ""))
    /\ decidedTimestamp'[h] = MsgField("timestamp", 0)

ValidatePostDeliverLatePrecommit(v) ==
    \* Late precommits add to lastCommitVotes but NOT to appVerifiedExt
    \* unless extension would have been app-accepted. We can only check the
    \* lastCommitVotes membership for an exact record.
    \E vote \in lastCommitVotes'[v] :
        /\ vote.voter = MsgField("voter", "")
        /\ vote.height = MsgField("height", 0)
        /\ vote.round = MsgField("round", 0)
        /\ vote.block = TraceValue(MsgField("block", ""))
        /\ vote.extension = MsgField("extension", NoExtension)

ValidatePostDeliverInRoundPrecommit(v) ==
    \E vote \in lastCommitVotes'[v] :
        /\ vote.voter = MsgField("voter", "")
        /\ vote.height = MsgField("height", 0)
        /\ vote.round = MsgField("round", 0)
        /\ vote.block = TraceValue(MsgField("block", ""))
        /\ vote.extension = MsgField("extension", NoExtension)

ValidatePostAdvanceRound(v) ==
    currentRound'[v] = StateField("round", 0)

\* ============================================================================
\* STEP CURSOR
\* ============================================================================

StepTrace == l' = l + 1

\* ============================================================================
\* ACTION WRAPPERS
\* ============================================================================

\* --- ProposeNewBlockIfLogged ---
\* event.name = "ProposeNewBlock", msg = { height, round, block, timestamp }
ProposeNewBlockIfLogged ==
    \E v \in Servers :
        /\ IsNodeEvent("ProposeNewBlock", v)
        /\ LET b  == TraceValue(MsgField("block", ""))
               ts == MsgField("timestamp", 0)
           IN /\ b \in Blocks
              /\ ts \in Times
              /\ ProposeNewBlock(v, b, ts)
              /\ ValidatePostProposeNew(v)
              /\ StepTrace

\* --- ProposeValidBlockIfLogged ---
\* event.name = "ProposeValidBlock"
ProposeValidBlockIfLogged ==
    \E v \in Servers :
        /\ IsNodeEvent("ProposeValidBlock", v)
        /\ ProposeValidBlock(v)
        /\ ValidatePostProposeValid(v)
        /\ StepTrace

\* --- DeliverProposalIfLogged ---
\* event.name = "DeliverProposal", msg = { proposer, height, round, block, timestamp }
DeliverProposalIfLogged ==
    \E v \in Servers, pr \in proposalMsg :
        /\ IsNodeEvent("DeliverProposal", v)
        /\ pr.proposer = MsgField("proposer", "")
        /\ pr.height = MsgField("height", 0)
        /\ pr.round = MsgField("round", 0)
        /\ DeliverProposal(v, pr)
        /\ ValidatePostDeliverProposal(v)
        /\ StepTrace

\* --- Trace-replay-only relaxation of AcceptProposalPOLNew ---
\* The cometbft artifact pinned at this case study is v0.38, which does NOT
\* implement `proposalIsTimely` (the PBTS-specific timely check landed in
\* v1.x). The harness emits AcceptProposalPOLNew whenever v0.38 accepts the
\* proposal, but a v0.38-acceptable proposal can have a recvTime well
\* outside the v1.x timely window. INSTRUMENTATION.md documents this:
\* "the IsTimely predicate in base.tla is structurally satisfied by any
\* proposal." So in trace replay we skip the IsTimely conjunct that lives
\* inside base.tla's AcceptProposalPOLNew. The full base.tla action remains
\* unchanged and is exercised by MC.
AcceptProposalPOLNewTrace(v, pr) ==
    /\ pr \in proposalMsg
    /\ pr.height = chainHeight
    /\ pr.round = currentRound[v]
    /\ pr.polRound = -1
    /\ proposalRecvTime[v][pr.height][pr.round] /= Nil
    \* IsTimely intentionally omitted — see comment above.
    /\ AppAcceptsPP[pr.height, pr.round, v, pr.block]
    /\ UNCHANGED <<clockVars, chainVars, validVars, currentRound, proposalMsg,
                   proposalRecvTime, lastCommitVars, syncVars>>

\* --- AcceptProposalPOLNewIfLogged ---
\* event.name = "AcceptProposalPOLNew", msg = { proposer, height, round }
AcceptProposalPOLNewIfLogged ==
    \E v \in Servers, pr \in proposalMsg :
        /\ IsNodeEvent("AcceptProposalPOLNew", v)
        /\ pr.proposer = MsgField("proposer", "")
        /\ pr.height = MsgField("height", 0)
        /\ pr.round = MsgField("round", 0)
        /\ AcceptProposalPOLNewTrace(v, pr)
        /\ StepTrace

\* --- AcceptProposalPOLOldIfLogged ---
\* event.name = "AcceptProposalPOLOld" — the F1 bypass surface
\* The POLOld branch doesn't have a timely check even in base.tla, so we
\* call into it directly.
AcceptProposalPOLOldIfLogged ==
    \E v \in Servers, pr \in proposalMsg :
        /\ IsNodeEvent("AcceptProposalPOLOld", v)
        /\ pr.proposer = MsgField("proposer", "")
        /\ pr.height = MsgField("height", 0)
        /\ pr.round = MsgField("round", 0)
        /\ AcceptProposalPOLOld(v, pr)
        /\ StepTrace

\* --- PolkaArmsValidBlockIfLogged ---
\* event.name = "PolkaArmsValidBlock" — the cs.ValidBlock writeback at state.go:2440-2445
PolkaArmsValidBlockIfLogged ==
    \E v \in Servers, pr \in proposalMsg :
        /\ IsNodeEvent("PolkaArmsValidBlock", v)
        /\ pr.proposer = MsgField("proposer", "")
        /\ pr.height = MsgField("height", 0)
        /\ pr.round = MsgField("round", 0)
        /\ PolkaArmsValidBlock(v, pr)
        /\ ValidatePostPolkaArms(v)
        /\ StepTrace

\* --- AdvanceRoundIfLogged ---
\* event.name = "AdvanceRound"
AdvanceRoundIfLogged ==
    \E v \in Servers :
        /\ IsNodeEvent("AdvanceRound", v)
        /\ AdvanceRound(v)
        /\ ValidatePostAdvanceRound(v)
        /\ StepTrace

\* --- ProposerSelfRejectIfLogged ---
\* event.name = "ProposerSelfReject" — state.go:1492 path
ProposerSelfRejectIfLogged ==
    \E v \in Servers, pr \in proposalMsg :
        /\ IsNodeEvent("ProposerSelfReject", v)
        /\ pr.proposer = MsgField("proposer", "")
        /\ pr.height = MsgField("height", 0)
        /\ pr.round = MsgField("round", 0)
        /\ ProposerSelfReject(v, pr)
        /\ StepTrace

\* --- DecideBlockIfLogged ---
\* event.name = "DecideBlock", msg = { height, block, timestamp }
DecideBlockIfLogged ==
    \E h \in Heights, pr \in proposalMsg :
        /\ IsEvent("DecideBlock")
        /\ h = MsgField("height", 0)
        /\ pr.height = h
        /\ pr.block = TraceValue(MsgField("block", ""))
        /\ pr.timestamp = MsgField("timestamp", 0)
        /\ DecideBlock(h, pr)
        /\ ValidatePostDecide(h)
        /\ StepTrace

\* --- ProposerSkipsRoundIfLogged ---
\* event.name = "ProposerSkipsRound" — Family 2 mechanism
ProposerSkipsRoundIfLogged ==
    \E v \in Servers :
        /\ IsNodeEvent("ProposerSkipsRound", v)
        /\ ProposerSkipsRound(v)
        /\ ValidatePostAdvanceRound(v)
        /\ StepTrace

\* --- DeliverInRoundPrecommitIfLogged ---
\* event.name = "DeliverInRoundPrecommit", msg = { voter, height, round, block, extension }
DeliverInRoundPrecommitIfLogged ==
    \E v \in Servers :
        /\ IsNodeEvent("DeliverInRoundPrecommit", v)
        /\ LET vote == PrecommitRec(
                          MsgField("voter", ""),
                          MsgField("height", 0),
                          MsgField("round", 0),
                          TraceValue(MsgField("block", "")),
                          MsgField("extension", NoExtension)) IN
            /\ DeliverInRoundPrecommit(v, vote)
            /\ ValidatePostDeliverInRoundPrecommit(v)
            /\ StepTrace

\* --- DeliverLatePrecommitIfLogged ---
\* event.name = "DeliverLatePrecommit" — F3 surface
DeliverLatePrecommitIfLogged ==
    \E v \in Servers :
        /\ IsNodeEvent("DeliverLatePrecommit", v)
        /\ LET vote == PrecommitRec(
                          MsgField("voter", ""),
                          MsgField("height", 0),
                          MsgField("round", 0),
                          TraceValue(MsgField("block", "")),
                          MsgField("extension", NoExtension)) IN
            /\ DeliverLatePrecommit(v, vote)
            /\ ValidatePostDeliverLatePrecommit(v)
            /\ StepTrace

\* ============================================================================
\* SILENT ACTIONS — tightly constrained
\* ============================================================================

\* Clock ticks are not always observable in logs. We need silent ticks to
\* bring realTime / wallClock up to the action-time clock the next trace
\* event was emitted for. To avoid per-validator tick interleaving
\* explosion (TLC would explore O(N!) orderings between events for N
\* validators), TickValidatorSilent picks the eligible validator
\* deterministically via CHOOSE on a canonical order.
\*
\* `EventActionTickBound` is the realTime / wallClock value the spec
\* must reach BEFORE the next event's wrapper fires:
\*   - DeliverProposal: state.proposalRecvTime (receive moment, < emit
\*     moment in state.wallClock).
\*   - ProposeNewBlock: msg.timestamp (the proposer's local clock at
\*     block creation, which the spec requires equal to wallClock[v]).
\*   - Other events: state.realTime (no internal pre-state constraint;
\*     the lockstep ticks just keep clocks moving with the trace).
\* Silent ticks stop at this bound so wrapper firing sees the right
\* wallClock; after the wrapper fires (cursor advances), the next event's
\* bound takes over.
EventActionTickBound ==
    IF l > Len(TraceLog) THEN 0
    ELSE IF /\ logline.event.name = "DeliverProposal"
            /\ "state" \in DOMAIN logline.event
            /\ "proposalRecvTime" \in DOMAIN logline.event.state
         THEN logline.event.state.proposalRecvTime
         ELSE IF /\ logline.event.name = "ProposeNewBlock"
                 /\ "msg" \in DOMAIN logline.event
                 /\ "timestamp" \in DOMAIN logline.event.msg
              THEN logline.event.msg.timestamp
              ELSE IF /\ "state" \in DOMAIN logline.event
                      /\ "realTime" \in DOMAIN logline.event.state
                   THEN logline.event.state.realTime
                   ELSE 0

\* A validator v's wallClock must tick when:
\*   (a) The next event is DeliverProposal at v and wallClock[v] is below
\*       state.proposalRecvTime (the spec stamps recvTime = wallClock).
\*   (b) realTime is about to advance to match the action-time bound and
\*       v has fallen behind realTime — without ticking, TickRealTime
\*       would violate the MaxClockSkew bound.
NextEventRequiresTickValidator(v) ==
    /\ l <= Len(TraceLog)
    /\ \/ /\ logline.event.nid = v
          /\ logline.event.name = "DeliverProposal"
          /\ "state" \in DOMAIN logline.event
          /\ "proposalRecvTime" \in DOMAIN logline.event.state
          /\ wallClock[v] < logline.event.state.proposalRecvTime
       \/ /\ wallClock[v] < realTime
          /\ realTime < EventActionTickBound

\* Atomic clock advance. Rather than emit one TickRealTime + N TickValidator
\* silent steps per realTime increment (which TLC interleaves into a
\* combinatorial state explosion across events), advance realTime AND every
\* validator's wallClock to the action-time bound in a single step. The
\* underlying TickRealTime / TickValidator from base.tla remain available
\* for MC runs.
\*
\* The advance is conservative: realTime jumps to EventActionTickBound, and
\* every wallClock that has fallen behind realTime jumps to match. This
\* matches the lockstep clock progression that the harness emits (wallClock
\* and realTime move together in every trace event).
LockstepAdvanceSilent ==
    /\ l <= Len(TraceLog)
    /\ realTime < EventActionTickBound
    /\ EventActionTickBound <= MaxTime
    /\ realTime' = EventActionTickBound
    /\ wallClock' = [v \in Servers |->
                       IF wallClock[v] < EventActionTickBound
                       THEN EventActionTickBound
                       ELSE wallClock[v]]
    /\ UNCHANGED <<l, chainVars, validVars, proposalVars,
                   lastCommitVars, syncVars>>

\* Per-validator silent tick retained for the rare case where a single
\* validator needs to catch up beyond the lockstep advance (e.g. branch (a)
\* — the DeliverProposal nid's wallClock must equal state.proposalRecvTime,
\* and if proposalRecvTime > realTime, only one validator should advance).
\* In practice with the lockstep advance, this is rarely needed.
CanTickValidator(v) ==
    /\ wallClock[v] < MaxTime
    /\ wallClock[v] + 1 - realTime <= MaxClockSkew

EligibleTickValidatorSet ==
    { v \in Servers : NextEventRequiresTickValidator(v) /\ CanTickValidator(v) }

TickValidatorSilent ==
    /\ l <= Len(TraceLog)
    /\ EligibleTickValidatorSet /= {}
    /\ LET v == CHOOSE w \in EligibleTickValidatorSet : TRUE IN
         /\ TickValidator(v)
         /\ UNCHANGED l

NextEventRequiresTickRealTime ==
    /\ l <= Len(TraceLog)
    /\ realTime < EventActionTickBound

TickRealTimeSilent ==
    /\ NextEventRequiresTickRealTime
    /\ TickRealTime
    /\ UNCHANGED l

\* RecordHonestAppHash silently captures the chain's app hash for the F5
\* invariant. Only enabled when the trace mentions an "appHash" field on a
\* DecideBlock-type event.
RecordHonestAppHashSilent ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("DecideBlock")
    /\ "appHash" \in DOMAIN logline.event.msg
    /\ honestAppHash = Nil
    /\ honestAppHash' = logline.event.msg.appHash
    /\ UNCHANGED <<l, clockVars, chainVars, validVars, proposalVars,
                    lastCommitVars, syncTargetHeight, rpcAppHash,
                    consumedChunks, appComputedHash, syncVerified,
                    rpcIdentity, chunkPeerIdentity>>

\* DeliverProposalSilent — stamps proposalRecvTime[v] for a validator that
\* has not yet been recorded as receiving the current round's proposal.
\* Single-node traces only directly record the receiver's own DeliverProposal;
\* however, when a polka is observed (PolkaArmsValidBlock or DecideBlock),
\* the spec requires a quorum of validators with non-Nil recvTime. This silent
\* action lets the spec replayer infer that the prevote signers must have
\* received the proposal — without that, single-node traces cannot replay
\* polka events. Only enabled when:
\*   - There is a proposal in proposalMsg for the current (chainHeight, round)
\*   - The next logged event is PolkaArmsValidBlock or DecideBlock (a quorum
\*     requirement)
\*   - The chosen validator's slot is currently Nil
DeliverProposalSilent ==
    /\ l <= Len(TraceLog)
    /\ \/ IsEvent("PolkaArmsValidBlock")
       \/ IsEvent("DecideBlock")
    /\ \E pr \in proposalMsg :
        /\ pr.height = chainHeight
        /\ \E w \in Servers : proposalRecvTime[w][pr.height][pr.round] = Nil
        \* Only fire when there is NOT YET a quorum of validators with
        \* non-Nil recvTime for this proposal. Otherwise the trace action
        \* can fire directly.
        /\ ~ \E S \in Quorum :
              S \subseteq { w \in Servers :
                             proposalRecvTime[w][pr.height][pr.round] /= Nil }
        \* Deterministically pick the lex-smallest v with Nil recvTime to
        \* eliminate per-validator interleaving.
        /\ LET v == CHOOSE w \in Servers :
                       proposalRecvTime[w][pr.height][pr.round] = Nil IN
            DeliverProposal(v, pr)
    /\ UNCHANGED l

\* PolkaArmsValidBlockSilent — propagates the ValidBlock writeback to
\* validators that have received the proposal but whose validBlock is still
\* Nil. Single-node traces only directly record the receiver arming its own
\* validBlock; the spec's DecideBlock action requires a 2/3 quorum of
\* validators with matching validBlock and validRound. This silent action
\* lets the spec replayer infer that other validators (who clearly armed
\* their validBlock too — otherwise they wouldn't have precommitted) had the
\* same writeback. Only enabled when:
\*   - The next logged event is DecideBlock (a quorum requirement)
\*   - There is a proposal in proposalMsg for the current (chainHeight, round)
\*   - The chosen validator has received the proposal but validBlock is Nil
PolkaArmsValidBlockSilent ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("DecideBlock")
    /\ \E pr \in proposalMsg :
        /\ pr.height = chainHeight
        /\ \E w \in Servers :
              /\ proposalRecvTime[w][pr.height][pr.round] /= Nil
              /\ validBlock[w] = Nil
        \* Only fire when there is NOT YET a quorum of validators with
        \* validBlock = pr.block / validRound = pr.round (the DecideBlock
        \* precondition). Otherwise DecideBlockIfLogged can fire directly.
        /\ ~ \E S \in Quorum :
              \A w \in S :
                /\ validBlock[w] = pr.block
                /\ validRound[w] = pr.round
        \* Deterministically pick the lex-smallest v with recvTime set and
        \* validBlock still Nil — single-path silent action.
        /\ LET v == CHOOSE w \in Servers :
                      /\ proposalRecvTime[w][pr.height][pr.round] /= Nil
                      /\ validBlock[w] = Nil IN
            PolkaArmsValidBlock(v, pr)
    /\ UNCHANGED l

\* ProposeNewBlockSilent — synthesizes a proposal in proposalMsg when the
\* next trace event is DeliverProposal but no matching proposal exists yet.
\* This handles the multi-node gap: a non-instrumented proposer (e.g., test
\* stub vs2) emits no ProposeNewBlock event, but the receiver's
\* DeliverProposal event still fires. Without this silent action, the spec
\* would deadlock because DeliverProposal requires pr \in proposalMsg.
\*
\* The synthesized proposal copies fields from the trace's DeliverProposal
\* event so the post-state validation still matches.
\* BlockTimeFor(h, r) looks ahead in TraceLog for a PolkaArmsValidBlock event
\* with matching height/round and returns its msg.timestamp (which the
\* harness emits as block.Header.Time). If none exists, fall back to the
\* current logline's msg.timestamp (proposal.Timestamp).
\*
\* This handles the test-helper artifact where decideProposal() creates the
\* proposal and block at slightly different real times: proposal.Timestamp
\* and block.Header.Time end up disagreeing in the trace (e.g. ts=10 in
\* DeliverProposal but ts=6 in PolkaArmsValidBlock). In real CometBFT they
\* are equal; the spec models them as the single `block.Header.Time`. We
\* prefer the PolkaArms-side timestamp because subsequent spec invariants
\* (ValidatePostPolkaArms, DecideBlock's monotonic check) compare against
\* it.
BlockTimeFor(h, r) ==
    LET matches == { k \in 1..Len(TraceLog) :
                       /\ TraceLog[k].event.name = "PolkaArmsValidBlock"
                       /\ "msg" \in DOMAIN TraceLog[k].event
                       /\ "height" \in DOMAIN TraceLog[k].event.msg
                       /\ "round" \in DOMAIN TraceLog[k].event.msg
                       /\ TraceLog[k].event.msg.height = h
                       /\ TraceLog[k].event.msg.round = r }
    IN  IF matches = {} THEN MsgField("timestamp", 0)
        ELSE TraceLog[CHOOSE k \in matches : TRUE].event.msg.timestamp

ProposeNewBlockSilent ==
    /\ l <= Len(TraceLog)
    /\ IsEvent("DeliverProposal")
    /\ "msg" \in DOMAIN logline.event
    /\ LET proposer == MsgField("proposer", "")
           h        == MsgField("height", 0)
           r        == MsgField("round", 0)
           b        == TraceValue(MsgField("block", ""))
           ts       == BlockTimeFor(h, r)
           polR     == MsgField("polRound", -1) IN
        /\ proposer \in Servers
        /\ h = chainHeight
        /\ b \in Blocks
        /\ ts \in Times
        /\ ~ \E pr \in proposalMsg : pr.height = h /\ pr.round = r
        /\ proposalMsg' = proposalMsg \cup
             { [proposer |-> proposer, height |-> h, round |-> r,
                polRound |-> polR, block |-> b, timestamp |-> ts,
                sentAt |-> realTime] }
    /\ UNCHANGED <<l, clockVars, chainVars, validVars, currentRound,
                   proposalRecvTime, lastCommitVars, syncVars>>

\* ============================================================================
\* TraceInit / TraceNext / Spec
\* ============================================================================

TraceInit ==
    /\ Init
    /\ l = 1

TraceNext ==
    \/ ProposeNewBlockIfLogged
    \/ ProposeValidBlockIfLogged
    \/ DeliverProposalIfLogged
    \/ AcceptProposalPOLNewIfLogged
    \/ AcceptProposalPOLOldIfLogged
    \/ PolkaArmsValidBlockIfLogged
    \/ AdvanceRoundIfLogged
    \/ ProposerSelfRejectIfLogged
    \/ DecideBlockIfLogged
    \/ ProposerSkipsRoundIfLogged
    \/ DeliverInRoundPrecommitIfLogged
    \/ DeliverLatePrecommitIfLogged
    \/ LockstepAdvanceSilent
    \/ RecordHonestAppHashSilent
    \/ DeliverProposalSilent
    \/ PolkaArmsValidBlockSilent
    \/ ProposeNewBlockSilent

\* TraceProgress is the disjunction of all trace-cursor-advancing actions.
\* Weak fairness on TraceProgress prevents TLC from finding stuttering paths
\* that ignore consumable trace events. Without this, silent actions can fire
\* indefinitely and the trace never gets fully consumed.
TraceProgress ==
    \/ ProposeNewBlockIfLogged
    \/ ProposeValidBlockIfLogged
    \/ DeliverProposalIfLogged
    \/ AcceptProposalPOLNewIfLogged
    \/ AcceptProposalPOLOldIfLogged
    \/ PolkaArmsValidBlockIfLogged
    \/ AdvanceRoundIfLogged
    \/ ProposerSelfRejectIfLogged
    \/ DecideBlockIfLogged
    \/ ProposerSkipsRoundIfLogged
    \/ DeliverInRoundPrecommitIfLogged
    \/ DeliverLatePrecommitIfLogged

TraceSpec ==
    TraceInit
    /\ [][TraceNext]_<<vars, l>>
    /\ WF_<<vars, l>>(TraceProgress)
    \* Silent actions must also be fair — otherwise TLC finds stuttering
    \* paths where the trace would have progressed if the silent action had
    \* fired (e.g., PolkaArmsValidBlockSilent fires once but stops before
    \* the quorum is reached).
    /\ WF_<<vars, l>>(DeliverProposalSilent)
    /\ WF_<<vars, l>>(PolkaArmsValidBlockSilent)
    /\ WF_<<vars, l>>(RecordHonestAppHashSilent)
    /\ WF_<<vars, l>>(ProposeNewBlockSilent)
    /\ WF_<<vars, l>>(LockstepAdvanceSilent)

\* Trace must be fully consumed.
TraceMatched == <>(l > Len(TraceLog))

\* ============================================================================
\* INVARIANTS (subset of MC — exclude fault-injection-only invariants)
\* ============================================================================

\* Structural invariants — must hold on every real execution
TraceTypeOK == TypeOK
TraceValidBlockRoundConsistency == ValidBlockRoundConsistency
TraceDecidedTimestampInRange == DecidedTimestampInRange
TraceMonotonicHeaderTime == MonotonicHeaderTime

\* Family-specific invariants intentionally NOT enabled here:
\*   - TimestampBoundedByCommitTime, BoundedHaltGap: only meaningful under
\*     fault-injection scenarios; a real trace from an honest network must NOT
\*     violate them (we want the bug to surface in MC, not on every trace).
\*   - ExtensionVerifyCoverage, LocalLastCommitConsistency: ditto; real traces
\*     would have to capture an actual Byzantine straggler scenario to violate.
\*   - StateSyncSoundness: state-sync traces are out of scope for the
\*     instrumentation harness; no events touch syncVerified during replay.

===============================================================================
