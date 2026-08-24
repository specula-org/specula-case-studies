-------------------------------- MODULE base --------------------------------
(*****************************************************************************)
(* TLA+ specification for k8ssandra/cass-operator (commit 704bf4c).          *)
(*                                                                           *)
(* Category A (distributed / control-plane).  A single reconcile worker      *)
(* drives a replicated Cassandra cluster through the Kubernetes API and a    *)
(* per-node management (mgmt) API.  Durable state lives ONLY in Kubernetes   *)
(* objects (CRD .status, pod labels, STS .spec.replicas, PVCs, PDB); the     *)
(* operator can crash / requeue between any two writes.                      *)
(*                                                                           *)
(* The spec models five HIGH-priority Scenarios from the Modeling Brief.     *)
(* Each Scenario has its own state record, mirroring the trace-harness       *)
(* structs in internal/speculatrace/trace.go so that actions map 1:1 to      *)
(* recorded trace events:                                                    *)
(*                                                                           *)
(*   s1  ResourceState    Scenario 1  cross-epoch resource delete            *)
(*   s2  DecommissionState Scenario 2 premature decommission / data loss     *)
(*   s3  OperationState    Scenario 3 remote side-effect vs durable marker   *)
(*   s4  RolloutState      Scenario 4 availability / PDB window              *)
(*   s5  DeletionState     Scenario 5 finalizer / deletion ordering          *)
(*                                                                           *)
(* Every logic block cites the implementation source it models.  The logic   *)
(* is code-faithful (including the BUGGY branches), so the invariants can     *)
(* expose the mechanisms the brief asks about.                               *)
(*****************************************************************************)

EXTENDS Integers, Sequences, FiniteSets, TLC

\* ===========================================================================
\* CONSTANTS
\* ===========================================================================

\* Which Scenarios' actions are enabled.  MC.cfg enables all five (convergence);
\* each MC_hunt_*.cfg narrows this to the single Scenario under test so the
\* other Scenarios stay dormant in their initial state.
CONSTANT ActiveScenarios          \* subset of {1,2,3,4,5}

\* Scenario 3 operation kind under test (Startup | Maintenance | Schedule |
\* TaskLifecycle).  Fixes s3.operation_kind; only that sub-flow is reachable.
CONSTANT Scen3OpKind

\* Upper bound on controller crashes (keeps the base model finite; enforced by
\* StateConstraint, NOT by an action guard, so the crash adversary itself is
\* semantically unbounded — MC.tla bounds its firing rate explicitly).
CONSTANT MaxCrashCount

\* ---------------------------------------------------------------------------
\* Enumerated string values (used as literals throughout).
\* ---------------------------------------------------------------------------
EpochA   == "epoch-a"
EpochB   == "epoch-b"
NoEpoch  == "none"
NoJob    == "none"

Epochs   == {EpochA, EpochB, NoEpoch}

\* ===========================================================================
\* VARIABLES
\* ===========================================================================

VARIABLE s1     \* Scenario 1 record (ResourceState)
VARIABLE s2     \* Scenario 2 record (DecommissionState)
VARIABLE s3     \* Scenario 3 record (OperationState)
VARIABLE s4     \* Scenario 4 record (RolloutState)
VARIABLE s5     \* Scenario 5 record (DeletionState)

\* Model-only bookkeeping (NOT part of any trace-harness struct; excluded from
\* trace validation).
VARIABLE crashCount     \* number of ControllerCrash events so far
VARIABLE remoteSubmits  \* Scenario 3: how many times the logical remote op was
                        \* submitted to the mgmt API (for AtMostOnceRemoteOp)

scenarioVars == <<s1, s2, s3, s4, s5>>
modelVars    == <<crashCount, remoteSubmits>>
vars         == <<s1, s2, s3, s4, s5, crashCount, remoteSubmits>>

\* ===========================================================================
\* HELPERS
\* ===========================================================================

SeqContains(seq, x) == \E i \in DOMAIN seq : seq[i] = x

\* Remove every occurrence of x from a sequence (SelectSeq keeps order).
RemoveFromSeq(seq, x) == SelectSeq(seq, LAMBDA e : e /= x)

\* ===========================================================================
\* INITIAL STATE  (mirrors the Initial*State() constructors in trace.go)
\* ===========================================================================

\* trace.go:138-158  InitialResourceState
InitS1 == [
    controller_up          |-> TRUE,
    live_dc_epoch          |-> EpochA,
    cached_dc_epoch        |-> EpochA,
    deleting_dc_epoch      |-> NoEpoch,
    cached_sts_owner_epoch |-> NoEpoch,
    cached_pvc_epoch       |-> NoEpoch,
    cached_pvc_in_use      |-> TRUE,
    sts_owner_epoch        |-> EpochA,
    sts_replicas           |-> 2,
    pod_epoch              |-> EpochA,
    pod_exists             |-> TRUE,
    pvc_epoch              |-> EpochA,
    pvc_exists             |-> TRUE,
    pvc_in_use             |-> TRUE,
    last_mutation_actor    |-> NoEpoch,
    last_mutation_target   |-> NoEpoch,
    last_mutation_kind     |-> "None" ]

\* trace.go:160-177  InitialDecommissionState
InitS2 == [
    controller_up                  |-> TRUE,
    metadata_outcome               |-> "Unobserved",
    ring_state                     |-> "Normal",
    observed_ring_state            |-> "Unknown",
    cleanup_target                 |-> "None",
    cleanup_phase                  |-> "Idle",
    sts_replicas                   |-> 2,
    pod_exists                     |-> TRUE,
    pvc_exists                     |-> TRUE,
    node_status_exists             |-> TRUE,
    load_known                     |-> FALSE,
    capacity_approved              |-> FALSE,
    authoritative_removal_observed |-> FALSE,
    cleanup_started                |-> FALSE ]

\* trace.go:179-200  InitialOperationState(kind)
InitS3 == [
    controller_up           |-> TRUE,
    operation_kind          |-> Scen3OpKind,
    remote_state            |-> "Idle",
    request_accepted        |-> FALSE,
    durable_marker          |-> "None",
    job_id                  |-> NoJob,
    pending_job_id          |-> NoJob,
    remote_jobs             |-> << >>,
    startup_pod_exists      |-> TRUE,
    startup_label           |-> "ReadyToStart",
    startup_ready           |-> FALSE,
    startup_timestamped     |-> FALSE,
    startup_retry_requested |-> FALSE,
    occurrence_state        |-> "Due",
    schedule_create_pending |-> FALSE,
    child_exists            |-> FALSE,
    task_label              |-> "Pending",
    task_status             |-> "Pending" ]

\* trace.go:202-212  InitialRolloutState
InitS4 == [
    controller_up     |-> TRUE,
    desired_size      |-> 2,
    sts_replicas      |-> 2,
    ready_pods        |-> 2,
    pdb_present       |-> TRUE,
    pdb_min_available |-> 1,
    evicted_pods      |-> 0 ]

