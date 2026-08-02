------------------------------ MODULE base ------------------------------
(*
 * SREGym benchmark lifecycle model.
 *
 * Category A (distributed / message-passing): HTTP/MCP requests, executor
 * work, Kubernetes effects, persisted cluster state, and noise-manager work
 * progress independently.
 *
 * Scenario extensions:
 *   S1 -- run generations, evaluation/cleanup windows, completion ownership
 *   S2 -- submission envelopes, delay/duplicate/retry, generic acknowledgments
 *   S3 -- baseline provenance/completeness and asymmetric reconciliation
 *   S4 -- noise epochs, bounded join, oracle and reinjection windows
 *)

EXTENDS Naturals, Integers, Sequences, FiniteSets, TLC

CONSTANTS
    MaxRun,
    MaxClusterGen,
    MaxNoiseEpoch,
    MaxQueueLen,
    MaxRetries,
    MaxResultVersion,
    RequestIds,
    NoRequest

ASSUME
    /\ MaxRun \in Nat \ {0}
    /\ MaxClusterGen \in Nat
    /\ MaxNoiseEpoch \in Nat \ {0}
    /\ MaxQueueLen \in Nat \ {0}
    /\ MaxRetries \in Nat
    /\ MaxResultVersion \in Nat \ {0}
    /\ RequestIds /= {}
    /\ NoRequest \notin RequestIds

\* -------------------------------------------------------------------------
\* Finite domains
\* -------------------------------------------------------------------------

NoRun == -1
RunIds == 0..MaxRun
LiveRunIds == 1..MaxRun

IdleStage == "idle"
SetupStage == "setup"
DiagnosisStage == "diagnosis"
MitigationStage == "mitigation"
TeardownStage == "tearing_down"
DoneStage == "done"

Stages ==
    {IdleStage, SetupStage, DiagnosisStage, MitigationStage,
     TeardownStage, DoneStage}
AgentStages == {DiagnosisStage, MitigationStage}
EvalStages == AgentStages \cup {"none"}

StageRank(s) ==
    CASE s = IdleStage       -> 0
      [] s = SetupStage      -> 1
      [] s = DiagnosisStage  -> 2
      [] s = MitigationStage -> 3
      [] s = TeardownStage   -> 4
      [] s = DoneStage       -> 5
      [] OTHER               -> 6

NatMax(a, b) == IF a >= b THEN a ELSE b

CleanupActors == {"driver", "evaluator"}
CleanupStates ==
    {"idle", "requested", "checked", "stoppingNoise",
     "recovering", "reconciling", "complete"}
CleanupActiveStates == {"stoppingNoise", "recovering", "reconciling"}

EvalPhases ==
    {"idle", "accepted", "stoppingNoise", "oracleReady", "oracleRunning",
     "oracleComplete", "completed", "advanced"}

AgentExitStates == {"none", "waiting", "expired"}
RequestStates ==
    {"new", "queued", "received", "accepted", "discarded", "graded", "acked"}

NoiseStopStates == {"idle", "joining", "cleaning", "forceRemoving", "complete"}
NoiseStopOwners == {"none", "evaluation"} \cup CleanupActors

OracleStates == {"idle", "evaluating"}

BaselineFields == {"resources", "values"}
BaselineCaptureStates == {"unchecked", "capturing", "captured"}

PreResource == "preexisting-resource"
RunResource == "run-resource"
Resources == {PreResource, RunResource}

CleanValue == "clean"
ReplacementValue == "replacement"
AgentValue == "agent"
ResourceValues == {CleanValue, ReplacementValue, AgentValue}
MutationKinds == {"create", "overwrite", "delete"}

\* Scenario 2: the ideal envelope exists only in the model/trace shadow state;
\* conductor_api.py:23-53,110-148 sends only solution text to Conductor.submit.
SubmissionUniverse ==
    { [requestId  |-> r,
       originRun  |-> g,
       originStage |-> s]
      : r \in RequestIds, g \in LiveRunIds, s \in AgentStages }

AcceptanceUniverse ==
    { [requestId    |-> m.requestId,
       originRun    |-> m.originRun,
       originStage  |-> m.originStage,
       acceptedRun  |-> g,
       acceptedStage |-> s]
      : m \in SubmissionUniverse, g \in LiveRunIds, s \in AgentStages }

DeleteUniverse ==
    { [run |-> g, resource |-> r, owned |-> b]
      : g \in LiveRunIds, r \in Resources, b \in BOOLEAN }

BoundedSeq(S) ==
    UNION { [1..n -> S] : n \in 0..MaxQueueLen }

RemoveAt(s, k) ==
    [j \in 1..(Len(s) - 1) |-> IF j < k THEN s[j] ELSE s[j + 1]]

AcceptanceOf(m, g, s) ==
    [requestId     |-> m.requestId,
     originRun     |-> m.originRun,
     originStage   |-> m.originStage,
     acceptedRun   |-> g,
     acceptedStage |-> s]

PersistedBaselineType ==
    [exists    : BOOLEAN,
     resources : SUBSET Resources,
     values    : [Resources -> ResourceValues]]

AffectedNoiseRuns(es, epochRuns) ==
    {epochRuns[e] : e \in es}

\* -------------------------------------------------------------------------
\* State
\* -------------------------------------------------------------------------

VARIABLES
    \* Process/run lifecycle (Scenarios 1, 3, 4)
    processUp,
    runGen,
    stage,
    stageOwner,
    runStage,
    maxStageRank,
    waitingForAgent,
    deployedRun,
    timeoutFired,
    agentExitState,
    doneRuns,
    resultsVersion,
    doneResultsVersion,

    \* Evaluation future and captured submission (Scenarios 1, 2, 4)
    evalInFlight,
    evalRun,
    evalStage,
    evalRequest,
    evalOriginRun,
    evalOriginStage,
    evalPhase,

    \* Per-caller check-then-set cleanup state (Scenario 1)
    cleanupState,
    cleanupRun,

    \* Submission transport and acknowledgments (Scenario 2)
    submissionQueue,
    receivedQueue,
    pendingAcks,
    acceptedByStage,
    gradedAcceptances,
    timedOutAcceptances,
    requestStatus,
    requestOriginRun,
    requestOriginStage,
    requestRetries,

    \* Baseline cache provenance, including ghost metadata omitted on disk (S3)
    clusterGen,
    baselineGen,
    baselineComplete,
    observedFields,
    baselineResources,
    baselineValues,
    baselineCaptureState,
    baselineAuthoritative,
    persistedBaseline,
    persistedBaselineGen,
    persistedBaselineComplete,

    \* Abstract Kubernetes resources and ownership (Scenario 3)
    clusterResources,
    preexisting,
    runCreated,
    resourceValue,
    preRunValue,
    deleteIssued,

    \* Noise manager epochs and long-running apply (Scenario 4)
    noiseEpoch,
    noiseRun,
    noiseRunning,
    liveNoiseEpochs,
    noiseEpochRun,
    noiseLoopCount,
    applyInFlight,
    activeNoise,
    noiseStopState,
    noiseStopOwner,

    \* Fault/oracle state and Khaos reinjection window (Scenarios 1, 4)
    faultInjectedRuns,
    faultEffective,
    workloadHealthy,
    podGen,
    reinjectionActive,
    reattachPending,
    oracleState,
    oracleRun,
    oracleStage,
    oraclePassed,
    quiescenceObserved

runVars ==
    <<processUp, runGen, stage, stageOwner, runStage, maxStageRank,
      waitingForAgent, deployedRun, timeoutFired, agentExitState,
      doneRuns, resultsVersion, doneResultsVersion>>

evalVars ==
    <<evalInFlight, evalRun, evalStage, evalRequest, evalOriginRun,
      evalOriginStage, evalPhase>>

cleanupVars == <<cleanupState, cleanupRun>>

submissionVars ==
    <<submissionQueue, receivedQueue, pendingAcks, acceptedByStage,
      gradedAcceptances, timedOutAcceptances, requestStatus,
      requestOriginRun, requestOriginStage, requestRetries>>

baselineVars ==
    <<clusterGen, baselineGen, baselineComplete, observedFields,
      baselineResources, baselineValues, baselineCaptureState,
      baselineAuthoritative, persistedBaseline, persistedBaselineGen,
      persistedBaselineComplete>>

resourceVars ==
    <<clusterResources, preexisting, runCreated, resourceValue,
      preRunValue, deleteIssued>>

noiseVars ==
    <<noiseEpoch, noiseRun, noiseRunning, liveNoiseEpochs, noiseEpochRun,
      noiseLoopCount, applyInFlight, activeNoise, noiseStopState,
      noiseStopOwner>>

oracleVars ==
    <<faultInjectedRuns, faultEffective, workloadHealthy, podGen,
      reinjectionActive, reattachPending, oracleState, oracleRun,
      oracleStage, oraclePassed, quiescenceObserved>>

vars ==
    <<runVars, evalVars, cleanupVars, submissionVars, baselineVars,
      resourceVars, noiseVars, oracleVars>>

\* -------------------------------------------------------------------------
\* Initial state
\* -------------------------------------------------------------------------

