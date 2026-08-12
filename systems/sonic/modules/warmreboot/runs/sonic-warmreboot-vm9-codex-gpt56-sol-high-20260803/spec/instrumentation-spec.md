# Warm Reboot Instrumentation Specification

This document is the handoff contract for producing Category A NDJSON traces accepted by `Trace.tla`. Source paths are relative to `/users/Pial/targets/sonic-buildimage-warmreboot-high`. The `sonic-host-services` and `sonic-utilities` directories are unpopulated gitlinks in this checkout; initialize them at the pinned commits before patching:

- `src/sonic-host-services` at `233cd591c324d4090a077f87da0eaaad7d12cabc`
- `src/sonic-utilities` at `b17c48270c15fc6d5c81a23d97e2946cd7059dcd`

## 1. Trace Event Schema

Emit one raw event at each trigger below. A merger orders events by `(monotonic_ns, process_instance, local_seq)`, correlates a logical request with a harness-only `trace_epoch`, and applies the deterministic shadow-state updates listed in the mapping. The enriched output is one NDJSON object per line:

```json
{
  "tag": "trace",
  "event": {
    "name": "EnableWarmRestart",
    "source": "fast-reboot",
    "process_instance": "uuid",
    "local_seq": 17,
    "monotonic_ns": 123456789,
    "trace_epoch": 1,
    "asic": "asic0",
    "component": "",
    "observed": {},
    "state": {
      "warm": {}
    }
  }
}
```

`asic` is required exactly for ASIC-parameterized actions and `component` exactly for component-parameterized actions. `observed` contains raw implementation values and command results. `state` is produced by the merger and must contain the complete post-action abstract record(s) modified by that action. This is mandatory: `Trace.tla` performs exact equality and has no missing-field fallback.

The full `state.backend` record contains `alive`, `active`, `manager`, `requestEpoch`, `nextEpoch`, `dbusPhase`, `localTimer`, `hostPending`, `hostEpoch`, `hostStatus`, `failureClass`, `failureCause`, and `threadJoinable`.

The full `state.shutdown` record contains `platformPhase`, `rollbackEnabled`, `producerState`, `inFlight`, `consumerState`, `stoppedAtCommit`, and `postCommitFailure`. Function-valued fields are JSON objects keyed by `asic0`, `asic1`, and so on; `stoppedAtCommit` is a JSON array/set of ASIC strings.

The full `state.warm` record contains `bootEpoch`, `flagEpoch`, `snapshotEpoch`, `snapshotValidity`, `snapshotSchema`, `copyComplete`, `snapshotQuiescent`, `namespaceFailed`, `restoreDecision`, `restoreEpoch`, `consumedSnapshotEpoch`, `restoredEpoch`, `required`, `readiness`, `deadlineExpired`, `finalizedNsEpoch`, `finalizedEpoch`, and `dbSavedEpoch`. `required` is a JSON array/set of component strings.

Epoch `0` means no epoch. The epoch is trace metadata only and must not be added to production D-Bus/API behavior. On backend admission the merger allocates the next integer. It correlates host and shell events by process instance, request payload digest, D-Bus call interval, and causal order. After a backend crash, the host event remains associated with the old epoch while a new backend admission receives a new epoch; this is the ownership gap the trace must preserve.

## 2. Action-to-Code Mapping

Every row is one spec action and one trace event type. “Record” names the exact complete post-state record required under `event.state`; “observed” lists the raw fields needed by the merger to build it.

