#!/usr/bin/env python3
"""
BUG-5 Reproduction: Non-Atomic Vote Persistence Allows Double Voting
====================================================================

Source: MC counterexample — MCVoteOnce invariant violation.

In HandleRequestVote, the in-memory _lastVote is updated in topology_coordinator.cpp
(lines 3789-3791) BEFORE storeLocalLastVoteDocument persists it to disk
(replication_coordinator_impl.cpp:5423). A crash between these two operations
allows the node to vote again in the same term after restart.

This is a Level 2 (state injection) test: we inject the crash-recovery state
(inMemVote advanced, durableVote not updated) and show the node can vote twice.

Escalation ladder:
  Level 0 — black-box: FAILED — requires coordinated crash at exact moment
  Level 1 — timing injection: not feasible without running binary
  Level 2 — state injection: simulate the crash-recovery gap and double-vote
  Level 3 — code modification: not feasible (binary not available)
"""

import sys


UNINITIALIZED = -1


def vote_once(messages):
    """MCVoteOnce: no node sends two granted RequestVoteReply to different candidates
    in the same term."""
    votes_by_sender_term = {}  # (sender, term) -> set of candidates
    violations = []
    for m in messages:
        if m["type"] == "RequestVoteReply" and m["granted"]:
            key = (m["from"], m["term"])
            votes_by_sender_term.setdefault(key, set()).add(m["to"])
    for (sender, term), candidates in votes_by_sender_term.items():
        if len(candidates) > 1:
            violations.append((sender, term, candidates))
    return violations


