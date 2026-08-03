------------------------------- MODULE Trace -------------------------------
(**************************************************************************)
(* Linear trace replay for the Category A SONiC warm-reboot protocol.      *)
(* Every logged wrapper invokes the full base action, validates all fields  *)
(* declared for that event in instrumentation-spec.md, then advances l.     *)
(**************************************************************************)

EXTENDS base, Json, IOUtils, Sequences, TLC

B == INSTANCE base

(**************************************************************************)
(* Trace loading.                                                          *)
(**************************************************************************)

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

TraceLog == TLCEval(
    LET all == ndJsonDeserialize(JsonFile)
    IN SelectSeq(all, LAMBDA x :
        /\ "tag" \in DOMAIN x
        /\ x.tag = "warmreboot"
        /\ "event" \in DOMAIN x
        /\ "name" \in DOMAIN x.event
        /\ "post" \in DOMAIN x.event))

ASSUME Len(TraceLog) > 0

VARIABLE l

traceVars == <<l>>
traceAllVars == <<vars, l>>

logline == TraceLog[l]
Post == logline.event.post

(**************************************************************************)
(* JSON conversion and event predicates.                                  *)
(**************************************************************************)

SeqToSet(seq) == {seq[i] : i \in 1..Len(seq)}

PairSeqToSet(seq) ==
    {<<seq[i].vid, seq[i].rid>> : i \in 1..Len(seq)}

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = name

IsOwnerEvent(name, c) ==
    /\ IsEvent(name)
    /\ "owner" \in DOMAIN logline.event
    /\ logline.event.owner = c

IsAsicEvent(name, a) ==
    /\ IsEvent(name)
    /\ "asic" \in DOMAIN logline.event
    /\ logline.event.asic = a

IsProducerEvent(name, p) ==
    /\ IsEvent(name)
    /\ "asic" \in DOMAIN logline.event
    /\ "producer" \in DOMAIN logline.event
    /\ p = <<logline.event.asic, logline.event.producer>>

IsComponentEvent(name, comp) ==
    /\ IsEvent(name)
    /\ "component" \in DOMAIN logline.event
    /\ logline.event.component = comp

Has(fields) == fields \subseteq DOMAIN Post

StepTrace == l' = l + 1

(**************************************************************************)
(* Mandatory post-state validators. Each requires, then checks, every field *)
(* emitted for its event schema; there are no conditional/vacuous checks.  *)
(**************************************************************************)

ValidateRequestPost(c) ==
    /\ Has({"request_kind", "phase", "attempt_outcome"})
    /\ requestKind'[c] = Post.request_kind
    /\ phase'[c] = Post.phase
    /\ attemptOutcome'[c] = Post.attempt_outcome

ValidateCheckAdmitPost(c) ==
    /\ Has({"checked", "phase"})
    /\ checked'[c] = Post.checked
    /\ phase'[c] = Post.phase

ValidateRejectPost(c) ==
    /\ Has({"phase", "attempt_outcome"})
    /\ phase'[c] = Post.phase
    /\ attemptOutcome'[c] = Post.attempt_outcome

ValidateEnablePost(c) ==
    /\ Has({"epoch", "owner", "flags", "phase", "checked", "admitted",
             "attempt_epoch", "attempt_outcome", "cancelled"})
    /\ {"warm", "fast", "epoch"} \subseteq DOMAIN Post.flags
    /\ epoch' = Post.epoch
    /\ owner' = Post.owner
    /\ flags' = [warm |-> Post.flags.warm,
                  fast |-> Post.flags.fast,
                  epoch |-> Post.flags.epoch]
    /\ phase'[c] = Post.phase
    /\ checked'[c] = Post.checked
    /\ admitted'[c] = Post.admitted
    /\ attemptEpoch'[c] = Post.attempt_epoch
    /\ attemptOutcome'[c] = Post.attempt_outcome
    /\ cancelled'[c] = Post.cancelled

ValidateClearBootPost(c) ==
    /\ Has({"owner", "cleanup_owner", "flags", "phase", "cancelled",
             "snapshot_present", "snapshot_valid", "snapshot_stage"})
    /\ {"warm", "fast", "epoch"} \subseteq DOMAIN Post.flags
    /\ Asics \subseteq DOMAIN Post.snapshot_present
    /\ Asics \subseteq DOMAIN Post.snapshot_valid
    /\ Asics \subseteq DOMAIN Post.snapshot_stage
    /\ owner' = Post.owner
    /\ cleanupOwner' = Post.cleanup_owner
    /\ flags' = [warm |-> Post.flags.warm,
                  fast |-> Post.flags.fast,
                  epoch |-> Post.flags.epoch]
    /\ phase'[c] = Post.phase
    /\ cancelled'[c] = Post.cancelled
    /\ \A a \in Asics :
          /\ snapshotPresent'[a] = Post.snapshot_present[a]
          /\ snapshotValid'[a] = Post.snapshot_valid[a]
          /\ snapshotStage'[a] = Post.snapshot_stage[a]

ValidatePhasePost(c) ==
    /\ Has({"phase"})
    /\ phase'[c] = Post.phase

