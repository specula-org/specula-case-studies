---- MODULE base ----
(***************************************************************************)
(* Asterinas regular-file partial-progress model.                          *)
(*                                                                         *)
(* Category B: concurrent runtime state. Each Thread is a cooperating       *)
(* caller using one shared InodeHandle/open-file description.              *)
(*                                                                         *)
(* Progress uses three symbolic classes represented by 0, 1, and 2 units.  *)
(* The units distinguish zero, positive-prefix, and complete progress;      *)
(* they are not byte, page, or chunk counts.                                *)
(*                                                                         *)
(* Modeling brief scenarios:                                               *)
(*   S1 - positive copy progress lost by tuple-to-Error conversion          *)
(*   S2 - adapter EOF limiting and write-publication ordering               *)
(*   S3 - readv/writev release the shared-offset lock per iovec             *)
(*   S4 - pread64/pwrite64 do not own or update the shared offset           *)
(***************************************************************************)

EXTENDS Integers, Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Thread,
    EnabledKinds,
    EnabledAdapters,
    ExplicitOffsets,
    InitialSharedOffset,
    InitialFileSize,
    InitialCacheCapacity,
    AllowSignals

NoThread == "NoThread"

ReadKind   == "Read"
WriteKind  == "Write"
PreadKind  == "Pread64"
PwriteKind == "Pwrite64"
ReadvKind  == "Readv"
WritevKind == "Writev"

OpKinds     == {ReadKind, WriteKind, PreadKind, PwriteKind, ReadvKind, WritevKind}
ReadKinds   == {ReadKind, PreadKind, ReadvKind}
WriteKinds  == {WriteKind, PwriteKind, WritevKind}
SharedKinds == {ReadKind, WriteKind, ReadvKind, WritevKind}
VectorKinds == {ReadvKind, WritevKind}

CorrectAdapter == "Correct"
RamFsAdapter   == "RamFs"
ExfatAdapter   == "Exfat"
AdapterProfiles == {CorrectAdapter, RamFsAdapter, ExfatAdapter}

ZeroProgress     == "Zero"
PrefixProgress   == "Prefix"
CompleteProgress == "Complete"
NoProgress       == "None"
ProgressClasses  == {ZeroProgress, PrefixProgress, CompleteProgress}

RequestUnits == 2
IovCount     == 2

PhaseSet == {
    "Idle",
    "NeedOffsetStart",
    "NeedPositionalStart",
    "NeedAdapter",
    "NeedCopy",
    "NeedTupleConversion",
    "NeedFileOpsReturn",
    "NeedHandleReturn",
    "NeedOffsetRelease",
    "NeedVectorDispatch",
    "NeedSyscallFinish",
    "NeedSignal",
    "NeedRestart",
    "Done"
}

EntryStatusSet == {"None", "Ok", "EFAULT", "EINTR"}
ResultSet      == {"Pending", "Ok", "EFAULT", "EINTR", "ERESTARTSYS"}

ASSUME /\ Thread # {}
       /\ NoThread \notin Thread
       /\ EnabledKinds \subseteq OpKinds
       /\ EnabledKinds # {}
       /\ EnabledAdapters \subseteq AdapterProfiles
       /\ EnabledAdapters # {}
       /\ ExplicitOffsets \subseteq Nat
       /\ ExplicitOffsets # {}
       /\ InitialSharedOffset \in Nat
       /\ InitialFileSize \in Nat
       /\ InitialCacheCapacity \in Nat
       /\ InitialFileSize <= InitialCacheCapacity
       /\ AllowSignals \in BOOLEAN

VARIABLES
    sharedOffset,     \* InodeHandle::offset shared by duplicated descriptors (S1/S3/S4)
    offsetOwner,      \* owner of the InodeHandle offset mutex, or NoThread (S3)
    fileSize,         \* logical EOF exposed by the filesystem adapter (S2)
    cacheCapacity,    \* page-aligned PageCache/Vmo capacity (S2)
    adapterProfile,   \* one filesystem profile for the shared file (S2)
    opState,          \* per-thread PC, progress, result, offset, and restart state
    effectLog,        \* visible user-memory/file-data effects (S1/S2/S4)
    commitLog         \* successful shared-offset entry commits (S1/S3)

vars == <<
    sharedOffset,
    offsetOwner,
    fileSize,
    cacheCapacity,
    adapterProfile,
    opState,
    effectLog,
    commitLog
>>

Units(progress) ==
    CASE progress = ZeroProgress     -> 0
      [] progress = PrefixProgress   -> 1
      [] progress = CompleteProgress -> RequestUnits

RequestedUnits(kind) ==
    IF kind \in VectorKinds THEN IovCount * RequestUnits ELSE RequestUnits

UsesSharedOffset(kind) == kind \in SharedKinds
IsRead(kind)           == kind \in ReadKinds
IsWrite(kind)          == kind \in WriteKinds
IsVector(kind)         == kind \in VectorKinds

StartPhase(kind) ==
    IF UsesSharedOffset(kind) THEN "NeedOffsetStart" ELSE "NeedPositionalStart"

NatMax(a, b) == IF a >= b THEN a ELSE b

AvailableClass(start, bound) ==
    IF bound <= start THEN ZeroProgress
    ELSE IF bound - start < RequestUnits THEN PrefixProgress
    ELSE CompleteProgress

EffectRecord(t, amount) == [
    tid       |-> t,
    syscallId |-> opState[t].syscallId,
    attemptId |-> opState[t].attemptId,
    iov       |-> opState[t].iovIndex,
    kind      |-> opState[t].kind,
    start     |-> opState[t].entryStart,
    amount    |-> amount
]

CommitRecord(t, amount) == [
    tid       |-> t,
    syscallId |-> opState[t].syscallId,
    attemptId |-> opState[t].attemptId,
    iov       |-> opState[t].iovIndex,
    kind      |-> opState[t].kind,
    start     |-> opState[t].entryStart,
    amount    |-> amount
]