| Spec action / event name | Code location | Trigger point | Required raw `observed` fields | Record | Notes |
|---|---|---|---|---|---|
| `HandleRebootRequestAccept` | `src/sonic-sysmgr/rebootbackend/rebootbe.cpp:168-207`; `reboot_thread.cpp:222-285` | After `Start` succeeds and `SetCurrentStatus` completes | method, request digest, manager status, active, thread joinable | `backend` | Allocate `trace_epoch`; event is after both volatile state updates. |
| `StartThreadLaunchFailure` | `reboot_thread.cpp:281-293` | In the `std::system_error` catch, after retriable status and before `m_finished.notify()` | request digest, active, last status, `thread.joinable()` | `backend` | Preserve `active=true` and `threadJoinable=false`. |
| `HostServiceIssueRebootAccept` | pinned `src/sonic-host-services/host_modules/reboot.py:83-97,140-251`; caller `reboot_thread.cpp:144-152` | Host: after worker/status accepts; merge with successful D-Bus return | request digest, host pending/status, D-Bus return status | `backend` | Correlate to caller interval; do not invent durable ownership. |
| `HostServiceIssueRebootReject` | pinned `reboot.py:83-97,140-251`; `interfaces.cpp:43-48` | After host rejects and before failure is returned to C++ | request digest, host pending/status, application status/retString | `backend` | Distinct raw cause even though C++ returns `DBUS_FAIL`. |
| `HostServiceTransportFailure` | `interfaces.cpp:35-41`; `reboot_thread.cpp:148-150` | In D-Bus exception path after C++ failure status is set | request digest, exception class, active, status | `backend` | Raw cause must be `transport`. |
| `WaitForPlatformRebootStart` | `reboot_thread.cpp:88-103`, called from `:155-209` | Immediately after `l_timer.start()` | request digest, timer started, D-Bus outcome | `backend` | Timer begins only after synchronous D-Bus completion. |
| `PlatformRebootDeadline` | `reboot_thread.cpp:64-103,155-209` | After timer selection and completed failure status | request digest, timer stopped, status, failure text | `backend` | Do not emit on SIGTERM/normal process disappearance. |
| `HandleRebootFinishJoinable` | `reboot_thread.cpp:40-55`; `rebootbe.cpp:302-309` | After successful join and manager reset | active, manager, joinable, status | `backend` | Must follow the worker-finished notification. |
| `HandleRebootFinishNonJoinable` | `reboot_thread.cpp:40-46`; `rebootbe.cpp:302-309` | After failed non-joinable `Join` and manager reset | active, manager, joinable, status | `backend` | Critical launch-failure refinement: active remains set. |
| `BackendCrash` | process supervisor around `rebootbe.cpp:41-72`; volatile fields defined by `rebootbe.h:47-49` | Immediately when the old process instance exits unexpectedly | old process instance, reason/signal, last request digest | `backend` | Merger clears backend-local fields only; host fields remain. |
| `BackendRecover` | `rebootbe.cpp:23-30,41-46`; `rebootbe.h:47-49` | At new process initialization before operational loop | new process instance, initial manager/active, warm-start result | `backend` | Verifies no host query/durable request restoration occurred. |
| `HostComplete` | pinned `reboot.py:140-251` | At worker terminal completion, before host status cleanup | request digest, host status, command exit/result | `backend` | May occur after backend timeout/recovery. |
| `FastRebootBegin` | pinned `src/sonic-utilities/scripts/fast-reboot:979-992` | Before first per-namespace warm enable command | request digest, reboot type, namespace list | `shutdown`, `warm` | Assign correlated host epoch to `bootEpoch`. |
| `EnableWarmRestart` | pinned `fast-reboot:979-992` | After each namespace enable command succeeds | namespace, command, exit code, resulting enable value | `warm` | One event per namespace. |
| `NamespaceCommandFailure` | pinned `fast-reboot:101-148,979-992,1130-1156` | Immediately after a namespace-scoped command fails but force mode continues | namespace, command, exit code, force flag | `warm` | Fault harness emits the same event when injecting failure. |
| `PreShutdownProducer` | pinned `fast-reboot:387-449,1075-1156` | After pre-shutdown request is issued for the namespace | namespace, producer role, command result | `shutdown` | Abstract exact unit names into the producer role. |
| `QueueConfigurationUpdate` | CONFIG_DB producer hook at the barrier described by pinned `fast-reboot:1075-1156` | After a producer commits a relevant CONFIG_DB update and before APPL_DB visibility | namespace, update trace ID, source DB sequence | `shutdown` | Fault/test hook corresponding to brief finding #12257. |
| `DeliverConfigurationUpdate` | APPL_DB consumer observation paired with the above barrier | On first consumer observation/ack of the update trace ID | namespace, update trace ID, destination DB sequence | `shutdown` | Must match exactly one queued event. |
| `StopProducer` | pinned `fast-reboot:1187-1217` generated service-order loop | After the producer stop command returns success | namespace, producer role, exit code, unit state | `shutdown` | One abstract producer per namespace. |
| `DrainConsumer` | pinned `fast-reboot:387-449`; consumer drain acknowledgement | After drain acknowledgement with zero paired in-flight writes | namespace, consumer role, ack, outstanding trace IDs | `shutdown` | The merger must reject a fabricated drain with outstanding IDs. |
| `FreezeOrchagent` | pinned `fast-reboot:1130-1156` | After each freeze/wait result, including forced continuation | namespace, freeze result, local queue result, outstanding trace IDs | `shutdown` | Retain `inFlight`; local empty is not global visibility. |
| `PruneNamespaceState` | pinned `fast-reboot:452-506` | Immediately after destructive STATE_DB pruning and before copy | namespace, prune exit code, pre-copy file metadata | `warm` | This is a required crash/failure boundary. |
| `SelectIncompatibleSnapshotSchema` | version/schema probe before pinned `fast-reboot:452-506,1219-1221`; restore at `files/build_templates/docker_image_ctl.j2:107-114` | After schema/version comparison returns incompatible | namespace, source schema, target schema | `warm` | Environment/fault event; never infer incompatibility merely from copy failure. |
| `SnapshotCopySuccess` | pinned `fast-reboot:1219-1221` | After copy/fsync/rename succeeds | namespace, exit code, byte count, checksum, schema, producer state | `warm` | `copyComplete=true` only after complete durable artifact. |
| `SnapshotCopyFailureLeavesArtifact` | pinned `fast-reboot:1163-1180,1219-1221` | After copy failure, after recording whether an artifact still exists | namespace, exit code, byte count, checksum/existence, producer state | `warm` | Fault hook must preserve actual stale/partial artifact metadata. |
| `CommitNoRollback` | pinned `fast-reboot:1163-1180` | Immediately after rollback is disabled | rollback flag, platform phase, stopped producer set | `shutdown` | This is the irreversible linearization point. |
| `TimerResurrectProducer` | systemd/timer event around pinned `fast-reboot:1187-1217` | After a stopped producer becomes active again post-commit | namespace, unit, timer/activation cause, unit state | `shutdown` | Independent timer injection; general mechanism, not a historical regression action. |
| `PostCommitStopFailure` | pinned `fast-reboot:1163-1180,1187-1221` | After a post-commit stop/snapshot command fails and execution ignores it | command, namespace if any, exit code, rollback flag | `shutdown` | `postCommitFailure=true`; do not emit a recovery claim. |
| `PhysicalReboot` | pinned host `reboot.py:140-251` and end of pinned `fast-reboot:1187-1221` | At positive observation of reboot boundary/process incarnation change | old/new boot ID, request digest | `shutdown` | Process disappearance alone must be tied to boot ID change. |
| `EnterExplicitRecovery` | no current automatic source transition; administrative recovery boundary after pinned `fast-reboot:1163-1180` | Only after an operator/tool explicitly declares recovery terminal | recovery command, operator reason, rollback flag | `shutdown` | Current post-commit state has rollback false, so base guard rejects this event; retain for future implementation comparison. |
| `StartRestore` | `files/build_templates/docker_image_ctl.j2:107-114,296-314` | Before the first namespace database restore decision | boot ID, namespace list, boot type | `shutdown` | One global event. |
| `RestoreNamespaceWarm` | `docker_image_ctl.j2:107-114,296-314` | After a namespace consumes the warm dump | namespace, flag value, file path, checksum, schema, load result | `warm` | Capture consumed snapshot epoch from merger correlation. |
| `RestoreNamespaceCold` | `docker_image_ctl.j2:112-114,296-314` | After the namespace chooses/creates empty cold DB | namespace, reason, empty-file command result | `warm` | Reason is failed namespace, absent flag, or absent invalid snapshot. |
| `CompleteRestore` | restore orchestration boundary after all `docker_image_ctl.j2:107-114,296-314` decisions | After all namespace DB containers expose their selected mode | per-namespace modes, boot ID | `shutdown` | Exposes the global coherence decision. |
| `RegisterWarmComponent` | `files/image_config/warmboot-finalizer/finalize-warmboot.sh:12-27,91-102` | When a component is added to the enabled reconciliation list | component, service, namespace/global scope | `warm` | Emit dynamic registrations too; do not snapshot the list too early. |
| `WarmComponentReconciled` | `finalize-warmboot.sh:139-155,237-254` | After an exact `reconciled` value is observed | component, namespace, raw value, read result | `warm` | Only exact valid data maps to ready. |
| `FinalizerTimeoutAsReady` | `finalize-warmboot.sh:255-287`; malformed/timeout fault probe motivated by PR #26911 | When the injected probe observes timeout/malformed data at the readiness boundary | component, namespace, timeout/malformed marker, raw value | `warm` | Despite the retained event name, this is telemetry only: set readiness to timeout and never infer a restored epoch. |
| `FinalizerDeadline` | `finalize-warmboot.sh:246-258` | Immediately after the 60-iteration loop exits with a nonempty list | incomplete component list, namespace, iteration count | `warm` | Abstract wall time to one nondeterministic event. |
| `FinalizeNamespace` | `finalize-warmboot.sh:165-190,268-290` | After namespace warm/fast flags are cleared | namespace, prior/new flag values, command exits | `warm` | One event per namespace, including deadline path. |
| `FinalizeGlobal` | `finalize-warmboot.sh:293-302` | After child waits and global finalization completes | child results, prior/new global flags | `warm` | Must follow all namespace finalization events. |
| `SaveDatabase` | `finalize-warmboot.sh:308-310` | After `config save -y` returns | exit code, saved boot ID/epoch, config checksum | `warm` | Never treat command invocation alone as successful save. |

