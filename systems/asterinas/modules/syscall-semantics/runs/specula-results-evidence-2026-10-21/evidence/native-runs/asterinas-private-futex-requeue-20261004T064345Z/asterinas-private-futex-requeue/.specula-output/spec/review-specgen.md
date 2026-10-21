# Spec Generation Review: asterinas-private-futex-requeue

Reviewed on 2026-10-05 against Asterinas commit `0c60537098f4c2949ad2d382aaf499de72263d76`, tree `4693fdec88cd7da14bed4f1541eba593f123059c`. The source checkout matches the brief and has no tracked modifications. This review covers the eight requested files, the coverage audit, and all 15 hunt configurations. [Input hashes](output/review-specgen-20261005T105823Z/inputs.json) identify the reviewed revision.

## Scores

| Criterion | Score | Notes |
|-----------|-------|-------|
| Scenario Coverage | 5/5 | All four scenarios have extensions and targeting configurations. Scenario 1 preserves locked load/compare/enqueue, recoverable-fault reload, and ordered store/WAKE. Scenario 2 separates zero quotas, collisions, same-address processing, and return counts. Scenarios 3 and 4 preserve saved-original cleanup, timer/callback ownership, closed entries, and the later live-migration consequence. |
| Action Design | 5/5 | Function-derived actions preserve the important implementation boundaries: load versus comparison, wake swap versus unpark/removal, same-bucket versus cross-bucket migration, extraction ownership, timer reads versus their consumers, and cleanup versus closure/return. Current timer actions preserve heap-head selection and callback order within each invocation. |
| Source Annotations | 4/5 | Source aliases resolve to the pinned files, with useful line ranges for the modeled operations and Linux reference oracles. Some references cover an action group or a whole branch/update block rather than each logic block separately. |
| Invariant Coverage | 5/5 | Every obligation in brief §5 has a corresponding enabled hunt check. Resource accounting and live migration run separately from the quota compatibility checks. Same-address processed entries are distinguished from physical movement. Conditional completion has explicit fairness and a dedicated configuration without symmetry. |
| MC Spec Structure | 4/5 | Symmetry, a budget-preserving view, a finite-capacity constraint, and a separate fair specification are present. Counters bound client admission, timed admission, stores, and recoverable faults. Thus the literal fault-only criterion is not met, although the finite workload is documented and admitted reactive actions remain unbounded. |
| Trace Spec Design | 5/5 | Every wrapper invokes its base action and checks an exact mandatory post-state record. No kernel transition is silent. Per-stream order, dependencies, timeboxes, collection identity, callback execution context, batch identity, and complete-attempt termination are constrained. Positive and negative replay checks behaved as expected. |
| Instrumentation Mapping | 5/5 | The independent audit finds 57 primitive actions, each with one direct wrapper, event dispatch, argument schema, and mapping row. Capture points explain atomic results, logical vector reconstruction, local clock samples, and callback batch ownership. The limited unpark projection is explicitly justified by target-thread state being unavailable to the caller. |
| Logical Correctness | 5/5 | All three modules pass fresh SANY parsing and semantic analysis. Source review and ten bounded replay checks found no remaining correctness blocker. The deliberate `TraceIncomplete` violation is treated as an existential replay witness, with final cursors verified. Broad safety/liveness proof remains outside this verdict. |

## Overall: 38/40

The scenario-specific failure predicates remain meaningful. The model intentionally retains wake-zero conversion, the same-bucket zero-migration behavior, wake-only REQUEUE return counts, and cleanup through the original bucket. These implementation behaviors must not be repaired inside the reference model. The quota and ownership candidates are separate from defects in the specification.

Fresh verification used unchanged base/MC/Trace inputs and a thin replay wrapper that overrides only the input filename. TLC runs were sequential under the ancestor controller's resource lock, with 512 MiB heap, 64 MiB off-heap, one worker, and a one-minute limit per run. SANY checks used 512 MiB heap. No source or specification was changed.

