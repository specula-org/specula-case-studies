---- MODULE MC ----
\* Model checking wrapper for MongoDB RaftMongo spec.
\* Adds counter-bounded fault injection, state constraints, and symmetry.

EXTENDS base

\* ---- MC-defined constants ----

\* InfOpTime sentinel — must exceed any reachable optime
MCInfOpTime == [term |-> 999, index |-> 999]

\* ---- MC Constants ----

\* State space bounds
CONSTANT MaxTerm           \* Maximum global term
CONSTANT MaxLogLen         \* Maximum log length per server

\* Counter bounds for non-deterministic actions
CONSTANT MaxElections      \* Maximum number of elections (StartElection)
CONSTANT MaxCrashes        \* Maximum number of crashes
CONSTANT MaxClientWrites   \* Maximum number of client writes

\* ---- Counter Variables ----

VARIABLE electionCount     \* Number of elections started
VARIABLE crashCount        \* Number of crashes
VARIABLE clientWriteCount  \* Number of client writes

faultVars == <<electionCount, crashCount, clientWriteCount>>
mcVars == <<vars, faultVars>>

\* ---- Counter-Bounded Action Wrappers ----

\* Bound election starts (non-deterministic — any follower can start)
MCStartElection(i) ==
    /\ electionCount < MaxElections
    /\ StartElection(i)
    /\ electionCount' = electionCount + 1
    /\ UNCHANGED <<crashCount, clientWriteCount>>

\* Bound crashes (non-deterministic fault injection)
MCCrash(i) ==
    /\ crashCount < MaxCrashes
    /\ Crash(i)
    /\ crashCount' = crashCount + 1
    /\ UNCHANGED <<electionCount, clientWriteCount>>

\* Bound client writes (non-deterministic — leader chooses to write)
MCClientWrite(i) ==
    /\ clientWriteCount < MaxClientWrites
    /\ ClientWrite(i)
    /\ clientWriteCount' = clientWriteCount + 1
    /\ UNCHANGED <<electionCount, crashCount>>

\* ---- Unconstrained (Reactive) Actions ----
\* These react to existing state and don't need bounding.

MCRequestVote(i, j) ==
    /\ RequestVote(i, j)
    /\ UNCHANGED faultVars

MCWinElection(i) ==
    /\ WinElection(i)
    /\ UNCHANGED faultVars

MCWritePrimaryNoOp(i) ==
    /\ WritePrimaryNoOp(i)
    /\ UNCHANGED faultVars

MCAppendOplog(i, j) ==
    /\ AppendOplog(i, j)
    /\ UNCHANGED faultVars

MCRollbackOplog(i, j) ==
    /\ RollbackOplog(i, j)
    /\ UNCHANGED faultVars

MCPersistOplog(i) ==
    /\ PersistOplog(i)
    /\ UNCHANGED faultVars

MCApplyOplog(i) ==
    /\ ApplyOplog(i)
    /\ UNCHANGED faultVars

MCStepdown(i) ==
    /\ Stepdown(i)
    /\ UNCHANGED faultVars

MCUpdateTermThroughHeartbeat(i, j) ==
    /\ UpdateTermThroughHeartbeat(i, j)
    /\ UNCHANGED faultVars

MCAdvanceCommitPoint ==
    /\ AdvanceCommitPoint
    /\ UNCHANGED faultVars

MCLearnCommitPointWithTermCheck(i, j) ==
    /\ LearnCommitPointWithTermCheck(i, j)
    /\ UNCHANGED faultVars

MCLearnCommitPointFromSyncSource(i, j) ==
    /\ LearnCommitPointFromSyncSourceNeverBeyondLastWritten(i, j)
    /\ UNCHANGED faultVars

\* ---- MC Init and Next ----

MCInit ==
    /\ Init
    /\ electionCount = 0
    /\ crashCount = 0
    /\ clientWriteCount = 0

MCNext ==
    \* --- Replication protocol (unbounded — reactive)
    \/ \E i, j \in Server : MCAppendOplog(i, j)
    \/ \E i, j \in Server : MCRollbackOplog(i, j)
    \/ \E i \in Server : MCPersistOplog(i)
    \/ \E i \in Server : MCApplyOplog(i)
    \* --- Election protocol
    \/ \E i \in Server : MCStartElection(i)          \* BOUNDED
    \/ \E i, j \in Server : MCRequestVote(i, j)      \* unbounded (reactive)
    \/ \E i \in Server : MCWinElection(i)             \* unbounded (reactive)
    \/ \E i \in Server : MCWritePrimaryNoOp(i)        \* unbounded (reactive)
    \/ \E i \in Server : MCStepdown(i)                \* unbounded (reactive)
    \* --- Term learning (unbounded — reactive)
    \/ \E i, j \in Server : MCUpdateTermThroughHeartbeat(i, j)
    \* --- Commit point protocol (unbounded — reactive)
    \/ MCAdvanceCommitPoint
    \/ \E i, j \in Server : MCLearnCommitPointWithTermCheck(i, j)
    \/ \E i, j \in Server : MCLearnCommitPointFromSyncSource(i, j)
    \* --- Fault injection
    \/ \E i \in Server : MCClientWrite(i)             \* BOUNDED
    \/ \E i \in Server : MCCrash(i)                   \* BOUNDED

\* ---- MC Specification ----

MCSpec == MCInit /\ [][MCNext]_mcVars

\* ---- State Constraint ----

StateConstraint ==
    /\ GlobalCurrentTerm <= MaxTerm
    /\ \A i \in Server : Len(log[i]) <= MaxLogLen

\* ---- Symmetry ----

ServerSymmetry == Permutations(Server)

\* ---- View (exclude counters from state comparison for symmetry) ----

MCView == <<vars>>

\* ---- Structural Invariants (always checked) ----

\* Counters are non-negative and bounded
CountersValid ==
    /\ electionCount >= 0 /\ electionCount <= MaxElections
    /\ crashCount >= 0 /\ crashCount <= MaxCrashes
    /\ clientWriteCount >= 0 /\ clientWriteCount <= MaxClientWrites

====
