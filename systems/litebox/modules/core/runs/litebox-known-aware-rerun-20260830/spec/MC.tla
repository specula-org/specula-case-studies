---- MODULE MC ----
(***************************************************************************)
(* Counter-bounded model-checking wrapper for the five LiteBox scenarios.  *)
(* Only environment/client/fault-introducing steps are bounded.  Reactive  *)
(* publication, compare, completion, and rollback-free failure aftermath   *)
(* remain unbounded, as required for Category B interleaving coverage.      *)
(***************************************************************************)

EXTENDS base, TLC, FiniteSets, Naturals

Base == INSTANCE base

CONSTANTS
    FSRequestLimit, FSMutationLimit,
    FDOperationLimit, FDReuseLimit,
    VMOperationLimit, VMMutationLimit,
    CloneStartLimit, SpawnFailureLimit,
    FutexWaitLimit, FutexWakeLimit, FutexChangeLimit

VARIABLE faultCount

FaultCountType ==
    [ fsRequest : 0..FSRequestLimit,
      fsMutation : 0..FSMutationLimit,
      fdOperation : 0..FDOperationLimit,
      fdReuse : 0..FDReuseLimit,
      vmOperation : 0..VMOperationLimit,
      vmMutation : 0..VMMutationLimit,
      cloneStart : 0..CloneStartLimit,
      spawnFailure : 0..SpawnFailureLimit,
      futexWait : 0..FutexWaitLimit,
      futexWake : 0..FutexWakeLimit,
      futexChange : 0..FutexChangeLimit ]

faultVars == <<faultCount>>
mcVars == <<vars, faultVars>>

MCInit ==
    /\ Init
    /\ faultCount =
        [ fsRequest |-> 0,
          fsMutation |-> 0,
          fdOperation |-> 0,
          fdReuse |-> 0,
          vmOperation |-> 0,
          vmMutation |-> 0,
          cloneStart |-> 0,
          spawnFailure |-> 0,
          futexWait |-> 0,
          futexWake |-> 0,
          futexChange |-> 0 ]

\* Scenario 1 bounded initiators/mutations.
MCResolverParentDirAndName(t, p) ==
    /\ faultCount.fsRequest < FSRequestLimit
    /\ Base!ResolverParentDirAndName(t, p)
    /\ faultCount' = [faultCount EXCEPT !.fsRequest = @ + 1]

MCTaskSysChdirValidate(t, p) ==
    /\ faultCount.fsRequest < FSRequestLimit
    /\ Base!TaskSysChdirValidate(t, p)
    /\ faultCount' = [faultCount EXCEPT !.fsRequest = @ + 1]

MCTaskResolvePathRelative(t) ==
    /\ faultCount.fsRequest < FSRequestLimit
    /\ Base!TaskResolvePathRelative(t)
    /\ faultCount' = [faultCount EXCEPT !.fsRequest = @ + 1]

MCInMemRmdirAt(p) ==
    /\ faultCount.fsMutation < FSMutationLimit
    /\ Base!InMemRmdirAt(p)
    /\ faultCount' = [faultCount EXCEPT !.fsMutation = @ + 1]

MCInMemRecreateAt(p, n) ==
    /\ faultCount.fsMutation < FSMutationLimit
    /\ Base!InMemRecreateAt(p, n)
    /\ faultCount' = [faultCount EXCEPT !.fsMutation = @ + 1]

\* Scenario 2 bounded syscall starts and close/reuse interference.
MCTaskChunkedReadBegin(t, f) ==
    /\ faultCount.fdOperation < FDOperationLimit
    /\ Base!TaskChunkedReadBegin(t, f)
    /\ faultCount' = [faultCount EXCEPT !.fdOperation = @ + 1]

MCDescriptorsDuplicate(source, target) ==
    /\ faultCount.fdOperation < FDOperationLimit
    /\ Base!DescriptorsDuplicate(source, target)
    /\ faultCount' = [faultCount EXCEPT !.fdOperation = @ + 1]

MCTaskSysGetdirent64Load(t, f) ==
    /\ faultCount.fdOperation < FDOperationLimit
    /\ Base!TaskSysGetdirent64Load(t, f)
    /\ faultCount' = [faultCount EXCEPT !.fdOperation = @ + 1]

MCEpollFileAddInterest(f) ==
    /\ faultCount.fdOperation < FDOperationLimit
    /\ Base!EpollFileAddInterest(f)
    /\ faultCount' = [faultCount EXCEPT !.fdOperation = @ + 1]

