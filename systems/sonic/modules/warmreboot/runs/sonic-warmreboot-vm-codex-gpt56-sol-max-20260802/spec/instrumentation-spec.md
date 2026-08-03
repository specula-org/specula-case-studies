# Warmreboot trace instrumentation specification

This document is the 1:1 handoff from `base.tla`/`Trace.tla` to a trace
collector. The target is Category A, so the output is one globally sequenced
NDJSON stream. Every row below names exactly one base action and exactly one
trace event type.

## 1. Trace event schema

### Envelope

Emit one compact JSON object per line:

```json
{
  "tag": "warmreboot",
  "seq": 42,
  "ts_ns": 123456789,
  "process": "syncd@asic_0",
  "pid": 1234,
  "event": {
    "name": "Syncd_ApplyViewCommit",
    "asic": "asic_0",
    "post": {
      "apply_state": "committed",
      "apply_dirty": false,
      "journal_state": "none"
    }
  }
}
```

The `tag`, `event.name`, and `event.post` fields are mandatory. `seq` is
assigned by one local collector over a Unix socket; write the NDJSON file in
that sequence order. This avoids using wall-clock timestamps to order events
from different containers. `ts_ns`, `process`, and `pid` are diagnostic and
are intentionally ignored by `Trace.tla`.

Event identifiers are included only where listed below:

- `owner`, `kind`
- `asic`, `producer`
- `component`
- `route`
- `vid`, `rid`
- `op` (1-based abstract APPLY operation ordinal)

Normalize runtime identifiers before serialization:

- callers: `owner_1`, `owner_2`, assigned from `(pid, process-start-time)`;
- ASIC namespaces: `asic_0`, `asic_1`;
- producer kinds: `orch_producer`, `ring_producer`, `fdb_producer`;
- components: `fpmsyncd_component`, `orchagent_component`;
- routes, VIDs, and RIDs: stable run-local names such as `route_1`, `vid_1`,
  `rid_1`; retain a sidecar dictionary for the original values.

### Serialization rules

- Sets are sorted JSON arrays. `Trace.tla` converts them back to sets.
- Total maps are JSON objects containing every configured domain key.
- Use `"no-rid"`/`"no-vid"` for absent identity-map entries; never omit a
  key or serialize JSON `null`.
- Candidate relations are arrays of `{"vid":"...","rid":"..."}`.
- Booleans are JSON booleans, epochs/cursors/operation ordinals are integers,
  and enum values exactly match the strings in `base.tla`.
- Capture `post` after the operation named by the event and before the next
  modeled operation. Fields listed for an event are all mandatory. Do not add
  an unvalidated field to `post`; diagnostic data belongs at envelope level.

### Instrumentation-only shadow state

The implementation intentionally lacks several fields the model needs to
correlate non-atomic effects. Maintain these in the collector, without using
them to alter production control flow:

- per-owner `request_kind`, `phase`, `checked`, `admitted`, `attempt_epoch`,
  `attempt_outcome`, `cancelled`, and `irreversible_started`;
- monotonic `epoch`, current `owner`, and `cleanup_owner`;
- per-producer queue/in-flight/fence state and derived `quiescent`;
- per-ASIC snapshot `epoch`, `valid`, and stage. At Redis SAVE, validity is
  the observed conjunction of writer-stopped plus all producer fences/drains;
- APPLY state, operation ordinal/set, candidate/matching abstractions,
  abstract DB/hardware views, map stage/pending/half, and dirty state;
- `journal_state` is always `none` on the current code. Patched MC-3 builds
  emit `intent`, `dirty`, and `committed` from the proposed durable journal;
- cached/refreshed/derived route sets and finalizer terminal/flag state.

Real implementation state must be read back where it exists: Redis flags and
component states, dump existence, syncd mode/status, queue/ring state, Redis
ASIC/map contents, and pipeline flush completion. A shadow value must never be
substituted for an available implementation read-back.

## 2. Action-to-code mapping

### Scenario 1 — admission, cancellation, and ownership

