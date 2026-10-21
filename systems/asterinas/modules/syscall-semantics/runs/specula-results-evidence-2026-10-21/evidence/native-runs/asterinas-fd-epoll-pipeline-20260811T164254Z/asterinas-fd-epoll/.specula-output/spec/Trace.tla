---- MODULE Trace ----
(***************************************************************************)
(* Category B timebox trace validation for Asterinas FD/epoll lifecycle.   *)
(* Each event branch invokes exactly one production-backed base action.    *)
(***************************************************************************)

EXTENDS base, Json, Naturals, Sequences, TLC

CONSTANT TraceFile

TraceData == JsonDeserialize(TraceFile)
traces == TraceData.traces

VARIABLE pc
traceAllVars == <<allVars, pc>>

ThreadsWithEvents ==
    {t \in DOMAIN traces : pc[t] <= Len(traces[t])}

ViablePIDs ==
    {t \in ThreadsWithEvents :
        ~\E other \in ThreadsWithEvents :
            /\ other /= t
            /\ traces[other][pc[other]].end < traces[t][pc[t]].start}

KeyFrom(line) == Key(line.args.epoll, line.args.fd, line.args.ofd)

CallbackRecordFrom(item) ==
    [key |-> Key(item.epoll, item.fd, item.ofd),
     actor |-> item.actor,
     epoch |-> item.epoch]

CallbackRecordsFrom(line) ==
    \* A notification probe emits every selected observer identity, executing
    \* callback actor, and producer epoch. Duplicate JSON rows are rejected.
    \* kernel/core/src/events/subject.rs:126-149
    {CallbackRecordFrom(line.state.callbacks[i]) :
        i \in 1..Len(line.state.callbacks)}

