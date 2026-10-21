---- MODULE base ----
(***************************************************************************)
(* Asterinas file-descriptor, epoll, readiness, and wait lifecycle model.  *)
(*                                                                         *)
(* Category B: concurrent kernel runtime.                                  *)
(* Snapshot: 4ba4abbe8cb3f2892129d67b0301cf247bbdda0f.                    *)
(*                                                                         *)
(* Scenario 1: reusable FD slots versus stable OFD references and exec.    *)
(* Scenario 2: epoll key lifetime and prepare/copyout delivery split.      *)
(* Scenario 3: semi-stateless readiness-cache invalidation.                *)
(* Scenario 4: thread-relative signalfd readiness.                         *)
(* Scenario 5: timeout/signal/readiness arbitration and mask restoration.  *)
(* Scenario 6: bounded, acyclic nested epoll and callback lock order.      *)
(***************************************************************************)

EXTENDS Integers, Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Threads,
    FDs,
    OFDs,
    Epolls,
    FD0,
    FD1,
    FD2,
    TimerOFD,
    SignalOFD,
    EventOFD,
    NoThread,
    NoFD,
    NoOFD,
    NoEpoll,
    NoKey,
    MaxTimerTicks,
    MaxEventCounter

ASSUME /\ Threads /= {}
       /\ Cardinality(Threads) = 2
       /\ FDs = {FD0, FD1, FD2}
       /\ Cardinality(FDs) = 3
       /\ OFDs = {TimerOFD, SignalOFD, EventOFD}
       /\ Cardinality(OFDs) = 3
       /\ Cardinality(Epolls) = 2
       /\ NoThread \notin Threads
       /\ NoFD \notin FDs
       /\ NoOFD \notin OFDs
       /\ NoEpoll \notin Epolls
       /\ MaxTimerTicks \in Nat \ {0}
       /\ MaxEventCounter \in Nat \ {0}

\* kernel/core/src/events/epoll/entry.rs:76-100,118-149
TriggerModes == {"LT", "ET", "ONESHOT"}
\* A negative task pointer is the checker identity stored by swap. The two
\* modeled POSIX threads stand for the two possible Task pointers.
\* kernel/core/src/process/signal/poll.rs:37-58,106-148
CacheStates == {"invalid", "ready", "not_ready"} \union Threads
MaskStates == {"blocked", "unblocked"}
WaitStates == {"idle", "mask_set", "registered", "blocked", "woken",
                "syscall_done", "returned"}
ReturnReasons == {"none", "ready", "timeout", "signal", "closed"}
WakeCauses == {"none", "ready", "timer", "signal"}

\* EntryKey contains the epoll-owned numeric FD plus weak file identity.
\* kernel/core/src/events/epoll/entry.rs:46-67
InterestKeys == [epoll : Epolls, fd : FDs, ofd : OFDs]
\* Signalfd readiness may bind one Entry key to a current POSIX thread.
\* kernel/core/src/syscall/signalfd.rs:171-179,205-215
Bindings == [key : InterestKeys, thread : Threads]
\* PollHandle registration is per polling task and Pollee.
\* kernel/core/src/process/signal/poll.rs:90-107,154-165
PollRegistrations == [thread : Threads, ofd : OFDs]
\* ReadySet and SyncSubject guards are the nested callback lock classes.
\* kernel/core/src/events/epoll/entry.rs:307-330
\* kernel/core/src/events/subject.rs:126-149
LockNames == ({<<"ready", e>> : e \in Epolls}
              \union {<<"subject", e>> : e \in Epolls})

\* kernel/core/src/events/epoll/entry.rs:46-67
Key(ep, fd, ofd) == [epoll |-> ep, fd |-> fd, ofd |-> ofd]
\* kernel/core/src/syscall/signalfd.rs:171-179,205-215
Binding(k, t) == [key |-> k, thread |-> t]
\* kernel/core/src/process/signal/poll.rs:90-107,154-165
PollRegistration(t, o) == [thread |-> t, ofd |-> o]
\* kernel/core/src/events/epoll/entry.rs:307-330
ReadyLock(e) == <<"ready", e>>
\* kernel/core/src/events/subject.rs:126-149
SubjectLock(e) == <<"subject", e>>

EmptyReplacement ==
    \* kernel/core/src/fs/file/file_table.rs:169-187
    \* kernel/core/src/syscall/dup.rs:50-78
    [phase |-> "idle",
     sourceFd |-> NoFD,
     targetFd |-> NoFD,
     sourceOFD |-> NoOFD,
     replacedOFD |-> NoOFD,
     newCloexec |-> FALSE,
     removedCount |-> 0]

EmptyCtl ==
    \* kernel/core/src/events/epoll/file.rs:65-84,96-176
    [phase |-> "idle",
     command |-> "none",
     epoll |-> NoEpoll,
     fd |-> NoFD,
     target |-> NoOFD,
     slotEpoch |-> 0,
     trigger |-> "LT",
     observed |-> FALSE]

EmptyDelivery ==
    \* kernel/core/src/events/epoll/entry.rs:103-149,367-397
    [stage |-> "idle", key |-> NoKey, hadEvent |-> FALSE, epoch |-> 0]
EmptyPollLocal ==
    \* kernel/core/src/process/signal/poll.rs:90-152
    [phase |-> "idle", ofd |-> NoOFD, loaded |-> "unset",
     observed |-> FALSE]

EmptyInterestIdentity ==
    \* The audit copy is written from epoll_ctl's captured Arc and slot
    \* generation when ADD publishes the already-updated Entry.
    \* kernel/core/src/events/epoll/file.rs:65-84,96-120
    [active |-> FALSE, fd |-> NoFD, ofd |-> NoOFD, slotEpoch |-> 0]

EmptyWaitReadyToken ==
    \* Waker::on_events runs synchronously from the notifying Pollee and
    \* retains both callback actor and producer epoch.
    \* kernel/core/src/process/signal/poll.rs:167-178,318-321
    [ofd |-> NoOFD, actor |-> NoThread, epoch |-> 0]

EmptyFdFlagAudit ==
    [active |-> FALSE,
     target |-> NoFD,
     peer |-> NoFD,
     ofd |-> NoOFD,
     requested |-> FALSE,
     peerBefore |-> FALSE,
     targetEpoch |-> 0,
     peerEpoch |-> 0]

EmptySignalNotify ==
    \* A successful SigQueues enqueue drops queues.lock before entering the
    \* synchronous Pollee notification. This record is the exact continuation
    \* retained by that executing actor across the unlocked seam.
    \* kernel/core/src/process/signal/sig_queues.rs:38-45
    [phase |-> "idle", queue |-> "none", target |-> NoThread, epoch |-> 0]

EmptyExecExternalAudit ==
    \* This history-only audit records which side of the atomic unshare
    \* boundary an external CLONE_FILES sharer completed a table mutation.
    \* kernel/core/src/process/namespace/unshare.rs:18-28
    \* kernel/core/src/process/clone.rs:738-745
    [beforeDup |-> FALSE,
     afterDup |-> FALSE,
     beforeCloexec |-> FALSE,
     afterCloexec |-> FALSE,
     oldTableRetained |-> FALSE]

EmptyWaitSlotSnapshot ==
    \* CowFiles::Owned preserves one cloned Option<Arc<dyn FileLike>> for each
    \* input descriptor, including two owners when duplicated slots alias.
    \* kernel/core/src/syscall/poll.rs:96-101,124-155
    [fd \in FDs |-> NoOFD]

ReplacementStates ==
    [phase : {"idle", "validated", "cleanup", "done"},
     sourceFd : FDs \cup {NoFD},
     targetFd : FDs \cup {NoFD},
     sourceOFD : OFDs \cup {NoOFD},
     replacedOFD : OFDs \cup {NoOFD},
     newCloexec : BOOLEAN,
     removedCount : {0, 1}]

CtlStates ==
    [phase : {"idle", "apply", "poll", "insert", "push"},
     command : {"none", "add", "del", "mod"},
     epoll : Epolls \cup {NoEpoll},
     fd : FDs \cup {NoFD},
     target : OFDs \cup {NoOFD},
     slotEpoch : Nat,
     trigger : TriggerModes,
     observed : BOOLEAN]

DeliveryStates ==
    [stage : {"idle", "popped", "prepared"},
     key : InterestKeys \cup {NoKey},
     hadEvent : BOOLEAN,
     epoch : Nat]

PollLocalStates ==
    [phase : {"idle", "load", "loaded", "check", "cache", "done"},
     ofd : OFDs \cup {NoOFD},
     loaded : CacheStates \cup {"unset"},
     observed : BOOLEAN]

InterestIdentityStates ==
    [active : BOOLEAN,
     fd : FDs \cup {NoFD},
     ofd : OFDs \cup {NoOFD},
     slotEpoch : Nat]

WaitReadyTokenStates ==
    [ofd : OFDs \cup {NoOFD},
     actor : Threads \cup {NoThread},
     epoch : Nat]

FdFlagAuditStates ==
    [active : BOOLEAN,
     target : FDs \cup {NoFD},
     peer : FDs \cup {NoFD},
     ofd : OFDs \cup {NoOFD},
     requested : BOOLEAN,
     peerBefore : BOOLEAN,
     targetEpoch : Nat,
     peerEpoch : Nat]

SignalNotifyStates ==
    \* kernel/core/src/process/signal/sig_queues.rs:38-45
    [phase : {"idle", "pending", "callbacks"},
     queue : {"none", "thread", "process"},
     target : Threads \cup {NoThread},
     epoch : Nat]

ExecExternalAuditStates ==
    \* kernel/core/src/process/namespace/unshare.rs:18-28
    [beforeDup : BOOLEAN,
     afterDup : BOOLEAN,
     beforeCloexec : BOOLEAN,
     afterCloexec : BOOLEAN,
     oldTableRetained : BOOLEAN]

(***************************************************************************)
(* Machine-checkable production action/source index.                      *)
(*                                                                         *)
(* MC wrappers and both Trace dispatches consume this exact mapping. The   *)
(* durable audit compares its domain with instrumentation-spec.md and      *)
(* resolves every pinned path/range against the checked-out source.        *)
(***************************************************************************)

ProductionActionNames ==
    {"FileTableInsert", "FcntlSetFlCapture", "FcntlSetFlUse",
     "SysCloseRemove", "ClosedFileDrop", "SysDup2Equal",
     "SysDup3Validate", "FileTableDupExact", "FileTableDupExactBadFd",
     "DupReplacementCleanup", "FileTableDupCeil", "FcntlSetFd",
     "SysCloseRangeCloexec", "ExecveWaitOtherThreadsExit",
     "ContextUnshareFiles", "FileTableCloseFilesOnExec",
     "EpollControlCaptureTarget", "EpollAddInterest", "EpollModInterest",
     "EpollDelInterest", "EpollControlError", "EntryUpdatePoll",
     "EpollControlPushReady", "ReadySetPushAcquire", "ReadySetPush",
     "ReadySetPushSuppressed", "ReadySetPushNotifySubject",
     "SyncSubjectCallbackReadySet", "ObserverCallbackRelease",
     "ReadySetPopDeleted", "ReadySetPop", "EntryPollDeadFile",
     "EntryPollDisabled", "EntryPollPrepare",
     "EpollDiscardEmptyPreparation", "DoEpollPwait2CopyoutSuccess",
     "DoEpollPwait2CopyoutFault", "PolleePollWithRegister",
     "PolleePollWithLoad", "PolleePollWithCached",
     "PolleePollWithBeginCheck", "PolleePollWithCheck",
     "PolleePollWithCache", "PolleePollWithConcurrentCheck",
     "PolleePollWithFinish", "TimerfdExpired", "TimerfdNotify",
     "TimerfdTryRead", "TimerfdSetTimeDisarm", "EventfdAddCounter",
     "EventfdTryRead", "EventfdNotify", "EventfdNotifyReturn",
     "SignalfdUpdateMask", "SigQueuesEnqueueThread",
     "SigQueuesEnqueueProcess", "SigQueuesNotifyThread",
     "SigQueuesNotifyProcess", "SigQueuesNotifyReturn",
     "SignalFileReadThread", "SignalFileReadProcess",
     "EpollWaitRegisterConsumer", "SaveAndSetSigMask",
     "PollFilesRegisterPoller", "WaiterTimeoutExpires",
     "WaiterSignalInterrupts", "EpollAddNestedInterest",
     "WaiterReadinessWake", "PollFilesInitialReady",
     "WaiterPauseTimeoutBlock", "WaiterPauseTimeoutReturnTimeout",
     "WaiterPauseTimeoutReturnSignal", "DoPollCountEvents",
     "HandlePendingSignalRestoreMask"}

ProductionActionSource(name) ==
    \* Each branch is the pinned implementation block refined by the action.
    \* The mapping is intentionally data, not a prose-only traceability claim.
    CASE name = "FileTableInsert" -> "kernel/core/src/fs/file/file_table.rs:190-194"
      [] name = "FcntlSetFlCapture" -> "kernel/core/src/syscall/fcntl.rs:87-91"
      [] name = "FcntlSetFlUse" -> "kernel/core/src/syscall/fcntl.rs:91-94"
      [] name = "SysCloseRemove" -> "kernel/core/src/syscall/close.rs:25-31"
      [] name = "ClosedFileDrop" -> "kernel/core/src/syscall/close.rs:33-40"
      [] name = "SysDup2Equal" -> "kernel/core/src/syscall/dup.rs:21-30"
      [] name = "SysDup3Validate" -> "kernel/core/src/syscall/dup.rs:50-73"
      [] name = "FileTableDupExact" -> "kernel/core/src/fs/file/file_table.rs:169-187"
      [] name = "FileTableDupExactBadFd" -> "kernel/core/src/fs/file/file_table.rs:181-187"
      [] name = "DupReplacementCleanup" -> "kernel/core/src/syscall/dup.rs:73-78"
      [] name = "FileTableDupCeil" -> "kernel/core/src/fs/file/file_table.rs:139-165"
      [] name = "FcntlSetFd" -> "kernel/core/src/syscall/fcntl.rs:61-73"
      [] name = "SysCloseRangeCloexec" -> "kernel/core/src/syscall/close.rs:76-101"
      [] name = "ExecveWaitOtherThreadsExit" -> "kernel/core/src/process/execve.rs:161-164,202-225"
      [] name = "ContextUnshareFiles" -> "kernel/core/src/process/namespace/unshare.rs:18-28"
      [] name = "FileTableCloseFilesOnExec" -> "kernel/core/src/process/execve.rs:378-386"
      [] name = "EpollControlCaptureTarget" -> "kernel/core/src/events/epoll/file.rs:65-84"
      [] name = "EpollAddInterest" -> "kernel/core/src/events/epoll/file.rs:96-125"
      [] name = "EpollModInterest" -> "kernel/core/src/events/epoll/file.rs:147-176"
      [] name = "EpollDelInterest" -> "kernel/core/src/events/epoll/file.rs:65-84,130-144,340-343"
      [] name = "EpollControlError" -> "kernel/core/src/events/epoll/file.rs:65-84,100-105,140-142,160-163"
      [] name = "EntryUpdatePoll" -> "kernel/core/src/events/epoll/file.rs:96-120,147-176"
      [] name = "EpollControlPushReady" -> "kernel/core/src/events/epoll/file.rs:65-84,110-125,166-176"
      [] name = "ReadySetPush" -> "kernel/core/src/events/subject.rs:126-149"
      [] name = "ReadySetPushSuppressed" -> "kernel/core/src/events/epoll/entry.rs:247-271,307-318"
      [] name = "ReadySetPopDeleted" -> "kernel/core/src/events/epoll/entry.rs:367-390"
      [] name = "ReadySetPop" -> "kernel/core/src/events/epoll/entry.rs:367-397"
      [] name = "EntryPollDeadFile" -> "kernel/core/src/events/epoll/entry.rs:103-117"
      [] name = "EntryPollDisabled" -> "kernel/core/src/events/epoll/entry.rs:118-124"
      [] name = "EntryPollPrepare" -> "kernel/core/src/events/epoll/entry.rs:116-149"
      [] name = "EpollDiscardEmptyPreparation" -> "kernel/core/src/events/epoll/file.rs:236-245"
      [] name = "DoEpollPwait2CopyoutSuccess" -> "kernel/core/src/syscall/epoll.rs:145-154"
      [] name = "DoEpollPwait2CopyoutFault" -> "kernel/core/src/syscall/epoll.rs:145-152"
      [] name = "PolleePollWithRegister" -> "kernel/core/src/process/signal/poll.rs:90-107,154-165"
      [] name = "PolleePollWithLoad" -> "kernel/core/src/process/signal/poll.rs:106-112"
      [] name = "PolleePollWithCached" -> "kernel/core/src/process/signal/poll.rs:106-110"
      [] name = "PolleePollWithBeginCheck" -> "kernel/core/src/process/signal/poll.rs:112-134"
      [] name = "PolleePollWithCheck" -> "kernel/core/src/process/signal/poll.rs:135-136"
      [] name = "PolleePollWithCache" -> "kernel/core/src/process/signal/poll.rs:138-151"
      [] name = "PolleePollWithConcurrentCheck" -> "kernel/core/src/process/signal/poll.rs:112-115"
      [] name = "PolleePollWithFinish" -> "kernel/core/src/process/signal/poll.rs:150-152"
      [] name = "TimerfdExpired" -> "kernel/core/src/time/timerfd.rs:98-105"
      [] name = "TimerfdNotify" -> "kernel/core/src/time/timerfd.rs:102-105"
      [] name = "TimerfdTryRead" -> "kernel/core/src/time/timerfd.rs:177-186"
      [] name = "TimerfdSetTimeDisarm" -> "kernel/core/src/time/timerfd.rs:130-145"
      [] name = "EventfdAddCounter" -> "kernel/core/src/syscall/eventfd.rs:151-159"
      [] name = "EventfdTryRead" -> "kernel/core/src/syscall/eventfd.rs:124-143"
      [] name = "EventfdNotify" -> "kernel/core/src/syscall/eventfd.rs:141-142,158-159"
      [] name = "EventfdNotifyReturn" -> "kernel/core/src/syscall/eventfd.rs:124-159"
      [] name = "SignalfdUpdateMask" -> "kernel/core/src/syscall/signalfd.rs:103-117,155-161"
      [] name = "SigQueuesEnqueueThread" -> "kernel/core/src/process/signal/sig_queues.rs:38-45"
      [] name = "SigQueuesEnqueueProcess" -> "kernel/core/src/process/signal/sig_queues.rs:38-45"
      [] name = "SigQueuesNotifyThread" -> "kernel/core/src/process/signal/sig_queues.rs:38-45,86-92"
      [] name = "SigQueuesNotifyProcess" -> "kernel/core/src/process/signal/sig_queues.rs:38-45,86-92"
      [] name = "SigQueuesNotifyReturn" -> "kernel/core/src/process/signal/sig_queues.rs:38-45"
      [] name = "SignalFileReadThread" -> "kernel/core/src/syscall/signalfd.rs:182-201,218-243"
      [] name = "SignalFileReadProcess" -> "kernel/core/src/syscall/signalfd.rs:182-201,218-243"
      [] name = "EpollWaitRegisterConsumer" -> "kernel/core/src/events/epoll/file.rs:191-205"
      [] name = "SaveAndSetSigMask" -> "kernel/core/src/syscall/ppoll.rs:31-40"
      [] name = "PollFilesRegisterPoller" -> "kernel/core/src/syscall/poll.rs:88-106,124-185"
      [] name = "PollFilesInitialReady" -> "kernel/core/src/syscall/poll.rs:103-106,165-185"
      [] name = "WaiterPauseTimeoutBlock" -> "kernel/core/src/process/signal/poll.rs:307-315"
      [] name = "WaiterReadinessWake" -> "kernel/core/src/process/signal/poll.rs:167-178,318-321"
      [] name = "WaiterTimeoutExpires" -> "kernel/core/src/process/signal/pause.rs:171-177"
      [] name = "WaiterSignalInterrupts" -> "kernel/core/src/process/signal/pause.rs:184-219"
      [] name = "WaiterPauseTimeoutReturnTimeout" -> "kernel/core/src/process/signal/pause.rs:202-209"
      [] name = "WaiterPauseTimeoutReturnSignal" -> "kernel/core/src/process/signal/pause.rs:211-219"
      [] name = "DoPollCountEvents" -> "kernel/core/src/syscall/poll.rs:108-121,188-215"
      [] name = "HandlePendingSignalRestoreMask" -> "kernel/core/src/process/signal/mod.rs:64-85,208-230"
      [] name = "EpollAddNestedInterest" -> "kernel/core/src/events/epoll/file.rs:64-125"
      [] name = "ReadySetPushAcquire" -> "kernel/core/src/events/subject.rs:126-149"
      [] name = "ReadySetPushNotifySubject" -> "kernel/core/src/events/epoll/entry.rs:320-330"
      [] name = "SyncSubjectCallbackReadySet" -> "kernel/core/src/events/subject.rs:136-149"
      [] name = "ObserverCallbackRelease" -> "kernel/core/src/events/subject.rs:126-153"
      [] OTHER -> ""

HasProductionSource(name) ==
    \* kernel/core/src/fs/file/file_table.rs:100-121
    name \in ProductionActionNames /\ ProductionActionSource(name) /= ""

(***************************************************************************)
(* Variables                                                               *)
(***************************************************************************)

VARIABLES
    slots,
    slotFlags,
    slotEpoch,
    ofdStatus,
    ofdAlive,
    captured,
    capturedFd,
    capturedStatus,
    captureEpoch,
    lastCaptured,
    actedOFD,
    actedSlotOFD,
    actedCaptureEpoch,
    actedSlotEpoch,
    closePending,
    replacement,
    sharedTable,
    execPhase,
    execOwner,
    execPrivateSlots,
    execPrivateFlags,
    execPrivateEpoch,
    execPrivateSlotMapAudit,
    execSnapshotSlots,
    execSnapshotFlags,
    execExternalAudit,
    fdFlagAudit,
    slotMapAudit

VARIABLES
    interest,
    readyQ,
    entryEnabled,
    triggerMode,
    registered,
    keySlotEpoch,
    interestIdentity,
    ctl,
    delivery,
    copyoutOk,
    deliveredKeys,
    faultedUndelivered,
    lastDeliveredKey,
    reportedOFD,
    epollWaiter,
    epollWake

VARIABLES
    sourceReady,
    sourceEpoch,
    readyEpoch,
    callbackEpoch,
    callbackActor,
    queuedEpoch,
    deliveredEpoch,
    consumerReadyEpoch,
    cacheState,
    directRegistered,
    notified,
    observedReady,
    observedEpoch,
    timerTicks,
    eventCounter,
    pollLocal,
    producerPhase,
    eventNotifyKeys,
    eventNotifyWaiters,
    eventNotifyCounter

VARIABLES
    signalMask,
    threadPending,
    processPending,
    pollerBindings,
    signalNotify,
    signalNotifyKeys,
    signalNotifyWaiters,
    threadSignalEnqueueEpoch,
    threadSignalNotifyEpoch,
    processSignalEnqueueEpoch,
    processSignalNotifyEpoch

VARIABLES
    waitState,
    wakeCause,
    deadlineExpired,
    interruptPending,
    visibleReady,
    terminalReady,
    terminalScanValid,
    terminalScanExpected,
    currentMask,
    savedMask,
    preWaitMask,
    returnReason,
    waitReadyToken,
    lastReadyWake,
    waitCapturedOFDs,
    waitCaptureAudit,
    waitCapturedSlots,
    waitCaptureSlotAudit,
    lastReleasedWaitOFDs,
    lastReleasedWaitSlots,
    waitGeneration,
    completedWaitReason,
    lastCompletedWaitReason

VARIABLES
    epollGraph,
    heldLocks,
    lockOwner,
    callbackStage,
    callbackKey,
    epollReadyEpoch,
    nestedRequiredEpoch,
    nestedDeliveredEpoch

execVars ==
    <<sharedTable, execPhase, execOwner, execPrivateSlots, execPrivateFlags,
      execPrivateEpoch, execPrivateSlotMapAudit, execSnapshotSlots,
      execSnapshotFlags, execExternalAudit>>

fdVars ==
    <<slots, slotFlags, slotEpoch, ofdStatus, ofdAlive, captured, capturedFd,
      capturedStatus, captureEpoch, lastCaptured, actedOFD, actedSlotOFD,
      actedCaptureEpoch, actedSlotEpoch, closePending, replacement, execVars,
      fdFlagAudit, slotMapAudit>>

epollVars ==
    <<interest, readyQ, entryEnabled, triggerMode, registered, keySlotEpoch,
      interestIdentity, ctl, delivery,
      copyoutOk, deliveredKeys, faultedUndelivered, lastDeliveredKey,
      reportedOFD, epollWaiter, epollWake>>

readinessVars ==
    <<sourceReady, sourceEpoch, readyEpoch, callbackEpoch, callbackActor,
      queuedEpoch, deliveredEpoch, consumerReadyEpoch, cacheState,
      directRegistered, notified, observedReady, observedEpoch, timerTicks,
      eventCounter, pollLocal, producerPhase, eventNotifyKeys,
      eventNotifyWaiters, eventNotifyCounter>>

signalVars ==
    <<signalMask, threadPending, processPending, pollerBindings,
      signalNotify, signalNotifyKeys, signalNotifyWaiters,
      threadSignalEnqueueEpoch, threadSignalNotifyEpoch,
      processSignalEnqueueEpoch, processSignalNotifyEpoch>>

waitVars ==
    <<waitState, wakeCause, deadlineExpired, interruptPending, visibleReady,
      terminalReady, terminalScanValid, terminalScanExpected, currentMask,
      savedMask, preWaitMask, returnReason, waitReadyToken, lastReadyWake,
      waitCapturedOFDs, waitCaptureAudit, waitCapturedSlots,
      waitCaptureSlotAudit, lastReleasedWaitOFDs, lastReleasedWaitSlots,
      waitGeneration, completedWaitReason, lastCompletedWaitReason>>

topologyVars ==
    <<epollGraph, heldLocks, lockOwner, callbackStage,
      callbackKey, epollReadyEpoch, nestedRequiredEpoch,
      nestedDeliveredEpoch>>

allVars == <<fdVars, epollVars, readinessVars, signalVars, waitVars,
             topologyVars>>

(***************************************************************************)
(* Helpers                                                                 *)
(***************************************************************************)

InitialSlots ==
    \* The bounded fixture mirrors the three pre-created file objects.
    \* kernel/core/src/syscall/timerfd_create.rs:17-28
    \* kernel/core/src/syscall/signalfd.rs:87-100
    \* kernel/core/src/syscall/eventfd.rs:52-83
    [fd \in FDs |-> CASE fd = FD0 -> TimerOFD
                     [] fd = FD1 -> SignalOFD
                     [] OTHER -> EventOFD]

OFDReady(o, t) ==
    \* Each branch is the live check used by the corresponding Pollable.
    \* kernel/core/src/time/timerfd.rs:189-204
    \* kernel/core/src/syscall/eventfd.rs:104-121,166-170
    \* kernel/core/src/syscall/signalfd.rs:171-179,205-215
    CASE o = TimerOFD -> timerTicks > 0
      [] o = EventOFD -> eventCounter > 0
      [] o = SignalOFD -> signalMask[SignalOFD]
                              /\ (threadPending[t] \/ processPending)

