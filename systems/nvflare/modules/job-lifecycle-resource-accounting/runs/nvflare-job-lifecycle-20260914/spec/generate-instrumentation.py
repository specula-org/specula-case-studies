from pathlib import Path
import json
P=Path(__file__).resolve().parent
A=json.loads((P/'trace-actions.json').read_text())
triggers={
'DefaultJobSchedulerBeginPass':'After taking the submitted-candidate snapshot and passing the locked capacity check; before inspecting its first candidate.',
'DefaultJobSchedulerEndPass':'After the final candidate; before schedule_job processes accumulated failed/blocked metadata.',
'DefaultJobSchedulerSkipBackoff':'At the time_since_last_schedule < required_interval continue branch, with the saved candidate ID.',
'DefaultJobSchedulerBackoffElapsed':'When monotonic elapsed time first satisfies the recorded backoff for this candidate; emit an observational deadline crossing.',
'DefaultJobSchedulerExhausted':'After appending this candidate to blocked_jobs and updating its history; before continuing the scan.',
'DefaultJobSchedulerTryJob':'At _try_job entry after retry/capacity gates; capture local candidate ID and assign a fresh attempt alias before sending checks.',
'ServerEngineCheckClientResources':'After enqueueing the batch of CHECK_RESOURCE requests and opening waiter slots; before the blocking wait.',
'CheckResourceProcessorReserve':'Inside the RM lock, after popleft and reserved_resources[token] assignment; capture the deque, UUID, payload and TTL before unlock.',
'CheckResourceProcessorUnavailable':'Inside the RM lock, after the unavailable decision and before returning the negative check result.',
'DefaultJobSchedulerEvaluateResources':'After inspecting all returned check results and computing dispatch/minimum/required-site decision; before cancellation or success return.',
'ServerEngineCancelClientResources':'After enqueueing cancellation requests for known positive tokens, before waiting for replies.',
'CancelResourceProcessorCancel':'Inside the RM lock after conditional token pop and appendleft, including the missing-token no-op branch.',
'DefaultJobSchedulerCancelReturned':'After _send_admin_requests returns, before returning from cancel_client_resources; replies are discarded by the pinned caller.',
'DefaultJobSchedulerUpdateHistory':'Immediately after count/history/time update in the local Job metadata, before returning success or appending to failed_jobs.',
'DefaultJobSchedulerAdmissionException':'At the whole-pass except after _try_job or post-admission processing raises, before returning through deferred metadata processing.',
'AutoCleanResourceManagerTick':'Inside _check_expired lock, after decrementing positive token TTLs and building the expired list, before popping any expired entry.',
'AutoCleanResourceManagerFinishExpiry':'Inside the same cleanup lock, immediately after one expired token pop and its _deallocate appendleft operations.',
'JobRunnerCheckSubmitted':'At completion of the SUBMITTED status read/check; capture the actual read value before entering deployment or continuing.',
'JobRunnerDeployJob':'After local server deployment succeeds and client DEPLOY batch is enqueued, before waiting on deployment replies.',
'JobRunnerDeploymentException':'At the exception/returned-error branch in _deploy_job, before runner exception cleanup.',
'ClientDeploySuccess':'After engine.deploy_app returns success and deployment has committed, at the successful reply boundary.',
'ClientDeployError':'At the ordinary staging/deployment error reply boundary; retain state at other successful sites.',
'JobRunnerEvaluateDeployment':'After building failed_clients and checking min_sites/required_sites, before _deploy_job returns or raises.',
'JobRunnerWriteDispatched':'Immediately after persistent DISPATCHED update commits, before deployment-detail metadata update.',
'JobRunnerPersistDeploy':'After deployment details/retry metadata update commits, before the DISPATCHED status check.',
'JobRunnerCheckDispatched':'Immediately after the DISPATCHED read/check and before calling _start_run.',
'ServerEngineSpawnJob':'Immediately at successful default local server spawn; retain handle/PID identity independently from run_processes.',
'ServerEngineRegisterJob':'Inside server engine lock, immediately after run_processes[job_id] publication.',
'ServerEngineInstallWaiter':'Immediately after the server wait_for_complete thread starts successfully.',
'JobRunnerSetPendingOutcomes':'Inside runner lock, after assigning _pending_client_outcomes[job_id].',
'ServerEngineStartClientJob':'After enqueueing exactly the deployable START_JOB batch with token/job headers; before its 20-second waiter.',
'JobRunnerEvaluateStartReplies':'After check_client_replies and active-client selection, before pending-outcome intersection; capture actual reply slots and strict policy.',
'JobRunnerFilterPendingOutcomes':'Inside runner lock, after intersection_update(active_client_sites), before JOB_STARTED dispatch.',
'DefaultJobSchedulerJobStarted':'Inside scheduler.handle_event lock after idempotent scheduled_jobs insertion; retain EVENT_DATA job ID, before synchronous dispatch returns.',
'JobRunnerRegisterRunning':'Inside runner lock, immediately after running_jobs[job_id] insertion and before set_status(RUNNING).',
'JobRunnerWriteRunning':'Immediately after persistent RUNNING write commits; do not bundle with map registration.',
'JobRunnerStartupStoreError':'At a raised deployment-detail/DISPATCHED/RUNNING store call, before entering runner failure cleanup.',
'ServerEngineStartupError':'At the ordinary server-start returned/raised-error boundary before successful spawn.',
'JobRunnerFailureRemove':'Inside runner exception-cleanup lock after conditional running-job removal and pending-outcome pop.',
'JobRunnerFailureStop':'At _stop_run request boundary after checking run_processes and enqueueing child/client aborts, before FAILED_TO_RUN store.',
'JobRunnerFailureStatus':'After successful FAILED_TO_RUN/status-detail store updates, before the JOB_ABORTED event.',
'DefaultJobSchedulerJobAbortedOnStartFailure':'Inside scheduler event lock after JOB_ABORTED removes the exact failed job ID; before runner retries its outer loop.',
'StartJobProcessorAllocate':'Inside RM lock after popping the reservation; immediately retain the returned allocation in a source-side observer ledger.',
'StartJobProcessorRejectToken':'At allocate_resources missing-token RuntimeError, before processor builds its error reply; no allocation/free event.',
'ListResourceConsumerConsume':'Immediately after the CUDA_VISIBLE_DEVICES assignment; capture the assigned unit sequence, not a later reread.',
'ClientEngineStartAppCheck':'After actual executor-status and deployed-app checks succeed; before the executor call.',
'ClientEngineStartAppReturnedError':'At the missing app-root early return, with unchanged ownership; only if a supported occurrence is established (CR-1).',
'JobExecutorRegisterPendingHandle':'Inside executor.lock immediately after the pending-handle map entry and STARTING status are installed.',
'JobExecutorPrepareException':'At an ordinary consume/preparation/metadata I/O exception before spawn; retain allocated payload for processor rollback.',
'ProcessJobLauncherSnapshotEnvironment':'Immediately after new_env = os.environ.copy(); capture new_env CUDA_VISIBLE_DEVICES before command preparation/spawn.',
'ProcessJobLauncherSpawn':'Immediately after spawn_process succeeds and returns its adapter; capture actual child PID and the passed environment snapshot.',
'ProcessJobLauncherSpawnException':'At pre-spawn launch exception after executor removes its own pending entry; before propagating to processor rollback.',
'PendingJobHandleAttach':'Inside pending_handle._lock after assigning _job_handle and reading the retained abort flag.',
'JobExecutorApplyPendingAbort':'After replaying pending abort against the attached handle, before AFTER_JOB_LAUNCH dispatch.',
'JobExecutorAfterJobLaunchEvent':'After real fire_event(AFTER_JOB_LAUNCH) returns; ordinary handler exceptions remain swallowed, then waiter construction follows.',
'JobExecutorInstallCleanupWaiter':'At successful cleanup-thread start, recording the exact resource payload/handle passed to that waiter.',
'JobExecutorWaiterInstallationException':'At Thread construction/start exception before any waiter execution; capture retained live handle and propagated exception.',
'StartJobProcessorRollback':'Inside RM lock after free_resources(payload) appends units; record child/handle independently and the actual free-call count.',
'StartJobProcessorReplySuccess':'After ClientEngine.start_app returns and processor builds the non-error reply, before transport delivery.',
'JobExecutorNotifyStarted':'Immediately after the STARTED assignment in executor.notify_job_status for an existing handle.',
'JobExecutorNotifyStopped':'Immediately after the STOPPED assignment; do not infer process exit or free resources.',
'ClientChildExit':'At observed ordinary OS process exit, retaining PID/handle identity; independently of logical STOPPED and later waiter return.',
'ClientChildFailure':'At observed reportable OS failure/exit classification, retaining the same owned PID identity.',
'JobExecutorWaitChildExit':'Immediately after job_handle.wait returns and exit code/status are obtained, before attempting terminal reporting.',
'JobExecutorReportOutcome':'After the exact job/site outcome request is enqueued, before waiting for report return.',
'JobExecutorOutcomeReportReturned':'After the reporting call returns normally, before resource free; capture report outcome and transport completion.',
'JobExecutorOutcomeReportException':'At caught reporting exception/timeout, before continuing to the unconditional allocated_resource free block.',
'JobExecutorFreeAfterExit':'Inside RM lock after the waiter free call, before executor map removal.',
'JobExecutorRemoveProcess':'Inside executor lock after run_processes.pop(job_id,None), before site-local completion dispatch.',
'JobExecutorJobCompletedEvent':'After the site-local JOB_COMPLETED event dispatch returns; it is not a server scheduler event.',
'ClientEngineAbortApp':'After the matching abort command executes the engine/executor status branch; preserve pending handle abort and delayed termination stages.',
'ClientEngineHeartbeatAbort':'At the same executor abort boundary for a matching heartbeat-cleanup command; retain heartbeat origin.',
'JobExecutorTerminateAfterGrace':'After the 10-second teardown grace and terminate request on the retained attached handle; process exit is another event.',
'FederatedServerHeartbeatCleanup':'After _sync_client_jobs derives a job absent from protected server registry/outcome keys, at the heartbeat abort reply boundary.',
'ServerEngineReceiveOutcome':'Inside runner.lock after resolve_client_outcome discards the exact reporting site from the exact job.',
'ServerEngineReceiveFailureOutcome':'After accepted authoritative failure updates outcome/exception bookkeeping and sends stop; later unknown jobs must not be reactivated.',
'ServerChildExit':'At observed normal server-child OS exit, before wait_for_complete removes the engine map entry.',
'ServerChildFailure':'At observed reportable server-child failure; retain authoritative exception classification.',
'ServerEngineObserveExit':'Inside server engine lock after wait_for_complete pops the registry entry following wait and status-update grace.',
'ServerEngineTerminateAfterGrace':'After _remove_run_processes calls terminate on its captured handle, before its unconditional map pop.',
'ServerEngineRemoveAfterTerminate':'Inside engine lock immediately after unconditional run_processes.pop following terminate attempt.',
'JobCommandAbortRead':'Immediately after get_job/status read in abort_job, before selecting/performing the store or stop branch.',
'JobCommandAbortPreRunWrite':'Immediately after persistent FINISHED_ABORTED store, before appending CLI success.',
'JobCommandAbortPreRunAcknowledge':'After appending the successful pre-run abort response; retain the saved branch and actual current stored status.',
'JobCommandAbortAlreadyTerminal':'At successful already-terminal CLI response from the saved status branch.',
'JobCommandAbortRunning':'At the supported running-job stop request boundary, before mark_run_aborted checks the runner map.',
'JobRunnerMarkAborted':'After inspecting running_jobs and conditionally setting job.run_aborted, before returning success/error.',
'JobRunnerSelectCompletion':'After reading the job reference and server-map absence, and checking/creating outcome wait state under actual locks.',
'JobRunnerOutcomesResolved':'At the next completion scan when pending is empty or abort/authoritative failure bypasses its wait.',
'JobRunnerOutcomeGraceExpired':'At the pending.clear timeout branch, with measured elapsed time since that job outcome deadline was first established.',
'JobRunnerClassifyCompletion':'After saving _FinishedJobState.status and sending failure cleanup as needed, before archival.',
'JobRunnerArchiveSuccess':'After _save_workspace succeeds and workspace_archival_complete is set, before terminal store.',
'JobRunnerArchiveException':'At archival exception inside its grace window, before continuing to another job.',
'JobRunnerRetryArchive':'At a later completion scan re-entering _save_workspace for the same saved finished state.',
'JobRunnerArchiveGraceExpired':'At an archival error on/after grace, after marking archival processing complete and before terminal store.',
'JobRunnerPublishTerminal':'Immediately after terminal set_status commits, before taking runner lock for deletion.',
'JobRunnerTerminalStoreException':'At caught terminal set_status failure, before continue/retry; do not remove runner/scheduler entries.',
'JobRunnerRemoveCompleted':'Inside runner lock after del running_jobs and completion/outcome bookkeeping pops, before lifecycle events.',
'DefaultJobSchedulerJobAbortedOnCompletion':'Inside scheduler.handle_event lock after the ABORTED event removes the exact job membership.',
'DefaultJobSchedulerJobCompleted':'Inside scheduler.handle_event lock after the subsequent COMPLETED removal; duplicate removal is a no-op.',
'TransportLoseMessage':'At a controlled ordinary transport drop of a concrete in-flight envelope; record its exact operation/job/site/attempt.',
'DefaultJobSchedulerPersistFailed':'At deferred refresh_meta for one failed job after candidate scan returns; before moving to the next failed job.',
'DefaultJobSchedulerPersistBlocked':'At deferred refresh_meta/set_status for one blocked job, after all failed jobs are processed.',
'DefaultJobSchedulerReturnPass':'At schedule_job return after all deferred metadata work, before runner performs its next status check.',
'JobRunnerMissingPendingOutcomes':'At the real KeyError when pending-outcome intersection finds the map was removed, before runner exception cleanup.'}
triggers.update({
 'JobCommandAbortRunningSend':'At the actual supported running-job client stop send, before its blocking wait; server abort/CLI return are separate.',
 'JobRunnerFailureSendStop':'At failure cleanup client stop send, before its blocking wait and the subsequent server abort.',
 'JobExecutorAbortStarting':'After invoking terminate on the pending or attached STARTING handle; retain the actual pending flag/termination request.',
 'ClientEngineAbortApp':'Under executor.lock after setting abort_requested and capturing handle/status, before graceful wait; or at the ClientEngine no-op early return.',
 'JobRunnerFailureStop':'After the blocking failure stop returns, before FAILED_TO_RUN metadata; client stop sends have their own earlier event.',
 'JobCommandAbortRunning':'After the blocking running-job stop returns, before mark_run_aborted; client stop sends have their own earlier event.'})
