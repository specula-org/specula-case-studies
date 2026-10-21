------------------------------ MODULE Trace ------------------------------
EXTENDS base, Json, IOUtils

\* Category B: a preprocessed, one-record NDJSON object holds per-thread
\* event arrays. Raw event files are never sorted into a total order.
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"
TraceData == JsonDeserialize(JsonFile)
TraceBackend == TraceData.backend
TraceThreads == {TraceData.threads[i] : i \in 1..Len(TraceData.threads)}
TraceP == TraceData.p
TraceG == TraceData.g
TraceMaxByte == TraceData.max_byte
TraceInitialSize == TraceData.initial_size
TraceInitialWarm == {TraceData.warm_pages[i] : i \in 1..Len(TraceData.warm_pages)}
TraceInitialPosition == TraceData.initial_position
traces == TraceData.traces
SeqSet(s) == {s[i] : i \in 1..Len(s)}

VARIABLE l
traceVars == <<vars, l>>
ThreadsWithEvents == {t \in Threads : l[t] <= Len(traces[t])}
ViablePIDs ==
    {t \in ThreadsWithEvents :
       ~\E u \in ThreadsWithEvents :
          u /= t /\ traces[u][l[u]].end < traces[t][l[t]].start}

\* Validate a fixed, mandatory local projection; ghost reference histories
\* are derived from these native observations and are not fabricated fields.
LocalObserved(x) ==
    [pc |-> x.pc,
     kind |-> x.kind,
     O |-> x.O,
     N |-> x.N,
     target |-> x.target,
     fault |-> x.fault,
     S |-> x.S,
     K |-> x.K,
     copyO |-> x.copyO,
     candidate |-> x.candidate,
     D |-> x.D,
     status |-> x.status,
     errorSite |-> x.errorSite,
     result |-> x.result,
     ioKind |-> x.ioKind,
     ioOff |-> x.ioOff,
     ioLen |-> x.ioLen,
     ioDone |-> x.ioDone,
     ioEnd |-> x.ioEnd,
     page |-> x.page,
     afterIo |-> x.afterIo,
     resizeOld |-> x.resizeOld,
     resizeNew |-> x.resizeNew,
     resizePurpose |-> x.resizePurpose,
     afterResize |-> x.afterResize,
     segmentEnd |-> x.segmentEnd,
     collectNext |-> x.collectNext,
     collectEnd |-> x.collectEnd,
     overwrite |-> x.overwrite,
     out |-> x.out]

\* Each action has precise field requirements, including empty projections.
\* Source locations and capture points are in instrumentation-spec.md.
InodeFields(a) ==
    CASE a \in {"RamfsWriteAtPublish", "RamfsResize", "RamfsResizePublish",
                 "Ext2ResizePublish", "Ext2WriteAtPublish", "ExfatWriteAtPublish"} -> {"L"}
      [] a = "ExfatResizeAllocation" -> {"L", "A", "clusters"}
      [] a = "PageCacheResizeCapacity" -> {"C"}
      [] a = "Ext2ResizePageCacheBound" -> {"npages"}
      [] OTHER -> {}
PageFields(t, a) ==
    CASE a \in {"VmoCommitPage", "VmoBackendRead"} ->
              {IF a = "VmoCommitPage" THEN q[t].collectNext ELSE q[t].page}
      [] a = "VmoCopyPage" /\ q[t].ioKind /= "Read" -> {q[t].page}
      [] a = "PageCacheResizeCapacity" ->
              {j \in Pages : q[t].resizeNew < q[t].resizeOld
                 /\ j * P >= Round(q[t].resizeNew, P) /\ j * P < f.C}
      [] OTHER -> {}
DiskFields(t, a) ==
    IF a = "Ext2AllocateRangeBlocks"
    THEN {j \in Pages : j * P < q[t].candidate /\ (j + 1) * P > q[t].O} \ f.blocks
    ELSE {}
