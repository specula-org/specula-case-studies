# Analysis Report: SONiC Warm Reboot Orchestration

## Coverage Statistics

| Metric | Count |
|--------|-------|
| Git bug-fix commits analyzed (sonic-swss) | 22 |
| Git bug-fix commits analyzed (sonic-sairedis) | 28 |
| GitHub issues deeply read (sonic-swss) | 20 |
| GitHub issues deeply read (sonic-buildimage) | 18 |
| GitHub issues deeply read (sonic-sairedis) | 8 |
| Total issues collected | 66+ |
| Total issues deeply read (full comments) | 46 |
| Confirmed bugs | 38 |
| Design defects | 6 |
| False positives excluded | 3 |
| Core files read in full | 8 |
| Deep analysis subagents | 4 (parallel) |
| New findings from deep analysis | 21 |
| Bug families identified | 5 |

## System Classification

**Category A (Distributed / Message-Passing)**: SONiC warm reboot is a multi-component coordination protocol where 6+ processes (orchagent, syncd, neighsyncd, fdbsyncd, teamd, xcvrd) communicate via Redis state tables. The main risks are protocol logic errors in the 4-phase shutdown sequence, ordering violations during independent reconciliation, and crash windows during the non-transactional APPLY_VIEW stage.

---

## Phase 1: Reconnaissance Summary

### Architecture
- **Warmboot Manager** (HLD, not yet fully implemented): 4-phase orchestrator — Sanity → Freeze/Quiescence → Checkpoint → Reboot
- **orchagent** (`orchdaemon.cpp`): Main event loop, manages 30+ Orch sub-modules; warm restart via `warmRestoreAndSyncUp()` (3-iteration doTask loop) + `warmRestartCheck()`/freeze
- **syncd** (`Syncd.cpp`): INIT_VIEW/APPLY_VIEW lifecycle; ComparisonLogic for pre/post-reboot state delta; two-stage destructive apply
- **warmRestartAssist** / **warmRestartHelper**: Per-component reconciliation caching with STALE/SAME/NEW/DELETE state machine
- **neighsyncd/fdbsyncd**: Timer-based reconciliation (5s/120s defaults) with netlink dump restore

### Concurrency Model
- orchagent: Single main event loop + ring buffer consumer thread (non-atomic head/tail)
- syncd: Main event loop + notification processor thread + flex counter thread; protected by `m_mutex`
- Cross-component: Asynchronous via Redis STATE_DB polling; no RPC or direct message passing

### Key Warm Restart Protocol Flow
```
SHUTDOWN PATH:
  1. warm-reboot script → orchagent_restart_check → "RESTARTCHECK" notification
  2. orchagent: warmRestartCheck() → drain pending tasks → reply READY/NOT_READY
  3. orchagent: disable FDB aging → disable FDB learning → flush pipeline → freeze (sleep forever)
  4. syncd: pre-shutdown SAI → save state → disconnect from ASIC → exit
  5. System reboot (kexec)

RESTORE PATH:
  1. syncd starts: performStartupLogic() → warm boot file check → performWarmRestart() (create switch with warm flag)
  2. orchagent starts: INIT_VIEW notification to syncd → syncd enters init view mode
  3. orchagent: warmRestoreAndSyncUp() → bake() all orchs → 3x doTask() iterations → warmRestoreValidation()
  4. orchagent: syncd_apply_view() → syncd: applyView() (Stage 1: compare, Stage 2: ASIC ops) → update Redis
  5. orchagent: RECONCILED
  6. neighsyncd/fdbsyncd: independently reconcile via timers (5s–120s)
```

---

## Phase 2: Bug Archaeology — Detailed Findings

### sonic-swss Git History (22 bug-fix commits)

