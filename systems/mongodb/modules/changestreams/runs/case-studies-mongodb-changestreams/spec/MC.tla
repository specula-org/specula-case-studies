------------------------------- MODULE MC -------------------------------
(*
 * Model checking wrapper for MongoDB Change Streams base spec.
 * Counter-bounds fault-injection and non-deterministic actions.
 * Leaves reactive/deterministic actions unconstrained.
 *
 * Bug Families:
 *   1 — Resume Token Ordering & Version Transition
 *   2 — Invalidation Event Sequencing
 *   3 — Cross-Shard Event Merging & Topology Change
 *   5 — Transaction Unwinding & Event Atomicity
 *)

EXTENDS base

\* ============================================================================
\* COUNTER-BOUNDED CONSTANTS
\* ============================================================================

\* --- Fault injection / non-deterministic action limits ---
CONSTANT MaxEvents          \* Max events generated per shard
CONSTANT MaxClockAdvance    \* Max clock advances per shard
CONSTANT MaxVersionSwitch   \* Max v1->v2 transitions per shard
CONSTANT MaxInvalidations   \* Max invalidation events total
CONSTANT MaxTopoChanges     \* Max topology changes (add/remove shard)
CONSTANT MaxTransactions    \* Max transactions per shard
CONSTANT MaxResumes         \* Max resume operations
CONSTANT MaxRecreates       \* Max collection recreations

\* ============================================================================
\* COUNTER VARIABLES
\* ============================================================================

VARIABLE counters
\* counters is a record:
\*   [events: [Shard -> Nat],
\*    clockAdv: [Shard -> Nat],
\*    versionSwitch: [Shard -> Nat],
\*    invalidations: Nat,
\*    topoChanges: Nat,
\*    transactions: [Shard -> Nat],
\*    resumes: Nat,
\*    recreates: Nat]

mcVars == <<vars, counters>>

\* ============================================================================
\* INIT
\* ============================================================================

MCInit ==
    /\ Init
    /\ counters = [
        events |-> [s \in Shard |-> 0],
        clockAdv |-> [s \in Shard |-> 0],
        versionSwitch |-> [s \in Shard |-> 0],
        invalidations |-> 0,
        topoChanges |-> 0,
        transactions |-> [s \in Shard |-> 0],
        resumes |-> 0,
        recreates |-> 0
       ]

\* ============================================================================
\* COUNTER-BOUNDED WRAPPERS (non-deterministic / fault-injection actions)
\* ============================================================================

\* --- Per-shard event generation (bounded) ---
MCGenerateEvent(s, op) ==
    /\ counters.events[s] < MaxEvents
    /\ GenerateEvent(s, op)
    /\ counters' = [counters EXCEPT !.events[s] = @ + 1]

\* --- Clock advance (bounded) ---
MCAdvanceShardClock(s) ==
    /\ counters.clockAdv[s] < MaxClockAdvance
    /\ AdvanceShardClock(s)
    /\ counters' = [counters EXCEPT !.clockAdv[s] = @ + 1]

\* --- Version switch (bounded, fault injection for Family 1) ---
MCSwitchTokenVersion(s) ==
    /\ counters.versionSwitch[s] < MaxVersionSwitch
    /\ SwitchTokenVersion(s)
    /\ counters' = [counters EXCEPT !.versionSwitch[s] = @ + 1]

\* --- Invalidation generation (bounded, fault injection for Family 2) ---
MCGenerateInvalidatingEvent(s, op) ==
    /\ counters.invalidations < MaxInvalidations
    /\ GenerateInvalidatingEvent(s, op)
    /\ counters' = [counters EXCEPT !.invalidations = @ + 1]

\* --- Collection recreation (bounded, enables drop-recreate-drop for MC-2) ---
MCRecreateCollection ==
    /\ counters.recreates < MaxRecreates
    /\ RecreateCollection
    /\ counters' = [counters EXCEPT !.recreates = @ + 1]

\* --- Topology changes (bounded, fault injection for Family 3) ---
MCAddShard(s) ==
    /\ counters.topoChanges < MaxTopoChanges
    /\ AddShard(s)
    /\ counters' = [counters EXCEPT !.topoChanges = @ + 1]

MCRemoveShard(s) ==
    /\ counters.topoChanges < MaxTopoChanges
    /\ RemoveShard(s)
    /\ counters' = [counters EXCEPT !.topoChanges = @ + 1]

\* --- Transaction start (bounded) ---
MCBeginTransaction(s) ==
    /\ counters.transactions[s] < MaxTransactions
    /\ BeginTransaction(s)
    /\ counters' = [counters EXCEPT !.transactions[s] = @ + 1]

