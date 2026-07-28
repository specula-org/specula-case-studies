--------------------------- MODULE MC ---------------------------
(*
 * Model checking wrapper for SlateDB distributed compaction coordination.
 *
 * Counter-bounds only the actions that introduce non-determinism:
 *   - local scheduler submissions
 *   - remote Submitted injections
 *   - coordinator crashes
 *   - coordinator / worker clock advancement
 *   - execution-error releases
 *   - GC deletions
 *   - checkpoint refreshes
 *
 * Reactive actions stay unbounded so the fault mechanisms remain reachable.
 *)

EXTENDS base

slatedb == INSTANCE base

\* ============================================================================
\* BOUND CONSTANTS / VARIABLES
\* ============================================================================

CONSTANT MaxLocalSubmitLimit
CONSTANT MaxRemoteSubmitLimit
CONSTANT MaxCrashLimit
CONSTANT MaxCoordClockLimit
CONSTANT MaxWorkerClockLimit
CONSTANT MaxExecErrorLimit
CONSTANT MaxGcSweepLimit
CONSTANT MaxCheckpointRefreshLimit

VARIABLE faultCounters

faultVars == <<faultCounters>>
mcVars == <<vars, faultVars>>

\* ============================================================================
\* COUNTER-BOUNDED ACTIONS
\* ============================================================================

MCMaybeScheduleCompactions(j) ==
    /\ faultCounters.localSubmit < MaxLocalSubmitLimit
    /\ slatedb!MaybeScheduleCompactions(j)
    /\ faultCounters' = [faultCounters EXCEPT !.localSubmit = @ + 1]

MCExternalSubmit(j) ==
    /\ faultCounters.remoteSubmit < MaxRemoteSubmitLimit
    /\ slatedb!ExternalSubmit(j)
    /\ faultCounters' = [faultCounters EXCEPT !.remoteSubmit = @ + 1]

MCCrashCoordinator ==
    /\ faultCounters.crash < MaxCrashLimit
    /\ slatedb!CrashCoordinator
    /\ faultCounters' = [faultCounters EXCEPT !.crash = @ + 1]

MCAdvanceCoordinatorClock ==
    /\ faultCounters.coordClock < MaxCoordClockLimit
    /\ slatedb!AdvanceCoordinatorClock
    /\ faultCounters' = [faultCounters EXCEPT !.coordClock = @ + 1]

MCAdvanceWorkerClock(w) ==
    /\ faultCounters.workerClock < MaxWorkerClockLimit
    /\ slatedb!AdvanceWorkerClock(w)
    /\ faultCounters' = [faultCounters EXCEPT !.workerClock = @ + 1]

MCHandleFinishedExecError(w, j) ==
    /\ faultCounters.execError < MaxExecErrorLimit
    /\ slatedb!HandleFinishedExecError(w, j)
    /\ faultCounters' = [faultCounters EXCEPT !.execError = @ + 1]

MCGcSweep(s) ==
    /\ faultCounters.gcSweep < MaxGcSweepLimit
    /\ slatedb!GcSweep(s)
    /\ faultCounters' = [faultCounters EXCEPT !.gcSweep = @ + 1]

MCRefreshCheckpoint(j) ==
    /\ faultCounters.checkpointRefresh < MaxCheckpointRefreshLimit
    /\ slatedb!RefreshCheckpoint(j)
    /\ faultCounters' = [faultCounters EXCEPT !.checkpointRefresh = @ + 1]

\* ============================================================================
\* UNBOUNDED REACTIVE ACTIONS
\* ============================================================================

MCStartCoordinator ==
    /\ slatedb!StartCoordinator
    /\ UNCHANGED faultVars

MCCoordinatorRefreshCompactions ==
    /\ slatedb!CoordinatorRefreshCompactions
    /\ UNCHANGED faultVars

MCCoordinatorRefreshManifest ==
    /\ slatedb!CoordinatorRefreshManifest
    /\ UNCHANGED faultVars

MCMaybeValidateSubmittedFail(j) ==
    /\ slatedb!MaybeValidateSubmittedFail(j)
    /\ UNCHANGED faultVars

MCMaybeValidateSubmittedSchedule(j) ==
    /\ slatedb!MaybeValidateSubmittedSchedule(j)
    /\ UNCHANGED faultVars

MCMaybeValidateSubmittedDrain(j) ==
    /\ slatedb!MaybeValidateSubmittedDrain(j)
    /\ UNCHANGED faultVars

MCPollAndClaimStopDuplicate(w, j) ==
    /\ slatedb!PollAndClaimStopDuplicate(w, j)
    /\ UNCHANGED faultVars

MCPollAndClaim(w, j) ==
    /\ slatedb!PollAndClaim(w, j)
    /\ UNCHANGED faultVars

MCDispatchClaimedJob(w, j) ==
    /\ slatedb!DispatchClaimedJob(w, j)
    /\ UNCHANGED faultVars

MCReleaseClaimPostClaimInvalid(w, j) ==
    /\ slatedb!ReleaseClaimPostClaimInvalid(w, j)
    /\ UNCHANGED faultVars