Init ==
    \* Conductor.__init__ initializes no active problem or submission stage;
    \* sregym/conductor/conductor.py:43-89.
    /\ processUp = TRUE
    /\ runGen = 0
    /\ stage = IdleStage
    /\ stageOwner = NoRun
    /\ runStage = [g \in RunIds |-> IdleStage]
    /\ maxStageRank = [g \in RunIds |-> 0]
    /\ waitingForAgent = FALSE
    /\ deployedRun = NoRun
    /\ timeoutFired = {}
    /\ agentExitState = "none"
    /\ doneRuns = {}
    /\ resultsVersion = [g \in RunIds |-> 0]
    /\ doneResultsVersion = [g \in RunIds |-> 0]

    \* Conductor.__init__ initializes no executor future/evaluation;
    \* sregym/conductor/conductor.py:76-89.
    /\ evalInFlight = FALSE
    /\ evalRun = NoRun
    /\ evalStage = "none"
    /\ evalRequest = NoRequest
    /\ evalOriginRun = NoRun
    /\ evalOriginStage = "none"
    /\ evalPhase = "idle"

    \* _finish_problem has two possible callers in the modeled paths;
    \* main.py:393-425; sregym/conductor/conductor.py:503-505.
    /\ cleanupState = [a \in CleanupActors |-> "idle"]
    /\ cleanupRun = [a \in CleanupActors |-> NoRun]

    \* HTTP/MCP request schemas initially contain no messages;
    \* sregym/conductor/conductor_api.py:23-53,110-148.
    /\ submissionQueue = <<>>
    /\ receivedQueue = <<>>
    /\ pendingAcks = <<>>
    /\ acceptedByStage = {}
    /\ gradedAcceptances = {}
    /\ timedOutAcceptances = {}
    /\ requestStatus = [r \in RequestIds |-> "new"]
    /\ requestOriginRun = [r \in RequestIds |-> NoRun]
    /\ requestOriginStage = [r \in RequestIds |-> "none"]
    /\ requestRetries = [r \in RequestIds |-> 0]

    \* ClusterStateManager starts without an in-memory baseline;
    \* sregym/service/cluster_state.py:116-128.
    /\ clusterGen = 0
    /\ baselineGen = NoRun
    /\ baselineComplete = FALSE
    /\ observedFields = {}
    /\ baselineResources = {}
    /\ baselineValues = [r \in Resources |-> CleanValue]
    /\ baselineCaptureState = "unchecked"
    /\ baselineAuthoritative = FALSE
    /\ persistedBaseline =
        [exists |-> FALSE,
         resources |-> {},
         values |-> [r \in Resources |-> CleanValue]]
    /\ persistedBaselineGen = NoRun
    /\ persistedBaselineComplete = FALSE

    \* Abstract fresh-cluster contents before benchmark deployment;
    \* sregym/conductor/conductor.py:787-796.
    /\ clusterResources = {PreResource}
    /\ preexisting = {PreResource}
    /\ runCreated = {}
    /\ resourceValue = [r \in Resources |-> CleanValue]
    /\ preRunValue = [r \in Resources |-> CleanValue]
    /\ deleteIssued = {}

    \* NoiseManager.__init__ initializes an empty manager;
    \* sregym/generators/noise/manager.py:44-57.
    /\ noiseEpoch = 0
    /\ noiseRun = NoRun
    /\ noiseRunning = FALSE
    /\ liveNoiseEpochs = {}
    /\ noiseEpochRun = [e \in 0..MaxNoiseEpoch |-> NoRun]
    /\ noiseLoopCount = 0
    /\ applyInFlight = {}
    /\ activeNoise = {}
    /\ noiseStopState = "idle"
    /\ noiseStopOwner = "none"

    \* No fault, reinjection, or oracle is active before start_problem;
    \* sregym/conductor/conductor.py:168-175,219-240.
    /\ faultInjectedRuns = {}
    /\ faultEffective = [g \in RunIds |-> FALSE]
    /\ workloadHealthy = [g \in RunIds |-> TRUE]
    /\ podGen = [g \in RunIds |-> 0]
    /\ reinjectionActive = {}
    /\ reattachPending = {}
    /\ oracleState = "idle"
    /\ oracleRun = NoRun
    /\ oracleStage = "none"
    /\ oraclePassed = {}
    /\ quiescenceObserved = [g \in RunIds |-> FALSE]

\* -------------------------------------------------------------------------
\* Run setup and persisted baseline
\* -------------------------------------------------------------------------

StartProblem ==
    \* start_problem waits for the previous submit future and then replaces
    \* current problem/results; sregym/conductor/conductor.py:399-414.
    /\ processUp
    /\ runGen < MaxRun
    /\ stage \in {IdleStage, DoneStage}
    /\ ~evalInFlight
    /\ \A a \in CleanupActors : cleanupState[a] \in {"idle", "complete"}
    /\ LET g == runGen + 1 IN
       /\ runGen' = g
       /\ stage' = SetupStage
       /\ stageOwner' = g
       /\ runStage' = [runStage EXCEPT ![g] = SetupStage]
       /\ maxStageRank' = [maxStageRank EXCEPT ![g] = StageRank(SetupStage)]
       /\ waitingForAgent' = FALSE
       /\ timeoutFired' = timeoutFired \ {g}
       /\ agentExitState' = "none"
       /\ resultsVersion' = [resultsVersion EXCEPT ![g] = 0]
       /\ doneResultsVersion' = [doneResultsVersion EXCEPT ![g] = 0]

       \* A new Conductor run has no accepted executor work yet;
       \* sregym/conductor/conductor.py:409-414,431-456.
       /\ evalInFlight' = FALSE
       /\ evalRun' = NoRun
       /\ evalStage' = "none"
       /\ evalRequest' = NoRequest
       /\ evalOriginRun' = NoRun
       /\ evalOriginStage' = "none"
       /\ evalPhase' = "idle"
       /\ cleanupState' = [a \in CleanupActors |-> "idle"]
       /\ cleanupRun' = [a \in CleanupActors |-> NoRun]

       \* Run ownership is process-local; after a crash, old cluster residue is
       \* not silently reclassified as new-run-owned; main.py:537-563.
       /\ runCreated' = {}

       \* Per-run fault/oracle fields are reset before _inject_fault;
       \* sregym/conductor/conductor.py:168-175,455-458.
       /\ faultEffective' = [faultEffective EXCEPT ![g] = FALSE]
       /\ workloadHealthy' = [workloadHealthy EXCEPT ![g] = TRUE]
       /\ podGen' = [podGen EXCEPT ![g] = 0]
       /\ quiescenceObserved' =
            [quiescenceObserved EXCEPT ![g] = FALSE]
       /\ oracleState' = "idle"
       /\ oracleRun' = NoRun
       /\ oracleStage' = "none"
    /\ UNCHANGED
        <<processUp, deployedRun, doneRuns, submissionVars, baselineVars,
          clusterResources, preexisting, resourceValue, preRunValue,
          deleteIssued, noiseVars, faultInjectedRuns, reinjectionActive,
          reattachPending, oraclePassed>>

LoadBaselineState ==
    \* deploy_app prefers the fixed persisted file and treats a successful load
    \* as authoritative; sregym/conductor/conductor.py:787-796.
    /\ processUp
    /\ stage = SetupStage
    /\ ~baselineAuthoritative
    /\ baselineCaptureState = "unchecked"
    /\ persistedBaseline.exists
    \* from_json accepts omitted fields as empty; cluster_state.py:98-113,165-182.
    /\ baselineResources' = persistedBaseline.resources
    /\ baselineValues' = persistedBaseline.values
    /\ baselineGen' = persistedBaselineGen
    /\ baselineComplete' = persistedBaselineComplete
    /\ observedFields' = BaselineFields
    /\ baselineCaptureState' = "captured"
    /\ baselineAuthoritative' = TRUE
    /\ UNCHANGED
        <<runVars, evalVars, cleanupVars, submissionVars, clusterGen,
          persistedBaseline, persistedBaselineGen, persistedBaselineComplete,
          resourceVars, noiseVars, oracleVars>>

BeginBaselineCapture ==
    \* save_baseline_state calls capture_baseline when no file loads;
    \* sregym/service/cluster_state.py:130-163.
    /\ processUp
    /\ stage = SetupStage
    /\ ~baselineAuthoritative
    /\ baselineCaptureState = "unchecked"
    /\ ~persistedBaseline.exists
    /\ baselineGen' = clusterGen
    /\ baselineComplete' = TRUE
    /\ observedFields' = {}
    /\ baselineResources' = {}
    /\ baselineValues' = [r \in Resources |-> CleanValue]
    /\ baselineCaptureState' = "capturing"
    /\ UNCHANGED
        <<runVars, evalVars, cleanupVars, submissionVars, clusterGen,
          baselineAuthoritative, persistedBaseline, persistedBaselineGen,
          persistedBaselineComplete, resourceVars, noiseVars, oracleVars>>

ObserveBaseline(field, ok) ==
    \* capture_baseline performs independent list/read calls per field;
    \* sregym/service/cluster_state.py:130-149.
    /\ field \in BaselineFields
    /\ ok \in BOOLEAN
    /\ baselineCaptureState = "capturing"
    /\ field \notin observedFields
    /\ observedFields' = observedFields \cup {field}
    \* ApiException is converted to an empty value and capture continues;
    \* sregym/service/cluster_state.py:352-395,451-511.
    /\ baselineComplete' = baselineComplete /\ ok
    /\ baselineResources' =
        IF field = "resources" /\ ok THEN clusterResources
        ELSE baselineResources
    /\ baselineValues' =
        IF field = "values" /\ ok THEN resourceValue
        ELSE baselineValues
    /\ UNCHANGED
        <<runVars, evalVars, cleanupVars, submissionVars, clusterGen,
          baselineGen, baselineCaptureState, baselineAuthoritative,
          persistedBaseline, persistedBaselineGen, persistedBaselineComplete,
          resourceVars, noiseVars, oracleVars>>