\* trace.go:214-226  InitialDeletionState
InitS5 == [
    controller_up         |-> TRUE,
    deleting              |-> FALSE,
    dependency_present    |-> TRUE,
    decommission_required |-> FALSE,
    mgmt_ready            |-> FALSE,
    context_ready         |-> FALSE,
    validation_passed     |-> FALSE,
    finalizers            |-> <<"cassandra.datastax.com/finalizer",
                                "example.com/foreign-finalizer">>,
    ordinary_cleanup_done |-> FALSE ]

Init ==
    /\ s1 = InitS1
    /\ s2 = InitS2
    /\ s3 = InitS3
    /\ s4 = InitS4
    /\ s5 = InitS5
    /\ crashCount = 0
    /\ remoteSubmits = 0

\* ===========================================================================
\* SCENARIO 1 : Cross-epoch resource deletion via name-based matching + cache
\* ===========================================================================
\* Destructive paths select resources by name-based labels, never by DC UID /
\* ownerReference, and read them through a (possibly stale) informer cache.  A
\* deletion for DC generation "epoch-a" can therefore act on identically-named
\* resources belonging to a freshly-recreated generation "epoch-b".
\* Source: reconcile_datacenter.go:27-200, reconcile_racks.go:1563-1745,
\*         context.go:56-127.

\* --- BeginDatacenterDeletionEpochA ------------------------------------------
\* context.go:88-96 : on a reconcile whose DC carries a deletionTimestamp, the
\* operator records the DC it is about to delete (its cached view = live epoch).
S1_BeginDatacenterDeletionEpochA ==
    /\ 1 \in ActiveScenarios
    /\ s1.controller_up
    /\ s1.deleting_dc_epoch = NoEpoch          \* deletion not yet begun
    /\ s1.live_dc_epoch /= NoEpoch             \* a live DC to delete
    /\ s1' = [s1 EXCEPT !.deleting_dc_epoch = s1.live_dc_epoch,
                        !.cached_dc_epoch    = s1.live_dc_epoch]
    /\ UNCHANGED <<s2, s3, s4, s5, modelVars>>

\* --- DeleteDatacenterObjectEpochA -------------------------------------------
\* scenario driver test:227-255 : the finalizer is removed and the epoch-a DC
\* object is garbage-collected (live generation disappears).
S1_DeleteDatacenterObjectEpochA ==
    /\ 1 \in ActiveScenarios
    /\ s1.deleting_dc_epoch = EpochA
    /\ s1.live_dc_epoch = EpochA
    /\ s1' = [s1 EXCEPT !.live_dc_epoch = NoEpoch]
    /\ UNCHANGED <<s2, s3, s4, s5, modelVars>>

\* --- CreateSameNameDatacenterEpochB (ADVERSARY) -----------------------------
\* test:257-314 : a new, identically-named DC (generation epoch-b) plus its STS,
\* pod and PVC are created while the operator still holds its epoch-a view.  The
\* cache has NOT yet observed the new owner / pvc epochs.
S1_CreateSameNameDatacenterEpochB ==
    /\ 1 \in ActiveScenarios
    /\ s1.controller_up
    /\ s1.live_dc_epoch = NoEpoch              \* old generation gone
    /\ s1' = [s1 EXCEPT !.live_dc_epoch          = EpochB,
                        !.sts_owner_epoch        = EpochB,
                        !.sts_replicas           = 2,
                        !.pod_epoch              = EpochB,
                        !.pod_exists             = TRUE,
                        !.pvc_epoch              = EpochB,
                        !.pvc_exists             = TRUE,
                        !.pvc_in_use             = TRUE,
                        !.cached_sts_owner_epoch = NoEpoch,
                        !.cached_pvc_epoch       = NoEpoch]
    /\ UNCHANGED <<s2, s3, s4, s5, modelVars>>

\* --- RefreshDatacenterCache -------------------------------------------------
\* context.go:88-96 (non-deleting branch) : a fresh reconcile re-reads the DC,
\* so the cached DC epoch catches up to the live epoch.  This is the path that a
\* correct guard COULD use to notice the generation changed.
S1_RefreshDatacenterCache ==
    /\ 1 \in ActiveScenarios
    /\ s1.controller_up
    /\ s1.cached_dc_epoch /= s1.live_dc_epoch
    /\ s1' = [s1 EXCEPT !.cached_dc_epoch = s1.live_dc_epoch]
    /\ UNCHANGED <<s2, s3, s4, s5, modelVars>>

\* --- GetStatefulSetForRack --------------------------------------------------
\* reconcile_racks.go:1563-1586 : reads the rack STS from cache; records the
\* observed owner epoch (name-based lookup, so it returns the epoch-b STS).
S1_GetStatefulSetForRack ==
    /\ 1 \in ActiveScenarios
    /\ s1.controller_up
    /\ s1' = [s1 EXCEPT !.cached_sts_owner_epoch = s1.sts_owner_epoch]
    /\ UNCHANGED <<s2, s3, s4, s5, modelVars>>

\* --- ProcessDeletionScaleStatefulSet ----------------------------------------
\* reconcile_racks.go:1716-1745 (UpdateRackNodeCount during ProcessDeletion) :
\* scales the (name-matched) STS to 0.  actor = the deleting operator's cached
\* DC epoch; target = the live STS owner epoch.  NO epoch/owner guard.
S1_ProcessDeletionScaleStatefulSet ==
    /\ 1 \in ActiveScenarios
    /\ s1.controller_up
    /\ s1.deleting_dc_epoch /= NoEpoch          \* a deletion is in progress
    /\ s1' = [s1 EXCEPT !.sts_replicas         = 0,
                        !.last_mutation_actor  = s1.deleting_dc_epoch,
                        !.last_mutation_target = s1.sts_owner_epoch,
                        !.last_mutation_kind   = "StatefulSet"]
    /\ UNCHANGED <<s2, s3, s4, s5, modelVars>>

\* --- StatefulSetControllerDeleteEpochPod ------------------------------------
\* test:341-344 : the Kubernetes STS controller reacts to the scale-to-0 and
\* deletes the (epoch-b) pod, releasing the PVC (pvc_in_use -> FALSE).
S1_StatefulSetControllerDeleteEpochPod ==
    /\ 1 \in ActiveScenarios
    /\ s1.sts_replicas = 0
    /\ s1.pod_exists
    /\ s1' = [s1 EXCEPT !.pod_exists           = FALSE,
                        !.pvc_in_use           = FALSE,
                        !.last_mutation_target = s1.pod_epoch,
                        !.last_mutation_kind   = "Pod"]
    /\ UNCHANGED <<s2, s3, s4, s5, modelVars>>

\* --- ProcessDeletionListPVCs ------------------------------------------------
\* reconcile_datacenter.go:159-176 : lists PVCs by GetDatacenterLabels() (name
\* based); records the epoch of the (epoch-b) PVC it found in cache.
S1_ProcessDeletionListPVCs ==
    /\ 1 \in ActiveScenarios
    /\ s1.controller_up
    /\ s1.deleting_dc_epoch /= NoEpoch
    /\ s1.pvc_exists
    /\ s1' = [s1 EXCEPT !.cached_pvc_epoch = s1.pvc_epoch]
    /\ UNCHANGED <<s2, s3, s4, s5, modelVars>>