MCFilesStateCloseSlot(f) ==
    /\ faultCount.fdReuse < FDReuseLimit
    /\ Base!FilesStateCloseSlot(f)
    /\ faultCount' = [faultCount EXCEPT !.fdReuse = @ + 1]

MCFilesStateReuseSlot(f, o) ==
    /\ faultCount.fdReuse < FDReuseLimit
    /\ Base!FilesStateReuseSlot(f, o)
    /\ faultCount' = [faultCount EXCEPT !.fdReuse = @ + 1]

\* Scenario 3 bounded mapping/plan starts and unmap interference.
MCTaskDoMmapFileHost(t, a, p) ==
    /\ faultCount.vmOperation < VMOperationLimit
    /\ Base!TaskDoMmapFileHost(t, a, p)
    /\ faultCount' = [faultCount EXCEPT !.vmOperation = @ + 1]

MCTaskMaybePatchOnMprotectExecCollect(t, a) ==
    /\ faultCount.vmOperation < VMOperationLimit
    /\ Base!TaskMaybePatchOnMprotectExecCollect(t, a)
    /\ faultCount' = [faultCount EXCEPT !.vmOperation = @ + 1]

MCTaskSysMprotectRaw(a, p) ==
    /\ faultCount.vmOperation < VMOperationLimit
    /\ Base!TaskSysMprotectRaw(a, p)
    /\ faultCount' = [faultCount EXCEPT !.vmOperation = @ + 1]

MCTaskSysMunmap(a) ==
    /\ faultCount.vmMutation < VMMutationLimit
    /\ Base!TaskSysMunmap(a)
    /\ faultCount' = [faultCount EXCEPT !.vmMutation = @ + 1]

\* Scenario 4: clone start is client nondeterminism; spawn failure is injected.
MCTaskDoClonePrepare(t, child) ==
    /\ faultCount.cloneStart < CloneStartLimit
    /\ Base!TaskDoClonePrepare(t, child)
    /\ faultCount' = [faultCount EXCEPT !.cloneStart = @ + 1]

MCSnpLinuxKernelSpawnThreadFailure(t) ==
    /\ faultCount.spawnFailure < SpawnFailureLimit
    /\ Base!SnpLinuxKernelSpawnThreadFailure(t)
    /\ faultCount' = [faultCount EXCEPT !.spawnFailure = @ + 1]

\* Scenario 5: waiter/wake requests and user-word mutation are bounded.
MCFutexManagerWaitInsert(t, expected) ==
    /\ faultCount.futexWait < FutexWaitLimit
    /\ Base!FutexManagerWaitInsert(t, expected)
    /\ faultCount' = [faultCount EXCEPT !.futexWait = @ + 1]

MCFutexManagerWakeBegin(w) ==
    /\ faultCount.futexWake < FutexWakeLimit
    /\ Base!FutexManagerWakeBegin(w)
    /\ faultCount' = [faultCount EXCEPT !.futexWake = @ + 1]

MCFutexSetValue(v) ==
    /\ faultCount.futexChange < FutexChangeLimit
    /\ Base!FutexSetValue(v)
    /\ faultCount' = [faultCount EXCEPT !.futexChange = @ + 1]

\* Reactive actions are deliberately unbounded and preserve fault counters.
Pass(A) == /\ A /\ UNCHANGED faultCount

MCFutexCompletion ==
    \E w \in Thread : Pass(Base!FutexManagerWakeComplete(w))

