---------- MODULE MC ----------
\* Model Checking Spec for ScyllaDB Raft library.
\*
\* Wraps the base spec with counter-bounded actions for
\* exhaustive state-space exploration via TLC.
\*
\* Bug families targeted:
\*   1. Commit index over-advancement (unclamped AppendEntries/ReadQuorum)
\*   2. Joint consensus quorum miscalculation (can_vote mismatch, read barrier stall)
\*   3. Snapshot lifecycle & persistence inconsistency
\*   5. Election disruption & failure detector dependence

EXTENDS base

\* Access original (un-overridden) operator definitions.
B == INSTANCE base

\* ============================================================================
\* CONSTRAINT CONSTANTS
\* ============================================================================

CONSTANT MaxTermLimit
ASSUME MaxTermLimit \in Nat

CONSTANT MaxTimeoutLimit
ASSUME MaxTimeoutLimit \in Nat

CONSTANT RequestLimit
ASSUME RequestLimit \in Nat

CONSTANT CrashLimit
ASSUME CrashLimit \in Nat

CONSTANT LoseLimit
ASSUME LoseLimit \in Nat

CONSTANT SnapshotLimit
ASSUME SnapshotLimit \in Nat

CONSTANT ReadBarrierLimit
ASSUME ReadBarrierLimit \in Nat

CONSTANT ConfigChangeLimit
ASSUME ConfigChangeLimit \in Nat

CONSTANT FDUpdateLimit
ASSUME FDUpdateLimit \in Nat

CONSTANT MaxMsgBufferLimit
ASSUME MaxMsgBufferLimit \in Nat

\* ============================================================================
\* CONSTRAINT VARIABLES
\* ============================================================================

VARIABLE cc  \* constraint counters record

faultVars == <<cc>>

\* ============================================================================
\* COUNTER-BOUNDED ACTIONS
\* ============================================================================

\* --- Election (bounded by term + timeout) ---
MCTimeout(i) ==
    /\ currentTerm[i] < MaxTermLimit
    /\ cc.timeout < MaxTimeoutLimit
    /\ B!Timeout(i)
    /\ cc' = [cc EXCEPT !.timeout = @ + 1]

\* --- Client Requests ---
MCClientRequest(i) ==
    /\ cc.request < RequestLimit
    /\ B!ClientRequest(i)
    /\ cc' = [cc EXCEPT !.request = @ + 1]

\* --- Crash ---
MCCrash(i) ==
    /\ cc.crash < CrashLimit
    /\ B!Crash(i)
    /\ cc' = [cc EXCEPT !.crash = @ + 1]

\* --- Message Loss ---
MCLoseMessage(m) ==
    /\ cc.lose < LoseLimit
    /\ B!LoseMessage(m)
    /\ cc' = [cc EXCEPT !.lose = @ + 1]

\* --- Snapshot ---
MCTakeLocalSnapshot(i) ==
    /\ cc.snapshot < SnapshotLimit
    /\ B!TakeLocalSnapshot(i)
    /\ cc' = [cc EXCEPT !.snapshot = @ + 1]

\* --- Read Barrier ---
MCBroadcastReadQuorum(i) ==
    /\ cc.readBarrier < ReadBarrierLimit
    /\ B!BroadcastReadQuorum(i)
    /\ cc' = [cc EXCEPT !.readBarrier = @ + 1]

MCCorrectBroadcastReadQuorum(i) ==
    /\ cc.readBarrier < ReadBarrierLimit
    /\ B!CorrectBroadcastReadQuorum(i)
    /\ cc' = [cc EXCEPT !.readBarrier = @ + 1]

\* --- Config Change ---
MCProposeConfigChange(i, newV) ==
    /\ cc.configChange < ConfigChangeLimit
    /\ B!ProposeConfigChange(i, newV)
    /\ cc' = [cc EXCEPT !.configChange = @ + 1]

\* --- FD Update ---
MCFDUpdate(i) ==
    /\ cc.fdUpdate < FDUpdateLimit
    /\ B!FDUpdate(i)
    /\ cc' = [cc EXCEPT !.fdUpdate = @ + 1]

\* --- Bug Family 1: Buggy variants ---
MCBuggyHandleAppendEntriesRequest(i, j, m) ==
    /\ B!BuggyHandleAppendEntriesRequest(i, j, m)
    /\ UNCHANGED cc

MCBuggyBroadcastReadQuorum(i) ==
    /\ cc.readBarrier < ReadBarrierLimit
    /\ B!BuggyBroadcastReadQuorum(i)
    /\ cc' = [cc EXCEPT !.readBarrier = @ + 1]

\* --- Bug Family 3: Buggy snapshot variant ---
MCBuggyHandleInstallSnapshot(i, j, m) ==
    /\ B!BuggyHandleInstallSnapshot(i, j, m)
    /\ UNCHANGED cc

