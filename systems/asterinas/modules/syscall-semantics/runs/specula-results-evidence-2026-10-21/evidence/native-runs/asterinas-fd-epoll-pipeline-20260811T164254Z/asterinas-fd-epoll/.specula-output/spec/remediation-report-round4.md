# Formal-model QA remediation report, round 4

Pinned Asterinas source: `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`.
The Asterinas worktree remained clean. No source file, agent configuration, or
modeling-guidance artifact was modified.

Commands below ran from `../.specula-output/spec`:

```sh
JAVA=/nix/store/mxf12821brqjb2kv1p3v8b9n6d5741y0-openjdk-21.0.12+8/bin/java
CP=/home/chin39/Documents/play/Specula/lib/tla2tools.jar:/home/chin39/Documents/play/Specula/lib/CommunityModules-deps.jar

$JAVA -cp "$CP" tla2sany.SANY MODULE.tla
timeout 150s $JAVA -Xmx2g -cp "$CP" tlc2.TLC -workers 4 \
  -metadir /tmp/RUN/meta -config CONFIG.cfg MODULE.tla
timeout 90s $JAVA -Xmx2g -cp "$CP" tlc2.TLC -workers 1 \
  -metadir /tmp/RUN/meta -config TRACE_CONFIG.cfg Trace.tla
$JAVA -Xmx2g -cp "$CP" tlc2.TLC -simulate num=50 -depth 35 \
  -metadir /tmp/RUN/meta -config base.cfg base.tla
```

TLC results are classified as:

- **PASS**: exhaustive bounded search or the requested simulation completed
  without a checked oracle failing.
- **CANDIDATE**: a focused production model violated its isolated oracle. This
  is not a confirmed Asterinas implementation bug.
- **REACH**: an intentionally negated non-vacuity predicate failed only after
  the named production state or action was reached.
- **CONTROL**: an intentional controller-only mutation or negative Trace
  fixture failed its designated oracle.

## Independent-review issue closure

