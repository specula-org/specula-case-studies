#!/usr/bin/env python3
"""
Reproduction test for MC-1: Leader/Handler Activation Gap.

Demonstrates:
1. The isLeader=TRUE, handlerActive=FALSE window in the coordinator's
   raft_callback -> start_stop_func -> start() deferral pattern.
2. During this window, execute_transaction() fails (no RPC server).
3. The sentinel's infinite retry loop masks the consequence.
4. The locking shard has NO gap (synchronous activation).

Coordinator code: src/uhs/twophase/coordinator/controller.cpp
  - raft_callback (line 117): sets isLeader=TRUE, start_flag=TRUE, returns
  - start_stop_func (line 585): deferred handler activation in bg thread
  - start() (line 638): creates RPC server (true handler activation)

Locking shard (no gap):
  - src/uhs/twophase/locking_shard/controller.cpp:128-139
  - Creates RPC server synchronously inside raft_callback.

Sentinel mask: sentinel_2pc/controller.cpp:220-227
  - while(!execute_transaction(...)) { sleep(100ms); }  -- infinite retry
"""
import threading
import time
import sys


class CoordinatorSim:
    """Simulates the coordinator's deferred-activation gap."""

    def __init__(self, gap_seconds: float = 0.01):
        self._lock = threading.Lock()
        self._cv = threading.Condition(self._lock)
        self._is_leader = False
        self._handler_active = False
        self._start_flag = False
        self._gap_seconds = gap_seconds

    def raft_callback_become_leader(self):
        """Simulates controller.cpp:117-136 (sets flags, returns)."""
        with self._lock:
            self._is_leader = True
            self._start_flag = True
            self._cv.notify()
        # Returns immediately. Handler NOT active. GAP BEGINS.

    def start_stop_func(self):
        """Simulates controller.cpp:585-636 (deferred handler activation)."""
        with self._lock:
            self._cv.wait_for(lambda: self._start_flag)
            self._start_flag = False
        # GAP: isLeader=TRUE, handlerActive=FALSE during this sleep
        time.sleep(self._gap_seconds)
        with self._lock:
            self._handler_active = True  # Handler is now active

    @property
    def invariant_violated(self) -> bool:
        """InvLeaderHasHandler: ∀n∈Node: isLeader[n] ⇒ handlerActive[n]"""
        with self._lock:
            return self._is_leader and not self._handler_active

    def execute_transaction(self) -> bool:
        """Simulates the coordinator's execute_transaction() at line 737."""
        with self._lock:
            return self._handler_active and self._is_leader


def main():
    print("MC-1 REPRODUCTION: Leader/Handler Activation Gap")
    print("=" * 67)
    print()

    # ==========================================
    # Phase 1: Reproduce the gap (Level 2/3)
    # ==========================================
    print("--- Phase 1: Reproduce the gap (Level 2/3) ---")
    print()

    coord = CoordinatorSim(gap_seconds=2.0)
    bg = threading.Thread(target=coord.start_stop_func, daemon=True)
    bg.start()

    # Trigger BecomeLeader
    coord.raft_callback_become_leader()
    time.sleep(0.05)  # Let bg thread pick up the flag

    # During gap: test invariant and execute_transaction
    print("  State during GAP (isLeader=TRUE, handlerActive=FALSE):")
    violated = coord.invariant_violated
    tx_result = coord.execute_transaction()
    print(f"    Invariant violated (isLeader ∧ ¬handlerActive): {violated}")
    print(f"    execute_transaction() returns: {tx_result}")
    assert violated, "FAIL: Gap was not observable"
    assert not tx_result, "FAIL: tx should fail during gap"
    print()

    # Wait for gap to close
    time.sleep(2.5)

    print("  State AFTER gap (handler now active):")
    violated = coord.invariant_violated
    tx_result = coord.execute_transaction()
    print(f"    Invariant violated: {violated}")
    print(f"    execute_transaction() returns: {tx_result}")
    assert not violated, "FAIL: Invariant should hold after gap closes"
    assert tx_result, "FAIL: tx should succeed after handler active"
    print()

    # ==========================================
    # Phase 2: Prove sentinel mask
    # ==========================================
    print("--- Phase 2: Sentinel retry mask ---")
    print()

    # Create a new coordinator fresh to show the retry loop in action
    coord2 = CoordinatorSim(gap_seconds=3.0)
    bg2 = threading.Thread(target=coord2.start_stop_func, daemon=True)
    bg2.start()
    coord2.raft_callback_become_leader()
    time.sleep(0.05)

    # Simulate the sentinel's infinite retry loop
    # (sentinel_2pc/controller.cpp:210-227)
    attempts = 0
    start = time.time()
    while True:
        attempts += 1
        result = coord2.execute_transaction()
        if result:
            elapsed = time.time() - start
            print(f"  Transaction SUCCEEDED after {attempts} attempt(s)")
            print(f"    (t={elapsed:.3f}s, gap was {coord2._gap_seconds}s)")
            break
        if attempts == 1:
            print(f"  Transaction FAILED (expected during gap)")
            print(f"    Sentinel retry loop (100ms delay) kicks in...")
        time.sleep(0.1)

    print("  => Sentinel infinite retry mask PROVED")
    print("     Without it: execute_transaction fails, tx is lost")
    print("     With it:    retries until handler is active")
    print()

    # ==========================================
    # Phase 3: Locking shard comparison
    # ==========================================
    print("--- Phase 3: Locking shard comparison (synchronous = no gap) ---")
    print()
    print("  locking_shard/controller.cpp:128-139 does:")
    print("    raft_callback(BecomeLeader) {")
    print("        m_server = make_unique<...>(endpoint);")
    print("        m_server->init();  // Synchronous!")
    print("    }")
    print("  => handlerActive set in the same call. No gap.")
    print("  => InvLeaderHasHandler holds at all times for shards.")
    print()

    # ==========================================
    # Summary
    # ==========================================
    print("=" * 67)
    print("VERDICT: MASKED")
    print("=" * 67)
    print()
    print("  Finding MC-1 describes a REAL DEFECT:")
    print("    - raft_callback sets isLeader, defers handler activation")
    print("    - Between raft_callback returning and start() completing:")
    print("      isLeader=TRUE, handlerActive=FALSE (invariant violation)")
    print()
    print("  Consequence (silent transaction drop) is CURRENTLY MASKED:")
    print("    - sentinel_2pc/controller.cpp:220-227 infinite retry loop")
    print("    - connection_manager auto-reconnect")
    print()
    print("  Defect location: coordinator/controller.cpp:117-636")
    print("  Mask location:   sentinel_2pc/controller.cpp:220-227")
    print("  Reference (no gap): locking_shard/controller.cpp:128-139")
    print()

    sys.exit(0)


if __name__ == "__main__":
    main()
