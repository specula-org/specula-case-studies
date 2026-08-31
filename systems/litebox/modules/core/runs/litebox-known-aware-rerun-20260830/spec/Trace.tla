---- MODULE Trace ----
(***************************************************************************)
(* Category B timebox trace validator for LiteBox.  The preprocessor emits  *)
(* one JSON record in an NDJSON file: {threads:[...], events:{tid:[...]}}.  *)
(* Every event calls exactly one base action and validates every captured    *)
(* action-specific post-state field.  There are no silent actions.           *)
(***************************************************************************)

EXTENDS base, Json, IOUtils, TLC

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

\* One preprocessed JSON object is stored as one NDJSON line.
TraceJson == ndJsonDeserialize(JsonFile)[1]

TraceThreads ==
    LET ts == TraceJson.threads IN {ts[i] : i \in 1..Len(ts)}

traces == TraceJson.events

VARIABLE tracePc

traceVars == <<vars, tracePc>>

ThreadsWithEvents ==
    {tid \in TraceThreads : tracePc[tid] < Len(traces[tid])}

NextEvent(tid) == traces[tid][tracePc[tid] + 1]

\* A wide wait-comparison interval can overlap the wake that selects the same
\* waiter.  If the concrete trace records that selection completing before the
\* comparison, the mismatch cannot be linearized first: doing so removes the
\* waiter and creates a branch that contradicts the later selected_waiter field.
FutureWakeTransitionPrecedes(tid, ev) ==
    \E w \in TraceThreads :
        \E i \in (tracePc[w] + 1)..Len(traces[w]) :
            LET future == traces[w][i] IN
            /\ future.event \in {"FutexManagerWakeSelect", "FutexManagerWakeComplete"}
            /\ future.args.selected_waiter = tid
            /\ future.end < ev.end

\* An event is viable iff no pending event on another thread completed first.
ViablePIDs ==
    {tid \in ThreadsWithEvents :
        /\ ~ \E tid2 \in ThreadsWithEvents :
                /\ tid2 /= tid
                /\ NextEvent(tid2).end < NextEvent(tid).start
        /\ ~(NextEvent(tid).event = "FutexManagerWaitCompareMismatch"
              /\ FutureWakeTransitionPrecedes(tid, NextEvent(tid)))}

TraceInit ==
    /\ Init
    /\ TraceThreads \subseteq Thread
    /\ tracePc = [tid \in TraceThreads |-> 0]

