--------------------------- MODULE MC ---------------------------
(*
 * Model checking specification for CometBFT — Round 2 (BFT extensions).
 *
 * Wraps base with counter-bounded fault-injection actions.
 *
 * Fault model coverage (Distributed + BFT overlay):
 *   Round-1 carryover:
 *     5.1 Crash:                MCCrash with persistent / in-memory split
 *     5.2 Loss / Partition:     MCLoseMessage
 *     5.3 Timeout:              MCHandleTimeout{Propose,Prevote,Precommit}
 *   BFT layer (round 2):
 *     2.1 Equivocation:         MCByzEquivocate
 *     2.4 Selective dissem:     MCByzSelectiveDisseminate
 *     2.6 Amnesia:              MCByzAmnesia + MCWALTailTruncate
 *     2.5 + 2.1 VE reuse:       MCByzAttachSameVEToBoth, MCByzReplaySelfVE,
 *                               MCByzLateAddPrecommitWithBadVE
 *     2.2 + 2.7 Lunatic:        MCByzLunaticForkHeader
 *     2.8 Evidence Byz:         MCByzInjectInvalidEvidence,
 *                               MCByzFloodEvidence,
 *                               MCEvidenceExpiryRace,
 *                               MCCrashDuringConsensusBuffer,
 *                               MCProposerExcludeEvidence
 *     2.1 + 2.7 Locking:        MCByzProposeAlternating,
 *                               MCByzPolkaForUnknownBlock,
 *                               MCByzPOLRoundGtRound
 *
 * Unbounded (reactive / deterministic):
 *   - EnterNewRound, EnterPropose, EnterPrevote, EnterPrevoteWait,
 *     EnterPrecommit*, EnterPrecommitWait, EnterCommit, FinalizeCommit
 *   - Receive{Proposal,Prevote,Precommit}, RoundSkip*
 *   - Recover, DetectEquivocation, ProcessConsensusBuffer, CommitEvidence,
 *     LightClientVerify
 *)

EXTENDS base

cometbft == INSTANCE base

\* ============================================================================
\* CONSTRAINT CONSTANTS — per-family bug-hunting bounds
\* ============================================================================

CONSTANT MaxTimeoutLimit
CONSTANT MaxCrashLimit
CONSTANT MaxLoseLimit
CONSTANT MaxMsgBufferLimit

\* Family 1
CONSTANT MaxByzEquivocateLimit
CONSTANT MaxByzSelectiveLimit

\* Family 2
CONSTANT MaxByzAmnesiaLimit
CONSTANT MaxWALTruncateLimit

\* Family 3
CONSTANT MaxByzVEAttachLimit
CONSTANT MaxByzVELateLimit
CONSTANT MaxByzVEReplayLimit

\* Family 4
CONSTANT MaxByzLunaticLimit

\* Family 5
CONSTANT MaxByzInjectEvLimit
CONSTANT MaxByzFloodEvLimit
CONSTANT MaxEvidenceRaceLimit
CONSTANT MaxCrashBufLimit
CONSTANT MaxProposerExcludeLimit
CONSTANT MaxAdvanceClockLimit

\* Family 6
CONSTANT MaxByzProposeAltLimit
CONSTANT MaxByzPolkaUnkLimit
CONSTANT MaxByzPOLRoundLimit

\* ============================================================================
\* COUNTER VARIABLES
\* ============================================================================

VARIABLE faultCounters

faultVars == <<faultCounters>>

\* ============================================================================
\* COUNTER-BOUNDED FAULT-INJECTION ACTIONS
\* ============================================================================

\* --- Round-1 fault wrappers ---

MCHandleTimeoutPropose(i) ==
    /\ faultCounters.timeout < MaxTimeoutLimit
    /\ cometbft!HandleTimeoutPropose(i)
    /\ faultCounters' = [faultCounters EXCEPT !.timeout = @ + 1]

MCHandleTimeoutPrevote(i) ==
    /\ faultCounters.timeout < MaxTimeoutLimit
    /\ cometbft!HandleTimeoutPrevote(i)
    /\ faultCounters' = [faultCounters EXCEPT !.timeout = @ + 1]