\* --- ProcessDeletionCheckPVCInUse -------------------------------------------
\* reconcile_datacenter.go:202-215 (isBeingUsed) : TOCTOU guard.  Reads whether
\* a pod currently uses the PVC (from cache).  After the pod was deleted this
\* observes "not in use", so the guard will permit deletion.
S1_ProcessDeletionCheckPVCInUse ==
    /\ 1 \in ActiveScenarios
    /\ s1.controller_up
    /\ s1.deleting_dc_epoch /= NoEpoch
    /\ s1' = [s1 EXCEPT !.cached_pvc_in_use = s1.pvc_in_use]
    /\ UNCHANGED <<s2, s3, s4, s5, modelVars>>

\* --- ProcessDeletionDeletePVC -----------------------------------------------
\* reconcile_datacenter.go:178-197 : deletes the name-matched PVC.  Guard is
\* ONLY isBeingUsed (cached_pvc_in_use = FALSE); there is NO epoch/owner check,
\* so a stale epoch-a operator can delete a live epoch-b PVC (data loss).
S1_ProcessDeletionDeletePVC ==
    /\ 1 \in ActiveScenarios
    /\ s1.controller_up
    /\ s1.pvc_exists
    /\ s1.cached_pvc_in_use = FALSE             \* isBeingUsed guard passed
    /\ s1' = [s1 EXCEPT !.pvc_exists           = FALSE,
                        !.last_mutation_actor  = s1.cached_dc_epoch,
                        !.last_mutation_target = s1.pvc_epoch,
                        !.last_mutation_kind   = "PVC"]
    /\ UNCHANGED <<s2, s3, s4, s5, modelVars>>

\* ===========================================================================
\* SCENARIO 2 : Premature decommission completion / capacity bypass
\* ===========================================================================
\* Completion, started-detection and capacity predicates over remote ring
\* metadata fall back to PERMISSIVE defaults when that metadata is empty /
\* partial / stale, so the destructive cleanup (STS scale-down + PVC delete)
\* can fire before the node has authoritatively left the ring.
\* Source: decommission_node.go:116-464, reconcile_racks.go:1402-1430.

\* --- GetCassMetadataEndpointsSuccess ----------------------------------------
\* reconcile_racks.go:1402-1421 : mgmt /metadata/endpoints returned data; the
\* observed ring state equals the (ground-truth) ring state.
S2_GetCassMetadataEndpointsSuccess ==
    /\ 2 \in ActiveScenarios
    /\ s2.controller_up
    /\ s2' = [s2 EXCEPT !.metadata_outcome    = "Success",
                        !.observed_ring_state = s2.ring_state]
    /\ UNCHANGED <<s1, s3, s4, s5, modelVars>>

\* --- GetCassMetadataEndpointsError ------------------------------------------
\* reconcile_racks.go:1414-1417,1423-1424 : the mgmt call errored (or no pod
\* ready) so metadata is EMPTY -> the target looks "Absent" from the ring even
\* though it may still be Normal/Leaving.  Permissive default #1.
S2_GetCassMetadataEndpointsError ==
    /\ 2 \in ActiveScenarios
    /\ s2.controller_up
    /\ s2' = [s2 EXCEPT !.metadata_outcome    = "Error",
                        !.observed_ring_state = "Absent"]
    /\ UNCHANGED <<s1, s3, s4, s5, modelVars>>

\* --- GetCassMetadataEndpointsPartial ----------------------------------------
\* reconcile_racks.go:1416-1417 : metadata came back but is missing the target
\* endpoint -> target looks "Absent".  Permissive default #2.
S2_GetCassMetadataEndpointsPartial ==
    /\ 2 \in ActiveScenarios
    /\ s2.controller_up
    /\ s2' = [s2 EXCEPT !.metadata_outcome    = "Partial",
                        !.observed_ring_state = "Absent"]
    /\ UNCHANGED <<s1, s3, s4, s5, modelVars>>

\* --- GetUsedStorageForPodsKnown ---------------------------------------------
\* decommission_node.go:440-463 : every dcPod mapped to endpoint load data.
S2_GetUsedStorageForPodsKnown ==
    /\ 2 \in ActiveScenarios
    /\ s2.controller_up
    /\ s2.capacity_approved = FALSE
    /\ s2' = [s2 EXCEPT !.load_known = TRUE]
    /\ UNCHANGED <<s1, s3, s4, s5, modelVars>>

\* --- GetUsedStorageForPodsMissing -------------------------------------------
\* decommission_node.go:455-457 : some pod (possibly the decommission target)
\* had no endpoint load -> its used storage silently defaults to 0.
S2_GetUsedStorageForPodsMissing ==
    /\ 2 \in ActiveScenarios
    /\ s2.controller_up
    /\ s2.capacity_approved = FALSE
    /\ s2' = [s2 EXCEPT !.load_known = FALSE]
    /\ UNCHANGED <<s1, s3, s4, s5, modelVars>>

\* --- EnsurePodsCanAbsorbDecommData ------------------------------------------
\* decommission_node.go:384-437 : spaceUsedByDecommPod defaults to 0 when the
\* target's load is missing (line 390), so `free < needed` is never true and the
\* check APPROVES the scale-down even with unknown load.  Permissive default #3.
\* (Callable directly without a prior /metadata observation — see the missing-
\* load path decommission_node.go:384 invoked outside CheckDecommissioningNodes.)
S2_EnsurePodsCanAbsorbDecommData ==
    /\ 2 \in ActiveScenarios
    /\ s2.controller_up
    /\ s2.capacity_approved = FALSE
    /\ s2' = [s2 EXCEPT !.capacity_approved = TRUE]
    /\ UNCHANGED <<s1, s3, s4, s5, modelVars>>

\* --- CallDecommission -------------------------------------------------------
\* decommission_node.go:152-181 (via DecommissionNodeOnRack:116-149, capacity
\* checked first at :125).  Submits the remote decommission and marks cleanup as
\* started.
S2_CallDecommission ==
    /\ 2 \in ActiveScenarios
    /\ s2.controller_up
    /\ s2.capacity_approved                     \* EnsurePods... ran first
    /\ ~s2.cleanup_started
    /\ s2' = [s2 EXCEPT !.cleanup_target  = "target-pod",
                        !.cleanup_phase   = "DecommissionSubmitted",
                        !.cleanup_started = TRUE]
    /\ UNCHANGED <<s1, s3, s4, s5, modelVars>>

\* --- Real Cassandra ring transitions (ground truth, monotone) ---------------
\* test:667-672 : the actual ring progresses Normal -> Leaving -> Left -> Absent
\* independently of what the operator has observed.  These may LAG behind the
\* operator's completion decision, which is exactly the hazard.
S2_CassandraRingMarkLeaving ==
    /\ 2 \in ActiveScenarios
    /\ s2.ring_state = "Normal"
    /\ s2.cleanup_started                       \* decommission requested first
    /\ s2' = [s2 EXCEPT !.ring_state = "Leaving"]
    /\ UNCHANGED <<s1, s3, s4, s5, modelVars>>

S2_CassandraRingMarkLeft ==
    /\ 2 \in ActiveScenarios
    /\ s2.ring_state = "Leaving"
    /\ s2' = [s2 EXCEPT !.ring_state = "Left"]
    /\ UNCHANGED <<s1, s3, s4, s5, modelVars>>