PersistBaselineState ==
    \* save_baseline_state writes exactly the captured JSON projection;
    \* sregym/service/cluster_state.py:153-163.
    /\ baselineCaptureState = "capturing"
    /\ observedFields = BaselineFields
    /\ persistedBaseline' =
        [exists |-> TRUE,
         resources |-> baselineResources,
         values |-> baselineValues]
    \* Generation/completeness are ghost provenance: to_json omits both;
    \* sregym/service/cluster_state.py:82-96; sregym/paths.py:11-16.
    /\ persistedBaselineGen' = baselineGen
    /\ persistedBaselineComplete' = baselineComplete
    /\ baselineCaptureState' = "captured"
    /\ baselineAuthoritative' = TRUE
    /\ UNCHANGED
        <<runVars, evalVars, cleanupVars, submissionVars, clusterGen,
          baselineGen, baselineComplete, observedFields, baselineResources,
          baselineValues, resourceVars, noiseVars, oracleVars>>

DeployProblem ==
    \* deploy_app performs infrastructure/application effects only after the
    \* load-or-capture branch; sregym/conductor/conductor.py:782-825.
    /\ processUp
    /\ stage = SetupStage
    /\ baselineAuthoritative
    /\ deployedRun /= runGen
    /\ deployedRun' = runGen
    /\ clusterResources' = clusterResources \cup {RunResource}
    /\ runCreated' =
        IF RunResource \in clusterResources
        THEN runCreated
        ELSE runCreated \cup {RunResource}
    /\ resourceValue' =
        IF RunResource \in clusterResources
        THEN resourceValue
        ELSE [resourceValue EXCEPT ![RunResource] = CleanValue]
    /\ UNCHANGED
        <<processUp, runGen, stage, stageOwner, runStage, maxStageRank,
          waitingForAgent, timeoutFired, agentExitState, doneRuns,
          resultsVersion, doneResultsVersion, evalVars, cleanupVars,
          submissionVars, baselineVars, preexisting, preRunValue,
          deleteIssued, noiseVars, oracleVars>>

InjectFault ==
    \* _inject_fault calls the problem injector and then marks fault_injected;
    \* sregym/conductor/conductor.py:219-240.
    /\ processUp
    /\ stage = SetupStage
    /\ deployedRun = runGen
    /\ runGen \notin faultInjectedRuns
    /\ faultInjectedRuns' = faultInjectedRuns \cup {runGen}
    /\ faultEffective' = [faultEffective EXCEPT ![runGen] = TRUE]
    /\ workloadHealthy' = [workloadHealthy EXCEPT ![runGen] = FALSE]
    \* Khaos faults start a pod-reinjection monitor after injection;
    \* sregym/conductor/problems/khaos_faults.py:259-270.
    /\ reinjectionActive' = reinjectionActive \cup {runGen}
    /\ UNCHANGED
        <<runVars, evalVars, cleanupVars, submissionVars, baselineVars,
          resourceVars, noiseVars, podGen, reattachPending, oracleState,
          oracleRun, oracleStage, oraclePassed, quiescenceObserved>>

AdvanceToFirstStage ==
    \* _advance_to_next_stage injects before exposing the first configured
    \* checkpoint, then sets waiting_for_agent; conductor.py:281-314.
    /\ processUp
    /\ stage = SetupStage
    /\ runGen \in faultInjectedRuns
    /\ stage' = DiagnosisStage
    /\ stageOwner' = runGen
    /\ runStage' = [runStage EXCEPT ![runGen] = DiagnosisStage]
    /\ maxStageRank' =
        [maxStageRank EXCEPT
            ![runGen] = NatMax(@, StageRank(DiagnosisStage))]
    /\ waitingForAgent' = TRUE
    /\ UNCHANGED
        <<processUp, runGen, deployedRun, timeoutFired, agentExitState,
          doneRuns, resultsVersion, doneResultsVersion, evalVars, cleanupVars,
          submissionVars, baselineVars, resourceVars, noiseVars, oracleVars>>

\* -------------------------------------------------------------------------
\* Submission transport, acceptance, and acknowledgment (Scenario 2)
\* -------------------------------------------------------------------------

SendSubmission(req) ==
    \* Stock clients send after observing the current stage, but the schema
    \* carries only solution text; conductor_api.py:23-32,110-115.
    /\ processUp
    /\ req \in RequestIds
    /\ stage \in AgentStages
    /\ requestStatus[req] = "new"
    /\ Len(submissionQueue) < MaxQueueLen
    /\ LET m ==
        [requestId |-> req, originRun |-> runGen, originStage |-> stage]
       IN
       /\ submissionQueue' = Append(submissionQueue, m)
       /\ requestStatus' = [requestStatus EXCEPT ![req] = "queued"]
       /\ requestOriginRun' = [requestOriginRun EXCEPT ![req] = runGen]
       /\ requestOriginStage' =
            [requestOriginStage EXCEPT ![req] = stage]
    /\ UNCHANGED
        <<runVars, evalVars, cleanupVars, receivedQueue, pendingAcks,
          acceptedByStage, gradedAcceptances, timedOutAcceptances,
          requestRetries, baselineVars, resourceVars, noiseVars, oracleVars>>

DelayOrDuplicate(k) ==
    \* Retries/duplicates are distinct transport deliveries even though the
    \* implementation has no request ID; conductor_api.py:42-51,131-145.
    /\ k \in 1..Len(submissionQueue)
    /\ Len(submissionQueue) < MaxQueueLen
    /\ submissionQueue' = Append(submissionQueue, submissionQueue[k])
    /\ UNCHANGED
        <<runVars, evalVars, cleanupVars, receivedQueue, pendingAcks,
          acceptedByStage, gradedAcceptances, timedOutAcceptances,
          requestStatus, requestOriginRun, requestOriginStage, requestRetries,
          baselineVars, resourceVars, noiseVars, oracleVars>>

ReceiveSubmission(k) ==
    \* The endpoint samples the mutable stage before entering its retry loop;
    \* sregym/conductor/conductor_api.py:33-43,116-132.
    /\ processUp
    /\ stage \in AgentStages
    \* A handler calls the no-suspension Conductor.submit coroutine before the
    \* event loop can start another handler.  Multiple received handlers can
    \* coexist only after every older one has yielded in its retry sleep.
    /\ \A j \in 1..Len(receivedQueue) :
        requestRetries[receivedQueue[j].requestId] > 0
    /\ k \in 1..Len(submissionQueue)
    /\ Len(receivedQueue) < MaxQueueLen
    /\ LET m == submissionQueue[k] IN
       /\ submissionQueue' = RemoveAt(submissionQueue, k)
       /\ receivedQueue' = Append(receivedQueue, m)
       /\ requestStatus' =
            [requestStatus EXCEPT ![m.requestId] = "received"]
    /\ UNCHANGED
        <<runVars, evalVars, cleanupVars, pendingAcks, acceptedByStage,
          gradedAcceptances, timedOutAcceptances, requestOriginRun,
          requestOriginStage, requestRetries, baselineVars, resourceVars,
          noiseVars, oracleVars>>

RetrySubmission(k) ==
    \* RuntimeError causes the already-received request to wait and retry while
    \* global stage may change; conductor_api.py:128-145.
    /\ k \in 1..Len(receivedQueue)
    /\ ~waitingForAgent
    /\ evalPhase \in {"completed", "advanced"}
    /\ requestRetries[receivedQueue[k].requestId] < MaxRetries
    /\ requestRetries' =
        [requestRetries EXCEPT ![receivedQueue[k].requestId] = @ + 1]
    /\ UNCHANGED
        <<runVars, evalVars, cleanupVars, submissionQueue, receivedQueue,
          pendingAcks, acceptedByStage, gradedAcceptances,
          timedOutAcceptances, requestStatus, requestOriginRun,
          requestOriginStage, baselineVars, resourceVars, noiseVars,
          oracleVars>>

ConductorSubmitAccept(k) ==
    \* Conductor.submit interprets the solution against current_stage_index,
    \* clears waiting, and marks evaluating; conductor.py:516-565.
    /\ processUp
    /\ stage \in AgentStages
    /\ waitingForAgent
    /\ ~evalInFlight
    /\ k \in 1..Len(receivedQueue)
    /\ Len(pendingAcks) < MaxQueueLen
    /\ LET m == receivedQueue[k]
           a == AcceptanceOf(m, runGen, stage)
       IN
       /\ receivedQueue' = RemoveAt(receivedQueue, k)
       /\ pendingAcks' = Append(pendingAcks, m.requestId)
       /\ acceptedByStage' = acceptedByStage \cup {a}
       /\ requestStatus' =
            [requestStatus EXCEPT ![m.requestId] = "accepted"]
       /\ waitingForAgent' = FALSE
       /\ evalInFlight' = TRUE
       /\ evalRun' = runGen
       /\ evalStage' = stage
       /\ evalRequest' = m.requestId
       /\ evalOriginRun' = m.originRun
       /\ evalOriginStage' = m.originStage
       /\ evalPhase' = "accepted"
    /\ UNCHANGED
        <<processUp, runGen, stage, stageOwner, runStage, maxStageRank,
          deployedRun, timeoutFired, agentExitState, doneRuns,
          resultsVersion, doneResultsVersion, cleanupVars, submissionQueue,
          gradedAcceptances, timedOutAcceptances, requestOriginRun,
          requestOriginStage, requestRetries, baselineVars, resourceVars,
          noiseVars, oracleVars>>

ConductorSubmitDuplicate(k) ==
    \* While _evaluating is true, Conductor discards an in-flight duplicate but
    \* returns success; conductor.py:537-548,568.
    /\ processUp
    /\ stage \in AgentStages
    /\ ~waitingForAgent
    /\ evalInFlight
    /\ evalPhase \notin {"completed", "advanced"}
    /\ k \in 1..Len(receivedQueue)
    /\ Len(pendingAcks) < MaxQueueLen
    /\ LET req == receivedQueue[k].requestId IN
       /\ receivedQueue' = RemoveAt(receivedQueue, k)
       /\ pendingAcks' = Append(pendingAcks, req)
       /\ requestStatus' = [requestStatus EXCEPT ![req] = "discarded"]
    /\ UNCHANGED
        <<runVars, evalVars, cleanupVars, submissionQueue, acceptedByStage,
          gradedAcceptances, timedOutAcceptances, requestOriginRun,
          requestOriginStage, requestRetries, baselineVars, resourceVars,
          noiseVars, oracleVars>>

