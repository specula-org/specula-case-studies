--------------------------- MODULE MC ---------------------------
(*
 * Model checking wrapper for Aptos BFT (2-chain HotStuff / Jolteon).
 *
 * Wraps base.tla with counter-bounded fault-injection actions,
 * symmetry reduction, and structural invariants.
 *
 * Counter-bounded (fault-injection) actions:
 *   - Timeout, Crash, CrashBetweenSignAndPersist, DropMessage,
 *     TriggerSync, EpochChange
 *
 * Unconstrained (deterministic/reactive) actions:
 *   - Propose, ReceiveProposal, CastVote, ReceiveVote, FormQC,
 *     CastOrderVote, ReceiveOrderVote, FormOrderingCert,
 *     ReceiveTimeout, FormTC, SignCommitVote, ReceiveCommitVote,
 *     ExecuteBlock, AggregateCommitVotes, PersistBlock, ResetPipeline,
 *     Recover
 *)

EXTENDS base

\* ============================================================================
\* MC CONSTANTS — counter limits
\* ============================================================================

CONSTANT MaxTimeoutLimit       \* Max number of timeout actions
CONSTANT MaxCrashLimit         \* Max crash (clean) actions
CONSTANT MaxCrashPersistLimit  \* Max crash-between-sign-and-persist
CONSTANT MaxDropLimit          \* Max message drops
CONSTANT MaxSyncLimit          \* Max TriggerSync actions
CONSTANT MaxEpochChangeLimit   \* Max epoch changes
CONSTANT MaxMsgBufferLimit     \* Max messages in bag (state space prune)

\* ============================================================================
\* MC VARIABLES — fault counters
\* ============================================================================

VARIABLE timeoutCount
VARIABLE crashCount
VARIABLE crashPersistCount
VARIABLE dropCount
VARIABLE syncCount
VARIABLE epochChangeCount

faultVars == <<timeoutCount, crashCount, crashPersistCount,
               dropCount, syncCount, epochChangeCount>>

mcAllVars == <<allVars, faultVars>>

\* ============================================================================
\* MC INIT
\* ============================================================================

MCInit ==
    /\ Init
    /\ timeoutCount      = 0
    /\ crashCount         = 0
    /\ crashPersistCount  = 0
    /\ dropCount          = 0
    /\ syncCount          = 0
    /\ epochChangeCount   = 0

\* ============================================================================
\* COUNTER-BOUNDED WRAPPERS (fault-injection actions)
\* ============================================================================

MCSignTimeout(s) ==
    /\ timeoutCount < MaxTimeoutLimit
    /\ SignTimeout(s)
    /\ timeoutCount' = timeoutCount + 1
    /\ UNCHANGED <<crashCount, crashPersistCount, dropCount,
                    syncCount, epochChangeCount>>

MCCrash(s) ==
    /\ crashCount < MaxCrashLimit
    /\ Crash(s)
    /\ crashCount' = crashCount + 1
    /\ UNCHANGED <<timeoutCount, crashPersistCount, dropCount,
                    syncCount, epochChangeCount>>

MCCrashBetweenSignAndPersist(s) ==
    /\ crashPersistCount < MaxCrashPersistLimit
    /\ CrashBetweenSignAndPersist(s)
    /\ crashPersistCount' = crashPersistCount + 1
    /\ UNCHANGED <<timeoutCount, crashCount, dropCount,
                    syncCount, epochChangeCount>>

MCDropMessage(m) ==
    /\ dropCount < MaxDropLimit
    /\ DropMessage(m)
    /\ dropCount' = dropCount + 1
    /\ UNCHANGED <<timeoutCount, crashCount, crashPersistCount,
                    syncCount, epochChangeCount>>

MCTriggerSync(s) ==
    /\ syncCount < MaxSyncLimit
    /\ TriggerSync(s)
    /\ syncCount' = syncCount + 1
    /\ UNCHANGED <<timeoutCount, crashCount, crashPersistCount,
                    dropCount, epochChangeCount>>

MCEpochChange(s) ==
    /\ epochChangeCount < MaxEpochChangeLimit
    /\ EpochChange(s)
    /\ epochChangeCount' = epochChangeCount + 1
    /\ UNCHANGED <<timeoutCount, crashCount, crashPersistCount,
                    dropCount, syncCount>>

\* ============================================================================
\* UNCONSTRAINED WRAPPERS (deterministic/reactive actions)
\* These pass through with UNCHANGED faultVars.
\* ============================================================================

MCPropose(s, v) ==
    /\ Propose(s, v)
    /\ UNCHANGED faultVars

MCReceiveProposal(s, m) ==
    /\ ReceiveProposal(s, m)
    /\ UNCHANGED faultVars

MCCastVote(s) ==
    /\ CastVote(s)
    /\ UNCHANGED faultVars

MCReceiveVote(s, m) ==
    /\ ReceiveVote(s, m)
    /\ UNCHANGED faultVars

MCFormQC(s, r) ==
    /\ FormQC(s, r)
    /\ UNCHANGED faultVars

MCCastOrderVote(s, r) ==
    /\ CastOrderVote(s, r)
    /\ UNCHANGED faultVars

MCReceiveOrderVote(s, m) ==
    /\ ReceiveOrderVote(s, m)
    /\ UNCHANGED faultVars

MCFormOrderingCert(s, r) ==
    /\ FormOrderingCert(s, r)
    /\ UNCHANGED faultVars