IdleOpState == [
    phase             |-> "Idle",
    kind              |-> "None",
    usesSharedOffset  |-> FALSE,
    explicitOffset    |-> 0,
    entryStart        |-> 0,
    logicalAvail      |-> ZeroProgress,
    copyLimit         |-> ZeroProgress,
    iovIndex          |-> 1,
    requested         |-> 0,
    entryCopied       |-> 0,
    entryReturned     |-> 0,
    copied            |-> 0,
    committed         |-> 0,
    reported          |-> 0,
    offsetAdvanced    |-> 0,
    entryStatus       |-> "None",
    result            |-> "Pending",
    lastFaultProgress |-> NoProgress,
    publishedEOF      |-> ZeroProgress,
    readPastEOF       |-> FALSE,
    sizeAtEntry       |-> 0,
    syscallId         |-> 0,
    attemptId         |-> 0,
    restartPending    |-> FALSE,
    signalPending     |-> FALSE,
    saRestart         |-> FALSE
]

(***************************************************************************)
(* Initialization                                                          *)
(***************************************************************************)

Init ==
    \* InodeHandle initializes one mutex-protected offset at zero.
    \* kernel/core/src/fs/file/inode_handle.rs:71-75
    /\ sharedOffset = InitialSharedOffset
    /\ offsetOwner = NoThread
    \* PageCache capacity is page-aligned and may exceed logical EOF.
    \* kernel/core/src/vm/page_cache/mod.rs:181-186,264-271
    /\ fileSize = InitialFileSize
    /\ cacheCapacity = InitialCacheCapacity
    \* One inode has one adapter; choose its profile once for the execution.
    \* kernel/core/src/fs/fs_impls/ramfs/fs.rs:694-756
    \* kernel/core/src/fs/fs_impls/exfat/inode.rs:642-755
    /\ adapterProfile \in EnabledAdapters
    \* Duplicated table entries clone the same Arc<FileLike>.
    \* kernel/core/src/fs/file/file_table.rs:181-188,393-398
    /\ opState = [t \in Thread |-> IdleOpState]
    /\ effectLog = <<>>
    /\ commitLog = <<>>

(***************************************************************************)
(* Syscall entry actions                                                    *)
(***************************************************************************)

BeginOperation(t, kind, explicit, hasSignal, restartFlag) ==
    \* A thread enters only after its prior syscall has returned to user mode.
    \* kernel/core/src/thread/task.rs:71-89
    /\ opState[t].phase \in {"Idle", "Done"}
    /\ kind \in EnabledKinds
    \* A pending user-handler signal may request SA_RESTART. The model never
    \* invents an EINTR producer; it only preserves the wrapper/restart gate.
    \* kernel/core/src/process/signal/mod.rs:54-60,125-158
    /\ hasSignal \in BOOLEAN
    /\ restartFlag \in BOOLEAN
    /\ (~hasSignal => ~restartFlag)
    /\ (AllowSignals \/ ~hasSignal)
    \* Save a fresh logical syscall and its first kernel attempt.
    \* kernel/core/src/thread/task.rs:83-89
    /\ opState' = [opState EXCEPT
        ![t].phase             = StartPhase(kind),
        ![t].kind              = kind,
        ![t].usesSharedOffset  = UsesSharedOffset(kind),
        ![t].explicitOffset    = explicit,
        ![t].entryStart        = 0,
        ![t].logicalAvail      = ZeroProgress,
        ![t].copyLimit         = ZeroProgress,
        ![t].iovIndex          = 1,
        ![t].requested         = RequestedUnits(kind),
        ![t].entryCopied       = 0,
        ![t].entryReturned     = 0,
        ![t].copied            = 0,
        ![t].committed         = 0,
        ![t].reported          = 0,
        ![t].offsetAdvanced    = 0,
        ![t].entryStatus       = "None",
        ![t].result            = "Pending",
        ![t].lastFaultProgress = NoProgress,
        ![t].publishedEOF      = ZeroProgress,
        ![t].readPastEOF       = FALSE,
        ![t].sizeAtEntry       = 0,
        ![t].syscallId         = @ + 1,
        ![t].attemptId         = 1,
        ![t].restartPending    = FALSE,
        ![t].signalPending     = hasSignal,
        ![t].saRestart         = restartFlag]
    /\ UNCHANGED <<sharedOffset, offsetOwner, fileSize, cacheCapacity,
                    adapterProfile, effectLog, commitLog>>

\* kernel/core/src/syscall/read.rs:10-35
SysReadBegin(t, hasSignal, restartFlag) ==
    BeginOperation(t, ReadKind, 0, hasSignal, restartFlag)

\* kernel/core/src/syscall/write.rs:10-35
SysWriteBegin(t, hasSignal, restartFlag) ==
    BeginOperation(t, WriteKind, 0, hasSignal, restartFlag)

\* kernel/core/src/syscall/pread64.rs:10-36
SysPread64Begin(t, explicit, hasSignal, restartFlag) ==
    /\ explicit \in ExplicitOffsets
    /\ BeginOperation(t, PreadKind, explicit, hasSignal, restartFlag)

\* kernel/core/src/syscall/pwrite64.rs:10-35
SysPwrite64Begin(t, explicit, hasSignal, restartFlag) ==
    /\ explicit \in ExplicitOffsets
    /\ BeginOperation(t, PwriteKind, explicit, hasSignal, restartFlag)

\* kernel/core/src/syscall/preadv.rs:11-18,134-155
DoSysReadvBegin(t, hasSignal, restartFlag) ==
    BeginOperation(t, ReadvKind, 0, hasSignal, restartFlag)

\* kernel/core/src/syscall/pwritev.rs:11-18,134-151
DoSysWritevBegin(t, hasSignal, restartFlag) ==
    BeginOperation(t, WritevKind, 0, hasSignal, restartFlag)

(***************************************************************************)
(* Offset selection and ownership                                           *)
(***************************************************************************)

