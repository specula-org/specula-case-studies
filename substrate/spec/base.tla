-------------------------------- MODULE base --------------------------------
\* TLA+ specification for Substrate GRANDPA BFT Finality Gadget
\*
\* Models:
\*   - Authority set changes: standard (on finality) and forced (on block depth)
\*     with ForkTree semantics and dependency ordering (Bug Family 1)
\*   - Multiple finalization paths racing on shared authority set state (Bug Family 2)
\*   - Equivocation counting in GHOST algorithm (Bug Family 3)
\*   - Round state machine: propose -> prevote -> precommit -> complete (Bug Family 4)
\*   - Vote target limits from pending authority changes (Bug Family 5)
\*   - Crash and recovery with persistence atomicity concerns (Families 2, 4)
\*
\* Source: substrate/client/consensus/grandpa/src/
\*         substrate/frame/grandpa/src/lib.rs

EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS
    Server,          \* Set of server/node IDs
    Block,           \* Set of block numbers (e.g., 1..MaxBlock)
    MaxBlock,        \* Maximum block number
    MaxRound,        \* Maximum round number
    Byzantine,       \* Set of Byzantine servers (subset of Server)
    Quorum,          \* Quorum size: 2f+1 where f = |Byzantine|
    InitAuthorities, \* Initial authority set (= Server)
    NilBlock         \* Sentinel for "no block"

VARIABLES
    \* ---- Block tree variables ----
    blockTree,         \* blockTree[b] = parent block number (0 = genesis has no parent)
    bestBlock,         \* bestBlock[s] = best (highest) block known to server s
    changeRecord,      \* changeRecord[b] = "none" or [type, delay, newAuth]
                       \*   On-chain authority change for block b (deterministic per block)

    \* ---- Finalization variables ----
    finalizedBlock,    \* finalizedBlock[s] = highest finalized block number on server s

    \* ---- Authority set variables (Bug Family 1) ----
    currentAuthorities, \* currentAuthorities[s] = current authority set on server s
    setId,              \* setId[s] = current authority set ID on server s
    pendingStandard,    \* pendingStandard[s] = set of pending standard changes
                        \*   Each element: [block |-> N, delay |-> N, newAuth |-> AuthSet]
    pendingForced,      \* pendingForced[s] = set of pending forced changes
                        \*   Each element: [block |-> N, delay |-> N, newAuth |-> AuthSet,
                        \*                  medianFinalized |-> N]

    \* ---- Finalization race variables (Bug Family 2) ----
    authSetLock,       \* authSetLock[s] \in {"free", "gossip", "sync", "import"}
    finalizationStep,  \* finalizationStep[s] = sub-step of ongoing finalization
                       \*   0 = idle, 1 = lock acquired, 2 = changes applied,
                       \*   3 = written to disk, 4 = lock released
    finalizingBlock,   \* finalizingBlock[s] = block being finalized (NilBlock if idle)
    finalizingPath,    \* finalizingPath[s] \in {"none", "gossip", "sync"}

    \* ---- Equivocation variables (Bug Family 3) ----
    prevotes,          \* prevotes[s][r] = set of prevote targets cast by server s in round r
    precommits,        \* precommits[s][r] = set of precommit targets cast by server s in round r
    equivocators,      \* equivocators[r] = set of servers that equivocated in round r

    \* ---- Round state variables (Bug Family 4) ----
    roundPhase,        \* roundPhase[s][r] \in {"idle", "proposed", "prevoted", "precommitted", "completed"}
    currentRound,      \* currentRound[s] = current round number on server s
    roundBase,         \* roundBase[s] = round voting base block (models last_finalized_in_rounds)
                       \*   Votes must descend from this; updated on round completion/finalization
    hasVoted,          \* hasVoted[s][r] = persisted vote state for crash recovery
                       \*   [phase |-> {"none","propose","prevote","precommit"},
                       \*    target |-> Block \cup {NilBlock}]

    \* ---- Vote target limit variables (Bug Family 5) ----
    voteLimit,         \* voteLimit[s] = earliest pending change effective number (or MaxBlock+1)

    \* ---- Crash/recovery variables (Families 2, 4) ----
    crashed,           \* crashed[s] = TRUE if server s is crashed
    persisted          \* persisted[s] = record of persisted state:
                       \*   [finalizedBlock |-> N, setId |-> N, authorities |-> AuthSet,
                       \*    hasVoted |-> hasVoted state]

\* Variable groupings for UNCHANGED
blockVars     == <<blockTree, bestBlock, changeRecord>>
finalVars     == <<finalizedBlock>>
authVars      == <<currentAuthorities, setId, pendingStandard, pendingForced>>
raceVars      == <<authSetLock, finalizationStep, finalizingBlock, finalizingPath>>
equivVars     == <<prevotes, precommits, equivocators>>
roundVars     == <<roundPhase, currentRound, roundBase, hasVoted>>
limitVars     == <<voteLimit>>
crashVars     == <<crashed, persisted>>

vars == <<blockVars, finalVars, authVars, raceVars, equivVars, roundVars, limitVars, crashVars>>

----
\* Helper operators

\* Block ancestry: b1 is an ancestor of b2 (or equal)
\* blockTree[b] = parent of b; genesis (block 0) has no parent
RECURSIVE IsAncestor(_, _, _)
IsAncestor(b1, b2, bt) ==
    IF b1 = b2 THEN TRUE
    ELSE IF b2 = 0 \/ b2 = NilBlock THEN FALSE
    ELSE IF bt[b2] = NilBlock THEN FALSE
    ELSE IsAncestor(b1, bt[b2], bt)

\* Effective number of a pending change
EffectiveNumber(change) == change.block + change.delay

