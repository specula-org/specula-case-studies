#!/usr/bin/env python3
"""
Test scenarios for SONiC Warm Reboot trace generation.

Each scenario exercises a specific protocol path and bug family:
  1. happy_path        — Full warm reboot with successful reconciliation
  2. toctou_race       — Family 2: Events arrive after READY reply
  3. apply_view_fail   — Family 3: APPLY_VIEW Stage 2 failure
  4. timer_race        — Family 4: Reconcile timer fires before all entries replayed
  5. ordering_violation — Family 1: vxlanmgrd reconciles before dependencies

Traces written to: traces/<scenario>.ndjson
"""

import os
import sys
import time

# Add harness src to path
sys.path.insert(0, os.path.dirname(__file__))

from tla_trace import TraceWriter
from warm_reboot_harness import (
    WarmRebootProtocol, CacheState, Phase, CompState, COMPONENTS,
)

TRACE_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "traces")


def _shutdown_all_components(proto, skip_orchagent=False):
    """Run the standard 4-phase shutdown for all components.

    When skip_orchagent=True, the orchagent freeze protocol is handled
    separately by the caller (for Family 2 scenarios).
    """
    # Phase 2: Freeze all non-orchagent components
    for c in COMPONENTS:
        if c == "orchagent" and skip_orchagent:
            continue
        if proto.component_state[c] == CompState.Running:
            proto.component_receive_freeze(c)

    # Phase 2: Quiesce all non-orchagent components
    for c in COMPONENTS:
        if c == "orchagent" and skip_orchagent:
            continue
        if proto.component_state[c] == CompState.Frozen:
            proto.component_quiesce(c)

    # If orchagent was skipped, handle its freeze protocol
    if skip_orchagent:
        _orchagent_freeze_protocol(proto)


def _orchagent_freeze_protocol(proto, inject_events=0):
    """Run orchagent's freeze protocol (Family 2 path).

    Reference: orchdaemon.cpp:1012-1051, 1178-1209

    Args:
        inject_events: Number of events to inject in TOCTOU window.
    """
    # orchagent receives freeze
    if proto.component_state["orchagent"] == CompState.Running:
        proto.component_receive_freeze("orchagent")

    # warmRestartCheck() — line 1178
    proto.orch_check_ready()

    # restartCheckReply("READY") — line 1207 (TOCTOU point)
    proto.orch_send_ready_reply()

    # Inject events in TOCTOU window (Family 2)
    for _ in range(inject_events):
        time.sleep(0.001)  # Real delay between events
        proto.event_arrival_after_ready()

    # Drain ring buffer — lines 1019-1026
    while proto.pending_events > 0:
        proto.orch_drain_ring_buffer()

    # Actually freeze — lines 1029-1048
    proto.orch_freeze()


def _checkpoint_and_reboot(proto):
    """Run checkpoint and reboot phases."""
    proto.enter_checkpoint_phase()
    for c in COMPONENTS:
        if proto.component_state[c] == CompState.Quiescent:
            proto.component_checkpoint(c)
    proto.enter_reboot_phase()
    proto.system_reboot()


def _standard_reconciliation(proto, components=None, timer_values=None,
                              replay_states=None, early_reconcile=None):
    """Run standard reconciliation for the given components.

    Args:
        components: List of components to reconcile (default: all)
        timer_values: Dict of component -> timer value
        replay_states: Dict of component -> {key -> CacheState}
        early_reconcile: Set of components that reconcile without timer
    """
    if components is None:
        components = list(COMPONENTS)
    if timer_values is None:
        timer_values = {}
    if replay_states is None:
        replay_states = {}
    if early_reconcile is None:
        early_reconcile = set()

    # Start timers and read tables
    for c in components:
        if c == "orchagent":
            continue  # orchagent has its own restore path
        if proto.component_state[c] != CompState.Initialized:
            continue
        tv = timer_values.get(c, 3)
        proto.component_start_reconcile_timer(c, tv)
        proto.component_read_table(c)

    # Replay entries for each component
    for c in components:
        if c == "orchagent":
            continue
        if proto.component_state[c] != CompState.Restored:
            continue
        if c in early_reconcile:
            continue
        states = replay_states.get(c, {"k1": CacheState.SAME, "k2": CacheState.SAME})
        for k, st in states.items():
            if k not in proto.replayed[c]:
                proto.replay_entry(c, k, st)

    # Tick timers and fire
    for c in components:
        if c == "orchagent":
            continue
        if c in early_reconcile:
            continue
        if proto.component_state[c] != CompState.Restored:
            continue
        while proto.reconcile_timer[c] > 0:
            proto.tick_timers()
            time.sleep(0.001)  # Real delay for timer ticks
        if proto.reconcile_timer[c] == 0 and not proto.timer_fired[c]:
            proto.reconcile_timer_fire(c)
            proto.reconcile_component(c)

    # Handle early-reconcile components
    for c in early_reconcile:
        if proto.component_state[c] == CompState.Restored:
            proto.reconcile_component_without_timer(c)


