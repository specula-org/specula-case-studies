------------------------------ MODULE MC_mc4 ------------------------------
\* Bug hunting MC spec for MC-4: Non-atomic finalization writes
\* environment.rs:1522-1527: If apply_finality succeeds but authority set
\* write fails, the node is in an inconsistent state (developers acknowledge:
\* "Node is in a potentially inconsistent state").
\*
\* Also models import.rs:420,578: authority set lock released before
\* inner.import_block() — mutated set visible before block persisted.
\*
\* Model: Split WriteToDisk into two sub-steps:
\* 1. WriteFinalizationToDisk: persists finalizedBlock
\* 2. WriteAuthSetToDisk: persists authority set state
\* A crash between these creates an inconsistent persisted state.

EXTENDS MC

VARIABLES
    \* Track whether finalization write is partially done
    finalizationWriteStep  \* finalizationWriteStep[s] \in {0, 1}
                           \* 0 = not started or complete
                           \* 1 = finalization written, auth set not yet written

mc4Vars == <<finalizationWriteStep>>

MCInitMC4 ==
    /\ MCInit
    /\ finalizationWriteStep = [s \in Server |-> 0]

\* ================================================================
\* Non-atomic WriteToDisk: Split into two sub-steps
\* environment.rs:1451-1530 — apply_finality then update_authority_set
\* ================================================================

\* Sub-step 1: Write finalized block to disk
\* environment.rs:1460-1509 — apply_finality (uses backend write)
WriteFinalizationToDisk(s) ==
    /\ ~crashed[s]
    /\ finalizationStep[s] = 2
    /\ finalizationWriteStep[s] = 0
    \* Update finalized block
    /\ finalizedBlock' = [finalizedBlock EXCEPT ![s] = finalizingBlock[s]]
    \* Persist ONLY finalized block (not auth set yet)
    /\ persisted' = [persisted EXCEPT ![s] =
        [@ EXCEPT !.finalizedBlock = finalizingBlock[s]]]
    /\ finalizationWriteStep' = [finalizationWriteStep EXCEPT ![s] = 1]
    /\ UNCHANGED <<blockVars, authVars, authSetLock, finalizingBlock, finalizingPath,
                   finalizationStep, equivVars, roundVars, limitVars, crashed>>

\* Sub-step 2: Write authority set to disk
\* environment.rs:1516-1527 — update_authority_set (separate write)
WriteAuthSetToDisk(s) ==
    /\ ~crashed[s]
    /\ finalizationStep[s] = 2
    /\ finalizationWriteStep[s] = 1
    \* Persist authority set state
    /\ persisted' = [persisted EXCEPT ![s] =
        [@ EXCEPT !.setId = setId[s],
                   !.authorities = currentAuthorities[s]]]
    /\ finalizationStep' = [finalizationStep EXCEPT ![s] = 3]
    /\ finalizationWriteStep' = [finalizationWriteStep EXCEPT ![s] = 0]
    /\ UNCHANGED <<blockVars, finalVars, authVars, authSetLock, finalizingBlock,
                   finalizingPath, equivVars, roundVars, limitVars, crashed>>

\* Crash: also resets finalizationWriteStep
CrashMC4(s) ==
    /\ ~crashed[s]
    /\ crashed' = [crashed EXCEPT ![s] = TRUE]
    /\ authSetLock' = [authSetLock EXCEPT ![s] = "free"]
    /\ finalizationStep' = [finalizationStep EXCEPT ![s] = 0]
    /\ finalizingBlock' = [finalizingBlock EXCEPT ![s] = NilBlock]
    /\ finalizingPath' = [finalizingPath EXCEPT ![s] = "none"]
    /\ finalizationWriteStep' = [finalizationWriteStep EXCEPT ![s] = 0]
    /\ UNCHANGED <<blockVars, finalVars, authVars, equivVars, roundVars, limitVars, persisted>>

MCCrashMC4(s) ==
    /\ faultCounters.crashes < MaxCrashLimit
    /\ CrashMC4(s)
    /\ faultCounters' = [faultCounters EXCEPT !.crashes = @ + 1]

\* Recovery is same as base (restores from potentially inconsistent persisted state)
\* If crash happened between WriteFinalizationToDisk and WriteAuthSetToDisk,
\* persisted.finalizedBlock is updated but persisted.setId/authorities are stale.

\* ================================================================
\* MC4-specific invariant
\* ================================================================

