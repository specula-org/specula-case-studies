---------------------------- MODULE Trace ----------------------------
(* Trace validation spec for sofa-jraft *)
(* Replays implementation traces against the base spec *)

EXTENDS base, Naturals, Sequences, IOUtils

(* ===== TRACE LOADING ===== *)

(* Trace log - will be loaded from NDJSON file by TLC *)
(* TLC loads the trace file specified in validation and provides it as TraceLog *)
CONSTANT TraceLog

(* ===== CURSOR AND HELPERS ===== *)

(* Single cursor walks through all events *)
VARIABLE l  \* Trace log index (0-based)

(* Current logline *)
CurrentLogline == IF l < Len(TraceLog) THEN TraceLog[l+1] ELSE Nil

(* Check if current event matches type *)
IsEvent(eventName) == CurrentLogline.event = eventName

(* Check if event is for a specific node *)
IsNodeEvent(eventName, node) == IsEvent(eventName) /\ CurrentLogline.nodeId = node

(* Map implementation role strings to spec constants *)
RoleMap == [x \in {"LEADER", "FOLLOWER", "CANDIDATE"} |->
  IF x = "LEADER" THEN "leader"
  ELSE IF x = "FOLLOWER" THEN "follower"
  ELSE "candidate"]

(* Extract server set from trace *)
ServerSet == {TraceLog[i].nodeId : i \in 1..Len(TraceLog)}

(* ===== BOOTSTRAP STATE ===== *)

