------------------------------ MODULE MC ------------------------------
\* Model checking wrapper for Hazelcast CP Subsystem (Raft) spec.
\*
\* Counter-bounds fault-injection and non-deterministic actions.
\* Deterministic/reactive actions pass through unbounded.
\*
\* Uses operator overrides in MC.cfg to inject bounded actions.

EXTENDS base

\* Operator access to base spec (needed because cfg overrides operators)
B == INSTANCE base

\* Counter bounds (set via CONSTANTS in cfg)
CONSTANT MaxTimeoutLimit       \* Max pre-vote starts
CONSTANT MaxElectionLimit      \* Max real elections (HandlePreVoteResponse → election)
CONSTANT RequestLimit          \* Max client requests
CONSTANT AppendEntriesLimit    \* Max AppendEntries sends (heartbeats)
CONSTANT CrashLimit            \* Max crashes
CONSTANT LoseLimit             \* Max lost messages
CONSTANT LeaseCheckLimit       \* Max leader lease checks (demotion)
CONSTANT MembershipLimit       \* Max membership change proposals
CONSTANT QueryLimit            \* Max linearizable read submissions
CONSTANT MaxTermLimit          \* Max term any server can reach

\* Counter variables
VARIABLE faultVars

\* Counter record fields
timeoutCount       == faultVars.timeoutCount
electionCount      == faultVars.electionCount
requestCount       == faultVars.requestCount
appendCount        == faultVars.appendCount
crashCount         == faultVars.crashCount
loseCount          == faultVars.loseCount
leaseCheckCount    == faultVars.leaseCheckCount
membershipCount    == faultVars.membershipCount
queryCount         == faultVars.queryCount

MCvars == <<vars, faultVars>>

----
\* Init
----

MCInit ==
    /\ Init
    /\ faultVars = [
           timeoutCount    |-> 0,
           electionCount   |-> 0,
           requestCount    |-> 0,
           appendCount     |-> 0,
           crashCount      |-> 0,
           loseCount       |-> 0,
           leaseCheckCount |-> 0,
           membershipCount |-> 0,
           queryCount      |-> 0
       ]

----
\* Counter-bounded actions (fault injection / non-deterministic)
----

MCTimeout(i) ==
    /\ timeoutCount < MaxTimeoutLimit
    /\ Timeout(i)
    /\ faultVars' = [faultVars EXCEPT !.timeoutCount = @ + 1]

MCHandlePreVoteResponse(i, m) ==
    \* Only bound the election-triggering path (sub-case 2)
    \* The vote-recording path (sub-case 1) is reactive
    /\ HandlePreVoteResponse(i, m)
    /\ IF state'[i] = Candidate
       THEN /\ electionCount < MaxElectionLimit
            /\ faultVars' = [faultVars EXCEPT !.electionCount = @ + 1]
       ELSE UNCHANGED faultVars

MCClientRequest(i) ==
    /\ requestCount < RequestLimit
    /\ ClientRequest(i)
    /\ faultVars' = [faultVars EXCEPT !.requestCount = @ + 1]

MCAppendEntries(i, j) ==
    /\ appendCount < AppendEntriesLimit
    /\ AppendEntries(i, j)
    /\ faultVars' = [faultVars EXCEPT !.appendCount = @ + 1]

MCCrash(i) ==
    /\ crashCount < CrashLimit
    /\ Crash(i)
    /\ faultVars' = [faultVars EXCEPT !.crashCount = @ + 1]

MCLoseMessage(m) ==
    /\ loseCount < LoseLimit
    /\ LoseMessage(m)
    /\ faultVars' = [faultVars EXCEPT !.loseCount = @ + 1]

MCLeaderCheckLease(i) ==
    /\ leaseCheckCount < LeaseCheckLimit
    /\ LeaderCheckLease(i)
    /\ faultVars' = [faultVars EXCEPT !.leaseCheckCount = @ + 1]

