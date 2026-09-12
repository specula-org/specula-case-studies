-------------------------------- MODULE MC --------------------------------
EXTENDS base

\* This named instance preserves unbounded base operators if cfg overrides are added.
B == INSTANCE base
CONSTANTS AddLimit, CrashLimit, ExpiryLimit, HistoryFailLimit, LossLimit, ObsoleteLimit, ReadFailLimit, StopLimit, StoreFailLimit, SyncLimit, TakeoverLimit, UncertainLimit, RangeLimit, RecordLimit, BufferLimit
VARIABLE faults
mcvars == <<vars, faults>>
MCInit == Init /\ faults = [add |-> 0, crash |-> 0, expiry |-> 0, historyFail |-> 0, loss |-> 0, obsolete |-> 0, readFail |-> 0, stop |-> 0, storeFail |-> 0, sync |-> 0, takeover |-> 0, takeoverOwners |-> {InitialOwner}, uncertain |-> 0]

\* Injection budget only: S1/S4: an external Add attempt, including retry with the same logical work.
MCAddTask(a, w, o) ==
    /\ faults.add < AddLimit
    /\ B!AddTask(a, w, o)
    /\ faults' = [faults EXCEPT !.add = @ + 1]

\* Injection budget only: S4: sync pair is not yet an accepted start.
MCTrySyncMatch(a, p) ==
    /\ B!TrySyncMatch(a, p)
    /\ faults' = [faults EXCEPT !.sync = @ + 1]

\* Injection budget only: Inject persistence limit rejection or an uncommitted failed transaction.
MCCreateTasksReject(o, result) ==
    /\ faults.storeFail < StoreFailLimit
    /\ B!CreateTasksReject(o, result)
    /\ faults' = [faults EXCEPT !.storeFail = @ + 1]

\* Injection budget only: A committed transaction returns Unavailable/timeout; no successful reader signal.
MCCreateTasksUncertainReturn(o) ==
    /\ faults.uncertain < UncertainLimit
    /\ B!CreateTasksUncertainReturn(o)
    /\ faults' = [faults EXCEPT !.uncertain = @ + 1]

\* Injection budget only: External transport loses the response; successful server acceptance remains.
MCAddTaskReplyLost(a) ==
    /\ faults.loss < LossLimit
    /\ B!AddTaskReplyLost(a)
    /\ faults' = [faults EXCEPT !.loss = @ + 1]

\* Injection budget only: Read I/O error schedules an explicit backoff wakeup.
MCGetTasksError(o) ==
    /\ faults.readFail < ReadFailLimit
    /\ B!GetTasksError(o)
    /\ faults' = [faults EXCEPT !.readFail = @ + 1]

\* Injection budget only: Rate limiter/context fails before constructing a History request. No accepted start is invented.
MCRecordTaskStartedPrecheckError(p, result) ==
    /\ faults.historyFail < HistoryFailLimit
    /\ B!RecordTaskStartedPrecheckError(p, result)
    /\ faults' = [faults EXCEPT !.historyFail = @ + 1]

\* Injection budget only: History fails without accepting: transient versus nontransient start error.
MCRecordTaskStartedError(p, result) ==
    /\ faults.historyFail < HistoryFailLimit
    /\ B!RecordTaskStartedError(p, result)
    /\ faults' = [faults EXCEPT !.historyFail = @ + 1]

\* Injection budget only: Lost response retried inside the same History RPC scope retains RequestId.
MCRecordTaskStartedRetryRPC(p) ==
    /\ faults.loss < LossLimit
    /\ B!RecordTaskStartedRetryRPC(p)
    /\ faults' = [faults EXCEPT !.loss = @ + 1]

\* Injection budget only: Lost History response becomes a transient error; accepted History effect is retained.
MCRecordTaskStartedReplyLost(p) ==
    /\ faults.loss < LossLimit
    /\ B!RecordTaskStartedReplyLost(p)
    /\ faults' = [faults EXCEPT !.loss = @ + 1]

\* Injection budget only: External transport loses Worker receipt; this does not revoke accepted History start.
MCPollTaskQueueResponseLost(p) ==
    /\ faults.loss < LossLimit
    /\ B!PollTaskQueueResponseLost(p)
    /\ faults' = [faults EXCEPT !.loss = @ + 1]