\* --- Unconstrained (reactive) actions ---
MCBecomeLeader(i) ==
    /\ B!BecomeLeader(i)
    /\ UNCHANGED cc

MCMaybeCommit(i) ==
    /\ B!MaybeCommit(i)
    /\ UNCHANGED cc

MCAppendEntries(i, j) ==
    /\ B!AppendEntries(i, j)
    /\ UNCHANGED cc

MCSendInstallSnapshot(i, j) ==
    /\ B!SendInstallSnapshot(i, j)
    /\ UNCHANGED cc

MCHandleRequestVoteRequest(i, j, m) ==
    /\ B!HandleRequestVoteRequest(i, j, m)
    /\ UNCHANGED cc

MCHandleRequestVoteResponse(i, j, m) ==
    /\ B!HandleRequestVoteResponse(i, j, m)
    /\ UNCHANGED cc

MCHandleAppendEntriesRequest(i, j, m) ==
    /\ B!HandleAppendEntriesRequest(i, j, m)
    /\ UNCHANGED cc

MCHandleAppendEntriesResponse(i, j, m) ==
    /\ B!HandleAppendEntriesResponse(i, j, m)
    /\ UNCHANGED cc

MCHandleReadQuorumRequest(i, j, m) ==
    /\ B!HandleReadQuorumRequest(i, j, m)
    /\ UNCHANGED cc

MCHandleReadQuorumResponse(i, j, m) ==
    /\ B!HandleReadQuorumResponse(i, j, m)
    /\ UNCHANGED cc

MCHandleInstallSnapshot(i, j, m) ==
    /\ B!HandleInstallSnapshot(i, j, m)
    /\ UNCHANGED cc

MCHandleInstallSnapshotResponse(i, j, m) ==
    /\ B!HandleInstallSnapshotResponse(i, j, m)
    /\ UNCHANGED cc

MCUpdateTerm(i, j, m) ==
    /\ B!UpdateTerm(i, j, m)
    /\ UNCHANGED cc

MCDropStaleMessage(i, j, m) ==
    /\ B!DropStaleMessage(i, j, m)
    /\ UNCHANGED cc

MCTickLeader(i) ==
    /\ B!TickLeader(i)
    /\ UNCHANGED cc

\* ============================================================================
\* INIT and NEXT
\* ============================================================================

MCInit ==
    /\ B!Init
    /\ cc = [timeout      |-> 0,
              request      |-> 0,
              crash        |-> 0,
              lose         |-> 0,
              snapshot     |-> 0,
              readBarrier  |-> 0,
              configChange |-> 0,
              fdUpdate     |-> 0]

MCNext ==
    \/ \E i \in Server :
        \/ MCTimeout(i)
        \/ MCBecomeLeader(i)
        \/ MCClientRequest(i)
        \/ MCMaybeCommit(i)
        \/ MCTakeLocalSnapshot(i)
        \/ MCCrash(i)
        \/ MCTickLeader(i)
        \/ MCFDUpdate(i)
    \/ \E i, j \in Server : i /= j /\
        \/ MCAppendEntries(i, j)
        \/ MCSendInstallSnapshot(i, j)
    \/ \E i \in Server :
        \/ MCBroadcastReadQuorum(i)
    \/ \E i \in Server, newV \in SUBSET Server \ {{}} :
        MCProposeConfigChange(i, newV)
    \/ \E m \in DOMAIN messages :
        \/ \E i, j \in Server :
            /\ i = m.mdest
            /\ j = m.msource
            /\ \/ m.mterm > currentTerm[i] /\ MCUpdateTerm(i, j, m)
               \/ m.mterm < currentTerm[i] /\ MCDropStaleMessage(i, j, m)
               \/ m.mterm = currentTerm[i] /\
                  \/ MCHandleRequestVoteRequest(i, j, m)
                  \/ MCHandleRequestVoteResponse(i, j, m)
                  \/ MCHandleAppendEntriesRequest(i, j, m)
                  \/ MCHandleAppendEntriesResponse(i, j, m)
                  \/ MCHandleReadQuorumRequest(i, j, m)
                  \/ MCHandleReadQuorumResponse(i, j, m)
                  \/ MCHandleInstallSnapshot(i, j, m)
                  \/ MCHandleInstallSnapshotResponse(i, j, m)
        \/ MCLoseMessage(m)

MCSpec == MCInit /\ [][MCNext]_<<vars, faultVars>>

\* ============================================================================
\* SYMMETRY
\* ============================================================================

MCSymmetry == Permutations(Server)

\* ============================================================================
\* STATE SPACE CONSTRAINTS
\* ============================================================================

\* View excludes fault counters from state fingerprint
MCView == <<vars>>

\* Bound message buffer to prevent state explosion
MsgBufferConstraint == BagCardinality(messages) <= MaxMsgBufferLimit

