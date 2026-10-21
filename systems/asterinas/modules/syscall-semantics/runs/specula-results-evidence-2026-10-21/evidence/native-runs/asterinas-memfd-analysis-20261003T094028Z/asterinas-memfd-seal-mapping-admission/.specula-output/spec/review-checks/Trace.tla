------------------------------ MODULE Trace ------------------------------
EXTENDS base, Json, IOUtils

\* Category B: file order only orders events within a thread. Across threads,
\* tight source-step timeboxes constrain the possible linearization orders.
JsonFile == IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
            ELSE "../traces/trace.ndjson"
RawLog == ndJsonDeserialize(JsonFile)
Bootstrap == Head(RawLog)
TraceLog == Tail(RawLog)
traces == [t \in Threads |-> SelectSeq(TraceLog,LAMBDA e : e.thread = t)]

VARIABLES pc, l
traceVars == <<s,pc,l>>
ThreadsWithEvents == {t \in Threads : pc[t] <= Len(traces[t])}
ViablePIDs == {t \in ThreadsWithEvents :
    ~\E u \in ThreadsWithEvents : u /= t /\
        traces[u][pc[u]].end < traces[t][pc[t]].start}

\* JSON carries integers for bitsets and ascending arrays for finite sets.
PermMask(p) == (IF "R" \in p THEN 1 ELSE 0) +
              (IF "W" \in p THEN 2 ELSE 0) + (IF "X" \in p THEN 4 ELSE 0)
SealMask(p) == (IF "SEAL" \in p THEN 1 ELSE 0) +
              (IF "WRITE" \in p THEN 8 ELSE 0) + (IF "FUTURE" \in p THEN 16 ELSE 0)
DecodePerm(n) == CHOOSE p \in SUBSET Perms : PermMask(p) = n
DecodeSeals(n) == CHOOSE p \in SUBSET SealBits : SealMask(p) = n
PageList(as) == SelectSeq(OrderedPages,LAMBDA a : a \in as)
OwnerList(os) == SelectSeq([i \in 1..OwnerSlots |-> i],LAMBDA o : o \in os)
EmptyRecord == [x \in {} |-> x]
RequestJSON(r) == [kind |-> r.kind, lo |-> r.lo, hi |-> r.hi, off |-> r.off,
    fd |-> r.fd, shared |-> r.shared, perms |-> PermMask(r.perms),
    fixed |-> r.fixed, seals |-> SealMask(r.bits)]
RequestFromJSON(r) == Request(r.kind,r.lo,r.hi,r.off,r.fd,r.shared,
                            DecodePerm(r.perms),r.fixed,DecodeSeals(r.seals))
QueueJSON(q) == [i \in 1..Len(q) |-> [lo |-> q[i].lo, hi |-> q[i].hi,
    perms |-> PermMask(q[i].perms), may |-> PermMask(q[i].may)]]
LocalJSON(c) ==
    [pc |-> c.pc, serial |-> c.serial, request |-> RequestJSON(c.req),
     result |-> c.result, may |-> PermMask(c.may), tracked |-> c.track,
     checked |-> c.checked, observed |-> SealMask(c.observed),
     queue |-> QueueJSON(c.queue), index |-> c.index, last_end |-> c.lastEnd,
     cur |-> c.cur, tmp |-> c.tmp, part_lo |-> c.partLo, part_hi |-> c.partHi,
     cut |-> c.cut, side |-> c.side, rest |-> c.rest, done |-> PageList(c.done),
     touched |-> PageList(c.touched), merge_side |-> c.mergeSide,
     neighbor |-> c.neighbor, anchor |-> c.anchor, generation |-> c.generation,
     deny_count |-> c.denyCount]
OwnerJSON(o,m) ==
    [id |-> o, role |-> m.role, lo |-> m.lo, hi |-> m.hi, off |-> m.off,
     fd |-> m.fd, shared |-> m.shared, perms |-> PermMask(m.perms),
     may |-> PermMask(m.may), tracked |-> m.tracked,
     generations |-> [i \in 1..NumPages |-> IF i-1 \in Range(m) THEN m.gens[i-1] ELSE 0]]