| # | Original defect | Exact artifacts and operators changed | Pinned source evidence | Validation command and result | Remaining limitation |
|---|---|---|---|---|---|
| 1 | Scenario 5 selected timeout/signal results from historical `visibleReady`; it did not perform a live readiness scan at the terminal boundary. | `base.tla`: added `LiveWaitReadiness`, `terminalScanValid`, and `terminalScanExpected`; updated `PollFilesRegisterPoller`, `PollFilesInitialReady`, `WaiterPauseTimeoutReturnTimeout`, `WaiterPauseTimeoutReturnSignal`, and `DoPollCountEvents`; added `TerminalScanMatchesLiveSnapshot`; changed `VisibleReadyWinsTerminalRace` to use the terminal snapshot. `MC.tla`: added `MCTerminalScanMatchesLiveSnapshot`, `MCNoTerminalReadyBeforeWake`, and `MCNoStaleVisibleAfterConsume`. Added `MC_reach_terminal_ready_before_wake.cfg`, `MC_reach_stale_visible_after_consume.cfg`, and `MC_control_terminal_scan_mutation.cfg`. `Trace.tla`, `instrumentation-spec.md`, `brief-coverage.md`, and `remediation-terminal-snapshot-field-negative.json` now carry and validate both snapshot fields. | Poll performs a register-before-check pass and a later live `count_events` scan: `kernel/core/src/syscall/poll.rs:88-121,165-215`. Timeout and interruption are selected by the pause result before the caller's later readiness scan: `kernel/core/src/process/signal/pause.rs:171-219`. | Producer-before-wake direction: **REACH**, 44/28 states, depth 7; final state has `sourceReady[timer]=TRUE`, `visibleReady[t1]=FALSE`, and `terminalScanExpected[t1]=terminalReady[t1]=TRUE`. Stale-visible direction: **REACH**, 71/48, depth 8; final state has `sourceReady[timer]=FALSE`, `visibleReady[t1]=TRUE`, and both terminal fields false. Snapshot substitution: **CONTROL**, exit 12 only at `MCTerminalScanMatchesLiveSnapshot`, 77/54, depth 9. The focused arbitration run remains an isolated **CANDIDATE** at `MCVisibleReadyWinsTerminalRace`, 368/197, depth 8. | `LiveWaitReadiness` scans the bounded modeled OFDs rather than a variable-length userspace poll array. FD slots, three OFDs, and terminal-order races remain within the brief's explicit bound. |
| 2 | Thread/process signal enqueue and `signalfd_pollee.notify` were one atomic action, hiding the source's unlocked interleaving seam. | `base.tla`: added `EmptySignalNotify`, per-actor `signalNotify`, exact `signalNotifyKeys`/`signalNotifyWaiters`, and enqueue/notify epochs; split `SigQueuesEnqueueThread`/`SigQueuesEnqueueProcess` from `SigQueuesNotifyThread`/`SigQueuesNotifyProcess` and `SigQueuesNotifyReturn`; exact obligations are discharged by `ReadySetPushSuppressed`, `ObserverCallbackRelease`, and `WaiterReadinessWake`; added `SignalNotifyOrdering`. `MC.tla` adds unbounded reactive wrappers, fairness, reach predicates, and action names. Added thread/process notify, gap, interleaving, completion, and ordering-control configs. `Trace.tla`, `instrumentation-spec.md`, `brief-coverage.md`, and `remediation-signal-notify-field-negative.json` record the split and exact pending sets. | Queue mutation occurs under `queues.lock()`, the guard is explicitly dropped, and only then is the pollee notified: `kernel/core/src/process/signal/sig_queues.rs:38-45`. Notification snapshots and calls observers synchronously: `kernel/core/src/events/subject.rs:126-153`. Signalfd registration and mask state are independently observable: `kernel/core/src/syscall/signalfd.rs:103-117,155-215`. | Thread notify and process notify are separately **REACH**, 7/5 and 6/3 states, depth 3. The unlocked gap permits ADD registration, waiter binding, and a mask update before notify: **REACH**, 9/8, depth 8. Exact selected callback completion and notify return are **REACH**, 15/14, depth 14; the selected key obligation is present after notify and empty only after callback return. Notify-before-enqueue mutation: **CONTROL**, exit 12 only at `MCSignalNotifyOrdering`, 2/2, depth 2. | Pending thread/process queue contents are Boolean, not full `siginfo_t` sequences. One continuation per bounded actor is sufficient to expose registration, mask, read, and callback interleavings without modeling unbounded signal queues. |
| 3 | `TraceMatched` accepted complete JSON while split syscall, ctl, mask restoration, or other non-callback work remained in flight. | `Trace.tla`: added `OperationsQuiescent`; strengthened `SynchronousCallbacksQuiescent` and `TraceMatched` to require empty captures, close/dup cleanup, `ctl`, delivery, poll, producer, signal-notify, callback, wait-token, and saved-mask obligations. The positive fixture now ends both waiters through `HandlePendingSignalRestoreMask`. Added `remediation-truncated-fsetfl.json`, `remediation-truncated-mask.json`, and `remediation-truncated-ctl.json` with matching configs. Updated `instrumentation-spec.md` and `brief-coverage.md`. Legacy wrong-actor, omitted-callback, and early-owner fixtures were refreshed to the same complete payload schema without changing their intended mutation. | F_SETFL captures an Arc/Cow before later use: `kernel/core/src/syscall/fcntl.rs:87-94` and `kernel/core/src/fs/file/file_table.rs:326-367`. Epoll ctl captures the target before ADD/MOD/DEL terminal paths: `kernel/core/src/events/epoll/file.rs:65-84,96-178`. Temporary masks have a deferred restore boundary: `kernel/core/src/process/signal/mod.rs:64-85,208-230`. | Positive `Trace.cfg`: **PASS**, 37/36 states, depth 36, with every operation returned, all exact callback obligations empty, no eventfd owner, and restored masks. Truncated F_SETFL, mask, and ctl controls each fail `TraceMatched` with exit 13 at depth 2. Wrong actor, omitted callback, and early owner release also fail `TraceMatched` cleanly with exit 13; no fixture ends in a TLC evaluation error. | Fixtures are deterministic model traces, not yet traces captured from an instrumented Asterinas VM. The instrumentation contract now defines the required completion payloads for a later harness phase. |
| 4 | Several Trace branches validated only a subset of the Base action's material post-state; `EntryPollDeadFile` omitted identity, registration, enablement, binding, delivery, and lifetime changes. | `Trace.tla`: expanded `ValidateFdAt`, `ValidateCtl`, `ValidateKeyState`, `ValidateEntryUpdate`, `ValidateDelivery`, `ValidatePoll`, `ValidateWait`, exact readiness/consumer/nested epoch deltas, and exact pending key/waiter sets; every one of the 74 `ValidatePostState` action literals is now present. `EntryPollDeadFile` validates `DELIVERY`, complete `KEY`, and OFD lifetime. `instrumentation-spec.md` profiles and all affected positive fixtures were updated. Added the dead-file positive/one-field negative, terminal-snapshot one-field negative, and signal-notify-epoch one-field negative controls. | Dead-file upgrade failure removes the exact Entry before the disabled check can apply: `kernel/core/src/events/epoll/entry.rs:103-124` and `kernel/core/src/events/epoll/file.rs:225-244`. Ready insertion changes the ready queue, wake state, and epochs: `kernel/core/src/events/epoll/entry.rs:280-330`. Poll cache and notification epochs follow `kernel/core/src/process/signal/poll.rs:90-178`. | Dead-file positive: **PASS**, 12/11 states, depth 11. Changing only `EntryPollDeadFile.state.identity_active` fails `TraceMatched`, exit 13, 10/10, depth 10. Wrong terminal `terminal_scan_expected` fails at depth 5; wrong `process_notify_epoch` fails at depth 2. The full positive Trace validates Scenario 4 waiter, enablement, trigger, slot generation, registration, binding, ready epoch, and consumer-ready epoch fields. | Trace validation checks all material fields represented by the bounded Base action; state intentionally abstracted out of Base, such as concrete Rust allocation addresses and full userspace event buffers, cannot be validated by these fixtures. |
| 5 | `SlotMapsOneOFD`, `TemporaryMaskRestored`, and `AcyclicEpollGraph` were preserved constructionally and lacked independent mutation-sensitive evidence. | `base.tla`: added independent `slotMapAudit` state and changed `SlotMapsOneOFD` to compare the table with that shadow; retained explicit saved/pre-mask state in `TemporaryMaskRestored`; kept `AcyclicEpollGraph` as a real checked safety invariant. `MC_Controls.tla`: added controller-only `MCInjectSlotMapDivergence`, `MCInjectMaskRestoreFailure`, and `MCInjectEpollCycle` with dedicated specs. Added `MC_control_slot_map_mutation.cfg`, `MC_control_mask_restore_mutation.cfg`, and `MC_control_epoll_cycle_mutation.cfg`. `Trace.tla`, `instrumentation-spec.md`, and fixtures validate `slot_map_audit`. No production cycle-rejection action was added. | File-table insert/remove/dup mutations occur under the table guard: `kernel/core/src/fs/file/file_table.rs:139-205`. Deferred mask restoration is explicit: `kernel/core/src/process/signal/mod.rs:64-85,208-230`. The checked-out epoll ADD path supports successful bounded insertion but contains no modeled production cycle-rejection branch: `kernel/core/src/events/epoll/file.rs:64-125`. | Slot shadow mutation: **CONTROL**, exit 12 only at `MCSlotMapsOneOFD`, 2/2, depth 2; normal slot-map hunt **PASS**, 16/11, depth 4. Mask mutation: **CONTROL**, exit 12 only at `MCTemporaryMaskRestored`, 74/43, depth 8; normal mask hunt **PASS**, 205/104, depth 11. Cycle mutation: **CONTROL**, exit 12 only at `MCAcyclicEpollGraph`, 7/4, depth 3; normal nested hunt **PASS**, 1,889/874, depth 13. | These controller-only mutations prove detector independence; they are not production transitions or implementation findings. The bounded production model still does not claim a cycle-rejection behavior absent from the pinned source. |

