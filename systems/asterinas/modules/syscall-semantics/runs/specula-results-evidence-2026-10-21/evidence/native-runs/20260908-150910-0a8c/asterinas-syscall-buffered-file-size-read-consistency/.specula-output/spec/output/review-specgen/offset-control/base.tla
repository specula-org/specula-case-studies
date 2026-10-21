------------------------------ MODULE base ------------------------------
EXTENDS Integers, Sequences, FiniteSets, TLC

\* Category B. Source: 604948581512d83734377974d4c34adb4530f2d7.
\* S1: sampled EOF / cursor progress. S2: exFAT prepare / publish gap.
\* S3: logical bytes / allocation / cold pages. S4: copy acceptance.
\* Source paths below are relative to source/. No durability or VM mappings.
CONSTANTS Backend, Threads, P, G, MaxByte, InitialSize, InitialWarm,
          InitialPosition

Min(a, b) == IF a < b THEN a ELSE b
Max(a, b) == IF a > b THEN a ELSE b
Sub(a, b) == Max(0, a - b)
Round(n, unit) == ((n + unit - 1) \div unit) * unit
Bytes == 0..(MaxByte - 1)
Pages == 0..((MaxByte \div P) - 1)
NoThread == "-"
ReadKinds == {"read", "pread64"}
MutKinds == {"pwrite64", "ftruncate"}
Kinds == ReadKinds \cup MutKinds
PageStates == {"Absent", "Uninit", "Clean", "Dirty"}
Values == {"zero", "seed", "sentinel", "uninit"} \cup Threads
Blank == [i \in 1..MaxByte |-> "sentinel"]

ASSUME /\ Backend \in {"ramfs", "ext2", "exfat"}
       /\ P > 0 /\ G > 0 /\ G % P = 0
       /\ MaxByte >= P /\ MaxByte % G = 0 /\ MaxByte \div P <= 32
       /\ InitialSize \in 0..MaxByte
       /\ InitialPosition \in 0..MaxByte
       /\ InitialWarm \subseteq {j \in Pages : j * P < InitialSize}
       /\ (Backend = "ramfs" => InitialWarm = {j \in Pages : j * P < InitialSize})
       /\ Threads /= {} /\ NoThread \notin Threads

VARIABLES f, mu, q, h, position
vars == <<f, mu, q, h, position>>

\* S1/S2: the mutex and RwMutex are different objects/protocols.
\* ramfs/fs.rs:703-709,731-750,796-814; ostd/src/sync/rwmutex.rs:159-197.
FreeInode == mu.writer = NoThread /\ mu.up = NoThread /\ mu.readers = {}
Active == {t \in Threads : q[t].pc \notin {"Idle", "Done"}}
Mutators == {t \in Active : q[t].kind \in MutKinds}
Quiescent == Mutators = {}
Initialized(x, j) == x.pages[j + 1] \in {"Clean", "Dirty"}

\* S3: absence does not imply zeros for exFAT after EOF publication.
\* ramfs anonymous: vmo/mod.rs:309-322; ext2/block_manager/mod.rs:141-154;
\* exfat/inode.rs:151-167. This observer does not populate a real page.
ReadableByte(x, i) ==
    LET j == i \div P IN
    IF i >= x.C THEN "Unreachable"
    ELSE IF Initialized(x, j) THEN x.data[i + 1]
    ELSE CASE Backend = "ramfs" -> "zero"
           [] Backend = "ext2" ->
                IF j >= x.npages THEN "Invalid"
                ELSE IF j \in x.blocks THEN x.disk[i + 1] ELSE "zero"
           [] OTHER ->
                IF j * P >= x.A THEN "Invalid"
                ELSE IF j * P >= x.L THEN "zero" ELSE x.disk[i + 1]
FileView(x) == [i \in 1..x.L |-> ReadableByte(x, i - 1)]

\* S1-S4: per-call state, never inferred from returned count.
\* inode_handle.rs:285-288,323-353; ramfs/fs.rs:703-710;
\* exfat/inode.rs:720-743; ostd/src/mm/io/mod.rs:339-360.
IdleLocal ==
    [pc |-> "Idle", kind |-> "read", O |-> 0, N |-> 0, target |-> 0,
     fault |-> 0, S |-> 0, K |-> 0, copyO |-> 0, candidate |-> 0,
     oldL |-> 0, oldView |-> <<>>, solo |-> TRUE,
     startPosition |-> 0, D |-> 0, accepted |-> {}, out |-> Blank,
     status |-> "Pending", errorSite |-> "none", result |-> -1,
     ioKind |-> "Read", ioOff |-> 0, ioLen |-> 0, ioDone |-> 0,
     ioEnd |-> 0, page |-> 0, afterIo |-> "BackendReturn",
     segmentEnd |-> 0, collectNext |-> 0, collectEnd |-> 0, overwrite |-> FALSE,
     resizeOld |-> 0, resizeNew |-> 0, resizePurpose |-> "resize",
     afterResize |-> "BackendReturn", reference |-> Blank,
     referenceSize |-> 0, referenceValid |-> FALSE]

\* Fixture: existing subject bytes are "seed". Reallocation reuses these
\* same subject clusters (S3/TV3); allocation never invents random bytes.
\* exfat/fat.rs:200-248,292-342; vmo/mod.rs:309-322,1040-1051.
Init ==
    /\ f = [L |-> InitialSize, C |-> Round(InitialSize, P),
             A |-> IF Backend = "exfat" THEN InitialSize ELSE 0,
             clusters |-> IF Backend = "exfat"
                         THEN Round(InitialSize, G) \div G ELSE 0,
             npages |-> IF Backend = "ext2"
                       THEN Round(InitialSize, P) \div P ELSE 0,
             blocks |-> IF Backend = "ext2"
                       THEN {j \in Pages : j * P < InitialSize} ELSE {},
             pages |-> [i \in 1..(MaxByte \div P) |->
                        IF i - 1 \in InitialWarm THEN "Clean" ELSE "Absent"],
             data |-> [i \in 1..MaxByte |->
                       IF (i - 1) \div P \in InitialWarm
                       THEN IF i <= InitialSize THEN "seed" ELSE "zero"
                       ELSE "uninit"],
             disk |-> [i \in 1..MaxByte |-> IF i <= InitialSize THEN "seed" ELSE "zero"]]
    /\ mu = [cache |-> NoThread, writer |-> NoThread, up |-> NoThread,
              readers |-> {}, offset |-> NoThread]
    /\ q = [t \in Threads |-> IdleLocal]
    /\ h = [completed |-> {}, writes |-> {}, everTruncated |-> FALSE,
             reference |-> [i \in 1..MaxByte |-> IF i <= InitialSize THEN "seed" ELSE "zero"],
             referenceSize |-> InitialSize, referenceValid |-> TRUE]
    /\ position = InitialPosition

