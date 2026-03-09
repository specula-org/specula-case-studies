------------------------------ MODULE MC_mc7 ------------------------------
\* Bug hunting MC spec for MC-7: HasVoted overwrite on round completion
\* PR #6823 — completed() callback for round N overwrites HasVoted for N+1
\*
\* The real implementation has a race: the voter state machine advances to
\* round N+1 and starts voting before the completed() callback for round N
\* fires. The callback then overwrites HasVoted[N+1] with No. On crash+
\* recovery, the server thinks it hasn't voted in N+1 and re-votes.
\*
\* Model: CompleteRound advances normally. A separate CompletedCallbackOverwrite
\* action fires later, simulating the delayed callback that destroys the vote.

EXTENDS MC

\* ================================================================
\* Helper: map hasVoted phase names to roundPhase names
\* hasVoted uses "prevote"/"precommit" while roundPhase uses "prevoted"/"precommitted"
\* ================================================================
MapPhaseToRoundPhase(p) ==
    CASE p = "precommit" -> "precommitted"
      [] p = "prevote" -> "prevoted"
      [] p = "propose" -> "proposed"
      [] OTHER -> "idle"

\* ================================================================
\* MC-7 Bug Action: Completed callback overwrites HasVoted for next round
\* environment.rs (PR #6823): completed() callback constructs VoterSetState::Live
\* with HasVoted::No for the new round, overwriting any existing vote state.
\*
\* This fires AFTER the server has advanced to round r+1 (CompleteRound)
\* and potentially already voted in round r+1.
\* ================================================================
CompletedCallbackOverwrite(s, r) ==
    /\ ~crashed[s]
    /\ roundPhase[s][r] = "completed"  \* round r has been completed
    /\ r + 1 <= MaxRound
    \* The bug: overwrite HasVoted for the NEXT round with "none"
    \* This models the completed() callback writing VoterSetState::Live
    \* with HasVoted::No for round r+1, destroying any existing vote state.
    /\ hasVoted' = [hasVoted EXCEPT ![s][r + 1] =
                        [phase |-> "none", target |-> NilBlock]]
    /\ persisted' = [persisted EXCEPT ![s].hasVoted[r + 1] =
                        [phase |-> "none", target |-> NilBlock]]
    /\ UNCHANGED <<blockVars, finalVars, authVars, raceVars, equivVars,
                   roundPhase, currentRound, limitVars, crashed>>

MCCompletedCallbackOverwrite(s, r) ==
    /\ CompletedCallbackOverwrite(s, r)
    /\ UNCHANGED faultCounters

\* ================================================================
\* Fixed Recovery: correctly maps hasVoted phases to roundPhase values
\* and resumes at the correct round number.
\*
\* The base Recover action directly copies hasVoted.phase to roundPhase,
\* but the phase names differ (e.g., "precommit" vs "precommitted").
\* This fix maps them correctly.
\* ================================================================
RecoverMC7(s) ==
    /\ crashed[s]
    /\ crashed' = [crashed EXCEPT ![s] = FALSE]
    \* Restore from persisted state
    /\ finalizedBlock' = [finalizedBlock EXCEPT ![s] = persisted[s].finalizedBlock]
    /\ currentAuthorities' = [currentAuthorities EXCEPT ![s] = persisted[s].authorities]
    /\ setId' = [setId EXCEPT ![s] = persisted[s].setId]
    /\ hasVoted' = [hasVoted EXCEPT ![s] = persisted[s].hasVoted]
    \* Re-populate pending changes from on-chain data (same as base Recover)
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
    \* Fixed: correctly map hasVoted phases to roundPhase values
    /\ roundPhase' = [roundPhase EXCEPT ![s] =
        [r \in 1..MaxRound |->
            MapPhaseToRoundPhase(persisted[s].hasVoted[r].phase)]]
    \* Resume at the first round that hasn't been fully voted
    \* In the implementation, the voter set state includes the current round number.
    \* The completed() callback sets the current round to r+1.
    \* After recovery, we resume at the first round with no vote.
    /\ currentRound' = [currentRound EXCEPT ![s] =
        LET votedRounds == {r \in 1..MaxRound :
                             persisted[s].hasVoted[r].phase /= "none"}
        IN IF votedRounds = {}
           THEN 1
           ELSE LET maxVoted == CHOOSE r \in votedRounds :
                        \A r2 \in votedRounds : r >= r2
                IN IF maxVoted < MaxRound THEN maxVoted + 1 ELSE MaxRound + 1]
    /\ UNCHANGED <<blockVars, raceVars, equivVars, persisted>>

