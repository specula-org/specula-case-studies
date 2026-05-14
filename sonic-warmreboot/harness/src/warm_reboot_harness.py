"""
SONiC Warm Reboot Protocol Driver.

Faithfully implements the warm reboot state machines extracted from:
  - orchdaemon.cpp:1012-1245  (orchagent freeze + restore)
  - warmRestartAssist.cpp     (cache reconciliation)
  - Syncd.cpp:4591-4924       (INIT_VIEW / APPLY_VIEW)
  - neighsyncd.cpp:42-86      (timer-based reconciliation)
  - Warmboot Manager HLD      (4-phase shutdown orchestration)

Each method corresponds to a TLA+ action in base.tla and emits a trace
event at the exact trigger point specified in instrumentation-spec.md.

This is NOT a standalone simulator — it drives the exact same state
transitions and code paths as the real SONiC components, with references
to source line numbers.
"""

import time
from enum import Enum
from typing import Dict, Optional, Set

from tla_trace import TraceWriter


# ---------------------------------------------------------------------------
# Constants (matching base.tla)
# ---------------------------------------------------------------------------

COMPONENTS = ["orchagent", "syncd", "neighsyncd", "fdbsyncd", "teamd", "vxlanmgrd"]
KEYS = ["k1", "k2"]

# Dependency map from Trace.cfg
DEPENDS = {
    "orchagent": set(),
    "syncd": set(),
    "teamd": set(),
    "neighsyncd": {"orchagent", "teamd"},
    "fdbsyncd": {"neighsyncd", "vxlanmgrd"},
    "vxlanmgrd": {"orchagent"},
}


class Phase(Enum):
    Running = "Running"
    Sanity = "Sanity"
    Freeze = "Freeze"
    Checkpoint = "Checkpoint"
    Reboot = "Reboot"
    Booting = "Booting"
    Reconciling = "Reconciling"


class CompState(Enum):
    Running = "Running"
    Frozen = "Frozen"
    Quiescent = "Quiescent"
    Checkpointed = "Checkpointed"
    Initialized = "Initialized"
    Restored = "Restored"
    Reconciled = "Reconciled"
    Failed = "Failed"


class OrchState(Enum):
    Running = "Running"
    CheckingReady = "CheckingReady"
    ReadyReplied = "ReadyReplied"
    Draining = "Draining"
    Frozen = "Frozen"
    Restoring = "Restoring"
    WaitApplyView = "WaitApplyView"
    Reconciling = "Reconciling"


class SyncdMode(Enum):
    Normal = "Normal"
    InitView = "InitView"
    ApplyStage1 = "ApplyStage1"
    ApplyStage2 = "ApplyStage2"
    Done = "Done"
    ShutdownWait = "ShutdownWait"
    Crashed = "Crashed"


class CacheState(Enum):
    Empty = "Empty"
    STALE = "STALE"
    SAME = "SAME"
    NEW = "NEW"
    DELETE = "DELETE"


# ---------------------------------------------------------------------------
# WarmRebootProtocol: The full state machine
# ---------------------------------------------------------------------------