\* Environment inputs only. Stable inaccessible suffix is fixed at entry.
\* syscall/{read.rs:27-44,pread64.rs:33-43,pwrite64.rs:33-41,truncate.rs:15-28}.
InputOK(k, o, n, z, b) ==
    /\ k \in Kinds /\ o \in 0..MaxByte /\ n \in 0..MaxByte
    /\ z \in 0..MaxByte /\ b \in 0..n
    /\ (k = "pwrite64" => o + n <= MaxByte)

\* Offset acquisition is part of entry for read only; positional calls
\* do not acquire it. inode_handle.rs:285-290,323-353,387-401.
SyscallEnter(t, k, o, n, z, b) ==
    /\ q[t].pc \in {"Idle", "Done"}
    /\ InputOK(k, o, n, z, b)
    /\ (k = "read" => mu.offset = NoThread /\ position <= MaxByte)
    /\ q' = [u \in Threads |->
          IF u = t THEN [IdleLocal EXCEPT
              !.pc = "Dispatch", !.kind = k,
              !.O = IF k = "read" THEN position ELSE o,
              !.N = n, !.target = z, !.fault = b,
              !.oldL = f.L, !.oldView = FileView(f), !.solo = Quiescent,
              !.startPosition = position, !.reference = h.reference,
              !.referenceSize = h.referenceSize,
              !.referenceValid = h.referenceValid /\ Quiescent]
          ELSE IF k \in MutKinds /\ u \in Active
               THEN [q[u] EXCEPT !.solo = FALSE] ELSE q[u]]
    /\ mu' = [mu EXCEPT !.offset = IF k = "read" THEN t ELSE @]
    \* Observer invalidation records overlap; it never guards a backend step.
    \* Brief S3; file effects occur later at cited backend publication steps.
    /\ h' = [h EXCEPT
               !.everTruncated = @ \/ k = "ftruncate",
               !.referenceValid = @ /\ ~(k \in MutKinds /\ ~Quiescent)]
    /\ UNCHANGED <<f, position>>

\* ramfs/fs.rs:703-708,784-785: metadata guard ends before cache lock.
RamfsReadAtObserve(t) ==
    /\ Backend = "ramfs" /\ q[t].pc = "Dispatch" /\ q[t].kind \in ReadKinds
    /\ q' = [q EXCEPT ![t].S = f.L, ![t].copyO = Min(f.L, q[t].O),
              ![t].K = Min(f.L, q[t].O + q[t].N) - Min(f.L, q[t].O),
              ![t].pc = "RamReadCache"]
    /\ UNCHANGED <<f, mu, h, position>>

\* ramfs/fs.rs:709: copy uses the un-limited original writer.
RamfsReadAtAcquireCache(t) ==
    /\ Backend = "ramfs" /\ q[t].pc = "RamReadCache" /\ mu.cache = NoThread
    /\ mu' = [mu EXCEPT !.cache = t]
    /\ q' = [q EXCEPT ![t].pc = "VmoBegin", ![t].ioKind = "Read",
              ![t].ioOff = q[t].copyO, ![t].ioLen = q[t].N]
    /\ UNCHANGED <<f, h, position>>

\* ext2/inode/file.rs:27-28: zero request bypasses even inode locking.
Ext2ReadAtEmpty(t) ==
    /\ Backend = "ext2" /\ q[t].pc = "Dispatch" /\ q[t].kind \in ReadKinds
    /\ q[t].N = 0
    /\ q' = [q EXCEPT ![t].pc = "BackendReturn"]
    /\ UNCHANGED <<f, mu, h, position>>

\* ext2/inode/file.rs:31,229-242: EOF under R bypasses copying.
Ext2ReadAt(t) ==
    /\ Backend = "ext2" /\ q[t].pc = "Dispatch" /\ q[t].kind \in ReadKinds
    /\ q[t].N > 0 /\ mu.writer = NoThread
    /\ LET k == Min(q[t].N, Sub(f.L, q[t].O)) IN
       /\ q' = [q EXCEPT ![t].S = f.L, ![t].K = k, ![t].copyO = q[t].O,
                 ![t].pc = IF k = 0 THEN "BackendReturn" ELSE "VmoBegin",
                 ![t].ioKind = "Read", ![t].ioOff = q[t].O, ![t].ioLen = k]
       /\ mu' = [mu EXCEPT !.readers = @ \cup {t}]
    /\ UNCHANGED <<f, h, position>>

\* exfat/inode.rs:643-654: unique upreader spans snapshot and copy.
ExfatReadAt(t) ==
    /\ Backend = "exfat" /\ q[t].pc = "Dispatch" /\ q[t].kind \in ReadKinds
    /\ mu.writer = NoThread /\ mu.up = NoThread
    /\ mu' = [mu EXCEPT !.up = t]
    /\ q' = [q EXCEPT ![t].S = f.L, ![t].copyO = Min(f.L, q[t].O),
              ![t].K = Min(f.L, q[t].O + q[t].N) - Min(f.L, q[t].O),
              ![t].pc = "VmoBegin", ![t].ioKind = "Read",
              ![t].ioOff = Min(f.L, q[t].O), ![t].ioLen = q[t].N]
    /\ UNCHANGED <<f, h, position>>

\* ramfs/fs.rs:731: metadata readers can run after this cache acquisition.
RamfsWriteAtAcquireCache(t) ==
    /\ Backend = "ramfs" /\ q[t].pc = "Dispatch" /\ q[t].kind = "pwrite64"
    /\ mu.cache = NoThread
    /\ mu' = [mu EXCEPT !.cache = t]
    /\ q' = [q EXCEPT ![t].pc = "RamWriteMetadata"]
    /\ UNCHANGED <<f, h, position>>