MCReceiveTimeout(s, m) ==
    /\ ReceiveTimeout(s, m)
    /\ UNCHANGED faultVars

MCFormTC(s, r) ==
    /\ FormTC(s, r)
    /\ UNCHANGED faultVars

MCSignCommitVote(s, r) ==
    /\ SignCommitVote(s, r)
    /\ UNCHANGED faultVars

MCReceiveCommitVote(s, m) ==
    /\ ReceiveCommitVote(s, m)
    /\ UNCHANGED faultVars

MCExecuteBlock(s, r) ==
    /\ ExecuteBlock(s, r)
    /\ UNCHANGED faultVars

MCAggrCommitVotes(s, r) ==
    /\ AggregateCommitVotes(s, r)
    /\ UNCHANGED faultVars

MCPersistBlock(s, r) ==
    /\ PersistBlock(s, r)
    /\ UNCHANGED faultVars

MCResetPipeline(s) ==
    /\ ResetPipeline(s)
    /\ UNCHANGED faultVars

MCRecover(s) ==
    /\ Recover(s)
    /\ UNCHANGED faultVars

\* ============================================================================
\* MC NEXT
\* ============================================================================

MCNext ==
    \* --- Proposal ---
    \/ \E s \in Server, v \in Values : MCPropose(s, v)
    \/ \E s \in Server, m \in DOMAIN msgs : MCReceiveProposal(s, m)
    \* --- Regular voting ---
    \/ \E s \in Server : MCCastVote(s)
    \/ \E s \in Server, m \in DOMAIN msgs : MCReceiveVote(s, m)
    \/ \E s \in Server, r \in 1..MaxRound : MCFormQC(s, r)
    \* --- Order voting (Family 1,2) ---
    \/ \E s \in Server, r \in 1..MaxRound : MCCastOrderVote(s, r)
    \/ \E s \in Server, m \in DOMAIN msgs : MCReceiveOrderVote(s, m)
    \/ \E s \in Server, r \in 1..MaxRound : MCFormOrderingCert(s, r)
    \* --- Timeout (bounded) ---
    \/ \E s \in Server : MCSignTimeout(s)
    \/ \E s \in Server, m \in DOMAIN msgs : MCReceiveTimeout(s, m)
    \/ \E s \in Server, r \in 1..MaxRound : MCFormTC(s, r)
    \* --- Commit vote (Family 1) ---
    \/ \E s \in Server, r \in 1..MaxRound : MCSignCommitVote(s, r)
    \/ \E s \in Server, m \in DOMAIN msgs : MCReceiveCommitVote(s, m)
    \* --- Pipeline (Family 3) ---
    \/ \E s \in Server, r \in 1..MaxRound : MCExecuteBlock(s, r)
    \/ \E s \in Server, r \in 1..MaxRound : MCAggrCommitVotes(s, r)
    \/ \E s \in Server, r \in 1..MaxRound : MCPersistBlock(s, r)
    \/ \E s \in Server : MCResetPipeline(s)
    \* --- Sync (bounded) ---
    \/ \E s \in Server : MCTriggerSync(s)
    \* --- Epoch (bounded, Family 5) ---
    \/ \E s \in Server : MCEpochChange(s)
    \* --- Crash/Recovery (bounded, Family 4) ---
    \/ \E s \in Server : MCCrash(s)
    \/ \E s \in Server : MCRecover(s)
    \/ \E s \in Server : MCCrashBetweenSignAndPersist(s)
    \* --- Network (bounded) ---
    \/ \E m \in DOMAIN msgs : MCDropMessage(m)

\* ============================================================================
\* SYMMETRY & VIEW
\* ============================================================================

MCSymmetry == Permutations(Server)

\* View excludes fault counters from state hash (symmetry-compatible)
MCView == <<allVars>>

\* ============================================================================
\* STATE SPACE CONSTRAINT
\* ============================================================================

\* Prune states where message bag exceeds limit
MsgBufferConstraint ==
    BagCardinality(msgs) <= MaxMsgBufferLimit

\* ============================================================================
\* STRUCTURAL INVARIANTS (sanity checks)
\* ============================================================================

\* Current round is always positive
RoundPositive ==
    \A s \in Server : currentRound[s] >= 1

\* QC round never exceeds current round
QCRoundBound ==
    \A s \in Server : highestQCRound[s] < currentRound[s]

\* TC round never exceeds current round
TCRoundBound ==
    \A s \in Server : highestTCRound[s] < currentRound[s]

\* last_voted_round <= current round
LVRBound ==
    \A s \in Server :
        alive[s] = TRUE => lastVotedRound[s] <= currentRound[s]

\* ============================================================================
\* TEMPORAL PROPERTIES
\* ============================================================================

\* Liveness: if a proposal exists and enough servers are alive, eventually committed
\* (requires fairness; useful with -simulate)
TimeoutLiveness ==
    \A s \in Server, r \in 1..MaxRound :
        (HasQuorum(timeoutVotes[s][r]) ~> highestTCRound[s] >= r)

OrderVoteLiveness ==
    \A s \in Server, r \in 1..MaxRound :
        (HasQuorum(votesForBlock[s][r]) /\ (\A t \in Server : alive[t] = TRUE)
         ~> HasQuorum(orderVotesForBlock[s][r]))

\* ============================================================================
\* SPECIFICATION
\* ============================================================================

MCSpec == MCInit /\ [][MCNext]_mcAllVars

=============================================================================
