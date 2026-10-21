# Specgen remediation report, round 5

Pinned implementation: `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`.

All six issues in the 31/40 independent review are closed. No TLC candidate
below is classified as a confirmed Asterinas implementation bug. The model
retains the brief's bound of two actors, three FD slots, three OFDs, and two
epoll instances.

## Commands and evidence

```sh
JAVA=/nix/store/mxf12821brqjb2kv1p3v8b9n6d5741y0-openjdk-21.0.12+8/bin/java
CP=/home/chin39/Documents/play/Specula/lib/tla2tools.jar:/home/chin39/Documents/play/Specula/lib/CommunityModules-deps.jar

$JAVA -cp "$CP" tla2sany.SANY MODULE.tla
timeout 180 $JAVA -Xmx2g -cp "$CP" tlc2.TLC -simulate num=50 -depth 35 \
  -metadir /tmp/asterinas-fd-epoll-round5-final-3cm3pe/base/meta \
  -config base.cfg base
timeout 600 $JAVA -XX:+UseParallelGC -cp "$CP" tlc2.TLC -workers 1 \
  -metadir /tmp/asterinas-fd-epoll-round5-final-3cm3pe/CONFIG/meta \
  -config CONFIG.cfg MC_OR_MC_Controls
timeout 720 $JAVA -Xmx3g -XX:+UseParallelGC -cp "$CP" tlc2.TLC \
  -workers 4 \
  -metadir /tmp/asterinas-fd-epoll-round5-final-3cm3pe/mc/MC_hunt_s2_level/meta \
  -config MC_hunt_s2_level.cfg MC
timeout 180 $JAVA -Xmx2g -cp "$CP" tlc2.TLC -workers 1 \
  -metadir /tmp/asterinas-fd-epoll-round5-final-3cm3pe/trace/CONFIG/meta \
  -config CONFIG.cfg Trace
python3 audit-spec.py
git -C ../../source rev-parse HEAD
git -C ../../source status --short
```

The complete logs, metadata, counterexamples, result TSVs, and 54 moved TLC
trace binaries are retained at
`/tmp/asterinas-fd-epoll-round5-final-3cm3pe/`. The durable spec directory has
zero TLC-generated transient files.

## Review issue closure