ConductorSubmitLate(k) ==
    \* A request that passed the endpoint precheck can later reach submit after
    \* teardown/done and still receive generic success; conductor.py:523-535;
    \* conductor_api.py:133-148.
    /\ processUp
    /\ stage \in {TeardownStage, DoneStage}
    /\ k \in 1..Len(receivedQueue)
    /\ Len(pendingAcks) < MaxQueueLen
    /\ LET req == receivedQueue[k].requestId IN
       /\ receivedQueue' = RemoveAt(receivedQueue, k)
       /\ pendingAcks' = Append(pendingAcks, req)
       /\ requestStatus' = [requestStatus EXCEPT ![req] = "discarded"]
    /\ UNCHANGED
        <<runVars, evalVars, cleanupVars, submissionQueue, acceptedByStage,
          gradedAcceptances, timedOutAcceptances, requestOriginRun,
          requestOriginStage, requestRetries, baselineVars, resourceVars,
          noiseVars, oracleVars>>

Acknowledge ==
    \* Both endpoints replace Conductor.submit's detailed return with a generic
    \* "Submission received"; conductor_api.py:45-46,133-135.
    /\ Len(pendingAcks) > 0
    /\ LET req == pendingAcks[1] IN
       /\ pendingAcks' = RemoveAt(pendingAcks, 1)
       /\ requestStatus' = [requestStatus EXCEPT ![req] = "acked"]
    /\ UNCHANGED
        <<runVars, evalVars, cleanupVars, submissionQueue, receivedQueue,
          acceptedByStage, gradedAcceptances, timedOutAcceptances,
          requestOriginRun, requestOriginStage, requestRetries, baselineVars,
          resourceVars, noiseVars, oracleVars>>

\* -------------------------------------------------------------------------
\* Evaluation and oracle progression (Scenarios 1, 2, 4)
\* -------------------------------------------------------------------------

BeginEvaluation ==
    \* The executor begins by stopping noise before calling the stage oracle;
    \* sregym/conductor/conductor.py:468-491.
    /\ evalInFlight
    /\ evalPhase = "accepted"
    /\ evalPhase' = "stoppingNoise"
    /\ UNCHANGED
        <<runVars, evalInFlight, evalRun, evalStage, evalRequest,
          evalOriginRun, evalOriginStage, cleanupVars, submissionVars,
          baselineVars, resourceVars, noiseVars, oracleVars>>

BeginOracle ==
    \* Evaluation starts immediately after NoiseManager.stop returns;
    \* sregym/conductor/conductor.py:476-491.
    /\ evalInFlight
    /\ evalPhase = "oracleReady"
    /\ oracleState = "idle"
    /\ oracleState' = "evaluating"
    /\ oracleRun' = evalRun
    /\ oracleStage' = evalStage
    /\ evalPhase' = "oracleRunning"
    \* This ghost observation records whether stop established real quiescence;
    \* noise/manager.py:84-95,125-157.
    /\ quiescenceObserved' =
        [quiescenceObserved EXCEPT
            ![evalRun] = (activeNoise = {} /\ applyInFlight = {})]
    /\ UNCHANGED
        <<runVars, evalInFlight, evalRun, evalStage, evalRequest,
          evalOriginRun, evalOriginStage, cleanupVars, submissionVars,
          baselineVars, resourceVars, noiseVars, faultInjectedRuns,
          faultEffective, workloadHealthy, podGen, reinjectionActive,
          reattachPending, oraclePassed>>

CompleteOracle ==
    \* Stage oracles return a Boolean success result after their external reads;
    \* sregym/conductor/conductor.py:242-279,485-500.
    /\ oracleState = "evaluating"
    /\ oracleRun = evalRun
    /\ oracleStage = evalStage
    /\ oraclePassed' =
        IF evalStage = MitigationStage
           /\ ~faultEffective[evalRun]
           /\ workloadHealthy[evalRun]
        THEN oraclePassed \cup {evalRun}
        ELSE oraclePassed
    /\ oracleState' = "idle"
    /\ oracleRun' = NoRun
    /\ oracleStage' = "none"
    /\ evalPhase' = "oracleComplete"
    /\ UNCHANGED
        <<runVars, evalInFlight, evalRun, evalStage, evalRequest,
          evalOriginRun, evalOriginStage, cleanupVars, submissionVars,
          baselineVars, resourceVars, noiseVars, faultInjectedRuns,
          faultEffective, workloadHealthy, podGen, reinjectionActive,
          reattachPending, quiescenceObserved>>

CompleteEvaluation ==
    \* Per-stage evaluation records a result, and the finally block clears
    \* _evaluating before stage advancement; conductor.py:242-279,485-505.
    /\ evalInFlight
    /\ evalPhase = "oracleComplete"
    /\ resultsVersion[evalRun] < MaxResultVersion
    /\ LET m ==
        [requestId |-> evalRequest,
         originRun |-> evalOriginRun,
         originStage |-> evalOriginStage]
           a == AcceptanceOf(m, evalRun, evalStage)
       IN
       /\ resultsVersion' =
            [resultsVersion EXCEPT ![evalRun] = @ + 1]
       /\ gradedAcceptances' = gradedAcceptances \cup {a}
       /\ requestStatus' =
            [requestStatus EXCEPT ![evalRequest] = "graded"]
    /\ evalPhase' = "completed"
    /\ UNCHANGED
        <<processUp, runGen, stage, stageOwner, runStage, maxStageRank,
          waitingForAgent, deployedRun, timeoutFired, agentExitState,
          doneRuns, doneResultsVersion, evalInFlight, evalRun, evalStage,
          evalRequest, evalOriginRun, evalOriginStage, cleanupVars,
          submissionQueue, receivedQueue, pendingAcks, acceptedByStage,
          timedOutAcceptances, requestOriginRun, requestOriginStage,
          requestRetries, baselineVars, resourceVars, noiseVars, oracleVars>>

AdvanceStageAfterEvaluation ==
    \* _submit_evaluate_and_advance computes current_stage_index + 1 only
    \* after clearing _evaluating; conductor.py:500-505.
    /\ evalInFlight
    /\ evalPhase = "completed"
    /\ ( \/ /\ evalStage = DiagnosisStage
             \* Diagnosis completion exposes mitigation and waiting_for_agent;
             \* conductor.py:281-314,503-505.
             /\ stage' = MitigationStage
             /\ stageOwner' = evalRun
             /\ runStage' =
                  [runStage EXCEPT ![runGen] = MitigationStage]
             /\ maxStageRank' =
                  [maxStageRank EXCEPT
                      ![runGen] = NatMax(@, StageRank(MitigationStage))]
             /\ waitingForAgent' = TRUE
             /\ cleanupState' = cleanupState
             /\ cleanupRun' = cleanupRun
          \/ /\ evalStage = MitigationStage
             \* Exhausting the stage sequence synchronously calls
             \* _finish_problem; conductor.py:315-317,503-505.
             /\ UNCHANGED
                  <<stage, stageOwner, runStage, maxStageRank,
                    waitingForAgent>>
             /\ cleanupState' =
                  [cleanupState EXCEPT !["evaluator"] = "requested"]
             /\ cleanupRun' =
                  [cleanupRun EXCEPT !["evaluator"] = evalRun] )
    /\ evalPhase' = "advanced"
    /\ UNCHANGED
        <<processUp, runGen, deployedRun, timeoutFired, agentExitState,
          doneRuns, resultsVersion, doneResultsVersion, evalInFlight,
          evalRun, evalStage, evalRequest, evalOriginRun, evalOriginStage,
          submissionVars, baselineVars, resourceVars, noiseVars, oracleVars>>

FinishEvaluationFuture ==
    \* The executor future covers evaluation, advancement, optional restart,
    \* and synchronous end-of-sequence cleanup; conductor.py:503-514,556-566.
    /\ evalInFlight
    /\ evalPhase = "advanced"
    /\ (evalStage = DiagnosisStage
        \/ cleanupState["evaluator"] = "complete")
    /\ evalInFlight' = FALSE
    /\ evalRun' = NoRun
    /\ evalStage' = "none"
    /\ evalRequest' = NoRequest
    /\ evalOriginRun' = NoRun
    /\ evalOriginStage' = "none"
    /\ evalPhase' = "idle"
    /\ UNCHANGED
        <<runVars, cleanupVars, submissionVars, baselineVars, resourceVars,
          noiseVars, oracleVars>>

AgentMitigate ==
    \* The mitigation solution may remove the intended fault and restore the
    \* workload before submission; abstracted from conductor.py:262-279.
    /\ processUp
    /\ stage = MitigationStage
    /\ faultEffective[runGen]
    /\ faultEffective' = [faultEffective EXCEPT ![runGen] = FALSE]
    /\ workloadHealthy' =
        [workloadHealthy EXCEPT ![runGen] = (activeNoise = {})]
    /\ UNCHANGED
        <<runVars, evalVars, cleanupVars, submissionVars, baselineVars,
          resourceVars, noiseVars, faultInjectedRuns, podGen,
          reinjectionActive, reattachPending, oracleState, oracleRun,
          oracleStage, oraclePassed, quiescenceObserved>>

\* -------------------------------------------------------------------------
\* Driver timeout/exit and non-atomic teardown ownership (Scenario 1)
\* -------------------------------------------------------------------------

