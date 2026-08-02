----------------------------- MODULE Trace -----------------------------
(*
 * Linear Category-A trace replay for SREGym.
 *
 * Every event invokes exactly one full base action. Instrumentation emits a
 * post-action abstract snapshot maintained by the trace shadow recorder;
 * ValidatePostState checks every base variable, not merely event feasibility.
 *)

EXTENDS base, Json, IOUtils, Sequences, FiniteSets, TLC

\* -------------------------------------------------------------------------
\* Trace loading
\* -------------------------------------------------------------------------

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

TraceLog ==
    TLCEval(
        LET all == ndJsonDeserialize(JsonFile)
        IN SelectSeq(all, LAMBDA x :
            /\ "tag" \in DOMAIN x
            /\ x.tag = "trace"
            /\ "event" \in DOMAIN x
            /\ "name" \in DOMAIN x.event
            /\ "params" \in DOMAIN x.event
            /\ "state" \in DOMAIN x.event))

ASSUME Len(TraceLog) > 0

VARIABLE l

traceVars == <<l>>
traceAllVars == <<vars, traceVars>>

logline == TraceLog[l]
Params == logline.event.params
Post == logline.event.state

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = name

StepTrace == l' = l + 1

SeqSet(xs) == {xs[k] : k \in 1..Len(xs)}
RunArray(xs) == [g \in RunIds |-> xs[g + 1]]
EpochArray(xs) == [e \in 0..MaxNoiseEpoch |-> xs[e + 1]]

\* Derive request IDs from parameterized transport/submission events.
TraceRequestIds ==
    TLCEval(
        LET ids ==
            UNION {
                IF "request_id" \in DOMAIN TraceLog[k].event.params
                THEN {TraceLog[k].event.params.request_id}
                ELSE {}
                : k \in 1..Len(TraceLog)
            }
        IN IF ids = {} THEN {"trace-default-request"} ELSE ids)

\* -------------------------------------------------------------------------
\* Mandatory strong post-state validation
\* -------------------------------------------------------------------------

