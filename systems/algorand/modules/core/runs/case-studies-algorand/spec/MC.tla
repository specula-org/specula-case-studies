--------------------------- MODULE MC ---------------------------
(*
 * Model checking specification for Algorand BA*.
 *
 * Wraps the base spec with counter-bounded fault-injection actions:
 *   - ByzantineVote   (BFT adversary)
 *   - CatchupInstall  (Family 1)
 *   - Crash           (Family 6)
 *   - LoseMessage     (network)
 *   - ForkCommitteeView (Family 5)
 *   - FastTimeoutPrimer (Family 2 fast-recovery)
 *
 * Reactive / deterministic actions pass through unbounded:
 *   IssueSoftVote, IssueCertVote, IssueNextVote, IssueFastVote,
 *   PersistState, BroadcastVote, ReceiveVote, ReceiveBundle, ReceiveProposal,
 *   ProposeBlock, PartitionPolicyRebroadcast, EnterPeriod*, EnterRound,
 *   HandleSoftThresholdSamePeriod, HandleCertThresholdLocal,
 *   UpdateNextThresholdCache, UpdateFreshest, UpdateStaging,
 *   UpdatePinnedLowest, CalculateFilterTimeoutShort/Default,
 *   RecordCredentialArrival, Recover.
 *)

EXTENDS base

algorand == INSTANCE base

\* ============================================================================
\* CONSTRAINT CONSTANTS
\* ============================================================================

CONSTANT MaxByzVoteLimit       \* Max Byzantine votes injected
CONSTANT MaxCatchupLimit       \* Max external catchup installs (Family 1)
CONSTANT MaxCrashLimit         \* Max crashes (Family 6)
CONSTANT MaxLoseLimit          \* Max message losses
CONSTANT MaxForkViewLimit      \* Max committeeView forks (Family 5)
CONSTANT MaxFastPrimerLimit    \* Max fast-recovery primer fires
CONSTANT MaxMsgBufferLimit     \* Max messages in flight at once

\* ============================================================================
\* CONSTRAINT VARIABLES
\* ============================================================================

VARIABLE faultCounters
faultVars == <<faultCounters>>

\* ============================================================================
\* COUNTER-BOUNDED FAULT-INJECTION ACTIONS
\* ============================================================================

MCByzantineVote ==
    /\ faultCounters.byz < MaxByzVoteLimit
    /\ \E b \in ByzServer, r \in 0..MaxRound, p \in 0..MaxPeriod,
        st \in {StepSoft, StepCert, StepNext},
        v \in Values \cup {Bottom}, origP \in 0..MaxPeriod :
        algorand!ByzantineVote(b, r, p, st, v, origP)
    /\ faultCounters' = [faultCounters EXCEPT !.byz = @ + 1]

MCCatchupInstall ==
    /\ faultCounters.catchup < MaxCatchupLimit
    /\ \E r \in 0..MaxRound, v \in Values :
        algorand!CatchupInstall(r, v)
    /\ faultCounters' = [faultCounters EXCEPT !.catchup = @ + 1]

MCCrash(i) ==
    /\ faultCounters.crash < MaxCrashLimit
    /\ algorand!Crash(i)
    /\ faultCounters' = [faultCounters EXCEPT !.crash = @ + 1]

MCLoseMessage(m) ==
    /\ faultCounters.lose < MaxLoseLimit
    /\ algorand!LoseMessage(m)
    /\ faultCounters' = [faultCounters EXCEPT !.lose = @ + 1]

MCForkCommitteeView ==
    /\ faultCounters.fork < MaxForkViewLimit
    /\ \E i \in Server, r \in 0..MaxRound, p \in 0..MaxPeriod,
        st \in {StepSoft, StepCert, StepNext}, newCmt \in SUBSET Server :
        algorand!ForkCommitteeView(i, r, p, st, newCmt)
    /\ faultCounters' = [faultCounters EXCEPT !.fork = @ + 1]

MCHandleFastTimeoutPrimer(i) ==
    /\ faultCounters.fastprim < MaxFastPrimerLimit
    /\ algorand!HandleFastTimeoutPrimer(i)
    /\ faultCounters' = [faultCounters EXCEPT !.fastprim = @ + 1]

\* ============================================================================
\* UNBOUNDED REACTIVE ACTIONS
\* ============================================================================

MCIssueSoftVote(i) ==
    /\ algorand!IssueSoftVote(i)
    /\ UNCHANGED faultVars

MCIssueCertVote(i) ==
    /\ algorand!IssueCertVote(i)
    /\ UNCHANGED faultVars

MCIssueNextVote(i) ==
    /\ algorand!IssueNextVote(i)
    /\ UNCHANGED faultVars

MCIssueFastVote(i) ==
    /\ algorand!IssueFastVote(i)
    /\ UNCHANGED faultVars