AgentTimeout ==
    \* The driver records timeout and immediately calls _finish_problem without
    \* awaiting/cancelling _submit_future; main.py:393-404.
    /\ processUp
    /\ stage \in AgentStages \cup {TeardownStage}
    /\ deployedRun = runGen
    /\ runGen \notin timeoutFired
    /\ cleanupState["driver"] \in {"idle", "complete"}
    /\ resultsVersion[runGen] < MaxResultVersion
    /\ timeoutFired' = timeoutFired \cup {runGen}
    /\ resultsVersion' =
        [resultsVersion EXCEPT ![runGen] = @ + 1]
    /\ timedOutAcceptances' =
        timedOutAcceptances
        \cup {a \in acceptedByStage :
                a.acceptedRun = runGen
                /\ a \notin gradedAcceptances}
    /\ cleanupState' =
        [cleanupState EXCEPT !["driver"] = "requested"]
    /\ cleanupRun' = [cleanupRun EXCEPT !["driver"] = runGen]
    /\ UNCHANGED
        <<processUp, runGen, stage, stageOwner, runStage, maxStageRank,
          waitingForAgent, deployedRun, agentExitState, doneRuns,
          doneResultsVersion, evalVars, submissionQueue, receivedQueue,
          pendingAcks, acceptedByStage, gradedAcceptances, requestStatus,
          requestOriginRun, requestOriginStage, requestRetries, baselineVars,
          resourceVars, noiseVars, oracleVars>>

AgentExit ==
    \* Process exit waits on an unfinished submit future, otherwise it proceeds
    \* directly to teardown; main.py:406-425.
    /\ processUp
    /\ stage \in AgentStages \cup {TeardownStage}
    /\ deployedRun = runGen
    /\ agentExitState = "none"
    /\ agentExitState' = IF evalInFlight THEN "waiting" ELSE "expired"
    /\ cleanupState' =
        IF evalInFlight
        THEN cleanupState
        ELSE [cleanupState EXCEPT !["driver"] = "requested"]
    /\ cleanupRun' =
        IF evalInFlight
        THEN cleanupRun
        ELSE [cleanupRun EXCEPT !["driver"] = runGen]
    /\ UNCHANGED
        <<processUp, runGen, stage, stageOwner, runStage, maxStageRank,
          waitingForAgent, deployedRun, timeoutFired, doneRuns,
          resultsVersion, doneResultsVersion, evalVars, submissionVars,
          baselineVars, resourceVars, noiseVars, oracleVars>>

AgentExitWaitTimeout ==
    \* asyncio.wait_for gives up after 300 seconds and teardown proceeds;
    \* main.py:412-424.
    /\ agentExitState = "waiting"
    /\ evalInFlight
    /\ cleanupState["driver"] \in {"idle", "complete"}
    /\ agentExitState' = "expired"
    /\ cleanupState' =
        [cleanupState EXCEPT !["driver"] = "requested"]
    /\ cleanupRun' = [cleanupRun EXCEPT !["driver"] = runGen]
    /\ UNCHANGED
        <<processUp, runGen, stage, stageOwner, runStage, maxStageRank,
          waitingForAgent, deployedRun, timeoutFired, doneRuns,
          resultsVersion, doneResultsVersion, evalVars, submissionVars,
          baselineVars, resourceVars, noiseVars, oracleVars>>

AgentExitAfterEvaluation ==
    \* If the future finishes within the wait, the driver then invokes the same
    \* teardown safety net; main.py:412-425.
    /\ agentExitState = "waiting"
    /\ ~evalInFlight
    /\ cleanupState["driver"] \in {"idle", "complete"}
    /\ agentExitState' = "expired"
    /\ cleanupState' =
        [cleanupState EXCEPT !["driver"] = "requested"]
    /\ cleanupRun' = [cleanupRun EXCEPT !["driver"] = runGen]
    /\ UNCHANGED
        <<processUp, runGen, stage, stageOwner, runStage, maxStageRank,
          waitingForAgent, deployedRun, timeoutFired, doneRuns,
          resultsVersion, doneResultsVersion, evalVars, submissionVars,
          baselineVars, resourceVars, noiseVars, oracleVars>>

FinishProblemCheck(actor) ==
    \* _finish_problem first reads submission_stage in an unsynchronized
    \* check-then-set guard; conductor.py:367-384.
    /\ actor \in CleanupActors
    /\ cleanupState[actor] = "requested"
    /\ cleanupState' =
        IF stage \in {DoneStage, TeardownStage}
        THEN [cleanupState EXCEPT ![actor] = "complete"]
        ELSE [cleanupState EXCEPT ![actor] = "checked"]
    /\ UNCHANGED
        <<runVars, evalVars, cleanupRun, submissionVars, baselineVars,
          resourceVars, noiseVars, oracleVars>>

BeginCleanup(actor) ==
    \* A caller that observed an open stage subsequently writes tearing_down;
    \* another caller may have passed the same check; conductor.py:378-385.
    /\ actor \in CleanupActors
    /\ cleanupState[actor] = "checked"
    /\ cleanupRun[actor] = runGen
    /\ cleanupState' =
        [cleanupState EXCEPT ![actor] = "stoppingNoise"]
    /\ stage' = TeardownStage
    /\ stageOwner' = cleanupRun[actor]
    /\ runStage' = [runStage EXCEPT ![runGen] = TeardownStage]
    /\ maxStageRank' =
        [maxStageRank EXCEPT
            ![runGen] = NatMax(@, StageRank(TeardownStage))]
    /\ waitingForAgent' = FALSE
    /\ UNCHANGED
        <<processUp, runGen, deployedRun, timeoutFired, agentExitState,
          doneRuns, resultsVersion, doneResultsVersion, evalVars, cleanupRun,
          submissionVars, baselineVars, resourceVars, noiseVars, oracleVars>>

CompleteRecovery(actor) ==
    \* _cleanup_sync recovers the fault and undeploys the captured problem
    \* before reconciliation; conductor.py:319-350.
    /\ actor \in CleanupActors
    /\ cleanupState[actor] = "recovering"
    /\ cleanupRun[actor] = runGen
    /\ cleanupState' =
        [cleanupState EXCEPT ![actor] = "reconciling"]
    /\ deployedRun' = IF deployedRun = runGen THEN NoRun ELSE deployedRun
    /\ faultEffective' = [faultEffective EXCEPT ![runGen] = FALSE]
    /\ workloadHealthy' =
        [workloadHealthy EXCEPT ![runGen] = (activeNoise = {})]
    \* recover_fault stops the Khaos reinjection monitor first;
    \* sregym/conductor/problems/khaos_faults.py:272-280.
    /\ reinjectionActive' = reinjectionActive \ {runGen}
    /\ reattachPending' = reattachPending \ {runGen}
    /\ UNCHANGED
        <<processUp, runGen, stage, stageOwner, runStage, maxStageRank,
          waitingForAgent, timeoutFired, agentExitState, doneRuns,
          resultsVersion, doneResultsVersion, evalVars, cleanupRun,
          submissionVars, baselineVars, resourceVars, noiseVars,
          faultInjectedRuns, podGen, oracleState, oracleRun, oracleStage,
          oraclePassed, quiescenceObserved>>

UnexpectedResources ==
    IF baselineAuthoritative
    THEN clusterResources \ baselineResources
    ELSE {}

RestorableMismatches ==
    IF baselineAuthoritative
    THEN {r \in clusterResources \cap baselineResources :
            resourceValue[r] /= baselineValues[r]}
    ELSE {}

ReconcileDelete(actor, resource) ==
    \* reconcile_to_baseline deletes current-minus-baseline identities without
    \* consulting run ownership; cluster_state.py:184-335.
    /\ actor \in CleanupActors
    /\ cleanupState[actor] = "reconciling"
    /\ resource \in UnexpectedResources
    /\ LET d ==
        [run |-> cleanupRun[actor],
         resource |-> resource,
         owned |-> resource \in runCreated]
       IN deleteIssued' = deleteIssued \cup {d}
    /\ clusterResources' = clusterResources \ {resource}
    /\ UNCHANGED
        <<runVars, evalVars, cleanupVars, submissionVars, baselineVars,
          preexisting, runCreated, resourceValue, preRunValue, noiseVars,
          oracleVars>>

ReconcileRestore(actor, resource) ==
    \* Reconciliation restores mutable node/CoreDNS values only for objects
    \* that still exist; it does not recreate deleted identities;
    \* cluster_state.py:337-347.
    /\ actor \in CleanupActors
    /\ cleanupState[actor] = "reconciling"
    /\ resource \in RestorableMismatches
    /\ resourceValue' =
        [resourceValue EXCEPT ![resource] = baselineValues[resource]]
    /\ UNCHANGED
        <<runVars, evalVars, cleanupVars, submissionVars, baselineVars,
          clusterResources, preexisting, runCreated, preRunValue,
          deleteIssued, noiseVars, oracleVars>>

CompleteCleanup(actor) ==
    \* _cleanup_sync sets submission_stage to done after reconciliation returns;
    \* conductor.py:352-365.
    /\ actor \in CleanupActors
    /\ cleanupState[actor] = "reconciling"
    /\ cleanupRun[actor] = runGen
    /\ UnexpectedResources = {}
    /\ RestorableMismatches = {}
    /\ cleanupState' = [cleanupState EXCEPT ![actor] = "complete"]
    /\ stage' = DoneStage
    /\ stageOwner' = cleanupRun[actor]
    /\ runStage' = [runStage EXCEPT ![runGen] = DoneStage]
    /\ maxStageRank' =
        [maxStageRank EXCEPT ![runGen] = StageRank(DoneStage)]
    /\ waitingForAgent' = FALSE
    /\ doneRuns' = doneRuns \cup {runGen}
    \* The first completion snapshots the published result version; later
    \* evaluator writes remain visible to DoneIsTerminal; main.py:428-463.
    /\ doneResultsVersion' =
        IF runGen \in doneRuns
        THEN doneResultsVersion
        ELSE [doneResultsVersion EXCEPT
                ![runGen] = resultsVersion[runGen]]
    /\ UNCHANGED
        <<processUp, runGen, deployedRun, timeoutFired, agentExitState,
          resultsVersion, evalVars, cleanupRun, submissionVars, baselineVars,
          resourceVars, noiseVars, oracleVars>>

