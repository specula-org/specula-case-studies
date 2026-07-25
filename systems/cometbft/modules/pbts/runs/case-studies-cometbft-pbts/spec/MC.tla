--------------------------- MODULE MC ---------------------------
(*
 * Model checking spec for the CometBFT PBTS + ABCI++ proposer + state-sync surface.
 *
 * Wraps base.tla's actions with counter-bounded fault wrappers so TLC explores
 * an exhaustive but tractable state space. The bug families being hunted
 * (per the modeling brief) are:
 *
 *   F1: PBTS POLRound-bypass — Byzantine timestamp drift via ValidBlock reproposal
 *   F2: Clock-jump halt      — block.Time monotonicity vs wallClock liveness
 *   F3: Straggler VEs        — proposer-side commit-info app-verification gap
 *   F4: PP-reject livelock   — proposer-self ProcessProposal rejection
 *   F5: State-sync trust gap — RPC + p2p collusion defeating verifyApp
 *)

EXTENDS base, TLC, FiniteSets

\* ============================================================================
\* Family-specific app scenarios (overrides AppAcceptsPP / AppAcceptsVE per cfg)
\* ============================================================================
\* base.tla defines the "all-accept" defaults (AppAcceptsPPAll, AppAcceptsVEAll).
\* These are the family-specific scenarios used by F3 and F4 hunt cfgs.

\* App rejects every extension. Used by F3 to surface the bug: late-precommit
\* extensions skip the app check, so they enter lastCommitVotes even though
\* AppAcceptsVE(ext) = FALSE.
AppAcceptsPPF3 ==
    [h \in 1..MaxHeight, r \in 0..MaxRound, v \in Servers, b \in Blocks |-> TRUE]

AppAcceptsVEF3 ==
    [e \in Extensions |-> FALSE]

\* App rejects ProcessProposal from proposer "s4" (the Byzantine validator in
\* our cfgs). Used by F4 to quantify rounds-to-decide under app rejection.
AppAcceptsPPF4 ==
    [h \in 1..MaxHeight, r \in 0..MaxRound, v \in Servers, b \in Blocks |-> v /= "s4"]

AppAcceptsVEF4 ==
    [e \in Extensions |-> TRUE]

\* ============================================================================
\* Counter bounds (tuned per the modeling brief — see brief-coverage.md)
\* ============================================================================
CONSTANTS
    ProposeNewBlockLimit,    \* F1 — new round-0 proposals (Byzantine pick window)
    ProposeValidBlockLimit,  \* F1 — F9 reproposals
    AdvanceRoundLimit,       \* F1, F2, F4 — round progression
    DeliverLatePrecommitLimit, \* F3 — late-commit straggler additions
    DeliverInRoundLimit,     \* F3 - in-round precommit deliveries (must not be too small)
    AppRejectLimit,          \* F4 — counter for app rejections actually consumed
    SyncFetchAppHashLimit,   \* F5
    SyncChunkLimit,          \* F5 — chunks consumed
    TickValidatorLimit,      \* F1, F2 — wall-clock advances
    TickRealTimeLimit        \* F2 — real-time advances

\* ============================================================================
\* Counter state
\* ============================================================================

VARIABLE faultCounters

mcVars == <<vars, faultCounters>>

CountersInit ==
    faultCounters = [
        proposeNewBlock      |-> 0,
        proposeValidBlock    |-> 0,
        advanceRound         |-> 0,
        deliverLatePrecommit |-> 0,
        deliverInRound       |-> 0,
        appReject            |-> 0,
        syncFetchAppHash     |-> 0,
        syncChunk            |-> 0,
        tickValidator        |-> 0,
        tickRealTime         |-> 0
    ]

Inc(field) ==
    [faultCounters EXCEPT ![field] = @ + 1]

\* ============================================================================
\* Counter-bounded wrappers
\* ============================================================================

MCProposeNewBlock(v, b, ts) ==
    /\ faultCounters.proposeNewBlock < ProposeNewBlockLimit
    /\ ProposeNewBlock(v, b, ts)
    /\ faultCounters' = Inc("proposeNewBlock")