\* Compute vote limit from pending standard changes.
\* authorities.rs:423-429 — current_limit checks ForkTree roots.
\* Under pallet constraint (one pending change per chain, frame/grandpa/lib.rs:485),
\* child changes always have higher effective_number than parent changes,
\* so roots() is equivalent to iter() for computing the minimum.
\* Takes explicit parameters to avoid TLC issues with priming operator calls.
ComputeVoteLimitOf(ps, fb) ==
    LET effectiveNums == {EffectiveNumber(c) : c \in ps}
        validNums == {n \in effectiveNums : n >= fb}
    IN IF validNums = {} THEN MaxBlock + 1
       ELSE CHOOSE n \in validNums : \A m \in validNums : n <= m

\* Check if an honest server
IsHonest(s) == s \notin Byzantine

\* All prevotes for a block in a round, counting equivocators as voting for everything
\* finality-grandpa PR #36 — equivocators treated as "voting for everything"
PrevoteWeight(r, b) ==
    LET directVoters == {s \in Server : b \in prevotes[s][r]}
    IN Cardinality(directVoters \cup equivocators[r])

\* All precommits for a block in a round, counting equivocators as voting for everything
PrecommitWeight(r, b) ==
    LET directVoters == {s \in Server : b \in precommits[s][r]}
    IN Cardinality(directVoters \cup equivocators[r])

\* GHOST estimate: highest block with prevote supermajority
\* Simplified — in the real algorithm this walks the block tree
HasPrevoteSupermajority(r, b) == PrevoteWeight(r, b) >= Quorum

\* Check if round is completable: precommit supermajority for some block
HasPrecommitSupermajority(r, b) == PrecommitWeight(r, b) >= Quorum

\* Whether a forced change dependency is satisfied
\* authorities.rs:478-492 — only checks roots of pending standard changes
ForcedChangeDepsOk(s, fc) ==
    \A sc \in pendingStandard[s] :
        \* If standard change is ancestor of forced change and effective number <= median
        ~(EffectiveNumber(sc) <= fc.medianFinalized
          /\ IsAncestor(sc.block, fc.block, blockTree))

----
\* Initial state

Init ==
    \* Block tree: initially only genesis (block 0)
    /\ blockTree = [b \in Block |-> IF b = 1 THEN 0 ELSE NilBlock]
    /\ bestBlock = [s \in Server |-> 1]
    /\ changeRecord = [b \in Block |-> [type |-> "none"]]
    \* Finalization
    /\ finalizedBlock = [s \in Server |-> 0]
    \* Authority set
    /\ currentAuthorities = [s \in Server |-> InitAuthorities]
    /\ setId = [s \in Server |-> 0]
    /\ pendingStandard = [s \in Server |-> {}]
    /\ pendingForced = [s \in Server |-> {}]
    \* Finalization race
    /\ authSetLock = [s \in Server |-> "free"]
    /\ finalizationStep = [s \in Server |-> 0]
    /\ finalizingBlock = [s \in Server |-> NilBlock]
    /\ finalizingPath = [s \in Server |-> "none"]
    \* Equivocation
    /\ prevotes = [s \in Server |-> [r \in 1..MaxRound |-> {}]]
    /\ precommits = [s \in Server |-> [r \in 1..MaxRound |-> {}]]
    /\ equivocators = [r \in 1..MaxRound |-> {}]
    \* Round state
    /\ roundPhase = [s \in Server |-> [r \in 1..MaxRound |-> "idle"]]
    /\ currentRound = [s \in Server |-> 1]
    /\ roundBase = [s \in Server |-> 0]
    /\ hasVoted = [s \in Server |-> [r \in 1..MaxRound |->
                    [phase |-> "none", target |-> NilBlock]]]
    \* Vote limit
    /\ voteLimit = [s \in Server |-> MaxBlock + 1]
    \* Crash/recovery
    /\ crashed = [s \in Server |-> FALSE]
    /\ persisted = [s \in Server |-> [finalizedBlock |-> 0, setId |-> 0,
                     authorities |-> InitAuthorities,
                     hasVoted |-> [r \in 1..MaxRound |->
                                   [phase |-> "none", target |-> NilBlock]]]]

----
\* ================================================================
\* Actions
\* ================================================================

\* ----------------------------------------------------------------
\* ProduceBlock: A new block is added to the block tree
\* Models block production; extends the chain
\* ----------------------------------------------------------------
ProduceBlock(s, parent, newBlock) ==
    /\ ~crashed[s]
    /\ newBlock \in Block
    /\ blockTree[newBlock] = NilBlock  \* block not yet in tree
    /\ parent \in Block \cup {0}
    /\ IF parent = 0 THEN TRUE ELSE blockTree[parent] /= NilBlock \* parent exists (genesis or in tree)
    /\ newBlock > parent
    /\ blockTree' = [blockTree EXCEPT ![newBlock] = parent]
    \* All servers learn about the new block (synchronous block propagation)
    \* Authority changes are on-chain, so all nodes must see all blocks
    /\ bestBlock' = [srv \in Server |->
                      IF newBlock > bestBlock[srv]
                      THEN newBlock ELSE bestBlock[srv]]
    /\ UNCHANGED <<finalVars, authVars, raceVars, equivVars, roundVars, limitVars, crashVars, changeRecord>>