# ===========================================================================
# Scenario 1: Happy Path — Full warm reboot with successful reconciliation
# ===========================================================================

def scenario_happy_path():
    """Full warm reboot: shutdown, reboot, reconcile all components."""
    tw = TraceWriter(os.path.join(TRACE_DIR, "happy_path.ndjson"))
    tw.emit_config({
        "scenario": "happy_path",
        "components": COMPONENTS,
        "description": "Full warm reboot with successful reconciliation",
    })
    proto = WarmRebootProtocol(tw)

    # --- Shutdown sequence ---
    proto.start_warm_reboot()
    proto.complete_sanity_checks()

    # Freeze + quiesce non-orchagent components
    for c in ["syncd", "neighsyncd", "fdbsyncd", "teamd", "vxlanmgrd"]:
        proto.component_receive_freeze(c)
    for c in ["syncd", "neighsyncd", "fdbsyncd", "teamd", "vxlanmgrd"]:
        proto.component_quiesce(c)

    # Orchagent freeze protocol (no TOCTOU events)
    _orchagent_freeze_protocol(proto, inject_events=0)

    # Checkpoint + reboot
    _checkpoint_and_reboot(proto)

    # --- Post-reboot: Orchagent warm restore ---
    proto.orch_warm_restore()
    proto.orch_send_apply_view()

    # Syncd APPLY_VIEW (success path)
    proto.syncd_receive_init_view()
    proto.apply_view_stage1()
    proto.apply_view_stage2()
    proto.apply_view_complete()

    # Orchagent reconcile complete
    proto.orch_reconcile_complete()

    # --- Reconciliation for other components ---
    # teamd + syncd reconcile first (no dependencies)
    for c in ["teamd", "syncd"]:
        proto.component_start_reconcile_timer(c, 2)
        proto.component_read_table(c)
        proto.replay_entry(c, "k1", CacheState.SAME)
        proto.replay_entry(c, "k2", CacheState.SAME)
        proto.tick_timers()
        time.sleep(0.001)
        proto.tick_timers()
        proto.reconcile_timer_fire(c)
        proto.reconcile_component(c)

    # neighsyncd (depends on orchagent, teamd — both reconciled)
    proto.component_start_reconcile_timer("neighsyncd", 2)
    proto.component_read_table("neighsyncd")
    proto.replay_entry("neighsyncd", "k1", CacheState.SAME)
    proto.replay_entry("neighsyncd", "k2", CacheState.NEW)
    proto.tick_timers()
    time.sleep(0.001)
    proto.tick_timers()
    proto.reconcile_timer_fire("neighsyncd")
    proto.reconcile_component("neighsyncd")

    # vxlanmgrd (depends on orchagent — reconciled)
    proto.component_start_reconcile_timer("vxlanmgrd", 1)
    proto.component_read_table("vxlanmgrd")
    proto.replay_entry("vxlanmgrd", "k1", CacheState.SAME)
    proto.replay_entry("vxlanmgrd", "k2", CacheState.SAME)
    proto.tick_timers()
    proto.reconcile_timer_fire("vxlanmgrd")
    proto.reconcile_component("vxlanmgrd")

    # fdbsyncd (depends on neighsyncd, vxlanmgrd — both reconciled)
    proto.component_start_reconcile_timer("fdbsyncd", 2)
    proto.component_read_table("fdbsyncd")
    proto.replay_entry("fdbsyncd", "k1", CacheState.SAME)
    proto.replay_entry("fdbsyncd", "k2", CacheState.DELETE)
    proto.tick_timers()
    time.sleep(0.001)
    proto.tick_timers()
    proto.reconcile_timer_fire("fdbsyncd")
    proto.reconcile_component("fdbsyncd")

    tw.close()
    return "happy_path"


# ===========================================================================
# Scenario 2: TOCTOU Race (Family 2)
# Events arrive after READY reply but before actual freeze
# ===========================================================================

