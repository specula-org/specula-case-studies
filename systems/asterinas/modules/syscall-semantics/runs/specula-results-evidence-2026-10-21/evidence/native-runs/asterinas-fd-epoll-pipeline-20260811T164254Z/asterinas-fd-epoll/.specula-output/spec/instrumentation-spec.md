# Asterinas FD/epoll trace instrumentation specification

Snapshot: `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`.

This handoff implements the Category B timebox contract in `Trace.tla`.
Instrumentation is test-only, but every emitted event below refines one pinned
production boundary. It must not change production control flow, lock scope,
notification order, or object lifetime.

## 1. Event schema

- Record events in preallocated per-actor buffers. The hot path must not take a
  shared tracing lock, allocate a sequence number, or perform an uncached global
  pointer-to-ID lookup.
- Record fenced x86_64 timestamps immediately before and after the cited
  mutation or branch. Copy the required scalar state while the production guard
  is held, but serialize after all implementation locks are released.
- Pre-register two actor IDs (`t1`, `t2`), three FD labels (`fd0`..`fd2`),
  three OFD allocation identities (`timer`, `signal`, `event`), and two epoll
  identities (`ep0`, `ep1`).
- Merge the per-actor NDJSON streams into
  `{"traces":{"t1":[...],"t2":[...]}}`. Compress timestamps to dense positive
  integers while preserving per-actor order and overlap.
- `tid` always names the executing actor. A different waiter or signal-queue
  destination is always `args.target`. Never overwrite `tid` with the target.

The common envelope is:

```json
{
  "tag": "trace",
  "event": "WaiterTimeoutExpires",
  "tid": "t1",
  "start": 17,
  "end": 19,
  "args": {"target": "t2"},
  "state": {
    "wait_state": "woken",
    "wake_cause": "timer",
    "deadline_expired": true,
    "interrupt_pending": false,
    "visible_ready": false,
    "terminal_ready": false,
    "terminal_scan_valid": false,
    "terminal_scan_expected": false,
    "current_mask": "unblocked",
    "saved_mask": "none",
    "pre_wait_mask": "unblocked",
    "return_reason": "none",
    "wait_generation": 1,
    "completed_wait_reason": "none",
    "last_completed_wait_reason": "none",
    "wait_captured_ofds": ["timer", "signal", "event"],
    "wait_capture_audit": ["timer", "signal", "event"],
    "wait_captured_slots": {"fd0":"timer","fd1":"signal","fd2":"event"},
    "wait_capture_slot_audit": {"fd0":"timer","fd1":"signal","fd2":"event"},
    "last_released_wait_ofds": [],
    "last_released_wait_slots": {"fd0":"no_ofd","fd1":"no_ofd","fd2":"no_ofd"},
    "timer_refs": 2,
    "signal_refs": 2,
    "event_refs": 2,
    "timer_alive": true,
    "signal_alive": true,
    "event_alive": true
  }
}
```

Canonical absent identities are `no_fd`, `no_ofd`, `no_epoll`, and `no_key`.
Trigger strings are `LT`, `ET`, and `ONESHOT`. Cache state is `invalid`,
`ready`, `not_ready`, or the checker actor (`t1`/`t2`). A poller's loaded value
uses the same values plus `unset`. An epoll key is always
`(args.epoll, args.fd, args.ofd)`; `args.ofd` must come from the captured Arc,
not a later numeric-slot lookup.

Shared post-state profiles used below:

| Profile | Exact fields checked by `Trace.tla` |
|---|---|
| `FD` | `slot_ofd`, `slot_cloexec`, `slot_epoch`, `slot_map_audit` |
| `EMPTY_FD_FLAG_AUDIT` | `fd_flag_audit_active=false` |
| `CTL` | `ctl_phase`, `ctl_command`, `ctl_epoll`, `ctl_fd`, `ctl_target`, `ctl_slot_epoch`, `ctl_trigger`, `ctl_observed` |
| `KEY` | `key_in_interest`, `key_enabled`, `key_trigger`, `key_registered`, `key_faulted`, `key_binding_count`, `key_in_ready`, `key_slot_epoch`, `identity_active`, `identity_fd`, `identity_ofd`, `identity_slot_epoch`, `queued_epoch`, `key_delivered`, `interest_count`, `ready_count` |
| `ENTRY_UPDATE` | `epoll_waiter`, `key_enabled`, `key_trigger`, `key_slot_epoch`, `key_registered`, `key_faulted`, `key_binding_count`, `key_bound_to_actor`, `key_bound_to_consumer`, `ready_epoch`, `consumer_ready_epoch` |
| `DELIVERY` | `delivery_stage`, `delivery_key_present`, `delivery_had_event`, `delivery_epoch`, `copyout_result` |
| `POLL` | `poll_phase`, `poll_ofd`, `poll_loaded`, `poll_observed`, `cache_state`, `source_ready` |
| `WAIT` | `wait_state`, `wake_cause`, `deadline_expired`, `interrupt_pending`, `visible_ready`, `terminal_ready`, `terminal_scan_valid`, `terminal_scan_expected`, `current_mask`, `saved_mask`, `pre_wait_mask`, `return_reason`, `wait_generation`, current and last completed reason, exact duplicate-free `wait_captured_ofds`, `wait_capture_audit`, and `last_released_wait_ofds`, exact `wait_captured_slots`, `wait_capture_slot_audit`, and `last_released_wait_slots` FD-to-OFD maps, per-OFD derived strong-ref counts, and every `ofdAlive` bit |
| `EXEC_EXTERNAL` | `exec_before_dup`, `exec_after_dup`, `exec_before_cloexec`, `exec_after_cloexec`, `exec_old_table_retained`; exact history-only sides of the atomic clone/install boundary and whether an external CLONE_FILES owner keeps the old table alive |
| `READINESS_EPOCHS` | `ready_epoch_changes`, exact duplicate-free `{epoll,fd,ofd,epoch}` deltas, and `consumer_epoch_changes`, exact duplicate-free `{epoll,fd,ofd,thread,epoch}` deltas |
| `CALLBACKS` | `callbacks`, an exact duplicate-free array of `{epoll,fd,ofd,actor,epoch}` records selected by the synchronous notification |
| `WAKE_CALLBACKS` | `wake_callbacks`, an exact duplicate-free array of `{target,ofd,actor,epoch}` Poller/Waker records selected by the same notification |
| `SCENARIO4` | `scenario4_keys`, an exact duplicate-free array of `{epoll,fd,ofd,consumer,enabled,trigger,slot_epoch,registered,bound,ready_epoch,consumer_ready_epoch}` for every signalfd interest in the selected epoll |
| `SIGNAL_NOTIFY` | `signal_notify_phase`, `signal_notify_queue`, `signal_notify_target`, `signal_notify_epoch`, `signal_pending_key_count`, `signal_pending_waiter_count` |
| `PENDING_KEYS` | `eventfd_pending_keys` and `signal_pending_keys`, exact duplicate-free arrays of `{epoll,fd,ofd}` keys remaining after suppression or callback return |
| `PENDING_WAITERS` | `eventfd_pending_waiters` and `signal_pending_waiters`, exact duplicate-free arrays of waiter actor IDs remaining after a wake callback |

## 2. One-to-one action mapping

Paths are relative to the pinned source root. Each table row is one
`Trace.MatchEvent` branch and one base action.