## SANY, base, and Trace controls

| Check | Result |
|---|---|
| `tla2sany.SANY base.tla` | exit 0 |
| `tla2sany.SANY MC.tla` | exit 0 |
| `tla2sany.SANY MC_Controls.tla` | exit 0 |
| `tla2sany.SANY Trace.tla` | exit 0 |
| `base.cfg`, simulation `num=50`, depth 35 | **PASS**, 1,752 states generated across 50 traces |
| `Trace.cfg` | **PASS**, 37 generated / 36 distinct, depth 36 |
| `Trace_dead_file.cfg` | **PASS**, 12 / 11, depth 11 |
| `Trace_dead_file_mutated.cfg` | **CONTROL**, exit 13 at `TraceMatched`, 10 / 10, depth 10 |
| `Trace_early_owner_release.cfg` | **CONTROL**, exit 13 at `TraceMatched`, 24 / 24, depth 24 |
| `Trace_mutated.cfg` | **CONTROL**, exit 13 at `TraceMatched`, 24 / 24, depth 24 |
| `Trace_omitted_callback.cfg` | **CONTROL**, exit 13 at `TraceMatched`, 26 / 26, depth 26 |
| `Trace_signal_notify_mutated.cfg` | **CONTROL**, exit 13 at `TraceMatched`, 2 / 2, depth 2 |
| `Trace_terminal_snapshot_mutated.cfg` | **CONTROL**, exit 13 at `TraceMatched`, 5 / 5, depth 5 |
| `Trace_truncated_ctl.cfg` | **CONTROL**, exit 13 at `TraceMatched`, 3 / 2, depth 2 |
| `Trace_truncated_fsetfl.cfg` | **CONTROL**, exit 13 at `TraceMatched`, 3 / 2, depth 2 |
| `Trace_truncated_mask.cfg` | **CONTROL**, exit 13 at `TraceMatched`, 3 / 2, depth 2 |

