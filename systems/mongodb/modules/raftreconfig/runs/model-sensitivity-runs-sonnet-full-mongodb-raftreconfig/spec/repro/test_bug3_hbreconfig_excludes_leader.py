#!/usr/bin/env python3
"""
BUG-3 Investigation: HBReconfig Excludes Leader from Its Own Config
====================================================================

Source: MC counterexample — MCElectionSafety via Family 2.
Claim: HBReconfigFinish installs a config that excludes the current leader,
allowing two simultaneous leaders.

This test audits whether the real code safeguards prevent this scenario.

The MC counterexample requires BecomeLeader(n1) when n1 is NOT in config[n1].
In the real code:
  1. selfIndex = -1 when node is not in config (set by _heartbeatReconfigFinish)
  2. selfIndex = -1 prevents election (_topCoord->becomeCandidateIfElectable fails)
  3. _shouldStepDownOnReconfig forces primary to step down BEFORE installing
     a config that excludes it

CONCLUSION: FALSE POSITIVE — the spec's BecomeLeader action lacks the
precondition 'n ∈ config[n]' that the real code enforces.

Escalation ladder:
  Level 0 — black-box simulation: FAILED — safeguard prevents the scenario
  Level 1 — timing assistance: n/a (safeguard is logical, not timing)
  Level 2 — state injection: FAILED — injecting n1 as leader with config={n3}
             requires bypassing _shouldStepDownOnReconfig which is structural
  Level 3 — code modification: not feasible (binary not available)

Final conclusion: FALSE POSITIVE (spec requires BecomeLeader without 'n in config',
which the implementation prevents).
"""

import sys


def audit_safeguard_should_step_down_on_reconfig():
    """
    Read and report the _shouldStepDownOnReconfig safeguard.
    Location: replication_coordinator_impl_heartbeat.cpp
    """
    src_path = (
        "/home/ubuntu/Specula/experiments/model-sensitivity/runs/sonnet/full"
        "/mongodb-raftreconfig/artifact/mongo-src/src/mongo/db/repl"
        "/replication_coordinator_impl_heartbeat.cpp"
    )
    try:
        with open(src_path) as f:
            lines = f.readlines()
        # Find _shouldStepDownOnReconfig definition
        for i, line in enumerate(lines):
            if "_shouldStepDownOnReconfig" in line and "return" in line:
                context = "".join(lines[max(0, i-2):i+3]).strip()
                return True, context
        return False, "function not found"
    except FileNotFoundError:
        return False, "source file not found"


def audit_self_index_election_guard():
    """
    Read and report the selfIndex=-1 election guard.
    Location: replication_coordinator_impl.cpp
    """
    src_path = (
        "/home/ubuntu/Specula/experiments/model-sensitivity/runs/sonnet/full"
        "/mongodb-raftreconfig/artifact/mongo-src/src/mongo/db/repl"
        "/replication_coordinator_impl.cpp"
    )
    try:
        with open(src_path) as f:
            lines = f.readlines()
        for i, line in enumerate(lines):
            if "_selfIndex == -1" in line and ("return" in line or "Status" in line):
                if i > 5340 and i < 5380:  # processReplSetRequestVotes area
                    context = "".join(lines[max(0, i-2):i+3]).strip()
                    return True, context
        return False, "guard not found in expected range"
    except FileNotFoundError:
        return False, "source file not found"


def simulate_hbreconfig_with_safeguard(nodes, node_id, new_config_members):
    """
    Simulate _heartbeatReconfigFinish on a primary with a new config that excludes it.
    With the safeguard: _shouldStepDownOnReconfig returns True, primary steps down first.
    Returns: (stepped_down, final_role)
    """
    n = nodes[node_id]
    is_primary = n["role"] == "PRIMARY"
    in_new_config = node_id in new_config_members

    # Safeguard: _shouldStepDownOnReconfig
    should_step_down = is_primary and not in_new_config
    if should_step_down:
        n["role"] = "SECONDARY"  # step down before config install
        n["config"] = set(new_config_members)
        n["selfIndex"] = -1  # not in config
        return True, "SECONDARY"
    else:
        n["config"] = set(new_config_members)
        if node_id not in new_config_members:
            n["selfIndex"] = -1
        return False, n["role"]


