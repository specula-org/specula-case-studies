---- MODULE MC ----
(***************************************************************************)
(* Counter-bounded model-checking wrapper for the Category B base model.   *)
(* Only request, producer, timeout, signal, and fault introductions consume *)
(* budgets. Deterministic/reactive completions are unbounded.              *)
(* EnabledActions, Action* domains, counters, seenActions, CrossReuseHunt, *)
(* and MaskTransitionHunt are exploration-controller state only. They have *)
(* no production or Trace event counterpart.                              *)
(***************************************************************************)

EXTENDS base

Base == INSTANCE base

CONSTANTS
    FdActionLimit,
    EpollCtlLimit,
    CopyFaultLimit,
    PollLimit,
    SourceLimit,
    SignalLimit,
    WaitStartLimit,
    TimeoutLimit,
    InterruptLimit,
    ExecLimit,
    TopologyLimit,
    MaxInterestLimit,
    EnabledActions,
    ActionFDs,
    ActionOFDs,
    ActionEpolls,
    ActionTriggerModes

ActionNames == Base!ProductionActionNames

ASSUME /\ FdActionLimit \in Nat
       /\ EpollCtlLimit \in Nat
       /\ CopyFaultLimit \in Nat
       /\ PollLimit \in Nat
       /\ SourceLimit \in Nat
       /\ SignalLimit \in Nat
       /\ WaitStartLimit \in Nat
       /\ TimeoutLimit \in Nat
       /\ InterruptLimit \in Nat
       /\ ExecLimit \in Nat
       /\ TopologyLimit \in Nat
       /\ MaxInterestLimit \in Nat
       /\ EnabledActions \subseteq ActionNames
       /\ ActionFDs \subseteq FDs
       /\ ActionOFDs \subseteq OFDs
       /\ ActionEpolls \subseteq Epolls
       /\ ActionTriggerModes \subseteq TriggerModes

CounterNames ==
    {"fd", "epoll_ctl", "copy_fault", "poll", "source", "signal",
     "wait_start", "timeout", "interrupt", "exec", "topology"}

CrossReuseHunt ==
    {"FileTableInsert", "FcntlSetFlCapture",
     "DoEpollPwait2CopyoutSuccess"} \subseteq EnabledActions

MaskTransitionHunt ==
    "SignalfdUpdateMask" \in EnabledActions
    /\ ActionTriggerModes = {"ET"}

VARIABLES faultCount, seenActions
mcVars == <<faultCount, seenActions>>
mcAllVars == <<allVars, mcVars>>

Bounded(name, limit, actionName, action) ==
    \* Every wrapper literal must resolve through base's pinned source index.
    \* kernel/core/src/fs/file/file_table.rs:100-121
    /\ Base!HasProductionSource(actionName)
    /\ actionName \in EnabledActions
    /\ faultCount[name] < limit
    /\ action
    /\ faultCount' = [faultCount EXCEPT ![name] = @ + 1]
    /\ seenActions' = seenActions \cup {actionName}

Reactive(actionName, action) ==
    \* Reactive wrappers consume the same action/source row but no budget.
    \* kernel/core/src/events/subject.rs:126-153
    /\ Base!HasProductionSource(actionName)
    /\ actionName \in EnabledActions
    /\ action
    /\ UNCHANGED faultCount
    /\ seenActions' = seenActions \cup {actionName}

(***************************************************************************)
(* Bounded request, producer, timeout, signal, and fault introductions.    *)
(***************************************************************************)

MCFileTableInsert(t, fd, o, c) ==
    /\ fd \in ActionFDs
    /\ o \in ActionOFDs
    /\ (~CrossReuseHunt
        \/ /\ o = EventOFD
           /\ \E actor \in Threads :
                 captured[actor] = TimerOFD /\ capturedFd[actor] = fd)
    /\ Bounded("fd", FdActionLimit, "FileTableInsert",
            Base!FileTableInsert(t, fd, o, c))
MCFcntlSetFlCapture(t, fd, s) ==
    /\ fd \in ActionFDs
    /\ (~CrossReuseHunt
        \/ \E k \in registered : k.fd = fd /\ k.ofd = slots[fd])
    /\ Bounded("fd", FdActionLimit, "FcntlSetFlCapture",
            Base!FcntlSetFlCapture(t, fd, s))
MCSysCloseRemove(t, fd) ==
    /\ fd \in ActionFDs
    /\ (~CrossReuseHunt
        \/ \E actor \in Threads :
              captured[actor] = slots[fd] /\ capturedFd[actor] = fd)
    /\ Bounded("fd", FdActionLimit, "SysCloseRemove",
            Base!SysCloseRemove(t, fd))
