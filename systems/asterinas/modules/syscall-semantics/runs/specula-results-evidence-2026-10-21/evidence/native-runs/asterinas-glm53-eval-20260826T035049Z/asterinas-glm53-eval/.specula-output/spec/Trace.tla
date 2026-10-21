---- MODULE Trace ----
(***************************************************************************)
(* Category B timebox trace validator for base.tla.                        *)
(*                                                                         *)
(* Each implementation thread emits an ordered event stream with [start,  *)
(* end] timestamps. ViablePIDs preserves real-time order for disjoint      *)
(* intervals and lets TLC explore both orders for overlapping intervals.   *)
(***************************************************************************)

EXTENDS base, Json, IOUtils, Naturals, Sequences, TLC

Base == INSTANCE base

(***************************************************************************)
(* Trace loading                                                            *)
(***************************************************************************)

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

TraceData == JsonDeserialize(JsonFile)
traces    == TraceData.traces

VARIABLE pc

traceVars == <<pc>>
traceAllVars == <<vars, traceVars>>

ThreadsWithEvents ==
    {t \in Thread : pc[t] <= Len(traces[t])}

SharedPostState(event) == <<
    event.state.shared_offset,
    event.state.offset_owner,
    event.state.file_size,
    event.state.cache_capacity,
    event.state.adapter_profile,
    event.state.effect_log_len,
    event.state.commit_log_len
>>

