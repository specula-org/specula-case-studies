-------------------------------- MODULE MC --------------------------------
\* Model Checking Spec for besu QBFT.
\*
\* Wraps the base spec with counter-bounded actions for
\* exhaustive state-space exploration via TLC.
\*
\* Scenarios covered:
\*   - Block timer expiry and round 0 proposal
\*   - Round expiry and round change protocol (2f+1 and f+1)
\*   - Re-proposal with hash reconstruction (Family 1)
\*   - Timer/import race conditions (Family 2)
\*   - Crash / recovery
\*   - Message loss
\*   - Block import failure with committed latch (Family 5)

EXTENDS base

\* Access original (un-overridden) operator definitions.
qbft == INSTANCE base

\* ============================================================================
\* SERVER CONSTANTS (for round-robin proposer)
\* ============================================================================

CONSTANTS s1, s2, s3, s4

\* Round-robin proposer matching besu implementation.
\* validators[(height + round) % n]
MCProposer(h, r) ==
    LET serverSeq == <<s1, s2, s3, s4>>
        idx == ((h + r) % Cardinality(Server)) + 1
    IN serverSeq[idx]

\* ============================================================================
\* CONSTRAINT CONSTANTS
\* ============================================================================

\* Max round number (prevents infinite round changes)
CONSTANT MaxRoundLimit
ASSUME MaxRoundLimit \in Nat

\* Total round expiry events (bounds round change messages)
CONSTANT MaxRoundExpiryLimit
ASSUME MaxRoundExpiryLimit \in Nat

\* Crash/restart limits
CONSTANT CrashLimit
ASSUME CrashLimit \in Nat

\* Message loss limits
CONSTANT LoseLimit
ASSUME LoseLimit \in Nat

\* Block timer expiry limits
CONSTANT BlockTimerLimit
ASSUME BlockTimerLimit \in Nat

\* Message buffer limit for state space pruning
CONSTANT MaxMsgBufferLimit
ASSUME MaxMsgBufferLimit \in Nat

\* ============================================================================
\* CONSTRAINT VARIABLES
\* ============================================================================

\* Counters for bounded actions (aggregated in a record)
VARIABLE constraintCounters

faultVars == <<constraintCounters>>

\* ============================================================================
\* MODEL CHECKING CONSTRAINED ACTIONS
\* ============================================================================

\* --- Block Timer Constraints ---
MCBlockTimerExpiry(s) ==
    /\ constraintCounters.blockTimer < BlockTimerLimit
    /\ qbft!BlockTimerExpiry(s)
    /\ constraintCounters' = [constraintCounters EXCEPT !.blockTimer = @ + 1]

\* --- Round Expiry Constraints ---
MCRoundExpiry(s) ==
    /\ currentRound[s] /= Nil
    /\ currentRound[s] < MaxRoundLimit
    /\ constraintCounters.roundExpiry < MaxRoundExpiryLimit
    /\ qbft!RoundExpiry(s)
    /\ constraintCounters' = [constraintCounters EXCEPT !.roundExpiry = @ + 1]

\* --- Crash Constraints ---
MCCrash(s) ==
    /\ constraintCounters.crash < CrashLimit
    /\ qbft!Crash(s)
    /\ constraintCounters' = [constraintCounters EXCEPT !.crash = @ + 1]

\* --- Message Loss Constraints ---
MCLoseMessage(m) ==
    /\ constraintCounters.lose < LoseLimit
    /\ qbft!LoseMessage(m)
    /\ constraintCounters' = [constraintCounters EXCEPT !.lose = @ + 1]

\* ============================================================================
\* INITIALIZATION
\* ============================================================================

MCInit ==
    /\ Init
    /\ constraintCounters = [
         blockTimer  |-> 0,
         roundExpiry |-> 0,
         crash       |-> 0,
         lose        |-> 0]

\* ============================================================================
\* NEXT STATE RELATIONS
\* ============================================================================