ValidatePostState ==
    \* Process/run lifecycle.
    /\ processUp' = Post.process_up
    /\ runGen' = Post.run_gen
    /\ stage' = Post.stage
    /\ stageOwner' = Post.stage_owner
    /\ runStage' = RunArray(Post.run_stage)
    /\ maxStageRank' = RunArray(Post.max_stage_rank)
    /\ waitingForAgent' = Post.waiting_for_agent
    /\ deployedRun' = Post.deployed_run
    /\ timeoutFired' = SeqSet(Post.timeout_fired)
    /\ agentExitState' = Post.agent_exit_state
    /\ doneRuns' = SeqSet(Post.done_runs)
    /\ resultsVersion' = RunArray(Post.results_version)
    /\ doneResultsVersion' = RunArray(Post.done_results_version)

    \* Evaluation future and cleanup callers.
    /\ evalInFlight' = Post.eval_in_flight
    /\ evalRun' = Post.eval_run
    /\ evalStage' = Post.eval_stage
    /\ evalRequest' = Post.eval_request
    /\ evalOriginRun' = Post.eval_origin_run
    /\ evalOriginStage' = Post.eval_origin_stage
    /\ evalPhase' = Post.eval_phase
    /\ cleanupState' = Post.cleanup_state
    /\ cleanupRun' = Post.cleanup_run

    \* Transport, acceptance, grading, timeout, and acknowledgment.
    /\ submissionQueue' = Post.submission_queue
    /\ receivedQueue' = Post.received_queue
    /\ pendingAcks' = Post.pending_acks
    /\ acceptedByStage' = SeqSet(Post.accepted_by_stage)
    /\ gradedAcceptances' = SeqSet(Post.graded_acceptances)
    /\ timedOutAcceptances' = SeqSet(Post.timed_out_acceptances)
    /\ requestStatus' = Post.request_status
    /\ requestOriginRun' = Post.request_origin_run
    /\ requestOriginStage' = Post.request_origin_stage
    /\ requestRetries' = Post.request_retries

    \* Baseline projection plus shadow provenance.
    /\ clusterGen' = Post.cluster_gen
    /\ baselineGen' = Post.baseline_gen
    /\ baselineComplete' = Post.baseline_complete
    /\ observedFields' = SeqSet(Post.observed_fields)
    /\ baselineResources' = SeqSet(Post.baseline_resources)
    /\ baselineValues' = Post.baseline_values
    /\ baselineCaptureState' = Post.baseline_capture_state
    /\ baselineAuthoritative' = Post.baseline_authoritative
    /\ persistedBaseline' =
        [exists |-> Post.persisted_baseline.exists,
         resources |-> SeqSet(Post.persisted_baseline.resources),
         values |-> Post.persisted_baseline.values]
    /\ persistedBaselineGen' = Post.persisted_baseline_gen
    /\ persistedBaselineComplete' = Post.persisted_baseline_complete

    \* Abstract Kubernetes resources and reconciliation ledger.
    /\ clusterResources' = SeqSet(Post.cluster_resources)
    /\ preexisting' = SeqSet(Post.preexisting)
    /\ runCreated' = SeqSet(Post.run_created)
    /\ resourceValue' = Post.resource_value
    /\ preRunValue' = Post.pre_run_value
    /\ deleteIssued' = SeqSet(Post.delete_issued)

    \* Noise epochs and stop/join state.
    /\ noiseEpoch' = Post.noise_epoch
    /\ noiseRun' = Post.noise_run
    /\ noiseRunning' = Post.noise_running
    /\ liveNoiseEpochs' = SeqSet(Post.live_noise_epochs)
    /\ noiseEpochRun' = EpochArray(Post.noise_epoch_run)
    /\ noiseLoopCount' = Post.noise_loop_count
    /\ applyInFlight' = SeqSet(Post.apply_in_flight)
    /\ activeNoise' = SeqSet(Post.active_noise)
    /\ noiseStopState' = Post.noise_stop_state
    /\ noiseStopOwner' = Post.noise_stop_owner

    \* Intended fault, Khaos reattachment, and oracle state.
    /\ faultInjectedRuns' = SeqSet(Post.fault_injected_runs)
    /\ faultEffective' = RunArray(Post.fault_effective)
    /\ workloadHealthy' = RunArray(Post.workload_healthy)
    /\ podGen' = RunArray(Post.pod_gen)
    /\ reinjectionActive' = SeqSet(Post.reinjection_active)
    /\ reattachPending' = SeqSet(Post.reattach_pending)
    /\ oracleState' = Post.oracle_state
    /\ oracleRun' = Post.oracle_run
    /\ oracleStage' = Post.oracle_stage
    /\ oraclePassed' = SeqSet(Post.oracle_passed)
    /\ quiescenceObserved' = RunArray(Post.quiescence_observed)

Wrap(name, action) ==
    /\ IsEvent(name)
    /\ action
    /\ ValidatePostState
    /\ StepTrace

\* -------------------------------------------------------------------------
\* One wrapper per base action
\* -------------------------------------------------------------------------

TraceStartProblem ==
    Wrap("StartProblem", StartProblem)

TraceLoadBaselineState ==
    Wrap("LoadBaselineState", LoadBaselineState)

TraceBeginBaselineCapture ==
    Wrap("BeginBaselineCapture", BeginBaselineCapture)

TraceObserveBaseline ==
    Wrap("ObserveBaseline",
         ObserveBaseline(Params.field, Params.ok))

TracePersistBaselineState ==
    Wrap("PersistBaselineState", PersistBaselineState)

TraceDeployProblem ==
    Wrap("DeployProblem", DeployProblem)

TraceInjectFault ==
    Wrap("InjectFault", InjectFault)

