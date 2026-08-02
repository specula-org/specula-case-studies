# Instrumentation Specification: SREGym Lifecycle

This document is the handoff contract for producing NDJSON traces accepted by
`Trace.tla`. Instrumentation is observational: trace-only generations, request
IDs, provenance flags, and abstract resource identities must not affect
Conductor decisions.

## Section 1: Trace Event Schema

### Event envelope

Every semantic boundary emits exactly one line after applying that boundary's
shadow-state update:

```json
{
  "tag": "trace",
  "timestamp_ns": 123456789,
  "event": {
    "name": "ConductorSubmitAccept",
    "params": {
      "queue_index": 1,
      "request_id": "req-0001"
    },
    "state": {
      "...": "complete abstract post-state described below"
    }
  }
}
```

`event.params` is always present, using `{}` when the action has no parameters.
`event.state` is mandatory on every event. Event names are case-sensitive and
must exactly match the action/event column in Section 2.

### Encoding rules

- TLA+ sets are sorted JSON arrays. Order is ignored by `Trace.tla`.
- TLA+ sequences remain JSON arrays in sequence order.
- Functions over run IDs are arrays indexed as `array[run_id]` in the
  implementation; JSON element 0 becomes TLA+ function entry 0.
- `noise_epoch_run` is likewise an array indexed by epoch, including epoch 0.
- Functions over string domains (`request_status`, `resource_value`,
  `cleanup_state`) are JSON objects.
- The TLA+ sentinel `NoRequest` is serialized as `"__none__"`.
- Submission records use exactly `requestId`, `originRun`, and `originStage`.
- Acceptance records use exactly `requestId`, `originRun`, `originStage`,
  `acceptedRun`, and `acceptedStage`.
- Delete ledger records use exactly `run`, `resource`, and `owned`.

### Complete post-state fields

The trace shadow recorder captures these fields on every event. This is
deliberately a full snapshot: `ValidatePostState` checks every field after every
base action.

| JSON field | TLA+ variable | Source or shadow derivation |
|---|---|---|
| `process_up` | `processUp` | Trace process lifecycle flag |
| `run_gen` | `runGen` | Monotonic trace-only generation incremented at `StartProblem` |
| `stage` | `stage` | `Conductor.submission_stage` |
| `stage_owner` | `stageOwner` | Trace-only generation of the actor that wrote `stage` |
| `run_stage` | `runStage` | Shadow array of last stage per generation |
| `max_stage_rank` | `maxStageRank` | Shadow high-water stage rank per generation |
| `waiting_for_agent` | `waitingForAgent` | `Conductor.waiting_for_agent` |
| `deployed_run` | `deployedRun` | Shadow generation owning the deployed app, or `-1` |
| `timeout_fired` | `timeoutFired` | Shadow set of generations timed out by `main.py` |
| `agent_exit_state` | `agentExitState` | Shadow `none`/`waiting`/`expired` |
| `done_runs` | `doneRuns` | Shadow set |
| `results_version` | `resultsVersion` | Shadow counter incremented on result/timeout writes |
| `done_results_version` | `doneResultsVersion` | First-done snapshot per generation |
| `eval_in_flight` | `evalInFlight` | Shadow `_submit_future` lifecycle |
| `eval_run`, `eval_stage`, `eval_request` | `evalRun`, `evalStage`, `evalRequest` | Captured at accepted submission |
| `eval_origin_run`, `eval_origin_stage` | `evalOriginRun`, `evalOriginStage` | Trace envelope provenance |
| `eval_phase` | `evalPhase` | Shadow split-point program counter |
| `cleanup_state`, `cleanup_run` | `cleanupState`, `cleanupRun` | Objects keyed by `driver` and `evaluator` |
| `submission_queue`, `received_queue` | `submissionQueue`, `receivedQueue` | Trace transport-shadow sequences |
| `pending_acks` | `pendingAcks` | Trace shadow sequence of request IDs |
| `accepted_by_stage`, `graded_acceptances`, `timed_out_acceptances` | Corresponding TLA+ sets | Arrays of acceptance records |
| `request_status`, `request_origin_run`, `request_origin_stage`, `request_retries` | Corresponding TLA+ functions | Objects keyed by trace request ID |
| `cluster_gen` | `clusterGen` | Harness cluster-lifetime generation |
| `baseline_gen`, `baseline_complete` | Corresponding TLA+ ghost variables | Actual capture provenance and aggregate getter success |
| `observed_fields` | `observedFields` | `resources` and/or `values` |
| `baseline_resources`, `baseline_values` | Corresponding TLA+ variables | Abstracted captured identities/values |
| `baseline_capture_state`, `baseline_authoritative` | Corresponding TLA+ variables | Shadow capture/load phase |
| `persisted_baseline` | `persistedBaseline` | Object with `exists`, resource array, and value object |
| `persisted_baseline_gen`, `persisted_baseline_complete` | Ghost provenance of persisted bytes | Recorded by tracer when bytes are written |
| `cluster_resources`, `preexisting`, `run_created` | Corresponding abstract sets | Cluster watcher mapped to the two abstract identities |
| `resource_value`, `pre_run_value` | Corresponding functions | Objects keyed by `preexisting-resource` and `run-resource` |
| `delete_issued` | `deleteIssued` | Array of delete ledger records |
| `noise_epoch`, `noise_run`, `noise_running` | Corresponding TLA+ variables | Noise trace shadow + `NoiseManager.running` |
| `live_noise_epochs`, `noise_epoch_run`, `noise_loop_count` | Corresponding TLA+ variables | Shadow daemon-thread ledger |
| `apply_in_flight`, `active_noise` | Corresponding TLA+ sets | Shadow epoch sets |
| `noise_stop_state`, `noise_stop_owner` | Corresponding TLA+ variables | Shadow split-point PC and caller |
| `fault_injected_runs`, `fault_effective` | Corresponding TLA+ variables | Fault lifecycle shadow + Khaos/predicate watcher |
| `workload_healthy`, `pod_gen` | Corresponding TLA+ variables | Abstract workload probe and pod/container generation |
| `reinjection_active`, `reattach_pending` | Corresponding TLA+ sets | Reinjection monitor lifecycle |
| `oracle_state`, `oracle_run`, `oracle_stage`, `oracle_passed` | Corresponding TLA+ variables | Oracle call/result shadow |
| `quiescence_observed` | `quiescenceObserved` | Computed at `BeginOracle` from active/in-flight noise |

