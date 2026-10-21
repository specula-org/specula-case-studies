# Modeling-brief coverage audit

Snapshot: Asterinas `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`.

Category B boundaries are explicit: lookup/captured use, removal/cleanup,
ADD update-before-insert, signal queue mutation/guard drop/later notify,
source mutation/synchronous notify/callback, cache load/swap/check/CAS,
delivery preparation/copyout, and live terminal selection.
Only introduction actions consume MC counters. Production-driven completion
and callback actions remain unbounded. `seenActions` and the actions in
`MC_Controls.tla` are labeled controller/test-only and are absent from
`base.Next` and `Trace.MatchEvent`.

## Brief section 2 scenarios

| Scenario | Source-backed model boundary | Independent oracle, reach, and control configs |
|---|---|---|
| 1. FD/OFD identity, duplication, flags, exec | `slotEpoch`; `FcntlSetFlCapture`/use; close/deferred release; atomic dup replacement; atomic close-range loop; exact per-wait `PollFiles::Owned` slot snapshot; old shared-table/private exec-table identity across the atomic clone/install cutover; private CLOEXEC closure and final releases. Source: `kernel/core/src/fs/file/file_table.rs:139-234,274-302,326-404`, `kernel/core/src/syscall/fcntl.rs:43-94`, `kernel/core/src/syscall/poll.rs:96-101,124-155`, `kernel/core/src/process/namespace/unshare.rs:18-28`, `kernel/core/src/process/execve.rs:378-386`. | Existing Scenario 1 hunts plus `MC_reach_poll_snapshot_close.cfg`, `MC_reach_poll_snapshot_release.cfg`, four `MC_reach_exec_{before,after}_{dup,cloexec}.cfg` cutover witnesses, and the poll omission/early-release and exec alias/wrong-table controls. |
| 2. Epoll identity, lifetime, delivery | Composite key plus an independent ADD-captured `{fd,ofd,slot generation}` audit; ADD `Entry::update` before interest insertion; captured-Arc release on every terminal ctl branch; weak-upgrade before enabled check; producer/callback/queue/delivery epochs; prepare/copyout split. Source: `kernel/core/src/events/epoll/file.rs:65-176,210-245,340-343`, `kernel/core/src/events/epoll/entry.rs:46-176,240-330,367-397`. | `MC_hunt_s2_key_identity.cfg`, `MC_hunt_s2_cross_reuse.cfg`, `MC_hunt_s2_epoll_delivery.cfg`, `MC_hunt_s2_copyout.cfg`, `MC_hunt_s2_oneshot.cfg`, `MC_hunt_s2_level.cfg`, `MC_hunt_lifetime.cfg`; valid-reuse reach and wrong-OFD/stale-generation/dead-before-disabled controls listed below. |
| 3. Readiness cache and registered delivery | Multiple actors may load `invalid` before either installs its checker identity; load/swap/check/CAS and source/callback/queue/delivery epochs remain separate. Eventfd's counter guard spans mutation, exact synchronous callback obligations, and notify return. Initial poll stores the live registration-pass result before choosing its terminal. Source: `kernel/core/src/process/signal/poll.rs:37-58,90-178`, `kernel/core/src/syscall/poll.rs:88-106,165-185`, `kernel/core/src/syscall/eventfd.rs:124-159`. | `MC_hunt_s3_cache.cfg`, `MC_hunt_eventfd_mutex.cfg`, `MC_hunt_s3_registered_delivery.cfg`, `MC_reach_two_checkers_loaded_invalid.cfg`, `MC_reach_poll_initial_ready.cfg`, `MC_reach_eventfd_callback_scope.cfg`; intentional eventfd early-release and second-mutation controls. The positive Trace fixture includes `PollFilesInitialReady` and a complete eventfd callback scope. |
| 4. Thread-relative signalfd | Executing actor is distinct from queue/wait target; enqueue under `queues.lock()` ends at the explicit guard drop; exact callbacks/Wakers are selected only by the later notify. Binding becomes obligatory only after update and interest insertion both complete. Source: `kernel/core/src/process/signal/sig_queues.rs:38-45,86-92`, `kernel/core/src/events/epoll/file.rs:96-120,191-205`, `kernel/core/src/events/epoll/entry.rs:155-166`, `kernel/core/src/syscall/signalfd.rs:171-179,205-215`. | Existing Scenario 4 hunts remain isolated. `MC_reach_signal_thread_gap.cfg`, `MC_reach_signal_interleave_gap.cfg`, and `MC_reach_signal_interleaved_completion.cfg` prove the unlocked gap, post-enqueue registration/mask interleaving, exact callback discharge, and notify return. Separate notify action reach configs and the ordering mutation control cover every new boundary. |
| 5. Timeout, interruption, close, mask restoration | Separate actor/target wakes; readiness wakes consume a producer-selected OFD/actor/epoch token. Each terminal branch records an audit-only live source scan separately from historical `visibleReady`; every new invocation resets all per-call result, wake, timeout, interrupt, snapshot, and mask state; save/install and return restoration remain separate. Source: `kernel/core/src/process/signal/poll.rs:154-178,282-321`, `kernel/core/src/process/signal/pause.rs:171-219`, `kernel/core/src/process/signal/mod.rs:64-85,208-230`, `kernel/core/src/syscall/poll.rs:88-121,124-155,188-215`. | Existing Scenario 5 hunts plus `MC_reach_wait_repeat_timeout.cfg` and `MC_reach_wait_repeat_signal.cfg`; `MC_control_wait_stale_second.cfg` corrupts the corrected second invocation. Terminal live/history and mask controls remain independent. |
| 6. Two-epoll nesting | Successful acyclic edges only within the bounded supported subset; ready/subject/outer-ready lock chain; required/delivered nested epochs. Source: `kernel/core/src/events/epoll/file.rs:64-125`, `kernel/core/src/events/epoll/entry.rs:280-330`, `kernel/core/src/events/subject.rs:126-153`. | `MC_hunt_s6_nested.cfg` checks `MCAcyclicEpollGraph`, lock ownership, and both epoch properties. |