MCSysDup2Equal(t, fd) ==
    /\ fd \in ActionFDs
    /\ Bounded("fd", FdActionLimit, "SysDup2Equal",
            Base!SysDup2Equal(t, fd))
MCSysDup3Validate(t, src, dst, c) ==
    /\ src \in ActionFDs
    /\ dst \in ActionFDs
    /\ Bounded("fd", FdActionLimit, "SysDup3Validate",
            Base!SysDup3Validate(t, src, dst, c))
MCFileTableDupCeil(t, src, dst, c) ==
    /\ src \in ActionFDs
    /\ dst \in ActionFDs
    /\ Bounded("fd", FdActionLimit, "FileTableDupCeil",
            Base!FileTableDupCeil(t, src, dst, c))
MCFcntlSetFd(t, fd, c) ==
    /\ fd \in ActionFDs
    /\ Bounded("fd", FdActionLimit, "FcntlSetFd",
            Base!FcntlSetFd(t, fd, c))
MCSysCloseRangeCloexec(t, first, last) ==
    /\ first \in ActionFDs
    /\ last \in ActionFDs
    /\ Bounded("fd", FdActionLimit, "SysCloseRangeCloexec",
            Base!SysCloseRangeCloexec(t, first, last))

MCEpollControlCaptureTarget(t, ep, fd, cmd, mode) ==
    /\ ep \in ActionEpolls
    /\ fd \in ActionFDs
    /\ mode \in ActionTriggerModes
    /\ (~MaskTransitionHunt \/ processPending)
    /\ \/ /\ cmd = "add"
              /\ "EpollAddInterest" \in EnabledActions
       \/ /\ cmd = "mod"
              /\ "EpollModInterest" \in EnabledActions
       \/ /\ cmd = "del"
              /\ "EpollDelInterest" \in EnabledActions
    /\ Bounded("epoll_ctl", EpollCtlLimit, "EpollControlCaptureTarget",
            Base!EpollControlCaptureTarget(t, ep, fd, cmd, mode))

MCDoEpollPwait2CopyoutFault(t) ==
    Bounded("copy_fault", CopyFaultLimit, "DoEpollPwait2CopyoutFault",
            Base!DoEpollPwait2CopyoutFault(t))

MCPolleePollWithRegister(t, o) ==
    /\ o \in ActionOFDs
    /\ Bounded("poll", PollLimit, "PolleePollWithRegister",
            Base!PolleePollWithRegister(t, o))

MCTimerfdExpired(t) ==
    /\ (~CrossReuseHunt \/ slots[FD0] = EventOFD)
    /\ Bounded("source", SourceLimit, "TimerfdExpired",
               Base!TimerfdExpired(t))
MCTimerfdTryRead(t) ==
    Bounded("source", SourceLimit, "TimerfdTryRead", Base!TimerfdTryRead(t))
MCTimerfdSetTimeDisarm(t) ==
    Bounded("source", SourceLimit, "TimerfdSetTimeDisarm",
            Base!TimerfdSetTimeDisarm(t))
MCEventfdAddCounter(t) ==
    Bounded("source", SourceLimit, "EventfdAddCounter",
            Base!EventfdAddCounter(t))
MCEventfdTryRead(t) ==
    Bounded("source", SourceLimit, "EventfdTryRead",
            Base!EventfdTryRead(t))

MCSignalfdUpdateMask(t, enabled) ==
    /\ (~MaskTransitionHunt
        \/ /\ enabled
           /\ processPending
           /\ \E k \in registered :
                 k.ofd = SignalOFD /\ epollWaiter[k.epoll] /= NoThread)
    /\ Bounded("signal", SignalLimit, "SignalfdUpdateMask",
            Base!SignalfdUpdateMask(t, enabled))
MCSigQueuesEnqueueThread(actor, target) ==
    Bounded("signal", SignalLimit, "SigQueuesEnqueueThread",
            Base!SigQueuesEnqueueThread(actor, target))
MCSigQueuesEnqueueProcess(actor) ==
    /\ (~MaskTransitionHunt \/ registered = {})
    /\ Bounded("signal", SignalLimit, "SigQueuesEnqueueProcess",
            Base!SigQueuesEnqueueProcess(actor))
MCSignalFileReadThread(t) ==
    Bounded("signal", SignalLimit, "SignalFileReadThread",
            Base!SignalFileReadThread(t))