\* ----------------------------------------------------------------
\* AddStandardChange: Schedule a standard authority set change
\* import.rs:314-342 — make_authorities_changes detects change in block
\* authorities.rs:304-334 — add_standard_change inserts into ForkTree
\* Bug Family 1: Authority set change ordering
\* ----------------------------------------------------------------
AddStandardChange(s, block, delay, newAuth) ==
    /\ ~crashed[s]
    /\ block \in Block
    /\ blockTree[block] /= NilBlock  \* block exists in tree
    /\ block <= bestBlock[s]
    \* No duplicate at same block — authorities.rs:323 ForkTree::import
    /\ ~\E c \in pendingStandard[s] : c.block = block
    /\ delay >= 0
    \* Pallet constraint: at most one pending change per chain
    \* frame/grandpa/src/lib.rs:485 — !<PendingChange<T>>::exists()
    \* On a given chain, a new change can only be signaled after the previous
    \* change is enacted (effective_number reached). This ensures child changes
    \* in the ForkTree always have higher effective_number than parent changes.
    /\ \A b2 \in Block :
        (b2 /= block /\ changeRecord[b2].type /= "none"
         /\ IsAncestor(b2, block, blockTree))
        => block > b2 + changeRecord[b2].delay
    \* Block must be on a chain compatible with all finalized blocks
    \* (nodes don't process authority changes on abandoned forks)
    /\ \A srv \in Server : ~crashed[srv] /\ finalizedBlock[srv] > 0 =>
        IsAncestor(finalizedBlock[srv], block, blockTree)
        \/ IsAncestor(block, finalizedBlock[srv], blockTree)
    \* On-chain determinism: change parameters are a function of the block
    /\ changeRecord[block] \in {[type |-> "none"], [type |-> "standard", delay |-> delay, newAuth |-> newAuth]}
    /\ changeRecord' = [changeRecord EXCEPT ![block] =
        [type |-> "standard", delay |-> delay, newAuth |-> newAuth]]
    \* Add to ALL servers — authority changes are on-chain, visible to all nodes
    /\ LET change == [block |-> block, delay |-> delay, newAuth |-> newAuth]
       IN /\ pendingStandard' = [srv \in Server |->
              IF \E c \in pendingStandard[srv] : c.block = block
              THEN pendingStandard[srv]
              ELSE pendingStandard[srv] \cup {change}]
          \* Update vote limit for all servers
          /\ voteLimit' = [srv \in Server |->
              LET newPS == IF \E c \in pendingStandard[srv] : c.block = block
                           THEN pendingStandard[srv]
                           ELSE pendingStandard[srv] \cup {change}
              IN ComputeVoteLimitOf(newPS, finalizedBlock[srv])]
    /\ UNCHANGED <<blockTree, bestBlock, finalVars, currentAuthorities, setId, pendingForced,
                   raceVars, equivVars, roundVars, crashVars>>

\* ----------------------------------------------------------------
\* AddForcedChange: Schedule a forced authority set change
\* import.rs:314-342 — make_authorities_changes, DelayKind::Best triggers pause
\* authorities.rs:336-380 — add_forced_change inserts into sorted Vec
\* Bug Family 1: Authority set change ordering
\* ----------------------------------------------------------------
AddForcedChange(s, block, delay, newAuth, medFin) ==
    /\ ~crashed[s]
    /\ block \in Block
    /\ blockTree[block] /= NilBlock
    /\ block <= bestBlock[s]
    \* At most one forced change in the system at a time — in the implementation,
    \* forced changes fire synchronously on block import (all nodes see same result).
    \* Multiple pending forced changes cause non-deterministic application order in
    \* the spec because we model per-node async application.
    /\ \A b2 \in Block : changeRecord[b2].type /= "forced"
    /\ delay >= 0
    /\ medFin <= finalizedBlock[s]
    \* Pallet constraint: no un-enacted change on ancestor chain
    /\ \A b2 \in Block :
        (b2 /= block /\ changeRecord[b2].type /= "none"
         /\ IsAncestor(b2, block, blockTree))
        => block > b2 + changeRecord[b2].delay
    \* Block must be on a chain compatible with all finalized blocks
    /\ \A srv \in Server : ~crashed[srv] /\ finalizedBlock[srv] > 0 =>
        IsAncestor(finalizedBlock[srv], block, blockTree)
        \/ IsAncestor(block, finalizedBlock[srv], blockTree)
    \* On-chain determinism: change parameters are a function of the block
    /\ changeRecord[block] \in {[type |-> "none"],
        [type |-> "forced", delay |-> delay, newAuth |-> newAuth, medFin |-> medFin]}
    /\ changeRecord' = [changeRecord EXCEPT ![block] =
        [type |-> "forced", delay |-> delay, newAuth |-> newAuth, medFin |-> medFin]]
    \* Add to ALL servers — authority changes are on-chain, visible to all nodes
    \* Use the same medFin for all servers (it's a consensus value, not per-node)
    /\ pendingForced' = [srv \in Server |->
        IF \E c \in pendingForced[srv] : c.block = block
        THEN pendingForced[srv]
        ELSE pendingForced[srv] \cup {[block |-> block, delay |-> delay,
               newAuth |-> newAuth, medianFinalized |-> medFin]}]
    /\ UNCHANGED <<blockTree, bestBlock, finalVars, currentAuthorities, setId, pendingStandard,
                   raceVars, equivVars, roundVars, limitVars, crashVars>>