| # | Original defect | Exact model changes | Pinned source evidence | Validation result | Remaining limitation |
|---|---|---|---|---|---|
| 1 | A second wait inherited timeout, interruption, terminal result/snapshot, Waker state, and mask-related per-call state. | `base.tla`: added `waitGeneration`, `completedWaitReason`, `lastCompletedWaitReason`, exact current/released wait snapshots, `FreshWaitFields`, `FreshWaitInvocation`, `FreshSecondWaitAfterTimeout`, and `FreshSecondWaitAfterSignal`. `SaveAndSetSigMask` and `PollFilesRegisterPoller` now reset every per-invocation field at the implementation-backed start boundary. `MC.tla` adds the oracle/reach wrappers. Added `MC_reach_wait_repeat_timeout.cfg`, `MC_reach_wait_repeat_signal.cfg`, and controller-only `MCInjectStaleSecondWait`/`MC_control_wait_stale_second.cfg`. `Trace.tla`, fixtures, and the `WAIT` instrumentation profile validate generation, current/last completion, snapshots, and mask state. | New `Poller`/wait loop and initial registration: `kernel/core/src/syscall/poll.rs:88-121,165-185`; fresh Waiter state and registration: `kernel/core/src/process/signal/poll.rs:282-315`; deferred mask restoration: `kernel/core/src/process/signal/mod.rs:64-85,208-230`. | Timeout-first and signal-first second-wait witnesses each **REACH**, exit 12 at their intentional negated predicate, 44 generated / 26 distinct, depth 7. The stale-second-wait mutation is **CONTROL**, exit 12 only at `MCFreshWaitInvocation`, 53 / 31, depth 8. Normal arbitration/mask and Trace runs retain their expected outcomes. | The bounded model runs at most one in-flight wait per actor and abstracts timeout duration; it checks invocation freshness, not clock precision. |
| 2 | A registered poll did not own the `PollFiles::Owned` Arc snapshot, so close/drop could retire an OFD under a waiter. | `base.tla`: added exact `waitCapturedSlots`/`waitCaptureSlotAudit` FD→OFD snapshots, distinct identity sets, released snapshots, `WaitReleasedRefs`, per-vector-entry accounting in `ofdRefs`, and release on initial ready, count-ready, timeout, and signal terminals. `PollSnapshotOwnershipStable` and `PollSnapshotReleasedOnTerminal` are independent of `TypeOK`; `PollSnapshotSurvivesClose` and `PollSnapshotReleasedAfterClose` are non-vacuity witnesses. `MC_Controls.tla` adds omission and premature-release mutations. Added four focused configs. `Trace.ValidateWait` and instrumentation now require the exact captured/released maps, identity sets, per-OFD ref counts, and lifetime bits; added a focused positive and one-field negative Trace. | Shared-table snapshot construction and every cloned vector entry: `kernel/core/src/syscall/poll.rs:96-101,124-155`; register/terminal scope: `kernel/core/src/syscall/poll.rs:103-121,165-185`. | Close/drop while registered is **REACH**, exit 12, 16 / 13, depth 4; terminal last-owner release is **REACH**, 72 / 43, depth 7. Omission and early-release controls each fail only `MCPollSnapshotOwnershipStable`, exit 12, 4 / 4, depth 3. `MC_hunt_lifetime.cfg` **PASS**, 135 / 71, depth 9. Focused positive Trace **PASS**, 8 / 7, depth 7; wrong FD→OFD audit **CONTROL**, exit 13 at `TraceMatched`, 4 / 4, depth 4. | The bounded poll vector has one modeled entry per FD slot. Repeating the same numeric FD multiple times in one userspace poll array remains outside this first model; duplicated slots aliasing one OFD is counted exactly. |
| 3 | MC-8 was quiescent by construction and had neither an old shared table nor an external sharer around exec unshare. | `base.tla`: retained `slots`/flags/epochs/shadow as the old shared table and added `execPrivateSlots`, `execPrivateFlags`, `execPrivateEpoch`, `execPrivateSlotMapAudit`, and `execExternalAudit`. `ContextUnshareFiles` performs one atomic copy/install. A bounded external CLONE_FILES owner may run `FileTableDupCeil` or the single-lock `SysCloseRangeCloexec` only against the old table before or after cutover. `FileTableCloseFilesOnExec` scans/releases only the private table. `ExecCutoverIsolation` detects aliasing/wrong-table propagation; four ordering witnesses and two mutations are isolated in new configs. `ExecPrivateFinalDropWitness` preserves deterministic no-external-owner final-drop coverage. Trace/instrumentation validate both tables and the before/after/owner audit. | Atomic old read-lock, clone, and installation: `kernel/core/src/process/namespace/unshare.rs:18-28`; external CLONE_FILES ownership: `kernel/core/src/process/clone.rs:738-745`; duplication: `kernel/core/src/fs/file/file_table.rs:139-165`; single-lock range flag loop: `kernel/core/src/syscall/close.rs:76-101`; private CLOEXEC scan/drop: `kernel/core/src/fs/file/file_table.rs:208-234`, `kernel/core/src/process/execve.rs:378-386`. | Before/after duplication are **REACH**, 110 / 87 at depth 6 and 112 / 89 at depth 6. Before/after close-range are **REACH**, 22 / 21 and 23 / 22 at depth 4. Private final drop is **REACH**, 38 / 36, depth 5. Alias and wrong-table controls fail only `MCExecCutoverIsolation`, exit 12, 138 / 115 at depth 7 and 26 / 25 at depth 5. `MC_hunt_s1_exec.cfg` **PASS**, 169 / 151, depth 5. | One Boolean records whether one bounded external process retains the old RwArc. Arbitrary process/share graphs and more than one external sharer remain outside scope; no partial clone/install visibility is invented. |
| 4 | Four liveness configurations combined `PROPERTIES` with `SYMMETRY`, despite TLC's unsoundness warning for that combination. | Removed `SYMMETRY` from `MC.cfg`, `MC_hunt_lifetime.cfg`, `MC_hunt_s1_exec.cfg`, and `MC_control_lifetime_resurrection_mutation.cfg`. `audit-spec.py` scans every durable `MC*.cfg` for both `PROPERTY`/`PROPERTIES` and `SYMMETRY`. | This is a TLC exploration constraint, not an Asterinas production behavior. | Mechanical result: 69 MC configs, `liveness_plus_symmetry=0`. Observed round-4→round-5 state spaces: neutral 288/156→519/296; lifetime 77/39→135/71; exec 53/28→169/151; resurrection control 5/4→6/5. Depths remained 7, 9, 5, and 4. These are actual combined post-remediation state spaces; exec and lifetime semantics also changed, so the delta is not attributed solely to symmetry removal. | Symmetry remains enabled only in safety-only configs where permitted. |
| 5 | The neutral result checked callback, epoll, signal, wait, and topology invariants vacuously while enabling only FD actions. | `MC.cfg` is now explicitly labeled an FD-lifecycle smoke check and retains only non-vacuous FD lifetime/slot/captured-reference oracles. `brief-coverage.md` maps callback, epoll, signal, wait, and topology properties only to focused configurations and inventories all 69 MC plus 13 Trace configs. | Neutral enabled actions refine `kernel/core/src/syscall/fcntl.rs:87-94`, `kernel/core/src/syscall/close.rs:25-40`, and `kernel/core/src/fs/file/file_table.rs:190-205,326-367`. | Neutral **PASS**, exit 0, 519 / 296, depth 7. The action-union audit reports all 74 production actions enabled by at least one focused config. All seven candidate oracles remain isolated from one another. | The neutral run is intentionally not evidence for non-FD behavior; focused configurations are the non-vacuity evidence. |
| 6 | MC wrappers/controller blocks and Trace CASE branches lacked strict block-local source traceability. | `base.tla` now exposes the machine-readable 74-name `ProductionActionNames` and total `ProductionActionSource`. Every MC production wrapper consumes it through `Bounded`/`Reactive`; every `ValidatePostState` and `MatchEvent` branch is gated by `HasProductionSource(line.event)`. All 18 `MCInject*` blocks and controller specs carry explicit pinned targets. Added `audit-spec.py` to compare Base source rows, MC wrappers, both Trace dispatches, instrumentation rows, enabled-action union, fixture events, controller separation, and all source ranges. `instrumentation-spec.md` documents the same contract. | All mapping values are pinned `kernel/...rs:line-line` ranges; the audit resolves paths and line bounds against the checked-out source. | Audit **PASS**: 74 production actions/source rows/MC wrappers/Validate branches/Match branches/instrumentation rows; 214 distinct pinned references resolve; 18 controller mutations have targets and zero Trace leaks; all 74 actions occur in the enabled-action union. | The audit is a generated Python consistency checker, not a parser/type checker for arbitrary TLA+ syntax; SANY remains the syntax/semantic frontend. |