S2_CassandraRingRemove ==
    /\ 2 \in ActiveScenarios
    /\ s2.ring_state = "Left"
    /\ s2' = [s2 EXCEPT !.ring_state = "Absent"]
    /\ UNCHANGED <<s1, s3, s4, s5, modelVars>>

\* --- IsDoneDecommissioning --------------------------------------------------
\* decommission_node.go:273-292 : returns TRUE if the endpoint shows StatusLeft
\* (:277) OR — critically — if the pod is simply ABSENT from the endpoint data
\* (:291-292 "Gone from the ring completely? return true").  So an empty/partial
\* observation (observed = Absent) authorizes cleanup even though the node has
\* not authoritatively left.  authoritative_removal_observed records the CORRECT
\* condition, exposing the divergence.
S2_IsDoneDecommissioning ==
    /\ 2 \in ActiveScenarios
    /\ s2.controller_up
    /\ s2.cleanup_started
    /\ s2.cleanup_phase = "DecommissionSubmitted"
    /\ s2.observed_ring_state \in {"Left", "Absent"}   \* code decides "done"
    /\ s2' = [s2 EXCEPT
            !.cleanup_phase = "CleanupAuthorized",
            !.authoritative_removal_observed =
                /\ s2.metadata_outcome = "Success"
                /\ s2.observed_ring_state \in {"Left", "Absent"}]
    /\ UNCHANGED <<s1, s3, s4, s5, modelVars>>

\* --- RemoveDecommissionedPodFromSts -----------------------------------------
\* decommission_node.go:343-378 (cleanUpAfterDecommissionedPod step 1) : scales
\* the rack STS down by one.
S2_RemoveDecommissionedPodFromSts ==
    /\ 2 \in ActiveScenarios
    /\ s2.controller_up
    /\ s2.cleanup_phase = "CleanupAuthorized"
    /\ s2' = [s2 EXCEPT !.sts_replicas  = s2.sts_replicas - 1,
                        !.cleanup_phase = "StatefulSetScaled"]
    /\ UNCHANGED <<s1, s3, s4, s5, modelVars>>

\* --- StatefulSetControllerRemoveDecommissionedPod ---------------------------
\* test:643-660 (AfterEmit) : the STS controller deletes the scaled-out pod.
S2_StatefulSetControllerRemoveDecommissionedPod ==
    /\ 2 \in ActiveScenarios
    /\ s2.cleanup_phase = "StatefulSetScaled"
    /\ s2.pod_exists
    /\ s2' = [s2 EXCEPT !.pod_exists = FALSE]
    /\ UNCHANGED <<s1, s3, s4, s5, modelVars>>

\* --- DeletePodPvcs ----------------------------------------------------------
\* decommission_node.go:308-341 (cleanUpAfterDecommissionedPod step 2) : deletes
\* the pod's PVCs.  NOTE there is NO isBeingUsed guard here (asymmetry with
\* deletePVCs; brief finding R1) — the destructive write is unconditional.
S2_DeletePodPvcs ==
    /\ 2 \in ActiveScenarios
    /\ s2.controller_up
    /\ s2.cleanup_phase = "StatefulSetScaled"
    /\ s2.pvc_exists
    /\ s2' = [s2 EXCEPT !.pvc_exists    = FALSE,
                        !.cleanup_phase = "PVCDeleted"]
    /\ UNCHANGED <<s1, s3, s4, s5, modelVars>>

\* --- PatchNodeStatusAfterDecommission ---------------------------------------
\* decommission_node.go:225-249 (cleanUpAfterDecommissionedPod step 3) : removes
\* the node from Status.NodeStatuses.
S2_PatchNodeStatusAfterDecommission ==
    /\ 2 \in ActiveScenarios
    /\ s2.controller_up
    /\ s2.cleanup_phase = "PVCDeleted"
    /\ s2' = [s2 EXCEPT !.node_status_exists = FALSE,
                        !.cleanup_target     = "None",
                        !.cleanup_phase      = "Done"]
    /\ UNCHANGED <<s1, s3, s4, s5, modelVars>>

\* ===========================================================================
\* SCENARIO 3 : Remote side-effect vs durable marker (double-execute / stuck)
\* ===========================================================================
\* The operator performs a remote side-effect (mgmt /start, async maintenance
\* job, child task) in a goroutine or BEFORE writing its durable marker (pod
\* label / task .status); a crash/requeue in between yields a duplicate remote
\* op or a permanently stuck state.
\* Source: reconcile_racks.go:1911-2121, cassandratask_controller.go:238-897,
\*         scheduledtask_controller.go:95-159.

\* ---- 3a. Startup sub-flow (operation_kind = "Startup") ---------------------

\* --- StartCassandra ---------------------------------------------------------
\* reconcile_racks.go:2042-2119 : launches the /start goroutine (:2068) and only
\* AFTER it writes the durable "Starting" label (:2120).  Enabled from "Idle" or
\* after a crash left the previous attempt "Lost" (durable label never written),
\* so re-entry re-submits -> double /start.  remoteSubmits counts submissions.
S3_StartCassandra ==
    /\ 3 \in ActiveScenarios
    /\ s3.operation_kind = "Startup"
    /\ s3.controller_up
    /\ s3.startup_label = "ReadyToStart"        \* no durable "Starting" marker
    /\ s3.remote_state \in {"Idle", "Lost"}
    /\ s3' = [s3 EXCEPT !.remote_state = "InFlight"]
    /\ remoteSubmits' = remoteSubmits + 1
    /\ UNCHANGED <<s1, s2, s4, s5, crashCount>>

\* --- LabelServerPodStarting -------------------------------------------------
\* reconcile_racks.go:1911-1922 : writes the durable "Starting" pod label.
S3_LabelServerPodStarting ==
    /\ 3 \in ActiveScenarios
    /\ s3.operation_kind = "Startup"
    /\ s3.controller_up
    /\ s3.remote_state = "InFlight"
    /\ s3.startup_label = "ReadyToStart"
    /\ s3' = [s3 EXCEPT !.startup_label  = "Starting",
                        !.durable_marker = "StartupStarting"]
    /\ UNCHANGED <<s1, s2, s4, s5, modelVars>>

\* --- PatchLastServerNodeStarted ---------------------------------------------
\* reconcile_racks.go:1924-1929 : patches DC status LastServerNodeStarted.
S3_PatchLastServerNodeStarted ==
    /\ 3 \in ActiveScenarios
    /\ s3.operation_kind = "Startup"
    /\ s3.controller_up
    /\ s3.startup_label = "Starting"
    /\ ~s3.startup_timestamped
    /\ s3' = [s3 EXCEPT !.startup_timestamped = TRUE,
                        !.durable_marker      = "StartupStartingTimestamp"]
    /\ UNCHANGED <<s1, s2, s4, s5, modelVars>>

