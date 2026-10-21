------------------------------ MODULE base ------------------------------
EXTENDS Integers, FiniteSets, Sequences, TLC

\* Category B. Source: 0c60537098f4c2949ad2d382aaf499de72263d76.
\* Paths below are relative to source/. This models one fixed-size memfd,
\* one VMAR, ordinary pages, valid arguments and sufficient memory.
\* Scenarios 1-4 require separate eligibility, tracking and ownership state.
CONSTANTS Threads, NumPages, OwnerSlots, AllowSealing
ASSUME /\ Cardinality(Threads) = 2 /\ "none" \notin Threads
       /\ NumPages >= 1 /\ OwnerSlots >= NumPages + 2
       /\ AllowSealing \in BOOLEAN

Pages == 0..(NumPages - 1)
OwnerIds == 1..OwnerSlots
Perms == {"R", "W", "X"}
SealBits == {"WRITE", "FUTURE", "SEAL"}
Files == {"rw", "rw2", "ro"}
WritableFile(f) == f \in {"rw", "rw2"}
Min(a,b) == IF a < b THEN a ELSE b
Max(a,b) == IF a > b THEN a ELSE b
Span(lo,hi) == lo..(hi - 1)
Range(m) == Span(m.lo,m.hi)
NoTranslation == [gen |-> 0, perms |-> {}]
NoOwner == [role |-> "free", lo |-> 0, hi |-> 0, off |-> 0,
            fd |-> "rw", shared |-> TRUE, perms |-> {}, may |-> {},
            tracked |-> FALSE, gens |-> [a \in Pages |-> 0]]
NoObservation == [gen |-> 0, offset |-> 0, fd |-> "rw", shared |-> TRUE,
                  perms |-> {}, may |-> {}]

\* Valid ordinary-page syscall inputs: syscall/{mmap,mprotect,munmap}.rs.
Request(k,lo,hi,off,fd,shared,p,fixed,bits) ==
    [kind |-> k, lo |-> lo, hi |-> hi, off |-> off, fd |-> fd,
     shared |-> shared, perms |-> p, fixed |-> fixed, bits |-> bits]
MapReq(lo,hi,off,fd,shared,p,fixed) ==
    Request("map",lo,hi,off,fd,shared,p,fixed,{})
ProtectReq(lo,hi,p) == Request("protect",lo,hi,0,"rw",TRUE,p,FALSE,{})
UnmapReq(lo,hi) == Request("unmap",lo,hi,0,"rw",TRUE,{},FALSE,{})
AddReq(bits) == Request("add",0,1,0,"rw",TRUE,{},FALSE,bits)
GetReq == Request("get",0,1,0,"rw",TRUE,{},FALSE,{})
FaultReq(a,p) == Request("fault",a,a+1,0,"rw",TRUE,p,FALSE,{})
ValidPerm(p) == p \subseteq Perms /\ ("W" \in p => "R" \in p)
Requests ==
    {MapReq(l,h,o,f,sh,p,fx) : l \in Pages, h \in 1..NumPages,
      o \in Pages, f \in Files, sh \in BOOLEAN,
      p \in {v \in SUBSET Perms : ValidPerm(v)}, fx \in BOOLEAN}
    \cup {ProtectReq(l,h,p) : l \in Pages, h \in 1..NumPages,
      p \in {v \in SUBSET Perms : ValidPerm(v)}}
    \cup {UnmapReq(l,h) : l \in Pages, h \in 1..NumPages}
    \cup {AddReq(b) : b \in SUBSET SealBits} \cup {GetReq}
    \cup {FaultReq(a,{"R","W"}) : a \in Pages}
ValidRequest(r) ==
    /\ r \in Requests /\ r.lo < r.hi
    /\ (r.kind = "map" => r.off + r.hi - r.lo <= NumPages)

\* Scenario 1: per-call snapshots survive the seal-check/counter window.
EmptyCall ==
    [pc |-> "idle", serial |-> 0, req |-> GetReq, result |-> "pending",
     may |-> Perms, track |-> FALSE, checked |-> FALSE, observed |-> {},
     beforeSeals |-> {}, before |-> [a \in Pages |-> NoObservation],
     queue |-> <<>>, index |-> 1, lastEnd |-> 0, cur |-> 0, tmp |-> 0,
     partLo |-> 0, partHi |-> 0, cut |-> 0, side |-> "left",
     rest |-> <<>>, done |-> {}, touched |-> {}, mergeSide |-> "prev",
     neighbor |-> 0, anchor |-> 0, generation |-> 0,
     denyCount |-> 0, denyEligible |-> 0, quiescent |-> FALSE]

\* Scenario 2: both locks and the single Relaxed atomic modification order.
\* Scenario 3: live wrappers include detached, split and merge temporaries.
\* pt/tlb are generation-tagged access, not physical-frame ownership.
\* Scenario 4: logs are observation ghosts, never transition guards.
VARIABLE s
vars == <<s>>
Live == {o \in OwnerIds : s.owner[o].role /= "free"}
\* vm_mapping.rs:732-747,808-821 and vmar_impls/mod.rs:391-411 transfer
\* ownership into the tree or a call-local value, never an unowned wrapper.
CallOwned == (UNION {{s.call[t].cur,s.call[t].tmp} \cup
    {s.call[t].rest[i] : i \in 1..Len(s.call[t].rest)} : t \in Threads}) \ {0}
