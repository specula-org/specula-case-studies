# Modeling Brief: SONiC Warm Reboot Orchestration

## 1. System Overview

- **System**: SONiC Warm Reboot — multi-component hitless upgrade orchestration across sonic-swss (orchagent), sonic-sairedis (syncd), and auxiliary daemons (neighsyncd, fdbsyncd, teamd, xcvrd)
- **Language**: C++ (orchagent, syncd), Python (Warmboot Manager, utilities)
- **Scale**: ~6000 LOC syncd core, ~1300 LOC orchdaemon, ~750 LOC warm restart libraries, ~400 LOC per syncd/daemon warm path
- **Category**: **Category A (Distributed / Message-Passing)** — 6+ components coordinate via Redis state tables (STATE_DB, APP_DB, ASIC_DB) using a 4-phase shutdown protocol and independent per-component reconciliation with timer-based completion
- **Protocol**: 4-phase shutdown (Sanity → Freeze/Quiescence → Checkpoint → Reboot) followed by per-component state restore and reconciliation, with an INIT_VIEW/APPLY_VIEW handshake between orchagent and syncd
- **Key architectural choices**:
  - Components reconcile independently on their own timers (5s–120s) with no global ordering barrier
  - orchagent uses a fixed 3-iteration `doTask()` loop for state restore (no convergence guarantee)
  - syncd APPLY_VIEW has a two-stage design: non-destructive comparison then destructive ASIC operations with no rollback
  - Phase 3 (Checkpoint) is the "point of no return" — syncd disconnects from ASIC, no recovery possible on failure
  - Warm restart state machine (Frozen→Quiescent→Checkpointed→Initialized→Reconciled→Failed) tracked in Redis STATE_DB
- **Concurrency model**: Single-threaded event loops per component + ring buffer thread in orchagent; cross-component coordination is asynchronous via Redis pub/sub and polling

## 2. Bug Families

### Family 1: Reconciliation Ordering Violations (HIGH)

**Mechanism**: Components reconcile independently based on their own timers (5s–120s) or synchronous passes, with no global ordering barrier. Dependent state is consumed before its prerequisites finish reconciliation.

**Evidence**:
- Historical: orchagent 3-iteration restore insufficient (commit `5796e544`), VNET orch before VRF/VxLAN orch (`4a174f4f`), FdbSyncd replays before interfaces restored (`721f47d9`), DualToR neighbor updates before mux state settled (`3da2e676`), FlexCounter before APPLY_VIEW (`a8a28a84`), blackhole routes removed during warm restart (`7dd3be98`)
- Code analysis: orchagent declares RECONCILED while neighsyncd still has 5–120s timer pending (`orchdaemon.cpp:1132`); neighorch and routeorch have zero warm restart awareness — no `bake()` override, no dependency gating; vlanmgrd/vxlanmgrd/vrfmgrd declare RECONCILED on first 1s SELECT_TIMEOUT with no content verification; orchagent APPLY_VIEW commits at `orchdaemon.cpp:1123` before fdbsyncd's 120s timer completes

**Affected code paths**:
- `OrchDaemon::warmRestoreAndSyncUp()` (`orchdaemon.cpp:1059–1136`)
- `AppRestartAssist::reconcile()` (`warmRestartAssist.cpp:258–306`)
- `WarmStartHelper::reconcile()` (`warmRestartHelper.cpp:152–260`)
- `fdbsync::isIntfRestoreDone()` (`fdbsync.cpp:54–69`)
- `neighsyncd` main loop (`neighsyncd.cpp:44–90`)

**Suggested modeling approach**:
- Variables: `componentState[Component -> {Initialized, Restored, Reconciled, Failed}]`, `reconcileTimer[Component -> Nat]`, `appDB[Table -> Key -> Value]`
- Actions: `ReconcileComponent(c)` — component c applies its cached diff to appDB; `ProcessAppDBEntry(c, entry)` — orchagent processes an appDB entry, checking dependency availability
- Granularity: Each component reconcile is a separate action; interleave with orchagent processing to find ordering violations
- Key: Model the dependency chain Port→LAG→Interface→ARP→Route and show that independent timers can violate it

**Priority**: High
**Rationale**: 6+ historical bugs sharing this mechanism. Confirmed unfixed design defect (orchdaemon.cpp:1132 comment). Directly affects data-plane correctness — traffic black-holes when routes installed before ARP, or FDB committed before VXLAN tunnels.