\* --- CallLifecycleStartEndpointAccepted -------------------------------------
\* reconcile_racks.go:2110-2113 (inside the goroutine) : mgmt /start accepted.
S3_CallLifecycleStartEndpointAccepted ==
    /\ 3 \in ActiveScenarios
    /\ s3.operation_kind = "Startup"
    /\ s3.remote_state = "InFlight"
    /\ s3.startup_timestamped                   \* server releases after patch
    /\ s3' = [s3 EXCEPT !.remote_state     = "Accepted",
                        !.request_accepted = TRUE]
    /\ UNCHANGED <<s1, s2, s4, s5, modelVars>>

\* --- CallLifecycleStartEndpointError ----------------------------------------
\* reconcile_racks.go:2088-2091 : mgmt /start failed.
S3_CallLifecycleStartEndpointError ==
    /\ 3 \in ActiveScenarios
    /\ s3.operation_kind = "Startup"
    /\ s3.remote_state = "InFlight"
    /\ s3.startup_timestamped
    /\ s3' = [s3 EXCEPT !.remote_state = "Failed"]
    /\ UNCHANGED <<s1, s2, s4, s5, modelVars>>

\* --- DeletePodAfterStartFailure ---------------------------------------------
\* reconcile_racks.go:2092-2099 : deletes the pod so it can be retried.
S3_DeletePodAfterStartFailure ==
    /\ 3 \in ActiveScenarios
    /\ s3.operation_kind = "Startup"
    /\ s3.remote_state = "Failed"
    /\ s3.startup_pod_exists
    /\ s3' = [s3 EXCEPT !.startup_pod_exists = FALSE,
                        !.startup_label      = "Deleted"]
    /\ UNCHANGED <<s1, s2, s4, s5, modelVars>>

\* --- CassandraPodBecomesReady -----------------------------------------------
\* test:822-826 : the Cassandra container reports Ready.
S3_CassandraPodBecomesReady ==
    /\ 3 \in ActiveScenarios
    /\ s3.operation_kind = "Startup"
    /\ s3.remote_state = "Accepted"
    /\ s3.startup_pod_exists
    /\ ~s3.startup_ready
    /\ s3' = [s3 EXCEPT !.startup_ready = TRUE]
    /\ UNCHANGED <<s1, s2, s4, s5, modelVars>>

\* --- LabelServerPodStarted --------------------------------------------------
\* reconcile_racks.go:1943-1953 (via findStartingNodes:1968-1985) : promotes the
\* pod label to "Started" once it is Ready.
S3_LabelServerPodStarted ==
    /\ 3 \in ActiveScenarios
    /\ s3.operation_kind = "Startup"
    /\ s3.controller_up
    /\ s3.startup_label = "Starting"
    /\ s3.startup_ready
    /\ s3' = [s3 EXCEPT !.startup_label  = "Started",
                        !.durable_marker = "StartupStarted"]
    /\ UNCHANGED <<s1, s2, s4, s5, modelVars>>

\* ---- 3b. Maintenance sub-flow (operation_kind = "Maintenance") -------------

\* --- StartPodTaskAsync ------------------------------------------------------
\* cassandratask_controller.go:726-766 : submits the async mgmt job and stores
\* the returned job id IN MEMORY only (status.JobID).  Enabled while no durable
\* job id exists; after a crash/patch-failure left it uncheckpointed, re-entry
\* re-submits -> a SECOND remote job (double execute).  remoteSubmits counts it.
S3_StartPodTaskAsync ==
    /\ 3 \in ActiveScenarios
    /\ s3.operation_kind = "Maintenance"
    /\ s3.controller_up
    /\ s3.job_id = NoJob                          \* nothing durably checkpointed
    /\ s3.remote_state \in {"Idle", "AcceptedUncheckpointed"}
    /\ LET newJob == IF remoteSubmits = 0 THEN "job-1" ELSE "job-2" IN
        s3' = [s3 EXCEPT !.remote_jobs      = Append(s3.remote_jobs, newJob),
                         !.pending_job_id   = newJob,
                         !.remote_state     = "Accepted",
                         !.request_accepted = TRUE]
    /\ remoteSubmits' = remoteSubmits + 1
    /\ UNCHANGED <<s1, s2, s4, s5, crashCount>>

\* --- ProcessRackPatchJobID --------------------------------------------------
\* cassandratask_controller.go:711-717 : persists status (durable job id).
S3_ProcessRackPatchJobID ==
    /\ 3 \in ActiveScenarios
    /\ s3.operation_kind = "Maintenance"
    /\ s3.controller_up
    /\ s3.pending_job_id /= NoJob
    /\ s3' = [s3 EXCEPT !.job_id         = s3.pending_job_id,
                        !.pending_job_id = NoJob,
                        !.durable_marker = "MaintenanceJobID"]
    /\ UNCHANGED <<s1, s2, s4, s5, modelVars>>

\* --- ProcessRackPatchJobIDFailure -------------------------------------------
\* cassandratask_controller.go:713-715 : the status patch failed, so the job id
\* was NEVER checkpointed even though the remote job is running.
S3_ProcessRackPatchJobIDFailure ==
    /\ 3 \in ActiveScenarios
    /\ s3.operation_kind = "Maintenance"
    /\ s3.controller_up
    /\ s3.pending_job_id /= NoJob
    /\ s3' = [s3 EXCEPT !.pending_job_id = NoJob,
                        !.remote_state   = "AcceptedUncheckpointed"]
    /\ UNCHANGED <<s1, s2, s4, s5, modelVars>>

\* --- CheckRackCompletion ----------------------------------------------------
\* cassandratask_controller.go:870-891 : polls the mgmt job and marks it done.
S3_CheckRackCompletion ==
    /\ 3 \in ActiveScenarios
    /\ s3.operation_kind = "Maintenance"
    /\ s3.controller_up
    /\ s3.job_id /= NoJob
    /\ s3.remote_jobs /= << >>
    /\ s3' = [s3 EXCEPT !.remote_jobs  = RemoveFromSeq(s3.remote_jobs, s3.job_id),
                        !.remote_state = "Completed"]
    /\ UNCHANGED <<s1, s2, s4, s5, modelVars>>

\* ---- 3c. Schedule sub-flow (operation_kind = "Schedule") -------------------

\* --- ScheduledTaskStatusUpdate ----------------------------------------------
\* scheduledtask_controller.go:124-134 : records the execution as consumed
\* (LastExecution) BEFORE the child task is created (:150).  This is the
\* claim-before-create ordering behind the possible lost execution (finding R4).
S3_ScheduledTaskStatusUpdate ==
    /\ 3 \in ActiveScenarios
    /\ s3.operation_kind = "Schedule"
    /\ s3.controller_up
    /\ s3.occurrence_state = "Due"
    /\ s3' = [s3 EXCEPT !.occurrence_state        = "Claimed",
                        !.schedule_create_pending = TRUE,
                        !.durable_marker          = "OccurrenceClaimed"]
    /\ UNCHANGED <<s1, s2, s4, s5, modelVars>>

\* --- ScheduledTaskCreateChild -----------------------------------------------
\* scheduledtask_controller.go:150-155 : child CassandraTask created.
S3_ScheduledTaskCreateChild ==
    /\ 3 \in ActiveScenarios
    /\ s3.operation_kind = "Schedule"
    /\ s3.controller_up
    /\ s3.schedule_create_pending
    /\ s3' = [s3 EXCEPT !.child_exists            = TRUE,
                        !.occurrence_state        = "Materialized",
                        !.schedule_create_pending = FALSE,
                        !.durable_marker          = "OccurrenceMaterialized"]
    /\ UNCHANGED <<s1, s2, s4, s5, modelVars>>

