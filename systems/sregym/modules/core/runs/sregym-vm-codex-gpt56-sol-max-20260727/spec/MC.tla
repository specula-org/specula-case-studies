------------------------------- MODULE MC -------------------------------
(*
 * Counter-bounded model-checking wrapper for SREGym.
 *
 * Only actions that introduce an external/fault choice are bounded. Reactive
 * implementation steps (acceptance, evaluation completion, stage advancement,
 * cleanup, reconciliation, and late-effect completion) remain unbounded.
 *)

EXTENDS base

\* Qualified access to the un-overridden base operators.
sregym == INSTANCE base

CONSTANTS
    MaxRunStartLimit,
    MaxSubmissionLimit,
    MaxDuplicateLimit,
    MaxRetryLimit,
    MaxTimeoutLimit,
    MaxExitLimit,
    MaxBaselineFailureLimit,
    MaxMutationLimit,
    MaxMitigationLimit,
    MaxCrashLimit,
    MaxClusterReplaceLimit,
    MaxNoiseApplyLimit,
    MaxJoinTimeoutLimit,
    MaxPodRestartLimit,
    MaxMessageBufferLimit

VARIABLE faultCounters

faultVars == <<faultCounters>>
mcVars == <<vars, faultVars>>

CounterRecord ==
    [runStart        : 0..MaxRunStartLimit,
     submission      : 0..MaxSubmissionLimit,
     duplicate       : 0..MaxDuplicateLimit,
     retry           : 0..MaxRetryLimit,
     timeout         : 0..MaxTimeoutLimit,
     exit            : 0..MaxExitLimit,
     baselineFailure : 0..MaxBaselineFailureLimit,
     mutation        : 0..MaxMutationLimit,
     mitigation      : 0..MaxMitigationLimit,
     crash           : 0..MaxCrashLimit,
     clusterReplace  : 0..MaxClusterReplaceLimit,
     noiseApply      : 0..MaxNoiseApplyLimit,
     joinTimeout     : 0..MaxJoinTimeoutLimit,
     podRestart      : 0..MaxPodRestartLimit]

\* Reactive actions preserve the complete counter record.
Unbounded(A) == /\ A /\ UNCHANGED faultVars

\* -------------------------------------------------------------------------
\* Counter-bounded external/fault actions
\* -------------------------------------------------------------------------

MCStartProblem ==
    /\ faultCounters.runStart < MaxRunStartLimit
    /\ sregym!StartProblem
    /\ faultCounters' =
        [faultCounters EXCEPT !.runStart = @ + 1]

MCSendSubmission(req) ==
    /\ faultCounters.submission < MaxSubmissionLimit
    /\ sregym!SendSubmission(req)
    /\ faultCounters' =
        [faultCounters EXCEPT !.submission = @ + 1]

MCDelayOrDuplicate(k) ==
    /\ faultCounters.duplicate < MaxDuplicateLimit
    /\ sregym!DelayOrDuplicate(k)
    /\ faultCounters' =
        [faultCounters EXCEPT !.duplicate = @ + 1]

MCRetrySubmission(k) ==
    /\ faultCounters.retry < MaxRetryLimit
    /\ sregym!RetrySubmission(k)
    /\ faultCounters' =
        [faultCounters EXCEPT !.retry = @ + 1]

MCAgentTimeout ==
    /\ faultCounters.timeout < MaxTimeoutLimit
    /\ sregym!AgentTimeout
    /\ faultCounters' =
        [faultCounters EXCEPT !.timeout = @ + 1]

MCAgentExit ==
    /\ faultCounters.exit < MaxExitLimit
    /\ sregym!AgentExit
    /\ faultCounters' =
        [faultCounters EXCEPT !.exit = @ + 1]

MCAgentExitWaitTimeout ==
    /\ faultCounters.exit < MaxExitLimit
    /\ sregym!AgentExitWaitTimeout
    /\ faultCounters' =
        [faultCounters EXCEPT !.exit = @ + 1]