## SANY, Base, and audit controls

| Check | Exit and result |
|---|---|
| `tla2sany.SANY base.tla` | 0, PASS |
| `tla2sany.SANY MC.tla` | 0, PASS |
| `tla2sany.SANY MC_Controls.tla` | 0, PASS |
| `tla2sany.SANY Trace.tla` | 0, PASS |
| `base.cfg`, simulation `num=50`, depth 35 | 0, PASS, 1,758 states generated |
| `python3 audit-spec.py` | 0, PASS: 74/74/74/74/74 action mapping, 214 source references resolved, 69 MC configs, 13 Trace configs, zero liveness-plus-symmetry configs, valid JSON, zero controller Trace leaks, zero durable transients, clean pinned source |

## Complete MC matrix

`PASS` is a clean bounded result. `CANDIDATE` is an isolated model-checking
counterexample and is not a confirmed implementation bug. `REACH` is the
expected failure of a deliberately negated witness. `CONTROL` is an intentional
controller-only mutation. Counts are generated / distinct; depth.

| Config | Classification | Exit | States; depth |
|---|---|---:|---:|
| `MC.cfg` | PASS | 0 | 519 / 296; 7 |
| `MC_control_dead_before_disabled.cfg` | CONTROL: `MCNoDeadBeforeDisabledWitness` | 12 | 25 / 16; 8 |
| `MC_control_epoll_cycle_mutation.cfg` | CONTROL: `MCAcyclicEpollGraph` | 12 | 6 / 4; 3 |
| `MC_control_eventfd_early_release.cfg` | CONTROL: `MCEventfdMutexExclusive` | 12 | 25 / 19; 6 |
| `MC_control_eventfd_second_mutation.cfg` | CONTROL: `MCEventfdMutexExclusive` | 12 | 25 / 19; 6 |
| `MC_control_exec_private_alias.cfg` | CONTROL: `MCExecCutoverIsolation` | 12 | 138 / 115; 7 |
| `MC_control_exec_wrong_table_cloexec.cfg` | CONTROL: `MCExecCutoverIsolation` | 12 | 26 / 25; 5 |
| `MC_control_lifetime_phantom_mutation.cfg` | CONTROL: `MCNoPhantomLiveOFD` | 12 | 5 / 4; 4 |
| `MC_control_lifetime_resurrection_mutation.cfg` | CONTROL: `MCOFDsNeverResurrect` | 13 | 6 / 5; 4 |
| `MC_control_mask_restore_mutation.cfg` | CONTROL: `MCTemporaryMaskRestored` | 12 | 73 / 42; 7 |
| `MC_control_poll_snapshot_early_release.cfg` | CONTROL: `MCPollSnapshotOwnershipStable` | 12 | 4 / 4; 3 |
| `MC_control_poll_snapshot_omission.cfg` | CONTROL: `MCPollSnapshotOwnershipStable` | 12 | 4 / 4; 3 |
| `MC_control_s1_flags_mutation.cfg` | CONTROL: `MCFdFlagsPerSlot` | 12 | 19 / 14; 4 |
| `MC_control_s1_flags_witness.cfg` | CONTROL: `MCNoAliasedDescriptorFlagWitness` | 12 | 2,942 / 1,093; 6 |
| `MC_control_s2_key_stale_generation.cfg` | CONTROL: `MCEpollKeyIdentity` | 12 | 56 / 35; 7 |
| `MC_control_s2_key_wrong_ofd.cfg` | CONTROL: `MCEpollKeyIdentity` | 12 | 7 / 6; 5 |
| `MC_control_signal_notify_ordering.cfg` | CONTROL: `MCSignalNotifyOrdering` | 12 | 2 / 2; 2 |
| `MC_control_slot_map_mutation.cfg` | CONTROL: `MCSlotMapsOneOFD` | 12 | 2 / 2; 2 |
| `MC_control_terminal_scan_mutation.cfg` | CONTROL: `MCTerminalScanMatchesLiveSnapshot` | 12 | 70 / 47; 8 |
| `MC_control_wait_stale_second.cfg` | CONTROL: `MCFreshWaitInvocation` | 12 | 53 / 31; 8 |
| `MC_hunt_eventfd_mutex.cfg` | PASS | 0 | 301 / 178; 19 |
| `MC_hunt_lifetime.cfg` | PASS | 0 | 135 / 71; 9 |
| `MC_hunt_s1_exec.cfg` | PASS | 0 | 169 / 151; 5 |
| `MC_hunt_s1_fd_exec.cfg` | PASS | 0 | 288 / 156; 7 |
| `MC_hunt_s1_flags.cfg` | PASS | 0 | 10,593 / 3,308; 9 |
| `MC_hunt_s1_replacement.cfg` | PASS | 0 | 397 / 247; 7 |
| `MC_hunt_s1_slot_map.cfg` | PASS | 0 | 16 / 11; 4 |
| `MC_hunt_s2_copyout.cfg` | CANDIDATE: `MCDeliveryCommitOnCopyout` | 12 | 106 / 71; 9 |
| `MC_hunt_s2_cross_reuse.cfg` | PASS | 0 | 3,810 / 1,395; 26 |
| `MC_hunt_s2_epoll_delivery.cfg` | CANDIDATE: `MCNoDeadInterest` | 12 | 23 / 15; 7 |
| `MC_hunt_s2_key_identity.cfg` | PASS | 0 | 124 / 75; 8 |
| `MC_hunt_s2_level.cfg` | PASS | 0 | 8,897 / 2,794; 21 |
| `MC_hunt_s2_oneshot.cfg` | CANDIDATE: `MCOneShotDisabledIffDelivered` | 12 | 615 / 360; 9 |
| `MC_hunt_s3_cache.cfg` | CANDIDATE: `MCCachedReadinessSound` | 12 | 1,897 / 851; 9 |
| `MC_hunt_s3_registered_delivery.cfg` | PASS | 0 | 1,487 / 669; 17 |
| `MC_hunt_s4_binding.cfg` | CANDIDATE: `MCSignalfdBindingCoversConsumer` | 12 | 329 / 175; 7 |
| `MC_hunt_s4_mask_transition.cfg` | CANDIDATE: `MCRegisteredTransitionNotLost` | 13 | 15 / 15; 8 |
| `MC_hunt_s5_arbitration.cfg` | CANDIDATE: `MCVisibleReadyWinsTerminalRace` | 12 | 344 / 180; 6 |
| `MC_hunt_s5_mask_restore.cfg` | PASS | 0 | 239 / 118; 11 |
| `MC_hunt_s6_nested.cfg` | PASS | 0 | 1,889 / 874; 13 |
| `MC_reach_epoll_control_error.cfg` | REACH: `MCNotReachedEpollControlError` | 12 | 4 / 3; 3 |
| `MC_reach_epoll_del_interest.cfg` | REACH: `MCNotReachedEpollDelInterest` | 12 | 26 / 17; 6 |
| `MC_reach_epoll_discard_empty.cfg` | REACH: `MCNotReachedEpollDiscardEmptyPreparation` | 12 | 284 / 165; 10 |
| `MC_reach_eventfd_callback_scope.cfg` | REACH: `MCNoEventfdCallbackScopeWitness` | 12 | 17 / 13; 5 |
| `MC_reach_exec_after_cloexec.cfg` | REACH: `MCNoExecAfterCutoverCloexecIsolated` | 12 | 23 / 22; 4 |
| `MC_reach_exec_after_dup.cfg` | REACH: `MCNoExecAfterCutoverDupIsolated` | 12 | 112 / 89; 6 |
| `MC_reach_exec_before_cloexec.cfg` | REACH: `MCNoExecBeforeCutoverCloexecCaptured` | 12 | 22 / 21; 4 |
| `MC_reach_exec_before_dup.cfg` | REACH: `MCNoExecBeforeCutoverDupCaptured` | 12 | 110 / 87; 6 |
| `MC_reach_exec_private_final_drop.cfg` | REACH: `MCNoExecPrivateFinalDrop` | 12 | 38 / 36; 5 |
| `MC_reach_file_table_dup_ceil.cfg` | REACH: `MCNotReachedFileTableDupCeil` | 12 | 7 / 5; 3 |
| `MC_reach_poll_initial_ready.cfg` | REACH: `MCNotReachedPollFilesInitialReady` | 12 | 11 / 9; 4 |
| `MC_reach_poll_snapshot_close.cfg` | REACH: `MCNoPollSnapshotSurvivesClose` | 12 | 16 / 13; 4 |
| `MC_reach_poll_snapshot_release.cfg` | REACH: `MCNoPollSnapshotReleasedAfterClose` | 12 | 72 / 43; 7 |
| `MC_reach_producer_before_wake.cfg` | REACH: `MCNoProducerBeforeReadinessWake` | 12 | 20 / 15; 5 |
| `MC_reach_s2_key_identity_reuse.cfg` | REACH: `MCNoValidKeyIdentityReuse` | 12 | 302 / 166; 7 |
| `MC_reach_s4_updated_before_insert.cfg` | REACH: `MCNoAddUpdatedBeforeInterestInsert` | 12 | 353 / 130; 6 |
| `MC_reach_signal_interleave_gap.cfg` | REACH: `MCNoSignalGapRegistrationMaskInterleave` | 12 | 9 / 8; 8 |
| `MC_reach_signal_interleaved_completion.cfg` | REACH: `MCNoCompletedInterleavedSignalNotify` | 12 | 15 / 14; 14 |
| `MC_reach_signal_notify_process.cfg` | REACH: `MCNotReachedSigQueuesNotifyProcess` | 12 | 6 / 3; 3 |
| `MC_reach_signal_notify_thread.cfg` | REACH: `MCNotReachedSigQueuesNotifyThread` | 12 | 6 / 4; 3 |
| `MC_reach_signal_read_process.cfg` | REACH: `MCNotReachedSignalFileReadProcess` | 12 | 32 / 8; 4 |
| `MC_reach_signal_read_thread.cfg` | REACH: `MCNotReachedSignalFileReadThread` | 12 | 44 / 18; 4 |
| `MC_reach_signal_thread_gap.cfg` | REACH: `MCSignalThreadNotifyGap` | 12 | 2 / 2; 2 |
| `MC_reach_stale_visible_after_consume.cfg` | REACH: `MCNoStaleVisibleAfterConsume` | 12 | 60 / 39; 7 |
| `MC_reach_sys_dup2_equal.cfg` | REACH: `MCNotReachedSysDup2Equal` | 12 | 2 / 2; 2 |
| `MC_reach_terminal_ready_before_wake.cfg` | REACH: `MCNoTerminalReadyBeforeWake` | 12 | 36 / 22; 6 |
| `MC_reach_two_checkers_loaded_invalid.cfg` | REACH: `MCNoTwoCheckersLoadedInvalid` | 12 | 12 / 9; 5 |
| `MC_reach_wait_repeat_signal.cfg` | REACH: `MCNoFreshSecondWaitAfterSignal` | 12 | 44 / 26; 7 |
| `MC_reach_wait_repeat_timeout.cfg` | REACH: `MCNoFreshSecondWaitAfterTimeout` | 12 | 44 / 26; 7 |

