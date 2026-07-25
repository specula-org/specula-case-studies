# Instrumentation Guide: SONiC Warm Reboot

Guide for adjusting instrumentation when trace validation reveals issues.

## Architecture

The harness has two layers:

1. **Python protocol driver** (`harness/src/`) — exercises the warm reboot state machines extracted from the C++ source code. Produces traces immediately without SONiC build infrastructure.
2. **C++ instrumentation patches** (`harness/patches/`) — instrument the real SONiC source code with NDJSON trace emission. For use with the full SONiC build environment.

## Instrumentation Points

### Python Driver (`warm_reboot_harness.py`)

Each method maps 1:1 to a TLA+ action. The trace emit call is the last statement in each method (captures post-action state).

| Event | Method | Source Reference |
|-------|--------|-----------------|
| StartWarmReboot | `start_warm_reboot()` | scripts/warm-reboot |
| CompleteSanityChecks | `complete_sanity_checks()` | Warmboot Manager Phase 1 |
| ComponentReceiveFreeze | `component_receive_freeze(c)` | orchdaemon.cpp:1012 |
| ComponentQuiesce | `component_quiesce(c)` | orchdaemon.cpp:1019-1026 |
| OrchCheckReady | `orch_check_ready()` | orchdaemon.cpp:1178-1209 |
| OrchSendReadyReply | `orch_send_ready_reply()` | orchdaemon.cpp:1207 |
| EventArrivalAfterReady | `event_arrival_after_ready()` | orchdaemon.cpp:1012-1014 |
| OrchDrainRingBuffer | `orch_drain_ring_buffer()` | orchdaemon.cpp:1019-1026 |
| OrchFreeze | `orch_freeze()` | orchdaemon.cpp:1029-1048 |
| EnterCheckpointPhase | `enter_checkpoint_phase()` | Warmboot Manager Phase 3 |
| ComponentCheckpoint | `component_checkpoint(c)` | Syncd pre-shutdown |
| EnterRebootPhase | `enter_reboot_phase()` | Warmboot Manager Phase 4 |
| SystemReboot | `system_reboot()` | scripts/warm-reboot kexec |
| SyncdReceiveInitView | `syncd_receive_init_view()` | Syncd.cpp:4591-4615 |
| ApplyViewStage1 | `apply_view_stage1()` | Syncd.cpp:4617-4627 |
| ApplyViewStage1Fail | `apply_view_stage1_fail()` | Syncd.cpp:4882-4891 |
| ApplyViewStage2 | `apply_view_stage2()` | Syncd.cpp:4894-4907 |
| ApplyViewStage2Fail | `apply_view_stage2_fail()` | Syncd.cpp:4904-4907 |
| ApplyViewComplete | `apply_view_complete()` | Syncd.cpp:4904-4909 |
| CrashBetweenAsicAndRedis | `crash_between_asic_and_redis()` | Syncd.cpp:4907-4909 |
| SyncdInitFail | `syncd_init_fail()` | Syncd.cpp:5050-5109 |
| ComponentStartReconcileTimer | `component_start_reconcile_timer(c)` | warmRestartAssist.cpp:49-66 |
| ComponentReadTable | `component_read_table(c)` | warmRestartAssist.cpp:131-165 |
| ReplayEntry | `replay_entry(c, k, state)` | warmRestartAssist.cpp:179-248 |
| ReconcileTimerFire | `reconcile_timer_fire(c)` | warmRestartAssist.cpp:330-337 |
| ReconcileComponent | `reconcile_component(c)` | warmRestartAssist.cpp:258-306 |
| ReconcileComponentWithoutTimer | `reconcile_component_without_timer(c)` | vxlanmgrd SELECT_TIMEOUT |
| OrchWarmRestore | `orch_warm_restore()` | orchdaemon.cpp:1059-1136 |
| OrchSendApplyView | `orch_send_apply_view()` | orchdaemon.cpp:1123 |
| OrchReconcileComplete | `orch_reconcile_complete()` | orchdaemon.cpp:1127-1134 |
| ComponentFailDuringShutdown | `component_fail_during_shutdown(c)` | Warmboot Manager |
| ComponentFailDuringReconciliation | `component_fail_during_reconciliation(c)` | neighsyncd exit() |
| ReconcileTimeout | `reconcile_timeout()` | Warmboot Manager timeout |