\* -------------------------------------------------------------------------
\* Noise manager split at real blocking/visibility boundaries (Scenario 4)
\* -------------------------------------------------------------------------

NoiseManagerStart ==
    \* start creates a new daemon thread only when running is false;
    \* sregym/generators/noise/manager.py:71-82.
    /\ processUp
    /\ stage \in {SetupStage, DiagnosisStage, MitigationStage}
    /\ deployedRun = runGen
    /\ ~noiseRunning
    /\ noiseStopState = "idle"
    /\ noiseEpoch < MaxNoiseEpoch
    /\ LET e == noiseEpoch + 1 IN
       /\ noiseEpoch' = e
       /\ noiseRun' = runGen
       /\ noiseRunning' = TRUE
       /\ liveNoiseEpochs' = liveNoiseEpochs \cup {e}
       /\ noiseEpochRun' = [noiseEpochRun EXCEPT ![e] = runGen]
       /\ noiseLoopCount' = noiseLoopCount + 1
    /\ UNCHANGED
        <<runVars, evalVars, cleanupVars, submissionVars, baselineVars,
          resourceVars, applyInFlight, activeNoise, noiseStopState,
          noiseStopOwner, oracleVars>>

BeginNoiseApply ==
    \* _background_loop issues _apply_experiment while running;
    \* noise/manager.py:99-121,125-150.
    /\ noiseRunning
    /\ noiseEpoch \in liveNoiseEpochs
    /\ noiseEpoch \notin applyInFlight
    /\ noiseEpoch \notin activeNoise
    /\ applyInFlight' = applyInFlight \cup {noiseEpoch}
    /\ UNCHANGED
        <<runVars, evalVars, cleanupVars, submissionVars, baselineVars,
          resourceVars, noiseEpoch, noiseRun, noiseRunning, liveNoiseEpochs,
          noiseEpochRun, noiseLoopCount, activeNoise, noiseStopState,
          noiseStopOwner, oracleVars>>

CompleteNoiseApply(epoch) ==
    \* The experiment is appended to active_experiments only after the blocking
    \* kubectl command returns; noise/manager.py:145-157.
    /\ epoch \in applyInFlight
    /\ applyInFlight' = applyInFlight \ {epoch}
    /\ activeNoise' = activeNoise \cup {epoch}
    /\ workloadHealthy' =
        [workloadHealthy EXCEPT ![noiseEpochRun[epoch]] = FALSE]
    /\ UNCHANGED
        <<runVars, evalVars, cleanupVars, submissionVars, baselineVars,
          resourceVars, noiseEpoch, noiseRun, noiseRunning, liveNoiseEpochs,
          noiseEpochRun, noiseLoopCount, noiseStopState, noiseStopOwner,
          faultInjectedRuns, faultEffective, podGen, reinjectionActive,
          reattachPending, oracleState, oracleRun, oracleStage, oraclePassed,
          quiescenceObserved>>

NoiseLoopExit(epoch) ==
    \* The background loop exits only after the blocking apply returns and it
    \* observes running=false; noise/manager.py:99-105,145-157.
    /\ epoch \in liveNoiseEpochs
    /\ epoch \notin applyInFlight
    /\ (~noiseRunning \/ epoch /= noiseEpoch)
    /\ liveNoiseEpochs' = liveNoiseEpochs \ {epoch}
    /\ noiseLoopCount' = noiseLoopCount - 1
    /\ UNCHANGED
        <<runVars, evalVars, cleanupVars, submissionVars, baselineVars,
          resourceVars, noiseEpoch, noiseRun, noiseRunning, noiseEpochRun,
          applyInFlight, activeNoise, noiseStopState, noiseStopOwner,
          oracleVars>>

NoiseManagerStop(owner) ==
    \* stop first clears running, then joins at most five seconds;
    \* sregym/generators/noise/manager.py:84-90.
    /\ owner \in NoiseStopOwners \ {"none"}
    /\ noiseStopState = "idle"
    /\ ( \/ /\ owner = "evaluation"
             /\ evalPhase = "stoppingNoise"
          \/ /\ owner \in CleanupActors
             /\ cleanupState[owner] = "stoppingNoise" )
    /\ noiseRunning' = FALSE
    /\ noiseStopState' = "joining"
    /\ noiseStopOwner' = owner
    /\ UNCHANGED
        <<runVars, evalVars, cleanupVars, submissionVars, baselineVars,
          resourceVars, noiseEpoch, noiseRun, liveNoiseEpochs, noiseEpochRun,
          noiseLoopCount, applyInFlight, activeNoise, oracleVars>>

NoiseManagerJoinComplete ==
    \* A stopped loop that has exited satisfies join before the timeout;
    \* sregym/generators/noise/manager.py:86-90.
    /\ noiseStopState = "joining"
    /\ (noiseEpoch = 0 \/ noiseEpoch \notin liveNoiseEpochs)
    /\ noiseStopState' = "cleaning"
    /\ UNCHANGED
        <<runVars, evalVars, cleanupVars, submissionVars, baselineVars,
          resourceVars, noiseEpoch, noiseRun, noiseRunning, liveNoiseEpochs,
          noiseEpochRun, noiseLoopCount, applyInFlight, activeNoise,
          noiseStopOwner, oracleVars>>

NoiseManagerJoinTimeout ==
    \* join(timeout=5) returns while an apply may still be blocked, and the
    \* thread reference is then cleared; noise/manager.py:84-90,125-157.
    /\ noiseStopState = "joining"
    /\ noiseEpoch \in liveNoiseEpochs
    /\ noiseEpoch \in applyInFlight
    /\ noiseStopState' = "cleaning"
    /\ UNCHANGED
        <<runVars, evalVars, cleanupVars, submissionVars, baselineVars,
          resourceVars, noiseEpoch, noiseRun, noiseRunning, liveNoiseEpochs,
          noiseEpochRun, noiseLoopCount, applyInFlight, activeNoise,
          noiseStopOwner, oracleVars>>

NoiseManagerCleanupRecorded ==
    \* _cleanup_experiments iterates only the list recorded at this instant and
    \* then clears it; noise/manager.py:176-203.
    /\ noiseStopState = "cleaning"
    /\ activeNoise' = {}
    /\ workloadHealthy' =
        [g \in RunIds |->
            IF g \in AffectedNoiseRuns(activeNoise, noiseEpochRun)
            THEN ~faultEffective[g]
            ELSE workloadHealthy[g]]
    /\ noiseStopState' = "forceRemoving"
    /\ UNCHANGED
        <<runVars, evalVars, cleanupVars, submissionVars, baselineVars,
          resourceVars, noiseEpoch, noiseRun, noiseRunning, liveNoiseEpochs,
          noiseEpochRun, noiseLoopCount, applyInFlight, noiseStopOwner,
          faultInjectedRuns, faultEffective, podGen, reinjectionActive,
          reattachPending, oracleState, oracleRun, oracleStage, oraclePassed,
          quiescenceObserved>>

NoiseManagerForceRemove ==
    \* The fallback scans currently existing Chaos resources; an apply that
    \* completes later is absent from this scan; noise/manager.py:205-245.
    /\ noiseStopState = "forceRemoving"
    /\ activeNoise' = {}
    /\ workloadHealthy' =
        [g \in RunIds |->
            IF g \in AffectedNoiseRuns(activeNoise, noiseEpochRun)
            THEN ~faultEffective[g]
            ELSE workloadHealthy[g]]
    /\ noiseStopState' = "complete"
    /\ UNCHANGED
        <<runVars, evalVars, cleanupVars, submissionVars, baselineVars,
          resourceVars, noiseEpoch, noiseRun, noiseRunning, liveNoiseEpochs,
          noiseEpochRun, noiseLoopCount, applyInFlight, noiseStopOwner,
          faultInjectedRuns, faultEffective, podGen, reinjectionActive,
          reattachPending, oracleState, oracleRun, oracleStage, oraclePassed,
          quiescenceObserved>>

NoiseManagerStopReturn ==
    \* stop returns after cleanup regardless of whether the timed-out old apply
    \* can still append; noise/manager.py:84-95.
    /\ noiseStopState = "complete"
    /\ evalPhase' =
        IF noiseStopOwner = "evaluation"
        THEN "oracleReady"
        ELSE evalPhase
    /\ cleanupState' =
        IF noiseStopOwner \in CleanupActors
        THEN [cleanupState EXCEPT ![noiseStopOwner] = "recovering"]
        ELSE cleanupState
    /\ noiseStopState' = "idle"
    /\ noiseStopOwner' = "none"
    /\ UNCHANGED
        <<runVars, evalInFlight, evalRun, evalStage, evalRequest,
          evalOriginRun, evalOriginStage, cleanupRun, submissionVars,
          baselineVars, resourceVars, noiseEpoch, noiseRun, noiseRunning,
          liveNoiseEpochs, noiseEpochRun, noiseLoopCount, applyInFlight,
          activeNoise, oracleVars>>

\* -------------------------------------------------------------------------
\* Resource mutations, crash/restart, and temporal Khaos windows (S3, S4)
\* -------------------------------------------------------------------------

