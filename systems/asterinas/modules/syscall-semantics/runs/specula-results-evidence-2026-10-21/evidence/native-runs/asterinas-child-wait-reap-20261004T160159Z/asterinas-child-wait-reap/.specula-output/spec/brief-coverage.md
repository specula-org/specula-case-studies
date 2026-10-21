# Brief coverage audit

This is the coverage audit for the Category B child wait/reap protocol at Asterinas `0c60537098f4c2949ad2d382aaf499de72263d76`, revised for findings R1-R3 on 2026-10-05 and the R4 capture timing correction in r2. It maps the accepted modeling brief to the suite. The revision's executed checks and evidence limits are recorded in [generation-checks/results.md](generation-checks/results.md). Linux controls, guest cases, and implementation trace collection remain **NOT RUN**.

The tables below were checked against the uncommented declarations in the actual `MC*.cfg` files after writing them. The main config enables core safety and structural checks. Each of the five scenarios has its own hunt config. No scenario was merged or dropped.

## Brief §2 scenarios

| Scenario and priority question | Base mechanism | Targeting config and enabled obligations | Reachable fixture |
| --- | --- | --- | --- |
| 1. Unique consuming owner, priority 1. | `TryWaitChildrenLock/Match/Zombie/Retain`, `ReapZombieChildRemove/PidRemove/Finish`, unlock, output, and return are separate. The children mutex spans selection and destructive cleanup. | `MC_hunt_1_unique_consume.cfg`: `TypeOK`, `LockExclusion`, `UniqueConsume`, `NoFreshSelectionAfterRemoval`. | Three calls, either API, consuming only, with or without WNOHANG. Includes two competing consumers and a fresh post-completion invocation. |
| 2. Observation and retained lifetime, priority 2. | WNOWAIT skips removal. Each invocation retains its selected Arc until after status reading and copyout. Old generations stay distinct from new calls. | `MC_hunt_2_observation.cfg`: core safety plus `NoFreshSelectionAfterRemoval`, `ObservationPreservesAvailability`, `RetainedSelectionValid`. | Four blocking calls allow two WNOWAIT observations, one consumer through either API, and a post-reap observer. Concurrent selection, removal, and late output can interleave. |
| 3. Registration and wake/park, priority 3. | First scan, waiter creation, signal registration, queue enqueue, recheck, cancellation check, token swap, runqueue check/dequeue, and resume are separate. The notifier finishes both paths even after a racing reap. | `MC_hunt_3_wakeup.cfg` retains both completion properties. `MC_hunt_3_blocking.cfg` checks the general `MCBlockingWaitCompletes`. Both use `MCFairSpec`. | The wakeup fixture retains exactly two initial blocking consumers and one optional spurious return. The general fixture admits four calls, all API/option combinations including blocking WNOWAIT, repeated invocations on either thread, and one optional spurious return. Neither temporal configuration uses symmetry. |
| 4. Exit publication, priority 4. | Store, Release zombie publication, Acquire observation, retained selection, relaxed exit-code read, and API output are separate. | `MC_hunt_4_publication.cfg`: core safety plus `PublishedStatusAgreement`, `RetainedSelectionValid`. | Two blocking calls, either consuming or WNOWAIT, and exit values 0, 37, 255. |
| 5. API-specific outcomes, priority 5. | A protected scan result is cached through unlock and later return. No-event and ECHILD do not write output. waitid event success is distinguished from no-event success by the outcome and fields. | `MC_hunt_5_api_results.cfg`: core safety plus `ApiOutcomeCorrect`, `NoFreshSelectionAfterRemoval`. | Three calls with all six supported API/option combinations. Includes a live WNOHANG scan that returns after exit/reap and fresh calls after a completed consumer. |

All hunt configs use two parent threads, one fixed positive child PID, fixed UID, stable private output buffers, null rusage, and normal SIGCHLD with SIG_DFL, no SA_NOCLDWAIT, and blocking in all parent threads. The main config has three invocation admissions. Only new invocations and optional spurious scheduler returns are counter-bounded. Scans, retries, queue operations, wake delivery, cleanup, and output completion remain reactive and unbounded by counters.

## Brief §5 obligations

Every safety obligation is defined in `base.tla` and inherited by `MC.tla` through `EXTENDS base`. The extra `INSTANCE base` supplies the original source actions to the MC wrappers. The following are actual enabled hunt declarations, not commented suggestions.