\* ----------------------------------------------------------------
\* ApplyStandardChange: Apply a standard change upon finalization
\* authorities.rs:541-602 — apply_standard_changes via finalize_with_descendent_if
\* environment.rs:1394-1402 — called inside finalize_block
\* Bug Family 1: Standard changes applied in order on finalization
\* ----------------------------------------------------------------
ApplyStandardChange(s) ==
    /\ ~crashed[s]
    /\ authSetLock[s] = "free" \/ finalizationStep[s] >= 2
    \* Forced changes have priority — authorities.rs calls apply_forced_changes first
    /\ ~\E fc \in pendingForced[s] :
        /\ EffectiveNumber(fc) <= bestBlock[s]
        /\ IsAncestor(fc.block, bestBlock[s], blockTree)
        /\ ForcedChangeDepsOk(s, fc)
    \* Find a pending standard change whose effective number <= finalized block
    /\ \E c \in pendingStandard[s] :
        \* authorities.rs:558 — predicate: effective_number <= finalized_number
        /\ EffectiveNumber(c) <= finalizedBlock[s]
        \* The change block must be on the finalized chain (ancestor of finalized)
        /\ IsAncestor(c.block, finalizedBlock[s], blockTree)
        \* Deterministic: pick the ready change with smallest effective number
        \* (ties broken by smallest block number) — matches impl ordering
        /\ ~\E other \in pendingStandard[s] :
            /\ other /= c
            /\ EffectiveNumber(other) <= finalizedBlock[s]
            /\ IsAncestor(other.block, finalizedBlock[s], blockTree)
            /\ \/ EffectiveNumber(other) < EffectiveNumber(c)
               \/ (EffectiveNumber(other) = EffectiveNumber(c)
                   /\ other.block < c.block)
        \* Apply the change — authorities.rs:592-593
        /\ currentAuthorities' = [currentAuthorities EXCEPT ![s] = c.newAuth]
        /\ setId' = [setId EXCEPT ![s] = setId[s] + 1]
        \* Remove the applied change and prune non-finalized-chain changes
        \* authorities.rs:555-560 — finalize_with_descendent_if prunes forks
        /\ LET newPS == {pc \in (pendingStandard[s] \ {c}) :
                            IsAncestor(pc.block, finalizedBlock[s], blockTree)}
           IN /\ pendingStandard' = [pendingStandard EXCEPT ![s] = newPS]
              \* Update vote limit
              /\ voteLimit' = [voteLimit EXCEPT ![s] = ComputeVoteLimitOf(newPS, finalizedBlock[s])]
        \* Prune forced changes not on finalized chain — authorities.rs:564-574
        /\ pendingForced' = [pendingForced EXCEPT ![s] =
            {fc \in @ :
                /\ EffectiveNumber(fc) > finalizedBlock[s]
                /\ IsAncestor(finalizedBlock[s], fc.block, blockTree)}]
    /\ UNCHANGED <<blockVars, finalVars, raceVars, equivVars, roundVars, crashVars>>

\* ----------------------------------------------------------------
\* ApplyForcedChange: Apply a forced change based on block depth
\* authorities.rs:447-529 — apply_forced_changes
\* Bug Family 1: Forced change dependency on standard changes
\* ----------------------------------------------------------------
ApplyForcedChange(s) ==
    /\ ~crashed[s]
    /\ \E fc \in pendingForced[s] :
        \* authorities.rs:461-465 — effective_number == best_number
        /\ EffectiveNumber(fc) <= bestBlock[s]
        \* authorities.rs:469 — best block on same branch as change
        /\ IsAncestor(fc.block, bestBlock[s], blockTree)
        \* authorities.rs:478-492 — dependency check on root standard changes
        /\ ForcedChangeDepsOk(s, fc)
        \* Deterministic: pick the ready change with smallest effective number
        \* (ties broken by smallest block number) — matches BTreeMap ordering in impl
        /\ ~\E other \in pendingForced[s] :
            /\ other /= fc
            /\ EffectiveNumber(other) <= bestBlock[s]
            /\ IsAncestor(other.block, bestBlock[s], blockTree)
            /\ ForcedChangeDepsOk(s, other)
            /\ \/ EffectiveNumber(other) < EffectiveNumber(fc)
               \/ (EffectiveNumber(other) = EffectiveNumber(fc)
                   /\ other.block < fc.block)
        \* Apply: create completely fresh set — authorities.rs:516-517
        /\ currentAuthorities' = [currentAuthorities EXCEPT ![s] = fc.newAuth]
        /\ setId' = [setId EXCEPT ![s] = setId[s] + 1]
        \* All pending changes wiped — authorities.rs:516-517
        /\ pendingStandard' = [pendingStandard EXCEPT ![s] = {}]
        /\ pendingForced' = [pendingForced EXCEPT ![s] = {}]
        /\ voteLimit' = [voteLimit EXCEPT ![s] = MaxBlock + 1]
    /\ UNCHANGED <<blockVars, finalVars, raceVars, equivVars, roundVars, crashVars>>

\* ----------------------------------------------------------------
\* Finalization sub-step actions (Bug Family 2)
\* Models the non-atomic finalization process from environment.rs:1354-1544
\* Split into sub-steps to allow interleaving between gossip and sync paths
\* ----------------------------------------------------------------

\* Step 1: Acquire authority set lock
\* environment.rs:1370-1373 — lock must be held through writing to DB
AcquireFinalizationLock(s, block, path) ==
    /\ ~crashed[s]
    \* import.rs:324 — voter is paused when forced change is pending
    /\ pendingForced[s] = {}
    /\ path \in {"gossip", "sync"}
    /\ authSetLock[s] = "free"
    /\ finalizationStep[s] = 0
    /\ block \in Block
    /\ block > finalizedBlock[s]  \* Must advance finality
    /\ blockTree[block] /= NilBlock
    /\ IsAncestor(finalizedBlock[s], block, blockTree)
    \* Voting requirement: block (or descendant) has precommit supermajority
    /\ \E r \in 1..MaxRound, b \in Block :
        /\ HasPrecommitSupermajority(r, b)
        /\ IsAncestor(block, b, blockTree)
    /\ authSetLock' = [authSetLock EXCEPT ![s] = path]
    /\ finalizationStep' = [finalizationStep EXCEPT ![s] = 1]
    /\ finalizingBlock' = [finalizingBlock EXCEPT ![s] = block]
    /\ finalizingPath' = [finalizingPath EXCEPT ![s] = path]
    /\ UNCHANGED <<blockVars, finalVars, authVars, equivVars, roundVars, limitVars, crashVars>>