InodeHandleReadAcquireOffset(t) ==
    \* read() acquires the shared offset before calling read_at().
    \* kernel/core/src/fs/file/inode_handle.rs:278-287
    /\ opState[t].phase = "NeedOffsetStart"
    /\ opState[t].kind \in {ReadKind, ReadvKind}
    /\ offsetOwner = NoThread
    \* The locked value is the scalar/iovec entry's start offset.
    \* kernel/core/src/fs/file/inode_handle.rs:285-288
    /\ offsetOwner' = t
    /\ opState' = [opState EXCEPT
        ![t].entryStart = sharedOffset,
        ![t].phase      = "NeedAdapter"]
    /\ UNCHANGED <<sharedOffset, fileSize, cacheCapacity, adapterProfile,
                    effectLog, commitLog>>

InodeHandleWriteAcquireOffset(t) ==
    \* write() acquires the same shared offset before calling write_at().
    \* kernel/core/src/fs/file/inode_handle.rs:301-318
    /\ opState[t].phase = "NeedOffsetStart"
    /\ opState[t].kind \in {WriteKind, WritevKind}
    /\ offsetOwner = NoThread
    \* O_APPEND range atomicity is excluded; this model uses the locked offset.
    \* kernel/core/src/fs/file/inode_handle.rs:308-318
    /\ offsetOwner' = t
    /\ opState' = [opState EXCEPT
        ![t].entryStart = sharedOffset,
        ![t].phase      = "NeedAdapter"]
    /\ UNCHANGED <<sharedOffset, fileSize, cacheCapacity, adapterProfile,
                    effectLog, commitLog>>

InodeHandleReadAtStart(t) ==
    \* read_at() passes the explicit offset without reading the shared mutex.
    \* kernel/core/src/fs/file/inode_handle.rs:323-332
    /\ opState[t].phase = "NeedPositionalStart"
    /\ opState[t].kind = PreadKind
    /\ opState' = [opState EXCEPT
        ![t].entryStart = opState[t].explicitOffset,
        ![t].phase      = "NeedAdapter"]
    /\ UNCHANGED <<sharedOffset, offsetOwner, fileSize, cacheCapacity,
                    adapterProfile, effectLog, commitLog>>

InodeHandleWriteAtStart(t) ==
    \* write_at() uses its argument and does not access InodeHandle::offset.
    \* kernel/core/src/fs/file/inode_handle.rs:334-354
    /\ opState[t].phase = "NeedPositionalStart"
    /\ opState[t].kind = PwriteKind
    /\ opState' = [opState EXCEPT
        ![t].entryStart = opState[t].explicitOffset,
        ![t].phase      = "NeedAdapter"]
    /\ UNCHANGED <<sharedOffset, offsetOwner, fileSize, cacheCapacity,
                    adapterProfile, effectLog, commitLog>>

(***************************************************************************)
(* Filesystem-adapter setup                                                  *)
(***************************************************************************)

Ext2VirtioFsReadComputeLimit(t) ==
    \* Ext2 returns at EOF and limits the destination before PageCache::read.
    \* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:228-242
    \* VirtioFS uses a limited exclusive clone and advances only on success.
    \* kernel/core/src/fs/fs_impls/virtiofs/inode/ops.rs:65-80
    /\ opState[t].phase = "NeedAdapter"
    /\ IsRead(opState[t].kind)
    /\ adapterProfile = CorrectAdapter
    /\ LET limit == AvailableClass(opState[t].entryStart, fileSize)
       IN opState' = [opState EXCEPT
            ![t].logicalAvail = limit,
            ![t].copyLimit    = limit,
            ![t].sizeAtEntry  = fileSize,
            ![t].phase        = "NeedCopy"]
    /\ UNCHANGED <<sharedOffset, offsetOwner, fileSize, cacheCapacity,
                    adapterProfile, effectLog, commitLog>>

RamFsExfatReadComputeLimit(t) ==
    \* RamFS computes an EOF-limited return but passes the unrestricted writer.
    \* kernel/core/src/fs/fs_impls/ramfs/fs.rs:701-710
    \* exFAT has the same unrestricted PageCache::read call.
    \* kernel/core/src/fs/fs_impls/exfat/inode.rs:643-657
    /\ opState[t].phase = "NeedAdapter"
    /\ IsRead(opState[t].kind)
    /\ adapterProfile \in {RamFsAdapter, ExfatAdapter}
    /\ LET logical == AvailableClass(opState[t].entryStart, fileSize)
           cache   == AvailableClass(opState[t].entryStart, cacheCapacity)
       IN opState' = [opState EXCEPT
            ![t].logicalAvail = logical,
            ![t].copyLimit    = cache,
            ![t].sizeAtEntry  = fileSize,
            ![t].phase        = "NeedCopy"]
    /\ UNCHANGED <<sharedOffset, offsetOwner, fileSize, cacheCapacity,
                    adapterProfile, effectLog, commitLog>>

RamFsWritePublishRequestedEnd(t) ==
    \* RamFS records requested EOF and timestamps before the fallible copy.
    \* kernel/core/src/fs/fs_impls/ramfs/fs.rs:731-750
    /\ opState[t].phase = "NeedAdapter"
    /\ IsWrite(opState[t].kind)
    /\ adapterProfile = RamFsAdapter
    /\ LET requestedEnd == opState[t].entryStart + RequestUnits
           expands      == requestedEnd > fileSize
       IN
       /\ fileSize' = NatMax(fileSize, requestedEnd)
       /\ cacheCapacity' = NatMax(cacheCapacity, requestedEnd)
       /\ opState' = [opState EXCEPT
            ![t].logicalAvail = CompleteProgress,
            ![t].copyLimit    = CompleteProgress,
            ![t].sizeAtEntry  = fileSize,
            ![t].publishedEOF = IF expands THEN CompleteProgress ELSE ZeroProgress,
            ![t].phase        = "NeedCopy"]
    /\ UNCHANGED <<sharedOffset, offsetOwner, adapterProfile,
                    effectLog, commitLog>>