\* ramfs/fs.rs:733-750: cache is held; metadata publication precedes growth.
RamfsWriteAtPublish(t) ==
    /\ Backend = "ramfs" /\ q[t].pc = "RamWriteMetadata" /\ mu.cache = t
    /\ LET e == q[t].O + q[t].N IN
       /\ f' = [f EXCEPT !.L = Max(@, e)]
       /\ q' = [q EXCEPT ![t].S = f.L, ![t].candidate = e,
                 ![t].pc = IF e > f.L THEN "ResizeBegin" ELSE "WriteCopyStart",
                 ![t].resizeOld = f.L, ![t].resizeNew = Round(e, P),
                 ![t].resizePurpose = "write", ![t].afterResize = "WriteCopyStart"]
    /\ UNCHANGED <<mu, h, position>>

\* ext2/inode/file.rs:44-51,247-257: empty write returns before preparation.
Ext2WriteAtEmpty(t) ==
    /\ Backend = "ext2" /\ q[t].pc = "Dispatch" /\ q[t].kind = "pwrite64"
    /\ q[t].N = 0
    /\ q' = [q EXCEPT ![t].pc = "BackendReturn"]
    /\ UNCHANGED <<f, mu, h, position>>

\* ext2/inode/file.rs:50,252-257: write guard stabilizes the saved size.
Ext2WriteAtPrepare(t) ==
    /\ Backend = "ext2" /\ q[t].pc = "Dispatch" /\ q[t].kind = "pwrite64"
    /\ q[t].N > 0 /\ FreeInode
    /\ LET e == q[t].O + q[t].N IN
       /\ mu' = [mu EXCEPT !.writer = t]
       /\ q' = [q EXCEPT ![t].S = f.L, ![t].candidate = e,
                 ![t].pc = IF e > f.L THEN "ResizeBegin" ELSE "Ext2Allocate",
                 ![t].resizeOld = f.L, ![t].resizeNew = e,
                 ![t].resizePurpose = "write", ![t].afterResize = "Ext2Allocate"]
    /\ UNCHANGED <<f, h, position>>

\* ext2/inode/file.rs:200,432-437; inode/block_manager/block_ptr_tree.rs:678-691.
\* Only successful allocation is admitted; exhaustion/device errors are excluded.
Ext2AllocateRangeBlocks(t) ==
    /\ Backend = "ext2" /\ q[t].pc = "Ext2Allocate" /\ mu.writer = t
    /\ LET bs == {j \in Pages : j * P < q[t].candidate /\ (j + 1) * P > q[t].O}
           fresh == bs \ f.blocks IN
       /\ f' = [f EXCEPT !.blocks = @ \cup bs,
                 !.disk = [i \in 1..MaxByte |->
                            IF (i - 1) \div P \in fresh THEN "zero" ELSE f.disk[i]]]
       /\ q' = [q EXCEPT ![t].pc = "WriteCopyStart"]
    /\ UNCHANGED <<mu, h, position>>

\* exfat/inode.rs:715-732: save max(end, observed L) under write guard.
ExfatWriteAtPrepare(t) ==
    /\ Backend = "exfat" /\ q[t].pc = "Dispatch" /\ q[t].kind = "pwrite64"
    /\ FreeInode
    /\ LET e == q[t].O + q[t].N IN
       /\ mu' = [mu EXCEPT !.writer = t]
       /\ q' = [q EXCEPT ![t].S = f.L, ![t].candidate = Max(e, f.L),
                 ![t].pc = IF e > f.L
                           THEN IF e > f.A THEN "ExfatAllocate" ELSE "ResizeBegin"
                           ELSE "ExfatReleasePreparation",
                 ![t].resizeOld = f.L, ![t].resizeNew = e,
                 ![t].resizePurpose = "write",
                 ![t].afterResize = "ExfatReleasePreparation"]
    /\ UNCHANGED <<f, h, position>>

\* exfat/inode.rs:286-312,726-729: allocation bound is NOT rounded capacity.
ExfatResizeAllocation(t) ==
    /\ Backend = "exfat" /\ q[t].pc = "ExfatAllocate" /\ mu.writer = t
    /\ LET n == q[t].resizeNew
           nc == Round(n, G) \div G IN
       /\ f' = [f EXCEPT !.A = n, !.clusters = nc,
                 !.L = IF nc < f.clusters /\ n < f.L THEN n ELSE @]
       /\ q' = [q EXCEPT ![t].pc = IF q[t].kind = "pwrite64"
                                           THEN "ResizeBegin" ELSE "BackendReturn"]
    /\ UNCHANGED <<mu, h, position>>

\* exfat/inode.rs:732-735: this release is the S2 interleaving window.
ExfatWriteAtReleasePreparation(t) ==
    /\ Backend = "exfat" /\ q[t].pc = "ExfatReleasePreparation" /\ mu.writer = t
    /\ mu' = [mu EXCEPT !.writer = NoThread]
    /\ q' = [q EXCEPT ![t].pc = "ExfatAcquireCopy"]
    /\ UNCHANGED <<f, h, position>>

\* exfat/inode.rs:735-736; rwmutex.rs:187-197: copies do not share upread.
ExfatWriteAtAcquireCopy(t) ==
    /\ Backend = "exfat" /\ q[t].pc = "ExfatAcquireCopy"
    /\ mu.writer = NoThread /\ mu.up = NoThread
    /\ mu' = [mu EXCEPT !.up = t]
    /\ q' = [q EXCEPT ![t].pc = "WriteCopyStart"]
    /\ UNCHANGED <<f, h, position>>

\* ramfs/fs.rs:796: separate metadata readers do not acquire this mutex.
RamfsResizeAcquireCache(t) ==
    /\ Backend = "ramfs" /\ q[t].pc = "Dispatch" /\ q[t].kind = "ftruncate"
    /\ mu.cache = NoThread
    /\ mu' = [mu EXCEPT !.cache = t]
    /\ q' = [q EXCEPT ![t].pc = "RamResizeMetadata"]
    /\ UNCHANGED <<f, h, position>>

\* ramfs/fs.rs:798-813: extension publishes L first, shrink publishes last.
RamfsResize(t) ==
    /\ Backend = "ramfs" /\ q[t].pc = "RamResizeMetadata" /\ mu.cache = t
    /\ f' = [f EXCEPT !.L = IF q[t].target > f.L THEN q[t].target ELSE @]
    /\ q' = [q EXCEPT ![t].S = f.L, ![t].resizeOld = f.L,
              ![t].resizeNew = q[t].target, ![t].resizePurpose = "resize",
              ![t].pc = IF q[t].target = f.L THEN "BackendReturn" ELSE "ResizeBegin",
              ![t].afterResize = IF q[t].target < f.L
                                THEN "RamResizePublish" ELSE "BackendReturn"]
    /\ UNCHANGED <<mu, h, position>>