MCRecoverMC7(s) ==
    /\ RecoverMC7(s)
    /\ UNCHANGED faultCounters

\* ================================================================
\* Modified MCNext: adds overwrite action + uses fixed recovery
\* Normal CompleteRound is used (no overwrite in CompleteRound itself)
\* The overwrite happens as a separate delayed action
\* ================================================================
MCNextMC7 ==
    \* Block production
    \/ \E s \in Server, parent \in Block \cup {0}, b \in Block :
        MCProduceBlock(s, parent, b)
    \/ \E s \in Server, parent \in Block \cup {0}, b \in Block,
         d \in 0..3, auth \in SUBSET Server :
        auth /= {} /\ MCProduceBlockWithStdChange(s, parent, b, d, auth)
    \/ \E s \in Server, parent \in Block \cup {0}, b \in Block,
         d \in 0..3, auth \in SUBSET Server, mf \in 0..MaxBlock :
        auth /= {} /\ MCProduceBlockWithForcedChange(s, parent, b, d, auth, mf)
    \* Authority change application
    \/ \E s \in Server : MCApplyStandardChange(s)
    \/ \E s \in Server : MCApplyForcedChange(s)
    \* Finalization sub-steps
    \/ \E s \in Server, b \in Block, p \in {"gossip", "sync"} :
        MCAcquireFinalizationLock(s, b, p)
    \/ \E s \in Server : MCApplyFinalizationChanges(s)
    \/ \E s \in Server : MCWriteToDisk(s)
    \/ \E s \in Server : MCReleaseFinalizationLock(s)
    \* Atomic finalization
    \/ \E s \in Server, b \in Block : MCFinalizeBlock(s, b)
    \* Round state machine (normal CompleteRound — no overwrite here)
    \/ \E s \in Server, r \in 1..MaxRound, b \in Block : MCPropose(s, r, b)
    \/ \E s \in Server, r \in 1..MaxRound, b \in Block : MCPrevote(s, r, b)
    \/ \E s \in Server, r \in 1..MaxRound, b \in Block : MCPrecommit(s, r, b)
    \/ \E s \in Server, r \in 1..MaxRound : MCCompleteRound(s, r)
    \* MC-7: Delayed completed callback that overwrites HasVoted (the bug)
    \/ \E s \in Server, r \in 1..MaxRound : MCCompletedCallbackOverwrite(s, r)
    \* Byzantine votes
    \/ \E s \in Server, r \in 1..MaxRound, b \in Block : MCByzantinePrevote(s, r, b)
    \/ \E s \in Server, r \in 1..MaxRound, b \in Block : MCByzantinePrecommit(s, r, b)
    \* Crash/Recovery — use fixed recovery
    \/ \E s \in Server : MCCrash(s)
    \/ \E s \in Server : MCRecoverMC7(s)

\* ================================================================
\* MC-7 specific invariants
\* ================================================================

\* Detect equivocation: an honest server should never have voted for
\* different blocks in the same round (cardinality > 1 means equivocation)
NoHonestEquivocation ==
    \A s \in Server, r \in 1..MaxRound :
        /\ ~crashed[s] /\ IsHonest(s)
        => Cardinality(prevotes[s][r]) <= 1 /\ Cardinality(precommits[s][r]) <= 1

=============================================================================