DeferredWritePrepare(t) ==
    \* Ext2 prepares capacity and rolls it back on a failed copy.
    \* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:193-219,245-271
    \* exFAT grows allocation but defers visible size until copy success.
    \* kernel/core/src/fs/fs_impls/exfat/inode.rs:711-743
    /\ opState[t].phase = "NeedAdapter"
    /\ IsWrite(opState[t].kind)
    /\ adapterProfile \in {CorrectAdapter, ExfatAdapter}
    /\ LET requestedEnd == opState[t].entryStart + RequestUnits
       IN
       /\ cacheCapacity' = NatMax(cacheCapacity, requestedEnd)
       /\ opState' = [opState EXCEPT
            ![t].logicalAvail = CompleteProgress,
            ![t].copyLimit    = CompleteProgress,
            ![t].sizeAtEntry  = fileSize,
            ![t].publishedEOF = ZeroProgress,
            ![t].phase        = "NeedCopy"]
    /\ UNCHANGED <<sharedOffset, offsetOwner, fileSize, adapterProfile,
                    effectLog, commitLog>>

(***************************************************************************)
(* Fallible VM copy and tuple-error conversion                              *)
(***************************************************************************)

VmoRead(t, progress) ==
    \* Vmo::read clips to VMO capacity, then each page copy is fallible.
    \* kernel/core/src/vm/page_cache/vmo/mod.rs:533-566
    /\ opState[t].phase = "NeedCopy"
    /\ IsRead(opState[t].kind)
    /\ progress \in ProgressClasses
    /\ Units(progress) <= Units(opState[t].copyLimit)
    \* read_fallible advances both cursors before returning (error, copied).
    \* ostd/src/mm/io/mod.rs:332-361
    /\ LET amount  == Units(progress)
           faulted == amount < Units(opState[t].copyLimit)
       IN
       /\ opState' = [opState EXCEPT
            ![t].entryCopied       = amount,
            ![t].copied            = @ + amount,
            ![t].committed         = @ + amount,
            ![t].lastFaultProgress = IF faulted THEN progress ELSE NoProgress,
            ![t].readPastEOF       = @ \/ amount > Units(opState[t].logicalAvail),
            ![t].phase             = IF faulted
                                     THEN "NeedTupleConversion"
                                     ELSE "NeedFileOpsReturn"]
       /\ effectLog' = IF amount > 0
                       THEN Append(effectLog, EffectRecord(t, amount))
                       ELSE effectLog
    /\ UNCHANGED <<sharedOffset, offsetOwner, fileSize, cacheCapacity,
                    adapterProfile, commitLog>>

VmoWrite(t, progress) ==
    \* Anonymous writes propagate the tuple with ?, while backed writes may
    \* dirty a positive prefix before returning only the error.
    \* kernel/core/src/vm/page_cache/vmo/mod.rs:569-640,667-699,734-750
    /\ opState[t].phase = "NeedCopy"
    /\ IsWrite(opState[t].kind)
    /\ progress \in ProgressClasses
    /\ Units(progress) <= Units(opState[t].copyLimit)
    \* write_fallible delegates to read_fallible and preserves its count.
    \* ostd/src/mm/io/mod.rs:367-375
    /\ LET amount  == Units(progress)
           faulted == amount < Units(opState[t].copyLimit)
       IN
       /\ opState' = [opState EXCEPT
            ![t].entryCopied       = amount,
            ![t].copied            = @ + amount,
            ![t].committed         = @ + amount,
            ![t].lastFaultProgress = IF faulted THEN progress ELSE NoProgress,
            ![t].phase             = IF faulted
                                     THEN "NeedTupleConversion"
                                     ELSE "NeedFileOpsReturn"]
       /\ effectLog' = IF amount > 0
                       THEN Append(effectLog, EffectRecord(t, amount))
                       ELSE effectLog
    /\ UNCHANGED <<sharedOffset, offsetOwner, fileSize, cacheCapacity,
                    adapterProfile, commitLog>>

ErrorFromTuple(t) ==
    \* Both tuple conversions discard the positive copied count.
    \* kernel/core/src/error.rs:209-219
    /\ opState[t].phase = "NeedTupleConversion"
    /\ opState[t].lastFaultProgress \in ProgressClasses
    /\ opState' = [opState EXCEPT
        ![t].entryStatus = "EFAULT",
        ![t].phase       = "NeedHandleReturn"]
    /\ UNCHANGED <<sharedOffset, offsetOwner, fileSize, cacheCapacity,
                    adapterProfile, effectLog, commitLog>>

(***************************************************************************)
(* Filesystem return values                                                  *)
(***************************************************************************)

FileOpsReadReturn(t) ==
    \* RamFS/exFAT return their separately computed logical length; correct
    \* adapters return the same limited length copied by the VMO.
    \* kernel/core/src/fs/fs_impls/ramfs/fs.rs:701-718
    \* kernel/core/src/fs/fs_impls/exfat/inode.rs:648-657
    \* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:234-242
    /\ opState[t].phase = "NeedFileOpsReturn"
    /\ IsRead(opState[t].kind)
    /\ opState' = [opState EXCEPT
        ![t].entryReturned = Units(opState[t].logicalAvail),
        ![t].entryStatus   = "Ok",
        ![t].phase         = "NeedHandleReturn"]
    /\ UNCHANGED <<sharedOffset, offsetOwner, fileSize, cacheCapacity,
                    adapterProfile, effectLog, commitLog>>

