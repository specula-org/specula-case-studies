---- MODULE MC_Controls ----
(***************************************************************************)
(* Controller-only mutations used to prove that the lifetime, identity,   *)
(* slot, mask, topology, terminal-scan, signal-order, eventfd-scope,       *)
(* FD-flag, and ordered-branch oracles reject their named                  *)
(* defects. They are absent from base.Next and Trace.MatchEvent.           *)
(***************************************************************************)

EXTENDS MC

MCInjectPhantomLive(o) ==
    \* CONTROL target: kernel/core/src/fs/file/file_table.rs:190-205,326-405
    /\ ~ofdAlive[o]
    /\ ofdRefs(o) = 0
    /\ ofdAlive' = [ofdAlive EXCEPT ![o] = TRUE]
    /\ UNCHANGED <<slots, slotFlags, slotEpoch, ofdStatus, captured,
                    capturedFd, capturedStatus, captureEpoch, lastCaptured,
                    actedOFD, actedSlotOFD, actedCaptureEpoch, actedSlotEpoch,
                    closePending, replacement, sharedTable, execPhase,
                    execOwner, execPrivateSlots, execPrivateFlags,
                    execPrivateEpoch, execPrivateSlotMapAudit,
                    execSnapshotSlots, execSnapshotFlags, execExternalAudit,
                    fdFlagAudit, slotMapAudit, epollVars, readinessVars, signalVars,
                    waitVars, topologyVars, faultCount, seenActions>>

MCInjectResurrection(fd, o) ==
    \* CONTROL target: kernel/core/src/fs/file/file_table.rs:190-205,326-405
    /\ ~ofdAlive[o]
    /\ ofdRefs(o) = 0
    /\ slots[fd] = NoOFD
    /\ slots' = [slots EXCEPT ![fd] = o]
    /\ slotFlags' = [slotFlags EXCEPT ![fd] = FALSE]
    /\ slotEpoch' = [slotEpoch EXCEPT ![fd] = @ + 1]
    /\ slotMapAudit' = [slotMapAudit EXCEPT ![fd] = o]
    /\ ofdAlive' = [ofdAlive EXCEPT ![o] = TRUE]
    /\ fdFlagAudit' = EmptyFdFlagAudit
    /\ UNCHANGED <<ofdStatus, captured, capturedFd, capturedStatus,
                    captureEpoch, lastCaptured, actedOFD, actedSlotOFD,
                    actedCaptureEpoch, actedSlotEpoch, closePending,
                    replacement, sharedTable, execPhase, execOwner,
                    execPrivateSlots, execPrivateFlags, execPrivateEpoch,
                    execPrivateSlotMapAudit, execSnapshotSlots,
                    execSnapshotFlags, execExternalAudit, epollVars,
                    readinessVars, signalVars, waitVars, topologyVars,
                    faultCount, seenActions>>

MCInjectSharedFdFlags(fd) ==
    \* CONTROL target: kernel/core/src/fs/file/file_table.rs:207-234,274-302
    /\ slots[fd] /= NoOFD
    /\ ~slotFlags[fd]
    /\ {p \in AliasPeers(fd) : ~slotFlags[p]} /= {}
    /\ LET peer == CHOOSE p \in AliasPeers(fd) : ~slotFlags[p]
       IN
       /\ slotFlags' = [p \in FDs |->
             IF p = fd \/ p = peer THEN TRUE ELSE slotFlags[p]]
       /\ fdFlagAudit' =
             [active |-> TRUE,
              target |-> fd,
              peer |-> peer,
              ofd |-> slots[fd],
              requested |-> TRUE,
              peerBefore |-> slotFlags[peer],
              targetEpoch |-> slotEpoch[fd],
              peerEpoch |-> slotEpoch[peer]]
    /\ UNCHANGED <<slots, slotEpoch, ofdStatus, ofdAlive, captured,
                    capturedFd, capturedStatus, captureEpoch, lastCaptured,
                    actedOFD, actedSlotOFD, actedCaptureEpoch, actedSlotEpoch,
                    closePending, replacement, sharedTable, execPhase,
                    execOwner, execPrivateSlots, execPrivateFlags,
                    execPrivateEpoch, execPrivateSlotMapAudit,
                    execSnapshotSlots, execSnapshotFlags, execExternalAudit,
                    slotMapAudit, epollVars, readinessVars, signalVars, waitVars,
                    topologyVars, faultCount, seenActions>>

