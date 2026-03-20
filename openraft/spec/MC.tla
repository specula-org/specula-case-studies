----------------------------- MODULE MC -----------------------------
\* Model checking wrapper for openraft base spec.
\*
\* Counter-bounds fault-injection and non-deterministic actions.
\* Reactive/deterministic actions (message handlers) are NOT bounded.
\*
\* Extensions reference Bug Families from modeling-brief.md.
\* Hunting configs (MC_hunt_*.cfg) target specific bug families.

EXTENDS base

\* Counter-bounded action limits
CONSTANT MaxElectLimit       \* Max elections per server
CONSTANT MaxRequestLimit     \* Max client requests total
CONSTANT MaxCrashLimit       \* Max crashes total
CONSTANT MaxHeartbeatLimit   \* Max heartbeats total
CONSTANT MaxConfigLimit      \* Max config changes total
CONSTANT MaxSnapshotLimit    \* Max snapshot triggers total
CONSTANT MaxLeaseExpireLimit \* Max lease expirations total
CONSTANT MaxMsgBufferLimit   \* Max messages in flight

\* Counter variables
VARIABLE electCount          \* [Server -> Nat]
VARIABLE requestCount        \* Nat
VARIABLE crashCount          \* Nat
VARIABLE heartbeatCount      \* Nat
VARIABLE configCount         \* Nat
VARIABLE snapshotCount       \* Nat
VARIABLE leaseExpireCount    \* Nat

faultVars == <<electCount, requestCount, crashCount, heartbeatCount,
              configCount, snapshotCount, leaseExpireCount>>

mcVars == <<vars, faultVars>>

----
\* Counter-bounded wrappers
\* Only fault-injection / non-deterministic actions are bounded.
\* Reactive handlers pass through with UNCHANGED faultVars.
----

MCElect(i) ==
    /\ electCount[i] < MaxElectLimit
    /\ Elect(i)
    /\ electCount' = [electCount EXCEPT ![i] = @ + 1]
    /\ UNCHANGED <<requestCount, crashCount, heartbeatCount,
                   configCount, snapshotCount, leaseExpireCount>>

MCClientRequest(i) ==
    /\ requestCount < MaxRequestLimit
    /\ ClientRequest(i)
    /\ requestCount' = requestCount + 1
    /\ UNCHANGED <<electCount, crashCount, heartbeatCount,
                   configCount, snapshotCount, leaseExpireCount>>

MCSendHeartbeat(i) ==
    /\ heartbeatCount < MaxHeartbeatLimit
    /\ SendHeartbeat(i)
    /\ heartbeatCount' = heartbeatCount + 1
    /\ UNCHANGED <<electCount, requestCount, crashCount,
                   configCount, snapshotCount, leaseExpireCount>>

MCCrash(i) ==
    /\ crashCount < MaxCrashLimit
    /\ Crash(i)
    /\ crashCount' = crashCount + 1
    /\ UNCHANGED <<electCount, requestCount, heartbeatCount,
                   configCount, snapshotCount, leaseExpireCount>>

MCTriggerSnapshot(i) ==
    /\ snapshotCount < MaxSnapshotLimit
    /\ TriggerSnapshot(i)
    /\ snapshotCount' = snapshotCount + 1
    /\ UNCHANGED <<electCount, requestCount, crashCount,
                   heartbeatCount, configCount, leaseExpireCount>>

MCProposeConfigChange(i, newVoters) ==
    /\ configCount < MaxConfigLimit
    /\ ProposeConfigChange(i, newVoters)
    /\ configCount' = configCount + 1
    /\ UNCHANGED <<electCount, requestCount, crashCount,
                   heartbeatCount, snapshotCount, leaseExpireCount>>

MCLeaseExpire(i) ==
    /\ leaseExpireCount < MaxLeaseExpireLimit
    /\ LeaseExpire(i)
    /\ leaseExpireCount' = leaseExpireCount + 1
    /\ UNCHANGED <<electCount, requestCount, crashCount,
                   heartbeatCount, configCount, snapshotCount>>

----
\* Unconstrained (reactive/deterministic) actions — UNCHANGED faultVars
----