| # | Hash | Subject | Component | Severity | Family |
|---|------|---------|-----------|----------|--------|
| 1 | `af56a611` | fpmsyncd crash: C++ init order, warmStartHelper holds dangling pointer | fpmsyncd | Critical | 4 |
| 2 | `48a0bc67` | MuxCable wrong initial state (standby) during warm reboot → crash | orchagent/muxorch | Critical | 1 |
| 3 | `ddb9a5ef` | Race: nexthop created after port goes down, missing NHFLAGS_IFDOWN | orchagent/neighorch | Critical | 2 |
| 4 | `05b2f55b` | FDB entry race: learned before bridge port removed → crash | orchagent/portsorch | Critical | 2 |
| 5 | `5796e544` | Warm restore needs 3 iterations — inter-orch dependency chain | orchagent/orchdaemon | High | 1 |
| 6 | `4a174f4f` | VNET orch ordered before VRF/VxLAN orch → routes fail | orchagent/orchdaemon | High | 1 |
| 7 | `721f47d9` | FdbSyncd/FpmSyncd replay before interfaces restored | fdbsyncd/fpmsyncd | High | 1 |
| 8 | `3da2e676` | DualToR: neighbor updates before mux state settled | orchagent/muxorch | High | 1 |
| 9 | `755b2607` | Data race: exit() destructs globals while main thread uses them | orchagent/notifications | High | 2 |
| 10 | `5575935e` | Neighbor syncd restore timeout too short → exit | neighsyncd | High | 4 |
| 11 | `7dd3be98` | Blackhole routes incorrectly removed during warm reboot | fpmsyncd | High | 1 |
| 12 | `cd959723` | ARP cache: double-update marks entry SAME incorrectly | warmrestart | High | 4 |
| 13 | `7d16f69f` | FDB warmboot: ALLOW_MAC_MOVE set on all dynamic entries | orchagent/fdborch | High | 4 |
| 14 | `fcb6c9de` | NEIGH_TABLE cleared after fast-reboot (no warm-start guard) | warmrestart | High | 4 |
| 15 | `94fbcd96` | FDB aging not disabled before freeze | orchagent | High | 2 |
| 16 | `bbbd5f44` | SAI_FDB_EVENT_FLUSHED not handled → stale FDB | orchagent/fdborch | High | 4 |
| 17 | `bab7b933` | allPortsReady() returns true prematurely → BufferOrch error | orchagent/portsorch | High | 1 |
| 18 | `a8a28a84` | FlexCounter runs before APPLY_VIEW | orchagent/flexcounterorch | Medium | 1 |
| 19 | `f3d0279a` | WarmRestartAssist: vector comparison ignores reordering | warmrestart | Medium | 4 |
| 20 | `fb0a5fd8` | Buffer pool watermark during reconciliation → SAI errors | orchagent/flexcounterorch | Medium | 1 |
| 21 | `bad21415` | INIT_VIEW timeout not extended for Marvell-Prestera | orchagent/saihelper | Medium | 5 |
| 22 | `2b02c249` | Frozen orchagent doesn't heartbeat → false alert | orchagent/orchdaemon | Medium | 2 |

### sonic-sairedis Git History (28 bug-fix commits)

| # | Hash | Subject | Component | Severity | Family |
|---|------|---------|-----------|----------|--------|
| 1 | `14a863a6` | INIT_VIEW failure: hardware info string mismatch | syncd | Critical | 3 |
| 2 | `88ffbf19` | Second INIT_VIEW creates duplicate switch | syncd | Critical | 3 |
| 3 | `85a579b3` | Optimized remove breaks reference integrity | ComparisonLogic | Critical | 3 |
| 4 | `d5a9128a` | Cross-version warm upgrade: TTL_MODE not implemented → crash | ComparisonLogic | Critical | 3 |
| 5 | `caa7ab29` | New SAI internal OID removal on warm boot upgrade | SaiSwitch | Critical | 3 |
| 6 | `11fc2626` | Add 2-stage shutdown (pre-shutdown) support | syncd | Critical | 5 |
| 7 | `a6b709a8` | Re-establish notifications after warm boot | syncd | Critical | 5 |
| 8 | `9c026a67` | Fix passing switch pointers during warm boot | syncd | Critical | 5 |
| 9 | `c4e3c142` | Fix deadlock between syncd and orchagent on init failure | syncd | Critical | 5 |
| 10 | `c00b6ede` | Race condition cold boot vs notifications | syncd | High | 5 |
| 11 | `4b2638ca` | Comparison logic: new transferred objects duplicated | ComparisonLogic | High | 3 |
| 12 | `3026945b` | Add break-before-make mechanism | ComparisonLogic | High | 3 |
| 13 | `7817c3b1` | Fast-reboot detection via /proc/cmdline persists | syncd | High | 5 |
| 14 | `a732858f` | Process only shutdown requests after pre-shutdown | syncd | High | 5 |
| 15 | `31fd65ea` | Fix pre-shutdown select dangling pointer | syncd | High | 5 |
| 16 | `b4a7160e` | Drain ASIC queue before processing shutdown | syncd | High | 5 |
| 17 | `f50dba7c` | Cold VID table per-switch access | RedisClient | High | 3 |
| 18 | `6092d504` | Workaround for warm boot new objects | SaiSwitch | High | 3 |
| 19 | `edbceb9a` | Keep new warm boot discovered SERDES objects | ComparisonLogic | High | 3 |
| 20 | `26a8a120` | Prevent notification event storms | NotificationQueue | High | 5 |
| 21 | `56456984` | FLUSHALL after config write → 10-min reboot | syncd_init | Critical | 5 |
| 22 | `ebd8dfc0` | Stop notifications thread after remove switch | syncd | Medium | 5 |
| 23 | `1885a8c4` | sendShutdownRequest null pointer check | syncd | Medium | 5 |
| 24 | `8d0f5ebf` | SAI failure dump handling above non-temp-view check | syncd | Medium | 3 |
| 25 | `b664f081` | logSet/logGet race condition | VendorSai | Medium | — |
| 26 | `2f2698c9` | RIF counters race condition | FlexCounter | Medium | — |