\* ramfs/fs.rs:813: metadata lock reacquired while cache remains held.
RamfsResizePublish(t) ==
    /\ q[t].pc = "RamResizePublish" /\ Backend = "ramfs" /\ mu.cache = t
    /\ f' = [f EXCEPT !.L = q[t].target]
    /\ q' = [q EXCEPT ![t].pc = "BackendReturn"]
    /\ UNCHANGED <<mu, h, position>>

\* ext2/inode/file.rs:108-131,409-429: one W guard covers size and cache.
Ext2Resize(t) ==
    /\ Backend = "ext2" /\ q[t].pc = "Dispatch" /\ q[t].kind = "ftruncate"
    /\ FreeInode
    /\ mu' = [mu EXCEPT !.writer = t]
    /\ q' = [q EXCEPT ![t].S = f.L, ![t].resizeOld = f.L,
              ![t].resizeNew = q[t].target, ![t].resizePurpose = "resize",
              ![t].afterResize = "Ext2ResizePublish",
              ![t].pc = IF f.L = q[t].target THEN "BackendReturn" ELSE "ResizeBegin"]
    /\ UNCHANGED <<f, h, position>>

\* ext2/inode/file.rs:412-415,426-428; no competing inode operation enters.
Ext2ResizePublish(t) ==
    /\ Backend = "ext2" /\ q[t].pc = "Ext2ResizePublish" /\ mu.writer = t
    /\ f' = [f EXCEPT !.L = q[t].target,
              !.blocks = IF q[t].target < q[t].S
                         THEN {j \in f.blocks : j * P < q[t].target} ELSE @]
    /\ q' = [q EXCEPT ![t].pc = "BackendReturn"]
    /\ UNCHANGED <<mu, h, position>>

\* exfat/inode.rs:1437-1450: the U-to-W upgrade has no unlocked interval.
ExfatResize(t) ==
    /\ Backend = "exfat" /\ q[t].pc = "Dispatch" /\ q[t].kind = "ftruncate"
    /\ mu.writer = NoThread /\ mu.up = NoThread
    /\ mu' = [mu EXCEPT !.up = t]
    /\ q' = [q EXCEPT ![t].S = f.L, ![t].resizeOld = f.L,
              ![t].resizeNew = q[t].target, ![t].pc = "ExfatResizeUpgrade",
              ![t].resizePurpose = "resize", ![t].afterResize = "ExfatAllocate"]
    /\ UNCHANGED <<f, h, position>>

\* exfat/inode.rs:1450-1455: public extension skips PageCache::resize.
ExfatResizeUpgrade(t) ==
    /\ Backend = "exfat" /\ q[t].pc = "ExfatResizeUpgrade"
    /\ mu.up = t /\ mu.readers = {}
    /\ mu' = [mu EXCEPT !.up = NoThread, !.writer = t]
    /\ q' = [q EXCEPT ![t].pc = IF q[t].target < q[t].S
                                        THEN "ResizeBegin" ELSE "ExfatAllocate"]
    /\ UNCHANGED <<f, h, position>>

\* page_cache/mod.rs:250-255: preserve both existing tail-clearing branches.
PageCacheResizeBegin(t) ==
    /\ q[t].pc = "ResizeBegin"
    /\ LET n == q[t].resizeNew
           old == q[t].resizeOld
           lo == Min(n, old)
           hi == IF n < old /\ n % P /= 0 THEN Min(old, Round(n, P))
                 ELSE IF n > old /\ old % P /= 0 THEN Min(n, Round(old, P))
                 ELSE lo IN
       /\ q' = [q EXCEPT ![t].pc = IF hi > lo THEN "FillZeros" ELSE "ResizeCapacity",
                 ![t].ioKind = "Zero", ![t].ioOff = lo, ![t].ioLen = hi - lo,
                 ![t].ioDone = 0, ![t].afterIo = "ResizeCapacity"]
    /\ UNCHANGED <<f, mu, h, position>>

\* vmo/mod.rs:644-660: zeros use a stable kernel source, never user EFAULT.
PageCacheFillZeros(t) ==
    /\ q[t].pc = "FillZeros"
    /\ q[t].ioOff + q[t].ioLen <= f.C
    /\ q' = [q EXCEPT ![t].pc = "VmoBegin"]
    /\ UNCHANGED <<f, mu, h, position>>

\* page_cache/mod.rs:258-278: decommit is selected by logical shrink,
\* not by comparing actual old/new capacity (S2).
PageCacheResizeCapacity(t) ==
    /\ q[t].pc = "ResizeCapacity"
    /\ LET n == Round(q[t].resizeNew, P)
           remove == {j \in Pages : q[t].resizeNew < q[t].resizeOld
                                            /\ j * P >= n /\ j * P < f.C} IN
       /\ f' = [f EXCEPT !.C = n,
                 !.pages = [i \in 1..Len(f.pages) |->
                              IF i - 1 \in remove THEN "Absent" ELSE f.pages[i]],
                 !.data = [i \in 1..MaxByte |->
                             IF (i - 1) \div P \in remove THEN "uninit" ELSE f.data[i]]]
       /\ q' = [q EXCEPT ![t].pc = IF Backend = "ext2"
                                  THEN "Ext2CacheBound" ELSE q[t].afterResize]
    /\ UNCHANGED <<mu, h, position>>

\* ext2/inode/mod.rs:478-480: publish backend npages after cache resizing.
Ext2ResizePageCacheBound(t) ==
    /\ Backend = "ext2" /\ q[t].pc = "Ext2CacheBound" /\ mu.writer = t
    /\ f' = [f EXCEPT !.npages = Round(q[t].resizeNew, P) \div P]
    /\ q' = [q EXCEPT ![t].pc = q[t].afterResize]
    /\ UNCHANGED <<mu, h, position>>

