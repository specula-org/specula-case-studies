# Formal-model QA remediation report, round 3

Pinned Asterinas source: `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`.
The Asterinas worktree remained clean. No source file, agent configuration, or
modeling-guidance artifact was modified.

Commands below ran from `../.specula-output/spec`:

```sh
JAVA=/nix/store/mxf12821brqjb2kv1p3v8b9n6d5741y0-openjdk-21.0.12+8/bin/java
CP=/home/chin39/Documents/play/Specula/lib/tla2tools.jar:/home/chin39/Documents/play/Specula/lib/CommunityModules-deps.jar

$JAVA -cp "$CP" tla2sany.SANY MODULE.tla
$JAVA -Xmx1g -XX:+UseParallelGC -cp "$CP" \
  tlc2.TLC -terse -workers 1 -metadir /tmp/RUN/meta \
  -config CONFIG.cfg MODULE
```

`MC_hunt_s2_level.cfg` used `-Xmx2g -workers 2`. TLC results are
classified as:

- **PASS**: exhaustive bounded search completed without a checked oracle
  failing.
- **CANDIDATE**: a focused production model violated its isolated oracle.
  This is not a confirmed Asterinas implementation bug.
- **REACH**: an intentionally negated non-vacuity predicate failed after the
  named production state or action was reached.
- **CONTROL**: an intentional controller-only mutation or branch-order setup
  failed its designated oracle.

## Independent-review issue closure

