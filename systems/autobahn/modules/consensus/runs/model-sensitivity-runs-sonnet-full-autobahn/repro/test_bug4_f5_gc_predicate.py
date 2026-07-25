#!/usr/bin/env python3
"""
BUG-F5 Reproduction: Inverted GC Predicate in clean_slot_periods
File: primary/src/core.rs:1711-1716

The buggy predicate: s % k != slot_period && s <= slot
  (De Morgan complement of the intended one)

The correct predicate: s % k != slot_period || s > slot
  (keep entries in a different pipeline lane, OR keep future entries in the same lane)

After committing slot S, the buggy code drops ALL future consensus instances,
including active instances in other pipeline lanes — corrupting liveness.
"""

import sys


def buggy_retain(s: int, k: int, slot_period: int, committed_slot: int) -> bool:
    """Actual buggy predicate from primary/src/core.rs:1711."""
    return (s % k != slot_period) and (s <= committed_slot)


def correct_retain(s: int, k: int, slot_period: int, committed_slot: int) -> bool:
    """Intended correct predicate (fix: && → ||, <= → >)."""
    return (s % k != slot_period) or (s > committed_slot)


def run_test() -> bool:
    K = 2
    committed_slot = 1
    slot_period = committed_slot % K  # = 1

    # Active consensus instances: slot 1 is committed, slots 2 and 3 are in-flight
    active_slots = {1: "slot_1_instance", 2: "slot_2_instance", 3: "slot_3_instance"}

    print("=" * 60)
    print("BUG-F5 Reproduction: Inverted GC Predicate")
    print("=" * 60)
    print(f"K={K}, committed_slot={committed_slot}, slot_period={slot_period}")
    print(f"Active slots before GC: {sorted(active_slots.keys())}")
    print()

    # Expected behavior (correct predicate):
    kept_correct = {s: v for s, v in active_slots.items()
                    if correct_retain(s, K, slot_period, committed_slot)}
    dropped_correct = {s for s in active_slots if s not in kept_correct}
    print(f"CORRECT predicate (||): keeps {sorted(kept_correct)}, drops {sorted(dropped_correct)}")
    for s in sorted(active_slots):
        r = correct_retain(s, K, slot_period, committed_slot)
        lhs = f"{s}%{K}={s % K}≠{slot_period}"
        rhs = f"{s}>{committed_slot}"
        print(f"  slot {s}: ({lhs}) OR ({rhs}) = {r} → {'KEPT   ✓' if r else 'DROPPED ✓'}")

    print()

    # Actual buggy behavior:
    kept_buggy = {s: v for s, v in active_slots.items()
                  if buggy_retain(s, K, slot_period, committed_slot)}
    dropped_buggy = {s for s in active_slots if s not in kept_buggy}
    print(f"BUGGY predicate (&&):  keeps {sorted(kept_buggy)}, drops {sorted(dropped_buggy)}")
    for s in sorted(active_slots):
        r = buggy_retain(s, K, slot_period, committed_slot)
        lhs = f"{s}%{K}={s % K}≠{slot_period}"
        rhs = f"{s}≤{committed_slot}"
        status = "KEPT ?" if r else "DROPPED ✗"
        wrong = "" if r == correct_retain(s, K, slot_period, committed_slot) else " ← WRONG!"
        print(f"  slot {s}: ({lhs}) AND ({rhs}) = {r} → {status}{wrong}")

    print()
    print("=" * 60)
    print("VERDICT")
    print("=" * 60)

    # The bug: slots 2 and 3 are active in-flight instances that should be KEPT
    bug_confirmed = (
        len(kept_buggy) == 0 and       # buggy predicate drops everything
        len(kept_correct) == 2 and     # correct predicate keeps slots 2 and 3
        2 in kept_correct and
        3 in kept_correct
    )

    if bug_confirmed:
        print("BUG-F5 CONFIRMED: The inverted predicate drops ALL instances!")
        print()
        print("  Slot 1 (committed, same lane: 1%2=1=slot_period):   correctly dropped")
        print("  Slot 2 (different lane, future: 2%2=0≠1, 2>1):      WRONGLY dropped!")
        print("  Slot 3 (same lane, future: 3%2=1=slot_period, 3>1): WRONGLY dropped!")
        print()
        print(f"  After GC: {len(kept_buggy)} instances remain (expected {len(kept_correct)})")
        print()
        print("Root cause (primary/src/core.rs:1711):")
        print("  BUGGY:   s % k != slot_period && s <= &slot")
        print("  CORRECT: s % k != slot_period || s > &slot")
        print()
        print("Impact: After every slot commit, ALL future pipeline instances are silently")
        print("purged — both same-lane and different-lane. This causes complete liveness")
        print("failure for all in-flight consensus instances beyond the committed slot.")
        return True
    else:
        print(f"Bug NOT reproduced as expected.")
        print(f"kept_buggy={sorted(kept_buggy)}, kept_correct={sorted(kept_correct)}")
        return False


if __name__ == "__main__":
    ok = run_test()
    sys.exit(0 if ok else 1)
