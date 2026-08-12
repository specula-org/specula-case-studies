# Modeling Brief: SONiC Warm Reboot

## 1. System Overview

- **Target:** `sonic-net/sonic-buildimage`, checkout `9914efc028c3835c564eb0c6028a019991b5c422`, with the C++ `rebootbackend` as the entry point and the warm-reboot shell/service pipeline as its environment.
- **Category:** **A — distributed/message-passing system.** Independent `rebootbackend`, host-service, systemd, Redis, SWSS, syncd, and per-ASIC processes communicate through D-Bus, databases, files, events, and process termination. This is not a Byzantine protocol.
- A gNOI request is accepted into volatile C++ state, handed synchronously to the host over D-Bus, and then considered locally pending until the backend process exits or its post-handoff timer expires.
- The host service keeps a second, independent in-memory request record and launches `warm-reboot`; the request has no durable correlation or epoch identifier shared with the backend.
- `fast-reboot` enables persistent warm-start flags, quiesces applications, freezes orchagent, stops services in a generated partial order, snapshots Redis, and crosses a point after which rollback is disabled.
- Startup consumers restore state independently. `warmboot-finalizer` waits for registered components, but after its deadline it still clears warm flags and saves the database.
- Multi-ASIC systems repeat several operations per namespace while the physical reboot remains global, creating partial-success and mixed-mode possibilities.
- Successful cold/warm reboot is inferred from the requesting process disappearing; ordinary production code does not persist a successful terminal status.

## 2. Scenarios

### Scenario 1: Volatile Request Ownership Versus a Pending Host Reboot

- **Mechanism:** Split one logical reboot into backend admission, D-Bus acceptance, host-side execution, and physical completion. Allow the backend to crash/recover, its local timer to expire, and the host to complete late. Recovery currently reconstructs the backend as idle without consulting durable ownership or host state.
- **Evidence:** `reboot_thread.cpp:267-295` records active/count only in memory; `rebootbe.h:47-49` initializes the manager idle; `rebootbe.cpp:41-46` restores no request; `reboot_thread.cpp:145-152` begins its 260-second timer only after D-Bus returns; `reboot_thread.cpp:155-219` releases ownership after timeout. The `STATE_DB` handle is constructed but unused. The pinned host `reboot.py:83-97,140-251` maintains a separate in-memory status and worker. Open issue #27910 reports an ordering-induced shutdown wedge, and #11416 reports a startup race in which warm state is missed.
- **Affected Component(s):** `rebootbackend`, `sonic-host-services` reboot daemon, D-Bus, supervisor/systemd, physical reboot command.
- **Model Approach:** Variables for `backendAlive`, `backendActive`, `managerState`, `hostPending`, `hostStatus`, `requestEpoch`, `dbusPhase`, `localTimer`, and `platformPhase`. Actions: `Accept`, `DbusDeliver`, `DbusLose`, `HostAccept`, `BackendCrash`, `BackendRecover`, `LocalTimeout`, `HostComplete`, and `AcceptSecond`. Explore arbitrary delay and loss between these actions.
- **Priority:** High.
- **Rationale:** This is a live architectural gap at the C++/host boundary. It can admit overlapping commands and lose observable status without requiring a historical fixed defect.

### Scenario 2: Epoch-Scoped Warm Flags and Finalization Safety

- **Mechanism:** Treat every reboot attempt as an epoch. Warm flags, restored snapshots, component completion, finalization, and later config-reload/restart activity must refer to the same epoch. Model a missed or late component, a deadline, unconditional flag clearing/database save, and a subsequent boot or config reload.
- **Evidence:** `finalize-warmboot.sh:12-31` builds a component registry; `:237-300` waits per namespace but proceeds at the deadline; `:302-310` finalizes and saves regardless of timeout. Open issues #17943 and #15675 show late/unregistered consumers and stale warm state. Issue #12257 shows an asynchronous CONFIG_DB-to-APPL_DB update crossing the restart-check/freeze barrier. Fixed issues #2435/#22204 and the historical #6772 are reference evidence that stale or prematurely cleared state has affected later epochs; they are not themselves regression targets. Open PR #26911 additionally shows that bounding readiness waits is unsafe if timeout or malformed data is interpreted as readiness.
- **Affected Component(s):** warmboot finalizer, `STATE_DB`/`CONFIG_DB`, warm-start consumers, pmon/xcvrd, orchagent, config reload and later reboot attempts.
- **Model Approach:** Variables for monotonically increasing `epoch`, `warmFlagEpoch`, `snapshotEpoch`, per-component `restored` and `required`, `deadlineExpired`, `finalizedEpoch`, and `dbSavedEpoch`. Permit components to register/start late. Finalization may occur only after the required set for that epoch is complete or must transition to an explicit failed/recovery state without claiming completion.
- **Priority:** High.
- **Rationale:** Persistent flags are currently boolean-like state without ownership. Epoch confusion turns one incomplete reboot into corruption or wrong-mode behavior in a later operation.