\* --- ScheduledTaskCreateChildFailure ----------------------------------------
\* scheduledtask_controller.go:150-153 : child create failed AFTER the execution
\* was already recorded -> the occurrence is claimed but never materialized.
S3_ScheduledTaskCreateChildFailure ==
    /\ 3 \in ActiveScenarios
    /\ s3.operation_kind = "Schedule"
    /\ s3.controller_up
    /\ s3.schedule_create_pending
    /\ s3' = [s3 EXCEPT !.schedule_create_pending = FALSE]
    /\ UNCHANGED <<s1, s2, s4, s5, modelVars>>

\* ---- 3d. Task lifecycle sub-flow (operation_kind = "TaskLifecycle") --------

\* --- CassandraTaskActivateLabel ---------------------------------------------
\* cassandratask_controller.go:244-250 : writes the Active LABEL first ...
S3_CassandraTaskActivateLabel ==
    /\ 3 \in ActiveScenarios
    /\ s3.operation_kind = "TaskLifecycle"
    /\ s3.controller_up
    /\ s3.task_label = "Pending"
    /\ s3' = [s3 EXCEPT !.task_label     = "Active",
                        !.durable_marker = "TaskActiveLabel"]
    /\ UNCHANGED <<s1, s2, s4, s5, modelVars>>

\* --- CassandraTaskActivateStatus --------------------------------------------
\* cassandratask_controller.go:252-258 : ... then the Running STATUS separately.
\* A crash in between wedges the task (label Active but status Pending; the
\* activation block at :245 is skipped on re-entry because the label is set).
S3_CassandraTaskActivateStatus ==
    /\ 3 \in ActiveScenarios
    /\ s3.operation_kind = "TaskLifecycle"
    /\ s3.controller_up
    /\ s3.task_label = "Active"
    /\ s3.task_status = "Pending"
    /\ s3' = [s3 EXCEPT !.task_status    = "Running",
                        !.durable_marker = "TaskActiveStatus"]
    /\ UNCHANGED <<s1, s2, s4, s5, modelVars>>

\* --- CassandraTaskCompleteLabel ---------------------------------------------
\* cassandratask_controller.go:280-286 : writes the Completed LABEL first ...
S3_CassandraTaskCompleteLabel ==
    /\ 3 \in ActiveScenarios
    /\ s3.operation_kind = "TaskLifecycle"
    /\ s3.controller_up
    /\ s3.task_status = "Running"
    /\ s3.task_label = "Active"
    /\ s3' = [s3 EXCEPT !.task_label     = "Completed",
                        !.durable_marker = "TaskCompletedLabel"]
    /\ UNCHANGED <<s1, s2, s4, s5, modelVars>>

\* --- CassandraTaskCompleteStatus --------------------------------------------
\* cassandratask_controller.go:320-326 : ... then the Completed STATUS.
S3_CassandraTaskCompleteStatus ==
    /\ 3 \in ActiveScenarios
    /\ s3.operation_kind = "TaskLifecycle"
    /\ s3.controller_up
    /\ s3.task_label = "Completed"
    /\ s3.task_status = "Running"
    /\ s3' = [s3 EXCEPT !.task_status    = "Completed",
                        !.durable_marker = "TaskCompletedStatus"]
    /\ UNCHANGED <<s1, s2, s4, s5, modelVars>>

\* ===========================================================================
\* SCENARIO 4 : Availability / PDB window during scale & rollout
\* ===========================================================================
\* The single cluster-wide PDB (minAvailable = Size-1) is stale, absent, or
\* bypassed during a multi-step scale/rollout because reconcile updates the STS
\* BEFORE the PDB (ladder order reconcile_racks.go:2810 < :2830) and re-creates
\* the PDB non-atomically (delete-then-create, :1678-1710).
\* Source: reconcile_racks.go:925-978, 1639-1712; constructor.go:23-44.

\* --- ChangeDatacenterSize ---------------------------------------------------
\* test:934-936 : the desired DC size is increased (scale-up requested).
S4_ChangeDatacenterSize ==
    /\ 4 \in ActiveScenarios
    /\ s4.controller_up
    /\ s4.desired_size = 2
    /\ s4' = [s4 EXCEPT !.desired_size = 3]
    /\ UNCHANGED <<s1, s2, s3, s5, modelVars>>

\* --- CheckRackScale ---------------------------------------------------------
\* reconcile_racks.go:925-978 : updates STS replicas to the desired size.  This
\* runs BEFORE CheckDcPodDisruptionBudget, so the PDB is momentarily stale.
S4_CheckRackScale ==
    /\ 4 \in ActiveScenarios
    /\ s4.controller_up
    /\ s4.sts_replicas < s4.desired_size
    /\ s4' = [s4 EXCEPT !.sts_replicas = s4.desired_size]
    /\ UNCHANGED <<s1, s2, s3, s5, modelVars>>

\* --- PodBecomesReady --------------------------------------------------------
\* test:946-948 : a newly-scheduled pod reports Ready.
S4_PodBecomesReady ==
    /\ 4 \in ActiveScenarios
    /\ s4.ready_pods < s4.sts_replicas
    /\ s4' = [s4 EXCEPT !.ready_pods = s4.ready_pods + 1]
    /\ UNCHANGED <<s1, s2, s3, s5, modelVars>>

\* --- CheckDcPodDisruptionBudgetDelete ---------------------------------------
\* reconcile_racks.go:1677-1691 : the PDB cannot be updated in place, so it is
\* DELETED first — opening a window with NO disruption budget at all.
S4_CheckDcPodDisruptionBudgetDelete ==
    /\ 4 \in ActiveScenarios
    /\ s4.controller_up
    /\ s4.pdb_present
    /\ s4.pdb_min_available /= s4.desired_size - 1   \* PDB needs updating
    /\ s4' = [s4 EXCEPT !.pdb_present = FALSE]
    /\ UNCHANGED <<s1, s2, s3, s5, modelVars>>

\* --- CheckDcPodDisruptionBudgetCreate ---------------------------------------
\* reconcile_racks.go:1693-1710; constructor.go:23-24 : re-creates the PDB with
\* minAvailable = Size-1.
S4_CheckDcPodDisruptionBudgetCreate ==
    /\ 4 \in ActiveScenarios
    /\ s4.controller_up
    /\ ~s4.pdb_present
    /\ s4' = [s4 EXCEPT !.pdb_present       = TRUE,
                        !.pdb_min_available = s4.desired_size - 1]
    /\ UNCHANGED <<s1, s2, s3, s5, modelVars>>