| # | Original defect | Exact artifacts and operators changed | Pinned source evidence | Validation command and result | Remaining limitation |
|---|---|---|---|---|---|
| 1 | The eventfd owner could be released after notification selection but before every synchronous Entry/Waker callback returned; the old mutex oracle did not expose early release. | `base.tla`: added exact `eventNotifyKeys`, `eventNotifyWaiters`, and `eventNotifyCounter`; extended `EventfdMutexOwnerFrom`; split `EventfdNotify` from `EventfdNotifyReturn`; discharged obligations in `ReadySetPushSuppressed`, `ObserverCallbackRelease`, and `WaiterReadinessWake`; strengthened `EventfdMutexExclusive`; added `EventfdCallbackScopeWitness`. `MC.tla`: added the unbounded reactive return wrapper, fairness, and the negated scope witness. `MC_Controls.tla`: added `MCInjectEventfdEarlyOwnerRelease` and `MCInjectEventfdSecondMutation`. Added `MC_hunt_eventfd_mutex.cfg`, `MC_reach_eventfd_callback_scope.cfg`, and both eventfd mutation configs. | The same `counter.lock()` guard encloses counter mutation and `pollee.notify`: `kernel/core/src/syscall/eventfd.rs:124-159`. `SyncSubject` calls selected observers synchronously before returning: `kernel/core/src/events/subject.rs:126-153`. | Mutex hunt: **PASS**, 301/178 states, depth 19. Scope witness: **REACH**, exit 12 only at `MCNoEventfdCallbackScopeWitness`, 17/13, depth 5. Early-release and second-mutation controls: **CONTROL**, each exit 12 only at `MCEventfdMutexExclusive`, 25/19, depth 6. The positive Trace consumes one Entry callback and one Waker callback before `EventfdNotifyReturn`. | The counter value is bounded and arithmetic details are abstracted. Selected callbacks are serialized into bounded semantic steps, but the owner and exact obligations preserve the production synchronous scope. |
| 2 | A positive trace could consume all input events while a selected synchronous callback was still pending; no omitted-callback or early-owner trace control existed. | `Trace.tla`: added exact Entry and Waker selection records, eventfd pending-set post-state checks, `EventfdNotifyReturn`, `SynchronousCallbacksQuiescent`, and the quiescence conjunct in `TraceMatched`. Rebuilt `remediation-positive.json`; made `remediation-mutated-negative.json` a one-field observer-actor mutation; added `remediation-omitted-callback-negative.json` and `remediation-early-owner-release-negative.json` with matching configs. | Observer callbacks execute inside the retained observer traversal: `kernel/core/src/events/subject.rs:126-153`. Eventfd retains its counter guard around that call: `kernel/core/src/syscall/eventfd.rs:124-159`. | `Trace.cfg`: **PASS**, 33/32 states, depth 32. Wrong actor: **CONTROL**, exit 13 at `TraceMatched`, 22/22, depth 22. Omitted callback: **CONTROL**, exit 13 at `TraceMatched`, 24/24, depth 24. Early owner release: **CONTROL**, exit 13 at `TraceMatched`, 22/22, depth 22. Canonical JSON diff shows exactly one changed field in each one-field control. | These are model fixtures, not traces captured from an instrumented Asterinas VM. The instrumentation handoff now states the fields required to collect equivalent traces. |
| 3 | Scenario 4 Trace checks covered too little of `EntryUpdatePoll` and consumer registration post-state. | `Trace.tla`: added `ValidateEntryUpdate`, `Scenario4RecordFrom`, `Scenario4RecordsFrom`, `Scenario4PostRecords`, and `ValidateScenario4Records`. `instrumentation-spec.md` now requires exact waiter, enablement, trigger, slot generation, registration, actor/consumer binding, ready epoch, and consumer-ready epoch fields. The positive fixture exercises an empty pre-ADD consumer scan and a populated post-ADD scan. | `Entry::update` updates the Entry, registers the PollHandle, then performs the live check: `kernel/core/src/events/epoll/entry.rs:155-166`. Epoll wait polls entries in the waiting actor: `kernel/core/src/events/epoll/file.rs:191-205`. Signalfd readiness is current-thread-relative: `kernel/core/src/syscall/signalfd.rs:171-179,205-215`. | Positive Trace **PASS** validates every listed field. `MC_reach_s4_updated_before_insert.cfg`: **REACH**, 458/152, depth 6, while the binding oracle still holds. `MC_hunt_s4_binding.cfg` remains an isolated **CANDIDATE**, 872/349, depth 7, only after completed registration. | The bounded fixture has two actors, one signalfd OFD, and one focused epoll. The completed-registration result remains a model-checking candidate pending trace and VM confirmation. |
| 4 | `EpollKeyIdentity` was TypeOK-tautological and could not reject a wrong in-domain OFD or stale ADD generation. | `base.tla`: added independent `interestIdentity` audit state, populated it only from the captured ctl FD/OFD/generation in `EpollAddInterest`, cleared it on DEL/dead cleanup, replaced `EpollKeyIdentity`, and added `ValidKeyIdentitySurvivesReuse`. `Trace.tla` and the `KEY` instrumentation profile validate all audit fields. `MC_Controls.tla` adds wrong-OFD and stale-generation mutations. Added the positive reuse reach and two negative configs. | ADD constructs and updates the Entry from the already captured target before insertion: `kernel/core/src/events/epoll/file.rs:65-84,96-125`. `EntryKey` retains file identity separately from the numeric slot: `kernel/core/src/events/epoll/entry.rs:46-67`. FD replacement advances the table entry independently: `kernel/core/src/fs/file/file_table.rs:190-205`. | Key hunt: **PASS**, 124/75, depth 8. Valid ADD/reuse: **REACH**, exit 12 only at `MCNoValidKeyIdentityReuse`, 302/166, depth 7, while `MCEpollKeyIdentity` holds. Wrong in-domain OFD: **CONTROL**, exit 12 at `MCEpollKeyIdentity`, 7/6, depth 5. Stale generation after reuse: **CONTROL**, exit 12 at the same oracle, 56/35, depth 7. | OFD allocation identities and generations are stable bounded labels. The model does not represent allocator-address reuse after object destruction. |
| 5 | `EntryPollDisabled` could consume an Entry after weak-file upgrade had already failed, reversing Rust's early-return order. | `base.tla`: `EntryPollDisabled` now requires the OFD to be alive; `EntryPollDeadFile` remains enabled regardless of the enabled bit; added `DeadBeforeDisabledWitness`. `MC_Controls.tla` adds only the dead-plus-disabled popped-state setup, not a replacement implementation branch. Added `MC_control_dead_before_disabled.cfg`. | `Entry::poll` executes `self.file()?` before locking `Inner` and testing `is_enabled`: `kernel/core/src/events/epoll/entry.rs:103-124`. | **CONTROL**, exit 12 only at the intentionally negated `MCNoDeadBeforeDisabledWitness`, 25/16 states, depth 8. The witness requires `ENABLED EntryPollDeadFile` and `~ENABLED EntryPollDisabled` in the same dead-plus-disabled state. | The seam setup is controller-only because reaching a simultaneously popped, dead, disabled Entry is not otherwise forced by the bounded production subset. Both compared branches are production actions. |
| 6 | `WaiterReadinessWake` could fabricate visible readiness without a producer, including with `SourceLimit = 0`; Scenario 5 did not require a real readiness event. | `base.tla`: added producer-scoped `waitReadyToken` and `lastReadyWake`; producer notifications in `TimerfdNotify`, `EventfdNotify`, and signal enqueue actions create exact OFD/actor/epoch tokens; `WaiterReadinessWake` consumes one; added `ReadinessWakesHaveProducerCause` and `ProducerBeforeReadinessWake`. `MC.tla` wraps both. `MC_hunt_s5_arbitration.cfg` now enables and budgets `TimerfdExpired`/`TimerfdNotify`; added `MC_reach_producer_before_wake.cfg`. Trace and instrumentation validate the producer token and separate callback actor from target waiter. | `Pollee::notify` invalidates then synchronously visits observers: `kernel/core/src/process/signal/poll.rs:167-178`. Poller registration precedes waiting, and its Waker callback wakes the target Waiter: `kernel/core/src/process/signal/poll.rs:154-165,307-321`. | Producer-before-wake: **REACH**, exit 12 only at `MCNoProducerBeforeReadinessWake`, 20/15, depth 5. Scenario 5: **CANDIDATE** only at `MCVisibleReadyWinsTerminalRace`, 462/224, depth 7; the causality invariant is checked first and holds. The positive Trace records callback `tid=t1`, `args.target=t2`, EventOFD, actor `t1`, epoch 1. | `PollFilesRegisterPoller` abstracts its bounded poll set to the live modeled OFDs. One token per waiter represents a selected Waker callback; fairness and wake ordering beyond the brief remain out of scope. |