MCPersistState(i) ==
    /\ algorand!PersistState(i)
    /\ UNCHANGED faultVars

MCBroadcastVote(i) ==
    /\ algorand!BroadcastVote(i)
    /\ UNCHANGED faultVars

MCProposeBlock(i) ==
    /\ algorand!ProposeBlock(i)
    /\ UNCHANGED faultVars

MCPartitionPolicyRebroadcast(i) ==
    /\ algorand!PartitionPolicyRebroadcast(i)
    /\ UNCHANGED faultVars

MCRecover(i) ==
    /\ algorand!Recover(i)
    /\ UNCHANGED faultVars

MCCalculateFilterTimeoutShort(i) ==
    /\ algorand!CalculateFilterTimeoutShort(i)
    /\ UNCHANGED faultVars

MCCalculateFilterTimeoutDefault(i) ==
    /\ algorand!CalculateFilterTimeoutDefault(i)
    /\ UNCHANGED faultVars

MCRecordCredentialArrival(i) ==
    /\ algorand!RecordCredentialArrival(i)
    /\ UNCHANGED faultVars

MCUpdateNextThresholdCache(i, p, v) ==
    /\ algorand!UpdateNextThresholdCache(i, round[i], p, v)
    /\ UNCHANGED faultVars

MCUpdateFreshest(i, et, ep, ev) ==
    /\ algorand!UpdateFreshest(i, round[i], et, ep, ev)
    /\ UNCHANGED faultVars

MCUpdateStaging(i, p, v) ==
    /\ algorand!UpdateStaging(i, round[i], p, v)
    /\ UNCHANGED faultVars

MCHandleSoftThresholdSamePeriod(i, p, v) ==
    /\ algorand!HandleSoftThresholdSamePeriod(i, p, v)
    /\ UNCHANGED faultVars

MCHandleCertThresholdLocal(i, p, v) ==
    /\ algorand!HandleCertThresholdLocal(i, p, v)
    /\ UNCHANGED faultVars

MCEnterPeriodViaNextThreshold(i, target, v) ==
    /\ algorand!EnterPeriodViaNextThreshold(i, target, v)
    /\ UNCHANGED faultVars

MCEnterPeriodViaSoftThreshold(i, target, v) ==
    /\ algorand!EnterPeriodViaSoftThreshold(i, target, v)
    /\ UNCHANGED faultVars

MCEnterRound(i, target) ==
    /\ algorand!EnterRound(i, target)
    /\ UNCHANGED faultVars

MCReceiveVote(m) ==
    /\ m.mtype = VoteMsg
    /\ algorand!ReceiveVote(m.vote.sender, m)
    /\ UNCHANGED faultVars

MCReceiveBundle(m) ==
    /\ m.mtype = BundleMsg
    /\ algorand!ReceiveBundle(m.broadcaster, m)
    /\ UNCHANGED faultVars

MCReceiveProposal(i, m) ==
    /\ m.mtype = ProposalMsg
    /\ algorand!ReceiveProposal(i, m)
    /\ UNCHANGED faultVars

\* ============================================================================
\* INITIALIZATION
\* ============================================================================

MCInit ==
    /\ Init
    /\ faultCounters = [
        byz      |-> 0,
        catchup  |-> 0,
        crash    |-> 0,
        lose     |-> 0,
        fork     |-> 0,
        fastprim |-> 0]

\* ============================================================================
\* NEXT
\* ============================================================================

MCNextPerServer(i) ==
    \/ MCIssueSoftVote(i)
    \/ MCIssueCertVote(i)
    \/ MCIssueNextVote(i)
    \/ MCIssueFastVote(i)
    \/ MCPersistState(i)
    \/ MCBroadcastVote(i)
    \/ MCProposeBlock(i)
    \/ MCPartitionPolicyRebroadcast(i)
    \/ MCRecover(i)
    \/ MCCalculateFilterTimeoutShort(i)
    \/ MCCalculateFilterTimeoutDefault(i)
    \/ MCRecordCredentialArrival(i)
    \/ MCCrash(i)
    \/ MCHandleFastTimeoutPrimer(i)

MCNextCache ==
    \/ \E i \in Server, p \in 0..MaxPeriod, v \in Values \cup {Bottom} :
        MCUpdateNextThresholdCache(i, p, v)
    \/ \E i \in Server, et \in {SoftThresholdT, CertThresholdT, NextThresholdT},
         ep \in 0..MaxPeriod, ev \in Values \cup {Bottom} :
        MCUpdateFreshest(i, et, ep, ev)
    \/ \E i \in Server, p \in 0..MaxPeriod, v \in Values :
        MCUpdateStaging(i, p, v)