\* --- AdmitVoluntaryEviction -------------------------------------------------
\* test:922-931 : a voluntary eviction (e.g. node drain) is admitted.  With NO
\* PDB present the API server admits it unconditionally; with a STALE PDB it is
\* admitted down to the (too-low) stale minAvailable.  Either way it can push
\* live availability below the size's real floor.
S4_AdmitVoluntaryEviction ==
    /\ 4 \in ActiveScenarios
    /\ \/ ~s4.pdb_present                                        \* no guard
       \/ (s4.ready_pods - s4.evicted_pods) - 1 >= s4.pdb_min_available
    /\ s4.ready_pods - s4.evicted_pods > 0
    /\ s4' = [s4 EXCEPT !.evicted_pods = s4.evicted_pods + 1]
    /\ UNCHANGED <<s1, s2, s3, s5, modelVars>>

\* ===========================================================================
\* SCENARIO 5 : Deletion / finalizer ordering (deadlock or premature removal)
\* ===========================================================================
\* Finalizer removal happens inside ProcessDeletion, which the controller runs
\* only AFTER IsValid passes.  IsValid loads the superuser secret and, on a
\* missing secret, the controller wraps the error as reconcile.TerminalError
\* (no requeue) BEFORE ProcessDeletion — so the finalizer is never removed
\* (stuck Terminating).  Conversely the finalizer must not be removed before
\* cleanup completes.
\* Source: cassandradatacenter_controller.go:98-137, handler.go:93-98,
\*         reconcile_datacenter.go:27-145, context.go:56-127.

\* --- SetDecommissionOnDelete ------------------------------------------------
\* test:1043-1049 : user sets the decommission-on-delete annotation.
S5_SetDecommissionOnDelete ==
    /\ 5 \in ActiveScenarios
    /\ s5.controller_up
    /\ ~s5.deleting
    /\ ~s5.decommission_required
    /\ s5' = [s5 EXCEPT !.decommission_required = TRUE]
    /\ UNCHANGED <<s1, s2, s3, s4, modelVars>>

\* --- BeginDatacenterDeletion ------------------------------------------------
\* test:1051-1059 : the DC receives a deletionTimestamp.
S5_BeginDatacenterDeletion ==
    /\ 5 \in ActiveScenarios
    /\ s5.controller_up
    /\ ~s5.deleting
    /\ s5' = [s5 EXCEPT !.deleting = TRUE]
    /\ UNCHANGED <<s1, s2, s3, s4, modelVars>>

\* --- DeleteDependencySecret (ADVERSARY) -------------------------------------
\* test:1118-1131 : the superuser/management secret is deleted first (e.g. a
\* namespace garbage-collection ordering, brief #952/#812).  Any in-memory
\* reconciliation context and validation become invalid.
S5_DeleteDependencySecret ==
    /\ 5 \in ActiveScenarios
    /\ s5.dependency_present
    /\ s5' = [s5 EXCEPT !.dependency_present = FALSE,
                        !.mgmt_ready         = FALSE,
                        !.context_ready      = FALSE,
                        !.validation_passed  = FALSE]
    /\ UNCHANGED <<s1, s2, s3, s4, modelVars>>

\* --- CreateReconciliationContext --------------------------------------------
\* context.go:56-127 : builds the reconciliation context + mgmt client.
S5_CreateReconciliationContext ==
    /\ 5 \in ActiveScenarios
    /\ s5.controller_up
    /\ ~s5.context_ready
    /\ s5' = [s5 EXCEPT !.mgmt_ready    = TRUE,
                        !.context_ready = TRUE]
    /\ UNCHANGED <<s1, s2, s3, s4, modelVars>>

\* --- IsValid ----------------------------------------------------------------
\* handler.go:93-98 + cassandradatacenter_controller.go:133-137 : validation
\* passes ONLY when the superuser secret is present.  A missing secret makes
\* IsValid error, the controller returns TerminalError (no requeue), and this
\* action is disabled forever -> ProcessDeletion below can never run.
S5_IsValid ==
    /\ 5 \in ActiveScenarios
    /\ s5.controller_up
    /\ s5.context_ready
    /\ s5.dependency_present                     \* validateSuperuserSecret ok
    /\ ~s5.validation_passed
    /\ s5' = [s5 EXCEPT !.validation_passed = TRUE]
    /\ UNCHANGED <<s1, s2, s3, s4, modelVars>>

\* --- ProcessDeletionOrdinaryCleanup -----------------------------------------
\* reconcile_datacenter.go:81-130 (non-decommission branch) : scales STS to 0
\* and deletes PVCs, then records cleanup done.  Runs only after IsValid passed.
S5_ProcessDeletionOrdinaryCleanup ==
    /\ 5 \in ActiveScenarios
    /\ s5.controller_up
    /\ s5.deleting
    /\ s5.validation_passed
    /\ ~s5.decommission_required
    /\ ~s5.ordinary_cleanup_done
    /\ SeqContains(s5.finalizers, "cassandra.datastax.com/finalizer")
    /\ s5' = [s5 EXCEPT !.ordinary_cleanup_done = TRUE]
    /\ UNCHANGED <<s1, s2, s3, s4, modelVars>>

\* --- ProcessDeletionDecommission --------------------------------------------
\* reconcile_datacenter.go:54-130 (decommission branch) : the decommission path
\* completes and records cleanup done.
S5_ProcessDeletionDecommission ==
    /\ 5 \in ActiveScenarios
    /\ s5.controller_up
    /\ s5.deleting
    /\ s5.validation_passed
    /\ s5.decommission_required
    /\ ~s5.ordinary_cleanup_done
    /\ SeqContains(s5.finalizers, "cassandra.datastax.com/finalizer")
    /\ s5' = [s5 EXCEPT !.ordinary_cleanup_done = TRUE]
    /\ UNCHANGED <<s1, s2, s3, s4, modelVars>>

\* --- ProcessDeletionRemoveFinalizers ----------------------------------------
\* reconcile_datacenter.go:132-142 : clears ALL finalizers (SetFinalizers(nil)),
\* allowing the DC object to be deleted.  Gated on cleanup having completed.
S5_ProcessDeletionRemoveFinalizers ==
    /\ 5 \in ActiveScenarios
    /\ s5.controller_up
    /\ s5.deleting
    /\ s5.validation_passed
    /\ s5.ordinary_cleanup_done
    /\ s5.finalizers /= << >>
    /\ s5' = [s5 EXCEPT !.finalizers = << >>]
    /\ UNCHANGED <<s1, s2, s3, s4, modelVars>>

\* ===========================================================================
\* CROSS-CUTTING : controller crash / recover (primary adversary)
\* ===========================================================================
\* A crash loses IN-MEMORY reconcile progress but never the state already
\* persisted to Kubernetes objects.  trace.go:124-132 defines the harness crash
\* effect for Scenario 3 (drop uncheckpointed job id / pending schedule create;
\* an in-flight Startup /start becomes "Lost").  For Scenario 5 the in-memory
\* reconciliation context / validation are lost and must be rebuilt on recovery
\* (and will fail if the dependency secret is now gone -> deadlock).