Tracked == {o \in Live : s.owner[o].tracked}
Eligible == {o \in Live : s.owner[o].shared /\ "W" \in s.owner[o].may}
Free == OwnerIds \ Live
Fresh == CHOOSE o \in Free : \A p \in Free : o <= p
At(a) == {o \in s.tree : a \in Range(s.owner[o])}
AtStart(a) == {o \in s.tree : s.owner[o].lo = a}
One(os) == CHOOSE o \in os : TRUE
Observation(a) ==
    IF At(a) = {} THEN NoObservation
    ELSE LET m == s.owner[One(At(a))] IN
         [gen |-> m.gens[a], offset |-> m.off + a - m.lo,
          fd |-> m.fd, shared |-> m.shared, perms |-> m.perms, may |-> m.may]
Snapshot == [a \in Pages |-> Observation(a)]
\* VMAR iteration is ascending by address (protect.rs:25-30, mod.rs:386-391).
OrderedPages == [i \in 1..NumPages |-> i-1]
MappingQueue(r) ==
    LET starts == SelectSeq(OrderedPages, LAMBDA a :
        IF AtStart(a) = {} THEN FALSE ELSE
        LET m == s.owner[One(AtStart(a))] IN m.lo < r.hi /\ r.lo < m.hi)
    IN [i \in 1..Len(starts) |->
        LET m == s.owner[One(AtStart(starts[i]))] IN
        [lo |-> m.lo, hi |-> m.hi, perms |-> m.perms, may |-> m.may]]
Slice(m,l,h) == [m EXCEPT !.lo = l, !.hi = h, !.off = m.off + l - m.lo]

\* vm_mapping.rs:1056-1086. Full permissions, file-description identity and
\* contiguous backing offsets matter. Inode/VMO identity is fixed to one object.
Compatible(x,y) ==
    /\ x.hi = y.lo /\ x.fd = y.fd /\ x.shared = y.shared
    /\ x.perms = y.perms /\ x.may = y.may
    /\ x.off + x.hi - x.lo = y.off
Merged(x,y) == [x EXCEPT !.role = "merge", !.hi = y.hi,
    !.gens = [a \in Pages |-> IF a \in Range(y) THEN y.gens[a] ELSE x.gens[a]]]
Neighbor(c) ==
    IF c.mergeSide = "prev"
    THEN LET os == {o \in s.tree : s.owner[o].lo < c.anchor} IN
         IF os = {} THEN 0 ELSE CHOOSE o \in os :
             \A p \in os : s.owner[o].lo >= s.owner[p].lo
    ELSE LET os == {o \in s.tree : s.owner[o].lo > c.anchor} IN
         IF os = {} THEN 0 ELSE CHOOSE o \in os :
             \A p \in os : s.owner[o].lo <= s.owner[p].lo
CanMerge(c,n) == IF n = 0 THEN FALSE ELSE
    IF s.owner[c.cur].lo < s.owner[n].lo
    THEN Compatible(s.owner[c.cur],s.owner[n])
    ELSE Compatible(s.owner[n],s.owner[c.cur])

\* memfd.rs:231-274, vmo/mod.rs:1192-1193. Setup has performed ftruncate.
\* rw is the created O_RDWR description; rw2 and ro are stable reopened
\* descriptions of the same inode/VMO. No initial WRITE seal is fabricated.
Init == s =
    [seals |-> IF AllowSealing THEN {} ELSE {"SEAL"}, status |-> 0,
     sealLock |-> "none", vmarLock |-> "none",
     owner |-> [o \in OwnerIds |-> NoOwner], tree |-> {}, birth |-> <<>>,
     pt |-> [a \in Pages |-> NoTranslation],
     tlb |-> [a \in Pages |-> NoTranslation], retired |-> {},
     call |-> [t \in Threads |-> EmptyCall],
     sealLog |-> <<>>, mapLog |-> <<>>, protectLog |-> <<>>,
     releaseSafe |-> TRUE]

\* syscall/mmap.rs:16-35, fcntl.rs:207-224, mprotect.rs:11-53,
\* munmap.rs:8-24. The environment supplies only validated ordinary inputs.
SyscallEnter(t,r) ==
    /\ s.call[t].pc = "idle" /\ ValidRequest(r)
    /\ s' = [s EXCEPT !.call[t] = [EmptyCall EXCEPT
        !.serial = s.call[t].serial + 1, !.req = r,
        !.pc = CASE r.kind = "map" -> "fd"
                   [] r.kind \in {"protect","unmap"} -> "vmar_lock"
                   [] r.kind = "add" -> "seal_lock"
                   [] r.kind = "get" -> "get_seals"
                   [] OTHER -> "fault"]]

\* syscall/mmap.rs:128-140. O_RDONLY shared WRITE fails before VMAR mutation.
MmapFdMode(t) ==
    LET c == s.call[t] r == c.req
        denied == r.shared /\ ~WritableFile(r.fd) /\ "W" \in r.perms
    IN /\ c.pc = "fd"
       /\ s' = [s EXCEPT !.call[t].may =
                    IF r.shared /\ ~WritableFile(r.fd) THEN Perms \ {"W"} ELSE Perms,
            !.call[t].pc = IF denied THEN "return" ELSE "vmar_lock",
            !.call[t].result = IF denied THEN "EACCES" ELSE "pending"]