ValidateContinuePost(c) ==
    /\ Has({"phase", "cancelled"})
    /\ phase'[c] = Post.phase
    /\ cancelled'[c] = Post.cancelled

ValidateIrreversiblePost(c) ==
    /\ Has({"phase", "irreversible_started"})
    /\ phase'[c] = Post.phase
    /\ irreversibleStarted'[c] = Post.irreversible_started

ValidateOutcomePost(c) ==
    /\ Has({"phase", "attempt_outcome"})
    /\ phase'[c] = Post.phase
    /\ attemptOutcome'[c] = Post.attempt_outcome

ValidateProducerPost(p) ==
    /\ Has({"queue", "inflight", "quiescent"})
    /\ queue'[p] = Post.queue
    /\ inflight'[p] = Post.inflight
    /\ quiescent'[p] = Post.quiescent

ValidateReadyPost(a) ==
    /\ Has({"ready_sent", "post_ready_step"})
    /\ readySent'[a] = Post.ready_sent
    /\ postReadyStep'[a] = Post.post_ready_step

ValidateReplyConsumedPost(a) ==
    /\ Has({"ready_consumed", "freeze_result"})
    /\ readyConsumed'[a] = Post.ready_consumed
    /\ freezeResult'[a] = Post.freeze_result

ValidateRingDrainPost(a) ==
    LET p == <<a, RingProducer>> IN
    /\ Has({"queue", "inflight", "quiescent", "post_ready_step"})
    /\ queue'[p] = Post.queue
    /\ inflight'[p] = Post.inflight
    /\ quiescent'[p] = Post.quiescent
    /\ postReadyStep'[a] = Post.post_ready_step

ValidatePostReadyStep(a) ==
    /\ Has({"post_ready_step"})
    /\ postReadyStep'[a] = Post.post_ready_step

ValidateFreezePost(a) ==
    /\ Has({"producer_state", "quiescent", "post_ready_step"})
    /\ ProducerKinds \subseteq DOMAIN Post.producer_state
    /\ ProducerKinds \subseteq DOMAIN Post.quiescent
    /\ \A kind \in ProducerKinds :
          /\ producerState'[<<a, kind>>] = Post.producer_state[kind]
          /\ quiescent'[<<a, kind>>] = Post.quiescent[kind]
    /\ postReadyStep'[a] = Post.post_ready_step

ValidateStopPost(a) ==
    /\ Has({"writer_stopped", "shutdown_status"})
    /\ writerStopped'[a] = Post.writer_stopped
    /\ shutdownStatus'[a] = Post.shutdown_status

ValidateShutdownModePost(a) ==
    /\ Has({"local_mode", "shutdown_status"})
    /\ localMode'[a] = Post.local_mode
    /\ shutdownStatus'[a] = Post.shutdown_status

ValidateSavePost(a) ==
    /\ Has({"snapshot_epoch", "snapshot_valid", "snapshot_stage"})
    /\ snapshotEpoch'[a] = Post.snapshot_epoch
    /\ snapshotValid'[a] = Post.snapshot_valid
    /\ snapshotStage'[a] = Post.snapshot_stage

ValidateCopyPost(a) ==
    /\ Has({"snapshot_present", "snapshot_stage"})
    /\ snapshotPresent'[a] = Post.snapshot_present
    /\ snapshotStage'[a] = Post.snapshot_stage

ValidateDecisionPost ==
    /\ Has({"global_decision", "selected_epoch"})
    /\ globalDecision' = Post.global_decision
    /\ selectedEpoch' = Post.selected_epoch

ValidateLoadPost(a) ==
    /\ Has({"snapshot_consumed", "snapshot_stage"})
    /\ snapshotConsumed'[a] = Post.snapshot_consumed
    /\ snapshotStage'[a] = Post.snapshot_stage

ValidateInitViewPost(a) ==
    /\ Has({"init_epoch"})
    /\ initEpoch'[a] = Post.init_epoch

ValidateApplyComparePost ==
    /\ Has({"apply_asic", "apply_epoch", "planned_ops", "op_cursor",
             "apply_state", "apply_dirty", "recovery_mode", "journal_state",
             "candidates", "matching"})
    /\ Vids \subseteq DOMAIN Post.matching
    /\ applyAsic' = Post.apply_asic
    /\ applyEpoch' = Post.apply_epoch
    /\ plannedOps' = SeqToSet(Post.planned_ops)
    /\ opCursor' = Post.op_cursor
    /\ applyState' = Post.apply_state
    /\ applyDirty' = Post.apply_dirty
    /\ recoveryMode' = Post.recovery_mode
    /\ journalState' = Post.journal_state
    /\ candidates' = PairSeqToSet(Post.candidates)
    /\ \A v \in Vids : matching'[v] = Post.matching[v]

ValidateMatchingPost(v) ==
    /\ Has({"matching_rid"})
    /\ matching'[v] = Post.matching_rid

ValidateApplyStatePost ==
    /\ Has({"apply_state"})
    /\ applyState' = Post.apply_state