FileOpsWriteReturn(t) ==
    \* Successful adapters return the requested write length.
    \* kernel/core/src/fs/fs_impls/ramfs/fs.rs:747-756
    \* kernel/core/src/fs/fs_impls/exfat/inode.rs:734-755
    \* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:262-271
    /\ opState[t].phase = "NeedFileOpsReturn"
    /\ IsWrite(opState[t].kind)
    /\ LET requestedEnd == opState[t].entryStart + RequestUnits
           expands      == requestedEnd > opState[t].sizeAtEntry
       IN
       /\ fileSize' = IF adapterProfile = RamFsAdapter
                      THEN fileSize
                      ELSE NatMax(fileSize, requestedEnd)
       /\ opState' = [opState EXCEPT
            ![t].entryReturned = RequestUnits,
            ![t].entryStatus   = "Ok",
            ![t].publishedEOF  = IF expands THEN CompleteProgress ELSE ZeroProgress,
            ![t].phase         = "NeedHandleReturn"]
    /\ UNCHANGED <<sharedOffset, offsetOwner, cacheCapacity,
                    adapterProfile, effectLog, commitLog>>

(***************************************************************************)
(* InodeHandle return, offset commit, and unlock                            *)
(***************************************************************************)

InodeHandleCommitOffset(t) ==
    \* read()/write() update the offset only after Ok(len).
    \* kernel/core/src/fs/file/inode_handle.rs:285-290,308-320
    /\ opState[t].phase = "NeedHandleReturn"
    /\ opState[t].usesSharedOffset
    /\ opState[t].entryStatus = "Ok"
    /\ offsetOwner = t
    /\ LET amount == opState[t].entryReturned
       IN
       /\ sharedOffset' = sharedOffset + amount
       /\ opState' = [opState EXCEPT
            ![t].offsetAdvanced = @ + amount,
            ![t].phase          = "NeedOffsetRelease"]
       /\ commitLog' = IF amount > 0
                       THEN Append(commitLog, CommitRecord(t, amount))
                       ELSE commitLog
    /\ UNCHANGED <<offsetOwner, fileSize, cacheCapacity,
                    adapterProfile, effectLog>>

InodeHandlePropagateError(t) ==
    \* The ? operator returns the FileOps error before offset advancement.
    \* kernel/core/src/fs/file/inode_handle.rs:287-290,317-320
    /\ opState[t].phase = "NeedHandleReturn"
    /\ opState[t].usesSharedOffset
    /\ opState[t].entryStatus \in {"EFAULT", "EINTR"}
    /\ offsetOwner = t
    /\ opState' = [opState EXCEPT ![t].phase = "NeedOffsetRelease"]
    /\ UNCHANGED <<sharedOffset, offsetOwner, fileSize, cacheCapacity,
                    adapterProfile, effectLog, commitLog>>

InodeHandlePositionalReturn(t) ==
    \* read_at()/write_at() return directly and never touch the shared offset.
    \* kernel/core/src/fs/file/inode_handle.rs:323-354
    /\ opState[t].phase = "NeedHandleReturn"
    /\ ~opState[t].usesSharedOffset
    /\ opState' = [opState EXCEPT ![t].phase = "NeedSyscallFinish"]
    /\ UNCHANGED <<sharedOffset, offsetOwner, fileSize, cacheCapacity,
                    adapterProfile, effectLog, commitLog>>

InodeHandleReleaseOffset(t) ==
    \* The local MutexGuard is dropped when read()/write() returns. Each vector
    \* loop iteration therefore exposes an unlocked boundary.
    \* kernel/core/src/fs/file/inode_handle.rs:285-290,308-320
    \* kernel/core/src/syscall/preadv.rs:156-174
    \* kernel/core/src/syscall/pwritev.rs:152-170
    /\ opState[t].phase = "NeedOffsetRelease"
    /\ offsetOwner = t
    /\ offsetOwner' = NoThread
    /\ opState' = [opState EXCEPT
        ![t].phase = IF IsVector(opState[t].kind)
                     THEN "NeedVectorDispatch"
                     ELSE "NeedSyscallFinish"]
    /\ UNCHANGED <<sharedOffset, fileSize, cacheCapacity, adapterProfile,
                    effectLog, commitLog>>

(***************************************************************************)
(* Per-iovec caller dispatch                                                 *)
(***************************************************************************)

DoSysReadvHandleEntry(t) ==
    \* Ok(read_len) is added to total_len; exhausting the writer continues
    \* even when an unbounded adapter returns a shorter logical length.
    \* kernel/core/src/syscall/preadv.rs:165-173
    /\ opState[t].phase = "NeedVectorDispatch"
    /\ opState[t].kind = ReadvKind
    /\ LET ok        == opState[t].entryStatus = "Ok"
           nextTotal == opState[t].reported + IF ok THEN opState[t].entryReturned ELSE 0
           continue  == /\ ok
                        /\ opState[t].entryCopied = RequestUnits
                        /\ opState[t].iovIndex < IovCount
       IN
       \* Err after prior total progress is suppressed; otherwise it propagates.
       \* kernel/core/src/syscall/preadv.rs:165-169
       /\ opState' = [opState EXCEPT
            ![t].reported      = nextTotal,
            ![t].iovIndex      = IF continue THEN @ + 1 ELSE @,
            ![t].entryStart    = IF continue THEN 0 ELSE @,
            ![t].logicalAvail  = IF continue THEN ZeroProgress ELSE @,
            ![t].copyLimit     = IF continue THEN ZeroProgress ELSE @,
            ![t].entryCopied   = IF continue THEN 0 ELSE @,
            ![t].entryReturned = IF continue THEN 0 ELSE @,
            ![t].entryStatus   = IF continue THEN "None" ELSE @,
            ![t].lastFaultProgress = IF continue THEN NoProgress ELSE @,
            ![t].publishedEOF  = IF continue THEN ZeroProgress ELSE @,
            ![t].sizeAtEntry   = IF continue THEN 0 ELSE @,
            ![t].phase         = IF continue
                                  THEN "NeedOffsetStart"
                                  ELSE "NeedSyscallFinish"]
    /\ UNCHANGED <<sharedOffset, offsetOwner, fileSize, cacheCapacity,
                    adapterProfile, effectLog, commitLog>>