| Event | Production boundary | `args`; checked post-state |
|---|---|---|
| `FileTableInsert` | `kernel/core/src/fs/file/file_table.rs:190-194`, one `put` under the write guard | `fd,ofd,cloexec`; `FD,EMPTY_FD_FLAG_AUDIT,ofd_alive` |
| `FcntlSetFlCapture` | `kernel/core/src/syscall/fcntl.rs:87-91` and `kernel/core/src/fs/file/file_table.rs:326-367`, after `get_file_fast!` returns its Arc/Cow | `fd,status`; `captured_ofd,capture_epoch,last_captured,acted_ofd,acted_slot_ofd,acted_capture_epoch,acted_slot_epoch` |
| `FcntlSetFlUse` | `kernel/core/src/syscall/fcntl.rs:91-94`, around `update_status_flags` on the captured object and captured-reference release | none; `acted_ofd,acted_slot_ofd,acted_capture_epoch,acted_slot_epoch,ofd_status,ofd_alive`; captured OFD/FD/status must be canonical empty values |
| `SysCloseRemove` | `kernel/core/src/syscall/close.rs:25-31` and `kernel/core/src/fs/file/file_table.rs:196-205`, one removal under the write guard | `fd`; `FD,EMPTY_FD_FLAG_AUDIT,close_pending` |
| `ClosedFileDrop` | `kernel/core/src/syscall/close.rs:33-40` and `kernel/core/src/fs/file/file_table.rs:297-302`, after the returned `ClosedFile` drops | `ofd`; `close_pending,ofd_alive` |
| `SysDup2Equal` | `kernel/core/src/syscall/dup.rs:21-30`, equal-FD validation lookup | `fd`; `acted_ofd` |
| `SysDup3Validate` | `kernel/core/src/syscall/dup.rs:50-73`, after equality/range validation | `source_fd,target_fd,cloexec`; `replacement_phase` |
| `FileTableDupExact` | `kernel/core/src/fs/file/file_table.rs:169-187` and `kernel/core/src/syscall/dup.rs:73-77`, source clone, target removal, and insert under one guard | `target_fd`; `FD,EMPTY_FD_FLAG_AUDIT` and the complete replacement record plus `close_pending` |
| `FileTableDupExactBadFd` | `kernel/core/src/fs/file/file_table.rs:181-187`, source-missing error branch | none; `replacement_phase` |
| `DupReplacementCleanup` | `kernel/core/src/syscall/dup.rs:73-78` and `kernel/core/src/fs/file/file_table.rs:297-302`, replacement `ClosedFile` drop after unlock | `ofd`; `replacement_phase,close_pending,ofd_alive` |
| `FileTableDupCeil` | `kernel/core/src/fs/file/file_table.rs:139-165` and `kernel/core/src/syscall/fcntl.rs:43-50`, lowest-free insert under one guard | `source_fd,target_fd,cloexec`; `FD,EMPTY_FD_FLAG_AUDIT,EXEC_EXTERNAL` |
| `FcntlSetFd` | `kernel/core/src/syscall/fcntl.rs:61-73` and `kernel/core/src/fs/file/file_table.rs:389-395`, per-entry flag update | `fd,cloexec`; `slot_cloexec` and the complete FD-flag audit record |
| `SysCloseRangeCloexec` | `kernel/core/src/syscall/close.rs:76-101`, the complete range loop under its single write guard | `first_fd,last_fd`; `fd0_cloexec,fd1_cloexec,fd2_cloexec,EMPTY_FD_FLAG_AUDIT,EXEC_EXTERNAL` |
| `ExecveWaitOtherThreadsExit` | `kernel/core/src/process/execve.rs:161-164,202-225`, after the task-count condition succeeds | none; `exec_phase,EXEC_EXTERNAL`; the bounded environment records whether a distinct CLONE_FILES process retains the old table |
| `ContextUnshareFiles` | `kernel/core/src/process/namespace/unshare.rs:18-28` and `kernel/core/src/fs/file/file_table.rs:117-121`, one atomic old-table read-lock/clone/install boundary | none; `exec_phase,shared_table`, complete snapshot and private slot/flag/epoch/shadow maps, `EXEC_EXTERNAL` |
| `FileTableCloseFilesOnExec` | `kernel/core/src/process/execve.rs:381-386` and `kernel/core/src/fs/file/file_table.rs:208-234`, scan the installed private table under one guard, then drop every returned `ClosedFile` | none; `exec_phase`, complete private slot/flag/epoch/shadow maps, `EXEC_EXTERNAL,timer_alive,signal_alive,event_alive` |
| `EpollControlCaptureTarget` | `kernel/core/src/events/epoll/file.rs:65-84`, after target lookup and file-table borrow release | `epoll,fd,command,trigger`; `CTL` |
| `EpollAddInterest` | `kernel/core/src/events/epoll/file.rs:96-125` and `kernel/core/src/events/epoll/entry.rs:76-100`, insertion of the already-updated Entry after `Entry::update` returns | key; `CTL,KEY` |
| `EpollModInterest` | `kernel/core/src/events/epoll/file.rs:147-176` and `kernel/core/src/events/epoll/entry.rs:155-166`, exact-entry update | key; `CTL,KEY` |
| `EpollDelInterest` | `kernel/core/src/events/epoll/file.rs:65-84,130-144,340-343` and `kernel/core/src/events/epoll/entry.rs:168-176`, exact-key removal/shutdown and terminal captured-Arc release | key plus `bound_thread`; `CTL,KEY,key_bound,ofd_alive` |
| `EpollControlError` | `kernel/core/src/events/epoll/file.rs:65-84,100-105,140-142,160-163`, EEXIST/ENOENT return and terminal captured-Arc release | key; `interest_count,ofd_alive` |
| `EntryUpdatePoll` | `kernel/core/src/events/epoll/file.rs:96-120,147-176`, `kernel/core/src/events/epoll/entry.rs:155-166`, and `kernel/core/src/syscall/signalfd.rs:205-215`, register-before-check completion; for ADD this precedes insertion | key plus `consumer`; `CTL,ENTRY_UPDATE` |
| `EpollControlPushReady` | `kernel/core/src/events/epoll/file.rs:65-84,110-125,166-176`, post-update ready push or not-ready terminal branch and captured-Arc release | key; empty `CTL`, `key_in_ready,queued_epoch,epoll_wake,epoll_ready_epoch,ofd_alive` |
| `ReadySetPush` | `kernel/core/src/events/subject.rs:126-149` and `kernel/core/src/events/epoll/entry.rs:280-283,307-330`, callback-selected ready insertion | key; `key_in_ready,key_notified,queued_epoch,callback_epoch,callback_actor,callback_stage,epoll_wake,epoll_ready_epoch` plus pending counts |
| `ReadySetPushSuppressed` | `kernel/core/src/events/epoll/entry.rs:247-271,307-318`, selected callback suppressed by shutdown/disable | key; `callback_epoch,callback_actor,key_in_ready,PENDING_KEYS` |
| `ReadySetPopDeleted` | `kernel/core/src/events/epoll/entry.rs:367-390`, weak-token upgrade failure | key; `key_in_ready,ready_count,epoll_wake` |
| `ReadySetPop` | `kernel/core/src/events/epoll/entry.rs:367-397`, pop and `reset_ready` | key; `DELIVERY,key_in_ready,epoll_wake` |
| `EntryPollDeadFile` | `kernel/core/src/events/epoll/entry.rs:103-117` and `kernel/core/src/events/epoll/file.rs:225-233`, weak OFD upgrade failure and exact-interest cleanup | key; `DELIVERY,KEY,ofd_alive` |
| `EntryPollDisabled` | `kernel/core/src/events/epoll/entry.rs:118-124`, disabled early return | key; `DELIVERY` |
| `EntryPollPrepare` | `kernel/core/src/events/epoll/entry.rs:116-149` and `kernel/core/src/events/epoll/file.rs:225-244`, live poll, LT requeue, and one-shot disable | key; `DELIVERY,key_enabled,key_in_ready,queued_epoch,epoll_wake` |
| `EpollDiscardEmptyPreparation` | `kernel/core/src/events/epoll/file.rs:236-245`, empty prepared event discarded | key; `DELIVERY` |
| `DoEpollPwait2CopyoutSuccess` | `kernel/core/src/syscall/epoll.rs:145-154`, successful userspace write | key; `DELIVERY,key_delivered,key_faulted,reported_ofd,delivered_epoch`; `lastDeliveredKey` is the event key |
| `DoEpollPwait2CopyoutFault` | `kernel/core/src/syscall/epoll.rs:145-152`, failed userspace write | key; `DELIVERY,key_faulted,key_enabled,key_in_ready` |
| `PolleePollWithRegister` | `kernel/core/src/process/signal/poll.rs:90-107,154-165`, register before cache load | `ofd`; `POLL,direct_registered` |
| `PolleePollWithLoad` | `kernel/core/src/process/signal/poll.rs:106-112`, atomic cache load before any checker installation | `ofd`; `POLL` |
| `PolleePollWithCached` | `kernel/core/src/process/signal/poll.rs:106-110`, return loaded nonnegative cache | `ofd`; `POLL,observed_ready,observed_epoch` |
| `PolleePollWithBeginCheck` | `kernel/core/src/process/signal/poll.rs:112-134`, swap invalid cache to this actor's task identity | `ofd`; `POLL` |
| `PolleePollWithCheck` | `kernel/core/src/process/signal/poll.rs:135-136`, live source checker | `ofd`; `POLL` |
| `PolleePollWithCache` | `kernel/core/src/process/signal/poll.rs:138-151`, checker-identity compare-exchange and result | `ofd`; `POLL,observed_ready,observed_epoch` |
| `PolleePollWithConcurrentCheck` | `kernel/core/src/process/signal/poll.rs:112-115`, direct check after another actor installed its identity | `ofd`; `POLL,observed_ready,observed_epoch` |
| `PolleePollWithFinish` | `kernel/core/src/process/signal/poll.rs:150-152`, poll return and captured-reference release | `ofd`; `poll_phase,ofd_alive` |
| `TimerfdExpired` | `kernel/core/src/time/timerfd.rs:98-105`, tick increment before notify | none; `timer_ticks,source_ready,source_epoch,producer_phase,READINESS_EPOCHS` |
| `TimerfdNotify` | `kernel/core/src/time/timerfd.rs:102-105`, `kernel/core/src/process/signal/poll.rs:167-178`, and `kernel/core/src/events/subject.rs:126-149`, cache invalidation and synchronous observer selection | none; `cache_state,producer_phase,CALLBACKS,WAKE_CALLBACKS` |
| `TimerfdTryRead` | `kernel/core/src/time/timerfd.rs:177-186`, nonzero `fetch_and(0)` | none; `timer_ticks,source_ready,cache_state` |
| `TimerfdSetTimeDisarm` | `kernel/core/src/time/timerfd.rs:130-145`, cancel and clear | none; `timer_ticks,source_ready,cache_state` |
| `EventfdAddCounter` | `kernel/core/src/syscall/eventfd.rs:151-159`, counter mutation while the counter mutex remains held through the following notify | none; `event_counter,source_ready,source_epoch,producer_phase,eventfd_owner,eventfd_counter_snapshot,READINESS_EPOCHS` |
| `EventfdTryRead` | `kernel/core/src/syscall/eventfd.rs:124-143`, decrement/clear while the counter mutex remains held through the following notify | none; `event_counter,source_ready,producer_phase,eventfd_owner,eventfd_counter_snapshot` |
| `EventfdNotify` | `kernel/core/src/syscall/eventfd.rs:141-142,158-159`, `kernel/core/src/process/signal/poll.rs:167-178`, and `kernel/core/src/events/subject.rs:126-149`, begin synchronous observer dispatch while retaining the counter mutex | none; `cache_state,producer_phase,eventfd_owner,eventfd_counter_snapshot,CALLBACKS,WAKE_CALLBACKS` |
| `EventfdNotifyReturn` | `kernel/core/src/syscall/eventfd.rs:124-159` and `kernel/core/src/events/subject.rs:126-153`, all selected observer/Waker callbacks have returned or been suppressed and `notify` returns before the counter guard drops | none; `producer_phase,eventfd_owner,eventfd_pending_key_count,eventfd_pending_waiter_count,eventfd_counter_snapshot` |
| `SignalfdUpdateMask` | `kernel/core/src/syscall/signalfd.rs:103-117,155-161`, atomic mask store without notification | `enabled`; `signal_mask,source_epoch,READINESS_EPOCHS` |
| `SigQueuesEnqueueThread` | `kernel/core/src/process/signal/sig_queues.rs:38-45` and `kernel/core/src/process/posix_thread/mod.rs:249-270`, queue mutation under `queues.lock()` through the explicit guard-drop boundary | `target`; `thread_pending,source_epoch,SIGNAL_NOTIFY,thread_enqueue_epoch,READINESS_EPOCHS`; callback arrays are absent at this boundary |
| `SigQueuesEnqueueProcess` | `kernel/core/src/process/signal/sig_queues.rs:38-45` and `kernel/core/src/process/posix_thread/mod.rs:264-270`, process queue mutation under `queues.lock()` through the explicit guard-drop boundary | none; `process_pending,source_epoch,SIGNAL_NOTIFY,process_enqueue_epoch,READINESS_EPOCHS`; callback arrays are absent at this boundary |
| `SigQueuesNotifyThread` | `kernel/core/src/process/signal/sig_queues.rs:38-45,86-92` and `kernel/core/src/events/subject.rs:126-153`, later unlocked notify snapshots exact observers and Wakers | `target`; `cache_state,SIGNAL_NOTIFY,thread_notify_epoch,CALLBACKS,WAKE_CALLBACKS` |
| `SigQueuesNotifyProcess` | `kernel/core/src/process/signal/sig_queues.rs:38-45,86-92` and `kernel/core/src/events/subject.rs:126-153`, later unlocked process notify snapshots exact observers and Wakers | none; `cache_state,SIGNAL_NOTIFY,process_notify_epoch,CALLBACKS,WAKE_CALLBACKS` |
| `SigQueuesNotifyReturn` | `kernel/core/src/process/signal/sig_queues.rs:38-45` and `kernel/core/src/events/subject.rs:126-153`, all exact selected callbacks return before the notify call returns | none; idle/empty `SIGNAL_NOTIFY` |
| `SignalFileReadThread` | `kernel/core/src/syscall/signalfd.rs:182-201,218-243`, consuming actor dequeues its thread-directed signal | none; `thread_pending` |
| `SignalFileReadProcess` | `kernel/core/src/syscall/signalfd.rs:182-201,218-243`, consuming actor dequeues process-directed signal | none; `process_pending` |
| `EpollWaitRegisterConsumer` | `kernel/core/src/events/epoll/file.rs:191-205` and `kernel/core/src/syscall/signalfd.rs:205-215`, wait actor becomes the epoll consumer and polls every selected Entry | `epoll`; `epoll_waiter,SCENARIO4` |
| `SaveAndSetSigMask` | `kernel/core/src/syscall/ppoll.rs:31-40`, `kernel/core/src/syscall/pselect6.rs:33-52`, and `kernel/core/src/syscall/epoll.rs:114-121` | `mask`; `WAIT` |
| `PollFilesRegisterPoller` | `kernel/core/src/syscall/poll.rs:88-106,134-185`, complete register-before-check pass with its live return value stored in `visible_ready` | none; `WAIT,last_ready_ofd,last_ready_actor,last_ready_epoch` |
| `PollFilesInitialReady` | `kernel/core/src/syscall/poll.rs:167-185`, initial-ready branch with the live terminal scan snapshot | none; `WAIT` |
| `WaiterPauseTimeoutBlock` | `kernel/core/src/process/signal/poll.rs:307-315` and `kernel/core/src/process/signal/pause.rs:171-200`, immediately before wait | none; `WAIT` |
| `WaiterReadinessWake` | `kernel/core/src/process/signal/poll.rs:167-178,318-321` and `kernel/core/src/events/epoll/entry.rs:327-330`, a producer-selected callback consumes its exact OFD/actor/epoch token and wakes another waiter | `target`; target `WAIT`, `producer_ofd,producer_actor,producer_epoch`, canonical-empty `wait_token_ofd,wait_token_actor,wait_token_epoch`, and `PENDING_WAITERS` |
| `WaiterTimeoutExpires` | `kernel/core/src/process/signal/pause.rs:171-177`, timer callback wakes target | `target`; target `WAIT` |
| `WaiterSignalInterrupts` | `kernel/core/src/process/signal/pause.rs:184-219` and `kernel/core/src/process/posix_thread/mod.rs:249-264`, actor signals target waiter | `target`; target `WAIT` |
| `WaiterPauseTimeoutReturnTimeout` | `kernel/core/src/process/signal/pause.rs:202-209` and `kernel/core/src/syscall/poll.rs:108-121,188-215`, ETIME selection plus an audit snapshot of live modeled file readiness at that terminal boundary | none; `WAIT` |
| `WaiterPauseTimeoutReturnSignal` | `kernel/core/src/process/signal/pause.rs:211-219` and `kernel/core/src/syscall/poll.rs:108-121,188-215`, EINTR selection plus the same live terminal audit snapshot | none; `WAIT` |
| `DoPollCountEvents` | `kernel/core/src/syscall/poll.rs:108-121,188-215`, post-wake live event count and terminal snapshot | none; `WAIT` |
| `HandlePendingSignalRestoreMask` | `kernel/core/src/process/signal/mod.rs:64-85,208-230`, restoration guard completion | none; `WAIT` |
| `EpollAddNestedInterest` | `kernel/core/src/events/epoll/file.rs:64-125`, successful acyclic epoll-as-target insertion within the bounded scope | `outer,inner`; `edge_present,graph_size` |
| `ReadySetPushAcquire` | `kernel/core/src/events/subject.rs:126-149` and `kernel/core/src/events/epoll/entry.rs:280-283,307-325`, callback acquires ready-set lock | key plus `epoll`; `lock_owner,lock_held` |
| `ReadySetPushNotifySubject` | `kernel/core/src/events/epoll/entry.rs:320-330` and `kernel/core/src/events/subject.rs:126-149`, inner notify acquires subject lock while ready lock is held | `epoll`; `lock_owner,lock_held,callback_stage` |
| `SyncSubjectCallbackReadySet` | `kernel/core/src/events/subject.rs:136-149` and `kernel/core/src/events/epoll/entry.rs:280-325`, synchronous outer callback acquires outer ready lock | `inner,outer`; `lock_owner,lock_held,nested_delivered_epoch` |
| `ObserverCallbackRelease` | `kernel/core/src/events/subject.rs:126-153` and `kernel/core/src/events/epoll/entry.rs:307-331`, one selected Entry callback and its nested callbacks return and guards drop | none; `held_count,owned_lock_count,callback_stage,PENDING_KEYS`; callback key is canonical empty after return |