MCInjectEventfdEarlyOwnerRelease(t) ==
    \* Intentional mutation: return from EventFile's counter guard while a
    \* callback selected by Pollee::notify is still outstanding.
    \* kernel/core/src/syscall/eventfd.rs:124-159
    /\ producerPhase[t] = "event_callbacks"
    /\ (eventNotifyKeys /= {} \/ eventNotifyWaiters /= {})
    /\ producerPhase' = [producerPhase EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<fdVars, epollVars, sourceReady, sourceEpoch, readyEpoch,
                    callbackEpoch, callbackActor, queuedEpoch, deliveredEpoch,
                    consumerReadyEpoch, cacheState, directRegistered, notified,
                    observedReady, observedEpoch, timerTicks, eventCounter,
                    pollLocal, eventNotifyKeys, eventNotifyWaiters,
                    eventNotifyCounter, signalVars, waitVars, topologyVars,
                    faultCount, seenActions>>

MCInjectEventfdSecondMutation(t) ==
    \* Intentional mutation: alter the protected counter before synchronous
    \* notify callbacks return.
    \* kernel/core/src/syscall/eventfd.rs:124-159
    /\ producerPhase[t] = "event_callbacks"
    /\ (eventNotifyKeys /= {} \/ eventNotifyWaiters /= {})
    /\ eventCounter < MaxEventCounter
    /\ eventCounter' = eventCounter + 1
    /\ UNCHANGED <<fdVars, epollVars, sourceReady, sourceEpoch, readyEpoch,
                    callbackEpoch, callbackActor, queuedEpoch, deliveredEpoch,
                    consumerReadyEpoch, cacheState, directRegistered, notified,
                    observedReady, observedEpoch, timerTicks, pollLocal,
                    producerPhase, eventNotifyKeys, eventNotifyWaiters,
                    eventNotifyCounter, signalVars, waitVars, topologyVars,
                    faultCount, seenActions>>

MCInjectWrongInterestOFD(k, wrongOFD) ==
    \* Intentional mutation: publish a different in-domain OFD in the
    \* interest key while retaining the ADD-captured identity audit.
    \* kernel/core/src/events/epoll/file.rs:65-84,96-120
    /\ k \in interest
    /\ wrongOFD /= k.ofd
    /\ LET wrongKey == Key(k.epoll, k.fd, wrongOFD) IN
       /\ wrongKey \notin interest
       /\ interest' = (interest \ {k}) \cup {wrongKey}
    /\ UNCHANGED <<fdVars, readyQ, entryEnabled, triggerMode, registered,
                    keySlotEpoch, interestIdentity, ctl, delivery, copyoutOk,
                    deliveredKeys, faultedUndelivered, lastDeliveredKey,
                    reportedOFD, epollWaiter, epollWake, readinessVars,
                    signalVars, waitVars, topologyVars, faultCount,
                    seenActions>>

MCInjectStaleKeyGeneration(k) ==
    \* Intentional mutation: replace the ADD-captured slot generation with an
    \* older generation after the descriptor has already been reused.
    \* kernel/core/src/fs/file/file_table.rs:190-205
    \* kernel/core/src/events/epoll/file.rs:65-84,96-120
    /\ k \in interest
    /\ interestIdentity[k].active
    /\ interestIdentity[k].slotEpoch > 0
    /\ keySlotEpoch' = [keySlotEpoch EXCEPT
          ![k] = interestIdentity[k].slotEpoch - 1]
    /\ UNCHANGED <<fdVars, interest, readyQ, entryEnabled, triggerMode,
                    registered, interestIdentity, ctl, delivery, copyoutOk,
                    deliveredKeys, faultedUndelivered, lastDeliveredKey,
                    reportedOFD, epollWaiter, epollWake, readinessVars,
                    signalVars, waitVars, topologyVars, faultCount,
                    seenActions>>