MCObserveBaseline(field, ok) ==
    IF ok
    THEN Unbounded(sregym!ObserveBaseline(field, TRUE))
    ELSE
        /\ faultCounters.baselineFailure < MaxBaselineFailureLimit
        /\ sregym!ObserveBaseline(field, FALSE)
        /\ faultCounters' =
            [faultCounters EXCEPT !.baselineFailure = @ + 1]

MCAgentMutate(resource, kind) ==
    /\ faultCounters.mutation < MaxMutationLimit
    /\ sregym!AgentMutate(resource, kind)
    /\ faultCounters' =
        [faultCounters EXCEPT !.mutation = @ + 1]

MCAgentMitigate ==
    /\ faultCounters.mitigation < MaxMitigationLimit
    /\ sregym!AgentMitigate
    /\ faultCounters' =
        [faultCounters EXCEPT !.mitigation = @ + 1]

MCCrash ==
    /\ faultCounters.crash < MaxCrashLimit
    /\ sregym!Crash
    /\ faultCounters' =
        [faultCounters EXCEPT !.crash = @ + 1]

MCReplaceCluster ==
    /\ faultCounters.clusterReplace < MaxClusterReplaceLimit
    /\ sregym!ReplaceCluster
    /\ faultCounters' =
        [faultCounters EXCEPT !.clusterReplace = @ + 1]

MCBeginNoiseApply ==
    /\ faultCounters.noiseApply < MaxNoiseApplyLimit
    /\ sregym!BeginNoiseApply
    /\ faultCounters' =
        [faultCounters EXCEPT !.noiseApply = @ + 1]

MCNoiseManagerJoinTimeout ==
    /\ faultCounters.joinTimeout < MaxJoinTimeoutLimit
    /\ sregym!NoiseManagerJoinTimeout
    /\ faultCounters' =
        [faultCounters EXCEPT !.joinTimeout = @ + 1]

MCRestartPod ==
    /\ faultCounters.podRestart < MaxPodRestartLimit
    /\ sregym!RestartPod
    /\ faultCounters' =
        [faultCounters EXCEPT !.podRestart = @ + 1]

\* -------------------------------------------------------------------------
\* MC initial state and next-state relation
\* -------------------------------------------------------------------------

MCInit ==
    /\ sregym!Init
    /\ faultCounters =
        [runStart        |-> 0,
         submission      |-> 0,
         duplicate       |-> 0,
         retry           |-> 0,
         timeout         |-> 0,
         exit            |-> 0,
         baselineFailure |-> 0,
         mutation        |-> 0,
         mitigation      |-> 0,
         crash           |-> 0,
         clusterReplace  |-> 0,
         noiseApply      |-> 0,
         joinTimeout     |-> 0,
         podRestart      |-> 0]