| Brief obligation | Definition / wiring | Enabled hunt cfgs |
| --- | --- | --- |
| `TypeOK` / `LockExclusion` | `base.tla`, inherited by MC. R1 corrects the pending return's type representation. | 1, 2, 3 (both configs), 4, 5. |
| `UniqueConsume` | Cardinality of the persistent consuming-claim set. | 1, 2, 3 (both configs), 4, 5. |
| `NoFreshSelectionAfterRemoval` | Selection records protected membership. Calls started after consuming completion cannot select and must finish with ECHILD. | 1, 2, 3 blocking, 5. |
| `ObservationPreservesAvailability` | Removal is equivalent to existence of a consuming claim. Every claimant is a selected non-WNOWAIT invocation. | 2, 3 blocking. |
| `RetainedSelectionValid` | Selected publication and membership justify the reference. Reads and copyout record whether that reference was retained. Late output is permitted. | 2, 3 blocking, 4. |
| `PublishedStatusAgreement` | Acquired publication, child identity, exit code, and API encodings agree. | 3 blocking, 4. |
| `ApiOutcomeCorrect` | Cached live/no-event, absent/ECHILD, and selected/event outcomes have distinct output and direct-return rules. | 3 (both configs), 5. |
| `BlockingWaitCompletes` | `MCBlockingWaitCompletes` instantiates the base property over the finite admitted invocation identities. | `MC_hunt_3_blocking.cfg` covers observers and later invocations. `MC_hunt_3_wakeup.cfg` retains initial-consumer coverage. Both use `MCFairSpec`. |
| `CompetingConsumersComplete` | `MCCompetingConsumersComplete` instantiates the two blocking-consumer antecedent over finite identities. | `MC_hunt_3_wakeup.cfg`, under `MCFairSpec`. |

`MC.cfg` comments out scenario properties and enables `MCTypeOK` and `QueueEntriesValid` for convergence. There is no queue-size state constraint that could discard a problematic reactive schedule. Closed and duplicate queue entries retain their original invocation identities. Budget variables remain in the state identity because they affect future admissions. Safety configs use thread symmetry. Both temporal configs omit it.

R3 adds configured coverage without narrowing an existing bound. The new configuration uses `Hunt = "all"` and `CallLimit = 4`, retaining the brief §3.1 sequence of two observations, a consume, and a post-reap invocation. The two threads share this total admission budget. `SpuriousLimit = 1` retains the wakeup fixture's optional scheduler return, including schedules that never take it. Every generation through the finite bound is quantified by the general completion property. All reactive steps and the existing weak exit/thread fairness and strong lock-acquisition fairness remain unchanged. A time-limited search of this configuration is an incomplete liveness check, not proof of the obligation. No reduced substitute is used.

R1 replaces only the internal return marker with numeric `PendingRet = -9999` in `NewCall` and `CallType`, which `TypeOK` uses. `SysWaitReturn` and `ApiOutcomeCorrect` retain their numeric ABI rules. R2 adds `TraceSearch.cfg` and the completion target `TraceComplete`, retaining all base-action calls, exact post-state validation, and `TraceEndOK`. Acceptance requires an explicit complete witness. Exhausted no-witness and incomplete searches are distinct outcomes, as documented in [instrumentation-spec.md](instrumentation-spec.md).

## Brief §6.1 findings

The brief contains no retained model-checkable defect candidate. There is therefore no defect fault setup to enable. The five hunt configs check the selected protocol questions using the pinned implementation's actual synchronization. No historical fix is reverted, recheck skipped, wake path removed, or ordering bridge weakened.

## Priority dispositions and evidence limits

The five priority questions retain their model obligations and targeting configurations. Revision r1 reran every MC configuration and recorded completed, failed, or time-limited outcomes in [generation-checks/results.md](generation-checks/results.md), including state counts and depths. Revision r2 changes no model or configuration, so none of those MC configurations is affected or rerun. Definition and configuration coverage do not establish that a property has passed TLC. Synthetic trace fixtures establish checker behavior only. Implementation schedules, including the two-consumer liveness antecedent and late-observer history, still require runtime evidence.

WR-01 through WR-03 map to scenarios 4 and 5. WR-04 and WR-05 map to scenario 2. WR-06 and WR-07 map to scenarios 1 and 3. WR-08 maps to scenario 2. WR-09 and WR-10 map to scenario 3. Every runtime case remains **NOT_RUN**.

WR-SQ remains a **SOURCE LEAD / NOT_RUN**. The model preserves Asterinas' no-write waitid branch but the primary siginfo starts at zero. The separate poisoned-output Linux/Asterinas control must compare the relevant fields and record direct arguments and libc error decoding. A prezeroed protocol trace cannot resolve WR-SQ. WR-CF remains **CALIBRATION / NOT_RUN**. Faulting output is excluded from the primary model. A separate sequential control must allow consume-before-EFAULT and check the following valid wait. Neither item is assigned novelty, severity, or an AST ID here.

The model projects the Rust atomics onto explicit protocol steps. `ProcessStatus` Release/Acquire supplies exit-code visibility. Queue-count RMW ordering, queue locking, wake-token Release/Acquire, and the shared runqueue lock supply the wake/recheck bridges. This is not a compiler or hardware weak-memory proof. The PID, group/session, accounting, and mutex-contention internals are projected as eventual cleanup/acquisition while preserving children-lock ownership and retained-result lifetime. General Arc reclamation is outside scope. The main task remains retained through the Process, as `task_set.rs:63-74,141-143` requires.