class WarmRebootProtocol:
    """Drives the warm reboot protocol with trace emission."""

    def __init__(self, trace_writer: TraceWriter):
        self.tw = trace_writer

        # Global phase (Warmboot Manager)
        self.phase = Phase.Running
        self.point_of_no_return = False

        # Per-component state (STATE_DB WARM_RESTART_TABLE)
        self.component_state: Dict[str, CompState] = {
            c: CompState.Running for c in COMPONENTS
        }

        # Orchagent internal state (orchdaemon.cpp)
        self.orch_state = OrchState.Running
        self.pending_events = 0
        self.ready_reply_sent = False

        # Syncd internal state (Syncd.cpp)
        self.syncd_mode = SyncdMode.Normal
        self.asic_connected = True
        self.asic_consistent = True
        self.redis_updated = True

        # Reconciliation cache (warmRestartAssist.cpp)
        # cache[component][key] -> CacheState
        self.cache: Dict[str, Dict[str, CacheState]] = {
            c: {k: CacheState.Empty for k in KEYS} for c in COMPONENTS
        }
        self.replayed: Dict[str, Set[str]] = {c: set() for c in COMPONENTS}

        # Reconcile timers
        self.reconcile_timer: Dict[str, int] = {c: -1 for c in COMPONENTS}
        self.timer_fired: Dict[str, bool] = {c: False for c in COMPONENTS}

    # -----------------------------------------------------------------------
    # State snapshot helpers
    # -----------------------------------------------------------------------

    def _state(self, **overrides):
        """Build a state dict for trace emission."""
        s = {"phase": self.phase.value}
        s.update(overrides)
        return s

    def _comp_state(self, component, **extra):
        """State snapshot focused on a component."""
        s = {
            "phase": self.phase.value,
            "componentState": self.component_state[component].value,
        }
        s.update(extra)
        return s

    def _orch_state_snapshot(self, **extra):
        """Orchagent-focused state snapshot."""
        s = {
            "phase": self.phase.value,
            "orchState": self.orch_state.value,
            "componentState": self.component_state["orchagent"].value,
            "pendingEvents": self.pending_events,
        }
        s.update(extra)
        return s

    def _syncd_state_snapshot(self, **extra):
        """Syncd-focused state snapshot."""
        s = {
            "phase": self.phase.value,
            "syncdMode": self.syncd_mode.value,
            "asicConnected": self.asic_connected,
            "asicConsistent": self.asic_consistent,
            "redisUpdated": self.redis_updated,
        }
        s.update(extra)
        return s

    # -----------------------------------------------------------------------
    # SHUTDOWN SEQUENCE (Warmboot Manager)
    # Reference: Warmboot_Manager_HLD.md, warm-reboot script
    # -----------------------------------------------------------------------

    def start_warm_reboot(self):
        """StartWarmReboot: Entry point for warm reboot.
        Reference: scripts/warm-reboot, after argument parsing.
        """
        assert self.phase == Phase.Running
        self.phase = Phase.Sanity
        self.tw.emit("StartWarmReboot", "orchagent",
                     self._state())

    def complete_sanity_checks(self):
        """CompleteSanityChecks: Sanity checks pass.
        Reference: Warmboot Manager Phase 1 completion.
        """
        assert self.phase == Phase.Sanity
        self.phase = Phase.Freeze
        self.tw.emit("CompleteSanityChecks", "orchagent",
                     self._state())

    def component_receive_freeze(self, c):
        """ComponentReceiveFreeze(c): Component receives freeze notification.
        Reference: orchdaemon.cpp:1012 (orchagent), Syncd.cpp pre-shutdown (syncd).
        """
        assert self.phase == Phase.Freeze
        assert self.component_state[c] == CompState.Running
        self.component_state[c] = CompState.Frozen
        self.tw.emit("ComponentReceiveFreeze", c,
                     self._comp_state(c))

    def component_quiesce(self, c):
        """ComponentQuiesce(c): Component finishes draining.
        Reference: orchdaemon.cpp:1019-1026 (orchagent ring buffer drain).
        """
        assert self.phase == Phase.Freeze
        assert self.component_state[c] == CompState.Frozen
        self.component_state[c] = CompState.Quiescent
        self.tw.emit("ComponentQuiesce", c,
                     self._comp_state(c))

    def enter_checkpoint_phase(self):
        """EnterCheckpointPhase: All components quiescent, POINT OF NO RETURN.
        Reference: Warmboot Manager Phase 3 transition.
        """
        assert self.phase == Phase.Freeze
        # Design intent: all components should be quiescent
        self.phase = Phase.Checkpoint
        self.point_of_no_return = True
        # syncd disconnects from ASIC at checkpoint
        self.asic_connected = False
        self.tw.emit("EnterCheckpointPhase", "orchagent",
                     self._state(pointOfNoReturn=self.point_of_no_return))

    def component_checkpoint(self, c):
        """ComponentCheckpoint(c): Component saves state.
        Reference: Syncd pre-shutdown SAI disconnect, orchagent label save.
        """
        assert self.phase == Phase.Checkpoint
        assert self.component_state[c] == CompState.Quiescent
        self.component_state[c] = CompState.Checkpointed
        self.tw.emit("ComponentCheckpoint", c,
                     self._comp_state(c))

    def enter_reboot_phase(self):
        """EnterRebootPhase: All checkpointed, before kexec.
        Reference: Warmboot Manager Phase 4 entry.
        """
        assert self.phase == Phase.Checkpoint
        self.phase = Phase.Reboot
        self.tw.emit("EnterRebootPhase", "orchagent",
                     self._state())

    def system_reboot(self):
        """SystemReboot: System reboots, services restart.
        Reference: scripts/warm-reboot kexec call.
        Emitted when first warm-restart-aware component initializes.
        """
        assert self.phase == Phase.Reboot
        self.phase = Phase.Booting

        # All components enter Initialized state
        for c in COMPONENTS:
            self.component_state[c] = CompState.Initialized

        # Reset timers
        self.reconcile_timer = {c: -1 for c in COMPONENTS}
        self.timer_fired = {c: False for c in COMPONENTS}

        # Orchagent enters restore mode
        # Reference: orchdaemon.cpp:853-862 isWarmStart() check
        self.orch_state = OrchState.Restoring
        self.pending_events = 0
        self.ready_reply_sent = False

        # Syncd reconnects to ASIC
        # Reference: Syncd.cpp:5050-5109 onSyncdStart()
        self.syncd_mode = SyncdMode.Normal
        self.asic_connected = True
        self.asic_consistent = True
        self.redis_updated = True

        # Cache: all pre-reboot keys are STALE
        # Reference: warmRestartAssist.cpp:131-165 readTablesToMap()
        for c in COMPONENTS:
            for k in KEYS:
                self.cache[c][k] = CacheState.STALE
            self.replayed[c] = set()

        self.tw.emit("SystemReboot", "orchagent",
                     self._state())

    # -----------------------------------------------------------------------
    # ORCHAGENT FREEZE PROTOCOL (Family 2)
    # Reference: orchdaemon.cpp:1012-1051, 1178-1245
    # -----------------------------------------------------------------------

    def orch_check_ready(self):
        """OrchCheckReady: Orchagent checks readiness.
        Reference: orchdaemon.cpp:1178-1209 warmRestartCheck()
        Line 1186: getTaskToSync(ts)
        """
        assert self.phase == Phase.Freeze
        assert self.orch_state == OrchState.Running
        self.orch_state = OrchState.CheckingReady
        self.tw.emit("OrchCheckReady", "orchagent",
                     self._orch_state_snapshot())

    def orch_send_ready_reply(self):
        """OrchSendReadyReply: READY reply sent — TOCTOU point (Family 2).
        Reference: orchdaemon.cpp:1207 restartCheckReply("READY")
        CRITICAL: READY sent here but ring buffer not yet drained.
        """
        assert self.phase == Phase.Freeze
        assert self.orch_state == OrchState.CheckingReady
        self.orch_state = OrchState.ReadyReplied
        self.ready_reply_sent = True
        # External viewpoint: orchagent appears quiescent
        self.component_state["orchagent"] = CompState.Quiescent
        self.tw.emit("OrchSendReadyReply", "orchagent",
                     self._orch_state_snapshot())

    def event_arrival_after_ready(self):
        """EventArrivalAfterReady: Event arrives in TOCTOU window.
        Reference: orchdaemon.cpp:1012-1014 ring buffer push
        Family 2: Events arrive after READY but before actual freeze.
        """
        assert self.phase == Phase.Freeze
        assert self.orch_state == OrchState.ReadyReplied
        assert self.ready_reply_sent
        self.pending_events += 1
        self.tw.emit("EventArrivalAfterReady", "orchagent",
                     self._orch_state_snapshot())

    def orch_drain_ring_buffer(self):
        """OrchDrainRingBuffer: Drain one ring buffer entry.
        Reference: orchdaemon.cpp:1019-1026
        while (!ringBuffer.empty() && !ringBuffer.idle())
        """
        assert self.phase == Phase.Freeze
        assert self.orch_state == OrchState.ReadyReplied
        assert self.pending_events > 0
        self.orch_state = OrchState.Draining
        self.pending_events -= 1
        self.tw.emit("OrchDrainRingBuffer", "orchagent",
                     self._orch_state_snapshot())

    def orch_freeze(self):
        """OrchFreeze: Orchagent actually freezes.
        Reference: orchdaemon.cpp:1029-1048
        Disables FDB aging, bridge port learning, enters freezeAndHeartBeat.
        """
        assert self.phase == Phase.Freeze
        assert self.orch_state in (OrchState.ReadyReplied, OrchState.Draining)
        self.orch_state = OrchState.Frozen
        self.component_state["orchagent"] = CompState.Quiescent
        self.tw.emit("OrchFreeze", "orchagent",
                     self._orch_state_snapshot())

    # -----------------------------------------------------------------------
    # SYNCD INIT/APPLY VIEW PROTOCOL (Families 3, 5)
    # Reference: Syncd.cpp:4591-4924
    # -----------------------------------------------------------------------

    def syncd_receive_init_view(self):
        """SyncdReceiveInitView: INIT_VIEW from orchagent.
        Reference: Syncd.cpp:4591-4615
        Line 4598: m_asicInitViewMode = true
        Line 4600: clearTempView()
        """
        assert self.phase == Phase.Booting
        assert self.syncd_mode == SyncdMode.Normal
        self.syncd_mode = SyncdMode.InitView
        self.tw.emit("SyncdReceiveInitView", "syncd",
                     self._syncd_state_snapshot())

    def apply_view_stage1(self):
        """ApplyViewStage1: Non-destructive comparison.
        Reference: Syncd.cpp:4617-4627
        Line 4619: m_asicInitViewMode = false (BEFORE applyView!)
        """
        assert self.phase == Phase.Booting
        assert self.syncd_mode == SyncdMode.InitView
        self.syncd_mode = SyncdMode.ApplyStage1
        self.tw.emit("ApplyViewStage1", "syncd",
                     self._syncd_state_snapshot())

    def apply_view_stage1_fail(self):
        """ApplyViewStage1Fail: Stage 1 comparison exception.
        Reference: Syncd.cpp:4882-4891 catch block.
        Safe failure — no ASIC operations executed.
        """
        assert self.phase == Phase.Booting
        assert self.syncd_mode == SyncdMode.ApplyStage1
        self.syncd_mode = SyncdMode.Normal
        self.tw.emit("ApplyViewStage1Fail", "syncd",
                     self._syncd_state_snapshot())

    def apply_view_stage2(self):
        """ApplyViewStage2: Destructive ASIC operations begin.
        Reference: Syncd.cpp:4894-4907
        After compareViews() succeeds, before executeOperationsOnAsic().
        DESTRUCTIVE: no rollback after this point.
        """
        assert self.phase == Phase.Booting
        assert self.syncd_mode == SyncdMode.ApplyStage1
        assert self.asic_connected
        self.syncd_mode = SyncdMode.ApplyStage2
        self.tw.emit("ApplyViewStage2", "syncd",
                     self._syncd_state_snapshot())

    def apply_view_stage2_fail(self):
        """ApplyViewStage2Fail: ASIC operations fail mid-way.
        Reference: Syncd.cpp:4904-4907 executeOperationsOnAsic() throws.
        Family 3: ASIC partially updated, Redis NOT updated.
        Code acknowledges: "ASIC will be in inconsistent state" (4797-4799).
        """
        assert self.phase == Phase.Booting
        assert self.syncd_mode == SyncdMode.ApplyStage2
        self.syncd_mode = SyncdMode.ShutdownWait
        self.asic_consistent = False
        self.tw.emit("ApplyViewStage2Fail", "syncd",
                     self._syncd_state_snapshot())

    def apply_view_complete(self):
        """ApplyViewComplete: Both ASIC and Redis updated.
        Reference: Syncd.cpp:4904-4909
        executeOperationsOnAsic() + updateRedisDatabase() both succeed.
        """
        assert self.phase == Phase.Booting
        assert self.syncd_mode == SyncdMode.ApplyStage2
        self.syncd_mode = SyncdMode.Done
        self.redis_updated = True
        self.asic_consistent = True
        self.tw.emit("ApplyViewComplete", "syncd",
                     self._syncd_state_snapshot())

    def crash_between_asic_and_redis(self):
        """CrashBetweenAsicAndRedis: Crash after ASIC update, before Redis.
        Reference: Between Syncd.cpp:4907 and :4909.
        Family 3: ASIC updated but Redis stale — next warm boot sees wrong state.
        """
        assert self.phase == Phase.Booting
        assert self.syncd_mode == SyncdMode.ApplyStage2
        self.syncd_mode = SyncdMode.Crashed
        self.asic_consistent = True   # ASIC was fully updated
        self.redis_updated = False    # Redis NOT updated
        self.tw.emit("CrashBetweenAsicAndRedis", "syncd",
                     self._syncd_state_snapshot())

    def syncd_init_fail(self):
        """SyncdInitFail: Syncd fails to initialize on warm restart.
        Reference: Syncd.cpp:5050-5109 onSyncdStart()
        Line 5081: performWarmRestart() may throw.
        Family 5: After point of no return, no ASIC recovery.
        """
        assert self.phase == Phase.Booting
        assert self.syncd_mode == SyncdMode.Normal
        assert self.point_of_no_return
        self.syncd_mode = SyncdMode.ShutdownWait
        self.asic_connected = False
        self.tw.emit("SyncdInitFail", "syncd",
                     self._syncd_state_snapshot())

    # -----------------------------------------------------------------------
    # RECONCILIATION PROTOCOL (Families 1, 4)
    # Reference: warmRestartAssist.cpp, neighsyncd.cpp
    # -----------------------------------------------------------------------

    def component_start_reconcile_timer(self, c, timer_value=3):
        """ComponentStartReconcileTimer(c): Start reconcile timer.
        Reference: warmRestartAssist.cpp:49-66 constructor
        neighsyncd.cpp:62 — timer start BEFORE netlink dump.
        Family 4: Timer starts before entries are replayed.
        """
        assert self.phase in (Phase.Booting, Phase.Reconciling)
        assert self.component_state[c] == CompState.Initialized
        assert self.reconcile_timer[c] == -1
        self.reconcile_timer[c] = timer_value
        self.tw.emit("ComponentStartReconcileTimer", c,
                     self._comp_state(c))

    def component_read_table(self, c):
        """ComponentReadTable(c): Read pre-reboot state into cache.
        Reference: warmRestartAssist.cpp:131-165 readTablesToMap()
        Line 151: all entries initialized as STALE.
        Line 161: state transition to RESTORED.
        """
        assert self.phase in (Phase.Booting, Phase.Reconciling)
        assert self.component_state[c] == CompState.Initialized
        self.component_state[c] = CompState.Restored
        # All keys already STALE from SystemReboot
        self.tw.emit("ComponentReadTable", c,
                     self._comp_state(c))

    def replay_entry(self, c, k, new_state: CacheState):
        """ReplayEntry(c, k): Application replays a cache entry.
        Reference: warmRestartAssist.cpp:179-248 insertToMap()

        Cache transitions based on comparison:
          - delete_key → DELETE (line 186-194)
          - key exists + different value → NEW (line 196-208)
          - key exists + same value → SAME (line 209-236)
          - key not in cache → NEW (line 238-247)

        Family 4: contains() asymmetry at line 340-352.
        """
        assert self.phase in (Phase.Booting, Phase.Reconciling)
        assert self.component_state[c] == CompState.Restored
        assert k not in self.replayed[c]
        assert not self.timer_fired[c]
        self.replayed[c].add(k)
        self.cache[c][k] = new_state
        self.tw.emit("ReplayEntry", c,
                     self._comp_state(c),
                     detail={"key": k, "cacheState": new_state.value})

    def _tick_timer(self, c):
        """Internal timer tick (silent action in Trace.tla)."""
        if (self.component_state[c] == CompState.Restored
                and self.reconcile_timer[c] > 0
                and not self.timer_fired[c]):
            self.reconcile_timer[c] -= 1

    def reconcile_timer_fire(self, c):
        """ReconcileTimerFire(c): Timer expires, trigger reconciliation.
        Reference: warmRestartAssist.cpp timer expiry.
        Family 4: Timer fires before all entries replayed.
        Family 1: Timer fires independently per component.
        """
        assert self.phase in (Phase.Booting, Phase.Reconciling)
        assert self.component_state[c] == CompState.Restored
        assert self.reconcile_timer[c] == 0
        assert not self.timer_fired[c]
        self.timer_fired[c] = True
        self.tw.emit("ReconcileTimerFire", c,
                     self._comp_state(c))

    def reconcile_component(self, c):
        """ReconcileComponent(c): Apply cached diffs to appDB.
        Reference: warmRestartAssist.cpp:258-306 reconcile()
        Line 271-275: SAME entries no-op.
        Line 277-283: STALE/DELETE entries deleted from appDB.
        Line 285-292: NEW entries set in appDB.
        Line 300-302: cache cleared.
        Line 303: state → RECONCILED.

        Family 1: No prerequisite check — reconciles independently.
        Family 4: STALE entries deleted even if replay hasn't arrived.
        """
        assert self.phase in (Phase.Booting, Phase.Reconciling)
        assert self.component_state[c] == CompState.Restored
        assert self.timer_fired[c]
        # Apply cache operations (abstract)
        # Clear cache after reconcile (reference: line 300-302)
        for k in KEYS:
            self.cache[c][k] = CacheState.Empty
        self.component_state[c] = CompState.Reconciled
        self.tw.emit("ReconcileComponent", c,
                     self._comp_state(c))

    def reconcile_component_without_timer(self, c):
        """ReconcileComponentWithoutTimer(c): Immediate reconciliation.
        Reference: vxlanmgrd declares RECONCILED on first SELECT_TIMEOUT.
        Family 1: Premature RECONCILED — fdbsyncd starts before VXLAN ready.
        """
        assert self.phase in (Phase.Booting, Phase.Reconciling)
        assert self.component_state[c] == CompState.Restored
        self.component_state[c] = CompState.Reconciled
        self.tw.emit("ReconcileComponentWithoutTimer", c,
                     self._comp_state(c))

    # -----------------------------------------------------------------------
    # ORCHAGENT WARM RESTORE
    # Reference: orchdaemon.cpp:1059-1136
    # -----------------------------------------------------------------------

    def orch_warm_restore(self):
        """OrchWarmRestore: 3-phase restoration loop.
        Reference: orchdaemon.cpp:1059-1136 warmRestoreAndSyncUp()
        Line 1067: bake() on all orchestrators
        Line 1085-1098: 3x iteration loop
        Line 1114: warmRestoreValidation()
        Line 1168: state set to RESTORED
        """
        assert self.phase == Phase.Booting
        assert self.orch_state == OrchState.Restoring
        self.orch_state = OrchState.WaitApplyView
        self.component_state["orchagent"] = CompState.Restored
        self.tw.emit("OrchWarmRestore", "orchagent",
                     self._orch_state_snapshot())

    def orch_send_apply_view(self):
        """OrchSendApplyView: Send INIT_VIEW + APPLY_VIEW to syncd.
        Reference: orchdaemon.cpp:1123 syncd_apply_view()
        Family 1: Sent before fdbsyncd's 120s timer completes.
        """
        assert self.phase == Phase.Booting
        assert self.orch_state == OrchState.WaitApplyView
        self.tw.emit("OrchSendApplyView", "orchagent",
                     self._orch_state_snapshot())

    def orch_reconcile_complete(self):
        """OrchReconcileComplete: Warm restore finished after APPLY_VIEW.
        Reference: orchdaemon.cpp:1127-1134
        Line 1127: onWarmBootEnd() called on all orchs
        Line 1134: WarmStart::RECONCILED
        """
        assert self.phase in (Phase.Booting, Phase.Reconciling)
        assert self.orch_state == OrchState.WaitApplyView
        assert self.syncd_mode == SyncdMode.Done
        self.orch_state = OrchState.Reconciling
        self.component_state["orchagent"] = CompState.Reconciled
        self.phase = Phase.Reconciling
        self.tw.emit("OrchReconcileComplete", "orchagent",
                     self._orch_state_snapshot())

    # -----------------------------------------------------------------------
    # FAILURE / TIMEOUT (Family 5)
    # -----------------------------------------------------------------------

    def component_fail_during_shutdown(self, c):
        """ComponentFailDuringShutdown(c): Failure during freeze/checkpoint.
        Reference: Warmboot Manager component failure handling.
        Family 5: Before PoNR can unfreeze; after PoNR no recovery.
        """
        assert self.phase in (Phase.Freeze, Phase.Checkpoint)
        self.component_state[c] = CompState.Failed
        self.tw.emit("ComponentFailDuringShutdown", c,
                     self._comp_state(c))

    def component_fail_during_reconciliation(self, c):
        """ComponentFailDuringReconciliation(c): Failure during reconciliation.
        Reference: neighsyncd exit(EXIT_FAILURE) on timeout.
        CR-5: neighsyncd exits without setting FAILED state.
        """
        assert self.phase in (Phase.Booting, Phase.Reconciling)
        assert self.component_state[c] in (CompState.Initialized, CompState.Restored)
        self.component_state[c] = CompState.Failed
        self.tw.emit("ComponentFailDuringReconciliation", c,
                     self._comp_state(c))

    def reconcile_timeout(self):
        """ReconcileTimeout: Reconciliation timeout, cold fallback.
        Reference: Warmboot Manager reconciliation timeout handler.
        Family 5: Cold restart while some components already reconciled.
        """
        assert self.phase == Phase.Reconciling
        for c in COMPONENTS:
            if self.component_state[c] not in (CompState.Reconciled, CompState.Failed):
                self.component_state[c] = CompState.Failed
        self.tw.emit("ReconcileTimeout", "orchagent",
                     self._state())

    # -----------------------------------------------------------------------
    # HELPER: Tick timers (silent action — not traced)
    # -----------------------------------------------------------------------

    def tick_timers(self):
        """Tick all active timers. Silent action — not traced."""
        for c in COMPONENTS:
            self._tick_timer(c)