\* Dispatch preserves the 1:1 event/action mapping in instrumentation-spec.md.
ApplyEvent(tid, ev) ==
    CASE ev.event = "ResolverParentDirAndName" ->
            ResolverParentDirAndName(tid, ev.args.path)
      [] ev.event = "InMemRmdirAt" ->
            InMemRmdirAt(ev.args.path)
      [] ev.event = "InMemRecreateAt" ->
            InMemRecreateAt(ev.args.path, ev.args.node)
      [] ev.event = "InMemCreateFileAt" ->
            InMemCreateFileAt(tid, ev.args.node)
      [] ev.event = "TaskSysChdirValidate" ->
            TaskSysChdirValidate(tid, ev.args.path)
      [] ev.event = "TaskSysChdirPublish" ->
            TaskSysChdirPublish(tid)
      [] ev.event = "TaskResolvePathRelative" ->
            TaskResolvePathRelative(tid)
      [] ev.event = "TaskChunkedReadBegin" ->
            TaskChunkedReadBegin(tid, ev.args.fd)
      [] ev.event = "TaskChunkedReadChunk" ->
            TaskChunkedReadChunk(tid)
      [] ev.event = "TaskChunkedReadFinish" ->
            TaskChunkedReadFinish(tid)
      [] ev.event = "FilesStateCloseSlot" ->
            FilesStateCloseSlot(ev.args.fd)
      [] ev.event = "FilesStateReuseSlot" ->
            FilesStateReuseSlot(ev.args.fd, ev.args.ofd)
      [] ev.event = "DescriptorsDuplicate" ->
            DescriptorsDuplicate(ev.args.source, ev.args.target)
      [] ev.event = "TaskSysGetdirent64Load" ->
            TaskSysGetdirent64Load(tid, ev.args.fd)
      [] ev.event = "TaskSysGetdirent64Produce" ->
            TaskSysGetdirent64Produce(tid)
      [] ev.event = "TaskSysGetdirent64Store" ->
            TaskSysGetdirent64Store(tid)
      [] ev.event = "EpollFileAddInterest" ->
            EpollFileAddInterest(ev.args.fd)
      [] ev.event = "TaskDoMmapFileHost" ->
            TaskDoMmapFileHost(tid, ev.args.addr, ev.args.perm)
      [] ev.event = "PageManagerRegisterExistingMapping" ->
            PageManagerRegisterExistingMapping(tid)
      [] ev.event = "TaskSysMunmap" ->
            TaskSysMunmap(ev.args.addr)
      [] ev.event = "TaskMaybePatchOnMprotectExecCollect" ->
            TaskMaybePatchOnMprotectExecCollect(tid, ev.args.addr)
      [] ev.event = "TaskMaybePatchExecSegmentApply" ->
            TaskMaybePatchExecSegmentApply(tid)
      [] ev.event = "TaskSysMprotectRaw" ->
            TaskSysMprotectRaw(ev.args.addr, ev.args.perm)
      [] ev.event = "TaskDoClonePrepare" ->
            TaskDoClonePrepare(tid, ev.args.child)
      [] ev.event = "TaskDoClonePublishParentTid" ->
            TaskDoClonePublishParentTid(tid)
      [] ev.event = "TaskDoCloneStackValidationSuccess" ->
            TaskDoCloneStackValidationSuccess(tid)
      [] ev.event = "TaskDoCloneStackValidationFailure" ->
            TaskDoCloneStackValidationFailure(tid)
      [] ev.event = "ThreadStateNewThread" ->
            ThreadStateNewThread(tid)
      [] ev.event = "TaskDoCloneTransferInit" ->
            TaskDoCloneTransferInit(tid)
      [] ev.event = "SnpLinuxKernelSpawnThreadSuccess" ->
            SnpLinuxKernelSpawnThreadSuccess(tid)
      [] ev.event = "SnpLinuxKernelSpawnThreadFailure" ->
            SnpLinuxKernelSpawnThreadFailure(tid)
      [] ev.event = "ProcessDetachThread" ->
            ProcessDetachThread(ev.args.child)
      [] ev.event = "FutexManagerWaitInsert" ->
            FutexManagerWaitInsert(tid, ev.args.expected)
      [] ev.event = "FutexManagerWaitCompareMatch" ->
            FutexManagerWaitCompareMatch(tid)
      [] ev.event = "FutexManagerWaitCompareMismatch" ->
            FutexManagerWaitCompareMismatch(tid)
      [] ev.event = "FutexManagerWakeBegin" ->
            FutexManagerWakeBegin(tid)
      [] ev.event = "FutexManagerWakeSelect" ->
            FutexManagerWakeSelect(tid)
      [] ev.event = "FutexManagerWakeComplete" ->
            FutexManagerWakeComplete(tid)
      [] ev.event = "FutexManagerWaitReturn" ->
            FutexManagerWaitReturn(tid)
      [] ev.event = "FutexSetValue" ->
            FutexSetValue(ev.args.value)
      [] OTHER -> FALSE

