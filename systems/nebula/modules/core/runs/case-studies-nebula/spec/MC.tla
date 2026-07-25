---------- MODULE MC ----------
\* Model Checking Spec for vesoft-inc/nebula Raft consensus.
\*
\* Wraps the base spec with counter-bounded actions for exhaustive
\* state-space exploration via TLC.
\*
\* Bug families targeted:
\*   1. Non-persisted term/vote → crash + re-vote (Crash/Restart)
\*   2. Leader lease without CheckQuorum + blind follower (ExpireLease, BlindFollowerTimeout)
\*   3. Snapshot lifecycle race conditions (StartSnapshot/CompleteSnapshot)
\*   4. Separate heartbeat path — no commit advance (SendHeartbeat)
\*   5. Pre-vote with step-down (SendPreVote)

EXTENDS base

\* Access original (un-overridden) operator definitions.
\* Required because cfg uses <- to override operators; without
\* INSTANCE the MC wrappers would recurse into themselves.
baseSpec == INSTANCE base

\* ============================================================================
\* CONSTRAINT CONSTANTS
\* ============================================================================

\* Term limit (prevents infinite state space from repeated elections)
CONSTANT MaxTermLimit
ASSUME MaxTermLimit \in Nat

\* Total timeout events (election start)
CONSTANT MaxTimeoutLimit
ASSUME MaxTimeoutLimit \in Nat

\* Client request limit
CONSTANT RequestLimit
ASSUME RequestLimit \in Nat

\* Crash/restart limit
CONSTANT CrashLimit
ASSUME CrashLimit \in Nat

\* Message loss limit
CONSTANT LoseLimit
ASSUME LoseLimit \in Nat

\* Heartbeat send limit
CONSTANT HeartbeatLimit
ASSUME HeartbeatLimit \in Nat

\* Lease expiry limit (Family 2 fault injection)
CONSTANT LeaseExpiryLimit
ASSUME LeaseExpiryLimit \in Nat

\* Snapshot start limit (Family 3 fault injection)
CONSTANT SnapshotLimit
ASSUME SnapshotLimit \in Nat

\* Pre-vote send limit (Family 5)
CONSTANT PreVoteLimit
ASSUME PreVoteLimit \in Nat

\* Message buffer limit for state space pruning
CONSTANT MaxMsgBufferLimit
ASSUME MaxMsgBufferLimit \in Nat

\* ============================================================================
\* CONSTRAINT VARIABLES
\* ============================================================================

\* Counters for bounded actions (aggregated in a record for simpler View)
VARIABLE cc  \* constraintCounters

faultVars == <<cc>>

\* ============================================================================
\* MODEL CHECKING CONSTRAINED ACTIONS
\* ============================================================================

\* --- Election Constraints ---
MCTimeout(i) ==
    /\ term[i] < MaxTermLimit
    /\ cc.timeout < MaxTimeoutLimit
    /\ baseSpec!Timeout(i)
    /\ cc' = [cc EXCEPT !.timeout = @ + 1]

MCBlindFollowerTimeout(i) ==
    /\ term[i] < MaxTermLimit
    /\ cc.timeout < MaxTimeoutLimit
    /\ baseSpec!BlindFollowerTimeout(i)
    /\ cc' = [cc EXCEPT !.timeout = @ + 1]

MCSendPreVote(i) ==
    /\ cc.preVote < PreVoteLimit
    /\ baseSpec!SendPreVote(i)
    /\ cc' = [cc EXCEPT !.preVote = @ + 1]

\* --- Client Request Constraints ---
MCClientRequest(i) ==
    /\ cc.request < RequestLimit
    /\ baseSpec!ClientRequest(i)
    /\ cc' = [cc EXCEPT !.request = @ + 1]

\* --- Crash/Restart Constraints ---
MCCrash(i) ==
    /\ cc.crash < CrashLimit
    /\ baseSpec!Crash(i)
    /\ cc' = [cc EXCEPT !.crash = @ + 1]

\* --- Message Loss Constraints ---
MCLoseMessage(m) ==
    /\ cc.lose < LoseLimit
    /\ baseSpec!LoseMessage(m)
    /\ cc' = [cc EXCEPT !.lose = @ + 1]

\* --- Heartbeat Constraints ---
MCSendHeartbeat(i, j) ==
    /\ cc.heartbeat < HeartbeatLimit
    /\ baseSpec!SendHeartbeat(i, j)
    /\ cc' = [cc EXCEPT !.heartbeat = @ + 1]

