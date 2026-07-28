--------------------------- MODULE Trace ---------------------------
(*
 * Trace validation specification for SlateDB distributed compaction
 * coordination.
 *
 * The harness is expected to emit full post-state snapshots for the modeled
 * shared state plus the coordinator / worker local state that this spec tracks.
 * Silent actions are reserved for clock advancement and checkpoint expiry, which
 * may occur between externally visible protocol events.
 *)

EXTENDS base, Json, Sequences, TLC

\* ============================================================================
\* TRACE LOADING
\* ============================================================================

JsonFile == "../traces/trace.ndjson"

TraceLog ==
    TLCEval(
        LET all == ndJsonDeserialize(JsonFile)
        IN SelectSeq(
            all,
            LAMBDA x :
                /\ "tag" \in DOMAIN x
                /\ x.tag = "trace"
                /\ "event" \in DOMAIN x))

ASSUME Len(TraceLog) > 0

\* ============================================================================
\* TRACE CURSOR
\* ============================================================================

VARIABLE l

traceVars == <<l>>
traceAllVars == <<vars, l>>

logline == TraceLog[l]

\* ============================================================================
\* TRACE HELPERS
\* ============================================================================

SeqToSet(seq) ==
    {seq[i] : i \in 1..Len(seq)}

TraceJobRecord(seq, j) ==
    LET matches == {i \in 1..Len(seq) : seq[i]["job"] = j}
    IN IF matches = {}
       THEN EmptyJob
       ELSE LET e == seq[CHOOSE i \in matches : TRUE]
            IN [status      |-> e["status"],
                worker      |-> e["worker"],
                lastHb      |-> e["last_hb"],
                origin      |-> e["origin"],
                retry       |-> e["retry"],
                ctx         |-> e["ctx"],
                output      |-> e["output"],
                submittedTs |-> e["submitted_ts"]]

TraceJobMap(seq) ==
    [j \in Jobs |-> TraceJobRecord(seq, j)]

TraceCheckpointActive(seq) ==
    [j \in Jobs |->
        LET matches == {i \in 1..Len(seq) : seq[i]["job"] = j}
        IN IF matches = {}
           THEN FALSE
           ELSE seq[CHOOSE i \in matches : TRUE]["active"]]

TraceCheckpointRefs(seq) ==
    [j \in Jobs |->
        LET matches == {i \in 1..Len(seq) : seq[i]["job"] = j}
        IN IF matches = {}
           THEN {}
           ELSE SeqToSet(seq[CHOOSE i \in matches : TRUE]["refs"])]

TraceCheckpointExpire(seq) ==
    [j \in Jobs |->
        LET matches == {i \in 1..Len(seq) : seq[i]["job"] = j}
        IN IF matches = {}
           THEN 0
           ELSE seq[CHOOSE i \in matches : TRUE]["expire"]]

TraceWorkerTime(seq) ==
    [w \in Workers |->
        LET matches == {i \in 1..Len(seq) : seq[i]["worker"] = w}
        IN IF matches = {}
           THEN 0
           ELSE seq[CHOOSE i \in matches : TRUE]["time"]]

TraceWorkerJobSet(seq, w) ==
    LET matches == {i \in 1..Len(seq) : seq[i]["worker"] = w}
    IN IF matches = {}
       THEN {}
       ELSE SeqToSet(seq[CHOOSE i \in matches : TRUE]["jobs"])

TraceLocalExecuting(seq) ==
    [w \in Workers |-> TraceWorkerJobSet(seq, w)]

TraceBufferedCtx(seq) ==
    [w \in Workers |-> TraceWorkerJobSet(seq, w)]

TraceNatMap(seq, keyField, valueField, domainSet) ==
    [x \in domainSet |->
        LET matches == {i \in 1..Len(seq) : seq[i][keyField] = x}
        IN IF matches = {}
           THEN 0
           ELSE seq[CHOOSE i \in matches : TRUE][valueField]]

TraceState == logline.event.state

\* ============================================================================
\* EVENT PREDICATES
\* ============================================================================

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = name

HasJob ==
    /\ "job" \in DOMAIN logline.event
    /\ logline.event.job \in Jobs

HasWorker ==
    /\ "worker" \in DOMAIN logline.event
    /\ logline.event.worker \in Workers

HasSst ==
    /\ "sst" \in DOMAIN logline.event
    /\ logline.event.sst \in GcManagedSsts

\* ============================================================================
\* POST-STATE VALIDATION
\* ============================================================================

