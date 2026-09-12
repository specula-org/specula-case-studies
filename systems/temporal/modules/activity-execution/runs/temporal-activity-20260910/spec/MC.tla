------------------------------- MODULE MC -------------------------------
EXTENDS base
Original == INSTANCE base
CONSTANTS TimeLimit, RequestLimit, HeartbeatLimit, CancelLimit, CloseLimit,
          CacheLossLimit, ShardLossLimit, StorageFaultLimit, ResponseLossLimit,
          DuplicateDispatchLimit, DuplicateStartLimit, RedeliveryLimit, MaxMessageBuffer
VARIABLE faults
mcVars == <<s,faults>>
Limits == [Time |-> TimeLimit, Request |-> RequestLimit, Heartbeat |-> HeartbeatLimit,
  Cancel |-> CancelLimit, Close |-> CloseLimit, CacheLoss |-> CacheLossLimit,
  ShardLoss |-> ShardLossLimit, StorageFault |-> StorageFaultLimit,
  ResponseLoss |-> ResponseLossLimit, DuplicateDispatch |-> DuplicateDispatchLimit,
  DuplicateStart |-> DuplicateStartLimit, Redelivery |-> RedeliveryLimit]
Bump(k) == faults' = [faults EXCEPT ![k] = @+1]
Can(k) == faults[k] < Limits[k]
MCInit == Init /\ faults = [k \in DOMAIN Limits |-> 0]

\* Only environmental choices are bounded. Deadline scans, retry decisions, store
\* commits/rejections, handlers, cleanup, reload and WFT consumption are reactive.
\* Origins are normalized to scheduling: pre-schedule idle time adds no ordering.
MCTimeSuccessors == {s.now+1}
ClockHorizon == 1+TimeLimit
MCTaskKeyFloors ==
  LET low == Max(s.keyFloor,s.now) high == s.now+1000 IN
  (low..Min(high,ClockHorizon)) \cup
  (IF high > ClockHorizon THEN {Max(low,ClockHorizon+1)} ELSE {})
FutureTime(t) == IF t > ClockHorizon THEN ClockHorizon+1 ELSE t
FutureTask(t) == [t EXCEPT !.due = FutureTime(@)]
FutureTasks(ts) == {FutureTask(t): t \in ts}
MCAdvanceTime(to) == /\ s.db.scheduled # {} /\ Can("Time") /\ Original!AdvanceTime(to) /\ Bump("Time")
MCClearWorkflowCache == /\ Can("CacheLoss") /\ Original!ClearWorkflowCache /\ Bump("CacheLoss")
MCLoseShardContext == /\ Can("ShardLoss") /\ Original!LoseShardContext /\ Bump("ShardLoss")
MCPersistenceTimeoutBeforeWrite == /\ Can("StorageFault") /\ Original!PersistenceTimeoutBeforeWrite /\ Bump("StorageFault")
MCPersistenceResponseTimeout == /\ Can("StorageFault") /\ Original!PersistenceResponseTimeout /\ Bump("StorageFault")
MCRetryPersistenceAfterUnavailable == /\ Can("StorageFault") /\ Original!RetryPersistenceAfterUnavailable /\ Bump("StorageFault")
MCRejectPersistenceWrite(w) == /\ Can("StorageFault") /\ Original!RejectPersistenceWrite(w) /\ Bump("StorageFault")
MCLoseAPIResponse(r) == /\ Can("ResponseLoss") /\ Original!LoseAPIResponse(r) /\ Bump("ResponseLoss")
MCRedeliverTask(t) == /\ Can("Redelivery") /\ Original!RedeliverTask(t) /\ Bump("Redelivery")
MCLoseAddActivityTaskResponse(id) == /\ Can("DuplicateDispatch") /\ Original!LoseAddActivityTaskResponse(id) /\ Bump("DuplicateDispatch")
MCRetryRecordActivityTaskStarted(r) == /\ Can("DuplicateStart") /\ Original!RetryRecordActivityTaskStarted(r) /\ Bump("DuplicateStart")
MCSendActivityRequest(t,k,d) ==
  LET budget == IF k = "Heartbeat" THEN "Heartbeat" ELSE "Request" IN
  /\ Can(budget) /\ Original!SendActivityRequest(t,k,d) /\ Bump(budget)