triggers.update({'ServerEngineIgnoreOutcome': 'At the actual receiver early return for a non-pending job/site, before its OK acknowledgement; capture code and exact job/site.', 'ServerEngineResolveMissingOutcome': 'At heartbeat-origin resolve_client_outcome under runner lock, using the actual missing-job observation, pending map and exception outcome.', 'ServerEngineReceiveAbortedOutcome': 'After accepted ABORTED report processing; capture actual exception classification with stronger-code precedence and cleanup requests.', 'JobExecutorClassifyAbortedExit': "At get_return_code classification after physical exit, when the observed returned code is ABORTED and the executor's abort-request flag is set."})
triggers.update({'ServerEngineTerminateAfterExit': 'After the cleanup loop observed no registry entry and terminated the captured handle; capture the actual loop local and elapsed time.', 'ServerEngineTerminateAfterAbortCommandError': 'After a zero-grace cleanup selected by abort command exception terminates the captured handle; capture max_wait=0.', 'ServerEngineTerminateAfterGrace': 'After the full max_wait=10 cleanup interval and captured-handle termination; early registry removal and zero grace use separate actions.'})
for a in A:
 n=a['name']
 if n.startswith('ServerEngineReceive') and n not in triggers:
  triggers[n]='After the '+n.removeprefix('ServerEngineReceive')+' reply is matched to its original waiter, or discarded because that waiter closed; before aggregate return.'
 if n.startswith('Admin') and n.endswith('Timeout'):
  triggers[n]='When the blocking '+n[5:-7]+' RPC batch reaches its deadline, after closing remaining waiter slots; retain executing commands and any late replies.'
 assert n in triggers,n