| Spec action / trace event | Code location | Exact trigger point | Identifiers and mandatory `post` fields | Notes |
|---|---|---|---|---|
| `FastReboot_Request` | `src/sonic-utilities/scripts/fast-reboot:922-975` | After options/reboot kind and caller identity are fixed; before `check_warm_restart_in_progress` | `owner`, `kind`; `post={request_kind, phase, attempt_outcome}` | Initialize the owner shadow entry. |
| `CheckWarmRestartInProgress_Admit` | `src/sonic-utilities/scripts/fast-reboot:883-894` | On normal return after the entire flag scan observes no enabled flag | `owner`; `post={checked, phase}` | Do not emit on a forced-ignore branch; model that branch only when added explicitly. |
| `CheckWarmRestartInProgress_Reject` | `src/sonic-utilities/scripts/fast-reboot:884-891` | Immediately before `exit EXIT_FAILURE` | `owner`; `post={phase, attempt_outcome}` | Flush the event synchronously before exit. |
| `EnableWarmRestart` | `src/sonic-utilities/scripts/fast-reboot:896-898,973-992` | After all warm/fast Redis writes complete and have been read back | `owner`; `post={epoch, owner, flags:{warm,fast,epoch}, phase, checked, admitted, attempt_epoch, attempt_outcome, cancelled}` | Increment instrumentation epoch at this point. `UseEpochCAS` patched builds acquire here. |
| `ClearBoot` | `src/sonic-utilities/scripts/fast-reboot:341-370` | After flag disable and dump renames, just before handler/function return | `owner`; `post={owner, cleanup_owner, flags:{warm,fast,epoch}, phase, cancelled, snapshot_present, snapshot_valid, snapshot_stage}` | Snapshot maps contain every ASIC. Read back flags and dump paths. |
| `FastReboot_ContinueAfterSignal` | `src/sonic-utilities/scripts/fast-reboot:341-370,975-996` | At the first instrumented mainline point reached after a signal trap returns | `owner`; `post={phase, cancelled}` | The trap itself does not terminate the shell; record this only when execution really resumes. |
| `FastReboot_PauseOrchagentComplete` | `src/sonic-utilities/scripts/fast-reboot:1130-1156` | After `execute_in_namespaces asic pause_orchagent` returns for all ASICs | `owner`; `post={phase}` | Aggregate only already-emitted per-ASIC ready/ignored results. |
| `FastReboot_BeginIrreversibleWork` | `src/sonic-utilities/scripts/fast-reboot:1163-1165` | Immediately after entering the documented no-rollback section | `owner`; `post={phase, irreversible_started}` | Emit before route deletion, timer stops, or service stops. |
| `FastReboot_RecordOutcome` | `src/sonic-utilities/scripts/fast-reboot:1219-1222`; `files/image_config/warmboot-finalizer/finalize-warmboot.sh:299-302` | When the collector observes the selected cold result or successful APPLY/finalizer completion | `owner`; `post={phase, attempt_outcome}` | This is a coordinator/collector event because current code has no single commit instruction. |

### Scenario 2 — readiness and producer fencing