MCHandleCommandRequestCancelActivity(a) == /\ Can("Cancel") /\ Original!HandleCommandRequestCancelActivity(a) /\ Bump("Cancel")
MCHandleCommandCancelBufferedActivity(a) == /\ Can("Cancel") /\ Original!HandleCommandCancelBufferedActivity(a) /\ Bump("Cancel")
MCHandleCommandCancelAndCompleteWorkflow(a) == /\ Can("Close") /\ Original!HandleCommandCancelAndCompleteWorkflow(a) /\ Bump("Close")
MCHandleCommandCompleteWorkflowRejected == /\ Can("Close") /\ Original!HandleCommandCompleteWorkflowRejected /\ Bump("Close")
MCHandleCommandCompleteWorkflow == /\ Can("Close") /\ Original!HandleCommandCompleteWorkflow /\ Bump("Close")

MCNext == (ReactiveNext /\ UNCHANGED faults) \/ EnvironmentNext
MCSpec == MCInit /\ [][MCNext]_mcVars
Symmetry == Permutations(Workers)
\* Diagnostic view excludes budgets. Default cfg retains full state: removing
\* budget counters from fingerprinting can merge states with different successors.
MCView == s
\* These two observation ledgers never enable protocol actions or safety checks.
\* Projecting their independent bookkeeping interleavings preserves safety;
\* keep fault counters because they control future enabled transitions.
\* Notification now gates lease release, so both notification ledgers are retained.
MCSafetyView == <<[s EXCEPT !.observed = {}, !.historyAppends = {},
  !.keyFloor = FutureTime(@), !.tasks = FutureTasks(@),
  !.newTasks = [i \in 1..Len(s.newTasks) |-> FutureTask(s.newTasks[i])],
  !.writes = {[w EXCEPT !.tasks = FutureTasks(@)]: w \in s.writes}],faults>>
MessageBound == Cardinality(s.copies) + Cardinality(s.matching) + Cardinality(s.startMsgs)
                + Cardinality(s.requests) + Cardinality(s.replies) + Cardinality(s.pollReplies) <= MaxMessageBuffer
MCTypeOK == TypeOK /\ s.now = 1+faults.Time /\ DOMAIN faults = DOMAIN Limits /\
            (\A k \in DOMAIN Limits: faults[k] \in 0..Limits[k])

\* Fair suffix assumptions are explicit; finite failures/retries alone do not
\* imply success. Progress allows policy terminal failure and legal Workflow close.
Resolved == \A a \in s.db.scheduled: \E e \in TermSet(s.db): e.a = a
EligibleWorkEventuallyResolves ==
  /\ (s.db.scheduled = Activities /\ s.db.open) ~> (~s.db.open \/ Resolved)
  /\ (TermSet(s.db) \ s.db.consumed # {} /\ s.db.open) ~>
           (~s.db.open \/ TermSet(s.db) \subseteq s.db.consumed)
PersistenceStep == CloseTransactionAsMutation \/ SetAndTrackTaskKeys \/ SubmitWorkflowMutation \/ AppendHistoryNodes
   \/ (\E w \in s.writes: ApplyWorkflowMutationTx(w) \/ RejectWorkflowMutationTx(w))
   \/ ReturnPersistenceResult \/ FinishUpdateWorkflowExecution
   \/ (\E id \in s.notifyPending: NotifyOnExecutionMutation(id))
   \/ ReloadAfterRejectedWorkflowClose \/ FailWorkflowTaskAfterRejectedClose
TimerStep == (\E t \in s.tasks: ExecuteActivityTimeoutTask(t) \/ DiscardClosedWorkflowTimer(t))
              \/ ExecuteWorkflowRunTimeoutTask
RecoveryStep == ReacquireShard \/ ShardReady \/ LoadMutableState
FairSuffix ==
  /\ WF_mcVars(\E to \in TimeSuccessors: AdvanceTime(to))
  /\ SF_mcVars(PersistenceStep /\ UNCHANGED faults)
  /\ SF_mcVars(TimerStep /\ UNCHANGED faults)
  /\ SF_mcVars(RecoveryStep /\ UNCHANGED faults)
  /\ SF_mcVars(RecordWorkflowTaskStarted /\ UNCHANGED faults)
  /\ SF_mcVars(RespondWorkflowTaskCompleted /\ UNCHANGED faults)
\* Global SCT fits in the relative horizon in progress cfg. Time starts only after
\* scheduling, avoiding horizon exhaustion before the workload exists.
MCProgressSpec == MCSpec /\ FairSuffix
\* The stuttering envelope makes this specification equivalent to MCSpec.
\* Removing explicit no-op choices lets simulation depth count state changes.
MCSimulationNext == MCNext /\ mcVars' # mcVars
MCSimulationSpec == MCInit /\ [][MCSimulationNext]_mcVars
=============================================================================