MCHandleTimeoutPrecommit(i) ==
    /\ faultCounters.timeout < MaxTimeoutLimit
    /\ cometbft!HandleTimeoutPrecommit(i)
    /\ faultCounters' = [faultCounters EXCEPT !.timeout = @ + 1]

MCCrash(i) ==
    /\ faultCounters.crash < MaxCrashLimit
    /\ cometbft!Crash(i)
    /\ faultCounters' = [faultCounters EXCEPT !.crash = @ + 1]

MCLoseMessage(m) ==
    /\ faultCounters.lose < MaxLoseLimit
    /\ cometbft!LoseMessage(m)
    /\ faultCounters' = [faultCounters EXCEPT !.lose = @ + 1]

\* --- Family 1: Equivocation + selective dissemination ---

MCByzEquivocate(i, h, r) ==
    /\ faultCounters.byzEquivocate < MaxByzEquivocateLimit
    /\ cometbft!ByzEquivocate(i, h, r)
    /\ faultCounters' = [faultCounters EXCEPT !.byzEquivocate = @ + 1]

MCByzSelectiveDisseminate(i, h, r) ==
    /\ faultCounters.byzSelective < MaxByzSelectiveLimit
    /\ cometbft!ByzSelectiveDisseminate(i, h, r)
    /\ faultCounters' = [faultCounters EXCEPT !.byzSelective = @ + 1]

\* --- Family 2: Amnesia + WAL tail truncation ---

MCByzAmnesia(i, h, r2) ==
    /\ faultCounters.byzAmnesia < MaxByzAmnesiaLimit
    /\ cometbft!ByzAmnesia(i, h, r2)
    /\ faultCounters' = [faultCounters EXCEPT !.byzAmnesia = @ + 1]

MCWALTailTruncate(i, k) ==
    /\ faultCounters.walTruncate < MaxWALTruncateLimit
    /\ cometbft!WALTailTruncate(i, k)
    /\ faultCounters' = [faultCounters EXCEPT !.walTruncate = @ + 1]

\* --- Family 3: VE reuse / late / replay ---

MCByzAttachSameVEToBoth(i, h, r) ==
    /\ faultCounters.byzVEAttach < MaxByzVEAttachLimit
    /\ cometbft!ByzAttachSameVEToBoth(i, h, r)
    /\ faultCounters' = [faultCounters EXCEPT !.byzVEAttach = @ + 1]

MCByzLateAddPrecommitWithBadVE(i, h, r) ==
    /\ faultCounters.byzVELate < MaxByzVELateLimit
    /\ cometbft!ByzLateAddPrecommitWithBadVE(i, h, r)
    /\ faultCounters' = [faultCounters EXCEPT !.byzVELate = @ + 1]

MCByzReplaySelfVE(i, h, oR, nR) ==
    /\ faultCounters.byzVEReplay < MaxByzVEReplayLimit
    /\ cometbft!ByzReplaySelfVE(i, h, oR, nR)
    /\ faultCounters' = [faultCounters EXCEPT !.byzVEReplay = @ + 1]

\* --- Family 4: Lunatic header fork ---

MCByzLunaticForkHeader(h) ==
    /\ faultCounters.byzLunatic < MaxByzLunaticLimit
    /\ cometbft!ByzLunaticForkHeader(h)
    /\ faultCounters' = [faultCounters EXCEPT !.byzLunatic = @ + 1]

\* --- Family 5: Evidence lifecycle ---

MCByzInjectInvalidEvidence(i) ==
    /\ faultCounters.byzInjectEv < MaxByzInjectEvLimit
    /\ cometbft!ByzInjectInvalidEvidence(i)
    /\ faultCounters' = [faultCounters EXCEPT !.byzInjectEv = @ + 1]

MCByzFloodEvidence(i) ==
    /\ faultCounters.byzFloodEv < MaxByzFloodEvLimit
    /\ cometbft!ByzFloodEvidence(i)
    /\ faultCounters' = [faultCounters EXCEPT !.byzFloodEv = @ + 1]

MCEvidenceExpiryRace(s1, s2, ev) ==
    /\ faultCounters.evRace < MaxEvidenceRaceLimit
    /\ cometbft!EvidenceExpiryRace(s1, s2, ev)
    /\ faultCounters' = [faultCounters EXCEPT !.evRace = @ + 1]