\* Disjoint intervals retain real-time order. Overlapping events remain
\* unordered only when their captured shared post-state agrees; otherwise the
\* earlier completion must replay first for both snapshots to be observable.
ViablePIDs ==
    {t \in ThreadsWithEvents :
        ~\E other \in ThreadsWithEvents :
            /\ other # t
            /\ \/ traces[other][pc[other]].end < traces[t][pc[t]].start
               \/ /\ traces[other][pc[other]].end < traces[t][pc[t]].end
                  /\ SharedPostState(traces[other][pc[other]])
                     # SharedPostState(traces[t][pc[t]])}

TraceOffsetOwner(event) ==
    IF event.state.offset_owner = "none"
    THEN NoThread
    ELSE event.state.offset_owner

(***************************************************************************)
(* Mandatory post-state validation                                         *)
(***************************************************************************)

\* Every event captures all implementation-observable shared fields and all
\* trace-shadow fields for the acting operation. The two history lengths
\* validate the derived ghost logs without requiring the kernel to serialize
\* their TLA+ records.
ValidatePostState(t, event) ==
    /\ sharedOffset' = event.state.shared_offset
    /\ offsetOwner' = TraceOffsetOwner(event)
    /\ fileSize' = event.state.file_size
    /\ cacheCapacity' = event.state.cache_capacity
    /\ adapterProfile' = event.state.adapter_profile
    /\ opState'[t].phase = event.state.phase
    /\ opState'[t].kind = event.state.kind
    /\ opState'[t].usesSharedOffset = event.state.uses_shared_offset
    /\ opState'[t].explicitOffset = event.state.explicit_offset
    /\ opState'[t].entryStart = event.state.entry_start
    /\ opState'[t].logicalAvail = event.state.logical_avail
    /\ opState'[t].copyLimit = event.state.copy_limit
    /\ opState'[t].iovIndex = event.state.iov_index
    /\ opState'[t].requested = event.state.requested
    /\ opState'[t].entryCopied = event.state.entry_copied
    /\ opState'[t].entryReturned = event.state.entry_returned
    /\ opState'[t].copied = event.state.copied
    /\ opState'[t].committed = event.state.committed
    /\ opState'[t].reported = event.state.reported
    /\ opState'[t].offsetAdvanced = event.state.offset_advanced
    /\ opState'[t].entryStatus = event.state.entry_status
    /\ opState'[t].result = event.state.result
    /\ opState'[t].lastFaultProgress = event.state.last_fault_progress
    /\ opState'[t].publishedEOF = event.state.published_eof
    /\ opState'[t].readPastEOF = event.state.read_past_eof
    /\ opState'[t].sizeAtEntry = event.state.size_at_entry
    /\ opState'[t].syscallId = event.state.syscall_id
    /\ opState'[t].attemptId = event.state.attempt_id
    /\ opState'[t].restartPending = event.state.restart_pending
    /\ opState'[t].signalPending = event.state.signal_pending
    /\ opState'[t].saRestart = event.state.sa_restart
    /\ Len(effectLog') = event.state.effect_log_len
    /\ Len(commitLog') = event.state.commit_log_len

(***************************************************************************)
(* Event matching                                                           *)
(***************************************************************************)

MatchEvent(t, event) ==
    CASE
    \* Syscall entry: kernel/core/src/syscall/read.rs:10-35
    event.event = "SysReadBegin" ->
        /\ Base!SysReadBegin(
            t, event.args.signal_pending, event.args.sa_restart)
        /\ ValidatePostState(t, event)

    \* Syscall entry: kernel/core/src/syscall/write.rs:10-35
    [] event.event = "SysWriteBegin" ->
        /\ Base!SysWriteBegin(
            t, event.args.signal_pending, event.args.sa_restart)
        /\ ValidatePostState(t, event)

    \* Positional read entry: kernel/core/src/syscall/pread64.rs:10-36
    [] event.event = "SysPread64Begin" ->
        /\ Base!SysPread64Begin(
            t,
            event.args.explicit_offset,
            event.args.signal_pending,
            event.args.sa_restart)
        /\ ValidatePostState(t, event)

    \* Positional write entry: kernel/core/src/syscall/pwrite64.rs:10-35
    [] event.event = "SysPwrite64Begin" ->
        /\ Base!SysPwrite64Begin(
            t,
            event.args.explicit_offset,
            event.args.signal_pending,
            event.args.sa_restart)
        /\ ValidatePostState(t, event)

    \* Vector read entry: kernel/core/src/syscall/preadv.rs:11-18,134-155
    [] event.event = "DoSysReadvBegin" ->
        /\ Base!DoSysReadvBegin(
            t, event.args.signal_pending, event.args.sa_restart)
        /\ ValidatePostState(t, event)

    \* Vector write entry: kernel/core/src/syscall/pwritev.rs:11-18,134-151
    [] event.event = "DoSysWritevBegin" ->
        /\ Base!DoSysWritevBegin(
            t, event.args.signal_pending, event.args.sa_restart)
        /\ ValidatePostState(t, event)

    \* Shared read lock: kernel/core/src/fs/file/inode_handle.rs:278-288
    [] event.event = "InodeHandleReadAcquireOffset" ->
        /\ Base!InodeHandleReadAcquireOffset(t)
        /\ ValidatePostState(t, event)

    \* Shared write lock: kernel/core/src/fs/file/inode_handle.rs:301-318
    [] event.event = "InodeHandleWriteAcquireOffset" ->
        /\ Base!InodeHandleWriteAcquireOffset(t)
        /\ ValidatePostState(t, event)

    \* Positional read start: kernel/core/src/fs/file/inode_handle.rs:323-332
    [] event.event = "InodeHandleReadAtStart" ->
        /\ Base!InodeHandleReadAtStart(t)
        /\ ValidatePostState(t, event)

    \* Positional write start: kernel/core/src/fs/file/inode_handle.rs:334-354
    [] event.event = "InodeHandleWriteAtStart" ->
        /\ Base!InodeHandleWriteAtStart(t)
        /\ ValidatePostState(t, event)

    \* Bounded read adapter: ext2/inode/file.rs:228-242 and
    \* virtiofs/inode/ops.rs:65-80
    [] event.event = "Ext2VirtioFsReadComputeLimit" ->
        /\ Base!Ext2VirtioFsReadComputeLimit(t)
        /\ ValidatePostState(t, event)

    \* Unbounded read adapters: ramfs/fs.rs:701-710 and exfat/inode.rs:648-657
    [] event.event = "RamFsExfatReadComputeLimit" ->
        /\ Base!RamFsExfatReadComputeLimit(t)
        /\ ValidatePostState(t, event)

    \* RamFS requested-end publication: ramfs/fs.rs:731-750
    [] event.event = "RamFsWritePublishRequestedEnd" ->
        /\ Base!RamFsWritePublishRequestedEnd(t)
        /\ ValidatePostState(t, event)

    \* Deferred/rollback setup: ext2/inode/file.rs:193-219,245-271 and
    \* exfat/inode.rs:711-743
    [] event.event = "DeferredWritePrepare" ->
        /\ Base!DeferredWritePrepare(t)
        /\ ValidatePostState(t, event)

    \* Fallible read copy: vmo/mod.rs:533-566; ostd/mm/io/mod.rs:332-361
    [] event.event = "VmoRead" ->
        /\ Base!VmoRead(t, event.args.progress)
        /\ ValidatePostState(t, event)

    \* Fallible write copy: vmo/mod.rs:569-640,667-750
    [] event.event = "VmoWrite" ->
        /\ Base!VmoWrite(t, event.args.progress)
        /\ ValidatePostState(t, event)

    \* Tuple conversion: kernel/core/src/error.rs:209-219
    [] event.event = "ErrorFromTuple" ->
        /\ Base!ErrorFromTuple(t)
        /\ ValidatePostState(t, event)

    \* Filesystem read return: ramfs/fs.rs:701-718; exfat/inode.rs:648-657;
    \* ext2/inode/file.rs:234-242
    [] event.event = "FileOpsReadReturn" ->
        /\ Base!FileOpsReadReturn(t)
        /\ ValidatePostState(t, event)

    \* Filesystem write return: ramfs/fs.rs:747-756; exfat/inode.rs:734-755;
    \* ext2/inode/file.rs:262-271
    [] event.event = "FileOpsWriteReturn" ->
        /\ Base!FileOpsWriteReturn(t)
        /\ ValidatePostState(t, event)

    \* Shared offset commit: inode_handle.rs:285-290,308-320
    [] event.event = "InodeHandleCommitOffset" ->
        /\ Base!InodeHandleCommitOffset(t)
        /\ ValidatePostState(t, event)

    \* Shared error propagation: inode_handle.rs:287-290,317-320
    [] event.event = "InodeHandlePropagateError" ->
        /\ Base!InodeHandlePropagateError(t)
        /\ ValidatePostState(t, event)

    \* Positional return: inode_handle.rs:323-354
    [] event.event = "InodeHandlePositionalReturn" ->
        /\ Base!InodeHandlePositionalReturn(t)
        /\ ValidatePostState(t, event)

    \* Shared offset unlock: inode_handle.rs:285-290,308-320
    [] event.event = "InodeHandleReleaseOffset" ->
        /\ Base!InodeHandleReleaseOffset(t)
        /\ ValidatePostState(t, event)

    \* readv entry dispatch: kernel/core/src/syscall/preadv.rs:156-174
    [] event.event = "DoSysReadvHandleEntry" ->
        /\ Base!DoSysReadvHandleEntry(t)
        /\ ValidatePostState(t, event)

    \* writev entry dispatch: kernel/core/src/syscall/pwritev.rs:152-170
    [] event.event = "DoSysWritevHandleEntry" ->
        /\ Base!DoSysWritevHandleEntry(t)
        /\ ValidatePostState(t, event)

    \* Scalar result mapping: kernel/core/src/syscall/read.rs:27-44
    [] event.event = "SysReadFinish" ->
        /\ Base!SysReadFinish(t)
        /\ ValidatePostState(t, event)

    \* Scalar result mapping: kernel/core/src/syscall/write.rs:27-44
    [] event.event = "SysWriteFinish" ->
        /\ Base!SysWriteFinish(t)
        /\ ValidatePostState(t, event)

    \* Positional result: kernel/core/src/syscall/pread64.rs:33-43
    [] event.event = "SysPread64Finish" ->
        /\ Base!SysPread64Finish(t)
        /\ ValidatePostState(t, event)

    \* Positional result: kernel/core/src/syscall/pwrite64.rs:33-41
    [] event.event = "SysPwrite64Finish" ->
        /\ Base!SysPwrite64Finish(t)
        /\ ValidatePostState(t, event)

    \* Vector result: kernel/core/src/syscall/preadv.rs:165-180
    [] event.event = "SysReadvFinish" ->
        /\ Base!SysReadvFinish(t)
        /\ ValidatePostState(t, event)

    \* Vector result: kernel/core/src/syscall/pwritev.rs:161-175
    [] event.event = "SysWritevFinish" ->
        /\ Base!SysWritevFinish(t)
        /\ ValidatePostState(t, event)

    \* Signal delivery/restart decision: process/signal/mod.rs:48-62,125-158
    [] event.event = "HandlePendingSignal" ->
        /\ Base!HandlePendingSignal(t)
        /\ ValidatePostState(t, event)

    \* Whole-syscall re-entry: process/signal/mod.rs:145-158
    [] event.event = "RestartSyscall" ->
        /\ Base!RestartSyscall(t)
        /\ ValidatePostState(t, event)

    [] OTHER -> FALSE

(***************************************************************************)
(* Init, Next, and completion                                                *)
(***************************************************************************)

TraceInit ==
    \* Base constants must match the trace's captured bootstrap state.
    /\ Base!Init
    /\ DOMAIN traces = Thread
    /\ sharedOffset = TraceData.initial_state.shared_offset
    /\ offsetOwner = NoThread
    /\ fileSize = TraceData.initial_state.file_size
    /\ cacheCapacity = TraceData.initial_state.cache_capacity
    /\ adapterProfile = TraceData.initial_state.adapter_profile
    /\ pc = [t \in Thread |-> 1]

ConsumeTraceEvent ==
    /\ ThreadsWithEvents # {}
    /\ \E t \in ViablePIDs :
        LET event == traces[t][pc[t]]
        IN /\ MatchEvent(t, event)
           /\ pc' = [pc EXCEPT ![t] = @ + 1]

TraceNext ==
    \/ ConsumeTraceEvent
    \* No silent actions exist: every base-spec semantic boundary has a trace
    \* event. Stuttering is allowed only after every event was consumed.
    \/ /\ ThreadsWithEvents = {}
       /\ UNCHANGED traceAllVars

\* Weak fairness prevents the implicit stuttering admitted by [][A]_v from
\* falsifying TraceMatched while a matching trace event remains enabled.
TraceSpec ==
    /\ TraceInit
    /\ [][TraceNext]_traceAllVars
    /\ WF_traceAllVars(ConsumeTraceEvent)

TraceMatched == <>(ThreadsWithEvents = {})

TraceTypeOK ==
    /\ DOMAIN traces = Thread
    /\ pc \in [Thread -> Nat]
    /\ \A t \in Thread : pc[t] \in 1..(Len(traces[t]) + 1)

====
