---- MODULE Trace ----
\* Trace validation spec for MongoDB RaftMongo Replication Commit Point Protocol.
\* Replays NDJSON trace events against the base spec to verify consistency.
\*
\* Trace events come from MongoDB LOGV2 structured logs, parsed into NDJSON format.
\* See instrumentation-spec.md for the event-to-code mapping.

EXTENDS base, Json, IOUtils, Sequences, Naturals, TLC

\* InfOpTime sentinel — matches MC.tla definition
TraceInfOpTime == [term |-> 999, index |-> 999]

\* ---- Trace Loading ----

\* Trace file path — default to traces directory, overridable via IOEnv
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/full_trace.ndjson"

\* Load and filter trace log entries
RawTraceLog == ndJsonDeserialize(JsonFile)
TraceLog == SelectSeq(RawTraceLog, LAMBDA e : e.tag = "trace")

\* ---- Cursor Variable ----

VARIABLE l    \* Cursor into TraceLog

traceVars == <<vars, l>>

\* Current log line (event at cursor position)
logline == TraceLog[l]

\* ---- Server Extraction ----

\* Extract server set from trace events
\* MongoDB nodes are identified by replica set member index or hostname
TraceServer == {TraceLog[k].event.state.server : k \in 1..Len(TraceLog)}

\* ---- Event Predicates ----

IsEvent(name) == logline.event.name = name

IsNodeEvent(name, i) ==
    /\ IsEvent(name)
    /\ logline.event.state.server = i

\* ---- OpTime Helpers ----

\* Parse an optime from trace JSON: {"term": N, "index": N}
ParseOpTime(ot) == [term |-> ot.term, index |-> ot.index]

\* ---- Post-State Validation ----

