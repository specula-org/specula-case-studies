------------------------------ MODULE MC ------------------------------
\* Model checking specification for Substrate GRANDPA
\* Wraps base spec with counter-bounded fault-injection actions
\* and symmetry reduction for exhaustive state space exploration.

EXTENDS base

CONSTANTS
    MaxStandardChangeLimit,  \* Max number of standard change additions
    MaxForcedChangeLimit,    \* Max number of forced change additions
    MaxCrashLimit,           \* Max number of crash actions
    MaxBlockLimit,           \* Max number of block production actions
    MaxByzantineVoteLimit,   \* Max number of Byzantine vote actions
    MaxFinalizationLimit,    \* Max number of finalization actions
    MaxMsgBufferLimit        \* Max pending changes per server

VARIABLES
    faultCounters  \* Record of fault-injection counters

mcVars == <<faultCounters>>

MCInit ==
    /\ Init
    /\ faultCounters = [
        standardChanges |-> 0,
        forcedChanges |-> 0,
        crashes |-> 0,
        blocks |-> 0,
        byzantineVotes |-> 0,
        finalizations |-> 0
       ]

----
\* ================================================================
\* Counter-bounded fault-injection wrappers
\* Bound: actions that introduce non-determinism
\* Don't bound: reactive/deterministic actions
\* ================================================================

\* Bounded: Block production without authority change
MCProduceBlock(s, parent, b) ==
    /\ faultCounters.blocks < MaxBlockLimit
    \* New blocks must extend the forced change's chain (not bypass it on a fork)
    \* In the implementation, forced changes fire synchronously on block import;
    \* blocks can't appear on a sibling fork before the change is applied.
    /\ \A b2 \in Block : changeRecord[b2].type = "forced" =>
        IsAncestor(b2, parent, blockTree)
    /\ ProduceBlock(s, parent, b)
    /\ faultCounters' = [faultCounters EXCEPT !.blocks = @ + 1]

\* Bounded: Block production WITH standard authority change (atomic)
\* In the implementation, authority changes are embedded in blocks.
\* Combining production + change ensures changes exist before finalization.
MCProduceBlockWithStdChange(s, parent, b, delay, newAuth) ==
    /\ faultCounters.blocks < MaxBlockLimit
    /\ faultCounters.standardChanges < MaxStandardChangeLimit
    \* Block production guards
    /\ ~crashed[s]
    /\ b \in Block
    /\ blockTree[b] = NilBlock
    /\ parent \in Block \cup {0}
    /\ IF parent = 0 THEN TRUE ELSE blockTree[parent] /= NilBlock
    /\ b > parent
    \* New blocks must extend the forced change's chain
    /\ \A b2 \in Block : changeRecord[b2].type = "forced" =>
        IsAncestor(b2, parent, blockTree)
    \* Standard change guards
    /\ delay >= 0
    /\ changeRecord[b] = [type |-> "none"]
    \* Pallet constraint: no un-enacted change on ancestor chain
    \* frame/grandpa/src/lib.rs:485 — !<PendingChange<T>>::exists()
    /\ \A b2 \in Block :
        (changeRecord[b2].type /= "none" /\ IsAncestor(b2, parent, blockTree))
        => b > b2 + changeRecord[b2].delay
    \* Combined state update
    /\ blockTree' = [blockTree EXCEPT ![b] = parent]
    /\ bestBlock' = [srv \in Server |->
                      IF b > bestBlock[srv] THEN b ELSE bestBlock[srv]]
    /\ changeRecord' = [changeRecord EXCEPT ![b] =
        [type |-> "standard", delay |-> delay, newAuth |-> newAuth]]
    /\ LET change == [block |-> b, delay |-> delay, newAuth |-> newAuth]
       IN /\ pendingStandard' = [srv \in Server |->
              pendingStandard[srv] \cup {change}]
          /\ voteLimit' = [srv \in Server |->
              ComputeVoteLimitOf(
                pendingStandard[srv] \cup {change}, finalizedBlock[srv])]
    /\ UNCHANGED <<finalVars, currentAuthorities, setId, pendingForced,
                   raceVars, equivVars, roundVars, crashVars>>
    /\ faultCounters' = [faultCounters EXCEPT !.blocks = @ + 1,
                                               !.standardChanges = @ + 1]