| Spec action / trace event | Code location | Exact trigger point | Identifiers and mandatory `post` fields | Notes |
|---|---|---|---|---|
| `Producer_Enqueue` | `src/sonic-swss/orchagent/orchdaemon.cpp:1170-1179,1190-1199` and producer-specific enqueue hooks | Immediately after a modeled queue gains one item | `asic`, `producer`; `post={queue, inflight, quiescent}` | Emit for orch consumer work, route-ring work, and FDB/channel work. |
| `Producer_DrainOne` | `src/sonic-swss/orchagent/orchdaemon.cpp:1170-1179,1194-1198` | After one item completes and counters are updated | `asic`, `producer`; `post={queue, inflight, quiescent}` | One event per item, not one event for a whole batch. |
| `OrchDaemon_WarmRestartCheck` | `src/sonic-swss/orchagent/orchdaemon.cpp:1384-1414` | Current build: immediately after `restartCheckReply`; MC-2 build: after local check passes but before drain | `asic`; `post={ready_sent, post_ready_step}` | `ready_sent=false`/`check-passed` in the reordered build. |
| `OrchagentRestartCheck_ConsumeReply` | `src/sonic-swss/orchagent/orchagent_restart_check.cpp:130-140` | After `pop` returns `READY`, immediately before success return | `asic`; `post={ready_consumed, freeze_result}` | Preserve the absence of a request/epoch ID. |
| `PauseOrchagent_IgnoreFailure` | `src/sonic-utilities/scripts/fast-reboot:1137-1146` | In the FORCE branch after logging that failure is ignored | `asic`; `post={ready_consumed, freeze_result}` | Emit `freeze_result="ignored-failure"`. |
| `OrchDaemon_DrainRing` | `src/sonic-swss/orchagent/orchdaemon.cpp:1190-1199` | When the ring loop first observes both empty and idle | `asic`; `post={queue, inflight, quiescent, post_ready_step}` | Fields describe `ring_producer`. |
| `OrchDaemon_SetAgingFDB` | `src/sonic-swss/orchagent/orchdaemon.cpp:1201-1205` | After `setAgingFDB(0)` returns | `asic`; `post={post_ready_step}` | Do not merge with bridge-port updates. |
| `OrchDaemon_SetBridgePortLearningFDB` | `src/sonic-swss/orchagent/orchdaemon.cpp:1207-1215` | After the last bridge-port learning call completes | `asic`; `post={post_ready_step}` | One namespace-level completion after the real loop. |
| `OrchDaemon_Flush` | `src/sonic-swss/orchagent/orchdaemon.cpp:1217-1218` | After `flush()` returns | `asic`; `post={post_ready_step}` | This is sairedis pipeline completion, not the heartbeat fence. |
| `OrchDaemon_WarmRestartReplyAfterFlush` | Proposed MC-2 placement between `orchdaemon.cpp:1218-1221` | Patched builds only: immediately after sending deferred READY | `asic`; `post={ready_sent, post_ready_step}` | Current builds never emit this event (`ReplyAfterLocalDrain=FALSE`). |
| `OrchDaemon_FreezeAndHeartBeat` | `src/sonic-swss/orchagent/orchdaemon.cpp:1220-1221` | Immediately before entering the non-returning freeze loop, after setting collector fence state | `asic`; `post={producer_state, quiescent, post_ready_step}` | `producer_state`/`quiescent` are maps keyed by all three producer-kind strings. |

### Scenario 3 — participant outcome and checkpoint

| Spec action / trace event | Code location | Exact trigger point | Identifiers and mandatory `post` fields | Notes |
|---|---|---|---|---|
| `StopSystemdService_Success` | `src/sonic-utilities/scripts/fast-reboot:190-216,1206-1217`; `files/scripts/swss.sh:522-544` | After the addressed systemd/container stop returns success | `asic`; `post={writer_stopped, shutdown_status}` | Verify the actual namespace/container, not merely command invocation. |
| `StopSystemdService_MaskedFailure` | Same paths; `fast-reboot:1163-1165` | After a nonzero stop result is suppressed/continued | `asic`; `post={writer_stopped, shutdown_status}` | `writer_stopped` must come from a process/write probe. |
| `Syncd_PerformWarmShutdown` | `src/sonic-sairedis/syncd/Syncd.cpp:6982-7029`; `WarmRestartTable.cpp:37-43` | After successful switch removal and warm-shutdown state publication | `asic`; `post={local_mode, shutdown_status}` | Read back the namespace state table. |
| `Syncd_DowngradeWarmShutdown` | `src/sonic-sairedis/syncd/Syncd.cpp:6988-7009` | Immediately after local cold fallback/failed-state publication | `asic`; `post={local_mode, shutdown_status}` | Covers missing file and SAI warm-flag failure branches. |
| `CentralizeDatabase_RedisSave` | `src/sonic-utilities/scripts/centralize_database:10-42` | After blocking `r.save()` returns | `asic`; `post={snapshot_epoch, snapshot_valid, snapshot_stage}` | Compute validity from observed writer/fence state at SAVE completion. |
| `BackupDatabase_DockerCopy` | `src/sonic-utilities/scripts/fast-reboot:468-505` | After `docker cp ... dump.rdb` returns and host existence is checked | `asic`; `post={snapshot_present, snapshot_stage}` | Do not infer validity from existence. |
| `FastReboot_AggregateWarmDecision` | `src/sonic-utilities/scripts/fast-reboot:1219-1222`; `files/scripts/syncd.sh:145-173` | Collector: after every required dump-copy event while boot flags still select warm | none; `post={global_decision, selected_epoch}` | Deliberately do not consult local mode/status in the current-policy event. |
| `FastReboot_AggregateColdDecision` | `src/sonic-sairedis/syncd/Syncd.cpp:6988-7009` | Collector: on explicit cold fallback or loss of warm authority | none; `post={global_decision, selected_epoch}` | Emit once. |
| `DockerImageCtl_PreStartAction` | `files/build_templates/docker_image_ctl.j2:102-115,296-299` | After warm dump is copied into the database container | `asic`; `post={snapshot_consumed, snapshot_stage}` | Record which host dump was consumed before it is renamed `.old`. |