ValidateExecuteOpPost ==
    /\ Has({"op_cursor", "hardware_view", "apply_dirty", "journal_state"})
    /\ opCursor' = Post.op_cursor
    /\ hardwareView' = SeqToSet(Post.hardware_view)
    /\ applyDirty' = Post.apply_dirty
    /\ journalState' = Post.journal_state

ValidateRemoveDbPost ==
    /\ Has({"db_view", "apply_state", "apply_dirty"})
    /\ dbView' = SeqToSet(Post.db_view)
    /\ applyState' = Post.apply_state
    /\ applyDirty' = Post.apply_dirty

ValidateCreateObjectPost ==
    /\ Has({"db_view", "apply_dirty"})
    /\ dbView' = SeqToSet(Post.db_view)
    /\ applyDirty' = Post.apply_dirty

ValidateMapStagePost ==
    /\ Has({"apply_state", "map_stage"})
    /\ applyState' = Post.apply_state
    /\ mapStage' = Post.map_stage

ValidateDeleteVidMapPost ==
    /\ Has({"vid_to_rid", "apply_state", "map_stage"})
    /\ Vids \subseteq DOMAIN Post.vid_to_rid
    /\ \A v \in Vids : vidToRid'[v] = Post.vid_to_rid[v]
    /\ applyState' = Post.apply_state
    /\ mapStage' = Post.map_stage

ValidateDeleteRidMapPost ==
    /\ Has({"rid_to_vid", "map_pending", "map_half", "apply_state",
             "map_stage"})
    /\ Rids \subseteq DOMAIN Post.rid_to_vid
    /\ \A r \in Rids : ridToVid'[r] = Post.rid_to_vid[r]
    /\ mapPending' = SeqToSet(Post.map_pending)
    /\ mapHalf' = Post.map_half
    /\ applyState' = Post.apply_state
    /\ mapStage' = Post.map_stage

ValidateWriteVidMapPost(v) ==
    /\ Has({"mapped_rid", "map_half"})
    /\ vidToRid'[v] = Post.mapped_rid
    /\ mapHalf' = Post.map_half

ValidateWriteRidMapPost ==
    /\ Has({"rid", "mapped_vid", "map_pending", "map_half"})
    /\ Post.rid \in Rids
    /\ ridToVid'[Post.rid] = Post.mapped_vid
    /\ mapPending' = SeqToSet(Post.map_pending)
    /\ mapHalf' = Post.map_half

ValidateMapCompletePost ==
    /\ Has({"apply_state", "map_stage"})
    /\ applyState' = Post.apply_state
    /\ mapStage' = Post.map_stage

ValidateCommitPost ==
    /\ Has({"apply_state", "apply_dirty", "journal_state"})
    /\ applyState' = Post.apply_state
    /\ applyDirty' = Post.apply_dirty
    /\ journalState' = Post.journal_state

ValidateCrashPost ==
    /\ Has({"apply_state", "apply_dirty", "journal_state"})
    /\ applyState' = Post.apply_state
    /\ applyDirty' = Post.apply_dirty
    /\ journalState' = Post.journal_state

ValidateJournalResumePost ==
    /\ Has({"recovery_mode", "hardware_view", "db_view", "vid_to_rid",
             "rid_to_vid", "map_stage", "map_pending", "map_half",
             "apply_state", "apply_dirty", "journal_state"})
    /\ Vids \subseteq DOMAIN Post.vid_to_rid
    /\ Rids \subseteq DOMAIN Post.rid_to_vid
    /\ recoveryMode' = Post.recovery_mode
    /\ hardwareView' = SeqToSet(Post.hardware_view)
    /\ dbView' = SeqToSet(Post.db_view)
    /\ \A v \in Vids : vidToRid'[v] = Post.vid_to_rid[v]
    /\ \A r \in Rids : ridToVid'[r] = Post.rid_to_vid[r]
    /\ mapStage' = Post.map_stage
    /\ mapPending' = SeqToSet(Post.map_pending)
    /\ mapHalf' = Post.map_half
    /\ applyState' = Post.apply_state
    /\ applyDirty' = Post.apply_dirty
    /\ journalState' = Post.journal_state

ValidateUnsafeRecoveryPost ==
    /\ Has({"recovery_mode", "apply_state"})
    /\ recoveryMode' = Post.recovery_mode
    /\ applyState' = Post.apply_state

ValidateColdRecoveryPost ==
    /\ Has({"recovery_mode", "apply_state", "apply_dirty",
             "global_decision"})
    /\ recoveryMode' = Post.recovery_mode
    /\ applyState' = Post.apply_state
    /\ applyDirty' = Post.apply_dirty
    /\ globalDecision' = Post.global_decision

ValidateRestorationPost ==
    /\ Has({"cached_old", "terminal"})
    /\ cachedOld' = SeqToSet(Post.cached_old)
    /\ terminal'[FpmComponent] = Post.terminal

ValidateRefreshPost ==
    /\ Has({"refreshed_new"})
    /\ refreshedNew' = SeqToSet(Post.refreshed_new)