---

### Family 2: Freeze/Quiescence Protocol Violations (HIGH)

**Mechanism**: The freeze handshake between the warm reboot orchestrator and components has TOCTOU races — the READY reply is sent before the system is actually quiescent, events arrive between freeze notification and actual quiescence, and there is no recovery (unfreeze) path on failure.

**Evidence**:
- Historical: `orchagent_restart_check` 1s timeout race (swss issue #827), `neighbor_advertiser` vs orchagent freeze ordering (buildimage #12257), no unfreeze mechanism (buildimage #25224), permanent freeze on double warm-reboot (swss PR #2471)
- Code analysis: TOCTOU between READY reply and ring buffer drain (`orchdaemon.cpp:1012–1051`) — READY sent at line 1207 but ring buffer not drained until lines 1019–1026; ring buffer `head`/`tail`/`idle_status` accessed without atomics (`orch.h:196–228`); FDB learning disable ignores SAI error on partial ports (`orchdaemon.cpp:1035–1041`)

**Affected code paths**:
- `OrchDaemon::warmRestartCheck()` (`orchdaemon.cpp:1178–1209`)
- `OrchDaemon::start()` main loop (`orchdaemon.cpp:1012–1051`)
- `orchagent_restart_check` binary (`orchagent_restart_check.cpp:44–161`)
- `OrchDaemon::freezeAndHeartBeat()` (`orchdaemon.cpp:1234–1245`)

**Suggested modeling approach**:
- Variables: `orchState ∈ {Running, CheckingReady, Draining, Frozen}`, `pendingEvents: Seq(Event)`, `ringBufferEmpty: BOOLEAN`, `freezeReplyeSent: BOOLEAN`
- Actions: `ReceiveEvent` — event arrives in ring buffer while orchagent is between READY-reply and Frozen; `DrainRingBuffer` — ring buffer processing may add new m_toSync entries; `Freeze` — actual freeze that blocks event processing
- Key: Show that events arriving between READY reply and actual freeze can leave unsaved state

**Priority**: High
**Rationale**: 4 historical bugs. Critical for warm reboot correctness — if orchagent is not truly quiescent when it claims READY, the checkpoint contains in-flight state. No unfreeze recovery means any failure post-freeze requires cold reboot.

---

### Family 3: APPLY_VIEW Non-Transactional Failure (CRITICAL)

**Mechanism**: syncd's APPLY_VIEW has a two-stage design where Stage 2 (destructive ASIC operations) has no rollback. Failure during Stage 2 leaves the ASIC in an inconsistent state with no recovery path. Failure during Stage 1 leaves syncd in normal mode with stale metadata.

**Evidence**:
- Historical: APPLY_VIEW fail → infinite INIT_VIEW loop (buildimage #7072), comparison logic reference integrity break (`85a579b3`), RIF counter fail sends shutdown_request (#9898), new SAI objects cause warm boot abort (`6092d504`, `caa7ab29`)
- Code analysis: `m_asicInitViewMode` cleared before `applyView()` returns (`Syncd.cpp:4619`); Stage 2 failure leaves ASIC inconsistent, acknowledged in code comments (`Syncd.cpp:4797–4799`); `executeOperationsOnAsic()` and `updateRedisDatabase()` not atomic — crash between them corrupts next warm boot (`Syncd.cpp:4904–4909`); `processEventInShutdownWaitMode` blanket-rejects all NOTIFY commands including legitimate APPLY_VIEW (`Syncd.cpp:385–389`)

**Affected code paths**:
- `Syncd::applyView()` (`Syncd.cpp:4770–4910`)
- `Syncd::processNotifySyncd()` (`Syncd.cpp:4460–4700`)
- `ComparisonLogic::compareViews()` / `executeOperationsOnAsic()` (`ComparisonLogic.cpp:81–3900`)
- `Syncd::processEventInShutdownWaitMode()` (`Syncd.cpp:366–396`)

**Suggested modeling approach**:
- Variables: `syncdMode ∈ {Normal, InitView, ApplyingView, ShutdownWait}`, `asicState: [ObjId -> Attributes]`, `redisState: [ObjId -> Attributes]`, `asicConsistent: BOOLEAN`
- Actions: `ApplyViewStage1` (comparison, non-destructive, may fail); `ApplyViewStage2` (ASIC ops, destructive, may fail mid-way); `CrashBetweenAsicAndRedis` (crash after ASIC updated but before Redis updated); `ProcessEventInShutdownWait` (blanket FAILURE response)
- Key: Show that Stage 2 failure or crash between Stage 2 and Redis update produces a state where the next warm boot cannot recover correctly

**Priority**: Critical (highest)
**Rationale**: Multiple production bugs. The code itself acknowledges "ASIC will be in inconsistent state" with no recovery. When triggered, requires manual cold reboot. Directly amenable to TLA+ modeling of crash points.

---

### Family 4: Reconciliation Cache State Machine Bugs (MEDIUM)

**Mechanism**: The STALE/SAME/NEW/DELETE cache state machine in AppRestartAssist has edge cases where field subsets are marked SAME (stale data persists), timers fire before all entries are replayed (premature deletion), and entries skipped during restoration are never cleaned up.

**Evidence**:
- Historical: double-update marks SAME incorrectly (commit `cd959723`), vector ordering ignored (`f3d0279a`), ProducerStateTable cleared unconditionally on fast-reboot (`fcb6c9de`)
- Code analysis: `contains()` asymmetry — field removal treated as SAME (`warmRestartAssist.cpp:198,340–352`); reconcile timer starts before netlink dump issued in neighsyncd (`neighsyncd.cpp:62,67`); empty FV entries skipped in `readTablesToMap()` leave keys in AppDB unreconciled (`warmRestartAssist.cpp:145–148`); `assert(RESTORED)` hard-abort in WarmStartHelper (`warmRestartHelper.cpp:157`)

**Affected code paths**:
- `AppRestartAssist::insertToMap()` (`warmRestartAssist.cpp:179–248`)
- `AppRestartAssist::reconcile()` (`warmRestartAssist.cpp:258–306`)
- `AppRestartAssist::contains()` (`warmRestartAssist.cpp:340–352`)
- `WarmStartHelper::reconcile()` (`warmRestartHelper.cpp:152–260`)

**Suggested modeling approach**:
- Variables: `cache[Key -> {STALE, SAME, NEW, DELETE}]`, `appDB[Key -> FieldValues]`, `timerFired: BOOLEAN`
- Actions: `ReplayEntry(key, fv, isDel)` — entry arrives from application; `TimerFire` — reconcile timer fires; `Reconcile` — apply cached diffs to appDB
- Key: Model the 4-state cache with non-deterministic event ordering and timer races to find states where STALE entries are incorrectly deleted or field removals are silently lost

**Priority**: Medium
**Rationale**: 3 historical bugs fixed, but the `contains()` asymmetry remains unfixed. Affects data correctness but typically limited to individual table entries rather than system-wide failures.

---

### Family 5: Shutdown Sequence / Point-of-No-Return Violations (CRITICAL)

**Mechanism**: After Phase 3 (Checkpoint), syncd disconnects from the ASIC and the system must complete warm restart. Failures after this point — syncd init failure, APPLY_VIEW failure, orchagent crash — leave the system in an unrecoverable state requiring manual cold reboot, with no automated fallback.

**Evidence**:
- Historical: 2-stage shutdown support (`11fc2626`), ASIC ops after pre-shutdown (`a732858f`), queue not drained before shutdown (`b4a7160e`), syncd/orchagent deadlock on init failure (`c4e3c142`), no cold fallback after APPLY_VIEW fail (#7072), no unfreeze mechanism (#25224)
- Code analysis: syncd `processEventInShutdownWaitMode` is the recovery attempt but blanket-rejects all operations (`Syncd.cpp:385–389`); switch RID mismatch throws but leaves orphaned SAI object (`Syncd.cpp:5377–5381`); `performWarmRestart()` throws on empty switch list with `FIXME` comment (`Syncd.cpp:5403–5407`)

**Affected code paths**:
- `Syncd::run()` exception handling → `sendShutdownRequestAfterException()` → `processEventInShutdownWaitMode()`
- `Syncd::performWarmRestartSingleSwitch()` RID validation (`Syncd.cpp:5377`)
- `Syncd::onSyncdStart()` (`Syncd.cpp:5050–5109`)

**Suggested modeling approach**:
- Variables: `phase ∈ {Sanity, Freeze, Checkpoint, Reboot, Booting, Reconciling}`, `syncdState ∈ {ColdInit, WarmInit, InitView, Normal, ShutdownWait, Crashed}`, `asicConnected: BOOLEAN`
- Actions: `CheckpointComplete` (point of no return — asicConnected becomes FALSE); `SyncdInitFail` (syncd fails to reconnect to ASIC); `ApplyViewFail` (comparison or ASIC ops fail); `ColdFallback` (should exist but doesn't)
- Key: Show that failures after Checkpoint have no automated recovery — the system gets stuck in ShutdownWait or restart loops

**Priority**: Critical
**Rationale**: This is the most operationally severe bug family. When triggered, the network device is offline until manual cold reboot. The code acknowledges the lack of recovery ("FIXME", TODO comments) but has no fix.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Per-component state machine | Family 1: components reconcile independently with no ordering | State variable per component: {Initialized, Restored, Reconciled, Failed}; transitions driven by timer + message processing |
| Reconciliation ordering constraints | Family 1: Port→LAG→Interface→ARP→Route dependency chain | Dependency predicate: component C can reconcile only if all predecessors are Reconciled |
| Freeze/quiescence handshake | Family 2: TOCTOU between READY and actual freeze | `orchState` with in-flight events; show events can arrive after READY reply |
| 4-phase shutdown sequence | Family 5: point of no return semantics | Phase variable with monotonic progression; failure after Checkpoint has no backward transition |
| APPLY_VIEW two-stage protocol | Family 3: non-transactional ASIC update | Split into Stage1 (non-destructive, may fail safely) and Stage2 (destructive, no rollback); model crash between Stage2 and Redis update |
| Timer-based reconciliation | Family 1, 4: timer fires before entries replayed | Non-deterministic timer fire relative to message delivery; show STALE entries deleted prematurely |
| Failure/timeout at each phase | Family 5: no recovery after checkpoint | Each phase can fail; model what recovery options exist (unfreeze for Phase 2, nothing for Phase 3+) |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Individual SAI object semantics | Too low-level; abstract as opaque state entries in ASIC view |
| Redis pub/sub implementation details | Model as reliable ordered channels; Redis availability is a separate concern |
| BGP/FRR graceful restart internals | Out of scope; model FRR as an abstract "route source" component |
| ComparisonLogic matching algorithm | The comparison logic bugs (#355, #359, #369) are algorithm-level issues better verified by unit tests |
| Ring buffer thread data race | C++ memory model issue, not protocol logic; better verified by ThreadSanitizer |
| Platform-specific SAI behaviors | BRCM vs MLNX differences are vendor implementation details |
| FDB aging/learning disable specifics | Implementation detail; model as a boolean "frozen" flag |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Component state machine | `componentState[C -> State]` | Track per-component lifecycle independently | Family 1 |
| Reconciliation timers | `timer[C -> Nat]`, `timerFired[C -> BOOLEAN]` | Model non-deterministic timer fire vs message delivery | Family 1, 4 |
| Dependency ordering | `depends[C -> SUBSET C]` | Express which components must reconcile before others | Family 1 |
| Freeze handshake | `orchState`, `readyReplySent`, `pendingEvents` | Capture TOCTOU between READY and actual freeze | Family 2 |
| Phase progression | `phase ∈ {Sanity, Freeze, Checkpoint, Reboot, Boot, Reconcile}` | Model 4-phase shutdown with point-of-no-return | Family 5 |
| APPLY_VIEW stages | `applyStage ∈ {None, Comparing, Applying, Done}`, `asicConsistent` | Model two-stage apply with crash/failure points | Family 3 |
| Cache state machine | `cache[Key -> {STALE, SAME, NEW, DELETE}]` | Verify reconciliation cache correctness | Family 4 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| OrderedReconciliation | Safety | If component B depends on A, B does not reconcile before A | Family 1 |
| NoStaleDelete | Safety | A key in AppDB is not deleted if its replayed value has not yet arrived | Family 1, 4 |
| QuiescentBeforeCheckpoint | Safety | All components must be in Quiescent state before Checkpoint phase begins | Family 2 |
| FreezeImpliesNoEvents | Safety | No new events are processed after orchagent sends READY reply | Family 2 |
| ApplyViewAtomicity | Safety | If APPLY_VIEW Stage 2 starts, either all operations succeed or the system transitions to a defined error state | Family 3 |
| AsicRedisConsistency | Safety | After APPLY_VIEW completes, asicState and redisState are consistent | Family 3 |
| PointOfNoReturnRecovery | Liveness | If failure occurs after Checkpoint, the system eventually reaches either Reconciled or ColdReboot (not stuck) | Family 5 |
| ReconcileTermination | Liveness | Every component eventually reaches Reconciled or Failed within its timer bound | Family 1 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | neighsyncd (5s timer) reconciles and deletes ARP entry; fpmsyncd (120s timer) later installs route using that ARP entry as nexthop | OrderedReconciliation, NoStaleDelete | 1 |
| MC-2 | orchagent APPLY_VIEW commits before fdbsyncd 120s reconcile; VXLAN FDB entries stale in hardware | OrderedReconciliation | 1 |
| MC-3 | READY reply sent but ring buffer not drained; new event changes state after READY declared | FreezeImpliesNoEvents | 2 |
| MC-4 | APPLY_VIEW Stage 2 fails mid-way; ASIC partially updated, Redis never updated; next warm boot sees stale Redis | AsicRedisConsistency | 3 |
| MC-5 | syncd init fails after Checkpoint; enters ShutdownWait; orchagent INIT_VIEW rejected with FAILURE; system stuck | PointOfNoReturnRecovery | 5 |
| MC-6 | Reconcile timer fires before netlink dump delivers all entries; STALE entries prematurely deleted | NoStaleDelete | 4 |
| MC-7 | vxlanmgrd declares RECONCILED after 1s; fdbsyncd starts reconciling before VXLAN tunnels restored | OrderedReconciliation | 1 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | 3-iteration restore loop insufficient for deep dependency chains (VRF→Interface→Neighbor→Route) | Create topology with 4-deep dependency chain; verify warm restore fails with pending tasks |
| TV-2 | `setBridgePortLearningFDB` SAI error on one port leaves asymmetric FDB learning | Inject SAI failure on specific port; verify FDB learning still active on unfrozen ports |
| TV-3 | `warmRestoreValidation()` sets RESTORED even when pending tasks exist | Verify STATE_DB shows RESTORED when warmRestoreAndSyncUp returns false |
| TV-4 | WarmStartHelper::reconcile() assert fires if state != RESTORED | Call reconcile() without prior runRestoration(); verify abort |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | `contains()` asymmetry allows field removal to be silently ignored | Replace with symmetric comparison (both directions) |
| CR-2 | `m_createdInInitView` not cleared on APPLY_VIEW Stage 1 failure | Add clear() to the failure path at `Syncd.cpp:4666` |
| CR-3 | RESTORED state written before `syncd_apply_view()` — ordering inversion for external observers | Move RESTORED write to after `syncd_apply_view()` succeeds |
| CR-4 | portsorch `bake()` return value ignored in warmRestoreAndSyncUp | Check return values and abort on portsorch bake failure |
| CR-5 | neighsyncd `exit(EXIT_FAILURE)` on timeout with no WarmStart FAILED state update | Add `setWarmStartState(FAILED)` before exit |

## 7. Reference Pointers

- **Full analysis report**: `.specula-output/analysis-report.md`
- **Key source files**:
  - `artifact/sonic-swss/orchagent/orchdaemon.cpp` (lines 853–1245: warm restart core)
  - `artifact/sonic-swss/warmrestart/warmRestartAssist.cpp` (353 lines: reconciliation cache)
  - `artifact/sonic-swss/warmrestart/warmRestartHelper.cpp` (378 lines: reconciliation helper)
  - `artifact/sonic-sairedis/syncd/Syncd.cpp` (lines 4490–5420: INIT_VIEW/APPLY_VIEW/warm restart)
  - `artifact/sonic-sairedis/syncd/ComparisonLogic.cpp` (3917 lines: view comparison)
- **Design documents**:
  - `invariants/SONiC_Warmboot.md` — Overall warm boot design (2 reconciliation proposals)
  - `invariants/Warmboot_Manager_HLD.md` — 4-phase shutdown orchestration (Google, 2023)
- **GitHub issues**: sonic-swss #827, sonic-buildimage #7072, #15076, #25224, #12257; sonic-sairedis #355, #639
- **GitHub repos**: sonic-net/sonic-swss, sonic-net/sonic-sairedis, sonic-net/sonic-buildimage