### Abstract resource mapping

The model intentionally does not serialize Kubernetes schemas.

- `preexisting-resource` represents any identity/value present before the
  benchmark run (namespace, cluster-scoped object, node metadata, or CoreDNS
  data).
- `run-resource` represents any identity created after the baseline.
- The watcher updates `preexisting`, `run_created`, and the abstract value maps
  from concrete Kubernetes audit/watch events.
- A current-minus-baseline deletion emits one `ReconcileDelete` per abstract
  identity class actually targeted.

## Section 2: Action-to-Code Mapping

Every row captures the complete Section 1 state snapshot in addition to the
listed parameters.

### Run setup and baseline

| Spec action / event | Code location | Exact trigger point | Event parameters and notes |
|---|---|---|---|
| `StartProblem` | `sregym/conductor/conductor.py:388-414,782-796` | After `deploy_app` writes `self.submission_stage = "setup"` at line 785; the tracer has already incremented `run_gen` and incorporated the resets at lines 409-414 | `{}`. This is the first event for a normal run. |
| `LoadBaselineState` | `sregym/service/cluster_state.py:165-182`; `sregym/conductor/conductor.py:790-796` | After `ClusterBaseline.from_json` assigns `self.baseline` and before `load_baseline_state` returns `True` | `{}`. Restore trace-only persisted generation/completeness alongside the implementation projection. |
| `BeginBaselineCapture` | `sregym/service/cluster_state.py:130-137,153-159` | Immediately before the first getter in `capture_baseline` | `{}`. Initialize aggregate success to true and clear observed abstract fields. |
| `ObserveBaseline` | `sregym/service/cluster_state.py:137-149,352-395,451-511` | Emit `field="resources"` after the identity getters through line 145; emit `field="values"` after node/CoreDNS getters through line 149 | `{"field":"resources|values","ok":bool}`. Getter exception branches must set a trace-only failure bit before returning empty. |
| `PersistBaselineState` | `sregym/service/cluster_state.py:153-163` | After `json.dump` completes at line 162 | `{}`. Store actual ghost provenance with the persisted-byte shadow record; do not add it to production JSON. |
| `DeployProblem` | `sregym/conductor/conductor.py:434-439,782-825` | After `self.deploy_app()` returns at line 438 | `{}`. Update abstract created-resource ownership from the cluster watcher. |
| `InjectFault` | `sregym/conductor/conductor.py:219-240` | After `self.fault_injected = True` at line 231 | `{}`. Mark intended fault effective and, for Khaos problems, reinjection active. |
| `AdvanceToFirstStage` | `sregym/conductor/conductor.py:281-314,455-456` | After lines 304-306 set waiting and the first stage | `{}`. If a future task list skips diagnosis, extend the model before tracing that configuration. |