MCNextThresholds ==
    \/ \E i \in Server, p \in 0..MaxPeriod, v \in Values :
        MCHandleSoftThresholdSamePeriod(i, p, v)
    \/ \E i \in Server, p \in 0..MaxPeriod, v \in Values :
        MCHandleCertThresholdLocal(i, p, v)

MCNextTransitions ==
    \/ \E i \in Server, target \in 1..MaxPeriod, v \in Values \cup {Bottom} :
        MCEnterPeriodViaNextThreshold(i, target, v)
    \/ \E i \in Server, target \in 1..MaxPeriod, v \in Values :
        MCEnterPeriodViaSoftThreshold(i, target, v)
    \/ \E i \in Server, target \in 1..MaxRound :
        MCEnterRound(i, target)

MCNextMessages ==
    \E m \in DOMAIN messages :
        \/ MCReceiveVote(m)
        \/ MCReceiveBundle(m)
        \/ MCLoseMessage(m)
        \/ \E i \in Server : MCReceiveProposal(i, m)

MCNextFaults ==
    \/ MCByzantineVote
    \/ MCCatchupInstall
    \/ MCForkCommitteeView

MCNext ==
    \/ \E i \in Server : MCNextPerServer(i)
    \/ MCNextCache
    \/ MCNextThresholds
    \/ MCNextTransitions
    \/ MCNextMessages
    \/ MCNextFaults

\* ============================================================================
\* SPEC
\* ============================================================================

mc_vars == <<vars, faultVars>>

MCSpec == MCInit /\ [][MCNext]_mc_vars

\* ============================================================================
\* SYMMETRY AND VIEW
\* ============================================================================

\* Honest servers are interchangeable; Byzantine set is treated as a fixed
\* "tail" so we only permute the honest prefix.
Symmetry == Permutations(Server \ ByzServer) \cup Permutations(ByzServer)

\* Hide fault counters from view to avoid them inflating the state graph.
ModelView == vars

\* ============================================================================
\* STATE SPACE PRUNING
\* ============================================================================

MsgBufferConstraint ==
    \/ MaxMsgBufferLimit = 0
    \/ BagCardinality(messages) <= MaxMsgBufferLimit

\* ============================================================================
\* MC-LEVEL STRUCTURAL INVARIANTS
\* ============================================================================

\* MCTypeOK: variables stay within declared domains
MCTypeOK ==
    /\ \A i \in Server :
        /\ round[i] \in 0..MaxRound
        /\ period[i] \in 0..MaxPeriod
        /\ persistedRound[i] \in 0..MaxRound
        /\ persistedPeriod[i] \in 0..MaxPeriod
    /\ \A r \in 0..MaxRound :
        ledgerCertified[r] \in (Values \cup {Bottom, Nil})

\* InFlightOnlyOwn: a server's inFlight only contains votes it itself signed.
InFlightOnlyOwn ==
    \A i \in Server :
        \A vt \in inFlight[i] :
            vt.sender = i

\* CommitteeViewCoincidesWithOracleWhenNoFork: forks only show up when
\* committeeView differs from oracle — sanity check.
CommitteeViewCoincidesInit ==
    \A i \in Server, r \in 0..MaxRound, p \in 0..MaxPeriod,
       s \in {StepPropose, StepSoft, StepCert, StepNext,
              StepLate, StepRedo, StepDown} :
        faultCounters.fork = 0 => committeeView[i][r][p][s] = committee[r][p][s]

\* No honest server signs a vote at a step where it's not in the committee.
HonestVoteInCommittee ==
    \A i \in Server :
        \A vt \in inFlight[i] :
            IsHonest(i) => i \in committeeView[i][vt.round][vt.period][vt.step]

\* ============================================================================
\* TEMPORAL PROPERTIES
\* ============================================================================

\* Decisions are monotone: once decided, the decision doesn't change.
DecisionMonotone ==
    [][
        \A i \in Server, r \in 0..MaxRound :
            decision[i][r] /= Nil => decision'[i][r] = decision[i][r]
    ]_mc_vars

\* Ledger entries are stable once set (modulo Nil -> v transition).
LedgerStable ==
    [][
        \A r \in 0..MaxRound :
            ledgerCertified[r] /= Nil =>
                ledgerCertified'[r] = ledgerCertified[r]
    ]_mc_vars

\* Round monotonicity per honest server.
RoundMonotone ==
    [][
        \A i \in Server :
            (IsHonest(i) /\ ~crashed[i] /\ ~crashed'[i])
            => round'[i] >= round[i]
    ]_mc_vars

\* Persisted state stays in sync (never drops).
PersistedMonotone ==
    [][
        \A i \in Server :
            (~crashed[i] /\ ~crashed'[i]) =>
                \/ persistedRound'[i] > persistedRound[i]
                \/ /\ persistedRound'[i] = persistedRound[i]
                   /\ persistedPeriod'[i] >= persistedPeriod[i]
    ]_mc_vars

====