manifest={'tag':'nvflare-job-lifecycle-config','sourceRevision':'53ba7ee567468ea7971dad4faccef13c6cb35dc2','resourceManager':'ListResourceManager','resourceConsumer':'ListResourceConsumer','launcher':'ProcessJobLauncher','jobOrder':['job-1','job-2'],'sites':['site-1','site-2'],'pool':[0,1],'requiredSites':['site-1'],'minSites':1,'strictStart':False,'maxJobs':2,'maxScheduleCount':10,'minScheduleInterval':10,'maxScheduleInterval':600,'attemptSlots':11,'reservationTTL':30,'outcomeGrace':900,'archiveGrace':60,'demandPerJobSite':1}
(P/'trace-manifest.example.json').write_text(json.dumps(manifest,indent=2)+'\n')
out='''# Instrumentation mapping: NVFlare job lifecycle

Source pin: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`. Single Category A NDJSON trace, with separate hooks for local concurrency steps. No instrumentation or production trace was executed during generation.

## 1. Trace event schema

Store real traces in `../traces/` (sibling of `spec/`). Trace.tla defaults to `../traces/trace.ndjson`; set environment variable `JSON` to a selected file. Use the experiment's `lib/tla2tools.jar`, `lib/CommunityModules-deps.jar` and TLA library directory. Do not mistake a generated/example trace for an implementation trace.

The first row must be the configuration record in `trace-manifest.example.json`, filled with the actual selected settings. Record the actual Git head before collecting. Trace.cfg obtains all constants from that row. Labels may be stable aliases for real UUID job IDs/site names; preserve the submission order, required-site role, token uniqueness and mapping in a separate provenance sidecar. The model supports a finite valid one-unit workload, cooperative connected sites and the selected process launcher; incompatible workload/configuration needs model extension before collection. Numeric resource IDs are deque elements, not real GPUs required for tests.

Every semantic event has these required fields:

| Field | Meaning / validation |
|---|---|
| `tag` | Exactly `trace`. Unrelated log rows may have other tags; unknown events under this tag fail. |
| `event` | Exactly one base action name from the table below. One base semantic step per event. |
| `node` | `server`, `transport`, or the site alias as specified below. |
| `args` | Exact named action arguments. `j` is a job alias; `s` a site alias; `t` is `[jobAlias,attemptNumber]`; `m` is a full message record. No extra or missing arguments. Actions without parameters use `{}`. |
| `elapsedSeconds` | Zero for non-deadline actions. For deadline actions, the actual elapsed time measured at the indicated boundary; must satisfy the lower bound in the table. A deadline event is not merely permission to skip a blocked step. |
| `post` | EXACT top-level field set specified for this action. Each named field carries its full normalized snapshot described below. Missing, extra or unequal fields reject the event. |

Message records are `{kind,site,job,attempt}`, with exact values from `Kinds` and the original request association. Operation name plus job/site/attempt is the abstract waiter identity. Capture real transport request/waiter IDs in the provenance ledger so late replies cannot be remapped to a current attempt. No arbitrary wrong-job messages, duplicate fresh-token STARTs or custom resource-manager behavior are part of the workload.

`post` encodings (all numbers/booleans must be JSON numbers/booleans, never strings):

| Field | JSON encoding / source mapping |
|---|---|
| `scheduler` | Complete record with the same fields as `scheduler`. `scheduled`, `failedPending`, `blockedPending` are arrays representing sets; `candidates` and each `history[j]` preserve sequence order. `count/history/persisted` come from local Job metadata and successful store reads; `issued/considered` are independent hook counters at actual _try_job entries, not the stored schedule count. `current`, `pc`, `returnTo` and pending sets record source call-stack/loop positions and actual failed_jobs/blocked_jobs contents. `cooldown[j]` records the actual elapsed-time predicate. |
| `jobs` | Object keyed by ALL configured job aliases, each with every `EmptyJob` field. `dispatch/deployed/active/pending` are arrays representing sets. `status/checked/adminRead/finishStatus` capture actual saved values, normalized to SUBMITTED/DISPATCHED/RUNNING/ABORTED/COMPLETED/FAILED/FAILED_TO_RUN/CANT_SCHEDULE. `running/serverRegistered/outcomeKey` capture membership/key presence independently. `serverAlive/serverSpawned/serverWaiter/serverStop/serverTerminated` come from owned handles and observed spawn/exit/wait/stop events. `completion/adminPC/archiveFailed` are local stage/grace observations. `abortAck/terminalPublished/completedRemoved/resurrected` are independently reconstructed history flags from actual acknowledgements and committed writes/removals. Never synthesize a terminal write from a logical stop. |
| `rm` | Object keyed by ALL sites. Each value is `{free:[...],tokens:[...]}`. Each token row has EXACT fields `{job,attempt,reserved,ttl,allocated,payload,releases}`. There must be one row for every configured job/attempt pair, including zero/empty rows. `free` and `reserved` preserve actual deque/list order and duplicates, `ttl` is the actual cleanup counter. `allocated/payload/releases` are independent source-side observer ledgers of returned allocate payloads and actual free calls; the built-in RM does not itself keep an allocation map or guard free by token. |
| `client` | Object keyed by ALL sites, each containing an array of `{job,attempt,value}` rows, one for every token pair. `value` contains every `EmptyClient` field. Capture executor handle membership/status/abort flags under its own lock, exact copied launch binding, actual successful spawn/attachment/waiter installation, exit observation and local cleanup PC. `deployed` means actual acknowledged deployment success in the selected workload. |
| `resourceEnv` | Object keyed by ALL sites, each value the last directly captured parent CUDA_VISIBLE_DEVICES unit sequence. Capture assignments and `new_env` copies separately; never substitute allocation arguments for the copied environment. |
| `rpc` | Object keyed by ALL sites, each containing every `{job,attempt,value}` row. `value` is `{check,deploy,start,cancel}` with values idle/waiting/ok/no/timeout from actual matching waiter lifecycle. A timeout changes a waiter, not the executing callback or another attempt. |
| `network` | Array of every currently outstanding abstract message record in the merged observer ledger; unique envelope records in this selected once-per-operation workload. Derive sends, receipts, drops and replies from real hooks and actual IDs, not from expected model transitions. |

The global `post` snapshots are assembled from source snapshots plus an independent observer ledger in the trace merger. A remote callback cannot atomically read all other sites. Carry forward their last recorded snapshots in a causally valid total order; update the emitting site's actual captured fields and the message ledger. This is a distributed observation projection, not a claim of a cross-process atomic memory snapshot. Directly observable ownership, resource queue, status, environment and copied binding values must come from the implementation. Do not import `base.tla` or execute its transitions to manufacture `post` values: that would make validation circular.

Every `post` field is checked by ValidatePostState. The wrapper fixes the exact field set first, so conditional field checks cannot become vacuous. Row decoding rejects absent/duplicate aliases. Set-array decoding rejects duplicate entries before conversion, so duplicate scheduled_jobs membership is not hidden by a set projection. Empty sets serialize as `[]`; preserve resource multiplicities as arrays, including duplicate units after an erroneous free. `Trace.cfg` actively checks TraceMatched; the trace spec uses fairness only to forbid infinite cursor stuttering. At an unmatchable event, TraceMatched still fails. Scenario bug predicates remain hunt checks, keeping conformance distinct from correctness.

## 2. Action-to-code mapping

Each row gives exactly one event/action pair. Emit after the listed semantic operation, with its captured post-state, before the next listed operation. Multi-location rows represent a documented component boundary abstraction; if source hooks show an intervening relevant state transition, split the base/Trace action before claiming conformance rather than skipping the evidence.

| Action / exact event | Code location(s) at pin | Trigger point | Node; args; minimum elapsed | Required post fields |
|---|---|---|---|---|
'''
for a in A:
 params=', '.join(a['params']) or '{}'
 n=a['node'].strip('"')
 fields=', '.join('`'+v+'`' for v in a['updates'])
 out+=f"| `{a['name']}` | {a['source']} | {triggers[a['name']]} | `{n}`; `{params}`; `{a['minimumElapsedSeconds']}` s | {fields} |\n"