### Scenario 3: Causal Quiescence and Monotonic Shutdown

- **Mechanism:** Replace the apparent static service list with causal dependencies: producers must stop producing, queued writes must become visible, consumers must acknowledge a drain, and no timer may resurrect a stopped service after its dependent has entered restore/shutdown. Include D-Bus delay and service-stop failure before and after the no-rollback point.
- **Evidence:** `fast-reboot:387-449` requests pre-shutdown and merely logs a wait failure; `:1075-1156` starts keepalive/CPA and freezes orchagent; `:1163-1180` disables rollback and ignores later errors; `:1187-1217` follows the generated service order. Issue #12257 demonstrates that empty local work does not imply propagated configuration is visible. Fixed #2750 demonstrates delayed service resurrection. Open #26758 reports keepalive behavior after its guard interval, #27910 reports syncd stopped before a blocked orchagent path, and #28787 reports APPLY_VIEW exceeding orchagent's fixed timeout. Open PR #25465's review identifies the need for a point where both old SWSS producers and syncd consumers are stopped; #27342 gives platform-specific evidence that CPU-punt traffic must quiesce before module removal. PR #28656 shows a live platform hook that power-cycles the ASIC after syncd stops unless preservation state is propagated correctly.
- **Affected Component(s):** systemd units, SWSS/orchagent, syncd, Redis queues, neighbor advertiser, teamd/LAG keepalive, platform modules.
- **Model Approach:** Represent a dependency DAG rather than exact unit names. Each producer has `running/quiescing/stopped`, each channel has `inFlight`, and each consumer has `drained/frozen/stopped`. Add independent timer events and failures. Cross `Commit` only after the pre-commit cut is causally closed; thereafter require monotonic progress to `Rebooted` or an explicit recovery terminal state.
- **Priority:** High.
- **Rationale:** Multiple current reports share this mechanism even though their concrete services differ. The abstraction can find new orderings rather than replaying one fixed incident.

### Scenario 4: Multi-ASIC Snapshot and Restore Coherence

- **Mechanism:** Model per-namespace warm enablement, quiescence, database pruning/copy, restore, timeout, and finalization around one global reboot. Allow one namespace operation to fail while others succeed and allow a crash between destructive pruning and snapshot copy.
- **Evidence:** `fast-reboot:101-148` executes namespace commands independently and can continue under force; `:452-506` prunes `STATE_DB` before copying `dump.rdb`; `:979-992` enables warm state per namespace; `:1130-1156` can force continuation after per-ASIC freeze; `:1219-1221` snapshots after service shutdown. `finalize-warmboot.sh:268-300` finalizes namespace flags independently. Open issue #11824 reports persisted-state schema incompatibility across releases, and fixed #27131 is historical evidence that per-ASIC persistent initialization state can survive into later boots. Open PR #28658 reports that restore ordering can make a configuration transition fatal even when cold initialization tolerates it; PR #28752 exposes a current save/restore path mismatch.
- **Affected Component(s):** database containers, per-ASIC SWSS/syncd instances, global services, warmboot-finalizer, snapshot files.
- **Model Approach:** Use a small finite set of ASIC namespaces. Track `mode[asic]`, `producerStopped[asic]`, `snapshotValidity[asic]`, `snapshotSchema[asic]`, `restored[asic]`, and a global `bootEpoch`. Add failures between prune/copy and during individual namespace commands. Require a coherent global decision: all compatible warm restores, or a defined cold-recovery transition that prevents stale producers and snapshots from being consumed.
- **Priority:** High.
- **Rationale:** The implementation composes local best-effort operations with a global irreversible action; partial failure is therefore a protocol state, not just a shell error.

### Scenario 5: Backend Worker Handoff and Failure Classification