DoSysWritevHandleEntry(t) ==
    \* Ok(write_len) is added to total_len; a full first iovec continues.
    \* kernel/core/src/syscall/pwritev.rs:161-169
    /\ opState[t].phase = "NeedVectorDispatch"
    /\ opState[t].kind = WritevKind
    /\ LET ok        == opState[t].entryStatus = "Ok"
           nextTotal == opState[t].reported + IF ok THEN opState[t].entryReturned ELSE 0
           continue  == /\ ok
                        /\ opState[t].entryReturned = RequestUnits
                        /\ opState[t].iovIndex < IovCount
       IN
       \* Err after prior total progress is suppressed; otherwise it propagates.
       \* kernel/core/src/syscall/pwritev.rs:161-165
       /\ opState' = [opState EXCEPT
            ![t].reported      = nextTotal,
            ![t].iovIndex      = IF continue THEN @ + 1 ELSE @,
            ![t].entryStart    = IF continue THEN 0 ELSE @,
            ![t].logicalAvail  = IF continue THEN ZeroProgress ELSE @,
            ![t].copyLimit     = IF continue THEN ZeroProgress ELSE @,
            ![t].entryCopied   = IF continue THEN 0 ELSE @,
            ![t].entryReturned = IF continue THEN 0 ELSE @,
            ![t].entryStatus   = IF continue THEN "None" ELSE @,
            ![t].lastFaultProgress = IF continue THEN NoProgress ELSE @,
            ![t].publishedEOF  = IF continue THEN ZeroProgress ELSE @,
            ![t].sizeAtEntry   = IF continue THEN 0 ELSE @,
            ![t].phase         = IF continue
                                  THEN "NeedOffsetStart"
                                  ELSE "NeedSyscallFinish"]
    /\ UNCHANGED <<sharedOffset, offsetOwner, fileSize, cacheCapacity,
                    adapterProfile, effectLog, commitLog>>

(***************************************************************************)
(* Syscall result and signal/restart handling                               *)
(***************************************************************************)

SysReadFinish(t) ==
    \* Scalar read maps EINTR to ERESTARTSYS, otherwise preserving the error.
    \* kernel/core/src/syscall/read.rs:27-44
    /\ opState[t].phase = "NeedSyscallFinish"
    /\ opState[t].kind = ReadKind
    /\ LET status == opState[t].entryStatus
       IN opState' = [opState EXCEPT
            ![t].reported = IF status = "Ok" THEN opState[t].entryReturned ELSE 0,
            ![t].result   = CASE status = "Ok"    -> "Ok"
                                  [] status = "EINTR" -> "ERESTARTSYS"
                                  [] OTHER            -> "EFAULT",
            ![t].phase    = "NeedSignal"]
    /\ UNCHANGED <<sharedOffset, offsetOwner, fileSize, cacheCapacity,
                    adapterProfile, effectLog, commitLog>>

SysWriteFinish(t) ==
    \* Scalar write has the same EINTR-to-ERESTARTSYS translation.
    \* kernel/core/src/syscall/write.rs:27-44
    /\ opState[t].phase = "NeedSyscallFinish"
    /\ opState[t].kind = WriteKind
    /\ LET status == opState[t].entryStatus
       IN opState' = [opState EXCEPT
            ![t].reported = IF status = "Ok" THEN opState[t].entryReturned ELSE 0,
            ![t].result   = CASE status = "Ok"    -> "Ok"
                                  [] status = "EINTR" -> "ERESTARTSYS"
                                  [] OTHER            -> "EFAULT",
            ![t].phase    = "NeedSignal"]
    /\ UNCHANGED <<sharedOffset, offsetOwner, fileSize, cacheCapacity,
                    adapterProfile, effectLog, commitLog>>

SysPread64Finish(t) ==
    \* pread64 returns read_at's result without touching the shared offset.
    \* kernel/core/src/syscall/pread64.rs:33-43
    /\ opState[t].phase = "NeedSyscallFinish"
    /\ opState[t].kind = PreadKind
    /\ LET status == opState[t].entryStatus
       IN opState' = [opState EXCEPT
            ![t].reported = IF status = "Ok" THEN opState[t].entryReturned ELSE 0,
            ![t].result   = IF status = "Ok" THEN "Ok" ELSE status,
            ![t].phase    = "NeedSignal"]
    /\ UNCHANGED <<sharedOffset, offsetOwner, fileSize, cacheCapacity,
                    adapterProfile, effectLog, commitLog>>

SysPwrite64Finish(t) ==
    \* pwrite64 returns write_at's result without shared-offset accounting.
    \* kernel/core/src/syscall/pwrite64.rs:33-41
    /\ opState[t].phase = "NeedSyscallFinish"
    /\ opState[t].kind = PwriteKind
    /\ LET status == opState[t].entryStatus
       IN opState' = [opState EXCEPT
            ![t].reported = IF status = "Ok" THEN opState[t].entryReturned ELSE 0,
            ![t].result   = IF status = "Ok" THEN "Ok" ELSE status,
            ![t].phase    = "NeedSignal"]
    /\ UNCHANGED <<sharedOffset, offsetOwner, fileSize, cacheCapacity,
                    adapterProfile, effectLog, commitLog>>

SysReadvFinish(t) ==
    \* readv returns prior total progress when a later entry fails.
    \* kernel/core/src/syscall/preadv.rs:165-180
    /\ opState[t].phase = "NeedSyscallFinish"
    /\ opState[t].kind = ReadvKind
    /\ LET success == opState[t].entryStatus = "Ok" \/ opState[t].reported > 0
       IN opState' = [opState EXCEPT
            ![t].result = IF success THEN "Ok" ELSE opState[t].entryStatus,
            ![t].phase  = "NeedSignal"]
    /\ UNCHANGED <<sharedOffset, offsetOwner, fileSize, cacheCapacity,
                    adapterProfile, effectLog, commitLog>>