LiveWaitReadiness(t) ==
    \* PollFiles::count_events invokes only the FileLike values retained by
    \* this invocation's CowFiles::Owned snapshot. Numeric-slot reuse cannot
    \* redirect this terminal scan to a later table entry.
    \* kernel/core/src/syscall/poll.rs:96-101,124-155,188-225
    /\ \E o \in waitCapturedOFDs[t] : ofdAlive[o] /\ OFDReady(o, t)

CurrentPollSnapshot ==
    \* The bounded poll vector contains one entry for each modeled FD. On the
    \* shared-table path, new_owned clones every present Arc before polling.
    \* kernel/core/src/syscall/poll.rs:96-101,124-155
    {slots[fd] : fd \in {d \in FDs : slots[d] /= NoOFD}}

CurrentPollSlotSnapshot ==
    \* This is the exact CowFiles::Owned vector at the bounded FD positions.
    \* Unlike CurrentPollSnapshot, it preserves duplicate Arc owners.
    \* kernel/core/src/syscall/poll.rs:96-101,124-155
    slots

WaitReleasedRefs(t, o) ==
    \* Each occupied captured vector position owns one Arc, even when several
    \* positions refer to the same open file description.
    \* kernel/core/src/syscall/poll.rs:96-101,124-155
    Cardinality({fd \in FDs : waitCapturedSlots[t][fd] = o})

KeyReady(k) ==
    \* SignalFile::poll installs its PollHandle on the thread executing
    \* Entry::update. A later epoll_wait changes the delivery consumer, but
    \* does not move a thread-directed signal registration to that consumer.
    \* kernel/core/src/events/epoll/entry.rs:155-166
    \* kernel/core/src/syscall/signalfd.rs:207-216
    IF k.ofd = SignalOFD
    THEN \E b \in pollerBindings : b.key = k /\ OFDReady(k.ofd, b.thread)
    ELSE \E t \in Threads : OFDReady(k.ofd, t)

FdIndex(fd) ==
    \* The concrete close_range loop walks the inclusive numeric interval.
    \* kernel/core/src/syscall/close.rs:83-100
    CASE fd = FD0 -> 0
      [] fd = FD1 -> 1
      [] OTHER -> 2

FdRange(first, last) ==
    \* kernel/core/src/syscall/close.rs:83-100
    {fd \in FDs : FdIndex(first) <= FdIndex(fd)
                    /\ FdIndex(fd) <= FdIndex(last)}

AliasPeers(fd) ==
    \* A duplicate creates a fresh FileTableEntry with descriptor-local flags
    \* while cloning the same Arc-backed open file description.
    \* kernel/core/src/fs/file/file_table.rs:181-187,372-404
    {peer \in FDs : peer /= fd /\ slots[fd] /= NoOFD
                       /\ slots[peer] = slots[fd]}

KeysForOFD(o) ==
    \* kernel/core/src/events/epoll/entry.rs:46-67
    {k \in interest : k.ofd = o}
EnabledRegisteredForOFD(o) ==
    \* Only registered, enabled Entry observers can receive a callback.
    \* kernel/core/src/events/epoll/entry.rs:247-283,307-330
    {k \in registered : k.ofd = o /\ entryEnabled[k]}

SignalKeysBoundToThread(t) ==
    \* A thread-directed SigQueues notification reaches only observers
    \* registered on that thread's queue.
    \* kernel/core/src/process/posix_thread/mod.rs:256-270
    \* kernel/core/src/process/signal/sig_queues.rs:38-45,86-92
    {k \in registered :
        /\ k.ofd = SignalOFD
        /\ entryEnabled[k]
        /\ Binding(k, t) \in pollerBindings}

EnabledSignalKeys ==
    \* The process SigQueues object is shared by every signalfd registration.
    \* kernel/core/src/process/posix_thread/mod.rs:266-270
    {k \in registered : k.ofd = SignalOFD /\ entryEnabled[k]}

SignalKeysConsumedBy(t) ==
    \* Entry::poll executes SignalFile::poll in the epoll-waiting thread.
    \* kernel/core/src/events/epoll/file.rs:210-244
    \* kernel/core/src/syscall/signalfd.rs:205-215
    {k \in registered :
        k.ofd = SignalOFD /\ entryEnabled[k]
        /\ epollWaiter[k.epoll] = t}

ofdRefs(o) ==
    \* File-table entries and in-flight owned/Cow references are strong; an
    \* epoll EntryKey is weak and deliberately absent.
    \* kernel/core/src/fs/file/file_table.rs:169-205,326-367
    \* kernel/core/src/events/epoll/entry.rs:46-67,103-109
    (IF execPhase \in {"snapshotted", "closed"}
         /\ ~execExternalAudit.oldTableRetained
     THEN 0
     ELSE Cardinality({fd \in FDs : slots[fd] = o}))
    + (IF execPhase \in {"snapshotted", "closed"}
       THEN Cardinality({fd \in FDs : execPrivateSlots[fd] = o})
       ELSE 0)
    + Cardinality({t \in Threads : captured[t] = o})
    + Cardinality({t \in Threads : closePending[t] = o})
    + Cardinality({t \in Threads :
          ctl[t].phase /= "idle" /\ ctl[t].target = o})
    + Cardinality({t \in Threads :
          pollLocal[t].phase /= "idle" /\ pollLocal[t].ofd = o})
    + Cardinality({p \in (Threads \X FDs) :
          waitCapturedSlots[p[1]][p[2]] = o})

ThreadsIdleForExec ==
    \* exec reaches file-table cutover only after sibling tasks terminate.
    \* kernel/core/src/process/execve.rs:161-164,202-234
    /\ \A t \in Threads : captured[t] = NoOFD
    /\ \A t \in Threads : closePending[t] = NoOFD
    /\ \A t \in Threads : replacement[t].phase \in {"idle", "done"}
    /\ \A t \in Threads : ctl[t].phase = "idle"
    /\ \A t \in Threads : delivery[t].stage = "idle"
    /\ \A t \in Threads : pollLocal[t].phase = "idle"
    /\ \A t \in Threads : waitState[t] \in {"idle", "returned"}
    /\ \A t \in Threads : waitCapturedOFDs[t] = {}
    /\ \A t \in Threads : waitCapturedSlots[t] = EmptyWaitSlotSnapshot

\* One POSIX thread executes one syscall path at a time. These guards still
\* allow another thread to close/reuse a slot between this thread's split
\* semantic steps (file_table.rs:335-337; dup.rs:73-78).
ThreadHasNoOtherOperation(t) ==
    \* kernel/core/src/fs/file/file_table.rs:335-367
    \* kernel/core/src/syscall/dup.rs:73-78
    /\ captured[t] = NoOFD
    /\ closePending[t] = NoOFD
    /\ replacement[t].phase \in {"idle", "done"}
    /\ ctl[t].phase = "idle"
    /\ delivery[t].stage = "idle"
    /\ pollLocal[t].phase = "idle"
    /\ producerPhase[t] = "idle"
    \* SigQueues::enqueue has not returned until its unlocked notify and all
    \* synchronously selected callbacks have returned.
    \* kernel/core/src/process/signal/sig_queues.rs:38-45
    \* kernel/core/src/events/subject.rs:126-153
    /\ signalNotify[t].phase = "idle"
    /\ callbackStage[t] = "idle"
    /\ \A k \in InterestKeys : callbackActor[k] /= t

ThreadSyscallIdle(t) ==
    \* kernel/core/src/syscall/close.rs:25-40
    \* kernel/core/src/syscall/poll.rs:88-121
    /\ ThreadHasNoOtherOperation(t)
    /\ waitState[t] \in {"idle", "returned"}

EventfdMutexOwnerFrom(phases) ==
    \* The counter Mutex remains held from counter mutation through the
    \* synchronous Pollee notification and every selected observer callback.
    \* kernel/core/src/syscall/eventfd.rs:124-159
    IF \E t \in Threads : phases[t] \in {"event_notify", "event_callbacks"}
    THEN CHOOSE t \in Threads :
           phases[t] \in {"event_notify", "event_callbacks"}
    ELSE NoThread

EventfdMutexOwner ==
    \* kernel/core/src/syscall/eventfd.rs:124-159
    EventfdMutexOwnerFrom(producerPhase)

WaitersEligibleForReady(o) ==
    \* PollFiles registers its Waker before returning Registered; a notify in
    \* the register-to-block window must therefore create the same wake token
    \* as a notify after Waiter::pause_timeout has blocked.
    \* kernel/core/src/syscall/poll.rs:103-106,165-185
    \* kernel/core/src/process/signal/poll.rs:154-165,307-321
    {w \in Threads :
        waitState[w] \in {"registered", "blocked", "woken"}
        /\ waitReadyToken[w].epoch = 0
        /\ o \in waitCapturedOFDs[w]
        /\ ofdAlive[o]}

WaitReadyTokenFor(o, actor) ==
    \* The notification callback carries the producer's current epoch and
    \* executes in the notifying actor, not the target waiter.
    \* kernel/core/src/process/signal/poll.rs:167-178,318-321
    [ofd |-> o, actor |-> actor, epoch |-> sourceEpoch[o]]

ProducerQuiescent(o) ==
    \* Mutation and notify are split only where the Rust call sequence has
    \* an observable boundary between them.
    \* kernel/core/src/time/timerfd.rs:102-105
    \* kernel/core/src/syscall/eventfd.rs:124-159
    CASE o = TimerOFD ->
            \A t \in Threads : producerPhase[t] /= "timer_notify"
      [] o = EventOFD -> EventfdMutexOwner = NoThread
      [] OTHER -> TRUE

ExpectedExecSlots ==
    \* close_files_on_exec removes exactly entries whose per-slot flag was in
    \* the unshared-table snapshot.
    \* kernel/core/src/fs/file/file_table.rs:208-234
    [fd \in FDs |->
        IF execSnapshotFlags[fd]
        THEN NoOFD
        ELSE execSnapshotSlots[fd]]

ExpectedExecFlags ==
    \* Removed slots have no surviving descriptor flag.
    \* kernel/core/src/fs/file/file_table.rs:208-234,389-395
    [fd \in FDs |->
        IF execSnapshotFlags[fd]
        THEN FALSE
        ELSE execSnapshotFlags[fd]]

ExecReleasedRefs(o) ==
    \* close_files_on_exec returns one ClosedFile per removed descriptor, and
    \* unshare_and_close_files drops the complete vector after unlocking.
    \* kernel/core/src/fs/file/file_table.rs:208-234
    \* kernel/core/src/process/execve.rs:378-386
    Cardinality({fd \in FDs : execSnapshotFlags[fd]
                                /\ execSnapshotSlots[fd] = o})

AliveAfterExecReleases ==
    \* All snapshot-selected ClosedFile values are released by the one
    \* production completion, including multiple descriptors for one OFD.
    \* kernel/core/src/process/execve.rs:381-386
    [o \in OFDs |->
        IF ExecReleasedRefs(o) > 0 /\ ofdRefs(o) = ExecReleasedRefs(o)
        THEN FALSE
        ELSE ofdAlive[o]]

AliveAfterWaitRelease(t) ==
    \* Dropping CowFiles::Owned releases every cloned slot owner in the exact
    \* per-wait snapshot, including duplicate descriptors for one OFD.
    \* kernel/core/src/syscall/poll.rs:96-101,103-121,124-155
    [o \in OFDs |->
        IF WaitReleasedRefs(t, o) > 0
           /\ ofdRefs(o) = WaitReleasedRefs(t, o)
        THEN FALSE
        ELSE ofdAlive[o]]

AliveAfterOneRelease(o) ==
    \* ClosedFile/Cow/PollHandle destruction releases one strong Arc after the
    \* implementation guard has gone out of scope.
    \* kernel/core/src/fs/file/file_table.rs:274-302,335-367
    [x \in OFDs |-> IF x = o /\ ofdRefs(o) = 1 THEN FALSE ELSE ofdAlive[x]]

FreshWaitFields(t) ==
    \* Poller/Waiter and timeout state is allocated afresh for each do_poll
    \* invocation; save_and_set_sig_mask likewise rejects an inherited saved
    \* mask from an earlier syscall.
    \* kernel/core/src/syscall/poll.rs:88-106,165-185
    \* kernel/core/src/process/signal/poll.rs:282-315
    \* kernel/core/src/process/posix_thread/mod.rs:381-386
    /\ wakeCause[t] = "none"
    /\ ~deadlineExpired[t]
    /\ ~interruptPending[t]
    /\ returnReason[t] = "none"
    /\ ~terminalReady[t]
    /\ ~terminalScanValid[t]
    /\ ~terminalScanExpected[t]
    /\ waitReadyToken[t] = EmptyWaitReadyToken
    /\ lastReadyWake[t] = EmptyWaitReadyToken
    /\ waitCapturedOFDs[t] = waitCaptureAudit[t]
    /\ waitCapturedSlots[t] = waitCaptureSlotAudit[t]
    /\ waitCapturedOFDs[t] =
          {waitCapturedSlots[t][fd] :
              fd \in {d \in FDs : waitCapturedSlots[t][d] /= NoOFD}}
    /\ lastReleasedWaitOFDs[t] = {}
    /\ lastReleasedWaitSlots[t] = EmptyWaitSlotSnapshot
    /\ completedWaitReason[t] = "none"
    /\ visibleReady[t] = LiveWaitReadiness(t)
    /\ IF savedMask[t] = "none"
       THEN currentMask[t] = preWaitMask[t]
       ELSE savedMask[t] = preWaitMask[t]

ExecPrivateExpectedSlots ==
    \* The installed private table equals the atomic clone until the later
    \* close-on-exec scan removes snapshot-marked entries.
    \* kernel/core/src/process/namespace/unshare.rs:18-28
    \* kernel/core/src/fs/file/file_table.rs:208-234
    IF execPhase = "closed" THEN ExpectedExecSlots ELSE execSnapshotSlots

ExecPrivateExpectedFlags ==
    \* kernel/core/src/process/namespace/unshare.rs:18-28
    \* kernel/core/src/fs/file/file_table.rs:208-234
    IF execPhase = "closed" THEN ExpectedExecFlags ELSE execSnapshotFlags

CompletedRegistration(k) ==
    \* Entry::update registers its PollHandle before the live check returns.
    \* kernel/core/src/events/epoll/entry.rs:155-166
    k \in interest /\ k \in registered

(***************************************************************************)
(* Init                                                                    *)
(***************************************************************************)

Init ==
    \* Initial file-table entries and descriptor-local flags.
    \* kernel/core/src/fs/file/file_table.rs:190-194,372-395
    /\ slots = InitialSlots
    /\ slotFlags = [fd \in FDs |-> FALSE]
    /\ slotEpoch = [fd \in FDs |-> 0]
    /\ ofdStatus = [o \in OFDs |-> FALSE]
    /\ ofdAlive = [o \in OFDs |-> TRUE]
    \* No syscall has captured or acted on an OFD yet.
    \* kernel/core/src/fs/file/file_table.rs:326-367
    /\ captured = [t \in Threads |-> NoOFD]
    /\ capturedFd = [t \in Threads |-> NoFD]
    /\ capturedStatus = [t \in Threads |-> FALSE]
    /\ captureEpoch = [t \in Threads |-> 0]
    /\ lastCaptured = [t \in Threads |-> NoOFD]
    /\ actedOFD = [t \in Threads |-> NoOFD]
    /\ actedSlotOFD = [t \in Threads |-> NoOFD]
    /\ actedCaptureEpoch = [t \in Threads |-> 0]
    /\ actedSlotEpoch = [t \in Threads |-> 0]
    /\ closePending = [t \in Threads |-> NoOFD]
    /\ replacement = [t \in Threads |-> EmptyReplacement]
    /\ sharedTable = TRUE
    /\ execPhase = "idle"
    /\ execOwner = NoThread
    /\ execPrivateSlots = InitialSlots
    /\ execPrivateFlags = [fd \in FDs |-> FALSE]
    /\ execPrivateEpoch = [fd \in FDs |-> 0]
    /\ execPrivateSlotMapAudit = InitialSlots
    /\ execSnapshotSlots = InitialSlots
    /\ execSnapshotFlags = [fd \in FDs |-> FALSE]
    /\ execExternalAudit = EmptyExecExternalAudit
    /\ fdFlagAudit = EmptyFdFlagAudit
    \* Independent shadow of each table mutation. Controller-only controls
    \* can corrupt one in-domain side without violating TypeOK.
    \* kernel/core/src/fs/file/file_table.rs:139-205
    /\ slotMapAudit = InitialSlots
    /\ interest = {}
    /\ readyQ = {}
    /\ entryEnabled = [k \in InterestKeys |-> FALSE]
    /\ triggerMode = [k \in InterestKeys |-> "LT"]
    /\ registered = {}
    /\ keySlotEpoch = [k \in InterestKeys |-> 0]
    /\ interestIdentity = [k \in InterestKeys |-> EmptyInterestIdentity]
    /\ ctl = [t \in Threads |-> EmptyCtl]
    /\ delivery = [t \in Threads |-> EmptyDelivery]
    /\ copyoutOk = [t \in Threads |-> "none"]
    /\ deliveredKeys = {}
    /\ faultedUndelivered = {}
    /\ lastDeliveredKey = [t \in Threads |-> NoKey]
    /\ reportedOFD = [t \in Threads |-> NoOFD]
    /\ epollWaiter = [e \in Epolls |-> NoThread]
    /\ epollWake = [e \in Epolls |-> FALSE]
    \* Epoch zero means no producer transition, callback, queue insertion, or
    \* delivery has occurred for the key.
    \* kernel/core/src/process/signal/poll.rs:167-178
    \* kernel/core/src/events/epoll/entry.rs:280-330
    /\ sourceReady = [o \in OFDs |-> FALSE]
    /\ sourceEpoch = [o \in OFDs |-> 0]
    /\ readyEpoch = [k \in InterestKeys |-> 0]
    /\ callbackEpoch = [k \in InterestKeys |-> 0]
    /\ callbackActor = [k \in InterestKeys |-> NoThread]
    /\ queuedEpoch = [k \in InterestKeys |-> 0]
    /\ deliveredEpoch = [k \in InterestKeys |-> 0]
    /\ consumerReadyEpoch = [b \in Bindings |-> 0]
    /\ cacheState = [o \in OFDs |-> "invalid"]
    /\ directRegistered = {}
    /\ notified = {}
    /\ observedReady = {}
    /\ observedEpoch = [r \in PollRegistrations |-> 0]
    /\ timerTicks = 0
    /\ eventCounter = 0
    /\ pollLocal = [t \in Threads |-> EmptyPollLocal]
    /\ producerPhase = [t \in Threads |-> "idle"]
    /\ eventNotifyKeys = {}
    /\ eventNotifyWaiters = {}
    /\ eventNotifyCounter = 0
    /\ signalMask = [o \in OFDs |-> FALSE]
    /\ threadPending = [t \in Threads |-> FALSE]
    /\ processPending = FALSE
    /\ pollerBindings = {}
    /\ signalNotify = [t \in Threads |-> EmptySignalNotify]
    /\ signalNotifyKeys = [t \in Threads |-> {}]
    /\ signalNotifyWaiters = [t \in Threads |-> {}]
    /\ threadSignalEnqueueEpoch = [t \in Threads |-> 0]
    /\ threadSignalNotifyEpoch = [t \in Threads |-> 0]
    /\ processSignalEnqueueEpoch = 0
    /\ processSignalNotifyEpoch = 0
    /\ waitState = [t \in Threads |-> "idle"]
    /\ wakeCause = [t \in Threads |-> "none"]
    /\ deadlineExpired = [t \in Threads |-> FALSE]
    /\ interruptPending = [t \in Threads |-> FALSE]
    /\ visibleReady = [t \in Threads |-> FALSE]
    /\ terminalReady = [t \in Threads |-> FALSE]
    /\ terminalScanValid = [t \in Threads |-> FALSE]
    /\ terminalScanExpected = [t \in Threads |-> FALSE]
    /\ currentMask = [t \in Threads |-> "unblocked"]
    /\ savedMask = [t \in Threads |-> "none"]
    /\ preWaitMask = [t \in Threads |-> "unblocked"]
    /\ returnReason = [t \in Threads |-> "none"]
    /\ waitReadyToken = [t \in Threads |-> EmptyWaitReadyToken]
    /\ lastReadyWake = [t \in Threads |-> EmptyWaitReadyToken]
    /\ waitCapturedOFDs = [t \in Threads |-> {}]
    /\ waitCaptureAudit = [t \in Threads |-> {}]
    /\ waitCapturedSlots = [t \in Threads |-> EmptyWaitSlotSnapshot]
    /\ waitCaptureSlotAudit = [t \in Threads |-> EmptyWaitSlotSnapshot]
    /\ lastReleasedWaitOFDs = [t \in Threads |-> {}]
    /\ lastReleasedWaitSlots = [t \in Threads |-> EmptyWaitSlotSnapshot]
    /\ waitGeneration = [t \in Threads |-> 0]
    /\ completedWaitReason = [t \in Threads |-> "none"]
    /\ lastCompletedWaitReason = [t \in Threads |-> "none"]
    /\ epollGraph = {}
    /\ heldLocks = [t \in Threads |-> {}]
    /\ lockOwner = [l \in LockNames |-> NoThread]
    /\ callbackStage = [t \in Threads |-> "idle"]
    /\ callbackKey = [t \in Threads |-> NoKey]
    /\ epollReadyEpoch = [e \in Epolls |-> 0]
    /\ nestedRequiredEpoch = [edge \in (Epolls \X Epolls) |-> 0]
    /\ nestedDeliveredEpoch = [edge \in (Epolls \X Epolls) |-> 0]

(***************************************************************************)
(* Scenario 1: file-table lookup, close, duplication, flags, and exec.     *)
(***************************************************************************)

FileTableInsert(t, fd, o, cloexec) ==
    \* FileTable::insert allocates/installs one FileTableEntry while the
    \* caller holds the table write lock (file_table.rs:190-194).
    /\ execPhase = "idle"
    /\ ThreadSyscallIdle(t)
    /\ slots[fd] = NoOFD
    /\ ofdAlive[o]
    \* One write-locked put changes the slot identity and its generation.
    \* kernel/core/src/fs/file/file_table.rs:190-194
    /\ slots' = [slots EXCEPT ![fd] = o]
    /\ slotMapAudit' = [slotMapAudit EXCEPT ![fd] = o]
    /\ slotFlags' = [slotFlags EXCEPT ![fd] = cloexec]
    /\ slotEpoch' = [slotEpoch EXCEPT ![fd] = @ + 1]
    /\ fdFlagAudit' = EmptyFdFlagAudit
    /\ UNCHANGED <<ofdStatus, ofdAlive, captured, capturedFd,
                    capturedStatus, captureEpoch, lastCaptured, actedOFD,
                    actedSlotOFD, actedCaptureEpoch, actedSlotEpoch,
                    closePending, replacement, execVars>>
    /\ UNCHANGED <<epollVars, readinessVars, signalVars, waitVars,
                    topologyVars>>

FcntlSetFlCapture(t, fd, status) ==
    \* get_file_fast returns a Cow tied to the old object identity. On the
    \* shared path the Arc clone survives after the read guard is released.
    \* kernel/core/src/syscall/fcntl.rs:87-92
    \* kernel/core/src/fs/file/file_table.rs:326-367
    /\ execPhase = "idle"
    /\ ThreadSyscallIdle(t)
    /\ captured[t] = NoOFD
    /\ slots[fd] /= NoOFD
    \* Capture the slot generation with the OFD; later reuse changes only the
    \* slot and generation, never this local reference.
    \* kernel/core/src/fs/file/file_table.rs:335-337,360-366
    /\ captured' = [captured EXCEPT ![t] = slots[fd]]
    /\ capturedFd' = [capturedFd EXCEPT ![t] = fd]
    /\ capturedStatus' = [capturedStatus EXCEPT ![t] = status]
    /\ captureEpoch' = [captureEpoch EXCEPT ![t] = slotEpoch[fd]]
    /\ lastCaptured' = [lastCaptured EXCEPT ![t] = slots[fd]]
    /\ actedOFD' = [actedOFD EXCEPT ![t] = NoOFD]
    /\ actedSlotOFD' = [actedSlotOFD EXCEPT ![t] = NoOFD]
    /\ actedCaptureEpoch' = [actedCaptureEpoch EXCEPT ![t] = 0]
    /\ actedSlotEpoch' = [actedSlotEpoch EXCEPT ![t] = 0]
    /\ UNCHANGED <<slots, slotFlags, slotEpoch, ofdStatus, ofdAlive,
                    closePending,
                    replacement, execVars,
                    fdFlagAudit, slotMapAudit>>
    /\ UNCHANGED <<epollVars, readinessVars, signalVars, waitVars,
                    topologyVars>>

FcntlSetFlUse(t) ==
    \* update_status_flags dereferences the captured Cow/Arc. There is no
    \* second lookup of capturedFd between lines 89 and 92.
    \* kernel/core/src/syscall/fcntl.rs:87-94
    /\ captured[t] /= NoOFD
    /\ LET o == captured[t]
           fd == capturedFd[t]
       IN
       \* The OFD update and release use the captured identity even when the
       \* numeric slot now names another object.
       \* kernel/core/src/fs/file/file_table.rs:335-367
       /\ ofdStatus' = [ofdStatus EXCEPT ![o] = capturedStatus[t]]
       /\ ofdAlive' = AliveAfterOneRelease(o)
       /\ actedOFD' = [actedOFD EXCEPT ![t] = o]
       /\ actedSlotOFD' = [actedSlotOFD EXCEPT ![t] = slots[fd]]
       /\ actedCaptureEpoch' =
             [actedCaptureEpoch EXCEPT ![t] = captureEpoch[t]]
       /\ actedSlotEpoch' = [actedSlotEpoch EXCEPT ![t] = slotEpoch[fd]]
    /\ captured' = [captured EXCEPT ![t] = NoOFD]
    /\ capturedFd' = [capturedFd EXCEPT ![t] = NoFD]
    /\ capturedStatus' = [capturedStatus EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<slots, slotFlags, slotEpoch, captureEpoch, lastCaptured,
                    closePending, replacement, execVars,
                    fdFlagAudit, slotMapAudit>>
    /\ UNCHANGED <<epollVars, readinessVars, signalVars, waitVars,
                    topologyVars>>

SysCloseRemove(t, fd) ==
    \* kernel/core/src/syscall/close.rs:25-31
    \* kernel/core/src/fs/file/file_table.rs:196-205
    \* sys_close validates and removes exactly one entry under the table write
    \* lock, retaining ClosedFile for deferred cleanup (close.rs:25-31).
    /\ execPhase = "idle"
    /\ ThreadSyscallIdle(t)
    /\ closePending[t] = NoOFD
    /\ slots[fd] /= NoOFD
    /\ closePending' = [closePending EXCEPT ![t] = slots[fd]]
    /\ slots' = [slots EXCEPT ![fd] = NoOFD]
    /\ slotMapAudit' = [slotMapAudit EXCEPT ![fd] = NoOFD]
    /\ slotFlags' = [slotFlags EXCEPT ![fd] = FALSE]
    /\ slotEpoch' = [slotEpoch EXCEPT ![fd] = @ + 1]
    /\ fdFlagAudit' = EmptyFdFlagAudit
    /\ UNCHANGED <<ofdStatus, ofdAlive, captured, capturedFd,
                    capturedStatus, captureEpoch, lastCaptured, actedOFD,
                    actedSlotOFD, actedCaptureEpoch, actedSlotEpoch,
                    replacement, execVars>>
    /\ UNCHANGED <<epollVars, readinessVars, signalVars, waitVars,
                    topologyVars>>