## 3. Special Considerations

The three processes do not share an epoch today. The collector must keep `trace_epoch` out of production state and construct it only in the trace merger. A backend restart starts a new `process_instance`; it must not accidentally inherit the old backend owner merely because a host request remains pending.

Use `CLOCK_MONOTONIC_RAW` (or the language runtime’s monotonic equivalent) and a per-process atomic sequence. If intervals overlap, retain causal edges from D-Bus call/return, process parentage, database update IDs, and boot IDs; do not sort solely by wall clock. The output for this Category A model must still be a single causal linearization.

The shell scripts run namespace work in parallel (`finalize-warmboot.sh:268-300`). Emit from each subprocess to a pipe/socket with atomic single-line writes and distinct process instances; merge only after collection. Never let concurrent writers append partial JSON to a shared regular file.

The enriched state reducer is deterministic and mirrors `base.tla` action updates. It may only update a record after seeing the corresponding raw event and required fields. It must fail closed on missing fields, unknown ASIC/component names, unmatched update IDs, epoch overflow, or impossible action order. It must not repair traces to satisfy TLA+ guards.

For snapshot events, capture exit status plus file identity, byte count, checksum, schema/version, and whether producers were quiescent. File existence alone is not copy success. For physical reboot, use a boot-ID/incarnation transition; successful RPC return or backend disappearance alone is not physical completion.

The default enriched trace path is `../traces/trace.ndjson` relative to `spec/`. A run may override it through `IOEnv.JSON`. `Trace.cfg` sets `MaxEpoch=8` and `MaxInFlight=8`; the merger must reject a trace exceeding those values or generate a per-run config with safe larger bounds.