| Synthetic fixture | Expected | Observed |
|-------------------|----------|----------|
| Ordered control | Accept | Accepted, 75 states. |
| Reversed heap removals | Reject | Rejected, 29 states. |
| Reversed callbacks within one batch | Reject | Rejected, 32 states. |
| Equal deadlines | Accept | Accepted, 75 states. |
| Overlapping batches on different contexts | Accept | Accepted, 77 states. |
| New collection on a context with an unfinished batch | Reject | Rejected, 32 states. |
| Wrong callback batch | Reject | Rejected, 32 states. |
| Wrong callback execution context | Reject | Rejected, 32 states. |
| Overlapping callbacks within one batch | Reject | Rejected, 33 states. |
| Corrupted post-state | Reject | Rejected, 29 states. |

For each accepted fixture, the only failing invariant was the configured `TraceIncomplete` success sentinel. Every final cursor equaled its stream length plus one, and collection/batch ownership was drained. Each rejected fixture exhausted its reachable prefix graph with zero queued states and no complete-replay sentinel. Rejection was not inferred from the process exit code or from a temporal failure alone.

[Replay results and task IDs](output/review-specgen-20261005T105823Z/results.json), [fixture identities](output/review-specgen-20261005T105823Z/fixtures.json), [final cursors](output/review-specgen-20261005T105823Z/tasks.json), [syntax results](output/review-specgen-20261005T105823Z/syntax-results.json), and the [mapping audit](output/review-specgen-20261005T105823Z/mapping-audit.json) retain the evidence. Individual logs are adjacent to these files.

## Issues Found

- **Nonblocking annotation granularity.** [base.tla](base.tla):331–338 gives one `F:398–427` annotation for both lock-acquisition actions. Larger blocks such as lines 345–357 combine the retain predicate, Waker swap, and derived observers under one source comment. The cited implementation supports these operations, but the checklist's requirement to annotate every logic block is stricter. Separate references for the second acquisition and the distinct implementation/observer blocks would make the mapping easier to audit.

- **Nonblocking deviation from fault-only bounds.** [MC.tla](MC.tla):75–89 limits WAIT/control admission, timed admission, and user stores as well as faults. These are deliberate workload bounds consistent with the brief's finite generations. Lines 99–106 retain `ReactiveNext` without budget guards, and `MCClock` covers both armed deadlines and sampled deadlines awaiting publication. This limits the scope of exploration without truncating admitted cleanup or callback work. The bounds should remain explicit in any downstream verification claim.

The two previous correctness findings are resolved in the reviewed revision:

- **Heap ordering:** [base.tla](base.tla):217–244 requires every pop to select a minimum original deadline, including cancelled nodes, and uses the same head condition to end collection. This matches [timer.rs](../../source/kernel/core/src/time/core/timer.rs):207–215 and 299–304. The previously accepted reversed-heap fixture is now rejected, while equal deadlines remain permitted.
- **Callback order and ownership:** [base.tla](base.tla):223–278 preserves each invocation's vector and advances it only on failed upgrade or completed callback. [Trace.tla](Trace.tla):197–205, 552–565, and 628–643 bind callback events to the originating execution stream and batch until that vector drains. This matches the synchronous callback loop at [timer.rs](../../source/kernel/core/src/time/core/timer.rs):220–221. Reversed, overlapping, misattributed, and wrong-batch callbacks are rejected, while independent invocations can overlap.

No unresolved correctness defect was found. This is a spec-generation review verdict, not a completed verification campaign. Existing round-2 records, whose primary-input and incomplete-run log hashes match the current manifest, still mark `MC.cfg`, `MC_hunt_completion.cfg`, and `MC_hunt_s3_opposite.cfg` incomplete at their 1,200-second limits. This review did not rerun those broad searches. Synthetic replay does not establish implementation-trace consistency or runtime confirmation. Kernel instrumentation, guest execution, and Linux controls remain unperformed by this review.

## Verdict: PASS