HasBlocks(a) == a \in {"Ext2AllocateRangeBlocks", "Ext2ResizePublish", "Ext2RollbackBlocks"}
HasPosition(t, a) == q[t].kind = "read" /\ a = "InodeHandleReturn"
HeldAfter(t) == [cache |-> mu'.cache = t, writer |-> mu'.writer = t,
                 up |-> mu'.up = t, reader |-> t \in mu'.readers,
                 offset |-> mu'.offset = t]

\* Every captured field is checked; required fields cannot be omitted.
ValidatePostState(t, e) ==
    /\ DOMAIN e.state = {"local", "accepted", "held", "inode", "pages", "disk", "blocks", "position"}
    /\ e.state.local = LocalObserved(q'[t])
    /\ SeqSet(e.state.accepted) = q'[t].accepted
    /\ Len(e.state.accepted) = Cardinality(q'[t].accepted)
    /\ e.state.held = HeldAfter(t)
    /\ DOMAIN e.state.inode = InodeFields(e.event)
    /\ \A key \in DOMAIN e.state.inode : e.state.inode[key] = f'[key]
    /\ SeqSet([i \in 1..Len(e.state.pages) |-> e.state.pages[i].index]) = PageFields(t, e.event)
    /\ Len(e.state.pages) = Cardinality(PageFields(t, e.event))
    /\ \A i \in 1..Len(e.state.pages) :
          LET item == e.state.pages[i] IN
          /\ DOMAIN item = {"index", "state", "data"}
          /\ item.state = f'.pages[item.index + 1]
          /\ item.data = SubSeq(f'.data, item.index * P + 1, (item.index + 1) * P)
    /\ SeqSet([i \in 1..Len(e.state.disk) |-> e.state.disk[i].index]) = DiskFields(t, e.event)
    /\ Len(e.state.disk) = Cardinality(DiskFields(t, e.event))
    /\ \A i \in 1..Len(e.state.disk) :
          LET item == e.state.disk[i] IN
          /\ DOMAIN item = {"index", "data"}
          /\ item.data = SubSeq(f'.disk, item.index * P + 1, (item.index + 1) * P)
    /\ IF HasBlocks(e.event)
       THEN Len(e.state.blocks) = 1 /\ SeqSet(e.state.blocks[1]) = f'.blocks
       ELSE e.state.blocks = <<>>
    /\ IF HasPosition(t, e.event)
             \/ (e.event = "SyscallEnter" /\ e.args[1] = "read")
       THEN e.state.position = <<position'>>
       ELSE e.state.position = <<>>

\* Full base actions are called directly. No silent state repair or bypass.
TraceSyscallEnter(t, e) ==
    /\ e.event = "SyscallEnter" /\ Len(e.args) = 5
    /\ SyscallEnter(t, e.args[1], e.args[2], e.args[3], e.args[4], e.args[5])
    /\ ValidatePostState(t, e)

TraceRamfsReadAtObserve(t, e) ==
    /\ e.event = "RamfsReadAtObserve" /\ e.args = <<>>
    /\ RamfsReadAtObserve(t)
    /\ ValidatePostState(t, e)

TraceRamfsReadAtAcquireCache(t, e) ==
    /\ e.event = "RamfsReadAtAcquireCache" /\ e.args = <<>>
    /\ RamfsReadAtAcquireCache(t)
    /\ ValidatePostState(t, e)

TraceExt2ReadAt(t, e) ==
    /\ e.event = "Ext2ReadAt" /\ e.args = <<>>
    /\ Ext2ReadAt(t)
    /\ ValidatePostState(t, e)

TraceExfatReadAt(t, e) ==
    /\ e.event = "ExfatReadAt" /\ e.args = <<>>
    /\ ExfatReadAt(t)
    /\ ValidatePostState(t, e)

TraceExt2ReadAtEmpty(t, e) ==
    /\ e.event = "Ext2ReadAtEmpty" /\ e.args = <<>>
    /\ Ext2ReadAtEmpty(t)
    /\ ValidatePostState(t, e)

TraceExt2WriteAtEmpty(t, e) ==
    /\ e.event = "Ext2WriteAtEmpty" /\ e.args = <<>>
    /\ Ext2WriteAtEmpty(t)
    /\ ValidatePostState(t, e)

TraceRamfsWriteAtAcquireCache(t, e) ==
    /\ e.event = "RamfsWriteAtAcquireCache" /\ e.args = <<>>
    /\ RamfsWriteAtAcquireCache(t)
    /\ ValidatePostState(t, e)

TraceRamfsWriteAtPublish(t, e) ==
    /\ e.event = "RamfsWriteAtPublish" /\ e.args = <<>>
    /\ RamfsWriteAtPublish(t)
    /\ ValidatePostState(t, e)

TraceExt2WriteAtPrepare(t, e) ==
    /\ e.event = "Ext2WriteAtPrepare" /\ e.args = <<>>
    /\ Ext2WriteAtPrepare(t)
    /\ ValidatePostState(t, e)

TraceExt2AllocateRangeBlocks(t, e) ==
    /\ e.event = "Ext2AllocateRangeBlocks" /\ e.args = <<>>
    /\ Ext2AllocateRangeBlocks(t)
    /\ ValidatePostState(t, e)

TraceExfatWriteAtPrepare(t, e) ==
    /\ e.event = "ExfatWriteAtPrepare" /\ e.args = <<>>
    /\ ExfatWriteAtPrepare(t)
    /\ ValidatePostState(t, e)

TraceExfatResizeAllocation(t, e) ==
    /\ e.event = "ExfatResizeAllocation" /\ e.args = <<>>
    /\ ExfatResizeAllocation(t)
    /\ ValidatePostState(t, e)

TraceExfatWriteAtReleasePreparation(t, e) ==
    /\ e.event = "ExfatWriteAtReleasePreparation" /\ e.args = <<>>
    /\ ExfatWriteAtReleasePreparation(t)
    /\ ValidatePostState(t, e)

TraceExfatWriteAtAcquireCopy(t, e) ==
    /\ e.event = "ExfatWriteAtAcquireCopy" /\ e.args = <<>>
    /\ ExfatWriteAtAcquireCopy(t)
    /\ ValidatePostState(t, e)

TraceRamfsResizeAcquireCache(t, e) ==
    /\ e.event = "RamfsResizeAcquireCache" /\ e.args = <<>>
    /\ RamfsResizeAcquireCache(t)
    /\ ValidatePostState(t, e)

TraceRamfsResize(t, e) ==
    /\ e.event = "RamfsResize" /\ e.args = <<>>
    /\ RamfsResize(t)
    /\ ValidatePostState(t, e)

TraceRamfsResizePublish(t, e) ==
    /\ e.event = "RamfsResizePublish" /\ e.args = <<>>
    /\ RamfsResizePublish(t)
    /\ ValidatePostState(t, e)

TraceExt2Resize(t, e) ==
    /\ e.event = "Ext2Resize" /\ e.args = <<>>
    /\ Ext2Resize(t)
    /\ ValidatePostState(t, e)

TraceExt2ResizePublish(t, e) ==
    /\ e.event = "Ext2ResizePublish" /\ e.args = <<>>
    /\ Ext2ResizePublish(t)
    /\ ValidatePostState(t, e)

TraceExfatResize(t, e) ==
    /\ e.event = "ExfatResize" /\ e.args = <<>>
    /\ ExfatResize(t)
    /\ ValidatePostState(t, e)

TraceExfatResizeUpgrade(t, e) ==
    /\ e.event = "ExfatResizeUpgrade" /\ e.args = <<>>
    /\ ExfatResizeUpgrade(t)
    /\ ValidatePostState(t, e)

TracePageCacheResizeBegin(t, e) ==
    /\ e.event = "PageCacheResizeBegin" /\ e.args = <<>>
    /\ PageCacheResizeBegin(t)
    /\ ValidatePostState(t, e)

TracePageCacheFillZeros(t, e) ==
    /\ e.event = "PageCacheFillZeros" /\ e.args = <<>>
    /\ PageCacheFillZeros(t)
    /\ ValidatePostState(t, e)

TracePageCacheResizeCapacity(t, e) ==
    /\ e.event = "PageCacheResizeCapacity" /\ e.args = <<>>
    /\ PageCacheResizeCapacity(t)
    /\ ValidatePostState(t, e)

TraceExt2ResizePageCacheBound(t, e) ==
    /\ e.event = "Ext2ResizePageCacheBound" /\ e.args = <<>>
    /\ Ext2ResizePageCacheBound(t)
    /\ ValidatePostState(t, e)

TraceWriteAtCopyStart(t, e) ==
    /\ e.event = "WriteAtCopyStart" /\ e.args = <<>>
    /\ WriteAtCopyStart(t)
    /\ ValidatePostState(t, e)

TraceVmoIoBegin(t, e) ==
    /\ e.event = "VmoIoBegin" /\ e.args = <<>>
    /\ VmoIoBegin(t)
    /\ ValidatePostState(t, e)

TraceVmoCollectBegin(t, e) ==
    /\ e.event = "VmoCollectBegin" /\ e.args = <<>>
    /\ VmoCollectBegin(t)
    /\ ValidatePostState(t, e)

TraceVmoCommitPage(t, e) ==
    /\ e.event = "VmoCommitPage" /\ e.args = <<>>
    /\ VmoCommitPage(t)
    /\ ValidatePostState(t, e)

TraceVmoCollectedPage(t, e) ==
    /\ e.event = "VmoCollectedPage" /\ e.args = <<>>
    /\ VmoCollectedPage(t)
    /\ ValidatePostState(t, e)

TraceExfatBackendReadBlocked(t, e) ==
    /\ e.event = "ExfatBackendReadBlocked" /\ e.args = <<>>
    /\ ExfatBackendReadBlocked(t)
    /\ ValidatePostState(t, e)

TraceVmoBackendRead(t, e) ==
    /\ e.event = "VmoBackendRead" /\ e.args = <<>>
    /\ VmoBackendRead(t)
    /\ ValidatePostState(t, e)

TraceVmoRangeError(t, e) ==
    /\ e.event = "VmoRangeError" /\ e.args = <<>>
    /\ VmoRangeError(t)
    /\ ValidatePostState(t, e)

TraceVmoCopyPage(t, e) ==
    /\ e.event = "VmoCopyPage" /\ e.args = <<>>
    /\ VmoCopyPage(t)
    /\ ValidatePostState(t, e)

TraceExt2WriteAtPublish(t, e) ==
    /\ e.event = "Ext2WriteAtPublish" /\ e.args = <<>>
    /\ Ext2WriteAtPublish(t)
    /\ ValidatePostState(t, e)

TraceExfatWriteAtPublish(t, e) ==
    /\ e.event = "ExfatWriteAtPublish" /\ e.args = <<>>
    /\ ExfatWriteAtPublish(t)
    /\ ValidatePostState(t, e)

TraceExt2RollbackWrite(t, e) ==
    /\ e.event = "Ext2RollbackWrite" /\ e.args = <<>>
    /\ Ext2RollbackWrite(t)
    /\ ValidatePostState(t, e)

TraceExt2RollbackBlocks(t, e) ==
    /\ e.event = "Ext2RollbackBlocks" /\ e.args = <<>>
    /\ Ext2RollbackBlocks(t)
    /\ ValidatePostState(t, e)

TraceBackendReturn(t, e) ==
    /\ e.event = "BackendReturn" /\ e.args = <<>>
    /\ BackendReturn(t)
    /\ ValidatePostState(t, e)

TraceExt2ReadAtUpdateAtime(t, e) ==
    /\ e.event = "Ext2ReadAtUpdateAtime" /\ e.args = <<>>
    /\ Ext2ReadAtUpdateAtime(t)
    /\ ValidatePostState(t, e)

TraceInodeHandleReturn(t, e) ==
    /\ e.event = "InodeHandleReturn" /\ e.args = <<>>
    /\ InodeHandleReturn(t)
    /\ ValidatePostState(t, e)

MatchEvent(t, e) ==
    /\ e.tag = "trace" /\ e.tid = t
    /\ CASE e.event = "SyscallEnter" -> TraceSyscallEnter(t, e)
         [] e.event = "RamfsReadAtObserve" -> TraceRamfsReadAtObserve(t, e)
         [] e.event = "RamfsReadAtAcquireCache" -> TraceRamfsReadAtAcquireCache(t, e)
         [] e.event = "Ext2ReadAt" -> TraceExt2ReadAt(t, e)
         [] e.event = "ExfatReadAt" -> TraceExfatReadAt(t, e)
         [] e.event = "Ext2ReadAtEmpty" -> TraceExt2ReadAtEmpty(t, e)
         [] e.event = "Ext2WriteAtEmpty" -> TraceExt2WriteAtEmpty(t, e)
         [] e.event = "RamfsWriteAtAcquireCache" -> TraceRamfsWriteAtAcquireCache(t, e)
         [] e.event = "RamfsWriteAtPublish" -> TraceRamfsWriteAtPublish(t, e)
         [] e.event = "Ext2WriteAtPrepare" -> TraceExt2WriteAtPrepare(t, e)
         [] e.event = "Ext2AllocateRangeBlocks" -> TraceExt2AllocateRangeBlocks(t, e)
         [] e.event = "ExfatWriteAtPrepare" -> TraceExfatWriteAtPrepare(t, e)
         [] e.event = "ExfatResizeAllocation" -> TraceExfatResizeAllocation(t, e)
         [] e.event = "ExfatWriteAtReleasePreparation" -> TraceExfatWriteAtReleasePreparation(t, e)
         [] e.event = "ExfatWriteAtAcquireCopy" -> TraceExfatWriteAtAcquireCopy(t, e)
         [] e.event = "RamfsResizeAcquireCache" -> TraceRamfsResizeAcquireCache(t, e)
         [] e.event = "RamfsResize" -> TraceRamfsResize(t, e)
         [] e.event = "RamfsResizePublish" -> TraceRamfsResizePublish(t, e)
         [] e.event = "Ext2Resize" -> TraceExt2Resize(t, e)
         [] e.event = "Ext2ResizePublish" -> TraceExt2ResizePublish(t, e)
         [] e.event = "ExfatResize" -> TraceExfatResize(t, e)
         [] e.event = "ExfatResizeUpgrade" -> TraceExfatResizeUpgrade(t, e)
         [] e.event = "PageCacheResizeBegin" -> TracePageCacheResizeBegin(t, e)
         [] e.event = "PageCacheFillZeros" -> TracePageCacheFillZeros(t, e)
         [] e.event = "PageCacheResizeCapacity" -> TracePageCacheResizeCapacity(t, e)
         [] e.event = "Ext2ResizePageCacheBound" -> TraceExt2ResizePageCacheBound(t, e)
         [] e.event = "WriteAtCopyStart" -> TraceWriteAtCopyStart(t, e)
         [] e.event = "VmoIoBegin" -> TraceVmoIoBegin(t, e)
         [] e.event = "VmoCollectBegin" -> TraceVmoCollectBegin(t, e)
         [] e.event = "VmoCommitPage" -> TraceVmoCommitPage(t, e)
         [] e.event = "VmoCollectedPage" -> TraceVmoCollectedPage(t, e)
         [] e.event = "ExfatBackendReadBlocked" -> TraceExfatBackendReadBlocked(t, e)
         [] e.event = "VmoBackendRead" -> TraceVmoBackendRead(t, e)
         [] e.event = "VmoRangeError" -> TraceVmoRangeError(t, e)
         [] e.event = "VmoCopyPage" -> TraceVmoCopyPage(t, e)
         [] e.event = "Ext2WriteAtPublish" -> TraceExt2WriteAtPublish(t, e)
         [] e.event = "ExfatWriteAtPublish" -> TraceExfatWriteAtPublish(t, e)
         [] e.event = "Ext2RollbackWrite" -> TraceExt2RollbackWrite(t, e)
         [] e.event = "Ext2RollbackBlocks" -> TraceExt2RollbackBlocks(t, e)
         [] e.event = "BackendReturn" -> TraceBackendReturn(t, e)
         [] e.event = "Ext2ReadAtUpdateAtime" -> TraceExt2ReadAtUpdateAtime(t, e)
         [] e.event = "InodeHandleReturn" -> TraceInodeHandleReturn(t, e)
         [] OTHER -> FALSE

\* All bootstrap fields are fixture inputs, never inferred from a desired
\* final result. No initial operation or pending mutation is hidden.
TraceInputOK ==
    /\ TraceData.format = "asterinas-buffered-v1"
    /\ TraceData.revision = "604948581512d83734377974d4c34adb4530f2d7"
    /\ DOMAIN traces = Threads
    /\ Len(TraceData.threads) = Cardinality(Threads)
    /\ \E t \in Threads : Len(traces[t]) > 0
    /\ \A t \in Threads : \A i \in 1..Len(traces[t]) :
          /\ DOMAIN traces[t][i] = {"tag", "event", "tid", "start", "end", "args", "state"}
          /\ traces[t][i].start \in Nat /\ traces[t][i].end \in Nat
          /\ traces[t][i].start <= traces[t][i].end
          /\ traces[t][i].tid = t /\ traces[t][i].tag = "trace"
          /\ (i > 1 => traces[t][i - 1].end <= traces[t][i].start)
TraceInit ==
    /\ Assert(TraceInputOK, "Invalid or empty trace input")
    /\ Init
    /\ l = [t \in Threads |-> 1]
TraceNext ==
    \/ /\ ThreadsWithEvents /= {}
       /\ \E t \in ViablePIDs :
             /\ MatchEvent(t, traces[t][l[t]])
             /\ l' = [l EXCEPT ![t] = @ + 1]
    \/ /\ ThreadsWithEvents = {}
       /\ UNCHANGED traceVars

\* Fairness belongs only to the offline cursor, excluding arbitrary replay
\* stuttering. It cannot enable a blocked base step or prove kernel liveness.
TraceSpec == TraceInit /\ [][TraceNext]_traceVars /\ WF_traceVars(TraceNext)
TraceMatched == <>(ThreadsWithEvents = {})
\* Optional existential witness mode: a violation proves complete consumption.
\* Needed when a different viable ordering is a dead end under universal TLC
\* liveness checking. Never treat a partial replay as a matching witness.
TraceNotComplete == ThreadsWithEvents /= {}
=============================================================================