\* ramfs/fs.rs:750; ext2/inode/file.rs:262; exfat/inode.rs:736.
WriteAtCopyStart(t) ==
    /\ q[t].pc = "WriteCopyStart"
    /\ q' = [q EXCEPT ![t].pc = "VmoBegin", ![t].ioKind = "Write",
              ![t].ioOff = q[t].O, ![t].ioLen = q[t].N,
              ![t].afterIo = IF Backend = "ramfs" THEN "BackendReturn"
                             ELSE IF Backend = "ext2" THEN "Ext2WritePublish"
                             ELSE "ExfatWritePublish"]
    /\ UNCHANGED <<f, mu, h, position>>

\* vmo/mod.rs:535-542,571-578: a capacity-clamped zero copy is success.
VmoIoBegin(t) ==
    /\ q[t].pc = "VmoBegin"
    /\ LET len == Min(q[t].ioLen, Sub(f.C, q[t].ioOff)) IN
       /\ q' = [q EXCEPT ![t].ioDone = 0, ![t].ioEnd = q[t].ioOff + len,
                 ![t].pc = IF len = 0 THEN q[t].afterIo ELSE "CollectBegin"]
    /\ UNCHANGED <<f, mu, h, position>>

\* vmo/mod.rs:548-557,595-637,681-690,717-724: collect each batch before
\* its first copy, including pages beyond a subsequent user fault.
VmoCollectBegin(t) ==
    /\ q[t].pc = "CollectBegin"
    /\ LET at == q[t].ioOff + q[t].ioDone
           whole == q[t].ioKind = "Read" \/ Backend = "ramfs"
                    \/ q[t].ioEnd - q[t].ioOff < P
           stop == IF whole THEN q[t].ioEnd
                   ELSE IF at % P /= 0 THEN Min(Round(at, P), q[t].ioEnd)
                   ELSE IF q[t].ioEnd - at >= P THEN (q[t].ioEnd \div P) * P
                   ELSE q[t].ioEnd IN
       /\ q' = [q EXCEPT ![t].segmentEnd = stop, ![t].collectNext = at \div P,
                 ![t].collectEnd = Round(stop, P) \div P,
                 ![t].overwrite = q[t].ioKind = "Write" /\ ~whole
                                  /\ at % P = 0 /\ stop % P = 0,
                 ![t].pc = "CommitPage"]
    /\ UNCHANGED <<f, mu, h, position>>

\* vmo/mod.rs:309-322,1020-1051: frame allocation precedes backend read.
VmoCommitPage(t) ==
    /\ q[t].pc = "CommitPage"
    /\ LET j == q[t].collectNext
           anon == Backend = "ramfs"
           fresh == f.pages[j + 1] = "Absent"
           needsRead == ~anon /\ ~Initialized(f, j) /\ ~q[t].overwrite IN
       /\ j * P < f.C
       /\ f' = [f EXCEPT
                 !.pages[j + 1] = IF fresh THEN IF anon THEN "Clean" ELSE "Uninit" ELSE @,
                 !.data = [i \in 1..MaxByte |->
                            IF anon /\ fresh /\ (i - 1) \div P = j THEN "zero" ELSE f.data[i]]]
       /\ q' = [q EXCEPT ![t].page = j,
                 ![t].pc = IF needsRead THEN "BackendRead" ELSE "CollectedPage"]
    /\ UNCHANGED <<mu, h, position>>

\* vmo/mod.rs:548-556,717-724: all collected references precede copying.
VmoCollectedPage(t) ==
    /\ q[t].pc = "CollectedPage"
    /\ LET more == q[t].collectNext + 1 < q[t].collectEnd IN
       /\ q' = [q EXCEPT ![t].collectNext = @ + 1,
                 ![t].page = IF more THEN q[t].collectNext + 1
                            ELSE (q[t].ioOff + q[t].ioDone) \div P,
                 ![t].pc = IF more THEN "CommitPage" ELSE "CopyPage"]
    /\ UNCHANGED <<f, mu, h, position>>

\* exfat/inode.rs:151; rwmutex.rs:129-130,163-168: recursive read waits
\* while the caller still holds W. TV7 is an explicit blocked PC, not fairness.
ExfatBackendReadBlocked(t) ==
    /\ Backend = "exfat" /\ q[t].pc = "BackendRead" /\ mu.writer = t
    /\ q' = [q EXCEPT ![t].pc = "BackendReadBlocked"]
    /\ UNCHANGED <<f, mu, h, position>>

\* ext2/block_manager/mod.rs:141-154; exfat/inode.rs:151-167.
\* Backend callbacks execute under the existing guard; U permits nested R.
VmoBackendRead(t) ==
    /\ q[t].pc = "BackendRead"
    /\ (Backend /= "exfat" \/ mu.writer = NoThread)
    /\ LET j == q[t].page
           valid == IF Backend = "ext2" THEN j < f.npages ELSE j * P < f.A
           zero == IF Backend = "ext2" THEN j \notin f.blocks ELSE j * P >= f.L IN
       /\ valid
       /\ f' = [f EXCEPT !.pages[j + 1] = "Clean",
                 !.data = [i \in 1..MaxByte |->
                           IF (i - 1) \div P = j
                           THEN IF zero THEN "zero" ELSE f.disk[i] ELSE f.data[i]]]
       /\ q' = [q EXCEPT ![t].pc = "CollectedPage"]
    /\ UNCHANGED <<mu, h, position>>

\* Error continuation mirrors ? and ext2 cleanup, not a rollback oracle.
\* ext2/inode/file.rs:257-264,205-219; exfat/inode.rs:736-743;
\* ramfs/fs.rs:748-750,809-813; error.rs:209-219.
ErrorPC(t) ==
    IF Backend = "ext2" /\ q[t].kind = "pwrite64"
    THEN IF q[t].resizePurpose = "rollback" THEN "Ext2RollbackBlocks"
         ELSE "Ext2RollbackStart"
    ELSE "BackendReturn"

\* vmo/mod.rs:648-650; ext2/block_manager/mod.rs:141-142;
\* exfat/inode.rs:152-153. Only actual range-check failures are admitted.
VmoRangeError(t) ==
    /\ \/ /\ q[t].pc = "FillZeros" /\ q[t].ioOff + q[t].ioLen > f.C
       \/ /\ q[t].pc = "BackendRead"
          /\ ((Backend = "ext2" /\ q[t].page >= f.npages)
              \/ (Backend = "exfat" /\ mu.writer = NoThread /\ q[t].page * P >= f.A))
    /\ q' = [q EXCEPT ![t].pc = ErrorPC(t),
              ![t].status = IF q[t].resizePurpose = "rollback" THEN @ ELSE "EINVAL",
              ![t].errorSite = IF q[t].resizePurpose = "rollback" THEN @
                              ELSE IF q[t].pc = "FillZeros" THEN "fill_range" ELSE "backend_bound"]
    /\ UNCHANGED <<f, mu, h, position>>