AgentMutate(resource, kind) ==
    \* The agent may create, edit, or delete abstract Kubernetes resources;
    \* reconciliation later sees only current-minus-baseline;
    \* sregym/service/cluster_state.py:184-350.
    /\ processUp
    /\ deployedRun = runGen
    /\ stage \in AgentStages
    /\ resource \in Resources
    /\ kind \in MutationKinds
    /\ ( \/ /\ kind = "create"
             /\ resource \notin clusterResources
             /\ clusterResources' = clusterResources \cup {resource}
             /\ runCreated' = runCreated \cup {resource}
             /\ resourceValue' =
                  [resourceValue EXCEPT ![resource] = AgentValue]
          \/ /\ kind = "overwrite"
             /\ resource \in clusterResources
             /\ clusterResources' = clusterResources
             /\ runCreated' = runCreated
             /\ resourceValue' =
                  [resourceValue EXCEPT ![resource] = AgentValue]
          \/ /\ kind = "delete"
             /\ resource \in clusterResources
             /\ clusterResources' = clusterResources \ {resource}
             /\ runCreated' = runCreated \ {resource}
             /\ resourceValue' = resourceValue )
    /\ UNCHANGED
        <<runVars, evalVars, cleanupVars, submissionVars, baselineVars,
          preexisting, preRunValue, deleteIssued, noiseVars, oracleVars>>

Crash ==
    \* Abnormal driver/API shutdown cleans agents/noise but does not invoke
    \* conductor recovery/reconciliation; main.py:537-563,630-652.
    /\ processUp
    /\ processUp' = FALSE
    /\ stage' = IdleStage
    /\ stageOwner' = NoRun
    /\ waitingForAgent' = FALSE
    /\ agentExitState' = "none"
    \* Executor/request/cleanup state is volatile process memory.
    /\ evalInFlight' = FALSE
    /\ evalRun' = NoRun
    /\ evalStage' = "none"
    /\ evalRequest' = NoRequest
    /\ evalOriginRun' = NoRun
    /\ evalOriginStage' = "none"
    /\ evalPhase' = "idle"
    /\ cleanupState' = [a \in CleanupActors |-> "idle"]
    /\ cleanupRun' = [a \in CleanupActors |-> NoRun]
    /\ submissionQueue' = <<>>
    /\ receivedQueue' = <<>>
    /\ pendingAcks' = <<>>
    \* Only persisted baseline data, not in-memory provenance, survives.
    /\ baselineGen' = NoRun
    /\ baselineComplete' = FALSE
    /\ observedFields' = {}
    /\ baselineResources' = {}
    /\ baselineValues' = [r \in Resources |-> CleanValue]
    /\ baselineCaptureState' = "unchecked"
    /\ baselineAuthoritative' = FALSE
    \* Threads die, but already-created Kubernetes noise resources remain.
    /\ noiseRun' = NoRun
    /\ noiseRunning' = FALSE
    /\ liveNoiseEpochs' = {}
    /\ noiseLoopCount' = 0
    /\ applyInFlight' = {}
    /\ noiseStopState' = "idle"
    /\ noiseStopOwner' = "none"
    /\ reinjectionActive' = {}
    /\ reattachPending' = {}
    /\ oracleState' = "idle"
    /\ oracleRun' = NoRun
    /\ oracleStage' = "none"
    /\ UNCHANGED
        <<runGen, runStage, maxStageRank, deployedRun, timeoutFired, doneRuns,
          resultsVersion, doneResultsVersion, acceptedByStage,
          gradedAcceptances, timedOutAcceptances, requestStatus,
          requestOriginRun, requestOriginStage, requestRetries, clusterGen,
          persistedBaseline, persistedBaselineGen, persistedBaselineComplete,
          resourceVars, noiseEpoch, noiseEpochRun, activeNoise,
          faultInjectedRuns, faultEffective, workloadHealthy, podGen,
          oraclePassed, quiescenceObserved>>

Restart ==
    \* A new process can start with the persisted home-directory cache and
    \* existing Kubernetes state; sregym/paths.py:11-16;
    \* sregym/conductor/conductor.py:43-89,787-796.
    /\ ~processUp
    /\ processUp' = TRUE
    /\ UNCHANGED
        <<runGen, stage, stageOwner, runStage, maxStageRank, waitingForAgent,
          deployedRun, timeoutFired, agentExitState, doneRuns, resultsVersion,
          doneResultsVersion, evalVars, cleanupVars, submissionVars,
          baselineVars, resourceVars, noiseVars, oracleVars>>

ReplaceCluster ==
    \* The cache path has no cluster identity/version, so replacing the cluster
    \* does not invalidate the persisted file; sregym/paths.py:11-16;
    \* cluster_state.py:82-113.
    /\ ~processUp
    /\ clusterGen < MaxClusterGen
    /\ clusterGen' = clusterGen + 1
    /\ clusterResources' = Resources
    /\ preexisting' = Resources
    /\ runCreated' = {}
    /\ resourceValue' = [r \in Resources |-> ReplacementValue]
    /\ preRunValue' = [r \in Resources |-> ReplacementValue]
    /\ deleteIssued' = {}
    /\ deployedRun' = NoRun
    /\ activeNoise' = {}
    /\ faultEffective' = [g \in RunIds |-> FALSE]
    /\ workloadHealthy' = [g \in RunIds |-> TRUE]
    /\ podGen' = [g \in RunIds |-> 0]
    /\ reinjectionActive' = {}
    /\ reattachPending' = {}
    /\ UNCHANGED
        <<processUp, runGen, stage, stageOwner, runStage, maxStageRank,
          waitingForAgent, timeoutFired, agentExitState, doneRuns,
          resultsVersion, doneResultsVersion, evalVars, cleanupVars,
          submissionVars, baselineGen, baselineComplete, observedFields,
          baselineResources, baselineValues, baselineCaptureState,
          baselineAuthoritative, persistedBaseline, persistedBaselineGen,
          persistedBaselineComplete, noiseEpoch, noiseRun, noiseRunning,
          liveNoiseEpochs, noiseEpochRun, noiseLoopCount, applyInFlight,
          noiseStopState, noiseStopOwner, faultInjectedRuns, oracleState,
          oracleRun, oracleStage, oraclePassed, quiescenceObserved>>

RestartPod ==
    \* A restarted container gets a new host PID, so the pinned eBPF fault
    \* temporarily disappears; khaos_faults.py:168-177,259-270.
    /\ processUp
    /\ stage \in AgentStages
    /\ runGen \in reinjectionActive
    /\ faultEffective[runGen]
    /\ podGen[runGen] < MaxResultVersion
    /\ faultEffective' = [faultEffective EXCEPT ![runGen] = FALSE]
    /\ workloadHealthy' = [workloadHealthy EXCEPT ![runGen] = TRUE]
    /\ podGen' = [podGen EXCEPT ![runGen] = @ + 1]
    /\ reattachPending' = reattachPending \cup {runGen}
    /\ UNCHANGED
        <<runVars, evalVars, cleanupVars, submissionVars, baselineVars,
          resourceVars, noiseVars, faultInjectedRuns, reinjectionActive,
          oracleState, oracleRun, oracleStage, oraclePassed,
          quiescenceObserved>>

ReattachFault ==
    \* The monitor re-checks stop, resolves the new PID, and then re-injects;
    \* khaos_faults.py:149-191.
    /\ processUp
    /\ runGen \in reattachPending
    /\ runGen \in reinjectionActive
    /\ faultEffective' = [faultEffective EXCEPT ![runGen] = TRUE]
    /\ workloadHealthy' = [workloadHealthy EXCEPT ![runGen] = FALSE]
    /\ reattachPending' = reattachPending \ {runGen}
    /\ UNCHANGED
        <<runVars, evalVars, cleanupVars, submissionVars, baselineVars,
          resourceVars, noiseVars, faultInjectedRuns, podGen,
          reinjectionActive, oracleState, oracleRun, oracleStage,
          oraclePassed, quiescenceObserved>>

\* -------------------------------------------------------------------------
\* Next-state relation
\* -------------------------------------------------------------------------

Next ==
    \/ StartProblem
    \/ LoadBaselineState
    \/ BeginBaselineCapture
    \/ \E field \in BaselineFields, ok \in BOOLEAN :
        ObserveBaseline(field, ok)
    \/ PersistBaselineState
    \/ DeployProblem
    \/ InjectFault
    \/ AdvanceToFirstStage
    \/ \E req \in RequestIds : SendSubmission(req)
    \/ \E k \in 1..Len(submissionQueue) : DelayOrDuplicate(k)
    \/ \E k \in 1..Len(submissionQueue) : ReceiveSubmission(k)
    \/ \E k \in 1..Len(receivedQueue) : RetrySubmission(k)
    \/ \E k \in 1..Len(receivedQueue) : ConductorSubmitAccept(k)
    \/ \E k \in 1..Len(receivedQueue) : ConductorSubmitDuplicate(k)
    \/ \E k \in 1..Len(receivedQueue) : ConductorSubmitLate(k)
    \/ Acknowledge
    \/ BeginEvaluation
    \/ BeginOracle
    \/ CompleteOracle
    \/ CompleteEvaluation
    \/ AdvanceStageAfterEvaluation
    \/ FinishEvaluationFuture
    \/ AgentMitigate
    \/ AgentTimeout
    \/ AgentExit
    \/ AgentExitWaitTimeout
    \/ AgentExitAfterEvaluation
    \/ \E actor \in CleanupActors : FinishProblemCheck(actor)
    \/ \E actor \in CleanupActors : BeginCleanup(actor)
    \/ \E actor \in CleanupActors : CompleteRecovery(actor)
    \/ \E actor \in CleanupActors, resource \in Resources :
        ReconcileDelete(actor, resource)
    \/ \E actor \in CleanupActors, resource \in Resources :
        ReconcileRestore(actor, resource)
    \/ \E actor \in CleanupActors : CompleteCleanup(actor)
    \/ NoiseManagerStart
    \/ BeginNoiseApply
    \/ \E epoch \in 1..MaxNoiseEpoch : CompleteNoiseApply(epoch)
    \/ \E epoch \in 1..MaxNoiseEpoch : NoiseLoopExit(epoch)
    \/ \E owner \in NoiseStopOwners \ {"none"} :
        NoiseManagerStop(owner)
    \/ NoiseManagerJoinComplete
    \/ NoiseManagerJoinTimeout
    \/ NoiseManagerCleanupRecorded
    \/ NoiseManagerForceRemove
    \/ NoiseManagerStopReturn
    \/ \E resource \in Resources, kind \in MutationKinds :
        AgentMutate(resource, kind)
    \/ Crash
    \/ Restart
    \/ ReplaceCluster
    \/ RestartPod
    \/ ReattachFault

Spec == Init /\ [][Next]_vars

\* -------------------------------------------------------------------------
\* Type and structural invariants
\* -------------------------------------------------------------------------

TypeOK ==
    /\ processUp \in BOOLEAN
    /\ runGen \in RunIds
    /\ stage \in Stages
    /\ stageOwner \in {NoRun} \cup RunIds
    /\ runStage \in [RunIds -> Stages]
    /\ maxStageRank \in [RunIds -> 0..5]
    /\ waitingForAgent \in BOOLEAN
    /\ deployedRun \in {NoRun} \cup RunIds
    /\ timeoutFired \subseteq LiveRunIds
    /\ agentExitState \in AgentExitStates
    /\ doneRuns \subseteq LiveRunIds
    /\ resultsVersion \in [RunIds -> 0..MaxResultVersion]
    /\ doneResultsVersion \in [RunIds -> 0..MaxResultVersion]

    /\ evalInFlight \in BOOLEAN
    /\ evalRun \in {NoRun} \cup RunIds
    /\ evalStage \in EvalStages
    /\ evalRequest \in {NoRequest} \cup RequestIds
    /\ evalOriginRun \in {NoRun} \cup RunIds
    /\ evalOriginStage \in EvalStages
    /\ evalPhase \in EvalPhases

    /\ cleanupState \in [CleanupActors -> CleanupStates]
    /\ cleanupRun \in [CleanupActors -> ({NoRun} \cup RunIds)]

    /\ submissionQueue \in BoundedSeq(SubmissionUniverse)
    /\ receivedQueue \in BoundedSeq(SubmissionUniverse)
    /\ pendingAcks \in BoundedSeq(RequestIds)
    /\ acceptedByStage \subseteq AcceptanceUniverse
    /\ gradedAcceptances \subseteq AcceptanceUniverse
    /\ timedOutAcceptances \subseteq AcceptanceUniverse
    /\ requestStatus \in [RequestIds -> RequestStates]
    /\ requestOriginRun \in [RequestIds -> ({NoRun} \cup RunIds)]
    /\ requestOriginStage \in [RequestIds -> EvalStages]
    /\ requestRetries \in [RequestIds -> 0..MaxRetries]

    /\ clusterGen \in 0..MaxClusterGen
    /\ baselineGen \in {NoRun} \cup (0..MaxClusterGen)
    /\ baselineComplete \in BOOLEAN
    /\ observedFields \subseteq BaselineFields
    /\ baselineResources \subseteq Resources
    /\ baselineValues \in [Resources -> ResourceValues]
    /\ baselineCaptureState \in BaselineCaptureStates
    /\ baselineAuthoritative \in BOOLEAN
    /\ persistedBaseline \in PersistedBaselineType
    /\ persistedBaselineGen \in {NoRun} \cup (0..MaxClusterGen)
    /\ persistedBaselineComplete \in BOOLEAN

    /\ clusterResources \subseteq Resources
    /\ preexisting \subseteq Resources
    /\ runCreated \subseteq Resources
    /\ resourceValue \in [Resources -> ResourceValues]
    /\ preRunValue \in [Resources -> ResourceValues]
    /\ deleteIssued \subseteq DeleteUniverse

    /\ noiseEpoch \in 0..MaxNoiseEpoch
    /\ noiseRun \in {NoRun} \cup RunIds
    /\ noiseRunning \in BOOLEAN
    /\ liveNoiseEpochs \subseteq 1..MaxNoiseEpoch
    /\ noiseEpochRun \in
        [0..MaxNoiseEpoch -> ({NoRun} \cup RunIds)]
    /\ noiseLoopCount \in 0..MaxNoiseEpoch
    /\ applyInFlight \subseteq 1..MaxNoiseEpoch
    /\ activeNoise \subseteq 1..MaxNoiseEpoch
    /\ noiseStopState \in NoiseStopStates
    /\ noiseStopOwner \in NoiseStopOwners

    /\ faultInjectedRuns \subseteq LiveRunIds
    /\ faultEffective \in [RunIds -> BOOLEAN]
    /\ workloadHealthy \in [RunIds -> BOOLEAN]
    /\ podGen \in [RunIds -> 0..MaxResultVersion]
    /\ reinjectionActive \subseteq LiveRunIds
    /\ reattachPending \subseteq LiveRunIds
    /\ oracleState \in OracleStates
    /\ oracleRun \in {NoRun} \cup RunIds
    /\ oracleStage \in EvalStages
    /\ oraclePassed \subseteq LiveRunIds
    /\ quiescenceObserved \in [RunIds -> BOOLEAN]

CurrentStageConsistent ==
    stage = IdleStage \/ runStage[runGen] = stage

NoiseLoopCountConsistent ==
    noiseLoopCount = Cardinality(liveNoiseEpochs)

NoiseSetsConsistent ==
    /\ applyInFlight \subseteq liveNoiseEpochs
    /\ activeNoise \subseteq 1..noiseEpoch

EvaluationMetadataConsistent ==
    evalInFlight =>
        /\ evalRun \in LiveRunIds
        /\ evalStage \in AgentStages
        /\ evalRequest \in RequestIds
        /\ evalPhase /= "idle"

CleanupMetadataConsistent ==
    \A actor \in CleanupActors :
        cleanupState[actor] /= "idle" =>
            cleanupRun[actor] \in LiveRunIds

AcceptanceAccounting ==
    /\ gradedAcceptances \subseteq acceptedByStage
    /\ timedOutAcceptances \subseteq acceptedByStage

\* -------------------------------------------------------------------------
\* Brief §5 safety invariants
\* -------------------------------------------------------------------------

ReferenceStageOrder ==
    \A g \in 1..runGen :
        StageRank(runStage[g]) = maxStageRank[g]

OneAcceptedPerStage ==
    \A g \in LiveRunIds, s \in AgentStages :
        Cardinality(
            {a \in acceptedByStage :
                a.acceptedRun = g /\ a.acceptedStage = s}) <= 1

SubmissionOriginMatches ==
    \A a \in acceptedByStage :
        /\ a.originRun = a.acceptedRun
        /\ a.originStage = a.acceptedStage

DoneIsTerminal ==
    \A g \in doneRuns :
        /\ runStage[g] = DoneStage
        /\ resultsVersion[g] = doneResultsVersion[g]

NoEvaluationDuringTeardown ==
    ~ \E actor \in CleanupActors :
        /\ evalInFlight
        /\ cleanupState[actor] \in CleanupActiveStates
        /\ cleanupRun[actor] = evalRun

NoOverlappingRuns ==
    /\ deployedRun \in {NoRun, runGen}
    /\ (evalInFlight => evalRun = runGen)
    /\ \A actor \in CleanupActors :
        cleanupState[actor] \in CleanupActiveStates =>
            cleanupRun[actor] = runGen
    /\ \A epoch \in liveNoiseEpochs \cup applyInFlight \cup activeNoise :
        noiseEpochRun[epoch] = runGen

FaultBeforeDiagnosis ==
    \A g \in LiveRunIds :
        runStage[g] = DiagnosisStage =>
            /\ g \in faultInjectedRuns
            /\ faultEffective[g]

BaselineMatchesCluster ==
    baselineAuthoritative =>
        /\ baselineComplete
        /\ baselineGen = clusterGen

PreexistingResourcesPreserved ==
    stage = DoneStage =>
        /\ preexisting \subseteq clusterResources
        /\ \A r \in preexisting :
            resourceValue[r] = preRunValue[r]

CleanupDeletesOnlyRunOwned ==
    \A d \in deleteIssued : d.owned

NoiseQuiescentAtEvaluation ==
    oracleState = "evaluating" =>
        /\ activeNoise = {}
        /\ applyInFlight = {}

OraclePassImpliesMitigated ==
    \A g \in oraclePassed :
        /\ ~faultEffective[g]
        /\ workloadHealthy[g]

\* -------------------------------------------------------------------------
\* Brief §5 liveness properties (conditional on fair, terminating effects)
\* -------------------------------------------------------------------------

AcceptedSubmissionTerminates ==
    \A a \in AcceptanceUniverse :
        (a \in acceptedByStage)
            ~> (a \in gradedAcceptances \/ a \in timedOutAcceptances)

TeardownEventuallyCompletes ==
    \A g \in LiveRunIds :
        (\E actor \in CleanupActors :
            cleanupRun[actor] = g
            /\ cleanupState[actor] \in CleanupActiveStates)
        ~> (g \in doneRuns)

RunGenerationMonotonic ==
    [] [runGen' >= runGen]_vars

ClusterGenerationMonotonic ==
    [] [clusterGen' >= clusterGen]_vars

=============================================================================