\* --- Resume (bounded) ---
MCInitiateResume ==
    /\ counters.resumes < MaxResumes
    /\ InitiateResume
    /\ counters' = [counters EXCEPT !.resumes = @ + 1]

MCInitiateResumeAfterInvalidate ==
    /\ counters.resumes < MaxResumes
    /\ InitiateResumeAfterInvalidate
    /\ counters' = [counters EXCEPT !.resumes = @ + 1]

\* ============================================================================
\* UNCONSTRAINED WRAPPERS (reactive/deterministic actions)
\* ============================================================================

\* These actions react to existing state and should NOT be bounded.

MCMergeNextNormal ==
    /\ MergeNextNormal
    /\ UNCHANGED counters

MCMergeNextDegraded ==
    /\ MergeNextDegraded
    /\ UNCHANGED counters

MCMergeNextInvalidating ==
    /\ MergeNextInvalidating
    /\ UNCHANGED counters

MCDeliverInvalidation ==
    /\ DeliverInvalidation
    /\ UNCHANGED counters

MCUndoGetNextAtSegmentBoundary ==
    /\ UndoGetNextAtSegmentBoundary
    /\ UNCHANGED counters

MCStartNewSegment ==
    /\ StartNewSegment
    /\ UNCHANGED counters

MCAddTxnOperation(s, op) ==
    /\ AddTxnOperation(s, op)
    /\ UNCHANGED counters

MCCommitTransaction(s) ==
    /\ CommitTransaction(s)
    /\ UNCHANGED counters

MCResetTxnState(s) ==
    /\ ResetTxnState(s)
    /\ UNCHANGED counters

\* ============================================================================
\* MC NEXT
\* ============================================================================

MCNext ==
    \* --- Bounded actions (non-deterministic / fault injection) ---
    \/ \E s \in Shard : \E op \in {InsertOp, UpdateOp, DeleteOp} :
        MCGenerateEvent(s, op)
    \/ \E s \in Shard : MCAdvanceShardClock(s)
    \/ \E s \in Shard : MCSwitchTokenVersion(s)
    \/ \E s \in Shard : \E op \in {DropOp, RenameOp} :
        MCGenerateInvalidatingEvent(s, op)
    \/ MCRecreateCollection
    \/ \E s \in Shard : MCAddShard(s)
    \/ \E s \in Shard : MCRemoveShard(s)
    \/ \E s \in Shard : MCBeginTransaction(s)
    \/ MCInitiateResume
    \/ MCInitiateResumeAfterInvalidate
    \* --- Unbounded actions (reactive / deterministic) ---
    \/ MCMergeNextNormal
    \/ MCMergeNextDegraded
    \/ MCMergeNextInvalidating
    \/ MCDeliverInvalidation
    \/ MCUndoGetNextAtSegmentBoundary
    \/ MCStartNewSegment
    \/ \E s \in Shard : \E op \in {InsertOp, UpdateOp, DeleteOp} :
        MCAddTxnOperation(s, op)
    \/ \E s \in Shard : MCCommitTransaction(s)
    \/ \E s \in Shard : MCResetTxnState(s)

MCSpec == MCInit /\ [][MCNext]_mcVars

\* ============================================================================
\* SYMMETRY
\* ============================================================================

\* Shard symmetry: all shards are interchangeable
ModelSymmetry == Permutations(Shard)

\* ============================================================================
\* STATE SPACE CONSTRAINT
\* ============================================================================

\* Limit total delivered events to prevent unbounded growth
MaxDelivered == 10

StateConstraint ==
    /\ Len(deliveredEvents) <= MaxDelivered
    /\ \A s \in Shard : Len(shardEvents[s]) <= MaxEvents + MaxTxnOps

\* ============================================================================
\* INVARIANTS — grouped by category
\* ============================================================================

\* --- Core safety ---
\* TotalOrder                    (defined in base)

\* --- Structural ---
\* CursorPositionsValid          (defined in base)
\* ActiveCursorsSubset           (defined in base)
\* StreamStateConsistency        (defined in base)
\* TokenVersionsValid            (defined in base)
\* DeliveredEventsHaveTokens     (defined in base)

\* --- Extension (bug-family, used in hunting configs) ---
\* InvalidationCompleteness      (Family 2, defined in base)
\* InvalidationIdempotency       (Family 2, defined in base)
\* NoEventLossAtSegmentBoundary  (Family 3, defined in base)
\* TxnOrderPreservation          (Family 5, defined in base)
\* NoGapOnResume                 (Family 1, defined in base)

====