MCProposeMembershipChange(i) ==
    /\ membershipCount < MembershipLimit
    /\ ProposeMembershipChange(i)
    /\ faultVars' = [faultVars EXCEPT !.membershipCount = @ + 1]

MCSubmitLinearizableRead(i) ==
    /\ queryCount < QueryLimit
    /\ SubmitLinearizableRead(i)
    /\ faultVars' = [faultVars EXCEPT !.queryCount = @ + 1]

----
\* Unconstrained actions (deterministic / reactive — no bound needed)
----

MCHandlePreVoteRequest(i, m) ==
    /\ HandlePreVoteRequest(i, m)
    /\ UNCHANGED faultVars

MCHandleVoteRequest(i, m) ==
    /\ HandleVoteRequest(i, m)
    /\ UNCHANGED faultVars

MCHandleVoteResponse(i, m) ==
    /\ HandleVoteResponse(i, m)
    /\ UNCHANGED faultVars

MCHandleAppendRequest(i, m) ==
    /\ HandleAppendRequest(i, m)
    /\ UNCHANGED faultVars

MCHandleAppendSuccessResponse(i, m) ==
    /\ HandleAppendSuccessResponse(i, m)
    /\ UNCHANGED faultVars

MCHandleAppendFailureResponse(i, m) ==
    /\ HandleAppendFailureResponse(i, m)
    /\ UNCHANGED faultVars

MCAdvanceCommitIndex(i) ==
    /\ AdvanceCommitIndex(i)
    /\ UNCHANGED faultVars

MCRunQueries(i) ==
    /\ RunQueries(i)
    /\ UNCHANGED faultVars

----
\* Term limit constraint (state space pruning)
----

TermConstraint ==
    \A s \in Server : currentTerm[s] <= MaxTermLimit

----
\* Message buffer constraint (state space pruning)
----

CONSTANT MaxMsgBuffer
MsgBufferConstraint ==
    BagCardinality(messages) <= MaxMsgBuffer

----
\* State constraint
----

StateConstraint ==
    /\ TermConstraint
    /\ MsgBufferConstraint

----
\* MCNext
----

MCNext ==
    \* Bounded election actions
    \/ \E i \in Server : MCTimeout(i)
    \/ \E m \in DOMAIN messages : MCHandlePreVoteRequest(m.mdest, m)
    \/ \E m \in DOMAIN messages : MCHandlePreVoteResponse(m.mdest, m)
    \/ \E m \in DOMAIN messages : MCHandleVoteRequest(m.mdest, m)
    \/ \E m \in DOMAIN messages : MCHandleVoteResponse(m.mdest, m)
    \* Bounded replication actions
    \/ \E i \in Server : MCClientRequest(i)
    \/ \E i \in Server, j \in Server : MCAppendEntries(i, j)
    \/ \E m \in DOMAIN messages : MCHandleAppendRequest(m.mdest, m)
    \/ \E m \in DOMAIN messages : MCHandleAppendSuccessResponse(m.mdest, m)
    \/ \E m \in DOMAIN messages : MCHandleAppendFailureResponse(m.mdest, m)
    \/ \E i \in Server : MCAdvanceCommitIndex(i)
    \* Bounded heartbeat / lease
    \/ \E i \in Server : MCLeaderCheckLease(i)
    \* Bounded membership
    \/ \E i \in Server : MCProposeMembershipChange(i)
    \* Bounded queries
    \/ \E i \in Server : MCSubmitLinearizableRead(i)
    \/ \E i \in Server : MCRunQueries(i)
    \* Bounded fault actions
    \/ \E i \in Server : MCCrash(i)
    \/ \E m \in DOMAIN messages : MCLoseMessage(m)

MCSpec == MCInit /\ [][MCNext]_MCvars

----
\* Symmetry
----

ModelSymmetry == Permutations(Server)

----
\* View (exclude counters from state hash)
----

MCView == vars

====