- **Mechanism:** Split `set active`, worker creation, D-Bus transport, host rejection, stop, timer start, notification, join, and clear-active. Preserve distinct retriable and definitive outcomes.
- **Evidence:** `reboot_thread.cpp:281-293` sets active before thread construction; its exception path signals completion, but `Join` at `:40-55` does not clear active for a non-joinable thread. `interfaces.cpp:35-48` collapses D-Bus transport errors and host rejections into `DBUS_FAIL`; `reboot_thread.cpp:145-151,234-241` turns both into a non-retriable WARM failure. The timer and stop path do not cover the synchronous D-Bus call (`reboot_thread.cpp:64-103,144-152`).
- **Affected Component(s):** C++ `RebootThread`, `RebootBE` event loop, D-Bus adapter.
- **Model Approach:** Include this only as a small refinement if Scenario 1's abstract handoff cannot establish the ownership properties. Otherwise cover launch failure, blocking transport, and status classification with deterministic tests.
- **Priority:** Low for TLC; high for targeted tests.
- **Rationale:** The defects are concrete but mostly local, bounded control-flow errors. A state model is useful only where they interact with distributed ownership.

## 3. Recommendations

### Model

- Model backend and host ownership as separate state machines joined by a lossy/delayed handoff.
- Model crash/recovery of `rebootbackend` independently from completion of the physical reboot.
- Give each reboot, warm flag, snapshot, and completion record an epoch identity.
- Model finalization as a safety transition, not merely a deadline event.
- Model service dependencies as causal drain edges with messages in flight and independent timers.
- Model two ASIC namespaces to expose partial success, mixed warm/cold mode, and snapshot incoherence.
- Model the irreversible commit point and require a terminal reboot or explicit recovery state afterward.
- Abstract time to nondeterministic `Deadline` actions; retain relative ordering, not wall-clock seconds.

### Do Not Model