SelectedCallbackRecords ==
    \* This is the exact pre/post delta selected by this synchronous
    \* notification. Unrelated callbacks pending before the event are not
    \* attributed to the current producer.
    \* kernel/core/src/events/subject.rs:136-149
    {[key |-> k, actor |-> callbackActor'[k], epoch |-> callbackEpoch'[k]] :
        k \in {q \in InterestKeys :
                  callbackEpoch[q] = 0 /\ callbackEpoch'[q] > 0}}

ValidateCallbackSelection(line) ==
    \* Equality, rather than aggregate cardinality, detects a wrong weak-entry
    \* key, wrong callback actor, or wrong producer epoch.
    \* kernel/core/src/events/subject.rs:136-149
    /\ Len(line.state.callbacks) = Cardinality(CallbackRecordsFrom(line))
    /\ CallbackRecordsFrom(line) = SelectedCallbackRecords

WakeRecordFrom(item) ==
    [target |-> item.target,
     ofd |-> item.ofd,
     actor |-> item.actor,
     epoch |-> item.epoch]

WakeRecordsFrom(line) ==
    \* Poller Waker callbacks are selected by the same synchronous Pollee
    \* notification and retain target separately from executing actor.
    \* kernel/core/src/process/signal/poll.rs:154-178,318-321
    {WakeRecordFrom(line.state.wake_callbacks[i]) :
        i \in 1..Len(line.state.wake_callbacks)}

SelectedWakeRecords ==
    \* Exact token deltas reject a wrong target, OFD, actor, or producer epoch.
    \* kernel/core/src/process/signal/poll.rs:167-178,318-321
    {[target |-> w, ofd |-> waitReadyToken'[w].ofd,
      actor |-> waitReadyToken'[w].actor,
      epoch |-> waitReadyToken'[w].epoch] :
        w \in {q \in Threads :
                  waitReadyToken[q].epoch = 0
                  /\ waitReadyToken'[q].epoch > 0}}

ValidateWakeSelection(line) ==
    \* Equality and duplicate rejection make multi-observer notification
    \* validation independent of aggregate pending counts.
    \* kernel/core/src/events/subject.rs:136-149
    /\ Len(line.state.wake_callbacks) = Cardinality(WakeRecordsFrom(line))
    /\ WakeRecordsFrom(line) = SelectedWakeRecords

Scenario4RecordFrom(item) ==
    [key |-> Key(item.epoll, item.fd, item.ofd),
     consumer |-> item.consumer,
     enabled |-> item.enabled,
     trigger |-> item.trigger,
     slotEpoch |-> item.slot_epoch,
     registered |-> item.registered,
     bound |-> item.bound,
     readyEpoch |-> item.ready_epoch,
     consumerReadyEpoch |-> item.consumer_ready_epoch]

Scenario4RecordsFrom(line) ==
    \* The wait event carries every signalfd Entry affected for this epoll,
    \* not one aggregate count or one arbitrarily selected key.
    \* kernel/core/src/events/epoll/file.rs:191-205
    \* kernel/core/src/syscall/signalfd.rs:205-215
    {Scenario4RecordFrom(line.state.scenario4_keys[i]) :
        i \in 1..Len(line.state.scenario4_keys)}

Scenario4PostRecords(consumer, ep) ==
    {[key |-> k, consumer |-> consumer,
      enabled |-> entryEnabled'[k], trigger |-> triggerMode'[k],
      slotEpoch |-> keySlotEpoch'[k], registered |-> (k \in registered'),
      bound |-> (Binding(k, consumer) \in pollerBindings'),
      readyEpoch |-> readyEpoch'[k],
      consumerReadyEpoch |-> consumerReadyEpoch'[Binding(k, consumer)]] :
        k \in {q \in interest' : q.epoll = ep /\ q.ofd = SignalOFD}}

ValidateScenario4Records(consumer, ep, line) ==
    \* Exact equality covers waiter identity, entry mode/enablement, captured
    \* generation, registration/binding, and both readiness epochs.
    \* kernel/core/src/events/epoll/entry.rs:155-166
    \* kernel/core/src/syscall/signalfd.rs:205-215
    /\ Len(line.state.scenario4_keys) =
          Cardinality(Scenario4RecordsFrom(line))
    /\ Scenario4RecordsFrom(line) = Scenario4PostRecords(consumer, ep)

(***************************************************************************)
(* Event-specific post-state validation.                                  *)
(*                                                                         *)
(* The implementation reads these fields at the cited semantic boundary   *)
(* in instrumentation-spec.md. No branch accepts missing state as a       *)
(* wildcard. FD/OFD and actor/target identity are never reconstructed from *)
(* a later file-table or waiter lookup.                                    *)
(* kernel/core/src/fs/file/file_table.rs:326-367                           *)
(* kernel/core/src/process/posix_thread/mod.rs:249-270                     *)
(***************************************************************************)

ValidateFdAt(fd, line) ==
    \* kernel/core/src/fs/file/file_table.rs:139-205,372-404
    /\ slots'[fd] = line.state.slot_ofd
    /\ slotFlags'[fd] = line.state.slot_cloexec
    /\ slotEpoch'[fd] = line.state.slot_epoch
    /\ slotMapAudit'[fd] = line.state.slot_map_audit

ValidateEmptyFdFlagAudit(line) ==
    \* kernel/core/src/fs/file/file_table.rs:181-205,372-404
    /\ fdFlagAudit'.active = line.state.fd_flag_audit_active
    /\ ~fdFlagAudit'.active

ValidateCtl(t, line) ==
    \* kernel/core/src/events/epoll/file.rs:65-84,96-176
    /\ ctl'[t].phase = line.state.ctl_phase
    /\ ctl'[t].command = line.state.ctl_command
    /\ ctl'[t].epoll = line.state.ctl_epoll
    /\ ctl'[t].fd = line.state.ctl_fd
    /\ ctl'[t].target = line.state.ctl_target
    /\ ctl'[t].slotEpoch = line.state.ctl_slot_epoch
    /\ ctl'[t].trigger = line.state.ctl_trigger
    /\ ctl'[t].observed = line.state.ctl_observed

ValidateEmptyCtl(t, line) ==
    \* kernel/core/src/events/epoll/file.rs:65-84,122-178
    /\ ValidateCtl(t, line)
    /\ ctl'[t] = EmptyCtl

ValidateKeyState(k, line) ==
    \* kernel/core/src/events/epoll/file.rs:96-176,210-245
    \* kernel/core/src/events/epoll/entry.rs:46-67,103-176,367-397
    /\ (k \in interest') = line.state.key_in_interest
    /\ entryEnabled'[k] = line.state.key_enabled
    /\ triggerMode'[k] = line.state.key_trigger
    /\ (k \in registered') = line.state.key_registered
    /\ (k \in faultedUndelivered') = line.state.key_faulted
    /\ Cardinality({b \in pollerBindings' : b.key = k}) =
          line.state.key_binding_count
    /\ (k \in readyQ') = line.state.key_in_ready
    /\ keySlotEpoch'[k] = line.state.key_slot_epoch
    /\ interestIdentity'[k].active = line.state.identity_active
    /\ interestIdentity'[k].fd = line.state.identity_fd
    /\ interestIdentity'[k].ofd = line.state.identity_ofd
    /\ interestIdentity'[k].slotEpoch = line.state.identity_slot_epoch
    /\ queuedEpoch'[k] = line.state.queued_epoch
    /\ (k \in deliveredKeys') = line.state.key_delivered
    /\ Cardinality(interest') = line.state.interest_count
    /\ Cardinality(readyQ') = line.state.ready_count

ValidateEntryUpdate(t, line) ==
    \* Entry::update mutates every field below before returning its live poll
    \* result; consumer identity is the epoll waiter, not the ctl actor.
    \* kernel/core/src/events/epoll/entry.rs:155-166
    \* kernel/core/src/syscall/signalfd.rs:205-215
    LET k == KeyFrom(line)
        consumer == line.args.consumer
    IN
    /\ epollWaiter'[k.epoll] = line.state.epoll_waiter
    /\ entryEnabled'[k] = line.state.key_enabled
    /\ triggerMode'[k] = line.state.key_trigger
    /\ keySlotEpoch'[k] = line.state.key_slot_epoch
    /\ (k \in registered') = line.state.key_registered
    /\ (k \in faultedUndelivered') = line.state.key_faulted
    /\ Cardinality({b \in pollerBindings' : b.key = k}) =
          line.state.key_binding_count
    /\ (Binding(k, t) \in pollerBindings') =
          line.state.key_bound_to_actor
    /\ readyEpoch'[k] = line.state.ready_epoch
    /\ consumer = epollWaiter'[k.epoll]
    /\ IF consumer = NoThread
       THEN /\ line.state.key_bound_to_consumer = FALSE
            /\ line.state.consumer_ready_epoch = 0
       ELSE /\ (Binding(k, consumer) \in pollerBindings') =
                    line.state.key_bound_to_consumer
            /\ consumerReadyEpoch'[Binding(k, consumer)] =
                    line.state.consumer_ready_epoch

ValidateDelivery(t, line) ==
    \* kernel/core/src/events/epoll/file.rs:210-245
    \* kernel/core/src/events/epoll/entry.rs:103-149,367-397
    /\ delivery'[t].stage = line.state.delivery_stage
    /\ delivery'[t].key =
          IF line.state.delivery_key_present THEN KeyFrom(line) ELSE NoKey
    /\ delivery'[t].hadEvent = line.state.delivery_had_event
    /\ delivery'[t].epoch = line.state.delivery_epoch
    /\ copyoutOk'[t] = line.state.copyout_result

ValidatePoll(t, line) ==
    \* kernel/core/src/process/signal/poll.rs:90-151
    LET o == line.args.ofd IN
    /\ pollLocal'[t].phase = line.state.poll_phase
    /\ pollLocal'[t].ofd = line.state.poll_ofd
    /\ pollLocal'[t].loaded = line.state.poll_loaded
    /\ pollLocal'[t].observed = line.state.poll_observed
    /\ cacheState'[o] = line.state.cache_state
    /\ sourceReady'[o] = line.state.source_ready

OFDSetFrom(items) ==
    \* JSON encodes the exact identity set as a duplicate-free array.
    \* kernel/core/src/syscall/poll.rs:96-101,124-155
    {items[i] : i \in 1..Len(items)}

WaitSlotSnapshotFrom(item) ==
    \* Fixed bounded slots preserve one owner per PollFiles::Owned vector entry.
    \* kernel/core/src/syscall/poll.rs:96-101,124-155
    [fd \in FDs |-> CASE fd = FD0 -> item.fd0
                     [] fd = FD1 -> item.fd1
                     [] OTHER -> item.fd2]

ValidateWait(target, line) ==
    \* kernel/core/src/process/signal/pause.rs:171-219
    \* kernel/core/src/syscall/poll.rs:88-121,188-215
    \* kernel/core/src/process/signal/mod.rs:64-85,208-230
    /\ waitState'[target] = line.state.wait_state
    /\ wakeCause'[target] = line.state.wake_cause
    /\ deadlineExpired'[target] = line.state.deadline_expired
    /\ interruptPending'[target] = line.state.interrupt_pending
    /\ visibleReady'[target] = line.state.visible_ready
    /\ terminalReady'[target] = line.state.terminal_ready
    /\ terminalScanValid'[target] = line.state.terminal_scan_valid
    /\ terminalScanExpected'[target] = line.state.terminal_scan_expected
    /\ currentMask'[target] = line.state.current_mask
    /\ savedMask'[target] = line.state.saved_mask
    /\ preWaitMask'[target] = line.state.pre_wait_mask
    /\ returnReason'[target] = line.state.return_reason
    /\ waitGeneration'[target] = line.state.wait_generation
    /\ completedWaitReason'[target] = line.state.completed_wait_reason
    /\ lastCompletedWaitReason'[target] =
          line.state.last_completed_wait_reason
    /\ Len(line.state.wait_captured_ofds) =
          Cardinality(OFDSetFrom(line.state.wait_captured_ofds))
    /\ Len(line.state.wait_capture_audit) =
          Cardinality(OFDSetFrom(line.state.wait_capture_audit))
    /\ Len(line.state.last_released_wait_ofds) =
          Cardinality(OFDSetFrom(line.state.last_released_wait_ofds))
    /\ waitCapturedOFDs'[target] =
          OFDSetFrom(line.state.wait_captured_ofds)
    /\ waitCaptureAudit'[target] =
          OFDSetFrom(line.state.wait_capture_audit)
    /\ lastReleasedWaitOFDs'[target] =
          OFDSetFrom(line.state.last_released_wait_ofds)
    /\ waitCapturedSlots'[target] =
          WaitSlotSnapshotFrom(line.state.wait_captured_slots)
    /\ waitCaptureSlotAudit'[target] =
          WaitSlotSnapshotFrom(line.state.wait_capture_slot_audit)
    /\ lastReleasedWaitSlots'[target] =
          WaitSlotSnapshotFrom(line.state.last_released_wait_slots)
    \* Exact derived ref counts prove duplicate aliases are counted and every
    \* terminal branch releases precisely this invocation's owners.
    \* kernel/core/src/syscall/poll.rs:96-101,103-121,124-155
    /\ ofdRefs(TimerOFD)' = line.state.timer_refs
    /\ ofdRefs(SignalOFD)' = line.state.signal_refs
    /\ ofdRefs(EventOFD)' = line.state.event_refs
    /\ ofdAlive'[TimerOFD] = line.state.timer_alive
    /\ ofdAlive'[SignalOFD] = line.state.signal_alive
    /\ ofdAlive'[EventOFD] = line.state.event_alive

ValidateExecExternalAudit(line) ==
    \* The audit distinguishes external old-table mutation before versus after
    \* the source-atomic clone/install cutover.
    \* kernel/core/src/process/namespace/unshare.rs:18-28
    /\ execExternalAudit'.beforeDup = line.state.exec_before_dup
    /\ execExternalAudit'.afterDup = line.state.exec_after_dup
    /\ execExternalAudit'.beforeCloexec = line.state.exec_before_cloexec
    /\ execExternalAudit'.afterCloexec = line.state.exec_after_cloexec
    /\ execExternalAudit'.oldTableRetained =
          line.state.exec_old_table_retained

ReadyEpochRecordFrom(item) ==
    [key |-> Key(item.epoll, item.fd, item.ofd), epoch |-> item.epoch]

ReadyEpochRecordsFrom(line) ==
    {ReadyEpochRecordFrom(line.state.ready_epoch_changes[i]) :
        i \in 1..Len(line.state.ready_epoch_changes)}

ChangedReadyEpochRecords ==
    {[key |-> k, epoch |-> readyEpoch'[k]] :
        k \in {q \in InterestKeys : readyEpoch'[q] /= readyEpoch[q]}}

ConsumerEpochRecordFrom(item) ==
    [binding |-> Binding(Key(item.epoll, item.fd, item.ofd), item.thread),
     epoch |-> item.epoch]

ConsumerEpochRecordsFrom(line) ==
    {ConsumerEpochRecordFrom(line.state.consumer_epoch_changes[i]) :
        i \in 1..Len(line.state.consumer_epoch_changes)}

ChangedConsumerEpochRecords ==
    {[binding |-> b, epoch |-> consumerReadyEpoch'[b]] :
        b \in {q \in Bindings :
                  consumerReadyEpoch'[q] /= consumerReadyEpoch[q]}}

ValidateReadinessEpochChanges(line) ==
    \* Exact delta sets detect a missed key or wrong consumer epoch without
    \* requiring a global post-state snapshot under implementation locks.
    \* kernel/core/src/events/epoll/entry.rs:155-166,280-330
    \* kernel/core/src/syscall/signalfd.rs:205-215
    /\ Len(line.state.ready_epoch_changes) =
          Cardinality(ReadyEpochRecordsFrom(line))
    /\ Len(line.state.consumer_epoch_changes) =
          Cardinality(ConsumerEpochRecordsFrom(line))
    /\ ReadyEpochRecordsFrom(line) = ChangedReadyEpochRecords
    /\ ConsumerEpochRecordsFrom(line) = ChangedConsumerEpochRecords

ValidateSignalNotify(actor, line) ==
    \* The continuation is copied immediately after queues.lock is dropped and
    \* retained through the later synchronous notification.
    \* kernel/core/src/process/signal/sig_queues.rs:38-45
    /\ signalNotify'[actor].phase = line.state.signal_notify_phase
    /\ signalNotify'[actor].queue = line.state.signal_notify_queue
    /\ signalNotify'[actor].target = line.state.signal_notify_target
    /\ signalNotify'[actor].epoch = line.state.signal_notify_epoch
    /\ Cardinality(signalNotifyKeys'[actor]) =
          line.state.signal_pending_key_count
    /\ Cardinality(signalNotifyWaiters'[actor]) =
          line.state.signal_pending_waiter_count

PendingKeyFrom(item) == Key(item.epoll, item.fd, item.ofd)

PendingKeysFrom(items) ==
    {PendingKeyFrom(items[i]) : i \in 1..Len(items)}

ValidatePendingKeySets(actor, line) ==
    \* Key-set equality prevents a different in-domain observer obligation
    \* from replacing the callback that just returned or was suppressed.
    \* kernel/core/src/events/subject.rs:126-153
    /\ Len(line.state.eventfd_pending_keys) =
          Cardinality(PendingKeysFrom(line.state.eventfd_pending_keys))
    /\ Len(line.state.signal_pending_keys) =
          Cardinality(PendingKeysFrom(line.state.signal_pending_keys))
    /\ eventNotifyKeys' =
          PendingKeysFrom(line.state.eventfd_pending_keys)
    /\ signalNotifyKeys'[actor] =
          PendingKeysFrom(line.state.signal_pending_keys)

PendingWaitersFrom(items) ==
    {items[i] : i \in 1..Len(items)}

ValidatePendingWaiterSets(actor, line) ==
    \* A wake consumes the selected target's obligation, not an arbitrary
    \* waiter while preserving only the aggregate count.
    \* kernel/core/src/process/signal/poll.rs:167-178,318-321
    /\ Len(line.state.eventfd_pending_waiters) =
          Cardinality(PendingWaitersFrom(
              line.state.eventfd_pending_waiters))
    /\ Len(line.state.signal_pending_waiters) =
          Cardinality(PendingWaitersFrom(
              line.state.signal_pending_waiters))
    /\ eventNotifyWaiters' =
          PendingWaitersFrom(line.state.eventfd_pending_waiters)
    /\ signalNotifyWaiters'[actor] =
          PendingWaitersFrom(line.state.signal_pending_waiters)

NestedEpochRecordFrom(item) ==
    [edge |-> <<item.outer, item.inner>>, epoch |-> item.epoch]

NestedEpochRecordsFrom(line) ==
    {NestedEpochRecordFrom(line.state.nested_epoch_changes[i]) :
        i \in 1..Len(line.state.nested_epoch_changes)}

ChangedNestedRequiredEpochRecords ==
    {[edge |-> edge, epoch |-> nestedRequiredEpoch'[edge]] :
        edge \in {q \in (Epolls \X Epolls) :
                    nestedRequiredEpoch'[q] /= nestedRequiredEpoch[q]}}

ValidateNestedRequiredEpochChanges(line) ==
    \* kernel/core/src/events/epoll/entry.rs:320-330
    \* kernel/core/src/events/subject.rs:126-149
    /\ Len(line.state.nested_epoch_changes) =
          Cardinality(NestedEpochRecordsFrom(line))
    /\ NestedEpochRecordsFrom(line) = ChangedNestedRequiredEpochRecords

ValidatePostState(t, line) ==
    \* Every dispatch literal must resolve to the pinned source index in Base.
    \* kernel/core/src/fs/file/file_table.rs:100-121
    /\ HasProductionSource(line.event)
    /\ CASE line.event = "FileTableInsert" ->
            /\ ValidateFdAt(line.args.fd, line)
            /\ ValidateEmptyFdFlagAudit(line)
            /\ ofdAlive'[line.args.ofd] = line.state.ofd_alive
      [] line.event = "FcntlSetFlCapture" ->
            /\ captured'[t] = line.state.captured_ofd
            /\ capturedFd'[t] = line.args.fd
            /\ capturedStatus'[t] = line.args.status
            /\ captureEpoch'[t] = line.state.capture_epoch
            /\ lastCaptured'[t] = line.state.last_captured
            /\ actedOFD'[t] = line.state.acted_ofd
            /\ actedSlotOFD'[t] = line.state.acted_slot_ofd
            /\ actedCaptureEpoch'[t] = line.state.acted_capture_epoch
            /\ actedSlotEpoch'[t] = line.state.acted_slot_epoch
      [] line.event = "FcntlSetFlUse" ->
            /\ actedOFD'[t] = line.state.acted_ofd
            /\ actedSlotOFD'[t] = line.state.acted_slot_ofd
            /\ actedCaptureEpoch'[t] = line.state.acted_capture_epoch
            /\ actedSlotEpoch'[t] = line.state.acted_slot_epoch
            /\ ofdStatus'[line.state.acted_ofd] = line.state.ofd_status
            /\ ofdAlive'[line.state.acted_ofd] = line.state.ofd_alive
            /\ captured'[t] = NoOFD
            /\ capturedFd'[t] = NoFD
            /\ capturedStatus'[t] = FALSE
      [] line.event = "SysCloseRemove" ->
            /\ ValidateFdAt(line.args.fd, line)
            /\ ValidateEmptyFdFlagAudit(line)
            /\ closePending'[t] = line.state.close_pending
      [] line.event = "ClosedFileDrop" ->
            /\ closePending'[t] = line.state.close_pending
            /\ ofdAlive'[line.args.ofd] = line.state.ofd_alive
      [] line.event = "SysDup2Equal" ->
            /\ actedOFD'[t] = line.state.acted_ofd
            /\ lastCaptured'[t] = line.state.last_captured
      [] line.event = "SysDup3Validate" ->
            /\ replacement'[t].phase = line.state.replacement_phase
            /\ replacement'[t].sourceFd = line.args.source_fd
            /\ replacement'[t].targetFd = line.args.target_fd
            /\ replacement'[t].sourceOFD = line.state.replacement_source_ofd
            /\ replacement'[t].replacedOFD =
                  line.state.replacement_replaced_ofd
            /\ replacement'[t].newCloexec = line.args.cloexec
            /\ replacement'[t].removedCount =
                  line.state.replacement_removed_count
      [] line.event = "FileTableDupExact" ->
            /\ ValidateFdAt(line.args.target_fd, line)
            /\ ValidateEmptyFdFlagAudit(line)
            /\ replacement'[t].phase = line.state.replacement_phase
            /\ replacement'[t].sourceFd = line.state.replacement_source_fd
            /\ replacement'[t].targetFd = line.args.target_fd
            /\ replacement'[t].sourceOFD = line.state.replacement_source_ofd
            /\ replacement'[t].replacedOFD = line.state.replacement_replaced_ofd
            /\ replacement'[t].newCloexec =
                  line.state.replacement_new_cloexec
            /\ replacement'[t].removedCount = line.state.replacement_removed_count
            /\ closePending'[t] = line.state.close_pending
      [] line.event = "FileTableDupExactBadFd" ->
            replacement'[t].phase = line.state.replacement_phase
      [] line.event = "DupReplacementCleanup" ->
            /\ replacement'[t].phase = line.state.replacement_phase
            /\ closePending'[t] = line.state.close_pending
            /\ ofdAlive'[line.args.ofd] = line.state.ofd_alive
      [] line.event = "FileTableDupCeil" ->
            /\ ValidateFdAt(line.args.target_fd, line)
            /\ ValidateEmptyFdFlagAudit(line)
            /\ ValidateExecExternalAudit(line)
      [] line.event = "FcntlSetFd" ->
            /\ slotFlags'[line.args.fd] = line.state.slot_cloexec
            /\ fdFlagAudit'.active = line.state.fd_flag_audit_active
            /\ fdFlagAudit'.target = line.state.fd_flag_target
            /\ fdFlagAudit'.peer = line.state.fd_flag_peer
            /\ fdFlagAudit'.ofd = line.state.fd_flag_ofd
            /\ fdFlagAudit'.requested = line.state.fd_flag_requested
            /\ fdFlagAudit'.peerBefore = line.state.fd_flag_peer_before
            /\ fdFlagAudit'.targetEpoch = line.state.fd_flag_target_epoch
            /\ fdFlagAudit'.peerEpoch = line.state.fd_flag_peer_epoch
      [] line.event = "SysCloseRangeCloexec" ->
            /\ slotFlags'[FD0] = line.state.fd0_cloexec
            /\ slotFlags'[FD1] = line.state.fd1_cloexec
            /\ slotFlags'[FD2] = line.state.fd2_cloexec
            /\ ValidateEmptyFdFlagAudit(line)
            /\ ValidateExecExternalAudit(line)
      [] line.event = "ExecveWaitOtherThreadsExit" ->
            /\ execPhase' = line.state.exec_phase
            /\ execOwner' = t
            /\ ValidateExecExternalAudit(line)
      [] line.event = "ContextUnshareFiles" ->
            /\ execPhase' = line.state.exec_phase
            /\ sharedTable' = line.state.shared_table
            /\ execSnapshotSlots'[FD0] = line.state.snapshot_fd0_ofd
            /\ execSnapshotSlots'[FD1] = line.state.snapshot_fd1_ofd
            /\ execSnapshotSlots'[FD2] = line.state.snapshot_fd2_ofd
            /\ execSnapshotFlags'[FD0] = line.state.snapshot_fd0_cloexec
            /\ execSnapshotFlags'[FD1] = line.state.snapshot_fd1_cloexec
            /\ execSnapshotFlags'[FD2] = line.state.snapshot_fd2_cloexec
            /\ execPrivateSlots'[FD0] = line.state.private_fd0_ofd
            /\ execPrivateSlots'[FD1] = line.state.private_fd1_ofd
            /\ execPrivateSlots'[FD2] = line.state.private_fd2_ofd
            /\ execPrivateFlags'[FD0] = line.state.private_fd0_cloexec
            /\ execPrivateFlags'[FD1] = line.state.private_fd1_cloexec
            /\ execPrivateFlags'[FD2] = line.state.private_fd2_cloexec
            /\ execPrivateEpoch'[FD0] = line.state.private_fd0_epoch
            /\ execPrivateEpoch'[FD1] = line.state.private_fd1_epoch
            /\ execPrivateEpoch'[FD2] = line.state.private_fd2_epoch
            /\ execPrivateSlotMapAudit'[FD0] = line.state.private_fd0_audit
            /\ execPrivateSlotMapAudit'[FD1] = line.state.private_fd1_audit
            /\ execPrivateSlotMapAudit'[FD2] = line.state.private_fd2_audit
            /\ ValidateExecExternalAudit(line)
      [] line.event = "FileTableCloseFilesOnExec" ->
            /\ execPhase' = line.state.exec_phase
            /\ execPrivateSlots'[FD0] = line.state.private_fd0_ofd
            /\ execPrivateSlots'[FD1] = line.state.private_fd1_ofd
            /\ execPrivateSlots'[FD2] = line.state.private_fd2_ofd
            /\ execPrivateFlags'[FD0] = line.state.private_fd0_cloexec
            /\ execPrivateFlags'[FD1] = line.state.private_fd1_cloexec
            /\ execPrivateFlags'[FD2] = line.state.private_fd2_cloexec
            /\ execPrivateEpoch'[FD0] = line.state.private_fd0_epoch
            /\ execPrivateEpoch'[FD1] = line.state.private_fd1_epoch
            /\ execPrivateEpoch'[FD2] = line.state.private_fd2_epoch
            /\ execPrivateSlotMapAudit'[FD0] = line.state.private_fd0_audit
            /\ execPrivateSlotMapAudit'[FD1] = line.state.private_fd1_audit
            /\ execPrivateSlotMapAudit'[FD2] = line.state.private_fd2_audit
            /\ ValidateEmptyFdFlagAudit(line)
            /\ ValidateExecExternalAudit(line)
            /\ ofdAlive'[TimerOFD] = line.state.timer_alive
            /\ ofdAlive'[SignalOFD] = line.state.signal_alive
            /\ ofdAlive'[EventOFD] = line.state.event_alive
      [] line.event = "EpollControlCaptureTarget" -> ValidateCtl(t, line)
      [] line.event \in {"EpollAddInterest", "EpollModInterest"} ->
            /\ ValidateCtl(t, line)
            /\ ValidateKeyState(KeyFrom(line), line)
      [] line.event = "EpollDelInterest" ->
            /\ ValidateCtl(t, line)
            /\ ValidateKeyState(KeyFrom(line), line)
            /\ (Binding(KeyFrom(line), line.args.bound_thread)
                   \in pollerBindings') = line.state.key_bound
            /\ ofdAlive'[line.args.ofd] = line.state.ofd_alive
      [] line.event = "EpollControlError" ->
            /\ ValidateEmptyCtl(t, line)
            /\ Cardinality(interest') = line.state.interest_count
            /\ ofdAlive'[line.args.ofd] = line.state.ofd_alive
      [] line.event = "EntryUpdatePoll" ->
            /\ ValidateCtl(t, line)
            /\ ValidateEntryUpdate(t, line)
      [] line.event = "EpollControlPushReady" ->
            /\ ValidateEmptyCtl(t, line)
            /\ (KeyFrom(line) \in readyQ') = line.state.key_in_ready
            /\ queuedEpoch'[KeyFrom(line)] = line.state.queued_epoch
            /\ epollWake'[line.args.epoll] = line.state.epoll_wake
            /\ epollReadyEpoch'[line.args.epoll] =
                  line.state.epoll_ready_epoch
            /\ ofdAlive'[line.args.ofd] = line.state.ofd_alive
      [] line.event = "ReadySetPush" ->
            /\ (KeyFrom(line) \in readyQ') = line.state.key_in_ready
            /\ (KeyFrom(line) \in notified') = line.state.key_notified
            /\ queuedEpoch'[KeyFrom(line)] = line.state.queued_epoch
            /\ callbackEpoch'[KeyFrom(line)] = line.state.callback_epoch
            /\ callbackActor'[KeyFrom(line)] = line.state.callback_actor
            /\ callbackStage'[t] = line.state.callback_stage
            /\ epollWake'[line.args.epoll] = line.state.epoll_wake
            /\ epollReadyEpoch'[line.args.epoll] =
                  line.state.epoll_ready_epoch
            /\ Cardinality(eventNotifyKeys') =
                 line.state.eventfd_pending_key_count
            /\ Cardinality(signalNotifyKeys'[t]) =
                 line.state.signal_pending_key_count
      [] line.event = "ReadySetPushSuppressed" ->
            /\ callbackEpoch'[KeyFrom(line)] = line.state.callback_epoch
            /\ callbackActor'[KeyFrom(line)] = line.state.callback_actor
            /\ (KeyFrom(line) \in readyQ') = line.state.key_in_ready
            /\ ValidatePendingKeySets(t, line)
      [] line.event = "ReadySetPopDeleted" ->
            /\ (KeyFrom(line) \in readyQ') = line.state.key_in_ready
            /\ Cardinality(readyQ') = line.state.ready_count
            /\ epollWake'[line.args.epoll] = line.state.epoll_wake
      [] line.event = "ReadySetPop" ->
            /\ ValidateDelivery(t, line)
            /\ delivery'[t].key = KeyFrom(line)
            /\ (KeyFrom(line) \in readyQ') = line.state.key_in_ready
            /\ epollWake'[line.args.epoll] = line.state.epoll_wake
      [] line.event = "EntryPollDeadFile" ->
            /\ ValidateDelivery(t, line)
            /\ ValidateKeyState(KeyFrom(line), line)
            /\ ofdAlive'[line.args.ofd] = line.state.ofd_alive
      [] line.event = "EntryPollDisabled" -> ValidateDelivery(t, line)
      [] line.event = "EntryPollPrepare" ->
            /\ ValidateDelivery(t, line)
            /\ delivery'[t].key = KeyFrom(line)
            /\ entryEnabled'[KeyFrom(line)] = line.state.key_enabled
            /\ (KeyFrom(line) \in readyQ') = line.state.key_in_ready
            /\ queuedEpoch'[KeyFrom(line)] = line.state.queued_epoch
            /\ epollWake'[line.args.epoll] = line.state.epoll_wake
      [] line.event = "EpollDiscardEmptyPreparation" ->
            ValidateDelivery(t, line)
      [] line.event = "DoEpollPwait2CopyoutSuccess" ->
            /\ ValidateDelivery(t, line)
            /\ (KeyFrom(line) \in deliveredKeys') = line.state.key_delivered
            /\ (KeyFrom(line) \in faultedUndelivered') =
                  line.state.key_faulted
            /\ lastDeliveredKey'[t] = KeyFrom(line)
            /\ reportedOFD'[t] = line.state.reported_ofd
            /\ deliveredEpoch'[KeyFrom(line)] = line.state.delivered_epoch
      [] line.event = "DoEpollPwait2CopyoutFault" ->
            /\ ValidateDelivery(t, line)
            /\ (KeyFrom(line) \in faultedUndelivered') = line.state.key_faulted
            /\ entryEnabled'[KeyFrom(line)] = line.state.key_enabled
            /\ (KeyFrom(line) \in readyQ') = line.state.key_in_ready
      [] line.event = "PolleePollWithRegister" ->
            /\ ValidatePoll(t, line)
            /\ (PollRegistration(t, line.args.ofd) \in directRegistered') =
                 line.state.direct_registered
      [] line.event = "PolleePollWithLoad" -> ValidatePoll(t, line)
      [] line.event \in {"PolleePollWithCached", "PolleePollWithCache",
                          "PolleePollWithConcurrentCheck"} ->
            /\ ValidatePoll(t, line)
            /\ (PollRegistration(t, line.args.ofd) \in observedReady') =
                 line.state.observed_ready
            /\ observedEpoch'[PollRegistration(t, line.args.ofd)] =
                 line.state.observed_epoch
      [] line.event \in {"PolleePollWithBeginCheck",
                          "PolleePollWithCheck"} -> ValidatePoll(t, line)
      [] line.event = "PolleePollWithFinish" ->
            /\ pollLocal'[t].phase = line.state.poll_phase
            /\ pollLocal'[t].ofd = line.state.poll_ofd
            /\ pollLocal'[t].loaded = line.state.poll_loaded
            /\ pollLocal'[t].observed = line.state.poll_observed
            /\ ofdAlive'[line.args.ofd] = line.state.ofd_alive
      [] line.event = "TimerfdExpired" ->
            /\ timerTicks' = line.state.timer_ticks
            /\ sourceReady'[TimerOFD] = line.state.source_ready
            /\ sourceEpoch'[TimerOFD] = line.state.source_epoch
            /\ producerPhase'[t] = line.state.producer_phase
            /\ ValidateReadinessEpochChanges(line)
      [] line.event = "TimerfdNotify" ->
            /\ cacheState'[TimerOFD] = line.state.cache_state
            /\ producerPhase'[t] = line.state.producer_phase
            /\ ValidateCallbackSelection(line)
            /\ ValidateWakeSelection(line)
      [] line.event = "TimerfdTryRead" ->
            /\ timerTicks' = line.state.timer_ticks
            /\ sourceReady'[TimerOFD] = line.state.source_ready
            /\ cacheState'[TimerOFD] = line.state.cache_state
      [] line.event = "TimerfdSetTimeDisarm" ->
            /\ timerTicks' = line.state.timer_ticks
            /\ sourceReady'[TimerOFD] = line.state.source_ready
            /\ cacheState'[TimerOFD] = line.state.cache_state
      [] line.event = "EventfdAddCounter" ->
            /\ eventCounter' = line.state.event_counter
            /\ sourceReady'[EventOFD] = line.state.source_ready
            /\ sourceEpoch'[EventOFD] = line.state.source_epoch
            /\ producerPhase'[t] = line.state.producer_phase
            /\ EventfdMutexOwnerFrom(producerPhase') = line.state.eventfd_owner
            /\ eventNotifyCounter' = line.state.eventfd_counter_snapshot
            /\ ValidateReadinessEpochChanges(line)
      [] line.event = "EventfdTryRead" ->
            /\ eventCounter' = line.state.event_counter
            /\ sourceReady'[EventOFD] = line.state.source_ready
            /\ producerPhase'[t] = line.state.producer_phase
            /\ EventfdMutexOwnerFrom(producerPhase') = line.state.eventfd_owner
            /\ eventNotifyCounter' = line.state.eventfd_counter_snapshot
      [] line.event = "EventfdNotify" ->
            /\ cacheState'[EventOFD] = line.state.cache_state
            /\ producerPhase'[t] = line.state.producer_phase
            /\ EventfdMutexOwnerFrom(producerPhase') = line.state.eventfd_owner
            /\ ValidateCallbackSelection(line)
            /\ ValidateWakeSelection(line)
            /\ eventNotifyKeys' =
                 {record.key : record \in CallbackRecordsFrom(line)}
            /\ eventNotifyWaiters' =
                 {record.target : record \in WakeRecordsFrom(line)}
            /\ eventNotifyCounter' = line.state.eventfd_counter_snapshot
      [] line.event = "EventfdNotifyReturn" ->
            /\ producerPhase'[t] = line.state.producer_phase
            /\ EventfdMutexOwnerFrom(producerPhase') = line.state.eventfd_owner
            /\ Cardinality(eventNotifyKeys') =
                 line.state.eventfd_pending_key_count
            /\ Cardinality(eventNotifyWaiters') =
                 line.state.eventfd_pending_waiter_count
            /\ eventNotifyCounter' = line.state.eventfd_counter_snapshot
      [] line.event = "SignalfdUpdateMask" ->
            /\ signalMask'[SignalOFD] = line.state.signal_mask
            /\ sourceEpoch'[SignalOFD] = line.state.source_epoch
            /\ ValidateReadinessEpochChanges(line)
      [] line.event = "SigQueuesEnqueueThread" ->
            /\ threadPending'[line.args.target] = line.state.thread_pending
            /\ sourceEpoch'[SignalOFD] = line.state.source_epoch
            /\ ValidateSignalNotify(t, line)
            /\ threadSignalEnqueueEpoch'[line.args.target] =
                  line.state.thread_enqueue_epoch
            /\ ValidateReadinessEpochChanges(line)
      [] line.event = "SigQueuesEnqueueProcess" ->
            /\ processPending' = line.state.process_pending
            /\ sourceEpoch'[SignalOFD] = line.state.source_epoch
            /\ ValidateSignalNotify(t, line)
            /\ processSignalEnqueueEpoch' =
                  line.state.process_enqueue_epoch
            /\ ValidateReadinessEpochChanges(line)
      [] line.event = "SigQueuesNotifyThread" ->
            /\ cacheState'[SignalOFD] = line.state.cache_state
            /\ ValidateSignalNotify(t, line)
            /\ threadSignalNotifyEpoch'[line.args.target] =
                  line.state.thread_notify_epoch
            /\ ValidateCallbackSelection(line)
            /\ ValidateWakeSelection(line)
            /\ signalNotifyKeys'[t] =
                  {record.key : record \in CallbackRecordsFrom(line)}
            /\ signalNotifyWaiters'[t] =
                  {record.target : record \in WakeRecordsFrom(line)}
      [] line.event = "SigQueuesNotifyProcess" ->
            /\ cacheState'[SignalOFD] = line.state.cache_state
            /\ ValidateSignalNotify(t, line)
            /\ processSignalNotifyEpoch' =
                  line.state.process_notify_epoch
            /\ ValidateCallbackSelection(line)
            /\ ValidateWakeSelection(line)
            /\ signalNotifyKeys'[t] =
                  {record.key : record \in CallbackRecordsFrom(line)}
            /\ signalNotifyWaiters'[t] =
                  {record.target : record \in WakeRecordsFrom(line)}
      [] line.event = "SigQueuesNotifyReturn" ->
            /\ ValidateSignalNotify(t, line)
            /\ signalNotify'[t] = EmptySignalNotify
      [] line.event = "SignalFileReadThread" ->
            threadPending'[t] = line.state.thread_pending
      [] line.event = "SignalFileReadProcess" ->
            processPending' = line.state.process_pending
      [] line.event = "EpollWaitRegisterConsumer" ->
            /\ epollWaiter'[line.args.epoll] = line.state.epoll_waiter
            /\ ValidateScenario4Records(t, line.args.epoll, line)
      [] line.event \in {"SaveAndSetSigMask", "PollFilesRegisterPoller",
                          "PollFilesInitialReady", "WaiterPauseTimeoutBlock",
                          "WaiterPauseTimeoutReturnTimeout",
                          "WaiterPauseTimeoutReturnSignal", "DoPollCountEvents",
                          "HandlePendingSignalRestoreMask"} ->
            /\ ValidateWait(t, line)
            /\ IF line.event = "PollFilesRegisterPoller"
               THEN /\ lastReadyWake'[t].ofd = line.state.last_ready_ofd
                    /\ lastReadyWake'[t].actor = line.state.last_ready_actor
                    /\ lastReadyWake'[t].epoch = line.state.last_ready_epoch
               ELSE TRUE
      [] line.event = "WaiterReadinessWake" ->
            /\ ValidateWait(line.args.target, line)
            /\ lastReadyWake'[line.args.target].ofd =
                 line.state.producer_ofd
            /\ lastReadyWake'[line.args.target].actor =
                 line.state.producer_actor
            /\ lastReadyWake'[line.args.target].epoch =
                 line.state.producer_epoch
            /\ waitReadyToken'[line.args.target].ofd =
                 line.state.wait_token_ofd
            /\ waitReadyToken'[line.args.target].actor =
                 line.state.wait_token_actor
            /\ waitReadyToken'[line.args.target].epoch =
                 line.state.wait_token_epoch
            /\ ValidatePendingWaiterSets(t, line)
      [] line.event \in {"WaiterTimeoutExpires", "WaiterSignalInterrupts"} ->
            ValidateWait(line.args.target, line)
      [] line.event = "EpollAddNestedInterest" ->
            /\ (<<line.args.outer, line.args.inner>> \in epollGraph') =
                 line.state.edge_present
            /\ Cardinality(epollGraph') = line.state.graph_size
      [] line.event = "ReadySetPushAcquire" ->
            /\ lockOwner'[ReadyLock(line.args.epoll)] = line.state.lock_owner
            /\ (ReadyLock(line.args.epoll) \in heldLocks'[t]) =
                 line.state.lock_held
            /\ callbackStage'[t] = line.state.callback_stage
            /\ callbackKey'[t] = KeyFrom(line)
      [] line.event = "ReadySetPushNotifySubject" ->
            /\ lockOwner'[SubjectLock(line.args.epoll)] = line.state.lock_owner
            /\ (SubjectLock(line.args.epoll) \in heldLocks'[t]) =
                 line.state.lock_held
            /\ callbackStage'[t] = line.state.callback_stage
            /\ ValidateNestedRequiredEpochChanges(line)
      [] line.event = "SyncSubjectCallbackReadySet" ->
            /\ lockOwner'[ReadyLock(line.args.outer)] = line.state.lock_owner
            /\ (ReadyLock(line.args.outer) \in heldLocks'[t]) =
                 line.state.lock_held
            /\ callbackStage'[t] = line.state.callback_stage
            /\ nestedDeliveredEpoch'[<<line.args.outer, line.args.inner>>] =
                 line.state.nested_delivered_epoch
            /\ epollReadyEpoch'[line.args.outer] =
                  line.state.epoll_ready_epoch
      [] line.event = "ObserverCallbackRelease" ->
            /\ Cardinality(heldLocks'[t]) = line.state.held_count
            /\ Cardinality({l \in LockNames : lockOwner'[l] = t}) =
                 line.state.owned_lock_count
            /\ ValidatePendingKeySets(t, line)
            /\ callbackStage'[t] = line.state.callback_stage
            /\ callbackKey'[t] = NoKey
      [] OTHER -> FALSE

(***************************************************************************)
(* Direct base-action dispatch. Each branch is one cited semantic boundary *)
(* in base.tla and instrumentation-spec.md.                                *)
(***************************************************************************)

MatchEvent(t, line) ==
    \* The same action/source row consumed above gates direct dispatch.
    \* kernel/core/src/fs/file/file_table.rs:100-121
    /\ HasProductionSource(line.event)
    /\ CASE line.event = "FileTableInsert" ->
            FileTableInsert(t, line.args.fd, line.args.ofd, line.args.cloexec)
      [] line.event = "FcntlSetFlCapture" ->
            FcntlSetFlCapture(t, line.args.fd, line.args.status)
      [] line.event = "FcntlSetFlUse" -> FcntlSetFlUse(t)
      [] line.event = "SysCloseRemove" -> SysCloseRemove(t, line.args.fd)
      [] line.event = "ClosedFileDrop" -> ClosedFileDrop(t)
      [] line.event = "SysDup2Equal" -> SysDup2Equal(t, line.args.fd)
      [] line.event = "SysDup3Validate" ->
            SysDup3Validate(t, line.args.source_fd, line.args.target_fd,
                            line.args.cloexec)
      [] line.event = "FileTableDupExact" -> FileTableDupExact(t)
      [] line.event = "FileTableDupExactBadFd" -> FileTableDupExactBadFd(t)
      [] line.event = "DupReplacementCleanup" -> DupReplacementCleanup(t)
      [] line.event = "FileTableDupCeil" ->
            FileTableDupCeil(t, line.args.source_fd, line.args.target_fd,
                             line.args.cloexec)
      [] line.event = "FcntlSetFd" ->
            FcntlSetFd(t, line.args.fd, line.args.cloexec)
      [] line.event = "SysCloseRangeCloexec" ->
            SysCloseRangeCloexec(t, line.args.first_fd, line.args.last_fd)
      [] line.event = "ExecveWaitOtherThreadsExit" ->
            ExecveWaitOtherThreadsExit(t)
      [] line.event = "ContextUnshareFiles" -> ContextUnshareFiles(t)
      [] line.event = "FileTableCloseFilesOnExec" ->
            FileTableCloseFilesOnExec(t)
      [] line.event = "EpollControlCaptureTarget" ->
            EpollControlCaptureTarget(t, line.args.epoll, line.args.fd,
                                      line.args.command, line.args.trigger)
      [] line.event = "EpollAddInterest" -> EpollAddInterest(t)
      [] line.event = "EpollModInterest" -> EpollModInterest(t)
      [] line.event = "EpollDelInterest" -> EpollDelInterest(t)
      [] line.event = "EpollControlError" -> EpollControlError(t)
      [] line.event = "EntryUpdatePoll" -> EntryUpdatePoll(t)
      [] line.event = "EpollControlPushReady" -> EpollControlPushReady(t)
      [] line.event = "ReadySetPush" -> ReadySetPush(t, KeyFrom(line))
      [] line.event = "ReadySetPushSuppressed" ->
            ReadySetPushSuppressed(t, KeyFrom(line))
      [] line.event = "ReadySetPopDeleted" ->
            ReadySetPopDeleted(t, KeyFrom(line))
      [] line.event = "ReadySetPop" -> ReadySetPop(t, KeyFrom(line))
      [] line.event = "EntryPollDeadFile" -> EntryPollDeadFile(t)
      [] line.event = "EntryPollDisabled" -> EntryPollDisabled(t)
      [] line.event = "EntryPollPrepare" -> EntryPollPrepare(t)
      [] line.event = "EpollDiscardEmptyPreparation" ->
            EpollDiscardEmptyPreparation(t)
      [] line.event = "DoEpollPwait2CopyoutSuccess" ->
            DoEpollPwait2CopyoutSuccess(t)
      [] line.event = "DoEpollPwait2CopyoutFault" ->
            DoEpollPwait2CopyoutFault(t)
      [] line.event = "PolleePollWithRegister" ->
            PolleePollWithRegister(t, line.args.ofd)
      [] line.event = "PolleePollWithLoad" -> PolleePollWithLoad(t)
      [] line.event = "PolleePollWithCached" -> PolleePollWithCached(t)
      [] line.event = "PolleePollWithBeginCheck" ->
            PolleePollWithBeginCheck(t)
      [] line.event = "PolleePollWithCheck" -> PolleePollWithCheck(t)
      [] line.event = "PolleePollWithCache" -> PolleePollWithCache(t)
      [] line.event = "PolleePollWithConcurrentCheck" ->
            PolleePollWithConcurrentCheck(t)
      [] line.event = "PolleePollWithFinish" -> PolleePollWithFinish(t)
      [] line.event = "TimerfdExpired" -> TimerfdExpired(t)
      [] line.event = "TimerfdNotify" -> TimerfdNotify(t)
      [] line.event = "TimerfdTryRead" -> TimerfdTryRead(t)
      [] line.event = "TimerfdSetTimeDisarm" -> TimerfdSetTimeDisarm(t)
      [] line.event = "EventfdAddCounter" -> EventfdAddCounter(t)
      [] line.event = "EventfdTryRead" -> EventfdTryRead(t)
      [] line.event = "EventfdNotify" -> EventfdNotify(t)
      [] line.event = "EventfdNotifyReturn" -> EventfdNotifyReturn(t)
      [] line.event = "SignalfdUpdateMask" ->
            SignalfdUpdateMask(t, line.args.enabled)
      [] line.event = "SigQueuesEnqueueThread" ->
            SigQueuesEnqueueThread(t, line.args.target)
      [] line.event = "SigQueuesEnqueueProcess" -> SigQueuesEnqueueProcess(t)
      [] line.event = "SigQueuesNotifyThread" -> SigQueuesNotifyThread(t)
      [] line.event = "SigQueuesNotifyProcess" -> SigQueuesNotifyProcess(t)
      [] line.event = "SigQueuesNotifyReturn" -> SigQueuesNotifyReturn(t)
      [] line.event = "SignalFileReadThread" -> SignalFileReadThread(t)
      [] line.event = "SignalFileReadProcess" -> SignalFileReadProcess(t)
      [] line.event = "EpollWaitRegisterConsumer" ->
            EpollWaitRegisterConsumer(t, line.args.epoll)
      [] line.event = "SaveAndSetSigMask" ->
            SaveAndSetSigMask(t, line.args.mask)
      [] line.event = "PollFilesRegisterPoller" -> PollFilesRegisterPoller(t)
      [] line.event = "PollFilesInitialReady" -> PollFilesInitialReady(t)
      [] line.event = "WaiterPauseTimeoutBlock" -> WaiterPauseTimeoutBlock(t)
      [] line.event = "WaiterReadinessWake" ->
            WaiterReadinessWake(t, line.args.target)
      [] line.event = "WaiterTimeoutExpires" ->
            WaiterTimeoutExpires(t, line.args.target)
      [] line.event = "WaiterSignalInterrupts" ->
            WaiterSignalInterrupts(t, line.args.target)
      [] line.event = "WaiterPauseTimeoutReturnTimeout" ->
            WaiterPauseTimeoutReturnTimeout(t)
      [] line.event = "WaiterPauseTimeoutReturnSignal" ->
            WaiterPauseTimeoutReturnSignal(t)
      [] line.event = "DoPollCountEvents" -> DoPollCountEvents(t)
      [] line.event = "HandlePendingSignalRestoreMask" ->
            HandlePendingSignalRestoreMask(t)
      [] line.event = "EpollAddNestedInterest" ->
            EpollAddNestedInterest(t, line.args.outer, line.args.inner)
      [] line.event = "ReadySetPushAcquire" ->
            ReadySetPushAcquire(t, KeyFrom(line))
      [] line.event = "ReadySetPushNotifySubject" ->
            ReadySetPushNotifySubject(t, line.args.epoll)
      [] line.event = "SyncSubjectCallbackReadySet" ->
            SyncSubjectCallbackReadySet(t, line.args.inner, line.args.outer)
      [] line.event = "ObserverCallbackRelease" -> ObserverCallbackRelease(t)
      [] OTHER -> FALSE

TraceInit ==
    /\ Init
    /\ DOMAIN traces = Threads
    /\ pc = [t \in Threads |-> 1]

TraceConsume ==
    /\ ThreadsWithEvents /= {}
    /\ \E t \in ViablePIDs :
         LET line == traces[t][pc[t]] IN
         /\ line.tag = "trace"
         /\ line.tid = t
         /\ line.start \in Nat \ {0}
         /\ line.end \in Nat \ {0}
         /\ line.start <= line.end
         /\ MatchEvent(t, line)
         /\ ValidatePostState(t, line)
         /\ pc' = [pc EXCEPT ![t] = @ + 1]

TraceNext ==
    \/ TraceConsume
    \/ /\ ThreadsWithEvents = {}
       /\ UNCHANGED traceAllVars

TraceSpec ==
    /\ TraceInit
    /\ [][TraceNext]_traceAllVars
    /\ WF_traceAllVars(TraceConsume)

SynchronousCallbacksQuiescent ==
    \* A trace is complete only after every observer selected by a synchronous
    \* notification has returned and the eventfd counter guard has dropped.
    \* kernel/core/src/syscall/eventfd.rs:124-159
    \* kernel/core/src/events/subject.rs:126-153
    /\ \A k \in InterestKeys :
          callbackEpoch[k] = 0 /\ callbackActor[k] = NoThread
    /\ \A t \in Threads :
          /\ callbackStage[t] = "idle"
          /\ callbackKey[t] = NoKey
          /\ heldLocks[t] = {}
          /\ waitReadyToken[t].epoch = 0
    /\ \A l \in LockNames : lockOwner[l] = NoThread
    /\ EventfdMutexOwner = NoThread
    /\ eventNotifyKeys = {}
    /\ eventNotifyWaiters = {}
    /\ eventNotifyCounter = 0

OperationsQuiescent ==
    \* Full JSON consumption is terminal only when no split syscall, captured
    \* reference, delivery, poll, mask-restore, signal-notify, or callback
    \* continuation remains in flight.
    \* kernel/core/src/fs/file/file_table.rs:326-367
    \* kernel/core/src/events/epoll/file.rs:65-84,96-178
    \* kernel/core/src/syscall/poll.rs:88-121
    \* kernel/core/src/process/signal/sig_queues.rs:38-45
    \* kernel/core/src/process/signal/mod.rs:64-85,208-230
    /\ execPhase \in {"idle", "closed"}
    /\ \A t \in Threads :
          /\ captured[t] = NoOFD
          /\ capturedFd[t] = NoFD
          /\ capturedStatus[t] = FALSE
          /\ closePending[t] = NoOFD
          /\ replacement[t].phase \in {"idle", "done"}
          /\ ctl[t] = EmptyCtl
          /\ delivery[t] = EmptyDelivery
          /\ pollLocal[t] = EmptyPollLocal
          /\ producerPhase[t] = "idle"
          /\ signalNotify[t] = EmptySignalNotify
          /\ signalNotifyKeys[t] = {}
          /\ signalNotifyWaiters[t] = {}
          /\ waitState[t] \in {"idle", "returned"}
          /\ savedMask[t] = "none"
          /\ currentMask[t] = preWaitMask[t]
          /\ waitReadyToken[t] = EmptyWaitReadyToken
          /\ waitCapturedOFDs[t] = {}
          /\ waitCaptureAudit[t] = {}
          /\ waitCapturedSlots[t] = EmptyWaitSlotSnapshot
          /\ waitCaptureSlotAudit[t] = EmptyWaitSlotSnapshot

TraceMatched ==
    \* A fully consumed trace is accepted only after every split production
    \* boundary above has reached its matching return/release boundary.
    \* kernel/core/src/fs/file/file_table.rs:326-367
    \* kernel/core/src/events/epoll/file.rs:65-84,96-178
    \* kernel/core/src/process/signal/sig_queues.rs:38-45
    \* kernel/core/src/process/signal/mod.rs:64-85,208-230
    <>(ThreadsWithEvents = {}
       /\ SynchronousCallbacksQuiescent
       /\ OperationsQuiescent)
TraceFullyConsumed == TraceMatched

====