MCSignalFileReadProcess(t) ==
    Bounded("signal", SignalLimit, "SignalFileReadProcess",
            Base!SignalFileReadProcess(t))

MCEpollWaitRegisterConsumer(t, ep) ==
    /\ ep \in ActionEpolls
    /\ (~MaskTransitionHunt
        \/ \E k \in registered : k.epoll = ep /\ k.ofd = SignalOFD)
    /\ Bounded("wait_start", WaitStartLimit, "EpollWaitRegisterConsumer",
            Base!EpollWaitRegisterConsumer(t, ep))
MCSaveAndSetSigMask(t, m) ==
    Bounded("wait_start", WaitStartLimit, "SaveAndSetSigMask",
            Base!SaveAndSetSigMask(t, m))
MCPollFilesRegisterPoller(t) ==
    Bounded("wait_start", WaitStartLimit, "PollFilesRegisterPoller",
            Base!PollFilesRegisterPoller(t))
MCWaiterTimeoutExpires(actor, target) ==
    Bounded("timeout", TimeoutLimit, "WaiterTimeoutExpires",
            Base!WaiterTimeoutExpires(actor, target))
MCWaiterSignalInterrupts(actor, target) ==
    Bounded("interrupt", InterruptLimit, "WaiterSignalInterrupts",
            Base!WaiterSignalInterrupts(actor, target))
MCExecveWaitOtherThreadsExit(t) ==
    Bounded("exec", ExecLimit, "ExecveWaitOtherThreadsExit",
            Base!ExecveWaitOtherThreadsExit(t))

MCEpollAddNestedInterest(t, outer, inner) ==
    /\ outer \in ActionEpolls
    /\ inner \in ActionEpolls
    /\ Bounded("topology", TopologyLimit, "EpollAddNestedInterest",
            Base!EpollAddNestedInterest(t, outer, inner))

(***************************************************************************)
(* Unbounded deterministic/reactive completion actions.                   *)
(***************************************************************************)

MCSigQueuesNotifyThread(actor) ==
    Reactive("SigQueuesNotifyThread", Base!SigQueuesNotifyThread(actor))
MCSigQueuesNotifyProcess(actor) ==
    \* The mask-transition controller delays this otherwise reactive action
    \* only to force the legal unlocked ADD/waiter/mask interleaving witness.
    \* Base retains the earlier-notify production ordering as well.
    \* kernel/core/src/process/signal/sig_queues.rs:38-45
    /\ (~MaskTransitionHunt
        \/ /\ signalMask[SignalOFD]
           /\ \E k \in interest :
                 k.ofd = SignalOFD /\ epollWaiter[k.epoll] /= NoThread)
    /\ Reactive("SigQueuesNotifyProcess", Base!SigQueuesNotifyProcess(actor))
MCSigQueuesNotifyReturn(actor) ==
    Reactive("SigQueuesNotifyReturn", Base!SigQueuesNotifyReturn(actor))

MCFcntlSetFlUse(t) == Reactive("FcntlSetFlUse", Base!FcntlSetFlUse(t))
MCClosedFileDrop(t) == Reactive("ClosedFileDrop", Base!ClosedFileDrop(t))
MCFileTableDupExact(t) ==
    Reactive("FileTableDupExact", Base!FileTableDupExact(t))
MCFileTableDupExactBadFd(t) ==
    Reactive("FileTableDupExactBadFd", Base!FileTableDupExactBadFd(t))
MCDupReplacementCleanup(t) ==
    Reactive("DupReplacementCleanup", Base!DupReplacementCleanup(t))
MCContextUnshareFiles(t) ==
    Reactive("ContextUnshareFiles", Base!ContextUnshareFiles(t))
MCFileTableCloseFilesOnExec(t) ==
    Reactive("FileTableCloseFilesOnExec", Base!FileTableCloseFilesOnExec(t))

MCEpollAddInterest(t) ==
    Reactive("EpollAddInterest", Base!EpollAddInterest(t))
MCEpollModInterest(t) ==
    Reactive("EpollModInterest", Base!EpollModInterest(t))
MCEpollDelInterest(t) ==
    Reactive("EpollDelInterest", Base!EpollDelInterest(t))
MCEpollControlError(t) ==
    Reactive("EpollControlError", Base!EpollControlError(t))
MCEntryUpdatePoll(t) ==
    Reactive("EntryUpdatePoll", Base!EntryUpdatePoll(t))
MCEpollControlPushReady(t) ==
    Reactive("EpollControlPushReady", Base!EpollControlPushReady(t))