ValidateInputCompletePost ==
    /\ Has({"input_complete"})
    /\ inputComplete' = Post.input_complete

ValidateTimerPost ==
    /\ Has({"timer_expired"})
    /\ timerExpired' = Post.timer_expired

ValidateReconcilePost ==
    /\ Has({"derived_outputs", "output_buffered", "terminal"})
    /\ derivedOutputs' = SeqToSet(Post.derived_outputs)
    /\ outputBuffered' = SeqToSet(Post.output_buffered)
    /\ terminal'[FpmComponent] = Post.terminal

ValidateFlushPost ==
    /\ Has({"output_buffered", "output_published"})
    /\ outputBuffered' = SeqToSet(Post.output_buffered)
    /\ outputPublished' = SeqToSet(Post.output_published)

ValidateLateInputPost ==
    /\ Has({"refreshed_new", "output_buffered", "derived_outputs"})
    /\ refreshedNew' = SeqToSet(Post.refreshed_new)
    /\ outputBuffered' = SeqToSet(Post.output_buffered)
    /\ derivedOutputs' = SeqToSet(Post.derived_outputs)

ValidateComponentPost(comp) ==
    /\ Has({"terminal"})
    /\ terminal'[comp] = Post.terminal

ValidateFinalizerTimeoutPost ==
    /\ Has({"finalizer_timed_out"})
    /\ finalizerTimedOut' = Post.finalizer_timed_out

ValidateFinalizePost ==
    /\ Has({"flags_cleared", "flags"})
    /\ Components \subseteq DOMAIN Post.flags_cleared
    /\ {"warm", "fast", "epoch"} \subseteq DOMAIN Post.flags
    /\ \A comp \in Components : flagsCleared'[comp] = Post.flags_cleared[comp]
    /\ flags' = [warm |-> Post.flags.warm,
                  fast |-> Post.flags.fast,
                  epoch |-> Post.flags.epoch]

(**************************************************************************)
(* Logged wrappers: Scenario 1.                                           *)
(**************************************************************************)

FastRebootRequestIfLogged ==
    \E c \in Owners, kind \in RequestKinds :
        /\ IsOwnerEvent("FastReboot_Request", c)
        /\ "kind" \in DOMAIN logline.event
        /\ logline.event.kind = kind
        /\ B!FastReboot_Request(c, kind)
        /\ ValidateRequestPost(c)
        /\ StepTrace

CheckWarmRestartInProgressAdmitIfLogged ==
    \E c \in Owners :
        /\ IsOwnerEvent("CheckWarmRestartInProgress_Admit", c)
        /\ B!CheckWarmRestartInProgress_Admit(c)
        /\ ValidateCheckAdmitPost(c)
        /\ StepTrace

CheckWarmRestartInProgressRejectIfLogged ==
    \E c \in Owners :
        /\ IsOwnerEvent("CheckWarmRestartInProgress_Reject", c)
        /\ B!CheckWarmRestartInProgress_Reject(c)
        /\ ValidateRejectPost(c)
        /\ StepTrace

EnableWarmRestartIfLogged ==
    \E c \in Owners :
        /\ IsOwnerEvent("EnableWarmRestart", c)
        /\ B!EnableWarmRestart(c)
        /\ ValidateEnablePost(c)
        /\ StepTrace

ClearBootIfLogged ==
    \E c \in Owners :
        /\ IsOwnerEvent("ClearBoot", c)
        /\ B!ClearBoot(c)
        /\ ValidateClearBootPost(c)
        /\ StepTrace

FastRebootContinueAfterSignalIfLogged ==
    \E c \in Owners :
        /\ IsOwnerEvent("FastReboot_ContinueAfterSignal", c)
        /\ B!FastReboot_ContinueAfterSignal(c)
        /\ ValidateContinuePost(c)
        /\ StepTrace

FastRebootPauseOrchagentCompleteIfLogged ==
    \E c \in Owners :
        /\ IsOwnerEvent("FastReboot_PauseOrchagentComplete", c)
        /\ B!FastReboot_PauseOrchagentComplete(c)
        /\ ValidatePhasePost(c)
        /\ StepTrace

FastRebootBeginIrreversibleWorkIfLogged ==
    \E c \in Owners :
        /\ IsOwnerEvent("FastReboot_BeginIrreversibleWork", c)
        /\ B!FastReboot_BeginIrreversibleWork(c)
        /\ ValidateIrreversiblePost(c)
        /\ StepTrace

FastRebootRecordOutcomeIfLogged ==
    \E c \in Owners :
        /\ IsOwnerEvent("FastReboot_RecordOutcome", c)
        /\ B!FastReboot_RecordOutcome(c)
        /\ ValidateOutcomePost(c)
        /\ StepTrace

(**************************************************************************)
(* Logged wrappers: Scenario 2.                                           *)
(**************************************************************************)

ProducerEnqueueIfLogged ==
    \E p \in Producers :
        /\ IsProducerEvent("Producer_Enqueue", p)
        /\ B!Producer_Enqueue(p)
        /\ ValidateProducerPost(p)
        /\ StepTrace