MCWriteOutputSst(w, j) ==
    /\ slatedb!WriteOutputSst(w, j)
    /\ UNCHANGED faultVars

MCHeartbeatLoseOwnership(w, j) ==
    /\ slatedb!HeartbeatLoseOwnership(w, j)
    /\ UNCHANGED faultVars

MCHeartbeatOwnedJobs(w, j) ==
    /\ slatedb!HeartbeatOwnedJobs(w, j)
    /\ UNCHANGED faultVars

MCHandleFinishedSuccess(w, j) ==
    /\ slatedb!HandleFinishedSuccess(w, j)
    /\ UNCHANGED faultVars

MCHandleFinishedLostOwnership(w, j) ==
    /\ slatedb!HandleFinishedLostOwnership(w, j)
    /\ UNCHANGED faultVars

MCReclaimStaleWorkers(j) ==
    /\ slatedb!ReclaimStaleWorkers(j)
    /\ UNCHANGED faultVars

MCCommitCompactedEntriesFail(j) ==
    /\ slatedb!CommitCompactedEntriesFail(j)
    /\ UNCHANGED faultVars

MCCommitCompactedEntriesWriteManifest(j) ==
    /\ slatedb!CommitCompactedEntriesWriteManifest(j)
    /\ UNCHANGED faultVars

MCCommitCompactedEntriesWriteCompactions(j) ==
    /\ slatedb!CommitCompactedEntriesWriteCompactions(j)
    /\ UNCHANGED faultVars

MCExpireCheckpoint(j) ==
    /\ slatedb!ExpireCheckpoint(j)
    /\ UNCHANGED faultVars

\* ============================================================================
\* INITIALIZATION / NEXT
\* ============================================================================

MCInit ==
    /\ Init
    /\ faultCounters =
        [localSubmit       |-> 0,
         remoteSubmit      |-> 0,
         crash             |-> 0,
         coordClock        |-> 0,
         workerClock       |-> 0,
         execError         |-> 0,
         gcSweep           |-> 0,
         checkpointRefresh |-> 0]

MCNext ==
    \/ MCStartCoordinator
    \/ MCCrashCoordinator
    \/ MCCoordinatorRefreshCompactions
    \/ MCCoordinatorRefreshManifest
    \/ \E j \in Jobs : MCMaybeScheduleCompactions(j)
    \/ \E j \in Jobs : MCExternalSubmit(j)
    \/ \E j \in Jobs : MCMaybeValidateSubmittedFail(j)
    \/ \E j \in Jobs : MCMaybeValidateSubmittedSchedule(j)
    \/ \E j \in Jobs : MCMaybeValidateSubmittedDrain(j)
    \/ \E w \in Workers : \E j \in Jobs : MCPollAndClaimStopDuplicate(w, j)
    \/ \E w \in Workers : \E j \in Jobs : MCPollAndClaim(w, j)
    \/ \E w \in Workers : \E j \in Jobs : MCDispatchClaimedJob(w, j)
    \/ \E w \in Workers : \E j \in Jobs : MCReleaseClaimPostClaimInvalid(w, j)
    \/ \E w \in Workers : \E j \in Jobs : MCWriteOutputSst(w, j)
    \/ \E w \in Workers : \E j \in Jobs : MCHeartbeatLoseOwnership(w, j)
    \/ \E w \in Workers : \E j \in Jobs : MCHeartbeatOwnedJobs(w, j)
    \/ \E w \in Workers : \E j \in Jobs : MCHandleFinishedSuccess(w, j)
    \/ \E w \in Workers : \E j \in Jobs : MCHandleFinishedLostOwnership(w, j)
    \/ \E w \in Workers : \E j \in Jobs : MCHandleFinishedExecError(w, j)
    \/ \E j \in Jobs : MCReclaimStaleWorkers(j)
    \/ \E j \in Jobs : MCCommitCompactedEntriesFail(j)
    \/ \E j \in Jobs : MCCommitCompactedEntriesWriteManifest(j)
    \/ \E j \in Jobs : MCCommitCompactedEntriesWriteCompactions(j)
    \/ \E j \in Jobs : MCRefreshCheckpoint(j)
    \/ \E j \in Jobs : MCExpireCheckpoint(j)
    \/ MCAdvanceCoordinatorClock
    \/ \E w \in Workers : MCAdvanceWorkerClock(w)
    \/ \E s \in GcManagedSsts : MCGcSweep(s)

MCSpec == MCInit /\ [][MCNext]_mcVars

\* ============================================================================
\* SYMMETRY / VIEW / CONSTRAINTS
\* ============================================================================

Symmetry == Permutations(Workers)

ModelView ==
    <<manifestRefs, checkpointActive, durJob, coordUp, coordManifestRefs, coordJob,
      coordTime, workerTime, localExecuting, bufferedCtx, presentSsts, deletedSsts,
      publishCount, retryCount>>

CheckpointConstraint ==
    Cardinality({j \in Jobs : checkpointActive[j]}) <= 2

=============================================================================