### Scenarios 4–5 — APPLY and identity publication

| Spec action / trace event | Code location | Exact trigger point | Identifiers and mandatory `post` fields | Notes |
|---|---|---|---|---|
| `Syncd_ProcessNotifySyncdInitView` | `src/sonic-sairedis/syncd/Syncd.cpp:5531-5555` | After INIT mode/temp clear and success response | `asic`; `post={init_epoch}` | Epoch comes from the collector's selected attempt. |
| `Syncd_ApplyViewCompare` | `src/sonic-sairedis/syncd/Syncd.cpp:5716-5794` | After current/temp views pass shape checks, immediately before the first `compareViews()` call | `asic`; `post={apply_asic, apply_epoch, planned_ops, op_cursor, apply_state, apply_dirty, recovery_mode, journal_state, candidates, matching}` | `matching` contains every VID with `no-rid`; candidates use normalized identities. |
| `BestCandidateFinder_SelectRandomCandidate` | `src/sonic-sairedis/syncd/BestCandidateFinder.cpp:1965-2035` | After random index selection, before returning the candidate | `vid`, `rid`; `post={matching_rid}` | Emit one event per actual bind, including deterministic one-candidate choices through the same hook. |
| `ComparisonLogic_CompareViewsComplete` | `src/sonic-sairedis/syncd/Syncd.cpp:5794-5847` | After all `compareViews()` calls succeed, before destructive execution | none; `post={apply_state}` | Must precede the first SAI operation. |
| `ComparisonLogic_ExecuteOperationsOnAsic` | `src/sonic-sairedis/syncd/ComparisonLogic.cpp:3797-3879` | After each `asic_process_event` returns success | none; `post={op_cursor, hardware_view, apply_dirty, journal_state}` | One event per irreversible operation; do not emit one aggregate loop event. |
| `Syncd_ApplyViewBeginRedisUpdate` | `src/sonic-sairedis/syncd/Syncd.cpp:5844-5849` | After all hardware loops return, immediately before `updateRedisDatabase` | none; `post={apply_state}` | Preserves the hardware/DB crash cut. |
| `RedisClient_RemoveAsicStateTable` | `src/sonic-sairedis/syncd/RedisClient.cpp:886-896` | After the last current ASIC_STATE key is deleted | none; `post={db_view, apply_state, apply_dirty}` | For finer key-level crash testing, split the base action and instrumentation together. |
| `RedisClient_RemoveTempAsicStateTable` | `src/sonic-sairedis/syncd/RedisClient.cpp:898-908` | After the last TEMP_ASIC_STATE key is deleted | none; `post={apply_state}` | Separate from current-table removal. |
| `RedisClient_CreateAsicObject` | `src/sonic-sairedis/syncd/RedisClient.cpp:582-600`; `Syncd.cpp:5939-5957` | After all HSETs for one abstract object complete | `op`; `post={db_view, apply_dirty}` | Map real objects deterministically to operation ordinals. |
| `Syncd_UpdateRedisDatabaseBeginMaps` | `src/sonic-sairedis/syncd/Syncd.cpp:5960-5978` | Immediately before calling/entering `setVidAndRidMap` | none; `post={apply_state, map_stage}` | Occurs only after all object events. |
| `RedisClient_SetVidAndRidMapDeleteVidToRid` | `src/sonic-sairedis/syncd/RedisClient.cpp:664-670` | Immediately after `del(VIDTORID)` returns | none; `post={vid_to_rid, apply_state, map_stage}` | `vid_to_rid` contains every VID mapped to `no-rid`. |
| `RedisClient_SetVidAndRidMapDeleteRidToVid` | `src/sonic-sairedis/syncd/RedisClient.cpp:669-672` | Immediately after `del(RIDTOVID)` returns | none; `post={rid_to_vid, map_pending, map_half, apply_state, map_stage}` | `map_pending` starts with every VID. |
| `RedisClient_SetVidAndRidMapWriteVidToRid` | `src/sonic-sairedis/syncd/RedisClient.cpp:672-678` | After the VIDTORID HSET and before the paired RIDTOVID HSET | `vid`; `post={mapped_rid, map_half}` | This hook is the critical half-pair crash boundary. |
| `RedisClient_SetVidAndRidMapWriteRidToVid` | `src/sonic-sairedis/syncd/RedisClient.cpp:674-679` | After the paired RIDTOVID HSET | none; `post={rid, mapped_vid, map_pending, map_half}` | `rid` is in `post` because the base action consumes current `mapHalf`. |
| `Syncd_UpdateRedisDatabaseComplete` | `src/sonic-sairedis/syncd/Syncd.cpp:5978-5980` | After `setVidAndRidMap` returns | none; `post={apply_state, map_stage}` | State becomes `verify`. |
| `Syncd_ApplyViewCommit` | `src/sonic-sairedis/syncd/Syncd.cpp:5849-5864,5583-5605` | After consistency check, success response, and local-cache clear | none; `post={apply_state, apply_dirty, journal_state}` | This is the only successful APPLY commit event. |
| `Syncd_CrashDuringApply` | Destructive boundaries above; `ComparisonLogic.cpp:3861-3889` | Injection harness: fsync this event immediately before killing syncd at the selected boundary | none; `post={apply_state, apply_dirty, journal_state}` | A spontaneous hard crash cannot reliably emit; collect this event from the controller that performs the kill. |
| `Syncd_ResumeFromDurableJournal` | Proposed MC-3 patch around `WarmRestartTable.cpp:20-43` and `Syncd.cpp:5844-5980` | Patched builds only: after replay reaches agreement and journal commit is durable | none; `post={recovery_mode, hardware_view, db_view, vid_to_rid, rid_to_vid, map_stage, map_pending, map_half, apply_state, apply_dirty, journal_state}` | Current builds never emit (`UseDurableApplyJournal=FALSE`). |
| `Syncd_AcceptDirtyWarmRecovery` | `files/build_templates/docker_image_ctl.j2:105-109`; `src/sonic-sairedis/syncd/Syncd.cpp:6211-6357` | When an unjournaled warm start accepts the consumed dump after an injected APPLY crash | none; `post={recovery_mode, apply_state}` | Collector correlates the previous crash with warm startup. |
| `Syncd_ForceColdRecovery` | `src/sonic-sairedis/syncd/Syncd.cpp:6988-7009` | After the cold fallback decision is published | none; `post={recovery_mode, apply_state, apply_dirty, global_decision}` | Emit before any cold reinitialization mutates the abstract views. |