out+='''
## 3. Special considerations

- **Source versus observer state:** preserve direct snapshots wherever available. The RM allocation ledger, physical ownership interval, transport correlation, per-attempt IDs and history properties require shadow fields because no single source object contains them all. Update those only from actual returned values, successful mutations and observed PID events. Retain raw values and exception records alongside normalized traces for review. A model-only trace is never implementation evidence.
- **Concurrency/ordering:** keep RM snapshots within the existing lock and split scan decrement/drain events without unlocking it. Capture consume assignment and environment copy separately. Capture pending-handle publication, spawn, attachment, production dispatch and waiter start separately. Do not add a lock spanning these windows. Stamp each hook with thread/process ID, local sequence and monotonic interval in a provenance sidecar; merge using per-thread order and send/receive dependencies, not unsynchronized wall-clock order. For overlaps without a defensible total order, retain the partial-order evidence and enumerate compatible serializations; do not force a false failure/pass by sorting timestamps.
- **Known aggregation boundaries:** reply construction is projected onto handler completion; successful per-candidate history changes and failure/terminal status processing may include source-local bookkeeping between hook points. Production observations that expose interference inside one projected action require refinement. The spec does not grant a production-wide lock around them.
- **Physical process observation:** logical STOPPED, abort reply, terminate request and registry removal do not establish exit. Record the owned handle/PID and an independent process-exit observation; a source cleanup waiter is not the only permissible observer, especially when waiter installation fails. An observational monitor must never free resources, remove a handle or repair startup. Preserve actual real-dispatch behavior: ordinary AFTER_JOB_LAUNCH component exceptions are caught. For MC-2, only the client cleanup waiter construction/start failure before waiter execution is represented.
- **Timing:** TTL is measured in actual RM scan ticks (30), while RPC timeouts, retry backoff, 900s outcome wait, 60s archival grace and 10s termination grace use their actual timers. No time acceleration is silently assumed. If a harness configures different duration constants, update/review the model/manifest contract first. The untimed base permits independent deadline crossings, so time-sensitive MC traces still need feasibility review.
- **Identity and repeats:** source aliases are stable for a job and its selected scheduling attempt. Closed waiter replies do not become a new attempt. Real server ABORTED followed by COMPLETED and repeated user aborts are represented; a site-local completion does not invoke the server scheduler. Child STARTED/STOPPED hooks cover their ordinary ordered successful notification path. The full STARTED retry/deadline loop and in-flight repeated child-status notifications are CR-4 review scope; a trace exercising them needs an explicit message/ack/retry extension, not silent acceptance or a fabricated notification.
- **Normal failure continuations:** an expired/cancelled token is rejected on allocate. Cancellation acknowledgement loss leaves TTL cleanup live. Startup exception rollback uses the original returned payload without a token guard. Reporting exceptions are caught before normal waiter free. Completion metadata errors retry; archival errors yield and eventually pass their grace boundary. Never encode a passing result by deleting one of these fields/events.
- **Deferred boundaries:** TV-2 failure-branch service death and TV-3 competing completion deletion are not modeled as service-exit transitions yet. The completion delete guard exposes that missing path; a real trace entering it must be reported unsupported and the model extended after the requested local functional test. CR-1 returned startup errors need a supported fresh-allocation trigger; no arbitrary deployed-directory deletion or repeated fresh-token START. CR-2 server termination does not support a claim of permanently surviving local processes. CR-3 invalid custom counts, CR-5 header-only error producer reachability and CR-6 disconnected empty-target fallback remain review boundaries in brief-coverage.md.
- **Bootstrap and finite scope:** collect from empty resource/registry/request state after component initialization with the configured finite submitted workload and unique initial pool. Existing running jobs, exhausted attempts, reconnect/HA state or nonempty transport require an explicit new TraceInit mapping. Example JSON is synthetic schema material only. All real traces must retain source pin, exact configuration, token alias ledger, raw hook provenance and original logs.

Generator entry points, in methodology order: `generate.py`, `generate-mc.py`, `generate-coverage.py`, `generate-trace.py`, `generate-instrumentation.py`. Re-run the coverage audit after any invariant/config change and semantic checks after regeneration. See generation-validation.md for executed checks and evidence limits.
'''
(P/'instrumentation-spec.md').write_text(out)
(P/'instrumentation-hooks.json').write_text(json.dumps([{**a,'trigger':triggers[a['name']]} for a in A],indent=2)+'\n')
print('wrote instrumentation-spec.md with',len(A),'unique hook mappings')