MCReadySetPushAcquire(t, k) ==
    Reactive("ReadySetPushAcquire", Base!ReadySetPushAcquire(t, k))
MCReadySetPush(t, k) ==
    Reactive("ReadySetPush", Base!ReadySetPush(t, k))
MCReadySetPushSuppressed(t, k) ==
    Reactive("ReadySetPushSuppressed", Base!ReadySetPushSuppressed(t, k))
MCReadySetPushNotifySubject(t, ep) ==
    Reactive("ReadySetPushNotifySubject",
             Base!ReadySetPushNotifySubject(t, ep))
MCSyncSubjectCallbackReadySet(t, inner, outer) ==
    Reactive("SyncSubjectCallbackReadySet",
             Base!SyncSubjectCallbackReadySet(t, inner, outer))
MCObserverCallbackRelease(t) ==
    Reactive("ObserverCallbackRelease", Base!ObserverCallbackRelease(t))
MCReadySetPopDeleted(t, k) ==
    Reactive("ReadySetPopDeleted", Base!ReadySetPopDeleted(t, k))
MCReadySetPop(t, k) ==
    Reactive("ReadySetPop", Base!ReadySetPop(t, k))
MCEntryPollDeadFile(t) ==
    Reactive("EntryPollDeadFile", Base!EntryPollDeadFile(t))
MCEntryPollDisabled(t) ==
    Reactive("EntryPollDisabled", Base!EntryPollDisabled(t))
MCEntryPollPrepare(t) ==
    Reactive("EntryPollPrepare", Base!EntryPollPrepare(t))
MCEpollDiscardEmptyPreparation(t) ==
    Reactive("EpollDiscardEmptyPreparation",
             Base!EpollDiscardEmptyPreparation(t))
MCDoEpollPwait2CopyoutSuccess(t) ==
    Reactive("DoEpollPwait2CopyoutSuccess",
             Base!DoEpollPwait2CopyoutSuccess(t))

MCPolleePollWithLoad(t) ==
    Reactive("PolleePollWithLoad", Base!PolleePollWithLoad(t))
MCPolleePollWithCached(t) ==
    Reactive("PolleePollWithCached", Base!PolleePollWithCached(t))
MCPolleePollWithBeginCheck(t) ==
    Reactive("PolleePollWithBeginCheck", Base!PolleePollWithBeginCheck(t))
MCPolleePollWithCheck(t) ==
    Reactive("PolleePollWithCheck", Base!PolleePollWithCheck(t))
MCPolleePollWithCache(t) ==
    Reactive("PolleePollWithCache", Base!PolleePollWithCache(t))
MCPolleePollWithConcurrentCheck(t) ==
    Reactive("PolleePollWithConcurrentCheck",
             Base!PolleePollWithConcurrentCheck(t))
MCPolleePollWithFinish(t) ==
    Reactive("PolleePollWithFinish", Base!PolleePollWithFinish(t))
MCTimerfdNotify(t) == Reactive("TimerfdNotify", Base!TimerfdNotify(t))
MCEventfdNotify(t) == Reactive("EventfdNotify", Base!EventfdNotify(t))
MCEventfdNotifyReturn(t) ==
    Reactive("EventfdNotifyReturn", Base!EventfdNotifyReturn(t))

MCWaiterReadinessWake(actor, target) ==
    Reactive("WaiterReadinessWake",
             Base!WaiterReadinessWake(actor, target))
MCPollFilesInitialReady(t) ==
    Reactive("PollFilesInitialReady", Base!PollFilesInitialReady(t))
MCWaiterPauseTimeoutBlock(t) ==
    Reactive("WaiterPauseTimeoutBlock", Base!WaiterPauseTimeoutBlock(t))
MCWaiterPauseTimeoutReturnTimeout(t) ==
    Reactive("WaiterPauseTimeoutReturnTimeout",
             Base!WaiterPauseTimeoutReturnTimeout(t))
MCWaiterPauseTimeoutReturnSignal(t) ==
    Reactive("WaiterPauseTimeoutReturnSignal",
             Base!WaiterPauseTimeoutReturnSignal(t))
MCDoPollCountEvents(t) ==
    Reactive("DoPollCountEvents", Base!DoPollCountEvents(t))
MCHandlePendingSignalRestoreMask(t) ==
    Reactive("HandlePendingSignalRestoreMask",
             Base!HandlePendingSignalRestoreMask(t))

(***************************************************************************)
(* Init, Next, fairness, symmetry, view, and scope constraint.             *)
(***************************************************************************)

MCInit ==
    /\ Base!Init
    /\ faultCount = [name \in CounterNames |-> 0]
    /\ seenActions = {}

