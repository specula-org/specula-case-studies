--------------------------- MODULE base ---------------------------
(*
 * TLA+ specification for SlateDB distributed compaction coordination.
 *
 * Derived from:
 *   - slatedb/src/compactor.rs
 *   - slatedb/src/compactor_state.rs
 *   - slatedb/src/compactor_state_protocols.rs
 *   - slatedb/src/compaction_worker.rs
 *   - slatedb/src/compactions_store.rs
 *   - slatedb/src/garbage_collector/compacted_gc.rs
 *   - slatedb/src/manifest/store.rs
 *
 * Category A (distributed / durable-shared-state coordination).
 *
 * Bug-family-driven scope:
 *   - Family 1: split admission control for externally submitted compactions
 *   - Family 2: non-atomic checkpoint -> manifest -> .compactions publication
 *   - Family 3: independent claim / heartbeat / reclaim / finish loops
 *   - Family 4: stale refresh / merge / fencing across manifest and .compactions
 *   - Family 5: fragmented concurrent-compaction accounting
 *)

EXTENDS Integers, FiniteSets, Sequences, TLC

\* ============================================================================
\* CONSTANTS
\* ============================================================================

CONSTANT Jobs
CONSTANT Workers
CONSTANT Segments
CONSTANT InputSsts
CONSTANT OutputSsts
CONSTANT GcManagedSsts
CONSTANT L0Ssts
CONSTANT RootSegment
CONSTANT Nil

\* Job / protocol state constants
CONSTANTS
    Absent,
    Submitted,
    Scheduled,
    Running,
    Compacted,
    Completed,
    Failed

\* Submission origin constants (Family 1)
CONSTANTS
    NoOrigin,
    LocalOrigin,
    RemoteOrigin

\* Retry reason constants (Family 2)
CONSTANTS
    NoRetry,
    PostClaimInvalid,
    ExecErrorRetry,
    TimeoutRetry,
    RestartRetry

\* Compaction kind constants
CONSTANTS
    TieredKind,
    DrainKind

\* Small-model tuning constants
CONSTANT MaxConcurrent
CONSTANT MaxWorkerClaims
CONSTANT HeartbeatTimeout
CONSTANT CheckpointTTL
CONSTANT GcMinAge

\* Per-job static structure from the modeling brief / code analysis
CONSTANT JobSources
CONSTANT JobOutput
CONSTANT JobSegment
CONSTANT JobKind
CONSTANT JobHasL0
CONSTANT JobHasSR
CONSTANT SchedulerAllows
CONSTANT DrainCoversWatermark
CONSTANT InitialManifestRefs
CONSTANT InputSstTs

\* Small-model operator defaults used by the generated cfgs.
DefaultJobSources ==
    [j \in {"j1", "j2", "j3"} |->
        CASE j = "j1" -> {"s0"}
          [] j = "j2" -> {"s0"}
          [] OTHER    -> {"s2"}]

DefaultJobOutput ==
    [j \in {"j1", "j2", "j3"} |->
        CASE j = "j1" -> "o0"
          [] j = "j2" -> "o0"
          [] OTHER    -> "o2"]

DefaultJobSegment ==
    [j \in {"j1", "j2", "j3"} |->
        CASE j = "j1" -> "root"
          [] j = "j2" -> "root"
          [] OTHER    -> "segA"]

DefaultJobKind ==
    [j \in {"j1", "j2", "j3"} |-> "TieredKind"]

DefaultJobHasL0 ==
    [j \in {"j1", "j2", "j3"} |->
        IF j = "j3" THEN TRUE ELSE FALSE]

DefaultJobHasSR ==
    [j \in {"j1", "j2", "j3"} |->
        IF j = "j3" THEN FALSE ELSE TRUE]

DefaultSchedulerAllows ==
    [j \in {"j1", "j2", "j3"} |-> TRUE]

DefaultDrainCoversWatermark ==
    [j \in {"j1", "j2", "j3"} |-> TRUE]

DefaultInitialManifestRefs == {"s0", "s2"}

DefaultInputSstTs ==
    [s \in {"s0", "s1", "s2", "s3"} |->
        CASE s = "s0" -> 0
          [] s = "s1" -> 1
          [] s = "s2" -> 2
          [] OTHER    -> 3]

\* Hunt-specific job presets. These are used only by selected MC_hunt configs to
\* keep the small-world setup aligned with the implementation scenarios that the
\* confirmation loop validated.
Family1ConfirmedL0JobSources ==
    [j \in {"j1", "j2", "j3"} |->
        CASE j = "j1" -> {"s0"}
          [] j = "j2" -> {"s0"}
          [] OTHER    -> {"s2"}]

Family1ConfirmedL0JobOutput ==
    [j \in {"j1", "j2", "j3"} |->
        CASE j = "j1" -> "o0"
          [] j = "j2" -> "o0"
          [] OTHER    -> "o2"]

Family1ConfirmedL0JobSegment ==
    [j \in {"j1", "j2", "j3"} |->
        CASE j = "j1" -> "root"
          [] j = "j2" -> "root"
          [] OTHER    -> "segA"]

Family1ConfirmedL0JobHasL0 ==
    [j \in {"j1", "j2", "j3"} |->
        CASE j = "j1" -> TRUE
          [] j = "j2" -> TRUE
          [] OTHER    -> TRUE]

Family1ConfirmedL0JobHasSR ==
    [j \in {"j1", "j2", "j3"} |->
        CASE j = "j1" -> FALSE
          [] j = "j2" -> FALSE
          [] OTHER    -> FALSE]

Family1ConfirmedL0InitialManifestRefs == {"s0", "s2"}

Family5CapacityJobSources ==
    [j \in {"j1", "j2", "j3"} |->
        CASE j = "j1" -> {"s0"}
          [] j = "j2" -> {"s1"}
          [] OTHER    -> {"s2"}]

Family5CapacityJobOutput ==
    [j \in {"j1", "j2", "j3"} |->
        CASE j = "j1" -> "o0"
          [] j = "j2" -> "o1"
          [] OTHER    -> "o2"]

Family5CapacityJobSegment ==
    [j \in {"j1", "j2", "j3"} |->
        CASE j = "j1" -> "root"
          [] j = "j2" -> "root"
          [] OTHER    -> "segA"]

Family5CapacityJobHasL0 ==
    [j \in {"j1", "j2", "j3"} |-> FALSE]

Family5CapacityJobHasSR ==
    [j \in {"j1", "j2", "j3"} |-> TRUE]

Family5CapacityInitialManifestRefs == {"s0", "s1", "s2"}

\* ============================================================================
\* VARIABLES
\* ============================================================================

\* --- Durable manifest state (.manifest) ---
VARIABLE manifestRefs
VARIABLE checkpointActive
VARIABLE checkpointRefs
VARIABLE checkpointExpire
VARIABLE manifestVersion
VARIABLE manifestEpoch

\* --- Durable compactions state (.compactions) ---
VARIABLE compactionsExists
VARIABLE durJob
VARIABLE compactionsVersion
VARIABLE compactionsEpoch

\* --- Coordinator-local dirty state (CompactorStateWriter.state) ---
VARIABLE coordUp
VARIABLE coordManifestRefs
VARIABLE coordCheckpointActive
VARIABLE coordCheckpointRefs
VARIABLE coordCheckpointExpire
VARIABLE coordJob
VARIABLE coordSeenManifestVersion
VARIABLE coordSeenCompactionsVersion

\* --- Local execution / clocks / physical SST store ---
VARIABLE coordTime
VARIABLE workerTime
VARIABLE localExecuting
VARIABLE bufferedCtx
VARIABLE presentSsts
VARIABLE deletedSsts
VARIABLE outputTs