ValidateCapturedState ==
    /\ coordUp' = TraceState.coord_up
    /\ coordTime' = TraceState.coord_time
    /\ workerTime' = TraceWorkerTime(TraceState.worker_time)

    /\ manifestRefs' = SeqToSet(TraceState.manifest_refs)
    /\ checkpointActive' = TraceCheckpointActive(TraceState.checkpoints)
    /\ checkpointRefs' = TraceCheckpointRefs(TraceState.checkpoints)
    /\ checkpointExpire' = TraceCheckpointExpire(TraceState.checkpoints)
    /\ manifestVersion' = TraceState.manifest_version
    /\ manifestEpoch' = TraceState.manifest_epoch

    /\ compactionsExists' = TraceState.compactions_exists
    /\ durJob' = TraceJobMap(TraceState.dur_jobs)
    /\ compactionsVersion' = TraceState.compactions_version
    /\ compactionsEpoch' = TraceState.compactions_epoch

    /\ coordManifestRefs' = SeqToSet(TraceState.coord_manifest_refs)
    /\ coordCheckpointActive' = TraceCheckpointActive(TraceState.coord_checkpoints)
    /\ coordCheckpointRefs' = TraceCheckpointRefs(TraceState.coord_checkpoints)
    /\ coordCheckpointExpire' = TraceCheckpointExpire(TraceState.coord_checkpoints)
    /\ coordJob' = TraceJobMap(TraceState.coord_jobs)
    /\ coordSeenManifestVersion' = TraceState.coord_seen_manifest_version
    /\ coordSeenCompactionsVersion' = TraceState.coord_seen_compactions_version

    /\ localExecuting' = TraceLocalExecuting(TraceState.local_executing)
    /\ bufferedCtx' = TraceBufferedCtx(TraceState.buffered_ctx)
    /\ presentSsts' = SeqToSet(TraceState.present_ssts)
    /\ deletedSsts' = SeqToSet(TraceState.deleted_ssts)
    /\ outputTs' = TraceNatMap(TraceState.output_ts, "sst", "ts", OutputSsts)

    /\ publishCount' = TraceNatMap(TraceState.publish_count, "job", "count", Jobs)
    /\ retryCount' = TraceNatMap(TraceState.retry_count, "job", "count", Jobs)

\* ============================================================================
\* TRACE CURSOR
\* ============================================================================

StepTrace == l' = l + 1

\* ============================================================================
\* ACTION WRAPPERS
\* ============================================================================

StartCoordinatorIfLogged ==
    /\ IsEvent("StartCoordinator")
    /\ StartCoordinator
    /\ ValidateCapturedState
    /\ StepTrace

CrashCoordinatorIfLogged ==
    /\ IsEvent("CrashCoordinator")
    /\ CrashCoordinator
    /\ ValidateCapturedState
    /\ StepTrace

CoordinatorRefreshCompactionsIfLogged ==
    /\ IsEvent("CoordinatorRefreshCompactions")
    /\ CoordinatorRefreshCompactions
    /\ ValidateCapturedState
    /\ StepTrace

CoordinatorRefreshManifestIfLogged ==
    /\ IsEvent("CoordinatorRefreshManifest")
    /\ CoordinatorRefreshManifest
    /\ ValidateCapturedState
    /\ StepTrace

MaybeScheduleCompactionsIfLogged ==
    /\ IsEvent("MaybeScheduleCompactions")
    /\ HasJob
    /\ MaybeScheduleCompactions(logline.event.job)
    /\ ValidateCapturedState
    /\ StepTrace

ExternalSubmitIfLogged ==
    /\ IsEvent("ExternalSubmit")
    /\ HasJob
    /\ ExternalSubmit(logline.event.job)
    /\ ValidateCapturedState
    /\ StepTrace

MaybeValidateSubmittedFailIfLogged ==
    /\ IsEvent("MaybeValidateSubmittedFail")
    /\ HasJob
    /\ MaybeValidateSubmittedFail(logline.event.job)
    /\ ValidateCapturedState
    /\ StepTrace

MaybeValidateSubmittedScheduleIfLogged ==
    /\ IsEvent("MaybeValidateSubmittedSchedule")
    /\ HasJob
    /\ MaybeValidateSubmittedSchedule(logline.event.job)
    /\ ValidateCapturedState
    /\ StepTrace

MaybeValidateSubmittedDrainIfLogged ==
    /\ IsEvent("MaybeValidateSubmittedDrain")
    /\ HasJob
    /\ MaybeValidateSubmittedDrain(logline.event.job)
    /\ ValidateCapturedState
    /\ StepTrace

PollAndClaimStopDuplicateIfLogged ==
    /\ IsEvent("PollAndClaimStopDuplicate")
    /\ HasJob
    /\ HasWorker
    /\ PollAndClaimStopDuplicate(logline.event.worker, logline.event.job)
    /\ ValidateCapturedState
    /\ StepTrace