ProducerDrainOneIfLogged ==
    \E p \in Producers :
        /\ IsProducerEvent("Producer_DrainOne", p)
        /\ B!Producer_DrainOne(p)
        /\ ValidateProducerPost(p)
        /\ StepTrace

OrchDaemonWarmRestartCheckIfLogged ==
    \E a \in Asics :
        /\ IsAsicEvent("OrchDaemon_WarmRestartCheck", a)
        /\ B!OrchDaemon_WarmRestartCheck(a)
        /\ ValidateReadyPost(a)
        /\ StepTrace

OrchagentRestartCheckConsumeReplyIfLogged ==
    \E a \in Asics :
        /\ IsAsicEvent("OrchagentRestartCheck_ConsumeReply", a)
        /\ B!OrchagentRestartCheck_ConsumeReply(a)
        /\ ValidateReplyConsumedPost(a)
        /\ StepTrace

PauseOrchagentIgnoreFailureIfLogged ==
    \E a \in Asics :
        /\ IsAsicEvent("PauseOrchagent_IgnoreFailure", a)
        /\ B!PauseOrchagent_IgnoreFailure(a)
        /\ ValidateReplyConsumedPost(a)
        /\ StepTrace

OrchDaemonDrainRingIfLogged ==
    \E a \in Asics :
        /\ IsAsicEvent("OrchDaemon_DrainRing", a)
        /\ B!OrchDaemon_DrainRing(a)
        /\ ValidateRingDrainPost(a)
        /\ StepTrace

OrchDaemonSetAgingFDBIfLogged ==
    \E a \in Asics :
        /\ IsAsicEvent("OrchDaemon_SetAgingFDB", a)
        /\ B!OrchDaemon_SetAgingFDB(a)
        /\ ValidatePostReadyStep(a)
        /\ StepTrace

OrchDaemonSetBridgePortLearningFDBIfLogged ==
    \E a \in Asics :
        /\ IsAsicEvent("OrchDaemon_SetBridgePortLearningFDB", a)
        /\ B!OrchDaemon_SetBridgePortLearningFDB(a)
        /\ ValidatePostReadyStep(a)
        /\ StepTrace

OrchDaemonFlushIfLogged ==
    \E a \in Asics :
        /\ IsAsicEvent("OrchDaemon_Flush", a)
        /\ B!OrchDaemon_Flush(a)
        /\ ValidatePostReadyStep(a)
        /\ StepTrace

OrchDaemonWarmRestartReplyAfterFlushIfLogged ==
    \E a \in Asics :
        /\ IsAsicEvent("OrchDaemon_WarmRestartReplyAfterFlush", a)
        /\ B!OrchDaemon_WarmRestartReplyAfterFlush(a)
        /\ ValidateReadyPost(a)
        /\ StepTrace

OrchDaemonFreezeAndHeartBeatIfLogged ==
    \E a \in Asics :
        /\ IsAsicEvent("OrchDaemon_FreezeAndHeartBeat", a)
        /\ B!OrchDaemon_FreezeAndHeartBeat(a)
        /\ ValidateFreezePost(a)
        /\ StepTrace

(**************************************************************************)
(* Logged wrappers: Scenario 3.                                           *)
(**************************************************************************)

StopSystemdServiceSuccessIfLogged ==
    \E a \in Asics :
        /\ IsAsicEvent("StopSystemdService_Success", a)
        /\ B!StopSystemdService_Success(a)
        /\ ValidateStopPost(a)
        /\ StepTrace

StopSystemdServiceMaskedFailureIfLogged ==
    \E a \in Asics :
        /\ IsAsicEvent("StopSystemdService_MaskedFailure", a)
        /\ B!StopSystemdService_MaskedFailure(a)
        /\ ValidateStopPost(a)
        /\ StepTrace

SyncdPerformWarmShutdownIfLogged ==
    \E a \in Asics :
        /\ IsAsicEvent("Syncd_PerformWarmShutdown", a)
        /\ B!Syncd_PerformWarmShutdown(a)
        /\ ValidateShutdownModePost(a)
        /\ StepTrace

SyncdDowngradeWarmShutdownIfLogged ==
    \E a \in Asics :
        /\ IsAsicEvent("Syncd_DowngradeWarmShutdown", a)
        /\ B!Syncd_DowngradeWarmShutdown(a)
        /\ ValidateShutdownModePost(a)
        /\ StepTrace

CentralizeDatabaseRedisSaveIfLogged ==
    \E a \in Asics :
        /\ IsAsicEvent("CentralizeDatabase_RedisSave", a)
        /\ B!CentralizeDatabase_RedisSave(a)
        /\ ValidateSavePost(a)
        /\ StepTrace

BackupDatabaseDockerCopyIfLogged ==
    \E a \in Asics :
        /\ IsAsicEvent("BackupDatabase_DockerCopy", a)
        /\ B!BackupDatabase_DockerCopy(a)
        /\ ValidateCopyPost(a)
        /\ StepTrace