MCProposeValidBlock(v) ==
    /\ faultCounters.proposeValidBlock < ProposeValidBlockLimit
    /\ ProposeValidBlock(v)
    /\ faultCounters' = Inc("proposeValidBlock")

MCAdvanceRound(v) ==
    /\ faultCounters.advanceRound < AdvanceRoundLimit
    /\ AdvanceRound(v)
    /\ faultCounters' = Inc("advanceRound")

MCProposerSkipsRound(v) ==
    /\ faultCounters.advanceRound < AdvanceRoundLimit
    /\ ProposerSkipsRound(v)
    /\ faultCounters' = Inc("advanceRound")

MCDeliverLatePrecommit(v, vote) ==
    /\ faultCounters.deliverLatePrecommit < DeliverLatePrecommitLimit
    /\ DeliverLatePrecommit(v, vote)
    /\ faultCounters' = Inc("deliverLatePrecommit")

MCDeliverInRoundPrecommit(v, vote) ==
    /\ faultCounters.deliverInRound < DeliverInRoundLimit
    /\ DeliverInRoundPrecommit(v, vote)
    /\ faultCounters' = Inc("deliverInRound")

MCProposerSelfReject(v, pr) ==
    /\ faultCounters.appReject < AppRejectLimit
    /\ ProposerSelfReject(v, pr)
    /\ faultCounters' = Inc("appReject")

MCSyncFetchAppHash(v, ah) ==
    /\ faultCounters.syncFetchAppHash < SyncFetchAppHashLimit
    /\ SyncFetchAppHash(v, ah)
    /\ faultCounters' = Inc("syncFetchAppHash")

MCSyncReceiveChunk(v, c) ==
    /\ faultCounters.syncChunk < SyncChunkLimit
    /\ SyncReceiveChunk(v, c)
    /\ faultCounters' = Inc("syncChunk")

MCTickValidator(v) ==
    /\ faultCounters.tickValidator < TickValidatorLimit
    /\ TickValidator(v)
    /\ faultCounters' = Inc("tickValidator")

MCTickRealTime ==
    /\ faultCounters.tickRealTime < TickRealTimeLimit
    /\ TickRealTime
    /\ faultCounters' = Inc("tickRealTime")

\* ============================================================================
\* Reactive (unbounded) wrappers — pass through, only counter touched
\* ============================================================================

MCDeliverProposal(v, pr) ==
    /\ DeliverProposal(v, pr)
    /\ UNCHANGED faultCounters

MCAcceptProposalPOLNew(v, pr) ==
    /\ AcceptProposalPOLNew(v, pr)
    /\ UNCHANGED faultCounters

MCAcceptProposalPOLOld(v, pr) ==
    /\ AcceptProposalPOLOld(v, pr)
    /\ UNCHANGED faultCounters

MCPolkaArmsValidBlock(v, pr) ==
    /\ PolkaArmsValidBlock(v, pr)
    /\ UNCHANGED faultCounters

MCDecideBlock(h, pr) ==
    /\ DecideBlock(h, pr)
    /\ UNCHANGED faultCounters

MCRecordHonestAppHash(ah) ==
    /\ RecordHonestAppHash(ah)
    /\ UNCHANGED faultCounters

MCSyncAppComputes(v, ah) ==
    /\ SyncAppComputes(v, ah)
    /\ UNCHANGED faultCounters

MCSyncVerifyApp(v) ==
    /\ SyncVerifyApp(v)
    /\ UNCHANGED faultCounters

\* ============================================================================
\* Init / Next
\* ============================================================================

MCInit ==
    /\ Init
    /\ CountersInit