MCEstablishLeader(i) == EstablishLeader(i) /\ UNCHANGED faultVars
MCHandleVoteRequest(i, m) == HandleVoteRequest(i, m) /\ UNCHANGED faultVars
MCHandleVoteResponse(i, m) == HandleVoteResponse(i, m) /\ UNCHANGED faultVars
MCHandleAppendEntries(i, m) == HandleAppendEntries(i, m) /\ UNCHANGED faultVars
MCHandleAppendEntriesResponse(i, m) == HandleAppendEntriesResponse(i, m) /\ UNCHANGED faultVars
MCHandleInstallSnapshot(i, m) == HandleInstallSnapshot(i, m) /\ UNCHANGED faultVars
MCHandleInstallSnapshotResponse(i, m) == HandleInstallSnapshotResponse(i, m) /\ UNCHANGED faultVars
MCReplicateEntries(i, j) == ReplicateEntries(i, j) /\ UNCHANGED faultVars
MCSendInstallSnapshot(i, j) == SendInstallSnapshot(i, j) /\ UNCHANGED faultVars
MCAdvanceCommitIndex(i) == AdvanceCommitIndex(i) /\ UNCHANGED faultVars
MCPurgeLog(i) == PurgeLog(i) /\ UNCHANGED faultVars
MCRestart(i) == Restart(i) /\ UNCHANGED faultVars
MCCommitConfigChange(i) == CommitConfigChange(i) /\ UNCHANGED faultVars
MCLeaderStepDown(i) == LeaderStepDown(i) /\ UNCHANGED faultVars

----
\* MCInit and MCNext
----

MCInit ==
    /\ Init
    /\ electCount       = [s \in Server |-> 0]
    /\ requestCount     = 0
    /\ crashCount       = 0
    /\ heartbeatCount   = 0
    /\ configCount      = 0
    /\ snapshotCount    = 0
    /\ leaseExpireCount = 0

MCNext ==
    \* Bounded non-deterministic actions
    \/ \E i \in Server :
        \/ MCElect(i)
        \/ MCClientRequest(i)
        \/ MCSendHeartbeat(i)
        \/ MCCrash(i)
        \/ MCTriggerSnapshot(i)
        \/ MCLeaseExpire(i)
    \/ \E i \in Server :
        \E newVoters \in SUBSET Server \ {{}} :
            MCProposeConfigChange(i, newVoters)
    \* Unbounded reactive actions
    \/ \E i \in Server :
        \/ MCEstablishLeader(i)
        \/ MCAdvanceCommitIndex(i)
        \/ MCPurgeLog(i)
        \/ MCRestart(i)
        \/ MCCommitConfigChange(i)
        \/ MCLeaderStepDown(i)
    \/ \E i \in Server, j \in Server :
        \/ MCReplicateEntries(i, j)
        \/ MCSendInstallSnapshot(i, j)
    \/ \E m \in DOMAIN messages :
        \/ MCHandleVoteRequest(m.mdest, m)
        \/ MCHandleVoteResponse(m.mdest, m)
        \/ MCHandleAppendEntries(m.mdest, m)
        \/ MCHandleAppendEntriesResponse(m.mdest, m)
        \/ MCHandleInstallSnapshot(m.mdest, m)
        \/ MCHandleInstallSnapshotResponse(m.mdest, m)

MCSpec == MCInit /\ [][MCNext]_mcVars

----
\* Symmetry reduction
----

\* Server symmetry — only valid if Server is a set of Nat
\* NOTE: vote ordering uses numeric comparison, so symmetry is
\* only valid for interchangeable servers. Use with caution.
\* ModelSymmetry == Permutations(Server)

----
\* State space constraint
----

\* Limit message buffer to control state space
MsgBufferConstraint ==
    BagCardinality(messages) <= MaxMsgBufferLimit

----
\* Structural invariants (always checked)
----

\* Vote state must be consistent with server state
MCVoteStateConsistency == VoteStateConsistency

\* CommitIndex must not exceed log length
MCCommitIndexBound == CommitIndexBound

\* Purge point must not exceed snapshot
MCNoCommittedLogDeletion == NoCommittedLogDeletion

\* At most one uncommitted membership per leader
MCAtMostOneUncommittedMembership == AtMostOneUncommittedMembership

----
\* Standard safety invariants (always checked)
----

MCElectionSafety == ElectionSafety
MCCommitSafety == CommitSafety
MCLogMatching == LogMatching

----
\* Extension invariants (bug-family targeted, commented out in MC.cfg)
\* Uncomment in hunting configs to detect specific bugs.
----

\* Bug Family 1: leader lease correctness
MCLeaseImpliesLeadership == LeaseImpliesLeadership

\* Bug Family 2: snapshot-log consistency
MCSnapshotLogConsistency == SnapshotLogConsistency

\* Bug Family 3: commit monotonicity (tracked via leader completeness)
MCLeaderCompleteness == LeaderCompleteness

\* Bug Family 5: restarted leader safety
MCRestartedLeaderSafety == RestartedLeaderSafety

====