\* map.rs:269-326, protect.rs:21-29, unmap.rs:44-50.
\* A non-fixed address is a chosen successful allocator result, not a promise
\* that a conflicting hint succeeds. Fixed replacement enters removal first.
VmarLock(t) ==
    LET c == s.call[t] r == c.req IN
    /\ c.pc = "vmar_lock" /\ s.vmarLock = "none"
    /\ (r.kind = "map" /\ ~r.fixed =>
        \A a \in Span(r.lo,r.hi) : At(a) = {})
    /\ s' = [s EXCEPT !.vmarLock = t, !.call[t].before = Snapshot,
        !.call[t].beforeSeals = s.seals, !.call[t].queue = MappingQueue(r),
        !.call[t].lastEnd = r.lo,
        !.call[t].pc = CASE r.kind = "protect" -> "protect_check"
            [] r.kind = "unmap" \/ r.fixed -> "remove_next"
            [] OTHER -> "check_writable"]

\* memfd.rs:80-89 under the inode mutex; map.rs:337-349 retains TRUE
\* even when check_writable removes MAY_WRITE (TV-1). The read-only mutex
\* critical section is one action. The subsequent counter RMW is separate.
MemfdCheckWritable(t) ==
    LET c == s.call[t] r == c.req
        check == r.shared /\ "W" \in c.may
        sealed == s.seals \cap {"WRITE","FUTURE"} /= {}
        reject == check /\ sealed /\ "W" \in r.perms
    IN /\ c.pc = "check_writable" /\ s.vmarLock = t
       /\ (check => s.sealLock = "none")
       /\ s' = [s EXCEPT !.call[t].checked = check,
            !.call[t].observed = IF check THEN s.seals ELSE {},
            !.call[t].track = check,
            !.call[t].may = IF check /\ sealed /\ ~reject
                           THEN c.may \ {"W"} ELSE c.may,
            !.call[t].pc = IF reject THEN "vmar_unlock" ELSE "mapped_new",
            !.call[t].result = IF reject THEN "EPERM" ELSE "pending"]

\* vm_mapping.rs:944-953 and vmo/mod.rs:1199-1206.
\* The new logical wrapper denotes the reservation at the successful RMW.
MappedVmoNew(t) ==
    LET c == s.call[t] r == c.req
        reject == c.track /\ s.status < 0
        g == Len(s.birth)+1 o == Fresh
    IN /\ c.pc = "mapped_new" /\ s.vmarLock = t
       /\ IF reject
          \* vmo/mod.rs:1202-1205 returns EPERM without acquiring an owner.
          THEN s' = [s EXCEPT !.call[t].pc = "vmar_unlock",
                              !.call[t].result = "EPERM"]
          ELSE /\ Assert(Free /= {}, "owner pool exhausted")
               \* vm_mapping.rs:949-953 completes the successful reservation.
               /\ s' = [s EXCEPT
                  !.status = IF c.track THEN @+1 ELSE @,
                  !.owner[o] = [role |-> "reserved", lo |-> r.lo, hi |-> r.hi,
                    off |-> r.off, fd |-> r.fd, shared |-> r.shared,
                    perms |-> r.perms, may |-> c.may, tracked |-> c.track,
                    gens |-> [a \in Pages |-> IF a \in Span(r.lo,r.hi) THEN g ELSE 0]],
                  !.birth = Append(@,[fd |-> r.fd, shared |-> r.shared,
                    bias |-> r.off-r.lo, may |-> c.may, tracked |-> c.track,
                    checked |-> c.checked, observed |-> c.observed]),
                  !.call[t].cur = o, !.call[t].generation = g,
                  !.call[t].anchor = r.lo, !.call[t].mergeSide = "prev",
                  !.call[t].pc = "merge_check"]

\* memfd.rs:46-51. The lock remains held through deny, publication and exit.
MemfdAddSealsLock(t) ==
    /\ s.call[t].pc = "seal_lock" /\ s.sealLock = "none"
    /\ s' = [s EXCEPT !.sealLock = t, !.call[t].beforeSeals = s.seals,
                       !.call[t].pc = "seal_check"]
MemfdAddSealsCheck(t) ==
    LET c == s.call[t] IN
    /\ c.pc = "seal_check" /\ s.sealLock = t
    \* memfd.rs:49-65. An existing SEAL rejects even an empty request.
    /\ s' = [s EXCEPT
        !.call[t].pc = IF "SEAL" \in s.seals THEN "seal_unlock"
                      ELSE IF "WRITE" \in c.req.bits THEN "deny" ELSE "publish",
        !.call[t].result = IF "SEAL" \in s.seals THEN "EPERM" ELSE "pending"]

\* vmo/mod.rs:1212-1220. This is one successful or failed conditional RMW.
WritableMappingDeny(t) ==
    LET c == s.call[t] busy == s.status > 0 IN
    /\ c.pc = "deny" /\ s.sealLock = t
    /\ s' = [s EXCEPT !.status = IF busy THEN @ ELSE -1,
        !.call[t].denyCount = s.status, !.call[t].denyEligible = Cardinality(Eligible),
        !.call[t].quiescent = s.vmarLock = "none" /\
            \A u \in Threads \ {t} : s.call[u].pc = "idle",
        !.call[t].result = IF busy THEN "EBUSY" ELSE "pending",
        !.call[t].pc = IF busy THEN "seal_unlock" ELSE "publish"]