TranslationJSON(a,tr) == [addr |-> a, generation |-> tr.gen, perms |-> PermMask(tr.perms)]

\* Required fields follow actual changes. Counter fields come from RMW return
\* values, not a later racy load. No optional/missing-field test weakens checks.
OwnerActions == {"MappedVmoNew","VmarProtectTake","VmarRemoveNext",
    "MappedVmoDupAtOffset","VmMappingSplit","VmarInsertRest","VmMappingProtect",
    "MappedVmoDropUnmapped","MappedVmoDupForMerge","MappedVmoDropMergeSelf",
    "MappedVmoDropMergeNeighbor","VmarInsertMapping"}
TreeActions == {"VmarLock","VmarProtectTake","VmarRemoveNext","VmarInsertRest",
    "MappedVmoDropMergeNeighbor","VmarInsertMapping","VmarUnlock"}
SealActions == {"MemfdAddSealsLock","MemfdAddSealsCheck","MemfdPublishSeals",
    "MemfdAddSealsUnlock","MemfdGetSeals"}
CounterEvent(t,name) ==
    \/ name = "WritableMappingDeny"
    \/ (name = "MappedVmoNew" /\ s.call[t].track)
    \/ (name \in {"MappedVmoDupAtOffset","MappedVmoDropUnmapped","MappedVmoDropMergeSelf"}
        /\ s.owner[s.call[t].cur].tracked)
    \/ (name = "MappedVmoDropMergeNeighbor" /\ s.owner[s.call[t].neighbor].tracked)
    \/ (name = "MappedVmoDupForMerge" /\
        LET c == s.call[t] x == s.owner[c.cur] y == s.owner[c.neighbor] IN
        IF x.lo < y.lo THEN x.tracked ELSE y.tracked)