MCInjectDeadDisabledPopped(t, k) ==
    \* Controller-only setup exposes the Entry::poll branch-order seam after
    \* production has reached a dead interest.
    \* kernel/core/src/events/epoll/entry.rs:103-124
    /\ k \in interest
    /\ ~ofdAlive[k.ofd]
    /\ delivery[t].stage = "idle"
    /\ entryEnabled' = [entryEnabled EXCEPT ![k] = FALSE]
    /\ delivery' = [delivery EXCEPT ![t] =
          [stage |-> "popped", key |-> k, hadEvent |-> FALSE,
           epoch |-> queuedEpoch[k]]]
    /\ UNCHANGED <<fdVars, interest, readyQ, triggerMode, registered,
                    keySlotEpoch, interestIdentity, ctl, copyoutOk,
                    deliveredKeys, faultedUndelivered, lastDeliveredKey,
                    reportedOFD, epollWaiter, epollWake, readinessVars,
                    signalVars, waitVars, topologyVars, faultCount,
                    seenActions>>

MCInjectSlotMapDivergence(fd, wrongOFD) ==
    \* Intentional in-domain redirection. The independent production shadow
    \* remains unchanged, so SlotMapsOneOFD detects the mutation before any
    \* type invariant can.
    \* kernel/core/src/fs/file/file_table.rs:139-205
    /\ slots[fd] /= wrongOFD
    /\ ofdAlive[wrongOFD]
    /\ slots' = [slots EXCEPT ![fd] = wrongOFD]
    /\ UNCHANGED <<slotFlags, slotEpoch, ofdStatus, ofdAlive, captured,
                    capturedFd, capturedStatus, captureEpoch, lastCaptured,
                    actedOFD, actedSlotOFD, actedCaptureEpoch, actedSlotEpoch,
                    closePending, replacement, sharedTable, execPhase,
                    execOwner, execPrivateSlots, execPrivateFlags,
                    execPrivateEpoch, execPrivateSlotMapAudit,
                    execSnapshotSlots, execSnapshotFlags, execExternalAudit,
                    fdFlagAudit, slotMapAudit, epollVars, readinessVars,
                    signalVars, waitVars, topologyVars, faultCount,
                    seenActions>>

MCInjectMaskRestoreFailure(t) ==
    \* Intentional post-return corruption keeps all values in-domain while
    \* violating only the saved-mask restoration oracle.
    \* kernel/core/src/process/signal/mod.rs:64-85,208-230
    /\ waitState[t] = "returned"
    /\ currentMask' = [currentMask EXCEPT ![t] =
          IF preWaitMask[t] = "blocked" THEN "unblocked" ELSE "blocked"]
    /\ UNCHANGED <<fdVars, epollVars, readinessVars, signalVars, waitState,
                    wakeCause, deadlineExpired, interruptPending, visibleReady,
                    terminalReady, terminalScanValid, terminalScanExpected,
                    savedMask, preWaitMask, returnReason, waitReadyToken,
                    lastReadyWake, waitCapturedOFDs, waitCaptureAudit,
                    waitCapturedSlots, waitCaptureSlotAudit,
                    lastReleasedWaitOFDs, lastReleasedWaitSlots,
                    waitGeneration, completedWaitReason,
                    lastCompletedWaitReason, topologyVars, faultCount,
                    seenActions>>

MCInjectEpollCycle(outer, inner) ==
    \* Intentional controller-only back edge. The pinned checkout has no
    \* production cycle-rejection branch; this mutation tests only the oracle.
    \* kernel/core/src/events/epoll/file.rs:64-125
    /\ outer /= inner
    /\ <<outer, inner>> \in epollGraph
    /\ <<inner, outer>> \notin epollGraph
    /\ epollGraph' = epollGraph \cup {<<inner, outer>>}
    /\ UNCHANGED <<fdVars, epollVars, readinessVars, signalVars, waitVars,
                    heldLocks, lockOwner, callbackStage, callbackKey,
                    epollReadyEpoch, nestedRequiredEpoch,
                    nestedDeliveredEpoch, faultCount, seenActions>>

MCInjectTerminalScanFromVisible(t) ==
    \* Intentional mutation substitutes historical Waker state for the live
    \* terminal snapshot while retaining the independent expected value.
    \* kernel/core/src/syscall/poll.rs:108-121,188-215
    /\ terminalScanValid[t]
    /\ visibleReady[t] /= terminalScanExpected[t]
    /\ terminalReady' = [terminalReady EXCEPT ![t] = visibleReady[t]]
    /\ UNCHANGED <<fdVars, epollVars, readinessVars, signalVars, waitState,
                    wakeCause, deadlineExpired, interruptPending, visibleReady,
                    terminalScanValid, terminalScanExpected, currentMask,
                    savedMask, preWaitMask, returnReason, waitReadyToken,
                    lastReadyWake, waitCapturedOFDs, waitCaptureAudit,
                    waitCapturedSlots, waitCaptureSlotAudit,
                    lastReleasedWaitOFDs, lastReleasedWaitSlots,
                    waitGeneration, completedWaitReason,
                    lastCompletedWaitReason, topologyVars, faultCount,
                    seenActions>>