ClosedFileDrop(t) ==
    \* VFS notification and ClosedFile::drop occur after releasing the file-table
    \* write lock (close.rs:33-40; file_table.rs:297-302).
    /\ closePending[t] /= NoOFD
    /\ replacement[t].phase /= "cleanup"
    \* Dropping the ClosedFile also performs the final Arc release. Epoll's
    \* weak EntryKey is not a strong reference.
    \* kernel/core/src/fs/file/file_table.rs:274-302
    \* kernel/core/src/events/epoll/entry.rs:46-67,103-109
    /\ ofdAlive' = AliveAfterOneRelease(closePending[t])
    /\ closePending' = [closePending EXCEPT ![t] = NoOFD]
    /\ UNCHANGED <<slots, slotFlags, slotEpoch, ofdStatus, captured,
                    capturedFd, capturedStatus, captureEpoch, lastCaptured,
                    actedOFD, actedSlotOFD, actedCaptureEpoch, actedSlotEpoch,
                    replacement, execVars, fdFlagAudit, slotMapAudit>>
    /\ UNCHANGED <<epollVars, readinessVars, signalVars, waitVars,
                    topologyVars>>

SysDup2Equal(t, fd) ==
    \* kernel/core/src/syscall/dup.rs:21-30
    \* dup2(oldfd, oldfd) validates that the slot exists and returns without
    \* replacement (dup.rs:21-30).
    /\ execPhase = "idle"
    /\ ThreadSyscallIdle(t)
    /\ slots[fd] /= NoOFD
    /\ actedOFD' = [actedOFD EXCEPT ![t] = slots[fd]]
    /\ lastCaptured' = [lastCaptured EXCEPT ![t] = slots[fd]]
    /\ UNCHANGED <<slots, slotFlags, slotEpoch, ofdStatus, ofdAlive, captured,
                    capturedFd, capturedStatus, captureEpoch, actedSlotOFD,
                    actedCaptureEpoch, actedSlotEpoch, closePending,
                    replacement, execVars, fdFlagAudit, slotMapAudit>>
    /\ UNCHANGED <<epollVars, readinessVars, signalVars, waitVars,
                    topologyVars>>

SysDup3Validate(t, sourceFd, targetFd, cloexec) ==
    \* kernel/core/src/syscall/dup.rs:50-73
    \* do_dup3 converts descriptors, rejects equality, and checks the target
    \* limit before locking the table (dup.rs:50-73).
    /\ execPhase = "idle"
    /\ ThreadSyscallIdle(t)
    /\ sourceFd /= targetFd
    /\ replacement[t].phase \in {"idle", "done"}
    /\ replacement' = [replacement EXCEPT ![t] =
          [phase |-> "validated",
           sourceFd |-> sourceFd,
           targetFd |-> targetFd,
           sourceOFD |-> NoOFD,
           replacedOFD |-> NoOFD,
           newCloexec |-> cloexec,
           removedCount |-> 0]]
    /\ UNCHANGED <<slots, slotFlags, slotEpoch, ofdStatus, ofdAlive, captured,
                    capturedFd, capturedStatus, captureEpoch, lastCaptured,
                    actedOFD, actedSlotOFD, actedCaptureEpoch, actedSlotEpoch,
                    closePending, execVars, fdFlagAudit, slotMapAudit>>
    /\ UNCHANGED <<epollVars, readinessVars, signalVars, waitVars,
                    topologyVars>>

FileTableDupExact(t) ==
    \* kernel/core/src/fs/file/file_table.rs:169-187
    \* kernel/core/src/syscall/dup.rs:73-77
    \* duplicate_entry clones the source, then close_file and put_at replace the
    \* target under one table write lock (file_table.rs:169-187; dup.rs:73-77).
    /\ replacement[t].phase = "validated"
    /\ slots[replacement[t].sourceFd] /= NoOFD
    /\ closePending[t] = NoOFD
    /\ LET src == slots[replacement[t].sourceFd]
           dst == replacement[t].targetFd
           old == slots[dst]
       IN
       /\ slots' = [slots EXCEPT ![dst] = src]
       /\ slotMapAudit' = [slotMapAudit EXCEPT ![dst] = src]
       /\ slotFlags' = [slotFlags EXCEPT ![dst] = replacement[t].newCloexec]
       /\ slotEpoch' = [slotEpoch EXCEPT ![dst] = @ + 1]
       /\ fdFlagAudit' = EmptyFdFlagAudit
       /\ closePending' = [closePending EXCEPT ![t] = old]
       /\ replacement' = [replacement EXCEPT ![t] =
             [@ EXCEPT !.phase = "cleanup",
                       !.sourceOFD = src,
                       !.replacedOFD = old,
                       !.removedCount = IF old = NoOFD THEN 0 ELSE 1]]
    /\ UNCHANGED <<ofdStatus, ofdAlive, captured, capturedFd,
                    capturedStatus, captureEpoch, lastCaptured, actedOFD,
                    actedSlotOFD, actedCaptureEpoch, actedSlotEpoch,
                    execVars>>
    /\ UNCHANGED <<epollVars, readinessVars, signalVars, waitVars,
                    topologyVars>>

FileTableDupExactBadFd(t) ==
    \* kernel/core/src/fs/file/file_table.rs:181-187
    \* duplicate_entry returns EBADF without changing the table if the source
    \* disappeared before the table lock was acquired (file_table.rs:181-187).
    /\ replacement[t].phase = "validated"
    /\ slots[replacement[t].sourceFd] = NoOFD
    /\ replacement' = [replacement EXCEPT ![t].phase = "done"]
    /\ UNCHANGED <<slots, slotFlags, slotEpoch, ofdStatus, ofdAlive, captured,
                    capturedFd, capturedStatus, captureEpoch, lastCaptured,
                    actedOFD, actedSlotOFD, actedCaptureEpoch, actedSlotEpoch,
                    closePending, execVars, fdFlagAudit, slotMapAudit>>
    /\ UNCHANGED <<epollVars, readinessVars, signalVars, waitVars,
                    topologyVars>>

DupReplacementCleanup(t) ==
    \* kernel/core/src/syscall/dup.rs:73-78
    \* kernel/core/src/fs/file/file_table.rs:297-302
    \* The replaced ClosedFile is dropped only after the table write guard leaves
    \* scope (dup.rs:73-78; file_table.rs:297-302).
    /\ replacement[t].phase = "cleanup"
    /\ ofdAlive' = IF closePending[t] = NoOFD
                    THEN ofdAlive
                    ELSE AliveAfterOneRelease(closePending[t])
    /\ closePending' = [closePending EXCEPT ![t] = NoOFD]
    /\ replacement' = [replacement EXCEPT ![t].phase = "done"]
    /\ UNCHANGED <<slots, slotFlags, slotEpoch, ofdStatus, captured,
                    capturedFd, capturedStatus, captureEpoch, lastCaptured,
                    actedOFD, actedSlotOFD, actedCaptureEpoch, actedSlotEpoch,
                    execVars, fdFlagAudit, slotMapAudit>>
    /\ UNCHANGED <<epollVars, readinessVars, signalVars, waitVars,
                    topologyVars>>

FileTableDupCeil(t, sourceFd, targetFd, cloexec) ==
    \* kernel/core/src/fs/file/file_table.rs:139-165
    \* kernel/core/src/syscall/fcntl.rs:43-50
    \* dup/F_DUPFD clone the source and install the lowest available slot while
    \* holding the table write lock (file_table.rs:139-165; fcntl.rs:43-50).
    \* After wait_other_threads_exit, t /= execOwner denotes the bounded
    \* external process that still owns the old CLONE_FILES table. It may run
    \* before or after unshare_files' one atomic read-lock/clone/install step.
    \* kernel/core/src/process/clone.rs:738-745
    \* kernel/core/src/process/namespace/unshare.rs:18-28
    /\ \/ execPhase = "idle"
       \/ /\ execPhase \in {"quiesced", "snapshotted"}
          /\ execOwner /= t
          /\ execExternalAudit.oldTableRetained
    /\ ThreadSyscallIdle(t)
    /\ slots[sourceFd] /= NoOFD
    /\ slots[targetFd] = NoOFD
    /\ \A fd \in FDs :
          (CASE targetFd = FD0 -> TRUE
             [] targetFd = FD1 -> fd /= FD0 \/ slots[fd] /= NoOFD
             [] OTHER -> fd = FD2 \/ slots[fd] /= NoOFD)
    /\ slots' = [slots EXCEPT ![targetFd] = slots[sourceFd]]
    /\ slotMapAudit' =
          [slotMapAudit EXCEPT ![targetFd] = slots[sourceFd]]
    /\ slotFlags' = [slotFlags EXCEPT ![targetFd] = cloexec]
    /\ slotEpoch' = [slotEpoch EXCEPT ![targetFd] = @ + 1]
    /\ fdFlagAudit' = EmptyFdFlagAudit
    /\ execExternalAudit' =
          IF execPhase = "quiesced"
          THEN [execExternalAudit EXCEPT !.beforeDup = TRUE]
          ELSE IF execPhase = "snapshotted"
               THEN [execExternalAudit EXCEPT !.afterDup = TRUE]
               ELSE execExternalAudit
    /\ UNCHANGED <<ofdStatus, ofdAlive, captured, capturedFd,
                    capturedStatus, captureEpoch, lastCaptured, actedOFD,
                    actedSlotOFD, actedCaptureEpoch, actedSlotEpoch,
                    closePending, replacement, sharedTable, execPhase,
                    execOwner, execPrivateSlots, execPrivateFlags,
                    execPrivateEpoch, execPrivateSlotMapAudit,
                    execSnapshotSlots, execSnapshotFlags>>
    /\ UNCHANGED <<epollVars, readinessVars, signalVars, waitVars,
                    topologyVars>>

FcntlSetFd(t, fd, cloexec) ==
    \* kernel/core/src/syscall/fcntl.rs:61-73
    \* kernel/core/src/fs/file/file_table.rs:389-395
    \* F_SETFD updates AtomicU8 flags in the selected FileTableEntry only
    \* (fcntl.rs:61-73; file_table.rs:389-395).
    /\ execPhase = "idle"
    /\ ThreadSyscallIdle(t)
    /\ slots[fd] /= NoOFD
    /\ LET peers == AliasPeers(fd)
           peer == IF peers = {} THEN NoFD ELSE CHOOSE p \in peers : TRUE
       IN
       /\ slotFlags' = [slotFlags EXCEPT ![fd] = cloexec]
       \* Record the untouched duplicate entry so the safety oracle detects a
       \* mistaken propagation of descriptor flags across a shared Arc.
       \* kernel/core/src/fs/file/file_table.rs:181-187,372-404
       /\ fdFlagAudit' =
             IF peer = NoFD
             THEN EmptyFdFlagAudit
             ELSE [active |-> TRUE,
                   target |-> fd,
                   peer |-> peer,
                   ofd |-> slots[fd],
                   requested |-> cloexec,
                   peerBefore |-> slotFlags[peer],
                   targetEpoch |-> slotEpoch[fd],
                   peerEpoch |-> slotEpoch[peer]]
    /\ UNCHANGED <<slots, slotEpoch, ofdStatus, ofdAlive, captured,
                    capturedFd, capturedStatus, captureEpoch, lastCaptured,
                    actedOFD, actedSlotOFD, actedCaptureEpoch, actedSlotEpoch,
                    closePending, replacement, execVars, slotMapAudit>>
    /\ UNCHANGED <<epollVars, readinessVars, signalVars, waitVars,
                    topologyVars>>

SysCloseRangeCloexec(t, first, last) ==
    \* The production loop holds one FileTable write guard across the entire
    \* inclusive interval. This action therefore updates all selected slots
    \* atomically; no close/reuse action can interleave between its iterations.
    \* kernel/core/src/syscall/close.rs:76-101
    \* The same syscall may execute in an external CLONE_FILES sharer around
    \* the atomic unshare cutover; after cutover it still locks only the old
    \* shared table represented by slots/slotFlags.
    \* kernel/core/src/process/clone.rs:738-745
    \* kernel/core/src/process/namespace/unshare.rs:18-28
    /\ \/ execPhase = "idle"
       \/ /\ execPhase \in {"quiesced", "snapshotted"}
          /\ execOwner /= t
          /\ execExternalAudit.oldTableRetained
    /\ ThreadSyscallIdle(t)
    /\ FdIndex(first) <= FdIndex(last)
    \* Missing slots are skipped by get_entry_mut; occupied selected entries
    \* receive their per-descriptor CLOEXEC bit under the same guard.
    \* kernel/core/src/syscall/close.rs:83-100
    /\ slotFlags' = [fd \in FDs |->
          IF fd \in FdRange(first, last) /\ slots[fd] /= NoOFD
          THEN TRUE
          ELSE slotFlags[fd]]
    /\ fdFlagAudit' = EmptyFdFlagAudit
    /\ execExternalAudit' =
          IF execPhase = "quiesced"
          THEN [execExternalAudit EXCEPT !.beforeCloexec = TRUE]
          ELSE IF execPhase = "snapshotted"
               THEN [execExternalAudit EXCEPT !.afterCloexec = TRUE]
               ELSE execExternalAudit
    /\ UNCHANGED <<slots, slotEpoch, ofdStatus, ofdAlive, captured,
                    capturedFd, capturedStatus, captureEpoch, lastCaptured,
                    actedOFD, actedSlotOFD, actedCaptureEpoch, actedSlotEpoch,
                    closePending, replacement, sharedTable, execPhase,
                    execOwner, execPrivateSlots, execPrivateFlags,
                    execPrivateEpoch, execPrivateSlotMapAudit,
                    execSnapshotSlots, execSnapshotFlags, slotMapAudit>>
    /\ UNCHANGED <<epollVars, readinessVars, signalVars, waitVars,
                    topologyVars>>

ExecveWaitOtherThreadsExit(t) ==
    \* kernel/core/src/process/execve.rs:161-164,202-225
    \* exec waits until sibling tasks have exited before file-table cutover
    \* (process/execve.rs:161-164,202-225).
    /\ execPhase = "idle"
    /\ ThreadsIdleForExec
    /\ execPhase' = "quiesced"
    /\ execOwner' = t
    \* The bounded environment chooses whether a distinct CLONE_FILES process
    \* still owns the old RwArc. No-external-sharer executions retain exact
    \* final-drop coverage; external-mutation hunts choose TRUE.
    \* kernel/core/src/process/clone.rs:738-745
    \* kernel/core/src/process/namespace/unshare.rs:18-28
    /\ execExternalAudit' \in
          {[execExternalAudit EXCEPT !.oldTableRetained = retained] :
              retained \in BOOLEAN}
    /\ UNCHANGED <<slots, slotFlags, slotEpoch, ofdStatus, ofdAlive, captured,
                    capturedFd, capturedStatus, captureEpoch, lastCaptured,
                    actedOFD, actedSlotOFD, actedCaptureEpoch, actedSlotEpoch,
                    closePending, replacement, sharedTable,
                    execPrivateSlots, execPrivateFlags, execPrivateEpoch,
                    execPrivateSlotMapAudit, execSnapshotSlots,
                    execSnapshotFlags,
                    fdFlagAudit, slotMapAudit>>
    /\ UNCHANGED <<epollVars, readinessVars, signalVars, waitVars,
                    topologyVars>>

ContextUnshareFiles(t) ==
    \* unshare_files holds the old table's read guard across FileTable::fork_from
    \* and installs the finished RwArc into both current-thread handles. This
    \* is one source-atomic cutover, with no partial slot visibility.
    \* kernel/core/src/process/namespace/unshare.rs:18-28
    \* kernel/core/src/fs/file/file_table.rs:117-121
    /\ execPhase = "quiesced"
    /\ execOwner = t
    /\ sharedTable' = FALSE
    /\ execPrivateSlots' = slots
    /\ execPrivateFlags' = slotFlags
    /\ execPrivateEpoch' = slotEpoch
    /\ execPrivateSlotMapAudit' = slotMapAudit
    /\ execSnapshotSlots' = slots
    /\ execSnapshotFlags' = slotFlags
    /\ execPhase' = "snapshotted"
    /\ UNCHANGED <<slots, slotFlags, slotEpoch, ofdStatus, ofdAlive, captured,
                    capturedFd, capturedStatus, captureEpoch, lastCaptured,
                    actedOFD, actedSlotOFD, actedCaptureEpoch, actedSlotEpoch,
                    closePending, replacement, execOwner, execExternalAudit,
                    fdFlagAudit, slotMapAudit>>
    /\ UNCHANGED <<epollVars, readinessVars, signalVars, waitVars,
                    topologyVars>>

FileTableCloseFilesOnExec(t) ==
    \* kernel/core/src/fs/file/file_table.rs:208-234
    \* kernel/core/src/process/execve.rs:381-386
    \* close_files_on_exec first identifies CLOEXEC entries and then removes
    \* exactly those entries from the unshared table (file_table.rs:208-234;
    \* process/execve.rs:381-386).
    /\ execPhase = "snapshotted"
    /\ execOwner = t
    /\ execPrivateSlots' = ExpectedExecSlots
    /\ execPrivateSlotMapAudit' = ExpectedExecSlots
    /\ execPrivateFlags' = ExpectedExecFlags
    /\ execPrivateEpoch' = [fd \in FDs |->
          IF execSnapshotFlags[fd] /\ execSnapshotSlots[fd] /= NoOFD
          THEN execPrivateEpoch[fd] + 1
          ELSE execPrivateEpoch[fd]]
    \* The returned ClosedFile vector is dropped after the write guard, so this
    \* same completion applies every corresponding final strong release.
    \* kernel/core/src/process/execve.rs:381-386
    /\ ofdAlive' = AliveAfterExecReleases
    /\ fdFlagAudit' = EmptyFdFlagAudit
    /\ execPhase' = "closed"
    /\ UNCHANGED <<slots, slotFlags, slotEpoch, slotMapAudit,
                    ofdStatus, captured, capturedFd,
                    capturedStatus, captureEpoch, lastCaptured, actedOFD,
                    actedSlotOFD, actedCaptureEpoch, actedSlotEpoch,
                    closePending, replacement, sharedTable,
                    execOwner, execSnapshotSlots, execSnapshotFlags,
                    execExternalAudit>>
    /\ UNCHANGED <<epollVars, readinessVars, signalVars, waitVars,
                    topologyVars>>

(***************************************************************************)
(* Scenario 2: epoll identity, queueing, and copyout commit.               *)
(***************************************************************************)

EpollControlCaptureTarget(t, ep, fd, command, mode) ==
    \* EpollFile::control captures an owned Arc for fd, drops the file-table
    \* borrow, then applies ADD/DEL/MOD to that identity (epoll/file.rs:65-84).
    /\ execPhase = "idle"
    /\ ThreadSyscallIdle(t)
    /\ ctl[t].phase = "idle"
    /\ command \in {"add", "del", "mod"}
    /\ mode \in TriggerModes
    /\ slots[fd] /= NoOFD
    \* The local Arc and slot generation are captured together. Later numeric
    \* reuse cannot retarget ADD/DEL/MOD.
    \* kernel/core/src/events/epoll/file.rs:65-84
    /\ ctl' = [ctl EXCEPT ![t] =
          [phase |-> "apply", command |-> command, epoll |-> ep, fd |-> fd,
           target |-> slots[fd], slotEpoch |-> slotEpoch[fd],
           trigger |-> mode, observed |-> FALSE]]
    /\ UNCHANGED <<fdVars, interest, readyQ, entryEnabled, triggerMode,
                    registered, keySlotEpoch, interestIdentity, delivery,
                    copyoutOk, deliveredKeys,
                    faultedUndelivered, lastDeliveredKey, reportedOFD,
                    epollWaiter, epollWake>>
    /\ UNCHANGED <<readinessVars, signalVars, waitVars, topologyVars>>

EpollAddInterest(t) ==
    \* ADD inserts the fully updated Entry while still holding the interest
    \* lock. Entry::update has already registered and polled it.
    \* kernel/core/src/events/epoll/file.rs:96-120
    /\ ctl[t].phase = "insert"
    /\ ctl[t].command = "add"
    /\ LET k == Key(ctl[t].epoll, ctl[t].fd, ctl[t].target) IN
       /\ k \notin interest
       /\ k \in registered
       \* The interest key is (numeric fd, captured weak OFD); its slot epoch
       \* records the reuse generation at control-time capture.
       \* kernel/core/src/events/epoll/file.rs:107-120
       \* kernel/core/src/events/epoll/entry.rs:46-67,76-100
       /\ interest' = interest \cup {k}
       \* This independent audit record is copied from control's captured Arc
       \* and generation at the publication boundary, rather than reconstructed
       \* from the mutable numeric slot later.
       \* kernel/core/src/events/epoll/file.rs:65-84,107-120
       /\ interestIdentity' = [interestIdentity EXCEPT ![k] =
             [active |-> TRUE, fd |-> ctl[t].fd, ofd |-> ctl[t].target,
              slotEpoch |-> ctl[t].slotEpoch]]
       /\ deliveredKeys' = deliveredKeys \ {k}
       /\ faultedUndelivered' = faultedUndelivered \ {k}
       /\ ctl' = [ctl EXCEPT ![t].phase = "push"]
    /\ UNCHANGED <<fdVars, readyQ, entryEnabled, triggerMode, registered,
                    keySlotEpoch, delivery, copyoutOk,
                    lastDeliveredKey, reportedOFD, epollWaiter, epollWake>>
    /\ UNCHANGED <<readinessVars, signalVars, waitVars, topologyVars>>

EpollModInterest(t) ==
    \* kernel/core/src/events/epoll/file.rs:147-176
    \* kernel/core/src/events/epoll/entry.rs:155-166
    \* MOD resolves the same composite key under the interest lock before its
    \* following Entry::update call (epoll/file.rs:147-176).
    /\ ctl[t].phase = "apply"
    /\ ctl[t].command = "mod"
    /\ LET k == Key(ctl[t].epoll, ctl[t].fd, ctl[t].target) IN
       /\ k \in interest
       /\ ctl' = [ctl EXCEPT ![t].phase = "poll"]
    /\ UNCHANGED <<fdVars, interest, readyQ, entryEnabled, triggerMode,
                    registered, keySlotEpoch, interestIdentity, delivery,
                    copyoutOk,
                    deliveredKeys, faultedUndelivered, lastDeliveredKey,
                    reportedOFD, epollWaiter, epollWake>>
    /\ UNCHANGED <<readinessVars, signalVars, waitVars, topologyVars>>

EpollDelInterest(t) ==
    \* kernel/core/src/events/epoll/file.rs:130-144,340-343
    \* kernel/core/src/events/epoll/entry.rs:168-176
    \* DEL removes only the captured (fd, weak OFD) key; shutdown disables its
    \* observer but queued Weak tokens are lazily discarded (epoll/file.rs:130-144;
    \* epoll/entry.rs:168-176; epoll/file.rs:340-343).
    /\ ctl[t].phase = "apply"
    /\ ctl[t].command = "del"
    /\ LET k == Key(ctl[t].epoll, ctl[t].fd, ctl[t].target) IN
       /\ k \in interest
       /\ interest' = interest \ {k}
       /\ interestIdentity' =
             [interestIdentity EXCEPT ![k] = EmptyInterestIdentity]
       /\ registered' = registered \ {k}
       /\ entryEnabled' = [entryEnabled EXCEPT ![k] = FALSE]
       /\ pollerBindings' = {b \in pollerBindings : b.key /= k}
       \* control's owned target Arc is released on successful DEL return.
       \* kernel/core/src/events/epoll/file.rs:65-84,130-144
       /\ ofdAlive' = AliveAfterOneRelease(ctl[t].target)
       /\ ctl' = [ctl EXCEPT ![t] = EmptyCtl]
    /\ UNCHANGED <<slots, slotFlags, slotEpoch, ofdStatus, captured,
                    capturedFd, capturedStatus, captureEpoch, lastCaptured,
                    actedOFD, actedSlotOFD, actedCaptureEpoch, actedSlotEpoch,
                    closePending, replacement, execVars,
                    fdFlagAudit, slotMapAudit, readyQ, triggerMode, keySlotEpoch,
                    delivery, copyoutOk,
                    deliveredKeys, faultedUndelivered, lastDeliveredKey,
                    reportedOFD, epollWaiter, epollWake>>
    /\ UNCHANGED <<readinessVars, threadPending, processPending, signalMask,
                    signalNotify, signalNotifyKeys, signalNotifyWaiters,
                    threadSignalEnqueueEpoch, threadSignalNotifyEpoch,
                    processSignalEnqueueEpoch, processSignalNotifyEpoch,
                    waitVars, topologyVars>>

EpollControlError(t) ==
    \* kernel/core/src/events/epoll/file.rs:100-105,140-142,160-163
    \* EEXIST/ENOENT terminate control without mutating the interest list
    \* (epoll/file.rs:100-105,140-142,160-163).
    /\ ctl[t].phase = "apply"
    /\ LET k == Key(ctl[t].epoll, ctl[t].fd, ctl[t].target) IN
          \/ (ctl[t].command = "add" /\ k \in interest)
          \/ (ctl[t].command \in {"del", "mod"} /\ k \notin interest)
    \* Every early EEXIST/ENOENT return drops control's captured Arc.
    \* kernel/core/src/events/epoll/file.rs:65-84,100-105,140-142,160-163
    /\ ofdAlive' = AliveAfterOneRelease(ctl[t].target)
    /\ ctl' = [ctl EXCEPT ![t] = EmptyCtl]
    /\ UNCHANGED <<slots, slotFlags, slotEpoch, ofdStatus, captured,
                    capturedFd, capturedStatus, captureEpoch, lastCaptured,
                    actedOFD, actedSlotOFD, actedCaptureEpoch, actedSlotEpoch,
                    closePending, replacement, execVars,
                    fdFlagAudit, slotMapAudit, interest, readyQ, entryEnabled, triggerMode,
                    registered, keySlotEpoch, interestIdentity, delivery,
                    copyoutOk, deliveredKeys,
                    faultedUndelivered, lastDeliveredKey, reportedOFD,
                    epollWaiter, epollWake>>
    /\ UNCHANGED <<readinessVars, signalVars, waitVars, topologyVars>>