MCNext ==
    \* Bounded Scenario 1 initiators.
    \/ \E t \in Thread, p \in Path : ResolverParentDirAndName(t, p)
    \/ \E p \in Path : InMemRmdirAt(p)
    \/ \E p \in Path, n \in Node : InMemRecreateAt(p, n)
    \/ \E t \in Thread, p \in Path : TaskSysChdirValidate(t, p)
    \/ \E t \in Thread : TaskResolvePathRelative(t)
    \* Reactive Scenario 1 completions.
    \/ \E t \in Thread, n \in Node : Pass(Base!InMemCreateFileAt(t, n))
    \/ \E t \in Thread : Pass(Base!TaskSysChdirPublish(t))
    \* Bounded Scenario 2 initiators/interference.
    \/ \E t \in Thread, f \in Fd : TaskChunkedReadBegin(t, f)
    \/ \E f \in Fd : FilesStateCloseSlot(f)
    \/ \E f \in Fd, o \in OFD : FilesStateReuseSlot(f, o)
    \/ \E source, target \in Fd : DescriptorsDuplicate(source, target)
    \/ \E t \in Thread, f \in Fd : TaskSysGetdirent64Load(t, f)
    \/ \E f \in Fd : EpollFileAddInterest(f)
    \* Reactive Scenario 2 stages.
    \/ \E t \in Thread : Pass(Base!TaskChunkedReadChunk(t))
    \/ \E t \in Thread : Pass(Base!TaskChunkedReadFinish(t))
    \/ \E t \in Thread : Pass(Base!TaskSysGetdirent64Produce(t))
    \/ \E t \in Thread : Pass(Base!TaskSysGetdirent64Store(t))
    \* Bounded Scenario 3 initiators/interference.
    \/ \E t \in Thread, a \in MapAddr, p \in Perm : TaskDoMmapFileHost(t, a, p)
    \/ \E a \in MapAddr : TaskSysMunmap(a)
    \/ \E t \in Thread, a \in MapAddr : TaskMaybePatchOnMprotectExecCollect(t, a)
    \/ \E a \in MapAddr, p \in Perm : TaskSysMprotectRaw(a, p)
    \* Reactive Scenario 3 publication/application.
    \/ \E t \in Thread : Pass(Base!PageManagerRegisterExistingMapping(t))
    \/ \E t \in Thread : Pass(Base!TaskMaybePatchExecSegmentApply(t))
    \* Bounded Scenario 4 start/failure.
    \/ \E t, child \in Thread : TaskDoClonePrepare(t, child)
    \/ \E t \in Thread : SnpLinuxKernelSpawnThreadFailure(t)
    \* Reactive Scenario 4 stages.
    \/ \E t \in Thread : Pass(Base!TaskDoClonePublishParentTid(t))
    \/ \E t \in Thread : Pass(Base!TaskDoCloneStackValidationSuccess(t))
    \/ \E t \in Thread : Pass(Base!TaskDoCloneStackValidationFailure(t))
    \/ \E t \in Thread : Pass(Base!ThreadStateNewThread(t))
    \/ \E t \in Thread : Pass(Base!TaskDoCloneTransferInit(t))
    \/ \E t \in Thread : Pass(Base!SnpLinuxKernelSpawnThreadSuccess(t))
    \/ \E child \in Thread : Pass(Base!ProcessDetachThread(child))
    \* Bounded Scenario 5 requests/environment.
    \/ \E t \in Thread, expected \in 0..1 : FutexManagerWaitInsert(t, expected)
    \/ \E w \in Thread : FutexManagerWakeBegin(w)
    \/ \E v \in 0..1 : FutexSetValue(v)
    \* Reactive Scenario 5 compare/select/complete/return.
    \/ \E t \in Thread : Pass(Base!FutexManagerWaitCompareMatch(t))
    \/ \E t \in Thread : Pass(Base!FutexManagerWaitCompareMismatch(t))
    \/ \E w \in Thread : Pass(Base!FutexManagerWakeSelect(w))
    \/ MCFutexCompletion
    \/ \E t \in Thread : Pass(Base!FutexManagerWaitReturn(t))

\* Scenario 4's platform-failure hunt excludes the separate stack-validation
\* return edge, so that the earlier parent-TID observation cannot mask the
\* attach/transfer/spawn-failure transaction named by MC-CLONE-1.
MCNextCloneSpawnHunt ==
    \/ \E t, child \in Thread : MCTaskDoClonePrepare(t, child)
    \/ \E t \in Thread : Pass(Base!TaskDoClonePublishParentTid(t))
    \/ \E t \in Thread : Pass(Base!TaskDoCloneStackValidationSuccess(t))
    \/ \E t \in Thread : Pass(Base!ThreadStateNewThread(t))
    \/ \E t \in Thread : Pass(Base!TaskDoCloneTransferInit(t))
    \/ \E t \in Thread : MCSnpLinuxKernelSpawnThreadFailure(t)
    \/ \E t \in Thread : Pass(Base!SnpLinuxKernelSpawnThreadSuccess(t))
    \/ \E child \in Thread : Pass(Base!ProcessDetachThread(child))

\* Fairness is limited to wake completion; it does not force any injected step.
MCSpec == MCInit /\ [][MCNext]_mcVars /\ WF_mcVars(MCFutexCompletion)

MCSpecCloneSpawnHunt == MCInit /\ [][MCNextCloneSpawnHunt]_mcVars

MCTypeOK == /\ TypeOK /\ faultCount \in FaultCountType

\* Threads other than the distinguished initial task are symmetric.
Symmetry == Permutations(Thread \ {MainThread})

\* Counters do not change semantic system state and are omitted from the view.
MCView == vars

====