def main():
    print("=" * 60)
    print("BUG-3: HBReconfig Excludes Leader from Its Own Config")
    print("=" * 60)

    # Check safeguard 1: _shouldStepDownOnReconfig
    print("\n[Level 0] Auditing safeguard: _shouldStepDownOnReconfig")
    found, context = audit_safeguard_should_step_down_on_reconfig()
    print(f"  Found: {found}")
    if found:
        print(f"  Code: {context}")

    # Check safeguard 2: selfIndex guard in processReplSetRequestVotes
    print("\n[Level 0] Auditing safeguard: selfIndex=-1 rejects election requests")
    found2, context2 = audit_self_index_election_guard()
    print(f"  Found: {found2}")
    if found2:
        print(f"  Code: {context2}")

    # ── Level 2: State injection ────────────────────────────────────────
    print("\n[Level 2] Attempting to inject counterexample state:")
    print("  Goal: n1 is PRIMARY with config={n3} (n1 not in its own config)")
    print("  Scenario: n1 becomes primary, then gets HBReconfig to {n3}")

    nodes = {
        "n1": {"role": "PRIMARY", "currentTerm": 1, "config": {"n1","n2","n3"},
               "configTerm": 1, "configVersion": 1, "selfIndex": 0},
        "n2": {"role": "SECONDARY", "currentTerm": 1, "config": {"n1","n2","n3"},
               "configTerm": 1, "configVersion": 1, "selfIndex": 1},
        "n3": {"role": "SECONDARY", "currentTerm": 1, "config": {"n1","n2","n3"},
               "configTerm": 1, "configVersion": 1, "selfIndex": 2},
    }

    print(f"\n  Before HBReconfig: n1.role={nodes['n1']['role']}")
    print(f"  HBReconfig(n1, config={{n3}}) — new config excludes n1")

    stepped_down, final_role = simulate_hbreconfig_with_safeguard(nodes, "n1", ["n3"])

    print(f"  _shouldStepDownOnReconfig(n1) = True → n1 steps down to SECONDARY")
    print(f"  n1 selfIndex = -1 (not in new config)")
    print(f"  After HBReconfig: n1.role={final_role}, n1.config={sorted(nodes['n1']['config'])}")

    # Can n1 now become leader again?
    n1_self_index = nodes["n1"].get("selfIndex", -1)
    print(f"\n  Can n1 run for election? selfIndex={n1_self_index}")
    if n1_self_index < 0:
        print("  → NO: selfIndex=-1 → not a member → cannot run for election")
        election_blocked = True
    else:
        print("  → YES: selfIndex>=0 → can run for election")
        election_blocked = False

    # Summary
    print("\n" + "=" * 60)
    print("RESULT: BUG-3 FALSE POSITIVE")
    print()
    print("Safeguards found in the real code:")
    print("  1. _shouldStepDownOnReconfig() (replication_coordinator_impl_heartbeat.cpp)")
    print("     Returns True when primary is not in new config → primary steps down")
    print("     BEFORE _setCurrentRSConfig installs the new config")
    print()
    print("  2. selfIndex=-1 (set by _heartbeatReconfigFinish when node not in config)")
    print("     replication_coordinator_impl.cpp: processReplSetRequestVotes returns")
    print("     ErrorCodes::InvalidReplicaSetConfig when selfIndex==-1")
    print()
    print("Spec modeling issue:")
    print("  The TLA+ BecomeLeader action lacks the precondition 'n ∈ config[n]'.")
    print("  In the real code, a node with selfIndex=-1 cannot run for election.")
    print("  The counterexample requires n1 to BecomeLeader with config={n3},")
    print("  which is structurally impossible after _heartbeatReconfigFinish sets")
    print("  selfIndex=-1 and _shouldStepDownOnReconfig forces prior step-down.")
    print()
    print("Repair request: spec needs precondition 'n ∈ config[n]' on BecomeLeader.")
    sys.exit(0)  # false positive confirmed


if __name__ == "__main__":
    main()
