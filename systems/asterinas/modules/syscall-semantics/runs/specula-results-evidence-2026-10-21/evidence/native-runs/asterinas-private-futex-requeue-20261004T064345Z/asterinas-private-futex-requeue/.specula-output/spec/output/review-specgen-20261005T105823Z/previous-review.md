# Spec Generation Review: asterinas-private-futex-requeue

Reviewed on 2026-10-05 against Asterinas commit `0c60537098f4c2949ad2d382aaf499de72263d76`, tree `4693fdec88cd7da14bed4f1541eba593f123059c`. The source checkout matches the brief and has no tracked modifications. This review covers the eight requested files and checks the supporting coverage audit and all 15 hunt configurations.

## Scores

| Criterion | Score | Notes |
|-----------|-------|-------|
| Scenario Coverage | 5/5 | All four scenarios have extensions and targeting hunt configurations. The suite includes ordered registration/retry, independent quota controls, original/current ownership, and the later live-migration consequence. |
| Action Design | 4/5 | Function-derived actions preserve compare/enqueue, wake/unpark/removal, same/cross-bucket movement, and cleanup/closure boundaries. Timer collection and callback execution omit implementation ordering constraints described below. |
| Source Annotations | 4/5 | Source aliases resolve to the pinned checkout, and most actions have useful line ranges. Coverage is mainly per action or group rather than every logic block. For example, `LockBucketPairsSecond` at `base.tla:324–326` shares the preceding action's annotation, and larger branch/update blocks lack individual references. |
| Invariant Coverage | 5/5 | All eight obligations in brief §5 have corresponding operators and enabled hunt configurations. Resource accounting and live migration are checked separately, quota incompatibilities cannot mask them, and the completion configuration enables conditional liveness without symmetry. |
| MC Spec Structure | 4/5 | Symmetry, a budget-preserving view, capacity constraint, and a separate fair specification are present. Counters also bound WAIT/control admission, timed admission, and user stores, so bounds are not exclusively fault injection. These are documented finite workloads. Admitted reactive work remains unbounded. |
| Trace Spec Design | 3/5 | All wrappers invoke base actions and require exact post-state records. There are no silent kernel transitions. Per-thread order, dependencies, and collection identity are checked, but both impossible timer histories below receive complete replay witnesses. |
| Instrumentation Mapping | 4/5 | The audit finds exactly 57 primitive actions, 57 argument schemas, 57 wrappers, and 57 mapping rows, with no missing names. Capture timing and queue reconstruction are explained. Callback events lack the collection identity and execution-order checks needed for issue 2. |
| Logical Correctness | 3/5 | All three modules pass fresh SANY parsing. Two independently exercised timer-ordering omissions make the transition relation more permissive than the implementation. The deliberate `TraceIncomplete` sentinel is correctly documented as a replay witness. |

## Overall: 32/40

The main futex paths and scenario oracles are well represented. The remaining blockers concern fidelity with two pending timers.

Three fresh synthetic replay checks used the unchanged base and trace modules, the original trace invariants/properties, and a thin wrapper that overrides only the input filename. Each fixture contains 74 events with disjoint timeboxes, complete WAIT/control returns, and one timer execution stream. Runs were sequential under the controller-held resource lock, with 512 MiB heap, 64 MiB off-heap, one worker, and a one-minute limit each.

| Fixture | Expected result | Observed result |
|---------|-----------------|-----------------|
| [Ordered control](output/review-specgen-20261005T071730Z/control.ndjson) | Accept. | Accepted in 75 states. |
| [Reversed heap removals](output/review-specgen-20261005T071730Z/heap-reversed.ndjson) | Reject. | Accepted in 75 states. |
| [Reversed callbacks within one batch](output/review-specgen-20261005T071730Z/callbacks-reversed.ndjson) | Reject. | Accepted in 75 states. |

Each run violated only `TraceIncomplete`, the configured success sentinel. Final cursors were checked against every stream's length and were fully exhausted. [Results and task IDs](output/review-specgen-20261005T071730Z/results.json), [input hashes](output/review-specgen-20261005T071730Z/inputs.json), and the three adjacent `.log` files retain the evidence. These checks establish model behavior on synthetic inputs. They do not establish kernel behavior or exhaustive MC safety/liveness.

## Issues Found

- **[P2] Restrict timer collection to a heap head.** At `base.tla:233–237`, `TimerCollect(g)` accepts any pending generation whose cancellation flag or deadline makes it collectible. It never requires that generation to have the minimum pending deadline. The implementation examines and removes only `timeout_list.peek()`/`pop()` in [timer.rs](../../source/kernel/core/src/time/core/timer.rs):207–215, and its comparator at lines 299–304 orders callbacks by increasing deadline.

  The reproduced state has uncancelled deadlines 1 and 2 and a batch sample of 2. The model collects generation 2 before generation 1 and accepts the entire resulting trace. In the [heap-reversed log](output/review-specgen-20261005T071730Z/heap-reversed.log), state 30 has `collect.ready = <<2>>` while the earlier timer is still pending. The minimum-deadline condition in `TimerCollectEnd` does not constrain these earlier pop actions. This permits impossible collection and notification histories during the multi-timer wake/expiry races covered by the brief. Require every pop, including cancelled-node removal, to select a minimum-deadline pending timer. Equal deadlines may remain nondeterministic.

- **[P2] Preserve callback order and execution ownership after collection ends.** At `base.tla:223–246`, collection end marks all collected callbacks `due`, and `TimerCallbackUpgrade(g)` can start any of them. The recorded `collect.ready` sequence does not gate callback execution and is overwritten by the next collection. In the implementation, [timer.rs](../../source/kernel/core/src/time/core/timer.rs):220–221 calls the collected callbacks synchronously, in vector order, from that collection's execution context.

  The second probe collects `<<1,2>>` in one batch, then executes callback 2 before callback 1 on the same timer stream. It is fully accepted. State 33 of the [callbacks-reversed log](output/review-specgen-20261005T071730Z/callbacks-reversed.log) shows callback 2 at `ref` while callback 1 remains `due`. The trace's `collection` identity is cleared at `Trace.tla:625–628`, and callback validation at lines 196–199 checks only membership in `timer_pids`. Neither the base model nor the wrapper retains the order obligation. Preserve each outstanding batch's callback sequence and executing context until it drains, and require each callback to finish before the next callback from that batch begins. Extend the callback mapping to verify this association while still allowing different collection invocations to overlap where the source permits.

Both findings are specification defects. They require multiple timers and do not occur in the dedicated owner/live-migration configurations, which admit at most one timed WAIT. The known quota and original-bucket cleanup behaviors remain intentional implementation modeling, and this review does not establish or dismiss their runtime consequences. The specifications and kernel source were left unchanged.

## Verdict: NEEDS_IMPROVEMENT
