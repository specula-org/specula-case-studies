--------------------------------- MODULE MC ---------------------------------
(*****************************************************************************)
(* Model-checking spec for cass-operator.  Wraps base.tla with counter-      *)
(* bounded fault-injection / initiator actions and leaves the reactive       *)
(* reconcile steps unbounded.                                                *)
(*                                                                           *)
(* Bounded (introduce non-determinism):                                      *)
(*   S1 CreateSameNameDatacenterEpochB  (adversary same-name recreation)     *)
(*   S2 GetCassMetadataEndpointsError    (empty ring metadata)               *)
(*   S2 GetCassMetadataEndpointsPartial  (partial ring metadata)             *)
(*   S2 GetUsedStorageForPodsMissing     (missing per-pod load)              *)
(*   S4 ChangeDatacenterSize             (scale-up request)                  *)
(*   S4 AdmitVoluntaryEviction           (voluntary disruption)             *)
(*   S5 DeleteDependencySecret           (secret deleted first)             *)
(*      ControllerCrash                  (primary crash adversary)          *)
(*                                                                           *)
(* Unbounded (react to existing state): every other base action, including   *)
(* the re-entry paths (re-submit, recover, ring transitions, cleanup steps)  *)
(* that make the target bugs reachable.                                      *)
(*****************************************************************************)

EXTENDS base

\* Access to original (un-overridden) base operators, if ever needed.
cass == INSTANCE base

\* ===========================================================================
\* FAULT-COUNTER LIMITS
\* ===========================================================================
CONSTANT MaxRecreateLimit      \* S1 same-name recreation
CONSTANT MaxMetaErrorLimit     \* S2 empty metadata observations
CONSTANT MaxMetaPartialLimit   \* S2 partial metadata observations
CONSTANT MaxLoadMissingLimit   \* S2 missing-load observations
CONSTANT MaxResizeLimit        \* S4 scale-up requests
CONSTANT MaxEvictLimit         \* S4 voluntary evictions
CONSTANT MaxSecretDelLimit     \* S5 dependency-secret deletions
CONSTANT MaxCrashLimit         \* controller crashes

\* ===========================================================================
\* FAULT COUNTERS
\* ===========================================================================
VARIABLE faultCounters
faultVars == <<faultCounters>>

mcVars == <<vars, faultCounters>>

\* ===========================================================================
\* COUNTER-BOUNDED FAULT / INITIATOR ACTIONS
\* ===========================================================================

MCCreateSameNameDatacenterEpochB ==
    /\ faultCounters.recreate < MaxRecreateLimit
    /\ S1_CreateSameNameDatacenterEpochB
    /\ faultCounters' = [faultCounters EXCEPT !.recreate = @ + 1]

MCGetCassMetadataEndpointsError ==
    /\ faultCounters.metaError < MaxMetaErrorLimit
    /\ S2_GetCassMetadataEndpointsError
    /\ faultCounters' = [faultCounters EXCEPT !.metaError = @ + 1]

MCGetCassMetadataEndpointsPartial ==
    /\ faultCounters.metaPartial < MaxMetaPartialLimit
    /\ S2_GetCassMetadataEndpointsPartial
    /\ faultCounters' = [faultCounters EXCEPT !.metaPartial = @ + 1]

MCGetUsedStorageForPodsMissing ==
    /\ faultCounters.loadMissing < MaxLoadMissingLimit
    /\ S2_GetUsedStorageForPodsMissing
    /\ faultCounters' = [faultCounters EXCEPT !.loadMissing = @ + 1]

MCChangeDatacenterSize ==
    /\ faultCounters.resize < MaxResizeLimit
    /\ S4_ChangeDatacenterSize
    /\ faultCounters' = [faultCounters EXCEPT !.resize = @ + 1]

MCAdmitVoluntaryEviction ==
    /\ faultCounters.evict < MaxEvictLimit
    /\ S4_AdmitVoluntaryEviction
    /\ faultCounters' = [faultCounters EXCEPT !.evict = @ + 1]