TraceAdvanceToFirstStage ==
    Wrap("AdvanceToFirstStage", AdvanceToFirstStage)

TraceSendSubmission ==
    Wrap("SendSubmission",
         SendSubmission(Params.request_id))

TraceDelayOrDuplicate ==
    Wrap("DelayOrDuplicate",
         DelayOrDuplicate(Params.queue_index))

TraceReceiveSubmission ==
    Wrap("ReceiveSubmission",
         ReceiveSubmission(Params.queue_index))

TraceRetrySubmission ==
    Wrap("RetrySubmission",
         RetrySubmission(Params.queue_index))

TraceConductorSubmitAccept ==
    Wrap("ConductorSubmitAccept",
         ConductorSubmitAccept(Params.queue_index))

TraceConductorSubmitDuplicate ==
    Wrap("ConductorSubmitDuplicate",
         ConductorSubmitDuplicate(Params.queue_index))

TraceConductorSubmitLate ==
    Wrap("ConductorSubmitLate",
         ConductorSubmitLate(Params.queue_index))

TraceAcknowledge ==
    Wrap("Acknowledge", Acknowledge)

TraceBeginEvaluation ==
    Wrap("BeginEvaluation", BeginEvaluation)

TraceBeginOracle ==
    Wrap("BeginOracle", BeginOracle)

TraceCompleteOracle ==
    Wrap("CompleteOracle", CompleteOracle)

TraceCompleteEvaluation ==
    Wrap("CompleteEvaluation", CompleteEvaluation)

TraceAdvanceStageAfterEvaluation ==
    Wrap("AdvanceStageAfterEvaluation", AdvanceStageAfterEvaluation)

TraceFinishEvaluationFuture ==
    Wrap("FinishEvaluationFuture", FinishEvaluationFuture)

TraceAgentMitigate ==
    Wrap("AgentMitigate", AgentMitigate)

TraceAgentTimeout ==
    Wrap("AgentTimeout", AgentTimeout)

TraceAgentExit ==
    Wrap("AgentExit", AgentExit)

TraceAgentExitWaitTimeout ==
    Wrap("AgentExitWaitTimeout", AgentExitWaitTimeout)

TraceAgentExitAfterEvaluation ==
    Wrap("AgentExitAfterEvaluation", AgentExitAfterEvaluation)

TraceFinishProblemCheck ==
    Wrap("FinishProblemCheck",
         FinishProblemCheck(Params.actor))

TraceBeginCleanup ==
    Wrap("BeginCleanup",
         BeginCleanup(Params.actor))

TraceCompleteRecovery ==
    Wrap("CompleteRecovery",
         CompleteRecovery(Params.actor))

TraceReconcileDelete ==
    Wrap("ReconcileDelete",
         ReconcileDelete(Params.actor, Params.resource))

TraceReconcileRestore ==
    Wrap("ReconcileRestore",
         ReconcileRestore(Params.actor, Params.resource))

TraceCompleteCleanup ==
    Wrap("CompleteCleanup",
         CompleteCleanup(Params.actor))

TraceNoiseManagerStart ==
    Wrap("NoiseManagerStart", NoiseManagerStart)

TraceBeginNoiseApply ==
    Wrap("BeginNoiseApply", BeginNoiseApply)

TraceCompleteNoiseApply ==
    Wrap("CompleteNoiseApply",
         CompleteNoiseApply(Params.epoch))

TraceNoiseLoopExit ==
    Wrap("NoiseLoopExit",
         NoiseLoopExit(Params.epoch))

TraceNoiseManagerStop ==
    Wrap("NoiseManagerStop",
         NoiseManagerStop(Params.owner))

TraceNoiseManagerJoinComplete ==
    Wrap("NoiseManagerJoinComplete", NoiseManagerJoinComplete)

TraceNoiseManagerJoinTimeout ==
    Wrap("NoiseManagerJoinTimeout", NoiseManagerJoinTimeout)