(* Initialize from trace's bootstrap state *)
TraceInit ==
  /\ IF Cardinality(ServerSet) > 0
     THEN Servers = ServerSet
     ELSE TRUE
  /\ currentTerm = [s \in Servers |-> 0]
  /\ votedFor = [s \in Servers |-> Nil]
  /\ state = [s \in Servers |-> "follower"]
  /\ leaderId = [s \in Servers |-> Nil]
  /\ persistentTerm = [s \in Servers |-> 0]
  /\ persistentVotedFor = [s \in Servers |-> Nil]
  /\ log = [s \in Servers |-> <<>>]
  /\ commitIndex = [s \in Servers |-> 0]
  /\ lastAppliedIndex = [s \in Servers |-> 0]
  /\ persistentLastApplied = [s \in Servers |-> 0]
  /\ nextIndex = [s \in Servers |-> [f \in Servers |-> 1]]
  /\ matchIndex = [s \in Servers |-> [f \in Servers |-> 0]]
  /\ lastIncludedIndex = [s \in Servers |-> 0]
  /\ lastIncludedTerm = [s \in Servers |-> 0]
  /\ snapshotInProgress = [s \in Servers |-> {}]
  /\ votesReceived = [s \in Servers |-> {}]
  /\ voteTerm = [s \in Servers |-> 0]
  /\ lockedRegions = [s \in Servers |-> {}]
  /\ lockCheckResults = [s \in Servers |-> Nil]
  /\ appendEntriesRetries = [s \in Servers |-> [f \in Servers |-> 0]]
  /\ lastRetryTime = [s \in Servers |-> [f \in Servers |-> 0]]
  /\ messages = {}
  /\ crashedServers = {}
  /\ l = 0

(* ===== POST-STATE VALIDATION ===== *)

(* Validate state matches trace after action *)
ValidatePostState(event) ==
  /\ event.nodeId \in Servers
  /\ IF "currentTerm" \in DOMAIN event.state THEN
       currentTerm[event.nodeId] = event.state.currentTerm
     ELSE TRUE
  /\ IF "state" \in DOMAIN event.state THEN
       state[event.nodeId] = RoleMap[event.state.state]
     ELSE TRUE
  /\ IF "commitIndex" \in DOMAIN event.state THEN
       commitIndex[event.nodeId] = event.state.commitIndex
     ELSE TRUE
  /\ IF "lastAppliedIndex" \in DOMAIN event.state THEN
       lastAppliedIndex[event.nodeId] = event.state.lastAppliedIndex
     ELSE TRUE

(* ===== ACTION WRAPPERS ===== *)

(* Wrapper: ElectSelf action *)
TraceElectSelf ==
  /\ IsNodeEvent("ElectSelf", CurrentLogline.nodeId)
  /\ LET s == CurrentLogline.nodeId IN
       ElectSelf(s)
  /\ ValidatePostState(CurrentLogline)
  /\ l' = l + 1
  /\ UNCHANGED <<persistentTerm, persistentVotedFor, persistentLastApplied>>

(* Wrapper: HandleRequestVoteRequest *)
TraceHandleRequestVoteRequest ==
  /\ IsEvent("HandleRequestVoteRequest")
  /\ LET s == CurrentLogline.nodeId
         src == CurrentLogline.from
         term == CurrentLogline.term
         li == CurrentLogline.lastLogIndex
         lt == CurrentLogline.lastLogTerm
     IN
       HandleRequestVoteRequest(s, src, term, src, li, lt)
  /\ ValidatePostState(CurrentLogline)
  /\ l' = l + 1
  /\ UNCHANGED <<persistentTerm, persistentVotedFor, persistentLastApplied>>

(* Wrapper: HandleRequestVoteResponse *)
TraceHandleRequestVoteResponse ==
  /\ IsEvent("HandleRequestVoteResponse")
  /\ LET s == CurrentLogline.nodeId
         src == CurrentLogline.from
         term == CurrentLogline.term
         vg == CurrentLogline.voteGranted
     IN
       HandleRequestVoteResponse(s, src, term, vg)
  /\ ValidatePostState(CurrentLogline)
  /\ l' = l + 1
  /\ UNCHANGED <<persistentTerm, persistentVotedFor, persistentLastApplied>>

(* Wrapper: BecomeLeader *)
TraceBecomeLeader ==
  /\ IsNodeEvent("BecomeLeader", CurrentLogline.nodeId)
  /\ BecomeLeader(CurrentLogline.nodeId)
  /\ ValidatePostState(CurrentLogline)
  /\ l' = l + 1
  /\ UNCHANGED <<persistentTerm, persistentVotedFor, persistentLastApplied>>

(* Wrapper: HandleAppendEntriesRequest *)
TraceHandleAppendEntriesRequest ==
  /\ IsEvent("HandleAppendEntriesRequest")
  /\ LET s == CurrentLogline.nodeId
         src == CurrentLogline.from
         term == CurrentLogline.term
         lc == CurrentLogline.leaderCommit
         pli == CurrentLogline.prevLogIndex
         plt == CurrentLogline.prevLogTerm
         entries == IF "entries" \in DOMAIN CurrentLogline
                    THEN CurrentLogline.entries
                    ELSE <<>>
     IN
       HandleAppendEntriesRequest(s, src, term, lc, pli, plt, entries)
  /\ ValidatePostState(CurrentLogline)
  /\ l' = l + 1
  /\ UNCHANGED <<persistentTerm, persistentVotedFor, persistentLastApplied>>

(* Wrapper: HandleAppendEntriesResponse *)
TraceHandleAppendEntriesResponse ==
  /\ IsEvent("HandleAppendEntriesResponse")
  /\ LET s == CurrentLogline.nodeId
         src == CurrentLogline.from
         term == CurrentLogline.term
         success == CurrentLogline.success
         mi == CurrentLogline.matchIndex
     IN
       HandleAppendEntriesResponse(s, src, term, success, mi)
  /\ ValidatePostState(CurrentLogline)
  /\ l' = l + 1
  /\ UNCHANGED <<persistentTerm, persistentVotedFor, persistentLastApplied>>

(* Wrapper: HandleInstallSnapshotRequest *)
TraceHandleInstallSnapshotRequest ==
  /\ IsEvent("HandleInstallSnapshotRequest")
  /\ LET s == CurrentLogline.nodeId
         src == CurrentLogline.from
         term == CurrentLogline.term
         li == CurrentLogline.lastIncludedIndex
         lt == CurrentLogline.lastIncludedTerm
     IN
       HandleInstallSnapshotRequest(s, src, term, li, lt)
  /\ ValidatePostState(CurrentLogline)
  /\ l' = l + 1
  /\ UNCHANGED <<persistentTerm, persistentVotedFor, persistentLastApplied>>

(* Wrapper: AdvanceCommitIndex *)
TraceAdvanceCommitIndex ==
  /\ IsNodeEvent("AdvanceCommitIndex", CurrentLogline.nodeId)
  /\ AdvanceCommitIndex(CurrentLogline.nodeId)
  /\ ValidatePostState(CurrentLogline)
  /\ l' = l + 1
  /\ UNCHANGED <<persistentTerm, persistentVotedFor, persistentLastApplied>>

(* Wrapper: ApplyCommittedEntries *)
TraceApplyCommittedEntries ==
  /\ IsNodeEvent("ApplyCommittedEntries", CurrentLogline.nodeId)
  /\ ApplyCommittedEntries(CurrentLogline.nodeId)
  /\ ValidatePostState(CurrentLogline)
  /\ l' = l + 1
  /\ UNCHANGED <<persistentTerm, persistentVotedFor>>

(* Wrapper: Crash *)
TraceCrash ==
  /\ IsNodeEvent("Crash", CurrentLogline.nodeId)
  /\ Crash(CurrentLogline.nodeId)
  /\ l' = l + 1
  /\ UNCHANGED <<persistentTerm, persistentVotedFor, persistentLastApplied>>

(* ===== SILENT ACTIONS ===== *)

(* Silent action: PersistTermAndVote (no trace event) *)
SilentPersistTermAndVote ==
  /\ l < Len(TraceLog)
  /\ \E s \in Servers : PersistTermAndVote(s)
  /\ UNCHANGED l

(* Silent action: PersistLastApplied (no trace event) *)
SilentPersistLastApplied ==
  /\ l < Len(TraceLog)
  /\ \E s \in Servers : PersistLastApplied(s)
  /\ UNCHANGED l

(* Silent action: Recover (no trace event) *)
SilentRecover ==
  /\ l < Len(TraceLog)
  /\ \E s \in Servers : Recover(s)
  /\ UNCHANGED l

(* ===== TRACE NEXT STATE ===== *)

TraceNext ==
  \/ (l <= Len(TraceLog) /\
      (\/ TraceElectSelf
       \/ TraceHandleRequestVoteRequest
       \/ TraceHandleRequestVoteResponse
       \/ TraceBecomeLeader
       \/ TraceHandleAppendEntriesRequest
       \/ TraceHandleAppendEntriesResponse
       \/ TraceHandleInstallSnapshotRequest
       \/ TraceAdvanceCommitIndex
       \/ TraceApplyCommittedEntries
       \/ TraceCrash))
  \/ SilentPersistTermAndVote
  \/ SilentPersistLastApplied
  \/ SilentRecover

(* ===== TEMPORAL PROPERTIES ===== *)

(* Trace must be fully consumed *)
TraceMatched == <>(l > Len(TraceLog))

========================================================================