\* ostd/src/mm/io/mod.rs:339-360; vmo/mod.rs:557,690,734-751.
\* The fixed fault boundary affects only user copies. A cold overwritten
\* page's faulted fragment stays Uninit; initialized fragments are accepted.
VmoCopyPage(t) ==
    /\ q[t].pc = "CopyPage"
    /\ LET at == q[t].ioOff + q[t].ioDone
           span == Min(q[t].ioEnd - at, P - (at % P))
           count == IF q[t].ioKind = "Zero" THEN span
                    ELSE Min(span, Sub(q[t].fault, q[t].D))
           failed == count < span
           rd == q[t].ioKind = "Read"
           accepted == ~rd /\ (Backend = "ramfs" \/ Initialized(f, q[t].page) \/ ~failed)
           done == q[t].ioDone + count
           next == IF failed THEN ErrorPC(t)
                   ELSE IF q[t].ioOff + done = q[t].ioEnd
                        THEN q[t].afterIo
                        ELSE IF q[t].ioOff + done = q[t].segmentEnd
                             THEN "CollectBegin" ELSE "CopyPage" IN
       /\ f' = [f EXCEPT
                 !.data = [i \in 1..MaxByte |->
                           IF ~rd /\ i - 1 \in at..(at + count - 1)
                           THEN IF q[t].ioKind = "Zero" THEN "zero" ELSE t ELSE f.data[i]],
                 !.pages[q[t].page + 1] =
                      IF ~rd /\ accepted /\ count > 0
                      THEN IF Backend = "ramfs" THEN "Clean" ELSE "Dirty" ELSE @]
       /\ q' = [q EXCEPT ![t].ioDone = done, ![t].pc = next,
                 ![t].page = IF next = "CopyPage" THEN (q[t].ioOff + done) \div P ELSE @,
                 ![t].D = IF q[t].ioKind = "Zero" THEN @ ELSE @ + count,
                 ![t].accepted = IF q[t].ioKind = "Write" /\ accepted
                                 THEN @ \cup at..(at + count - 1) ELSE @,
                 ![t].out = [i \in 1..MaxByte |->
                            IF rd /\ i > q[t].D /\ i <= q[t].D + count
                            THEN f.data[at + i - q[t].D] ELSE q[t].out[i]],
                 ![t].status = IF failed THEN "EFAULT" ELSE @,
                 ![t].errorSite = IF failed THEN IF rd THEN "user_destination"
                                                         ELSE "user_source" ELSE @]
    /\ UNCHANGED <<mu, h, position>>

\* ext2/inode/file.rs:268-271: successful write publishes after copying.
Ext2WriteAtPublish(t) ==
    /\ Backend = "ext2" /\ q[t].pc = "Ext2WritePublish" /\ mu.writer = t
    /\ f' = [f EXCEPT !.L = IF q[t].candidate > q[t].S THEN q[t].candidate ELSE @]
    /\ q' = [q EXCEPT ![t].pc = "BackendReturn"]
    /\ UNCHANGED <<mu, h, position>>

\* exfat/inode.rs:740-744: upgrade is atomic, assignment uses saved size.
ExfatWriteAtPublish(t) ==
    /\ Backend = "exfat" /\ q[t].pc = "ExfatWritePublish"
    /\ mu.up = t /\ mu.readers = {}
    /\ mu' = [mu EXCEPT !.up = NoThread, !.writer = t]
    /\ f' = [f EXCEPT !.L = q[t].candidate]
    /\ q' = [q EXCEPT ![t].pc = "BackendReturn"]
    /\ UNCHANGED <<h, position>>

\* ext2/inode/file.rs:205-217: rollback can retain in-EOF initialized data.
Ext2RollbackWrite(t) ==
    /\ Backend = "ext2" /\ q[t].pc = "Ext2RollbackStart" /\ mu.writer = t
    /\ q' = [q EXCEPT ![t].resizePurpose = "rollback",
              ![t].resizeOld = q[t].candidate, ![t].resizeNew = q[t].S,
              ![t].afterResize = "Ext2RollbackBlocks",
              ![t].pc = IF q[t].candidate > q[t].S THEN "ResizeBegin" ELSE "BackendReturn"]
    /\ UNCHANGED <<f, mu, h, position>>

\* ext2/inode/file.rs:216-218: cleanup continues even after resize failure.
Ext2RollbackBlocks(t) ==
    /\ Backend = "ext2" /\ q[t].pc = "Ext2RollbackBlocks" /\ mu.writer = t
    /\ f' = [f EXCEPT !.blocks = {j \in f.blocks : j * P < q[t].S}]
    /\ q' = [q EXCEPT ![t].pc = "BackendReturn"]
    /\ UNCHANGED <<mu, h, position>>

\* ramfs/fs.rs:709-718,750-756,816; ext2/inode/file.rs:31-35,271;
\* exfat/inode.rs:656-657,744-755,1462. Atime/sync succeed in this scope.
\* ext2 read releases R before its atime W acquisition, represented below.
BackendReturn(t) ==
    /\ q[t].pc = "BackendReturn"
    /\ q' = [q EXCEPT ![t].result = IF q[t].status \in {"Pending", "Ok"}
                        THEN IF q[t].kind \in ReadKinds THEN q[t].K
                             ELSE IF q[t].kind = "pwrite64" THEN q[t].N ELSE 0
                        ELSE -1,
              ![t].status = IF @ = "Pending" THEN "Ok" ELSE @,
              ![t].pc = IF Backend = "ext2" /\ q[t].kind \in ReadKinds
                               /\ q[t].status = "Pending" /\ q[t].K > 0
                       THEN "Ext2ReadAtime" ELSE "Return"]
    /\ mu' = [mu EXCEPT !.cache = IF @ = t THEN NoThread ELSE @,
               !.writer = IF @ = t THEN NoThread ELSE @,
               !.up = IF @ = t THEN NoThread ELSE @, !.readers = @ \ {t}]
    /\ UNCHANGED <<f, h, position>>

