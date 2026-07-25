---------------------------- MODULE MC ----------------------------
(* Model checking wrapper for sofa-jraft *)
(* Bounds fault-injection actions while preserving base spec logic *)

EXTENDS base, Naturals

(* ===== CONSTANTS FOR FAULT INJECTION BOUNDS ===== *)
CONSTANT MaxTermLimit
CONSTANT MaxTimeoutLimit
CONSTANT MaxCrashLimit
CONSTANT MaxLoseLimit
CONSTANT MaxRetryLimit

(* ===== FAULT COUNTER VARIABLES ===== *)
VARIABLE faultCounters

faultVars == <<faultCounters>>

vars == <<currentTerm, votedFor, state, leaderId, persistentTerm,
           persistentVotedFor, log, commitIndex, lastAppliedIndex,
           persistentLastApplied, nextIndex, matchIndex,
           lastIncludedIndex, lastIncludedTerm, snapshotInProgress,
           votesReceived, voteTerm, lockedRegions, lockCheckResults,
           appendEntriesRetries, lastRetryTime, messages, crashedServers,
           faultCounters>>

(* Counter access helpers *)
GetCounter(name) == faultCounters[name]
IncrementCounter(name) == [faultCounters EXCEPT ![name] = faultCounters[name] + 1]

(* ===== BOUNDED FAULT-INJECTION ACTIONS ===== *)

(* Bounded election timeout *)
MCElectSelf(s) ==
  /\ GetCounter("election") < MaxTimeoutLimit
  /\ ElectSelf(s)
  /\ faultCounters' = IncrementCounter("election")

(* Bounded crash *)
MCCrash(s) ==
  /\ GetCounter("crash") < MaxCrashLimit
  /\ Crash(s)
  /\ faultCounters' = IncrementCounter("crash")

(* Bounded message loss *)
MCLoseMessage(msg) ==
  /\ GetCounter("lose") < MaxLoseLimit
  /\ LoseMessage(msg)
  /\ faultCounters' = IncrementCounter("lose")

(* ===== PASSTHROUGH ACTIONS (NO BOUND) ===== *)

(* Deterministic persistence and recovery - no bound *)
MCPersistTermAndVote(s) ==
  /\ PersistTermAndVote(s)
  /\ UNCHANGED faultVars

MCPersistLastApplied(s) ==
  /\ PersistLastApplied(s)
  /\ UNCHANGED faultVars

MCRecover(s) ==
  /\ Recover(s)
  /\ UNCHANGED faultVars

(* Message handlers - no bound (they react to existing messages) *)
MCHandleRequestVoteRequest(s, src, term, candidateId, lastLogIndex, lastLogTerm) ==
  /\ HandleRequestVoteRequest(s, src, term, candidateId, lastLogIndex, lastLogTerm)
  /\ UNCHANGED faultVars

MCHandleRequestVoteResponse(s, src, term, voteGranted, matchIdx) ==
  /\ HandleRequestVoteResponse(s, src, term, voteGranted)
  /\ UNCHANGED faultVars

MCBecomeLeader(s) ==
  /\ BecomeLeader(s)
  /\ UNCHANGED faultVars

MCHandleAppendEntriesRequest(s, src, term, leaderCommit, prevLogIndex,
                              prevLogTerm, entries) ==
  /\ HandleAppendEntriesRequest(s, src, term, leaderCommit, prevLogIndex, prevLogTerm, entries)
  /\ UNCHANGED faultVars

MCHandleAppendEntriesResponse(s, src, term, success, matchIdx) ==
  /\ HandleAppendEntriesResponse(s, src, term, success, matchIdx)
  /\ UNCHANGED faultVars

MCHandleInstallSnapshotRequest(s, src, term, lastIncludedIdx, lastIncludedTermArg) ==
  /\ HandleInstallSnapshotRequest(s, src, term, lastIncludedIdx, lastIncludedTermArg)
  /\ UNCHANGED faultVars

MCAdvanceCommitIndex(s) ==
  /\ AdvanceCommitIndex(s)
  /\ UNCHANGED faultVars

MCApplyCommittedEntries(s) ==
  /\ ApplyCommittedEntries(s)
  /\ UNCHANGED faultVars

(* ===== MC INITIALIZATION ===== *)

MCInit ==
  /\ Init
  /\ faultCounters = [election |-> 0, crash |-> 0, lose |-> 0, retry |-> 0]

(* ===== MC NEXT STATE ===== *)