MCDeleteDependencySecret ==
    /\ faultCounters.secretDel < MaxSecretDelLimit
    /\ S5_DeleteDependencySecret
    /\ faultCounters' = [faultCounters EXCEPT !.secretDel = @ + 1]

MCControllerCrash ==
    /\ faultCounters.crash < MaxCrashLimit
    /\ ControllerCrash
    /\ faultCounters' = [faultCounters EXCEPT !.crash = @ + 1]

MCBoundedFaults ==
    \/ MCCreateSameNameDatacenterEpochB
    \/ MCGetCassMetadataEndpointsError
    \/ MCGetCassMetadataEndpointsPartial
    \/ MCGetUsedStorageForPodsMissing
    \/ MCChangeDatacenterSize
    \/ MCAdmitVoluntaryEviction
    \/ MCDeleteDependencySecret
    \/ MCControllerCrash

\* ===========================================================================
\* UNBOUNDED (REACTIVE) ACTIONS
\* ===========================================================================
\* Everything the base spec offers except the eight bounded faults above.

MCReactive ==
    \* --- Scenario 1 ---
    \/ S1_BeginDatacenterDeletionEpochA
    \/ S1_DeleteDatacenterObjectEpochA
    \/ S1_RefreshDatacenterCache
    \/ S1_GetStatefulSetForRack
    \/ S1_ProcessDeletionScaleStatefulSet
    \/ S1_StatefulSetControllerDeleteEpochPod
    \/ S1_ProcessDeletionListPVCs
    \/ S1_ProcessDeletionCheckPVCInUse
    \/ S1_ProcessDeletionDeletePVC
    \* --- Scenario 2 ---
    \/ S2_GetCassMetadataEndpointsSuccess
    \/ S2_GetUsedStorageForPodsKnown
    \/ S2_EnsurePodsCanAbsorbDecommData
    \/ S2_CallDecommission
    \/ S2_CassandraRingMarkLeaving
    \/ S2_CassandraRingMarkLeft
    \/ S2_CassandraRingRemove
    \/ S2_IsDoneDecommissioning
    \/ S2_RemoveDecommissionedPodFromSts
    \/ S2_StatefulSetControllerRemoveDecommissionedPod
    \/ S2_DeletePodPvcs
    \/ S2_PatchNodeStatusAfterDecommission
    \* --- Scenario 3 ---
    \/ S3_StartCassandra
    \/ S3_LabelServerPodStarting
    \/ S3_PatchLastServerNodeStarted
    \/ S3_CallLifecycleStartEndpointAccepted
    \/ S3_CallLifecycleStartEndpointError
    \/ S3_DeletePodAfterStartFailure
    \/ S3_CassandraPodBecomesReady
    \/ S3_LabelServerPodStarted
    \/ S3_StartPodTaskAsync
    \/ S3_ProcessRackPatchJobID
    \/ S3_ProcessRackPatchJobIDFailure
    \/ S3_CheckRackCompletion
    \/ S3_ScheduledTaskStatusUpdate
    \/ S3_ScheduledTaskCreateChild
    \/ S3_ScheduledTaskCreateChildFailure
    \/ S3_CassandraTaskActivateLabel
    \/ S3_CassandraTaskActivateStatus
    \/ S3_CassandraTaskCompleteLabel
    \/ S3_CassandraTaskCompleteStatus
    \* --- Scenario 4 ---
    \/ S4_CheckRackScale
    \/ S4_PodBecomesReady
    \/ S4_CheckDcPodDisruptionBudgetDelete
    \/ S4_CheckDcPodDisruptionBudgetCreate
    \* --- Scenario 5 ---
    \/ S5_SetDecommissionOnDelete
    \/ S5_BeginDatacenterDeletion
    \/ S5_CreateReconciliationContext
    \/ S5_IsValid
    \/ S5_ProcessDeletionOrdinaryCleanup
    \/ S5_ProcessDeletionDecommission
    \/ S5_ProcessDeletionRemoveFinalizers
    \* --- Cross-cutting recovery (reactive) ---
    \/ ControllerRecover