### Scenario 6 — reconciliation and flag finalization

| Spec action / trace event | Code location | Exact trigger point | Identifiers and mandatory `post` fields | Notes |
|---|---|---|---|---|
| `WarmStartHelper_RunRestoration` | `src/sonic-swss/warmrestart/warmRestartHelper.cpp:102-133` | After restoration vector load and `RESTORED` publication | none; `post={cached_old, terminal}` | Normalize all restored route keys before emit. |
| `WarmStartHelper_InsertRefreshMap` | `src/sonic-swss/warmrestart/warmRestartHelper.cpp:137-142` | After the refresh-map assignment while state is RESTORED | `route`; `post={refreshed_new}` | One event per normalized key. |
| `FpmSyncd_EoiuInputComplete` | `src/sonic-swss/fpmsyncd/fpmsyncd.cpp:221-230` | When EOIU flags are observed and accepted as input completion | none; `post={input_complete}` | Keep distinct from hold-timer/reconcile actions. |
| `FpmSyncd_WarmRestartTimerExpired` | `src/sonic-swss/fpmsyncd/fpmsyncd.cpp:197-214` | On the timer-select branch before `onWarmStartEnd` | none; `post={timer_expired}` | Do not set `input_complete` on silence. |
| `RouteSync_OnWarmStartEnd` | `src/sonic-swss/fpmsyncd/routesync.cpp:3768-3781`; `warmRestartHelper.cpp:152-256` | After `reconcile()` publishes RECONCILED and before caller flushes pipeline | none; `post={derived_outputs, output_buffered, terminal}` | Captures the premature terminal/publication window. |
| `FpmSyncd_PipelineFlush` | `src/sonic-swss/fpmsyncd/fpmsyncd.cpp:214-219` | Immediately after `pipeline.flush()` returns | none; `post={output_buffered, output_published}` | `output_buffered` must now be empty. |
| `WarmStartHelper_LateInput` | Same refresh/input path as above; `fpmsyncd.cpp:190-220` | After a route is accepted while component state is already RECONCILED | `route`; `post={refreshed_new, output_buffered, derived_outputs}` | Collector classifies early versus late using observed component state. |
| `Component_PublishTerminal` | Component state writers; observed by `files/image_config/warmboot-finalizer/finalize-warmboot.sh:139-155` | On a STATE_DB transition to the expected reconciled state | `component`; `post={terminal}` | A Redis keyspace subscriber may emit this centrally instead of patching every daemon. |
| `Component_PublishFailure` | Proposed explicit failure writer; finalizer observation at `finalize-warmboot.sh:139-158` | On a terminal failure state write | `component`; `post={terminal}` | Patched MC-5 builds only until components publish explicit failure. |
| `FinalizeWarmboot_WaitTimeout` | `files/image_config/warmboot-finalizer/finalize-warmboot.sh:237-259` | After the final polling iteration logs remaining components | none; `post={finalizer_timed_out}` | Emit before any flag-clear call. |
| `FinalizeWarmboot_FinalizeGlobal` | `files/image_config/warmboot-finalizer/finalize-warmboot.sh:165-196,268-302` | After all namespace/global disable writes return and are read back | none; `post={flags_cleared, flags:{warm,fast,epoch}}` | `flags_cleared` contains every configured component key. |