## Brief section 5 invariants and properties

Each scenario oracle has an isolated config. A candidate in one hunt cannot
stop TLC before another required property is explored.

| Brief property | Definition / wrapper | Dedicated config or control |
|---|---|---|
| `SlotMapsOneOFD` | independent slot-table/shadow equality in `base.tla` / `MCSlotMapsOneOFD` | `MC_hunt_s1_slot_map.cfg`; `MC_control_slot_map_mutation.cfg` changes only the live slot to a wrong in-domain OFD |
| `CapturedReferenceStable` | `base!CapturedReferenceStable` / `MCCapturedReferenceStable` | `MC_hunt_s1_fd_exec.cfg` |
| `ReplacementExactlyOnce` | `base!ReplacementExactlyOnce` / `MCReplacementExactlyOnce` | `MC_hunt_s1_replacement.cfg` |
| `FdFlagsPerSlot` | `base!FdFlagsPerSlot` / `MCFdFlagsPerSlot` | `MC_hunt_s1_flags.cfg`; real alias witness and intentional shared-flag mutation controls |
| `ExecClosesExactlySnapshotMarked` | private installed-table closure | `MC_hunt_s1_exec.cfg` |
| `ExecCutoverIsolation` | private table equals its atomic cutover snapshot despite later old-table writes | four before/after exec reach configs; `MC_reach_exec_private_final_drop.cfg` preserves the no-external-owner final release; two exec mutation controls reject alias/wrong-table changes |
| `PollSnapshotOwnershipStable`, `PollSnapshotReleasedOnTerminal` | exact distinct identities plus exact FD-to-OFD owner vector, including duplicated slots | two poll snapshot reach configs; `MC_control_poll_snapshot_omission.cfg` and `MC_control_poll_snapshot_early_release.cfg` |
| `FreshWaitInvocation` | every second registration has fresh per-call state | timeout-first and signal-first repeat configs; `MC_control_wait_stale_second.cfg` |
| `NoPhantomLiveOFD`, `NoDeadOFDReference`, `OFDsNeverResurrect` | all strong owners, including private exec entries and every wait snapshot vector entry | `MC_hunt_lifetime.cfg`; lifetime and poll-owner mutation controls |
| `EpollKeyIdentity` | `base!EpollKeyIdentity` / `MCEpollKeyIdentity` | `MC_hunt_s2_key_identity.cfg`; valid reuse and wrong-OFD/stale-generation controls |
| `NoCrossReuseDelivery` | `base!NoCrossReuseDelivery` / `MCNoCrossReuseDelivery` | `MC_hunt_s2_cross_reuse.cfg` |
| `NoDeadInterest` | `base!NoDeadInterest` / `MCNoDeadInterest` | `MC_hunt_s2_epoll_delivery.cfg` |
| `DeliveryCommitOnCopyout` | `base!DeliveryCommitOnCopyout` / `MCDeliveryCommitOnCopyout` | `MC_hunt_s2_copyout.cfg` |
| `OneShotDisabledIffDelivered` | `base!OneShotDisabledIffDelivered` / `MCOneShotDisabledIffDelivered` | `MC_hunt_s2_oneshot.cfg` |
| `LevelReadyEventuallyRedelivered` | temporal `base!LevelReadyEventuallyRedelivered` | `MC_hunt_s2_level.cfg` |
| `CachedReadinessSound` | `base!CachedReadinessSound` / `MCCachedReadinessSound` | `MC_hunt_s3_cache.cfg` |
| `RegisteredTransitionNotLost` | temporal `base!RegisteredTransitionNotLost` | `MC_hunt_s3_registered_delivery.cfg`; mask transition isolated in `MC_hunt_s4_mask_transition.cfg` |
| `SignalfdRegistrationHasBinding` | `base!SignalfdRegistrationHasBinding` / `MCSignalfdRegistrationHasBinding` | `MC_hunt_s4_binding.cfg`; real pre-insert state reach in `MC_reach_s4_updated_before_insert.cfg` |
| `VisibleReadyWinsTerminalRace` | `base!VisibleReadyWinsTerminalRace` / `MCVisibleReadyWinsTerminalRace` | `MC_hunt_s5_arbitration.cfg`; both live terminal-scan reach configs |
| `TerminalScanMatchesLiveSnapshot` | `base!TerminalScanMatchesLiveSnapshot` / `MCTerminalScanMatchesLiveSnapshot` | normal terminal hunts plus `MC_control_terminal_scan_mutation.cfg` |
| `TemporaryMaskRestored` | `base!TemporaryMaskRestored` / `MCTemporaryMaskRestored` | `MC_hunt_s5_mask_restore.cfg`; `MC_control_mask_restore_mutation.cfg` |
| `AcyclicEpollGraph` | `base!AcyclicEpollGraph` / `MCAcyclicEpollGraph` | `MC_hunt_s6_nested.cfg`; controller-only reverse-edge mutation in `MC_control_epoll_cycle_mutation.cfg` |
| `SignalNotifyOrdering` | `base!SignalNotifyOrdering` / `MCSignalNotifyOrdering` | signal gap/completion configs; `MC_control_signal_notify_ordering.cfg` |
| `NestedReadyEpochPropagates` | temporal `base!NestedReadyEpochPropagates` | `MC_hunt_s6_nested.cfg` |
| `EventfdMutexExclusive` | `base!EventfdMutexExclusive` / `MCEventfdMutexExclusive` | eventfd mutex hunt, scope witness, and two intentional controls |
| `ReadinessWakesHaveProducerCause` | `base!ReadinessWakesHaveProducerCause` / `MCReadinessWakesHaveProducerCause` | arbitration hunt and producer-before-wake witness |