SysWritevFinish(t) ==
    \* writev likewise returns prior total progress after a later error.
    \* kernel/core/src/syscall/pwritev.rs:161-175
    /\ opState[t].phase = "NeedSyscallFinish"
    /\ opState[t].kind = WritevKind
    /\ LET success == opState[t].entryStatus = "Ok" \/ opState[t].reported > 0
       IN opState' = [opState EXCEPT
            ![t].result = IF success THEN "Ok" ELSE opState[t].entryStatus,
            ![t].phase  = "NeedSignal"]
    /\ UNCHANGED <<sharedOffset, offsetOwner, fileSize, cacheCapacity,
                    adapterProfile, effectLog, commitLog>>

HandlePendingSignal(t) ==
    \* ERESTARTSYS is first converted to EINTR; only a dequeued user signal
    \* with SA_RESTART rewinds the syscall instruction.
    \* kernel/core/src/process/signal/mod.rs:48-62,70-86,125-158
    /\ opState[t].phase = "NeedSignal"
    /\ LET restartable == /\ opState[t].result = "ERESTARTSYS"
                           /\ opState[t].signalPending
                           /\ opState[t].saRestart
       IN opState' = [opState EXCEPT
            ![t].result         = IF opState[t].result = "ERESTARTSYS"
                                   THEN "EINTR"
                                   ELSE @,
            ![t].restartPending = restartable,
            ![t].signalPending  = FALSE,
            ![t].phase          = IF restartable THEN "NeedRestart" ELSE "Done"]
    /\ UNCHANGED <<sharedOffset, offsetOwner, fileSize, cacheCapacity,
                    adapterProfile, effectLog, commitLog>>

RestartSyscall(t) ==
    \* Rewinding re-enters the original syscall with the same arguments.
    \* kernel/core/src/process/signal/mod.rs:145-158
    /\ opState[t].phase = "NeedRestart"
    /\ opState[t].restartPending
    \* No committed-progress guard is added here: the implementation gates
    \* only on ERESTARTSYS and SA_RESTART. RestartNoReplay checks the contract.
    \* kernel/core/src/process/signal/mod.rs:145-158
    /\ opState' = [opState EXCEPT
        ![t].phase             = StartPhase(opState[t].kind),
        ![t].entryStart        = 0,
        ![t].logicalAvail      = ZeroProgress,
        ![t].copyLimit         = ZeroProgress,
        ![t].iovIndex          = 1,
        ![t].entryCopied       = 0,
        ![t].entryReturned     = 0,
        ![t].reported          = 0,
        ![t].entryStatus       = "None",
        ![t].result            = "Pending",
        ![t].lastFaultProgress = NoProgress,
        ![t].publishedEOF      = ZeroProgress,
        ![t].sizeAtEntry       = 0,
        ![t].attemptId         = @ + 1,
        ![t].restartPending    = FALSE]
    /\ UNCHANGED <<sharedOffset, offsetOwner, fileSize, cacheCapacity,
                    adapterProfile, effectLog, commitLog>>

(***************************************************************************)
(* Next                                                                     *)
(***************************************************************************)

Next ==
    \/ \E t \in Thread, sig \in BOOLEAN, restart \in BOOLEAN :
        SysReadBegin(t, sig, restart)
    \/ \E t \in Thread, sig \in BOOLEAN, restart \in BOOLEAN :
        SysWriteBegin(t, sig, restart)
    \/ \E t \in Thread, e \in ExplicitOffsets,
          sig \in BOOLEAN, restart \in BOOLEAN :
        SysPread64Begin(t, e, sig, restart)
    \/ \E t \in Thread, e \in ExplicitOffsets,
          sig \in BOOLEAN, restart \in BOOLEAN :
        SysPwrite64Begin(t, e, sig, restart)
    \/ \E t \in Thread, sig \in BOOLEAN, restart \in BOOLEAN :
        DoSysReadvBegin(t, sig, restart)
    \/ \E t \in Thread, sig \in BOOLEAN, restart \in BOOLEAN :
        DoSysWritevBegin(t, sig, restart)
    \/ \E t \in Thread : InodeHandleReadAcquireOffset(t)
    \/ \E t \in Thread : InodeHandleWriteAcquireOffset(t)
    \/ \E t \in Thread : InodeHandleReadAtStart(t)
    \/ \E t \in Thread : InodeHandleWriteAtStart(t)
    \/ \E t \in Thread : Ext2VirtioFsReadComputeLimit(t)
    \/ \E t \in Thread : RamFsExfatReadComputeLimit(t)
    \/ \E t \in Thread : RamFsWritePublishRequestedEnd(t)
    \/ \E t \in Thread : DeferredWritePrepare(t)
    \/ \E t \in Thread, p \in ProgressClasses : VmoRead(t, p)
    \/ \E t \in Thread, p \in ProgressClasses : VmoWrite(t, p)
    \/ \E t \in Thread : ErrorFromTuple(t)
    \/ \E t \in Thread : FileOpsReadReturn(t)
    \/ \E t \in Thread : FileOpsWriteReturn(t)
    \/ \E t \in Thread : InodeHandleCommitOffset(t)
    \/ \E t \in Thread : InodeHandlePropagateError(t)
    \/ \E t \in Thread : InodeHandlePositionalReturn(t)
    \/ \E t \in Thread : InodeHandleReleaseOffset(t)
    \/ \E t \in Thread : DoSysReadvHandleEntry(t)
    \/ \E t \in Thread : DoSysWritevHandleEntry(t)
    \/ \E t \in Thread : SysReadFinish(t)
    \/ \E t \in Thread : SysWriteFinish(t)
    \/ \E t \in Thread : SysPread64Finish(t)
    \/ \E t \in Thread : SysPwrite64Finish(t)
    \/ \E t \in Thread : SysReadvFinish(t)
    \/ \E t \in Thread : SysWritevFinish(t)
    \/ \E t \in Thread : HandlePendingSignal(t)
    \/ \E t \in Thread : RestartSyscall(t)

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* Structural invariants                                                    *)
(***************************************************************************)

