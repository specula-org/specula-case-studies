# Spec Validation Changelog — crossbeam-skiplist_2

## Round 1 - Trace Validation
- All 5 trace files passed validation with no failures (scenario_single_thread_basic, scenario_two_threads_distinct_keys, scenario_height_growth, scenario_insert_remove_race, scenario_insert_replace).

## Round 1 - Model Checking
- MC.cfg BFS run (output/MC_run1.out): no invariant violations in 30 min budget. Reached depth 21, 899M distinct states found, 670M on queue (state space not exhausted). All structural invariants (AllocBound, NodesAllocatedHaveState, RefcountNonNegative, MCTypeOK) hold within explored space.
- Note: TLC needed `-XX:-UsePerfData` JVM flag to avoid SIGBUS in `PerfLongVariant::sample()` (JVM hsperfdata bug, unrelated to spec).
- Note: `-deadlock` flag passed to TLC (disables deadlock check) — bounded model with `MaxOps` naturally reaches terminal states; this is expected, not a real bug.

## Result
Converged in 1 round. No spec modifications needed. Proceeding to bug hunting.

## Bug Hunting

### Round 2 - Spec fix during F2 hunt
- [fix-spec] Insert_AllocCASLevel0: added CAS-contention precondition `\A n \in NodesForKeyAt(pc[t].key, 0) : n = pc[t].found`. Without it, two concurrent inserts of the same key both reach Done without contention, violating KeysUnique outside the in-flight carve-out — Case B (real CAS in base.rs:1095-1104 prevents this; the spec was abstracting too aggressively). Re-validated all 5 traces still pass.

### Hunt Results
- [bug] F1 IteratorFusion violated under FaultIterRewind (Case C). Trace: 11 states, depth 15, 5s. See bug-report.md.
- F2 (FaultInsertReorder=TRUE): BFS 30 min (735M distinct, depth 18) + simulation 30 min (2.88B states checked, 220M traces) — no violations. F2 absence-window mechanism doesn't trigger duplicate invariants; carve-out covers transient duplicate window.
- F3 (FaultMarkBottomUp=TRUE): BFS exhausted state space (5.37M distinct, depth 35, 42s) — no violations. Abstraction collapses mark_tower loop, so top-down/bottom-up are indistinguishable at this granularity (documented brief tradeoff, priority LOW).
- F4: BFS 30 min (767M distinct, depth 19) + simulation 30 min (5.05B states checked, 377M traces) — no violations. Refcount discipline holds; documented historical regressions (#672/#671/#1143/#1178) all stay closed.

## Result
Converged in 2 rounds. Bug hunting: 1 bug found (F1 iterator rewind, 4 affected sites in base.rs).