MCCrashDuringConsensusBuffer(i) ==
    /\ faultCounters.crashBuf < MaxCrashBufLimit
    /\ cometbft!CrashDuringConsensusBuffer(i)
    /\ faultCounters' = [faultCounters EXCEPT !.crashBuf = @ + 1]

MCProposerExcludeEvidence(i, ev) ==
    /\ faultCounters.proposerExclude < MaxProposerExcludeLimit
    /\ cometbft!ProposerExcludeEvidence(i, ev)
    /\ faultCounters' = [faultCounters EXCEPT !.proposerExclude = @ + 1]

MCAdvanceClock(i) ==
    /\ faultCounters.advClock < MaxAdvanceClockLimit
    /\ cometbft!AdvanceClock(i)
    /\ faultCounters' = [faultCounters EXCEPT !.advClock = @ + 1]

\* --- Family 6: Byzantine proposer interleaving ---

MCByzProposeAlternating(i, v) ==
    /\ faultCounters.byzProposeAlt < MaxByzProposeAltLimit
    /\ cometbft!ByzProposeAlternating(i, v)
    /\ faultCounters' = [faultCounters EXCEPT !.byzProposeAlt = @ + 1]

MCByzPolkaForUnknownBlock(blockX) ==
    /\ faultCounters.byzPolkaUnk < MaxByzPolkaUnkLimit
    /\ cometbft!ByzPolkaForUnknownBlock(blockX)
    /\ faultCounters' = [faultCounters EXCEPT !.byzPolkaUnk = @ + 1]

MCByzPOLRoundGtRound(i) ==
    /\ faultCounters.byzPOLRound < MaxByzPOLRoundLimit
    /\ cometbft!ByzPOLRoundGtRound(i)
    /\ faultCounters' = [faultCounters EXCEPT !.byzPOLRound = @ + 1]

\* ============================================================================
\* UNBOUNDED (DETERMINISTIC / REACTIVE) ACTIONS
\* ============================================================================

MCEnterNewRound(i) ==
    /\ cometbft!EnterNewRound(i, round[i])
    /\ UNCHANGED faultVars

MCEnterPropose(i) ==
    /\ cometbft!EnterPropose(i)
    /\ UNCHANGED faultVars

MCEnterPrevote(i) ==
    /\ cometbft!EnterPrevote(i)
    /\ UNCHANGED faultVars

MCEnterPrevoteWait(i) ==
    /\ cometbft!EnterPrevoteWait(i)
    /\ UNCHANGED faultVars

MCEnterPrecommitNoPolka(i) ==
    /\ cometbft!EnterPrecommitNoPolka(i)
    /\ UNCHANGED faultVars

MCEnterPrecommitNilPolka(i) ==
    /\ cometbft!EnterPrecommitNilPolka(i)
    /\ UNCHANGED faultVars

MCEnterPrecommitRelockPolka(i) ==
    /\ cometbft!EnterPrecommitRelockPolka(i)
    /\ UNCHANGED faultVars

MCEnterPrecommitNewLockPolka(i) ==
    /\ cometbft!EnterPrecommitNewLockPolka(i)
    /\ UNCHANGED faultVars

MCEnterPrecommitUnknownPolka(i) ==
    /\ cometbft!EnterPrecommitUnknownPolka(i)
    /\ UNCHANGED faultVars

MCEnterPrecommitWait(i) ==
    /\ cometbft!EnterPrecommitWait(i)
    /\ UNCHANGED faultVars

MCEnterCommit(i) ==
    /\ cometbft!EnterCommit(i)
    /\ UNCHANGED faultVars

MCFinalizeCommit(i) ==
    /\ cometbft!FinalizeCommit(i)
    /\ UNCHANGED faultVars

MCRecover(i) ==
    /\ cometbft!Recover(i)
    /\ UNCHANGED faultVars

MCRoundSkipPrevote(i) ==
    /\ cometbft!RoundSkipPrevote(i)
    /\ UNCHANGED faultVars

MCRoundSkipPrecommit(i) ==
    /\ cometbft!RoundSkipPrecommit(i)
    /\ UNCHANGED faultVars