The wrong-actor fixture differs from the positive fixture only in
`EventfdNotify.state.callbacks[0].actor: t1 -> t2`. The early-release fixture
differs only in `EventfdNotify.state.eventfd_owner: t1 -> no_thread`. The
omitted-callback fixture removes `ReadySetPushAcquire`, `ReadySetPush`,
`ReadySetPushNotifySubject`, and `ObserverCallbackRelease` while retaining the
selection and return events. The positive readiness wake has executing
`tid=t1` and target `args.target=t2`.

## Full bounded TLC matrix

All 55 neutral, hunt, reach, and controller configs were rerun after the final
semantic edit. The matrix driver returned success with zero unexpected exits.

| Config | Classification and checked result | Generated / distinct; depth |
|---|---|---|
| `MC.cfg` | PASS | 288 / 156; 7 |
| `MC_control_dead_before_disabled.cfg` | CONTROL: `MCNoDeadBeforeDisabledWitness`, exit 12 | 25 / 16; 8 |
| `MC_control_epoll_cycle_mutation.cfg` | CONTROL: `MCAcyclicEpollGraph`, exit 12 | 7 / 4; 3 |
| `MC_control_eventfd_early_release.cfg` | CONTROL: `MCEventfdMutexExclusive`, exit 12 | 38 / 28; 8 |
| `MC_control_eventfd_second_mutation.cfg` | CONTROL: `MCEventfdMutexExclusive`, exit 12 | 36 / 26; 8 |
| `MC_control_lifetime_phantom_mutation.cfg` | CONTROL: `MCNoPhantomLiveOFD`, exit 12 | 5 / 4; 4 |
| `MC_control_lifetime_resurrection_mutation.cfg` | CONTROL: `MCOFDsNeverResurrect`, exit 12 | 5 / 4; 4 |
| `MC_control_mask_restore_mutation.cfg` | CONTROL: `MCTemporaryMaskRestored`, exit 12 | 74 / 43; 8 |
| `MC_control_s1_flags_mutation.cfg` | CONTROL: `MCFdFlagsPerSlot`, exit 12 | 33 / 21; 5 |
| `MC_control_s1_flags_witness.cfg` | CONTROL: `MCNoAliasedDescriptorFlagWitness`, exit 12 | 3,559 / 1,289; 8 |
| `MC_control_s2_key_stale_generation.cfg` | CONTROL: `MCEpollKeyIdentity`, exit 12 | 57 / 40; 8 |
| `MC_control_s2_key_wrong_ofd.cfg` | CONTROL: `MCEpollKeyIdentity`, exit 12 | 8 / 7; 6 |
| `MC_control_signal_notify_ordering.cfg` | CONTROL: `MCSignalNotifyOrdering`, exit 12 | 2 / 2; 2 |
| `MC_control_slot_map_mutation.cfg` | CONTROL: `MCSlotMapsOneOFD`, exit 12 | 2 / 2; 2 |
| `MC_control_terminal_scan_mutation.cfg` | CONTROL: `MCTerminalScanMatchesLiveSnapshot`, exit 12 | 77 / 54; 9 |
| `MC_hunt_eventfd_mutex.cfg` | PASS | 301 / 178; 19 |
| `MC_hunt_lifetime.cfg` | PASS | 77 / 39; 9 |
| `MC_hunt_s1_exec.cfg` | PASS | 53 / 28; 5 |
| `MC_hunt_s1_fd_exec.cfg` | PASS | 288 / 156; 7 |
| `MC_hunt_s1_flags.cfg` | PASS | 10,593 / 3,308; 9 |
| `MC_hunt_s1_replacement.cfg` | PASS | 397 / 247; 7 |
| `MC_hunt_s1_slot_map.cfg` | PASS | 16 / 11; 4 |
| `MC_hunt_s2_copyout.cfg` | CANDIDATE: `MCDeliveryCommitOnCopyout`, exit 12 | 167 / 111; 10 |
| `MC_hunt_s2_cross_reuse.cfg` | PASS | 3,810 / 1,395; 26 |
| `MC_hunt_s2_epoll_delivery.cfg` | CANDIDATE: `MCNoDeadInterest`, exit 12 | 24 / 15; 7 |
| `MC_hunt_s2_key_identity.cfg` | PASS | 124 / 75; 8 |
| `MC_hunt_s2_level.cfg` | PASS | 8,897 / 2,794; 21 |
| `MC_hunt_s2_oneshot.cfg` | CANDIDATE: `MCOneShotDisabledIffDelivered`, exit 12 | 623 / 366; 10 |
| `MC_hunt_s3_cache.cfg` | CANDIDATE: `MCCachedReadinessSound`, exit 12 | 2,934 / 1,319; 11 |
| `MC_hunt_s3_registered_delivery.cfg` | PASS | 1,487 / 669; 17 |
| `MC_hunt_s4_binding.cfg` | CANDIDATE: `MCSignalfdBindingCoversConsumer`, exit 12 | 349 / 183; 8 |
| `MC_hunt_s4_mask_transition.cfg` | CANDIDATE: `MCRegisteredTransitionNotLost`, exit 13 | 15 / 15; 8 |
| `MC_hunt_s5_arbitration.cfg` | CANDIDATE: `MCVisibleReadyWinsTerminalRace`, exit 12 | 368 / 197; 8 |
| `MC_hunt_s5_mask_restore.cfg` | PASS | 205 / 104; 11 |
| `MC_hunt_s6_nested.cfg` | PASS | 1,889 / 874; 13 |
| `MC_reach_epoll_control_error.cfg` | REACH: `MCNotReachedEpollControlError`, exit 12 | 4 / 3; 3 |
| `MC_reach_epoll_del_interest.cfg` | REACH: `MCNotReachedEpollDelInterest`, exit 12 | 32 / 20; 7 |
| `MC_reach_epoll_discard_empty.cfg` | REACH: `MCNotReachedEpollDiscardEmptyPreparation`, exit 12 | 451 / 245; 11 |
| `MC_reach_eventfd_callback_scope.cfg` | REACH: `MCNoEventfdCallbackScopeWitness`, exit 12 | 26 / 21; 7 |
| `MC_reach_file_table_dup_ceil.cfg` | REACH: `MCNotReachedFileTableDupCeil`, exit 12 | 13 / 9; 5 |
| `MC_reach_poll_initial_ready.cfg` | REACH: `MCNotReachedPollFilesInitialReady`, exit 12 | 17 / 14; 5 |
| `MC_reach_producer_before_wake.cfg` | REACH: `MCNoProducerBeforeReadinessWake`, exit 12 | 27 / 20; 6 |
| `MC_reach_s2_key_identity_reuse.cfg` | REACH: `MCNoValidKeyIdentityReuse`, exit 12 | 458 / 235; 9 |
| `MC_reach_s4_updated_before_insert.cfg` | REACH: `MCNoAddUpdatedBeforeInterestInsert`, exit 12 | 412 / 160; 7 |
| `MC_reach_signal_interleave_gap.cfg` | REACH: `MCNoSignalGapRegistrationMaskInterleave`, exit 12 | 9 / 8; 8 |
| `MC_reach_signal_interleaved_completion.cfg` | REACH: `MCNoCompletedInterleavedSignalNotify`, exit 12 | 15 / 14; 14 |
| `MC_reach_signal_notify_process.cfg` | REACH: `MCNotReachedSigQueuesNotifyProcess`, exit 12 | 6 / 3; 3 |
| `MC_reach_signal_notify_thread.cfg` | REACH: `MCNotReachedSigQueuesNotifyThread`, exit 12 | 7 / 5; 3 |
| `MC_reach_signal_read_process.cfg` | REACH: `MCNotReachedSignalFileReadProcess`, exit 12 | 35 / 10; 4 |
| `MC_reach_signal_read_thread.cfg` | REACH: `MCNotReachedSignalFileReadThread`, exit 12 | 51 / 23; 4 |
| `MC_reach_signal_thread_gap.cfg` | REACH: `MCSignalThreadNotifyGap`, exit 12 | 2 / 2; 2 |
| `MC_reach_stale_visible_after_consume.cfg` | REACH: `MCNoStaleVisibleAfterConsume`, exit 12 | 71 / 48; 8 |
| `MC_reach_sys_dup2_equal.cfg` | REACH: `MCNotReachedSysDup2Equal`, exit 12 | 2 / 2; 2 |
| `MC_reach_terminal_ready_before_wake.cfg` | REACH: `MCNoTerminalReadyBeforeWake`, exit 12 | 44 / 28; 7 |
| `MC_reach_two_checkers_loaded_invalid.cfg` | REACH: `MCNoTwoCheckersLoadedInvalid`, exit 12 | 13 / 9; 5 |