\* ============================================================================
\* INVARIANTS
\* ============================================================================

\* --- Standard safety ---
MCElectionSafety == B!ElectionSafety
MCLogMatching == B!LogMatching
MCLeaderCompleteness == B!LeaderCompleteness

\* --- Structural ---
MCCommitBound == B!CommitBound
MCVoteValid == B!VoteValid
MCReadIdMonotonic == B!ReadIdMonotonic
MCSnapshotLogContinuity == B!SnapshotLogContinuity

\* --- Extension (bug-family targets) ---
\* Commented out in MC.cfg during convergence; enabled in hunting configs.
MCCommitIndexSafety == B!CommitIndexSafety
MCJointQuorumAgreement == B!JointQuorumAgreement
MCCrashRecoveryConsistency == B!CrashRecoveryConsistency
MCSnapshotBound == B!SnapshotBound

\* ============================================================================
\* HUNTING NEXT FORMULAS (buggy action variants)
\* ============================================================================

\* Family 1: Uses buggy AppendEntries (unclamped commit) and buggy ReadQuorum
MCNextFamily1 ==
    \/ \E i \in Server :
        \/ MCTimeout(i)
        \/ MCBecomeLeader(i)
        \/ MCClientRequest(i)
        \/ MCMaybeCommit(i)
        \/ MCTakeLocalSnapshot(i)
        \/ MCCrash(i)
        \/ MCTickLeader(i)
        \/ MCFDUpdate(i)
    \/ \E i, j \in Server : i /= j /\
        \/ MCAppendEntries(i, j)
        \/ MCSendInstallSnapshot(i, j)
    \/ \E i \in Server :
        \/ MCBuggyBroadcastReadQuorum(i)
    \/ \E i \in Server, newV \in SUBSET Server \ {{}} :
        MCProposeConfigChange(i, newV)
    \/ \E m \in DOMAIN messages :
        \/ \E i, j \in Server :
            /\ i = m.mdest
            /\ j = m.msource
            /\ \/ m.mterm > currentTerm[i] /\ MCUpdateTerm(i, j, m)
               \/ m.mterm < currentTerm[i] /\ MCDropStaleMessage(i, j, m)
               \/ m.mterm = currentTerm[i] /\
                  \/ MCHandleRequestVoteRequest(i, j, m)
                  \/ MCHandleRequestVoteResponse(i, j, m)
                  \/ MCBuggyHandleAppendEntriesRequest(i, j, m)
                  \/ MCHandleAppendEntriesResponse(i, j, m)
                  \/ MCHandleReadQuorumRequest(i, j, m)
                  \/ MCHandleReadQuorumResponse(i, j, m)
                  \/ MCHandleInstallSnapshot(i, j, m)
                  \/ MCHandleInstallSnapshotResponse(i, j, m)
        \/ MCLoseMessage(m)

MCSpecFamily1 == MCInit /\ [][MCNextFamily1]_<<vars, faultVars>>

\* Family 3: Uses buggy InstallSnapshot (non-zero trailing for remote)
MCNextFamily3 ==
    \/ \E i \in Server :
        \/ MCTimeout(i)
        \/ MCBecomeLeader(i)
        \/ MCClientRequest(i)
        \/ MCMaybeCommit(i)
        \/ MCTakeLocalSnapshot(i)
        \/ MCCrash(i)
        \/ MCTickLeader(i)
        \/ MCFDUpdate(i)
    \/ \E i, j \in Server : i /= j /\
        \/ MCAppendEntries(i, j)
        \/ MCSendInstallSnapshot(i, j)
    \/ \E i \in Server :
        \/ MCBroadcastReadQuorum(i)
    \/ \E i \in Server, newV \in SUBSET Server \ {{}} :
        MCProposeConfigChange(i, newV)
    \/ \E m \in DOMAIN messages :
        \/ \E i, j \in Server :
            /\ i = m.mdest
            /\ j = m.msource
            /\ \/ m.mterm > currentTerm[i] /\ MCUpdateTerm(i, j, m)
               \/ m.mterm < currentTerm[i] /\ MCDropStaleMessage(i, j, m)
               \/ m.mterm = currentTerm[i] /\
                  \/ MCHandleRequestVoteRequest(i, j, m)
                  \/ MCHandleRequestVoteResponse(i, j, m)
                  \/ MCHandleAppendEntriesRequest(i, j, m)
                  \/ MCHandleAppendEntriesResponse(i, j, m)
                  \/ MCHandleReadQuorumRequest(i, j, m)
                  \/ MCHandleReadQuorumResponse(i, j, m)
                  \/ MCBuggyHandleInstallSnapshot(i, j, m)
                  \/ MCHandleInstallSnapshotResponse(i, j, m)
        \/ MCLoseMessage(m)

MCSpecFamily3 == MCInit /\ [][MCNextFamily3]_<<vars, faultVars>>

====