\* --- Lease Expiry Constraints (Family 2) ---
MCExpireLease(i) ==
    /\ cc.leaseExpiry < LeaseExpiryLimit
    /\ baseSpec!ExpireLease(i)
    /\ cc' = [cc EXCEPT !.leaseExpiry = @ + 1]

\* --- Snapshot Constraints (Family 3) ---
MCStartSnapshot(i, j) ==
    /\ cc.snapshot < SnapshotLimit
    /\ baseSpec!StartSnapshot(i, j)
    /\ cc' = [cc EXCEPT !.snapshot = @ + 1]

\* ============================================================================
\* INITIALIZATION
\* ============================================================================

MCInit ==
    /\ Init
    /\ cc = [
         timeout     |-> 0,
         request     |-> 0,
         crash       |-> 0,
         lose        |-> 0,
         heartbeat   |-> 0,
         leaseExpiry |-> 0,
         snapshot    |-> 0,
         preVote     |-> 0]

\* ============================================================================
\* NEXT STATE RELATION
\* ============================================================================

\* Per-server async actions
MCNextAsync(i) ==
    \* --- Elections ---
    \/ MCTimeout(i)
    \/ MCBlindFollowerTimeout(i)
    \/ MCSendPreVote(i)
    \/ /\ baseSpec!SendRequestVote(i)
       /\ UNCHANGED faultVars
    \/ /\ baseSpec!BecomeLeader(i)
       /\ UNCHANGED faultVars
    \* --- Client requests ---
    \/ MCClientRequest(i)
    \* --- Lease expiry (Family 2) ---
    \/ MCExpireLease(i)
    \* --- Crash/restart (Family 1) ---
    \/ MCCrash(i)
    \/ /\ baseSpec!Restart(i)
       /\ UNCHANGED faultVars

\* Per-server-pair actions
MCNextPair(i, j) ==
    \* --- Log replication ---
    \/ /\ baseSpec!AppendEntries(i, j)
       /\ UNCHANGED faultVars
    \* --- Heartbeat (Family 4) ---
    \/ MCSendHeartbeat(i, j)
    \* --- Snapshot (Family 3) ---
    \/ MCStartSnapshot(i, j)
    \/ /\ baseSpec!CompleteSnapshot(i, j)
       /\ UNCHANGED faultVars

\* Message handlers (reactive — not bounded)
MCNextMsg(m) ==
    /\ \/ baseSpec!HandlePreVoteRequest(m.mdest, m)
       \/ baseSpec!HandleRequestVoteRequest(m.mdest, m)
       \/ baseSpec!HandlePreVoteResponse(m.mdest, m)
       \/ baseSpec!HandleRequestVoteResponse(m.mdest, m)
       \/ baseSpec!HandleAppendEntriesRequest(m.mdest, m)
       \/ baseSpec!HandleAppendEntriesResponse(m.mdest, m)
       \/ baseSpec!HandleHeartbeatRequest(m.mdest, m)
       \/ baseSpec!HandleHeartbeatResponse(m.mdest, m)
    /\ UNCHANGED faultVars

MCNext ==
    \/ \E i \in Server : MCNextAsync(i)
    \/ \E i, j \in Server : i /= j /\ MCNextPair(i, j)
    \/ \E m \in DOMAIN messages : MCNextMsg(m)
    \/ \E m \in DOMAIN messages : MCLoseMessage(m)

MCSpec == MCInit /\ [][MCNext]_<<vars, faultVars>>

\* ============================================================================
\* STATE SPACE MANAGEMENT
\* ============================================================================

\* Symmetry reduction
ModelSymmetry == Permutations(Server)

\* State space constraint: limit message buffer size
MessageBufferConstraint ==
    BagCardinality(messages) <= MaxMsgBufferLimit

\* View: exclude counters from state fingerprint
MCView == <<vars>>

\* ============================================================================
\* INVARIANTS (for MC.cfg — structural + safety, hunting invariants commented out)
\* ============================================================================

\* Structural invariants
MCTermsNonNegative == TermsNonNegative
MCCommitIndexBound == CommitIndexBound
MCAliveLeaders == AliveLeaders
MCMessageInvariant == MessageInvariant

\* Core safety invariants
MCElectionSafety == ElectionSafety
MCLogMatching == LogMatching

\* Extension invariants (uncommented in hunting configs)
MCNoStaleLeaseRead == NoStaleLeaseRead
MCLeaderCompleteness == LeaderCompleteness

==========
