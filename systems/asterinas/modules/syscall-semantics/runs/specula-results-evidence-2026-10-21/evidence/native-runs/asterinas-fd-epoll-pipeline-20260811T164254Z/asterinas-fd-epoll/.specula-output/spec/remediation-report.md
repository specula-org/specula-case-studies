# Formal-model QA remediation report

Pinned Asterinas source: `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`.
No Asterinas source file was modified.

Command definitions used below:

```sh
JAVA=/nix/store/mxf12821brqjb2kv1p3v8b9n6d5741y0-openjdk-21.0.12+8/bin/java
CP=/home/chin39/Documents/play/Specula/lib/tla2tools.jar:/home/chin39/Documents/play/Specula/lib/CommunityModules-deps.jar
$JAVA -cp "$CP" tla2sany.SANY MODULE.tla
$JAVA -Xmx1g -XX:+UseParallelGC -cp "$CP" tlc2.TLC -terse -workers 1 +  -metadir /tmp/specula-final-matrix/NAME -config CONFIG.cfg MODULE
```

The level-trigger run used `-Xmx2g -workers 2`. The base smoke used
`-simulate num=50 -depth 35`.

## Review-issue closure

| # | Original defect | Exact artifacts/operators changed | Pinned source evidence | Validation command and result | Remaining limitation |
|---|---|---|---|---|---|
| 1 | Scenario 4 binding invariant rejected legal ADD insertion before poller registration. | `base.tla`: `CompletedRegistration`, `EpollAddInterest`, `EntryUpdatePoll`, `SignalfdBindingCoversConsumer`, `S4LegalAddIntermediate`; `MC_control_s4_legal_intermediate.cfg`; `MC_hunt_s4_binding.cfg`. | Interest insertion precedes `Entry::update` at `kernel/core/src/events/epoll/file.rs:96-125`; registration/check is `kernel/core/src/events/epoll/entry.rs:155-166`; signalfd registration is `kernel/core/src/syscall/signalfd.rs:205-215`. | `-config MC_control_s4_legal_intermediate.cfg MC`: exit 12 only at deliberately negated `MCS4LegalAddIntermediateAbsent`, 4/3 states. Because `MCSignalfdBindingCoversConsumer` is checked first, the legal intermediate satisfies it. Separate `-config MC_hunt_s4_binding.cfg MC`: exit 12 at `MCSignalfdBindingCoversConsumer` after completed registration, 654/194 states. | Two actors, one signalfd OFD, one focused epoll. The completed-registration violation remains a candidate pending `SMP=2` confirmation. |
| 2 | `ReadySetPush` could fabricate readiness without a producer notification. | `base.tla`: `sourceEpoch`, `callbackEpoch`, `callbackActor`, `TimerfdNotify`, `EventfdNotify`, signal enqueue actions, `ReadySetPushAcquire`, `ReadySetPush`, `ReadySetPushSuppressed`, `ReadyCallbacksHaveProducerCause`. | `Pollee::notify` invalidates then notifies at `kernel/core/src/process/signal/poll.rs:167-178`; subject invokes callbacks at `kernel/core/src/events/subject.rs:126-149`; callback pushes at `kernel/core/src/events/epoll/entry.rs:280-330`. | Neutral `-config MC.cfg MC`: pass, 288/156 states. `MC_hunt_s2_cross_reuse.cfg`: pass, 3794/1389. All callback-bearing hunts enable `MCReadyCallbacksHaveProducerCause`. | Epochs abstract concrete event masks to the modeled readiness class; instrumentation must capture synchronous callback selection without adding locks. |
| 3 | F_SETFL was atomic lookup/use while close-range CLOEXEC incorrectly interleaved per slot. | `base.tla:531` `FcntlSetFlCapture`, `base.tla:559` `FcntlSetFlUse`, `base.tla:778` `SysCloseRangeCloexec`; corresponding MC/Trace branches and instrumentation rows. | F_SETFL captures then uses at `kernel/core/src/syscall/fcntl.rs:87-94` via `kernel/core/src/fs/file/file_table.rs:326-367`. Close range holds one write guard for the loop at `kernel/core/src/syscall/close.rs:76-101`. | `MC_hunt_s1_fd_exec.cfg`: pass, 288/156. `MC_hunt_s1_flags.cfg`: pass, 715/197. Positive trace: captured timer survives close/reuse and is used while slot names event; pass, 11/10 states. | Bounded to three slots and the F_SETFL status bit represented by one Boolean. |
| 4 | Cache PC omitted the loaded value and checker identity, excluding two pre-install invalid loads. | `base.tla`: `CacheStates` includes actors; `PollLocal.loaded`; `PolleePollWithLoad`, `PolleePollWithBeginCheck`, `PolleePollWithConcurrentCheck`, `PolleePollWithCache`; Trace POLL profile. | Separate load, branch, task-pointer swap, live check, and compare-exchange are at `kernel/core/src/process/signal/poll.rs:106-148`. | `MC_hunt_s3_cache.cfg`: isolated exit 12 at `MCCachedReadinessSound`, 1988/897 states. This hunt permits both actors to load `invalid` before either installs its identity. | Task pointers are abstracted to two actor IDs; weak-CAS spurious failure and hardware memory-order detail are outside this model. |
| 5 | Trace conflated executing actor with target signal queue/waiter. | `base.tla:1597` `SigQueuesEnqueueThread(actor,target)` and `base.tla:1785` wake actions; `Trace.tla:86` `ValidatePostState` and `Trace.tla:325` `MatchEvent`; `instrumentation-spec.md` envelope and target rows. | Queue destination differs from sender at `kernel/core/src/process/signal/sig_queues.rs:38-45` and `kernel/core/src/process/posix_thread/mod.rs:249-270`; callback/wait ownership is `kernel/core/src/process/signal/poll.rs:275-321`. | Positive trace contains `tid=t1,args.target=t2` for `WaiterTimeoutExpires` and passes, 11/10 states. Mutating only F_SETFL acted OFD fails `TraceMatched`, exit 13, 5/5 states. | Synthetic controls validate the Trace contract; production probes and an `SMP=2` trace have not been generated in this phase. |
| 6 | Cross-reuse/capture/nesting properties were constructional; readiness liveness could be discharged by old history. | `base.tla`: `slotEpoch`, `keySlotEpoch`, `captureEpoch`, `readyEpoch`, `queuedEpoch`, `deliveredEpoch`, `nestedRequiredEpoch`, `nestedDeliveredEpoch`; `CapturedReferenceStable`, `NoCrossReuseDelivery`, `LevelReadyEventuallyRedelivered`, `RegisteredTransitionNotLost`, `NestedReadyEpochPropagates`. | Captured Arc semantics: `kernel/core/src/fs/file/file_table.rs:326-367`. Epoll key and delivery: `kernel/core/src/events/epoll/entry.rs:46-67,116-149,367-397`. Nested callback propagation: `kernel/core/src/events/subject.rs:126-153`. | Capture and cross-reuse hunts pass; level redelivery passes 4059/1339; registered timer delivery passes 895/409; nested propagation passes 1433/610. Mask-transition hunt retains the epoch-sensitive candidate violation, exit 13 at `MCRegisteredTransitionNotLost`, 31/22. | Passing results are exhaustive only within each cfg's finite bounds. Candidate violations are not classified as implementation bugs here. |
| 7 | Model/trace contained fixture-only capture/final-drop/reset and unsupported cycle-rejection transitions. | Removed `CapturedFileOperation`, `FileLikeFinalDrop`, `ResetWait`, `EpollRejectNestedCycle`, inert `topologyRejected`, and uncited `WaiterDescriptorCloseWake`. Actual capture/use and close/dup cleanup own lifetime updates. `SupportedNestedTopology` is a state constraint; `instrumentation-spec.md` labels MC filters/controller guards as non-events. | Actual cleanup: `kernel/core/src/fs/file/file_table.rs:274-302`. Pinned epoll control has no explicit cycle-rejection branch: `kernel/core/src/events/epoll/file.rs:64-125`. Generic numeric close has removal/cleanup but no waiter-wake branch: `kernel/core/src/syscall/close.rs:25-40`. | `rg` over base/MC/Trace/configs finds none of the removed transitions. SANY passes all modules. Action map audit is 70 Trace events ↔ 70 instrumentation rows with no difference. | Cyclic nested epoll behavior is explicitly unsupported/unverified; successful acyclic insertion is the only modeled production path. |
| 8 | MC counters bounded callback and ready-pop completion actions. | `MC.tla:106` `Reactive`; `MC.tla:253-343` completion wrappers; `MCReactiveNext`; `MCCallbackFairness`; `MCDeliveryFairness`. Counters remain only on introductions in `MCBoundedNext`. | Push/pop/callback calls are synchronous/reactive production continuations at `kernel/core/src/events/subject.rs:126-153` and `kernel/core/src/events/epoll/entry.rs:280-330,367-397`. | Static audit finds callback, pop, prepare, successful-copyout, and release wrappers only under `Reactive`/`MCReactiveNext`, never `Bounded`. Level and nested liveness hunts complete successfully. | `EnabledActions` can exclude a path for a focused cfg, but once enabled its deterministic/reactive completions have no counter budget. |
| 9 | Combined scenario oracles let an early violation hide another required check. | Added one-oracle configs for S1 subproperties, S2 key/reuse/dead/copyout/one-shot/level, S3 cache/delivery, S4 legal/binding/mask, and S5 arbitration/restoration; `brief-coverage.md` maps each oracle. | The separations follow the implementation boundaries cited in the respective base operators; no source semantic was changed to obtain completion. | All 19 focused configs were run individually. Independent candidate stops are `MCNoDeadInterest`, `MCDeliveryCommitOnCopyout`, `MCOneShotDisabledIffDelivered`, `MCCachedReadinessSound`, `MCSignalfdBindingCoversConsumer`, `MCRegisteredTransitionNotLost`, and `MCVisibleReadyWinsTerminalRace`. Other configs complete as listed below. | Core type/causality invariants remain in relevant configs and may correctly preempt a scenario oracle if the model itself becomes ill-typed. |
| 10 | Helpers, guards, multi-branch updates, and invariant bodies lacked block-level citations. | Added pinned `kernel/core/src/...:line` comments inside every semantic helper/action/invariant block in `base.tla`; rewrote `instrumentation-spec.md` and `brief-coverage.md` with block-level mappings. | Citations cover the exact branches used, including F_SETFL `87-94`, close range `76-101`, epoll update/delivery `entry.rs:103-166,280-330,367-397`, cache `poll.rs:106-178`, and waits `pause.rs:171-219`. | Operator-block audit reports no uncited semantic helper, action, or invariant; only schema constructors, aggregate tuples, `Next`/`Spec`, and the derived negated witness lack source comments. Brief config/name audit reports no missing config or wrapper. | Citations are pinned to this HEAD and must be refreshed if source line layout changes. |