MCInjectSignalNotifyWithoutEnqueue(target) ==
    \* Intentional controller-only ordering violation advances the notification
    \* audit beyond every successful enqueue epoch.
    \* kernel/core/src/process/signal/sig_queues.rs:38-45
    /\ threadSignalNotifyEpoch' = [threadSignalNotifyEpoch EXCEPT
          ![target] = threadSignalEnqueueEpoch[target] + 1]
    /\ UNCHANGED <<fdVars, epollVars, readinessVars, signalMask,
                    threadPending, processPending, pollerBindings,
                    signalNotify, signalNotifyKeys, signalNotifyWaiters,
                    threadSignalEnqueueEpoch, processSignalEnqueueEpoch,
                    processSignalNotifyEpoch, waitVars, topologyVars,
                    faultCount, seenActions>>

MCInjectPollSnapshotOmission(t, fd) ==
    \* CONTROL: omit one Arc cloned into CowFiles::Owned while retaining the
    \* independent expected capture set. No value leaves its declared domain.
    \* kernel/core/src/syscall/poll.rs:96-101,124-155
    /\ waitState[t] \in {"registered", "blocked", "woken"}
    /\ waitCapturedSlots[t][fd] /= NoOFD
    /\ LET mutated == [waitCapturedSlots[t] EXCEPT ![fd] = NoOFD]
       IN /\ waitCapturedSlots' =
                [waitCapturedSlots EXCEPT ![t] = mutated]
          /\ waitCapturedOFDs' = [waitCapturedOFDs EXCEPT ![t] =
                {mutated[d] : d \in {x \in FDs : mutated[x] /= NoOFD}}]
    /\ UNCHANGED <<fdVars, epollVars, readinessVars, signalVars, waitState,
                    wakeCause, deadlineExpired, interruptPending,
                    visibleReady, terminalReady, terminalScanValid,
                    terminalScanExpected, currentMask, savedMask, preWaitMask,
                    returnReason, waitReadyToken, lastReadyWake,
                    waitCaptureAudit, waitCaptureSlotAudit,
                    lastReleasedWaitOFDs, lastReleasedWaitSlots,
                    waitGeneration, completedWaitReason,
                    lastCompletedWaitReason, topologyVars, faultCount,
                    seenActions>>

MCInjectPollSnapshotEarlyRelease(t) ==
    \* CONTROL: drop every wait-held owner before a terminal poll path leaves
    \* scope. The expected capture set remains active for the named oracle.
    \* kernel/core/src/syscall/poll.rs:96-121,124-155
    /\ waitState[t] \in {"registered", "blocked", "woken"}
    /\ waitCapturedOFDs[t] /= {}
    /\ waitCaptureAudit[t] = waitCapturedOFDs[t]
    /\ waitCapturedOFDs' = [waitCapturedOFDs EXCEPT ![t] = {}]
    /\ waitCapturedSlots' =
          [waitCapturedSlots EXCEPT ![t] = EmptyWaitSlotSnapshot]
    /\ UNCHANGED <<fdVars, epollVars, readinessVars, signalVars, waitState,
                    wakeCause, deadlineExpired, interruptPending,
                    visibleReady, terminalReady, terminalScanValid,
                    terminalScanExpected, currentMask, savedMask, preWaitMask,
                    returnReason, waitReadyToken, lastReadyWake,
                    waitCaptureAudit, waitCaptureSlotAudit,
                    lastReleasedWaitOFDs, lastReleasedWaitSlots,
                    waitGeneration, completedWaitReason,
                    lastCompletedWaitReason, topologyVars, faultCount,
                    seenActions>>