### GitHub Issues Summary

**sonic-swss** (20 issues read): Key confirmed bugs: #827 (freeze timeout race), #2884 (dual-ToR warm boot crash), #1432 (LAG MTU lost), #888 (LAG MTU deleted), #1270 (VLAN interfaces lost), #2217 (COPP always deleted/recreated), #1657 (missing EVPN EOIU). Open PR #2471 (permanent freeze on double warm-reboot).

**sonic-buildimage** (18 issues read): Key confirmed bugs: #15076 (Redis unavailable race), #7072 (APPLY_VIEW fail → infinite loop), #9898 (RIF counter crash), #10605 (FDB flush blocks restart check), #25224 (no unfreeze), #11416 (db_migrator race), #22560 (VXLAN check regression), #12257 (neighbor_advertiser vs freeze race), #3008 (Redis Lua 36s lock).

**sonic-sairedis** (8 issues read): Key confirmed bugs: #1429 (dummy object removal on second warm boot), #1030 (duplicate buffer profiles from GET snooping), #639 (FLUSHDB on restart_syncd), #355/#359/#369 (comparison logic gaps for NHG/ACL/policer).

---

## Phase 3: Deep Analysis — New Findings

### orchdaemon.cpp Warm Restart Logic

| ID | Location | Description | Classification |
|----|----------|-------------|----------------|
| WR-01 | `orchdaemon.cpp:1168` | RESTORED written even when warmRestoreValidation fails (pending tasks exist) | Code-review-only |
| WR-02 | `orchdaemon.cpp:1114–1123` | No rollback path after syncd_apply_view + onWarmBootEnd failure | Code-review-only |
| WR-03 | `orchdaemon.cpp:1012–1051` | TOCTOU: READY reply sent before ring buffer fully drained | Model-checkable |
| WR-04 | `orch.h:196–228` | RingBuffer head/tail/idle_status accessed without atomics — data race | Code-review-only |
| WR-06 | `orchdaemon.cpp:1085–1098` | 3-iteration restore loop has no convergence guarantee for deep dependency chains | Test-verifiable |
| WR-08 | `orchdaemon.cpp:1114–1134` | RESTORED state written before syncd_apply_view — observer ordering inversion | Model-checkable |
| WR-10 | `orchdaemon.cpp:1035–1041` | setBridgePortLearningFDB return value unchecked — partial FDB disable | Test-verifiable |
| WR-11 | `orchdaemon.cpp:999–1051` | warmRestartCheck not atomic with ring thread m_toSync population | Model-checkable |

### syncd Warm Boot Logic

| ID | Location | Description | Classification |
|----|----------|-------------|----------------|
| A1 | `Syncd.cpp:4619` | m_asicInitViewMode cleared before applyView returns; failure leaves syncd in inconsistent mode | Model-checkable |
| B1 | `Syncd.cpp:4904–4909` | Stage-2 ASIC operation failure leaves ASIC inconsistent, acknowledged in comments | Code-review-only |
| B2 | `Syncd.cpp:4906–4909` | executeOperationsOnAsic and updateRedisDatabase not atomic; crash between corrupts warm boot | Model-checkable |
| C1 | `Syncd.cpp:385–389` | processEventInShutdownWaitMode blanket-rejects all NOTIFY including APPLY_VIEW | Model-checkable |
| E1 | `Syncd.cpp:4662` | clearLocalCache after APPLY_VIEW races with queued pre-APPLY_VIEW notifications | Model-checkable |

### Reconciliation Cache