EntryUpdatePoll(t) ==
    \* Entry::update stores masks, enables the observer, registers before the
    \* live check, and evaluates readiness as the current thread
    \* (epoll/entry.rs:155-166; signalfd.rs:205-215).
    /\ LET k == Key(ctl[t].epoll, ctl[t].fd, ctl[t].target)
           isAdd == ctl[t].command = "add"
       IN
       \* ADD performs update before insertion; MOD first resolves the existing
       \* entry and then performs the same update call.
       \* kernel/core/src/events/epoll/file.rs:96-120,147-176
       /\ \/ /\ isAdd
                 /\ ctl[t].phase = "apply"
                 /\ k \notin interest
          \/ /\ ~isAdd
                 /\ ctl[t].command = "mod"
                 /\ ctl[t].phase = "poll"
                 /\ k \in interest
       \* PollHandle registration and the current-thread signalfd binding are
       \* complete before the live readiness result is returned.
       \* kernel/core/src/events/epoll/entry.rs:155-166
       \* kernel/core/src/syscall/signalfd.rs:205-215
       /\ entryEnabled' = [entryEnabled EXCEPT ![k] = TRUE]
       /\ triggerMode' = [triggerMode EXCEPT ![k] = ctl[t].trigger]
       /\ keySlotEpoch' =
             IF isAdd
             THEN [keySlotEpoch EXCEPT ![k] = ctl[t].slotEpoch]
             ELSE keySlotEpoch
       /\ faultedUndelivered' = faultedUndelivered \ {k}
       /\ registered' = registered \cup {k}
       /\ pollerBindings' =
             IF k.ofd = SignalOFD
             THEN pollerBindings \cup {Binding(k, t)}
             ELSE pollerBindings
       /\ ctl' = [ctl EXCEPT
                        ![t].phase = IF isAdd THEN "insert" ELSE "push",
                              ![t].observed = OFDReady(k.ofd, t)]
       /\ readyEpoch' =
             IF OFDReady(k.ofd, t)
             THEN [readyEpoch EXCEPT ![k] = sourceEpoch[k.ofd]]
             ELSE readyEpoch
       /\ consumerReadyEpoch' = [b \in Bindings |->
             IF b.key = k /\ k.ofd = SignalOFD /\ b.thread = t
                /\ OFDReady(SignalOFD, t)
             THEN sourceEpoch[SignalOFD]
             ELSE consumerReadyEpoch[b]]
    /\ UNCHANGED <<fdVars, interest, readyQ, delivery, copyoutOk,
                    deliveredKeys, interestIdentity,
                    lastDeliveredKey, reportedOFD, epollWaiter, epollWake>>
    /\ UNCHANGED <<sourceReady, sourceEpoch, callbackEpoch, callbackActor,
                    queuedEpoch, deliveredEpoch,
                    cacheState, directRegistered, notified, observedReady,
                    observedEpoch, timerTicks, eventCounter, pollLocal,
                    producerPhase, eventNotifyKeys, eventNotifyWaiters,
                    eventNotifyCounter, signalMask, threadPending,
                    processPending,
                    signalNotify, signalNotifyKeys, signalNotifyWaiters,
                    threadSignalEnqueueEpoch, threadSignalNotifyEpoch,
                    processSignalEnqueueEpoch, processSignalNotifyEpoch,
                    waitVars, topologyVars>>

EpollControlPushReady(t) ==
    \* add_interest/mod_interest enqueue the entry after dropping the interest
    \* lock when Entry::update found readiness (epoll/file.rs:110-125,166-176).
    /\ ctl[t].phase = "push"
    /\ LET k == Key(ctl[t].epoll, ctl[t].fd, ctl[t].target) IN
       /\ readyQ' = IF ctl[t].observed /\ k \in interest /\ entryEnabled[k]
                     THEN readyQ \cup {k}
                     ELSE readyQ
       \* The direct post-update push carries the epoch observed by
       \* Entry::update; it is not an Observer callback.
       \* kernel/core/src/events/epoll/file.rs:110-125,166-176
       /\ queuedEpoch' = IF ctl[t].observed /\ k \in interest /\ entryEnabled[k]
                          THEN [queuedEpoch EXCEPT ![k] = readyEpoch[k]]
                          ELSE queuedEpoch
       /\ epollReadyEpoch' =
             IF ctl[t].observed /\ k \in interest /\ entryEnabled[k]
             THEN [epollReadyEpoch EXCEPT ![k.epoll] = @ + 1]
             ELSE epollReadyEpoch
       /\ epollWake' = IF ctl[t].observed
                        THEN [epollWake EXCEPT ![k.epoll] = TRUE]
                        ELSE epollWake
       \* Returning from ADD/MOD releases control's owned target Arc after the
       \* optional ready push completes.
       \* kernel/core/src/events/epoll/file.rs:65-84,122-127,173-178
       /\ ofdAlive' = AliveAfterOneRelease(ctl[t].target)
       /\ ctl' = [ctl EXCEPT ![t] = EmptyCtl]
    /\ UNCHANGED <<slots, slotFlags, slotEpoch, ofdStatus, captured,
                    capturedFd, capturedStatus, captureEpoch, lastCaptured,
                    actedOFD, actedSlotOFD, actedCaptureEpoch, actedSlotEpoch,
                    closePending, replacement, execVars,
                    fdFlagAudit, slotMapAudit, interest, entryEnabled,
                    triggerMode, registered,
                    keySlotEpoch, interestIdentity, delivery, copyoutOk,
                    deliveredKeys,
                    faultedUndelivered,
                    lastDeliveredKey, reportedOFD, epollWaiter>>
    /\ UNCHANGED <<sourceReady, sourceEpoch, readyEpoch, callbackEpoch,
                    callbackActor, deliveredEpoch, consumerReadyEpoch,
                    cacheState, directRegistered, notified, observedReady,
                    observedEpoch, timerTicks, eventCounter, pollLocal,
                    producerPhase, eventNotifyKeys, eventNotifyWaiters,
                    eventNotifyCounter, signalVars, waitVars, epollGraph,
                    heldLocks, lockOwner, callbackStage,
                    callbackKey, nestedRequiredEpoch, nestedDeliveredEpoch>>

ReadySetPush(actor, k) ==
    \* Observer::on_events is called synchronously by SyncSubject only after a
    \* producer's Pollee::notify created callbackEpoch[k].
    \* kernel/core/src/events/subject.rs:126-149
    \* kernel/core/src/events/epoll/entry.rs:280-283
    /\ callbackEpoch[k] > 0
    /\ callbackActor[k] = actor
    /\ callbackStage[actor] = "locked"
    /\ callbackKey[actor] = k
    /\ ReadyLock(k.epoll) \in heldLocks[actor]
    \* The enabled check happened before ReadySetPushAcquire took the entries
    \* lock. Concurrent shutdown after that check does not rewind the callback.
    \* kernel/core/src/events/epoll/entry.rs:307-325
    \* ReadySet::push deduplicates the token but still advances the current
    \* notification epoch and wakes the epoll pollee.
    \* kernel/core/src/events/epoll/entry.rs:307-330
    /\ readyQ' = readyQ \cup {k}
    /\ notified' = notified \cup {k}
    /\ queuedEpoch' = [queuedEpoch EXCEPT ![k] = callbackEpoch[k]]
    /\ callbackEpoch' = [callbackEpoch EXCEPT ![k] = 0]
    /\ callbackActor' = [callbackActor EXCEPT ![k] = NoThread]
    /\ epollWake' = [epollWake EXCEPT ![k.epoll] = TRUE]
    /\ callbackStage' = [callbackStage EXCEPT ![actor] = "queued"]
    /\ epollReadyEpoch' = [epollReadyEpoch EXCEPT ![k.epoll] = @ + 1]
    /\ UNCHANGED <<fdVars, interest, entryEnabled, triggerMode, registered,
                    keySlotEpoch, interestIdentity, ctl, delivery, copyoutOk,
                    deliveredKeys,
                    faultedUndelivered, lastDeliveredKey, reportedOFD,
                    epollWaiter>>
    /\ UNCHANGED <<sourceReady, sourceEpoch, readyEpoch, deliveredEpoch,
                    consumerReadyEpoch, cacheState, directRegistered,
                    observedReady, observedEpoch, timerTicks, eventCounter,
                    pollLocal, producerPhase, eventNotifyKeys,
                    eventNotifyWaiters, eventNotifyCounter, signalVars,
                    waitVars,
                    epollGraph, heldLocks, lockOwner,
                    callbackKey, nestedRequiredEpoch, nestedDeliveredEpoch>>

ReadySetPushSuppressed(actor, k) ==
    \* A notification already selected the observer, but shutdown or disable
    \* can make ReadySet::push return before taking the entries lock.
    \* kernel/core/src/events/epoll/entry.rs:247-271,307-318
    /\ callbackEpoch[k] > 0
    /\ callbackActor[k] = actor
    /\ callbackStage[actor] = "idle"
    \* Absence from interest alone is not shutdown during ADD's real
    \* update-before-insert interval; registration/enablement is authoritative.
    \* kernel/core/src/events/epoll/file.rs:96-120
    /\ (k \notin registered \/ ~entryEnabled[k])
    /\ callbackEpoch' = [callbackEpoch EXCEPT ![k] = 0]
    /\ callbackActor' = [callbackActor EXCEPT ![k] = NoThread]
    \* A synchronous eventfd callback obligation is complete only when the
    \* selected callback has run or this pre-lock enabled check suppresses it.
    \* kernel/core/src/syscall/eventfd.rs:124-159
    \* kernel/core/src/events/epoll/entry.rs:307-318
    /\ eventNotifyKeys' = eventNotifyKeys \ {k}
    /\ signalNotifyKeys' =
          IF signalNotify[actor].phase = "callbacks"
          THEN [signalNotifyKeys EXCEPT ![actor] = @ \ {k}]
          ELSE signalNotifyKeys
    /\ UNCHANGED <<fdVars, epollVars, sourceReady, sourceEpoch, readyEpoch,
                    queuedEpoch, deliveredEpoch, consumerReadyEpoch,
                    cacheState, directRegistered, notified, observedReady,
                    observedEpoch, timerTicks, eventCounter, pollLocal,
                    producerPhase, eventNotifyWaiters, eventNotifyCounter,
                    signalMask, threadPending, processPending, pollerBindings,
                    signalNotify, signalNotifyWaiters,
                    threadSignalEnqueueEpoch, threadSignalNotifyEpoch,
                    processSignalEnqueueEpoch, processSignalNotifyEpoch,
                    waitVars, topologyVars>>

ReadySetPopDeleted(t, k) ==
    \* kernel/core/src/events/epoll/entry.rs:367-390
    \* A queued Weak token whose Entry was deleted is discarded during the
    \* ready-list scan (epoll/entry.rs:372-390; epoll/file.rs:221-233).
    /\ delivery[t].stage = "idle"
    /\ k \in readyQ
    /\ k \notin registered
    /\ readyQ' = readyQ \ {k}
    /\ epollWake' = [epollWake EXCEPT ![k.epoll] =
          \E q \in readyQ \ {k} : q.epoll = k.epoll]
    /\ UNCHANGED <<fdVars, interest, entryEnabled, triggerMode, registered,
                    keySlotEpoch, interestIdentity, ctl, delivery, copyoutOk,
                    deliveredKeys,
                    faultedUndelivered, lastDeliveredKey, reportedOFD,
                    epollWaiter>>
    /\ UNCHANGED <<readinessVars, signalVars, waitVars, topologyVars>>

ReadySetPop(t, k) ==
    \* kernel/core/src/events/epoll/entry.rs:367-397
    \* The iterator removes one token and resets its ready bit before Entry::poll
    \* (epoll/entry.rs:367-397; epoll/file.rs:210-226).
    /\ delivery[t].stage = "idle"
    /\ k \in readyQ
    \* A registered Entry is live even during ADD's update-before-insert
    \* interval because epoll_ctl still owns its Arc locally.
    \* kernel/core/src/events/epoll/file.rs:96-120
    /\ k \in registered
    /\ readyQ' = readyQ \ {k}
    /\ epollWake' = [epollWake EXCEPT ![k.epoll] =
          \E q \in readyQ \ {k} : q.epoll = k.epoll]
    /\ delivery' = [delivery EXCEPT ![t] =
          [stage |-> "popped", key |-> k, hadEvent |-> FALSE,
           epoch |-> queuedEpoch[k]]]
    /\ copyoutOk' = [copyoutOk EXCEPT ![t] = "none"]
    /\ UNCHANGED <<fdVars, interest, entryEnabled, triggerMode, registered,
                    keySlotEpoch, interestIdentity, ctl, deliveredKeys,
                    faultedUndelivered,
                    lastDeliveredKey,
                    reportedOFD, epollWaiter>>
    /\ UNCHANGED <<readinessVars, signalVars, waitVars, topologyVars>>

EntryPollDeadFile(t) ==
    \* kernel/core/src/events/epoll/entry.rs:103-117
    \* kernel/core/src/events/epoll/file.rs:225-233
    \* Weak::upgrade failure makes Entry::poll return None; wait then tries to
    \* remove the exact dead interest (epoll/entry.rs:103-117;
    \* epoll/file.rs:225-233).
    /\ delivery[t].stage = "popped"
    /\ LET k == delivery[t].key IN
       /\ ~ofdAlive[k.ofd]
       /\ interest' = interest \ {k}
       /\ interestIdentity' =
             [interestIdentity EXCEPT ![k] = EmptyInterestIdentity]
       /\ registered' = registered \ {k}
       /\ entryEnabled' = [entryEnabled EXCEPT ![k] = FALSE]
       /\ pollerBindings' = {b \in pollerBindings : b.key /= k}
       /\ delivery' = [delivery EXCEPT ![t] = EmptyDelivery]
    /\ UNCHANGED <<fdVars, readyQ, triggerMode, keySlotEpoch, ctl, copyoutOk,
                    deliveredKeys, faultedUndelivered, lastDeliveredKey,
                    reportedOFD, epollWaiter, epollWake>>
    /\ UNCHANGED <<readinessVars, signalMask, threadPending, processPending,
                    signalNotify, signalNotifyKeys, signalNotifyWaiters,
                    threadSignalEnqueueEpoch, threadSignalNotifyEpoch,
                    processSignalEnqueueEpoch, processSignalNotifyEpoch,
                    waitVars, topologyVars>>

EntryPollDisabled(t) ==
    \* Entry::poll upgrades the weak file at line 117 before it can acquire
    \* Inner and test enabled at lines 118-124.
    \* kernel/core/src/events/epoll/entry.rs:103-124
    \* Disabled one-shot entries produce no event and are not requeued
    \* (epoll/entry.rs:118-124).
    /\ delivery[t].stage = "popped"
    /\ ofdAlive[delivery[t].key.ofd]
    /\ entryEnabled[delivery[t].key] = FALSE
    /\ delivery' = [delivery EXCEPT ![t] = EmptyDelivery]
    /\ UNCHANGED <<fdVars, interest, readyQ, entryEnabled, triggerMode,
                    registered, keySlotEpoch, interestIdentity, ctl, copyoutOk,
                    deliveredKeys,
                    faultedUndelivered, lastDeliveredKey, reportedOFD,
                    epollWaiter, epollWake>>
    /\ UNCHANGED <<readinessVars, signalVars, waitVars, topologyVars>>

EntryPollPrepare(t) ==
    \* Entry::poll checks the live OFD, decides LT requeue, and disables one-shot
    \* before syscall copyout (epoll/entry.rs:116-149;
    \* epoll/file.rs:225-244; syscall/epoll.rs:145-154).
    /\ delivery[t].stage = "popped"
    /\ LET k == delivery[t].key
           has == OFDReady(k.ofd, t)
       IN
       /\ ofdAlive[k.ofd]
       /\ entryEnabled[k]
       \* Preserve the queue epoch through live polling and copyout. A later
       \* source transition cannot be discharged by this preparation.
       \* kernel/core/src/events/epoll/entry.rs:116-149
       /\ delivery' = [delivery EXCEPT ![t] =
             [stage |-> "prepared", key |-> k, hadEvent |-> has,
              epoch |-> delivery[t].epoch]]
       \* Level-triggered readiness is immediately requeued for the same
       \* epoch while the live predicate remains true.
       \* kernel/core/src/events/epoll/entry.rs:136-142
       /\ readyQ' = IF has /\ triggerMode[k] = "LT"
                     THEN readyQ \cup {k}
                     ELSE readyQ
       /\ queuedEpoch' = IF has /\ triggerMode[k] = "LT"
                          THEN [queuedEpoch EXCEPT ![k] = delivery[t].epoch]
                          ELSE queuedEpoch
       \* One-shot disable happens before userspace copyout.
       \* kernel/core/src/events/epoll/entry.rs:143-147
       /\ entryEnabled' =
             IF has /\ triggerMode[k] = "ONESHOT"
             THEN [entryEnabled EXCEPT ![k] = FALSE]
             ELSE entryEnabled
       /\ epollWake' =
             IF has /\ triggerMode[k] = "LT"
             THEN [epollWake EXCEPT ![k.epoll] = TRUE]
             ELSE epollWake
    /\ UNCHANGED <<fdVars, interest, triggerMode, registered, ctl, copyoutOk,
                    keySlotEpoch, interestIdentity, deliveredKeys,
                    faultedUndelivered,
                    lastDeliveredKey,
                    reportedOFD, epollWaiter>>
    /\ UNCHANGED <<sourceReady, sourceEpoch, readyEpoch, callbackEpoch,
                    callbackActor, deliveredEpoch, consumerReadyEpoch,
                    cacheState, directRegistered, notified, observedReady,
                    observedEpoch, timerTicks, eventCounter, pollLocal,
                    producerPhase, eventNotifyKeys, eventNotifyWaiters,
                    eventNotifyCounter, signalVars, waitVars, topologyVars>>

EpollDiscardEmptyPreparation(t) ==
    \* kernel/core/src/events/epoll/file.rs:236-245
    \* A live entry with no current event contributes nothing to the userspace
    \* vector and the scan continues (epoll/file.rs:236-245).
    /\ delivery[t].stage = "prepared"
    /\ ~delivery[t].hadEvent
    /\ delivery' = [delivery EXCEPT ![t] = EmptyDelivery]
    /\ UNCHANGED <<fdVars, interest, readyQ, entryEnabled, triggerMode,
                    registered, keySlotEpoch, interestIdentity, ctl, copyoutOk,
                    deliveredKeys,
                    faultedUndelivered, lastDeliveredKey, reportedOFD,
                    epollWaiter, epollWake>>
    /\ UNCHANGED <<readinessVars, signalVars, waitVars, topologyVars>>

DoEpollPwait2CopyoutSuccess(t) ==
    \* Successful write_val calls commit the prepared event to userspace
    \* (syscall/epoll.rs:145-154).
    /\ delivery[t].stage = "prepared"
    /\ delivery[t].hadEvent
    /\ LET k == delivery[t].key IN
       /\ deliveredKeys' = deliveredKeys \cup {k}
       /\ faultedUndelivered' = faultedUndelivered \ {k}
       /\ lastDeliveredKey' = [lastDeliveredKey EXCEPT ![t] = k]
       /\ reportedOFD' = [reportedOFD EXCEPT ![t] = k.ofd]
       \* Commit only the epoch that was prepared before write_val.
       \* kernel/core/src/syscall/epoll.rs:145-154
       /\ deliveredEpoch' =
             [deliveredEpoch EXCEPT ![k] = delivery[t].epoch]
       /\ copyoutOk' = [copyoutOk EXCEPT ![t] = "success"]
       /\ delivery' = [delivery EXCEPT ![t] = EmptyDelivery]
    /\ UNCHANGED <<fdVars, interest, readyQ, entryEnabled, triggerMode,
                    registered, keySlotEpoch, interestIdentity, ctl,
                    epollWaiter, epollWake>>
    /\ UNCHANGED <<sourceReady, sourceEpoch, readyEpoch, callbackEpoch,
                    callbackActor, queuedEpoch, consumerReadyEpoch,
                    cacheState, directRegistered, notified, observedReady,
                    observedEpoch, timerTicks, eventCounter, pollLocal,
                    producerPhase, eventNotifyKeys, eventNotifyWaiters,
                    eventNotifyCounter, signalVars, waitVars, topologyVars>>

DoEpollPwait2CopyoutFault(t) ==
    \* kernel/core/src/syscall/epoll.rs:145-152
    \* write_val failure returns after Entry::poll already popped ET state or
    \* disabled one-shot; the current code has no rollback path
    \* (syscall/epoll.rs:145-152; epoll/entry.rs:136-147).
    /\ delivery[t].stage = "prepared"
    /\ delivery[t].hadEvent
    /\ LET k == delivery[t].key IN
       /\ faultedUndelivered' = faultedUndelivered \cup {k}
       /\ copyoutOk' = [copyoutOk EXCEPT ![t] = "fault"]
       /\ delivery' = [delivery EXCEPT ![t] = EmptyDelivery]
    /\ UNCHANGED <<fdVars, interest, readyQ, entryEnabled, triggerMode,
                    registered, keySlotEpoch, interestIdentity, ctl,
                    deliveredKeys,
                    lastDeliveredKey,
                    reportedOFD, epollWaiter, epollWake>>
    /\ UNCHANGED <<readinessVars, signalVars, waitVars, topologyVars>>

(***************************************************************************)
(* Scenario 3: Pollee cache and timerfd/eventfd producer transitions.      *)
(***************************************************************************)

PolleePollWithRegister(t, o) ==
    \* poll_with registers before its Acquire load of PolleeInner.state.
    \* kernel/core/src/process/signal/poll.rs:90-107,154-165
    /\ pollLocal[t].phase = "idle"
    /\ ThreadSyscallIdle(t)
    /\ ofdAlive[o]
    /\ directRegistered' = directRegistered \cup {PollRegistration(t, o)}
    /\ pollLocal' = [pollLocal EXCEPT ![t] =
          [phase |-> "load", ofd |-> o, loaded |-> "unset",
           observed |-> FALSE]]
    /\ UNCHANGED <<fdVars, epollVars, sourceReady, sourceEpoch, readyEpoch,
                    callbackEpoch, callbackActor, queuedEpoch,
                    deliveredEpoch, consumerReadyEpoch, cacheState, notified,
                    observedReady, observedEpoch, timerTicks, eventCounter,
                    producerPhase, eventNotifyKeys, eventNotifyWaiters,
                    eventNotifyCounter, signalVars, waitVars, topologyVars>>

PolleePollWithLoad(t) ==
    \* The Acquire load is a separate semantic step. Both modeled checkers may
    \* therefore load INV_STATE before either stores its Task pointer.
    \* kernel/core/src/process/signal/poll.rs:106-115
    /\ pollLocal[t].phase = "load"
    /\ LET o == pollLocal[t].ofd IN
       /\ pollLocal' = [pollLocal EXCEPT ![t].phase = "loaded",
                                         ![t].loaded = cacheState[o]]
    /\ UNCHANGED <<fdVars, epollVars, sourceReady, sourceEpoch, readyEpoch,
                    callbackEpoch, callbackActor, queuedEpoch,
                    deliveredEpoch, consumerReadyEpoch, cacheState,
                    directRegistered, notified, observedReady, observedEpoch,
                    timerTicks, eventCounter, producerPhase, eventNotifyKeys,
                    eventNotifyWaiters, eventNotifyCounter, signalVars,
                    waitVars, topologyVars>>

PolleePollWithCached(t) ==
    \* The cached branch uses the value already returned by the Acquire load,
    \* not a second read of state.
    \* kernel/core/src/process/signal/poll.rs:106-110
    /\ pollLocal[t].phase = "loaded"
    /\ pollLocal[t].loaded \in {"ready", "not_ready"}
    /\ LET o == pollLocal[t].ofd
           seen == pollLocal[t].loaded = "ready"
       IN
       /\ pollLocal' = [pollLocal EXCEPT ![t].phase = "done",
                                         ![t].observed = seen]
       /\ observedReady' = IF seen
                            THEN observedReady \cup {PollRegistration(t, o)}
                            ELSE observedReady
       /\ observedEpoch' = IF seen
                            THEN [observedEpoch EXCEPT
                                   ![PollRegistration(t, o)] = sourceEpoch[o]]
                            ELSE observedEpoch
    /\ UNCHANGED <<fdVars, epollVars, sourceReady, sourceEpoch, readyEpoch,
                    callbackEpoch, callbackActor, queuedEpoch,
                    deliveredEpoch, consumerReadyEpoch, cacheState,
                    directRegistered, notified, timerTicks, eventCounter,
                    producerPhase, eventNotifyKeys, eventNotifyWaiters,
                    eventNotifyCounter, signalVars, waitVars, topologyVars>>

PolleePollWithBeginCheck(t) ==
    \* A checker that loaded INV_STATE swaps in its own Task pointer. A second
    \* checker that also loaded INV_STATE may overwrite the first pointer.
    \* kernel/core/src/process/signal/poll.rs:117-136
    /\ pollLocal[t].phase = "loaded"
    /\ pollLocal[t].loaded = "invalid"
    /\ cacheState' = [cacheState EXCEPT ![pollLocal[t].ofd] = t]
    /\ pollLocal' = [pollLocal EXCEPT ![t].phase = "check"]
    /\ UNCHANGED <<fdVars, epollVars, sourceReady, sourceEpoch, readyEpoch,
                    callbackEpoch, callbackActor, queuedEpoch,
                    deliveredEpoch, consumerReadyEpoch, directRegistered,
                    notified, observedReady, observedEpoch, timerTicks,
                    eventCounter, producerPhase, eventNotifyKeys,
                    eventNotifyWaiters, eventNotifyCounter, signalVars, waitVars,
                    topologyVars>>

PolleePollWithCheck(t) ==
    \* The source-specific closure runs after registration and records the live
    \* readiness result.
    \* kernel/core/src/process/signal/poll.rs:135-136
    /\ pollLocal[t].phase = "check"
    /\ LET o == pollLocal[t].ofd IN
       /\ pollLocal' = [pollLocal EXCEPT ![t].phase = "cache",
                                         ![t].observed = sourceReady[o]]
    /\ UNCHANGED <<fdVars, epollVars, sourceReady, sourceEpoch, readyEpoch,
                    callbackEpoch, callbackActor, queuedEpoch,
                    deliveredEpoch, consumerReadyEpoch, cacheState,
                    directRegistered, notified, observedReady, observedEpoch,
                    timerTicks, eventCounter, producerPhase, eventNotifyKeys,
                    eventNotifyWaiters, eventNotifyCounter, signalVars,
                    waitVars, topologyVars>>

PolleePollWithCache(t) ==
    \* compare_exchange caches only if state still contains this checker's
    \* Task pointer; overwrite or invalidation makes the CAS fail.
    \* kernel/core/src/process/signal/poll.rs:138-151
    /\ pollLocal[t].phase = "cache"
    /\ LET o == pollLocal[t].ofd
           seen == pollLocal[t].observed
       IN
       /\ cacheState' =
             IF cacheState[o] = t
             THEN [cacheState EXCEPT ![o] = IF seen THEN "ready" ELSE "not_ready"]
             ELSE cacheState
       /\ observedReady' = IF seen
                            THEN observedReady \cup {PollRegistration(t, o)}
                            ELSE observedReady
       /\ observedEpoch' = IF seen
                            THEN [observedEpoch EXCEPT
                                   ![PollRegistration(t, o)] = sourceEpoch[o]]
                            ELSE observedEpoch
       /\ pollLocal' = [pollLocal EXCEPT ![t].phase = "done"]
    /\ UNCHANGED <<fdVars, epollVars, sourceReady, sourceEpoch, readyEpoch,
                    callbackEpoch, callbackActor, queuedEpoch,
                    deliveredEpoch, consumerReadyEpoch, directRegistered,
                    notified, timerTicks, eventCounter, producerPhase,
                    eventNotifyKeys, eventNotifyWaiters, eventNotifyCounter,
                    signalVars, waitVars, topologyVars>>

PolleePollWithConcurrentCheck(t) ==
    \* A loaded task pointer selects the direct-check branch. The loaded owner
    \* is retained even if state changes before this branch executes.
    \* kernel/core/src/process/signal/poll.rs:112-115
    /\ pollLocal[t].phase = "loaded"
    /\ LET o == pollLocal[t].ofd IN
       /\ pollLocal[t].loaded \in Threads
       /\ pollLocal' = [pollLocal EXCEPT ![t].phase = "done",
                                         ![t].observed = sourceReady[o]]
       /\ observedReady' = IF sourceReady[o]
                            THEN observedReady \cup {PollRegistration(t, o)}
                            ELSE observedReady
       /\ observedEpoch' = IF sourceReady[o]
                            THEN [observedEpoch EXCEPT
                                   ![PollRegistration(t, o)] = sourceEpoch[o]]
                            ELSE observedEpoch
    /\ UNCHANGED <<fdVars, epollVars, sourceReady, sourceEpoch, readyEpoch,
                    callbackEpoch, callbackActor, queuedEpoch,
                    deliveredEpoch, consumerReadyEpoch, cacheState,
                    directRegistered, notified, timerTicks, eventCounter,
                    producerPhase, eventNotifyKeys, eventNotifyWaiters,
                    eventNotifyCounter, signalVars, waitVars, topologyVars>>