\* memfd.rs:68. Successful denial is visible before WRITE publication.
MemfdPublishSeals(t) ==
    /\ s.call[t].pc = "publish" /\ s.sealLock = t
    /\ s' = [s EXCEPT !.seals = @ \cup s.call[t].req.bits,
                       !.call[t].result = "OK", !.call[t].pc = "seal_unlock"]

\* memfd.rs:46-71. Ghost observations are taken before releasing this mutex.
MemfdAddSealsUnlock(t) ==
    LET c == s.call[t] IN
    /\ c.pc = "seal_unlock" /\ s.sealLock = t
    /\ s' = [s EXCEPT !.sealLock = "none", !.call[t].pc = "return",
        !.sealLog = Append(@,[before |-> c.beforeSeals, after |-> s.seals,
            requested |-> c.req.bits, result |-> c.result,
            count |-> c.denyCount, eligible |-> c.denyEligible,
            quiescent |-> c.quiescent])]

\* memfd.rs:73-75, fcntl.rs:219-224. No unlocked seal read is invented.
MemfdGetSeals(t) ==
    /\ s.call[t].pc = "get_seals" /\ s.sealLock = "none"
    /\ s' = [s EXCEPT !.call[t].observed = s.seals,
                       !.call[t].result = "OK", !.call[t].pc = "return"]

\* protect.rs:29-43,73-77. Preserve the snapshot's permissions and MAY bits.
VmarProtectCheck(t) ==
    LET c == s.call[t] r == c.req IN
    /\ c.pc = "protect_check" /\ s.vmarLock = t
    /\ IF c.index > Len(c.queue)
       \* protect.rs:73-80 distinguishes a trailing hole from full completion.
       THEN s' = [s EXCEPT !.call[t].pc = "vmar_unlock",
            !.call[t].result = IF c.lastEnd < r.hi THEN "ENOMEM" ELSE "OK"]
       ELSE LET q == c.queue[c.index] IN
            \* protect.rs:31-37 rejects a hole before this snapshot entry.
            IF c.lastEnd < q.lo
            THEN s' = [s EXCEPT !.call[t].pc = "vmar_unlock",
                                !.call[t].result = "ENOMEM"]
            ELSE IF r.perms = q.perms
            \* protect.rs:39-40 skips an already matching segment.
            THEN s' = [s EXCEPT !.call[t].lastEnd = q.hi,
                !.call[t].index = @+1,
                !.call[t].done = @ \cup Span(Max(r.lo,q.lo),Min(r.hi,q.hi))]
            ELSE IF ~(r.perms \subseteq q.may)
            \* protect.rs:42-43, perms.rs:35-43 check retained MAY first.
            THEN s' = [s EXCEPT !.call[t].lastEnd = q.hi,
                !.call[t].pc = "vmar_unlock", !.call[t].result = "EACCES"]
            ELSE s' = [s EXCEPT !.call[t].lastEnd = q.hi,
                                !.call[t].pc = "protect_take"]

\* protect.rs:45-58. The absent-start compensation is kept, not replaced
\* by an assertion that an earlier merge cannot consume the snapshot entry.
VmarProtectTake(t) ==
    LET c == s.call[t] r == c.req q == c.queue[c.index]
        os == AtStart(q.lo)
    IN /\ c.pc = "protect_take" /\ s.vmarLock = t
       /\ IF os = {}
          \* protect.rs:45-50 permits an entry absorbed by an earlier merge.
          THEN s' = [s EXCEPT !.call[t].index = @+1,
                    !.call[t].pc = "protect_check",
                    !.call[t].done = @ \cup Span(Max(r.lo,q.lo),Min(r.hi,q.hi))]
          ELSE LET o == One(os) m == s.owner[o] IN
               \* protect.rs:52-58 detaches before the split-range handoff.
               s' = [s EXCEPT !.tree = @ \ {o}, !.owner[o].role = "detached",
                    !.call[t].cur = o, !.call[t].partLo = Max(r.lo,m.lo),
                    !.call[t].partHi = Min(r.hi,m.hi), !.call[t].rest = <<>>,
                    !.call[t].pc = "split_left"]

\* vmar_impls/mod.rs:386-398. Fixed replacement uses this same removal loop
\* before map.rs:337-349. Counter and hardware state are unchanged by detach.
VmarRemoveNext(t) ==
    LET c == s.call[t] r == c.req IN
    /\ c.pc = "remove_next" /\ s.vmarLock = t
    /\ IF c.index > Len(c.queue)
       \* mod.rs:414 returns to map.rs:337 or unmap.rs:50 after the last piece.
       THEN s' = [s EXCEPT
          !.call[t].pc = IF r.kind = "map" THEN "check_writable" ELSE "vmar_unlock",
          !.call[t].result = IF r.kind = "map" THEN "pending" ELSE "OK"]
       ELSE LET o == One(AtStart(c.queue[c.index].lo)) m == s.owner[o] IN
            \* mod.rs:391-398 moves the next owned mapping out of the tree.
            s' = [s EXCEPT !.tree = @ \ {o}, !.owner[o].role = "detached",
                !.call[t].cur = o, !.call[t].partLo = Max(r.lo,m.lo),
                !.call[t].partHi = Min(r.hi,m.hi), !.call[t].rest = <<>>,
                !.call[t].pc = "split_left"]