PollAndClaimIfLogged ==
    /\ IsEvent("PollAndClaim")
    /\ HasJob
    /\ HasWorker
    /\ PollAndClaim(logline.event.worker, logline.event.job)
    /\ ValidateCapturedState
    /\ StepTrace

DispatchClaimedJobIfLogged ==
    /\ IsEvent("DispatchClaimedJob")
    /\ HasJob
    /\ HasWorker
    /\ DispatchClaimedJob(logline.event.worker, logline.event.job)
    /\ ValidateCapturedState
    /\ StepTrace

ReleaseClaimPostClaimInvalidIfLogged ==
    /\ IsEvent("ReleaseClaimPostClaimInvalid")
    /\ HasJob
    /\ HasWorker
    /\ ReleaseClaimPostClaimInvalid(logline.event.worker, logline.event.job)
    /\ ValidateCapturedState
    /\ StepTrace

WriteOutputSstIfLogged ==
    /\ IsEvent("WriteOutputSst")
    /\ HasJob
    /\ HasWorker
    /\ WriteOutputSst(logline.event.worker, logline.event.job)
    /\ ValidateCapturedState
    /\ StepTrace

HeartbeatLoseOwnershipIfLogged ==
    /\ IsEvent("HeartbeatLoseOwnership")
    /\ HasJob
    /\ HasWorker
    /\ HeartbeatLoseOwnership(logline.event.worker, logline.event.job)
    /\ ValidateCapturedState
    /\ StepTrace

HeartbeatOwnedJobsIfLogged ==
    /\ IsEvent("HeartbeatOwnedJobs")
    /\ HasJob
    /\ HasWorker
    /\ HeartbeatOwnedJobs(logline.event.worker, logline.event.job)
    /\ ValidateCapturedState
    /\ StepTrace

HandleFinishedSuccessIfLogged ==
    /\ IsEvent("HandleFinishedSuccess")
    /\ HasJob
    /\ HasWorker
    /\ HandleFinishedSuccess(logline.event.worker, logline.event.job)
    /\ ValidateCapturedState
    /\ StepTrace

HandleFinishedLostOwnershipIfLogged ==
    /\ IsEvent("HandleFinishedLostOwnership")
    /\ HasJob
    /\ HasWorker
    /\ HandleFinishedLostOwnership(logline.event.worker, logline.event.job)
    /\ ValidateCapturedState
    /\ StepTrace

HandleFinishedExecErrorIfLogged ==
    /\ IsEvent("HandleFinishedExecError")
    /\ HasJob
    /\ HasWorker
    /\ HandleFinishedExecError(logline.event.worker, logline.event.job)
    /\ ValidateCapturedState
    /\ StepTrace

ReclaimStaleWorkersIfLogged ==
    /\ IsEvent("ReclaimStaleWorkers")
    /\ HasJob
    /\ ReclaimStaleWorkers(logline.event.job)
    /\ ValidateCapturedState
    /\ StepTrace

CommitCompactedEntriesFailIfLogged ==
    /\ IsEvent("CommitCompactedEntriesFail")
    /\ HasJob
    /\ CommitCompactedEntriesFail(logline.event.job)
    /\ ValidateCapturedState
    /\ StepTrace

CommitCompactedEntriesWriteManifestIfLogged ==
    /\ IsEvent("CommitCompactedEntriesWriteManifest")
    /\ HasJob
    /\ CommitCompactedEntriesWriteManifest(logline.event.job)
    /\ ValidateCapturedState
    /\ StepTrace

CommitCompactedEntriesWriteCompactionsIfLogged ==
    /\ IsEvent("CommitCompactedEntriesWriteCompactions")
    /\ HasJob
    /\ CommitCompactedEntriesWriteCompactions(logline.event.job)
    /\ ValidateCapturedState
    /\ StepTrace

RefreshCheckpointIfLogged ==
    /\ IsEvent("RefreshCheckpoint")
    /\ HasJob
    /\ RefreshCheckpoint(logline.event.job)
    /\ ValidateCapturedState
    /\ StepTrace

GcSweepIfLogged ==
    /\ IsEvent("GcSweep")
    /\ HasSst
    /\ GcSweep(logline.event.sst)
    /\ ValidateCapturedState
    /\ StepTrace

\* ============================================================================
\* SILENT ACTIONS
\* ============================================================================

SilentAdvanceCoordinatorClock ==
    /\ l <= Len(TraceLog)
    /\ coordTime < TraceState.coord_time
    /\ AdvanceCoordinatorClock
    /\ UNCHANGED l