MCBoundedNext ==
    \/ \E t \in Threads, fd \in FDs, o \in OFDs, c \in BOOLEAN :
          MCFileTableInsert(t, fd, o, c)
    \/ \E t \in Threads, fd \in FDs, s \in BOOLEAN :
          MCFcntlSetFlCapture(t, fd, s)
    \/ \E t \in Threads, fd \in FDs : MCSysCloseRemove(t, fd)
    \/ \E t \in Threads, fd \in FDs : MCSysDup2Equal(t, fd)
    \/ \E t \in Threads, src \in FDs, dst \in FDs, c \in BOOLEAN :
          MCSysDup3Validate(t, src, dst, c)
    \/ \E t \in Threads, src \in FDs, dst \in FDs, c \in BOOLEAN :
          MCFileTableDupCeil(t, src, dst, c)
    \/ \E t \in Threads, fd \in FDs, c \in BOOLEAN : MCFcntlSetFd(t, fd, c)
    \/ \E t \in Threads, first \in FDs, last \in FDs :
          MCSysCloseRangeCloexec(t, first, last)
    \/ \E t \in Threads, ep \in Epolls, fd \in FDs,
          cmd \in {"add", "del", "mod"}, mode \in TriggerModes :
          MCEpollControlCaptureTarget(t, ep, fd, cmd, mode)
    \/ \E t \in Threads : MCDoEpollPwait2CopyoutFault(t)
    \/ \E t \in Threads, o \in OFDs : MCPolleePollWithRegister(t, o)
    \/ \E t \in Threads : MCTimerfdExpired(t)
    \/ \E t \in Threads : MCTimerfdTryRead(t)
    \/ \E t \in Threads : MCTimerfdSetTimeDisarm(t)
    \/ \E t \in Threads : MCEventfdAddCounter(t)
    \/ \E t \in Threads : MCEventfdTryRead(t)
    \/ \E t \in Threads, enabled \in BOOLEAN :
          MCSignalfdUpdateMask(t, enabled)
    \/ \E actor \in Threads, target \in Threads :
          MCSigQueuesEnqueueThread(actor, target)
    \/ \E t \in Threads : MCSigQueuesEnqueueProcess(t)
    \/ \E t \in Threads : MCSignalFileReadThread(t)
    \/ \E t \in Threads : MCSignalFileReadProcess(t)
    \/ \E t \in Threads, ep \in Epolls : MCEpollWaitRegisterConsumer(t, ep)
    \/ \E t \in Threads, m \in MaskStates : MCSaveAndSetSigMask(t, m)
    \/ \E t \in Threads : MCPollFilesRegisterPoller(t)
    \/ \E actor \in Threads, target \in Threads :
          MCWaiterTimeoutExpires(actor, target)
    \/ \E actor \in Threads, target \in Threads :
          MCWaiterSignalInterrupts(actor, target)
    \/ \E t \in Threads : MCExecveWaitOtherThreadsExit(t)
    \/ \E t \in Threads, outer \in Epolls, inner \in Epolls :
          MCEpollAddNestedInterest(t, outer, inner)