## 3. Controller-only state and exclusions

- `MC.tla`'s `ActionNames` filters, introduction counters, `seenActions`,
  `CrossReuseHunt`, and `MaskTransitionHunt` are exploration-controller state.
  They are not base actions, do not appear in `Trace.MatchEvent`, and must never
  be emitted as implementation behavior.
- `MC_Controls.tla` contains only explicitly named phantom-live,
  resurrection, shared-descriptor-flag, eventfd early-release/second-mutation,
  wrong-key-OFD/stale-generation, dead-plus-disabled, slot-shadow divergence,
  mask-restore corruption, epoll-cycle, terminal-snapshot substitution, and
  notify-before-enqueue, poll-snapshot omission/early release, stale-second-wait,
  and exec-private alias/wrong-table transitions. These controller-only
  controls have no production counterpart and no trace event.
- The model has no `CapturedFileOperation`, `FileLikeFinalDrop`, `ResetWait`,
  or `EpollRejectNestedCycle` transition. Captured F_SETFL use has its own
  source boundary; strong-reference release is folded into actual close/dup
  cleanup; wait reset is outside a syscall trace; the pinned source has no
  cycle-rejection branch.
- `EpollAddNestedInterest` covers only successful acyclic insertions in the
  stated two-epoll scope. `AcyclicEpollGraph` is checked as an invariant, while
  the action's scope guard is not evidence that production rejects a self-edge
  or back-edge.