Completion assumes finite client activity, eventual child exit and completion of its notifier, live parent threads, eventual lock acquisition/release, eventual completion of pending unpark work, and execution of runnable waiters. It does not assume a timeout, spontaneous notification, FIFO selection, immediate scheduling, or a reap-triggered extra wake. Optional spurious scheduler return only exposes the existing retry loop. Completion must still hold on schedules without it.

The Linux source reference remains commit `4645fefac0b24d509b962c096b0327e87f34b1d2`, not a runtime control. Runtime concurrency claims require actual SMP >= 2, pinned guest/Linux identities, and internal schedule evidence for a lost-wakeup claim. Trace generation and collection belong to the next assigned worker.

## Review and continuation boundary

The original generation remains preserved in the reviewed Git baseline. Its review is retained in `review-specgen.v0.md`, and the r1 review is in `review-specgen.md`. `generation-checks.txt` retains the original logs and r1 commands. `generation-manifest.json` records current artifact hashes and revision provenance. [REVISION-2026-10-05.md](REVISION-2026-10-05.md) records the explicitly requested R1-R3 correction and reruns. [REVISION-2026-10-05-r2.md](REVISION-2026-10-05-r2.md) records the R4-only correction. Prior content remains available in Git, with executed input hashes in `generation-checks/results.json`. This local revision does not claim a new independent acceptance review or launch another pipeline stage. Subsequent campaign corrections remain subject to the controller's `corrective_review_gate` and resource ownership rules.

## Generation checks

During original generation, SANY parsed and semantically checked `base.tla`, `MC.tla`, and `Trace.tla`. An initial invalid dependent set binding in the type predicate was corrected to a nested comprehension. The final checks reported no errors. The actual TLC `ModelConfig` parser accepted all eight cfg files without constructing a model checker or generating states. Static assembly checks found 41 base actions, 41 trace dispatch arms, 41 exact post-state checks, and 41 instrumentation rows, with identical action names. Every configured operator is defined, every brief safety obligation is enabled in a hunt, and `TraceMatched` is enabled. These checks are recorded in `generation-checks.txt`. `generation-manifest.json` records input and output hashes.

The revised modules also pass SANY and all ten configurations pass `ModelConfig.parse`. The static audit still finds the same 41 action/event/dispatch/post-state/mapping names and verifies that existing action logic, numeric return checks, MC wrappers, and old configurations are unchanged. See `generation-checks/audit.log` and `generation-checks/results.md` for revision evidence. MC exploration and synthetic replay are now executed. Harness execution, Linux controls, Asterinas runtime cases, and independent acceptance of the revised version remain **NOT RUN**.

The revision's executed MC result is **PASS** for `MC_hunt_4_publication.cfg`
(1,005,898 distinct states, depth 77) and **TIME-LIMITED** for the other six
MC configurations. The new general liveness search records 274,877 distinct
states at depth 22, and the restricted wakeup search records 259,862 at depth
49. These are the last complete progress samples before their limits. Neither
liveness property has an exhaustive pass. The overlap and sequential synthetic
traces are accepted with complete witnesses. The corrupted trace is rejected
by exhausted search. The unchanged universal overlap check fails `TraceMatched`
as predicted by R2, with its counterexample retained and classified in the
results file. No MC run reports a property violation.

Revision r2 addresses only R4 from the r1 review. `ParkCurrentCheck` now has
separate capture timing for its two branches. The false branch records the
load while holding the runqueue guard, before dequeue. The true branch saves
the same load result but records post-state and interval end after the callback,
guard release, and `reschedule` return. `ParkCurrentResume` is emitted only
after a dequeue. These boundaries follow `ostd/src/task/scheduler/mod.rs:453-485,577-584`,
`kernel/core/src/sched/sched_class/mod.rs:255-259`, and `ostd/src/sync/wait.rs:273-275`.
The 41-action correspondence, modules, configurations, and exact post-state
checks are unchanged. No MC reachable behavior is affected, so D4 is **NOT RUN**
with this reason, and the r1 MC results above retain their original limits.

The new `park-true` and `park-false` synthetic fixtures pass existential replay
with 55- and 57-state complete witnesses. The latter includes a wake swap
between false check and dequeue while the runqueue lock is held, followed by
unpark and resume. Both witnesses complete the calls and notifier. Reruns
preserve acceptance of overlap and sequential inputs, exhausted rejection of
the corrupted input, and the expected universal `TraceMatched` failure. SANY
again parses all three unchanged modules. See [REVISION-2026-10-05-r2.md](REVISION-2026-10-05-r2.md)
for the R4-only inventory and criterion table.