FastRebootAggregateWarmDecisionIfLogged ==
    /\ IsEvent("FastReboot_AggregateWarmDecision")
    /\ B!FastReboot_AggregateWarmDecision
    /\ ValidateDecisionPost
    /\ StepTrace

FastRebootAggregateColdDecisionIfLogged ==
    /\ IsEvent("FastReboot_AggregateColdDecision")
    /\ B!FastReboot_AggregateColdDecision
    /\ ValidateDecisionPost
    /\ StepTrace

DockerImageCtlPreStartActionIfLogged ==
    \E a \in Asics :
        /\ IsAsicEvent("DockerImageCtl_PreStartAction", a)
        /\ B!DockerImageCtl_PreStartAction(a)
        /\ ValidateLoadPost(a)
        /\ StepTrace

(**************************************************************************)
(* Logged wrappers: Scenarios 4-5.                                        *)
(**************************************************************************)

SyncdProcessNotifySyncdInitViewIfLogged ==
    \E a \in Asics :
        /\ IsAsicEvent("Syncd_ProcessNotifySyncdInitView", a)
        /\ B!Syncd_ProcessNotifySyncdInitView(a)
        /\ ValidateInitViewPost(a)
        /\ StepTrace

SyncdApplyViewCompareIfLogged ==
    \E a \in Asics :
        /\ IsAsicEvent("Syncd_ApplyViewCompare", a)
        /\ B!Syncd_ApplyViewCompare(a)
        /\ ValidateApplyComparePost
        /\ StepTrace

BestCandidateFinderSelectRandomCandidateIfLogged ==
    \E v \in Vids, r \in Rids :
        /\ IsEvent("BestCandidateFinder_SelectRandomCandidate")
        /\ "vid" \in DOMAIN logline.event
        /\ "rid" \in DOMAIN logline.event
        /\ logline.event.vid = v
        /\ logline.event.rid = r
        /\ B!BestCandidateFinder_SelectRandomCandidate(v, r)
        /\ ValidateMatchingPost(v)
        /\ StepTrace

ComparisonLogicCompareViewsCompleteIfLogged ==
    /\ IsEvent("ComparisonLogic_CompareViewsComplete")
    /\ B!ComparisonLogic_CompareViewsComplete
    /\ ValidateApplyStatePost
    /\ StepTrace

ComparisonLogicExecuteOperationsOnAsicIfLogged ==
    /\ IsEvent("ComparisonLogic_ExecuteOperationsOnAsic")
    /\ B!ComparisonLogic_ExecuteOperationsOnAsic
    /\ ValidateExecuteOpPost
    /\ StepTrace

SyncdApplyViewBeginRedisUpdateIfLogged ==
    /\ IsEvent("Syncd_ApplyViewBeginRedisUpdate")
    /\ B!Syncd_ApplyViewBeginRedisUpdate
    /\ ValidateApplyStatePost
    /\ StepTrace

RedisClientRemoveAsicStateTableIfLogged ==
    /\ IsEvent("RedisClient_RemoveAsicStateTable")
    /\ B!RedisClient_RemoveAsicStateTable
    /\ ValidateRemoveDbPost
    /\ StepTrace

RedisClientRemoveTempAsicStateTableIfLogged ==
    /\ IsEvent("RedisClient_RemoveTempAsicStateTable")
    /\ B!RedisClient_RemoveTempAsicStateTable
    /\ ValidateApplyStatePost
    /\ StepTrace

RedisClientCreateAsicObjectIfLogged ==
    \E op \in ApplyOps :
        /\ IsEvent("RedisClient_CreateAsicObject")
        /\ "op" \in DOMAIN logline.event
        /\ logline.event.op = op
        /\ B!RedisClient_CreateAsicObject(op)
        /\ ValidateCreateObjectPost
        /\ StepTrace

SyncdUpdateRedisDatabaseBeginMapsIfLogged ==
    /\ IsEvent("Syncd_UpdateRedisDatabaseBeginMaps")
    /\ B!Syncd_UpdateRedisDatabaseBeginMaps
    /\ ValidateMapStagePost
    /\ StepTrace

RedisClientSetVidAndRidMapDeleteVidToRidIfLogged ==
    /\ IsEvent("RedisClient_SetVidAndRidMapDeleteVidToRid")
    /\ B!RedisClient_SetVidAndRidMapDeleteVidToRid
    /\ ValidateDeleteVidMapPost
    /\ StepTrace

RedisClientSetVidAndRidMapDeleteRidToVidIfLogged ==
    /\ IsEvent("RedisClient_SetVidAndRidMapDeleteRidToVid")
    /\ B!RedisClient_SetVidAndRidMapDeleteRidToVid
    /\ ValidateDeleteRidMapPost
    /\ StepTrace

RedisClientSetVidAndRidMapWriteVidToRidIfLogged ==
    \E v \in Vids :
        /\ IsEvent("RedisClient_SetVidAndRidMapWriteVidToRid")
        /\ "vid" \in DOMAIN logline.event
        /\ logline.event.vid = v
        /\ B!RedisClient_SetVidAndRidMapWriteVidToRid(v)
        /\ ValidateWriteVidMapPost(v)
        /\ StepTrace