- Descriptor close interleaves through `SysCloseRemove`; the model does not
  synthesize a wake because the pinned generic close path has no such branch.

## 4. Probe and validation controls

- Keep FD-slot identity, slot epoch, and OFD allocation identity in the event
  record. Copyout reports the prepared key's OFD, never the current slot.
- Keep actor and target independently registered. Producer/timer callbacks may
  have `tid != args.target`.
- Every notification record must include complete `callbacks` and
  `wake_callbacks` arrays. `Trace.tla` compares key or waiter target, OFD,
  callback actor, and producer epoch as exact sets and rejects duplicates; an
  aggregate count is insufficient.
- Signal enqueue and notify are distinct events. Capture the pending queue,
  target, and epoch at the explicit `drop(queues)` boundary, then emit the
  later notify event with the exact observer/Waker selection made after any
  intervening registration or mask changes. Do not hold or reacquire
  `queues.lock()` across the notify probe.
- An eventfd probe must retain the source-global counter-guard owner and
  counter snapshot from mutation through `EventfdNotify`, every selected
  callback/suppression, and `EventfdNotifyReturn`. The return event is illegal
  while either pending set is nonempty.
- Scenario 4 probes must emit the exact `SCENARIO4` array at consumer
  registration and all listed Entry fields at `EntryUpdatePoll`; no missing
  field is inferred from a later state.
