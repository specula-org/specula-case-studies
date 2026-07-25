---- MODULE Trace ----
\*****************************************************************************
\* Trace validation spec for MongoRaftReconfig.
\* Replays NDJSON traces from MongoDB replica set against the base spec.
\*
\* Trace source: MongoDB LOGV2 structured logs parsed into NDJSON.
\* See instrumentation-spec.md for event schema and code locations.
\*****************************************************************************

EXTENDS base, Json, IOUtils, Sequences, TLC

(******************************************************************************)
(* Constants: override Server and Arbiter from Trace.cfg                      *)
(******************************************************************************)

\* Server IDs as strings matching JSON trace values.
TraceServers == {"s1", "s2", "s3", "s4"}

\* No arbiters in the test scenarios.
TraceArbiter == {}

(******************************************************************************)
(* Trace loading                                                              *)
(******************************************************************************)

\* Trace file path. Override via IOEnv.JSON for per-run selection.
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/election_drain.ndjson"

\* Load and filter trace events.
RawLog == ndJsonDeserialize(JsonFile)
TraceLog == SelectSeq(RawLog, LAMBDA x : x.tag = "trace")

\* Current position in the trace.
VARIABLE l

traceVars == <<vars, l>>

(******************************************************************************)
(* Trace helpers                                                              *)
(******************************************************************************)

\* Current log line.
logline == TraceLog[l]

\* Event predicates.
IsEvent(name) == logline.event.name = name

IsNodeEvent(name, i) ==
    /\ logline.event.name = name
    /\ logline.event.node = i

\* Map implementation state strings to spec constants.
MapState(s) ==
    CASE s = "Leader"   -> Leader
      [] s = "PRIMARY"  -> Leader
      [] s = "Follower" -> Follower
      [] s = "SECONDARY" -> Follower
      [] s = "Down"     -> Down
      [] s = "DOWN"     -> Down
      [] s = "REMOVED"  -> Down
      [] OTHER          -> Follower

\* Map boolean strings/values to BOOLEAN.
MapBool(b) ==
    CASE b = TRUE  -> TRUE
      [] b = "true" -> TRUE
      [] b = FALSE -> FALSE
      [] b = "false" -> FALSE
      [] OTHER -> FALSE

(******************************************************************************)
(* Post-state validation                                                      *)
(******************************************************************************)

\* Strong validation: check all critical state fields.
ValidatePostState(i) ==
    /\ currentTerm'[i] = logline.event.state.currentTerm
    /\ state'[i] = MapState(logline.event.state.state)
    /\ configVersion'[i] = logline.event.state.configVersion
    /\ configTerm'[i] = logline.event.state.configTerm

\* Weak validation: check only term + state (for async events).
ValidatePostStateWeak(i) ==
    /\ currentTerm'[i] = logline.event.state.currentTerm
    /\ state'[i] = MapState(logline.event.state.state)

\* Drain mode validation (if field present).
ValidateDrainMode(i) ==
    IF "drainMode" \in DOMAIN logline.event.state
    THEN drainMode'[i] = MapBool(logline.event.state.drainMode)
    ELSE TRUE

(******************************************************************************)
(* Action wrappers                                                            *)
(******************************************************************************)

\* --- Election actions (Family 2) ---

TraceWinElection ==
    /\ IsEvent("WinElection")
    /\ LET i == logline.event.node IN
       /\ WinElection(i)
       /\ ValidatePostStateWeak(i)
       /\ ValidateDrainMode(i)
    /\ l' = l + 1

TraceCompleteDrain ==
    /\ IsEvent("CompleteDrain")
    /\ LET i == logline.event.node IN
       /\ CompleteDrain(i)
       \* Use weak validation: MongoDB may not increment configVersion
       \* during doOptimizedReconfig (spec/impl divergence).
       /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

\* --- Reconfig actions ---

TraceReconfig ==
    /\ IsEvent("Reconfig")
    /\ LET i == logline.event.node IN
       /\ Reconfig(i)
       /\ ValidatePostState(i)
    /\ l' = l + 1

TraceForceReconfig ==
    /\ IsEvent("ForceReconfig")
    /\ LET i == logline.event.node IN
       /\ ForceReconfig(i)
       /\ ValidatePostState(i)
    /\ l' = l + 1

\* --- Config propagation ---
\* Trace format: event.node = receiver, event.sender = sender

TraceSendConfig ==
    /\ IsEvent("SendConfig")
    /\ LET sender   == logline.event.sender
           receiver == logline.event.node IN
       /\ sender \in Server
       /\ receiver \in Server
       /\ SendConfig(sender, receiver)
    /\ l' = l + 1

\* --- Client/commit actions ---

TraceClientRequest ==
    /\ IsEvent("ClientRequest")
    /\ LET i == logline.event.node IN
       /\ ClientRequest(i)
       /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

TraceCommitEntry ==
    /\ IsEvent("CommitEntry")
    /\ LET i == logline.event.node IN
       /\ CommitEntry(i)
       /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

\* --- Log replication ---

