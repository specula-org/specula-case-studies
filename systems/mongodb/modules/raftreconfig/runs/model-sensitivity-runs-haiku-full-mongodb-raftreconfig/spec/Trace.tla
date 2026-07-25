---------------------------- MODULE Trace ----------------------------
(* Trace validation spec: replay implementation traces against base.tla *)

EXTENDS base, Naturals, Sequences, TLC

(* ====== Trace Loading ====== *)

NULL == "NULL"  \* Sentinel value for undefined/missing data

VARIABLE
  TraceLog,  \* Sequence of trace events from implementation
  l          \* Cursor: current position in trace

(* Load JSON trace file *)
JsonFile ==
  "../traces/trace.ndjson"

ndJsonDeserialize(filename) ==
  (* This would be implemented by the harness to load NDJSON events *)
  <<>>

(* ====== Helper Functions ====== *)

IsEvent(eventName) ==
  l <= Len(TraceLog) /\ TraceLog[l].event.name = eventName

IsNodeEvent(eventName, nodeId) ==
  l <= Len(TraceLog) /\
  TraceLog[l].event.name = eventName /\
  TraceLog[l].event.nid = nodeId

IsMsgEvent(eventName, from, to) ==
  l <= Len(TraceLog) /\
  TraceLog[l].event.name = eventName /\
  TraceLog[l].event.from = from /\
  TraceLog[l].event.to = to

(* Extract node from current event *)
CurrentNode ==
  IF l <= Len(TraceLog) THEN TraceLog[l].event.nid ELSE NULL

(* Get field value from current event *)
GetEventField(fieldName) ==
  IF l <= Len(TraceLog) /\ fieldName \in DOMAIN TraceLog[l].event
  THEN TraceLog[l].event[fieldName]
  ELSE NULL

(* ====== Post-State Validation ====== *)

(* Validate state after CompareConfigVersionAndTerm *)
ValidatePostState_CompareConfig(s) ==
  TRUE  \* Comparison is read-only

(* Validate state after QuorumChecker_Start *)
ValidatePostState_QuorumStart(s) ==
  /\ quorumState[s] = "in_progress"
  /\ voterResponses[s] = {s}  \* Self counted as responded

(* Validate state after QuorumChecker_ProcessResponse *)
ValidatePostState_QuorumResponse(s, voter) ==
  /\ quorumState[s] \in {"in_progress", "succeeded"}
  /\ voter \in voterResponses[s]

(* Validate state after DoReplSetReconfig_Initiate *)
ValidatePostState_ReConfigInitiate(s) ==
  /\ configStateEnum[s] = "kConfigReconfiguring"

(* Validate state after DoReplSetReconfig_Persist *)
ValidatePostState_ReConfigPersist(s) ==
  /\ pendingConfigWrite[s] = TRUE

(* Validate state after JournalFlush_Complete *)
ValidatePostState_JournalFlush(s) ==
  /\ persistedConfigVersion[s] = configVersion[s]
  /\ persistedConfigTerm[s] = configTerm[s]
  /\ pendingConfigWrite[s] = FALSE

(* Validate state after DoReplSetReconfig_FinishInstall *)
ValidatePostState_ReConfigInstall(s) ==
  /\ configStateEnum[s] = "kConfigSteady"
  /\ configTerm[s] = configState[s].term
  /\ configVersion[s] = configState[s].version

(* Validate state after crash recovery *)
ValidatePostState_CrashRecovery(s) ==
  /\ configTerm[s] = persistedConfigTerm[s]
  /\ configVersion[s] = persistedConfigVersion[s]
  /\ configStateEnum[s] = "kConfigSteady"

(* ====== Action Wrappers (Trace Events -> Base Actions) ====== *)

(* Event: CompareConfigVersionAndTerm *)
TraceEvent_CompareConfig(s) ==
  /\ IsNodeEvent("CompareConfig", s)
  /\ \E other \in Server :
       /\ CompareConfigVersionAndTerm(s, other)
       /\ ValidatePostState_CompareConfig(s)
  /\ l' = l + 1

(* Event: QuorumChecker_Start *)
TraceEvent_QuorumStart(s) ==
  /\ IsNodeEvent("QuorumStart", s)
  /\ QuorumChecker_Start(s)
  /\ ValidatePostState_QuorumStart(s)
  /\ l' = l + 1

(* Event: QuorumChecker_ProcessResponse *)
TraceEvent_QuorumResponse(s) ==
  /\ IsNodeEvent("QuorumResponse", s)
  /\ LET voter == GetEventField("voter")
     IN
       /\ voter \in Server
       /\ QuorumChecker_ProcessResponse(s, voter)
       /\ ValidatePostState_QuorumResponse(s, voter)
  /\ l' = l + 1

(* Event: QuorumChecker_Timeout *)
TraceEvent_QuorumTimeout(s) ==
  /\ IsNodeEvent("QuorumTimeout", s)
  /\ QuorumChecker_Timeout(s)
  /\ l' = l + 1