Structural oracles are checked non-vacuously only by their focused configs:
`ReadyCallbacksHaveProducerCause` and `ReadinessWakesHaveProducerCause` by
callback/producer hunts, `NestedEpochNeverRegresses` and `AcyclicEpollGraph`
by the nested hunt, and `EventfdMutexExclusive` by the eventfd hunt. The
neutral config does not claim coverage for those action families.
`MC_hunt_eventfd_mutex.cfg` exercises the mutex oracle
without the cache candidate; `MC_reach_eventfd_callback_scope.cfg` proves a
selected callback retains the owner and disables both mutators; and
`MC_hunt_s6_nested.cfg` exercises the graph invariant.
`AddUpdatedBeforeInterestInsert` is a reachability
predicate, not a production invariant. Its config lists
`MCSignalfdRegistrationHasBinding` before the intentionally negated reach
predicate, so the expected witness proves the real update-before-insert state
satisfies the binding oracle.
`TwoCheckersLoadedInvalid` is likewise a reach predicate;
`MC_reach_two_checkers_loaded_invalid.cfg` proves both actors can retain an
`invalid` load before either checker identity is installed.
`ValidKeyIdentitySurvivesReuse`, `ProducerBeforeReadinessWake`,
`DeadBeforeDisabledWitness`, and `EventfdCallbackScopeWitness` are
non-vacuity predicates.
Their focused reach/control configs keep these checks independent from
candidate hunts. In particular, `MC_control_dead_before_disabled.cfg` uses
controller state only to expose a dead-plus-disabled popped Entry, then checks
that the production dead-file action is enabled and the disabled action is
not.