\* Step 2: Check already-finalized + apply authority changes
\* environment.rs:1377-1402 — check + apply_standard_changes
ApplyFinalizationChanges(s) ==
    /\ ~crashed[s]
    /\ finalizationStep[s] = 1
    \* environment.rs:1377-1388 — already finalized check
    /\ finalizingBlock[s] > finalizedBlock[s]
    /\ finalizationStep' = [finalizationStep EXCEPT ![s] = 2]
    \* Authority changes applied as part of finalization (modeled separately)
    /\ UNCHANGED <<blockVars, finalVars, authVars, authSetLock, finalizingBlock,
                   finalizingPath, equivVars, roundVars, limitVars, crashVars>>

\* Step 3: Write to disk (finality + authority set)
\* environment.rs:1451-1530 — apply_finality then update_authority_set
\* Non-atomic: finality written before authority set
WriteToDisk(s) ==
    /\ ~crashed[s]
    /\ finalizationStep[s] = 2
    \* Update finalized block
    /\ finalizedBlock' = [finalizedBlock EXCEPT ![s] = finalizingBlock[s]]
    \* Persist state — aux_schema.rs non-atomic writes
    /\ persisted' = [persisted EXCEPT ![s] =
        [@ EXCEPT !.finalizedBlock = finalizingBlock[s],
                   !.setId = setId[s],
                   !.authorities = currentAuthorities[s]]]
    /\ finalizationStep' = [finalizationStep EXCEPT ![s] = 3]
    \* voter/mod.rs:628-629 — process_incoming updates last_finalized_in_rounds
    /\ roundBase' = [roundBase EXCEPT ![s] =
        IF finalizingBlock[s] > @ THEN finalizingBlock[s] ELSE @]
    /\ UNCHANGED <<blockVars, authVars, authSetLock, finalizingBlock, finalizingPath,
                   equivVars, roundPhase, currentRound, hasVoted, limitVars, crashed>>

\* Step 4: Release lock
\* environment.rs:1535-1543 — lock released at end of finalize_block
ReleaseFinalizationLock(s) ==
    /\ ~crashed[s]
    /\ finalizationStep[s] = 3
    /\ authSetLock' = [authSetLock EXCEPT ![s] = "free"]
    /\ finalizationStep' = [finalizationStep EXCEPT ![s] = 0]
    /\ finalizingBlock' = [finalizingBlock EXCEPT ![s] = NilBlock]
    /\ finalizingPath' = [finalizingPath EXCEPT ![s] = "none"]
    /\ UNCHANGED <<blockVars, finalVars, authVars, equivVars, roundVars, limitVars, crashVars>>

\* Combined atomic finalization (for simpler modeling when races not needed)
\* Requires precommit supermajority — in implementation, finalization is triggered
\* by completed() callback after voting round reaches agreement.
FinalizeBlock(s, block) ==
    /\ ~crashed[s]
    \* import.rs:324 — voter is paused when forced change is pending
    /\ pendingForced[s] = {}
    /\ authSetLock[s] = "free"
    /\ finalizationStep[s] = 0
    /\ block \in Block
    /\ block > finalizedBlock[s]
    /\ blockTree[block] /= NilBlock
    /\ IsAncestor(finalizedBlock[s], block, blockTree)
    \* Voting requirement: block (or descendant) has precommit supermajority
    /\ \E r \in 1..MaxRound, b \in Block :
        /\ HasPrecommitSupermajority(r, b)
        /\ IsAncestor(block, b, blockTree)
    /\ finalizedBlock' = [finalizedBlock EXCEPT ![s] = block]
    /\ persisted' = [persisted EXCEPT ![s] =
        [@ EXCEPT !.finalizedBlock = block]]
    \* Update vote limit (pendingStandard unchanged, finalizedBlock becomes block)
    /\ voteLimit' = [voteLimit EXCEPT ![s] = ComputeVoteLimitOf(pendingStandard[s], block)]
    \* voter/mod.rs:628-629 — finalization updates last_finalized_in_rounds
    /\ roundBase' = [roundBase EXCEPT ![s] = IF block > @ THEN block ELSE @]
    /\ UNCHANGED <<blockVars, authVars, raceVars, equivVars,
                   roundPhase, currentRound, hasVoted, crashed>>

\* ----------------------------------------------------------------
\* Round state machine actions (Bug Family 4)
\* environment.rs:797-1093 — proposed/prevoted/precommitted/completed/concluded
\* ----------------------------------------------------------------

\* Propose: Primary sends a proposal
\* environment.rs:797-838 — proposed()
Propose(s, r, block) ==
    /\ ~crashed[s]
    /\ IsHonest(s)
    \* import.rs:324 — voter is paused when forced change is pending
    /\ pendingForced[s] = {}
    /\ r = currentRound[s]
    /\ roundPhase[s][r] = "idle"
    \* environment.rs:814 — can_propose() check
    /\ hasVoted[s][r].phase = "none"
    /\ block \in Block
    /\ blockTree[block] /= NilBlock
    \* Bug Family 5: vote target must respect authority set limit
    \* authorities.rs:423-429 — current_limit
    /\ block <= voteLimit[s]
    /\ block >= finalizedBlock[s]
    /\ roundPhase' = [roundPhase EXCEPT ![s][r] = "proposed"]
    /\ hasVoted' = [hasVoted EXCEPT ![s][r] = [phase |-> "propose", target |-> block]]
    \* Persist — environment.rs:832
    /\ persisted' = [persisted EXCEPT ![s].hasVoted[r] =
        [phase |-> "propose", target |-> block]]
    /\ UNCHANGED <<blockVars, finalVars, authVars, raceVars, equivVars,
                   currentRound, roundBase, limitVars, crashed>>