OpStateType == [
    phase             : PhaseSet,
    kind              : OpKinds \cup {"None"},
    usesSharedOffset  : BOOLEAN,
    explicitOffset    : Nat,
    entryStart        : Nat,
    logicalAvail      : ProgressClasses,
    copyLimit         : ProgressClasses,
    iovIndex          : 1..IovCount,
    requested         : Nat,
    entryCopied       : 0..RequestUnits,
    entryReturned     : 0..RequestUnits,
    copied            : Nat,
    committed         : Nat,
    reported          : Nat,
    offsetAdvanced    : Nat,
    entryStatus       : EntryStatusSet,
    result            : ResultSet,
    lastFaultProgress : ProgressClasses \cup {NoProgress},
    publishedEOF      : ProgressClasses,
    readPastEOF       : BOOLEAN,
    sizeAtEntry       : Nat,
    syscallId         : Nat,
    attemptId         : Nat,
    restartPending    : BOOLEAN,
    signalPending     : BOOLEAN,
    saRestart         : BOOLEAN
]

EffectRecordType == [
    tid       : Thread,
    syscallId : Nat,
    attemptId : Nat,
    iov       : 1..IovCount,
    kind      : OpKinds,
    start     : Nat,
    amount    : 1..RequestUnits
]

CommitRecordType == [
    tid       : Thread,
    syscallId : Nat,
    attemptId : Nat,
    iov       : 1..IovCount,
    kind      : SharedKinds,
    start     : Nat,
    amount    : 1..RequestUnits
]

TypeOK ==
    /\ sharedOffset \in Nat
    /\ offsetOwner \in Thread \cup {NoThread}
    /\ fileSize \in Nat
    /\ cacheCapacity \in Nat
    /\ adapterProfile \in AdapterProfiles
    /\ opState \in [Thread -> OpStateType]
    /\ effectLog \in Seq(EffectRecordType)
    /\ commitLog \in Seq(CommitRecordType)

OffsetOwnerWellFormed ==
    \/ offsetOwner = NoThread
    \/ /\ offsetOwner \in Thread
       /\ opState[offsetOwner].usesSharedOffset
       /\ opState[offsetOwner].phase \in {
            "NeedAdapter", "NeedCopy", "NeedTupleConversion",
            "NeedFileOpsReturn", "NeedHandleReturn", "NeedOffsetRelease"
          }

ProgressWithinRequest ==
    \A t \in Thread :
        /\ opState[t].copied <= opState[t].requested
        /\ opState[t].committed <= opState[t].requested
        /\ opState[t].reported <= opState[t].requested
        /\ opState[t].offsetAdvanced <= opState[t].requested

CacheCoversFile == fileSize <= cacheCapacity

CommitLogWellFormed ==
    \A i \in DOMAIN commitLog :
        /\ commitLog[i].kind \in SharedKinds
        /\ commitLog[i].amount > 0

\* A finite smoke-check constraint for base.cfg only. The base transition
\* relation itself remains unbounded; MC.tla supplies action counters.
BaseStateConstraint ==
    /\ \A t \in Thread : opState[t].syscallId <= 1
    /\ Len(effectLog) <= 2 * Cardinality(Thread) * IovCount
    /\ Len(commitLog) <= 2 * Cardinality(Thread) * IovCount

(***************************************************************************)
(* Scenario safety invariants                                               *)
(***************************************************************************)

\* S1/S2: every visible read-side copy must be represented by the result.
ReadReturnCoversCopies ==
    \A t \in Thread :
        /\ opState[t].phase = "Done"
        /\ IsRead(opState[t].kind)
        => IF opState[t].result = "Ok"
           THEN opState[t].reported = opState[t].committed
           ELSE opState[t].committed = 0

\* S1/S2: every visible file-data prefix must be represented by the result.
WriteReturnCoversCommit ==
    \A t \in Thread :
        /\ opState[t].phase = "Done"
        /\ IsWrite(opState[t].kind)
        => IF opState[t].result = "Ok"
           THEN opState[t].reported = opState[t].committed
           ELSE opState[t].committed = 0

\* S2: a filesystem EOF limit bounds all user-memory effects.
NoReadPastEOF ==
    \A t \in Thread : ~opState[t].readPastEOF

\* S2: a zero/prefix copy fault cannot leave a full-request EOF publication.
NoNominalEOFOnFault ==
    \A t \in Thread :
        /\ opState[t].phase = "Done"
        /\ IsWrite(opState[t].kind)
        /\ opState[t].lastFaultProgress \in {ZeroProgress, PrefixProgress}
        => opState[t].publishedEOF # CompleteProgress

\* S1/S3: a shared operation advances the offset by exactly its return value.
SharedOffsetTracksReport ==
    \A t \in Thread :
        /\ opState[t].phase = "Done"
        /\ opState[t].usesSharedOffset
        => opState[t].offsetAdvanced = opState[t].reported

SameVectorOperation(a, b) ==
    /\ a.kind \in VectorKinds
    /\ a.tid = b.tid
    /\ a.syscallId = b.syscallId
    /\ a.attemptId = b.attemptId

\* S3: no competing shared-offset commit may appear between two entries of
\* one vector syscall attempt.
VectorSingleLinearization ==
    \A i, j \in DOMAIN commitLog :
        /\ i < j
        /\ SameVectorOperation(commitLog[i], commitLog[j])
        => \A k \in (i + 1)..(j - 1) :
               SameVectorOperation(commitLog[i], commitLog[k])

\* S4: positional operations never account any shared-offset advancement.
PositionalOffsetIsolation ==
    \A t \in Thread :
        ~opState[t].usesSharedOffset => opState[t].offsetAdvanced = 0

SameLogicalIov(a, b) ==
    /\ a.tid = b.tid
    /\ a.syscallId = b.syscallId
    /\ a.iov = b.iov

\* S1: restart is never armed after an effect, and a restarted syscall never
\* produces the same logical iovec effect twice.
RestartNoReplay ==
    /\ \A t \in Thread :
        opState[t].restartPending => opState[t].committed = 0
    /\ \A i, j \in DOMAIN effectLog :
        i # j => ~SameLogicalIov(effectLog[i], effectLog[j])

====