\* ext2/inode/file.rs:32-33: a mutation may finish after copy before atime.
Ext2ReadAtUpdateAtime(t) ==
    /\ q[t].pc = "Ext2ReadAtime" /\ FreeInode
    /\ q' = [q EXCEPT ![t].pc = "Return"]
    /\ UNCHANGED <<f, mu, h, position>>

\* S3 reference observer: only isolated, known histories get byte oracles.
\* Source effects: ext2/file.rs:409-429; ramfs/fs.rs:788-816;
\* exfat/inode.rs:711-755,1436-1462. Desired results are not action guards.
ReferenceAfter(t) ==
    IF q[t].kind = "ftruncate"
    THEN [i \in 1..MaxByte |-> IF i <= Min(h.referenceSize, q[t].target)
                              THEN h.reference[i] ELSE "zero"]
    ELSE [i \in 1..MaxByte |->
            IF i - 1 >= q[t].O /\ i - 1 < q[t].O + q[t].result THEN t
            ELSE IF i > h.referenceSize THEN "zero" ELSE h.reference[i]]
ReferenceSizeAfter(t) ==
    IF q[t].kind = "ftruncate" THEN q[t].target
    ELSE IF q[t].result = 0 THEN h.referenceSize
    ELSE Max(h.referenceSize, q[t].O + q[t].result)
ReadZerosOK(t) ==
    (q[t].kind \in ReadKinds /\ q[t].solo /\ q[t].referenceValid)
    => \A i \in 1..q[t].D :
        (q[t].O + i <= q[t].referenceSize
         /\ q[t].reference[q[t].O + i] = "zero") => q[t].out[i] = "zero"

\* inode_handle.rs:287-290,323-353: offset update uses returned K, not D.
\* Completion history stores original offset/result independently of final L.
InodeHandleReturn(t) ==
    /\ q[t].pc = "Return"
    /\ LET pos == IF q[t].kind = "read" /\ q[t].status = "Ok"
                  THEN position + q[t].result ELSE position
           isMut == q[t].kind \in MutKinds
           refUpdate == isMut /\ q[t].solo /\ h.referenceValid /\ q[t].status = "Ok"
           rec == [kind |-> q[t].kind, O |-> q[t].O, N |-> q[t].N,
                   D |-> q[t].D, accepted |-> q[t].accepted, result |-> q[t].result,
                   status |-> q[t].status, fault |-> q[t].fault,
                   solo |-> q[t].solo, oldL |-> q[t].oldL, L |-> f.L, C |-> f.C,
                   target |-> q[t].target, startPosition |-> q[t].startPosition,
                   positionBefore |-> position, positionAfter |-> pos,
                   oldView |-> q[t].oldView, view |-> FileView(f), out |-> q[t].out,
                   zerosOK |-> ReadZerosOK(t)] IN
       /\ position' = pos
       /\ h' = [h EXCEPT !.completed = @ \cup {rec},
                 !.writes = IF q[t].kind = "pwrite64" /\ q[t].status = "Ok"
                                   /\ q[t].result > 0
                            THEN @ \cup {[O |-> q[t].O, k |-> q[t].result]} ELSE @,
                 !.reference = IF refUpdate THEN ReferenceAfter(t) ELSE @,
                 !.referenceSize = IF refUpdate THEN ReferenceSizeAfter(t) ELSE @,
                 !.referenceValid = @ /\ ~(isMut /\ q[t].status /= "Ok")]
       /\ q' = [q EXCEPT ![t].pc = "Done"]
       /\ mu' = [mu EXCEPT !.offset = IF q[t].kind = "read" THEN NoThread ELSE @]
    /\ UNCHANGED f

\* Dispatch contains every reactive step; MC bounds only SyscallEnter.
ThreadStep(t) ==
    \/ RamfsReadAtObserve(t) \/ RamfsReadAtAcquireCache(t) \/ Ext2ReadAt(t)
    \/ ExfatReadAt(t) \/ Ext2ReadAtEmpty(t) \/ Ext2WriteAtEmpty(t)
    \/ RamfsWriteAtAcquireCache(t) \/ RamfsWriteAtPublish(t) \/ Ext2WriteAtPrepare(t)
    \/ Ext2AllocateRangeBlocks(t) \/ ExfatWriteAtPrepare(t) \/ ExfatResizeAllocation(t)
    \/ ExfatWriteAtReleasePreparation(t) \/ ExfatWriteAtAcquireCopy(t)
    \/ RamfsResizeAcquireCache(t) \/ RamfsResize(t) \/ RamfsResizePublish(t)
    \/ Ext2Resize(t) \/ Ext2ResizePublish(t)
    \/ ExfatResize(t) \/ ExfatResizeUpgrade(t) \/ PageCacheResizeBegin(t)
    \/ PageCacheFillZeros(t) \/ PageCacheResizeCapacity(t) \/ Ext2ResizePageCacheBound(t)
    \/ WriteAtCopyStart(t) \/ VmoIoBegin(t) \/ VmoCollectBegin(t)
    \/ VmoCommitPage(t) \/ VmoCollectedPage(t)
    \/ ExfatBackendReadBlocked(t) \/ VmoBackendRead(t) \/ VmoRangeError(t)
    \/ VmoCopyPage(t) \/ Ext2WriteAtPublish(t) \/ ExfatWriteAtPublish(t)
    \/ Ext2RollbackWrite(t) \/ Ext2RollbackBlocks(t) \/ BackendReturn(t)
    \/ Ext2ReadAtUpdateAtime(t) \/ InodeHandleReturn(t)

Next == \E t \in Threads :
          \/ ThreadStep(t)
          \/ \E k \in Kinds, o \in 0..MaxByte, n \in 0..MaxByte,
                 z \in 0..MaxByte, b \in 0..MaxByte : SyscallEnter(t, k, o, n, z, b)
Spec == Init /\ [][Next]_vars

