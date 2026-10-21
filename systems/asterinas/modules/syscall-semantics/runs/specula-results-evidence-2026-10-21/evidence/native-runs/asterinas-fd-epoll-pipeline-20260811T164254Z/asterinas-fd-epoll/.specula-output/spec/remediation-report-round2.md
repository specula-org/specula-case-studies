# Formal-model QA remediation report, round 2

Pinned Asterinas source: `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`.
The Asterinas worktree remained clean. No source, agent configuration, or
modeling-guidance file was modified.

Commands below ran from `../.specula-output/spec`:

```sh
JAVA=/nix/store/mxf12821brqjb2kv1p3v8b9n6d5741y0-openjdk-21.0.12+8/bin/java
CP=/home/chin39/Documents/play/Specula/lib/tla2tools.jar:/home/chin39/Documents/play/Specula/lib/CommunityModules-deps.jar

$JAVA -cp "$CP" tla2sany.SANY MODULE.tla
$JAVA -Xmx1g -XX:+UseParallelGC -cp "$CP" \
  tlc2.TLC -terse -workers 1 -metadir /tmp/specula-r2-validation-xH7ipM/NAME/meta \
  -config CONFIG.cfg MODULE
```

`MC_hunt_s2_level.cfg` used `-Xmx2g -workers 2`. TLC results are
classified as:

- **PASS**: exhaustive bounded search completed without the checked oracle
  failing.
- **CANDIDATE**: the focused production model violated its isolated oracle.
  This is not a confirmed Asterinas bug.
- **REACH**: an intentionally negated reach predicate failed after the named
  production action or state was reached.
- **CONTROL**: an intentional controller-only mutation, or a positive
  non-vacuity witness, failed its designated oracle.

## Independent-review issue closure