## Production-action reachability audit

The controller-only `seenActions` set records completed base actions without
bounding reactive completion. Each config below intentionally fails only its
negated reach predicate.

| Previously absent production action | Focused reach config |
|---|---|
| `SysDup2Equal` | `MC_reach_sys_dup2_equal.cfg` |
| `FileTableDupCeil` | `MC_reach_file_table_dup_ceil.cfg` |
| `EpollDelInterest` | `MC_reach_epoll_del_interest.cfg` |
| `EpollControlError` | `MC_reach_epoll_control_error.cfg` |
| `EpollDiscardEmptyPreparation` | `MC_reach_epoll_discard_empty.cfg` |
| `SignalFileReadThread` | `MC_reach_signal_read_thread.cfg` |
| `SignalFileReadProcess` | `MC_reach_signal_read_process.cfg` |
| `PollFilesInitialReady` | `MC_reach_poll_initial_ready.cfg` |

The `EventfdNotifyReturn` production boundary is enabled by
`MC_hunt_eventfd_mutex.cfg`, `MC_hunt_s3_cache.cfg`, and
`MC_reach_eventfd_callback_scope.cfg`. It is also consumed by the positive
Trace fixture.

| Round-4 production boundary or witness | Focused config |
|---|---|
| `SigQueuesNotifyThread` | `MC_reach_signal_notify_thread.cfg` |
| `SigQueuesNotifyProcess` | `MC_reach_signal_notify_process.cfg` |
| `SigQueuesNotifyReturn` after exact key callback discharge | `MC_reach_signal_interleaved_completion.cfg` |
| unlocked thread enqueue/notify gap | `MC_reach_signal_thread_gap.cfg` |
| post-enqueue ADD/waiter/mask interleaving | `MC_reach_signal_interleave_gap.cfg` |
| live ready before historical Waker state | `MC_reach_terminal_ready_before_wake.cfg` |
| stale historical ready after live consume | `MC_reach_stale_visible_after_consume.cfg` |

The action-union audit therefore covers all 74 production actions, including
every action in the round-2 reach table and all three split signal completion
actions.
`MC.cfg` is explicitly an FD-lifecycle smoke check. Its action set contains
only F_SETFL capture/use, close/drop, and insert/reuse; only FD lifetime,
slot-shadow, and captured-reference oracles are treated as non-vacuous there.
Callback, epoll, signal, wait, and topology invariants map to focused configs.
All 69 durable `MC*.cfg` artifacts are included in the config audit.

## Brief section 6.1 candidate findings

