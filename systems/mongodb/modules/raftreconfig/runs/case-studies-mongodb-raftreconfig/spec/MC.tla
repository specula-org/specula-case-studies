---- MODULE MC ----
\*****************************************************************************
\* Model checking wrapper for MongoRaftReconfig base spec.
\* Counter-bounded fault-injection actions, symmetry reduction, and
\* structural invariants for exhaustive state space exploration.
\*****************************************************************************

EXTENDS base

\* Counter limits for fault-injection/non-deterministic actions.
CONSTANTS
    MaxTermLimit,        \* Max number of election terms (bounds WinElection)
    ForceReconfigLimit,  \* Max force reconfigs (Family 1)
    ReconfigLimit,       \* Max safe reconfigs
    ShutDownLimit,       \* Max node shutdowns
    ClientRequestLimit,  \* Max client writes
    RemoveNewlyAddedLimit \* Max newlyAdded removals (Family 5)

\* Fault injection counters.
VARIABLE faultCounters

\* Access individual counters.
termCount           == faultCounters.term
forceReconfigCount  == faultCounters.forceReconfig
reconfigCount       == faultCounters.reconfig
shutDownCount       == faultCounters.shutDown
clientRequestCount  == faultCounters.clientRequest
removeNewlyAddedCount == faultCounters.removeNewlyAdded

mcVars == <<vars, faultCounters>>

-------------------------------------------------------------------------------------------

(******************************************************************************)
(* Counter-bounded wrappers                                                   *)
(******************************************************************************)

\* Bound election terms.
MCWinElection(i) ==
    /\ termCount < MaxTermLimit
    /\ WinElection(i)
    /\ faultCounters' = [faultCounters EXCEPT !.term = @ + 1]

\* Bound force reconfigs (primary fault injection — Family 1).
MCForceReconfig(i) ==
    /\ forceReconfigCount < ForceReconfigLimit
    /\ ForceReconfig(i)
    /\ faultCounters' = [faultCounters EXCEPT !.forceReconfig = @ + 1]

\* Bound safe reconfigs.
MCReconfig(i) ==
    /\ reconfigCount < ReconfigLimit
    /\ Reconfig(i)
    /\ faultCounters' = [faultCounters EXCEPT !.reconfig = @ + 1]

\* Bound node shutdowns.
MCShutDown(i) ==
    /\ shutDownCount < ShutDownLimit
    /\ ShutDown(i)
    /\ faultCounters' = [faultCounters EXCEPT !.shutDown = @ + 1]

\* Bound client requests.
MCClientRequest(i) ==
    /\ clientRequestCount < ClientRequestLimit
    /\ ClientRequest(i)
    /\ faultCounters' = [faultCounters EXCEPT !.clientRequest = @ + 1]

\* Bound newlyAdded removal.
MCRemoveNewlyAdded(i, j) ==
    /\ removeNewlyAddedCount < RemoveNewlyAddedLimit
    /\ RemoveNewlyAdded(i, j)
    /\ faultCounters' = [faultCounters EXCEPT !.removeNewlyAdded = @ + 1]

\* Unconstrained reactive actions (no bounding needed).
MCCompleteDrain(i)        == CompleteDrain(i) /\ UNCHANGED faultCounters
MCSendConfig(i, j)        == SendConfig(i, j) /\ UNCHANGED faultCounters
MCGetEntry(i, j)           == GetEntry(i, j) /\ UNCHANGED faultCounters
MCRollbackEntries(i, j)   == RollbackEntries(i, j) /\ UNCHANGED faultCounters
MCCommitEntry(i)           == CommitEntry(i) /\ UNCHANGED faultCounters
MCUpdateTermsOnNodes(i, j) == UpdateTermsOnNodes(i, j) /\ UNCHANGED faultCounters

-------------------------------------------------------------------------------------------

(******************************************************************************)
(* MC Init and Next                                                           *)
(******************************************************************************)

MCInit ==
    /\ Init
    /\ faultCounters = [
        term           |-> 0,
        forceReconfig  |-> 0,
        reconfig       |-> 0,
        shutDown       |-> 0,
        clientRequest  |-> 0,
        removeNewlyAdded |-> 0
       ]

MCNext ==
    \* Counter-bounded actions (fault injection / non-deterministic).
    \/ \E s \in AliveNodes(Server) : MCWinElection(s)
    \/ \E s \in AliveNodes(Server) : MCForceReconfig(s)
    \/ \E s \in AliveNodes(Server) : MCReconfig(s)
    \/ \E s \in AliveNodes(Server) : MCShutDown(s)
    \/ \E s \in AliveNodes(Server) : MCClientRequest(s)
    \/ \E s, t \in AliveNodes(Server) : MCRemoveNewlyAdded(s, t)
    \* Unconstrained reactive actions.
    \/ \E s \in AliveNodes(Server) : MCCompleteDrain(s)
    \/ \E s, t \in AliveNodes(Server) : MCSendConfig(s, t)
    \/ \E s, t \in AliveNodes(Server) : MCGetEntry(s, t)
    \/ \E s, t \in AliveNodes(Server) : MCRollbackEntries(s, t)
    \/ \E s \in AliveNodes(Server) : MCCommitEntry(s)
    \/ \E s, t \in AliveNodes(Server) : MCUpdateTermsOnNodes(s, t)

MCSpec == MCInit /\ [][MCNext]_mcVars

-------------------------------------------------------------------------------------------

(******************************************************************************)
(* Symmetry reduction                                                         *)
(******************************************************************************)

\* Symmetry set for Server (when Arbiter = {}).
\* Do NOT use symmetry if Arbiter is non-empty (breaks symmetry).
ModelSymmetry == Permutations(Server)

-------------------------------------------------------------------------------------------

(******************************************************************************)
(* State space constraints                                                    *)
(******************************************************************************)

\* Limit total log length to prevent unbounded growth.
MaxLogLen == 4

LogLenConstraint ==
    \A s \in Server : Len(log[s]) <= MaxLogLen

\* Limit committed entries set size.
MaxCommittedEntries == 6

CommittedEntriesConstraint ==
    Cardinality(immediatelyCommitted) <= MaxCommittedEntries

StateConstraint == LogLenConstraint /\ CommittedEntriesConstraint

=============================================================================