- Every terminal wait event emits both the implementation result and the
  audit-only live snapshot fields `terminal_scan_valid` and
  `terminal_scan_expected`. `visible_ready` remains historical Waker state and
  cannot be substituted for that snapshot.
- Every wait event emits the exact duplicate-free OFD identity set plus the
  fixed FD-to-OFD `PollFiles::Owned` snapshot. The latter preserves multiple
  cloned owners for duplicated descriptors. Terminal events emit the exact
  released snapshot and post-release strong-ref counts; no later numeric FD
  lookup may reconstruct these fields.
- `ContextUnshareFiles` emits both the old-table snapshot and the installed
  private table at the atomic `namespace/unshare.rs:18-28` boundary. External
  sharer mutations emit only through the ordinary duplication/close-range
  events and carry `EXEC_EXTERNAL`; post-cutover changes must not appear in the
  private table.
- A trace is complete only after all captures, ctl/delivery/poll PCs, signal
  notify continuations, wait tokens, callback locks, producer scopes, and
  temporary-mask restoration obligations are quiescent. `syscall_done` still
  requires `HandlePendingSignalRestoreMask`; only `idle` and `returned` are
  quiescent wait PCs.
- Do not reacquire file-table, epoll-interest, ready-set, subject, signal-queue,
  or timer locks to construct a global snapshot.