MCInjectStaleSecondWait(t) ==
    \* CONTROL: reintroduce a prior timeout flag after the corrected second
    \* registration has established all fresh fields.
    \* kernel/core/src/syscall/poll.rs:88-106,165-185
    \* kernel/core/src/process/signal/poll.rs:282-315
    /\ waitState[t] = "registered"
    /\ waitGeneration[t] > 1
    /\ FreshWaitFields(t)
    /\ deadlineExpired' = [deadlineExpired EXCEPT ![t] = TRUE]
    /\ UNCHANGED <<fdVars, epollVars, readinessVars, signalVars, waitState,
                    wakeCause, interruptPending, visibleReady, terminalReady,
                    terminalScanValid, terminalScanExpected, currentMask,
                    savedMask, preWaitMask, returnReason, waitReadyToken,
                    lastReadyWake, waitCapturedOFDs, waitCaptureAudit,
                    waitCapturedSlots, waitCaptureSlotAudit,
                    lastReleasedWaitOFDs, lastReleasedWaitSlots,
                    waitGeneration, completedWaitReason,
                    lastCompletedWaitReason, topologyVars, faultCount,
                    seenActions>>

MCInjectExecPrivateAlias(fd) ==
    \* CONTROL: copy one post-cutover old-table slot into the installed
    \* private table. The private shadow changes with it, so SlotMapsOneOFD
    \* remains true and ExecCutoverIsolation is the named detector.
    \* kernel/core/src/process/namespace/unshare.rs:18-28
    /\ execPhase = "snapshotted"
    /\ slots[fd] /= execPrivateSlots[fd]
    /\ execPrivateSlots' =
          [execPrivateSlots EXCEPT ![fd] = slots[fd]]
    /\ execPrivateSlotMapAudit' =
          [execPrivateSlotMapAudit EXCEPT ![fd] = slots[fd]]
    /\ UNCHANGED <<slots, slotFlags, slotEpoch, ofdStatus, ofdAlive,
                    captured, capturedFd, capturedStatus, captureEpoch,
                    lastCaptured, actedOFD, actedSlotOFD, actedCaptureEpoch,
                    actedSlotEpoch, closePending, replacement, sharedTable,
                    execPhase, execOwner, execPrivateFlags, execPrivateEpoch,
                    execSnapshotSlots, execSnapshotFlags, execExternalAudit,
                    fdFlagAudit, slotMapAudit, epollVars, readinessVars,
                    signalVars, waitVars, topologyVars, faultCount,
                    seenActions>>

MCInjectExecWrongTableCloexec(fd) ==
    \* CONTROL: apply an old-table post-cutover CLOEXEC mutation to the
    \* private entry as well. All slot/flag values remain type-correct.
    \* kernel/core/src/process/namespace/unshare.rs:18-28
    \* kernel/core/src/syscall/close.rs:76-101
    /\ execPhase = "snapshotted"
    /\ slotFlags[fd] /= execPrivateFlags[fd]
    /\ execPrivateFlags' = [execPrivateFlags EXCEPT ![fd] = slotFlags[fd]]
    /\ UNCHANGED <<slots, slotFlags, slotEpoch, ofdStatus, ofdAlive,
                    captured, capturedFd, capturedStatus, captureEpoch,
                    lastCaptured, actedOFD, actedSlotOFD, actedCaptureEpoch,
                    actedSlotEpoch, closePending, replacement, sharedTable,
                    execPhase, execOwner, execPrivateSlots, execPrivateEpoch,
                    execPrivateSlotMapAudit, execSnapshotSlots,
                    execSnapshotFlags, execExternalAudit, fdFlagAudit,
                    slotMapAudit, epollVars, readinessVars, signalVars,
                    waitVars, topologyVars, faultCount, seenActions>>

MCPhantomSpec ==
    \* CONTROL target: kernel/core/src/fs/file/file_table.rs:190-205,326-405
    MCInit /\ [][MCNext \/ \E o \in OFDs : MCInjectPhantomLive(o)]_mcAllVars

MCResurrectionSpec ==
    \* CONTROL target: kernel/core/src/fs/file/file_table.rs:190-205,326-405
    MCInit /\ [][MCNext \/ \E fd \in FDs, o \in OFDs :
                         MCInjectResurrection(fd, o)]_mcAllVars

MCFdFlagMutationSpec ==
    \* CONTROL target: kernel/core/src/fs/file/file_table.rs:207-234,274-302
    MCInit /\ [][MCNext \/ \E fd \in FDs : MCInjectSharedFdFlags(fd)]_mcAllVars