\* Mandatory strong post-state validation.  Each branch checks all fields
\* listed for that event in instrumentation-spec.md; none is vacuous.
ValidatePostState(tid, ev) ==
    CASE ev.event = "ResolverParentDirAndName" ->
            /\ pc'[tid] = ev.state.pc_after
            /\ walkedParent'[tid] = ev.state.walked_parent
            /\ walkedPath'[tid] = ev.state.walked_path
      [] ev.event = "InMemRmdirAt" ->
            /\ namespace'[ev.args.path] = ev.state.namespace_binding
            /\ nodeAlive'[ev.args.victim] = ev.state.victim_alive
            /\ nodeParent'[ev.args.victim] = ev.state.victim_parent
      [] ev.event = "InMemRecreateAt" ->
            /\ namespace'[ev.args.path] = ev.state.namespace_binding
            /\ nodeAlive'[ev.args.node] = ev.state.node_alive
            /\ nodeParent'[ev.args.node] = ev.state.node_parent
      [] ev.event = "InMemCreateFileAt" ->
            /\ pc'[tid] = ev.state.pc_after
            /\ namespace'[ChildPath] = ev.state.child_binding
            /\ nodeAlive'[ev.args.node] = ev.state.node_alive
            /\ nodeParent'[ev.args.node] = ev.state.node_parent
            /\ createResult'[tid] = ev.state.create_result
            /\ createdNode'[tid] = ev.state.created_node
      [] ev.event = "TaskSysChdirValidate" ->
            /\ pc'[tid] = ev.state.pc_after
            /\ cwdCandidate'[tid] = ev.state.cwd_candidate
            /\ walkedPath'[tid] = ev.state.walked_path
      [] ev.event = "TaskSysChdirPublish" ->
            /\ pc'[tid] = ev.state.pc_after
            /\ cwdNode'[tid] = ev.state.cwd_node
            /\ cwdPath'[tid] = ev.state.cwd_path
      [] ev.event = "TaskResolvePathRelative" ->
            relativeLookupNode'[tid] = ev.state.relative_node
      [] ev.event = "TaskChunkedReadBegin" ->
            /\ pc'[tid] = ev.state.pc_after
            /\ opFd'[tid] = ev.state.op_fd
            /\ opOFD'[tid] = ev.state.op_ofd
            /\ lastChunkOFD'[tid] = ev.state.last_chunk_ofd
            /\ chunksDone'[tid] = ev.state.chunks_done
      [] ev.event = "TaskChunkedReadChunk" ->
            /\ lastChunkOFD'[tid] = ev.state.chunk_ofd
            /\ chunksDone'[tid] = ev.state.chunks_done
      [] ev.event = "TaskChunkedReadFinish" ->
            pc'[tid] = ev.state.pc_after
      [] ev.event = "FilesStateCloseSlot" ->
            /\ fdSlot'[ev.args.fd] = ev.state.slot_ofd
            /\ fdGeneration'[ev.args.fd] = ev.state.fd_generation
            /\ ofdRefs'[ev.args.old_ofd] = ev.state.old_ofd_refs
            /\ dirOffset'[ev.args.fd] = ev.state.dir_offset
      [] ev.event = "FilesStateReuseSlot" ->
            /\ fdSlot'[ev.args.fd] = ev.state.slot_ofd
            /\ fdGeneration'[ev.args.fd] = ev.state.fd_generation
            /\ ofdRefs'[ev.args.ofd] = ev.state.ofd_refs
            /\ dirOffset'[ev.args.fd] = ev.state.dir_offset
      [] ev.event = "DescriptorsDuplicate" ->
            /\ fdSlot'[ev.args.target] = ev.state.target_ofd
            /\ fdGeneration'[ev.args.target] = ev.state.target_generation
            /\ ofdRefs'[ev.state.target_ofd] = ev.state.ofd_refs
            /\ dirOffset'[ev.args.target] = ev.state.target_dir_offset
      [] ev.event = "TaskSysGetdirent64Load" ->
            /\ pc'[tid] = ev.state.pc_after
            /\ dirFd'[tid] = ev.state.dir_fd
            /\ dirCursor'[tid] = ev.state.dir_cursor
      [] ev.event = "TaskSysGetdirent64Produce" ->
            /\ pc'[tid] = ev.state.pc_after
            /\ dirCursor'[tid] = ev.state.dir_cursor
      [] ev.event = "TaskSysGetdirent64Store" ->
            /\ pc'[tid] = ev.state.pc_after
            /\ dirOffset'[ev.args.fd] = ev.state.dir_offset
      [] ev.event = "EpollFileAddInterest" ->
            /\ Cardinality(epollInterests') = ev.state.interest_count
            /\ [fd |-> ev.args.fd, ofd |-> ev.args.ofd] \in epollInterests'
      [] ev.event = "TaskDoMmapFileHost" ->
            /\ pc'[tid] = ev.state.pc_after
            /\ hostMapped'[ev.args.addr] = ev.state.host_mapped
            /\ hostGeneration'[ev.args.addr] = ev.state.host_generation
            /\ hostPerm'[ev.args.addr] = ev.state.host_perm
            /\ mapGeneration'[ev.args.addr] = ev.state.map_generation
            /\ localMapAddr'[tid] = ev.state.local_addr
            /\ localMapGeneration'[tid] = ev.state.local_generation
            /\ localMapPerm'[tid] = ev.state.local_perm
      [] ev.event = "PageManagerRegisterExistingMapping" ->
            /\ pc'[tid] = ev.state.pc_after
            /\ vmemMapped'[ev.args.addr] = ev.state.vmem_mapped
            /\ vmemGeneration'[ev.args.addr] = ev.state.vmem_generation
            /\ vmemPerm'[ev.args.addr] = ev.state.vmem_perm
            /\ patchIntervals'[ev.args.addr] = ev.state.patch_generation
      [] ev.event = "TaskSysMunmap" ->
            /\ hostMapped'[ev.args.addr] = ev.state.host_mapped
            /\ vmemMapped'[ev.args.addr] = ev.state.vmem_mapped
            /\ patchIntervals'[ev.args.addr] = ev.state.patch_generation
      [] ev.event = "TaskMaybePatchOnMprotectExecCollect" ->
            /\ pc'[tid] = ev.state.pc_after
            /\ planAddr'[tid] = ev.state.plan_addr
            /\ planGeneration'[tid] = ev.state.plan_generation
            /\ patchApplied'[tid] = ev.state.patch_applied
      [] ev.event = "TaskMaybePatchExecSegmentApply" ->
            /\ pc'[tid] = ev.state.pc_after
            /\ patchApplied'[tid] = ev.state.patch_applied
            /\ patchAppliedPlanGeneration'[tid] = ev.state.plan_generation
            /\ patchAppliedHostGeneration'[tid] = ev.state.host_generation
      [] ev.event = "TaskSysMprotectRaw" ->
            /\ hostPerm'[ev.args.addr] = ev.state.host_perm
            /\ vmemPerm'[ev.args.addr] = ev.state.vmem_perm
      [] ev.event = "TaskDoClonePrepare" ->
            /\ pc'[tid] = ev.state.pc_after
            /\ cloneChild'[tid] = ev.state.clone_child
            /\ parentTid'[tid] = ev.state.parent_tid
            /\ spawnResult'[tid] = ev.state.spawn_result
      [] ev.event = "TaskDoClonePublishParentTid" ->
            /\ pc'[tid] = ev.state.pc_after
            /\ parentTid'[tid] = ev.state.parent_tid
      [] ev.event = "TaskDoCloneStackValidationSuccess" ->
            pc'[tid] = ev.state.pc_after
      [] ev.event = "TaskDoCloneStackValidationFailure" ->
            /\ pc'[tid] = ev.state.pc_after
            /\ spawnResult'[tid] = ev.state.spawn_result
            /\ parentTid'[tid] = ev.state.parent_tid
      [] ev.event = "ThreadStateNewThread" ->
            /\ pc'[tid] = ev.state.pc_after
            /\ ev.args.child \in threads'
            /\ threadCount' = ev.state.thread_count
            /\ initOwner'[ev.args.child] = ev.state.init_owner
      [] ev.event = "TaskDoCloneTransferInit" ->
            /\ pc'[tid] = ev.state.pc_after
            /\ initOwner'[ev.args.child] = ev.state.init_owner
      [] ev.event = "SnpLinuxKernelSpawnThreadSuccess" ->
            /\ pc'[tid] = ev.state.pc_after
            /\ ev.args.child \in committedThreads'
            /\ initOwner'[ev.args.child] = ev.state.init_owner
            /\ spawnResult'[tid] = ev.state.spawn_result
      [] ev.event = "SnpLinuxKernelSpawnThreadFailure" ->
            /\ pc'[tid] = ev.state.pc_after
            /\ (ev.args.child \in threads') = ev.state.attached
            /\ (ev.args.child \in committedThreads') = ev.state.committed
            /\ initOwner'[ev.args.child] = ev.state.init_owner
            /\ spawnResult'[tid] = ev.state.spawn_result
      [] ev.event = "ProcessDetachThread" ->
            /\ (ev.args.child \in threads') = ev.state.attached
            /\ (ev.args.child \in committedThreads') = ev.state.committed
            /\ threadCount' = ev.state.thread_count
            /\ initOwner'[ev.args.child] = ev.state.init_owner
      [] ev.event = "FutexManagerWaitInsert" ->
            /\ waiterPhase'[tid] = ev.state.waiter_phase
            /\ waiterExpected'[tid] = ev.state.waiter_expected
            /\ Len(waitQueue') = ev.state.queue_len
      [] ev.event = "FutexManagerWaitCompareMatch" ->
            /\ waiterPhase'[tid] = ev.state.waiter_phase
            /\ Len(waitQueue') = ev.state.queue_len
      [] ev.event = "FutexManagerWaitCompareMismatch" ->
            /\ waiterPhase'[tid] = ev.state.waiter_phase
            /\ Len(waitQueue') = ev.state.queue_len
      [] ev.event = "FutexManagerWakeBegin" ->
            /\ pc'[tid] = ev.state.pc_after
            /\ wakeBudget'[tid] = ev.state.wake_budget
            /\ wakeCount'[tid] = ev.state.wake_count
            /\ wakeReturn'[tid] = ev.state.wake_return
            /\ wakeHadUnvalidated'[tid] = ev.state.had_unvalidated
            /\ Cardinality(selected') = ev.state.selected_count
      [] ev.event = "FutexManagerWakeSelect" ->
            /\ pc'[tid] = ev.state.pc_after
            /\ waiterPhase'[ev.args.selected_waiter] = ev.state.selected_phase
            /\ Len(waitQueue') = ev.state.queue_len
            /\ Cardinality(selected') = ev.state.selected_count
            /\ wakeCount'[tid] = ev.state.wake_count
            /\ wakeHadUnvalidated'[tid] = ev.state.had_unvalidated
      [] ev.event = "FutexManagerWakeComplete" ->
            /\ pc'[tid] = ev.state.pc_after
            /\ Cardinality(selected') = ev.state.selected_count
            /\ wakeReturn'[tid] = ev.state.wake_return
            /\ waiterPhase'[ev.args.selected_waiter] = ev.state.waiter_phase
      [] ev.event = "FutexManagerWaitReturn" ->
            waiterPhase'[tid] = ev.state.waiter_phase
      [] ev.event = "FutexSetValue" ->
            futexValue' = ev.state.futex_value
      [] OTHER -> FALSE

MatchEvent(tid) ==
    LET ev == NextEvent(tid) IN
    /\ ev.tag = "trace"
    /\ ev.tid = tid
    /\ ApplyEvent(tid, ev)
    /\ ValidatePostState(tid, ev)

TraceNext ==
    \/ /\ ThreadsWithEvents /= {}
       /\ \E tid \in ViablePIDs :
            /\ MatchEvent(tid)
            /\ tracePc' = [tracePc EXCEPT ![tid] = @ + 1]
    \/ /\ ThreadsWithEvents = {}
       /\ UNCHANGED traceVars

TraceSpec == TraceInit /\ [][TraceNext]_traceVars /\ WF_traceVars(TraceNext)

TraceMatched == <>(ThreadsWithEvents = {})
TraceFullyConsumed == TraceMatched

TraceTypeOK ==
    /\ TypeOK
    /\ tracePc \in [TraceThreads -> Nat]

\* These are implementation safety properties, not MC-only fault counters.
TraceSafety ==
    /\ NamespaceIsATree
    /\ ReachableCreate
    /\ CwdIdentityStable
    /\ SingleBindingPerFdSlot
    /\ OFDRefCountsCorrect
    /\ OperationBindsOneOFD
    /\ AliasOffsetsShared
    /\ NoStaleEpollInterests
    /\ MappingRangesDisjoint
    /\ HostVmemAgreement
    /\ NoStalePatchPlan
    /\ ThreadCountMatchesAttachments
    /\ CloneFailureAtomic
    /\ WaitQueueDistinct
    /\ WakeCountsValidatedWaiters

\* Convergence checks the same structural oracle set as MC.cfg. Scenario
\* properties remain in TraceSafety and in their dedicated MC_hunt_*.cfg files;
\* wiring them here would make implementation traces that demonstrate a target
\* bug look like trace-matching failures.
TraceStructuralSafety ==
    /\ NamespaceIsATree
    /\ SingleBindingPerFdSlot
    /\ OFDRefCountsCorrect
    /\ MappingRangesDisjoint
    /\ WaitQueueDistinct

====
