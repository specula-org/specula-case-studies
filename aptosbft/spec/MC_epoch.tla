--------------------------- MODULE MC_epoch ---------------------------
(*
 * Extended model checking wrapper for Aptos BFT — Epoch boundary bugs.
 *
 * Tests MC-3 and MC-5 by modeling the release-build behavior where
 * debug_assert epoch checks are compiled out.
 *
 * Adds two "weak epoch" receive actions:
 *   - ReceiveTimeoutWeakEpoch: timeout_2chain.rs:248-257 debug_assert compiled out
 *   - ReceiveOrderVoteWeakEpoch: order vote epoch validation bypass
 *
 * These model the scenario where the upper-layer epoch check is bypassed
 * or the debug_assert at the aggregation level (the last line of defense)
 * is compiled out in release builds.
 *)

EXTENDS MC

\* ============================================================================
\* CONSTANT: control weak-epoch actions
\* ============================================================================

CONSTANT MaxWeakEpochLimit   \* Max number of weak-epoch receives

\* ============================================================================
\* VARIABLE: counter for weak-epoch actions
\* ============================================================================

VARIABLE weakEpochCount

epochVars == <<weakEpochCount>>

mcEpochAllVars == <<allVars, faultVars, epochVars>>

\* ============================================================================
\* WEAK-EPOCH RECEIVE ACTIONS
\* ============================================================================

\* MC-3: ReceiveTimeout WITHOUT epoch check
\* Models: timeout_2chain.rs:248-257 — debug_assert for epoch compiled out
\* in release builds. The TwoChainTimeoutCertificate::add() method does NOT
\* validate epoch at runtime in release mode.
ReceiveTimeoutWeakEpoch(s, m) ==
    /\ weakEpochCount < MaxWeakEpochLimit
    /\ alive[s] = TRUE
    /\ m \in DOMAIN msgs
    /\ msgs[m] > 0
    /\ m.mtype = TimeoutMsgType
    \* REMOVED: m.mepoch = currentEpoch[s]  — debug_assert compiled out
    /\ m.mround <= MaxRound
    /\ m.mround >= currentRound[s]
    \* Add timeout vote (even though epoch may differ)
    /\ timeoutVotes' = [timeoutVotes EXCEPT ![s][m.mround] =
         timeoutVotes[s][m.mround] \union {m.msrc}]
    /\ Discard(m)
    /\ weakEpochCount' = weakEpochCount + 1
    /\ UNCHANGED <<safetyVars, persistVars, roundVars, certVars,
                    votesForBlock, orderVotesForBlock, commitVotes,
                    pipelineVars, commitVars, blockVars>>
    /\ UNCHANGED faultVars

\* MC-5: ReceiveOrderVote WITHOUT epoch check
\* Models: order vote processing path where epoch validation is bypassed.
\* In the implementation, the epoch check is in verify_order_vote_proposal
\* (safety_rules.rs:87-111), but if this check is skipped or has a bug,
\* cross-epoch order votes can accumulate.
ReceiveOrderVoteWeakEpoch(s, m) ==
    /\ weakEpochCount < MaxWeakEpochLimit
    /\ alive[s] = TRUE
    /\ m \in DOMAIN msgs
    /\ msgs[m] > 0
    /\ m.mtype = OrderVoteMsgType
    \* REMOVED: m.mepoch = currentEpoch[s]  — epoch check bypassed
    /\ m.mround <= MaxRound
    /\ ~HasQuorum(orderVotesForBlock[s][m.mround])
    /\ m.mround > highestOrderedRound[s]
    /\ m.mround < highestOrderedRound[s] + 100
    \* Add order vote (even though epoch may differ)
    /\ orderVotesForBlock' = [orderVotesForBlock EXCEPT ![s][m.mround] =
         orderVotesForBlock[s][m.mround] \union {m.msrc}]
    /\ Discard(m)
    /\ weakEpochCount' = weakEpochCount + 1
    /\ UNCHANGED <<safetyVars, persistVars, roundVars, certVars,
                    votesForBlock, timeoutVotes, commitVotes,
                    pipelineVars, commitVars, blockVars>>
    /\ UNCHANGED faultVars

\* ============================================================================
\* MC_EPOCH INIT
\* ============================================================================

MCEpochInit ==
    /\ MCInit
    /\ weakEpochCount = 0

\* ============================================================================
\* MC_EPOCH NEXT — extends MCNext with weak-epoch actions
\* ============================================================================

MCEpochNext ==
    \/ (MCNext /\ UNCHANGED epochVars)
    \* --- Weak-epoch actions (MC-3, MC-5) ---
    \/ \E s \in Server, m \in DOMAIN msgs : ReceiveTimeoutWeakEpoch(s, m)
    \/ \E s \in Server, m \in DOMAIN msgs : ReceiveOrderVoteWeakEpoch(s, m)

\* ============================================================================
\* VIEW (excludes counters from state hash)
\* ============================================================================

MCEpochView == <<allVars>>

\* ============================================================================
\* SPECIFICATION
\* ============================================================================

MCEpochSpec == MCEpochInit /\ [][MCEpochNext]_mcEpochAllVars

=============================================================================