def scenario_toctou_race():
    """Family 2: TOCTOU race — events arrive after READY reply.

    Reference: orchdaemon.cpp:1207 (READY reply) vs 1019-1026 (drain).
    Bug: READY sent at line 1207, but ring buffer not yet drained.
    Events can arrive between READY and actual freeze at line 1048.
    """
    tw = TraceWriter(os.path.join(TRACE_DIR, "toctou_race.ndjson"))
    tw.emit_config({
        "scenario": "toctou_race",
        "bug_family": 2,
        "description": "Events arrive after READY reply (TOCTOU window)",
    })
    proto = WarmRebootProtocol(tw)

    # --- Shutdown ---
    proto.start_warm_reboot()
    proto.complete_sanity_checks()

    # Freeze non-orchagent components first
    for c in ["syncd", "neighsyncd", "fdbsyncd", "teamd", "vxlanmgrd"]:
        proto.component_receive_freeze(c)
    for c in ["syncd", "neighsyncd", "fdbsyncd", "teamd", "vxlanmgrd"]:
        proto.component_quiesce(c)

    # Orchagent freeze protocol WITH TOCTOU events
    proto.component_receive_freeze("orchagent")
    proto.orch_check_ready()
    proto.orch_send_ready_reply()   # READY sent — TOCTOU window opens

    # 2 events arrive in the TOCTOU window
    time.sleep(0.002)
    proto.event_arrival_after_ready()
    time.sleep(0.001)
    proto.event_arrival_after_ready()

    # Drain ring buffer — spec allows one drain (ReadyReplied -> Draining)
    # then OrchFreeze fires from Draining state.
    # The second event remains pending — THIS IS THE BUG (Family 2).
    proto.orch_drain_ring_buffer()  # pending: 2 -> 1, state: Draining

    # Freeze with 1 event still pending — checkpoint will capture inconsistent state
    proto.orch_freeze()

    # Checkpoint + reboot
    _checkpoint_and_reboot(proto)

    # --- Post-reboot reconciliation (abbreviated) ---
    proto.orch_warm_restore()
    proto.orch_send_apply_view()
    proto.syncd_receive_init_view()
    proto.apply_view_stage1()
    proto.apply_view_stage2()
    proto.apply_view_complete()
    proto.orch_reconcile_complete()

    # Reconcile remaining components
    for c in ["teamd", "syncd", "neighsyncd", "vxlanmgrd", "fdbsyncd"]:
        proto.component_start_reconcile_timer(c, 1)
        proto.component_read_table(c)
        proto.replay_entry(c, "k1", CacheState.SAME)
        proto.replay_entry(c, "k2", CacheState.SAME)
        proto.tick_timers()
        proto.reconcile_timer_fire(c)
        proto.reconcile_component(c)

    tw.close()
    return "toctou_race"


# ===========================================================================
# Scenario 3: APPLY_VIEW Stage 2 Failure (Family 3)
# ===========================================================================

def scenario_apply_view_fail():
    """Family 3: APPLY_VIEW Stage 2 failure — ASIC partially updated.

    Reference: Syncd.cpp:4904-4907 executeOperationsOnAsic() can throw.
    Bug: After Stage 2 begins, ASIC operations are destructive with no
    rollback. If they fail, ASIC is in inconsistent state.
    Code acknowledges this: Syncd.cpp:4797-4799.
    """
    tw = TraceWriter(os.path.join(TRACE_DIR, "apply_view_fail.ndjson"))
    tw.emit_config({
        "scenario": "apply_view_fail",
        "bug_family": 3,
        "description": "APPLY_VIEW Stage 2 failure — ASIC inconsistent",
    })
    proto = WarmRebootProtocol(tw)

    # Standard shutdown
    proto.start_warm_reboot()
    proto.complete_sanity_checks()
    for c in ["syncd", "neighsyncd", "fdbsyncd", "teamd", "vxlanmgrd"]:
        proto.component_receive_freeze(c)
    for c in ["syncd", "neighsyncd", "fdbsyncd", "teamd", "vxlanmgrd"]:
        proto.component_quiesce(c)
    _orchagent_freeze_protocol(proto)
    _checkpoint_and_reboot(proto)

    # Post-reboot: orchagent restore
    proto.orch_warm_restore()
    proto.orch_send_apply_view()

    # Syncd APPLY_VIEW — Stage 1 succeeds, Stage 2 FAILS
    proto.syncd_receive_init_view()
    proto.apply_view_stage1()
    proto.apply_view_stage2()          # Destructive operations begin
    proto.apply_view_stage2_fail()     # ASIC partially updated!

    tw.close()
    return "apply_view_fail"