### Submission transport, acceptance, and acknowledgment

| Spec action / event | Code location | Exact trigger point | Event parameters and notes |
|---|---|---|---|
| `SendSubmission` | `clients/tierzero/driver.py:187-199`; `clients/stratus/tools/submit_tool.py:57-77,155-172` | Immediately before the HTTP POST or MCP `call_tool` leaves the client | `{"request_id":"..."}`. Generate a trace-only ID and record current origin run/stage; carry it in tracing context/header only. |
| `DelayOrDuplicate` | Transport trace shim associated with `sregym/conductor/conductor_api.py:42-51,128-145` | When the shim retains/delivers an additional copy before API receipt | `{"queue_index":n,"request_id":"..."}`. This is a harness adversary event, not a production behavior change. |
| `ReceiveSubmission` | `sregym/conductor/conductor_api.py:23-43,110-132` | After the endpoint stage precheck succeeds and before entering the retry loop | `{"queue_index":n,"request_id":"..."}`. Move the selected transport-shadow envelope to `received_queue`. |
| `RetrySubmission` | `sregym/conductor/conductor_api.py:47-51,136-145` | In each `RuntimeError` branch, before the one-second sleep | `{"queue_index":n,"request_id":"..."}`. Increment only the trace retry count. |
| `ConductorSubmitAccept` | `sregym/conductor/conductor.py:550-565` | After `_submit_future` is assigned at line 565 | `{"queue_index":n,"request_id":"..."}`. Capture current accepted run/stage while retaining origin only in trace shadow. |
| `ConductorSubmitDuplicate` | `sregym/conductor/conductor.py:537-548` | Immediately before returning the “already accepted” result at line 543 | `{"queue_index":n,"request_id":"..."}`. The shadow request is discarded and an acknowledgment is queued. |
| `ConductorSubmitLate` | `sregym/conductor/conductor.py:523-535` | Immediately before a done/tearing-down/no-stage return | `{"queue_index":n,"request_id":"..."}`. Use only for a request that passed the earlier endpoint precheck. |
| `Acknowledge` | `sregym/conductor/conductor_api.py:45-46,133-135` | Immediately before either endpoint returns generic success | `{"request_id":"..."}` is optional to humans but the shadow recorder must remove the head pending acknowledgment exactly as `Trace.tla` does. |

### Evaluation and stage advancement

| Spec action / event | Code location | Exact trigger point | Event parameters and notes |
|---|---|---|---|
| `BeginEvaluation` | `sregym/conductor/conductor.py:468-483` | At executor entry after `stage_name` is read and immediately before calling `NoiseManager.stop` | `{}`. Advance shadow `eval_phase` to `stoppingNoise`. |
| `BeginOracle` | `sregym/conductor/conductor.py:485-491` | Immediately before `current_stage["evaluation"](sol)` | `{}`. Compute `quiescence_observed` from shadow `active_noise` and `apply_in_flight`. |
| `CompleteOracle` | `sregym/conductor/conductor.py:242-279,485-500` | Immediately after the evaluation function returns or its outer exception fallback is recorded | `{}`. For mitigation, add `oracle_passed` only from the actual success plus the abstract state observed at this point. |
| `CompleteEvaluation` | `sregym/conductor/conductor.py:485-502` | Immediately after `_evaluating = False` at line 501 | `{}`. Increment result version and mark the captured acceptance graded. |
| `AdvanceStageAfterEvaluation` | `sregym/conductor/conductor.py:503-505`; `_advance_to_next_stage` at `281-317` | Immediately after `_advance_to_next_stage` returns | `{}`. Diagnosis exposes mitigation; mitigation requests evaluator-owned cleanup. |
| `FinishEvaluationFuture` | `sregym/conductor/conductor.py:468-514,556-566` | In a `finally` at the outermost return of `_submit_evaluate_and_advance`, after optional noise restart | `{}`. This marks the actual `_submit_future` work complete; emit after evaluator cleanup when mitigation is final. |
| `AgentMitigate` | Agent/Kubernetes effect watcher; evaluation consumer at `sregym/conductor/conductor.py:262-279` | When the watched intended-fault predicate first becomes ineffective and workload health is restored during mitigation | `{}`. Observation-only external-effect event; do not infer mitigation merely from solution text. |

### Driver exit and teardown ownership