SilentAdvanceWorkerClock ==
    /\ l <= Len(TraceLog)
    /\ \E w \in Workers :
        /\ workerTime[w] < TraceWorkerTime(TraceState.worker_time)[w]
        /\ AdvanceWorkerClock(w)
    /\ UNCHANGED l

SilentExpireCheckpoint ==
    /\ l <= Len(TraceLog)
    /\ \E j \in Jobs :
        /\ checkpointActive[j]
        /\ ~TraceCheckpointActive(TraceState.checkpoints)[j]
        /\ coordTime >= checkpointExpire[j]
        /\ ExpireCheckpoint(j)
    /\ UNCHANGED l

\* ============================================================================
\* INIT / NEXT / PROPERTY
\* ============================================================================

TraceInit ==
    /\ Init
    /\ l = 1

TraceNext ==
    \/ /\ l <= Len(TraceLog)
       /\ StartCoordinatorIfLogged
    \/ /\ l <= Len(TraceLog)
       /\ CrashCoordinatorIfLogged
    \/ /\ l <= Len(TraceLog)
       /\ CoordinatorRefreshCompactionsIfLogged
    \/ /\ l <= Len(TraceLog)
       /\ CoordinatorRefreshManifestIfLogged
    \/ /\ l <= Len(TraceLog)
       /\ MaybeScheduleCompactionsIfLogged
    \/ /\ l <= Len(TraceLog)
       /\ ExternalSubmitIfLogged
    \/ /\ l <= Len(TraceLog)
       /\ MaybeValidateSubmittedFailIfLogged
    \/ /\ l <= Len(TraceLog)
       /\ MaybeValidateSubmittedScheduleIfLogged
    \/ /\ l <= Len(TraceLog)
       /\ MaybeValidateSubmittedDrainIfLogged
    \/ /\ l <= Len(TraceLog)
       /\ PollAndClaimStopDuplicateIfLogged
    \/ /\ l <= Len(TraceLog)
       /\ PollAndClaimIfLogged
    \/ /\ l <= Len(TraceLog)
       /\ DispatchClaimedJobIfLogged
    \/ /\ l <= Len(TraceLog)
       /\ ReleaseClaimPostClaimInvalidIfLogged
    \/ /\ l <= Len(TraceLog)
       /\ WriteOutputSstIfLogged
    \/ /\ l <= Len(TraceLog)
       /\ HeartbeatLoseOwnershipIfLogged
    \/ /\ l <= Len(TraceLog)
       /\ HeartbeatOwnedJobsIfLogged
    \/ /\ l <= Len(TraceLog)
       /\ HandleFinishedSuccessIfLogged
    \/ /\ l <= Len(TraceLog)
       /\ HandleFinishedLostOwnershipIfLogged
    \/ /\ l <= Len(TraceLog)
       /\ HandleFinishedExecErrorIfLogged
    \/ /\ l <= Len(TraceLog)
       /\ ReclaimStaleWorkersIfLogged
    \/ /\ l <= Len(TraceLog)
       /\ CommitCompactedEntriesFailIfLogged
    \/ /\ l <= Len(TraceLog)
       /\ CommitCompactedEntriesWriteManifestIfLogged
    \/ /\ l <= Len(TraceLog)
       /\ CommitCompactedEntriesWriteCompactionsIfLogged
    \/ /\ l <= Len(TraceLog)
       /\ RefreshCheckpointIfLogged
    \/ /\ l <= Len(TraceLog)
       /\ GcSweepIfLogged
    \/ /\ l <= Len(TraceLog)
       /\ SilentAdvanceCoordinatorClock
    \/ /\ l <= Len(TraceLog)
       /\ SilentAdvanceWorkerClock
    \/ /\ l <= Len(TraceLog)
       /\ SilentExpireCheckpoint
    \/ /\ l > Len(TraceLog)
       /\ UNCHANGED vars
       /\ UNCHANGED l

TraceSpec ==
    /\ TraceInit
    /\ [][TraceNext]_traceAllVars
    /\ WF_traceAllVars(TraceNext)
    /\ WF_traceAllVars(SilentAdvanceCoordinatorClock)
    /\ WF_traceAllVars(SilentAdvanceWorkerClock)
    /\ WF_traceAllVars(SilentExpireCheckpoint)
    /\ WF_traceAllVars(GcSweepIfLogged)

TraceMatched == <>(l > Len(TraceLog))

TraceView ==
    <<l, manifestRefs, durJob, coordUp, coordManifestRefs, coordJob,
      coordTime, workerTime, localExecuting, presentSsts, deletedSsts,
      publishCount, retryCount>>

=============================================================================