PolleePollWithFinish(t) ==
    \* Returning from poll releases the caller's temporary OFD reference.
    \* kernel/core/src/process/signal/poll.rs:150-152
    \* kernel/core/src/fs/file/file_table.rs:335-337
    /\ pollLocal[t].phase = "done"
    /\ ofdAlive' = AliveAfterOneRelease(pollLocal[t].ofd)
    /\ pollLocal' = [pollLocal EXCEPT ![t] = EmptyPollLocal]
    /\ UNCHANGED <<slots, slotFlags, slotEpoch, ofdStatus, captured,
                    capturedFd, capturedStatus, captureEpoch, lastCaptured,
                    actedOFD, actedSlotOFD, actedCaptureEpoch, actedSlotEpoch,
                    closePending, replacement, execVars,
                    fdFlagAudit, slotMapAudit,
                    epollVars, sourceReady, sourceEpoch, readyEpoch,
                    callbackEpoch, callbackActor, queuedEpoch,
                    deliveredEpoch, consumerReadyEpoch, cacheState,
                    directRegistered, notified, observedReady, observedEpoch,
                    timerTicks, eventCounter, producerPhase, eventNotifyKeys,
                    eventNotifyWaiters, eventNotifyCounter, signalVars,
                    waitVars, topologyVars>>

TimerfdExpired(t) ==
    \* The timer callback increments ticks before calling Pollee::notify
    \* (time/timerfd.rs:98-105).
    /\ producerPhase[t] = "idle"
    /\ timerTicks < MaxTimerTicks
    \* ticks becomes readable before Pollee::notify. Create a fresh source and
    \* per-key obligation epoch at that production boundary.
    \* kernel/core/src/time/timerfd.rs:98-105
    /\ timerTicks' = timerTicks + 1
    /\ sourceReady' = [sourceReady EXCEPT ![TimerOFD] = TRUE]
    /\ sourceEpoch' = [sourceEpoch EXCEPT ![TimerOFD] = @ + 1]
    /\ readyEpoch' = [k \in InterestKeys |->
          IF k \in EnabledRegisteredForOFD(TimerOFD)
          THEN sourceEpoch[TimerOFD] + 1
          ELSE readyEpoch[k]]
    /\ producerPhase' = [producerPhase EXCEPT ![t] = "timer_notify"]
    /\ UNCHANGED <<fdVars, epollVars, callbackEpoch, callbackActor,
                    queuedEpoch, deliveredEpoch, consumerReadyEpoch,
                    cacheState, directRegistered, notified, observedReady,
                    observedEpoch, eventCounter, pollLocal, eventNotifyKeys,
                    eventNotifyWaiters, eventNotifyCounter, signalVars,
                    waitVars, topologyVars>>

TimerfdNotify(t) ==
    \* Pollee::notify invalidates cached events before SyncSubject enumerates
    \* observers. The callback itself remains a separate reactive action.
    \* kernel/core/src/time/timerfd.rs:102-105
    \* kernel/core/src/process/signal/poll.rs:167-178
    /\ producerPhase[t] = "timer_notify"
    /\ \A k \in EnabledRegisteredForOFD(TimerOFD) : callbackEpoch[k] = 0
    /\ cacheState' = [cacheState EXCEPT ![TimerOFD] = "invalid"]
    \* Each pending ReadySet callback carries the exact producer epoch and
    \* executing actor. ReadySetPush cannot occur without this state.
    \* kernel/core/src/events/subject.rs:126-149
    /\ callbackEpoch' = [k \in InterestKeys |->
          IF k \in EnabledRegisteredForOFD(TimerOFD)
          THEN readyEpoch[k]
          ELSE callbackEpoch[k]]
    /\ callbackActor' = [k \in InterestKeys |->
          IF k \in EnabledRegisteredForOFD(TimerOFD)
          THEN t
          ELSE callbackActor[k]]
    \* Waker observers selected by this same Pollee notification receive a
    \* producer-scoped token before a later WaiterReadinessWake can run.
    \* kernel/core/src/process/signal/poll.rs:167-178,318-321
    /\ waitReadyToken' = [w \in Threads |->
          IF sourceReady[TimerOFD] /\ w \in WaitersEligibleForReady(TimerOFD)
          THEN WaitReadyTokenFor(TimerOFD, t)
          ELSE waitReadyToken[w]]
    /\ producerPhase' = [producerPhase EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<fdVars, epollVars, sourceReady, sourceEpoch, readyEpoch,
                    queuedEpoch, deliveredEpoch, consumerReadyEpoch,
                    directRegistered, notified, observedReady, observedEpoch,
                    timerTicks, eventCounter, pollLocal,
                    eventNotifyKeys, eventNotifyWaiters, eventNotifyCounter,
                    signalVars, waitState, wakeCause, deadlineExpired,
                    interruptPending, visibleReady, terminalReady,
                    terminalScanValid, terminalScanExpected, currentMask,
                    savedMask, preWaitMask, returnReason, lastReadyWake,
                    waitCapturedOFDs, waitCaptureAudit, waitCapturedSlots,
                    waitCaptureSlotAudit, lastReleasedWaitOFDs,
                    lastReleasedWaitSlots, waitGeneration,
                    completedWaitReason, lastCompletedWaitReason,
                    topologyVars>>

TimerfdTryRead(t) ==
    \* kernel/core/src/time/timerfd.rs:177-186
    \* try_read atomically clears ticks but does not invalidate Pollee's cached
    \* IN result (time/timerfd.rs:177-186).
    /\ ThreadSyscallIdle(t)
    /\ timerTicks > 0
    /\ timerTicks' = 0
    /\ sourceReady' = [sourceReady EXCEPT ![TimerOFD] = FALSE]
    /\ UNCHANGED <<fdVars, epollVars, sourceEpoch, readyEpoch, callbackEpoch,
                    callbackActor, queuedEpoch, deliveredEpoch,
                    consumerReadyEpoch, cacheState, directRegistered,
                    notified, observedReady, observedEpoch, eventCounter,
                    pollLocal, producerPhase, eventNotifyKeys,
                    eventNotifyWaiters, eventNotifyCounter, signalVars, waitVars,
                    topologyVars>>

TimerfdSetTimeDisarm(t) ==
    \* kernel/core/src/time/timerfd.rs:130-145
    \* set_time cancels the timer and clears ticks without a cache invalidation
    \* (time/timerfd.rs:130-145).
    /\ ThreadSyscallIdle(t)
    /\ timerTicks > 0
    /\ timerTicks' = 0
    /\ sourceReady' = [sourceReady EXCEPT ![TimerOFD] = FALSE]
    /\ UNCHANGED <<fdVars, epollVars, sourceEpoch, readyEpoch, callbackEpoch,
                    callbackActor, queuedEpoch, deliveredEpoch,
                    consumerReadyEpoch, cacheState, directRegistered,
                    notified, observedReady, observedEpoch, eventCounter,
                    pollLocal, producerPhase, eventNotifyKeys,
                    eventNotifyWaiters, eventNotifyCounter, signalVars, waitVars,
                    topologyVars>>

EventfdAddCounter(t) ==
    \* kernel/core/src/syscall/eventfd.rs:151-159
    \* add_counter_val mutates the protected counter before notifying IN
    \* (syscall/eventfd.rs:151-159).
    /\ ThreadSyscallIdle(t)
    /\ producerPhase[t] = "idle"
    \* The single counter mutex excludes every other mutator until this
    \* actor's synchronous notification completes.
    \* kernel/core/src/syscall/eventfd.rs:151-159
    /\ EventfdMutexOwner = NoThread
    /\ eventCounter < MaxEventCounter
    /\ eventCounter' = eventCounter + 1
    /\ sourceReady' = [sourceReady EXCEPT ![EventOFD] = TRUE]
    /\ sourceEpoch' = [sourceEpoch EXCEPT ![EventOFD] = @ + 1]
    /\ readyEpoch' = [k \in InterestKeys |->
          IF k \in EnabledRegisteredForOFD(EventOFD)
          THEN sourceEpoch[EventOFD] + 1
          ELSE readyEpoch[k]]
    /\ producerPhase' = [producerPhase EXCEPT ![t] = "event_notify"]
    \* Snapshot the protected counter at mutex acquisition. It cannot change
    \* again until EventfdNotifyReturn releases the guard.
    \* kernel/core/src/syscall/eventfd.rs:151-159
    /\ eventNotifyCounter' = eventCounter + 1
    /\ UNCHANGED <<fdVars, epollVars, callbackEpoch, callbackActor,
                    queuedEpoch, deliveredEpoch, consumerReadyEpoch,
                    cacheState, directRegistered, notified, observedReady,
                    observedEpoch, timerTicks, pollLocal, eventNotifyKeys,
                    eventNotifyWaiters, signalVars, waitVars, topologyVars>>

EventfdTryRead(t) ==
    \* kernel/core/src/syscall/eventfd.rs:124-143
    \* eventfd read clears/decrements the counter, then follows with a Pollee
    \* notification before releasing the counter lock
    \* (syscall/eventfd.rs:124-143).
    /\ ThreadSyscallIdle(t)
    /\ producerPhase[t] = "idle"
    /\ EventfdMutexOwner = NoThread
    /\ eventCounter > 0
    /\ eventCounter' = 0
    /\ sourceReady' = [sourceReady EXCEPT ![EventOFD] = FALSE]
    /\ producerPhase' = [producerPhase EXCEPT ![t] = "event_notify"]
    /\ eventNotifyCounter' = 0
    /\ UNCHANGED <<fdVars, epollVars, sourceEpoch, readyEpoch, callbackEpoch,
                    callbackActor, queuedEpoch, deliveredEpoch,
                    consumerReadyEpoch, cacheState, directRegistered,
                    notified, observedReady, observedEpoch, timerTicks,
                    pollLocal, eventNotifyKeys, eventNotifyWaiters,
                    signalVars, waitVars, topologyVars>>

EventfdNotify(t) ==
    \* kernel/core/src/syscall/eventfd.rs:141-142,158-159
    \* kernel/core/src/process/signal/poll.rs:167-178
    \* This boundary begins synchronous observer dispatch. The counter mutex
    \* is deliberately retained until EventfdNotifyReturn.
    \* kernel/core/src/syscall/eventfd.rs:141-142,158-159
    \* kernel/core/src/events/subject.rs:126-153
    /\ EventfdMutexOwner = t
    /\ producerPhase[t] = "event_notify"
    /\ \A k \in EnabledRegisteredForOFD(EventOFD) : callbackEpoch[k] = 0
    /\ \A w \in WaitersEligibleForReady(EventOFD) :
          waitReadyToken[w].epoch = 0
    /\ cacheState' = [cacheState EXCEPT ![EventOFD] = "invalid"]
    /\ callbackEpoch' = [k \in InterestKeys |->
          IF sourceReady[EventOFD] /\ k \in EnabledRegisteredForOFD(EventOFD)
          THEN readyEpoch[k]
          ELSE callbackEpoch[k]]
    /\ callbackActor' = [k \in InterestKeys |->
          IF sourceReady[EventOFD] /\ k \in EnabledRegisteredForOFD(EventOFD)
          THEN t
          ELSE callbackActor[k]]
    \* Retain the exact selected key and Waker sets until each callback has
    \* returned or been synchronously suppressed.
    \* kernel/core/src/events/subject.rs:136-153
    /\ eventNotifyKeys' =
          IF sourceReady[EventOFD]
          THEN EnabledRegisteredForOFD(EventOFD)
          ELSE {}
    /\ eventNotifyWaiters' =
          IF sourceReady[EventOFD]
          THEN WaitersEligibleForReady(EventOFD)
          ELSE {}
    /\ waitReadyToken' = [w \in Threads |->
          IF sourceReady[EventOFD] /\ w \in WaitersEligibleForReady(EventOFD)
          THEN WaitReadyTokenFor(EventOFD, t)
          ELSE waitReadyToken[w]]
    /\ producerPhase' = [producerPhase EXCEPT ![t] = "event_callbacks"]
    /\ UNCHANGED <<fdVars, epollVars, sourceReady, sourceEpoch, readyEpoch,
                    queuedEpoch, deliveredEpoch, consumerReadyEpoch,
                    directRegistered, notified, observedReady, observedEpoch,
                    timerTicks, eventCounter, pollLocal, eventNotifyCounter,
                    signalVars, waitState, wakeCause, deadlineExpired,
                    interruptPending, visibleReady, terminalReady,
                    terminalScanValid, terminalScanExpected, currentMask,
                    savedMask, preWaitMask, returnReason, lastReadyWake,
                    waitCapturedOFDs, waitCaptureAudit, waitCapturedSlots,
                    waitCaptureSlotAudit, lastReleasedWaitOFDs,
                    lastReleasedWaitSlots, waitGeneration,
                    completedWaitReason, lastCompletedWaitReason,
                    topologyVars>>

EventfdNotifyReturn(t) ==
    \* Pollee::notify and every selected SyncSubject callback return before
    \* add_counter_val/try_read drops the counter Mutex guard.
    \* kernel/core/src/syscall/eventfd.rs:124-159
    \* kernel/core/src/events/subject.rs:126-153
    /\ producerPhase[t] = "event_callbacks"
    /\ EventfdMutexOwner = t
    /\ eventNotifyKeys = {}
    /\ eventNotifyWaiters = {}
    /\ callbackStage[t] = "idle"
    /\ producerPhase' = [producerPhase EXCEPT ![t] = "idle"]
    /\ eventNotifyCounter' = 0
    /\ UNCHANGED <<fdVars, epollVars, sourceReady, sourceEpoch, readyEpoch,
                    callbackEpoch, callbackActor, queuedEpoch, deliveredEpoch,
                    consumerReadyEpoch, cacheState, directRegistered, notified,
                    observedReady, observedEpoch, timerTicks, eventCounter,
                    pollLocal, eventNotifyKeys, eventNotifyWaiters, signalVars,
                    waitVars, topologyVars>>

(***************************************************************************)
(* Scenario 4: signalfd mask, queue binding, and consumer identity.        *)
(***************************************************************************)

SignalfdUpdateMask(t, enabled) ==
    \* Updating an existing signalfd stores the new mask and does not notify a
    \* poller even when a matching signal is already pending
    \* (syscall/signalfd.rs:103-117,155-161).
    /\ ThreadSyscallIdle(t)
    /\ LET becomesReady == enabled /\ ~signalMask[SignalOFD]
                            /\ (processPending
                                \/ \E w \in Threads : threadPending[w])
           nextEpoch == sourceEpoch[SignalOFD] + 1
       IN
       \* The mask store can expose already-pending signals, but current Rust
       \* performs no Pollee notification on this path.
       \* kernel/core/src/syscall/signalfd.rs:103-117,155-161
       /\ sourceEpoch' = IF becomesReady
                          THEN [sourceEpoch EXCEPT ![SignalOFD] = nextEpoch]
                          ELSE sourceEpoch
       /\ readyEpoch' = [k \in InterestKeys |->
             IF becomesReady /\ CompletedRegistration(k)
                /\ k.ofd = SignalOFD /\ entryEnabled[k]
                /\ epollWaiter[k.epoll] /= NoThread
                /\ (threadPending[epollWaiter[k.epoll]] \/ processPending)
             THEN nextEpoch
             ELSE readyEpoch[k]]
       /\ consumerReadyEpoch' = [b \in Bindings |->
             IF becomesReady /\ CompletedRegistration(b.key)
                /\ b.key.ofd = SignalOFD /\ entryEnabled[b.key]
                /\ (threadPending[b.thread] \/ processPending)
             THEN nextEpoch
             ELSE consumerReadyEpoch[b]]
    /\ signalMask' = [signalMask EXCEPT ![SignalOFD] = enabled]
    /\ UNCHANGED <<fdVars, epollVars, sourceReady, callbackEpoch,
                    callbackActor, queuedEpoch, deliveredEpoch, cacheState,
                    directRegistered, notified, observedReady, observedEpoch,
                    timerTicks, eventCounter, pollLocal, producerPhase,
                    eventNotifyKeys, eventNotifyWaiters, eventNotifyCounter,
                    threadPending, processPending, pollerBindings,
                    signalNotify, signalNotifyKeys, signalNotifyWaiters,
                    threadSignalEnqueueEpoch, threadSignalNotifyEpoch,
                    processSignalEnqueueEpoch, processSignalNotifyEpoch,
                    waitVars, topologyVars>>

SigQueuesEnqueueThread(actor, target) ==
    \* queues.enqueue and count.fetch_add execute under queues.lock. The guard
    \* is explicitly dropped before signalfd_pollee.notify; this action ends at
    \* that unlocked interleaving boundary.
    \* kernel/core/src/process/signal/sig_queues.rs:38-45
    \* kernel/core/src/process/posix_thread/mod.rs:256-270
    /\ ThreadHasNoOtherOperation(actor)
    /\ ~threadPending[target]
    /\ LET nextEpoch == sourceEpoch[SignalOFD] + 1 IN
       \* The queue mutation is live before notification. Registrations and
       \* mask changes by the other actor may interleave before notify begins.
       \* kernel/core/src/process/posix_thread/mod.rs:256-270
       \* kernel/core/src/process/signal/sig_queues.rs:38-45
       /\ threadPending' = [threadPending EXCEPT ![target] = TRUE]
       /\ sourceEpoch' = [sourceEpoch EXCEPT ![SignalOFD] = nextEpoch]
       /\ consumerReadyEpoch' = [b \in Bindings |->
             IF CompletedRegistration(b.key) /\ b.key.ofd = SignalOFD
                /\ entryEnabled[b.key] /\ b.thread = target
             THEN nextEpoch
             ELSE consumerReadyEpoch[b]]
       /\ readyEpoch' = [k \in InterestKeys |->
             IF signalMask[SignalOFD] /\ k \in SignalKeysConsumedBy(target)
             THEN nextEpoch
             ELSE readyEpoch[k]]
       /\ signalNotify' = [signalNotify EXCEPT ![actor] =
             [phase |-> "pending", queue |-> "thread", target |-> target,
              epoch |-> nextEpoch]]
       /\ threadSignalEnqueueEpoch' =
             [threadSignalEnqueueEpoch EXCEPT ![target] = nextEpoch]
    /\ UNCHANGED <<fdVars, epollVars, sourceReady, callbackEpoch,
                    callbackActor, queuedEpoch, deliveredEpoch, cacheState,
                    directRegistered, notified, observedReady, observedEpoch,
                    timerTicks, eventCounter, pollLocal, producerPhase,
                    eventNotifyKeys, eventNotifyWaiters, eventNotifyCounter,
                    signalMask, processPending, pollerBindings,
                    signalNotifyKeys, signalNotifyWaiters,
                    threadSignalNotifyEpoch, processSignalEnqueueEpoch,
                    processSignalNotifyEpoch, waitVars, topologyVars>>

SigQueuesEnqueueProcess(actor) ==
    \* kernel/core/src/process/signal/sig_queues.rs:38-45
    \* kernel/core/src/process/posix_thread/mod.rs:264-270
    \* This action ends after the process queue mutation and explicit guard
    \* drop, before the shared signalfd Pollee notification begins.
    /\ ThreadHasNoOtherOperation(actor)
    /\ ~processPending
    /\ LET nextEpoch == sourceEpoch[SignalOFD] + 1 IN
       /\ processPending' = TRUE
       /\ sourceEpoch' = [sourceEpoch EXCEPT ![SignalOFD] = nextEpoch]
       /\ consumerReadyEpoch' = [b \in Bindings |->
             IF CompletedRegistration(b.key) /\ b.key.ofd = SignalOFD
                /\ entryEnabled[b.key]
             THEN nextEpoch
             ELSE consumerReadyEpoch[b]]
       /\ readyEpoch' = [k \in InterestKeys |->
             IF signalMask[SignalOFD] /\ k \in EnabledSignalKeys
             THEN nextEpoch
             ELSE readyEpoch[k]]
       /\ signalNotify' = [signalNotify EXCEPT ![actor] =
             [phase |-> "pending", queue |-> "process", target |-> NoThread,
              epoch |-> nextEpoch]]
       /\ processSignalEnqueueEpoch' = nextEpoch
    /\ UNCHANGED <<fdVars, epollVars, sourceReady, callbackEpoch,
                    callbackActor, queuedEpoch, deliveredEpoch, cacheState,
                    directRegistered, notified, observedReady, observedEpoch,
                    timerTicks, eventCounter, pollLocal, producerPhase,
                    eventNotifyKeys, eventNotifyWaiters, eventNotifyCounter,
                    signalMask, threadPending, pollerBindings,
                    signalNotifyKeys, signalNotifyWaiters,
                    threadSignalEnqueueEpoch, threadSignalNotifyEpoch,
                    processSignalNotifyEpoch, waitVars, topologyVars>>

SigQueuesNotifyThread(actor) ==
    \* After queues.lock is dropped, notify snapshots the then-current weak
    \* observer list and synchronously invokes every selected callback.
    \* kernel/core/src/process/signal/sig_queues.rs:38-45,86-92
    \* kernel/core/src/events/subject.rs:126-153
    /\ signalNotify[actor].phase = "pending"
    /\ signalNotify[actor].queue = "thread"
    /\ LET target == signalNotify[actor].target
           epoch == signalNotify[actor].epoch
           keys == SignalKeysBoundToThread(target)
           waiters == {target} \intersect
                         WaitersEligibleForReady(SignalOFD)
       IN
       /\ epoch = threadSignalEnqueueEpoch[target]
       /\ \A k \in keys : callbackEpoch[k] = 0
       /\ \A w \in waiters : waitReadyToken[w].epoch = 0
       /\ callbackStage[actor] = "idle"
       /\ signalNotifyKeys[actor] = {}
       /\ signalNotifyWaiters[actor] = {}
       /\ cacheState' = [cacheState EXCEPT ![SignalOFD] = "invalid"]
       \* The delayed notify polls observers after the unlocked gap. A mask or
       \* registration interleaving can advance the live readiness epoch, so
       \* the callback carries the then-current key/source epoch while the
       \* continuation retains the enqueue epoch for ordering accountability.
       \* kernel/core/src/process/signal/sig_queues.rs:38-45,86-92
       \* kernel/core/src/events/subject.rs:126-153
       /\ callbackEpoch' = [k \in InterestKeys |->
             IF k \in keys THEN readyEpoch[k] ELSE callbackEpoch[k]]
       /\ callbackActor' = [k \in InterestKeys |->
             IF k \in keys THEN actor ELSE callbackActor[k]]
       /\ waitReadyToken' = [w \in Threads |->
             IF w \in waiters
             THEN [ofd |-> SignalOFD, actor |-> actor,
                   epoch |-> sourceEpoch[SignalOFD]]
             ELSE waitReadyToken[w]]
       /\ signalNotify' = [signalNotify EXCEPT ![actor].phase = "callbacks"]
       /\ signalNotifyKeys' = [signalNotifyKeys EXCEPT ![actor] = keys]
       /\ signalNotifyWaiters' =
             [signalNotifyWaiters EXCEPT ![actor] = waiters]
       /\ threadSignalNotifyEpoch' =
             [threadSignalNotifyEpoch EXCEPT ![target] = epoch]
    /\ UNCHANGED <<fdVars, epollVars, sourceReady, sourceEpoch, readyEpoch,
                    queuedEpoch, deliveredEpoch, consumerReadyEpoch,
                    directRegistered, notified, observedReady, observedEpoch,
                    timerTicks, eventCounter, pollLocal, producerPhase,
                    eventNotifyKeys, eventNotifyWaiters, eventNotifyCounter,
                    signalMask, threadPending, processPending, pollerBindings,
                    threadSignalEnqueueEpoch, processSignalEnqueueEpoch,
                    processSignalNotifyEpoch, waitState, wakeCause,
                    deadlineExpired, interruptPending, visibleReady,
                    terminalReady, terminalScanValid, terminalScanExpected,
                    currentMask, savedMask, preWaitMask, returnReason,
                    lastReadyWake, waitCapturedOFDs, waitCaptureAudit,
                    waitCapturedSlots, waitCaptureSlotAudit,
                    lastReleasedWaitOFDs, lastReleasedWaitSlots,
                    waitGeneration, completedWaitReason,
                    lastCompletedWaitReason, topologyVars>>

SigQueuesNotifyProcess(actor) ==
    \* The process queue uses the same unlocked notify boundary and selects
    \* registrations only when the notification call begins.
    \* kernel/core/src/process/signal/sig_queues.rs:38-45,86-92
    \* kernel/core/src/events/subject.rs:126-153
    /\ signalNotify[actor].phase = "pending"
    /\ signalNotify[actor].queue = "process"
    /\ LET epoch == signalNotify[actor].epoch
           keys == EnabledSignalKeys
           waiters == WaitersEligibleForReady(SignalOFD)
       IN
       /\ epoch = processSignalEnqueueEpoch
       /\ \A k \in keys : callbackEpoch[k] = 0
       /\ \A w \in waiters : waitReadyToken[w].epoch = 0
       /\ callbackStage[actor] = "idle"
       /\ signalNotifyKeys[actor] = {}
       /\ signalNotifyWaiters[actor] = {}
       /\ cacheState' = [cacheState EXCEPT ![SignalOFD] = "invalid"]
       \* Notification observes the current readiness epoch after any legal
       \* unlocked registration or mask interleaving.
       \* kernel/core/src/process/signal/sig_queues.rs:38-45,86-92
       \* kernel/core/src/events/subject.rs:126-153
       /\ callbackEpoch' = [k \in InterestKeys |->
             IF k \in keys THEN readyEpoch[k] ELSE callbackEpoch[k]]
       /\ callbackActor' = [k \in InterestKeys |->
             IF k \in keys THEN actor ELSE callbackActor[k]]
       /\ waitReadyToken' = [w \in Threads |->
             IF w \in waiters
             THEN [ofd |-> SignalOFD, actor |-> actor,
                   epoch |-> sourceEpoch[SignalOFD]]
             ELSE waitReadyToken[w]]
       /\ signalNotify' = [signalNotify EXCEPT ![actor].phase = "callbacks"]
       /\ signalNotifyKeys' = [signalNotifyKeys EXCEPT ![actor] = keys]
       /\ signalNotifyWaiters' =
             [signalNotifyWaiters EXCEPT ![actor] = waiters]
       /\ processSignalNotifyEpoch' = epoch
    /\ UNCHANGED <<fdVars, epollVars, sourceReady, sourceEpoch, readyEpoch,
                    queuedEpoch, deliveredEpoch, consumerReadyEpoch,
                    directRegistered, notified, observedReady, observedEpoch,
                    timerTicks, eventCounter, pollLocal, producerPhase,
                    eventNotifyKeys, eventNotifyWaiters, eventNotifyCounter,
                    signalMask, threadPending, processPending, pollerBindings,
                    threadSignalEnqueueEpoch, threadSignalNotifyEpoch,
                    processSignalEnqueueEpoch, waitState, wakeCause,
                    deadlineExpired, interruptPending, visibleReady,
                    terminalReady, terminalScanValid, terminalScanExpected,
                    currentMask, savedMask, preWaitMask, returnReason,
                    lastReadyWake, waitCapturedOFDs, waitCaptureAudit,
                    waitCapturedSlots, waitCaptureSlotAudit,
                    lastReleasedWaitOFDs, lastReleasedWaitSlots,
                    waitGeneration, completedWaitReason,
                    lastCompletedWaitReason, topologyVars>>