| Spec action / event | Code location | Exact trigger point | Event parameters and notes |
|---|---|---|---|
| `AgentTimeout` | `main.py:393-404` | After timeout result fields are written at lines 400-401 and immediately before `_finish_problem()` at line 403 | `{}`. Mark all ungraded current-run acceptances explicitly timed out. |
| `AgentExit` | `main.py:406-425` | After detecting non-`None` return code; before waiting on an unfinished future, or before direct cleanup if no future exists | `{}`. Set shadow exit state to `waiting` or `expired` according to the branch. |
| `AgentExitWaitTimeout` | `main.py:412-424` | In the `TimeoutError` branch after line 420 and before `_finish_problem` | `{}`. |
| `AgentExitAfterEvaluation` | `main.py:412-425` | After the awaited future completes successfully and immediately before `_finish_problem` | `{}`. |
| `FinishProblemCheck` | `sregym/conductor/conductor.py:367-384` | After evaluating the guard at line 378 but before either return at 382 or write at 384 | `{"actor":"driver|evaluator"}`. Determine actor from thread-local trace context. Both actors may emit `checked` before either writes teardown. |
| `BeginCleanup` | `sregym/conductor/conductor.py:383-385` | Immediately after `submission_stage = "tearing_down"` at line 384 and before `_cleanup_sync` | `{"actor":"driver|evaluator"}`. |
| `CompleteRecovery` | `sregym/conductor/conductor.py:319-350`; Khaos stop at `problems/khaos_faults.py:272-280` | After fault recovery and `problem.app.cleanup()` complete at line 350, before reconciliation | `{"actor":"driver|evaluator"}`. Remove reinjection activity only after the monitor stop/recovery path completes. |
| `ReconcileDelete` | `sregym/service/cluster_state.py:208-335` | After each successful current-minus-baseline delete call | `{"actor":"driver|evaluator","resource":"preexisting-resource|run-resource"}`. Record whether the target belonged to the current run before removing it. |
| `ReconcileRestore` | `sregym/service/cluster_state.py:337-347` and its label/taint/CoreDNS helpers | After each abstract mutable-value restoration succeeds | `{"actor":"driver|evaluator","resource":"preexisting-resource|run-resource"}`. Never emit for recreation; current code does not recreate missing identities. |
| `CompleteCleanup` | `sregym/conductor/conductor.py:352-365` | Immediately after `submission_stage = "done"` at line 364 | `{"actor":"driver|evaluator"}`. Capture `done_results_version` only on the first completion for that generation. |

### Noise manager

| Spec action / event | Code location | Exact trigger point | Event parameters and notes |
|---|---|---|---|
| `NoiseManagerStart` | `sregym/generators/noise/manager.py:71-82`; callers at `conductor.py:441-452,507-514` | After `_background_thread.start()` at line 81 | `{}`. Allocate the next noise epoch and associate it with current run. |
| `BeginNoiseApply` | `sregym/generators/noise/manager.py:125-150` | Immediately before blocking `kubectl apply` at line 150 | `{}`. Add current epoch to `apply_in_flight`. |
| `CompleteNoiseApply` | `sregym/generators/noise/manager.py:150-157` | After appending to `active_experiments` at line 155 | `{"epoch":n}`. This event may occur after stop/cleanup returned. |
| `NoiseLoopExit` | `sregym/generators/noise/manager.py:99-105` | In a `finally` when `_background_loop` actually exits | `{"epoch":n}`. Remove the real live epoch; do not infer exit from clearing `_background_thread`. |
| `NoiseManagerStop` | `sregym/generators/noise/manager.py:84-88` | Immediately after `running = False` and before `join(timeout=5)` | `{"owner":"evaluation|driver|evaluator"}` from caller trace context. |
| `NoiseManagerJoinComplete` | `sregym/generators/noise/manager.py:87-90` | After `join` returns, only if `thread.is_alive()` is false | `{}`. Add the `is_alive` observation; current code clears the reference either way. |
| `NoiseManagerJoinTimeout` | `sregym/generators/noise/manager.py:87-90` | After `join` returns, when `thread.is_alive()` remains true, and before clearing the reference | `{}`. |
| `NoiseManagerCleanupRecorded` | `sregym/generators/noise/manager.py:176-203` | Immediately after `active_experiments.clear()` at line 203 | `{}`. |
| `NoiseManagerForceRemove` | `sregym/generators/noise/manager.py:205-245` | After `_force_remove_all_chaos_resources` returns | `{}`. It sees only resources present at scan time. |
| `NoiseManagerStopReturn` | `sregym/generators/noise/manager.py:84-95` | After `_last_injection_time = 0` and immediately before/after the final log at line 95 | `{}`. Transfer the owner PC to `oracleReady` or `recovering`. |