\* Core safety/model fidelity (brief S1-S4).
PCs == {"Idle", "Done", "Dispatch", "RamReadCache", "VmoBegin", "BackendReturn",
        "RamWriteMetadata", "ResizeBegin", "WriteCopyStart", "Ext2Allocate",
        "ExfatAllocate", "ExfatReleasePreparation", "ExfatAcquireCopy",
        "RamResizeMetadata", "RamResizePublish", "Ext2ResizePublish",
        "ExfatResizeUpgrade", "FillZeros", "ResizeCapacity", "Ext2CacheBound",
        "CollectBegin", "CommitPage", "CollectedPage", "BackendRead", "CopyPage",
        "BackendReadBlocked", "Ext2RollbackBlocks", "Ext2RollbackStart",
        "Ext2WritePublish", "ExfatWritePublish", "Ext2ReadAtime", "Return"}
TypeOK ==
    /\ f.L \in 0..MaxByte /\ f.C \in 0..MaxByte /\ f.C % P = 0
    /\ f.A \in 0..MaxByte /\ f.clusters \in 0..(MaxByte \div G)
    /\ f.npages \in 0..(MaxByte \div P) /\ f.blocks \subseteq Pages
    /\ f.pages \in [1..(MaxByte \div P) -> PageStates]
    /\ f.data \in [1..MaxByte -> Values] /\ f.disk \in [1..MaxByte -> Values]
    /\ DOMAIN q = Threads /\ position \in Nat
    /\ {mu.cache, mu.writer, mu.up, mu.offset} \subseteq Threads \cup {NoThread}
    /\ mu.readers \subseteq Threads
    /\ h.reference \in [1..MaxByte -> Values]
    /\ h.referenceSize \in 0..MaxByte /\ h.referenceValid \in BOOLEAN
    /\ h.everTruncated \in BOOLEAN
    /\ \A e \in h.writes : e.O \in 0..MaxByte /\ e.k \in 1..MaxByte
    /\ \A t \in Threads :
          /\ q[t].pc \in PCs /\ q[t].kind \in Kinds
          /\ q[t].O \in 0..MaxByte /\ q[t].N \in 0..MaxByte
          /\ q[t].D \in 0..q[t].N /\ q[t].accepted \subseteq Bytes
          /\ q[t].fault \in 0..q[t].N /\ q[t].out \in [1..MaxByte -> Values]
          /\ q[t].result \in {-1} \cup 0..q[t].N
          /\ {q[t].S, q[t].K, q[t].candidate, q[t].copyO,
               q[t].ioOff, q[t].ioLen, q[t].ioDone, q[t].ioEnd,
               q[t].resizeOld, q[t].resizeNew, q[t].segmentEnd} \subseteq 0..MaxByte
          /\ q[t].page \in Pages
          /\ {q[t].collectNext, q[t].collectEnd} \subseteq 0..(MaxByte \div P)
          /\ q[t].overwrite \in BOOLEAN /\ q[t].solo \in BOOLEAN
          /\ q[t].ioKind \in {"Read", "Write", "Zero"}
          /\ q[t].status \in {"Pending", "Ok", "EFAULT", "EINVAL"}
LockExclusion ==
    /\ (mu.writer /= NoThread => mu.up = NoThread /\ mu.readers = {})
    /\ (Backend = "ramfs" => FreeInode)
    /\ (Backend /= "ramfs" => mu.cache = NoThread)
    /\ (Backend = "ext2" => mu.up = NoThread)
    /\ (Backend = "exfat" => mu.readers = {})
    /\ \A t \in Threads : q[t].pc = "BackendReadBlocked" =>
              Backend = "exfat" /\ mu.writer = t

\* Structural invariants, enabled during convergence, not hunt substitutes.
CopyAcceptanceStructure ==
    \A t \in Threads : Cardinality(q[t].accepted) <= q[t].D
OffsetLockStructure ==
    /\ (mu.offset /= NoThread => q[mu.offset].kind = "read" /\ mu.offset \in Active)
    /\ \A t \in Active : q[t].kind = "read" => mu.offset = t

\* S1/S2; read(2)/write(2). D is independent cursor movement.
SuccessfulTransferAccounting ==
    \A e \in h.completed : e.status = "Ok" =>
       /\ (e.kind \in ReadKinds => e.result = e.D /\ e.D <= e.N)
       /\ (e.kind = "pwrite64" => 0 <= e.result /\ e.result <= e.D /\ e.D <= e.N)
UnreportedReadSuffixUnchanged ==
    \A e \in h.completed : (e.kind \in ReadKinds /\ e.status = "Ok") =>
         \A i \in (e.result + 1)..e.N : e.out[i] = "sentinel"
ControlledOffsetAccounting ==
    \A e \in h.completed :
       /\ ((e.kind = "read" /\ e.status = "Ok") =>
              e.positionAfter = e.startPosition + e.result
              /\ e.positionAfter = e.startPosition + e.D)
       /\ (e.kind \in {"pread64", "pwrite64"} => e.positionAfter = e.positionBefore)

\* S2/S3: capacity can exceed EOF. Cold backed pages also need valid bounds.
SettledReadableExtent == Quiescent =>
    /\ f.L <= f.C
    /\ \A j \in Pages : (j * P < f.L /\ ~Initialized(f, j)) =>
          CASE Backend = "exfat" -> j * P < f.A
            [] Backend = "ext2" -> j < f.npages
            [] OTHER -> TRUE
ExtendersPreserveExtent ==
    (Quiescent /\ ~h.everTruncated) => \A e \in h.writes : f.L >= e.O + e.k
SuccessfulResizeContract ==
    \A e \in h.completed : (e.kind = "ftruncate" /\ e.solo /\ e.status = "Ok")
                           => e.L = e.target
HoleZeros == \A e \in h.completed : e.zerosOK
EmptyWriteNoEffect ==
    \A e \in h.completed : (e.kind = "pwrite64" /\ e.N = 0 /\ e.solo /\ e.status = "Ok")
                           => e.L = e.oldL /\ e.view = e.oldView

\* S4 contract is qualified: ramfs zero-progress append-at-EOF compared
\* with Linux v6.12 mm/filemap.c:4042-4045 and fs/libfs.c:960-989;
\* ext2/exFAT preserve L on isolated copy error but may retain page effects.
\* No universal rollback or acceptance of Uninit fragments is asserted.
AcceptedExtent ==
    \A e \in h.completed : (e.kind = "pwrite64" /\ e.solo /\ e.status = "EFAULT") =>
       CASE Backend = "ramfs" ->
              (e.D = 0 /\ e.accepted = {} /\ e.O = e.oldL /\ e.N > 0) => e.L = e.oldL
         [] OTHER -> e.L = e.oldL
=============================================================================