SigQueuesNotifyReturn(actor) ==
    \* SyncSubject::notify returns only after every selected Entry and Waker
    \* callback has run or been synchronously suppressed.
    \* kernel/core/src/process/signal/sig_queues.rs:38-45
    \* kernel/core/src/events/subject.rs:126-153
    /\ signalNotify[actor].phase = "callbacks"
    /\ signalNotifyKeys[actor] = {}
    /\ signalNotifyWaiters[actor] = {}
    /\ callbackStage[actor] = "idle"
    /\ signalNotify' = [signalNotify EXCEPT ![actor] = EmptySignalNotify]
    /\ UNCHANGED <<fdVars, epollVars, readinessVars, signalMask,
                    threadPending, processPending, pollerBindings,
                    signalNotifyKeys, signalNotifyWaiters,
                    threadSignalEnqueueEpoch, threadSignalNotifyEpoch,
                    processSignalEnqueueEpoch, processSignalNotifyEpoch,
                    waitVars, topologyVars>>

SignalFileReadThread(t) ==
    \* kernel/core/src/syscall/signalfd.rs:182-201,218-243
    \* signalfd read evaluates and dequeues against the consuming current thread
    \* (syscall/signalfd.rs:182-201,218-243).
    /\ signalMask[SignalOFD]
    /\ ThreadSyscallIdle(t)
    /\ threadPending[t]
    /\ threadPending' = [threadPending EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<fdVars, epollVars, readinessVars, signalMask,
                    processPending, pollerBindings, signalNotify,
                    signalNotifyKeys, signalNotifyWaiters,
                    threadSignalEnqueueEpoch, threadSignalNotifyEpoch,
                    processSignalEnqueueEpoch, processSignalNotifyEpoch,
                    waitVars, topologyVars>>

SignalFileReadProcess(t) ==
    \* kernel/core/src/syscall/signalfd.rs:182-201,218-243
    \* The same read may consume from the process queue when no matching
    \* thread-directed signal is selected (syscall/signalfd.rs:182-201).
    /\ signalMask[SignalOFD]
    /\ ThreadSyscallIdle(t)
    /\ ~threadPending[t]
    /\ processPending
    /\ processPending' = FALSE
    /\ UNCHANGED <<fdVars, epollVars, readinessVars, signalMask,
                    threadPending, pollerBindings, signalNotify,
                    signalNotifyKeys, signalNotifyWaiters,
                    threadSignalEnqueueEpoch, threadSignalNotifyEpoch,
                    processSignalEnqueueEpoch, processSignalNotifyEpoch,
                    waitVars, topologyVars>>

EpollWaitRegisterConsumer(t, ep) ==
    \* epoll_wait records its consumer thread. With an empty ReadySet it does
    \* not call Entry::poll, so this alone cannot add a signalfd readiness
    \* epoch or migrate the prior PollHandle registration.
    \* kernel/core/src/events/epoll/file.rs:225-280
    \* kernel/core/src/syscall/signalfd.rs:207-216
    /\ ThreadSyscallIdle(t)
    /\ epollWaiter' = [epollWaiter EXCEPT ![ep] = t]
    /\ UNCHANGED <<fdVars, interest, readyQ, entryEnabled, triggerMode,
                    registered, keySlotEpoch, interestIdentity, ctl, delivery,
                    copyoutOk,
                    deliveredKeys,
                    faultedUndelivered, lastDeliveredKey, reportedOFD,
                    epollWake, sourceReady, sourceEpoch, callbackEpoch,
                    callbackActor, readyEpoch, queuedEpoch, deliveredEpoch,
                    consumerReadyEpoch, cacheState,
                    directRegistered, notified, observedReady, observedEpoch,
                    timerTicks, eventCounter, pollLocal, producerPhase,
                    eventNotifyKeys, eventNotifyWaiters, eventNotifyCounter,
                    signalVars, waitVars, topologyVars>>

(***************************************************************************)
(* Scenario 5: wait arbitration and deferred temporary-mask restoration.   *)
(***************************************************************************)

SaveAndSetSigMask(t, newMask) ==
    \* kernel/core/src/syscall/ppoll.rs:31-40
    \* kernel/core/src/syscall/pselect6.rs:33-52
    \* kernel/core/src/syscall/epoll.rs:114-121
    \* ppoll/pselect6/epoll_pwait save the old per-thread mask and install the
    \* temporary one before waiting (ppoll.rs:31-40; pselect6.rs:33-52;
    \* syscall/epoll.rs:114-121; process/posix_thread/mod.rs:381-386).
    /\ waitState[t] \in {"idle", "returned"}
    /\ ThreadHasNoOtherOperation(t)
    /\ newMask \in MaskStates
    /\ savedMask[t] = "none"
    /\ preWaitMask' = [preWaitMask EXCEPT ![t] = currentMask[t]]
    /\ savedMask' = [savedMask EXCEPT ![t] = currentMask[t]]
    /\ currentMask' = [currentMask EXCEPT ![t] = newMask]
    /\ waitState' = [waitState EXCEPT ![t] = "mask_set"]
    \* A new syscall invocation allocates fresh Waiter/Poller state before a
    \* later PollFiles registration. No terminal state crosses this boundary.
    \* kernel/core/src/process/posix_thread/mod.rs:381-386
    \* kernel/core/src/syscall/poll.rs:88-106
    /\ waitGeneration' = [waitGeneration EXCEPT ![t] = @ + 1]
    /\ wakeCause' = [wakeCause EXCEPT ![t] = "none"]
    /\ deadlineExpired' = [deadlineExpired EXCEPT ![t] = FALSE]
    /\ interruptPending' = [interruptPending EXCEPT ![t] = FALSE]
    /\ visibleReady' = [visibleReady EXCEPT ![t] = FALSE]
    /\ terminalReady' = [terminalReady EXCEPT ![t] = FALSE]
    /\ terminalScanValid' = [terminalScanValid EXCEPT ![t] = FALSE]
    /\ terminalScanExpected' = [terminalScanExpected EXCEPT ![t] = FALSE]
    /\ returnReason' = [returnReason EXCEPT ![t] = "none"]
    /\ waitReadyToken' =
          [waitReadyToken EXCEPT ![t] = EmptyWaitReadyToken]
    /\ lastReadyWake' = [lastReadyWake EXCEPT ![t] = EmptyWaitReadyToken]
    /\ waitCapturedOFDs' = [waitCapturedOFDs EXCEPT ![t] = {}]
    /\ waitCaptureAudit' = [waitCaptureAudit EXCEPT ![t] = {}]
    /\ waitCapturedSlots' =
          [waitCapturedSlots EXCEPT ![t] = EmptyWaitSlotSnapshot]
    /\ waitCaptureSlotAudit' =
          [waitCaptureSlotAudit EXCEPT ![t] = EmptyWaitSlotSnapshot]
    /\ lastReleasedWaitOFDs' =
          [lastReleasedWaitOFDs EXCEPT ![t] = {}]
    /\ lastReleasedWaitSlots' =
          [lastReleasedWaitSlots EXCEPT ![t] = EmptyWaitSlotSnapshot]
    /\ completedWaitReason' =
          [completedWaitReason EXCEPT ![t] = "none"]
    /\ UNCHANGED <<fdVars, epollVars, readinessVars, signalVars,
                    lastCompletedWaitReason, topologyVars>>

PollFilesRegisterPoller(t) ==
    \* kernel/core/src/syscall/poll.rs:88-106,124-185
    \* do_poll snapshots/captures OFDs and register_poller registers each before
    \* entering the wait loop (syscall/poll.rs:88-106,134-185).
    /\ waitState[t] \in {"idle", "mask_set", "returned"}
    /\ ThreadHasNoOtherOperation(t)
    /\ waitReadyToken[t].epoch = 0
    \* EventFile::poll cannot finish while another actor owns its counter
    \* mutex; timerfd/signalfd checks have no corresponding global guard.
    \* kernel/core/src/syscall/eventfd.rs:104-121,124-159
    /\ EventfdMutexOwner = NoThread
    /\ LET snapshot == CurrentPollSnapshot
           found == \E o \in snapshot : ofdAlive[o] /\ OFDReady(o, t)
       IN
       \* register_poller invokes each live file poll before deciding between
       \* FoundEvents and Registered. Preserve that result for the caller's
       \* immediate branch.
       \* kernel/core/src/syscall/poll.rs:103-106,165-185
       /\ visibleReady' = [visibleReady EXCEPT ![t] = found]
       /\ preWaitMask' = IF waitState[t] \in {"idle", "returned"}
                          THEN [preWaitMask EXCEPT ![t] = currentMask[t]]
                          ELSE preWaitMask
       /\ savedMask' = IF waitState[t] \in {"idle", "returned"}
                        THEN [savedMask EXCEPT ![t] = "none"]
                        ELSE savedMask
       /\ waitState' = [waitState EXCEPT ![t] = "registered"]
       /\ waitGeneration' =
             IF waitState[t] \in {"idle", "returned"}
             THEN [waitGeneration EXCEPT ![t] = @ + 1]
             ELSE waitGeneration
       /\ wakeCause' = [wakeCause EXCEPT ![t] = "none"]
       /\ deadlineExpired' = [deadlineExpired EXCEPT ![t] = FALSE]
       /\ interruptPending' = [interruptPending EXCEPT ![t] = FALSE]
       /\ returnReason' = [returnReason EXCEPT ![t] = "none"]
       /\ terminalReady' = [terminalReady EXCEPT ![t] = FALSE]
       /\ terminalScanValid' =
             [terminalScanValid EXCEPT ![t] = FALSE]
       /\ terminalScanExpected' =
             [terminalScanExpected EXCEPT ![t] = FALSE]
       /\ waitCapturedOFDs' =
             [waitCapturedOFDs EXCEPT ![t] = snapshot]
       \* The audit copy is independent oracle state. Controller-only
       \* mutations can drop an owner without changing this expected set.
       \* kernel/core/src/syscall/poll.rs:143-155
       /\ waitCaptureAudit' =
             [waitCaptureAudit EXCEPT ![t] = snapshot]
       /\ waitCapturedSlots' =
             [waitCapturedSlots EXCEPT ![t] = CurrentPollSlotSnapshot]
       /\ waitCaptureSlotAudit' =
             [waitCaptureSlotAudit EXCEPT ![t] = CurrentPollSlotSnapshot]
       /\ lastReleasedWaitOFDs' =
             [lastReleasedWaitOFDs EXCEPT ![t] = {}]
       /\ lastReleasedWaitSlots' =
             [lastReleasedWaitSlots EXCEPT ![t] = EmptyWaitSlotSnapshot]
       /\ completedWaitReason' =
             [completedWaitReason EXCEPT ![t] = "none"]
       \* A new Poller owns a fresh Waker. The guard excludes any selected
       \* callback still returning, and prior wake history is not inherited.
       \* kernel/core/src/syscall/poll.rs:88-106,165-185
       \* kernel/core/src/process/signal/poll.rs:282-300
       /\ lastReadyWake' = [lastReadyWake EXCEPT ![t] = EmptyWaitReadyToken]
    /\ UNCHANGED <<fdVars, epollVars, readinessVars, signalVars,
                    currentMask, waitReadyToken, lastCompletedWaitReason,
                    topologyVars>>

PollFilesInitialReady(t) ==
    \* kernel/core/src/syscall/poll.rs:167-185
    \* Registration returns immediately when a file's live poll reports events
    \* (syscall/poll.rs:167-185).
    /\ waitState[t] = "registered"
    /\ visibleReady[t]
    /\ waitState' = [waitState EXCEPT ![t] = "syscall_done"]
    /\ returnReason' = [returnReason EXCEPT ![t] = "ready"]
    /\ terminalReady' = [terminalReady EXCEPT ![t] = TRUE]
    /\ terminalScanValid' = [terminalScanValid EXCEPT ![t] = TRUE]
    /\ terminalScanExpected' =
          [terminalScanExpected EXCEPT ![t] = visibleReady[t]]
    \* The early return drops PollFiles::Owned and every Arc in its snapshot.
    \* kernel/core/src/syscall/poll.rs:96-106,124-155,165-185
    /\ ofdAlive' = AliveAfterWaitRelease(t)
    /\ lastReleasedWaitOFDs' =
          [lastReleasedWaitOFDs EXCEPT ![t] = waitCapturedOFDs[t]]
    /\ lastReleasedWaitSlots' =
          [lastReleasedWaitSlots EXCEPT ![t] = waitCapturedSlots[t]]
    /\ waitCapturedOFDs' = [waitCapturedOFDs EXCEPT ![t] = {}]
    /\ waitCaptureAudit' = [waitCaptureAudit EXCEPT ![t] = {}]
    /\ waitCapturedSlots' =
          [waitCapturedSlots EXCEPT ![t] = EmptyWaitSlotSnapshot]
    /\ waitCaptureSlotAudit' =
          [waitCaptureSlotAudit EXCEPT ![t] = EmptyWaitSlotSnapshot]
    /\ completedWaitReason' =
          [completedWaitReason EXCEPT ![t] = "ready"]
    /\ lastCompletedWaitReason' =
          [lastCompletedWaitReason EXCEPT ![t] = "ready"]
    /\ UNCHANGED <<slots, slotFlags, slotEpoch, ofdStatus, captured,
                    capturedFd, capturedStatus, captureEpoch, lastCaptured,
                    actedOFD, actedSlotOFD, actedCaptureEpoch, actedSlotEpoch,
                    closePending, replacement, execVars, fdFlagAudit,
                    slotMapAudit, epollVars, readinessVars, signalVars,
                    wakeCause,
                    deadlineExpired, interruptPending, visibleReady,
                    currentMask, savedMask, preWaitMask, waitReadyToken,
                    lastReadyWake, waitGeneration,
                    topologyVars>>

WaiterPauseTimeoutBlock(t) ==
    \* kernel/core/src/process/signal/poll.rs:307-315
    \* kernel/core/src/process/signal/pause.rs:171-200
    \* If registration finds no readiness, Poller::wait enters Waiter::pause_timeout
    \* (syscall/poll.rs:103-110; process/signal/poll.rs:307-315).
    /\ waitState[t] = "registered"
    /\ ~visibleReady[t]
    /\ waitState' = [waitState EXCEPT ![t] = "blocked"]
    /\ UNCHANGED <<fdVars, epollVars, readinessVars, signalVars, wakeCause,
                    deadlineExpired, interruptPending, visibleReady,
                    terminalReady, terminalScanValid, terminalScanExpected,
                    currentMask, savedMask, preWaitMask,
                    returnReason, waitReadyToken, lastReadyWake,
                    waitCapturedOFDs, waitCaptureAudit, waitCapturedSlots,
                    waitCaptureSlotAudit, lastReleasedWaitOFDs,
                    lastReleasedWaitSlots, waitGeneration,
                    completedWaitReason, lastCompletedWaitReason,
                    topologyVars>>

WaiterReadinessWake(actor, target) ==
    \* An observer notification makes readiness visible and wakes the Waiter
    \* (process/signal/poll.rs:318-321; epoll/entry.rs:327-330).
    \* actor executes Observer::on_events; target owns the Waiter/Waker pair.
    \* kernel/core/src/process/signal/poll.rs:275-320
    \* A readiness wake is a selected Waker callback from an earlier modeled
    \* producer notification. Actor, OFD, and epoch are not guessed here.
    \* kernel/core/src/process/signal/poll.rs:167-178,318-321
    /\ waitReadyToken[target].epoch > 0
    /\ waitReadyToken[target].actor = actor
    /\ LET active == waitState[target] \in {"registered", "blocked", "woken"}
       IN
       \* The selected Arc callback still returns if a concurrent terminal
       \* path has already dropped the Poller; only an active wait is changed.
       \* kernel/core/src/events/subject.rs:136-149
       /\ visibleReady' =
             IF active THEN [visibleReady EXCEPT ![target] = TRUE]
             ELSE visibleReady
       /\ wakeCause' =
             IF active THEN [wakeCause EXCEPT ![target] = "ready"]
             ELSE wakeCause
       /\ waitState' =
             IF active THEN [waitState EXCEPT ![target] = "woken"]
             ELSE waitState
    /\ lastReadyWake' = [lastReadyWake EXCEPT ![target] =
          waitReadyToken[target]]
    /\ waitReadyToken' =
          [waitReadyToken EXCEPT ![target] = EmptyWaitReadyToken]
    \* A direct EventFile Waker is part of the same synchronous notify call
    \* whose counter Mutex remains held by actor.
    \* kernel/core/src/syscall/eventfd.rs:124-159
    /\ eventNotifyWaiters' =
          IF waitReadyToken[target].ofd = EventOFD
          THEN eventNotifyWaiters \ {target}
          ELSE eventNotifyWaiters
    /\ signalNotifyWaiters' =
          IF waitReadyToken[target].ofd = SignalOFD
             /\ signalNotify[actor].phase = "callbacks"
          THEN [signalNotifyWaiters EXCEPT ![actor] = @ \ {target}]
          ELSE signalNotifyWaiters
    /\ UNCHANGED <<fdVars, epollVars, sourceReady, sourceEpoch, readyEpoch,
                    callbackEpoch, callbackActor, queuedEpoch, deliveredEpoch,
                    consumerReadyEpoch, cacheState, directRegistered, notified,
                    observedReady, observedEpoch, timerTicks, eventCounter,
                    pollLocal, producerPhase, eventNotifyKeys,
                    eventNotifyCounter, signalMask, threadPending,
                    processPending, pollerBindings, signalNotify,
                    signalNotifyKeys, threadSignalEnqueueEpoch,
                    threadSignalNotifyEpoch, processSignalEnqueueEpoch,
                    processSignalNotifyEpoch,
                    deadlineExpired, interruptPending, terminalReady,
                    terminalScanValid, terminalScanExpected,
                    currentMask, savedMask, preWaitMask, returnReason,
                    waitCapturedOFDs, waitCaptureAudit, waitCapturedSlots,
                    waitCaptureSlotAudit, lastReleasedWaitOFDs,
                    lastReleasedWaitSlots, waitGeneration,
                    completedWaitReason, lastCompletedWaitReason,
                    topologyVars>>

WaiterTimeoutExpires(actor, target) ==
    \* The timeout callback only wakes the waiter; no cause is retained by the
    \* Waker itself (process/signal/pause.rs:171-177,195-205).
    \* The timer callback executes in actor and wakes target's Waker.
    \* kernel/core/src/process/signal/pause.rs:171-177,195-205
    /\ waitState[target] \in {"blocked", "woken"}
    /\ ~deadlineExpired[target]
    /\ deadlineExpired' = [deadlineExpired EXCEPT ![target] = TRUE]
    /\ wakeCause' = [wakeCause EXCEPT ![target] = "timer"]
    /\ waitState' = [waitState EXCEPT ![target] = "woken"]
    /\ UNCHANGED <<fdVars, epollVars, readinessVars, signalVars,
                    interruptPending, visibleReady, terminalReady,
                    terminalScanValid, terminalScanExpected,
                    currentMask, savedMask, preWaitMask, returnReason,
                    waitReadyToken, lastReadyWake, waitCapturedOFDs,
                    waitCaptureAudit, waitCapturedSlots,
                    waitCaptureSlotAudit, lastReleasedWaitOFDs,
                    lastReleasedWaitSlots, waitGeneration,
                    completedWaitReason, lastCompletedWaitReason,
                    topologyVars>>

WaiterSignalInterrupts(actor, target) ==
    \* Signal enqueue wakes the registered signalled waker; pause_timeout checks
    \* pending signals after the timeout check (pause.rs:184-219).
    \* Signal delivery may execute in an enqueuing actor while target owns the
    \* registered signalled Waker.
    \* kernel/core/src/process/posix_thread/mod.rs:249-264
    \* kernel/core/src/process/signal/pause.rs:184-219
    /\ waitState[target] \in {"blocked", "woken"}
    /\ ~interruptPending[target]
    /\ interruptPending' = [interruptPending EXCEPT ![target] = TRUE]
    /\ wakeCause' = [wakeCause EXCEPT ![target] = "signal"]
    /\ waitState' = [waitState EXCEPT ![target] = "woken"]
    /\ UNCHANGED <<fdVars, epollVars, readinessVars, signalVars,
                    deadlineExpired, visibleReady, terminalReady,
                    terminalScanValid, terminalScanExpected,
                    currentMask, savedMask, preWaitMask, returnReason,
                    waitReadyToken, lastReadyWake, waitCapturedOFDs,
                    waitCaptureAudit, waitCapturedSlots,
                    waitCaptureSlotAudit, lastReleasedWaitOFDs,
                    lastReleasedWaitSlots, waitGeneration,
                    completedWaitReason, lastCompletedWaitReason,
                    topologyVars>>

WaiterPauseTimeoutReturnTimeout(t) ==
    \* kernel/core/src/process/signal/pause.rs:202-209
    \* kernel/core/src/syscall/poll.rs:108-117
    \* pause_timeout selects ETIME before do_poll calls count_events. The audit
    \* snapshot below observes the live FileLike predicates at this exact
    \* terminal branch; it does not invent a production rescan or alter the
    \* implementation result.
    \* kernel/core/src/process/signal/pause.rs:202-209
    \* kernel/core/src/syscall/poll.rs:108-121,188-215
    /\ waitState[t] = "woken"
    /\ deadlineExpired[t]
    /\ LET live == LiveWaitReadiness(t) IN
       /\ terminalReady' = [terminalReady EXCEPT ![t] = live]
       /\ terminalScanExpected' =
             [terminalScanExpected EXCEPT ![t] = live]
    /\ terminalScanValid' = [terminalScanValid EXCEPT ![t] = TRUE]
    /\ returnReason' = [returnReason EXCEPT ![t] = "timeout"]
    /\ waitState' = [waitState EXCEPT ![t] = "syscall_done"]
    \* Every return branch drops the Owned Arc vector after the live scan.
    \* kernel/core/src/syscall/poll.rs:96-121,124-155
    /\ ofdAlive' = AliveAfterWaitRelease(t)
    /\ lastReleasedWaitOFDs' =
          [lastReleasedWaitOFDs EXCEPT ![t] = waitCapturedOFDs[t]]
    /\ lastReleasedWaitSlots' =
          [lastReleasedWaitSlots EXCEPT ![t] = waitCapturedSlots[t]]
    /\ waitCapturedOFDs' = [waitCapturedOFDs EXCEPT ![t] = {}]
    /\ waitCaptureAudit' = [waitCaptureAudit EXCEPT ![t] = {}]
    /\ waitCapturedSlots' =
          [waitCapturedSlots EXCEPT ![t] = EmptyWaitSlotSnapshot]
    /\ waitCaptureSlotAudit' =
          [waitCaptureSlotAudit EXCEPT ![t] = EmptyWaitSlotSnapshot]
    /\ completedWaitReason' =
          [completedWaitReason EXCEPT ![t] = "timeout"]
    /\ lastCompletedWaitReason' =
          [lastCompletedWaitReason EXCEPT ![t] = "timeout"]
    /\ UNCHANGED <<slots, slotFlags, slotEpoch, ofdStatus, captured,
                    capturedFd, capturedStatus, captureEpoch, lastCaptured,
                    actedOFD, actedSlotOFD, actedCaptureEpoch, actedSlotEpoch,
                    closePending, replacement, execVars, fdFlagAudit,
                    slotMapAudit, epollVars, readinessVars, signalVars,
                    wakeCause,
                    deadlineExpired, interruptPending, visibleReady,
                    currentMask, savedMask, preWaitMask, waitReadyToken,
                    lastReadyWake, waitGeneration,
                    topologyVars>>

WaiterPauseTimeoutReturnSignal(t) ==
    \* kernel/core/src/process/signal/pause.rs:211-219
    \* kernel/core/src/syscall/poll.rs:108-117
    \* EINTR is also selected before count_events. Retain an audit-only live
    \* snapshot at this terminal boundary, separate from historical wake state.
    \* kernel/core/src/process/signal/pause.rs:211-219
    \* kernel/core/src/syscall/poll.rs:108-121,188-215
    /\ waitState[t] = "woken"
    /\ ~deadlineExpired[t]
    /\ interruptPending[t]
    /\ LET live == LiveWaitReadiness(t) IN
       /\ terminalReady' = [terminalReady EXCEPT ![t] = live]
       /\ terminalScanExpected' =
             [terminalScanExpected EXCEPT ![t] = live]
    /\ terminalScanValid' = [terminalScanValid EXCEPT ![t] = TRUE]
    /\ returnReason' = [returnReason EXCEPT ![t] = "signal"]
    /\ waitState' = [waitState EXCEPT ![t] = "syscall_done"]
    \* kernel/core/src/syscall/poll.rs:96-121,124-155
    /\ ofdAlive' = AliveAfterWaitRelease(t)
    /\ lastReleasedWaitOFDs' =
          [lastReleasedWaitOFDs EXCEPT ![t] = waitCapturedOFDs[t]]
    /\ lastReleasedWaitSlots' =
          [lastReleasedWaitSlots EXCEPT ![t] = waitCapturedSlots[t]]
    /\ waitCapturedOFDs' = [waitCapturedOFDs EXCEPT ![t] = {}]
    /\ waitCaptureAudit' = [waitCaptureAudit EXCEPT ![t] = {}]
    /\ waitCapturedSlots' =
          [waitCapturedSlots EXCEPT ![t] = EmptyWaitSlotSnapshot]
    /\ waitCaptureSlotAudit' =
          [waitCaptureSlotAudit EXCEPT ![t] = EmptyWaitSlotSnapshot]
    /\ completedWaitReason' =
          [completedWaitReason EXCEPT ![t] = "signal"]
    /\ lastCompletedWaitReason' =
          [lastCompletedWaitReason EXCEPT ![t] = "signal"]
    /\ UNCHANGED <<slots, slotFlags, slotEpoch, ofdStatus, captured,
                    capturedFd, capturedStatus, captureEpoch, lastCaptured,
                    actedOFD, actedSlotOFD, actedCaptureEpoch, actedSlotEpoch,
                    closePending, replacement, execVars, fdFlagAudit,
                    slotMapAudit, epollVars, readinessVars, signalVars,
                    wakeCause,
                    deadlineExpired, interruptPending, visibleReady,
                    currentMask, savedMask, preWaitMask, waitReadyToken,
                    lastReadyWake, waitGeneration,
                    topologyVars>>

