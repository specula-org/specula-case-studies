# CometBFT Invariant Checking Log

## Model Checking Configuration

**Spec:** `MC.tla` + `MC.cfg`
**Mode:** Simulation (random traces)
**Parameters:**
- Server = {s1, s2, s3}
- MaxHeight = 2, MaxRound = 2
- MaxTimeoutLimit = 5, MaxCrashLimit = 2, MaxLoseLimit = 3
- MaxInvalidVELimit = 2, MaxMsgBufferLimit = 10
- Symmetry reduction enabled
- Deadlock checking disabled (crashes cause legitimate deadlocks)

---

### Run #1 — Initial simulation

**Date:** 2026-02-27
**Duration:** 5 minutes (timeout)
**States checked:** ~19.6M states across ~246K traces
**Mean trace length:** 23 steps (sd=12)
**Result:** No violations found

**Invariants checked (all held):**

Safety:
- `ElectionSafety` — at most one value committed per height
- `Validity` — only proposed values can be committed
- `LockSafety` — locked values are consistent with prevote quorums
- `POLRoundValidity` — POLRound < Round for all proposals
- `CommittedBlockDurability` — committed blocks are never lost
- `EvidenceUniqueness` — no duplicate evidence

Structural:
- `RoundBound`, `HeightBound` — within configured bounds
- `LockedRoundBound`, `ValidRoundBound` — lock/valid round within bounds
- `LockConsistency`, `ValidConsistency` — lock/valid state consistency
- `VoteCountBound` — vote counts bounded by server count
- `DecisionStability` — committed decisions are stable
- `CrashedNoTimeouts` — crashed servers have no scheduled timeouts
- `PrivvalConsistency` — persisted term consistent with current height

Temporal properties:
- `MonotonicHeight` — non-crashed servers never decrease height
- `MonotonicRound` — non-crashed servers never decrease round within same height
- `DecisionPermanence` — once decided, decision doesn't change

---

### Record #1 — POLRoundValidity evaluation error (resolved)

#### Counterexample Summary
TLC reported "Evaluating invariant POLRoundValidity failed" — not a violation of the invariant, but an evaluation error when comparing a record-typed proposal with the string "Nil".

#### Analysis Conclusion
- **Type**: Config issue (not a spec or invariant problem)
- **Violated Property**: POLRoundValidity (evaluation error)
- **Root Cause**: MC.cfg used `Nil = "Nil"` (string), but `proposal[s]` can be either a record or `"Nil"`. TLC cannot compare records with strings using `=` or `/=`.

#### Modifications Made
- **File**: `MC.cfg`
- **Before**: `Nil = "Nil"` (string constant)
- **After**: `Nil = Nil` (model value)

Model values can be compared with records in TLC (they are always unequal), avoiding the type-check error. This change only affects MC.cfg; Trace.cfg continues to use `Nil = "Nil"` (required for JSON trace compatibility).

---

### Run #2 — VE deadlock (MC-1, Bug #5204)

**Date:** 2026-02-27
**Config:** `MC_ve_ultra.cfg` (MCSpecVE, MaxRound=0, Values={v1}, 3 servers)
**Mode:** BFS
**Duration:** 41 seconds
**States checked:** 26.2M states, 4.25M distinct, depth 23
**Result:** **VELivenessInv violated** — 22-state counterexample

Proposer (s2) with InvalidVE commits while others can't reach quorum because proposer's precommits (with InvalidVE) are dropped. See `counterexample_MC1_VEDeadlock.out`.

---

### Run #3 — NilPrecommitAdvance (MC-3, Bug #1431)

**Date:** 2026-02-27
**Config:** `MC_liveness.cfg` (MCSpec, 3 servers, no faults)
**Mode:** BFS (temporal property checking)
**Duration:** 66 seconds
**States checked:** 889K states, 184K distinct, depth 16
**Result:** **NilPrecommitAdvance violated** — 16-state counterexample (stuttering)

All servers precommit nil, then system stutters. Without timeout, no mechanism to advance. See `counterexample_MC3_NilPrecommitAdvance.out`.

---

### Run #4 — Extended safety (4 servers)

**Date:** 2026-02-27
**Config:** `MC_safety_extended.cfg` (MCSpec, 4 servers, MaxRound=3)
**Mode:** Simulation (5 minutes timeout)
**States checked:** 152M states, 490K traces (mean length 7)
**Result:** No violations found

All 18 safety invariants hold including VELivenessInv (which doesn't trigger with 4 servers since 3/4 > 2/3).

---

### Run #5 — Full simulation sanity check (post-NilVote fix)

**Date:** 2026-02-27
**Config:** `MC.cfg` (MCSpec, 3 servers, standard bounds)
**Mode:** Simulation
**States checked:** 66K states, 523 traces (mean length 12)
**Result:** No violations found

All 16 safety invariants + 3 temporal properties hold after NilVote encoding fix.

---