## SANY, Trace, and base controls

| Check | Result |
|---|---|
| `tla2sany.SANY base.tla` | exit 0 |
| `tla2sany.SANY MC.tla` | exit 0 |
| `tla2sany.SANY MC_Controls.tla` | exit 0 |
| `tla2sany.SANY Trace.tla` | exit 0 |
| `Trace.cfg` | **PASS**, 33 generated / 32 distinct, depth 32 |
| `Trace_mutated.cfg` | **CONTROL**, exit 13 at `TraceMatched`, 22/22, depth 22 |
| `Trace_omitted_callback.cfg` | **CONTROL**, exit 13 at `TraceMatched`, 24/24, depth 24 |
| `Trace_early_owner_release.cfg` | **CONTROL**, exit 13 at `TraceMatched`, 22/22, depth 22 |
| `base.cfg`, simulation `num=50`, depth 35 | **PASS**, 1,751 states checked, 50 traces |

The wrong-actor fixture differs from the positive fixture only in
`callbacks[0].actor: t1 -> t2`. The early-release fixture differs only in
`EventfdNotify.state.eventfd_owner: t1 -> no_thread`. The omitted-callback
fixture removes `ReadySetPushAcquire`, `ReadySetPush`,
`ReadySetPushNotifySubject`, and `ObserverCallbackRelease` while retaining the
selection and return events.

## Full bounded TLC matrix

All 43 neutral/focused MC configs were rerun after the final semantic edit.

