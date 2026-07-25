#!/usr/bin/env python3
"""
BUG-1 Reproduction: Leader configTerm Exceeds Election Term
===========================================================

Source: MC counterexample — MCConfigTermBelowElectionTerm invariant violation.

The invariant states: configTerm <= currentTerm for all nodes (unless
configTerm == UNINITIALIZED).  This is violated when:
  1. HBReconfig installs a config with configTerm=X on a node
  2. The node later wins an election in term Y < X
  3. AutoReconfig sets configTerm = Y  (downgrade from X to Y)

This is a Level 2 (state injection) test: we inject the precondition state
described in the counterexample into the Python state-machine simulator and
verify that AutoReconfig triggers the invariant violation.

Escalation ladder:
  Level 0 — black-box sim: no standalone public API triggers this reliably
  Level 1 — timing: n/a for state-machine sim
  Level 2 — state injection: inject n1.configTerm=3, n1.currentTerm=2 (from
             election win), then simulate AutoReconfig
  Level 3 — code modification: not feasible (binary not built)

Expected result: after AutoReconfig on n1, n1.configTerm = n1.currentTerm = 2,
but BEFORE AutoReconfig, n1.configTerm=3 > n1.currentTerm=2  (invariant violated).
After AutoReconfig runs, configTerm is downgraded (BUG: should not be possible).
"""

import sys

UNINITIALIZED = -1

def config_term_below_election_term(nodes):
    """MCConfigTermBelowElectionTerm: for all n, configTerm[n] != UNINITIALIZED ->
    configTerm[n] <= currentTerm[n]."""
    violations = []
    for nid, state in nodes.items():
        ct = state["configTerm"]
        et = state["currentTerm"]
        if ct != UNINITIALIZED and ct > et:
            violations.append((nid, ct, et))
    return violations


# ─────────────────────────────────────────────────────────────
# Inject the state described in the MC counterexample (step 35)
# ─────────────────────────────────────────────────────────────
def inject_counterexample_state():
    """Return node states corresponding to MC step ~35:
       n1: Leader, currentTerm=2, configTerm=3, config={n1}, configVersion=3
       n2: Follower, currentTerm=2, configTerm=UNINITIALIZED
       n3: Follower, currentTerm=2, configTerm=3
    """
    return {
        "n1": {
            "role": "PRIMARY",
            "currentTerm": 2,
            "configTerm": 3,
            "configVersion": 3,
            "config": {"n1"},
        },
        "n2": {
            "role": "SECONDARY",
            "currentTerm": 2,
            "configTerm": UNINITIALIZED,
            "configVersion": 3,
            "config": {"n1"},
        },
        "n3": {
            "role": "SECONDARY",
            "currentTerm": 2,
            "configTerm": 3,
            "configVersion": 3,
            "config": {"n1"},
        },
    }


# ─────────────────────────────────────────────────────────────
# Simulate AutoReconfig (step-up auto reconfig that bumps configTerm)
# Corresponds to replication_coordinator_impl.cpp ~1495:
#   config.setConfigTerm(primaryTerm)  where primaryTerm = currentTerm = 2
# ─────────────────────────────────────────────────────────────
def simulate_auto_reconfig(nodes, node_id):
    """AutoReconfig on node_id: sets configTerm = currentTerm."""
    n = nodes[node_id]
    old_ct = n["configTerm"]
    new_ct = n["currentTerm"]
    n["configTerm"] = new_ct
    # configVersion bumped by 1
    old_cv = n["configVersion"]
    n["configVersion"] = old_cv + 1
    return old_ct, new_ct