\* Prevote: Cast a prevote
\* environment.rs:840-901 — prevoted()
Prevote(s, r, block) ==
    /\ ~crashed[s]
    /\ IsHonest(s)
    \* import.rs:324 — voter is paused when forced change is pending
    /\ pendingForced[s] = {}
    /\ r = currentRound[s]
    /\ roundPhase[s][r] \in {"idle", "proposed"}
    \* environment.rs:871 — can_prevote() check
    /\ hasVoted[s][r].phase \in {"none", "propose"}
    /\ block \in Block
    /\ blockTree[block] /= NilBlock
    \* Bug Family 5: vote target limit
    /\ block <= voteLimit[s]
    \* Vote must descend from round base (models last_finalized_in_rounds)
    \* voting_round.rs:373-384 — handle_vote drops votes not descending from round base
    /\ IF roundBase[s] = 0 THEN TRUE
       ELSE IsAncestor(roundBase[s], block, blockTree)
    /\ roundPhase' = [roundPhase EXCEPT ![s][r] = "prevoted"]
    /\ prevotes' = [prevotes EXCEPT ![s][r] = @ \cup {block}]
    /\ hasVoted' = [hasVoted EXCEPT ![s][r] = [phase |-> "prevote", target |-> block]]
    /\ persisted' = [persisted EXCEPT ![s].hasVoted[r] =
        [phase |-> "prevote", target |-> block]]
    /\ UNCHANGED <<blockVars, finalVars, authVars, raceVars,
                   precommits, equivocators, currentRound, roundBase, limitVars, crashed>>

\* Precommit: Cast a precommit
\* environment.rs:903-974 — precommitted()
\* Bug Family 4: must prevote before precommitting
Precommit(s, r, block) ==
    /\ ~crashed[s]
    /\ IsHonest(s)
    \* import.rs:324 — voter is paused when forced change is pending
    /\ pendingForced[s] = {}
    /\ r = currentRound[s]
    /\ roundPhase[s][r] = "prevoted"
    \* environment.rs:942 — can_precommit() check
    /\ hasVoted[s][r].phase = "prevote"
    \* environment.rs:948 — Safety check: must have prevoted first
    /\ prevotes[s][r] /= {}
    /\ block \in Block
    /\ blockTree[block] /= NilBlock
    /\ block <= voteLimit[s]
    \* Vote must descend from round base (models last_finalized_in_rounds)
    \* voting_round.rs:373-384 — handle_vote drops votes not descending from round base
    /\ IF roundBase[s] = 0 THEN TRUE
       ELSE IsAncestor(roundBase[s], block, blockTree)
    \* Precommit target must be on a chain with prevote supermajority
    \* (GHOST estimate or ancestor — voting rules can restrict target)
    \* Fix for Appendix A spec bug: old guard only checked existence of
    \* supermajority without constraining the precommit target's relationship
    /\ \/ HasPrevoteSupermajority(r, block)
       \/ \E b \in Block : HasPrevoteSupermajority(r, b)
                           /\ IsAncestor(block, b, blockTree)
    /\ roundPhase' = [roundPhase EXCEPT ![s][r] = "precommitted"]
    /\ precommits' = [precommits EXCEPT ![s][r] = @ \cup {block}]
    /\ hasVoted' = [hasVoted EXCEPT ![s][r] = [phase |-> "precommit", target |-> block]]
    /\ persisted' = [persisted EXCEPT ![s].hasVoted[r] =
        [phase |-> "precommit", target |-> block]]
    /\ UNCHANGED <<blockVars, finalVars, authVars, raceVars,
                   prevotes, equivocators, currentRound, roundBase, limitVars, crashed>>

\* CompleteRound: Mark a round as completed
\* environment.rs:976-1036 — completed()
\* Bug Family 4: Round completion and next round start
CompleteRound(s, r) ==
    /\ ~crashed[s]
    \* import.rs:324 — voter is paused when forced change is pending
    /\ pendingForced[s] = {}
    /\ r = currentRound[s]
    /\ roundPhase[s][r] = "precommitted"
    \* Round is completable: precommit supermajority exists
    /\ \E b \in Block : HasPrecommitSupermajority(r, b)
    /\ roundPhase' = [roundPhase EXCEPT ![s][r] = "completed"]
    \* environment.rs:1023 — start tracking next round
    /\ currentRound' = [currentRound EXCEPT ![s] = r + 1]
    \* voter/mod.rs:809-833 — completed_best_round updates last_finalized_in_rounds
    \* to the round's estimate (committed block). Next round's votes must descend from it.
    /\ LET committedBlocks == {b \in Block : HasPrecommitSupermajority(r, b)}
           maxB == CHOOSE b \in committedBlocks : \A b2 \in committedBlocks : b >= b2
       IN roundBase' = [roundBase EXCEPT ![s] = IF maxB > @ THEN maxB ELSE @]
    /\ UNCHANGED <<blockVars, finalVars, authVars, raceVars, equivVars,
                   hasVoted, limitVars, crashVars>>

\* ----------------------------------------------------------------
\* Equivocation actions (Bug Family 3)
\* Byzantine voter casts conflicting votes
\* finality-grandpa PR #5 — equivocated votes double-counted
\* finality-grandpa PR #36 — equivocators must be treated as "voting for everything"
\* ----------------------------------------------------------------