## Final validation matrix

`PASS` means complete bounded state-space exploration with no checked-property
error. `CANDIDATE` means the dedicated oracle was violated and retained.
`CONTROL` is an intentional mutation/witness failure.

| Config | Result | Generated / distinct; depth |
|---|---|---|
| `base.cfg` random simulation | PASS, 50 traces × depth 35 | 1753 generated |
| `MC.cfg` | PASS | 288 / 156; 7 |
| `MC_hunt_s1_slot_map.cfg` | PASS | 16 / 11; 4 |
| `MC_hunt_s1_fd_exec.cfg` | PASS | 288 / 156; 7 |
| `MC_hunt_s1_replacement.cfg` | PASS | 397 / 247; 7 |
| `MC_hunt_s1_flags.cfg` | PASS | 715 / 197; 5 |
| `MC_hunt_s1_exec.cfg` | PASS | 53 / 28; 5 |
| `MC_hunt_s2_key_identity.cfg` | PASS | 132 / 78; 8 |
| `MC_hunt_s2_cross_reuse.cfg` | PASS | 3794 / 1389; 26 |
| `MC_hunt_s2_epoll_delivery.cfg` | CANDIDATE: `MCNoDeadInterest`, exit 12 | 24 / 16; 7 |
| `MC_hunt_s2_copyout.cfg` | CANDIDATE: `MCDeliveryCommitOnCopyout`, exit 12 | 70 / 45; 9 |
| `MC_hunt_s2_oneshot.cfg` | CANDIDATE: `MCOneShotDisabledIffDelivered`, exit 12 | 458 / 250; 9 |
| `MC_hunt_s2_level.cfg` | PASS | 4059 / 1339; 21 |
| `MC_hunt_s3_cache.cfg` | CANDIDATE: `MCCachedReadinessSound`, exit 12 | 1988 / 897; 9 |
| `MC_hunt_s3_registered_delivery.cfg` | PASS | 895 / 409; 17 |
| `MC_control_s4_legal_intermediate.cfg` | CONTROL: `MCS4LegalAddIntermediateAbsent`, exit 12 | 4 / 3; 3 |
| `MC_hunt_s4_binding.cfg` | CANDIDATE: `MCSignalfdBindingCoversConsumer`, exit 12 | 654 / 194; 7 |
| `MC_hunt_s4_mask_transition.cfg` | CANDIDATE: `MCRegisteredTransitionNotLost`, exit 13 | 31 / 22; 8 |
| `MC_hunt_s5_arbitration.cfg` | CANDIDATE: `MCVisibleReadyWinsTerminalRace`, exit 12 | 205 / 98; 6 |
| `MC_hunt_s5_mask_restore.cfg` | PASS | 1373 / 433; 13 |
| `MC_hunt_s6_nested.cfg` | PASS | 1433 / 610; 13 |
| `Trace.cfg` | PASS; includes actor `t1` waking target `t2` | 11 / 10; 10 |
| `Trace_mutated.cfg` | CONTROL: `TraceMatched`, exit 13 | 5 / 5; 5 |

SANY accepted `base.tla`, `MC.tla`, and `Trace.tla` with exit 0.
Both JSON fixtures pass `jq -e`.

## Final audits and cleanup

- Brief coverage: all six section 2 scenarios, all section 5 properties, and
  every section 6.1 candidate map to an existing dedicated config and MC
  wrapper.
- Action-to-instrumentation: 70 unique `Trace.MatchEvent` literals and 70
  mapping rows; `comm -3` output is empty.
- Removed-transition audit: no base/MC/Trace/config reference remains for
  `CapturedFileOperation`, `FileLikeFinalDrop`, `ResetWait`,
  `EpollRejectNestedCycle`, `WaiterDescriptorCloseWake`, or
  `topologyRejected`.
- TLC-generated `*_TTrace_*.tla`/`*.bin` files were moved out of the durable
  spec directory to `/tmp/specula-tlc-transients-20260812T1048/`. They are
  recoverable until `/tmp` is cleared.
- Existing candidate violations remain candidates. This remediation did not
  generate exploit code, modify Asterinas, run an `SMP=2` regression, compare
  live Linux behavior, or classify any candidate as a confirmed bug.