\* Injection budget only: Environment clock crosses the captured nonzero task expiry; SQL retains the row.
MCExpireTask(w) ==
    /\ faults.expiry < ExpiryLimit
    /\ B!ExpireTask(w)
    /\ faults' = [faults EXCEPT !.expiry = @ + 1]

\* Injection budget only: External History marks this logical stamp obsolete; successor stamp is outside this work identity.
MCObsoleteTask(w) ==
    /\ faults.obsolete < ObsoleteLimit
    /\ B!ObsoleteTask(w)
    /\ faults' = [faults EXCEPT !.obsolete = @ + 1]

\* Injection budget only: Fresh manager lifetime begins the supported conditional reacquisition path.
MCTakeOverTaskQueueBegin(o) ==
    /\ (o \in faults.takeoverOwners \/ faults.takeover < TakeoverLimit)
    /\ B!TakeOverTaskQueueBegin(o)
    /\ faults' = [faults EXCEPT !.takeover = IF o \in faults.takeoverOwners THEN @ ELSE @ + 1,
          !.takeoverOwners = @ \cup {o}]

\* Injection budget only: Store rejects/does not commit the metadata operation.
MCUpdateTaskQueueError(o) ==
    /\ faults.storeFail < StoreFailLimit
    /\ B!UpdateTaskQueueError(o)
    /\ faults' = [faults EXCEPT !.storeFail = @ + 1]

\* Injection budget only: Committed metadata or lease response is lost; local range remains old.
MCUpdateTaskQueueReplyLost(o) ==
    /\ faults.uncertain < UncertainLimit
    /\ B!UpdateTaskQueueReplyLost(o)
    /\ faults' = [faults EXCEPT !.uncertain = @ + 1]

\* Injection budget only: External supported unload marks stopped status before final backlog synchronization.
MCStopBegin(o) ==
    /\ faults.stop < StopLimit
    /\ B!StopBegin(o)
    /\ faults' = [faults EXCEPT !.stop = @ + 1]

\* Injection budget only: Process failure freezes local callbacks; durable effects already submitted may still commit.
MCCrash(o) ==
    /\ faults.crash < CrashLimit
    /\ B!Crash(o)
    /\ faults' = [faults EXCEPT !.crash = @ + 1]

\* Injection budget only: GC failure/lost result retains gcLast; durable deletion, if already committed, is not undone.
MCDoGCError(o) ==
    /\ faults.storeFail < StoreFailLimit
    /\ B!DoGCError(o)
    /\ faults' = [faults EXCEPT !.storeFail = @ + 1]