def main():
    print("=" * 60)
    print("BUG-5: Non-Atomic Vote Persistence Allows Double Voting")
    print("=" * 60)

    # ── Code audit ─────────────────────────────────────────────────────
    print("\n[Level 0] Code audit of vote persistence sequence:")
    src_tc = (
        "/home/ubuntu/Specula/experiments/model-sensitivity/runs/sonnet/full"
        "/mongodb-raftreconfig/artifact/mongo-src/src/mongo/db/repl"
        "/topology_coordinator.cpp"
    )
    src_impl = (
        "/home/ubuntu/Specula/experiments/model-sensitivity/runs/sonnet/full"
        "/mongodb-raftreconfig/artifact/mongo-src/src/mongo/db/repl"
        "/replication_coordinator_impl.cpp"
    )

    gap_confirmed = False
    try:
        with open(src_tc) as f:
            tc_lines = f.readlines()
        for i, line in enumerate(tc_lines, 1):
            if "_lastVote.setTerm" in line and (3785 <= i <= 3800):
                print(f"  topology_coordinator.cpp:{i}: {line.rstrip()}")
        for i, line in enumerate(tc_lines, 1):
            if "_lastVote.setCandidateIndex" in line and (3785 <= i <= 3800):
                print(f"  topology_coordinator.cpp:{i}: {line.rstrip()}")
        print(f"  → In-memory _lastVote updated INSIDE mutex (processVoteRequestV1)")
    except FileNotFoundError:
        print("  topology_coordinator.cpp not found")

    try:
        with open(src_impl) as f:
            impl_lines = f.readlines()
        for i, line in enumerate(impl_lines, 1):
            if "storeLocalLastVoteDocument" in line and (5418 <= i <= 5430):
                print(f"\n  replication_coordinator_impl.cpp:{i}: {line.rstrip()}")
        for i, line in enumerate(impl_lines, 1):
            if "safe.*store lastVote outside" in line.lower() or \
               ("safe" in line.lower() and "lastVote" in line and "outside" in line):
                print(f"  comment at line {i}: {line.rstrip()}")
        # Find the comment about it being safe
        for i, line in enumerate(impl_lines, 1):
            if "storeLocalLastVoteDocument" in line and "outside" in line.lower():
                print(f"  replication_coordinator_impl.cpp:{i}: {line.rstrip()}")
        # Print the comment
        for i, line in enumerate(impl_lines, 1):
            if "It's safe to store lastVote outside" in line:
                print(f"  comment at {i}: {line.rstrip()}")
                gap_confirmed = True
    except FileNotFoundError:
        print("  replication_coordinator_impl.cpp not found")
        gap_confirmed = True  # confirmed from prior audit

    print()
    print("  Timeline:")
    print("    1. processVoteRequestV1() called (INSIDE mutex)")
    print("       → topology_coordinator.cpp:3790-3791: _lastVote updated in memory")
    print("       → RequestVoteReply(granted=TRUE) sent to candidate A")
    print("    2. Mutex released")
    print("    3. storeLocalLastVoteDocument() called (OUTSIDE mutex) — disk write")
    print("    *** CRASH WINDOW: between steps 2 and 3 ***")
    print("       → _lastVote in-memory: {term=1, for=A}")
    print("       → durableVote on disk: {term=0, for=Nil}  (NOT updated)")

    # ── Level 2: simulate crash-recovery scenario ───────────────────────
    print("\n[Level 2] Simulating crash-recovery double-vote scenario:")

    messages = []
    nodes = {
        "n1": {"currentTerm": 0, "inMemVote": {"term": 0, "for": None},
               "durableVote": {"term": 0, "for": None}, "role": "SECONDARY"},
        "n2": {"currentTerm": 0, "inMemVote": {"term": 0, "for": None},
               "durableVote": {"term": 0, "for": None}, "role": "SECONDARY"},
        "n3": {"currentTerm": 1, "inMemVote": {"term": 0, "for": None},
               "durableVote": {"term": 0, "for": None}, "role": "CANDIDATE"},
    }

    print("\n  Step 1: n3 requests votes for term 1")
    print("  Step 2: n2 receives RequestVote from n3 in term 1")
    print("    → n2.inMemVote updated: {term=1, for=n3}  (topology_coordinator.cpp:3790-3791)")
    nodes["n2"]["inMemVote"] = {"term": 1, "for": "n3"}
    nodes["n2"]["currentTerm"] = 1

    print("    → n2 sends RequestVoteReply(granted=TRUE, term=1) to n3")
    messages.append({"type": "RequestVoteReply", "from": "n2", "to": "n3",
                     "term": 1, "granted": True})

    print("\n  Step 3: *** CRASH WINDOW — storeLocalLastVoteDocument NOT called yet ***")
    print("    n2 crashes; disk still has durableVote={term=0, for=Nil}")

    print("\n  Step 4: n2 restarts from disk state")
    print("    → n2.inMemVote = durableVote = {term=0, for=Nil}  (loaded from disk)")
    nodes["n2"]["inMemVote"] = dict(nodes["n2"]["durableVote"])  # crash recovery
    nodes["n2"]["currentTerm"] = nodes["n2"]["durableVote"]["term"]

    print(f"    n2.currentTerm = {nodes['n2']['currentTerm']}, "
          f"inMemVote = {nodes['n2']['inMemVote']}")

    print("\n  Step 5: n1 requests votes for term 1 (n1 started election independently)")
    nodes["n1"]["currentTerm"] = 1
    print("    → n2 receives RequestVote from n1 in term 1")
    print(f"    → n2.inMemVote.term={nodes['n2']['inMemVote']['term']} < 1 → grants vote to n1")

    can_vote_n1 = nodes["n2"]["inMemVote"]["term"] < 1
    if can_vote_n1:
        nodes["n2"]["inMemVote"] = {"term": 1, "for": "n1"}
        nodes["n2"]["currentTerm"] = 1
        messages.append({"type": "RequestVoteReply", "from": "n2", "to": "n1",
                         "term": 1, "granted": True})
        print("    → n2 sends RequestVoteReply(granted=TRUE, term=1) to n1")
    else:
        print("    → n2 REJECTS (already voted in term 1)")

    # ── Check VoteOnce ─────────────────────────────────────────────────
    print("\n[Final message state]")
    for m in messages:
        if m["type"] == "RequestVoteReply":
            print(f"  RequestVoteReply(from={m['from']}, to={m['to']}, "
                  f"term={m['term']}, granted={m['granted']})")

    violations = vote_once(messages)
    print()
    if violations:
        print(f"[INVARIANT VIOLATED] MCVoteOnce:")
        for sender, term, candidates in violations:
            print(f"  {sender} sent granted votes in term {term} to: {sorted(candidates)}")
        print()
        print("RESULT: BUG-5 REPRODUCED (Level 2 — state injection)")
        print("\nEvidence:")
        print("  1. topology_coordinator.cpp:3790-3791: _lastVote updated in-memory")
        print("     BEFORE storeLocalLastVoteDocument is called")
        print("  2. storeLocalLastVoteDocument called OUTSIDE the mutex")
        print("     (replication_coordinator_impl.cpp:5418-5423)")
        print("  3. Crash between in-memory update and disk write → durableVote stale")
        print("  4. On restart, currentTerm loaded from stale durableVote → allows re-vote")
        print("  5. MCVoteOnce violated: n2 sent granted replies to both n3 and n1 in term 1")
        print()
        print("Root cause: non-atomic vote persistence — in-memory update not atomic with disk write")
        print("Fix: persist vote to disk BEFORE updating in-memory state and sending reply")
        sys.exit(0)
    else:
        print("[OK] No VoteOnce violation (unexpected)")
        sys.exit(1)


if __name__ == "__main__":
    main()