MCReactiveNext == MCReactive /\ UNCHANGED faultVars

\* ===========================================================================
\* INIT / NEXT / SPEC
\* ===========================================================================

MCInit ==
    /\ Init
    /\ faultCounters = [ recreate    |-> 0,
                         metaError   |-> 0,
                         metaPartial |-> 0,
                         loadMissing |-> 0,
                         resize      |-> 0,
                         evict       |-> 0,
                         secretDel   |-> 0,
                         crash       |-> 0 ]

MCNext ==
    \/ MCBoundedFaults
    \/ MCReactiveNext

MCSpec == MCInit /\ [][MCNext]_mcVars

\* Exclude the fault counters from the fingerprint (they don't change protocol
\* behaviour, only bound firing rates).
MCView == <<vars>>

\* ===========================================================================
\* STRUCTURAL INVARIANTS (sanity — hold in all correct states)
\* ===========================================================================

MCTypeOK ==
    /\ faultCounters.recreate    \in 0..MaxRecreateLimit
    /\ faultCounters.metaError   \in 0..MaxMetaErrorLimit
    /\ faultCounters.metaPartial \in 0..MaxMetaPartialLimit
    /\ faultCounters.loadMissing \in 0..MaxLoadMissingLimit
    /\ faultCounters.resize      \in 0..MaxResizeLimit
    /\ faultCounters.evict       \in 0..MaxEvictLimit
    /\ faultCounters.secretDel   \in 0..MaxSecretDelLimit
    /\ faultCounters.crash       \in 0..MaxCrashLimit

\* At most one controller is "up" model-wide is not meaningful here (single
\* worker); instead assert crash/recover keep the up-flags in lock-step.
ControllerUpConsistent ==
    (s1.controller_up = s2.controller_up)
        /\ (s2.controller_up = s3.controller_up)
        /\ (s3.controller_up = s4.controller_up)
        /\ (s4.controller_up = s5.controller_up)

\* Durable job id and pending job id are never both set to the same value
\* (a job id is either pending OR checkpointed, never duplicated).
JobIdDisjoint ==
    (s3.job_id /= NoJob /\ s3.pending_job_id /= NoJob)
        => (s3.job_id /= s3.pending_job_id)

\* ===========================================================================
\* SAFETY ENCODINGS OF THE BRIEF'S LIVENESS PROPERTIES
\* ===========================================================================

\* Scenario 3 (brief NoStuckStarting, liveness) — safety proxy: a Startup pod is
\* never wedged with the durable "Starting" label while its remote /start was
\* lost to a crash (findStartingNodes would requeue forever, brief #806).  This
\* state has no enabled action that can advance it, so reaching it IS the bug.
NoStuckStarting ==
    ~(s3.startup_label = "Starting" /\ s3.remote_state = "Lost")

\* Scenario 5 (brief FinalizerLiveness, liveness) — safety proxy: the DC is
\* never left Terminating with the operator finalizer present while the
\* dependency secret is gone (IsValid can never pass -> TerminalError ->
\* ProcessDeletion never runs -> permanent deadlock, brief #952/#812).
NoFinalizerDeadlock ==
    ~( s5.deleting
       /\ ~s5.dependency_present
       /\ SeqContains(s5.finalizers, "cassandra.datastax.com/finalizer") )

\* ===========================================================================
\* TEMPORAL PROPERTIES (documented; require fairness — see hunt cfgs)
\* ===========================================================================

\* Once a Startup begins, it eventually resolves (Started, or retried).
NoStuckStartingProp ==
    [] ( (s3.operation_kind = "Startup" /\ s3.startup_label = "Starting")
            => <> (s3.startup_label \in {"Started", "Deleted"}) )

\* Once deletion begins, the operator finalizer is eventually removed.
FinalizerLivenessProp ==
    [] ( s5.deleting
            => <> (~SeqContains(s5.finalizers, "cassandra.datastax.com/finalizer")) )

=============================================================================