| Config | Classification and checked result | Generated / distinct; depth |
|---|---|---|
| `MC.cfg` | PASS | 288 / 156; 7 |
| `MC_control_dead_before_disabled.cfg` | CONTROL: `MCNoDeadBeforeDisabledWitness`, exit 12 | 25 / 16; 8 |
| `MC_control_eventfd_early_release.cfg` | CONTROL: `MCEventfdMutexExclusive`, exit 12 | 25 / 19; 6 |
| `MC_control_eventfd_second_mutation.cfg` | CONTROL: `MCEventfdMutexExclusive`, exit 12 | 25 / 19; 6 |
| `MC_control_lifetime_phantom_mutation.cfg` | CONTROL: `MCNoPhantomLiveOFD`, exit 12 | 5 / 4; 4 |
| `MC_control_lifetime_resurrection_mutation.cfg` | CONTROL: `MCOFDsNeverResurrect`, exit 12 | 5 / 4; 4 |
| `MC_control_s1_flags_mutation.cfg` | CONTROL: `MCFdFlagsPerSlot`, exit 12 | 19 / 14; 4 |
| `MC_control_s1_flags_witness.cfg` | CONTROL: `MCNoAliasedDescriptorFlagWitness`, exit 12 | 2,942 / 1,093; 6 |
| `MC_control_s2_key_stale_generation.cfg` | CONTROL: `MCEpollKeyIdentity`, exit 12 | 56 / 35; 7 |
| `MC_control_s2_key_wrong_ofd.cfg` | CONTROL: `MCEpollKeyIdentity`, exit 12 | 7 / 6; 5 |
| `MC_hunt_eventfd_mutex.cfg` | PASS | 301 / 178; 19 |
| `MC_hunt_lifetime.cfg` | PASS | 77 / 39; 9 |
| `MC_hunt_s1_exec.cfg` | PASS | 53 / 28; 5 |
| `MC_hunt_s1_fd_exec.cfg` | PASS | 288 / 156; 7 |
| `MC_hunt_s1_flags.cfg` | PASS | 10,593 / 3,308; 9 |
| `MC_hunt_s1_replacement.cfg` | PASS | 397 / 247; 7 |
| `MC_hunt_s1_slot_map.cfg` | PASS | 16 / 11; 4 |
| `MC_hunt_s2_copyout.cfg` | CANDIDATE: `MCDeliveryCommitOnCopyout`, exit 12 | 106 / 71; 9 |
| `MC_hunt_s2_cross_reuse.cfg` | PASS | 3,810 / 1,395; 26 |
| `MC_hunt_s2_epoll_delivery.cfg` | CANDIDATE: `MCNoDeadInterest`, exit 12 | 23 / 15; 7 |
| `MC_hunt_s2_key_identity.cfg` | PASS | 124 / 75; 8 |
| `MC_hunt_s2_level.cfg` | PASS | 8,897 / 2,794; 21 |
| `MC_hunt_s2_oneshot.cfg` | CANDIDATE: `MCOneShotDisabledIffDelivered`, exit 12 | 639 / 360; 9 |
| `MC_hunt_s3_cache.cfg` | CANDIDATE: `MCCachedReadinessSound`, exit 12 | 1,897 / 851; 9 |
| `MC_hunt_s3_registered_delivery.cfg` | PASS | 1,487 / 669; 17 |
| `MC_hunt_s4_binding.cfg` | CANDIDATE: `MCSignalfdBindingCoversConsumer`, exit 12 | 872 / 349; 7 |
| `MC_hunt_s4_mask_transition.cfg` | CANDIDATE: `MCRegisteredTransitionNotLost`, exit 13 | 41 / 30; 8 |
| `MC_hunt_s5_arbitration.cfg` | CANDIDATE: `MCVisibleReadyWinsTerminalRace`, exit 12 | 462 / 224; 7 |
| `MC_hunt_s5_mask_restore.cfg` | PASS | 228 / 110; 11 |
| `MC_hunt_s6_nested.cfg` | PASS | 2,113 / 890; 13 |
| `MC_reach_epoll_control_error.cfg` | REACH: `MCNotReachedEpollControlError`, exit 12 | 4 / 3; 3 |
| `MC_reach_epoll_del_interest.cfg` | REACH: `MCNotReachedEpollDelInterest`, exit 12 | 26 / 17; 6 |
| `MC_reach_epoll_discard_empty.cfg` | REACH: `MCNotReachedEpollDiscardEmptyPreparation`, exit 12 | 329 / 183; 10 |
| `MC_reach_eventfd_callback_scope.cfg` | REACH: `MCNoEventfdCallbackScopeWitness`, exit 12 | 17 / 13; 5 |
| `MC_reach_file_table_dup_ceil.cfg` | REACH: `MCNotReachedFileTableDupCeil`, exit 12 | 7 / 5; 3 |
| `MC_reach_poll_initial_ready.cfg` | REACH: `MCNotReachedPollFilesInitialReady`, exit 12 | 11 / 9; 4 |
| `MC_reach_producer_before_wake.cfg` | REACH: `MCNoProducerBeforeReadinessWake`, exit 12 | 20 / 15; 5 |
| `MC_reach_s2_key_identity_reuse.cfg` | REACH: `MCNoValidKeyIdentityReuse`, exit 12 | 302 / 166; 7 |
| `MC_reach_s4_updated_before_insert.cfg` | REACH: `MCNoAddUpdatedBeforeInterestInsert`, exit 12 | 458 / 152; 6 |
| `MC_reach_signal_read_process.cfg` | REACH: `MCNotReachedSignalFileReadProcess`, exit 12 | 38 / 8; 4 |
| `MC_reach_signal_read_thread.cfg` | REACH: `MCNotReachedSignalFileReadThread`, exit 12 | 44 / 11; 4 |
| `MC_reach_sys_dup2_equal.cfg` | REACH: `MCNotReachedSysDup2Equal`, exit 12 | 2 / 2; 2 |
| `MC_reach_two_checkers_loaded_invalid.cfg` | REACH: `MCNoTwoCheckersLoadedInvalid`, exit 12 | 12 / 9; 5 |