MCRawNext ==
    \/ \E o \in Owners : (B!RenewLeaseRetry(o) /\ UNCHANGED faults) \/ (B!RenewLeaseFailure(o) /\ UNCHANGED faults)
    \/ \E a \in CallIds : (B!SyncTaskReceive(a) /\ UNCHANGED faults)
    \/ \E a \in CallIds : \E w \in Work : \E o \in Owners : MCAddTask(a, w, o)
    \/ \E a \in CallIds : (B!TrySyncMatchFallback(a) /\ UNCHANGED faults)
    \/ \E a \in CallIds : \E p \in Pollers : MCTrySyncMatch(a, p)
    \/ \E a \in CallIds : (B!SpoolTask(a) /\ UNCHANGED faults)
    \/ \E o \in Owners : (B!TaskWriterDequeue(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : (B!AssignTaskIDs(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : (B!CreateTasksBegin(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : (B!CreateTasksCommit(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : (B!CreateTasksConditionFailed(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : \E result \in {"limit", "noCommit"} : MCCreateTasksReject(o, result)
    \/ \E o \in Owners : \E reply \in {"ok", "definite", "unknown", "condition"} : (B!CreateTasksReturn(o, reply) /\ UNCHANGED faults)
    \/ \E o \in Owners : MCCreateTasksUncertainReturn(o)
    \/ \E o \in Owners : (B!SignalNewTasksBypass(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : (B!SignalNewTasksWake(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : \E r \in owner[o].adding : (B!AddTaskToMatcher(o, r) /\ UNCHANGED faults)
    \/ \E o \in Owners : \E r \in owner[o].adding : (B!AddTaskToMatcherClosed(o, r) /\ UNCHANGED faults)
    \/ \E o \in Owners : (B!SignalReadersDone(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : (B!TaskWriterPublish(o) /\ UNCHANGED faults)
    \/ \E a \in CallIds : (B!AppendTaskReceive(a) /\ UNCHANGED faults)
    \/ \E a \in CallIds : (B!AppendTaskShutdown(a) /\ UNCHANGED faults)
    \/ \E a \in CallIds : (B!AddTaskReply(a) /\ UNCHANGED faults)
    \/ \E a \in CallIds : MCAddTaskReplyLost(a)
    \/ \E o \in Owners : (B!GetTasksPump(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : (B!GetTaskBatchMax(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : (B!GetTasksIssue(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : (B!GetTasksSnapshot(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : MCGetTasksError(o)
    \/ \E o \in Owners : (B!BackoffSignal(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : (B!GetTaskBatchReturn(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : (B!ProcessTaskBatch(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : (B!ProcessTaskBatchDone(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : (B!SetReadLevelAfterGapStale(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : (B!SetReadLevelAfterGap(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : (B!SetReadLevelAfterGapAck(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : (B!UpdateAckLevelAfterGap(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : \E r \in owner[o].queued : \E p \in Pollers : (B!PollTask(o, r, p) /\ UNCHANGED faults)
    \/ \E p \in Pollers : \E q \in StartIds : (B!RecordTaskStartedBegin(p, q) /\ UNCHANGED faults)
    \/ \E p \in Pollers : \E result \in {"transient", "respool", "busy"} : MCRecordTaskStartedPrecheckError(p, result)
    \/ \E p \in Pollers : (B!RecordTaskStarted(p) /\ UNCHANGED faults)
    \/ \E p \in Pollers : \E result \in {"transient", "respool", "busy"} : MCRecordTaskStartedError(p, result)
    \/ \E p \in Pollers : (B!RecordTaskStartedReply(p) /\ UNCHANGED faults)
    \/ \E p \in Pollers : MCRecordTaskStartedRetryRPC(p)
    \/ \E p \in Pollers : MCRecordTaskStartedReplyLost(p)
    \/ \E p \in Pollers : (B!FinishSyncTask(p) /\ UNCHANGED faults)
    \/ \E p \in Pollers : (B!CompleteTaskTransient(p) /\ UNCHANGED faults)
    \/ \E p \in Pollers : (B!RespoolTaskAfterError(p) /\ UNCHANGED faults)
    \/ \E o \in Owners : (B!TaskWriterPublishReplacement(o) /\ UNCHANGED faults)
    \/ \E p \in Pollers : (B!RespoolTaskReturn(p) /\ UNCHANGED faults)
    \/ \E p \in Pollers : (B!RespoolTaskRetry(p) /\ UNCHANGED faults)
    \/ \E p \in Pollers : (B!RespoolTaskShutdown(p) /\ UNCHANGED faults)
    \/ \E p \in Pollers : (B!CompleteTaskAck(p) /\ UNCHANGED faults)
    \/ \E o \in Owners : (B!AckTaskLockedDrained(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : \E launch \in BOOLEAN : (B!MaybeGCLocked(o, launch) /\ UNCHANGED faults)
    \/ \E o \in Owners : (B!UpdateAckLevelAndBacklogStats(o) /\ UNCHANGED faults)
    \/ \E p \in Pollers : (B!PollTaskQueueResponse(p) /\ UNCHANGED faults)
    \/ \E p \in Pollers : MCPollTaskQueueResponseLost(p)
    \/ \E w \in Work : MCExpireTask(w)
    \/ \E w \in Work : MCObsoleteTask(w)
    \/ \E o \in Owners : \E r \in owner[o].queued : \E p \in Pollers : (B!FinishExpiredTask(o, r, p) /\ UNCHANGED faults)
    \/ \E o \in Owners : \E kind \in {"sync", "verify"} : (B!SyncStateBegin(o, kind) /\ UNCHANGED faults)
    \/ \E o \in Owners : (B!RenewLeaseBegin(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : MCTakeOverTaskQueueBegin(o)
    \/ \E o \in Owners : (B!TakeOverTaskQueueSnapshot(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : (B!UpdateTaskQueueCommit(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : (B!VerifyOwnership(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : (B!UpdateTaskQueueConditionFailed(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : MCUpdateTaskQueueError(o)
    \/ \E o \in Owners : MCUpdateTaskQueueReplyLost(o)
    \/ \E o \in Owners : (B!UpdateTaskQueueReturn(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : MCStopBegin(o)
    \/ \E o \in Owners : (B!SignalIfFatal(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : (B!UnloadAfterError(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : (B!StopRefreshAck(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : (B!StopSyncState(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : (B!StopCancel(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : MCCrash(o)
    \/ \E o \in Owners : (B!CompleteTasksLessThan(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : (B!DoGCReturn(o) /\ UNCHANGED faults)
    \/ \E o \in Owners : MCDoGCError(o)
    \/ \E o \in Owners : (B!DiscardCrashedWriter(o) /\ UNCHANGED faults)
    \/ \E p \in Pollers : (B!PollerDisconnect(p) /\ UNCHANGED faults)
    \/ \E p \in Pollers : (B!PollTaskErrorReturn(p) /\ UNCHANGED faults)

MCNext == Track(MCRawNext)
MCSpec == MCInit /\ [][MCNext]_mcvars

\* Work values are opaque logical identities. Owners and storage IDs are ordered.
Symmetry == Permutations(Work)
\* Keep counters in the view: remaining fault budgets affect future enabledness.
MCView == mcvars
InFlight == Cardinality({p \in Pollers : dispatch[p].pc # "idle"}) +
            Cardinality({o \in Owners : writer[o].pc # "idle"}) +
            Cardinality({o \in Owners : reader[o].pc # "idle"}) +
            Cardinality({o \in Owners : metadata[o].pc # "idle"})
\* Resource frontiers, not action guards. Reaching a frontier is not a liveness proof.
StateConstraint == /\ durable.range <= RangeLimit
                   /\ Cardinality(DOMAIN catalog) <= RecordLimit
                   /\ InFlight <= BufferLimit
MCTypeOK == TypeOK /\ faults.add \in 0..AddLimit /\ faults.crash \in 0..CrashLimit /\ faults.expiry \in 0..ExpiryLimit /\ faults.historyFail \in 0..HistoryFailLimit /\ faults.loss \in 0..LossLimit /\ faults.obsolete \in 0..ObsoleteLimit /\ faults.readFail \in 0..ReadFailLimit /\ faults.stop \in 0..StopLimit /\ faults.storeFail \in 0..StoreFailLimit /\ faults.sync \in 0..AddLimit /\ faults.takeover \in 0..TakeoverLimit /\ faults.uncertain \in 0..UncertainLimit

\* Explicit environment conditions, not a claim about unstable owners or failed stores.
StableOwner == <>[](\E o \in Owners : owner[o].life = "ready" /\ owner[o].range = durable.range)
FiniteInterference == <>[][UNCHANGED faults]_mcvars
\* Strong fairness states eventual lock acquisition/processing and eligible polling.
\* Fixed identity domain avoids vacuous fairness over an initially empty catalog.
ProgressIdCeiling == RangeSize * (4 + TakeoverLimit + AddLimit + UncertainLimit +
                      HistoryFailLimit * (2 + StoreFailLimit + UncertainLimit))
ProcessingFairness ==
    /\ \A o \in Owners : SF_mcvars(Track(B!RenewLeaseRetry(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!RenewLeaseFailure(o)) /\ UNCHANGED faults)
    /\ \A a \in CallIds : SF_mcvars(Track(B!SyncTaskReceive(a)) /\ UNCHANGED faults)
    /\ \A a \in CallIds : SF_mcvars(Track(B!TrySyncMatchFallback(a)) /\ UNCHANGED faults)
    /\ \A a \in CallIds : SF_mcvars(Track(B!SpoolTask(a)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!TaskWriterDequeue(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!AssignTaskIDs(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!CreateTasksBegin(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!CreateTasksCommit(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!CreateTasksConditionFailed(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : \A reply \in {"ok", "definite", "unknown", "condition"} : SF_mcvars(Track(B!CreateTasksReturn(o, reply)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!SignalNewTasksBypass(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!SignalNewTasksWake(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : \A r \in 1..ProgressIdCeiling : SF_mcvars(Track(B!AddTaskToMatcher(o, r)) /\ UNCHANGED faults)
    /\ \A o \in Owners : \A r \in 1..ProgressIdCeiling : SF_mcvars(Track(B!AddTaskToMatcherClosed(o, r)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!SignalReadersDone(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!TaskWriterPublish(o)) /\ UNCHANGED faults)
    /\ \A a \in CallIds : SF_mcvars(Track(B!AppendTaskReceive(a)) /\ UNCHANGED faults)
    /\ \A a \in CallIds : SF_mcvars(Track(B!AppendTaskShutdown(a)) /\ UNCHANGED faults)
    /\ \A a \in CallIds : SF_mcvars(Track(B!AddTaskReply(a)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!GetTasksPump(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!GetTaskBatchMax(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!GetTasksIssue(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!GetTasksSnapshot(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!BackoffSignal(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!GetTaskBatchReturn(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!ProcessTaskBatch(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!ProcessTaskBatchDone(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!SetReadLevelAfterGapStale(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!SetReadLevelAfterGap(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!SetReadLevelAfterGapAck(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!UpdateAckLevelAfterGap(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : \A r \in 1..ProgressIdCeiling : \A p \in Pollers : SF_mcvars(Track(B!PollTask(o, r, p)) /\ UNCHANGED faults)
    /\ \A p \in Pollers : SF_mcvars(Track(\E q \in StartIds : B!RecordTaskStartedBegin(p, q)) /\ UNCHANGED faults)
    /\ \A p \in Pollers : SF_mcvars(Track(B!RecordTaskStarted(p)) /\ UNCHANGED faults)
    /\ \A p \in Pollers : SF_mcvars(Track(B!RecordTaskStartedReply(p)) /\ UNCHANGED faults)
    /\ \A p \in Pollers : SF_mcvars(Track(B!FinishSyncTask(p)) /\ UNCHANGED faults)
    /\ \A p \in Pollers : SF_mcvars(Track(B!CompleteTaskTransient(p)) /\ UNCHANGED faults)
    /\ \A p \in Pollers : SF_mcvars(Track(B!RespoolTaskAfterError(p)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!TaskWriterPublishReplacement(o)) /\ UNCHANGED faults)
    /\ \A p \in Pollers : SF_mcvars(Track(B!RespoolTaskReturn(p)) /\ UNCHANGED faults)
    /\ \A p \in Pollers : SF_mcvars(Track(B!RespoolTaskRetry(p)) /\ UNCHANGED faults)
    /\ \A p \in Pollers : SF_mcvars(Track(B!RespoolTaskShutdown(p)) /\ UNCHANGED faults)
    /\ \A p \in Pollers : SF_mcvars(Track(B!CompleteTaskAck(p)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!AckTaskLockedDrained(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : \A launch \in BOOLEAN : SF_mcvars(Track(B!MaybeGCLocked(o, launch)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!UpdateAckLevelAndBacklogStats(o)) /\ UNCHANGED faults)
    /\ \A p \in Pollers : SF_mcvars(Track(B!PollTaskQueueResponse(p)) /\ UNCHANGED faults)
    /\ \A o \in Owners : \A r \in 1..ProgressIdCeiling : \A p \in Pollers : SF_mcvars(Track(B!FinishExpiredTask(o, r, p)) /\ UNCHANGED faults)
    /\ \A o \in Owners : \A kind \in {"sync", "verify"} : SF_mcvars(Track(B!SyncStateBegin(o, kind)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!RenewLeaseBegin(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!TakeOverTaskQueueSnapshot(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!UpdateTaskQueueCommit(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!VerifyOwnership(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!UpdateTaskQueueConditionFailed(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!UpdateTaskQueueReturn(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!SignalIfFatal(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!UnloadAfterError(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!StopRefreshAck(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!StopSyncState(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!StopCancel(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!CompleteTasksLessThan(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!DoGCReturn(o)) /\ UNCHANGED faults)
    /\ \A o \in Owners : SF_mcvars(Track(B!DiscardCrashedWriter(o)) /\ UNCHANGED faults)
    /\ \A p \in Pollers : SF_mcvars(Track(B!PollerDisconnect(p)) /\ UNCHANGED faults)
    /\ \A p \in Pollers : SF_mcvars(Track(B!PollTaskErrorReturn(p)) /\ UNCHANGED faults)
\* No state constraint or symmetry reduction in the dedicated liveness cfg.
\* StableOwner excludes executions that never reacquire a ready owner. For an
\* initial committed-error admission, retry/wakeup/reload is an extra caller
\* obligation; it is deliberately not part of audit.accepted.
MCLiveSpec == MCSpec /\ ProcessingFairness
ConditionalProgress == StableOwner => EventuallyDischarged

=============================================================================
