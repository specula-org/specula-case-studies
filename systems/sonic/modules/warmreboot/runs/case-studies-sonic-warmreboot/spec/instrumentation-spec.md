# Instrumentation Spec: SONiC Warm Reboot

Maps TLA+ spec actions to source code locations for trace generation.

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "tag": "trace",
  "timestamp": "<ISO8601>",
  "event": {
    "name": "<action_name>",
    "component": "<component_id>",
    "state": {
      "phase": "<Phase>",
      "componentState": "<ComponentState>",
      "orchState": "<OrchState>",
      "syncdMode": "<SyncdMode>",
      "pendingEvents": <int>,
      "readyReplySent": <bool>,
      "pointOfNoReturn": <bool>,
      "asicConnected": <bool>,
      "asicConsistent": <bool>,
      "redisUpdated": <bool>
    },
    "detail": {
      "key": "<abstract_key>",
      "cacheState": "<CacheState>"
    }
  }
}
```

### State Fields

| Implementation Field | TLA+ Variable | Access Method | Notes |
|---------------------|---------------|---------------|-------|
| Warmboot Manager phase | `phase` | Read from WM orchestration state | PhaseRunning/Sanity/Freeze/Checkpoint/Reboot/Booting/Reconciling |
| STATE_DB warm restart state | `componentState` | `WarmStart::getWarmStartState()` | Per-component: Running/Frozen/Quiescent/Checkpointed/Initialized/Restored/Reconciled/Failed |
| orchagent internal state | `orchInternalState` | Infer from orchdaemon.cpp control flow | Running/CheckingReady/ReadyReplied/Draining/Frozen/Restoring/WaitApplyView/Reconciling |
| `m_ringBuffer` status | `pendingEvents` | Ring buffer `size()` or `head - tail` | Count of unprocessed ring buffer entries |
| READY reply flag | `readyReplySent` | Set after `restartCheckReply("READY")` | Boolean |
| Phase 3 complete | `pointOfNoReturn` | Set when phase transitions to Checkpoint | Boolean |
| `m_asicInitViewMode` | `syncdMode` | `Syncd::m_asicInitViewMode` + control flow | Normal/InitView/ApplyStage1/ApplyStage2/Done/ShutdownWait/Crashed |
| SAI connection state | `asicConnected` | `Syncd::m_vendorSai` != nullptr | Boolean |
| ASIC consistency | `asicConsistent` | Inferred from exception handling in applyView() | Boolean: false after Stage 2 partial failure |
| Redis update state | `redisUpdated` | Set after `updateRedisDatabase()` returns | Boolean |
| Cache entry state | `cache[c][k]` | `AppRestartAssist::m_appTableCacheMap` entry state | Empty/STALE/SAME/NEW/DELETE |

### Component ID Mapping

| Implementation Component | TLA+ Component ID | Process/Binary |
|-------------------------|-------------------|----------------|
| orchagent | `"orchagent"` | `orchagent` binary in swss container |
| syncd | `"syncd"` | `syncd` binary in syncd container |
| neighsyncd | `"neighsyncd"` | `neighsyncd` binary in swss container |
| fdbsyncd | `"fdbsyncd"` | `fdbsyncd` binary in swss container |
| teamd | `"teamd"` | `teamd` or `teamsyncd` in teamd container |
| vxlanmgrd | `"vxlanmgrd"` | `vxlanmgrd` binary in swss container |

## Section 2: Action-to-Code Mapping

### 1. StartWarmReboot

- **Spec action**: `StartWarmReboot`
- **Code location**: `sonic-buildimage: scripts/warm-reboot` (entry point) or Warmboot Manager init
- **Trigger point**: After warm-reboot command issued, before sanity checks
- **Trace event name**: `"StartWarmReboot"`
- **Fields**: State snapshot (phase)
- **Notes**: This is the warm reboot entry point. The Warmboot Manager (Python) orchestrates from here. In the shell script, this is after argument parsing.

### 2. CompleteSanityChecks

- **Spec action**: `CompleteSanityChecks`
- **Code location**: `sonic-buildimage: Warmboot Manager Phase 1 completion`
- **Trigger point**: After all sanity checks pass (filesystem, DB, image verification)
- **Trace event name**: `"CompleteSanityChecks"`
- **Fields**: State snapshot (phase)
- **Notes**: Failure here aborts warm reboot entirely. No state changes committed yet.

### 3. ComponentReceiveFreeze

- **Spec action**: `ComponentReceiveFreeze(c)`
- **Code location**:
  - orchagent: `orchdaemon.cpp:1012` — `checkRestartReady()` check in main loop
  - syncd: `Syncd.cpp` — pre-shutdown notification handler
  - neighsyncd: `neighsyncd.cpp` — warm restart flag check
  - teamd: teamd container — LACP PDU processing stop
- **Trigger point**: After component receives freeze notification from Warmboot Manager
- **Trace event name**: `"ComponentReceiveFreeze"`
- **Fields**: State snapshot (componentState for this component)
- **Notes**: Components stop generating new self-sourced intents. Each component has different freeze behavior. Orchagent stops periodic timers. Syncd stops listening to port link events.

### 4. ComponentQuiesce

- **Spec action**: `ComponentQuiesce(c)`
- **Code location**:
  - orchagent: `orchdaemon.cpp:1019-1026` — ring buffer drain
  - syncd: Syncd pre-shutdown drain
  - others: application-specific queue drain
- **Trigger point**: After component finishes draining pending work
- **Trace event name**: `"ComponentQuiesce"`
- **Fields**: State snapshot (componentState for this component)
- **Notes**: Component reports quiescent to Warmboot Manager via STATE_DB. May transition back to Frozen if receiving new requests.

### 5. OrchCheckReady

- **Spec action**: `OrchCheckReady`
- **Code location**: `orchdaemon.cpp:1178-1209` — `warmRestartCheck()`
- **Trigger point**: After entering warmRestartCheck(), before reply
- **Trace event name**: `"OrchCheckReady"`
- **Fields**: State snapshot (orchState)
- **Notes**: Line 1186 calls `getTaskToSync(ts)` to check pending tasks. If tasks pending and `skipPendingTaskCheck()` is false, replies NOT_READY.

### 6. OrchSendReadyReply

- **Spec action**: `OrchSendReadyReply`
- **Code location**: `orchdaemon.cpp:1207` — `gSwitchOrch->restartCheckReply("READY")`
- **Trigger point**: After READY reply sent
- **Trace event name**: `"OrchSendReadyReply"`
- **Fields**: State snapshot (orchState, componentState for orchagent)
- **Notes**: **CRITICAL FOR FAMILY 2**: This is the TOCTOU point. READY is sent here but ring buffer not yet drained (that happens at lines 1019-1026). Events can arrive between this point and actual freeze.

### 7. EventArrivalAfterReady

- **Spec action**: `EventArrivalAfterReady`
- **Code location**: `orchdaemon.cpp:1012-1014` — ring buffer receives event after READY
- **Trigger point**: After event added to ring buffer while in ReadyReplied state
- **Trace event name**: `"EventArrivalAfterReady"`
- **Fields**: State snapshot (pendingEvents)
- **Notes**: Models events arriving in the TOCTOU window. Instrument the ring buffer `push()` path when `readyReplySent` is true.

### 8. OrchDrainRingBuffer

- **Spec action**: `OrchDrainRingBuffer`
- **Code location**: `orchdaemon.cpp:1019-1026` — ring buffer drain loop
- **Trigger point**: After each ring buffer entry processed
- **Trace event name**: `"OrchDrainRingBuffer"`
- **Fields**: State snapshot (orchState, pendingEvents)
- **Notes**: Loop at lines 1019-1026: `while (!ringBuffer.empty() && !ringBuffer.idle())`. Each iteration processes one entry.

### 9. OrchFreeze

- **Spec action**: `OrchFreeze`
- **Code location**: `orchdaemon.cpp:1029-1048`
- **Trigger point**: After FDB aging disabled and bridge port learning disabled
- **Trace event name**: `"OrchFreeze"`
- **Fields**: State snapshot (orchState)
- **Notes**: Line 1035-1041: `setBridgePortLearningFDB()` may fail on some ports (ignores SAI error). Line 1048: enters `freezeAndHeartBeat()`.

### 10. EnterCheckpointPhase

- **Spec action**: `EnterCheckpointPhase`
- **Code location**: Warmboot Manager Phase 3 transition
- **Trigger point**: After all components confirmed quiescent, before checkpoint notifications sent
- **Trace event name**: `"EnterCheckpointPhase"`
- **Fields**: State snapshot (phase, pointOfNoReturn)
- **Notes**: **POINT OF NO RETURN**. After this, syncd disconnects from ASIC. No recovery path.

### 11. ComponentCheckpoint

- **Spec action**: `ComponentCheckpoint(c)`
- **Code location**:
  - syncd: Syncd pre-shutdown SAI disconnect
  - orchagent: label-to-key mapping save
  - teamd: LACP state save
- **Trigger point**: After component saves state to persistent storage / DB
- **Trace event name**: `"ComponentCheckpoint"`
- **Fields**: State snapshot (componentState for this component)
- **Notes**: Syncd specifically disconnects from ASIC at this point.

### 12. EnterRebootPhase

- **Spec action**: `EnterRebootPhase`
- **Code location**: Warmboot Manager Phase 4 entry
- **Trigger point**: After all components checkpointed, before kexec
- **Trace event name**: `"EnterRebootPhase"`
- **Fields**: State snapshot (phase)
- **Notes**: DB backup happens here. Platform-specific preparation.

### 13. SystemReboot

- **Spec action**: `SystemReboot`
- **Code location**: `sonic-buildimage: scripts/warm-reboot` — kexec call
- **Trigger point**: After system reboots and services restart. Emit this event when the first warm-restart-aware component initializes.
- **Trace event name**: `"SystemReboot"`
- **Fields**: State snapshot (phase)
- **Notes**: This is a synthetic event emitted after boot, not during reboot. It represents the transition from reboot to booting phase.

### 14. SyncdReceiveInitView

- **Spec action**: `SyncdReceiveInitView`
- **Code location**: `Syncd.cpp:4591-4615` — `processNotifySyncd()` INIT_VIEW handler
- **Trigger point**: After `m_asicInitViewMode = true` at line 4598
- **Trace event name**: `"SyncdReceiveInitView"`
- **Fields**: State snapshot (syncdMode)
- **Notes**: Line 4593-4596 warns if already in init mode. Line 4600 clears temp view. Line 4602 clears created objects list.

### 15. ApplyViewStage1

- **Spec action**: `ApplyViewStage1`
- **Code location**: `Syncd.cpp:4617-4627` — `processNotifySyncd()` APPLY_VIEW handler, before `applyView()`
- **Trigger point**: After `m_asicInitViewMode = false` at line 4619, before `applyView()` call at line 4627
- **Trace event name**: `"ApplyViewStage1"`
- **Fields**: State snapshot (syncdMode)
- **Notes**: Line 4619 sets `m_asicInitViewMode = false` BEFORE calling `applyView()`. This is the non-destructive comparison phase.

### 16. ApplyViewStage1Fail

- **Spec action**: `ApplyViewStage1Fail`
- **Code location**: `Syncd.cpp:4882-4891` — `applyView()` catch block
- **Trigger point**: After exception caught in Stage 1
- **Trace event name**: `"ApplyViewStage1Fail"`
- **Fields**: State snapshot (syncdMode)
- **Notes**: Safe failure — no ASIC operations executed. Returns FAILURE to orchagent.

### 17. ApplyViewStage2

- **Spec action**: `ApplyViewStage2`
- **Code location**: `Syncd.cpp:4894-4907` — `applyView()` Stage 2 entry
- **Trigger point**: After `compareViews()` succeeds, before `executeOperationsOnAsic()`
- **Trace event name**: `"ApplyViewStage2"`
- **Fields**: State snapshot (syncdMode)
- **Notes**: **DESTRUCTIVE**: After this point, ASIC operations begin with no rollback.

### 18. ApplyViewStage2Fail

- **Spec action**: `ApplyViewStage2Fail`
- **Code location**: `Syncd.cpp:4904-4907` — `executeOperationsOnAsic()` exception
- **Trigger point**: After exception during ASIC operations
- **Trace event name**: `"ApplyViewStage2Fail"`
- **Fields**: State snapshot (syncdMode, asicConnected, asicConsistent)
- **Notes**: **CRITICAL FOR FAMILY 3**: ASIC is partially updated. Code comment at Syncd.cpp:4797-4799 acknowledges "ASIC will be in inconsistent state".

### 19. ApplyViewComplete

- **Spec action**: `ApplyViewComplete`
- **Code location**: `Syncd.cpp:4904-4909`
- **Trigger point**: After both `executeOperationsOnAsic()` and `updateRedisDatabase()` succeed
- **Trace event name**: `"ApplyViewComplete"`
- **Fields**: State snapshot (syncdMode, asicConsistent, redisUpdated)
- **Notes**: Both ASIC and Redis updated. Normal completion path.

### 20. CrashBetweenAsicAndRedis

- **Spec action**: `CrashBetweenAsicAndRedis`
- **Code location**: Between `Syncd.cpp:4907` (`executeOperationsOnAsic()` return) and `Syncd.cpp:4909` (`updateRedisDatabase()`)
- **Trigger point**: Crash/power loss between these two calls
- **Trace event name**: `"CrashBetweenAsicAndRedis"`
- **Fields**: State snapshot (syncdMode, asicConsistent, redisUpdated)
- **Notes**: **CRITICAL FOR FAMILY 3**: This is a crash-injection point, not a normal code path. Can be triggered via fault injection (kill -9 syncd at the right moment). ASIC is updated but Redis is not — next warm boot sees stale Redis state.

### 21. SyncdInitFail

- **Spec action**: `SyncdInitFail`
- **Code location**: `Syncd.cpp:5050-5109` — `onSyncdStart()`
- **Trigger point**: After `performWarmRestart()` throws at line 5081
- **Trace event name**: `"SyncdInitFail"`
- **Fields**: State snapshot (syncdMode, asicConnected)
- **Notes**: RID mismatch (line 5377-5381) or empty switch list (line 5403-5407 with FIXME). After point of no return, this leaves system unrecoverable.

### 22. ComponentStartReconcileTimer

- **Spec action**: `ComponentStartReconcileTimer(c)`
- **Code location**:
  - neighsyncd: `neighsyncd.cpp:62` — timer start
  - AppRestartAssist: constructor (line 49-66) — timer init
- **Trigger point**: After timer started
- **Trace event name**: `"ComponentStartReconcileTimer"`
- **Fields**: State snapshot (no specific state field; timer value is internal)
- **Notes**: **CRITICAL FOR FAMILY 4**: neighsyncd starts timer at line 62, but netlink dump is at line 67. Timer can fire before all entries arrive.

### 23. ComponentReadTable

- **Spec action**: `ComponentReadTable(c)`
- **Code location**: `warmRestartAssist.cpp:131-165` — `readTablesToMap()`
- **Trigger point**: After all entries read into cache (line 159), after state set to RESTORED (line 161)
- **Trace event name**: `"ComponentReadTable"`
- **Fields**: State snapshot (componentState for this component)
- **Notes**: All entries initialized as STALE (line 151).

### 24. ReplayEntry

- **Spec action**: `ReplayEntry(c, k)`
- **Code location**: `warmRestartAssist.cpp:179-248` — `insertToMap()`
- **Trigger point**: After cache entry state updated
- **Trace event name**: `"ReplayEntry"`
- **Fields**: State snapshot + detail (key, cacheState)
- **Notes**: Maps to the `insertToMap()` logic. Cache transitions: STALE->SAME (if identical), STALE->NEW (if different), STALE->DELETE (if delete). **Family 4**: `contains()` at line 340-352 has asymmetry — field removal treated as SAME.

### 25. ReconcileTimerFire

- **Spec action**: `ReconcileTimerFire(c)`
- **Code location**: Component main loop timer check (e.g., `neighsyncd.cpp:44-90`)
- **Trigger point**: After timer expires and reconciliation triggered
- **Trace event name**: `"ReconcileTimerFire"`
- **Fields**: State snapshot
- **Notes**: Timer ticks are NOT individually traced (handled by silent actions in Trace.tla). Only the fire event is traced.

### 26. ReconcileComponent

- **Spec action**: `ReconcileComponent(c)`
- **Code location**: `warmRestartAssist.cpp:258-306` — `reconcile()`
- **Trigger point**: After reconcile completes, after state set to RECONCILED (line 303)
- **Trace event name**: `"ReconcileComponent"`
- **Fields**: State snapshot (componentState for this component)
- **Notes**: Line 271-275: SAME entries no-op. Line 277-283: STALE/DELETE entries deleted from appDB. Line 285-292: NEW entries set in appDB. Line 300-302: cache cleared.

### 27. ReconcileComponentWithoutTimer

- **Spec action**: `ReconcileComponentWithoutTimer(c)`
- **Code location**: vxlanmgrd main loop — declares RECONCILED on first SELECT_TIMEOUT
- **Trigger point**: After component declares RECONCILED without full reconciliation
- **Trace event name**: `"ReconcileComponentWithoutTimer"`
- **Fields**: State snapshot (componentState for this component)
- **Notes**: **CRITICAL FOR FAMILY 1**: vxlanmgrd declares RECONCILED after 1s timeout with no content verification. fdbsyncd then starts reconciling before VXLAN tunnels are actually restored.

### 28. OrchWarmRestore

- **Spec action**: `OrchWarmRestore`
- **Code location**: `orchdaemon.cpp:1059-1136` — `warmRestoreAndSyncUp()`
- **Trigger point**: After 3-phase restoration loop completes, after state set to RESTORED (line 1168)
- **Trace event name**: `"OrchWarmRestore"`
- **Fields**: State snapshot (orchState, componentState for orchagent)
- **Notes**: Abstracts the entire 3x iteration loop (lines 1085-1098) as a single event. Includes bake() calls (line 1067), MirrorOrch/AclOrch deferred processing (lines 1106-1107), and warmRestoreValidation() (line 1114).

### 29. OrchSendApplyView

- **Spec action**: `OrchSendApplyView`
- **Code location**: `orchdaemon.cpp:1123` — `syncd_apply_view()`
- **Trigger point**: After orchagent sends INIT_VIEW + APPLY_VIEW to syncd
- **Trace event name**: `"OrchSendApplyView"`
- **Fields**: State snapshot
- **Notes**: **CRITICAL FOR FAMILY 1**: This is sent before fdbsyncd's 120s timer completes. VXLAN FDB entries may be stale in hardware at this point.

### 30. OrchReconcileComplete

- **Spec action**: `OrchReconcileComplete`
- **Code location**: `orchdaemon.cpp:1127-1134`
- **Trigger point**: After `onWarmBootEnd()` called on all orchs (line 1127) and RECONCILED set (line 1134)
- **Trace event name**: `"OrchReconcileComplete"`
- **Fields**: State snapshot (orchState, componentState for orchagent, phase)
- **Notes**: This transitions the system to PhaseReconciling. Other components may still be reconciling independently.

### 31. ComponentFailDuringShutdown

- **Spec action**: `ComponentFailDuringShutdown(c)`
- **Code location**: Various component error paths during Phase 2-3
- **Trigger point**: After component enters failed state
- **Trace event name**: `"ComponentFailDuringShutdown"`
- **Fields**: State snapshot (componentState for this component)
- **Notes**: Before point of no return, Warmboot Manager can unfreeze. After, no recovery.

### 32. ComponentFailDuringReconciliation

- **Spec action**: `ComponentFailDuringReconciliation(c)`
- **Code location**: Component reconciliation error paths (e.g., neighsyncd `exit(EXIT_FAILURE)`)
- **Trigger point**: After component fails during reconciliation
- **Trace event name**: `"ComponentFailDuringReconciliation"`
- **Fields**: State snapshot (componentState for this component)
- **Notes**: **CR-5**: neighsyncd exits without setting FAILED state in STATE_DB.

### 33. ReconcileTimeout

- **Spec action**: `ReconcileTimeout`
- **Code location**: Warmboot Manager reconciliation timeout handler
- **Trigger point**: After timeout expires and remaining components marked failed
- **Trace event name**: `"ReconcileTimeout"`
- **Fields**: State snapshot
- **Notes**: **Family 5**: Cold restart triggered while some components already reconciled — partial state.

## Section 3: Special Considerations

### Cross-Component Coordination

All components run in separate containers. Trace collection requires coordinating log timestamps across containers. Use:
1. **Syslog** with unified timestamps across all containers
2. **Redis pub/sub** event logging via `swssloglevel` configuration
3. **STATE_DB** polling to capture state transitions

### STATE_DB as Ground Truth

Most component state transitions are observable via `STATE_DB:WARM_RESTART_TABLE`. This is the primary instrumentation point:
- Key: `WARM_RESTART_TABLE|<component>`
- Fields: `state` (the warm restart state), `timestamp`
- Poll with `redis-cli -n 6 hgetall "WARM_RESTART_TABLE|<component>"`

### Orchagent Internal State

Orchagent's internal freeze protocol state (OrchCheckingReady, OrchReadyReplied, etc.) is NOT visible in STATE_DB. Requires source-level instrumentation:
- Add syslog messages at key transition points in `orchdaemon.cpp`
- Or add a shadow STATE_DB key for orchagent internal state

### Syncd Internal State

Syncd's APPLY_VIEW stages are not observable via STATE_DB. Requires:
- Source-level syslog instrumentation in `Syncd.cpp` (processNotifySyncd, applyView)
- Or monitoring the ASIC_DB `VIDCOUNTER` table changes

### Timer Resolution

Component timers range from 1s (vxlanmgrd) to 120s (fdbsyncd). Trace collection should:
- Use sub-second timestamps (millisecond precision minimum)
- Capture timer start and fire events explicitly
- Timer tick events are NOT captured (too frequent, handled by silent actions)

### Crash Injection

Family 3 (CrashBetweenAsicAndRedis) requires crash injection:
- Use `kill -9` on syncd process at specific code points
- Or use a debugger to set a breakpoint between `executeOperationsOnAsic()` and `updateRedisDatabase()` in `Syncd.cpp:4904-4909`
- Capture pre-crash ASIC and Redis state for validation

### Key Abstraction

The spec uses abstract keys (k1, k2, ...). In the real system, keys are Redis table entries like `ROUTE_TABLE|10.0.0.0/24`. The instrumentation harness should:
- Map a small set of real Redis keys to abstract key names
- Track only the selected keys during trace collection
- Include the key mapping in trace metadata