The eight production actions previously absent from all enabled sets retain
their dedicated REACH controls: `SysDup2Equal`, `FileTableDupCeil`,
`EpollDelInterest`, `EpollControlError`, `EpollDiscardEmptyPreparation`,
`SignalFileReadThread`, `SignalFileReadProcess`, and
`PollFilesInitialReady`.

## Audit results

- Action mapping is exact: 71 `MC.ActionNames`, 71 names in the union of all
  `EnabledActions`, 71 `Trace.MatchEvent` branches, and 71 instrumentation
  rows. Every set difference is empty.
- Brief/config coverage is exact: all 43 `MC*.cfg` artifacts are named in
  `brief-coverage.md`; all 17 brief section-5 oracles have one base definition,
  one MC wrapper, and at least one checked config.
- `EventfdNotifyReturn` is an unbounded reactive completion. `Reactive` leaves
  introduction counters unchanged; callback, ctl, delivery, poll, exec, and
  mask-restoration completions remain unbounded.
- Controller-only actions remain confined to `MC_Controls.tla`; none appears
  in `base.Next`, `MC.ActionNames`, `Trace.MatchEvent`, or the instrumentation
  action table.
- Citation audit: all 71 production action blocks and all 36 structural,
  scenario, temporal, and reach-oracle blocks contain a full pinned
  `kernel/...rs:line` citation. All 111 unique cited source starts resolve and
  are within the pinned files.
- Lifetime controls remain mutation-sensitive. `MC_hunt_lifetime.cfg` passes,
  while the phantom-live and resurrection mutations fail their intended
  oracles. No corrected production run reaches `ofdRefs = 0 /\ ofdAlive` or a
  resurrected modeled allocation identity.
- Trace JSON audit: all four fixtures pass `jq -e`; the positive trace has
  `tid=t1` and `args.target=t2` for its producer-scoped readiness wake; exact
  Scenario 4 records contain every required field.
- TLC-generated transient count in the durable spec directory is zero. The 68
  generated `*_TTrace_*.tla`/`.bin` files were moved to
  `/tmp/asterinas-r3-transients.027bAe`.
- Source fence: `git rev-parse HEAD` returned
  `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`; `git status --short`,
  `git diff --stat`, and `git diff --name-only` were empty.

The CANDIDATE rows remain formal-model candidates. None is classified here as
a confirmed Asterinas implementation defect.