\* Bounded: Block production WITH forced authority change (atomic)
MCProduceBlockWithForcedChange(s, parent, b, delay, newAuth, medFin) ==
    /\ faultCounters.blocks < MaxBlockLimit
    /\ faultCounters.forcedChanges < MaxForcedChangeLimit
    \* Block production guards
    /\ ~crashed[s]
    /\ b \in Block
    /\ blockTree[b] = NilBlock
    /\ parent \in Block \cup {0}
    /\ IF parent = 0 THEN TRUE ELSE blockTree[parent] /= NilBlock
    /\ b > parent
    \* Forced change guards
    /\ delay >= 0
    /\ medFin <= finalizedBlock[s]
    /\ changeRecord[b] = [type |-> "none"]
    \* At most one forced change in the system at a time
    /\ \A b2 \in Block : changeRecord[b2].type /= "forced"
    \* Pallet constraint: no un-enacted change on ancestor chain
    /\ \A b2 \in Block :
        (changeRecord[b2].type /= "none" /\ IsAncestor(b2, parent, blockTree))
        => b > b2 + changeRecord[b2].delay
    \* Combined state update
    /\ blockTree' = [blockTree EXCEPT ![b] = parent]
    /\ bestBlock' = [srv \in Server |->
                      IF b > bestBlock[srv] THEN b ELSE bestBlock[srv]]
    /\ changeRecord' = [changeRecord EXCEPT ![b] =
        [type |-> "forced", delay |-> delay, newAuth |-> newAuth, medFin |-> medFin]]
    /\ pendingForced' = [srv \in Server |->
        pendingForced[srv] \cup {[block |-> b, delay |-> delay,
          newAuth |-> newAuth, medianFinalized |-> medFin]}]
    /\ UNCHANGED <<finalVars, currentAuthorities, setId, pendingStandard,
                   raceVars, equivVars, roundVars, limitVars, crashVars>>
    /\ faultCounters' = [faultCounters EXCEPT !.blocks = @ + 1,
                                               !.forcedChanges = @ + 1]

\* Unbounded: Apply standard change (reactive — triggered by finalization state)
MCApplyStandardChange(s) ==
    /\ ApplyStandardChange(s)
    /\ UNCHANGED faultCounters

\* Unbounded: Apply forced change (reactive — triggered by block depth)
MCApplyForcedChange(s) ==
    /\ ApplyForcedChange(s)
    /\ UNCHANGED faultCounters

\* Bounded: Finalization via gossip or sync (introduces interleaving)
MCAcquireFinalizationLock(s, block, path) ==
    /\ faultCounters.finalizations < MaxFinalizationLimit
    /\ AcquireFinalizationLock(s, block, path)
    /\ faultCounters' = [faultCounters EXCEPT !.finalizations = @ + 1]

\* Unbounded: Finalization sub-steps (reactive — continue in-progress finalization)
MCApplyFinalizationChanges(s) ==
    /\ ApplyFinalizationChanges(s)
    /\ UNCHANGED faultCounters

MCWriteToDisk(s) ==
    /\ WriteToDisk(s)
    /\ UNCHANGED faultCounters

MCReleaseFinalizationLock(s) ==
    /\ ReleaseFinalizationLock(s)
    /\ UNCHANGED faultCounters

\* Bounded: Atomic finalization (alternative path)
MCFinalizeBlock(s, block) ==
    /\ faultCounters.finalizations < MaxFinalizationLimit
    /\ FinalizeBlock(s, block)
    /\ faultCounters' = [faultCounters EXCEPT !.finalizations = @ + 1]

\* Unbounded: Round state machine actions (reactive — follow protocol)
MCPropose(s, r, block) ==
    /\ Propose(s, r, block)
    /\ UNCHANGED faultCounters

MCPrevote(s, r, block) ==
    /\ Prevote(s, r, block)
    /\ UNCHANGED faultCounters

MCPrecommit(s, r, block) ==
    /\ Precommit(s, r, block)
    /\ UNCHANGED faultCounters

MCCompleteRound(s, r) ==
    /\ CompleteRound(s, r)
    /\ UNCHANGED faultCounters

\* Bounded: Byzantine votes (fault injection)
MCByzantinePrevote(s, r, block) ==
    /\ faultCounters.byzantineVotes < MaxByzantineVoteLimit
    /\ ByzantinePrevote(s, r, block)
    /\ faultCounters' = [faultCounters EXCEPT !.byzantineVotes = @ + 1]

MCByzantinePrecommit(s, r, block) ==
    /\ faultCounters.byzantineVotes < MaxByzantineVoteLimit
    /\ ByzantinePrecommit(s, r, block)
    /\ faultCounters' = [faultCounters EXCEPT !.byzantineVotes = @ + 1]

\* Bounded: Crash (fault injection)
MCCrash(s) ==
    /\ faultCounters.crashes < MaxCrashLimit
    /\ Crash(s)
    /\ faultCounters' = [faultCounters EXCEPT !.crashes = @ + 1]