- `Trace.cfg` selects `../traces/remediation-positive.json` through the
  `TraceFile` constant. It exercises `tid != args.target`, ADD update before
  insertion, all Scenario 4 fields, exact Entry/Waker callback identities, the
  eventfd begin/callback/return scope, and the initial-ready poll terminal.
  `Trace_mutated.cfg` changes one observer `actor` field.
  `Trace_omitted_callback.cfg` omits a selected Entry callback, and
  `Trace_early_owner_release.cfg` changes only the notify post-state owner.
  The dead-file and terminal-snapshot configs add one-field post-state
  controls. `Trace_terminal_snapshot_positive.cfg` is the focused positive
  initial-ready/release trace, while `Trace_poll_snapshot_mutated.cfg` changes
  one captured FD-to-OFD audit field. The three truncated configs end after F_SETFL capture, temporary
  mask installation, and epoll ctl capture. TLC must reject every negative or
  truncated fixture.
- Temporary-mask restoration occurs in syscall-return signal handling, so
  `SaveAndSetSigMask` and `HandlePendingSignalRestoreMask` remain separate.
- A candidate remains unconfirmed until its TLA+ counterexample is minimized
  and an isolated Asterinas regression passes with `SMP=2` while Linux
  demonstrates the intended behavior.

## 5. Action-to-instrumentation audit

The durable audit compares the 74 names in `base.ProductionActionNames`, the
74 nonempty branches of `base.ProductionActionSource`, the 74 MC wrapper
literals, both 74-branch Trace dispatches, and the 74 table rows above. It also
parses every `kernel/...rs:line-line` mapping and verifies the pinned path and
line bounds. Required result: no missing or extra name, no unresolved source
range, and no controller-only name in either Trace dispatch. The final command
and result are recorded in `remediation-report-round5.md`.