MCReactiveNext ==
    \/ \E t \in Threads : MCFcntlSetFlUse(t)
    \/ \E t \in Threads : MCClosedFileDrop(t)
    \/ \E t \in Threads : MCFileTableDupExact(t)
    \/ \E t \in Threads : MCFileTableDupExactBadFd(t)
    \/ \E t \in Threads : MCDupReplacementCleanup(t)
    \/ \E t \in Threads : MCContextUnshareFiles(t)
    \/ \E t \in Threads : MCFileTableCloseFilesOnExec(t)
    \/ \E t \in Threads : MCEpollAddInterest(t)
    \/ \E t \in Threads : MCEpollModInterest(t)
    \/ \E t \in Threads : MCEpollDelInterest(t)
    \/ \E t \in Threads : MCEpollControlError(t)
    \/ \E t \in Threads : MCEntryUpdatePoll(t)
    \/ \E t \in Threads : MCEpollControlPushReady(t)
    \/ \E t \in Threads, k \in InterestKeys : MCReadySetPushAcquire(t, k)
    \/ \E t \in Threads, k \in InterestKeys : MCReadySetPush(t, k)
    \/ \E t \in Threads, k \in InterestKeys : MCReadySetPushSuppressed(t, k)
    \/ \E t \in Threads, ep \in Epolls : MCReadySetPushNotifySubject(t, ep)
    \/ \E t \in Threads, inner \in Epolls, outer \in Epolls :
          MCSyncSubjectCallbackReadySet(t, inner, outer)
    \/ \E t \in Threads : MCObserverCallbackRelease(t)
    \/ \E t \in Threads, k \in InterestKeys : MCReadySetPopDeleted(t, k)
    \/ \E t \in Threads, k \in InterestKeys : MCReadySetPop(t, k)
    \/ \E t \in Threads : MCEntryPollDeadFile(t)
    \/ \E t \in Threads : MCEntryPollDisabled(t)
    \/ \E t \in Threads : MCEntryPollPrepare(t)
    \/ \E t \in Threads : MCEpollDiscardEmptyPreparation(t)
    \/ \E t \in Threads : MCDoEpollPwait2CopyoutSuccess(t)
    \/ \E t \in Threads : MCPolleePollWithLoad(t)
    \/ \E t \in Threads : MCPolleePollWithCached(t)
    \/ \E t \in Threads : MCPolleePollWithBeginCheck(t)
    \/ \E t \in Threads : MCPolleePollWithCheck(t)
    \/ \E t \in Threads : MCPolleePollWithCache(t)
    \/ \E t \in Threads : MCPolleePollWithConcurrentCheck(t)
    \/ \E t \in Threads : MCPolleePollWithFinish(t)
    \/ \E t \in Threads : MCTimerfdNotify(t)
    \/ \E t \in Threads : MCEventfdNotify(t)
    \/ \E t \in Threads : MCEventfdNotifyReturn(t)
    \/ \E t \in Threads : MCSigQueuesNotifyThread(t)
    \/ \E t \in Threads : MCSigQueuesNotifyProcess(t)
    \/ \E t \in Threads : MCSigQueuesNotifyReturn(t)
    \/ \E actor \in Threads, target \in Threads :
          MCWaiterReadinessWake(actor, target)
    \/ \E t \in Threads : MCPollFilesInitialReady(t)
    \/ \E t \in Threads : MCWaiterPauseTimeoutBlock(t)
    \/ \E t \in Threads : MCWaiterPauseTimeoutReturnTimeout(t)
    \/ \E t \in Threads : MCWaiterPauseTimeoutReturnSignal(t)
    \/ \E t \in Threads : MCDoPollCountEvents(t)
    \/ \E t \in Threads : MCHandlePendingSignalRestoreMask(t)

MCNext == MCBoundedNext \/ MCReactiveNext

MCCallbackFairness ==
    /\ \A t \in Threads, k \in InterestKeys :
          WF_mcAllVars(MCReadySetPushAcquire(t, k))
    /\ \A t \in Threads, k \in InterestKeys :
          WF_mcAllVars(MCReadySetPush(t, k))
    /\ \A t \in Threads, k \in InterestKeys :
          WF_mcAllVars(MCReadySetPushSuppressed(t, k))
    /\ \A t \in Threads, ep \in Epolls :
          WF_mcAllVars(MCReadySetPushNotifySubject(t, ep))
    /\ \A t \in Threads, inner \in Epolls, outer \in Epolls :
          WF_mcAllVars(MCSyncSubjectCallbackReadySet(t, inner, outer))
    /\ \A t \in Threads : WF_mcAllVars(MCObserverCallbackRelease(t))
    /\ \A t \in Threads : WF_mcAllVars(MCEventfdNotifyReturn(t))
    /\ \A t \in Threads : WF_mcAllVars(MCSigQueuesNotifyThread(t))
    /\ \A t \in Threads : WF_mcAllVars(MCSigQueuesNotifyProcess(t))
    /\ \A t \in Threads : WF_mcAllVars(MCSigQueuesNotifyReturn(t))
    /\ \A actor \in Threads, target \in Threads :
          WF_mcAllVars(MCWaiterReadinessWake(actor, target))

MCDeliveryFairness ==
    /\ \A t \in Threads : WF_mcAllVars(MCEntryPollDeadFile(t))
    /\ \A t \in Threads : WF_mcAllVars(MCEntryPollDisabled(t))
    /\ \A t \in Threads : WF_mcAllVars(MCEntryPollPrepare(t))
    /\ \A t \in Threads : WF_mcAllVars(MCEpollDiscardEmptyPreparation(t))
    /\ \A t \in Threads : WF_mcAllVars(MCDoEpollPwait2CopyoutSuccess(t))

MCSpec ==
    /\ MCInit
    /\ [][MCNext]_mcAllVars
    /\ WF_mcAllVars(MCReactiveNext)
    /\ MCCallbackFairness
    /\ MCDeliveryFairness