| ID | Location | Description | Classification |
|----|----------|-------------|----------------|
| A1/E1 | `warmRestartAssist.cpp:198,340–352` | contains() asymmetry — field removal treated as SAME | Code-review-only |
| A4/C1 | `neighsyncd.cpp:62,67` | Reconcile timer starts before netlink dump issued — STALE entries deleted prematurely | Model-checkable |
| B1 | `warmRestartHelper.cpp:157` | assert(RESTORED) hard-abort; m_state uninitialized if checkAndStart() skipped | Model-checkable |
| B3 | `warmRestartHelper.cpp:229–248` | DEL-then-SET out-of-order: SET survives despite net delete intent | Model-checkable |
| D1 | cross-component | Independent timers enable cross-component ordering violations (neighbor deleted before route) | Model-checkable |

### Per-Component State Transitions

| ID | Location | Description | Classification |
|----|----------|-------------|----------------|
| PC-1 | `orchdaemon.cpp:1132–1134` | RECONCILED admitted not to guarantee neighbor state | Code-review-only |
| PC-2 | `portsorch.cpp:4358–4374` | bake() return value ignored; cleanPortTable deletes all APP_PORT_TABLE on fallback | Code-review-only |
| PC-3 | `fdborch.cpp:70–84` | orchagent APPLY_VIEW commits before fdbsyncd 120s reconcile | Model-checkable |
| PC-4 | `neighorch.cpp`, `routeorch.cpp` | Zero warm restart awareness — no bake override, no dependency gating | Code-review-only |
| PC-5 | `vlanmgr.cpp:59–62`, `vxlanmgrd.cpp:99–108`, `vrfmgrd.cpp:71–78` | RECONCILED declared prematurely (1s timeout, no content verification) | Model-checkable |
| PC-6 | `neighsyncd.cpp:54–58` | exit(EXIT_FAILURE) on timeout with no FAILED state update | Code-review-only |

---

## Developer Signals (TODO/FIXME/HACK in Core Files)

| File | Line | Signal |
|------|------|--------|
| `orchdaemon.cpp` | 1161 | `TODO: Update this section accordingly once pre-warmStart consistency validation is ready` |
| `Syncd.cpp` | 4654 | `TODO possible race condition - get notification when new view is applied and cache have old values` |
| `Syncd.cpp` | 4797–4799 | `if there will be bug in comparison logic or any asic operation will fail, then syncd will crash, since asic will be in inconsistent state` |
| `Syncd.cpp` | 5026 | `TODO check if those 2 maps are consistent` |
| `Syncd.cpp` | 5061 | `this may cause race condition` (port notification during startup) |
| `Syncd.cpp` | 5407 | `not supported yet, FIXME` (empty switch list on warm restart) |
| `ComparisonLogic.cpp` | 573 | `FIXME` — reference count errors throw rather than recover |
| `ComparisonLogic.cpp` | 677 | `FIXME` — VID not found in temporary view |
| `ComparisonLogic.cpp` | 2466 | `TODO: there could be potential issue here` — new discovered object removal in init view |
| `ComparisonLogic.cpp` | 3108, 3218 | `XXX this is workaround. FIXME` — root-object ordering |
| `ComparisonLogic.cpp` | 3422–3883 | Multiple `ASIC will be in inconsistent state` with `SWSS_LOG_THROW` — no rollback |

---

## Bug Hotspot Analysis

Files with the most warm-restart bug-fix commits:

| File | Bug-Fix Commits | Severity Profile |
|------|----------------|-----------------|
| `syncd/Syncd.cpp` | 15+ | 6 Critical, 5 High |
| `orchagent/orchdaemon.cpp` | 8+ | 2 Critical, 4 High |
| `syncd/ComparisonLogic.cpp` | 5+ | 2 Critical, 2 High |
| `warmrestart/warmRestartAssist.cpp` | 4 | 3 High |
| `orchagent/fdborch.cpp` | 3 | 2 High |
| `orchagent/portsorch.cpp` | 3 | 1 Critical, 2 High |
| `neighsyncd/neighsyncd.cpp` | 3 | 2 High |
| `fpmsyncd/routesync.cpp` | 2 | 1 Critical, 1 High |

---

## False Positives Excluded

| Issue | Reason for Exclusion |
|-------|---------------------|
| swss #596 | Test infrastructure issue (VS vEthernet stale neighbors), not production |
| swss #703 | Kernel I2C oops after ONIE reinstall, not warm reboot specific |
| swss #2913 | MCLAG crash on interface unplug, warm reboot not specifically involved |
