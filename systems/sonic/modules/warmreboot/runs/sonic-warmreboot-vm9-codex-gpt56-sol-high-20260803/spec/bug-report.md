# Bug Report — SONiC Warm Reboot

## Summary

- Scenarios tested: 5
- Bugs found: 5
- Configs run: `MC_hunt_scenario1.cfg`, `MC_hunt_scenario2.cfg`, `MC_hunt_scenario3.cfg`, `MC_hunt_scenario4.cfg`, `MC_hunt_scenario5.cfg`

## Bug 1: Backend Restart Loses Accepted-Reboot Ownership

- **Scenario**: 1 — backend restart during an accepted reboot
- **Severity**: High
- **Invariant violated**: `OwnershipRecovery`
- **Config**: `MC_hunt_scenario1.cfg`
- **Counterexample**: 5 states, `spec/output/MC_hunt_scenario1_bfs.out`

### Trace Summary

1. The backend accepts a reboot request and the host records it as pending at epoch 1.
2. The backend crashes while the accepted operation is still owned by the host-side workflow.
3. The backend restarts with its manager state reset to idle.
4. The host still has a pending reboot, but the restarted backend is neither active nor associated with that request. `OwnershipRecovery` is violated.

TLC explored the complete graph for this configuration: 40 generated states, 29 distinct states, and depth 10.

### Root Cause

Backend reboot ownership is process-local. `RebootManager` initializes its status to `IDLE`, while construction and startup create database connectors and a worker thread without recovering an accepted request or querying the separately maintained host reboot status. The host workflow keeps its own in-memory `reboot_status_flag`; therefore a backend process restart can expose an idle control plane while the previously accepted reboot remains pending.

### Affected Code

- `src/sonic-sysmgr/rebootbackend/rebootbe.h:48`: initializes backend reboot status to `IDLE`.
- `src/sonic-sysmgr/rebootbackend/rebootbe.cpp:26`: constructs the backend without restoring operation ownership.
- `src/sonic-sysmgr/rebootbackend/rebootbe.cpp:44`: starts warm-reboot handling without reconciling host-side pending state.
- `src/sonic-host-services/host_modules/reboot.py:74`: maintains the host's separate process-local reboot status.

### Recommendation

Persist an operation identifier and lifecycle state in a shared durable store before acknowledging acceptance. On backend startup, reconcile that record with the host-side reboot status and resume or explicitly fail the operation before admitting another request.

---

## Bug 2: Late Warm Component Is Omitted from Finalization Barrier

- **Scenario**: 2 — component registration after the finalizer's startup snapshot
- **Severity**: High
- **Invariant violated**: `NoPrematureFinalization`
- **Config**: `MC_hunt_scenario2.cfg`
- **Counterexample**: 14 states, `spec/output/MC_hunt_scenario2_bfs.out`

### Trace Summary

1. The finalizer begins with an empty required-component set and finalizes both ASIC namespaces.
2. A warm-sensitive component (`orchagent`) becomes required after those namespace barriers have completed.
3. The component has not restored the current boot epoch.
4. Global finalization nevertheless completes at epoch 1, violating `NoPrematureFinalization`.

TLC generated 116,308 states and found 33,653 distinct states at depth 14 before the violation.

### Root Cause

The finalizer snapshots `*_reconcile` files once at startup and never refreshes the component list. Each namespace worker waits only for that initial list; after all workers exit, the script unconditionally runs global finalization and saves configuration. A component whose reconciliation marker appears after the snapshot is invisible to the barrier, so the reboot can be declared complete before that component reconciles.

### Affected Code

- `files/image_config/warmboot-finalizer/finalize-warmboot.sh:25`: discovers reconciliation files only during startup.
- `files/image_config/warmboot-finalizer/finalize-warmboot.sh:93`: builds the required-component list from the static discovery result.
- `files/image_config/warmboot-finalizer/finalize-warmboot.sh:313`: namespace completion depends only on the captured component list.
- `files/image_config/warmboot-finalizer/finalize-warmboot.sh:334`: performs global finalization after workers exit without rechecking registrations.

### Recommendation

Freeze registration explicitly before finalization, or repeatedly discover and version the required set until it is stable. Bind global completion to a generation number and require every component in that generation to report exact `reconciled` state before finalizing.

---

## Bug 3: Configuration Update Can Cross the Consumer Freeze Boundary

- **Scenario**: 3 — producer update races with orchagent freeze
- **Severity**: High
- **Invariant violated**: `CausalFreeze`
- **Config**: `MC_hunt_scenario3.cfg`
- **Counterexample**: 9 states, `spec/output/MC_hunt_scenario3_bfs.out`

### Trace Summary

1. A warm reboot is accepted and shutdown preparation begins.
2. The ASIC consumer is frozen with no configuration update in flight.
3. The configuration producer remains able to run, matching the script's pause-before-service-stop ordering.
4. A new configuration update is emitted after the consumer is frozen, leaving one update in flight and violating `CausalFreeze`.

TLC generated 1,081 states and found 734 distinct states at depth 12 before the violation.

### Root Cause