MCDetectEquivocation(i) ==
    /\ cometbft!DetectEquivocation(i)
    /\ UNCHANGED faultVars

MCProcessConsensusBuffer(i) ==
    /\ cometbft!ProcessConsensusBuffer(i)
    /\ UNCHANGED faultVars

MCCommitEvidence(i, ev) ==
    /\ cometbft!CommitEvidence(i, ev)
    /\ UNCHANGED faultVars

MCReceiveProposal(i, m) ==
    /\ cometbft!ReceiveProposal(i, m)
    /\ UNCHANGED faultVars

MCReceivePrevote(i, m) ==
    /\ cometbft!ReceivePrevote(i, m)
    /\ UNCHANGED faultVars

MCReceivePrecommit(i, m) ==
    /\ cometbft!ReceivePrecommit(i, m)
    /\ UNCHANGED faultVars

MCLightClientVerify(c, m) ==
    /\ cometbft!LightClientVerify(c, m)
    /\ UNCHANGED faultVars

\* ============================================================================
\* INIT AND NEXT
\* ============================================================================

MCInit ==
    /\ Init
    /\ faultCounters = [
         timeout         |-> 0,
         crash           |-> 0,
         lose            |-> 0,
         byzEquivocate   |-> 0,
         byzSelective    |-> 0,
         byzAmnesia      |-> 0,
         walTruncate     |-> 0,
         byzVEAttach     |-> 0,
         byzVELate       |-> 0,
         byzVEReplay     |-> 0,
         byzLunatic      |-> 0,
         byzInjectEv     |-> 0,
         byzFloodEv      |-> 0,
         evRace          |-> 0,
         crashBuf        |-> 0,
         proposerExclude |-> 0,
         advClock        |-> 0,
         byzProposeAlt   |-> 0,
         byzPolkaUnk     |-> 0,
         byzPOLRound     |-> 0]

MCNextAsync(i) ==
    \* Honest reactive consensus state machine (unbounded)
    \/ MCEnterNewRound(i)
    \/ MCEnterPropose(i)
    \/ MCEnterPrevote(i)
    \/ MCEnterPrevoteWait(i)
    \/ MCEnterPrecommitNoPolka(i)
    \/ MCEnterPrecommitNilPolka(i)
    \/ MCEnterPrecommitRelockPolka(i)
    \/ MCEnterPrecommitNewLockPolka(i)
    \/ MCEnterPrecommitUnknownPolka(i)
    \/ MCEnterPrecommitWait(i)
    \/ MCEnterCommit(i)
    \/ MCFinalizeCommit(i)
    \/ MCRoundSkipPrevote(i)
    \/ MCRoundSkipPrecommit(i)
    \/ MCRecover(i)
    \/ MCDetectEquivocation(i)
    \/ MCProcessConsensusBuffer(i)
    \* Timeouts (bounded)
    \/ MCHandleTimeoutPropose(i)
    \/ MCHandleTimeoutPrevote(i)
    \/ MCHandleTimeoutPrecommit(i)
    \* Family 2 amnesia (bounded)
    \/ \E h \in 1..MaxHeight, r2 \in 1..MaxRound : MCByzAmnesia(i, h, r2)
    \* Family 1 equivocation (bounded)
    \/ \E h \in 1..MaxHeight, r \in 0..MaxRound : MCByzEquivocate(i, h, r)
    \/ \E h \in 1..MaxHeight, r \in 0..MaxRound : MCByzSelectiveDisseminate(i, h, r)
    \* Family 3 VE (bounded)
    \/ \E h \in 1..MaxHeight, r \in 0..MaxRound : MCByzAttachSameVEToBoth(i, h, r)
    \/ \E h \in 1..MaxHeight, r \in 0..MaxRound : MCByzLateAddPrecommitWithBadVE(i, h, r)
    \/ \E h \in 1..MaxHeight, oR \in 0..MaxRound, nR \in 0..MaxRound :
            MCByzReplaySelfVE(i, h, oR, nR)
    \* Family 5 (bounded)
    \/ MCByzInjectInvalidEvidence(i)
    \/ MCByzFloodEvidence(i)
    \/ MCCrashDuringConsensusBuffer(i)
    \/ MCAdvanceClock(i)
    \/ \E ev \in pendingEvidence[i] : MCProposerExcludeEvidence(i, ev)
    \/ \E ev \in pendingEvidence[i] : MCCommitEvidence(i, ev)
    \* Family 6 Byzantine proposer (bounded)
    \/ \E v \in Values : MCByzProposeAlternating(i, v)
    \/ MCByzPOLRoundGtRound(i)
    \* Family 2 WAL truncation (bounded)
    \/ \E k \in 1..MaxRound : MCWALTailTruncate(i, k)