DoPollCountEvents(t) ==
    \* kernel/core/src/syscall/poll.rs:108-121,188-215
    \* Only an Ok wake reaches count_events. This action evaluates the live
    \* source predicates now; visibleReady is retained only as wake history.
    \* kernel/core/src/syscall/poll.rs:108-121,188-215
    /\ waitState[t] = "woken"
    /\ ~deadlineExpired[t]
    /\ ~interruptPending[t]
    /\ LET live == LiveWaitReadiness(t) IN
       /\ terminalScanValid' = [terminalScanValid EXCEPT ![t] = TRUE]
       /\ terminalScanExpected' =
             [terminalScanExpected EXCEPT ![t] = live]
       /\ terminalReady' = [terminalReady EXCEPT ![t] = live]
       /\ IF live
          THEN /\ waitState' = [waitState EXCEPT ![t] = "syscall_done"]
               /\ returnReason' = [returnReason EXCEPT ![t] = "ready"]
          ELSE /\ waitState' = [waitState EXCEPT ![t] = "blocked"]
               /\ returnReason' = returnReason
       /\ ofdAlive' = IF live THEN AliveAfterWaitRelease(t) ELSE ofdAlive
       /\ lastReleasedWaitOFDs' =
             IF live
             THEN [lastReleasedWaitOFDs EXCEPT ![t] = waitCapturedOFDs[t]]
             ELSE lastReleasedWaitOFDs
       /\ lastReleasedWaitSlots' =
             IF live
             THEN [lastReleasedWaitSlots EXCEPT ![t] = waitCapturedSlots[t]]
             ELSE lastReleasedWaitSlots
       /\ waitCapturedOFDs' =
             IF live THEN [waitCapturedOFDs EXCEPT ![t] = {}]
             ELSE waitCapturedOFDs
       /\ waitCaptureAudit' =
             IF live THEN [waitCaptureAudit EXCEPT ![t] = {}]
             ELSE waitCaptureAudit
       /\ waitCapturedSlots' =
             IF live
             THEN [waitCapturedSlots EXCEPT ![t] = EmptyWaitSlotSnapshot]
             ELSE waitCapturedSlots
       /\ waitCaptureSlotAudit' =
             IF live
             THEN [waitCaptureSlotAudit EXCEPT ![t] = EmptyWaitSlotSnapshot]
             ELSE waitCaptureSlotAudit
       /\ completedWaitReason' =
             IF live
             THEN [completedWaitReason EXCEPT ![t] = "ready"]
             ELSE completedWaitReason
       /\ lastCompletedWaitReason' =
             IF live
             THEN [lastCompletedWaitReason EXCEPT ![t] = "ready"]
             ELSE lastCompletedWaitReason
    /\ UNCHANGED <<slots, slotFlags, slotEpoch, ofdStatus, captured,
                    capturedFd, capturedStatus, captureEpoch, lastCaptured,
                    actedOFD, actedSlotOFD, actedCaptureEpoch, actedSlotEpoch,
                    closePending, replacement, execVars, fdFlagAudit,
                    slotMapAudit, epollVars, readinessVars, signalVars,
                    wakeCause,
                    deadlineExpired, interruptPending, visibleReady,
                    currentMask, savedMask, preWaitMask, waitReadyToken,
                    lastReadyWake, waitGeneration,
                    topologyVars>>

HandlePendingSignalRestoreMask(t) ==
    \* kernel/core/src/process/signal/mod.rs:64-85,208-230
    \* Syscall-return signal handling takes the saved mask into an RAII guard;
    \* every normal/early branch drops it and restores the original mask
    \* (process/signal/mod.rs:64-85,208-230).
    /\ waitState[t] = "syscall_done"
    /\ waitCapturedOFDs[t] = {}
    /\ waitCaptureAudit[t] = {}
    /\ waitCapturedSlots[t] = EmptyWaitSlotSnapshot
    /\ waitCaptureSlotAudit[t] = EmptyWaitSlotSnapshot
    /\ currentMask' = [currentMask EXCEPT ![t] = preWaitMask[t]]
    /\ savedMask' = [savedMask EXCEPT ![t] = "none"]
    /\ waitState' = [waitState EXCEPT ![t] = "returned"]
    /\ UNCHANGED <<fdVars, epollVars, readinessVars, signalVars, wakeCause,
                    deadlineExpired, interruptPending, visibleReady,
                    terminalReady, terminalScanValid, terminalScanExpected,
                    preWaitMask, returnReason, waitReadyToken,
                    lastReadyWake, waitCapturedOFDs, waitCaptureAudit,
                    waitCapturedSlots, waitCaptureSlotAudit,
                    lastReleasedWaitOFDs, lastReleasedWaitSlots,
                    waitGeneration, completedWaitReason,
                    lastCompletedWaitReason, topologyVars>>

(***************************************************************************)
(* Scenario 6: supported two-node nested epoll and callback locks.         *)
(***************************************************************************)

EpollAddNestedInterest(t, outer, inner) ==
    \* The pinned control path accepts an epoll FileLike like any other target.
    \* The guards below are the explicit supported-scope admission constraint,
    \* not an implementation claim that cycles are rejected.
    \* kernel/core/src/events/epoll/file.rs:64-125
    /\ ThreadSyscallIdle(t)
    /\ outer /= inner
    /\ <<inner, outer>> \notin epollGraph
    /\ <<outer, inner>> \notin epollGraph
    /\ epollGraph' = epollGraph \cup {<<outer, inner>>}
    /\ UNCHANGED <<fdVars, epollVars, readinessVars, signalVars, waitVars,
                    heldLocks, lockOwner, callbackStage,
                    callbackKey, epollReadyEpoch, nestedRequiredEpoch,
                    nestedDeliveredEpoch>>

ReadySetPushAcquire(t, k) ==
    \* This lock acquisition is enabled only for a callback that a producer
    \* notification already scheduled; it cannot fabricate readiness.
    \* kernel/core/src/events/subject.rs:126-149
    \* kernel/core/src/events/epoll/entry.rs:280-283,307-325
    /\ callbackEpoch[k] > 0
    /\ callbackActor[k] = t
    /\ callbackStage[t] = "idle"
    \* Observer::is_enabled is checked before ReadySet::entries is locked.
    \* A callback that fails this check takes ReadySetPushSuppressed instead.
    \* kernel/core/src/events/epoll/entry.rs:307-320
    /\ k \in registered
    /\ entryEnabled[k]
    /\ lockOwner[ReadyLock(k.epoll)] = NoThread
    /\ lockOwner' = [lockOwner EXCEPT ![ReadyLock(k.epoll)] = t]
    /\ heldLocks' = [heldLocks EXCEPT ![t] = @ \cup {ReadyLock(k.epoll)}]
    /\ callbackStage' = [callbackStage EXCEPT ![t] = "locked"]
    /\ callbackKey' = [callbackKey EXCEPT ![t] = k]
    /\ UNCHANGED <<fdVars, epollVars, readinessVars, signalVars, waitVars,
                    epollGraph, epollReadyEpoch,
                    nestedRequiredEpoch, nestedDeliveredEpoch>>

ReadySetPushNotifySubject(t, ep) ==
    \* ReadySet::push calls Pollee::notify while still holding entries; the
    \* notification acquires SyncSubject.observers
    \* (events/epoll/entry.rs:320-330; events/subject.rs:126-149).
    /\ callbackStage[t] = "queued"
    /\ callbackKey[t].epoll = ep
    /\ ReadyLock(ep) \in heldLocks[t]
    /\ lockOwner[SubjectLock(ep)] = NoThread
    /\ lockOwner' = [lockOwner EXCEPT ![SubjectLock(ep)] = t]
    /\ heldLocks' = [heldLocks EXCEPT ![t] = @ \cup {SubjectLock(ep)}]
    /\ callbackStage' = [callbackStage EXCEPT ![t] = "subject"]
    \* A registered outer epoll observer receives the exact inner epoll-ready
    \* epoch produced by this notification.
    \* kernel/core/src/events/subject.rs:136-149
    /\ nestedRequiredEpoch' = [edge \in (Epolls \X Epolls) |->
          IF edge \in epollGraph /\ edge[2] = ep
          THEN epollReadyEpoch[ep]
          ELSE nestedRequiredEpoch[edge]]
    /\ UNCHANGED <<fdVars, epollVars, readinessVars, signalVars, waitVars,
                    epollGraph, callbackKey,
                    epollReadyEpoch, nestedDeliveredEpoch>>

SyncSubjectCallbackReadySet(t, inner, outer) ==
    \* kernel/core/src/events/subject.rs:136-149
    \* kernel/core/src/events/epoll/entry.rs:280-325
    \* A nested epoll observer callback runs synchronously under the inner
    \* subject lock and may acquire the outer ready-set lock
    \* (events/subject.rs:136-149; events/epoll/entry.rs:280-283,307-325).
    /\ <<outer, inner>> \in epollGraph
    /\ callbackStage[t] = "subject"
    /\ callbackKey[t].epoll = inner
    /\ SubjectLock(inner) \in heldLocks[t]
    /\ nestedRequiredEpoch[<<outer, inner>>]
          > nestedDeliveredEpoch[<<outer, inner>>]
    /\ lockOwner[ReadyLock(outer)] = NoThread
    /\ lockOwner' = [lockOwner EXCEPT ![ReadyLock(outer)] = t]
    /\ heldLocks' = [heldLocks EXCEPT ![t] = @ \cup {ReadyLock(outer)}]
    /\ callbackStage' = [callbackStage EXCEPT ![t] = "nested"]
    /\ nestedDeliveredEpoch' = [nestedDeliveredEpoch EXCEPT
          ![<<outer, inner>>] = nestedRequiredEpoch[<<outer, inner>>]]
    /\ epollReadyEpoch' = [epollReadyEpoch EXCEPT ![outer] = @ + 1]
    /\ UNCHANGED <<fdVars, epollVars, readinessVars, signalVars, waitVars,
                    epollGraph, callbackKey,
                    nestedRequiredEpoch>>

ObserverCallbackRelease(t) ==
    \* Callback/notify scopes release their spin guards on return
    \* (events/subject.rs:126-153; events/epoll/entry.rs:307-331).
    /\ callbackStage[t] \in {"subject", "nested"}
    \* SyncSubject invokes every selected observer before the subject guard
    \* can leave scope. A pending bounded outer callback must therefore run
    \* before release; this is not a test-controller completion.
    \* kernel/core/src/events/subject.rs:126-153
    /\ (callbackStage[t] = "nested"
        \/ /\ callbackStage[t] = "subject"
           /\ \A edge \in (Epolls \X Epolls) :
                 edge \in epollGraph /\ edge[2] = callbackKey[t].epoll
                 => nestedDeliveredEpoch[edge] >= nestedRequiredEpoch[edge])
    /\ lockOwner' = [l \in LockNames |->
          IF lockOwner[l] = t THEN NoThread ELSE lockOwner[l]]
    /\ heldLocks' = [heldLocks EXCEPT ![t] = {}]
    /\ callbackStage' = [callbackStage EXCEPT ![t] = "idle"]
    /\ callbackKey' = [callbackKey EXCEPT ![t] = NoKey]
    \* Returning from the selected Entry observer discharges that key's
    \* eventfd notify obligation while the counter mutex remains owned.
    \* kernel/core/src/syscall/eventfd.rs:124-159
    \* kernel/core/src/events/subject.rs:136-153
    /\ eventNotifyKeys' = eventNotifyKeys \ {callbackKey[t]}
    /\ signalNotifyKeys' =
          IF signalNotify[t].phase = "callbacks"
          THEN [signalNotifyKeys EXCEPT ![t] = @ \ {callbackKey[t]}]
          ELSE signalNotifyKeys
    /\ UNCHANGED <<fdVars, epollVars, sourceReady, sourceEpoch, readyEpoch,
                    callbackEpoch, callbackActor, queuedEpoch, deliveredEpoch,
                    consumerReadyEpoch, cacheState, directRegistered, notified,
                    observedReady, observedEpoch, timerTicks, eventCounter,
                    pollLocal, producerPhase, eventNotifyWaiters,
                    eventNotifyCounter, signalMask, threadPending,
                    processPending, pollerBindings, signalNotify,
                    signalNotifyWaiters, threadSignalEnqueueEpoch,
                    threadSignalNotifyEpoch, processSignalEnqueueEpoch,
                    processSignalNotifyEpoch, waitVars,
                    epollGraph, epollReadyEpoch,
                    nestedRequiredEpoch, nestedDeliveredEpoch>>

(***************************************************************************)
(* Next                                                                    *)
(***************************************************************************)

Next ==
    \/ \E t \in Threads, fd \in FDs, o \in OFDs, c \in BOOLEAN :
          FileTableInsert(t, fd, o, c)
    \/ \E t \in Threads, fd \in FDs, s \in BOOLEAN :
          FcntlSetFlCapture(t, fd, s)
    \/ \E t \in Threads : FcntlSetFlUse(t)
    \/ \E t \in Threads, fd \in FDs : SysCloseRemove(t, fd)
    \/ \E t \in Threads : ClosedFileDrop(t)
    \/ \E t \in Threads, fd \in FDs : SysDup2Equal(t, fd)
    \/ \E t \in Threads, src \in FDs, dst \in FDs, c \in BOOLEAN :
          SysDup3Validate(t, src, dst, c)
    \/ \E t \in Threads : FileTableDupExact(t)
    \/ \E t \in Threads : FileTableDupExactBadFd(t)
    \/ \E t \in Threads : DupReplacementCleanup(t)
    \/ \E t \in Threads, src \in FDs, dst \in FDs, c \in BOOLEAN :
          FileTableDupCeil(t, src, dst, c)
    \/ \E t \in Threads, fd \in FDs, c \in BOOLEAN : FcntlSetFd(t, fd, c)
    \/ \E t \in Threads, first \in FDs, last \in FDs :
          SysCloseRangeCloexec(t, first, last)
    \/ \E t \in Threads : ExecveWaitOtherThreadsExit(t)
    \/ \E t \in Threads : ContextUnshareFiles(t)
    \/ \E t \in Threads : FileTableCloseFilesOnExec(t)
    \/ \E t \in Threads, ep \in Epolls, fd \in FDs,
          cmd \in {"add", "del", "mod"}, mode \in TriggerModes :
          EpollControlCaptureTarget(t, ep, fd, cmd, mode)
    \/ \E t \in Threads : EpollAddInterest(t)
    \/ \E t \in Threads : EpollModInterest(t)
    \/ \E t \in Threads : EpollDelInterest(t)
    \/ \E t \in Threads : EpollControlError(t)
    \/ \E t \in Threads : EntryUpdatePoll(t)
    \/ \E t \in Threads : EpollControlPushReady(t)
    \/ \E t \in Threads, k \in InterestKeys : ReadySetPush(t, k)
    \/ \E t \in Threads, k \in InterestKeys : ReadySetPushSuppressed(t, k)
    \/ \E t \in Threads, k \in InterestKeys : ReadySetPopDeleted(t, k)
    \/ \E t \in Threads, k \in InterestKeys : ReadySetPop(t, k)
    \/ \E t \in Threads : EntryPollDeadFile(t)
    \/ \E t \in Threads : EntryPollDisabled(t)
    \/ \E t \in Threads : EntryPollPrepare(t)
    \/ \E t \in Threads : EpollDiscardEmptyPreparation(t)
    \/ \E t \in Threads : DoEpollPwait2CopyoutSuccess(t)
    \/ \E t \in Threads : DoEpollPwait2CopyoutFault(t)
    \/ \E t \in Threads, o \in OFDs : PolleePollWithRegister(t, o)
    \/ \E t \in Threads : PolleePollWithLoad(t)
    \/ \E t \in Threads : PolleePollWithCached(t)
    \/ \E t \in Threads : PolleePollWithBeginCheck(t)
    \/ \E t \in Threads : PolleePollWithCheck(t)
    \/ \E t \in Threads : PolleePollWithCache(t)
    \/ \E t \in Threads : PolleePollWithConcurrentCheck(t)
    \/ \E t \in Threads : PolleePollWithFinish(t)
    \/ \E t \in Threads : TimerfdExpired(t)
    \/ \E t \in Threads : TimerfdNotify(t)
    \/ \E t \in Threads : TimerfdTryRead(t)
    \/ \E t \in Threads : TimerfdSetTimeDisarm(t)
    \/ \E t \in Threads : EventfdAddCounter(t)
    \/ \E t \in Threads : EventfdTryRead(t)
    \/ \E t \in Threads : EventfdNotify(t)
    \/ \E t \in Threads : EventfdNotifyReturn(t)
    \/ \E t \in Threads, enabled \in BOOLEAN : SignalfdUpdateMask(t, enabled)
    \/ \E actor \in Threads, target \in Threads :
          SigQueuesEnqueueThread(actor, target)
    \/ \E t \in Threads : SigQueuesEnqueueProcess(t)
    \/ \E t \in Threads : SigQueuesNotifyThread(t)
    \/ \E t \in Threads : SigQueuesNotifyProcess(t)
    \/ \E t \in Threads : SigQueuesNotifyReturn(t)
    \/ \E t \in Threads : SignalFileReadThread(t)
    \/ \E t \in Threads : SignalFileReadProcess(t)
    \/ \E t \in Threads, ep \in Epolls : EpollWaitRegisterConsumer(t, ep)
    \/ \E t \in Threads, m \in MaskStates : SaveAndSetSigMask(t, m)
    \/ \E t \in Threads : PollFilesRegisterPoller(t)
    \/ \E t \in Threads : PollFilesInitialReady(t)
    \/ \E t \in Threads : WaiterPauseTimeoutBlock(t)
    \/ \E actor \in Threads, target \in Threads :
          WaiterReadinessWake(actor, target)
    \/ \E actor \in Threads, target \in Threads :
          WaiterTimeoutExpires(actor, target)
    \/ \E actor \in Threads, target \in Threads :
          WaiterSignalInterrupts(actor, target)
    \/ \E t \in Threads : WaiterPauseTimeoutReturnTimeout(t)
    \/ \E t \in Threads : WaiterPauseTimeoutReturnSignal(t)
    \/ \E t \in Threads : DoPollCountEvents(t)
    \/ \E t \in Threads : HandlePendingSignalRestoreMask(t)
    \/ \E t \in Threads, outer \in Epolls, inner \in Epolls :
          EpollAddNestedInterest(t, outer, inner)
    \/ \E t \in Threads, k \in InterestKeys : ReadySetPushAcquire(t, k)
    \/ \E t \in Threads, ep \in Epolls : ReadySetPushNotifySubject(t, ep)
    \/ \E t \in Threads, inner \in Epolls, outer \in Epolls :
          SyncSubjectCallbackReadySet(t, inner, outer)
    \/ \E t \in Threads : ObserverCallbackRelease(t)

Spec == Init /\ [][Next]_allVars

(***************************************************************************)
(* Structural and core safety invariants.                                 *)
(***************************************************************************)

TypeOK ==
    \* File-table slot and OFD identity domains.
    \* kernel/core/src/fs/file/file_table.rs:100-205,372-405
    /\ slots \in [FDs -> OFDs \cup {NoOFD}]
    /\ slotFlags \in [FDs -> BOOLEAN]
    /\ slotEpoch \in [FDs -> Nat]
    /\ ofdStatus \in [OFDs -> BOOLEAN]
    /\ ofdAlive \in [OFDs -> BOOLEAN]
    /\ captured \in [Threads -> OFDs \cup {NoOFD}]
    /\ capturedFd \in [Threads -> FDs \cup {NoFD}]
    /\ capturedStatus \in [Threads -> BOOLEAN]
    /\ captureEpoch \in [Threads -> Nat]
    /\ lastCaptured \in [Threads -> OFDs \cup {NoOFD}]
    /\ actedOFD \in [Threads -> OFDs \cup {NoOFD}]
    /\ actedSlotOFD \in [Threads -> OFDs \cup {NoOFD}]
    /\ actedCaptureEpoch \in [Threads -> Nat]
    /\ actedSlotEpoch \in [Threads -> Nat]
    /\ closePending \in [Threads -> OFDs \cup {NoOFD}]
    /\ replacement \in [Threads -> ReplacementStates]
    /\ sharedTable \in BOOLEAN
    /\ execPhase \in {"idle", "quiesced", "snapshotted", "closed"}
    /\ execOwner \in Threads \cup {NoThread}
    /\ execPrivateSlots \in [FDs -> OFDs \cup {NoOFD}]
    /\ execPrivateFlags \in [FDs -> BOOLEAN]
    /\ execPrivateEpoch \in [FDs -> Nat]
    /\ execPrivateSlotMapAudit \in [FDs -> OFDs \cup {NoOFD}]
    /\ execSnapshotSlots \in [FDs -> OFDs \cup {NoOFD}]
    /\ execSnapshotFlags \in [FDs -> BOOLEAN]
    /\ execExternalAudit \in ExecExternalAuditStates
    /\ fdFlagAudit \in FdFlagAuditStates
    /\ slotMapAudit \in [FDs -> OFDs \cup {NoOFD}]
    /\ interest \subseteq InterestKeys
    /\ readyQ \subseteq InterestKeys
    /\ entryEnabled \in [InterestKeys -> BOOLEAN]
    /\ triggerMode \in [InterestKeys -> TriggerModes]
    /\ registered \subseteq InterestKeys
    /\ keySlotEpoch \in [InterestKeys -> Nat]
    /\ interestIdentity \in [InterestKeys -> InterestIdentityStates]
    /\ ctl \in [Threads -> CtlStates]
    /\ delivery \in [Threads -> DeliveryStates]
    /\ copyoutOk \in [Threads -> {"none", "success", "fault"}]
    /\ deliveredKeys \subseteq InterestKeys
    /\ faultedUndelivered \subseteq InterestKeys
    /\ lastDeliveredKey \in [Threads -> InterestKeys \cup {NoKey}]
    /\ reportedOFD \in [Threads -> OFDs \cup {NoOFD}]
    /\ epollWaiter \in [Epolls -> Threads \cup {NoThread}]
    /\ epollWake \in [Epolls -> BOOLEAN]
    /\ sourceReady \in [OFDs -> BOOLEAN]
    \* Producer, callback, queue, observation, and delivery epochs.
    \* kernel/core/src/process/signal/poll.rs:167-178
    \* kernel/core/src/events/epoll/entry.rs:280-330,367-397
    /\ sourceEpoch \in [OFDs -> Nat]
    /\ readyEpoch \in [InterestKeys -> Nat]
    /\ callbackEpoch \in [InterestKeys -> Nat]
    /\ callbackActor \in [InterestKeys -> Threads \cup {NoThread}]
    /\ queuedEpoch \in [InterestKeys -> Nat]
    /\ deliveredEpoch \in [InterestKeys -> Nat]
    /\ consumerReadyEpoch \in [Bindings -> Nat]
    /\ cacheState \in [OFDs -> CacheStates]
    /\ directRegistered \subseteq PollRegistrations
    /\ notified \subseteq InterestKeys
    /\ observedReady \subseteq PollRegistrations
    /\ observedEpoch \in [PollRegistrations -> Nat]
    /\ timerTicks \in 0..MaxTimerTicks
    /\ eventCounter \in 0..MaxEventCounter
    /\ pollLocal \in [Threads -> PollLocalStates]
    /\ producerPhase \in
          [Threads -> {"idle", "timer_notify", "event_notify",
                       "event_callbacks"}]
    /\ eventNotifyKeys \subseteq InterestKeys
    /\ eventNotifyWaiters \subseteq Threads
    /\ eventNotifyCounter \in 0..MaxEventCounter
    /\ signalMask \in [OFDs -> BOOLEAN]
    /\ threadPending \in [Threads -> BOOLEAN]
    /\ processPending \in BOOLEAN
    /\ pollerBindings \subseteq Bindings
    /\ signalNotify \in [Threads -> SignalNotifyStates]
    /\ signalNotifyKeys \in [Threads -> SUBSET InterestKeys]
    /\ signalNotifyWaiters \in [Threads -> SUBSET Threads]
    /\ threadSignalEnqueueEpoch \in [Threads -> Nat]
    /\ threadSignalNotifyEpoch \in [Threads -> Nat]
    /\ processSignalEnqueueEpoch \in Nat
    /\ processSignalNotifyEpoch \in Nat
    /\ waitState \in [Threads -> WaitStates]
    /\ wakeCause \in [Threads -> WakeCauses]
    /\ deadlineExpired \in [Threads -> BOOLEAN]
    /\ interruptPending \in [Threads -> BOOLEAN]
    /\ visibleReady \in [Threads -> BOOLEAN]
    /\ terminalReady \in [Threads -> BOOLEAN]
    /\ terminalScanValid \in [Threads -> BOOLEAN]
    /\ terminalScanExpected \in [Threads -> BOOLEAN]
    /\ currentMask \in [Threads -> MaskStates]
    /\ savedMask \in [Threads -> MaskStates \cup {"none"}]
    /\ preWaitMask \in [Threads -> MaskStates]
    /\ returnReason \in [Threads -> ReturnReasons]
    /\ waitReadyToken \in [Threads -> WaitReadyTokenStates]
    /\ lastReadyWake \in [Threads -> WaitReadyTokenStates]
    /\ waitCapturedOFDs \in [Threads -> SUBSET OFDs]
    /\ waitCaptureAudit \in [Threads -> SUBSET OFDs]
    /\ waitCapturedSlots \in [Threads -> [FDs -> OFDs \cup {NoOFD}]]
    /\ waitCaptureSlotAudit \in
          [Threads -> [FDs -> OFDs \cup {NoOFD}]]
    /\ lastReleasedWaitOFDs \in [Threads -> SUBSET OFDs]
    /\ lastReleasedWaitSlots \in
          [Threads -> [FDs -> OFDs \cup {NoOFD}]]
    /\ waitGeneration \in [Threads -> Nat]
    /\ completedWaitReason \in [Threads -> ReturnReasons]
    /\ lastCompletedWaitReason \in [Threads -> ReturnReasons]
    /\ epollGraph \subseteq (Epolls \X Epolls)
    /\ heldLocks \in [Threads -> SUBSET LockNames]
    /\ lockOwner \in [LockNames -> Threads \cup {NoThread}]
    /\ callbackStage \in
          [Threads -> {"idle", "locked", "queued", "subject", "nested"}]
    /\ callbackKey \in [Threads -> InterestKeys \cup {NoKey}]
    /\ epollReadyEpoch \in [Epolls -> Nat]
    /\ nestedRequiredEpoch \in [(Epolls \X Epolls) -> Nat]
    /\ nestedDeliveredEpoch \in [(Epolls \X Epolls) -> Nat]

NoPhantomLiveOFD ==
    \* Every live modeled allocation must still have a FileTableEntry or an
    \* in-flight owned/Cow reference. Weak epoll keys do not keep it alive.
    \* kernel/core/src/fs/file/file_table.rs:169-205,274-302,326-367
    \* kernel/core/src/events/epoll/entry.rs:46-67,103-109
    \A o \in OFDs : ofdAlive[o] => ofdRefs(o) > 0

NoDeadOFDReference ==
    \* Once Arc strong count reaches zero, no modeled strong-reference holder
    \* may still name that allocation.
    \* kernel/core/src/fs/file/file_table.rs:169-205,274-302,326-367
    \A o \in OFDs : ~ofdAlive[o] => ofdRefs(o) = 0

OFDsNeverResurrect ==
    \* A dropped Arc allocation identity cannot become live again. A later
    \* file installation must use a distinct allocation identity.
    \* kernel/core/src/fs/file/file_table.rs:190-194,274-302
    \A o \in OFDs : [](~ofdAlive[o] => []~ofdAlive[o])

OccupiedSlotsReferToAliveOFDs ==
    \* A FileTableEntry owns a strong Arc.
    \* The installed exec-private table is an independent owner after cutover.
    \* kernel/core/src/fs/file/file_table.rs:117-121,181-205,372-386
    /\ (execPhase \notin {"snapshotted", "closed"}
        \/ execExternalAudit.oldTableRetained)
       => \A fd \in FDs : slots[fd] /= NoOFD => ofdAlive[slots[fd]]
    /\ execPhase \in {"snapshotted", "closed"}
       => \A fd \in FDs :
            execPrivateSlots[fd] /= NoOFD
            => ofdAlive[execPrivateSlots[fd]]

ReadyQueueKeysRemainIdentityTyped ==
    \* Ready tokens retain Entry identity even after weak upgrade can fail.
    \* kernel/core/src/events/epoll/entry.rs:357-397
    readyQ \subseteq InterestKeys