| # | Original defect | Exact artifact and operator changes | Pinned source evidence | Validation command and result | Remaining limitation |
|---|---|---|---|---|---|
| 1 | ADD inserted interest before `Entry::update`; the old Scenario 4 control witnessed an impossible state. | `base.tla`: added ctl phase `insert`; reordered `EntryUpdatePoll` before `EpollAddInterest`; defined `CompletedRegistration` as update plus insertion; changed `ReadySetPush`, `ReadySetPushSuppressed`, `ReadySetPop`, and `ReadySetPopDeleted` so a locally owned registered Entry remains live before insertion; added `AddUpdatedBeforeInterestInsert`. `MC.tla`: added its negated reach wrapper. Removed `MC_control_s4_legal_intermediate.cfg`; added `MC_reach_s4_updated_before_insert.cfg`. Updated `Trace.tla`, both trace fixtures, `instrumentation-spec.md`, and `brief-coverage.md`. | Rust calls `entry.update` before `interest.insert`: `kernel/core/src/events/epoll/file.rs:96-125`. Update registers then checks: `kernel/core/src/events/epoll/entry.rs:155-166`. ReadySet uses the Entry observer rather than the interest map: `kernel/core/src/events/epoll/entry.rs:307-325`. | `MC_reach_s4_updated_before_insert.cfg`: **REACH**, exit 12 at only `MCNoAddUpdatedBeforeInterestInsert`, 458/152 states, depth 6. The witness has a pending signal, waiter `t2`, registered key, `interest = {}`, and a positive consumer epoch; `MCSignalfdBindingCoversConsumer` is checked first and holds. `MC_hunt_s4_binding.cfg`: **CANDIDATE**, exit 12 at `MCSignalfdBindingCoversConsumer`, 872/349, depth 7, after both update and insertion complete. | Two actors, one signalfd OFD, and one focused epoll. The completed-registration candidate still requires trace/reproduction confirmation. |
| 2 | Terminal `epoll_ctl` branches leaked the captured Arc; exec close did not apply final drops, permitting phantom-live or resurrected identities. | `base.tla`: `ofdRefs`, `ExecReleasedRefs`, `AliveAfterExecReleases`, `AliveAfterOneRelease`, `EpollDelInterest`, `EpollControlError`, `EpollControlPushReady`, and `FileTableCloseFilesOnExec`; added `NoPhantomLiveOFD`, `NoDeadOFDReference`, and `OFDsNeverResurrect`. `MC.tla` wraps them. `MC_Controls.tla` isolates phantom-live and resurrection mutations. Added `MC_hunt_lifetime.cfg` and two lifetime mutation configs; strengthened Trace terminal-state validation. | Control owns an Arc from lookup through return: `kernel/core/src/events/epoll/file.rs:65-84,100-176`. Exec drops every returned `ClosedFile`: `kernel/core/src/fs/file/file_table.rs:208-234`, `kernel/core/src/process/execve.rs:378-386`. Deferred close/final Arc release: `kernel/core/src/fs/file/file_table.rs:274-302`. | `MC_hunt_lifetime.cfg`: **PASS**, 77/39, depth 9. `MC_hunt_s1_exec.cfg`: **PASS**, 53/28, depth 5. Phantom mutation: **CONTROL**, exit 12 at `MCNoPhantomLiveOFD`, 5/4, depth 4. Resurrection mutation: **CONTROL**, exit 12 at `MCOFDsNeverResurrect`, 5/4, depth 4. Neutral `MC.cfg` also passes all lifetime checks, 288/156, depth 7. | Strong counts include only the modeled slots and in-flight holders. Allocation is bounded to three stable identities; reuse must select a still-live distinct modeled identity. |
| 3 | The initial-ready poll terminal was unreachable and absent from focused MC/Trace coverage. | `base.tla`: `PollFilesRegisterPoller` computes and stores the live registration-pass result before `PollFilesInitialReady` selects the terminal. `MC.tla`: reach wrapper. Added `MC_reach_poll_initial_ready.cfg`. The positive fixture now contains register followed by initial-ready; `Trace.tla` and `instrumentation-spec.md` validate the full WAIT post-state. | `register_poller` returns `FoundEvents` from the live per-file polls before the wait branch: `kernel/core/src/syscall/poll.rs:88-106,165-185`. | `MC_reach_poll_initial_ready.cfg`: **REACH**, exit 12 at `MCNotReachedPollFilesInitialReady`, 11/9, depth 4. Positive `Trace.cfg`: **PASS**, 19/18, depth 18, and consumes `PollFilesInitialReady`. | The bounded poll set is abstracted to the three modeled live OFDs; the positive trace is a model control, not an Asterinas VM trace. |
| 4 | `FdFlagsPerSlot` was tautological, and its hunt never forced duplicated slots plus a one-slot descriptor-flag mutation. | `base.tla`: added `fdFlagAudit`, `AliasPeers`, audit updates in `FcntlSetFd`, invalidation on slot mutations, mutation-sensitive `FdFlagsPerSlot`, and `AliasedDescriptorFlagWitness`. `MC.tla`: witness wrapper. `MC_hunt_s1_flags.cfg` now enables close/drop, `FileTableDupCeil`, captured `F_SETFL`, and `F_SETFD`. Added positive witness and shared-flag mutation configs plus `MCInjectSharedFdFlags` in `MC_Controls.tla`. | Duplicate entries clone one Arc but create distinct `FileTableEntry` flags: `kernel/core/src/fs/file/file_table.rs:139-187,372-404`. Descriptor and status mutations are separate: `kernel/core/src/syscall/fcntl.rs:61-94`. | Main flags hunt: **PASS**, 10,593/3,308, depth 9. Positive alias witness: **CONTROL**, exit 12 at the negated witness, 2,942/1,093, depth 6; sequence closes `fd1`, duplicates `fd0 -> fd1`, shares `ofdStatus[timer] = TRUE`, then `FcntlSetFd(fd0, TRUE)`, leaving flags `TRUE/FALSE`. Shared-flag mutation: **CONTROL**, exit 12 at `MCFdFlagsPerSlot`, 19/14, depth 4. | Descriptor flags and OFD status flags are each reduced to one Boolean; only three slots and three OFDs are modeled. |
| 5 | `AcyclicEpollGraph` was absent and acyclicity was enforced only by a state constraint. | `base.tla`: defined the safety invariant `AcyclicEpollGraph`; retained only the successful bounded acyclic subset in `EpollAddNestedInterest`. `MC.tla`: added `MCAcyclicEpollGraph` and removed topology pruning from `MCStateConstraint`. Enabled it in neutral, base, Trace, and `MC_hunt_s6_nested.cfg`; updated coverage/instrumentation scope text. | The checked-out control path accepts a FileLike target but has no explicit nested-cycle rejection branch: `kernel/core/src/events/epoll/file.rs:64-125`. Nested callback/lock propagation is at `kernel/core/src/events/epoll/entry.rs:280-330` and `kernel/core/src/events/subject.rs:126-153`. | `MC_hunt_s6_nested.cfg`: **PASS**, 2,113/890, depth 13, checking graph, locks, epoch monotonicity, and propagation. Neutral `MC.cfg` also checks the invariant and passes. Static audit confirms `MCStateConstraint` contains no topology predicate. | Cyclic behavior outside the successful two-epoll subset remains unsupported/unverified. The model does not claim production rejects a cycle. |
| 6 | Eight production actions were absent from every `EnabledActions` set. | `MC.tla`: added controller-only `seenActions`, `MCReachView`, and one negated reach wrapper per action without bounding reactive completions. Added eight `MC_reach_*.cfg` files. Updated `brief-coverage.md`. | `SysDup2Equal`: `kernel/core/src/syscall/dup.rs:21-30`; `FileTableDupCeil`: `kernel/core/src/fs/file/file_table.rs:139-165`; DEL/error: `kernel/core/src/events/epoll/file.rs:100-144`; empty preparation: `kernel/core/src/events/epoll/file.rs:236-245`; signalfd reads: `kernel/core/src/syscall/signalfd.rs:182-201,218-243`; initial-ready: `kernel/core/src/syscall/poll.rs:165-185`. | All eight are **REACH** controls: `SysDup2Equal` 2/2 depth 2; `FileTableDupCeil` 7/5 depth 3; `EpollDelInterest` 26/17 depth 6; `EpollControlError` 4/3 depth 3; `EpollDiscardEmptyPreparation` 329/183 depth 10; `SignalFileReadThread` 44/11 depth 4; `SignalFileReadProcess` 38/8 depth 4; `PollFilesInitialReady` 11/9 depth 4. Each exits 12 only at its negated reach predicate. The 70-action enabled-union audit has no missing name. | Reachability establishes bounded model coverage, not implementation execution or Linux conformance. |
| 7 | Split eventfd mutation/notify allowed a second counter mutator while Rust still held the one counter mutex. | `base.tla`: `EventfdMutexOwnerFrom`, `EventfdMutexOwner`, guards and owner transitions in `EventfdAddCounter`, `EventfdTryRead`, `EventfdNotify`, and `PollFilesRegisterPoller`; added `EventfdMutexExclusive`. Added isolated `MC_hunt_eventfd_mutex.cfg`. `Trace.tla` validates `eventfd_owner`; positive fixture and instrumentation rows include it. | The same `counter.lock()` guard spans counter mutation and synchronous `pollee.notify`: `kernel/core/src/syscall/eventfd.rs:124-159`. | `MC_hunt_eventfd_mutex.cfg`: **PASS**, 10/7, depth 5, independent of the cache candidate. `MC_hunt_s3_cache.cfg` also enables both mutators and checks the mutex oracle before its separately classified cache candidate. Positive Trace observes owner `t1` after mutation and `no_thread` after notify. | Counter arithmetic and memory ordering are abstracted; the owner models only the source-global critical-section exclusion and release boundary. |
| 8 | Multi-key notification Trace branches checked only an aggregate callback count, so a wrong key or actor could pass. | `Trace.tla`: added `CallbackRecordFrom`, `CallbackRecordsFrom`, `SelectedCallbackRecords`, and `ValidateCallbackSelection`; timerfd, eventfd, thread-signal, and process-signal notification branches now require exact duplicate-free `{key, actor, epoch}` delta equality. Updated the `CALLBACKS` instrumentation profile and notification rows. The negative fixture changes one callback actor field only. | `SyncSubject::notify` selects concrete observers and calls each synchronously: `kernel/core/src/events/subject.rs:126-149`. | Positive `Trace.cfg`: **PASS**, 19/18, depth 18. `Trace_mutated.cfg`: **CONTROL**, exit 13 at `TraceMatched`, 15/15, depth 15. Sorted JSON diff contains exactly one change, callback `actor: t1 -> t2`. The positive fixture also contains `WaiterTimeoutExpires` with `tid=t1` and `args.target=t2`. | The callback array is a required instrumentation payload but has not been implemented in Asterinas. The exact-set predicate covers wrong keys, actors, epochs, and duplicates; the durable negative fixture mutates the actor field. |

