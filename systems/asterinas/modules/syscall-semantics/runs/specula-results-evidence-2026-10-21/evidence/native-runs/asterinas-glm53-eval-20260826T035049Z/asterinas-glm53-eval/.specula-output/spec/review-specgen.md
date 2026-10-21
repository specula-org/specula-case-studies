# Spec Generation Review: asterinas-glm53-eval

## Scores

| Criterion | Score | Notes |
|-----------|-------|-------|
| Scenario Coverage | 4/5 | All four brief scenarios have base-spec state/actions and focused hunt configs. S1 restart remains intentionally unreachable, and S2 omits the source-required rollback path. |
| Action Design | 4/5 | Offset ownership, VM copy, tuple conversion, vector dispatch, and syscall completion are split at useful implementation boundaries. Divergent Ext2, VirtioFS, and exFAT write-error paths are merged, and no rollback action exists. |
| Source Annotations | 4/5 | Implementation-facing actions and trace branches usually cite `file:line`. Helper logic, invariants, MC wrappers, and some compound branches have only broad or no source citations, so the every-logic-block requirement is not met. |
| Invariant Coverage | 3/5 | All eight brief invariants are defined, wired, and enabled in hunt configs. `RestartNoReplay` is unreachable, while `PositionalOffsetIsolation` checks a ghost field whose update rules already force the property. |
| MC Spec Structure | 3/5 | Symmetry, view, constraints, fault counters, and focused configs are present and executable. The view omits transition-controlling counters, and ordinary operation admission plus reactive restart are counter-bounded. |
| Trace Spec Design | 3/5 | The Category B timebox structure has no silent actions, calls base actions, validates post-state, and enables `TraceMatched`. The capture timing can produce incoherent post-states, and its progress contract conflicts with the base action guards. |
| Instrumentation Mapping | 3/5 | Every emitted base action has a named row with code locations and trigger timing. Rollback has no action/event, and most operation state is sourced from an underspecified trace shadow rather than concrete implementation observations. |
| Logical Correctness | 3/5 | SANY accepts all three modules; `MC.cfg` exhausts 511,868 states and the focused hunts reach their stated outcomes. The MC view is not behavior-preserving, one temporal property is tautological, and rollback/restart gaps remain. |

## Overall: 27/40

## Issues Found

- `DeferredWritePrepare` expands `cacheCapacity` for both `Correct` and `Exfat` (`base.tla:399-417`), but a copy fault goes through `ErrorFromTuple` directly to `NeedHandleReturn` (`base.tla:477-486`). There is no `RollbackExtent` action. Ext2 rolls the page cache back on this path (`kernel/core/src/fs/fs_impls/ext2/inode/file.rs:262-264`), and VirtioFS restores both cache size and visible EOF (`kernel/core/src/fs/fs_impls/virtiofs/inode/ops.rs:170-177`). The model therefore admits impossible post-fault state, omits VirtioFS's intermediate publication, and cannot match the rollback that `instrumentation-spec.md:158` says the harness must observe.
- The trace progress encoding is internally inconsistent. `instrumentation-spec.md:92-101` says consuming the entire effective copy limit emits `Complete` (two units). In `base.tla:423-443`, a one-unit short read has `copyLimit = Prefix`; its successful copy must pass `progress = Prefix` so `1 <= 1` and `faulted` is false. Emitting `Complete` makes the action guard false, so a valid correct-adapter short read cannot be replayed.
- `MCView == vars` (`MC.tla:231-244`) removes `beginCount`, `copyFaultCount`, and `restartCount` from state identity even though the begin, copy-fault, and restart guards read those counters (`MC.tla:42-114`). Equal views can therefore have different enabled successors. TLC may merge them and prune reachable behavior; no-violation results are not exhaustive unless the counters are included in the view or proven to be functions of it.
- The MC layer bounds more than fault injection. All six ordinary syscall-entry actions consume `BeginLimit` (`MC.tla:42-76`), and `RestartSyscall`, a reaction to an already-made restart decision, consumes `RestartLimit` (`MC.tla:106-114`). This does not satisfy the checklist's only-fault-injection-bounded rule.
- `RestartNoReplay` is not a current oracle. No action assigns `entryStatus = "EINTR"`; consequently `ERESTARTSYS`, `restartPending`, and `RestartSyscall` are unreachable. Enabling the invariant in the S1 hunt does not add coverage. This intentional source limitation should be reported as unverified coverage, not counted as an exercised invariant.
- `PositionalOffsetIsolation` (`base.tla:980-983`) only checks `offsetAdvanced`. That ghost field is updated solely by `InodeHandleCommitOffset`, whose guard already requires `usesSharedOffset`. A positional action could incorrectly mutate global `sharedOffset` while this invariant still passes, so the S4 hunt is not a discriminating check of the stated property.
- `MCEventuallyQuiescent == <>(AllOperationsQuiescent)` (`MC.tla:276-282`) is true in every initial state because all operations start `Idle` and `offsetOwner = NoThread`. If enabled, it proves nothing about quiescence after work begins.
- The instrumentation captures all shared post-state fields after the event's `end` timestamp and without a shared lock (`instrumentation-spec.md:62-65,103-122`). Another thread can change a subset of those fields before capture, yielding a snapshot that corresponds to neither event's modeled post-state while `ViablePIDs` still orders the completed event first. The per-field capture point must be made coherent, or the trace schema must validate only observations tied to the event boundary.

## Verdict: NEEDS_IMPROVEMENT