- Do not encode exact historical fixed bugs as adversary actions or invariant names; use them only to justify general mechanisms.
- Do not model Redis Lua hashing/runtime performance (#3008/#20235), sonic-cfggen latency (#22438), or generic platform boot duration (#23383).
- Do not model SAI object identities, kernel driver details, vendor-specific CPU-punt implementation, JSON formatting, logging, or metrics.
- Do not model exact systemd unit inventories; preserve only dependency roles and dynamically registered components.
- Do not model C++ allocation failure, the unlocked test-only accessor race, persistent `Select::ERROR`, or exception mechanics unless a smaller code-level model is explicitly requested.
- Do not assume every issue title states a root cause. The disputed #6212 and uncertain #27412/#7094 are excluded from confirmed premises.

## 4. Recommended Model Extensions

| Extension | Purpose | Scenarios | Priority |
|---|---|---|---|
| `BackendHostOwnership` | Separate local admission from host/platform pending state and add crash/recovery | 1, 5 | High |
| `EpochState` | Correlate flags, snapshots, restore acknowledgements, and finalization | 2, 4 | High |
| `CausalDrain` | Represent producer stop, in-flight updates, consumer drain, and freeze | 3 | High |
| `IrreversibleCommit` | Capture rollback-enabled and post-commit failure behavior | 3, 4 | High |
| `MultiNamespace` | Expose partial command, snapshot, restore, and finalization outcomes | 4 | High |
| `FailureClasses` | Distinguish transport loss, host rejection, timeout, and launch failure | 1, 5 | Medium |

## 5. Invariants to Verify

| Invariant | Statement |
|---|---|
| `SinglePendingReboot` | At most one reboot command for the active control processor is pending across backend and host state. |
| `OwnershipRecovery` | Backend recovery cannot report/admit idle while an uncorrelated host reboot remains pending. |
| `EpochConsistency` | A flag, snapshot, restore acknowledgement, finalization, and DB save used together have the same reboot epoch. |
| `NoPrematureFinalization` | An epoch is never marked finalized while a required warm consumer is incomplete or while its input remains in flight. |
| `CausalFreeze` | A consumer may freeze only after all required producers are quiescent and their prior writes are visible or explicitly discarded. |
| `ShutdownMonotonicity` | After the irreversible commit, no stopped pre-reboot producer is resurrected and execution reaches reboot or explicit recovery. |
| `SnapshotSafety` | A snapshot marked valid was copied completely from a quiescent, compatible namespace state. |
| `CrossNamespaceCoherence` | A global reboot never consumes an undefined mixture of warm and cold namespace state. |
| `RetryLiveness` | A retriable handoff failure eventually becomes inactive and permits another request under weak fairness. |
| `TimeoutIsNotReadiness` | Expiration, missing data, or malformed readiness data is never interpreted as successful readiness. |

## 6. Findings Pending Verification

### 6.1 Model Checking

- Can a backend crash after host acceptance, followed by recovery and a second request, violate `SinglePendingReboot`?
- Can local timeout release ownership before a late host completion and admit a second cold/HALT request?
- Can a finalizer deadline clear an epoch's flags and save DB while a required or late warm-sensitive consumer remains incomplete?
- Can a freeze observe an empty work queue while a causally prior configuration update remains in transit?
- Can one namespace fail after prune or warm enablement while the global reboot proceeds with mixed state?
- After the no-rollback point, can an ignored stop/snapshot failure leave the system live but permanently degraded rather than terminal?
- What is the weakest durable epoch/ownership record sufficient to make recovery safe without requiring exactly-once D-Bus delivery?

### 6.2 Testing

- Inject `std::thread` construction failure after `active=true`; verify completion clears active and exposes `RETRIABLE_FAILURE`.
- Separately inject D-Bus transport failure and host application rejection; verify retry policy preserves the distinction.
- Block the D-Bus call, issue `Stop`, and test the intended end-to-end deadline/cancellation contract.
- Return host success, let the backend timer expire, then complete the first host action late and attempt a second request.
- Kill and recreate `rebootbackend` after host acceptance; exercise recovered status and duplicate-request rejection.
- Test nonzero WARM delay end-to-end. The C++ path accepts it before the pinned host rejects it, unlike COLD/HALT.
- Fault each namespace command and the prune-to-copy snapshot window; verify all-warm or defined cold recovery.
- Delay CONFIG-to-APPL propagation and component registration beyond freeze/finalizer events.
- Exercise a platform stop hook that would reset preserved hardware; assert warm/fast state suppresses it and the SAI state artifact exists on restore.
- Inject partial object construction followed by rollback (the PR #28759 mechanism); verify cleanup does not assume full initialization.
- Add TSAN coverage for cross-thread use of the unlocked public `GetCurrentStatus` helper.
- Fault a persistent `swss::Select::ERROR`; confirm whether timer/stop progress remains possible.

### 6.3 Code Review

- Decide and document the authoritative owner of a pending reboot across backend restart; remove the unused `STATE_DB` handle or use a durable epoch record.
- Review `Join`'s non-joinable path against the thread-creation catch and manager transition to `IDLE`.
- Review why host immediate command failure is not polled by C++ for COLD/WARM, producing an avoidable wait until local timeout.
- Define whether the 260-second deadline begins at client admission, D-Bus acceptance, or host execution, and make cancellation/query semantics match.
- Audit finalizer component registration for late-start services such as pmon/xcvrd and prohibit timeout from silently claiming success.
- Audit post-commit shell commands whose failures are ignored, especially generated shutdown order and database snapshot creation.
- Define the atomicity of `STATE_DB` pruning plus `dump.rdb` copy and the compatibility contract for restored schemas.
- Review recovery from failed warm/fast reboot so old SWSS producers and syncd consumers share a quiescent incarnation boundary.

## 7. Reference Pointers

- C++ core: `src/sonic-sysmgr/rebootbackend/{rebootbe.cpp,reboot_thread.cpp,interfaces.cpp}` and headers/tests at checkout `9914efc0`.
- Finalizer: `files/image_config/warmboot-finalizer/finalize-warmboot.sh`.
- Shutdown manifests: `files/image_config/warmboot-finalizer/`, `files/build_templates/*service-requires`, and generated service-order inputs used by `fast-reboot`.
- Pinned host service: `sonic-host-services@233cd591c324d4090a077f87da0eaaad7d12cabc`, `host_modules/reboot.py`.
- Pinned orchestration script: `sonic-utilities@b17c48270c15fc6d5c81a23d97e2946cd7059dcd`, `scripts/fast-reboot`.
- API contract: `gnoi-system@2b6ff72de5769839fc68bd019f345a184e3b0bf1`, `system/system.proto`.
- Highest-value live tracker evidence: sonic-buildimage issues #17943, #11416, #11824, #12257, #12361, #15675, #26758, #27910, #28787; PRs #25465, #26911, #27342, #28656, #28658, #28752, #28759.
- Historical generalization evidence only: issues #2435, #2750, #6772, #7488, #22204, #27131 and their linked fixes.