| Candidate | Mutation-sensitive activation | Oracle config |
|---|---|---|
| MC-1 | Cached timer/event readiness survives a live consume/disarm mutation without a matching invalidation epoch | `MCCachedReadinessSound` in `MC_hunt_s3_cache.cfg` |
| MC-2 | A completed registration is followed by a signalfd mask transition creating a readiness epoch without corresponding delivery | `MCRegisteredTransitionNotLost` in `MC_hunt_s4_mask_transition.cfg` |
| MC-4 | A registered waiter has observed readiness when timeout or interruption selects a terminal result | `MCVisibleReadyWinsTerminalRace` in `MC_hunt_s5_arbitration.cfg` |
| MC-5a | ET preparation mutates the current readiness epoch, then userspace copyout faults without a recoverable token | `MCDeliveryCommitOnCopyout` in `MC_hunt_s2_copyout.cfg` |
| MC-5b | One-shot is disabled for a current event-bearing epoch without prepared or completed delivery | `MCOneShotDisabledIffDelivered` in `MC_hunt_s2_oneshot.cfg` |
| MC-6 | The last modeled strong reference is released while a weak epoll interest survives | `MCNoDeadInterest` in `MC_hunt_s2_epoll_delivery.cfg` |
| MC-7a | F_SETFL uses a captured OFD after the numeric slot advances to a different generation | `MCCapturedReferenceStable` in `MC_hunt_s1_fd_exec.cfg` |
| MC-7b | A registered key's numeric FD advances to a different OFD before delivery | `MCNoCrossReuseDelivery` in `MC_hunt_s2_cross_reuse.cfg` |
| MC-8a | Two duplicated slots alias one OFD; F_SETFD mutates one descriptor flag while F_SETFL remains shared | `MCFdFlagsPerSlot` and alias witness controls for `MC_hunt_s1_flags.cfg` |
| MC-8b | External shared-table duplication or CLOEXEC mutation wins either before the atomic clone/install boundary and appears in the private snapshot, or after it and remains isolated from the private table; exec then closes only the private snapshot-marked descriptors | `MCExecCutoverIsolation`, four focused reach configs, two mutation controls, and `MCExecClosesExactlySnapshotMarked` in `MC_hunt_s1_exec.cfg` |

These are model-checking candidates or controls, not confirmed implementation
bugs. Confirmation remains subject to a minimized counterexample, concrete
Rust sequence, Linux comparison, and an isolated Asterinas `SMP=2`
regression.

## Trace validation controls

| Purpose | Config |
|---|---|
| Fully quiescent positive fixture, including split signal notify and syscall-return cleanup | `Trace.cfg` |
| Wrong callback actor | `Trace_mutated.cfg` |
| Selected callback omitted | `Trace_omitted_callback.cfg` |
| Eventfd owner released early | `Trace_early_owner_release.cfg` |
| Complete dead-file cleanup post-state | `Trace_dead_file.cfg` |
| One-field stale dead-entry identity | `Trace_dead_file_mutated.cfg` |
| One-field wrong terminal live snapshot | `Trace_terminal_snapshot_mutated.cfg` |
| Focused positive initial-ready snapshot capture/release | `Trace_terminal_snapshot_positive.cfg` |
| One-field wrong captured FD-to-OFD owner audit | `Trace_poll_snapshot_mutated.cfg` |
| One-field wrong signal notify epoch | `Trace_signal_notify_mutated.cfg` |
| Truncated F_SETFL capture | `Trace_truncated_fsetfl.cfg` |
| Truncated temporary-mask installation | `Trace_truncated_mask.cfg` |
| Truncated epoll ctl capture | `Trace_truncated_ctl.cfg` |

Each negative fixture is rejected by direct branch post-state validation or
`TraceMatched`; full JSON consumption alone is insufficient.

## Scope and unsupported behavior

- The base model contains no synthetic final-drop, wait-reset, or nested-cycle
  rejection action. `MC_Controls.tla` mutations are isolated test-only
  transitions and cannot stand in for implementation behavior.
- Terminal-snapshot substitution, slot-shadow divergence, mask corruption,
  reverse-edge insertion, and notify-before-enqueue exist only in
  `MC_Controls.tla`. They prove their named oracles are independent detectors;
  they are not production behavior or candidate implementation findings.
- The pinned epoll control path
  (`kernel/core/src/events/epoll/file.rs:64-125`) has no explicit
  cycle-rejection branch. The action admits only the bounded successful
  acyclic subset; `AcyclicEpollGraph` checks that modeled subset. Other cyclic
  behavior remains unsupported/unverified, not an assumed bug or guarantee.
- The bounded scope remains two threads, three FD slots, three OFDs, two epoll
  instances, x86_64, and the file classes named in the brief.

## Audit result

The final audit compares brief sections 2, 5, and 6.1 with dedicated configs;
compares every production action in `base.ProductionActionNames` with the
union of all `EnabledActions`; checks zero `PROPERTIES` plus `SYMMETRY`
configs; compares both Trace dispatches with the instrumentation table; and
resolves every machine-indexed pinned source path/range. Exact commands and
results are recorded in `remediation-report-round5.md`.