Symmetry == Permutations(Threads)
MCView == allVars
MCReachView == <<allVars, seenActions>>

MCStateConstraint ==
    /\ Cardinality(interest) <= MaxInterestLimit
    /\ \A name \in CounterNames : faultCount[name] \in Nat
    /\ seenActions \subseteq ActionNames

(***************************************************************************)
(* Structural/core wrappers enabled by the neutral configuration.         *)
(***************************************************************************)

MCTypeOK == Base!TypeOK
MCOccupiedSlotsReferToAliveOFDs == Base!OccupiedSlotsReferToAliveOFDs
MCReadyQueueKeysRemainIdentityTyped == Base!ReadyQueueKeysRemainIdentityTyped
MCLockOwnershipConsistent == Base!LockOwnershipConsistent
MCReadyCallbacksHaveProducerCause == Base!ReadyCallbacksHaveProducerCause
MCReadinessWakesHaveProducerCause == Base!ReadinessWakesHaveProducerCause
MCNestedEpochNeverRegresses == Base!NestedEpochNeverRegresses
MCNoPhantomLiveOFD == Base!NoPhantomLiveOFD
MCNoDeadOFDReference == Base!NoDeadOFDReference
MCEventfdMutexExclusive == Base!EventfdMutexExclusive
MCAcyclicEpollGraph == Base!AcyclicEpollGraph
MCSignalNotifyOrdering == Base!SignalNotifyOrdering
MCOFDsNeverResurrect == Base!OFDsNeverResurrect
MCExecCutoverIsolation == Base!ExecCutoverIsolation
MCPollSnapshotOwnershipStable == Base!PollSnapshotOwnershipStable
MCPollSnapshotReleasedOnTerminal == Base!PollSnapshotReleasedOnTerminal
MCFreshWaitInvocation == Base!FreshWaitInvocation

(***************************************************************************)
(* Scenario wrappers. Each independent oracle has its own hunt config.     *)
(***************************************************************************)

MCSlotMapsOneOFD == Base!SlotMapsOneOFD
MCCapturedReferenceStable == Base!CapturedReferenceStable
MCReplacementExactlyOnce == Base!ReplacementExactlyOnce
MCFdFlagsPerSlot == Base!FdFlagsPerSlot
MCExecClosesExactlySnapshotMarked == Base!ExecClosesExactlySnapshotMarked
MCEpollKeyIdentity == Base!EpollKeyIdentity
MCNoCrossReuseDelivery == Base!NoCrossReuseDelivery
MCNoDeadInterest == Base!NoDeadInterest
MCDeliveryCommitOnCopyout == Base!DeliveryCommitOnCopyout
MCOneShotDisabledIffDelivered == Base!OneShotDisabledIffDelivered
MCCachedReadinessSound == Base!CachedReadinessSound
MCSignalfdRegistrationHasBinding == Base!SignalfdRegistrationHasBinding
MCVisibleReadyWinsTerminalRace == Base!VisibleReadyWinsTerminalRace
MCTerminalScanMatchesLiveSnapshot == Base!TerminalScanMatchesLiveSnapshot
MCTemporaryMaskRestored == Base!TemporaryMaskRestored
MCNoAliasedDescriptorFlagWitness == ~Base!AliasedDescriptorFlagWitness
MCNoAddUpdatedBeforeInterestInsert == ~Base!AddUpdatedBeforeInterestInsert
MCNoTwoCheckersLoadedInvalid == ~Base!TwoCheckersLoadedInvalid
MCNoValidKeyIdentityReuse == ~Base!ValidKeyIdentitySurvivesReuse
MCNoProducerBeforeReadinessWake == ~Base!ProducerBeforeReadinessWake
MCNoDeadBeforeDisabledWitness == ~Base!DeadBeforeDisabledWitness
MCNoEventfdCallbackScopeWitness == ~Base!EventfdCallbackScopeWitness
MCNoPollSnapshotSurvivesClose == ~Base!PollSnapshotSurvivesClose
MCNoPollSnapshotReleasedAfterClose == ~Base!PollSnapshotReleasedAfterClose
MCNoFreshSecondWaitAfterTimeout == ~Base!FreshSecondWaitAfterTimeout
MCNoFreshSecondWaitAfterSignal == ~Base!FreshSecondWaitAfterSignal
MCNoExecBeforeCutoverDupCaptured == ~Base!ExecBeforeCutoverDupCaptured
MCNoExecAfterCutoverDupIsolated == ~Base!ExecAfterCutoverDupIsolated
MCNoExecBeforeCutoverCloexecCaptured ==
    ~Base!ExecBeforeCutoverCloexecCaptured