## 3. Special considerations

### Ordering and buffering

- Send events to one sequencer synchronously at modeled boundaries. Per-process
  files merged later by timestamps are not sufficient for a Category A linear
  trace because container clocks and write buffering can reorder the READY,
  SAVE, APPLY, and finalizer cuts under test.
- The collector must append each line atomically. Flush at every event in test
  builds; fsync the controller-side `Syncd_CrashDuringApply` marker before kill.
- Redis read-back used for `post` must occur after the modeled command, never
  before it. Capture pipeline-backed fields only after the corresponding flush
  event unless the purpose is to record that they remain buffered.

### Bootstrap contract

`TraceInit` is `base.Init`; collection must begin before the first modeled
request and before warm restoration. Initial queues are empty/running, flags
are clear, snapshots are absent, APPLY is idle, and initial VID/RID maps must be
reciprocal. If collection starts from a later production state, add a separate
bootstrap event and update `TraceInit`; do not weaken individual post checks.

### Counterfactual/patched-build events

Four mechanisms are explicit brief §6.1 verification toggles:

- `UseEpochCAS` for MC-1;
- `ReplyAfterLocalDrain` and `OrchDaemon_WarmRestartReplyAfterFlush` for MC-2;
- `UseDurableApplyJournal`/`Syncd_ResumeFromDurableJournal` for MC-3;
- known-object labels and explicit terminal failure for MC-5/MC-6.

Current-code traces use all toggles `FALSE` as in `Trace.cfg` and must not emit
patched-only events. When validating a patched build, copy `Trace.cfg`, change
only the relevant toggle/domain constants, and retain every post-state check.

### Privacy and size

Route keys and VID/RID values can disclose topology. Normalize them in memory
and persist only the sidecar when the test environment permits. Avoid SAI
attributes, packet contents, full Redis dumps, and exact timing; the modeling
brief deliberately abstracts those details. Keep traces to one reboot attempt
or a focused fault cut so TLC replay remains diagnostic.