\* --- Bug-family bookkeeping ---
VARIABLE publishCount
VARIABLE retryCount

\* ============================================================================
\* VARIABLE GROUPS
\* ============================================================================

manifestVars ==
    <<manifestRefs, checkpointActive, checkpointRefs, checkpointExpire,
      manifestVersion, manifestEpoch>>

compactionsVars ==
    <<compactionsExists, durJob, compactionsVersion, compactionsEpoch>>

coordVars ==
    <<coordUp, coordManifestRefs, coordCheckpointActive, coordCheckpointRefs,
      coordCheckpointExpire, coordJob, coordSeenManifestVersion,
      coordSeenCompactionsVersion>>

runtimeVars ==
    <<coordTime, workerTime, localExecuting, bufferedCtx,
      presentSsts, deletedSsts, outputTs>>

bookkeepingVars == <<publishCount, retryCount>>

vars == <<manifestVars, compactionsVars, coordVars, runtimeVars, bookkeepingVars>>

\* ============================================================================
\* HELPERS
\* ============================================================================

JobStatuses == {Absent, Submitted, Scheduled, Running, Compacted, Completed, Failed}
Origins     == {NoOrigin, LocalOrigin, RemoteOrigin}
RetryKinds  == {NoRetry, PostClaimInvalid, ExecErrorRetry, TimeoutRetry, RestartRetry}
Kinds       == {TieredKind, DrainKind}
SstUniverse == InputSsts \cup OutputSsts

JobType ==
    [status      : JobStatuses,
     worker      : Workers \cup {Nil},
     lastHb      : Int,
     origin      : Origins,
     retry       : RetryKinds,
     ctx         : BOOLEAN,
     output      : BOOLEAN,
     submittedTs : Int]

EmptyJob ==
    [status      |-> Absent,
     worker      |-> Nil,
     lastHb      |-> 0,
     origin      |-> NoOrigin,
     retry       |-> NoRetry,
     ctx         |-> FALSE,
     output      |-> FALSE,
     submittedTs |-> 0]

ActiveStatuses == {Submitted, Scheduled, Running, Compacted}
SlotStatuses   == {Submitted, Scheduled, Running}
\* Submitted entries are durable backlog awaiting coordinator validation. They are
\* not yet worker-claimable and the implementation can transiently hold conflicting
\* Submitted specs before the validation chokepoint resolves them.
LiveConflictStatuses == {Scheduled, Running, Compacted}

SetMin(S) == CHOOSE x \in S : \A y \in S : x <= y
SetMax(S) == CHOOSE x \in S : \A y \in S : x >= y

SstTimestamp(s) ==
    IF s \in InputSsts
    THEN InputSstTs[s]
    ELSE outputTs[s]

AllCheckpointRefs ==
    UNION {IF checkpointActive[j] THEN checkpointRefs[j] ELSE {} : j \in Jobs}

RunningCount(jobMap) ==
    Cardinality({j \in Jobs : jobMap[j].status = Running})

SlotCount(jobMap) ==
    Cardinality({j \in Jobs : jobMap[j].status \in SlotStatuses})

HasDrainConflict(j, jobMap) ==
    \E k \in Jobs :
        /\ k /= j
        /\ jobMap[k].status \in ActiveStatuses
        /\ JobKind[j] = DrainKind
        /\ JobKind[k] = DrainKind
        /\ JobSegment[k] = JobSegment[j]

HasDestinationConflict(j, jobMap) ==
    \E k \in Jobs :
        /\ k /= j
        /\ jobMap[k].status \in ActiveStatuses
        /\ JobKind[j] = TieredKind
        /\ JobKind[k] = TieredKind
        /\ JobOutput[k] = JobOutput[j]

ShouldAdoptStateTransition(localStatus, remoteStatus) ==
    CASE localStatus = Submitted -> remoteStatus = Compacted
      [] localStatus = Scheduled -> remoteStatus \in {Running, Compacted}
      [] localStatus = Running   -> remoteStatus \in {Scheduled, Running, Compacted}
      [] localStatus = Compacted -> remoteStatus = Compacted
      [] OTHER                   -> FALSE

MergedJob(localRec, remoteRec) ==
    CASE localRec.status = Absent /\ remoteRec.status \in {Submitted, Compacted, Completed, Failed}
            -> remoteRec
      [] localRec.status = Absent /\ remoteRec.status \in {Scheduled, Running}
            -> localRec
      [] localRec.status # Absent /\ ShouldAdoptStateTransition(localRec.status, remoteRec.status)
            -> remoteRec
      [] OTHER -> localRec

SourcesPresent(j, manifestSet) ==
    JobSources[j] \subseteq manifestSet

TargetSegmentValid(j) ==
    ~(JobKind[j] = DrainKind /\ JobSegment[j] = RootSegment)

DestinationFresh(j, manifestSet) ==
    IF JobKind[j] = DrainKind
    THEN TRUE
    ELSE ~(JobOutput[j] \in (manifestSet \ JobSources[j]))

NoParallelL0(j, jobMap) ==
    IF ~JobHasL0[j]
    THEN TRUE
    ELSE ~ \E k \in Jobs :
            /\ k /= j
            /\ jobMap[k].status \in {Scheduled, Running}
            /\ JobHasL0[k]
            /\ JobSegment[k] = JobSegment[j]

ValidateCompaction(jobMap, manifestSet, j) ==
    /\ JobSources[j] # {}
    /\ TargetSegmentValid(j)
    /\ SourcesPresent(j, manifestSet)
    /\ DestinationFresh(j, manifestSet)
    /\ IF JobKind[j] = DrainKind THEN DrainCoversWatermark[j] ELSE TRUE
    /\ NoParallelL0(j, jobMap)
    /\ SchedulerAllows[j]

ClaimValid(j, manifestSet) ==
    /\ JobKind[j] = TieredKind
    /\ SourcesPresent(j, manifestSet)

PublishedInManifest(j) ==
    IF JobKind[j] = DrainKind
    THEN JobSources[j] \cap manifestRefs = {}
    ELSE /\ JobOutput[j] \in manifestRefs
         /\ JobSources[j] \cap manifestRefs = {}

InFlightOutputRefs ==
    UNION {
        IF /\ JobOutput[j] \in presentSsts
           /\ (durJob[j].status \in {Running, Compacted}
               \/ \E w \in Workers : j \in localExecuting[w])
        THEN {JobOutput[j]}
        ELSE {}
        : j \in Jobs
    }

