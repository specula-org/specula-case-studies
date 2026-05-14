# Brief Coverage Self-Audit — crossbeam-skiplist_2

This document maps the modeling brief's §2 (Bug Families), §5 (Proposed
Invariants), and §6.1 (Model-Checkable Findings) to the spec artifacts
(`base.tla`, `MC.tla`, hunt cfgs).

## Table 1: Bug Families (brief §2)

| Brief Family | Hunt cfg file | Family-relevant invariants enabled | If skipped, why? |
|---|---|---|---|
| F1 — Iterator rewind after exhaustion (HIGH) | `MC_hunt_family1_iter_rewind.cfg` | IteratorFusion, IterNoSameKeyTwice | — |
| F2 — Insert install-then-mark transient duplicate (MEDIUM) | `MC_hunt_family2_insert_dup.cfg` | KeysUnique, LenIsApproximatelyKeyCount, IterNoSameKeyTwice, MarkMonotone, MarkTopDown | — |
| F3 — Tower-CAS memory ordering / SeqCst sensitivity (LOW) | `MC_hunt_family3_memorder.cfg` | KeysUnique, MarkTopDown, MarkMonotone | — |
| F4 — Caller misuse: concurrent iter + insert + remove (MEDIUM) | `MC_hunt_family4_caller_misuse.cfg` | RefcountMatchesHandlesAndInstalls, GetReturnsLatest, NoUseAfterFree | — |
| F5 — Refcount discipline (HIGH historical, mostly fixed) | (REFERENCE-ONLY per brief; NoUseAfterFree exposed via family4) | (NoUseAfterFree enabled in family4) | Brief §2 marks F5 reference-only — fixes have landed and the bug class is well-tested; the related safety net `NoUseAfterFree` is checked in family4. |
| F6 — `compare_insert` predicate gap (LOW) | (REFERENCE-ONLY per brief) | — | Brief §2 marks F6 as a design issue, not a protocol bug. No invariant proposed in §5. |

## Table 2: Proposed Invariants (brief §5)

| Brief invariant | Defined at (file:line) | Wired in MC.tla? | Enabled in which hunt cfg(s)? | If skipped, why? |
|---|---|---|---|---|
| KeysUnique | base.tla:885 | yes (extends base) | family2_insert_dup.cfg, family3_memorder.cfg | — |
| IterNoSameKeyTwice | base.tla:944 | yes | family1_iter_rewind.cfg, family2_insert_dup.cfg | — |
| IterFusedAfterExhaust (named `IteratorFusion`) | base.tla:930 | yes | family1_iter_rewind.cfg | — |
| RefcountNonNegative | base.tla:879 | yes | MC.cfg + ALL hunt cfgs (it's a baseline) | — |
| RefcountMatchesHandlesAndInstalls | base.tla:964 | yes | family4_caller_misuse.cfg | — |
| MarkMonotone | base.tla:898 | yes | family2_insert_dup.cfg, family3_memorder.cfg | — |
| MarkTopDown | base.tla:907 | yes | family2_insert_dup.cfg, family3_memorder.cfg | — |
| LenIsApproximatelyKeyCount | base.tla:922 | yes | family2_insert_dup.cfg | — |
| GetReturnsLatest | base.tla:975 | yes | family4_caller_misuse.cfg | — |
| NoUseAfterFree | base.tla:990 | yes | family4_caller_misuse.cfg | — |

## Table 3: Model-Checkable Findings (brief §6.1)

| ID | Trigger mechanism | Expected violated invariant | Hunt cfg targeting it |
|---|---|---|---|
| MC1 | `Iter::next` after exhaustion: `FaultIterRewind = TRUE` | IteratorFusion, IterNoSameKeyTwice | family1_iter_rewind.cfg |
| MC2 | `Iter::next_back` after exhaustion: `FaultIterRewind = TRUE` driving `Iter_NextBack` | IteratorFusion | family1_iter_rewind.cfg |
| MC3 | `Range::next_back` after exhaustion: same flag, `Iter_Begin` with `kind="Range"` then `Iter_NextBack` | IteratorFusion | family1_iter_rewind.cfg (same actions cover Range via `kind` parameter) |
| MC4 | Two-thread interleaved inserts of same key, observe via Iter during AllocCASLevel0→MarkOld window. `FaultInsertReorder` opens the wider #1023 regression window. | IterNoSameKeyTwice, KeysUnique | family2_insert_dup.cfg |
| MC5 | Same as MC4; observe via len() (`lenCounter`) during the window | LenIsApproximatelyKeyCount | family2_insert_dup.cfg |
| MC6 | Insert breaks early at level k (build CAS failure / `Insert_BuildLevel` early-break path); HelpUnlink cleans up | RefcountMatchesHandlesAndInstalls (after grace) | family4_caller_misuse.cfg (general refcount; partial-build path is reachable under harness with concurrent insert/remove) |
| MC7 | `FaultMarkBottomUp = TRUE` flips mark_tower direction; PostBuildCheck (top-only read) misses the mark | KeysUnique, MarkTopDown | family3_memorder.cfg |
| MC8 | Concurrent `pop_front` from N threads: the harness lets all threads issue PopFront on the same level-0 head | RefcountMatchesHandlesAndInstalls (no leak) | family4_caller_misuse.cfg |

## Coverage Summary

```
Families:                       4 / 4 implemented (skipped: F5, F6 — reference-only per brief)
Proposed Safety Invariants:    10 / 10 enabled in ≥1 hunt cfg
Model-Checkable Findings:       8 / 8 targeted by a hunt cfg
Hunt cfg files:                 4
```

## Notes on coverage decisions

- **MC3 Range coverage**: `Iter_Begin(t, kind)` accepts `kind \in {"Iter", "Range"}`. The forward/back step machinery is shared (the bug shape and code shape are identical between `Iter` and `Range` per brief §2 F1). The hunt cfg constants do not need to enumerate both; symmetry / non-determinism over `kind` covers both code paths.

- **MC6 partial-build path**: `Insert_BuildLevel` has an early-break branch when `nMark[n][lvl]` (base.rs:1222-1240). The cleanup is triggered by `HelpUnlink`, which is wrapped under counter `MaxHelpUnlinkLimit`. `RefcountMatchesHandlesAndInstalls` is checked at quiescence (no in-flight ops), which exercises the cleanup grace.

- **Liveness for MC8**: The brief calls out a liveness side ("if list is non-empty after some bound, eventually returns Some"). The current spec captures this only via the safety side (`RefcountMatchesHandlesAndInstalls` after pop completes). A pure liveness property would require fairness assumptions which we have intentionally omitted (state-space cost). This is acceptable per the brief: the safety side is the load-bearing check.

- **F5 reference-only treatment**: brief §2 explicitly marks F5 as REFERENCE-ONLY (the bug class is well-tested and individually fixed; per `bug-archaeology.md` § 1.4 reproducing closed bugs adds no value). Nevertheless, the brief proposes `NoUseAfterFree` as a §5 invariant that targets F5 — we honor that by checking it in family4 (which has the right interleaving surface for the hazard).

- **F6 reference-only treatment**: brief §2 marks F6 as a design issue. No invariant is proposed in §5 for F6, so no cfg is required.