The reboot script pauses orchagent before it stops the producer services, and it has no cross-database generation or drain barrier proving that all causally prior configuration writes are visible before the consumer freezes. The restart check can also be force-bypassed. Consequently, an asynchronous configuration write can be accepted after the consumer's freeze point and be absent from the state preserved for warm restart.

### Affected Code

- `src/sonic-utilities/scripts/fast-reboot:1159`: starts the orchagent pause sequence.
- `src/sonic-utilities/scripts/fast-reboot:1183`: permits the pause/restart check to be ignored under force handling.
- `src/sonic-utilities/scripts/fast-reboot:1235`: stops producer services only after the consumer has been paused.

### Recommendation

Introduce an explicit quiescence protocol: stop or fence all configuration producers, capture a monotonically increasing generation, drain propagation through the databases, and only then freeze orchagent. Reject or queue writes whose generation is newer than the acknowledged freeze generation.

---

## Bug 4: Failed Snapshot Copy Leaves a Restorable Artifact

- **Scenario**: 4 — snapshot copy fails after destructive pruning
- **Severity**: High
- **Invariant violated**: `SnapshotSafety`
- **Config**: `MC_hunt_scenario4.cfg`
- **Counterexample**: 7 states, `spec/output/MC_hunt_scenario4_bfs.out`

### Trace Summary

1. Warm-shutdown processing destructively prunes the database before taking its snapshot.
2. Snapshot copy begins without a proven quiescent, complete image.
3. The copy fails or leaves a partial/stale destination artifact.
4. The destination is still treated as a valid epoch-1 snapshot although `copyComplete` and `snapshotQuiescent` are false, violating `SnapshotSafety`.

TLC generated 2,226 states and found 1,420 distinct states at depth 12 before the violation.

### Root Cause

The backup path prunes Redis data and then copies `dump.rdb` directly to the warm directory without an atomic temporary file, success validation, or integrity marker. The restore path treats mere file existence as sufficient evidence that the snapshot is usable. A failed copy can therefore leave an old or partial `dump.rdb` that is selected for warm restoration.

### Affected Code

- `src/sonic-utilities/scripts/fast-reboot:470`: begins destructive database backup and pruning.
- `src/sonic-utilities/scripts/fast-reboot:503`: copies `dump.rdb` directly into the restorable path without validating the result.
- `files/build_templates/docker_image_ctl.j2:107`: gates restoration on file existence rather than validated completeness.

### Recommendation

Copy each snapshot to a unique temporary path, verify command success and integrity while the source is quiescent, write an epoch-bound manifest, and atomically rename the artifact only after validation. Restore only artifacts whose manifest, checksum, namespace set, and boot epoch all match.

---

## Bug 5: Transient D-Bus Failure Is Classified as Definitive

- **Scenario**: 5 — transport loss while dispatching the host reboot request
- **Severity**: Medium
- **Invariant violated**: `FailureClassification`
- **Config**: `MC_hunt_scenario5.cfg`
- **Counterexample**: 3 states, `spec/output/MC_hunt_scenario5_bfs.out`

### Trace Summary

1. The backend accepts a reboot request.
2. The D-Bus transport is lost while the request is dispatched.
3. The transport failure is recorded as definitive rather than retriable, violating `FailureClassification`.

TLC explored the complete graph for this configuration: 11 generated states, 9 distinct states, and depth 5.

### Root Cause

The D-Bus wrapper maps both transport exceptions and a nonzero host application result to the same `DBUS_FAIL` value. The reboot thread then maps every `DBUS_FAIL` to a non-retry failure even though the protocol and implementation contain a retriable-failure path. The caller cannot distinguish an uncertain transient transport outcome from an authoritative host rejection.

### Affected Code

- `src/sonic-sysmgr/rebootbackend/interfaces.cpp:35`: maps a D-Bus exception to `DBUS_FAIL`.
- `src/sonic-sysmgr/rebootbackend/interfaces.cpp:43`: maps a host-side nonzero result to that same value.
- `src/sonic-sysmgr/rebootbackend/reboot_thread.cpp:169`: classifies every `DBUS_FAIL` as non-retry.
- `src/sonic-sysmgr/rebootbackend/reboot_thread.cpp:357`: contains an otherwise available retry-failure response path.

### Recommendation

Use distinct results for transport uncertainty and authoritative host rejection. Return `RETRIABLE_FAILURE` for failures known not to have reached the host; for ambiguous delivery, attach an idempotency key and reconcile operation status before retrying.

---

## Not Reproduced

| Scenario | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| None | — | — | All five targeted scenarios produced invariant violations. |

## Spec Adjustments During Hunting

- **Case B — `FinalizerTimeoutAsReady`**: the original model and trace reducer incorrectly treated a finalizer timeout as successful restoration. The production script accepts only exact `reconciled` state, so the invented restored-epoch update was removed and all traces plus the base model were revalidated.
- **Case A — `CausalFreeze`**: the original invariant also required the abstract producer to be stopped when the consumer froze. Production intentionally pauses orchagent before stopping services, so the unsupported producer-state clause was removed while retaining the implementation-backed no-update-in-flight requirement.