RedisClientSetVidAndRidMapWriteRidToVidIfLogged ==
    /\ IsEvent("RedisClient_SetVidAndRidMapWriteRidToVid")
    /\ B!RedisClient_SetVidAndRidMapWriteRidToVid
    /\ ValidateWriteRidMapPost
    /\ StepTrace

SyncdUpdateRedisDatabaseCompleteIfLogged ==
    /\ IsEvent("Syncd_UpdateRedisDatabaseComplete")
    /\ B!Syncd_UpdateRedisDatabaseComplete
    /\ ValidateMapCompletePost
    /\ StepTrace

SyncdApplyViewCommitIfLogged ==
    /\ IsEvent("Syncd_ApplyViewCommit")
    /\ B!Syncd_ApplyViewCommit
    /\ ValidateCommitPost
    /\ StepTrace

SyncdCrashDuringApplyIfLogged ==
    /\ IsEvent("Syncd_CrashDuringApply")
    /\ B!Syncd_CrashDuringApply
    /\ ValidateCrashPost
    /\ StepTrace

SyncdResumeFromDurableJournalIfLogged ==
    /\ IsEvent("Syncd_ResumeFromDurableJournal")
    /\ B!Syncd_ResumeFromDurableJournal
    /\ ValidateJournalResumePost
    /\ StepTrace

SyncdAcceptDirtyWarmRecoveryIfLogged ==
    /\ IsEvent("Syncd_AcceptDirtyWarmRecovery")
    /\ B!Syncd_AcceptDirtyWarmRecovery
    /\ ValidateUnsafeRecoveryPost
    /\ StepTrace

SyncdForceColdRecoveryIfLogged ==
    /\ IsEvent("Syncd_ForceColdRecovery")
    /\ B!Syncd_ForceColdRecovery
    /\ ValidateColdRecoveryPost
    /\ StepTrace

(**************************************************************************)
(* Logged wrappers: Scenario 6.                                           *)
(**************************************************************************)

WarmStartHelperRunRestorationIfLogged ==
    /\ IsEvent("WarmStartHelper_RunRestoration")
    /\ B!WarmStartHelper_RunRestoration
    /\ ValidateRestorationPost
    /\ StepTrace

WarmStartHelperInsertRefreshMapIfLogged ==
    \E r \in Routes :
        /\ IsEvent("WarmStartHelper_InsertRefreshMap")
        /\ "route" \in DOMAIN logline.event
        /\ logline.event.route = r
        /\ B!WarmStartHelper_InsertRefreshMap(r)
        /\ ValidateRefreshPost
        /\ StepTrace

FpmSyncdEoiuInputCompleteIfLogged ==
    /\ IsEvent("FpmSyncd_EoiuInputComplete")
    /\ B!FpmSyncd_EoiuInputComplete
    /\ ValidateInputCompletePost
    /\ StepTrace

FpmSyncdWarmRestartTimerExpiredIfLogged ==
    /\ IsEvent("FpmSyncd_WarmRestartTimerExpired")
    /\ B!FpmSyncd_WarmRestartTimerExpired
    /\ ValidateTimerPost
    /\ StepTrace

RouteSyncOnWarmStartEndIfLogged ==
    /\ IsEvent("RouteSync_OnWarmStartEnd")
    /\ B!RouteSync_OnWarmStartEnd
    /\ ValidateReconcilePost
    /\ StepTrace

FpmSyncdPipelineFlushIfLogged ==
    /\ IsEvent("FpmSyncd_PipelineFlush")
    /\ B!FpmSyncd_PipelineFlush
    /\ ValidateFlushPost
    /\ StepTrace

WarmStartHelperLateInputIfLogged ==
    \E r \in Routes :
        /\ IsEvent("WarmStartHelper_LateInput")
        /\ "route" \in DOMAIN logline.event
        /\ logline.event.route = r
        /\ B!WarmStartHelper_LateInput(r)
        /\ ValidateLateInputPost
        /\ StepTrace

ComponentPublishTerminalIfLogged ==
    \E comp \in Components :
        /\ IsComponentEvent("Component_PublishTerminal", comp)
        /\ B!Component_PublishTerminal(comp)
        /\ ValidateComponentPost(comp)
        /\ StepTrace

ComponentPublishFailureIfLogged ==
    \E comp \in Components :
        /\ IsComponentEvent("Component_PublishFailure", comp)
        /\ B!Component_PublishFailure(comp)
        /\ ValidateComponentPost(comp)
        /\ StepTrace

FinalizeWarmbootWaitTimeoutIfLogged ==
    /\ IsEvent("FinalizeWarmboot_WaitTimeout")
    /\ B!FinalizeWarmboot_WaitTimeout
    /\ ValidateFinalizerTimeoutPost
    /\ StepTrace

FinalizeWarmbootFinalizeGlobalIfLogged ==
    /\ IsEvent("FinalizeWarmboot_FinalizeGlobal")
    /\ B!FinalizeWarmboot_FinalizeGlobal
    /\ ValidateFinalizePost
    /\ StepTrace