MCNext ==
    \/ \E v \in Servers : MCTickValidator(v)
    \/ MCTickRealTime
    \/ \E v \in Servers, b \in Blocks, ts \in Times : MCProposeNewBlock(v, b, ts)
    \/ \E v \in Servers : MCProposeValidBlock(v)
    \/ \E v \in Servers, pr \in proposalMsg : MCDeliverProposal(v, pr)
    \/ \E v \in Servers, pr \in proposalMsg : MCAcceptProposalPOLNew(v, pr)
    \/ \E v \in Servers, pr \in proposalMsg : MCAcceptProposalPOLOld(v, pr)
    \/ \E v \in Servers, pr \in proposalMsg : MCPolkaArmsValidBlock(v, pr)
    \/ \E v \in Servers : MCAdvanceRound(v)
    \/ \E v \in Servers, pr \in proposalMsg : MCProposerSelfReject(v, pr)
    \/ \E h \in Heights, pr \in proposalMsg : MCDecideBlock(h, pr)
    \/ \E v \in Servers : MCProposerSkipsRound(v)
    \/ \E v \in Servers, b \in Blocks, ext \in (Extensions \cup {NoExtension}),
         voter \in Servers, r \in Rounds :
         MCDeliverInRoundPrecommit(v, PrecommitRec(voter, chainHeight, r, b, ext))
    \/ \E v \in Servers, b \in Blocks, ext \in (Extensions \cup {NoExtension}),
         voter \in Servers, r \in Rounds :
         MCDeliverLatePrecommit(v, PrecommitRec(voter, chainHeight - 1, r, b, ext))
    \/ \E ah \in AppHashes : MCRecordHonestAppHash(ah)
    \/ \E v \in Servers, ah \in AppHashes : MCSyncFetchAppHash(v, ah)
    \/ \E v \in Servers, c \in ChunkValues : MCSyncReceiveChunk(v, c)
    \/ \E v \in Servers, ah \in AppHashes : MCSyncAppComputes(v, ah)
    \/ \E v \in Servers : MCSyncVerifyApp(v)

MCSpec == MCInit /\ [][MCNext]_mcVars

\* ============================================================================
\* State-space constraints
\* ============================================================================

\* Bound message bag growth.
MCMsgConstraint ==
    Cardinality(proposalMsg) <= 6

\* Bound time by counter limits — prevents the clock from running away while
\* the rest of the system is bounded.
MCTimeConstraint ==
    /\ realTime <= MaxTime
    /\ \A v \in Servers : wallClock[v] <= MaxTime

\* Bound lastCommitVotes growth (Family 3 — straggler set must stay small).
MCLastCommitConstraint ==
    \A v \in Servers : Cardinality(lastCommitVotes[v]) <= 6

MCStateConstraint ==
    /\ MCMsgConstraint
    /\ MCTimeConstraint
    /\ MCLastCommitConstraint

\* ============================================================================
\* Symmetry
\* ============================================================================

\* Symmetric across honest validators only. Faulty is a fixed set.
MCSymmetry == Permutations(Servers \ Faulty) \cup Permutations(Identities \ MaliciousIdentities)

\* ============================================================================
\* Structural invariants (always-checked)
\* ============================================================================

MCTypeOK ==
    /\ TypeOK
    /\ faultCounters \in [
         proposeNewBlock: 0..ProposeNewBlockLimit,
         proposeValidBlock: 0..ProposeValidBlockLimit,
         advanceRound: 0..AdvanceRoundLimit,
         deliverLatePrecommit: 0..DeliverLatePrecommitLimit,
         deliverInRound: 0..DeliverInRoundLimit,
         appReject: 0..AppRejectLimit,
         syncFetchAppHash: 0..SyncFetchAppHashLimit,
         syncChunk: 0..SyncChunkLimit,
         tickValidator: 0..TickValidatorLimit,
         tickRealTime: 0..TickRealTimeLimit
       ]

MCValidBlockRoundConsistency == ValidBlockRoundConsistency
MCDecidedTimestampInRange == DecidedTimestampInRange
MCMonotonicHeaderTime == MonotonicHeaderTime

\* ============================================================================
\* Bug-family invariants (overlaid by hunt cfgs)
\* ============================================================================

MCTimestampBoundedByCommitTime == TimestampBoundedByCommitTime  \* F1
MCBoundedHaltGap == BoundedHaltGap                              \* F2
MCExtensionVerifyCoverage == ExtensionVerifyCoverage            \* F3
MCLocalLastCommitConsistency == LocalLastCommitConsistency     \* F3
MCStateSyncSoundness == StateSyncSoundness                      \* F5

===============================================================================