## Coverage, mutation, and source-fence audits

- Action mapping is exact: 74 `MC.ActionNames`, 74 names in the union of all
  `EnabledActions`, 74 `Trace.MatchEvent` branches, 74 post-state action
  literals, and 74 instrumentation rows. Every set difference is empty.
- Brief/config coverage is exact: every one of the 55 `MC*.cfg` and 11
  `Trace*.cfg` artifacts is named in `brief-coverage.md`; brief sections 2, 5,
  and 6.1 remain mapped to isolated hunts, oracles, and Trace controls.
- Signal enqueue, thread/process notify, and notify return are separately
  reachable. The gap witness shows an interest, registration, waiter identity,
  and mask update while the continuation is pending. The completion witness
  carries the exact selected key until its callback returns.
- Terminal-scan witnesses cover both requested directions: live readiness with
  no historical wake, and stale historical wake after source consumption.
- `SlotMapsOneOFD`, `TemporaryMaskRestored`, and `AcyclicEpollGraph` each fail
  their own named oracle under an in-domain controller mutation while the
  corresponding production hunt passes.
- Lifetime controls remain mutation-sensitive. `MC_hunt_lifetime.cfg` passes;
  phantom-live fails `MCNoPhantomLiveOFD`; resurrection fails
  `MCOFDsNeverResurrect`. No corrected production run reaches
  `ofdRefs = 0 /\ ofdAlive = TRUE` or resurrects a dead modeled identity.