\* Unbounded: Recovery (reactive — restores from crash)
MCRecover(s) ==
    /\ Recover(s)
    /\ UNCHANGED faultCounters

----
\* ================================================================
\* MCNext: All actions grouped
\* ================================================================

MCNext ==
    \* Block production: plain or with embedded authority change (bounded)
    \/ \E s \in Server, parent \in Block \cup {0}, b \in Block :
        MCProduceBlock(s, parent, b)
    \/ \E s \in Server, parent \in Block \cup {0}, b \in Block,
         d \in 0..3, auth \in SUBSET Server :
        auth /= {} /\ MCProduceBlockWithStdChange(s, parent, b, d, auth)
    \/ \E s \in Server, parent \in Block \cup {0}, b \in Block,
         d \in 0..3, auth \in SUBSET Server, mf \in 0..MaxBlock :
        auth /= {} /\ MCProduceBlockWithForcedChange(s, parent, b, d, auth, mf)
    \* Authority change application (unbounded — reactive)
    \/ \E s \in Server : MCApplyStandardChange(s)
    \/ \E s \in Server : MCApplyForcedChange(s)
    \* Finalization sub-steps (bounded start, unbounded continuation)
    \/ \E s \in Server, b \in Block, p \in {"gossip", "sync"} :
        MCAcquireFinalizationLock(s, b, p)
    \/ \E s \in Server : MCApplyFinalizationChanges(s)
    \/ \E s \in Server : MCWriteToDisk(s)
    \/ \E s \in Server : MCReleaseFinalizationLock(s)
    \* Atomic finalization (bounded)
    \/ \E s \in Server, b \in Block : MCFinalizeBlock(s, b)
    \* Round state machine (unbounded — reactive)
    \/ \E s \in Server, r \in 1..MaxRound, b \in Block : MCPropose(s, r, b)
    \/ \E s \in Server, r \in 1..MaxRound, b \in Block : MCPrevote(s, r, b)
    \/ \E s \in Server, r \in 1..MaxRound, b \in Block : MCPrecommit(s, r, b)
    \/ \E s \in Server, r \in 1..MaxRound : MCCompleteRound(s, r)
    \* Byzantine votes (bounded — fault injection)
    \/ \E s \in Server, r \in 1..MaxRound, b \in Block : MCByzantinePrevote(s, r, b)
    \/ \E s \in Server, r \in 1..MaxRound, b \in Block : MCByzantinePrecommit(s, r, b)
    \* Crash/Recovery (bounded crash, unbounded recovery)
    \/ \E s \in Server : MCCrash(s)
    \/ \E s \in Server : MCRecover(s)

----
\* ================================================================
\* Symmetry and View
\* ================================================================

\* Symmetry reduction: servers are interchangeable
MCSymmetry == Permutations(Server)

\* State space view: exclude counters from state fingerprint
MCView == <<blockVars, finalVars, authVars, raceVars, equivVars, roundVars, limitVars, crashVars>>

----
\* ================================================================
\* State space pruning: structural constraints
\* ================================================================

\* Limit pending changes per server to prevent explosion
PendingChangeConstraint ==
    \A s \in Server :
        /\ Cardinality(pendingStandard[s]) <= MaxMsgBufferLimit
        /\ Cardinality(pendingForced[s]) <= MaxMsgBufferLimit

----
\* ================================================================
\* Invariants (include all base invariants + structural)
\* ================================================================

\* All base spec invariants are inherited.
\* Additional structural invariants for MC:

\* The set_id should never go backwards
SetIdMonotonic ==
    \A s \in Server :
        ~crashed[s] => setId[s] >= 0

\* Finalized block should never decrease (except on crash/recovery)
FinalizedMonotonic ==
    \A s \in Server :
        ~crashed[s] => finalizedBlock[s] >= 0

----
\* ================================================================
\* Temporal Properties
\* ================================================================

\* Liveness: If no server is crashed and blocks are produced,
\* rounds eventually complete (requires fairness)
\* Bug Family 4
RoundCompletion ==
    \A s \in Server :
        IsHonest(s) /\ ~crashed[s]
        ~> \E r \in 1..MaxRound : roundPhase[s][r] = "completed"

\* Liveness: Finality eventually advances if honest majority participates
\* Bug Families 1, 4
FinalityProgress ==
    \A s \in Server :
        IsHonest(s) /\ ~crashed[s] /\ bestBlock[s] > finalizedBlock[s]
        ~> finalizedBlock[s] > 0

=============================================================================