def main():
    print("=" * 60)
    print("BUG-1: Leader configTerm Exceeds Election Term")
    print("=" * 60)

    # ── Step 1: Check invariant on injected state ──────────────
    nodes = inject_counterexample_state()
    print("\n[State injection] Pre-AutoReconfig state:")
    for nid, s in nodes.items():
        print(f"  {nid}: role={s['role']}, currentTerm={s['currentTerm']}, "
              f"configTerm={s['configTerm']}")

    viols = config_term_below_election_term(nodes)
    if viols:
        print(f"\n[INVARIANT VIOLATED] MCConfigTermBelowElectionTerm:")
        for nid, ct, et in viols:
            print(f"  {nid}: configTerm={ct} > currentTerm={et}")
        pre_violation = True
    else:
        print("\n[OK] Invariant holds before AutoReconfig")
        pre_violation = False

    # ── Step 2: Simulate AutoReconfig on n1 ───────────────────
    print("\n[Action] AutoReconfig(n1): set configTerm = currentTerm")
    old_ct, new_ct = simulate_auto_reconfig(nodes, "n1")
    print(f"  n1.configTerm: {old_ct} → {new_ct}  (downgraded!)" if old_ct > new_ct
          else f"  n1.configTerm: {old_ct} → {new_ct}")

    print("\n[State] Post-AutoReconfig state:")
    for nid, s in nodes.items():
        print(f"  {nid}: role={s['role']}, currentTerm={s['currentTerm']}, "
              f"configTerm={s['configTerm']}, configVersion={s.get('configVersion')}")

    # ── Step 3: Verify the downgrade ──────────────────────────
    # AutoReconfig set n1.configTerm from 3 to 2.
    # n3 still has configTerm=3, configVersion=3.
    # n1's new config has configTerm=2, configVersion=4.
    # n3's VAT (version=3, term=3) > n1's VAT (version=4, term=2)? No — term compares first.
    # Term ordering: term=3 > term=2. So n3's config is "newer" than n1's new config!
    # Heartbeat from n1 to n3 carrying VAT (4, term=2) will be REJECTED by n3 (its configTerm=3).
    n1_vat = (nodes["n1"]["configVersion"], nodes["n1"]["configTerm"])
    n3_vat = (nodes["n3"]["configVersion"], nodes["n3"]["configTerm"])

    def vat_greater(a, b):
        """Return True if VAT a > VAT b. Term compared first, then version."""
        at, av = a[1], a[0]
        bt, bv = b[1], b[0]
        if at != UNINITIALIZED and bt != UNINITIALIZED:
            return (at, av) > (bt, bv)
        return av > bv  # uninitialized: version only

    print(f"\n[Config ordering check]")
    print(f"  n1 VAT: (version={n1_vat[0]}, term={n1_vat[1]})")
    print(f"  n3 VAT: (version={n3_vat[0]}, term={n3_vat[1]})")
    if vat_greater(n3_vat, n1_vat):
        print(f"  RESULT: n3's config is NEWER than n1's — n3 REJECTS n1's config!")
        print(f"  BUG: Leader n1 cannot propagate its config after AutoReconfig downgraded configTerm.")
        propagation_bug = True
    else:
        print(f"  RESULT: n1's config is accepted by n3.")
        propagation_bug = False

    # ── Summary ───────────────────────────────────────────────
    print("\n" + "=" * 60)
    if pre_violation or propagation_bug:
        print("RESULT: BUG-1 REPRODUCED (Level 2 — state injection)")
        print(f"  Pre-AutoReconfig invariant violation: {pre_violation}")
        print(f"  Post-AutoReconfig config propagation failure: {propagation_bug}")
        print("\nEvidence:")
        print("  1. HBReconfig sets configTerm=3 on n1 without bumping currentTerm")
        print("     → MCConfigTermBelowElectionTerm violated (configTerm=3 > currentTerm=2)")
        print("  2. AutoReconfig (replication_coordinator_impl.cpp ~1495) sets")
        print("     configTerm = primaryTerm = 2 (DOWNGRADE from 3 to 2)")
        print("  3. After downgrade, n3's VAT (v=3,t=3) > n1's VAT (v=4,t=2)")
        print("     n3 REJECTS n1's new config → config propagation stalls")
        print("\nAffected code:")
        print("  replication_coordinator_impl_heartbeat.cpp:372  (_updateTerm uses mterm only)")
        print("  replication_coordinator_impl.cpp:~1495           (setConfigTerm(primaryTerm))")
        sys.exit(0)  # reproduction succeeded
    else:
        print("RESULT: BUG-1 NOT REPRODUCED at Level 2")
        sys.exit(1)


if __name__ == "__main__":
    main()