MCNoExecAfterCutoverCloexecIsolated ==
    ~Base!ExecAfterCutoverCloexecIsolated
MCNoExecPrivateFinalDrop == ~Base!ExecPrivateFinalDropWitness

MCActionNotReached(name) == name \notin seenActions
MCNotReachedSysDup2Equal == MCActionNotReached("SysDup2Equal")
MCNotReachedFileTableDupCeil == MCActionNotReached("FileTableDupCeil")
MCNotReachedEpollDelInterest == MCActionNotReached("EpollDelInterest")
MCNotReachedEpollControlError == MCActionNotReached("EpollControlError")
MCNotReachedEpollDiscardEmptyPreparation ==
    MCActionNotReached("EpollDiscardEmptyPreparation")
MCNotReachedSignalFileReadThread == MCActionNotReached("SignalFileReadThread")
MCNotReachedSignalFileReadProcess == MCActionNotReached("SignalFileReadProcess")
MCNotReachedPollFilesInitialReady == MCActionNotReached("PollFilesInitialReady")
MCNotReachedSigQueuesNotifyThread ==
    MCActionNotReached("SigQueuesNotifyThread")
MCNotReachedSigQueuesNotifyProcess ==
    MCActionNotReached("SigQueuesNotifyProcess")
MCNotReachedSigQueuesNotifyReturn ==
    MCActionNotReached("SigQueuesNotifyReturn")

MCSignalThreadNotifyGap ==
    \* kernel/core/src/process/signal/sig_queues.rs:38-45
    ~\E actor \in Threads :
        /\ signalNotify[actor].phase = "pending"
        /\ signalNotify[actor].queue = "thread"
MCSignalProcessNotifyGap ==
    \* kernel/core/src/process/signal/sig_queues.rs:38-45
    ~\E actor \in Threads :
        /\ signalNotify[actor].phase = "pending"
        /\ signalNotify[actor].queue = "process"

MCNoSignalGapRegistrationMaskInterleave ==
    \* In a MaskTransitionHunt, process enqueue is admitted only while the
    \* registration set is empty. This state therefore proves that ADD,
    \* waiter selection, and mask mutation occurred after the queue guard was
    \* dropped and before the later notify call began.
    \* kernel/core/src/process/signal/sig_queues.rs:38-45
    \* kernel/core/src/events/epoll/file.rs:96-120,191-205
    \* kernel/core/src/syscall/signalfd.rs:103-117,155-179
    ~\E actor \in Threads :
        /\ signalNotify[actor].phase = "pending"
        /\ signalNotify[actor].queue = "process"
        /\ processPending
        /\ signalMask[SignalOFD]
        /\ registered /= {}
        /\ \E k \in registered :
              k.ofd = SignalOFD /\ epollWaiter[k.epoll] /= NoThread

MCNoCompletedInterleavedSignalNotify ==
    \* Completion requires the exact key selected after the unlocked gap to
    \* traverse synchronous callback return before SigQueuesNotifyReturn.
    \* kernel/core/src/process/signal/sig_queues.rs:38-45,86-92
    \* kernel/core/src/events/subject.rs:126-153
    ~(/\ processSignalNotifyEpoch > 0
      /\ \A actor \in Threads : signalNotify[actor].phase = "idle"
      /\ {"SigQueuesEnqueueProcess", "EpollAddInterest",
           "EpollWaitRegisterConsumer", "SignalfdUpdateMask",
           "SigQueuesNotifyProcess", "ReadySetPush",
           "ObserverCallbackRelease", "SigQueuesNotifyReturn"}
            \subseteq seenActions)

MCNoTerminalReadyBeforeWake ==
    \* kernel/core/src/syscall/poll.rs:108-121,188-215
    ~\E t \in Threads :
        /\ terminalScanValid[t] /\ terminalReady[t]
        /\ visibleReady[t] = FALSE
        /\ lastReadyWake[t].epoch = 0
MCNoStaleVisibleAfterConsume ==
    \* kernel/core/src/syscall/poll.rs:108-121,188-215
    ~\E t \in Threads :
        /\ terminalScanValid[t] /\ ~terminalReady[t]
        /\ visibleReady[t]

MCLevelReadyEventuallyRedelivered == Base!LevelReadyEventuallyRedelivered
MCRegisteredTransitionNotLost == Base!RegisteredTransitionNotLost
MCNestedReadyEpochPropagates == Base!NestedReadyEpochPropagates

====