MCEventfdEarlyReleaseSpec ==
    \* CONTROL target: kernel/core/src/syscall/eventfd.rs:124-159
    MCInit /\ [][MCNext \/ \E t \in Threads :
                         MCInjectEventfdEarlyOwnerRelease(t)]_mcAllVars

MCEventfdSecondMutationSpec ==
    \* CONTROL target: kernel/core/src/syscall/eventfd.rs:124-159
    MCInit /\ [][MCNext \/ \E t \in Threads :
                         MCInjectEventfdSecondMutation(t)]_mcAllVars

MCWrongInterestOFDSpec ==
    \* CONTROL target: kernel/core/src/events/epoll/file.rs:65-84,96-120
    MCInit /\ [][MCNext \/ \E k \in InterestKeys, o \in OFDs :
                         MCInjectWrongInterestOFD(k, o)]_mcAllVars

MCStaleKeyGenerationSpec ==
    \* CONTROL target: kernel/core/src/fs/file/file_table.rs:190-205
    MCInit /\ [][MCNext \/ \E k \in InterestKeys :
                         MCInjectStaleKeyGeneration(k)]_mcAllVars

MCDeadBeforeDisabledSpec ==
    \* CONTROL target: kernel/core/src/events/epoll/entry.rs:103-124
    MCInit /\ [][MCNext \/ \E t \in Threads, k \in InterestKeys :
                         MCInjectDeadDisabledPopped(t, k)]_mcAllVars

MCSlotMapMutationSpec ==
    \* CONTROL target: kernel/core/src/fs/file/file_table.rs:139-205
    MCInit /\ [][MCNext \/ \E fd \in FDs, o \in OFDs :
                         MCInjectSlotMapDivergence(fd, o)]_mcAllVars

MCMaskRestoreMutationSpec ==
    \* CONTROL target: kernel/core/src/process/signal/mod.rs:64-85,208-230
    MCInit /\ [][MCNext \/ \E t \in Threads :
                         MCInjectMaskRestoreFailure(t)]_mcAllVars

MCEpollCycleMutationSpec ==
    \* CONTROL target: kernel/core/src/events/epoll/file.rs:64-125
    MCInit /\ [][MCNext \/ \E outer, inner \in Epolls :
                         MCInjectEpollCycle(outer, inner)]_mcAllVars

MCTerminalScanMutationSpec ==
    \* CONTROL target: kernel/core/src/syscall/poll.rs:108-121,188-215
    MCInit /\ [][MCNext \/ \E t \in Threads :
                         MCInjectTerminalScanFromVisible(t)]_mcAllVars

MCSignalNotifyOrderingMutationSpec ==
    \* CONTROL target: kernel/core/src/process/signal/sig_queues.rs:38-45
    MCInit /\ [][MCNext \/ \E target \in Threads :
                         MCInjectSignalNotifyWithoutEnqueue(target)]_mcAllVars

MCPollSnapshotOmissionSpec ==
    \* CONTROL target: kernel/core/src/syscall/poll.rs:96-101,124-155
    MCInit /\ [][MCNext \/ \E t \in Threads, fd \in FDs :
                         MCInjectPollSnapshotOmission(t, fd)]_mcAllVars

MCPollSnapshotEarlyReleaseSpec ==
    \* CONTROL target: kernel/core/src/syscall/poll.rs:96-121,124-155
    MCInit /\ [][MCNext \/ \E t \in Threads :
                         MCInjectPollSnapshotEarlyRelease(t)]_mcAllVars

MCStaleSecondWaitSpec ==
    \* CONTROL target: kernel/core/src/syscall/poll.rs:88-106,165-185
    MCInit /\ [][MCNext \/ \E t \in Threads :
                         MCInjectStaleSecondWait(t)]_mcAllVars

MCExecPrivateAliasSpec ==
    \* CONTROL target: kernel/core/src/process/namespace/unshare.rs:18-28
    MCInit /\ [][MCNext \/ \E fd \in FDs :
                         MCInjectExecPrivateAlias(fd)]_mcAllVars

MCExecWrongTableCloexecSpec ==
    \* CONTROL target: kernel/core/src/process/namespace/unshare.rs:18-28
    MCInit /\ [][MCNext \/ \E fd \in FDs :
                         MCInjectExecWrongTableCloexec(fd)]_mcAllVars

====