LockOwnershipConsistent ==
    \* ReadySet entries and SyncSubject observers are the two callback locks.
    \* kernel/core/src/events/epoll/entry.rs:307-330
    \* kernel/core/src/events/subject.rs:126-149
    /\ \A t \in Threads, l \in LockNames :
          (l \in heldLocks[t]) <=> (lockOwner[l] = t)
    /\ \A l \in LockNames :
          lockOwner[l] = NoThread \/ lockOwner[l] \in Threads

EventfdMutexExclusive ==
    \* EventFile's one counter Mutex covers the mutation and synchronous notify
    \* call. The counter snapshot and exact selected callback obligations make
    \* an early owner release or a second mutation observable.
    \* kernel/core/src/syscall/eventfd.rs:124-159
    LET owners == {t \in Threads :
                      producerPhase[t] \in
                          {"event_notify", "event_callbacks"}}
    IN
    /\ Cardinality(owners) <= 1
    /\ (owners = {})
          => /\ eventNotifyKeys = {}
             /\ eventNotifyWaiters = {}
             /\ eventNotifyCounter = 0
    /\ \A t \in owners :
          /\ eventNotifyCounter = eventCounter
          /\ \A k \in eventNotifyKeys :
                /\ k.ofd = EventOFD
                /\ \/ /\ callbackEpoch[k] > 0
                          /\ callbackActor[k] = t
                   \/ /\ callbackStage[t] /= "idle"
                          /\ callbackKey[t] = k
          /\ \A w \in eventNotifyWaiters :
                /\ waitReadyToken[w].ofd = EventOFD
                /\ waitReadyToken[w].actor = t
                /\ waitReadyToken[w].epoch > 0

AcyclicEpollGraph ==
    \* Cyclic nesting is unsupported in this checkout. The checked production
    \* subset contains only successful acyclic insertions; this safety oracle
    \* reports a cycle if a modeled mutation ever creates one.
    \* kernel/core/src/events/epoll/file.rs:64-125
    /\ \A e \in Epolls : <<e, e>> \notin epollGraph
    /\ \A outer, inner \in Epolls :
          <<outer, inner>> \in epollGraph
          => <<inner, outer>> \notin epollGraph

SignalNotifyOrdering ==
    \* Notify cannot overtake the successful enqueue whose epoch it carries.
    \* A pending continuation retains the exact queue and producer epoch until
    \* the unlocked notification and all selected callbacks return.
    \* kernel/core/src/process/signal/sig_queues.rs:38-45
    \* kernel/core/src/events/subject.rs:126-153
    /\ processSignalNotifyEpoch <= processSignalEnqueueEpoch
    /\ \A target \in Threads :
          threadSignalNotifyEpoch[target]
              <= threadSignalEnqueueEpoch[target]
    /\ \A actor \in Threads :
          LET n == signalNotify[actor] IN
          /\ (n.phase = "idle")
                => /\ n = EmptySignalNotify
                   /\ signalNotifyKeys[actor] = {}
                   /\ signalNotifyWaiters[actor] = {}
          /\ (n.phase = "pending")
                => /\ n.epoch > 0
                   /\ signalNotifyKeys[actor] = {}
                   /\ signalNotifyWaiters[actor] = {}
                   /\ IF n.queue = "thread"
                      THEN /\ n.target \in Threads
                           /\ n.epoch = threadSignalEnqueueEpoch[n.target]
                           /\ threadSignalNotifyEpoch[n.target] < n.epoch
                      ELSE /\ n.queue = "process"
                           /\ n.target = NoThread
                           /\ n.epoch = processSignalEnqueueEpoch
                           /\ processSignalNotifyEpoch < n.epoch
          /\ (n.phase = "callbacks")
                => /\ n.epoch > 0
                   /\ IF n.queue = "thread"
                      THEN /\ n.target \in Threads
                           /\ threadSignalNotifyEpoch[n.target] = n.epoch
                      ELSE /\ n.queue = "process"
                           /\ n.target = NoThread
                           /\ processSignalNotifyEpoch = n.epoch

(***************************************************************************)
(* Scenario invariants from modeling brief section 5.                     *)
(***************************************************************************)

SlotMapsOneOFD ==
    \* The production table mutation and an independently maintained shadow
    \* must agree after every insert/remove/replace/exec scan. A controller can
    \* redirect one in-domain slot while TypeOK remains true.
    \* kernel/core/src/fs/file/file_table.rs:139-205,208-234
    /\ slots = slotMapAudit
    /\ \A fd \in FDs : slots[fd] = NoOFD => ~slotFlags[fd]
    /\ execPhase \in {"snapshotted", "closed"}
       => /\ execPrivateSlots = execPrivateSlotMapAudit
          /\ \A fd \in FDs :
                execPrivateSlots[fd] = NoOFD => ~execPrivateFlags[fd]

CapturedReferenceStable ==
    \* Only an actual slot-generation change activates the reuse witness. The
    \* acted object must remain the pre-reuse capture, not the current slot.
    \* kernel/core/src/syscall/fcntl.rs:87-94
    \* kernel/core/src/fs/file/file_table.rs:335-367
    \A t \in Threads :
        actedOFD[t] = NoOFD
        \/ ((actedCaptureEpoch[t] /= actedSlotEpoch[t]
             /\ actedSlotOFD[t] /= NoOFD
             /\ actedSlotOFD[t] /= lastCaptured[t])
            => /\ actedOFD[t] = lastCaptured[t]
               /\ actedOFD[t] /= actedSlotOFD[t])

ReplacementExactlyOnce ==
    \* dup_exact clones the source and removes at most one target under one
    \* write guard; the optional ClosedFile is dropped once afterward.
    \* kernel/core/src/fs/file/file_table.rs:169-187
    \* kernel/core/src/syscall/dup.rs:73-78
    \A t \in Threads :
        replacement[t].phase = "cleanup" =>
          /\ replacement[t].sourceFd /= replacement[t].targetFd
          /\ replacement[t].sourceOFD \in OFDs
          /\ closePending[t] = replacement[t].replacedOFD
          /\ (replacement[t].removedCount = 0
                <=> replacement[t].replacedOFD = NoOFD)
          /\ (replacement[t].removedCount = 1
                <=> replacement[t].replacedOFD \in OFDs)

FdFlagsPerSlot ==
    \* The last F_SETFD mutation records an aliased peer's pre-state. While
    \* both slot generations still name the same OFD, only the target entry may
    \* change; the peer's descriptor flag must remain independent.
    \* kernel/core/src/fs/file/file_table.rs:181-187,372-404
    \* kernel/core/src/syscall/fcntl.rs:61-73
    ~fdFlagAudit.active
    \/ LET a == fdFlagAudit IN
       (slots[a.target] = a.ofd /\ slots[a.peer] = a.ofd
        /\ slotEpoch[a.target] = a.targetEpoch
        /\ slotEpoch[a.peer] = a.peerEpoch)
       => /\ slotFlags[a.target] = a.requested
          /\ slotFlags[a.peer] = a.peerBefore

AliasedDescriptorFlagWitness ==
    \* This reachability witness requires F_SETFD to mutate one of two
    \* FileTableEntry values sharing one OFD after a shared F_SETFL mutation.
    \* kernel/core/src/fs/file/file_table.rs:181-187,372-404
    \* kernel/core/src/syscall/fcntl.rs:61-94
    /\ fdFlagAudit.active
    /\ LET a == fdFlagAudit IN
          /\ slots[a.target] = a.ofd
          /\ slots[a.peer] = a.ofd
          /\ slotEpoch[a.target] = a.targetEpoch
          /\ slotEpoch[a.peer] = a.peerEpoch
          /\ slotFlags[a.target] = a.requested
          /\ slotFlags[a.peer] = a.peerBefore
          /\ slotFlags[a.target] /= slotFlags[a.peer]
          /\ ofdStatus[a.ofd]

PollSnapshotSurvivesClose ==
    \* Non-vacuity witness: the numeric slot and deferred ClosedFile owner are
    \* both gone while PollFiles::Owned still keeps the captured OFD alive.
    \* kernel/core/src/syscall/poll.rs:96-101,124-155
    \* kernel/core/src/syscall/close.rs:25-40
    \E t \in Threads, o \in OFDs :
        /\ waitState[t] \in {"registered", "blocked", "woken"}
        /\ o \in waitCapturedOFDs[t]
        /\ o \in waitCaptureAudit[t]
        /\ \E fd \in FDs : waitCapturedSlots[t][fd] = o
        /\ ~\E fd \in FDs : slots[fd] = o
        /\ ~\E actor \in Threads : closePending[actor] = o
        /\ ofdAlive[o]

PollSnapshotReleasedAfterClose ==
    \* A terminal path releases the same last owner after the close/drop
    \* witness, so the retired OFD cannot remain phantom-live.
    \* kernel/core/src/syscall/poll.rs:103-121
    \E t \in Threads, o \in OFDs :
        /\ waitState[t] \in {"syscall_done", "returned"}
        /\ o \in lastReleasedWaitOFDs[t]
        /\ \E fd \in FDs : lastReleasedWaitSlots[t][fd] = o
        /\ ~\E fd \in FDs : slots[fd] = o
        /\ ~ofdAlive[o]

FreshSecondWaitAfterTimeout ==
    \* kernel/core/src/syscall/poll.rs:88-121
    \* kernel/core/src/process/signal/pause.rs:202-209
    \E t \in Threads :
        /\ waitGeneration[t] > 1
        /\ lastCompletedWaitReason[t] = "timeout"
        /\ waitState[t] = "registered"
        /\ FreshWaitFields(t)

FreshSecondWaitAfterSignal ==
    \* kernel/core/src/syscall/poll.rs:88-121
    \* kernel/core/src/process/signal/pause.rs:211-219
    \E t \in Threads :
        /\ waitGeneration[t] > 1
        /\ lastCompletedWaitReason[t] = "signal"
        /\ waitState[t] = "registered"
        /\ FreshWaitFields(t)

ExecBeforeCutoverDupCaptured ==
    \* An external mutation that wins before FileTable::fork_from's read lock
    \* is included in the atomically installed private snapshot.
    \* kernel/core/src/process/namespace/unshare.rs:18-28
    \* kernel/core/src/fs/file/file_table.rs:139-165
    /\ execExternalAudit.beforeDup
    /\ execPhase = "snapshotted"
    /\ \E sourceFd, targetFd \in FDs :
          /\ sourceFd /= targetFd
          /\ execSnapshotSlots[sourceFd] /= NoOFD
          /\ execSnapshotSlots[targetFd] = execSnapshotSlots[sourceFd]
          /\ execPrivateSlots[targetFd] = execSnapshotSlots[targetFd]

ExecAfterCutoverDupIsolated ==
    \* The same old-table duplication after install must not appear in the
    \* execing task's private table.
    \* kernel/core/src/process/namespace/unshare.rs:18-28
    \* kernel/core/src/fs/file/file_table.rs:139-165
    /\ execExternalAudit.afterDup
    /\ execPhase = "snapshotted"
    /\ execPrivateSlots = execSnapshotSlots
    /\ \E fd \in FDs : slots[fd] /= execPrivateSlots[fd]

ExecBeforeCutoverCloexecCaptured ==
    \* kernel/core/src/process/namespace/unshare.rs:18-28
    \* kernel/core/src/syscall/close.rs:76-101
    /\ execExternalAudit.beforeCloexec
    /\ execPhase = "snapshotted"
    /\ \E fd \in FDs :
          execSnapshotSlots[fd] /= NoOFD /\ execSnapshotFlags[fd]
          /\ execPrivateFlags[fd]

ExecAfterCutoverCloexecIsolated ==
    \* kernel/core/src/process/namespace/unshare.rs:18-28
    \* kernel/core/src/syscall/close.rs:76-101
    /\ execExternalAudit.afterCloexec
    /\ execPhase = "snapshotted"
    /\ \E fd \in FDs :
          /\ slots[fd] /= NoOFD
          /\ slotFlags[fd]
          /\ ~execPrivateFlags[fd]

ExecPrivateFinalDropWitness ==
    \* With no external CLONE_FILES owner, close_files_on_exec can release the
    \* last private-table Arc for a snapshot-marked OFD exactly once.
    \* kernel/core/src/process/namespace/unshare.rs:18-28
    \* kernel/core/src/process/execve.rs:378-386
    /\ execPhase = "closed"
    /\ ~execExternalAudit.oldTableRetained
    /\ \E o \in OFDs : ExecReleasedRefs(o) > 0 /\ ~ofdAlive[o]

ExecClosesExactlySnapshotMarked ==
    \* exec unshares, then close_files_on_exec removes precisely the marked
    \* entries from that snapshot.
    \* kernel/core/src/process/execve.rs:378-386
    \* kernel/core/src/fs/file/file_table.rs:208-234
    execPhase = "closed" =>
      /\ execPrivateSlots = ExpectedExecSlots
      /\ execPrivateFlags = ExpectedExecFlags

ExecCutoverIsolation ==
    \* unshare_files installs a completed clone. External CLONE_FILES users
    \* may mutate only the old RwArc afterward; the execing task's private
    \* table remains the cutover snapshot until close_files_on_exec.
    \* kernel/core/src/process/namespace/unshare.rs:18-28
    \* kernel/core/src/process/clone.rs:738-745
    /\ (execPhase \in {"snapshotted", "closed"}) => ~sharedTable
    /\ (execPhase = "snapshotted")
          => /\ execPrivateSlots = execSnapshotSlots
             /\ execPrivateFlags = execSnapshotFlags
             /\ execPrivateSlotMapAudit = execSnapshotSlots
    /\ (execPhase = "closed")
          => /\ execPrivateSlots = ExpectedExecSlots
             /\ execPrivateFlags = ExpectedExecFlags
             /\ execPrivateSlotMapAudit = ExpectedExecSlots

PollSnapshotOwnershipStable ==
    \* CowFiles::Owned retains exactly the cloned Arc set until do_poll takes
    \* a terminal return. The independent audit makes omission/early release
    \* observable without a type failure.
    \* kernel/core/src/syscall/poll.rs:96-101,124-155
    \A t \in Threads :
        waitState[t] \in {"registered", "blocked", "woken"}
        => /\ waitCapturedOFDs[t] = waitCaptureAudit[t]
           /\ waitCapturedSlots[t] = waitCaptureSlotAudit[t]
           /\ waitCapturedOFDs[t] =
                 {waitCapturedSlots[t][fd] :
                     fd \in {d \in FDs :
                         waitCapturedSlots[t][d] /= NoOFD}}
           /\ \A o \in waitCaptureAudit[t] : ofdAlive[o]

PollSnapshotReleasedOnTerminal ==
    \* The PollFiles local leaves scope on ready, timeout, interruption, or
    \* syscall error before signal-mask return cleanup finishes.
    \* kernel/core/src/syscall/poll.rs:103-121
    \A t \in Threads :
        waitState[t] \in {"syscall_done", "returned"}
        => /\ waitCapturedOFDs[t] = {}
           /\ waitCaptureAudit[t] = {}
           /\ waitCapturedSlots[t] = EmptyWaitSlotSnapshot
           /\ waitCaptureSlotAudit[t] = EmptyWaitSlotSnapshot

FreshWaitInvocation ==
    \* Every registration after a prior completed wait uses a fresh Poller,
    \* timeout state, result state, and live snapshot.
    \* kernel/core/src/syscall/poll.rs:88-106,165-185
    \* kernel/core/src/process/signal/poll.rs:282-315
    \A t \in Threads :
        waitState[t] = "registered" /\ waitGeneration[t] > 1
        => FreshWaitFields(t)

EpollKeyIdentity ==
    \* The published EntryKey must still match the independent identity copied
    \* from control's captured Arc and slot generation at ADD. This does not
    \* compare the key to the potentially reused current numeric slot.
    \* kernel/core/src/events/epoll/file.rs:65-84,96-120
    \* kernel/core/src/events/epoll/entry.rs:46-67
    \A k \in interest :
        LET capturedIdentity == interestIdentity[k] IN
        /\ capturedIdentity.active
        /\ capturedIdentity.fd = k.fd
        /\ capturedIdentity.ofd = k.ofd
        /\ capturedIdentity.slotEpoch = keySlotEpoch[k]
        /\ capturedIdentity.slotEpoch <= slotEpoch[k.fd]

NoCrossReuseDelivery ==
    \* The obligation is activated only after the registered numeric slot has
    \* advanced to a different live OFD. Copyout must still report the key's
    \* captured OFD identity.
    \* kernel/core/src/events/epoll/entry.rs:46-67,367-397
    \* kernel/core/src/syscall/epoll.rs:145-154
    \A t \in Threads :
        lastDeliveredKey[t] = NoKey
        \/ LET k == lastDeliveredKey[t] IN
           (slotEpoch[k.fd] /= keySlotEpoch[k]
            /\ slots[k.fd] /= NoOFD /\ slots[k.fd] /= k.ofd)
           => /\ reportedOFD[t] = k.ofd
              /\ reportedOFD[t] /= slots[k.fd]

ValidKeyIdentitySurvivesReuse ==
    \* A legal old epoll key remains tied to the ADD-captured OFD/generation
    \* after the same numeric descriptor advances to an unrelated allocation.
    \* kernel/core/src/events/epoll/entry.rs:46-67
    \* kernel/core/src/fs/file/file_table.rs:190-205
    \E k \in interest :
        LET capturedIdentity == interestIdentity[k] IN
        /\ capturedIdentity.active
        /\ capturedIdentity.ofd = k.ofd
        /\ capturedIdentity.slotEpoch = keySlotEpoch[k]
        /\ slotEpoch[k.fd] > capturedIdentity.slotEpoch
        /\ slots[k.fd] /= NoOFD
        /\ slots[k.fd] /= k.ofd

NoDeadInterest ==
    \* Epoll stores only a Weak OFD; after final Arc release, the dead Entry
    \* must not remain indefinitely in the interest set.
    \* kernel/core/src/events/epoll/entry.rs:103-117
    \* kernel/core/src/events/epoll/file.rs:225-233
    \A k \in interest : ofdAlive[k.ofd]

DeliveryCommitOnCopyout ==
    \* Entry::poll mutates ET/one-shot state before write_val; a failed copyout
    \* must leave a recoverable prepared or queued token to satisfy this oracle.
    \* kernel/core/src/events/epoll/entry.rs:116-149
    \* kernel/core/src/syscall/epoll.rs:145-154
    \A k \in faultedUndelivered :
        k \in readyQ
        \/ \E t \in Threads :
             delivery[t].stage = "prepared" /\ delivery[t].key = k

OneShotDisabledIffDelivered ==
    \* One-shot disable occurs only for an event-bearing preparation.
    \* kernel/core/src/events/epoll/entry.rs:143-147
    \A k \in interest :
        triggerMode[k] = "ONESHOT" /\ ~entryEnabled[k]
        => \/ deliveredEpoch[k] >= readyEpoch[k]
           \/ \E t \in Threads :
                /\ delivery[t].stage = "prepared"
                /\ delivery[t].key = k
                /\ delivery[t].hadEvent
                /\ delivery[t].epoch >= readyEpoch[k]

CachedReadinessSound ==
    \* A nonnegative cache is current only if no notify/invalidate intervened.
    \* kernel/core/src/process/signal/poll.rs:43-58,106-151,167-189
    \A o \in {TimerOFD, EventOFD} :
        cacheState[o] = "ready" /\ ProducerQuiescent(o)
        => sourceReady[o]

SignalfdRegistrationHasBinding ==
    \* Entry::update calls SignalFile::poll in its own caller context. The
    \* signal PollHandle must therefore remain attached to at least one
    \* registration thread; a later epoll_wait consumer is not that thread's
    \* substitute for a thread-directed pending signal.
    \* kernel/core/src/events/epoll/entry.rs:155-166
    \* kernel/core/src/syscall/signalfd.rs:207-216
    \A k \in InterestKeys :
        CompletedRegistration(k)
        /\ k.ofd = SignalOFD
        => \E t \in Threads : Binding(k, t) \in pollerBindings

AddUpdatedBeforeInterestInsert ==
    \* ADD calls Entry::update before inserting the new Entry into interest.
    \* This production intermediate is registered but is not yet a completed
    \* registration for consumer-binding purposes.
    \* kernel/core/src/events/epoll/file.rs:96-120
    \* kernel/core/src/events/epoll/entry.rs:155-166
    \E t \in Threads :
        /\ ctl[t].command = "add"
        /\ ctl[t].phase = "insert"
        /\ LET k == Key(ctl[t].epoll, ctl[t].fd, ctl[t].target) IN
              /\ k.ofd = SignalOFD
              /\ k \in registered
              /\ k \notin interest
              /\ epollWaiter[k.epoll] /= NoThread
              /\ signalMask[SignalOFD]
              /\ (threadPending[epollWaiter[k.epoll]] \/ processPending)
              /\ consumerReadyEpoch[
                    Binding(k, epollWaiter[k.epoll])] > 0

TwoCheckersLoadedInvalid ==
    \* Two callers can both finish the Acquire load of INV_STATE before
    \* either swap installs its task identity.
    \* kernel/core/src/process/signal/poll.rs:106-134
    \E first, second \in Threads :
        /\ first /= second
        /\ pollLocal[first].phase = "loaded"
        /\ pollLocal[second].phase = "loaded"
        /\ pollLocal[first].ofd = pollLocal[second].ofd
        /\ pollLocal[first].loaded = "invalid"
        /\ pollLocal[second].loaded = "invalid"

VisibleReadyWinsTerminalRace ==
    \* pause_timeout selects timeout/signal before do_poll can rescan; this
    \* oracle records the Linux-visible ready-wins expectation.
    \* kernel/core/src/process/signal/pause.rs:202-219
    \* kernel/core/src/syscall/poll.rs:108-121
    \A t \in Threads :
        waitState[t] \in {"syscall_done", "returned"}
        /\ terminalScanValid[t] /\ terminalReady[t]
        => returnReason[t] = "ready"

TerminalScanMatchesLiveSnapshot ==
    \* Each terminal branch records the independent live value it observed;
    \* historical Waker state is not accepted as a substitute. The expected
    \* side is an audit snapshot written from the same source-backed scan.
    \* kernel/core/src/syscall/poll.rs:108-121,188-215
    \A t \in Threads :
        terminalScanValid[t]
        => terminalReady[t] = terminalScanExpected[t]

TemporaryMaskRestored ==
    \* RestoreSigMaskGuard restores the saved mask on every return path.
    \* kernel/core/src/process/signal/mod.rs:64-85,208-230
    \A t \in Threads :
        waitState[t] = "returned"
        => /\ currentMask[t] = preWaitMask[t]
           /\ savedMask[t] = "none"

ReadyCallbacksHaveProducerCause ==
    \* A pending callback is created only by Pollee/SigQueues notification and
    \* carries a nonzero producer epoch plus executing actor.
    \* kernel/core/src/process/signal/poll.rs:167-178
    \* kernel/core/src/events/subject.rs:126-149
    \A k \in InterestKeys :
        callbackEpoch[k] > 0
        => /\ callbackActor[k] \in Threads
           /\ callbackEpoch[k] <= sourceEpoch[k.ofd]

ReadinessWakesHaveProducerCause ==
    \* A ready wake records the exact notification token it consumed. The
    \* epoch must have been produced by that OFD before the callback ran.
    \* kernel/core/src/process/signal/poll.rs:167-178,318-321
    \A w \in Threads :
        wakeCause[w] = "ready"
        => /\ lastReadyWake[w].ofd \in OFDs
           /\ lastReadyWake[w].actor \in Threads
           /\ lastReadyWake[w].epoch > 0
           /\ lastReadyWake[w].epoch
                  <= sourceEpoch[lastReadyWake[w].ofd]

ProducerBeforeReadinessWake ==
    \* Non-vacuous reach witness for a producer-scoped callback reaching a
    \* registered waiter after notification.
    \* kernel/core/src/process/signal/poll.rs:154-178,307-321
    \E w \in Threads :
        /\ wakeCause[w] = "ready"
        /\ lastReadyWake[w].epoch > 0
        /\ lastReadyWake[w].epoch
              <= sourceEpoch[lastReadyWake[w].ofd]

DeadBeforeDisabledWitness ==
    \* Entry::poll must take failed weak upgrade before the enabled check even
    \* when the popped entry is also disabled.
    \* kernel/core/src/events/epoll/entry.rs:103-124
    \E t \in Threads :
        /\ delivery[t].stage = "popped"
        /\ ~ofdAlive[delivery[t].key.ofd]
        /\ ~entryEnabled[delivery[t].key]
        /\ ENABLED EntryPollDeadFile(t)
        /\ ~ENABLED EntryPollDisabled(t)

EventfdCallbackScopeWitness ==
    \* During selected callbacks, the notifying actor still owns the counter
    \* Mutex and neither counter-mutating syscall is enabled.
    \* kernel/core/src/syscall/eventfd.rs:124-159
    \E owner \in Threads :
        /\ producerPhase[owner] = "event_callbacks"
        /\ eventNotifyKeys /= {}
        /\ EventfdMutexOwner = owner
        /\ ~\E actor \in Threads :
              \/ ENABLED EventfdAddCounter(actor)
              \/ ENABLED EventfdTryRead(actor)

NestedEpochNeverRegresses ==
    \* Synchronous outer callbacks consume no epoch newer than the one emitted
    \* by the inner epoll Pollee notification.
    \* kernel/core/src/events/epoll/entry.rs:307-330
    \* kernel/core/src/events/subject.rs:126-149
    \A edge \in (Epolls \X Epolls) :
        nestedDeliveredEpoch[edge] <= nestedRequiredEpoch[edge]

(***************************************************************************)
(* Liveness properties from modeling brief section 5.                     *)
(***************************************************************************)

LevelReadyEventuallyRedelivered ==
    \* Historical delivery is deliberately insufficient. While the same LT
    \* readiness epoch remains live, a token carrying that epoch must reappear.
    \* kernel/core/src/events/epoll/entry.rs:126-149
    \* kernel/core/src/events/epoll/file.rs:241-244
    \A k \in InterestKeys :
       (CompletedRegistration(k) /\ entryEnabled[k]
        /\ triggerMode[k] = "LT" /\ readyEpoch[k] > 0 /\ KeyReady(k))
       ~> (~KeyReady(k)
           \/ (k \in readyQ /\ queuedEpoch[k] >= readyEpoch[k]))

RegisteredTransitionNotLost ==
    \* Each new readiness epoch must itself be queued or delivered. Membership
    \* left by an older epoch cannot discharge a later transition.
    \* kernel/core/src/process/signal/poll.rs:84-89,167-178
    \* kernel/core/src/events/epoll/entry.rs:280-330
    \A k \in InterestKeys :
       (CompletedRegistration(k) /\ entryEnabled[k]
        /\ readyEpoch[k] > deliveredEpoch[k] /\ KeyReady(k))
       ~> (~KeyReady(k)
           \/ deliveredEpoch[k] >= readyEpoch[k]
           \/ (k \in readyQ /\ queuedEpoch[k] >= readyEpoch[k]))

NestedReadyEpochPropagates ==
    \* For the one supported outer->inner edge, every inner Pollee epoch that
    \* enters SyncSubject must complete the synchronous outer callback.
    \* kernel/core/src/events/epoll/entry.rs:280-330
    \* kernel/core/src/events/subject.rs:126-149
    \A edge \in (Epolls \X Epolls) :
       (edge \in epollGraph
        /\ nestedRequiredEpoch[edge] > nestedDeliveredEpoch[edge])
       ~> (nestedDeliveredEpoch[edge] >= nestedRequiredEpoch[edge])

====