TraceNoiseManagerCleanupRecorded ==
    Wrap("NoiseManagerCleanupRecorded", NoiseManagerCleanupRecorded)

TraceNoiseManagerForceRemove ==
    Wrap("NoiseManagerForceRemove", NoiseManagerForceRemove)

TraceNoiseManagerStopReturn ==
    Wrap("NoiseManagerStopReturn", NoiseManagerStopReturn)

TraceAgentMutate ==
    Wrap("AgentMutate",
         AgentMutate(Params.resource, Params.kind))

TraceCrash ==
    Wrap("Crash", Crash)

TraceRestart ==
    Wrap("Restart", Restart)

TraceReplaceCluster ==
    Wrap("ReplaceCluster", ReplaceCluster)

TraceRestartPod ==
    Wrap("RestartPod", RestartPod)

TraceReattachFault ==
    Wrap("ReattachFault", ReattachFault)

\* Every real semantic boundary has an event; no unconstrained silent action is
\* needed or permitted.
TraceNext ==
    \/ TraceStartProblem
    \/ TraceLoadBaselineState
    \/ TraceBeginBaselineCapture
    \/ TraceObserveBaseline
    \/ TracePersistBaselineState
    \/ TraceDeployProblem
    \/ TraceInjectFault
    \/ TraceAdvanceToFirstStage
    \/ TraceSendSubmission
    \/ TraceDelayOrDuplicate
    \/ TraceReceiveSubmission
    \/ TraceRetrySubmission
    \/ TraceConductorSubmitAccept
    \/ TraceConductorSubmitDuplicate
    \/ TraceConductorSubmitLate
    \/ TraceAcknowledge
    \/ TraceBeginEvaluation
    \/ TraceBeginOracle
    \/ TraceCompleteOracle
    \/ TraceCompleteEvaluation
    \/ TraceAdvanceStageAfterEvaluation
    \/ TraceFinishEvaluationFuture
    \/ TraceAgentMitigate
    \/ TraceAgentTimeout
    \/ TraceAgentExit
    \/ TraceAgentExitWaitTimeout
    \/ TraceAgentExitAfterEvaluation
    \/ TraceFinishProblemCheck
    \/ TraceBeginCleanup
    \/ TraceCompleteRecovery
    \/ TraceReconcileDelete
    \/ TraceReconcileRestore
    \/ TraceCompleteCleanup
    \/ TraceNoiseManagerStart
    \/ TraceBeginNoiseApply
    \/ TraceCompleteNoiseApply
    \/ TraceNoiseLoopExit
    \/ TraceNoiseManagerStop
    \/ TraceNoiseManagerJoinComplete
    \/ TraceNoiseManagerJoinTimeout
    \/ TraceNoiseManagerCleanupRecorded
    \/ TraceNoiseManagerForceRemove
    \/ TraceNoiseManagerStopReturn
    \/ TraceAgentMutate
    \/ TraceCrash
    \/ TraceRestart
    \/ TraceReplaceCluster
    \/ TraceRestartPod
    \/ TraceReattachFault
    \/ /\ l > Len(TraceLog)
       /\ UNCHANGED traceAllVars

TraceInit ==
    /\ Init
    /\ l = 1

TraceSpec ==
    /\ TraceInit
    /\ [][TraceNext]_traceAllVars
    \* Rule out infinite stuttering at an enabled, unconsumed event so that
    \* TraceMatched is a meaningful completion property.
    /\ WF_traceAllVars(TraceNext)

TraceMatched ==
    <>(l > Len(TraceLog))

TraceTypeOK ==
    /\ TypeOK
    /\ l \in 1..(Len(TraceLog) + 1)

TraceView == <<vars, l>>

TraceAlias ==
    [cursor |-> l,
     event |-> IF l <= Len(TraceLog)
              THEN TraceLog[l].event.name
              ELSE "TRACE_COMPLETE"]

=============================================================================