# ===========================================================================
# Scenario 4: Timer Race (Family 4)
# Reconcile timer fires before all entries replayed
# ===========================================================================

def scenario_timer_race():
    """Family 4: Timer race — reconcile fires before entries replayed.

    Reference: neighsyncd.cpp:62 — timer starts before netlink dump (line 67).
    Bug: Timer can fire before all entries arrive from netlink.
    warmRestartAssist.cpp:258-306 reconcile() deletes STALE entries,
    which may be entries whose replay hasn't arrived yet.
    """
    tw = TraceWriter(os.path.join(TRACE_DIR, "timer_race.ndjson"))
    tw.emit_config({
        "scenario": "timer_race",
        "bug_family": 4,
        "description": "Reconcile timer fires before all entries replayed",
    })
    proto = WarmRebootProtocol(tw)

    # Standard shutdown + reboot
    proto.start_warm_reboot()
    proto.complete_sanity_checks()
    for c in ["syncd", "neighsyncd", "fdbsyncd", "teamd", "vxlanmgrd"]:
        proto.component_receive_freeze(c)
    for c in ["syncd", "neighsyncd", "fdbsyncd", "teamd", "vxlanmgrd"]:
        proto.component_quiesce(c)
    _orchagent_freeze_protocol(proto)
    _checkpoint_and_reboot(proto)

    # Orchagent restore + APPLY_VIEW success
    proto.orch_warm_restore()
    proto.orch_send_apply_view()
    proto.syncd_receive_init_view()
    proto.apply_view_stage1()
    proto.apply_view_stage2()
    proto.apply_view_complete()
    proto.orch_reconcile_complete()

    # neighsyncd: timer with value 1 — fires FAST
    # Reference: neighsyncd.cpp:62 — timer start
    proto.component_start_reconcile_timer("neighsyncd", 1)
    proto.component_read_table("neighsyncd")

    # Only replay k1 before timer fires — k2 is still STALE
    proto.replay_entry("neighsyncd", "k1", CacheState.SAME)

    # Timer fires before k2 is replayed!
    proto.tick_timers()     # timer: 1 -> 0
    time.sleep(0.001)
    proto.reconcile_timer_fire("neighsyncd")

    # Reconcile: k2 is still STALE, will be DELETED (Family 4 bug)
    proto.reconcile_component("neighsyncd")

    # Reconcile other components normally
    for c in ["teamd", "syncd", "vxlanmgrd"]:
        proto.component_start_reconcile_timer(c, 2)
        proto.component_read_table(c)
        proto.replay_entry(c, "k1", CacheState.SAME)
        proto.replay_entry(c, "k2", CacheState.SAME)
        proto.tick_timers()
        time.sleep(0.001)
        proto.tick_timers()
        proto.reconcile_timer_fire(c)
        proto.reconcile_component(c)

    # fdbsyncd
    proto.component_start_reconcile_timer("fdbsyncd", 2)
    proto.component_read_table("fdbsyncd")
    proto.replay_entry("fdbsyncd", "k1", CacheState.SAME)
    proto.replay_entry("fdbsyncd", "k2", CacheState.SAME)
    proto.tick_timers()
    time.sleep(0.001)
    proto.tick_timers()
    proto.reconcile_timer_fire("fdbsyncd")
    proto.reconcile_component("fdbsyncd")

    tw.close()
    return "timer_race"


# ===========================================================================
# Scenario 5: Ordering Violation (Family 1)
# vxlanmgrd declares RECONCILED prematurely
# ===========================================================================