\* ByzantinePrevote: Byzantine server casts a (possibly equivocating) prevote
ByzantinePrevote(s, r, block) ==
    /\ ~crashed[s]
    /\ s \in Byzantine
    /\ r <= MaxRound
    /\ block \in Block
    /\ blockTree[block] /= NilBlock
    /\ prevotes' = [prevotes EXCEPT ![s][r] = @ \cup {block}]
    \* If already voted for a different block, mark as equivocator
    /\ IF prevotes[s][r] /= {} /\ block \notin prevotes[s][r]
       THEN equivocators' = [equivocators EXCEPT ![r] = @ \cup {s}]
       ELSE UNCHANGED equivocators
    /\ UNCHANGED <<blockVars, finalVars, authVars, raceVars, precommits,
                   roundVars, limitVars, crashVars>>

\* ByzantinePrecommit: Byzantine server casts a (possibly equivocating) precommit
ByzantinePrecommit(s, r, block) ==
    /\ ~crashed[s]
    /\ s \in Byzantine
    /\ r <= MaxRound
    /\ block \in Block
    /\ blockTree[block] /= NilBlock
    /\ precommits' = [precommits EXCEPT ![s][r] = @ \cup {block}]
    /\ IF precommits[s][r] /= {} /\ block \notin precommits[s][r]
       THEN equivocators' = [equivocators EXCEPT ![r] = @ \cup {s}]
       ELSE UNCHANGED equivocators
    /\ UNCHANGED <<blockVars, finalVars, authVars, raceVars, prevotes,
                   roundVars, limitVars, crashVars>>

\* ----------------------------------------------------------------
\* Crash and Recovery (Families 2, 4)
\* ----------------------------------------------------------------

\* Crash: Server crashes, losing volatile state
Crash(s) ==
    /\ ~crashed[s]
    /\ crashed' = [crashed EXCEPT ![s] = TRUE]
    \* Release any held lock
    /\ authSetLock' = [authSetLock EXCEPT ![s] = "free"]
    /\ finalizationStep' = [finalizationStep EXCEPT ![s] = 0]
    /\ finalizingBlock' = [finalizingBlock EXCEPT ![s] = NilBlock]
    /\ finalizingPath' = [finalizingPath EXCEPT ![s] = "none"]
    /\ UNCHANGED <<blockVars, finalVars, authVars, equivVars, roundVars, limitVars, persisted>>

\* Recover: Server recovers from crash, restoring persisted state
\* environment.rs HasVoted recovery — environment.rs:735-743
\* aux_schema.rs:362-380 — missing set_state causes round 0 restart
Recover(s) ==
    /\ crashed[s]
    /\ crashed' = [crashed EXCEPT ![s] = FALSE]
    \* Restore from persisted state
    /\ finalizedBlock' = [finalizedBlock EXCEPT ![s] = persisted[s].finalizedBlock]
    /\ currentAuthorities' = [currentAuthorities EXCEPT ![s] = persisted[s].authorities]
    /\ setId' = [setId EXCEPT ![s] = persisted[s].setId]
    \* Restore hasVoted for equivocation prevention — environment.rs:735-743
    /\ hasVoted' = [hasVoted EXCEPT ![s] = persisted[s].hasVoted]
    \* Re-populate pending changes from on-chain data (changeRecord)
    \* Implementation re-discovers changes by re-importing blocks on recovery
    /\ LET recPS == {[block |-> b, delay |-> changeRecord[b].delay,
                      newAuth |-> changeRecord[b].newAuth] :
                     b \in {b2 \in Block :
                        /\ changeRecord[b2].type = "standard"
                        /\ blockTree[b2] /= NilBlock}}
       IN /\ pendingStandard' = [pendingStandard EXCEPT ![s] = recPS]
          /\ voteLimit' = [voteLimit EXCEPT ![s] =
              ComputeVoteLimitOf(recPS, persisted[s].finalizedBlock)]
    /\ pendingForced' = [pendingForced EXCEPT ![s] =
        {[block |-> b, delay |-> changeRecord[b].delay,
          newAuth |-> changeRecord[b].newAuth,
          medianFinalized |-> changeRecord[b].medFin] :
         b \in {b2 \in Block :
            /\ changeRecord[b2].type = "forced"
            /\ blockTree[b2] /= NilBlock}}]
    \* Round state reset — volatile
    /\ roundPhase' = [roundPhase EXCEPT ![s] =
        [r \in 1..MaxRound |->
            IF persisted[s].hasVoted[r].phase /= "none"
            THEN persisted[s].hasVoted[r].phase \* restore from HasVoted
            ELSE "idle"]]
    \* aux_schema.rs:362-380 — restart at round 1 if set_state missing
    /\ currentRound' = [currentRound EXCEPT ![s] = 1]
    \* On recovery, round base resets to persisted finalized block
    /\ roundBase' = [roundBase EXCEPT ![s] = persisted[s].finalizedBlock]
    /\ UNCHANGED <<blockVars, raceVars, equivVars, persisted>>

----
\* ================================================================
\* Next state relation
\* ================================================================