### C++ Patches (`patches/instrumentation.patch`)

The patch adds `#include "tla_trace.h"` and `TlaTrace::emit()` calls to:

| File | Events Instrumented |
|------|-------------------|
| orchdaemon.cpp | OrchCheckReady, OrchSendReadyReply, OrchDrainRingBuffer, OrchFreeze, OrchWarmRestore, OrchSendApplyView, OrchReconcileComplete |
| warmRestartAssist.cpp | ComponentStartReconcileTimer, ComponentReadTable, ReplayEntry, ReconcileTimerFire, ReconcileComponent |
| Syncd.cpp | SyncdReceiveInitView, ApplyViewStage1, ApplyViewStage1Fail, ApplyViewStage2, ApplyViewComplete |
| neighsyncd.cpp | TlaTrace::init() call |

## How to Adjust Instrumentation

### Add a new field to an event

In the Python driver (`warm_reboot_harness.py`):
```python
def some_action(self):
    # ... state changes ...
    self.tw.emit("EventName", "component",
                 self._comp_state(c, newField="value"))  # Add field here
```

In the C++ patches (`tla_trace.h`):
```cpp
TlaTrace::emit("EventName", {
    {"existingField", "value"},
    {"newField", "newValue"}});  // Add field here
```

### Add a new event type

1. Add a method to `WarmRebootProtocol` in `warm_reboot_harness.py`
2. Call it from the appropriate scenario in `test_scenarios.py`
3. Add a corresponding `*IfLogged` wrapper in `Trace.tla`
4. Add it to `TraceNext` in `Trace.tla`

### Move a capture point (before -> after)

In the Python driver, move the `self.tw.emit()` call before or after the state mutation:
```python
def some_action(self):
    # Emit BEFORE state change (captures pre-state):
    self.tw.emit("Event", "comp", self._state())
    self.some_state = new_value

    # OR emit AFTER state change (captures post-state):
    self.some_state = new_value
    self.tw.emit("Event", "comp", self._state())
```

### Rebuild and re-run

```bash
cd .specula-output
bash harness/run.sh
```

## Test Scenarios

| Scenario | File | Bug Family | Events |
|----------|------|------------|--------|
| happy_path | traces/happy_path.ndjson | None | 62 |
| toctou_race | traces/toctou_race.ndjson | Family 2 | 65 |
| apply_view_fail | traces/apply_view_fail.ndjson | Family 3 | 31 |
| timer_race | traces/timer_race.ndjson | Family 4 | 61 |
| ordering_violation | traces/ordering_violation.ndjson | Family 1 | 59 |

## State Capture Levels

All events use **full capture** — the Python driver has access to all protocol state at every point. In the C++ patches, some events have reduced capture:

| Event | Level | Reason |
|-------|-------|--------|
| OrchDrainRingBuffer | Specialized | Only orchState + pendingEvents available in drain loop |
| ReplayEntry | Specialized | componentState + detail (key, cacheState) |
| All others | Full | All relevant state fields captured |

## Trace Format

Every trace line follows:
```json
{"tag":"trace","timestamp":"<ISO8601>","event":{"name":"<Action>","component":"<id>","state":{...},"detail":{...}}}
```

- `tag`: Always `"trace"` (required by Trace.tla filter)
- `timestamp`: Real ISO 8601 timestamps with microsecond precision
- `component`: One of `orchagent`, `syncd`, `neighsyncd`, `fdbsyncd`, `teamd`, `vxlanmgrd`
- `state`: Post-action state snapshot (fields depend on event type)
- `detail`: Optional action-specific fields (e.g., `key`, `cacheState` for ReplayEntry)