\* vm_mapping.rs:766-785. The branch is separate from dup's atomic increment.
VmMappingSplitRange(t) ==
    LET c == s.call[t] m == s.owner[c.cur]
        left == c.pc = "split_left"
        needed == IF left THEN m.lo < c.partLo ELSE c.partHi < m.hi
    IN /\ c.pc \in {"split_left","split_right"} /\ s.vmarLock = t
       /\ s' = [s EXCEPT !.call[t].side = IF left THEN "left" ELSE "right",
            !.call[t].cut = IF left THEN c.partLo ELSE c.partHi,
            !.call[t].pc = IF needed THEN "split_dup"
                         ELSE IF left THEN "split_right" ELSE "put_rest"]

\* vm_mapping.rs:732,1026-1035, vmo/mod.rs:1227-1228. Increment precedes
\* transfer. The parent and temporary wrapper coexist at this boundary.
MappedVmoDupAtOffset(t) ==
    LET c == s.call[t] m == s.owner[c.cur] o == Fresh IN
    /\ c.pc = "split_dup" /\ s.vmarLock = t
    /\ Assert(Free /= {}, "owner pool exhausted")
    /\ s' = [s EXCEPT !.owner[o] = [Slice(m,c.cut,m.hi) EXCEPT !.role = "split"],
        !.status = IF m.tracked THEN @+1 ELSE @,
        !.call[t].tmp = o, !.call[t].pc = "split_commit"]

\* vm_mapping.rs:733-747. Moving the left owner performs no decrement.
VmMappingSplit(t) ==
    LET c == s.call[t] IN
    /\ c.pc = "split_commit" /\ s.vmarLock = t
    /\ s' = [s EXCEPT !.owner[c.cur].hi = c.cut,
        !.owner[c.tmp].role = "detached", !.call[t].tmp = 0,
        !.call[t].rest = Append(@,IF c.side = "left" THEN c.cur ELSE c.tmp),
        !.call[t].cur = IF c.side = "left" THEN c.tmp ELSE c.cur,
        !.call[t].pc = IF c.side = "left" THEN "split_right" ELSE "put_rest"]

\* protect.rs:60-66 and vmar_impls/mod.rs:399-409. Left then right are
\* inserted without merging. The taken object stays owned outside the tree.
VmarInsertRest(t) ==
    LET c == s.call[t] IN
    /\ c.pc = "put_rest" /\ s.vmarLock = t
    /\ IF c.rest = <<>>
       \* protect.rs:68-70 or mod.rs:411 consumes the remaining taken object.
       THEN s' = [s EXCEPT !.call[t].touched = {},
           !.call[t].pc = IF c.req.kind = "protect" THEN "protect_pt" ELSE "unmap_pt"]
       ELSE LET o == Head(c.rest) IN
            \* protect.rs:60-66 and mod.rs:399-404 reinsert without merging.
            s' = [s EXCEPT !.tree = @ \cup {o}, !.owner[o].role = "tree",
                           !.call[t].rest = Tail(@)]

\* vm_mapping.rs:830-837, vm_space.rs:472-535. PTE removal does not
\* release the eligibility owner or promise remote translation revocation.
CursorUnmap(t) ==
    LET c == s.call[t] remaining == Range(s.owner[c.cur]) \ c.touched IN
    /\ c.pc = "unmap_pt" /\ s.vmarLock = t
    /\ IF remaining = {}
       THEN s' = [s EXCEPT !.call[t].pc = "dispatch"]
       ELSE LET a == CHOOSE a \in remaining : \A b \in remaining : a <= b IN
            s' = [s EXCEPT !.pt[a] = NoTranslation, !.call[t].touched = @ \cup {a}]

\* vm_mapping.rs:843-875. A VMO-backed protect never installs PTE WRITE.
\* A later ordinary shared-write fault can enable it within retained MAY.
CursorProtect(t) ==
    LET c == s.call[t] remaining == Range(s.owner[c.cur]) \ c.touched IN
    /\ c.pc = "protect_pt" /\ s.vmarLock = t
    /\ IF remaining = {}
       THEN s' = [s EXCEPT !.call[t].pc = "dispatch"]
       ELSE LET a == CHOOSE a \in remaining : \A b \in remaining : a <= b IN
            s' = [s EXCEPT !.pt[a].perms =
                    IF s.pt[a].gen = 0 THEN {} ELSE c.req.perms \ {"W"},
                 !.call[t].touched = @ \cup {a}]

\* vm_mapping.rs:836,872; tlb.rs:76-117. One representative remote cache
\* retains old access until completion. Ordinary flush machinery is assumed.
DispatchTlbFlush(t) ==
    /\ s.call[t].pc = "dispatch" /\ s.vmarLock = t
    /\ s' = [s EXCEPT !.call[t].pc = "sync"]