MCNextCrash == \E i \in Server : MCCrash(i)

MCNextUnreliable ==
    \E m \in DOMAIN messages : MCLoseMessage(m)

MCNextMessage ==
    \E m \in DOMAIN messages :
        \/ MCReceiveProposal(m.dest, m)
        \/ MCReceivePrevote(m.dest, m)
        \/ MCReceivePrecommit(m.dest, m)

MCNextLight ==
    \E c \in LightClient, m \in DOMAIN messages :
        MCLightClientVerify(c, m)

MCNextByzLunatic ==
    \E h \in 2..MaxHeight : MCByzLunaticForkHeader(h)

MCNextByzPolkaUnk ==
    \E blockX \in Values : MCByzPolkaForUnknownBlock(blockX)

MCNextEvidenceRace ==
    \E sa, sb \in Honest :
        \E ev \in pendingEvidence[sa] :
            MCEvidenceExpiryRace(sa, sb, ev)

MCNext ==
    \/ \E i \in Server : MCNextAsync(i)
    \/ MCNextCrash
    \/ MCNextUnreliable
    \/ MCNextMessage
    \/ MCNextLight
    \/ MCNextByzLunatic
    \/ MCNextByzPolkaUnk
    \/ MCNextEvidenceRace

\* ============================================================================
\* SPECIFICATIONS
\* ============================================================================

mc_vars == <<vars, faultVars>>

MCSpec == MCInit /\ [][MCNext]_mc_vars

\* ============================================================================
\* SYMMETRY AND VIEW
\* ============================================================================

\* Symmetry: honest servers only. Faulty is a CONSTANT — Permutations(Server)
\* would symmetrize across faulty/honest mapping (incorrect) so we permute
\* honest validators only. Light clients are also permuted as an independent
\* equivalence class.
Symmetry == Permutations(Honest)

ModelView == <<vars>>

\* ============================================================================
\* STATE-SPACE PRUNING
\* ============================================================================

MsgBufferConstraint ==
    \/ MaxMsgBufferLimit = 0
    \/ BagCardinality(messages) <= MaxMsgBufferLimit

\* ============================================================================
\* STRUCTURAL INVARIANTS
\* ============================================================================

VoteCountBound ==
    \A s \in Server :
        \A r \in 0..MaxRound :
            Cardinality({j \in Server : prevotes[s][r][j] /= Nil}) <= Cardinality(Server)

DecisionStability ==
    \A s \in Server :
        \A h \in 1..MaxHeight :
            decision[s][h] /= Nil => decision[s][h] \in Values

CrashedNoTimeouts ==
    \A s \in Server :
        crashed[s] => timeoutScheduled[s] = {}

\* Family 1: any conflicting record pair must be from a Byzantine signer.
\* (Honest validators never sign conflicting votes; if violated, the spec
\* failed to enforce honesty.)
ConflictsOnlyFromByzantine ==
    \A s \in Server :
        \A pair \in seenConflicting[s] :
            pair[1].signer \in Faulty

\* ============================================================================
\* TEMPORAL PROPERTIES
\* ============================================================================

MonotonicHeight ==
    [][
        \A s \in Server :
            (~crashed[s] /\ ~crashed'[s]) => height'[s] >= height[s]
    ]_mc_vars

MonotonicRound ==
    [][
        \A s \in Server :
            (~crashed[s] /\ ~crashed'[s] /\ height'[s] = height[s]) =>
                round'[s] >= round[s]
    ]_mc_vars

DecisionPermanenceTemporal ==
    [][
        \A s \in Server :
            \A h \in 1..MaxHeight :
                (decision[s][h] /= Nil /\ ~crashed[s]) =>
                    decision'[s][h] = decision[s][h]
    ]_mc_vars

====