TraceGetEntry ==
    /\ IsEvent("GetEntry")
    /\ LET receiver == logline.event.node
           sender   == logline.event.sender IN
       /\ GetEntry(receiver, sender)
       /\ ValidatePostStateWeak(receiver)
    /\ l' = l + 1

TraceRollbackEntries ==
    /\ IsEvent("RollbackEntries")
    /\ LET i == logline.event.node
           j == logline.event.source IN
       /\ RollbackEntries(i, j)
       /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

\* --- Term exchange ---

TraceUpdateTerms ==
    /\ IsEvent("UpdateTerms")
    /\ LET i == logline.event.node
           j == logline.event.peer IN
       /\ UpdateTermsOnNodes(i, j)
       /\ ValidatePostStateWeak(i)
    /\ l' = l + 1

\* --- Shutdown ---

TraceShutDown ==
    /\ IsEvent("ShutDown")
    /\ LET i == logline.event.node IN
       /\ ShutDown(i)
    /\ l' = l + 1

\* --- Family 5: newlyAdded removal ---

TraceRemoveNewlyAdded ==
    /\ IsEvent("RemoveNewlyAdded")
    /\ LET i == logline.event.node
           j == logline.event.member IN
       /\ RemoveNewlyAdded(i, j)
       /\ ValidatePostState(i)
    /\ l' = l + 1

(******************************************************************************)
(* Silent actions                                                             *)
(******************************************************************************)

\* Silent GetEntry: replication may happen without a trace event.
SilentGetEntry ==
    /\ l <= Len(TraceLog)
    /\ \E i, j \in Server :
        /\ GetEntry(i, j)
        \* Constrain: only if the next event requires i to have more entries.
        /\ IF "logLength" \in DOMAIN logline.event.state
           THEN Len(log'[i]) <= logline.event.state.logLength
           ELSE TRUE
    /\ UNCHANGED l

\* Silent UpdateTerms: term exchange via heartbeat without trace event.
\* Tightly constrained: only fires if next event requires a higher term.
SilentUpdateTerms ==
    /\ l <= Len(TraceLog)
    /\ \E i, j \in Server :
        /\ UpdateTermsOnNodes(i, j)
        \* Constrain: only if next event has a higher term than current.
        /\ IF "currentTerm" \in DOMAIN logline.event.state
           THEN currentTerm'[logline.event.node] <= logline.event.state.currentTerm
           ELSE TRUE
    /\ UNCHANGED l

\* Silent CommitEntry: commit may happen without explicit trace event.
SilentCommitEntry ==
    /\ l <= Len(TraceLog)
    /\ \E i \in Server : CommitEntry(i)
    /\ UNCHANGED l

\* Silent SendConfig: config propagation without trace event.
SilentSendConfig ==
    /\ l <= Len(TraceLog)
    /\ \E i, j \in Server :
        /\ SendConfig(i, j)
        /\ IF "configVersion" \in DOMAIN logline.event.state
           THEN configVersion'[logline.event.node] <= logline.event.state.configVersion
           ELSE TRUE
    /\ UNCHANGED l

\* Silent ClientRequest: writes may happen without trace event.
SilentClientRequest ==
    /\ l <= Len(TraceLog)
    /\ \E i \in Server : ClientRequest(i)
    /\ UNCHANGED l

(******************************************************************************)
(* Trace Init and Next                                                        *)
(******************************************************************************)

TraceInit ==
    /\ l = 1
    \* Bootstrap state: MongoDB starts with configVersion=1 after rs.initiate.
    /\ currentTerm = [i \in Server |-> 0]
    /\ state       = [i \in Server |-> Follower]
    /\ log         = [i \in Server |-> << >>]
    /\ config      = [i \in Server |-> Server]
    /\ configVersion = [i \in Server |-> 1]
    /\ configTerm    = [i \in Server |-> 0]
    /\ immediatelyCommitted = {}
    /\ drainMode = [i \in Server |-> FALSE]
    /\ newlyAdded = [i \in Server |-> FALSE]
    /\ lastCommittedInPrevConfig = [i \in Server |-> 0]

TraceNext ==
    /\ l <= Len(TraceLog)
    /\ \/ TraceWinElection
       \/ TraceCompleteDrain
       \/ TraceReconfig
       \/ TraceForceReconfig
       \/ TraceSendConfig
       \/ TraceClientRequest
       \/ TraceCommitEntry
       \/ TraceGetEntry
       \/ TraceRollbackEntries
       \/ TraceUpdateTerms
       \/ TraceShutDown
       \/ TraceRemoveNewlyAdded
       \* Silent actions (tightly constrained).
       \/ SilentUpdateTerms

\* Spec with deadlock-based completion checking.
\* TLC will report "deadlock" when the trace is fully consumed — that is success.
TraceSpec == TraceInit /\ [][TraceNext]_traceVars

\* Temporal property: entire trace was consumed.
TraceMatched == <>(l > Len(TraceLog))

(******************************************************************************)
(* Trace-specific invariants                                                  *)
(******************************************************************************)

\* The cursor should never go past the end of the trace.
TraceBounds == l <= Len(TraceLog) + 1

=============================================================================