ChangedOwners ==
    LET ids == OwnerList({o \in OwnerIds : s.owner[o] /= s'.owner[o]}) IN
    [i \in 1..Len(ids) |-> OwnerJSON(ids[i],s'.owner[ids[i]])]
TreeJSON == LET ids == OwnerList(s'.tree) IN
    [i \in 1..Len(ids) |-> OwnerJSON(ids[i],s'.owner[ids[i]])]
ChangedPtes ==
    LET as == PageList({a \in Pages : s.pt[a] /= s'.pt[a]}) IN
    [i \in 1..Len(as) |-> TranslationJSON(as[i],s'.pt[as[i]])]
ReturnValue(c) ==
    CASE c.result = "EPERM" -> -1 [] c.result = "EACCES" -> -13
      [] c.result = "EBUSY" -> -16 [] c.result = "ENOMEM" -> -12
      [] c.req.kind = "map" -> Bootstrap.base_address + c.req.lo * Bootstrap.page_size
      [] c.req.kind = "get" -> SealMask(c.observed)
      [] OTHER -> 0

PostState(t,name) ==
    [local |-> LocalJSON(s'.call[t])]
    @@ (IF name \in OwnerActions THEN [owners |-> ChangedOwners] ELSE EmptyRecord)
    @@ (IF name \in TreeActions THEN [tree |-> TreeJSON] ELSE EmptyRecord)
    @@ (IF CounterEvent(t,name) THEN [counter |-> s'.status] ELSE EmptyRecord)
    @@ (IF name \in SealActions \/ (name = "MemfdCheckWritable" /\ s'.call[t].checked)
        THEN [seals |-> SealMask(s'.seals)] ELSE EmptyRecord)
    @@ (IF name \in {"VmarLock","VmarUnlock"}
        THEN [vmar_owner |-> s'.vmarLock] ELSE EmptyRecord)
    @@ (IF name \in {"MemfdAddSealsLock","MemfdAddSealsUnlock"}
        THEN [seal_owner |-> s'.sealLock] ELSE EmptyRecord)
    @@ (IF name \in {"CursorUnmap","CursorProtect","HandlePageFault"}
        THEN [ptes |-> ChangedPtes] ELSE EmptyRecord)
    @@ (IF name = "DispatchTlbFlush" THEN [dispatched |-> PageList(s.call[t].touched)] ELSE EmptyRecord)
    @@ (IF name = "SyncTlbFlush" THEN [completed |-> PageList(s.call[t].touched)] ELSE EmptyRecord)
    @@ (IF name = "SyscallReturn" THEN [return_value |-> ReturnValue(s'.call[t])] ELSE EmptyRecord)

ValidatePostState(t,e) == e.state = PostState(t,e.event)

\* Every wrapper below calls the complete base action. The shared validator
\* requires the exact payload, including all emitted source-state fields.
TraceSyscallEnter(t,e) ==
    /\ e.event = "SyscallEnter"
    /\ SyscallEnter(t,RequestFromJSON(e.args))
    /\ ValidatePostState(t,e)

TraceMmapFdMode(t,e) ==
    /\ e.event = "MmapFdMode"
    /\ MmapFdMode(t)
    /\ ValidatePostState(t,e)

TraceVmarLock(t,e) ==
    /\ e.event = "VmarLock"
    /\ VmarLock(t)
    /\ ValidatePostState(t,e)

TraceMemfdCheckWritable(t,e) ==
    /\ e.event = "MemfdCheckWritable"
    /\ MemfdCheckWritable(t)
    /\ ValidatePostState(t,e)

TraceMappedVmoNew(t,e) ==
    /\ e.event = "MappedVmoNew"
    /\ MappedVmoNew(t)
    /\ ValidatePostState(t,e)

TraceMemfdAddSealsLock(t,e) ==
    /\ e.event = "MemfdAddSealsLock"
    /\ MemfdAddSealsLock(t)
    /\ ValidatePostState(t,e)

TraceMemfdAddSealsCheck(t,e) ==
    /\ e.event = "MemfdAddSealsCheck"
    /\ MemfdAddSealsCheck(t)
    /\ ValidatePostState(t,e)

TraceWritableMappingDeny(t,e) ==
    /\ e.event = "WritableMappingDeny"
    /\ WritableMappingDeny(t)
    /\ ValidatePostState(t,e)

TraceMemfdPublishSeals(t,e) ==
    /\ e.event = "MemfdPublishSeals"
    /\ MemfdPublishSeals(t)
    /\ ValidatePostState(t,e)

TraceMemfdAddSealsUnlock(t,e) ==
    /\ e.event = "MemfdAddSealsUnlock"
    /\ MemfdAddSealsUnlock(t)
    /\ ValidatePostState(t,e)

TraceMemfdGetSeals(t,e) ==
    /\ e.event = "MemfdGetSeals"
    /\ MemfdGetSeals(t)
    /\ ValidatePostState(t,e)

TraceVmarProtectCheck(t,e) ==
    /\ e.event = "VmarProtectCheck"
    /\ VmarProtectCheck(t)
    /\ ValidatePostState(t,e)

TraceVmarProtectTake(t,e) ==
    /\ e.event = "VmarProtectTake"
    /\ VmarProtectTake(t)
    /\ ValidatePostState(t,e)

TraceVmarRemoveNext(t,e) ==
    /\ e.event = "VmarRemoveNext"
    /\ VmarRemoveNext(t)
    /\ ValidatePostState(t,e)

TraceVmMappingSplitRange(t,e) ==
    /\ e.event = "VmMappingSplitRange"
    /\ VmMappingSplitRange(t)
    /\ ValidatePostState(t,e)

TraceMappedVmoDupAtOffset(t,e) ==
    /\ e.event = "MappedVmoDupAtOffset"
    /\ MappedVmoDupAtOffset(t)
    /\ ValidatePostState(t,e)

TraceVmMappingSplit(t,e) ==
    /\ e.event = "VmMappingSplit"
    /\ VmMappingSplit(t)
    /\ ValidatePostState(t,e)

TraceVmarInsertRest(t,e) ==
    /\ e.event = "VmarInsertRest"
    /\ VmarInsertRest(t)
    /\ ValidatePostState(t,e)

TraceCursorUnmap(t,e) ==
    /\ e.event = "CursorUnmap"
    /\ CursorUnmap(t)
    /\ ValidatePostState(t,e)

TraceCursorProtect(t,e) ==
    /\ e.event = "CursorProtect"
    /\ CursorProtect(t)
    /\ ValidatePostState(t,e)

TraceDispatchTlbFlush(t,e) ==
    /\ e.event = "DispatchTlbFlush"
    /\ DispatchTlbFlush(t)
    /\ ValidatePostState(t,e)

TraceSyncTlbFlush(t,e) ==
    /\ e.event = "SyncTlbFlush"
    /\ SyncTlbFlush(t)
    /\ ValidatePostState(t,e)

TraceVmMappingProtect(t,e) ==
    /\ e.event = "VmMappingProtect"
    /\ VmMappingProtect(t)
    /\ ValidatePostState(t,e)

TraceMappedVmoDropUnmapped(t,e) ==
    /\ e.event = "MappedVmoDropUnmapped"
    /\ MappedVmoDropUnmapped(t)
    /\ ValidatePostState(t,e)

TraceVmarTryMerge(t,e) ==
    /\ e.event = "VmarTryMerge"
    /\ VmarTryMerge(t)
    /\ ValidatePostState(t,e)

TraceMappedVmoDupForMerge(t,e) ==
    /\ e.event = "MappedVmoDupForMerge"
    /\ MappedVmoDupForMerge(t)
    /\ ValidatePostState(t,e)

TraceMappedVmoDropMergeSelf(t,e) ==
    /\ e.event = "MappedVmoDropMergeSelf"
    /\ MappedVmoDropMergeSelf(t)
    /\ ValidatePostState(t,e)

TraceMappedVmoDropMergeNeighbor(t,e) ==
    /\ e.event = "MappedVmoDropMergeNeighbor"
    /\ MappedVmoDropMergeNeighbor(t)
    /\ ValidatePostState(t,e)

TraceVmarInsertMapping(t,e) ==
    /\ e.event = "VmarInsertMapping"
    /\ VmarInsertMapping(t)
    /\ ValidatePostState(t,e)

TraceVmarUnlock(t,e) ==
    /\ e.event = "VmarUnlock"
    /\ VmarUnlock(t)
    /\ ValidatePostState(t,e)

TraceHandlePageFault(t,e) ==
    /\ e.event = "HandlePageFault"
    /\ HandlePageFault(t)
    /\ ValidatePostState(t,e)

TraceSyscallReturn(t,e) ==
    /\ e.event = "SyscallReturn"
    /\ SyscallReturn(t)
    /\ ValidatePostState(t,e)

EventNames == {"SyscallEnter", "MmapFdMode", "VmarLock", "MemfdCheckWritable", "MappedVmoNew", "MemfdAddSealsLock", "MemfdAddSealsCheck", "WritableMappingDeny", "MemfdPublishSeals", "MemfdAddSealsUnlock", "MemfdGetSeals", "VmarProtectCheck", "VmarProtectTake", "VmarRemoveNext", "VmMappingSplitRange", "MappedVmoDupAtOffset", "VmMappingSplit", "VmarInsertRest", "CursorUnmap", "CursorProtect", "DispatchTlbFlush", "SyncTlbFlush", "VmMappingProtect", "MappedVmoDropUnmapped", "VmarTryMerge", "MappedVmoDupForMerge", "MappedVmoDropMergeSelf", "MappedVmoDropMergeNeighbor", "VmarInsertMapping", "VmarUnlock", "HandlePageFault", "SyscallReturn"}

MatchEvent(t,e) ==
    TraceSyscallEnter(t,e)
    \/ TraceMmapFdMode(t,e)
    \/ TraceVmarLock(t,e)
    \/ TraceMemfdCheckWritable(t,e)
    \/ TraceMappedVmoNew(t,e)
    \/ TraceMemfdAddSealsLock(t,e)
    \/ TraceMemfdAddSealsCheck(t,e)
    \/ TraceWritableMappingDeny(t,e)
    \/ TraceMemfdPublishSeals(t,e)
    \/ TraceMemfdAddSealsUnlock(t,e)
    \/ TraceMemfdGetSeals(t,e)
    \/ TraceVmarProtectCheck(t,e)
    \/ TraceVmarProtectTake(t,e)
    \/ TraceVmarRemoveNext(t,e)
    \/ TraceVmMappingSplitRange(t,e)
    \/ TraceMappedVmoDupAtOffset(t,e)
    \/ TraceVmMappingSplit(t,e)
    \/ TraceVmarInsertRest(t,e)
    \/ TraceCursorUnmap(t,e)
    \/ TraceCursorProtect(t,e)
    \/ TraceDispatchTlbFlush(t,e)
    \/ TraceSyncTlbFlush(t,e)
    \/ TraceVmMappingProtect(t,e)
    \/ TraceMappedVmoDropUnmapped(t,e)
    \/ TraceVmarTryMerge(t,e)
    \/ TraceMappedVmoDupForMerge(t,e)
    \/ TraceMappedVmoDropMergeSelf(t,e)
    \/ TraceMappedVmoDropMergeNeighbor(t,e)
    \/ TraceVmarInsertMapping(t,e)
    \/ TraceVmarUnlock(t,e)
    \/ TraceHandlePageFault(t,e)
    \/ TraceSyscallReturn(t,e)

\* Bootstrap fields are mandatory. Postprocessing must reject missing events,
\* bad clocks and unsupported source/FD identities before invoking TLC.
TraceInit ==
    /\ Bootstrap.tag = "setup"
    /\ Bootstrap.source = "0c60537098f4c2949ad2d382aaf499de72263d76"
    /\ Bootstrap.num_pages = NumPages /\ Bootstrap.owner_slots = OwnerSlots
    /\ Bootstrap.allow_sealing = AllowSealing
    /\ Bootstrap.page_size = 4096 /\ Bootstrap.base_address \in Nat \ {0}
    /\ Bootstrap.base_address % Bootstrap.page_size = 0
    /\ Bootstrap.eof_bytes = NumPages * Bootstrap.page_size
    /\ Bootstrap.initial_counter = 0
    /\ Bootstrap.inode = "memfd0" /\ Bootstrap.vmo = "vmo0"
    /\ Bootstrap.fd_modes = [rw |-> "O_RDWR", rw2 |-> "O_RDWR", ro |-> "O_RDONLY"]
    /\ Init /\ Bootstrap.initial_seals = SealMask(s.seals)
    /\ \A i \in 1..Len(TraceLog) :
        /\ TraceLog[i].tag = "trace" /\ TraceLog[i].thread \in Threads
        /\ TraceLog[i].event \in EventNames
        /\ TraceLog[i].start <= TraceLog[i].end
    /\ \A t \in Threads : \A i \in 1..(Len(traces[t])-1) :
        traces[t][i].end <= traces[t][i+1].start
    /\ pc = [t \in Threads |-> 1] /\ l = 1

\* All source boundaries are instrumentable here, so there are no silent
\* transitions and no skipped preconditions. Completion stutters explicitly.
TraceAdvance ==
    /\ ThreadsWithEvents /= {}
    /\ \E t \in ViablePIDs :
        /\ MatchEvent(t,traces[t][pc[t]])
        /\ pc' = [pc EXCEPT ![t] = @+1] /\ l' = l+1
TraceNext == TraceAdvance \/ (ThreadsWithEvents = {} /\ UNCHANGED traceVars)
\* Fairness here is only for the replay cursor, not for the kernel scheduler.
TraceSpec == TraceInit /\ [][TraceNext]_traceVars /\ WF_traceVars(TraceAdvance)
TraceMatched == <>(l > Len(TraceLog))
TraceNotComplete == l <= Len(TraceLog)
=============================================================================