def scenario_ordering_violation():
    """Family 1: Reconciliation ordering violation.

    Reference: vxlanmgrd declares RECONCILED on first SELECT_TIMEOUT (1s)
    with no content verification. fdbsyncd then starts reconciling before
    VXLAN tunnels are actually restored.

    Bug: No prerequisite check in ReconcileComponent.
    Reference: orchdaemon.cpp:1132 — no ordering barrier.
    """
    tw = TraceWriter(os.path.join(TRACE_DIR, "ordering_violation.ndjson"))
    tw.emit_config({
        "scenario": "ordering_violation",
        "bug_family": 1,
        "description": "vxlanmgrd reconciles prematurely, fdbsyncd sees stale VXLAN state",
    })
    proto = WarmRebootProtocol(tw)

    # Standard shutdown + reboot
    proto.start_warm_reboot()
    proto.complete_sanity_checks()
    for c in ["syncd", "neighsyncd", "fdbsyncd", "teamd", "vxlanmgrd"]:
        proto.component_receive_freeze(c)
    for c in ["syncd", "neighsyncd", "fdbsyncd", "teamd", "vxlanmgrd"]:
        proto.component_quiesce(c)
    _orchagent_freeze_protocol(proto)
    _checkpoint_and_reboot(proto)

    # Orchagent restore + APPLY_VIEW success
    proto.orch_warm_restore()
    proto.orch_send_apply_view()
    proto.syncd_receive_init_view()
    proto.apply_view_stage1()
    proto.apply_view_stage2()
    proto.apply_view_complete()
    proto.orch_reconcile_complete()

    # teamd reconciles first (no dependencies)
    proto.component_start_reconcile_timer("teamd", 1)
    proto.component_read_table("teamd")
    proto.replay_entry("teamd", "k1", CacheState.SAME)
    proto.replay_entry("teamd", "k2", CacheState.SAME)
    proto.tick_timers()
    proto.reconcile_timer_fire("teamd")
    proto.reconcile_component("teamd")

    # syncd reconciles
    proto.component_start_reconcile_timer("syncd", 1)
    proto.component_read_table("syncd")
    proto.replay_entry("syncd", "k1", CacheState.SAME)
    proto.replay_entry("syncd", "k2", CacheState.SAME)
    proto.tick_timers()
    proto.reconcile_timer_fire("syncd")
    proto.reconcile_component("syncd")

    # vxlanmgrd: reconciles WITHOUT timer (Family 1 bug)
    # Reference: vxlanmgrd declares RECONCILED on SELECT_TIMEOUT
    proto.component_start_reconcile_timer("vxlanmgrd", 1)
    proto.component_read_table("vxlanmgrd")
    # vxlanmgrd doesn't wait for entries — declares reconciled immediately
    proto.reconcile_component_without_timer("vxlanmgrd")

    # neighsyncd reconciles (depends on orchagent + teamd, both done)
    proto.component_start_reconcile_timer("neighsyncd", 2)
    proto.component_read_table("neighsyncd")
    proto.replay_entry("neighsyncd", "k1", CacheState.SAME)
    proto.replay_entry("neighsyncd", "k2", CacheState.NEW)
    proto.tick_timers()
    time.sleep(0.001)
    proto.tick_timers()
    proto.reconcile_timer_fire("neighsyncd")
    proto.reconcile_component("neighsyncd")

    # fdbsyncd reconciles — depends on neighsyncd + vxlanmgrd
    # vxlanmgrd is "reconciled" but VXLAN tunnels aren't actually ready!
    proto.component_start_reconcile_timer("fdbsyncd", 2)
    proto.component_read_table("fdbsyncd")
    proto.replay_entry("fdbsyncd", "k1", CacheState.NEW)
    proto.replay_entry("fdbsyncd", "k2", CacheState.SAME)
    proto.tick_timers()
    time.sleep(0.001)
    proto.tick_timers()
    proto.reconcile_timer_fire("fdbsyncd")
    proto.reconcile_component("fdbsyncd")

    tw.close()
    return "ordering_violation"


# ===========================================================================
# Main: run all scenarios
# ===========================================================================

ALL_SCENARIOS = [
    ("happy_path", scenario_happy_path),
    ("toctou_race", scenario_toctou_race),
    ("apply_view_fail", scenario_apply_view_fail),
    ("timer_race", scenario_timer_race),
    ("ordering_violation", scenario_ordering_violation),
]


def main():
    os.makedirs(TRACE_DIR, exist_ok=True)
    results = []
    for name, fn in ALL_SCENARIOS:
        try:
            fn()
            trace_file = os.path.join(TRACE_DIR, f"{name}.ndjson")
            count = sum(1 for _ in open(trace_file))
            results.append((name, "OK", count))
            print(f"  {name}: {count} lines")
        except Exception as e:
            results.append((name, "FAIL", str(e)))
            print(f"  {name}: FAILED — {e}")
            import traceback
            traceback.print_exc()

    print()
    ok = sum(1 for _, s, _ in results if s == "OK")
    print(f"Scenarios: {ok}/{len(results)} passed")
    return 0 if ok == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