## Full TLC matrix

All 35 neutral/focused MC configs were run after the final semantic edit.

| Config | Classification and checked result | Generated / distinct; depth |
|---|---|---|
| `MC.cfg` | PASS | 288 / 156; 7 |
| `MC_control_lifetime_phantom_mutation.cfg` | CONTROL: `MCNoPhantomLiveOFD`, exit 12 | 5 / 4; 4 |
| `MC_control_lifetime_resurrection_mutation.cfg` | CONTROL: `MCOFDsNeverResurrect`, exit 12 | 5 / 4; 4 |
| `MC_control_s1_flags_mutation.cfg` | CONTROL: `MCFdFlagsPerSlot`, exit 12 | 19 / 14; 4 |
| `MC_control_s1_flags_witness.cfg` | CONTROL: negated alias witness, exit 12 | 2,942 / 1,093; 6 |
| `MC_hunt_eventfd_mutex.cfg` | PASS | 10 / 7; 5 |
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
| `MC_hunt_s3_cache.cfg` | CANDIDATE: `MCCachedReadinessSound`, exit 12 | 1,982 / 895; 9 |
| `MC_hunt_s3_registered_delivery.cfg` | PASS | 1,487 / 669; 17 |
| `MC_hunt_s4_binding.cfg` | CANDIDATE: `MCSignalfdBindingCoversConsumer`, exit 12 | 872 / 349; 7 |
| `MC_hunt_s4_mask_transition.cfg` | CANDIDATE: `MCRegisteredTransitionNotLost`, exit 13 | 41 / 30; 8 |
| `MC_hunt_s5_arbitration.cfg` | CANDIDATE: `MCVisibleReadyWinsTerminalRace`, exit 12 | 205 / 98; 6 |
| `MC_hunt_s5_mask_restore.cfg` | PASS | 1,373 / 433; 13 |
| `MC_hunt_s6_nested.cfg` | PASS | 2,113 / 890; 13 |
| `MC_reach_epoll_control_error.cfg` | REACH, exit 12 | 4 / 3; 3 |
| `MC_reach_epoll_del_interest.cfg` | REACH, exit 12 | 26 / 17; 6 |
| `MC_reach_epoll_discard_empty.cfg` | REACH, exit 12 | 329 / 183; 10 |
| `MC_reach_file_table_dup_ceil.cfg` | REACH, exit 12 | 7 / 5; 3 |
| `MC_reach_poll_initial_ready.cfg` | REACH, exit 12 | 11 / 9; 4 |
| `MC_reach_s4_updated_before_insert.cfg` | REACH, exit 12 | 458 / 152; 6 |
| `MC_reach_signal_read_process.cfg` | REACH, exit 12 | 38 / 8; 4 |
| `MC_reach_signal_read_thread.cfg` | REACH, exit 12 | 44 / 11; 4 |
| `MC_reach_sys_dup2_equal.cfg` | REACH, exit 12 | 2 / 2; 2 |
| `MC_reach_two_checkers_loaded_invalid.cfg` | REACH, exit 12 | 12 / 9; 5 |