### Resource, crash, and reinjection events

| Spec action / event | Code location | Exact trigger point | Event parameters and notes |
|---|---|---|---|
| `AgentMutate` | Kubernetes audit/watch collector for agent-originated operations; reconciliation consumer at `cluster_state.py:184-350` | After a watched abstract identity is created, overwritten, or deleted | `{"resource":"preexisting-resource|run-resource","kind":"create|overwrite|delete"}`. Filter to agent-originated effects; benchmark deployment has its own event. |
| `Crash` | `main.py:537-563,630-652` | In the durable trace supervisor when the SREGym process exits without a completed Conductor teardown | `{}`. Flush this event outside the crashing process; preserve only Kubernetes/persisted-baseline shadow state. |
| `Restart` | `sregym/conductor/conductor.py:43-89,787-796` | After constructing the new Conductor but before the next `start_problem` | `{}`. Rehydrate only the persistent/external portion of trace shadow. |
| `ReplaceCluster` | Fixed path at `sregym/paths.py:11-16`; load path at `cluster_state.py:165-182` | Harness event after a new cluster identity is provisioned while the same home cache remains | `{}`. Increment `cluster_gen`; classify new-cluster initial identities as preexisting. |
| `RestartPod` | Reinjection detection at `sregym/conductor/problems/khaos_faults.py:149-177,259-270` | When a new container ID is observed, before resolving/reinjecting into its host PID | `{}`. Increment current `pod_gen`, mark intended fault temporarily ineffective, and set reattach pending. |
| `ReattachFault` | `sregym/conductor/problems/khaos_faults.py:173-191` | After `_exec_khaos_fault_on_node` succeeds at line 184 and before/with updating the remembered container ID | `{}`. Mark the intended fault effective again and clear pending reattachment. |

## Section 3: Special Considerations

### 1. One global ordered stream

SREGym uses driver, API, executor, noise, and monitor threads. Emit through a
single trace writer with a monotonic sequence lock. Acquire that lock only
around shadow update plus serialization; do not hold it across Kubernetes,
oracle, network, join, or evaluator calls. File order is the modeled action
order.

### 2. Shadow metadata is mandatory and observation-only

The implementation deliberately lacks run/stage/request correlation. The
tracer must therefore maintain:

- monotonic `run_gen`;
- trace request IDs and their origin run/stage;
- stage/result high-water marks;
- actual baseline capture generation/completeness;
- cleanup caller PCs;
- noise epoch/thread/apply ledgers; and
- abstract resource provenance.

Do not pass these values into `Conductor.submit`, use them in guards, or alter
retry behavior. A tracing header or `ContextVar` may correlate events, but the
application must continue to interpret only solution text.

### 3. Full snapshot atomicity

Build `event.state` from the trace shadow under the writer lock. Directly read
the relevant implementation field at the trigger point, update the shadow, and
serialize the resulting complete snapshot. Do not take a later best-effort
snapshot: evaluation/cleanup and late noise effects can change state between
the semantic boundary and logging.

### 4. Baseline getter outcome

Current getters erase `ApiException` by returning an empty value. Instrument
the exception branches at `cluster_state.py:352-395,451-511` so the enclosing
capture can emit `ok=false`; inferring success from the returned empty set would
make `baseline_complete` incorrectly true.

### 5. Stop/join observation

Add `thread.is_alive()` immediately after the five-second join. Clearing
`_background_thread` is not evidence that the loop stopped. The original thread
object/epoch must remain in trace shadow until `NoiseLoopExit`.

### 6. Bootstrap contract

`TraceInit` models a fresh SREGym process, cluster generation 0, one abstract
preexisting resource, and no persisted baseline file. Default trace collection
must therefore use a fresh test cluster and remove only the dedicated test
cache file before capture. Tracing an already-running process needs a future
explicit bootstrap action; do not weaken `TraceInit` or fabricate `Init`.

### 7. Crash durability

The `Crash` event cannot rely on the dying process's buffered writer. A
supervisor should own the file descriptor or synthesize the event from the last
durably acknowledged shadow snapshot and process exit status.

### 8. Trace sizing and bounds

The default `Trace.cfg` supports two runs, four noise epochs, four queued
messages, sixty retries, and result/pod versions through eight. Increase the
matching constants for longer traces; never truncate arrays or drop events to
fit a bound.

### 9. No silent actions

Every split base action above has an event. In particular, emit separate events
for stop, join result, recorded cleanup, force removal, stop return, oracle
begin/end, evaluation completion, stage advance, and future completion. The
trace spec intentionally contains no silent action that could hide one of these
windows.