(**************************************************************************)
(* Main transition. No silent protocol actions are needed: the required    *)
(* instrumentation exposes every base action boundary. The only stutter is *)
(* tightly constrained to an already-consumed trace.                       *)
(**************************************************************************)

TraceDone ==
    /\ l > Len(TraceLog)
    /\ UNCHANGED <<vars, l>>

TraceNext ==
    \/ FastRebootRequestIfLogged
    \/ CheckWarmRestartInProgressAdmitIfLogged
    \/ CheckWarmRestartInProgressRejectIfLogged
    \/ EnableWarmRestartIfLogged
    \/ ClearBootIfLogged
    \/ FastRebootContinueAfterSignalIfLogged
    \/ FastRebootPauseOrchagentCompleteIfLogged
    \/ FastRebootBeginIrreversibleWorkIfLogged
    \/ FastRebootRecordOutcomeIfLogged
    \/ ProducerEnqueueIfLogged
    \/ ProducerDrainOneIfLogged
    \/ OrchDaemonWarmRestartCheckIfLogged
    \/ OrchagentRestartCheckConsumeReplyIfLogged
    \/ PauseOrchagentIgnoreFailureIfLogged
    \/ OrchDaemonDrainRingIfLogged
    \/ OrchDaemonSetAgingFDBIfLogged
    \/ OrchDaemonSetBridgePortLearningFDBIfLogged
    \/ OrchDaemonFlushIfLogged
    \/ OrchDaemonWarmRestartReplyAfterFlushIfLogged
    \/ OrchDaemonFreezeAndHeartBeatIfLogged
    \/ StopSystemdServiceSuccessIfLogged
    \/ StopSystemdServiceMaskedFailureIfLogged
    \/ SyncdPerformWarmShutdownIfLogged
    \/ SyncdDowngradeWarmShutdownIfLogged
    \/ CentralizeDatabaseRedisSaveIfLogged
    \/ BackupDatabaseDockerCopyIfLogged
    \/ FastRebootAggregateWarmDecisionIfLogged
    \/ FastRebootAggregateColdDecisionIfLogged
    \/ DockerImageCtlPreStartActionIfLogged
    \/ SyncdProcessNotifySyncdInitViewIfLogged
    \/ SyncdApplyViewCompareIfLogged
    \/ BestCandidateFinderSelectRandomCandidateIfLogged
    \/ ComparisonLogicCompareViewsCompleteIfLogged
    \/ ComparisonLogicExecuteOperationsOnAsicIfLogged
    \/ SyncdApplyViewBeginRedisUpdateIfLogged
    \/ RedisClientRemoveAsicStateTableIfLogged
    \/ RedisClientRemoveTempAsicStateTableIfLogged
    \/ RedisClientCreateAsicObjectIfLogged
    \/ SyncdUpdateRedisDatabaseBeginMapsIfLogged
    \/ RedisClientSetVidAndRidMapDeleteVidToRidIfLogged
    \/ RedisClientSetVidAndRidMapDeleteRidToVidIfLogged
    \/ RedisClientSetVidAndRidMapWriteVidToRidIfLogged
    \/ RedisClientSetVidAndRidMapWriteRidToVidIfLogged
    \/ SyncdUpdateRedisDatabaseCompleteIfLogged
    \/ SyncdApplyViewCommitIfLogged
    \/ SyncdCrashDuringApplyIfLogged
    \/ SyncdResumeFromDurableJournalIfLogged
    \/ SyncdAcceptDirtyWarmRecoveryIfLogged
    \/ SyncdForceColdRecoveryIfLogged
    \/ WarmStartHelperRunRestorationIfLogged
    \/ WarmStartHelperInsertRefreshMapIfLogged
    \/ FpmSyncdEoiuInputCompleteIfLogged
    \/ FpmSyncdWarmRestartTimerExpiredIfLogged
    \/ RouteSyncOnWarmStartEndIfLogged
    \/ FpmSyncdPipelineFlushIfLogged
    \/ WarmStartHelperLateInputIfLogged
    \/ ComponentPublishTerminalIfLogged
    \/ ComponentPublishFailureIfLogged
    \/ FinalizeWarmbootWaitTimeoutIfLogged
    \/ FinalizeWarmbootFinalizeGlobalIfLogged
    \/ TraceDone

TraceInit ==
    /\ B!Init
    /\ l = 1

TraceSpec ==
    /\ TraceInit
    /\ [][TraceNext]_traceAllVars
    /\ WF_traceAllVars(TraceNext)

TraceMatched == <>(l > Len(TraceLog))

TraceView == <<vars, l>>

TraceAlias ==
    [cursor |-> l,
     length |-> Len(TraceLog),
     event  |-> IF l <= Len(TraceLog) THEN logline.event.name ELSE "DONE",
     epoch  |-> epoch,
     owner  |-> owner,
     phase  |-> phase,
     ready  |-> readySent,
     snapshot |-> snapshotStage,
     apply  |-> applyState,
     terminal |-> terminal]

=============================================================================