MCNext ==
    \* Bounded external/fault choices.
    \/ MCStartProblem
    \/ \E req \in RequestIds : MCSendSubmission(req)
    \/ \E k \in 1..Len(submissionQueue) : MCDelayOrDuplicate(k)
    \/ \E k \in 1..Len(receivedQueue) : MCRetrySubmission(k)
    \/ MCAgentTimeout
    \/ MCAgentExit
    \/ MCAgentExitWaitTimeout
    \/ \E field \in BaselineFields, ok \in BOOLEAN :
        MCObserveBaseline(field, ok)
    \/ \E resource \in Resources, kind \in MutationKinds :
        MCAgentMutate(resource, kind)
    \/ MCAgentMitigate
    \/ MCCrash
    \/ MCReplaceCluster
    \/ MCBeginNoiseApply
    \/ MCNoiseManagerJoinTimeout
    \/ MCRestartPod

    \* Unbounded deterministic/reactive implementation steps.
    \/ Unbounded(sregym!LoadBaselineState)
    \/ Unbounded(sregym!BeginBaselineCapture)
    \/ Unbounded(sregym!PersistBaselineState)
    \/ Unbounded(sregym!DeployProblem)
    \/ Unbounded(sregym!InjectFault)
    \/ Unbounded(sregym!AdvanceToFirstStage)
    \/ \E k \in 1..Len(submissionQueue) :
        Unbounded(sregym!ReceiveSubmission(k))
    \/ \E k \in 1..Len(receivedQueue) :
        Unbounded(sregym!ConductorSubmitAccept(k))
    \/ \E k \in 1..Len(receivedQueue) :
        Unbounded(sregym!ConductorSubmitDuplicate(k))
    \/ \E k \in 1..Len(receivedQueue) :
        Unbounded(sregym!ConductorSubmitLate(k))
    \/ Unbounded(sregym!Acknowledge)
    \/ Unbounded(sregym!BeginEvaluation)
    \/ Unbounded(sregym!BeginOracle)
    \/ Unbounded(sregym!CompleteOracle)
    \/ Unbounded(sregym!CompleteEvaluation)
    \/ Unbounded(sregym!AdvanceStageAfterEvaluation)
    \/ Unbounded(sregym!FinishEvaluationFuture)
    \/ Unbounded(sregym!AgentExitAfterEvaluation)
    \/ \E actor \in CleanupActors :
        Unbounded(sregym!FinishProblemCheck(actor))
    \/ \E actor \in CleanupActors :
        Unbounded(sregym!BeginCleanup(actor))
    \/ \E actor \in CleanupActors :
        Unbounded(sregym!CompleteRecovery(actor))
    \/ \E actor \in CleanupActors, resource \in Resources :
        Unbounded(sregym!ReconcileDelete(actor, resource))
    \/ \E actor \in CleanupActors, resource \in Resources :
        Unbounded(sregym!ReconcileRestore(actor, resource))
    \/ \E actor \in CleanupActors :
        Unbounded(sregym!CompleteCleanup(actor))
    \/ Unbounded(sregym!NoiseManagerStart)
    \/ \E epoch \in 1..MaxNoiseEpoch :
        Unbounded(sregym!CompleteNoiseApply(epoch))
    \/ \E epoch \in 1..MaxNoiseEpoch :
        Unbounded(sregym!NoiseLoopExit(epoch))
    \/ \E owner \in NoiseStopOwners \ {"none"} :
        Unbounded(sregym!NoiseManagerStop(owner))
    \/ Unbounded(sregym!NoiseManagerJoinComplete)
    \/ Unbounded(sregym!NoiseManagerCleanupRecorded)
    \/ Unbounded(sregym!NoiseManagerForceRemove)
    \/ Unbounded(sregym!NoiseManagerStopReturn)
    \/ Unbounded(sregym!Restart)
    \/ Unbounded(sregym!ReattachFault)

MCSpec == MCInit /\ [][MCNext]_mcVars

\* -------------------------------------------------------------------------
\* Symmetry, view, state-space constraints, and structural checks
\* -------------------------------------------------------------------------

Symmetry == Permutations(RequestIds)

\* Counter values are excluded from the semantic state view, as they are only
\* search bounds and not implementation state.
ModelView == vars

MessageBufferConstraint ==
    Len(submissionQueue) + Len(receivedQueue) + Len(pendingAcks)
        <= MaxMessageBufferLimit

MCTypeOK ==
    /\ TypeOK
    /\ faultCounters \in CounterRecord

CounterBounds ==
    /\ faultCounters.runStart <= MaxRunStartLimit
    /\ faultCounters.submission <= MaxSubmissionLimit
    /\ faultCounters.duplicate <= MaxDuplicateLimit
    /\ faultCounters.retry <= MaxRetryLimit
    /\ faultCounters.timeout <= MaxTimeoutLimit
    /\ faultCounters.exit <= MaxExitLimit
    /\ faultCounters.baselineFailure <= MaxBaselineFailureLimit
    /\ faultCounters.mutation <= MaxMutationLimit
    /\ faultCounters.mitigation <= MaxMitigationLimit
    /\ faultCounters.crash <= MaxCrashLimit
    /\ faultCounters.clusterReplace <= MaxClusterReplaceLimit
    /\ faultCounters.noiseApply <= MaxNoiseApplyLimit
    /\ faultCounters.joinTimeout <= MaxJoinTimeoutLimit
    /\ faultCounters.podRestart <= MaxPodRestartLimit

=============================================================================