- Introduction counters bound only externally introduced operations. Signal
  notify/return, eventfd notify/return, callback suppression/release, ctl,
  delivery, poll, exec, and mask-restoration completions remain unbounded
  reactive actions.
- Controller-only mutations remain confined to `MC_Controls.tla`; none appears
  in `base.Next`, `MC.ActionNames`, `Trace.MatchEvent`, or the instrumentation
  action table. No production epoll cycle-rejection branch was invented.
- Citation audit: all 74 production action blocks, all 38 oracle bodies, and
  all 21 Trace validation/quiescence helpers contain pinned block-level
  `kernel/...rs:line` citations. Every unique cited path and range resolves
  within the pinned checkout.
- JSON audit: all 11 fixtures pass `jq -e`. Positive Trace completion is fully
  quiescent; the nine negative/truncated fixtures fail `TraceMatched` rather
  than producing TLC evaluation errors.
- TLC-generated transients were removed from the durable spec directory. All
  241 `*_TTrace_*.tla`/`.bin` files were moved to
  `/tmp/asterinas-r4-transients.cwWUOp`; the durable transient count is zero.
- Source fence: `git rev-parse HEAD` returned
  `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`; `git status --short` was empty.

The CANDIDATE rows remain formal-model candidates. None is classified here as
a confirmed Asterinas implementation defect.