\* tlb.rs:119-150; smp.rs:77-93,163-175. This enabled completion is not
\* a fairness assertion and does not prove the underlying IPI implementation.
SyncTlbFlush(t) ==
    /\ s.call[t].pc = "sync" /\ s.vmarLock = t
    /\ s' = [s EXCEPT !.tlb = [a \in Pages |->
                    IF a \in s.call[t].touched THEN NoTranslation ELSE s.tlb[a]],
        !.call[t].pc = IF s.call[t].req.kind = "protect" THEN "protect_finish" ELSE "unmap_drop"]

\* vm_mapping.rs:875, protect.rs:69-70. Metadata changes after completion.
VmMappingProtect(t) ==
    LET c == s.call[t] IN
    /\ c.pc = "protect_finish" /\ s.vmarLock = t
    /\ s' = [s EXCEPT !.owner[c.cur].perms = c.req.perms,
        !.call[t].done = @ \cup Range(s.owner[c.cur]),
        !.call[t].anchor = s.owner[c.cur].lo,
        !.call[t].mergeSide = "prev", !.call[t].pc = "merge_check"]

\* vm_mapping.rs:839-840,1039-1043. Drop consumes one tracked wrapper
\* only after the ordinary unmap's sync. Retired generations are ghost data.
MappedVmoDropUnmapped(t) ==
    LET c == s.call[t] m == s.owner[c.cur] IN
    /\ c.pc = "unmap_drop" /\ s.vmarLock = t
    /\ s' = [s EXCEPT !.status = IF m.tracked THEN @-1 ELSE @,
        !.releaseSafe = @ /\ \A a \in Range(m) :
            s.pt[a].gen /= m.gens[a] /\ s.tlb[a].gen /= m.gens[a],
        !.retired = @ \cup {[addr |-> a, gen |-> m.gens[a]] : a \in Range(m)},
        !.owner[c.cur] = NoOwner, !.call[t].cur = 0,
        !.call[t].index = @+1, !.call[t].pc = "remove_next"]

\* vmar_impls/mod.rs:292-311. Predecessor and successor are tested once,
\* using the original insertion address, including after a predecessor merge.
VmarTryMerge(t) ==
    LET c == s.call[t] n == Neighbor(c) IN
    /\ c.pc = "merge_check" /\ s.vmarLock = t
    /\ s' = [s EXCEPT !.call[t].neighbor = n,
        !.call[t].pc = IF CanMerge(c,n) THEN "merge_dup"
                      ELSE IF c.mergeSide = "prev" THEN "merge_check" ELSE "insert",
        !.call[t].mergeSide = IF CanMerge(c,n) THEN c.mergeSide ELSE "next"]

\* vm_mapping.rs:1056-1102. try_merge duplicates the LEFT wrapper before
\* dropping self or the neighbor. The tracked flag is copied, not repaired.
MappedVmoDupForMerge(t) ==
    LET c == s.call[t] x == s.owner[c.cur] y == s.owner[c.neighbor]
        left == IF x.lo < y.lo THEN x ELSE y
        right == IF x.lo < y.lo THEN y ELSE x o == Fresh
    IN /\ c.pc = "merge_dup" /\ s.vmarLock = t
       /\ Assert(Free /= {}, "owner pool exhausted")
       /\ s' = [s EXCEPT !.owner[o] = Merged(left,right),
            !.status = IF left.tracked THEN @+1 ELSE @,
            !.call[t].tmp = o, !.call[t].pc = "merge_drop_self"]

\* vm_mapping.rs:808-821,1039-1043. Returning the new object drops self.
MappedVmoDropMergeSelf(t) ==
    LET c == s.call[t] IN
    /\ c.pc = "merge_drop_self" /\ s.vmarLock = t
    /\ s' = [s EXCEPT !.status = IF s.owner[c.cur].tracked THEN @-1 ELSE @,
        !.owner[c.cur] = NoOwner, !.call[t].cur = c.tmp,
        !.call[t].tmp = 0, !.call[t].pc = "merge_drop_neighbor"]
\* vmar_impls/mod.rs:295-310; vm_mapping.rs:1039-1043.
MappedVmoDropMergeNeighbor(t) ==
    LET c == s.call[t] IN
    /\ c.pc = "merge_drop_neighbor" /\ s.vmarLock = t
    /\ s' = [s EXCEPT !.status = IF s.owner[c.neighbor].tracked THEN @-1 ELSE @,
        !.tree = @ \ {c.neighbor}, !.owner[c.neighbor] = NoOwner,
        !.call[t].neighbor = 0,
        !.call[t].pc = IF c.mergeSide = "prev" THEN "merge_check" ELSE "insert",
        !.call[t].mergeSide = "next"]

\* vmar_impls/mod.rs:314-324. Publication follows all temporary-owner drops.
VmarInsertMapping(t) ==
    LET c == s.call[t] IN
    /\ c.pc = "insert" /\ s.vmarLock = t
    /\ s' = [s EXCEPT !.tree = @ \cup {c.cur}, !.owner[c.cur].role = "tree",
        !.call[t].cur = 0, !.call[t].index = @+1,
        !.call[t].result = IF c.req.kind = "map" THEN "OK" ELSE "pending",
        !.call[t].pc = IF c.req.kind = "map" THEN "vmar_unlock" ELSE "protect_check"]