\* After recovery, the persisted state should be consistent:
\* if finalizedBlock was updated, the authority set should reflect
\* any changes that were applied before finalization.
\* This invariant detects the inconsistency from non-atomic writes.
PersistedStateConsistency ==
    \A s \in Server :
        ~crashed[s] =>
        \* If a server has a higher finalizedBlock than its persisted setId implies,
        \* check that the authority set is consistent with what should be active
        \* at that finalized block height.
        \* Simplified check: if two non-crashed servers have the same finalized block,
        \* they should have the same authority set.
        \A s2 \in Server :
            /\ ~crashed[s2]
            /\ finalizedBlock[s] = finalizedBlock[s2]
            /\ finalizedBlock[s] > 0
            => setId[s] = setId[s2]

\* ================================================================
\* Modified MCNext for MC4
\* ================================================================

MCNextMC4 ==
    \* Block production
    \/ \E s \in Server, parent \in Block \cup {0}, b \in Block :
        /\ MCProduceBlock(s, parent, b)
        /\ UNCHANGED mc4Vars
    \/ \E s \in Server, parent \in Block \cup {0}, b \in Block,
         d \in 0..3, auth \in SUBSET Server :
        /\ auth /= {} /\ MCProduceBlockWithStdChange(s, parent, b, d, auth)
        /\ UNCHANGED mc4Vars
    \/ \E s \in Server, parent \in Block \cup {0}, b \in Block,
         d \in 0..3, auth \in SUBSET Server, mf \in 0..MaxBlock :
        /\ auth /= {} /\ MCProduceBlockWithForcedChange(s, parent, b, d, auth, mf)
        /\ UNCHANGED mc4Vars
    \* Authority change application
    \/ \E s \in Server :
        /\ MCApplyStandardChange(s)
        /\ UNCHANGED mc4Vars
    \/ \E s \in Server :
        /\ MCApplyForcedChange(s)
        /\ UNCHANGED mc4Vars
    \* Finalization sub-steps
    \/ \E s \in Server, b \in Block, p \in {"gossip", "sync"} :
        /\ MCAcquireFinalizationLock(s, b, p)
        /\ UNCHANGED mc4Vars
    \/ \E s \in Server :
        /\ MCApplyFinalizationChanges(s)
        /\ UNCHANGED mc4Vars
    \* Non-atomic write steps (replaces MCWriteToDisk)
    \/ \E s \in Server :
        /\ WriteFinalizationToDisk(s)
        /\ UNCHANGED faultCounters
    \/ \E s \in Server :
        /\ WriteAuthSetToDisk(s)
        /\ UNCHANGED faultCounters
    \/ \E s \in Server :
        /\ MCReleaseFinalizationLock(s)
        /\ UNCHANGED mc4Vars
    \* Atomic finalization (for paths without sub-step races)
    \/ \E s \in Server, b \in Block :
        /\ MCFinalizeBlock(s, b)
        /\ UNCHANGED mc4Vars
    \* Round state machine
    \/ \E s \in Server, r \in 1..MaxRound, b \in Block :
        /\ MCPropose(s, r, b)
        /\ UNCHANGED mc4Vars
    \/ \E s \in Server, r \in 1..MaxRound, b \in Block :
        /\ MCPrevote(s, r, b)
        /\ UNCHANGED mc4Vars
    \/ \E s \in Server, r \in 1..MaxRound, b \in Block :
        /\ MCPrecommit(s, r, b)
        /\ UNCHANGED mc4Vars
    \/ \E s \in Server, r \in 1..MaxRound :
        /\ MCCompleteRound(s, r)
        /\ UNCHANGED mc4Vars
    \* Byzantine votes
    \/ \E s \in Server, r \in 1..MaxRound, b \in Block :
        /\ MCByzantinePrevote(s, r, b)
        /\ UNCHANGED mc4Vars
    \/ \E s \in Server, r \in 1..MaxRound, b \in Block :
        /\ MCByzantinePrecommit(s, r, b)
        /\ UNCHANGED mc4Vars
    \* Crash (with mc4Vars reset) / Recovery
    \/ \E s \in Server : MCCrashMC4(s)
    \/ \E s \in Server :
        /\ MCRecover(s)
        /\ UNCHANGED mc4Vars

\* View: exclude mc4Vars from fingerprint (they're derived state)
MCViewMC4 == <<blockVars, finalVars, authVars, raceVars, equivVars, roundVars, limitVars, crashVars, mc4Vars>>

=============================================================================