### Durable config inventory

The mechanical audit requires every checked configuration to appear here.
`MC.cfg` is the FD-only neutral smoke. Prefixes classify the rest exactly:
`MC_hunt_*` are clean/candidate oracle hunts, `MC_reach_*` intentionally fail
a negated reach predicate, and `MC_control_*` are controller-only mutations.

```text
MC.cfg
MC_control_dead_before_disabled.cfg
MC_control_epoll_cycle_mutation.cfg
MC_control_eventfd_early_release.cfg
MC_control_eventfd_second_mutation.cfg
MC_control_exec_private_alias.cfg
MC_control_exec_wrong_table_cloexec.cfg
MC_control_lifetime_phantom_mutation.cfg
MC_control_lifetime_resurrection_mutation.cfg
MC_control_mask_restore_mutation.cfg
MC_control_poll_snapshot_early_release.cfg
MC_control_poll_snapshot_omission.cfg
MC_control_s1_flags_mutation.cfg
MC_control_s1_flags_witness.cfg
MC_control_s2_key_stale_generation.cfg
MC_control_s2_key_wrong_ofd.cfg
MC_control_signal_notify_ordering.cfg
MC_control_slot_map_mutation.cfg
MC_control_terminal_scan_mutation.cfg
MC_control_wait_stale_second.cfg
MC_hunt_eventfd_mutex.cfg
MC_hunt_lifetime.cfg
MC_hunt_s1_exec.cfg
MC_hunt_s1_fd_exec.cfg
MC_hunt_s1_flags.cfg
MC_hunt_s1_replacement.cfg
MC_hunt_s1_slot_map.cfg
MC_hunt_s2_copyout.cfg
MC_hunt_s2_cross_reuse.cfg
MC_hunt_s2_epoll_delivery.cfg
MC_hunt_s2_key_identity.cfg
MC_hunt_s2_level.cfg
MC_hunt_s2_oneshot.cfg
MC_hunt_s3_cache.cfg
MC_hunt_s3_registered_delivery.cfg
MC_hunt_s4_binding.cfg
MC_hunt_s4_mask_transition.cfg
MC_hunt_s5_arbitration.cfg
MC_hunt_s5_mask_restore.cfg
MC_hunt_s6_nested.cfg
MC_reach_epoll_control_error.cfg
MC_reach_epoll_del_interest.cfg
MC_reach_epoll_discard_empty.cfg
MC_reach_eventfd_callback_scope.cfg
MC_reach_exec_after_cloexec.cfg
MC_reach_exec_after_dup.cfg
MC_reach_exec_before_cloexec.cfg
MC_reach_exec_before_dup.cfg
MC_reach_exec_private_final_drop.cfg
MC_reach_file_table_dup_ceil.cfg
MC_reach_poll_initial_ready.cfg
MC_reach_poll_snapshot_close.cfg
MC_reach_poll_snapshot_release.cfg
MC_reach_producer_before_wake.cfg
MC_reach_s2_key_identity_reuse.cfg
MC_reach_s4_updated_before_insert.cfg
MC_reach_signal_interleave_gap.cfg
MC_reach_signal_interleaved_completion.cfg
MC_reach_signal_notify_process.cfg
MC_reach_signal_notify_thread.cfg
MC_reach_signal_read_process.cfg
MC_reach_signal_read_thread.cfg
MC_reach_signal_thread_gap.cfg
MC_reach_stale_visible_after_consume.cfg
MC_reach_sys_dup2_equal.cfg
MC_reach_terminal_ready_before_wake.cfg
MC_reach_two_checkers_loaded_invalid.cfg
MC_reach_wait_repeat_signal.cfg
MC_reach_wait_repeat_timeout.cfg
Trace.cfg
Trace_dead_file.cfg
Trace_dead_file_mutated.cfg
Trace_early_owner_release.cfg
Trace_mutated.cfg
Trace_omitted_callback.cfg
Trace_poll_snapshot_mutated.cfg
Trace_signal_notify_mutated.cfg
Trace_terminal_snapshot_mutated.cfg
Trace_terminal_snapshot_positive.cfg
Trace_truncated_ctl.cfg
Trace_truncated_fsetfl.cfg
Trace_truncated_mask.cfg
```