Next ==
    \/ \E s \in Server, parent \in Block \cup {0}, b \in Block :
        ProduceBlock(s, parent, b)
    \/ \E s \in Server, b \in Block, d \in 0..3, auth \in SUBSET Server :
        auth /= {} /\ AddStandardChange(s, b, d, auth)
    \/ \E s \in Server, b \in Block, d \in 0..3, auth \in SUBSET Server, mf \in 0..MaxBlock :
        auth /= {} /\ AddForcedChange(s, b, d, auth, mf)
    \/ \E s \in Server : ApplyStandardChange(s)
    \/ \E s \in Server : ApplyForcedChange(s)
    \* Finalization sub-steps (Bug Family 2)
    \/ \E s \in Server, b \in Block, p \in {"gossip", "sync"} :
        AcquireFinalizationLock(s, b, p)
    \/ \E s \in Server : ApplyFinalizationChanges(s)
    \/ \E s \in Server : WriteToDisk(s)
    \/ \E s \in Server : ReleaseFinalizationLock(s)
    \* Atomic finalization (when not modeling races)
    \/ \E s \in Server, b \in Block : FinalizeBlock(s, b)
    \* Round state machine (Bug Family 4)
    \/ \E s \in Server, r \in 1..MaxRound, b \in Block : Propose(s, r, b)
    \/ \E s \in Server, r \in 1..MaxRound, b \in Block : Prevote(s, r, b)
    \/ \E s \in Server, r \in 1..MaxRound, b \in Block : Precommit(s, r, b)
    \/ \E s \in Server, r \in 1..MaxRound : CompleteRound(s, r)
    \* Equivocation (Bug Family 3)
    \/ \E s \in Server, r \in 1..MaxRound, b \in Block : ByzantinePrevote(s, r, b)
    \/ \E s \in Server, r \in 1..MaxRound, b \in Block : ByzantinePrecommit(s, r, b)
    \* Crash/Recovery
    \/ \E s \in Server : Crash(s)
    \/ \E s \in Server : Recover(s)

----
\* ================================================================
\* Invariants
\* ================================================================

\* Standard: Finalization Safety — if block B is finalized, all future finalized
\* blocks are descendants of B (Bug Families 1-3)
FinalizationSafety ==
    \A s1, s2 \in Server :
        /\ ~crashed[s1] /\ ~crashed[s2]
        /\ finalizedBlock[s1] > 0 /\ finalizedBlock[s2] > 0
        => \/ IsAncestor(finalizedBlock[s1], finalizedBlock[s2], blockTree)
           \/ IsAncestor(finalizedBlock[s2], finalizedBlock[s1], blockTree)

\* Extension: Election Safety — at most one authority set active per set_id
\* Bug Family 1
ElectionSafety ==
    \A s1, s2 \in Server :
        /\ ~crashed[s1] /\ ~crashed[s2]
        /\ setId[s1] = setId[s2]
        => currentAuthorities[s1] = currentAuthorities[s2]

\* Extension: Authority Set Consistency — all honest nodes agree on auth set for a set_id
\* Bug Family 1
AuthoritySetConsistency ==
    \A s1, s2 \in Server :
        /\ ~crashed[s1] /\ ~crashed[s2]
        /\ IsHonest(s1) /\ IsHonest(s2)
        /\ setId[s1] = setId[s2]
        => currentAuthorities[s1] = currentAuthorities[s2]

\* Extension: Vote Limit Respected — no honest voter votes past pending change boundary
\* Bug Family 5, authorities.rs:423-429
VoteLimitRespected ==
    \A s \in Server, r \in 1..MaxRound :
        /\ ~crashed[s] /\ IsHonest(s)
        => /\ \A b \in prevotes[s][r] : b <= voteLimit[s]
           /\ \A b \in precommits[s][r] : b <= voteLimit[s]

\* Extension: No Prevote Skip — must prevote before precommitting
\* Bug Family 4, environment.rs:948
NoPrevoteSkip ==
    \A s \in Server, r \in 1..MaxRound :
        /\ ~crashed[s] /\ IsHonest(s)
        /\ roundPhase[s][r] = "precommitted"
        => prevotes[s][r] /= {}

\* Extension: Forced Change Dependency — forced change not applied until
\* dependent standard changes are satisfied
\* Bug Family 1, authorities.rs:478-492
ForcedChangeDependency ==
    \A s \in Server :
        ~crashed[s] =>
        \A fc \in pendingForced[s] :
            EffectiveNumber(fc) <= bestBlock[s]
            /\ IsAncestor(fc.block, bestBlock[s], blockTree)
            => ForcedChangeDepsOk(s, fc)

\* Extension: Standard Change Ordering — standard changes on finalized chain applied
\* in ancestor-before-descendant order
\* Bug Family 1
\* Only applies to changes on the finalized chain; changes on other branches are
\* pruned during ApplyStandardChange and don't need ordering.
StandardChangeOrdering ==
    \A s \in Server :
        ~crashed[s] =>
        \A c1, c2 \in pendingStandard[s] :
            /\ c1 /= c2
            /\ IsAncestor(c1.block, c2.block, blockTree)
            /\ IF finalizedBlock[s] = 0 THEN FALSE
               ELSE IsAncestor(c2.block, finalizedBlock[s], blockTree)
            /\ EffectiveNumber(c1) <= finalizedBlock[s]
            => EffectiveNumber(c2) > finalizedBlock[s]

\* Structural: Finalized block is on the block tree
FinalizedBlockExists ==
    \A s \in Server :
        ~crashed[s] =>
        IF finalizedBlock[s] = 0 THEN TRUE ELSE blockTree[finalizedBlock[s]] /= NilBlock

\* Structural: Current round is within bounds
RoundInBounds ==
    \A s \in Server : currentRound[s] >= 1 /\ currentRound[s] <= MaxRound + 1

\* Extension: Equivocation Correctness — equivocators counted as voting for all blocks
\* Bug Family 3
EquivocationCorrectness ==
    \A s \in Server, r \in 1..MaxRound :
        /\ ~crashed[s]
        /\ s \in equivocators[r]
        => Cardinality(prevotes[s][r]) >= 2 \/ Cardinality(precommits[s][r]) >= 2

=============================================================================