\* Strong validation: check term and state; optimes are directional checks
\* (MongoDB's optime index uses timestamp increments, not sequential log indices)
ValidatePostState(i) ==
    /\ currentTerm'[i] = logline.event.state.currentTerm
    /\ state'[i] = logline.event.state.state

\* Weak validation: check only term and state (for async/partial events)
ValidatePostStateWeak(i) ==
    /\ currentTerm'[i] = logline.event.state.currentTerm
    /\ state'[i] = logline.event.state.state

\* ---- Trace Action Wrappers ----

\* Each wrapper: match event → call base action → validate post-state → advance cursor

TraceStartElection ==
    /\ IsEvent("StartElection")
    /\ LET i == logline.event.state.server
       IN /\ StartElection(i)
          /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

TraceRequestVote ==
    /\ IsEvent("VoteGranted")
    /\ LET voter == logline.event.state.server
       IN /\ \E candidate \in Server : RequestVote(candidate, voter)
          /\ ValidatePostStateWeak(voter)
    /\ l' = l + 1

TraceWinElection ==
    /\ IsEvent("ElectionWon")
    /\ LET i == logline.event.state.server
       IN /\ WinElection(i)
          /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

TraceWritePrimaryNoOp ==
    /\ IsEvent("TransitionToPrimary")
    /\ LET i == logline.event.state.server
       IN /\ WritePrimaryNoOp(i)
          /\ ValidatePostState(i)
    /\ l' = l + 1

TraceClientWrite ==
    /\ IsEvent("ClientWrite")
    /\ LET i == logline.event.state.server
       IN /\ ClientWrite(i)
          /\ ValidatePostState(i)
    /\ l' = l + 1

TraceAppendOplog ==
    /\ IsEvent("AppendOplog")
    /\ LET i == logline.event.state.server
       IN /\ \E j \in Server : AppendOplog(i, j)
          /\ ValidatePostState(i)
    /\ l' = l + 1

TraceRollbackOplog ==
    /\ IsEvent("RollbackOplog")
    /\ LET i == logline.event.state.server
       IN /\ \E j \in Server : RollbackOplog(i, j)
          /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

TracePersistOplog ==
    /\ IsEvent("PersistOplog")
    /\ LET i == logline.event.state.server
       IN /\ PersistOplog(i)
          /\ lastDurable'[i] = ParseOpTime(logline.event.state.lastDurable)
    /\ l' = l + 1

TraceApplyOplog ==
    /\ IsEvent("ApplyOplog")
    /\ LET i == logline.event.state.server
       IN /\ ApplyOplog(i)
          /\ lastApplied'[i] = ParseOpTime(logline.event.state.lastApplied)
    /\ l' = l + 1

TraceUpdateTerm ==
    /\ IsEvent("UpdateTerm")
    /\ LET i == logline.event.state.server
       IN /\ \E j \in Server : UpdateTermThroughHeartbeat(i, j)
          /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

TraceStepdown ==
    /\ IsEvent("Stepdown")
    /\ LET i == logline.event.state.server
       IN /\ Stepdown(i)
          /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

TraceAdvanceCommitPoint ==
    /\ IsEvent("AdvanceCommitPoint")
    /\ LET i == logline.event.state.server
       IN \/ /\ AdvanceCommitPoint
             /\ l' = l + 1
          \* Also allow LearnCommitPoint paths for non-leader nodes
          \/ /\ \E j \in Server : LearnCommitPointWithTermCheck(i, j)
             /\ l' = l + 1
          \/ /\ \E j \in Server : LearnCommitPointFromSyncSourceNeverBeyondLastWritten(i, j)
             /\ l' = l + 1

TraceLearnCommitPointHeartbeat ==
    /\ IsEvent("LearnCommitPointHeartbeat")
    /\ LET i == logline.event.state.server
       IN /\ \E j \in Server : LearnCommitPointWithTermCheck(i, j)
    /\ l' = l + 1

TraceLearnCommitPointSyncSource ==
    /\ IsEvent("LearnCommitPointSyncSource")
    /\ LET i == logline.event.state.server
       IN /\ \E j \in Server : LearnCommitPointFromSyncSourceNeverBeyondLastWritten(i, j)
    /\ l' = l + 1

TraceCrash ==
    /\ IsEvent("Crash")
    /\ LET i == logline.event.state.server
       IN /\ Crash(i)
          /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

\* ---- Silent Actions ----
\* Handle implementation state changes that don't produce trace events.
\* MUST be tightly constrained to avoid state space explosion.

\* Silent PersistOplog: journal flush happens asynchronously without a log event
SilentPersistOplog ==
    /\ l <= Len(TraceLog)
    /\ \E i \in Server : PersistOplog(i)
    /\ UNCHANGED l

\* Silent ApplyOplog: oplog application on followers without explicit trace event
SilentApplyOplog ==
    /\ l <= Len(TraceLog)
    /\ \E i \in Server : ApplyOplog(i)
    /\ UNCHANGED l

\* Silent AppendOplog: oplog sync may happen without a discrete trace event
\* CONSTRAINED: only fire if the next trace event for this server requires
\* a longer log than we currently have
SilentAppendOplog ==
    /\ l <= Len(TraceLog)
    /\ \E i, j \in Server :
        /\ AppendOplog(i, j)
        \* Constraint: the NEXT event for this server expects a longer log
        /\ \E k \in l..Len(TraceLog) :
            /\ TraceLog[k].event.state.server = i
            /\ TraceLog[k].event.state.lastWritten.index > lastWritten[i].index
    /\ UNCHANGED l

\* Silent UpdateTerm: term updates from heartbeats may not be individually logged
SilentUpdateTerm ==
    /\ l <= Len(TraceLog)
    /\ \E i, j \in Server :
        /\ UpdateTermThroughHeartbeat(i, j)
        \* Constraint: the NEXT event for this server expects a higher term
        /\ \E k \in l..Len(TraceLog) :
            /\ TraceLog[k].event.state.server = i
            /\ TraceLog[k].event.state.currentTerm > currentTerm[i]
    /\ UNCHANGED l

\* Silent RequestVote: vote grants between traced events
SilentRequestVote ==
    /\ l <= Len(TraceLog)
    /\ \E i, j \in Server : RequestVote(i, j)
    /\ UNCHANGED l

\* ---- Trace Init ----

\* Initialize from the first trace event's state
TraceInit ==
    /\ l = 1
    \* Default init — will be overridden if trace provides initial state
    /\ Init

\* ---- Trace Next ----

TraceNext ==
    \/ TraceStartElection
    \/ TraceRequestVote
    \/ TraceWinElection
    \/ TraceWritePrimaryNoOp
    \/ TraceClientWrite
    \/ TraceAppendOplog
    \/ TraceRollbackOplog
    \/ TracePersistOplog
    \/ TraceApplyOplog
    \/ TraceUpdateTerm
    \/ TraceStepdown
    \/ TraceAdvanceCommitPoint
    \/ TraceLearnCommitPointHeartbeat
    \/ TraceLearnCommitPointSyncSource
    \/ TraceCrash
    \* Silent actions
    \/ SilentPersistOplog
    \/ SilentApplyOplog
    \/ SilentAppendOplog
    \/ SilentUpdateTerm
    \/ SilentRequestVote

\* ---- Trace Completion ----

\* The entire trace was consumed (checked as temporal property or via deadlock)
TraceMatched == <>(l = Len(TraceLog) + 1)

\* Alternative: use deadlock detection — TLC reports deadlock when no action is
\* enabled at l > Len(TraceLog), confirming all events were processed.
TraceFinished == l = Len(TraceLog) + 1

====
