# Bug Report — SONiC Warm Reboot

## Summary

- Bug families tested: 5
- Bugs found: 5
- Configs run: MC_hunt_family1.cfg, MC_hunt_family2.cfg, MC_hunt_family3.cfg, MC_hunt_family4.cfg, MC_hunt_family5.cfg

---

## Bug 1: Reconciliation Ordering Violation

- **Bug Family**: Family 1 — Reconciliation Ordering Violations
- **Severity**: High
- **Invariant violated**: OrderedReconciliation
- **Config**: MC_hunt_family1.cfg
- **Counterexample**: 30 states, output file `spec/output/hunt_family1_sim.out`

### Trace Summary

1. Normal warm reboot shutdown (freeze, quiesce, checkpoint, reboot) completes successfully
2. After reboot, vxlanmgrd reads its pre-reboot table and immediately declares RECONCILED via `ReconcileComponentWithoutTimer` (models vxlanmgrd's 1s SELECT_TIMEOUT behavior)
3. At this point, fdbsyncd (which depends on vxlanmgrd) has only just started its reconcile timer and hasn't begun reconciliation
4. **Violation**: vxlanmgrd is CReconciled while its dependent fdbsyncd is still CInitialized — the dependency ordering (vxlanmgrd must reconcile AFTER fdbsyncd's dependencies are met) is violated

### Root Cause

Components reconcile independently on their own timers with no global ordering barrier. vxlanmgrd declares RECONCILED on the first 1s SELECT_TIMEOUT with no content verification. fdbsyncd then starts reconciling before VXLAN tunnels are actually restored, potentially committing stale FDB entries.

### Affected Code

- `orchdaemon.cpp:1132`: No ordering barrier between component reconciliations
- vxlanmgrd main loop: Declares RECONCILED on first SELECT_TIMEOUT without verification
- `fdbsync.cpp:54-69`: `isIntfRestoreDone()` checks interface state but not VXLAN tunnel state

### Recommendation

Add dependency-aware reconciliation gating: a component should not begin reconciliation until all its prerequisite components have completed. This could be implemented via STATE_DB polling or a Warmboot Manager coordination phase.

---

## Bug 2: Freeze/Quiescence TOCTOU Race

- **Bug Family**: Family 2 — Freeze/Quiescence Protocol Violations
- **Severity**: High
- **Invariant violated**: FreezeImpliesNoEvents
- **Config**: MC_hunt_family2.cfg
- **Counterexample**: 13 states, output file `spec/output/hunt_family2_sim.out`

### Trace Summary

1. During freeze phase, orchagent checks readiness (`OrchCheckReady`)
2. Orchagent sends READY reply (`OrchSendReadyReply`) — externally declares quiescent
3. **Before the ring buffer is drained and orchagent actually freezes**, a new event arrives (`EventArrivalAfterReady`) — `pendingEvents` goes from 0 to 1
4. **Violation**: `readyReplySent = TRUE` but `pendingEvents = 1` — orchagent claimed quiescent while events remain unprocessed

### Root Cause

TOCTOU between READY reply (orchdaemon.cpp:1207) and actual ring buffer drain (orchdaemon.cpp:1019-1026). The READY reply is sent before the ring buffer is empty. Events arriving in this window are unsaved state that will be lost on checkpoint, potentially causing post-reboot inconsistency.

### Affected Code

- `orchdaemon.cpp:1207`: `gSwitchOrch->restartCheckReply("READY")` sent before drain
- `orchdaemon.cpp:1019-1026`: Ring buffer drain loop runs AFTER READY reply
- `orch.h:196-228`: Ring buffer head/tail accessed without atomics

### Recommendation

Move the READY reply to AFTER the ring buffer drain and freeze complete, or use an atomic flag that prevents new events from entering the ring buffer once READY is declared.

---

## Bug 3: APPLY_VIEW Non-Atomic ASIC/Redis Update

- **Bug Family**: Family 3 — APPLY_VIEW Non-Transactional Failure
- **Severity**: Critical
- **Invariant violated**: AsicRedisConsistency
- **Config**: MC_hunt_family3.cfg
- **Counterexample**: 40 states, output file `spec/output/hunt_family3_sim.out`

### Trace Summary

1. Normal warm reboot completes through checkpoint and reboot
2. After reboot, orchagent sends INIT_VIEW/APPLY_VIEW to syncd
3. Syncd performs Stage 1 (non-destructive comparison) successfully
4. Syncd begins Stage 2 (destructive ASIC operations)
5. `CrashBetweenAsicAndRedis`: Crash occurs after `executeOperationsOnAsic()` succeeds but before `updateRedisDatabase()` completes
6. **Violation**: `asicConsistent = TRUE` (ASIC was fully updated) but `redisUpdated = FALSE` (Redis still has pre-reboot state) — next warm boot will see stale Redis state

### Root Cause

`executeOperationsOnAsic()` and `updateRedisDatabase()` in `Syncd::applyView()` are not atomic. A crash (power loss, kill -9, exception) between these two calls leaves the ASIC in the new state but Redis in the old state. The next warm boot will use stale Redis state for comparison, producing incorrect diffs.

### Affected Code

- `Syncd.cpp:4904-4907`: `executeOperationsOnAsic()` — destructive, no rollback
- `Syncd.cpp:4909`: `updateRedisDatabase()` — separate operation, not transactional
- `Syncd.cpp:4797-4799`: Code comment acknowledges "ASIC will be in inconsistent state"

### Recommendation

Either: (a) write a WAL/intent log before ASIC operations so Redis can be recovered on next boot, or (b) update Redis incrementally as each ASIC operation succeeds, or (c) accept the risk and add a cold-restart fallback that detects ASIC/Redis divergence.

---

## Bug 4: Premature Timer-Based Stale Entry Deletion

- **Bug Family**: Family 4 — Reconciliation Cache State Machine Bugs
- **Severity**: Medium
- **Invariant violated**: NoStaleDelete
- **Config**: MC_hunt_family4.cfg
- **Counterexample**: 36 states, output file `spec/output/hunt_family4_sim.out`

### Trace Summary

1. After reboot, vxlanmgrd starts its reconcile timer and reads the pre-reboot table (all entries STALE)
2. vxlanmgrd replays entry k1 (transitions from STALE to SAME/NEW/DELETE)
3. Timer ticks down and fires BEFORE all entries have been replayed
4. **Violation**: `timerFired[vxlanmgrd] = TRUE` and `cache[vxlanmgrd][k1] = CacheSTALE` — the timer fired while k1 is still STALE (unreplayed), meaning the next reconcile will DELETE this entry even though its replay hasn't arrived yet

### Root Cause

The reconcile timer starts BEFORE the netlink dump (or equivalent data source) delivers all entries. In neighsyncd, the timer starts at line 62 but the netlink dump is issued at line 67. If the timer fires before all entries arrive, STALE entries are incorrectly deleted from AppDB — they're treated as "removed" when they're actually "not yet replayed."

### Affected Code

- `neighsyncd.cpp:62`: Timer start
- `neighsyncd.cpp:67`: Netlink dump (entries arrive AFTER timer starts)
- `warmRestartAssist.cpp:277-283`: STALE entries deleted during reconcile

### Recommendation

Start the reconcile timer AFTER the initial data dump completes (i.e., after `readTablesToMap()` and the data source has delivered all entries), not before.

---

## Bug 5: No Recovery After Point-of-No-Return Failure

- **Bug Family**: Family 5 — Shutdown Sequence / Point-of-No-Return Violations
- **Severity**: Critical
- **Invariant violated**: NoStuckAfterPointOfNoReturn
- **Config**: MC_hunt_family5.cfg
- **Counterexample**: 46 states, output file `spec/output/hunt_family5_sim.out`

### Trace Summary

1. During shutdown, teamd fails (ComponentFailDuringShutdown) but the system proceeds past checkpoint (point of no return)
2. System reboots. Syncd reconnects to ASIC and receives INIT_VIEW from orchagent
3. Orchagent sends APPLY_VIEW. Syncd completes Stage 1 (comparison)
4. During Stage 2 (destructive ASIC operations), `ApplyViewStage2Fail` occurs — ASIC is partially updated
5. Syncd enters `SyncdShutdownWait` mode with `pointOfNoReturn = TRUE`
6. **Violation**: `pointOfNoReturn = TRUE` and `syncdMode = SyncdShutdownWait` — the system is stuck with no automated recovery. `processEventInShutdownWaitMode` blanket-rejects all NOTIFY commands including legitimate recovery attempts.

### Root Cause

After Phase 3 (Checkpoint), syncd disconnects from the ASIC and the system MUST complete warm restart. If APPLY_VIEW Stage 2 fails, syncd enters ShutdownWait mode which blanket-rejects all operations (Syncd.cpp:385-389). There is no automated cold-restart fallback — the device remains offline until manual intervention.

### Affected Code

- `Syncd.cpp:385-389`: `processEventInShutdownWaitMode` blanket FAILURE response
- `Syncd.cpp:4797-4799`: Acknowledges "ASIC will be in inconsistent state"
- `Syncd.cpp:5377-5381`: RID mismatch throws with no recovery
- `Syncd.cpp:5403-5407`: Empty switch list throws with FIXME comment

### Recommendation

Add an automated cold-restart fallback: when syncd enters ShutdownWait after point-of-no-return, it should trigger a full cold reboot rather than staying stuck. This requires platform-level support (watchdog timer, health monitor).

---

## Not Reproduced

All 5 bug families were successfully reproduced. No untested families.

| Bug Family | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| Family 1: Reconciliation Ordering | MC_hunt_family1.cfg | 1,492 | OrderedReconciliation violated |
| Family 2: Freeze/Quiescence TOCTOU | MC_hunt_family2.cfg | 680 | FreezeImpliesNoEvents violated |
| Family 3: APPLY_VIEW Non-Transactional | MC_hunt_family3.cfg | 1,949 | AsicRedisConsistency violated |
| Family 4: Cache State Machine | MC_hunt_family4.cfg | 2,219 | NoStaleDelete violated |
| Family 5: Point-of-No-Return | MC_hunt_family5.cfg | 1,826 | NoStuckAfterPointOfNoReturn violated |