MCNext ==
  \/ \E s \in Servers : MCElectSelf(s)
  \/ \E s \in Servers : MCPersistTermAndVote(s)
  \/ \E s \in Servers, src \in Servers, term \in 0..TermLimit :
       \E li, lt \in 0..LogIndexLimit :
         MCHandleRequestVoteRequest(s, src, term, src, li, lt)
  \/ \E s \in Servers, src \in Servers, term \in 0..TermLimit, vg \in BOOLEAN :
       \E mi \in 0..LogIndexLimit :
         MCHandleRequestVoteResponse(s, src, term, vg, mi)
  \/ \E s \in Servers : MCBecomeLeader(s)
  \/ \E s \in Servers, src \in Servers, term \in 0..TermLimit, lc \in 0..LogIndexLimit :
       \E pli, plt \in 0..LogIndexLimit, entries \in {<<>>, <<[term |-> 0]>>, <<[term |-> 1]>>, <<[term |-> 2]>>, <<[term |-> 3]>>, <<[term |-> 4]>>} :
         MCHandleAppendEntriesRequest(s, src, term, lc, pli, plt, entries)
  \/ \E s \in Servers, src \in Servers, term \in 0..TermLimit, success \in BOOLEAN :
       \E mi \in 0..LogIndexLimit :
         MCHandleAppendEntriesResponse(s, src, term, success, mi)
  \/ \E s \in Servers, src \in Servers, term \in 0..TermLimit :
       \E li, lt \in 0..LogIndexLimit :
         MCHandleInstallSnapshotRequest(s, src, term, li, lt)
  \/ \E s \in Servers : MCAdvanceCommitIndex(s)
  \/ \E s \in Servers : MCApplyCommittedEntries(s)
  \/ \E s \in Servers : MCPersistLastApplied(s)
  \/ \E msg \in messages : MCLoseMessage(msg)
  \/ \E s \in Servers : MCCrash(s)
  \/ \E s \in Servers : MCRecover(s)

(* ===== SYMMETRY REDUCTION ===== *)

(* Servers are symmetric - enables TLC to collapse permutations *)
Symmetry == Permutations(Servers)

(* Exclude fault counters from symmetry view *)
ViewMC == << currentTerm, votedFor, state, leaderId, persistentTerm,
             persistentVotedFor, log, commitIndex, lastAppliedIndex,
             persistentLastApplied, nextIndex, matchIndex,
             lastIncludedIndex, lastIncludedTerm, snapshotInProgress,
             votesReceived, voteTerm, messages, crashedServers >>

(* ===== MESSAGE BUFFER CONSTRAINT ===== *)

(* Keep message buffer bounded *)
MessageBoundary ==
  Cardinality(messages) <= 20

(* ===== SAFETY INVARIANTS FOR MC ===== *)

(* Core Raft safety invariants *)
MCElectionSafety ==
  \A s1, s2 \in Servers : (state[s1] = "leader" /\ state[s2] = "leader" /\
                            currentTerm[s1] = currentTerm[s2]) =>
                           s1 = s2

MCNoDoubleVote ==
  \A s1, s2 \in Servers :
    (votedFor[s1] = s2 /\ votedFor[s1] /= Nil) =>
    \A s3 \in Servers \ {s1} : votedFor[s3] /= s1 \/ votedFor[s3] = Nil

MCLogMatching ==
  \A s1, s2 \in Servers, idx \in 1..LogIndexLimit :
    (GetLogEntry(s1, idx) /= Nil /\ GetLogEntry(s2, idx) /= Nil /\
     GetLogEntry(s1, idx).term = GetLogEntry(s2, idx).term) =>
    (GetLogEntry(s1, idx) = GetLogEntry(s2, idx))

MCPersistenceConsistency ==
  \A s \in Servers : (s \in crashedServers) =>
                     (currentTerm[s] >= persistentTerm[s])

MCValidState ==
  \A s \in Servers : state[s] \in {"leader", "follower", "candidate"}

(* Family 1: Voted for must be persisted before leader assumption *)
MCVotedForPersistence ==
  \A s \in Servers : (state[s] = "leader") =>
                     (persistentVotedFor[s] = s)

(* ===== EXTENSION INVARIANTS FOR BUG FAMILIES ===== *)
(* These are commented out during standard convergence; uncommented during bug hunting *)

(* Family 1: Non-atomic persistence *)
\* MCNonAtomicPersistence ==
\*   \A s \in Servers : (currentTerm[s] > persistentTerm[s]) =>
\*                      (votedFor[s] = Nil \/ votedFor[s] = persistentVotedFor[s])

(* Family 3: Double voting during ABA race *)
\* MCDoubleVoteABA ==
\*   \A s1, s2 \in Servers : (votedFor[s1] = s2 /\ votedFor[s1] /= Nil) =>
\*                           \A s3 \in Servers \ {s1} : (votedFor[s3] = s1) => FALSE

(* Family 5: Snapshot state machine separation *)
\* MCSnapshotSeparation ==
\*   \A s \in Servers : \A f \in Servers : (f \in snapshotInProgress[s]) =>
\*                                         (matchIndex[s][f] <= lastIncludedIndex[s])

(* Family 8: Quorum safety with vote races *)
\* MCQuorumSafety ==
\*   \A s \in Servers : (state[s] = "leader") =>
\*                      (Cardinality(votesReceived[s]) \in Quorum)

(* Family 9: FSM application safety *)
\* MCFSMApplicationSafety ==
\*   \A s \in Servers : lastAppliedIndex[s] <= GetLastIndex(s)

========================================================================