The final `base.cfg` smoke simulation also passed: 50 traces at depth 35,
1,754 generated states.

## Audit results

- SANY exit 0: `base.tla`, `MC.tla`, `Trace.tla`, and the
  controller-only `MC_Controls.tla`.
- Action mapping: 70 `MC.ActionNames`, 70 `Trace.MatchEvent` names, 70
  instrumentation rows, and 70 names in the union of all
  `EnabledActions`; no missing or extra name.
- Brief coverage: 21 section-5 oracles have a base definition, MC wrapper, and
  config enablement. All 34 focused config references in
  `brief-coverage.md` exist; `MC.cfg` is the additional neutral config.
- Citation audit: all 70 production action blocks and all 30 safety,
  liveness, and reach-oracle blocks contain pinned `file:line` citations.
  All 109 unique cited source starts resolve within the pinned checkout.
- Reactive-completion audit: `Reactive` leaves `faultCount` unchanged;
  ctl, callback, delivery, poll, exec, and mask-restoration completions remain
  unbounded. `seenActions` records coverage only and is excluded from the
  normal `MCView`.
- Trace controls: both JSON fixtures pass `jq -e`; their sorted diff is one
  callback actor field. Exact key/actor/epoch selection and
  `tid != args.target` are exercised as described above.
- Source fence: `git rev-parse HEAD` returned
  `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`; `git status --short`,
  `git diff --stat`, and `git diff --name-only` were empty.
- TLC cleanup: 109 generated `*_TTrace_*.tla`/`.bin` files were moved from
  the durable spec directory to
  `/tmp/specula-r2-transients-C5DqaJ`; the durable transient count is zero.

The CANDIDATE rows remain formal-model candidates. None is classified here as
a confirmed implementation defect.