(* Event: DoReplSetReconfig_Initiate *)
TraceEvent_ReConfigInitiate(s) ==
  /\ IsNodeEvent("ReConfigInitiate", s)
  /\ LET newVersion == GetEventField("newVersion")
         newTerm == GetEventField("newTerm")
     IN
       /\ newVersion \in Nat
       /\ newTerm \in {UninitTerm} \cup Nat
       /\ DoReplSetReconfig_Initiate(s, newVersion, newTerm)
       /\ ValidatePostState_ReConfigInitiate(s)
  /\ l' = l + 1

(* Event: DoReplSetReconfig_Persist *)
TraceEvent_ReConfigPersist(s) ==
  /\ IsNodeEvent("ReConfigPersist", s)
  /\ LET newVersion == GetEventField("newVersion")
         newTerm == GetEventField("newTerm")
     IN
       /\ newVersion \in Nat
       /\ newTerm \in {UninitTerm} \cup Nat
       /\ DoReplSetReconfig_Persist(s, newVersion, newTerm)
       /\ ValidatePostState_ReConfigPersist(s)
  /\ l' = l + 1

(* Event: JournalFlush_Complete *)
TraceEvent_JournalFlush(s) ==
  /\ IsNodeEvent("JournalFlush", s)
  /\ JournalFlush_Complete(s)
  /\ ValidatePostState_JournalFlush(s)
  /\ l' = l + 1

(* Event: DoReplSetReconfig_FinishInstall *)
TraceEvent_ReConfigInstall(s) ==
  /\ IsNodeEvent("ReConfigInstall", s)
  /\ LET newVersion == GetEventField("newVersion")
         newTerm == GetEventField("newTerm")
     IN
       /\ newVersion \in Nat
       /\ newTerm \in {UninitTerm} \cup Nat
       /\ DoReplSetReconfig_FinishInstall(s, newVersion, newTerm)
       /\ ValidatePostState_ReConfigInstall(s)
  /\ l' = l + 1

(* Event: Crash_RecoverConfigFromDisk *)
TraceEvent_CrashRecovery(s) ==
  /\ IsNodeEvent("CrashRecovery", s)
  /\ Crash_RecoverConfigFromDisk(s)
  /\ ValidatePostState_CrashRecovery(s)
  /\ l' = l + 1

(* Event: Heartbeat_SendCurrentConfig *)
TraceEvent_Heartbeat(s) ==
  /\ IsNodeEvent("Heartbeat", s)
  /\ LET dest == GetEventField("dest")
     IN
       /\ dest \in Server
       /\ Heartbeat_SendCurrentConfig(s, dest)
  /\ l' = l + 1

(* Event: AdvanceCommittedOptime *)
TraceEvent_AdvanceCommit(s) ==
  /\ IsNodeEvent("AdvanceCommit", s)
  /\ LET optime == GetEventField("optime")
     IN
       /\ optime \in Nat
       /\ AdvanceCommittedOptime(s, optime)
  /\ l' = l + 1

(* ====== Silent Actions ====== *)

(* Silent action: No event but spec state may need adjustment *)
(* (These are state changes not captured in trace) *)

(* ====== Trace Next ====== *)

TraceNext ==
  l <= Len(TraceLog) /\
  \E s \in Server :
    \/ TraceEvent_CompareConfig(s)
    \/ TraceEvent_QuorumStart(s)
    \/ TraceEvent_QuorumResponse(s)
    \/ TraceEvent_QuorumTimeout(s)
    \/ TraceEvent_ReConfigInitiate(s)
    \/ TraceEvent_ReConfigPersist(s)
    \/ TraceEvent_JournalFlush(s)
    \/ TraceEvent_ReConfigInstall(s)
    \/ TraceEvent_CrashRecovery(s)
    \/ TraceEvent_Heartbeat(s)
    \/ TraceEvent_AdvanceCommit(s)

(* ====== Trace Bootstrap State ====== *)

(* Initialize from trace initial state (may differ from base.Init) *)
TraceInit ==
  /\ Init
  /\ TraceLog = ndJsonDeserialize(JsonFile)
  /\ l = 1

(* ====== Trace Completion ====== *)

TraceMatched == <>(l > Len(TraceLog))

(* ====== Trace Invariants ====== *)

(* Check base invariants throughout trace *)
TraceTypeOK == MCTypeOK
TraceConfigVersionTermTransitivity == ConfigVersionTermTransitivity
TraceConfigVersionMonotonicity == ConfigVersionMonotonicity
TracePersistentConfigValidity == PersistentConfigValidity
TraceQuorumBasedOnActualResponses == QuorumBasedOnActualResponses
TraceConfigStateConsistency == ConfigStateConsistency

(* Trace specification for TLC *)
Trace == TraceInit /\ [][TraceNext]_vars /\ TraceMatched

=============================================================================