\* MCNextAsync(s) - All async actions for a single server s.
MCNextAsync(s) ==
    \* --- Block timer ---
    \/ MCBlockTimerExpiry(s)
    \* --- Round expiry ---
    \/ MCRoundExpiry(s)
    \* --- New chain head (reactive, not bounded) ---
    \/ /\ qbft!NewChainHead(s)
       /\ UNCHANGED faultVars
    \* --- Recovery (reactive, not bounded) ---
    \/ /\ qbft!Recover(s)
       /\ UNCHANGED faultVars

\* MCNextCrash - Crash events
MCNextCrash == \E s \in Server : MCCrash(s)

\* MCNextMessages - Message handling (reactive, not bounded)
MCNextMessages ==
    \E m \in DOMAIN messages :
        /\ \/ qbft!HandleProposal(m.mdest, m)
           \/ qbft!HandlePrepare(m.mdest, m)
           \/ qbft!HandleCommit(m.mdest, m)
           \/ qbft!HandleRoundChange(m.mdest, m)
           \/ qbft!DropStaleMessage(m)
        /\ UNCHANGED faultVars

\* MCNextUnreliable - Network unreliability
MCNextUnreliable ==
    \E m \in DOMAIN messages :
        \/ MCLoseMessage(m)
        \/ /\ qbft!DropStaleMessage(m)
           /\ UNCHANGED faultVars

\* --- Combined Next ---
MCNext ==
    \/ \E s \in Server : MCNextAsync(s)
    \/ MCNextCrash
    \/ MCNextMessages
    \/ MCNextUnreliable

\* ============================================================================
\* SPECIFICATIONS
\* ============================================================================

mc_vars == <<vars, faultVars>>

MCSpec ==
    /\ MCInit
    /\ [][MCNext]_mc_vars

\* ============================================================================
\* SYMMETRY AND VIEW DEFINITIONS
\* ============================================================================

\* Symmetry set over server IDs for state space reduction.
Symmetry == Permutations(Server)

\* View excludes constraintCounters so states differing only in counters
\* are considered identical.
ModelView == <<vars>>

\* ============================================================================
\* STATE SPACE PRUNING CONSTRAINTS
\* ============================================================================

\* Limit network messages buffer size.
MsgBufferConstraint ==
    \/ MaxMsgBufferLimit = 0
    \/ BagCardinality(messages) <= MaxMsgBufferLimit

\* ============================================================================
\* SAFETY INVARIANTS (complementing base spec invariants)
\* ============================================================================

\* Round number is Nil or a bounded natural.
RoundBoundInv ==
    \A s \in Server : \/ currentRound[s] = Nil
                      \/ (currentRound[s] >= 0 /\ currentRound[s] <= MaxRoundLimit + 1)

\* Blockchain height is monotonically <= current height.
BlockchainHeightBoundInv ==
    \A s \in Server : blockchainHeight[s] < currentHeight[s]
                      \/ (blockImported[s] /\ blockchainHeight[s] = currentHeight[s])

\* Only one server can be proposer for a given (height, round).
\* (Implicit from Proposer function being deterministic.)

\* If a block is imported, blockchain height was updated.
ImportImpliesHeightInv ==
    \A s \in Server :
        (alive[s] /\ blockImported[s]) => blockchainHeight[s] >= currentHeight[s]

\* Committed implies proposal exists.
CommittedImpliesProposalInv ==
    \A s \in Server :
        (alive[s] /\ committed[s]) => ~IsNil(proposedBlock[s])

\* ============================================================================
\* TEMPORAL PROPERTIES
\* ============================================================================

\* Round number never decreases within a height (except after crash/recovery).
\* Guard: Nil -> any round is allowed (block timer starting round 0).
MonotonicRoundProp ==
    [][~(\E s \in Server : qbft!Crash(s)) =>
        \A s \in Server :
            (currentHeight'[s] = currentHeight[s]) =>
                IF currentRound[s] = Nil THEN TRUE
                ELSE currentRound'[s] >= currentRound[s]]_mc_vars

\* Blockchain height never decreases.
MonotonicBlockchainHeightProp ==
    [][\A s \in Server : blockchainHeight'[s] >= blockchainHeight[s]]_mc_vars

=============================================================================
