-------------------------------- MODULE base --------------------------------
(*****************************************************************************)
(* CometBFT consensus — PBTS (Proposer-Based Timestamps) timing layer.       *)
(*                                                                           *)
(* SCOPE (Modeling Brief, Family B — the only bug-hunt target):              *)
(*   This spec models the PBTS *clock* layer that prior abstract-time passes  *)
(*   never reached.  It carries just enough of the Tendermint H/R/S skeleton  *)
(*   (one height, multiple rounds, prevote/precommit/commit, lock+POLRound    *)
(*   re-proposal) to express the four PBTS time mechanisms the brief asks to  *)
(*   model:                                                                   *)
(*     - a discrete per-validator clock with bounded skew <= Precision;       *)
(*     - IsTimely as a prevote guard, applied ONLY to POLRound = -1 proposals *)
(*       (types/proposal.go:97-107, internal/consensus/state.go:1406);        *)
(*     - the adaptive per-round MessageDelay back-off (types/params.go:152);  *)
(*     - the proposer-wait halt mechanism (state.go:1156-1164, 2765-2771);    *)
(*     - the POLRound>=0 re-proposal guarded by a *local* 2/3 polka           *)
(*       (state.go:1536-1538) — the soundness of the timely-exemption.        *)
(*                                                                           *)
(* Families A (WAL-replay timeliness flip) and C (cross-height vote           *)
(* extensions) are CLOSED by the analysis (Do-Not-Model, brief §3.2): no      *)
(* crash/replay action and no vote-extension state appear here.               *)
(*                                                                           *)
(* ABSTRACTION — block identity == its proposal timestamp.  Under PBTS the    *)
(* block's Header.Time IS the proposal Timestamp (state.go:1400 enforces      *)
(* equality), it is part of the block, and every property under test          *)
(* (BlockTimeWithinPrecision / ProposerWaitBounded / TimelyExemptionSound)    *)
(* is a pure function of that timestamp.  We therefore let a block be          *)
(* identified by its timestamp t \in Timestamps; Nil votes carry NilBlock.    *)
(* Distinct real blocks have distinct Header.Time (nanosecond cmttime.Now),   *)
(* so this is injective in practice; re-proposals reuse the exact timestamp.  *)
(*                                                                           *)
(* TIME MODEL — a single global real-time advance moves all correct clocks    *)
(* in lockstep (TendermintPBT.tla:777, the system's own PBTS spec); the       *)
(* bounded skew <= Precision is fixed at Init ([PBTS-CLOCK-PRECISION.0]).      *)
(* recvTime models the single field cs.ProposalReceiveTime (overwritten each   *)
(* round), so it is one value per validator, not a per-round vector.          *)
(*                                                                           *)
(* BFT environment (brief §1): static corruption, Faulty a CONSTANT with      *)
(* 3*|Faulty| < |Server|; honest signatures unforgeable (only the designated  *)
(* proposer's proposal is accepted; a faulty proposer may pick an ARBITRARY   *)
(* timestamp but is still routed through the receiver-side IsTimely gate —     *)
(* never bypassing it).                                                       *)
(*****************************************************************************)
EXTENDS Integers, FiniteSets, Sequences, TLC

CONSTANTS
    s1, s2, s3, s4,   \* validator identities (model values); s4 is Byzantine
    MaxRound,         \* highest round modeled (Rounds == 0..MaxRound)
    MaxTime,          \* highest discrete clock tick (Timestamps == 0..MaxTime)
    Precision,        \* PBTS Precision: future-dating bound + max clock skew
    BaseMessageDelay, \* PBTS MessageDelay at round 0 (params.go:218-223)
    MaxMessageDelay,  \* cap on the per-round back-off (params.go:34-41)
    LastBlockTime     \* committed Time of the previous height (drives proposer-wait)

----------------------------------------------------------------------------
(* Validator topology.  n = 3f+1 with f = 1: three correct, one Byzantine.    *)
Server  == {s1, s2, s3, s4}
Correct == {s1, s2, s3}
Faulty  == {s4}
N       == Cardinality(Server)

ASSUME 3 * Cardinality(Faulty) < N          \* BFT threshold (brief §1)
ASSUME Precision \in Nat /\ Precision >= 1
ASSUME BaseMessageDelay \in Nat /\ MaxMessageDelay >= BaseMessageDelay
ASSUME LastBlockTime \in 0..MaxTime

Rounds       == 0 .. MaxRound
Timestamps   == 0 .. MaxTime
Steps        == {"PROPOSE", "PREVOTE", "PRECOMMIT", "DECIDED"}

NilBlock     == -1                 \* "Nil" block id (nil prevote/precommit)
NilRound     == -1                 \* POLRound = -1 (a fresh, non-reproposed value)
NilTime      == -1                 \* receive time not yet recorded this round
NilDecision  == -1                 \* no decision yet
BlockOrNil   == Timestamps \cup {NilBlock}

(* PROPOSER SCHEDULE — adversarially schedulable (over-approximation).         *)
(* Rather than naming a fixed round-robin proposer (which would name specific   *)
(* correct validators and break Permutations(Correct) symmetry), we let *any*   *)
(* validator be the proposer of a round, first-come, one proposal per round     *)
(* (guarded by ProposalsIn(r) = {}).  This only *strengthens* the adversary     *)
(* (it can pick who proposes), so it is sound for the Family-B safety hunt:      *)
(* a "Confirm" under it is a stronger result, and any violation is re-checked    *)
(* against the real round-robin in Phase 4.  It makes s1/s2/s3 interchangeable, *)
(* enabling sound symmetry reduction (the lone Byzantine s4 is fixed).          *)

----------------------------------------------------------------------------
(* Helpers                                                                    *)
Min2(a, b) == IF a <= b THEN a ELSE b
Max2(a, b) == IF a >= b THEN a ELSE b
AbsDiff(a, b) == IF a >= b THEN a - b ELSE b - a

IsQuorum(S) == 3 * Cardinality(S) > 2 * N    \* 2/3 voting power (equal weights)

(* params.go:152-165 InRound: MessageDelay grows with the round and is capped. *)
(* The implementation uses MessageDelay * 1.1^round; we abstract the exact      *)
(* growth shape as a monotone, capped step function.  Only the *intent* is      *)
(* load-bearing for the bound: InRound loosens ONLY the upper (too-old) timely  *)
(* bound and leaves Precision — the future-dating bound — constant per round.   *)
MessageDelayInRound(r) == Min2(MaxMessageDelay, BaseMessageDelay + r)

(* types/proposal.go:97-107 IsTimely(recvTime, sp):                           *)
(*   recvTime >= Timestamp - Precision   (future-dating bound: <= Precision)   *)
(*   recvTime <= Timestamp + MessageDelay + Precision  (staleness bound)        *)
(* state.go:1373 evaluates it with InRound(Proposal.Round).                     *)
IsTimely(recvT, t, r) ==
    /\ recvT >= t - Precision
    /\ recvT <= t + MessageDelayInRound(r) + Precision

----------------------------------------------------------------------------
VARIABLES
    \* --- core H/R/S machine (per correct validator) --------------------------
    round,        \* round[s]: current round
    step,         \* step[s] \in Steps
    lockedValue,  \* lockedValue[s] \in BlockOrNil  (locked block id)
    lockedRound,  \* lockedRound[s] \in Rounds \cup {NilRound}
    validValue,   \* validValue[s] \in BlockOrNil   (cs.ValidBlock id)
    validRound,   \* validRound[s] \in Rounds \cup {NilRound}
    decision,     \* decision[s] \in Timestamps \cup {NilDecision}
    \* --- PBTS time layer ----------------------------------------------------
    clock,        \* clock[s] \in Timestamps: local clock (cmttime.Now abstraction)
    recvTime,     \* recvTime[s]: clock when s recorded the CURRENT round's proposal
                  \*   (cs.ProposalReceiveTime, state.go:2081); reset each round
    \* --- messages (sets; signatures dedup, faulty may equivocate) -----------
    proposals,    \* set of [src, round, time, polRound]
    prevotes,     \* set of [src, round, id]
    precommits,   \* set of [src, round, id]
    \* --- auxiliary bug-hunt bookkeeping -------------------------------------
    timelyBlocks  \* set of block ids that some correct validator prevoted via
                  \*   the POLRound = -1 *timely* branch (timely-exemption base)

coreVars == <<round, step, lockedValue, lockedRound, validValue, validRound, decision>>
timeVars == <<clock, recvTime>>
msgVars  == <<proposals, prevotes, precommits>>
auxVars  == <<timelyBlocks>>
vars     == <<coreVars, timeVars, msgVars, auxVars>>

----------------------------------------------------------------------------
(* Derived quantities used by guards and invariants.                         *)
ClockValues     == { clock[q] : q \in Correct }
MaxCorrectClock == CHOOSE x \in ClockValues : \A y \in ClockValues : y <= x
MinCorrectClock == CHOOSE x \in ClockValues : \A y \in ClockValues : x <= y

ProposalsIn(r)  == { m \in proposals : m.round = r }
ProposedTimes   == { m.time : m \in proposals }   \* block ids that actually exist
PrevoteSrcs(r, v)   == { m.src : m \in {mm \in prevotes   : mm.round = r /\ mm.id = v} }
PrecommitSrcs(r, v) == { m.src : m \in {mm \in precommits : mm.round = r /\ mm.id = v} }
HasPolka(r, v)  == v # NilBlock /\ IsQuorum(PrevoteSrcs(r, v))
HasCommit(r, v) == v # NilBlock /\ IsQuorum(PrecommitSrcs(r, v))

SendPrevote(s, r, v)   == prevotes'   = prevotes   \cup {[src |-> s, round |-> r, id |-> v]}
SendPrecommit(s, r, v) == precommits' = precommits \cup {[src |-> s, round |-> r, id |-> v]}

----------------------------------------------------------------------------
(* doPrevote gate for a received proposal m, evaluated by correct s.          *)
(* Mirrors state.go:1399-1556.                                                *)
GatePass(s, m) ==
    IF m.polRound = NilRound
    THEN \* POLRound = -1 branch: TIMELY check applies (state.go:1406), then
         \* the line-23 lock condition (state.go:1463-1507).
         /\ IsTimely(recvTime[s], m.time, round[s])
         /\ (lockedRound[s] = NilRound \/ lockedValue[s] = m.time)
    ELSE \* POLRound = pr >= 0 branch: NO timely check; instead require a LOCAL
         \* 2/3 polka for the block at pr (state.go:1536-1538) and the line-29
         \* lock condition (state.go:1539-1548).
         /\ HasPolka(m.polRound, m.time)
         /\ m.polRound < round[s]
         /\ (lockedRound[s] < m.polRound \/ lockedValue[s] = m.time)

----------------------------------------------------------------------------
(*                              ACTIONS                                       *)
----------------------------------------------------------------------------

(* AdvanceRealTime — real time passes; all correct clocks advance in lockstep   *)
(* (mirrors the system's own PBTS spec TendermintPBT.tla:777-784).  Bounded     *)
(* clock skew is fixed at Init within Precision ([PBTS-CLOCK-PRECISION.0],      *)
(* pbts-sysmodel.md) and preserved by uniform advance, so it never needs        *)
(* re-checking.  The interleaving of this action with message delivery is what  *)
(* gives each validator a different recvTime for the same proposal — the source *)
(* of timely-verdict divergence the timely check must tolerate.                 *)
AdvanceRealTime ==
    /\ MaxCorrectClock < MaxTime
    /\ clock' = [q \in Correct |-> clock[q] + 1]
    /\ UNCHANGED <<coreVars, recvTime, msgVars, auxVars>>

(* ProposerWait — the enterPropose halt (state.go:1156-1164 + proposerWaitTime  *)
(* 2765-2771): a correct proposer whose local clock has not yet reached the     *)
(* previous block's time sleeps before it may Propose.  Realized as real time   *)
(* advancing while the round's correct proposer is still below LastBlockTime     *)
(* (proposerWaitTime > 0).  Same successor state as AdvanceRealTime; named       *)
(* separately for the mechanism and for instrumentation (the scheduled          *)
(* RoundStepNewRound timeout, state.go:1161).                                    *)
ProposerWait ==
    /\ \E s \in Correct :
         /\ step[s] = "PROPOSE"
         /\ clock[s] < LastBlockTime          \* a would-be proposer still below LastBlockTime
    /\ MaxCorrectClock < MaxTime
    /\ clock' = [q \in Correct |-> clock[q] + 1]
    /\ UNCHANGED <<coreVars, recvTime, msgVars, auxVars>>

(* StartRound — give up the current round and enter the next (OnTimeout*       *)
(* path; enterNewRound -> enterPropose entry).  A validator advances only      *)
(* after it has precommitted in the current round.  cs.Proposal and            *)
(* cs.ProposalReceiveTime are reset for the new round (recvTime := NilTime).    *)
StartRound(s) ==
    /\ s \in Correct
    /\ step[s] = "PRECOMMIT"
    /\ decision[s] = NilDecision
    /\ round[s] < MaxRound
    /\ round'    = [round EXCEPT ![s] = round[s] + 1]
    /\ step'     = [step EXCEPT ![s] = "PROPOSE"]
    /\ recvTime' = [recvTime EXCEPT ![s] = NilTime]
    /\ UNCHANGED <<lockedValue, lockedRound, validValue, validRound, decision,
                   clock, proposals, prevotes, precommits, auxVars>>

(* Propose — a correct proposer emits its proposal                            *)
(* (defaultDecideProposal, state.go:1219-...; block time from MakeBlock,        *)
(* state/state.go:246-247).  Two code paths:                                   *)
(*   - reuse ValidBlock if present -> POLRound = validRound (re-proposal);      *)
(*   - otherwise a fresh block with Timestamp = local clock, POLRound = -1.     *)
(* Gated by the proposer-wait having elapsed (clock >= LastBlockTime).         *)
Propose(s) ==
    /\ s \in Correct
    /\ step[s] = "PROPOSE"
    /\ clock[s] >= LastBlockTime               \* proposerWaitTime <= 0 (proposer-wait elapsed)
    /\ ProposalsIn(round[s]) = {}              \* one proposal per round
    /\ LET r == round[s] IN
         IF validValue[s] # NilBlock
         THEN \* re-proposal: reuse ValidBlock id (= its original timestamp)
              proposals' = proposals \cup
                  {[src |-> s, round |-> r, time |-> validValue[s],
                    polRound |-> validRound[s]]}
         ELSE \* fresh proposal: Timestamp = proposer's local clock
              proposals' = proposals \cup
                  {[src |-> s, round |-> r, time |-> clock[s],
                    polRound |-> NilRound]}
    /\ UNCHANGED <<coreVars, timeVars, prevotes, precommits, auxVars>>

(* ReceiveProposal — defaultSetProposal (state.go:2043-2092).  Records the     *)
(* receive time once per round, from the local clock (cs.ProposalReceiveTime = *)
(* recvTime, state.go:2081).  Rejects an out-of-range POLRound (2056-2059).    *)
ReceiveProposal(s) ==
    /\ s \in Correct
    /\ recvTime[s] = NilTime
    /\ \E m \in ProposalsIn(round[s]) :
         /\ (m.polRound = NilRound \/ (m.polRound >= 0 /\ m.polRound < m.round))
         /\ recvTime' = [recvTime EXCEPT ![s] = clock[s]]
    /\ UNCHANGED <<coreVars, clock, msgVars, auxVars>>

(* PrevoteBlock — defaultDoPrevote, prevote FOR the proposed block when the     *)
(* gate passes (state.go:1463-1507 / 1539-1548).  If it passed via the         *)
(* POLRound = -1 *timely* branch, record the block as timely-witnessed: this    *)
(* is the inductive base of the timely-exemption (TimelyExemptionSound).        *)
PrevoteBlock(s) ==
    /\ s \in Correct
    /\ step[s] = "PROPOSE"
    /\ recvTime[s] # NilTime
    /\ \E m \in ProposalsIn(round[s]) :
         /\ GatePass(s, m)
         /\ SendPrevote(s, round[s], m.time)
         /\ timelyBlocks' = IF m.polRound = NilRound
                            THEN timelyBlocks \cup {m.time}
                            ELSE timelyBlocks
    /\ step' = [step EXCEPT ![s] = "PREVOTE"]
    /\ UNCHANGED <<round, lockedValue, lockedRound, validValue, validRound,
                   decision, timeVars, proposals, precommits>>

(* PrevoteNil — defaultDoPrevote nil paths: no (timely, gate-passing) proposal  *)
(* for this round (proposal absent / untimely / locked-mismatch / app-reject).  *)
(* state.go:1386/1393/1402/1415/1490/1506.                                      *)
PrevoteNil(s) ==
    /\ s \in Correct
    /\ step[s] = "PROPOSE"
    /\ ~ \E m \in ProposalsIn(round[s]) :
            /\ recvTime[s] # NilTime
            /\ GatePass(s, m)
    /\ SendPrevote(s, round[s], NilBlock)
    /\ step' = [step EXCEPT ![s] = "PREVOTE"]
    /\ UNCHANGED <<round, lockedValue, lockedRound, validValue, validRound,
                   decision, timeVars, proposals, precommits, auxVars>>

(* cs.ValidBlock/ValidRound are set together with the lock in PrecommitBlock     *)
(* below (the dominant case).  The separate addVote setValidBlock refresh — a    *)
(* validator adopting a polka it observed but did not lock — is intentionally    *)
(* NOT a standalone action here: it would multiply state with no effect on the   *)
(* property under test, because the timely-exemption soundness gate lives at     *)
(* the PREVOTER (GatePass's HasPolka(polRound,t) check, state.go:1536-1538), not *)
(* at the proposer.  Re-proposal of the LOCKED block exercises that gate fully.  *)

(* PrecommitBlock — enterPrecommit, lock-on-polka: a 2/3 prevote majority for a *)
(* non-nil block in the current round => lock it, refresh ValidBlock, and        *)
(* precommit it (state.go enterPrecommit 1658-1683).                             *)
PrecommitBlock(s) ==
    /\ s \in Correct
    /\ step[s] = "PREVOTE"
    /\ \E v \in Timestamps :
         /\ HasPolka(round[s], v)
         /\ lockedValue' = [lockedValue EXCEPT ![s] = v]
         /\ lockedRound' = [lockedRound EXCEPT ![s] = round[s]]
         /\ validValue'  = [validValue EXCEPT ![s] = v]
         /\ validRound'  = [validRound EXCEPT ![s] = round[s]]
         /\ SendPrecommit(s, round[s], v)
    /\ step' = [step EXCEPT ![s] = "PRECOMMIT"]
    /\ UNCHANGED <<round, decision, timeVars, proposals, prevotes, auxVars>>

(* PrecommitNil — enterPrecommit with no block polka (nil polka or timeout):    *)
(* precommit nil, keep any existing lock (state.go:1626/1643).                   *)
PrecommitNil(s) ==
    /\ s \in Correct
    /\ step[s] = "PREVOTE"
    /\ ~ \E v \in Timestamps : HasPolka(round[s], v)
    /\ SendPrecommit(s, round[s], NilBlock)
    /\ step' = [step EXCEPT ![s] = "PRECOMMIT"]
    /\ UNCHANGED <<round, lockedValue, lockedRound, validValue, validRound,
                   decision, timeVars, proposals, prevotes, auxVars>>

(* Decide — finalizeCommit: a 2/3 precommit majority for a non-nil block in     *)
(* some round commits it (state.go finalizeCommit 1829).  decision[s] := block  *)
(* id (= the committed Header.Time).                                            *)
Decide(s) ==
    /\ s \in Correct
    /\ decision[s] = NilDecision
    /\ \E r \in Rounds, v \in Timestamps :
         /\ HasCommit(r, v)
         /\ decision' = [decision EXCEPT ![s] = v]
    /\ step' = [step EXCEPT ![s] = "DECIDED"]
    /\ UNCHANGED <<round, lockedValue, lockedRound, validValue, validRound,
                   timeVars, msgVars, auxVars>>

----------------------------------------------------------------------------
(*                       BFT ADVERSARY ACTIONS                                *)
(* The application + up to f validators are adversarial.  A faulty proposer    *)
(* picks an ARBITRARY timestamp/POLRound; faulty validators emit arbitrary     *)
(* prevotes/precommits (equivocation allowed).  Correct validators still run   *)
(* IsTimely on faulty proposals (the gate is never bypassed).  MC bounds the   *)
(* firing rate of each via counters; the base spec leaves them unbounded.      *)
----------------------------------------------------------------------------

(* FaultyPropose — a Byzantine proposer future-dates arbitrarily.  Under the    *)
(* adversarial proposer schedule the faulty validator may be the round's        *)
(* proposer (first-come, one per round).                                        *)
FaultyPropose ==
    /\ \E f \in Faulty, r \in Rounds, t \in Timestamps,
          pr \in {NilRound} \cup (0 .. MaxRound) :
         /\ (pr = NilRound \/ (pr >= 0 /\ pr < r))   \* else receiver rejects it
         /\ ProposalsIn(r) = {}
         /\ proposals' = proposals \cup
                {[src |-> f, round |-> r, time |-> t, polRound |-> pr]}
    /\ UNCHANGED <<coreVars, timeVars, prevotes, precommits, auxVars>>

(* FaultyPrevote — a Byzantine validator prevotes for an existing block or nil. *)
(* Restricting the vote target to {NilBlock} \cup ProposedTimes loses no power:  *)
(* a vote for a block id no proposal carries can never join a quorum (correct    *)
(* validators only ever vote proposed blocks, and f < quorum), so it is a dead   *)
(* move — and a real Byzantine node would target actual proposals.               *)
FaultyPrevote ==
    /\ \E f \in Faulty, r \in Rounds, v \in {NilBlock} \cup ProposedTimes :
         /\ [src |-> f, round |-> r, id |-> v] \notin prevotes
         /\ SendPrevote(f, r, v)
    /\ UNCHANGED <<coreVars, timeVars, proposals, precommits, auxVars>>

(* FaultyPrecommit — a Byzantine validator precommits for an existing block/nil. *)
FaultyPrecommit ==
    /\ \E f \in Faulty, r \in Rounds, v \in {NilBlock} \cup ProposedTimes :
         /\ [src |-> f, round |-> r, id |-> v] \notin precommits
         /\ SendPrecommit(f, r, v)
    /\ UNCHANGED <<coreVars, timeVars, proposals, prevotes, auxVars>>

----------------------------------------------------------------------------
Init ==
    /\ round       = [s \in Correct |-> 0]
    /\ step        = [s \in Correct |-> "PROPOSE"]
    /\ lockedValue = [s \in Correct |-> NilBlock]
    /\ lockedRound = [s \in Correct |-> NilRound]
    /\ validValue  = [s \in Correct |-> NilBlock]
    /\ validRound  = [s \in Correct |-> NilRound]
    /\ decision    = [s \in Correct |-> NilDecision]
    /\ clock       \in [Correct -> 0 .. Precision]   \* initial skew <= Precision
    /\ recvTime    = [s \in Correct |-> NilTime]
    /\ proposals   = {}
    /\ prevotes    = {}
    /\ precommits  = {}
    /\ timelyBlocks = {}

Next ==
    \/ AdvanceRealTime
    \/ ProposerWait
    \/ \E s \in Correct : StartRound(s)
    \/ \E s \in Correct : Propose(s)
    \/ \E s \in Correct : ReceiveProposal(s)
    \/ \E s \in Correct : PrevoteBlock(s)
    \/ \E s \in Correct : PrevoteNil(s)
    \/ \E s \in Correct : PrecommitBlock(s)
    \/ \E s \in Correct : PrecommitNil(s)
    \/ \E s \in Correct : Decide(s)
    \/ FaultyPropose
    \/ FaultyPrevote
    \/ FaultyPrecommit

Spec == Init /\ [][Next]_vars

(* Correct validators are interchangeable; sound for safety (see PROPOSER       *)
(* SCHEDULE note above).  Used by base.cfg.                                     *)
Symmetry == Permutations(Correct)

----------------------------------------------------------------------------
(*                            INVARIANTS                                      *)
----------------------------------------------------------------------------

TypeOK ==
    /\ round       \in [Correct -> Rounds]
    /\ step        \in [Correct -> Steps]
    /\ lockedValue \in [Correct -> BlockOrNil]
    /\ lockedRound \in [Correct -> Rounds \cup {NilRound}]
    /\ validValue  \in [Correct -> BlockOrNil]
    /\ validRound  \in [Correct -> Rounds \cup {NilRound}]
    /\ decision    \in [Correct -> Timestamps \cup {NilDecision}]
    /\ clock       \in [Correct -> Timestamps]
    /\ recvTime    \in [Correct -> Timestamps \cup {NilTime}]
    /\ timelyBlocks \subseteq Timestamps

(* Structural: clocks of correct validators stay within Precision.            *)
(* [PBTS-CLOCK-PRECISION.0] — held by the uniform-advance time model.         *)
ClocksSynchronized ==
    \A p, q \in Correct : AbsDiff(clock[p], clock[q]) <= Precision

(* ---- Family B / MC-1 safety invariants (brief §5) ---- *)

(* BlockTimeWithinPrecision (MC-1, headline).  Any block committed by a        *)
(* correct validator has Time <= (max correct clock) + Precision.  Equivalent  *)
(* to: the next height's proposer-wait (decidedTime - now) <= Precision.       *)
BlockTimeWithinPrecision ==
    \A s \in Correct :
        decision[s] # NilDecision => decision[s] <= MaxCorrectClock + Precision

(* ProposerWaitBounded (MC-1 corollary).  The wait a *slow* next-height        *)
(* proposer would incur, decidedTime - (min correct clock), is bounded by      *)
(* Precision + skew (skew itself <= Precision).                                *)
ProposerWaitBounded ==
    \A s \in Correct :
        decision[s] # NilDecision =>
            decision[s] <= MinCorrectClock + Precision + Precision

(* TimelyExemptionSound.  No block reaches a commit without some correct        *)
(* validator having prevoted it through the POLRound = -1 *timely* gate.        *)
(* A violation = the POLRound>=0 re-proposal exemption let an untimely block    *)
(* commit purely via Byzantine-assisted polkas (the novel internal halt        *)
(* vector MC-1 hunts).                                                          *)
TimelyExemptionSound ==
    \A s \in Correct :
        decision[s] # NilDecision => decision[s] \in timelyBlocks

(* ---- regression safety (PBTS must not weaken Agreement) ---- *)
Agreement ==
    \A p, q \in Correct :
        (decision[p] # NilDecision /\ decision[q] # NilDecision)
            => decision[p] = decision[q]

(* ---- liveness (Family B / #2184); requires fairness + BFS ---- *)
PBTSProgress == <>(\E s \in Correct : decision[s] # NilDecision)

=============================================================================