Summary: 14 PASS, 7 CANDIDATE, 29 REACH, and 19 CONTROL. Every expected
violation names an invariant or liveness oracle; no run ended in a TLC
evaluation error or timeout.

## Complete Trace matrix

All three positive traces consume every JSON event and end quiescent. Each
negative trace fails `TraceMatched` at the intended field or incomplete
obligation, without a TLC evaluation error.

| Config | Classification | Exit | States; depth |
|---|---|---:|---:|
| `Trace.cfg` | PASS | 0 | 37 / 36; 36 |
| `Trace_dead_file.cfg` | PASS | 0 | 12 / 11; 11 |
| `Trace_dead_file_mutated.cfg` | CONTROL: `TraceMatched` | 13 | 10 / 10; 10 |
| `Trace_early_owner_release.cfg` | CONTROL: `TraceMatched` | 13 | 24 / 24; 24 |
| `Trace_mutated.cfg` | CONTROL: `TraceMatched` | 13 | 24 / 24; 24 |
| `Trace_omitted_callback.cfg` | CONTROL: `TraceMatched` | 13 | 26 / 26; 26 |
| `Trace_poll_snapshot_mutated.cfg` | CONTROL: `TraceMatched` | 13 | 4 / 4; 4 |
| `Trace_signal_notify_mutated.cfg` | CONTROL: `TraceMatched` | 13 | 2 / 2; 2 |
| `Trace_terminal_snapshot_mutated.cfg` | CONTROL: `TraceMatched` | 13 | 5 / 5; 5 |
| `Trace_terminal_snapshot_positive.cfg` | PASS | 0 | 8 / 7; 7 |
| `Trace_truncated_ctl.cfg` | CONTROL: `TraceMatched` | 13 | 3 / 2; 2 |
| `Trace_truncated_fsetfl.cfg` | CONTROL: `TraceMatched` | 13 | 3 / 2; 2 |
| `Trace_truncated_mask.cfg` | CONTROL: `TraceMatched` | 13 | 3 / 2; 2 |

## Final bounds and status

- Bounded state remains `2` actors, `3` FD slots, `3` OFDs, and `2` epoll
  instances. Introduction counters remain bounded; deterministic/reactive
  completion actions remain unbounded in MC wrappers.
- The final action/config/Trace/instrumentation audit is exact: every one of
  the 74 production actions is source-mapped, wrapped, enabled by at least one
  durable config, represented in both Trace dispatches, and documented once.
- All JSON fixtures parse. Controller-only mutations are absent from Trace and
  production enabled-action sets.
- The seven CANDIDATE results are formal-model hypotheses requiring Phase 4a
  source-level confirmation. They are not implementation findings.
- The checkout is clean at the pinned commit. All durable generated changes
  are confined to `.specula-output/spec` and `.specula-output/traces`.