\* map.rs:404, protect.rs:31-80, unmap.rs:48-51. Observe effects while the
\* VMAR is still locked. A delayed syscall return cannot reclassify admission.
VmarUnlock(t) ==
    LET c == s.call[t] IN
    /\ c.pc = "vmar_unlock" /\ s.vmarLock = t
    /\ s' = [s EXCEPT !.vmarLock = "none", !.call[t].pc = "return",
        !.mapLog = IF c.req.kind = "map" THEN Append(@,
            [req |-> c.req, before |-> c.before, after |-> Snapshot,
             beforeSeals |-> c.beforeSeals, observed |-> c.observed,
             checked |-> c.checked, may |-> c.may, result |-> c.result]) ELSE @,
        !.protectLog = IF c.req.kind = "protect" THEN Append(@,
            [req |-> c.req, before |-> c.before, after |-> Snapshot,
             done |-> c.done, result |-> c.result]) ELSE @]

\* vmar_impls/page_fault.rs:9-23, vm_mapping.rs:374-427,450-457.
\* Ordinary shared WRITE faults are one read-locked abstraction: no VMAR
\* writer can interleave. Read fault-around, private faults/COW and physical
\* frame contents are excluded. The page-cache commit substrate is assumed.
HandlePageFault(t) ==
    LET c == s.call[t] a == c.req.lo os == At(a) IN
    /\ c.pc = "fault" /\ s.vmarLock = "none"
    /\ IF os = {}
       \* vmar_impls/page_fault.rs:20-23 rejects an unmapped address.
       THEN s' = [s EXCEPT !.call[t].pc = "return", !.call[t].result = "EACCES"]
       ELSE LET m == s.owner[One(os)] allowed == c.req.perms \subseteq m.perms
                flags == IF s.pt[a].gen = 0 THEN m.perms
                         ELSE s.pt[a].perms \cup {"W"}
            IN
            \* vm_mapping.rs:450-457 checks current permissions, not seals.
            /\ m.shared
            /\ s' = [s EXCEPT !.call[t].pc = "return",
                !.call[t].result = IF allowed THEN "OK" ELSE "EACCES",
                \* vm_mapping.rs:474-482,506-526,536-568.
                !.pt[a] = IF allowed THEN [gen |-> m.gens[a], perms |-> flags] ELSE @,
                !.tlb[a] = IF allowed THEN [gen |-> m.gens[a], perms |-> flags] ELSE @]

\* syscall/mmap.rs:36, fcntl.rs:216,224, mprotect.rs:55, munmap.rs:26.
SyscallReturn(t) ==
    /\ s.call[t].pc = "return"
    /\ s' = [s EXCEPT !.call[t].pc = "idle"]

InternalStep(t) ==
    \/ MmapFdMode(t) \/ VmarLock(t) \/ MemfdCheckWritable(t) \/ MappedVmoNew(t)
    \/ MemfdAddSealsLock(t) \/ MemfdAddSealsCheck(t) \/ WritableMappingDeny(t)
    \/ MemfdPublishSeals(t) \/ MemfdAddSealsUnlock(t) \/ MemfdGetSeals(t)
    \/ VmarProtectCheck(t) \/ VmarProtectTake(t) \/ VmarRemoveNext(t)
    \/ VmMappingSplitRange(t) \/ MappedVmoDupAtOffset(t) \/ VmMappingSplit(t)
    \/ VmarInsertRest(t) \/ CursorUnmap(t) \/ CursorProtect(t)
    \/ DispatchTlbFlush(t) \/ SyncTlbFlush(t) \/ VmMappingProtect(t)
    \/ MappedVmoDropUnmapped(t) \/ VmarTryMerge(t) \/ MappedVmoDupForMerge(t)
    \/ MappedVmoDropMergeSelf(t) \/ MappedVmoDropMergeNeighbor(t)
    \/ VmarInsertMapping(t) \/ VmarUnlock(t) \/ HandlePageFault(t)
    \/ SyscallReturn(t)
Next == \E t \in Threads :
    InternalStep(t) \/ (\E r \in Requests : SyscallEnter(t,r))
Spec == Init /\ [][Next]_vars

\* Structural safety, brief section 5. The birth record is immutable and
\* follows an admitted page through owner moves, splits, merges and remaps.
TypeAndIdentity ==
    /\ s.seals \subseteq SealBits /\ s.status \in {-1} \cup Nat
    /\ s.sealLock \in Threads \cup {"none"} /\ s.vmarLock \in Threads \cup {"none"}
    /\ DOMAIN s.call = Threads /\ DOMAIN s.owner = OwnerIds
    /\ s.tree \subseteq Live
    /\ Live = s.tree \cup CallOwned
    /\ \A o \in s.tree : s.owner[o].role = "tree"
    /\ \A o,p \in s.tree : o /= p => Range(s.owner[o]) \cap Range(s.owner[p]) = {}
    /\ \A o \in Live : LET m == s.owner[o] IN
        /\ 0 <= m.lo /\ m.lo < m.hi /\ m.hi <= NumPages
        /\ 0 <= m.off /\ m.off + m.hi - m.lo <= NumPages
        /\ m.fd \in Files /\ m.shared \in BOOLEAN /\ m.tracked \in BOOLEAN
        /\ m.perms \subseteq m.may /\ m.may \subseteq Perms
        /\ \A a \in Range(m) :
            /\ m.gens[a] \in 1..Len(s.birth)
            /\ LET b == s.birth[m.gens[a]] IN
               /\ m.fd = b.fd /\ m.shared = b.shared /\ m.may = b.may
               /\ m.tracked = b.tracked /\ m.off + a - m.lo = b.bias + a