\* --- ControllerCrash --------------------------------------------------------
ControllerCrash ==
    /\ s1.controller_up  \/ s2.controller_up \/ s3.controller_up
       \/ s4.controller_up \/ s5.controller_up
    /\ crashCount' = crashCount + 1
    /\ s1' = [s1 EXCEPT !.controller_up = FALSE]
    /\ s2' = [s2 EXCEPT !.controller_up = FALSE,
                        !.metadata_outcome    = "Unobserved",
                        !.observed_ring_state = "Unknown"]  \* re-read on recover
    /\ s3' = [s3 EXCEPT !.controller_up           = FALSE,
                        !.pending_job_id          = NoJob,
                        !.schedule_create_pending = FALSE,
                        !.remote_state = IF s3.operation_kind = "Startup"
                                            /\ s3.remote_state = "InFlight"
                                         THEN "Lost" ELSE s3.remote_state]
    /\ s4' = [s4 EXCEPT !.controller_up = FALSE]
    /\ s5' = [s5 EXCEPT !.controller_up      = FALSE,
                        !.mgmt_ready          = FALSE,
                        !.context_ready       = FALSE,
                        !.validation_passed   = FALSE]
    /\ UNCHANGED remoteSubmits

\* --- ControllerRecover ------------------------------------------------------
ControllerRecover ==
    /\ ~(s1.controller_up \/ s2.controller_up \/ s3.controller_up
         \/ s4.controller_up \/ s5.controller_up)
    /\ s1' = [s1 EXCEPT !.controller_up = TRUE]
    /\ s2' = [s2 EXCEPT !.controller_up = TRUE]
    /\ s3' = [s3 EXCEPT !.controller_up = TRUE]
    /\ s4' = [s4 EXCEPT !.controller_up = TRUE]
    /\ s5' = [s5 EXCEPT !.controller_up = TRUE]
    /\ UNCHANGED modelVars

\* ===========================================================================
\* NEXT
\* ===========================================================================

Next ==
    \* --- Scenario 1 ---
    \/ S1_BeginDatacenterDeletionEpochA
    \/ S1_DeleteDatacenterObjectEpochA
    \/ S1_CreateSameNameDatacenterEpochB
    \/ S1_RefreshDatacenterCache
    \/ S1_GetStatefulSetForRack
    \/ S1_ProcessDeletionScaleStatefulSet
    \/ S1_StatefulSetControllerDeleteEpochPod
    \/ S1_ProcessDeletionListPVCs
    \/ S1_ProcessDeletionCheckPVCInUse
    \/ S1_ProcessDeletionDeletePVC
    \* --- Scenario 2 ---
    \/ S2_GetCassMetadataEndpointsSuccess
    \/ S2_GetCassMetadataEndpointsError
    \/ S2_GetCassMetadataEndpointsPartial
    \/ S2_GetUsedStorageForPodsKnown
    \/ S2_GetUsedStorageForPodsMissing
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
    \/ S4_ChangeDatacenterSize
    \/ S4_CheckRackScale
    \/ S4_PodBecomesReady
    \/ S4_CheckDcPodDisruptionBudgetDelete
    \/ S4_CheckDcPodDisruptionBudgetCreate
    \/ S4_AdmitVoluntaryEviction
    \* --- Scenario 5 ---
    \/ S5_SetDecommissionOnDelete
    \/ S5_BeginDatacenterDeletion
    \/ S5_DeleteDependencySecret
    \/ S5_CreateReconciliationContext
    \/ S5_IsValid
    \/ S5_ProcessDeletionOrdinaryCleanup
    \/ S5_ProcessDeletionDecommission
    \/ S5_ProcessDeletionRemoveFinalizers
    \* --- Cross-cutting ---
    \/ ControllerCrash
    \/ ControllerRecover

Spec == Init /\ [][Next]_vars

\* Keeps the base model finite for standalone checking (crash/recover would
\* otherwise ping-pong forever).  MC.tla bounds crash firing explicitly instead.
StateConstraint == crashCount <= MaxCrashCount

\* ===========================================================================
\* INVARIANTS
\* ===========================================================================
\* ---- Standard / structural ------------------------------------------------

\* Epoch tags are always well-formed.
EpochTypeOK ==
    /\ s1.live_dc_epoch     \in Epochs
    /\ s1.deleting_dc_epoch \in Epochs
    /\ s1.pvc_epoch         \in Epochs
    /\ s1.sts_owner_epoch   \in Epochs

\* Availability accounting never goes negative / absurd.
RolloutSane ==
    /\ s4.ready_pods >= 0
    /\ s4.evicted_pods >= 0
    /\ s4.pdb_min_available >= 0
    /\ s4.ready_pods <= s4.sts_replicas

\* A cleanup phase only ever moves forward through the fixed pipeline.
DecommissionPhaseOK ==
    s2.cleanup_phase \in {"Idle", "DecommissionSubmitted", "CleanupAuthorized",
                          "StatefulSetScaled", "PVCDeleted", "Done"}

\* brief §5 (standard) ObservedGenerationSanity — the operator must not scale a
\* rack whose cached STS owner generation disagrees with the live one while it
\* believes a deletion is in progress on the OLD generation.  (Structural view
\* of the stale-cache guard shared by Scenarios 1 & 4.)
ObservedGenerationSanity ==
    (s1.last_mutation_kind = "StatefulSet" /\ s1.deleting_dc_epoch /= NoEpoch)
        => (s1.last_mutation_actor = s1.deleting_dc_epoch)

\* ---- Scenario 1 : NoCrossEpochPVCDelete -----------------------------------
\* A PVC delete must target a PVC whose (live) epoch equals the deleting DC's
\* epoch.  The delete records actor = the operator's cached DC epoch and target
\* = the live PVC epoch; a stale operator deleting a newer-generation PVC makes
\* them differ.
NoCrossEpochPVCDelete ==
    (s1.last_mutation_kind = "PVC")
        => (s1.last_mutation_actor = s1.last_mutation_target)

\* ---- Scenario 2 : NoDataLossOnDecommission --------------------------------
\* A node's PVC is deleted only after the node has authoritatively left the ring
\* (ground-truth ring_state Left/Absent).  Deleting while the real ring is still
\* Normal/Leaving is unrecoverable data loss.
NoDataLossOnDecommission ==
    (s2.cleanup_started /\ ~s2.pvc_exists
        /\ s2.cleanup_phase \in {"PVCDeleted", "Done"})
        => (s2.ring_state \in {"Left", "Absent"})

\* ---- Scenario 2 : CapacityRespected ---------------------------------------
\* Decommission capacity is approved only when the leaving node's load is
\* actually known (missing data must block, not silently default to 0).
CapacityRespected ==
    s2.capacity_approved => s2.load_known

\* ---- Scenario 3 : AtMostOnceRemoteOp --------------------------------------
\* Each logical start / maintenance job is submitted to the mgmt API at most
\* once, even across crashes.
AtMostOnceRemoteOp ==
    remoteSubmits <= 1

\* ---- Scenario 4 : AvailabilityFloor ---------------------------------------
\* Live availability (ready minus evicted) never drops below the size's floor
\* (Size-1) across scale / PDB-recreate windows and evictions.
AvailabilityFloor ==
    (s4.ready_pods - s4.evicted_pods) >= (s4.desired_size - 1)

\* ---- Scenario 5 : FinalizerAfterCleanup -----------------------------------
\* The finalizer is removed only after the required cleanup completed.
FinalizerAfterCleanup ==
    (s5.deleting /\ s5.finalizers = << >>) => s5.ordinary_cleanup_done

=============================================================================