CompactionLowWatermark ==
    LET tracked == {j \in Jobs : durJob[j].status # Absent}
    IN IF tracked = {}
       THEN 0
       ELSE SetMin({durJob[j].submittedTs : j \in tracked})

NewestL0Ts ==
    LET liveL0 == manifestRefs \cap L0Ssts
    IN IF liveL0 = {}
       THEN 0
       ELSE SetMax({SstTimestamp(s) : s \in liveL0})

GcCutoff ==
    SetMin({coordTime - GcMinAge, CompactionLowWatermark, NewestL0Ts})

SameLogicalCompaction(j, k) ==
    /\ JobSegment[j] = JobSegment[k]
    /\ JobKind[j] = JobKind[k]
    /\ JobSources[j] = JobSources[k]
    /\ IF JobKind[j] = DrainKind
       THEN TRUE
       ELSE JobOutput[j] = JobOutput[k]

ClaimableByLiveWorker(j) ==
    /\ durJob[j].status = Scheduled
    /\ durJob[j].worker = Nil
    /\ \E w \in Workers : Cardinality(localExecuting[w]) < MaxWorkerClaims

CoordinatorCanWriteManifest ==
    /\ coordUp
    /\ coordSeenManifestVersion = manifestVersion
    /\ coordSeenCompactionsVersion = compactionsVersion

CoordinatorCanWriteCompactions ==
    /\ coordUp
    /\ compactionsExists
    /\ coordSeenCompactionsVersion = compactionsVersion

\* ============================================================================
\* INITIALIZATION
\* ============================================================================

Init ==
    /\ \* Durable manifest starts with the brief-provided live SST set.
       manifestRefs = InitialManifestRefs
    /\ checkpointActive = [j \in Jobs |-> FALSE]
    /\ checkpointRefs = [j \in Jobs |-> {}]
    /\ checkpointExpire = [j \in Jobs |-> 0]
    /\ manifestVersion = 1
    /\ manifestEpoch = 0

    /\ \* Fresh bootstrap: .compactions may not exist yet (compactor_state_protocols.rs:189-195).
       compactionsExists = FALSE
    /\ durJob = [j \in Jobs |-> EmptyJob]
    /\ compactionsVersion = 0
    /\ compactionsEpoch = 0

    /\ \* Coordinator starts down; first StartCoordinator performs fencing and bootstrap.
       coordUp = FALSE
    /\ coordManifestRefs = InitialManifestRefs
    /\ coordCheckpointActive = [j \in Jobs |-> FALSE]
    /\ coordCheckpointRefs = [j \in Jobs |-> {}]
    /\ coordCheckpointExpire = [j \in Jobs |-> 0]
    /\ coordJob = [j \in Jobs |-> EmptyJob]
    /\ coordSeenManifestVersion = 0
    /\ coordSeenCompactionsVersion = 0

    /\ coordTime = 0
    /\ workerTime = [w \in Workers |-> 0]
    /\ localExecuting = [w \in Workers |-> {}]
    /\ bufferedCtx = [w \in Workers |-> {}]

    /\ presentSsts = InitialManifestRefs
    /\ deletedSsts = {}
    /\ outputTs = [s \in OutputSsts |-> 0]

    /\ publishCount = [j \in Jobs |-> 0]
    /\ retryCount = [j \in Jobs |-> 0]

\* ============================================================================
\* ACTIONS
\* ============================================================================

\* --------------------------------------------------------------------------
\* StartCoordinator: fence manifest, lazily create/load .compactions, and
\* reset Scheduled -> Submitted on restart.
\* Reference: compactor_state_protocols.rs:129-205
\* --------------------------------------------------------------------------
StartCoordinator ==
    /\ ~coordUp
    /\ \* Fence the manifest by taking a new compactor epoch first
       \* (compactor_state_protocols.rs:177-204).
       manifestEpoch' = manifestEpoch + 1
    /\ \* Lazily create .compactions if absent and align its epoch with the
       \* fenced manifest epoch (compactor_state_protocols.rs:189-203).
       compactionsExists' = TRUE
    /\ compactionsEpoch' = manifestEpoch'
    /\ \* Reset only Scheduled -> Submitted; leave Running untouched for later
       \* timeout reclaim (compactor_state_protocols.rs:146-167).
       LET restarted ==
            [j \in Jobs |->
                IF durJob[j].status = Scheduled
                THEN [durJob[j] EXCEPT !.status = Submitted,
                                       !.worker = Nil,
                                       !.retry = RestartRetry]
                ELSE durJob[j]]
       IN /\ durJob' = restarted
          /\ compactionsVersion' = compactionsVersion + 1
          /\ coordJob' = restarted
    /\ \* Seed coordinator-local manifest and checkpoint state from the fenced
       \* durable view (compactor_state_protocols.rs:145-168, 235-239).
       coordManifestRefs' = manifestRefs
    /\ coordCheckpointActive' = checkpointActive
    /\ coordCheckpointRefs' = checkpointRefs
    /\ coordCheckpointExpire' = checkpointExpire
    /\ coordSeenManifestVersion' = manifestVersion
    /\ coordSeenCompactionsVersion' = compactionsVersion + 1
    /\ coordUp' = TRUE
    /\ UNCHANGED <<manifestRefs, checkpointActive, checkpointRefs, checkpointExpire,
                   manifestVersion, coordTime, workerTime, localExecuting, bufferedCtx,
                   presentSsts, deletedSsts, outputTs, publishCount, retryCount>>

\* --------------------------------------------------------------------------
\* CrashCoordinator: lose in-memory coordinator-local state without changing
\* durable state.
\* Reference: compactor_state_protocols.rs:321-330 and compactor.rs:843-858
\* --------------------------------------------------------------------------
CrashCoordinator ==
    /\ coordUp
    /\ coordUp' = FALSE
    /\ UNCHANGED <<manifestVars, compactionsVars,
                   coordManifestRefs, coordCheckpointActive, coordCheckpointRefs,
                   coordCheckpointExpire, coordJob, coordSeenManifestVersion,
                   coordSeenCompactionsVersion, runtimeVars, bookkeepingVars>>

\* --------------------------------------------------------------------------
\* CoordinatorRefreshCompactions: merge the latest durable .compactions view
\* into the coordinator-local copy.
\* Reference: compactor_state_protocols.rs:219-239,
\*            compactor_state.rs:878-944
\* --------------------------------------------------------------------------
CoordinatorRefreshCompactions ==
    /\ coordUp
    /\ compactionsExists
    /\ \* Merge vacant local slots by accepting Submitted / Compacted / terminal
       \* durable entries but skipping remote Scheduled / Running that are absent
       \* locally (compactor_state.rs:892-918).
       \* Merge occupied local slots only across the allowed remote state
       \* transitions (compactor_state.rs:919-943, 289-323).
       coordJob' = [j \in Jobs |-> MergedJob(coordJob[j], durJob[j])]
    /\ coordSeenCompactionsVersion' = compactionsVersion
    /\ UNCHANGED <<manifestVars, compactionsVars,
                   coordUp, coordManifestRefs, coordCheckpointActive,
                   coordCheckpointRefs, coordCheckpointExpire,
                   coordSeenManifestVersion, runtimeVars, bookkeepingVars>>

\* --------------------------------------------------------------------------
\* CoordinatorRefreshManifest: refresh the durable manifest into the
\* coordinator-local copy.
\* Reference: compactor_state_protocols.rs:212-239,
\*            compactor_state.rs:946-974
\* --------------------------------------------------------------------------
CoordinatorRefreshManifest ==
    /\ coordUp
    /\ \* The production merge preserves writer-side fields while refreshing
       \* manifest state; this abstraction takes the refreshed durable view
       \* directly because the modeled bug families depend on stale-vs-fresh
       \* visibility, not on the unmodeled writer merge internals
       \* (compactor_state.rs:951-973).
       coordManifestRefs' = manifestRefs
    /\ coordCheckpointActive' = checkpointActive
    /\ coordCheckpointRefs' = checkpointRefs
    /\ coordCheckpointExpire' = checkpointExpire
    /\ coordSeenManifestVersion' = manifestVersion
    /\ UNCHANGED <<manifestVars, compactionsVars, coordUp, coordJob,
                   coordSeenCompactionsVersion, runtimeVars, bookkeepingVars>>

\* --------------------------------------------------------------------------
\* MaybeScheduleCompactions: scheduler proposes a new local compaction and the
\* coordinator persists it as Submitted.
\* Reference: compactor.rs:1123-1161,
\*            compactor.rs:1269-1273,
\*            compactor_state.rs:976-1024
\* --------------------------------------------------------------------------
MaybeScheduleCompactions(j) ==
    /\ CoordinatorCanWriteCompactions
    /\ coordJob[j].status = Absent
    /\ \* Capacity uses only Running jobs, not Submitted / Scheduled
       \* (compactor.rs:1127-1136, 1269-1273).
       RunningCount(coordJob) < MaxConcurrent
    /\ \* add_compaction's explicit drain-per-segment guard
       \* (compactor_state.rs:990-1001).
       ~HasDrainConflict(j, coordJob)
    /\ \* add_compaction's destination-collision guard across active jobs
       \* (compactor_state.rs:1002-1015).
       ~HasDestinationConflict(j, coordJob)
    /\ LET submitted ==
            [status      |-> Submitted,
             worker      |-> Nil,
             lastHb      |-> 0,
             origin      |-> LocalOrigin,
             retry       |-> NoRetry,
             ctx         |-> FALSE,
             output      |-> FALSE,
             submittedTs |-> coordTime]
       IN /\ coordJob' = [coordJob EXCEPT ![j] = submitted]
          /\ \* Persist the new Submitted entry through write_compactions_safely
             \* (compactor.rs:1156-1159, compactor_state_protocols.rs:296-319).
             durJob' = [durJob EXCEPT ![j] = submitted]
    /\ compactionsExists' = TRUE
    /\ compactionsVersion' = compactionsVersion + 1
    /\ coordSeenCompactionsVersion' = compactionsVersion + 1
    /\ UNCHANGED <<manifestVars, compactionsEpoch,
                   coordUp, coordManifestRefs, coordCheckpointActive,
                   coordCheckpointRefs, coordCheckpointExpire,
                   coordSeenManifestVersion, runtimeVars, bookkeepingVars>>

\* --------------------------------------------------------------------------
\* ExternalSubmit: a remote / reloaded Submitted job appears in durable
\* .compactions without passing local add_compaction admission.
\* Reference: compactor_state.rs:878-944
\* --------------------------------------------------------------------------
ExternalSubmit(j) ==
    /\ compactionsExists
    /\ durJob[j].status = Absent
    /\ \* Remote Submitted entries can be accepted into the durable object and
       \* later merged into local state without add_compaction conflict checks
       \* (compactor_state.rs:892-910).
       LET submitted ==
            [status      |-> Submitted,
             worker      |-> Nil,
             lastHb      |-> 0,
             origin      |-> RemoteOrigin,
             retry       |-> NoRetry,
             ctx         |-> FALSE,
             output      |-> FALSE,
             submittedTs |-> coordTime]
       IN durJob' = [durJob EXCEPT ![j] = submitted]
    /\ compactionsVersion' = compactionsVersion + 1
    /\ UNCHANGED <<manifestVars, compactionsExists, compactionsEpoch,
                   coordVars, runtimeVars, bookkeepingVars>>

\* --------------------------------------------------------------------------
\* MaybeValidateSubmittedFail: canonical Submitted validation rejects the job.
\* Reference: compactor.rs:1164-1225, 929-1044
\* --------------------------------------------------------------------------
MaybeValidateSubmittedFail(j) ==
    /\ CoordinatorCanWriteManifest
    /\ coordJob[j].status = Submitted
    /\ \* validate_compaction re-checks manifest-derived validity but not the
       \* upstream add_compaction overlap rules (compactor.rs:910-929, 931-1044).
       ~ValidateCompaction(coordJob, coordManifestRefs, j)
    /\ LET failed == [coordJob[j] EXCEPT !.status = Failed,
                                         !.retry = NoRetry,
                                         !.ctx = FALSE]
       IN /\ coordJob' = [coordJob EXCEPT ![j] = failed]
          /\ durJob' = [durJob EXCEPT ![j] = failed]
    /\ compactionsVersion' = compactionsVersion + 1
    /\ coordSeenCompactionsVersion' = compactionsVersion + 1
    /\ UNCHANGED <<manifestVars, compactionsExists, compactionsEpoch,
                   coordUp, coordManifestRefs, coordCheckpointActive,
                   coordCheckpointRefs, coordCheckpointExpire,
                   coordSeenManifestVersion, runtimeVars, publishCount, retryCount>>

\* --------------------------------------------------------------------------
\* MaybeValidateSubmittedSchedule: valid tiered Submitted job becomes Scheduled.
\* Reference: compactor.rs:1204-1222
\* --------------------------------------------------------------------------
MaybeValidateSubmittedSchedule(j) ==
    /\ CoordinatorCanWriteManifest
    /\ coordJob[j].status = Submitted
    /\ JobKind[j] = TieredKind
    /\ \* Valid tiered jobs clear ctx and become Scheduled so only workers act
       \* on them after this chokepoint (compactor.rs:1204-1215).
       ValidateCompaction(coordJob, coordManifestRefs, j)
    /\ LET scheduled == [coordJob[j] EXCEPT !.status = Scheduled,
                                            !.worker = Nil,
                                            !.ctx = FALSE,
                                            !.retry = NoRetry]
       IN /\ coordJob' = [coordJob EXCEPT ![j] = scheduled]
          /\ durJob' = [durJob EXCEPT ![j] = scheduled]
    /\ compactionsVersion' = compactionsVersion + 1
    /\ coordSeenCompactionsVersion' = compactionsVersion + 1
    /\ UNCHANGED <<manifestVars, compactionsExists, compactionsEpoch,
                   coordUp, coordManifestRefs, coordCheckpointActive,
                   coordCheckpointRefs, coordCheckpointExpire,
                   coordSeenManifestVersion, runtimeVars, publishCount, retryCount>>

\* --------------------------------------------------------------------------
\* MaybeValidateSubmittedDrain: valid drain job applies directly to manifest and
\* completes without a worker.
\* Reference: compactor.rs:1204-1222,
\*            compactor_state.rs:1135-1215,
\*            compactor_state_protocols.rs:241-330
\* --------------------------------------------------------------------------
MaybeValidateSubmittedDrain(j) ==
    /\ CoordinatorCanWriteManifest
    /\ coordJob[j].status = Submitted
    /\ JobKind[j] = DrainKind
    /\ ValidateCompaction(coordJob, coordManifestRefs, j)
    /\ \* Drain completion updates manifest state immediately; write_state_safely
       \* still writes a checkpoint before the manifest update
       \* (compactor.rs:1204-1221, compactor_state_protocols.rs:247-329).
       LET drainedManifest == coordManifestRefs \ JobSources[j]
           completed == [coordJob[j] EXCEPT !.status = Completed,
                                           !.retry = NoRetry,
                                           !.ctx = FALSE]
       IN /\ coordManifestRefs' = drainedManifest
          /\ coordCheckpointActive' = [coordCheckpointActive EXCEPT ![j] = TRUE]
          /\ coordCheckpointRefs' = [coordCheckpointRefs EXCEPT ![j] = JobSources[j] \cap coordManifestRefs]
          /\ coordCheckpointExpire' = [coordCheckpointExpire EXCEPT ![j] = coordTime + CheckpointTTL]
          /\ coordJob' = [coordJob EXCEPT ![j] = completed]
          /\ manifestRefs' = drainedManifest
          /\ checkpointActive' = [checkpointActive EXCEPT ![j] = TRUE]
          /\ checkpointRefs' = [checkpointRefs EXCEPT ![j] = JobSources[j] \cap manifestRefs]
          /\ checkpointExpire' = [checkpointExpire EXCEPT ![j] = coordTime + CheckpointTTL]
          /\ durJob' = [durJob EXCEPT ![j] = completed]
    /\ manifestVersion' = manifestVersion + 1
    /\ compactionsVersion' = compactionsVersion + 1
    /\ coordSeenManifestVersion' = manifestVersion + 1
    /\ coordSeenCompactionsVersion' = compactionsVersion + 1
    /\ publishCount' = [publishCount EXCEPT ![j] = @ + 1]
    /\ UNCHANGED <<manifestEpoch, compactionsExists, compactionsEpoch,
                   coordUp, coordTime, workerTime, localExecuting, bufferedCtx,
                   presentSsts, deletedSsts, outputTs, retryCount>>

\* --------------------------------------------------------------------------
\* PollAndClaimStopDuplicate: worker sees a reclaimed Scheduled copy of work it
\* is still executing locally and stops the duplicate local execution.
\* Reference: compaction_worker.rs:338-350
\* --------------------------------------------------------------------------
PollAndClaimStopDuplicate(w, j) ==
    /\ compactionsExists
    /\ durJob[j].status = Scheduled
    /\ durJob[j].worker = Nil
    /\ j \in localExecuting[w]
    /\ \* The worker must not re-claim local duplicate execution; it stops the
       \* local job so a later poll can re-claim safely (compaction_worker.rs:338-350).
       localExecuting' = [localExecuting EXCEPT ![w] = @ \ {j}]
    /\ bufferedCtx' = [bufferedCtx EXCEPT ![w] = @ \ {j}]
    /\ UNCHANGED <<manifestVars, compactionsVars, coordVars, coordTime,
                   workerTime, presentSsts, deletedSsts, outputTs,
                   publishCount, retryCount>>

\* --------------------------------------------------------------------------
\* PollAndClaim: CAS claim Scheduled -> Running for one worker.
\* Reference: compaction_worker.rs:310-417
\* --------------------------------------------------------------------------
PollAndClaim(w, j) ==
    /\ compactionsExists
    /\ durJob[j].status = Scheduled
    /\ durJob[j].worker = Nil
    /\ j \notin localExecuting[w]
    /\ Cardinality(localExecuting[w]) < MaxWorkerClaims
    /\ \* Claim succeeds by writing Running plus worker heartbeat to durable
       \* .compactions (compaction_worker.rs:363-380).
       LET claimed == [durJob[j] EXCEPT !.status = Running,
                                         !.worker = w,
                                         !.lastHb = workerTime[w]]
       IN durJob' = [durJob EXCEPT ![j] = claimed]
    /\ compactionsVersion' = compactionsVersion + 1
    /\ UNCHANGED <<manifestVars, compactionsExists, compactionsEpoch,
                   coordVars, coordTime, workerTime, localExecuting, bufferedCtx,
                   presentSsts, deletedSsts, outputTs, publishCount, retryCount>>

\* --------------------------------------------------------------------------
\* DispatchClaimedJob: build executor args against a manifest read performed
\* after the claim CAS; valid claims become local execution.
\* Reference: compaction_worker.rs:383-503
\* --------------------------------------------------------------------------
DispatchClaimedJob(w, j) ==
    /\ durJob[j].status = Running
    /\ durJob[j].worker = w
    /\ j \notin localExecuting[w]
    /\ \* build_job_args re-reads the manifest after the claim and only starts
       \* the executor if the sources still match the manifest
       \* (compaction_worker.rs:383-503).
       ClaimValid(j, manifestRefs)
    /\ localExecuting' = [localExecuting EXCEPT ![w] = @ \cup {j}]
    /\ UNCHANGED <<manifestVars, compactionsVars, coordVars, coordTime,
                   workerTime, bufferedCtx, presentSsts, deletedSsts, outputTs,
                   publishCount, retryCount>>

\* --------------------------------------------------------------------------
\* ReleaseClaimPostClaimInvalid: claimed work fails the post-claim manifest
\* check and is released back to Scheduled.
\* Reference: compaction_worker.rs:405-413, 647-682
\* --------------------------------------------------------------------------
ReleaseClaimPostClaimInvalid(w, j) ==
    /\ durJob[j].status = Running
    /\ durJob[j].worker = w
    /\ j \notin localExecuting[w]
    /\ \* Post-claim validation rejects missing / mismatched sources and returns
       \* the claim to Scheduled rather than terminally failing the job
       \* (compaction_worker.rs:405-413, 457-476, 647-682).
       ~ClaimValid(j, manifestRefs)
    /\ LET released == [durJob[j] EXCEPT !.status = Scheduled,
                                          !.worker = Nil,
                                          !.lastHb = 0,
                                          !.retry = PostClaimInvalid]
       IN durJob' = [durJob EXCEPT ![j] = released]
    /\ compactionsVersion' = compactionsVersion + 1
    /\ retryCount' = [retryCount EXCEPT ![j] = @ + 1]
    /\ UNCHANGED <<manifestVars, compactionsExists, compactionsEpoch,
                   coordVars, coordTime, workerTime, localExecuting, bufferedCtx,
                   presentSsts, deletedSsts, outputTs, publishCount>>

\* --------------------------------------------------------------------------
\* WriteOutputSst: abstract the executor writing the output SST before the
\* worker reports Compacted.
\* Reference: compaction_worker.rs:587-621,
\*            compacted_gc.rs:201-210
\* --------------------------------------------------------------------------
WriteOutputSst(w, j) ==
    /\ j \in localExecuting[w]
    /\ JobKind[j] = TieredKind
    /\ JobOutput[j] \notin presentSsts
    /\ \* Output SST ids are minted when the worker materializes the result, so
       \* the modeled output timestamp cannot predate the compaction record that
       \* introduced the job into durable state.
       workerTime[w] >= durJob[j].submittedTs
    /\ \* Physical output SSTs exist before manifest publication and before the
       \* worker writes Compacted back to .compactions
       \* (compaction_worker.rs:587-621, compacted_gc.rs:201-210).
       presentSsts' = presentSsts \cup {JobOutput[j]}
    /\ \* If the same output id is re-materialized after an earlier GC pass, the
       \* live store view should drop it from the deleted set in this abstraction.
       deletedSsts' = deletedSsts \ {JobOutput[j]}
    /\ outputTs' = [outputTs EXCEPT ![JobOutput[j]] = workerTime[w]]
    /\ bufferedCtx' = [bufferedCtx EXCEPT ![w] = @ \cup {j}]
    /\ UNCHANGED <<manifestVars, compactionsVars, coordVars, coordTime,
                   workerTime, localExecuting,
                   publishCount, retryCount>>

\* --------------------------------------------------------------------------
\* HeartbeatLoseOwnership: a heartbeat sees the job missing or owned by another
\* worker and stops local execution.
\* Reference: compaction_worker.rs:532-550
\* --------------------------------------------------------------------------
HeartbeatLoseOwnership(w, j) ==
    /\ j \in localExecuting[w]
    /\ durJob[j].worker # w
    /\ localExecuting' = [localExecuting EXCEPT ![w] = @ \ {j}]
    /\ bufferedCtx' = [bufferedCtx EXCEPT ![w] = @ \ {j}]
    /\ UNCHANGED <<manifestVars, compactionsVars, coordVars, coordTime,
                   workerTime, presentSsts, deletedSsts, outputTs,
                   publishCount, retryCount>>

\* --------------------------------------------------------------------------
\* HeartbeatOwnedJobs: refresh worker lastHeartbeat and optionally publish
\* buffered progress context for reclaim / resume.
\* Reference: compaction_worker.rs:512-584
\* --------------------------------------------------------------------------
HeartbeatOwnedJobs(w, j) ==
    /\ j \in localExecuting[w]
    /\ durJob[j].worker = w
    /\ \* Heartbeat publishes worker ownership plus any buffered resume context;
       \* it is the sole writer of progress in .compactions
       \* (compaction_worker.rs:512-584).
       LET updated ==
            [durJob[j] EXCEPT !.lastHb = workerTime[w],
                               !.ctx = IF j \in bufferedCtx[w] THEN TRUE ELSE @]
       IN durJob' = [durJob EXCEPT ![j] = updated]
    /\ compactionsVersion' = compactionsVersion + 1
    /\ UNCHANGED <<manifestVars, compactionsExists, compactionsEpoch,
                   coordVars, coordTime, workerTime, localExecuting, bufferedCtx,
                   presentSsts, deletedSsts, outputTs, publishCount, retryCount>>

\* --------------------------------------------------------------------------
\* HandleFinishedSuccess: successful local execution writes Compacted (with
\* output recorded) if the worker still owns the entry.
\* Reference: compaction_worker.rs:587-699
\* --------------------------------------------------------------------------
HandleFinishedSuccess(w, j) ==
    /\ j \in localExecuting[w]
    /\ durJob[j].worker = w
    /\ JobKind[j] = TieredKind
    /\ JobOutput[j] \in presentSsts
    /\ \* write_compacted preserves worker ownership through Compacted and clears
       \* the buffered ctx on success (compaction_worker.rs:587-627, 685-698).
       LET compacted ==
            [durJob[j] EXCEPT !.status = Compacted,
                               !.output = TRUE,
                               !.lastHb = workerTime[w],
                               !.ctx = FALSE]
       IN durJob' = [durJob EXCEPT ![j] = compacted]
    /\ compactionsVersion' = compactionsVersion + 1
    /\ localExecuting' = [localExecuting EXCEPT ![w] = @ \ {j}]
    /\ bufferedCtx' = [bufferedCtx EXCEPT ![w] = @ \ {j}]
    /\ UNCHANGED <<manifestVars, compactionsExists, compactionsEpoch,
                   coordVars, coordTime, workerTime,
                   presentSsts, deletedSsts, outputTs, publishCount, retryCount>>

\* --------------------------------------------------------------------------
\* HandleFinishedLostOwnership: executor finishes after the claim was already
\* reclaimed; the orphan output is dropped from coordination state.
\* Reference: compaction_worker.rs:600-615, 631-645
\* --------------------------------------------------------------------------
HandleFinishedLostOwnership(w, j) ==
    /\ j \in localExecuting[w]
    /\ durJob[j].worker # w
    /\ localExecuting' = [localExecuting EXCEPT ![w] = @ \ {j}]
    /\ bufferedCtx' = [bufferedCtx EXCEPT ![w] = @ \ {j}]
    /\ UNCHANGED <<manifestVars, compactionsVars, coordVars, coordTime,
                   workerTime, presentSsts, deletedSsts, outputTs,
                   publishCount, retryCount>>

\* --------------------------------------------------------------------------
\* HandleFinishedExecError: execution error releases the durable claim back to
\* Scheduled so another worker can retry.
\* Reference: compaction_worker.rs:647-699
\* --------------------------------------------------------------------------
HandleFinishedExecError(w, j) ==
    /\ j \in localExecuting[w]
    /\ durJob[j].worker = w
    /\ LET released == [durJob[j] EXCEPT !.status = Scheduled,
                                          !.worker = Nil,
                                          !.lastHb = 0,
                                          !.retry = ExecErrorRetry]
       IN durJob' = [durJob EXCEPT ![j] = released]
    /\ compactionsVersion' = compactionsVersion + 1
    /\ localExecuting' = [localExecuting EXCEPT ![w] = @ \ {j}]
    /\ bufferedCtx' = [bufferedCtx EXCEPT ![w] = @ \ {j}]
    /\ retryCount' = [retryCount EXCEPT ![j] = @ + 1]
    /\ UNCHANGED <<manifestVars, compactionsExists, compactionsEpoch,
                   coordVars, coordTime, workerTime,
                   presentSsts, deletedSsts, outputTs, publishCount>>

\* --------------------------------------------------------------------------
\* ReclaimStaleWorkers: coordinator-local timeout scan reclaims stale Running
\* jobs back to Scheduled.
\* Reference: compactor.rs:725-782
\* --------------------------------------------------------------------------
ReclaimStaleWorkers(j) ==
    /\ CoordinatorCanWriteCompactions
    /\ coordJob[j].status = Running
    /\ \* The coordinator compares its local clock to the worker-written
       \* lastHeartbeat and reclaims stale or workerless Running jobs
       \* (compactor.rs:735-780).
       \/ coordJob[j].worker = Nil
       \/ coordTime - coordJob[j].lastHb > HeartbeatTimeout
    /\ LET reclaimed ==
            [coordJob[j] EXCEPT !.status = Scheduled,
                                 !.worker = Nil,
                                 !.lastHb = 0,
                                 !.retry = TimeoutRetry]
       IN /\ coordJob' = [coordJob EXCEPT ![j] = reclaimed]
          /\ durJob' = [durJob EXCEPT ![j] = reclaimed]
    /\ compactionsVersion' = compactionsVersion + 1
    /\ coordSeenCompactionsVersion' = compactionsVersion + 1
    /\ retryCount' = [retryCount EXCEPT ![j] = @ + 1]
    /\ UNCHANGED <<manifestVars, compactionsExists, compactionsEpoch,
                   coordUp, coordManifestRefs, coordCheckpointActive,
                   coordCheckpointRefs, coordCheckpointExpire,
                   coordSeenManifestVersion, runtimeVars, publishCount>>

\* --------------------------------------------------------------------------
\* CommitCompactedEntriesFail: coordinator sees a durable Compacted entry whose
\* sources no longer validate against the current manifest and marks it Failed.
\* Reference: compactor.rs:836-907, 910-1044
\* --------------------------------------------------------------------------
CommitCompactedEntriesFail(j) ==
    /\ CoordinatorCanWriteManifest
    /\ coordJob[j].status = Compacted
    /\ \* Post-restart recovery treats "manifest already changed" as Failed, not
       \* as "publish definitely absent" (compactor.rs:843-858, 891-900).
       ~ValidateCompaction(coordJob, coordManifestRefs, j)
    /\ LET failed == [coordJob[j] EXCEPT !.status = Failed,
                                         !.ctx = FALSE]
       IN /\ coordJob' = [coordJob EXCEPT ![j] = failed]
          /\ durJob' = [durJob EXCEPT ![j] = failed]
    /\ compactionsVersion' = compactionsVersion + 1
    /\ coordSeenCompactionsVersion' = compactionsVersion + 1
    /\ UNCHANGED <<manifestVars, compactionsExists, compactionsEpoch,
                   coordUp, coordManifestRefs, coordCheckpointActive,
                   coordCheckpointRefs, coordCheckpointExpire,
                   coordSeenManifestVersion, runtimeVars, publishCount, retryCount>>

\* --------------------------------------------------------------------------
\* CommitCompactedEntriesWriteManifest: coordinator commits one valid Compacted
\* result to the durable manifest, leaving .compactions terminalization for a
\* later step.
\* Reference: compactor.rs:836-907,
\*            compactor_state.rs:1043-1133,
\*            compactor_state_protocols.rs:241-330
\* --------------------------------------------------------------------------
CommitCompactedEntriesWriteManifest(j) ==
    /\ CoordinatorCanWriteManifest
    /\ coordJob[j].status = Compacted
    /\ JobKind[j] = TieredKind
    /\ ValidateCompaction(coordJob, coordManifestRefs, j)
    /\ \* finish_compaction removes sources, inserts the output SR, and marks the
       \* local compaction Completed before write_state_safely performs the
       \* durable manifest-first write (compactor.rs:872-889,
       \* compactor_state.rs:1049-1129, compactor_state_protocols.rs:247-330).
       LET committedManifest == (coordManifestRefs \ JobSources[j]) \cup {JobOutput[j]}
           completed == [coordJob[j] EXCEPT !.status = Completed]
       IN /\ coordManifestRefs' = committedManifest
          /\ coordCheckpointActive' = [coordCheckpointActive EXCEPT ![j] = TRUE]
          /\ coordCheckpointRefs' = [coordCheckpointRefs EXCEPT ![j] = JobSources[j] \cap coordManifestRefs]
          /\ coordCheckpointExpire' = [coordCheckpointExpire EXCEPT ![j] = coordTime + CheckpointTTL]
          /\ coordJob' = [coordJob EXCEPT ![j] = completed]
          /\ manifestRefs' = (manifestRefs \ JobSources[j]) \cup {JobOutput[j]}
          /\ checkpointActive' = [checkpointActive EXCEPT ![j] = TRUE]
          /\ checkpointRefs' = [checkpointRefs EXCEPT ![j] = JobSources[j] \cap manifestRefs]
          /\ checkpointExpire' = [checkpointExpire EXCEPT ![j] = coordTime + CheckpointTTL]
    /\ manifestVersion' = manifestVersion + 1
    /\ coordSeenManifestVersion' = manifestVersion + 1
    /\ publishCount' = [publishCount EXCEPT ![j] = @ + 1]
    /\ UNCHANGED <<manifestEpoch, compactionsExists, durJob, compactionsVersion,
                   compactionsEpoch, coordUp, coordSeenCompactionsVersion, coordTime,
                   workerTime, localExecuting, bufferedCtx, presentSsts, deletedSsts,
                   outputTs, retryCount>>

\* --------------------------------------------------------------------------
\* CommitCompactedEntriesWriteCompactions: second half of manifest-first split
\* persistence; durable .compactions catches up from Compacted -> Completed.
\* Reference: compactor_state_protocols.rs:321-329
\* --------------------------------------------------------------------------
CommitCompactedEntriesWriteCompactions(j) ==
    /\ CoordinatorCanWriteCompactions
    /\ coordJob[j].status = Completed
    /\ durJob[j].status = Compacted
    /\ PublishedInManifest(j)
    /\ \* write_state_safely writes .compactions only after the manifest update
       \* has succeeded (compactor_state_protocols.rs:321-329).
       durJob' = [durJob EXCEPT ![j].status = Completed]
    /\ compactionsVersion' = compactionsVersion + 1
    /\ coordSeenCompactionsVersion' = compactionsVersion + 1
    /\ UNCHANGED <<manifestVars, compactionsExists, compactionsEpoch,
                   coordUp, coordManifestRefs, coordCheckpointActive,
                   coordCheckpointRefs, coordCheckpointExpire, coordJob,
                   coordSeenManifestVersion, runtimeVars, bookkeepingVars>>

\* --------------------------------------------------------------------------
\* RefreshCheckpoint: extend a checkpoint's expiry from a local wall clock.
\* Reference: manifest/store.rs:385-413
\* --------------------------------------------------------------------------
RefreshCheckpoint(j) ==
    /\ checkpointActive[j]
    /\ \* refresh_checkpoint rewrites expire_time using the caller's local clock
       \* (manifest/store.rs:385-405).
       checkpointExpire' = [checkpointExpire EXCEPT ![j] = coordTime + CheckpointTTL]
    /\ manifestVersion' = manifestVersion + 1
    /\ UNCHANGED <<manifestRefs, checkpointActive, checkpointRefs, manifestEpoch,
                   compactionsVars, coordVars, coordTime, workerTime, localExecuting,
                   bufferedCtx, presentSsts, deletedSsts, outputTs,
                   publishCount, retryCount>>

\* --------------------------------------------------------------------------
\* ExpireCheckpoint: abstract the point where an expired checkpoint no longer
\* protects its referenced SSTs from GC.
\* Reference: manifest/store.rs:117-123, 385-405
\* --------------------------------------------------------------------------
ExpireCheckpoint(j) ==
    /\ checkpointActive[j]
    /\ coordTime >= checkpointExpire[j]
    /\ checkpointActive' = [checkpointActive EXCEPT ![j] = FALSE]
    /\ checkpointRefs' = [checkpointRefs EXCEPT ![j] = {}]
    /\ checkpointExpire' = [checkpointExpire EXCEPT ![j] = 0]
    /\ UNCHANGED <<manifestRefs, manifestVersion, manifestEpoch,
                   compactionsVars, coordVars, coordTime, workerTime,
                   localExecuting, bufferedCtx, presentSsts, deletedSsts, outputTs,
                   publishCount, retryCount>>

\* --------------------------------------------------------------------------
\* AdvanceCoordinatorClock: abstract coordinator wall-clock progress.
\* Reference: compactor.rs:735-747, compacted_gc.rs:223-232
\* --------------------------------------------------------------------------
AdvanceCoordinatorClock ==
    /\ coordTime' = coordTime + 1
    /\ UNCHANGED <<manifestVars, compactionsVars, coordVars, workerTime,
                   localExecuting, bufferedCtx, presentSsts, deletedSsts,
                   outputTs, publishCount, retryCount>>

\* --------------------------------------------------------------------------
\* AdvanceWorkerClock: abstract worker wall-clock progress used for heartbeats.
\* Reference: compaction_worker.rs:363-365, 527-529, 616-620
\* --------------------------------------------------------------------------
AdvanceWorkerClock(w) ==
    /\ workerTime' = [workerTime EXCEPT ![w] = @ + 1]
    /\ UNCHANGED <<manifestVars, compactionsVars, coordVars, coordTime,
                   localExecuting, bufferedCtx, presentSsts, deletedSsts,
                   outputTs, publishCount, retryCount>>

\* --------------------------------------------------------------------------
\* GcSweep: delete one compacted SST that is older than the GC cutoff and not
\* referenced by any active manifest/checkpoint.
\* Reference: compacted_gc.rs:103-112, 197-261
\* --------------------------------------------------------------------------
GcSweep(s) ==
    LET expired ==
            {j \in Jobs :
                /\ checkpointActive[j]
                /\ checkpointExpire[j] > 0
                /\ coordTime >= checkpointExpire[j]}
        liveCheckpointRefs ==
            UNION {
                IF checkpointActive[j] /\ ~(j \in expired)
                THEN checkpointRefs[j]
                ELSE {}
                : j \in Jobs
            }
    IN /\ s \in GcManagedSsts
       /\ s \in presentSsts
       /\ \* A GC tick first removes expired checkpoints, then computes active
          \* manifest references and deletes one eligible SST
          \* (garbage_collector.rs:383-436, compacted_gc.rs:201-252).
          s \notin manifestRefs
       /\ s \notin liveCheckpointRefs
       /\ SstTimestamp(s) < GcCutoff
       /\ checkpointActive' =
            [j \in Jobs |-> IF j \in expired THEN FALSE ELSE checkpointActive[j]]
       /\ checkpointRefs' =
            [j \in Jobs |-> IF j \in expired THEN {} ELSE checkpointRefs[j]]
       /\ checkpointExpire' =
            [j \in Jobs |-> IF j \in expired THEN 0 ELSE checkpointExpire[j]]
       /\ presentSsts' = presentSsts \ {s}
       /\ deletedSsts' = deletedSsts \cup {s}
       /\ UNCHANGED <<manifestRefs, manifestVersion, manifestEpoch,
                      compactionsVars, coordVars, coordTime, workerTime,
                      localExecuting, bufferedCtx, outputTs,
                      publishCount, retryCount>>

\* ============================================================================
\* NEXT STATE RELATION
\* ============================================================================

Next ==
    \/ StartCoordinator
    \/ CrashCoordinator
    \/ CoordinatorRefreshCompactions
    \/ CoordinatorRefreshManifest
    \/ \E j \in Jobs : MaybeScheduleCompactions(j)
    \/ \E j \in Jobs : ExternalSubmit(j)
    \/ \E j \in Jobs : MaybeValidateSubmittedFail(j)
    \/ \E j \in Jobs : MaybeValidateSubmittedSchedule(j)
    \/ \E j \in Jobs : MaybeValidateSubmittedDrain(j)
    \/ \E w \in Workers : \E j \in Jobs : PollAndClaimStopDuplicate(w, j)
    \/ \E w \in Workers : \E j \in Jobs : PollAndClaim(w, j)
    \/ \E w \in Workers : \E j \in Jobs : DispatchClaimedJob(w, j)
    \/ \E w \in Workers : \E j \in Jobs : ReleaseClaimPostClaimInvalid(w, j)
    \/ \E w \in Workers : \E j \in Jobs : WriteOutputSst(w, j)
    \/ \E w \in Workers : \E j \in Jobs : HeartbeatLoseOwnership(w, j)
    \/ \E w \in Workers : \E j \in Jobs : HeartbeatOwnedJobs(w, j)
    \/ \E w \in Workers : \E j \in Jobs : HandleFinishedSuccess(w, j)
    \/ \E w \in Workers : \E j \in Jobs : HandleFinishedLostOwnership(w, j)
    \/ \E w \in Workers : \E j \in Jobs : HandleFinishedExecError(w, j)
    \/ \E j \in Jobs : ReclaimStaleWorkers(j)
    \/ \E j \in Jobs : CommitCompactedEntriesFail(j)
    \/ \E j \in Jobs : CommitCompactedEntriesWriteManifest(j)
    \/ \E j \in Jobs : CommitCompactedEntriesWriteCompactions(j)
    \/ \E j \in Jobs : RefreshCheckpoint(j)
    \/ \E j \in Jobs : ExpireCheckpoint(j)
    \/ AdvanceCoordinatorClock
    \/ \E w \in Workers : AdvanceWorkerClock(w)
    \/ \E s \in GcManagedSsts : GcSweep(s)

BaseSpec == Init /\ [][Next]_vars

\* ============================================================================
\* INVARIANTS
\* ============================================================================

TypeOK ==
    /\ manifestRefs \subseteq SstUniverse
    /\ checkpointActive \in [Jobs -> BOOLEAN]
    /\ checkpointRefs \in [Jobs -> SUBSET SstUniverse]
    /\ checkpointExpire \in [Jobs -> Int]
    /\ manifestVersion \in Int
    /\ manifestEpoch \in Int
    /\ compactionsExists \in BOOLEAN
    /\ durJob \in [Jobs -> JobType]
    /\ compactionsVersion \in Int
    /\ compactionsEpoch \in Int
    /\ coordUp \in BOOLEAN
    /\ coordManifestRefs \subseteq SstUniverse
    /\ coordCheckpointActive \in [Jobs -> BOOLEAN]
    /\ coordCheckpointRefs \in [Jobs -> SUBSET SstUniverse]
    /\ coordCheckpointExpire \in [Jobs -> Int]
    /\ coordJob \in [Jobs -> JobType]
    /\ coordSeenManifestVersion \in Int
    /\ coordSeenCompactionsVersion \in Int
    /\ coordTime \in Int
    /\ workerTime \in [Workers -> Int]
    /\ localExecuting \in [Workers -> SUBSET Jobs]
    /\ bufferedCtx \in [Workers -> SUBSET Jobs]
    /\ presentSsts \subseteq SstUniverse
    /\ deletedSsts \subseteq SstUniverse
    /\ deletedSsts \cap presentSsts = {}
    /\ outputTs \in [OutputSsts -> Int]
    /\ publishCount \in [Jobs -> Nat]
    /\ retryCount \in [Jobs -> Nat]
    /\ JobSources \in [Jobs -> SUBSET SstUniverse]
    /\ JobOutput \in [Jobs -> OutputSsts]
    /\ JobSegment \in [Jobs -> Segments]
    /\ JobKind \in [Jobs -> Kinds]
    /\ JobHasL0 \in [Jobs -> BOOLEAN]
    /\ JobHasSR \in [Jobs -> BOOLEAN]
    /\ SchedulerAllows \in [Jobs -> BOOLEAN]
    /\ DrainCoversWatermark \in [Jobs -> BOOLEAN]
    /\ InputSstTs \in [InputSsts -> Int]
    /\ InitialManifestRefs \subseteq SstUniverse

RunningHasWorker ==
    \A j \in Jobs :
        durJob[j].status = Running => durJob[j].worker \in Workers

EpochAlignment ==
    compactionsExists => compactionsEpoch = manifestEpoch

ViewVersionsMonotone ==
    /\ coordSeenManifestVersion <= manifestVersion
    /\ coordSeenCompactionsVersion <= compactionsVersion

NoConflictingActiveCompactions ==
    \A j, k \in Jobs :
        /\ j /= k
        /\ durJob[j].status \in LiveConflictStatuses
        /\ durJob[k].status \in LiveConflictStatuses
        => /\ JobSources[j] \cap JobSources[k] = {}
           /\ ~(JobKind[j] = TieredKind /\ JobKind[k] = TieredKind /\ JobOutput[j] = JobOutput[k])
           /\ ~(JobKind[j] = DrainKind /\ JobKind[k] = DrainKind /\ JobSegment[j] = JobSegment[k])

ActiveCompactionsDisjoint ==
    NoConflictingActiveCompactions

MaxConcurrentRespected ==
    SlotCount(durJob) <= MaxConcurrent

BoundedRunningClaims ==
    RunningCount(durJob) <= MaxConcurrent

SinglePublishPerCompaction ==
    /\ \A j \in Jobs : publishCount[j] <= 1
    /\ \A j, k \in Jobs :
        /\ j /= k
        /\ SameLogicalCompaction(j, k)
        => ~(publishCount[j] > 0 /\ publishCount[k] > 0)

SingleDurablePublishPerJob ==
    SinglePublishPerCompaction

ManifestReferencesExistingFiles ==
    /\ manifestRefs \subseteq presentSsts
    /\ AllCheckpointRefs \subseteq presentSsts

NoPrematureReclaim ==
    deletedSsts \cap (manifestRefs \cup AllCheckpointRefs \cup InFlightOutputRefs) = {}

NoGcOfNeededSst ==
    NoPrematureReclaim

OnlyCurrentOwnerPublishes ==
    \A j \in Jobs :
        durJob[j].status = Compacted
            => /\ durJob[j].worker \in Workers
               /\ durJob[j].output
               /\ \* The worker that durably reported Compacted must have
                  \* cleared its own local execution. Another worker may still
                  \* be asynchronously stopping after reclaim.
                  j \notin localExecuting[durJob[j].worker]

RecoverySafeTerminalRelation ==
    /\ \* `publishCount` tracks the durable record that actually performed the
       \* manifest-first publish. Equivalent duplicate jobs can satisfy
       \* `PublishedInManifest` later via the same source/output shape even if
       \* they remain Absent, Submitted, or Failed after recovery.
       \A j \in Jobs :
        publishCount[j] > 0 => durJob[j].status \in {Compacted, Completed, Failed}
    /\ \A j \in Jobs :
        durJob[j].status = Completed => publishCount[j] > 0
    /\ \A j \in Jobs :
        /\ publishCount[j] > 0
        /\ durJob[j].status = Failed
        => PublishedInManifest(j)

RecoverySafeTerminalState ==
    RecoverySafeTerminalRelation

FencedWriterCannotOverwriteFreshState ==
    /\ EpochAlignment
    /\ ViewVersionsMonotone

CheckpointRefsKnown ==
    AllCheckpointRefs \subseteq SstUniverse

PublishedOutputsTracked ==
    \A j \in Jobs :
        durJob[j].output => JobOutput[j] \in presentSsts \/ JobOutput[j] \in deletedSsts

\* ============================================================================
\* TEMPORAL PROPERTIES
\* ============================================================================

TimedOutOrFailedJobsDoNotLivelock ==
    \A j \in Jobs :
        []((retryCount[j] > 0 /\ durJob[j].status \in {Submitted, Scheduled, Running})
            => <>(durJob[j].status \in {Completed, Failed}))

=============================================================================