TrackedOwnershipConservation ==
    IF s.status = -1 THEN Tracked = {} ELSE s.status = Cardinality(Tracked)

\* memfd.rs:49-68. No inverse implication from denied to published WRITE.
SealPublicationAndFreeze ==
    /\ ("WRITE" \in s.seals => s.status = -1)
    /\ \A i \in 1..Len(s.sealLog) : LET e == s.sealLog[i] IN
        /\ e.before \subseteq e.after
        /\ ("SEAL" \in e.before => e.result = "EPERM" /\ e.after = e.before)
        /\ (e.result = "EBUSY" => e.after = e.before /\ "WRITE" \in e.requested)
        /\ (e.result = "OK" => e.after = e.before \cup e.requested)

\* Brief section 5 and memfd.rs:80-89, protect.rs:39-43. Admission history,
\* not return time, decides whether FUTURE permits a later WRITE upgrade.
RetainedWriteEligibility ==
    /\ \A o \in Live : s.owner[o].perms \subseteq s.owner[o].may
    /\ \A g \in 1..Len(s.birth) : LET b == s.birth[g] IN
        /\ (b.shared /\ b.checked /\ b.observed \cap {"WRITE","FUTURE"} /= {}
            => "W" \notin b.may)
        /\ (b.shared /\ WritableFile(b.fd) /\ b.observed \cap {"WRITE","FUTURE"} = {}
            => "W" \in b.may)
    /\ \A o \in Live : \A a \in Range(s.owner[o]) :
        s.owner[o].may = s.birth[s.owner[o].gens[a]].may

\* NO-STALE-ACCESS and completion-before-drop, qualified to tracked shared
\* owners. One abstract remote translation conservatively retains old access.
RevocationBeforeOwnerRelease ==
    /\ s.releaseSafe
    /\ \A e \in s.retired :
        s.pt[e.addr].gen /= e.gen /\ s.tlb[e.addr].gen /= e.gen
    /\ \A a \in Pages : \A tr \in {s.pt[a],s.tlb[a]} :
        tr.gen /= 0 =>
          /\ tr.gen \in 1..Len(s.birth)
          /\ \E o \in Live : a \in Range(s.owner[o]) /\ s.owner[o].gens[a] = tr.gen
          /\ (s.birth[tr.gen].shared /\ "W" \in tr.perms =>
                "W" \in s.birth[tr.gen].may /\ "WRITE" \notin s.seals)

\* Linux v6.18 mm/memfd.c:373-407 and mm/vma.c:2731-2744.
\* These outcome predicates intentionally expose TV-1, never guard admission.
ReadOnlyAdmissionAfterWrite ==
    \A i \in 1..Len(s.mapLog) : LET e == s.mapLog[i] IN
        e.req.shared /\ e.checked /\ "W" \notin e.req.perms /\
        "WRITE" \in e.observed => e.result = "OK" /\ "W" \notin e.may
ReadOnlyAdmissionNoFalseBusy ==
    \A i \in 1..Len(s.sealLog) : LET e == s.sealLog[i] IN
        e.quiescent /\ e.eligible = 0 /\ "SEAL" \notin e.before /\
        "WRITE" \in e.requested => e.result /= "EBUSY"
ReadOnlyAdmissionCompatibility ==
    ReadOnlyAdmissionAfterWrite /\ ReadOnlyAdmissionNoFalseBusy

\* Linux v6.18 mm/mmap.c:485-491, before replacement. Restrict the oracle
\* to an already active write seal and the specified shared WRITE conflict.
SealRejectedReplacement ==
    \A i \in 1..Len(s.mapLog) : LET e == s.mapLog[i] IN
        e.req.fixed /\ e.req.shared /\ "W" \in e.req.perms /\
        e.beforeSeals \cap {"WRITE","FUTURE"} /= {} =>
            e.result = "EPERM" /\ e.after = e.before

\* protect.rs:21-77 and Linux v6.18 mm/mprotect.c:931-1005. Completed
\* prefix effects survive failure. Representation changes do not alter this
\* per-page observation, which also checks offsets, generations and MAY bits.
ProtectionPrefixEffects ==
    \A i \in 1..Len(s.protectLog) : LET e == s.protectLog[i] IN
        /\ e.done \subseteq Span(e.req.lo,e.req.hi)
        /\ \A a \in e.done : \A b \in Span(e.req.lo,a) : b \in e.done
        /\ (e.result = "OK" => e.done = Span(e.req.lo,e.req.hi))
        /\ \A a \in Pages :
            IF a \in e.done
            THEN /\ e.before[a].gen /= 0 /\ e.req.perms \subseteq e.before[a].may
                 /\ e.after[a] = [e.before[a] EXCEPT !.perms = e.req.perms]
            ELSE e.after[a] = e.before[a]
=============================================================================
