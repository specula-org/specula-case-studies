------------------------------ MODULE base ------------------------------
EXTENDS Integers, Sequences, FiniteSets, TLC

\* Category B model for regular-file I/O through one shared open-file
\* description.  One abstract unit denotes a positive prefix and two units
\* denote completion.  These are progress classes, not byte/page counts.

CONSTANTS
    Threads,
    MaxAttempts,
    MaxOffset,
    VectorLength,
    InitialFileSize,
    EnableReferenceInterruptible

ASSUME /\ Threads # {}
       /\ MaxAttempts \in Nat
       /\ MaxAttempts > 0
       /\ MaxOffset \in Nat
       /\ VectorLength = 2
       /\ InitialFileSize \in Nat
       /\ EnableReferenceInterruptible \in BOOLEAN

NoThread == "NoThread"
NoOp == "NoOp"

Zero == "Zero"
Positive == "Positive"
Complete == "Complete"
Progress == {Zero, Positive, Complete}

SharedRead == "SharedRead"
SharedWrite == "SharedWrite"
VectorRead == "VectorRead"
VectorWrite == "VectorWrite"
PositionalRead == "PositionalRead"
PositionalWrite == "PositionalWrite"
OpKinds == {NoOp, SharedRead, SharedWrite, VectorRead, VectorWrite,
            PositionalRead, PositionalWrite}
SharedKinds == {SharedRead, SharedWrite, VectorRead, VectorWrite}
VectorKinds == {VectorRead, VectorWrite}
ReadKinds == {SharedRead, VectorRead, PositionalRead}
WriteKinds == {SharedWrite, VectorWrite, PositionalWrite}

Ext2Buffered == "Ext2Buffered"
Ext2Direct == "Ext2Direct"
Ramfs == "Ramfs"
BackendModes == {Ext2Buffered, Ext2Direct, Ramfs}

UpToDate == "UpToDate"
Uninit == "Uninit"
PageStates == {UpToDate, Uninit}
InPlace == "InPlace"
Extending == "Extending"
RangeClasses == {InPlace, Extending}

NoEntryResult == "NoEntryResult"
EntryOk == "EntryOk"
EntryFault == "EntryFault"
EntryEintr == "EntryEintr"
EntryRestartSys == "EntryRestartSys"
EntryResults == {NoEntryResult, EntryOk, EntryFault, EntryEintr,
                 EntryRestartSys}

NoResult == "NoResult"
Pending == "Pending"
Success == "Success"
ShortSuccess == "ShortSuccess"
Fault == "Fault"
Interrupted == "Interrupted"
Restarted == "Restarted"
Results == {NoResult, Pending, Success, ShortSuccess, Fault, Interrupted,
            Restarted}

PCStates == {
    "Idle", "AcquireOffset", "BeginPositional", "ChooseAppendStart",
    "AcquireData",
    "SnapshotSize", "PrepareWrite", "CopyRead", "CopyWrite",
    "DirectCopy", "DirectSubmit", "DirectWait", "DirectMetadata",
    "DirectRollback", "BackendFinish", "ReleaseData", "InodeReturn",
    "SyscallDispatch",
    "VectorDispatch", "SignalClassify", "SignalDeliver", "RestartReady"
}

Min(a, b) == IF a <= b THEN a ELSE b
Max(a, b) == IF a >= b THEN a ELSE b

ProgressUnits(p) ==
    CASE p = Zero     -> 0
      [] p = Positive -> 1
      [] p = Complete -> 2

ProgressOf(n) == IF n = 0 THEN Zero ELSE IF n = 1 THEN Positive ELSE Complete

IsRead(k) == k \in ReadKinds
IsWrite(k) == k \in WriteKinds
IsShared(k) == k \in SharedKinds
IsVector(k) == k \in VectorKinds
IsPositional(k) == k \in {PositionalRead, PositionalWrite}

EffectDomain ==
    {<<t, e, part>> :
        t \in Threads,
        e \in 1..MaxAttempts,
        part \in 0..(VectorLength * VectorLength)}

MaxTrackedUnits ==
    InitialFileSize + MaxOffset
    + ProgressUnits(Complete) * VectorLength * MaxAttempts * Cardinality(Threads)

BioDomain ==
    {<<t, attempt, effect, entry, segment, rangeStart>> :
        t \in Threads,
        attempt \in 1..MaxAttempts,
        effect \in 1..MaxAttempts,
        entry \in 0..VectorLength,
        segment \in 1..VectorLength,
        rangeStart \in 0..(MaxTrackedUnits + VectorLength)}

VARIABLES
    pc,
    opKind,
    backendMode,
    requested,
    copied,
    committed,
    reported,
    copiedTotal,
    committedTotal,
    visibleTotal,
    reportedTotal,
    result,
    entryResult,
    copyFault,
    ofdOffset,
    expectedOffset,
    offsetOwner,
    dataOwner,
    ioOffset,
    explicitOffset,
    appendMode,
    fileSize,
    expectedFileSize,
    oldFileSize,
    plannedEnd,
    sizePublicationOwners,
    pageState,
    rangeClass,
    fileSizeSnapshot,
    dataEpoch,
    entryDataEpoch,
    bufferEpochs,
    vectorIndex,
    vectorIntervened,
    attemptId,
    effectToken,
    directPart,
    pendingBios,
    completedBios,
    commitCount,
    saRestart,
    restartPending,
    interruptibleBackend,
    positionalOFDExpected

vars == <<
    pc, opKind, backendMode, requested, copied, committed, reported,
    copiedTotal, committedTotal, visibleTotal, reportedTotal, result,
    entryResult, copyFault, ofdOffset, expectedOffset, offsetOwner, dataOwner,
    ioOffset,
    explicitOffset, appendMode, fileSize, expectedFileSize, oldFileSize,
    plannedEnd, sizePublicationOwners, pageState, rangeClass,
    fileSizeSnapshot, dataEpoch, entryDataEpoch, bufferEpochs, vectorIndex,
    vectorIntervened, attemptId, effectToken, directPart, pendingBios,
    completedBios, commitCount, saRestart, restartPending,
    interruptibleBackend, positionalOFDExpected
>>

ThreadVars == <<
    pc, opKind, backendMode, requested, copied, committed, reported,
    copiedTotal, committedTotal, visibleTotal, reportedTotal, result,
    entryResult, copyFault, ioOffset, explicitOffset, appendMode, oldFileSize,
    plannedEnd, pageState, rangeClass, fileSizeSnapshot, entryDataEpoch,
    bufferEpochs, vectorIndex, vectorIntervened, attemptId, effectToken,
    directPart, saRestart, restartPending, interruptibleBackend
>>

FileVars == <<ofdOffset, expectedOffset, offsetOwner, dataOwner, fileSize,
              expectedFileSize, sizePublicationOwners, dataEpoch,
              pendingBios, completedBios, commitCount, positionalOFDExpected>>

EffectKey(t, part) == <<t, effectToken[t], part>>
DirectEffectPart(entry, segment) ==
    IF entry = 0 THEN segment ELSE (entry - 1) * VectorLength + segment
BioKey(t, segment) ==
    <<t, attemptId[t], effectToken[t],
      IF IsVector(opKind[t]) THEN vectorIndex[t] ELSE 0,
      segment, ioOffset[t] + segment - 1>>
BioEffect(bio) == <<bio[1], bio[3], DirectEffectPart(bio[4], bio[5])>>
BioAttempt(bio) == <<bio[1], bio[2]>>
BioRangeStart(bio) == bio[6] - (bio[5] - 1)
BioAtSegment(bio, segment) ==
    <<bio[1], bio[2], bio[3], bio[4], segment,
      BioRangeStart(bio) + segment - 1>>

CurrentPart(t) == IF IsVector(opKind[t]) THEN vectorIndex[t] ELSE 0

AttemptBios(t) ==
    {bio \in pendingBios : bio[1] = t /\ bio[2] = attemptId[t]}

ActiveAttempts ==
    LET activeThreads == {t \in Threads : pc[t] # "Idle"}
    IN {<<t, attemptId[t]>> : t \in activeThreads}

LogicalReadUnits(t) ==
    Min(ProgressUnits(requested[t]),
        IF fileSize > ioOffset[t] THEN fileSize - ioOffset[t] ELSE 0)

\* ramfs computes read_len from EOF but does not limit the VmWriter passed to
\* the page cache.  ext2 limits the writer before VMO copy.
\* kernel/core/src/fs/fs_impls/ramfs/fs.rs:701-710
\* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:234-242
ReadCopyTargetUnits(t) ==
    IF backendMode[t] = Ramfs
    THEN ProgressUnits(requested[t])
    ELSE LogicalReadUnits(t)

\* A successful ramfs VMO read is bounded by page-cache capacity, not the
\* logical EOF snapshot.  Capacity is page-aligned and intentionally omitted
\* from this zero/positive/complete abstraction, so retain every class between
\* the logical bytes available at copy time and the caller's request.
\* kernel/core/src/vm/page_cache/vmo/mod.rs:533-566
\* kernel/core/src/vm/page_cache/mod.rs:181-186
ReadCopyCompleteClasses(t) ==
    IF backendMode[t] = Ramfs
    THEN {p \in Progress :
            /\ LogicalReadUnits(t) <= ProgressUnits(p)
            /\ ProgressUnits(p) <= ProgressUnits(requested[t])}
    ELSE {ProgressOf(LogicalReadUnits(t))}

SpeculativeEnds ==
    {expectedFileSize} \cup {plannedEnd[t] : t \in sizePublicationOwners}

AllowedFileSize ==
    CHOOSE candidate \in SpeculativeEnds :
        \A other \in SpeculativeEnds : other <= candidate

\* A shared-offset conflict can occur only after one scalar call releases the
\* OFD lock and before the next entry reacquires it.
\* kernel/core/src/syscall/preadv.rs:152-174
\* kernel/core/src/syscall/pwritev.rs:148-170
\* kernel/core/src/fs/file/inode_handle.rs:285-290,308-320
VectorOffsetGap(t) ==
    /\ IsVector(opKind[t])
    /\ pc[t] # "Idle"
    /\ ((pc[t] = "VectorDispatch"
            /\ vectorIndex[t] < VectorLength
            /\ entryResult[t] = EntryOk
            /\ ProgressUnits(reported[t]) = ProgressUnits(requested[t]))
        \/ (pc[t] = "AcquireOffset" /\ vectorIndex[t] > 1
            /\ offsetOwner # t))

\* A data conflict starts when the current entry drops its backend guard and
\* remains possible through OFD reacquisition, EOF snapshot, and acquisition of
\* the next entry's backend guard.  Positional writes can run while a vector
\* still owns the OFD lock.
\* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:31-35,49-52,69-74,93-96
\* kernel/core/src/fs/fs_impls/ramfs/fs.rs:701-710,727-756
\* kernel/core/src/syscall/preadv.rs:152-174
\* kernel/core/src/syscall/pwritev.rs:148-170
VectorDataGap(t) ==
    /\ IsVector(opKind[t])
    /\ pc[t] # "Idle"
    /\ ((pc[t] = "InodeReturn"
            /\ dataOwner # t
            /\ vectorIndex[t] < VectorLength
            /\ entryResult[t] = EntryOk
            /\ ProgressUnits(reported[t]) = ProgressUnits(requested[t]))
        \/ (pc[t] = "VectorDispatch"
            /\ vectorIndex[t] < VectorLength
            /\ entryResult[t] = EntryOk
            /\ ProgressUnits(reported[t]) = ProgressUnits(requested[t]))
        \/ (vectorIndex[t] > 1
            /\ pc[t] \in {"AcquireOffset", "SnapshotSize", "AcquireData"}
            /\ dataOwner # t))
\* Derive the beginning of the vector's contiguous abstract range.  Before
\* the second entry acquires the OFD lock, ioOffset still holds entry one's
\* start.  After acquisition it holds the next scalar start, so subtract the
\* already reported first-entry units.
\* kernel/core/src/fs/file/inode_handle.rs:285-290,308-320
\* kernel/core/src/syscall/preadv.rs:152-174
\* kernel/core/src/syscall/pwritev.rs:148-170
VectorRangeStart(t) ==
    IF vectorIndex[t] > 1 /\ pc[t] \in {"SnapshotSize", "AcquireData"}
    THEN ioOffset[t] - reportedTotal[t]
    ELSE ioOffset[t]

VectorRangeUnits == VectorLength * ProgressUnits(Complete)

RangesOverlap(leftStart, leftUnits, rightStart, rightUnits) ==
    /\ leftUnits > 0
    /\ rightUnits > 0
    /\ leftStart < rightStart + rightUnits
    /\ rightStart < leftStart + leftUnits

\* Writes conflict with either vector direction.  Reads conflict with a
\* vector write because they can observe the state between its scalar entries;
\* two reads commute when neither changes the shared offset.
\* kernel/core/src/syscall/preadv.rs:152-174
\* kernel/core/src/syscall/pwritev.rs:148-170
DataConflictsWithVector(kind, vectorThread) ==
    IsWrite(kind) \/ (IsRead(kind) /\ opKind[vectorThread] = VectorWrite)

\* Ghost witness for a conflicting implementation effect in the real
\* release/reacquire window.  Shared calls conflict through OFD movement;
\* data observations/effects conflict only when their ranges intersect the
\* vector's two-entry range and their directions do not commute.
\* kernel/core/src/syscall/preadv.rs:165-174
\* kernel/core/src/syscall/pwritev.rs:161-170
\* kernel/core/src/vm/page_cache/vmo/mod.rs:734-751
\* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:383-405
MarkVectorIntervenedForAttempt(actor, actorAttempt, kind, actorStart, actorUnits) ==
    [t \in Threads |->
        vectorIntervened[t]
        \/ (((IsShared(kind) /\ VectorOffsetGap(t))
                \/ (DataConflictsWithVector(kind, t)
                    /\ VectorDataGap(t)
                    /\ RangesOverlap(actorStart, actorUnits,
                                     VectorRangeStart(t), VectorRangeUnits)))
            /\ ~(t = actor /\ attemptId[t] = actorAttempt))]

MarkVectorIntervened(actor) ==
    MarkVectorIntervenedForAttempt(
        actor, attemptId[actor], opKind[actor], ioOffset[actor],
        ProgressUnits(copied[actor]))

\* O_APPEND can mutate f_pos before any backend data effect.  Keep that OFD
\* witness separate from the range-qualified write-effect witness so a
\* zero-copy failure still splits an active vector call.
\* kernel/core/src/fs/file/inode_handle.rs:308-320
MarkVectorOffsetIntervenedForAttempt(actor, actorAttempt) ==
    [t \in Threads |->
        vectorIntervened[t]
        \/ (VectorOffsetGap(t)
            /\ ~(t = actor /\ attemptId[t] = actorAttempt))]

\* A delayed direct-I/O completion remains a write conflict even if its owner
\* has already returned and reused the thread-local opKind slot.
\* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:383-405
\* kernel/core/comps/block/src/bio.rs:239-270
MarkVectorWriteEffect(bio) ==
    MarkVectorIntervenedForAttempt(
        bio[1], bio[2], PositionalWrite, bio[6], 1)

\* A positional call snapshots the current OFD position at FileLike::read_at /
\* write_at entry.  Shared offset publications refresh every active positional
\* call's expected value, so unrelated shared I/O remains legal while a
\* positional action that writes f_pos is observable.
\* kernel/core/src/fs/file/inode_handle.rs:285-290,308-353
ActivePositional(t) ==
    /\ IsPositional(opKind[t])
    /\ pc[t] \notin {"Idle", "BeginPositional"}

TrackPositionalOFD(newOffset) ==
    [t \in Threads |->
        IF ActivePositional(t) THEN newOffset ELSE positionalOFDExpected[t]]

\* A faulting vector entry matters to whole-call linearizability only when it
\* exposed read data, retained write data, or ramfs's pre-copy size expansion.
\* A positive prefix discarded from an Uninit/rolled-back ext2 page is not an
\* externally visible second-entry effect.
\* kernel/core/src/vm/page_cache/vmo/mod.rs:724-751,1019-1052
\* kernel/core/src/fs/fs_impls/ramfs/fs.rs:731-750
FaultingEntryObservable(t) ==
    \/ (IsRead(opKind[t]) /\ ProgressUnits(copied[t]) > 0)
    \/ (IsWrite(opKind[t])
        /\ (ProgressUnits(committed[t]) > 0
            \/ (backendMode[t] = Ramfs /\ rangeClass[t] = Extending)))

Init ==
    \* The duplicated-descriptor ownership is one shared Arc/InodeHandle.
    \* kernel/core/src/fs/file/file_table.rs:117-121,181-187,393-399
    /\ pc = [t \in Threads |-> "Idle"]
    /\ opKind = [t \in Threads |-> NoOp]
    /\ backendMode = [t \in Threads |-> Ext2Buffered]
    /\ requested = [t \in Threads |-> Zero]
    /\ copied = [t \in Threads |-> Zero]
    /\ committed = [t \in Threads |-> Zero]
    /\ reported = [t \in Threads |-> Zero]
    /\ copiedTotal = [t \in Threads |-> 0]
    /\ committedTotal = [t \in Threads |-> 0]
    /\ visibleTotal = [t \in Threads |-> 0]
    /\ reportedTotal = [t \in Threads |-> 0]
    /\ result = [t \in Threads |-> NoResult]
    /\ entryResult = [t \in Threads |-> NoEntryResult]
    /\ copyFault = [t \in Threads |-> FALSE]
    \* InodeHandle::offset is the mutex-protected OFD position.
    \* kernel/core/src/fs/file/inode_handle.rs:285-290,308-320
    /\ ofdOffset = 0
    /\ expectedOffset = 0
    /\ offsetOwner = NoThread
    \* The backend inode/page-cache critical section is nested inside one
    \* scalar FileLike call; vectors release it between entries.
    \* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:31-35,49-52,69-74,93-96
    \* kernel/core/src/fs/fs_impls/ramfs/fs.rs:701-710,727-752
    /\ dataOwner = NoThread
    /\ ioOffset = [t \in Threads |-> 0]
    /\ explicitOffset = [t \in Threads |-> 0]
    /\ appendMode = [t \in Threads |-> FALSE]
    \* Initial data/metadata abstraction.
    \* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:234-242,245-271
    \* kernel/core/src/fs/fs_impls/ramfs/fs.rs:701-756
    /\ fileSize = InitialFileSize
    /\ expectedFileSize = InitialFileSize
    /\ oldFileSize = [t \in Threads |-> InitialFileSize]
    /\ plannedEnd = [t \in Threads |-> InitialFileSize]
    /\ sizePublicationOwners = {}
    /\ pageState = [t \in Threads |-> UpToDate]
    /\ rangeClass = [t \in Threads |-> InPlace]
    /\ fileSizeSnapshot = [t \in Threads |-> InitialFileSize]
    /\ dataEpoch = 0
    /\ entryDataEpoch = [t \in Threads |-> 0]
    /\ bufferEpochs = [t \in Threads |-> <<>>]
    /\ vectorIndex = [t \in Threads |-> 1]
    /\ vectorIntervened = [t \in Threads |-> FALSE]
    /\ attemptId = [t \in Threads |-> 0]
    /\ effectToken = [t \in Threads |-> 0]
    /\ directPart = [t \in Threads |-> 1]
    /\ pendingBios = {}
    /\ completedBios = {}
    /\ commitCount = [effect \in EffectDomain |-> 0]
    \* Current ext2/ramfs waits do not return EINTR; the reference capability
    \* is controlled by EnableReferenceInterruptible.
    \* ostd/src/sync/wait.rs:69-85
    \* kernel/libs/io-util/src/batch.rs:147-164
    /\ saRestart = [t \in Threads |-> FALSE]
    /\ restartPending = [t \in Threads |-> FALSE]
    /\ interruptibleBackend = [t \in Threads |-> FALSE]
    /\ positionalOFDExpected = [t \in Threads |-> 0]

TypeOK ==
    /\ pc \in [Threads -> PCStates]
    /\ opKind \in [Threads -> OpKinds]
    /\ backendMode \in [Threads -> BackendModes]
    /\ requested \in [Threads -> Progress]
    /\ copied \in [Threads -> Progress]
    /\ committed \in [Threads -> Progress]
    /\ reported \in [Threads -> Progress]
    /\ copiedTotal \in [Threads -> Nat]
    /\ committedTotal \in [Threads -> Nat]
    /\ visibleTotal \in [Threads -> Nat]
    /\ reportedTotal \in [Threads -> Nat]
    /\ result \in [Threads -> Results]
    /\ entryResult \in [Threads -> EntryResults]
    /\ copyFault \in [Threads -> BOOLEAN]
    /\ ofdOffset \in Nat
    /\ expectedOffset \in Nat
    /\ offsetOwner \in Threads \cup {NoThread}
    /\ dataOwner \in Threads \cup {NoThread}
    /\ ioOffset \in [Threads -> Nat]
    /\ explicitOffset \in [Threads -> 0..MaxOffset]
    /\ appendMode \in [Threads -> BOOLEAN]
    /\ fileSize \in Nat
    /\ expectedFileSize \in Nat
    /\ oldFileSize \in [Threads -> Nat]
    /\ plannedEnd \in [Threads -> Nat]
    /\ sizePublicationOwners \subseteq Threads
    /\ pageState \in [Threads -> PageStates]
    /\ rangeClass \in [Threads -> RangeClasses]
    /\ fileSizeSnapshot \in [Threads -> Nat]
    /\ dataEpoch \in Nat
    /\ entryDataEpoch \in [Threads -> Nat]
    /\ bufferEpochs \in [Threads -> Seq(Nat)]
    /\ vectorIndex \in [Threads -> 1..VectorLength]
    /\ vectorIntervened \in [Threads -> BOOLEAN]
    /\ attemptId \in [Threads -> 0..MaxAttempts]
    /\ effectToken \in [Threads -> 0..MaxAttempts]
    /\ directPart \in [Threads -> 1..VectorLength]
    /\ pendingBios \subseteq BioDomain
    /\ completedBios \subseteq BioDomain
    /\ commitCount \in [EffectDomain -> Nat]
    /\ saRestart \in [Threads -> BOOLEAN]
    /\ restartPending \in [Threads -> BOOLEAN]
    /\ interruptibleBackend \in [Threads -> BOOLEAN]
    \* Per-call expected OFD snapshots allow concurrent shared offset changes
    \* without assuming positional neutrality in the type invariant.
    \* kernel/core/src/fs/file/inode_handle.rs:273-353
    /\ positionalOFDExpected \in [Threads -> Nat]

OffsetLockConsistent ==
    \* kernel/core/src/fs/file/inode_handle.rs:285-290,308-320
    offsetOwner = NoThread
    \/ (offsetOwner \in Threads
        /\ IsShared(opKind[offsetOwner])
        /\ pc[offsetOwner] # "Idle")

DataLockConsistent ==
    \* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:31-35,49-52,69-74,93-96
    \* kernel/core/src/fs/fs_impls/ramfs/fs.rs:701-710,727-752
    dataOwner = NoThread
    \/ (dataOwner \in Threads
        /\ opKind[dataOwner] # NoOp
        /\ pc[dataOwner] # "Idle")

SpeculativeSizeConsistent ==
    \* kernel/core/src/fs/fs_impls/ramfs/fs.rs:731-750
    \A t \in sizePublicationOwners :
        /\ backendMode[t] = Ramfs
        /\ IsWrite(opKind[t])
        /\ pc[t] # "Idle"

BackendReleaseBoundaryConsistent ==
    \* Backend return holds the guard until ReleaseData; InodeReturn runs only
    \* after that owner dropped it, though another thread may already own it.
    \* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:31-35,49-52,69-74,93-96
    \* kernel/core/src/fs/fs_impls/ramfs/fs.rs:701-710,727-756
    \A t \in Threads :
        /\ (pc[t] = "ReleaseData" => dataOwner = t)
        /\ (pc[t] = "InodeReturn" => dataOwner # t)

StructuralOK ==
    /\ OffsetLockConsistent
    /\ DataLockConsistent
    /\ SpeculativeSizeConsistent
    /\ BackendReleaseBoundaryConsistent

\* Scenario 1/4: a completed syscall must report every byte class already
\* visible in a user read buffer.
\* ostd/src/mm/io/mod.rs:332-362
\* kernel/core/src/error.rs:209-219
\* kernel/core/src/syscall/read.rs:27-44
\* kernel/core/src/syscall/preadv.rs:165-180
ReportedCoversVisibleCopy ==
    \A t \in Threads :
        pc[t] # "Idle"
        \/ opKind[t] = NoOp
        \/ visibleTotal[t] = 0
        \/ (result[t] \in {Success, ShortSuccess}
            /\ reportedTotal[t] >= visibleTotal[t])

\* Scenario 1/2: a completed write must report every retained/published class.
\* kernel/core/src/vm/page_cache/vmo/mod.rs:689-700,734-751
\* kernel/core/src/error.rs:209-219
\* kernel/core/src/syscall/write.rs:27-44
\* kernel/core/src/syscall/pwritev.rs:161-175
ReportedCoversCommittedWrite ==
    \A t \in Threads :
        pc[t] # "Idle"
        \/ opKind[t] = NoOp
        \/ committedTotal[t] = 0
        \/ (result[t] \in {Success, ShortSuccess}
            /\ reportedTotal[t] >= committedTotal[t])

\* Scenario 1/2 regression specialization: a later Uninit page may fault
\* after an earlier backed page was already dirtied.  That retained prefix
\* must not disappear merely because the faulting page itself stayed Uninit.
\* kernel/core/src/vm/page_cache/vmo/mod.rs:724-750,1019-1052
\* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:204-219,262-265
MixedPageRetainedPrefixReported ==
    \A t \in Threads :
        pc[t] # "Idle"
        \/ backendMode[t] # Ext2Buffered
        \/ pageState[t] # Uninit
        \/ copied[t] # Positive
        \/ committed[t] # Positive
        \/ (result[t] \in {Success, ShortSuccess}
            /\ reportedTotal[t] >= committedTotal[t])

\* Scenario 1/3/5: expectedOffset advances only for reported shared progress;
\* append changes its base only when the write succeeds.  A held mutex hides
\* the implementation's transient local offset state.
\* kernel/core/src/fs/file/inode_handle.rs:285-290,308-320
SharedOffsetMatchesReported ==
    offsetOwner # NoThread \/ ofdOffset = expectedOffset

\* Scenario 2: a ramfs pre-publication is allowed only while its write is
\* active.  On successful completion expectedFileSize catches up; a failed or
\* zero-length extending write leaves an observable mismatch.
\* kernel/core/src/fs/fs_impls/ramfs/fs.rs:731-756
\* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:245-271,290-328
FileSizeMatchesProgress == dataOwner # NoThread \/ fileSize = AllowedFileSize

\* Scenario 3/4: vector scalar entries must remain contiguous in shared-OFD
\* order and free of an overlapping data effect between entries.  The
\* range-qualified witness is authoritative; the global dataEpoch is retained
\* for trace diagnostics and cannot distinguish disjoint inode ranges.
\* kernel/core/src/fs/file/inode_handle.rs:285-290,308-320
\* kernel/core/src/syscall/preadv.rs:152-174
\* kernel/core/src/syscall/pwritev.rs:148-170
\* kernel/core/src/vm/page_cache/vmo/mod.rs:734-751
VectorCallLinearizable ==
    \A t \in Threads :
        pc[t] # "Idle"
        \/ ~IsVector(opKind[t])
        \* A later fault with no visible/committed/metadata effect contributes
        \* no second-entry effect.  The completed prefix can still linearize
        \* before an intervening operation.
        \* kernel/core/src/syscall/preadv.rs:165-180
        \* kernel/core/src/syscall/pwritev.rs:161-175
        \/ (entryResult[t] = EntryFault /\ ~FaultingEntryObservable(t))
        \/ ~vectorIntervened[t]

\* MC1 specialization: after at least one completed iovec, a positive fault
\* in a later entry must not coexist with a conflicting operation in the
\* release/reacquire gap.  The faulting prefix is visible/committed even though
\* the vector wrapper omits it from total_len.
\* kernel/core/src/syscall/preadv.rs:152-180
\* kernel/core/src/syscall/pwritev.rs:148-175
\* kernel/core/src/error.rs:209-219
LaterIovecFaultLinearizable ==
    \A t \in Threads :
        pc[t] # "Idle"
        \/ ~IsVector(opKind[t])
        \/ vectorIndex[t] = 1
        \/ entryResult[t] # EntryFault
        \/ copied[t] # Positive
        \/ ~FaultingEntryObservable(t)
        \/ ~vectorIntervened[t]

\* Scenario 3/5 composition: an O_APPEND competitor that pre-positions f_pos
\* and then returns a zero-copy fault must not coexist with a completed vector
\* whose two scalar entries straddle that assignment.  The focused hunt uses
\* this completion gate so a zero-length successful append cannot terminate it
\* before the requested fault path executes.
\* kernel/core/src/fs/file/inode_handle.rs:308-320
\* kernel/core/src/syscall/preadv.rs:152-180
\* kernel/core/src/syscall/pwritev.rs:148-175
AppendFailureVectorLinearizable ==
    \A vectorThread, appendThread \in Threads :
        pc[vectorThread] # "Idle"
        \/ ~IsVector(opKind[vectorThread])
        \/ result[vectorThread] \notin {Success, ShortSuccess}
        \/ pc[appendThread] # "Idle"
        \/ opKind[appendThread] # SharedWrite
        \/ ~appendMode[appendThread]
        \/ result[appendThread] # Fault
        \/ copied[appendThread] # Zero
        \/ ~vectorIntervened[vectorThread]

\* Scenario 4: read_at/write_at bypass InodeHandle::offset.  Each active
\* positional call must continue to see the OFD value produced by shared
\* offset writers, never a value produced by its own implementation path.
\* kernel/core/src/fs/file/inode_handle.rs:285-290,308-353
PositionalOffsetStable ==
    \A t \in Threads : ~ActivePositional(t) \/ ofdOffset = positionalOFDExpected[t]

\* Scenario 2: a BIO may remain outstanding only while its submitting attempt
\* is still active and can account for it before returning.
\* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:383-405
\* kernel/libs/io-util/src/batch.rs:147-164
NoUnaccountedPendingEffect ==
    \A bio \in pendingBios : BioAttempt(bio) \in ActiveAttempts

\* Scenario 6 contract: a rewind is safe only when the attempt has no copied
\* or committed progress.  The implementation action below does not guard it.
\* kernel/core/src/syscall/read.rs:27-39
\* kernel/core/src/syscall/write.rs:27-39
\* kernel/core/src/process/signal/mod.rs:145-158
RestartRequiresZeroProgress ==
    \A t \in Threads :
        ~restartPending[t]
        \/ (copied[t] = Zero
            /\ committed[t] = Zero
            /\ copiedTotal[t] = 0
            /\ committedTotal[t] = 0)

\* Scenario 6: a logical effect token/part may be committed at most once even
\* if the syscall instruction is re-executed.
\* kernel/core/src/process/signal/mod.rs:145-158
\* kernel/core/src/thread/task.rs:83-105
NoEffectReplay ==
    \A effect \in EffectDomain : commitCount[effect] <= 1

\* Common state reset for the six in-scope syscall entry points.  The named
\* wrappers below retain their implementation identities; this operator only
\* factors their identical per-attempt bookkeeping.
\* kernel/core/src/syscall/read.rs:10-35
\* kernel/core/src/syscall/write.rs:10-35
\* kernel/core/src/syscall/pread64.rs:10-37
\* kernel/core/src/syscall/pwrite64.rs:10-35
\* kernel/core/src/syscall/preadv.rs:11-18,134-180
\* kernel/core/src/syscall/pwritev.rs:11-18,134-175
BeginFresh(t, kind, backend, req, isAppend, pos, restartable, initialPage, nextPc) ==
    /\ pc[t] = "Idle"
    /\ attemptId[t] < MaxAttempts
    /\ kind \in OpKinds \ {NoOp}
    /\ backend \in BackendModes
    /\ req \in {Zero, Complete}
    /\ pos \in 0..MaxOffset
    /\ initialPage \in PageStates
    \* Syscall arguments and the selected implementation path become local
    \* attempt state before entering FileLike.
    \* kernel/core/src/syscall/read.rs:21-35
    \* kernel/core/src/syscall/write.rs:21-35
    \* kernel/core/src/syscall/pread64.rs:22-37
    \* kernel/core/src/syscall/pwrite64.rs:22-35
    /\ pc' = [pc EXCEPT ![t] = nextPc]
    /\ opKind' = [opKind EXCEPT ![t] = kind]
    /\ backendMode' = [backendMode EXCEPT ![t] = backend]
    /\ requested' = [requested EXCEPT ![t] = req]
    /\ explicitOffset' = [explicitOffset EXCEPT ![t] = pos]
    /\ appendMode' = [appendMode EXCEPT ![t] = isAppend]
    /\ saRestart' = [saRestart EXCEPT ![t] = restartable]
    /\ interruptibleBackend' =
        [interruptibleBackend EXCEPT ![t] = EnableReferenceInterruptible]
    \* A fresh logical operation receives a fresh effect token.  A restarted
    \* operation uses TaskRestartSyscall instead and retains this token.
    \* kernel/core/src/thread/task.rs:83-105
    /\ attemptId' = [attemptId EXCEPT ![t] = @ + 1]
    /\ effectToken' = [effectToken EXCEPT ![t] = attemptId[t] + 1]
    /\ restartPending' = [restartPending EXCEPT ![t] = FALSE]
    \* Progress is tracked independently at the copy, backend, return, and OFD
    \* publication layers.
    \* ostd/src/mm/io/mod.rs:271-292,332-385
    \* kernel/core/src/error.rs:209-219
    /\ copied' = [copied EXCEPT ![t] = Zero]
    /\ committed' = [committed EXCEPT ![t] = Zero]
    /\ reported' = [reported EXCEPT ![t] = Zero]
    /\ copiedTotal' = [copiedTotal EXCEPT ![t] = 0]
    /\ committedTotal' = [committedTotal EXCEPT ![t] = 0]
    /\ visibleTotal' = [visibleTotal EXCEPT ![t] = 0]
    /\ reportedTotal' = [reportedTotal EXCEPT ![t] = 0]
    /\ result' = [result EXCEPT ![t] = Pending]
    /\ entryResult' = [entryResult EXCEPT ![t] = NoEntryResult]
    /\ copyFault' = [copyFault EXCEPT ![t] = FALSE]
    \* Offset, backend, and vector-local snapshots are initialized without
    \* mutating shared file state.
    \* kernel/core/src/fs/file/inode_handle.rs:273-353
    \* kernel/core/src/syscall/preadv.rs:152-174
    \* kernel/core/src/syscall/pwritev.rs:148-170
    /\ ioOffset' = [ioOffset EXCEPT ![t] = 0]
    /\ oldFileSize' = [oldFileSize EXCEPT ![t] = fileSize]
    /\ plannedEnd' = [plannedEnd EXCEPT ![t] = fileSize]
    /\ pageState' = [pageState EXCEPT ![t] = initialPage]
    /\ rangeClass' = [rangeClass EXCEPT ![t] = InPlace]
    /\ fileSizeSnapshot' = [fileSizeSnapshot EXCEPT ![t] = fileSize]
    /\ entryDataEpoch' = [entryDataEpoch EXCEPT ![t] = dataEpoch]
    /\ bufferEpochs' = [bufferEpochs EXCEPT ![t] = <<>>]
    /\ vectorIndex' = [vectorIndex EXCEPT ![t] = 1]
    /\ vectorIntervened' = [vectorIntervened EXCEPT ![t] = FALSE]
    /\ directPart' = [directPart EXCEPT ![t] = 1]
    /\ UNCHANGED FileVars

\* sys_read builds one VmWriter and calls FileLike::read.
\* kernel/core/src/syscall/read.rs:10-35
SysReadStart(t, backend, restartable) ==
    BeginFresh(t, SharedRead, backend, Complete, FALSE, 0, restartable,
               UpToDate, "AcquireOffset")

\* sys_write builds one VmReader and calls FileLike::write.  Zero requests are
\* retained because ramfs can expand metadata even for a zero-length write.
\* kernel/core/src/syscall/write.rs:10-35
SysWriteStart(t, backend, req, isAppend, restartable, initialPage) ==
    BeginFresh(t, SharedWrite, backend, req, isAppend, 0, restartable,
               initialPage, "AcquireOffset")

\* sys_pread64 passes its local offset to FileLike::read_at.
\* kernel/core/src/syscall/pread64.rs:22-37
SysPread64Start(t, backend, pos) ==
    BeginFresh(t, PositionalRead, backend, Complete, FALSE, pos, FALSE,
               UpToDate, "BeginPositional")

\* sys_pwrite64 passes its local offset to FileLike::write_at.
\* kernel/core/src/syscall/pwrite64.rs:22-35
SysPwrite64Start(t, backend, req, pos, initialPage) ==
    BeginFresh(t, PositionalWrite, backend, req, FALSE, pos, FALSE,
               initialPage, "BeginPositional")

\* do_sys_readv loops over independently locked FileLike::read calls.
\* kernel/core/src/syscall/preadv.rs:134-180
DoSysReadvStart(t, backend) ==
    BeginFresh(t, VectorRead, backend, Complete, FALSE, 0, FALSE,
               UpToDate, "AcquireOffset")

\* do_sys_writev loops over independently locked FileLike::write calls.
\* kernel/core/src/syscall/pwritev.rs:134-175
DoSysWritevStart(t, backend, initialPage) ==
    BeginFresh(t, VectorWrite, backend, Complete, FALSE, 0, FALSE,
               initialPage, "AcquireOffset")

\* InodeHandle::read takes the OFD offset mutex around exactly one read_at.
\* kernel/core/src/fs/file/inode_handle.rs:273-290
InodeHandleReadAcquireOffset(t) ==
    /\ pc[t] = "AcquireOffset"
    /\ opKind[t] \in {SharedRead, VectorRead}
    /\ offsetOwner = NoThread
    \* Capture the current shared offset while holding the mutex.
    \* kernel/core/src/fs/file/inode_handle.rs:285-287
    /\ offsetOwner' = t
    /\ ioOffset' = [ioOffset EXCEPT ![t] = ofdOffset]
    \* ramfs snapshots EOF before taking its page-cache mutex; other backends
    \* proceed directly to the fallible copy.
    \* kernel/core/src/fs/fs_impls/ramfs/fs.rs:701-710
    /\ pc' = [pc EXCEPT ![t] =
        IF backendMode[t] = Ramfs THEN "SnapshotSize" ELSE "AcquireData"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, reported,
        copiedTotal, committedTotal, visibleTotal, reportedTotal, result,
        entryResult, copyFault, ofdOffset, expectedOffset, dataOwner,
        explicitOffset,
        appendMode, fileSize, expectedFileSize, oldFileSize, plannedEnd,
        sizePublicationOwners, pageState, rangeClass, fileSizeSnapshot,
        dataEpoch, entryDataEpoch, bufferEpochs, vectorIndex,
        vectorIntervened, attemptId, effectToken, directPart, pendingBios,
        completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* InodeHandle::write takes the OFD offset mutex around exactly one write_at.
\* kernel/core/src/fs/file/inode_handle.rs:293-320
InodeHandleWriteAcquireOffset(t) ==
    /\ pc[t] = "AcquireOffset"
    /\ opKind[t] \in {SharedWrite, VectorWrite}
    /\ offsetOwner = NoThread
    \* Capture f_pos under the mutex.  The append branch may replace it next.
    \* kernel/core/src/fs/file/inode_handle.rs:308-315
    /\ offsetOwner' = t
    /\ ioOffset' = [ioOffset EXCEPT ![t] = ofdOffset]
    /\ pc' = [pc EXCEPT ![t] =
        IF appendMode[t] THEN "ChooseAppendStart" ELSE "AcquireData"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, reported,
        copiedTotal, committedTotal, visibleTotal, reportedTotal, result,
        entryResult, copyFault, ofdOffset, expectedOffset, dataOwner,
        explicitOffset,
        appendMode, fileSize, expectedFileSize, oldFileSize, plannedEnd,
        sizePublicationOwners, pageState, rangeClass, fileSizeSnapshot,
        dataEpoch, entryDataEpoch, bufferEpochs, vectorIndex,
        vectorIntervened, attemptId, effectToken, directPart, pendingBios,
        completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* InodeHandle::read_at bypasses self.offset and uses only the explicit offset.
\* kernel/core/src/fs/file/inode_handle.rs:323-332
InodeHandleReadAtBegin(t) ==
    /\ pc[t] = "BeginPositional"
    /\ opKind[t] = PositionalRead
    \* The positional offset is copied locally; ofdOffset is untouched.
    \* kernel/core/src/fs/file/inode_handle.rs:323-331
    /\ ioOffset' = [ioOffset EXCEPT ![t] = explicitOffset[t]]
    /\ positionalOFDExpected' =
        [positionalOFDExpected EXCEPT ![t] = ofdOffset]
    /\ pc' = [pc EXCEPT ![t] =
        IF backendMode[t] = Ramfs THEN "SnapshotSize" ELSE "AcquireData"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, reported,
        copiedTotal, committedTotal, visibleTotal, reportedTotal, result,
        entryResult, copyFault, ofdOffset, expectedOffset, offsetOwner,
        dataOwner,
        explicitOffset, appendMode, fileSize, expectedFileSize, oldFileSize,
        plannedEnd, sizePublicationOwners, pageState, rangeClass,
        fileSizeSnapshot, dataEpoch, entryDataEpoch, bufferEpochs,
        vectorIndex, vectorIntervened, attemptId, effectToken, directPart,
        pendingBios, completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend
        >>

\* InodeHandle::write_at bypasses self.offset and uses only a local offset.
\* kernel/core/src/fs/file/inode_handle.rs:334-353
InodeHandleWriteAtBegin(t) ==
    /\ pc[t] = "BeginPositional"
    /\ opKind[t] = PositionalWrite
    \* pwrite64's local offset does not publish to the OFD.
    \* kernel/core/src/fs/file/inode_handle.rs:334-353
    /\ ioOffset' = [ioOffset EXCEPT ![t] = explicitOffset[t]]
    /\ positionalOFDExpected' =
        [positionalOFDExpected EXCEPT ![t] = ofdOffset]
    /\ pc' = [pc EXCEPT ![t] = "AcquireData"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, reported,
        copiedTotal, committedTotal, visibleTotal, reportedTotal, result,
        entryResult, copyFault, ofdOffset, expectedOffset, offsetOwner,
        dataOwner,
        explicitOffset, appendMode, fileSize, expectedFileSize, oldFileSize,
        plannedEnd, sizePublicationOwners, pageState, rangeClass,
        fileSizeSnapshot, dataEpoch, entryDataEpoch, bufferEpochs,
        vectorIndex, vectorIntervened, attemptId, effectToken, directPart,
        pendingBios, completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend
        >>

\* O_APPEND writes EOF into the shared offset before the fallible backend call.
\* kernel/core/src/fs/file/inode_handle.rs:308-317
InodeHandleWriteChooseAppendStart(t) ==
    /\ pc[t] = "ChooseAppendStart"
    /\ opKind[t] = SharedWrite
    /\ appendMode[t]
    /\ offsetOwner = t
    \* This is the implementation's pre-success f_pos publication.
    \* kernel/core/src/fs/file/inode_handle.rs:310-315
    /\ ofdOffset' = fileSize
    /\ ioOffset' = [ioOffset EXCEPT ![t] = fileSize]
    /\ positionalOFDExpected' = TrackPositionalOFD(fileSize)
    \* If EOF differs from the old f_pos, this pre-success assignment is a
    \* complete OFD intervention even if the following copy faults at zero.
    \* kernel/core/src/fs/file/inode_handle.rs:310-317
    /\ vectorIntervened' =
        IF fileSize # ofdOffset
        THEN MarkVectorOffsetIntervenedForAttempt(t, attemptId[t])
        ELSE vectorIntervened
    /\ pc' = [pc EXCEPT ![t] = "AcquireData"]
    \* expectedOffset deliberately remains unchanged until a successful result.
    \* Linux fs/read_write.c:v6.16:727-740
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, reported,
        copiedTotal, committedTotal, visibleTotal, reportedTotal, result,
        entryResult, copyFault, expectedOffset, offsetOwner, dataOwner,
        explicitOffset,
        appendMode, fileSize, expectedFileSize, oldFileSize, plannedEnd,
        sizePublicationOwners, pageState, rangeClass, fileSizeSnapshot,
        dataEpoch, entryDataEpoch, bufferEpochs, vectorIndex,
        attemptId, effectToken, directPart, pendingBios,
        completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend
        >>

\* ramfs computes read_len from an EOF snapshot before locking the page cache.
\* kernel/core/src/fs/fs_impls/ramfs/fs.rs:701-710
RamInodeReadAtSnapshotSize(t) ==
    /\ pc[t] = "SnapshotSize"
    /\ IsRead(opKind[t])
    /\ backendMode[t] = Ramfs
    \* Record the metadata snapshot used later as the returned read_len.
    \* kernel/core/src/fs/fs_impls/ramfs/fs.rs:703-708
    /\ fileSizeSnapshot' = [fileSizeSnapshot EXCEPT ![t] = fileSize]
    /\ pc' = [pc EXCEPT ![t] = "AcquireData"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, reported,
        copiedTotal, committedTotal, visibleTotal, reportedTotal, result,
        entryResult, copyFault, ofdOffset, expectedOffset, offsetOwner,
        dataOwner,
        ioOffset, explicitOffset, appendMode, fileSize, expectedFileSize,
        oldFileSize, plannedEnd, sizePublicationOwners, pageState, rangeClass,
        dataEpoch, entryDataEpoch, bufferEpochs, vectorIndex,
        vectorIntervened, attemptId, effectToken, directPart, pendingBios,
        completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* FileOps enters the backend inode/page-cache critical section for one scalar
\* call.  A vector call releases it before dispatching its next entry.
\* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:31-35,49-52,69-74,93-96
\* kernel/core/src/fs/fs_impls/ramfs/fs.rs:701-710,727-752
FileOpsAcquireData(t) ==
    /\ pc[t] = "AcquireData"
    /\ opKind[t] # NoOp
    /\ dataOwner = NoThread
    \* ext2 checks a zero-length write before acquiring self.inner; ramfs still
    \* takes its page-cache/metadata guards and may expand size at a far offset.
    \* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:44-50,83-94
    \* kernel/core/src/fs/fs_impls/ramfs/fs.rs:727-750
    /\ ~(IsWrite(opKind[t])
        /\ backendMode[t] \in {Ext2Buffered, Ext2Direct}
        /\ requested[t] = Zero)
    \* The lock spans the backend copy/publication path but not the next vector
    \* entry.  ramfs read took its EOF snapshot before this action.
    \* kernel/core/src/fs/fs_impls/ramfs/fs.rs:701-710,731-750
    /\ dataOwner' = t
    /\ pc' = [pc EXCEPT ![t] =
        IF IsRead(opKind[t]) THEN "CopyRead" ELSE "PrepareWrite"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, reported,
        copiedTotal, committedTotal, visibleTotal, reportedTotal, result,
        entryResult, copyFault, ofdOffset, expectedOffset, offsetOwner,
        ioOffset, explicitOffset, appendMode, fileSize, expectedFileSize,
        oldFileSize, plannedEnd, sizePublicationOwners, pageState, rangeClass,
        fileSizeSnapshot, dataEpoch, entryDataEpoch, bufferEpochs,
        vectorIndex, vectorIntervened, attemptId, effectToken, directPart,
        pendingBios, completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* ext2 buffered and direct writes return Ok(0) before acquiring self.inner.
\* This differs from ramfs, which enters its page-cache/metadata critical
\* section even for a zero-length request.
\* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:39-51,78-95
Ext2InodeWriteAtZeroLengthReturn(t) ==
    /\ pc[t] = "AcquireData"
    /\ IsWrite(opKind[t])
    /\ backendMode[t] \in {Ext2Buffered, Ext2Direct}
    /\ requested[t] = Zero
    \* No copy, data publication, metadata commit, or backend guard occurs.
    \* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:44-46,83-85
    /\ reported' = [reported EXCEPT ![t] = Zero]
    /\ entryResult' = [entryResult EXCEPT ![t] = EntryOk]
    /\ pc' = [pc EXCEPT ![t] = "InodeReturn"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, copiedTotal,
        committedTotal, visibleTotal, reportedTotal, result, copyFault,
        ofdOffset, expectedOffset, offsetOwner, dataOwner, ioOffset,
        explicitOffset, appendMode, fileSize, expectedFileSize, oldFileSize,
        plannedEnd, sizePublicationOwners, pageState, rangeClass,
        fileSizeSnapshot, dataEpoch, entryDataEpoch, bufferEpochs, vectorIndex,
        vectorIntervened, attemptId, effectToken, directPart, pendingBios,
        completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* ext2 prepare_write grows only page-cache/block backing; file size is
\* committed after a successful nonzero copy.
\* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:193-201,245-271,290-328
InodeInnerPrepareWrite(t) ==
    /\ pc[t] = "PrepareWrite"
    /\ IsWrite(opKind[t])
    /\ backendMode[t] \in {Ext2Buffered, Ext2Direct}
    /\ dataOwner = t
    /\ requested[t] # Zero
    \* Save the rollback boundary and classify only zero/positive extension.
    \* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:247-260,297-310
    /\ oldFileSize' = [oldFileSize EXCEPT ![t] = fileSize]
    /\ plannedEnd' =
        [plannedEnd EXCEPT ![t] = ioOffset[t] + ProgressUnits(requested[t])]
    /\ rangeClass' = [rangeClass EXCEPT ![t] =
        IF ioOffset[t] + ProgressUnits(requested[t]) > fileSize
        THEN Extending ELSE InPlace]
    \* A nonzero direct write enters its per-range copy/submit loop; a buffered
    \* write proceeds to its VMO copy.
    \* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:245-271,290-328,383-405
    /\ pc' = [pc EXCEPT ![t] =
        IF backendMode[t] = Ext2Direct THEN "DirectCopy" ELSE "CopyWrite"]
    /\ entryResult' = [entryResult EXCEPT ![t] = NoEntryResult]
    /\ reported' = [reported EXCEPT ![t] = Zero]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, copiedTotal,
        committedTotal, visibleTotal, reportedTotal, result, copyFault,
        ofdOffset, expectedOffset, offsetOwner, dataOwner, ioOffset,
        explicitOffset,
        appendMode, fileSize, expectedFileSize, sizePublicationOwners,
        pageState, fileSizeSnapshot, dataEpoch, entryDataEpoch, bufferEpochs,
        vectorIndex, vectorIntervened, attemptId, effectToken, directPart,
        pendingBios, completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* ramfs publishes timestamps and the requested end before page-cache copy and
\* has no rollback on the subsequent `?` error path.
\* kernel/core/src/fs/fs_impls/ramfs/fs.rs:721-756
RamInodeWriteAtPublishMetadata(t) ==
    /\ pc[t] = "PrepareWrite"
    /\ IsWrite(opKind[t])
    /\ backendMode[t] = Ramfs
    /\ dataOwner = t
    \* Lines 733-744 publish size/blocks from offset + reader.remain(), even
    \* when remain() is zero and offset already lies beyond EOF.
    \* kernel/core/src/fs/fs_impls/ramfs/fs.rs:731-745
    /\ LET newEnd == ioOffset[t] + ProgressUnits(requested[t]) IN
       /\ oldFileSize' = [oldFileSize EXCEPT ![t] = fileSize]
       /\ plannedEnd' = [plannedEnd EXCEPT ![t] = newEnd]
       /\ rangeClass' = [rangeClass EXCEPT ![t] =
            IF newEnd > fileSize THEN Extending ELSE InPlace]
       /\ fileSize' = Max(fileSize, newEnd)
       /\ sizePublicationOwners' =
            IF newEnd > fileSize
            THEN sizePublicationOwners \cup {t}
            ELSE sizePublicationOwners
       \* A published EOF extension is observable even when the following
       \* page copy faults at zero.  Mark only vectors whose abstract data
       \* range intersects the extending request.
       \* kernel/core/src/fs/fs_impls/ramfs/fs.rs:731-750
       /\ vectorIntervened' =
            IF newEnd > fileSize
            THEN MarkVectorIntervenedForAttempt(
                t, attemptId[t], opKind[t], ioOffset[t],
                ProgressUnits(requested[t]))
            ELSE vectorIntervened
    \* The anonymous page-cache write follows the metadata publication.
    \* kernel/core/src/fs/fs_impls/ramfs/fs.rs:747-752
    /\ pc' = [pc EXCEPT ![t] = "CopyWrite"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, reported,
        copiedTotal, committedTotal, visibleTotal, reportedTotal, result,
        entryResult, copyFault, ofdOffset, expectedOffset, offsetOwner,
        dataOwner,
        ioOffset, explicitOffset, appendMode, expectedFileSize, pageState,
        fileSizeSnapshot, dataEpoch, entryDataEpoch, bufferEpochs,
        vectorIndex, attemptId, effectToken, directPart,
        pendingBios, completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* Aggregate one scalar backend read after all internal VMO pages, direct-I/O
\* ranges, holes, or the no-copy EOF branch have finished.  The existing
\* inode/page-cache guard spans the internal loop, so no in-scope operation can
\* observe an intermediate iteration.
\* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:228-242,274-287,331-362
\* kernel/core/src/fs/fs_impls/ramfs/fs.rs:701-710
\* kernel/core/src/vm/page_cache/vmo/mod.rs:533-566
FileOpsReadAtCopyComplete(t) ==
    /\ pc[t] = "CopyRead"
    /\ IsRead(opKind[t])
    /\ dataOwner = t
    \* The ext2 writer limit stops at EOF; ramfs leaves the writer unbounded by
    \* its separate read_len snapshot.
    \* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:234-242
    \* kernel/core/src/fs/fs_impls/ramfs/fs.rs:701-710
    /\ \E copiedClass \in ReadCopyCompleteClasses(t) :
        /\ copied' = [copied EXCEPT ![t] = copiedClass]
        /\ copyFault' = [copyFault EXCEPT ![t] = FALSE]
        \* Capture the data generation actually copied into the user buffer.
        \* kernel/core/src/vm/page_cache/vmo/mod.rs:556-559
        /\ entryDataEpoch' = [entryDataEpoch EXCEPT ![t] = dataEpoch]
        /\ vectorIntervened' =
            IF ProgressUnits(copiedClass) > 0
            THEN MarkVectorIntervenedForAttempt(
                t, attemptId[t], opKind[t], ioOffset[t],
                ProgressUnits(copiedClass))
            ELSE vectorIntervened
        /\ pc' = [pc EXCEPT ![t] = "BackendFinish"]
        /\ UNCHANGED <<
            opKind, backendMode, requested, committed, reported, copiedTotal,
            committedTotal, visibleTotal, reportedTotal, result, entryResult,
            ofdOffset, expectedOffset, offsetOwner, dataOwner, ioOffset,
            explicitOffset,
            appendMode, fileSize, expectedFileSize, oldFileSize, plannedEnd,
            sizePublicationOwners, pageState, rangeClass, fileSizeSnapshot,
            dataEpoch, bufferEpochs, vectorIndex, attemptId, effectToken,
            directPart, pendingBios, completedBios, commitCount, saRestart,
            restartPending, interruptibleBackend, positionalOFDExpected
            >>

\* Aggregate a backend read whose internal fallible calls copied no bytes
\* before the first fault.  Cursor comparison at the backend boundary makes
\* this distinct from a later fault after earlier complete page/range copies.
\* ostd/src/mm/io/mod.rs:339-360
\* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:228-242,274-287,331-362
\* kernel/core/src/fs/fs_impls/ramfs/fs.rs:701-710
FileOpsReadAtCopyFaultZero(t) ==
    /\ pc[t] = "CopyRead"
    /\ IsRead(opKind[t])
    /\ dataOwner = t
    /\ ReadCopyTargetUnits(t) > 0
    \* memcpy copied zero of a nonempty request.
    \* ostd/src/mm/io/mod.rs:347-359
    /\ copied' = [copied EXCEPT ![t] = Zero]
    /\ copyFault' = [copyFault EXCEPT ![t] = TRUE]
    /\ entryDataEpoch' = [entryDataEpoch EXCEPT ![t] = dataEpoch]
    /\ pc' = [pc EXCEPT ![t] = "BackendFinish"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, committed, reported, copiedTotal,
        committedTotal, visibleTotal, reportedTotal, result, entryResult,
        ofdOffset, expectedOffset, offsetOwner, dataOwner, ioOffset,
        explicitOffset,
        appendMode, fileSize, expectedFileSize, oldFileSize, plannedEnd,
        sizePublicationOwners, pageState, rangeClass, fileSizeSnapshot,
        dataEpoch, bufferEpochs, vectorIndex, vectorIntervened, attemptId,
        effectToken, directPart, pendingBios, completedBios, commitCount,
        saRestart, restartPending, interruptibleBackend, positionalOFDExpected
        >>

\* Aggregate any positive cursor advance across one or more internal calls
\* before a later fault.  The backend caller later erases this cumulative
\* count when converting the tuple error.
\* ostd/src/mm/io/mod.rs:347-359
\* kernel/core/src/error.rs:209-219
\* kernel/core/src/vm/page_cache/vmo/mod.rs:548-559
\* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:346-362
FileOpsReadAtCopyFaultPositive(t) ==
    /\ pc[t] = "CopyRead"
    /\ IsRead(opKind[t])
    /\ dataOwner = t
    /\ ReadCopyTargetUnits(t) > 0
    \* The exact prefix is abstracted to Positive.
    \* ostd/src/mm/io/mod.rs:354-359
    /\ copied' = [copied EXCEPT ![t] = Positive]
    /\ copyFault' = [copyFault EXCEPT ![t] = TRUE]
    /\ entryDataEpoch' = [entryDataEpoch EXCEPT ![t] = dataEpoch]
    /\ vectorIntervened' = MarkVectorIntervenedForAttempt(
        t, attemptId[t], opKind[t], ioOffset[t], ProgressUnits(Positive))
    /\ pc' = [pc EXCEPT ![t] = "BackendFinish"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, committed, reported, copiedTotal,
        committedTotal, visibleTotal, reportedTotal, result, entryResult,
        ofdOffset, expectedOffset, offsetOwner, dataOwner, ioOffset,
        explicitOffset,
        appendMode, fileSize, expectedFileSize, oldFileSize, plannedEnd,
        sizePublicationOwners, pageState, rangeClass, fileSizeSnapshot,
        dataEpoch, bufferEpochs, vectorIndex, attemptId, effectToken,
        directPart, pendingBios, completedBios, commitCount, saRestart,
        restartPending, interruptibleBackend, positionalOFDExpected
        >>

\* Aggregate one buffered/anonymous backend write after its internal page loop
\* finishes.  Ext2 and ramfs hold their existing data guard across the loop;
\* direct-I/O range copies remain separate BioSegment actions below.
\* ostd/src/mm/io/mod.rs:367-385
\* kernel/core/src/vm/page_cache/vmo/mod.rs:667-759
\* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:245-271
\* kernel/core/src/fs/fs_impls/ramfs/fs.rs:727-752
FileOpsWriteAtCopyComplete(t) ==
    /\ pc[t] = "CopyWrite"
    /\ IsWrite(opKind[t])
    /\ dataOwner = t
    \* A nonfaulting copy consumes the full abstract request, including the
    \* zero-length ramfs case.
    \* ostd/src/mm/io/mod.rs:339-360,369-375
    /\ copied' = [copied EXCEPT ![t] = requested[t]]
    /\ copyFault' = [copyFault EXCEPT ![t] = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "BackendFinish"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, committed, reported, copiedTotal,
        committedTotal, visibleTotal, reportedTotal, result, entryResult,
        ofdOffset, expectedOffset, offsetOwner, dataOwner, ioOffset,
        explicitOffset,
        appendMode, fileSize, expectedFileSize, oldFileSize, plannedEnd,
        sizePublicationOwners, pageState, rangeClass, fileSizeSnapshot,
        dataEpoch, entryDataEpoch, bufferEpochs, vectorIndex,
        vectorIntervened, attemptId, effectToken, directPart, pendingBios,
        completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* Aggregate a buffered/anonymous write with zero cumulative cursor advance
\* before the fault.
\* ostd/src/mm/io/mod.rs:347-359,367-375
\* kernel/core/src/vm/page_cache/vmo/mod.rs:681-699,717-759
FileOpsWriteAtCopyFaultZero(t, faultPage) ==
    /\ pc[t] = "CopyWrite"
    /\ IsWrite(opKind[t])
    /\ dataOwner = t
    /\ requested[t] # Zero
    /\ faultPage \in PageStates
    \* No cursor advances, but ramfs metadata may already have been published.
    \* kernel/core/src/fs/fs_impls/ramfs/fs.rs:731-750
    /\ copied' = [copied EXCEPT ![t] = Zero]
    /\ copyFault' = [copyFault EXCEPT ![t] = TRUE]
    \* Capture the actual faulting page's disposition at the aggregate
    \* boundary; it need not equal an earlier page in a multi-page request.
    \* kernel/core/src/vm/page_cache/vmo/mod.rs:724-746
    /\ pageState' = [pageState EXCEPT ![t] = faultPage]
    /\ pc' = [pc EXCEPT ![t] = "BackendFinish"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, committed, reported, copiedTotal,
        committedTotal, visibleTotal, reportedTotal, result, entryResult,
        ofdOffset, expectedOffset, offsetOwner, dataOwner, ioOffset,
        explicitOffset,
        appendMode, fileSize, expectedFileSize, oldFileSize, plannedEnd,
        sizePublicationOwners, rangeClass, fileSizeSnapshot,
        dataEpoch, entryDataEpoch, bufferEpochs, vectorIndex,
        vectorIntervened, attemptId, effectToken, directPart, pendingBios,
        completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* Aggregate a positive prefix from one or more internal page-copy calls before
\* the backend returns the scalar fault.  Keep cumulative retained progress
\* separate from the faulting page: an earlier page may already be dirty when
\* a later Uninit page faults.
\* ostd/src/mm/io/mod.rs:347-359,367-375
\* kernel/core/src/vm/page_cache/vmo/mod.rs:681-699,717-759
FileOpsWriteAtCopyFaultPositive(t, faultPage, retainedPrefix) ==
    /\ pc[t] = "CopyWrite"
    /\ IsWrite(opKind[t])
    /\ dataOwner = t
    /\ requested[t] # Zero
    /\ faultPage \in PageStates
    /\ retainedPrefix \in {Zero, Positive}
    \* Anonymous pages retain every copied prefix.  A backed UpToDate faulting
    \* page is dirtied by the fault branch itself.
    \* kernel/core/src/vm/page_cache/vmo/mod.rs:689-691,734-745
    /\ ((backendMode[t] = Ramfs \/ faultPage = UpToDate)
        => retainedPrefix = Positive)
    \* For a backed Uninit faulting page, Zero means all copied bytes belonged
    \* to that page.  Positive records an earlier page already dirtied by a
    \* successful loop iteration before the later page faulted.
    \* kernel/core/src/vm/page_cache/vmo/mod.rs:724-750,1019-1052
    /\ copied' = [copied EXCEPT ![t] = Positive]
    /\ committed' = [committed EXCEPT ![t] = retainedPrefix]
    /\ copyFault' = [copyFault EXCEPT ![t] = TRUE]
    /\ pageState' = [pageState EXCEPT ![t] = faultPage]
    /\ pc' = [pc EXCEPT ![t] = "BackendFinish"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, reported, copiedTotal,
        committedTotal, visibleTotal, reportedTotal, result, entryResult,
        ofdOffset, expectedOffset, offsetOwner, dataOwner, ioOffset,
        explicitOffset,
        appendMode, fileSize, expectedFileSize, oldFileSize, plannedEnd,
        sizePublicationOwners, rangeClass, fileSizeSnapshot,
        dataEpoch, entryDataEpoch, bufferEpochs, vectorIndex,
        vectorIntervened, attemptId, effectToken, directPart, pendingBios,
        completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* Each ext2 direct mapped range first copies into a BioSegment, then submits.
\* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:383-391
BioSegmentWriteFallibleComplete(t) ==
    /\ pc[t] = "DirectCopy"
    /\ IsWrite(opKind[t])
    /\ backendMode[t] = Ext2Direct
    /\ dataOwner = t
    \* Completing the first abstract range is Positive overall progress;
    \* completing the second finishes the request.
    \* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:384-390
    /\ copied' = [copied EXCEPT ![t] =
        IF directPart[t] = 1 THEN Positive ELSE Complete]
    /\ copyFault' = [copyFault EXCEPT ![t] = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "DirectSubmit"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, committed, reported, copiedTotal,
        committedTotal, visibleTotal, reportedTotal, result, entryResult,
        ofdOffset, expectedOffset, offsetOwner, dataOwner, ioOffset,
        explicitOffset,
        appendMode, fileSize, expectedFileSize, oldFileSize, plannedEnd,
        sizePublicationOwners, pageState, rangeClass, fileSizeSnapshot,
        dataEpoch, entryDataEpoch, bufferEpochs, vectorIndex,
        vectorIntervened, attemptId, effectToken, directPart, pendingBios,
        completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* A direct-range zero-prefix fault exits through `?`; earlier submitted BIOs
\* remain in the local IoBatch but wait_all is skipped.
\* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:383-405
BioSegmentWriteFallibleFaultZero(t) ==
    /\ pc[t] = "DirectCopy"
    /\ IsWrite(opKind[t])
    /\ backendMode[t] = Ext2Direct
    /\ dataOwner = t
    \* Part two retains the already copied/submitted positive first range.
    \* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:384-390
    /\ copied' = [copied EXCEPT ![t] =
        IF directPart[t] = 1 THEN Zero ELSE Positive]
    /\ copyFault' = [copyFault EXCEPT ![t] = TRUE]
    /\ pc' = [pc EXCEPT ![t] = "DirectRollback"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, committed, reported, copiedTotal,
        committedTotal, visibleTotal, reportedTotal, result, entryResult,
        ofdOffset, expectedOffset, offsetOwner, dataOwner, ioOffset,
        explicitOffset,
        appendMode, fileSize, expectedFileSize, oldFileSize, plannedEnd,
        sizePublicationOwners, pageState, rangeClass, fileSizeSnapshot,
        dataEpoch, entryDataEpoch, bufferEpochs, vectorIndex,
        vectorIntervened, attemptId, effectToken, directPart, pendingBios,
        completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* A direct-range positive-prefix fault also exits before submission of that
\* range and before IoBatch::wait_all.
\* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:383-405
BioSegmentWriteFallibleFaultPositive(t) ==
    /\ pc[t] = "DirectCopy"
    /\ IsWrite(opKind[t])
    /\ backendMode[t] = Ext2Direct
    /\ dataOwner = t
    \* Aggregate progress remains Positive until all ranges finish.
    \* ostd/src/mm/io/mod.rs:347-359
    /\ copied' = [copied EXCEPT ![t] = Positive]
    /\ copyFault' = [copyFault EXCEPT ![t] = TRUE]
    /\ pc' = [pc EXCEPT ![t] = "DirectRollback"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, committed, reported, copiedTotal,
        committedTotal, visibleTotal, reportedTotal, result, entryResult,
        ofdOffset, expectedOffset, offsetOwner, dataOwner, ioOffset,
        explicitOffset,
        appendMode, fileSize, expectedFileSize, oldFileSize, plannedEnd,
        sizePublicationOwners, pageState, rangeClass, fileSizeSnapshot,
        dataEpoch, entryDataEpoch, bufferEpochs, vectorIndex,
        vectorIntervened, attemptId, effectToken, directPart, pendingBios,
        completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* Reference-only capability action at the FileOps error-propagation seam.
\* It is disabled for pinned ext2/ramfs, whose waits cannot return EINTR.  If a
\* future interruptible backend returns EINTR after a copy/publication, the
\* scalar wrappers and signal path receive only the errno, not its provenance.
\* kernel/core/src/fs/file/inode_handle.rs:287,317
\* kernel/core/src/syscall/read.rs:27-39
\* kernel/core/src/syscall/write.rs:27-39
\* ostd/src/sync/wait.rs:69-85
\* kernel/libs/io-util/src/batch.rs:147-164
InterruptibleBackendReturnEintr(t) ==
    /\ pc[t] = "BackendFinish"
    /\ opKind[t] \in {SharedRead, SharedWrite}
    /\ interruptibleBackend[t]
    /\ dataOwner = t
    \* A write backend may have made the copied prefix durable before its
    \* interruptible wait reports EINTR.  Reads retain their visible copy.
    \* The pinned implementations never take this capability branch.
    /\ committed' = [committed EXCEPT ![t] =
        IF IsWrite(opKind[t]) THEN copied[t] ELSE @]
    /\ dataEpoch' =
        IF IsWrite(opKind[t]) /\ ProgressUnits(copied[t]) > 0
        THEN dataEpoch + 1
        ELSE dataEpoch
    /\ commitCount' =
        IF IsWrite(opKind[t]) /\ ProgressUnits(copied[t]) > 0
        THEN [commitCount EXCEPT ![EffectKey(t, CurrentPart(t))] = @ + 1]
        ELSE commitCount
    /\ vectorIntervened' =
        IF IsWrite(opKind[t]) /\ ProgressUnits(copied[t]) > 0
        THEN MarkVectorIntervened(t)
        ELSE vectorIntervened
    /\ sizePublicationOwners' = sizePublicationOwners \ {t}
    /\ entryResult' = [entryResult EXCEPT ![t] = EntryEintr]
    /\ reported' = [reported EXCEPT ![t] = Zero]
    /\ pc' = [pc EXCEPT ![t] = "ReleaseData"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, copiedTotal,
        committedTotal, visibleTotal, reportedTotal, result, copyFault,
        ofdOffset, expectedOffset, offsetOwner, dataOwner, ioOffset,
        explicitOffset,
        appendMode, fileSize, expectedFileSize, oldFileSize, plannedEnd,
        pageState, rangeClass, fileSizeSnapshot, entryDataEpoch, bufferEpochs,
        vectorIndex, attemptId, effectToken, directPart, pendingBios,
        completedBios, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* Buffered ext2/ramfs FileOps finish the scalar read after the aggregate copy
\* outcome.  This includes ext2's pre-VMO EOF return.  When Vmo::read faults,
\* kernel Error conversion preserves only EFAULT, not the positive count.
\* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:228-242
\* kernel/core/src/fs/fs_impls/ramfs/fs.rs:701-710
\* kernel/core/src/vm/page_cache/vmo/mod.rs:533-566
\* kernel/core/src/error.rs:195-219
FileOpsReadAtFinish(t) ==
    /\ pc[t] = "BackendFinish"
    /\ IsRead(opKind[t])
    /\ backendMode[t] \in {Ext2Buffered, Ramfs}
    /\ dataOwner = t
    \* Fault returns report zero at the backend boundary.  On ramfs success,
    \* read_len still comes from the earlier EOF snapshot even if VMO copied
    \* farther into the page-cache capacity.
    \* kernel/core/src/fs/fs_impls/ramfs/fs.rs:701-710
    /\ LET snapshotUnits ==
            Min(ProgressUnits(requested[t]),
                IF fileSizeSnapshot[t] > ioOffset[t]
                THEN fileSizeSnapshot[t] - ioOffset[t]
                ELSE 0)
       IN reported' = [reported EXCEPT ![t] =
            IF copyFault[t]
            THEN Zero
            ELSE IF backendMode[t] = Ramfs
                 THEN ProgressOf(snapshotUnits)
                 ELSE copied[t]]
    \* Tuple conversion erases the copied prefix on every fault branch.
    \* kernel/core/src/error.rs:209-219
    /\ entryResult' = [entryResult EXCEPT ![t] =
        IF copyFault[t] THEN EntryFault ELSE EntryOk]
    /\ pc' = [pc EXCEPT ![t] = "ReleaseData"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, copiedTotal,
        committedTotal, visibleTotal, reportedTotal, result, copyFault,
        ofdOffset, expectedOffset, offsetOwner, dataOwner, ioOffset,
        explicitOffset, appendMode, fileSize, expectedFileSize, oldFileSize,
        plannedEnd, sizePublicationOwners, pageState, rangeClass,
        fileSizeSnapshot, dataEpoch, entryDataEpoch, bufferEpochs,
        vectorIndex, vectorIntervened, attemptId, effectToken, directPart,
        pendingBios, completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* Ext2 direct reads return through InodeInner::read_direct_at after the
\* mapped-range BioSegment copy.  The fallible tuple count is still erased by
\* `?`, but this path has distinct direct-I/O return sites from Vmo::read.
\* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:274-287,331-362
\* kernel/core/src/error.rs:209-219
InodeInnerReadDirectAtFinish(t) ==
    /\ pc[t] = "BackendFinish"
    /\ IsRead(opKind[t])
    /\ backendMode[t] = Ext2Direct
    /\ dataOwner = t
    \* read_direct_at returns read_len only when every mapped-range copy
    \* succeeds; a fallible-copy error propagates without its positive count.
    \* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:281-287,346-362
    /\ reported' = [reported EXCEPT ![t] =
        IF copyFault[t] THEN Zero ELSE copied[t]]
    /\ entryResult' = [entryResult EXCEPT ![t] =
        IF copyFault[t] THEN EntryFault ELSE EntryOk]
    /\ pc' = [pc EXCEPT ![t] = "ReleaseData"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, copiedTotal,
        committedTotal, visibleTotal, reportedTotal, result, copyFault,
        ofdOffset, expectedOffset, offsetOwner, dataOwner, ioOffset,
        explicitOffset, appendMode, fileSize, expectedFileSize, oldFileSize,
        plannedEnd, sizePublicationOwners, pageState, rangeClass,
        fileSizeSnapshot, dataEpoch, entryDataEpoch, bufferEpochs,
        vectorIndex, vectorIntervened, attemptId, effectToken, directPart,
        pendingBios, completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* Successful ext2 buffered copy dirties the page and commits file size after
\* page-cache write returns.
\* kernel/core/src/vm/page_cache/vmo/mod.rs:734-759
\* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:245-271
VmoWritePagesWithBackendFinishSuccess(t) ==
    /\ pc[t] = "BackendFinish"
    /\ IsWrite(opKind[t])
    /\ backendMode[t] = Ext2Buffered
    /\ dataOwner = t
    /\ ~copyFault[t]
    \* written_size > 0 transitions the cache page to Dirty.
    \* kernel/core/src/vm/page_cache/vmo/mod.rs:734-751
    /\ committed' = [committed EXCEPT ![t] = copied[t]]
    /\ dataEpoch' =
        IF ProgressUnits(copied[t]) > 0 THEN dataEpoch + 1 ELSE dataEpoch
    /\ commitCount' =
        IF ProgressUnits(copied[t]) > 0
        THEN [commitCount EXCEPT ![EffectKey(t, CurrentPart(t))] = @ + 1]
        ELSE commitCount
    /\ vectorIntervened' =
        IF ProgressUnits(copied[t]) > 0
        THEN MarkVectorIntervened(t)
        ELSE vectorIntervened
    \* ext2 commits size/timestamps only after page-cache write succeeds.
    \* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:262-271
    /\ fileSize' = Max(fileSize, plannedEnd[t])
    /\ expectedFileSize' = Max(expectedFileSize, plannedEnd[t])
    /\ reported' = [reported EXCEPT ![t] = copied[t]]
    /\ entryResult' = [entryResult EXCEPT ![t] = EntryOk]
    /\ pc' = [pc EXCEPT ![t] = "ReleaseData"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, copiedTotal, committedTotal,
        visibleTotal, reportedTotal, result, copyFault, ofdOffset,
        expectedOffset, offsetOwner, dataOwner, ioOffset, explicitOffset,
        appendMode, oldFileSize, plannedEnd, sizePublicationOwners, pageState,
        rangeClass, fileSizeSnapshot, entryDataEpoch, bufferEpochs,
        vectorIndex, attemptId, effectToken, directPart, pendingBios,
        completedBios, saRestart, restartPending, interruptibleBackend,
        positionalOFDExpected
        >>

\* A positive fault may retain the faulting UpToDate prefix or a prefix dirtied
\* by an earlier page iteration before a later Uninit page faults.  Rollback
\* does not undo retained data that intersects the old file.
\* kernel/core/src/vm/page_cache/vmo/mod.rs:724-750,1019-1052
\* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:262-265
VmoWritePagesWithBackendFaultRetain(t) ==
    /\ pc[t] = "BackendFinish"
    /\ IsWrite(opKind[t])
    /\ backendMode[t] = Ext2Buffered
    /\ dataOwner = t
    /\ copyFault[t]
    /\ copied[t] = Positive
    /\ committed[t] = Positive
    \* rollback_write truncates/zeroes an extension back to old EOF.  A dirty
    \* positive prefix remains visible only when it includes old-file data.
    \* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:204-219,262-265
    \* kernel/core/src/vm/page_cache/mod.rs:246-280
    /\ (rangeClass[t] = InPlace \/ ioOffset[t] < oldFileSize[t])
    \* Each successful earlier page is dirty before the loop advances; the
    \* faulting page is also dirty only when it was already UpToDate.
    \* kernel/core/src/vm/page_cache/vmo/mod.rs:724-750
    /\ dataEpoch' = dataEpoch + 1
    /\ commitCount' =
        [commitCount EXCEPT ![EffectKey(t, CurrentPart(t))] = @ + 1]
    /\ vectorIntervened' = MarkVectorIntervened(t)
    \* The scalar error contains no progress count and ext2 rolls back only the
    \* prepared extension metadata/block range.
    \* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:204-219,262-265
    /\ reported' = [reported EXCEPT ![t] = Zero]
    /\ entryResult' = [entryResult EXCEPT ![t] = EntryFault]
    /\ pc' = [pc EXCEPT ![t] = "ReleaseData"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, copiedTotal,
        committedTotal, visibleTotal, reportedTotal, result, copyFault, ofdOffset,
        expectedOffset, offsetOwner, dataOwner, ioOffset, explicitOffset,
        appendMode, fileSize, expectedFileSize, oldFileSize, plannedEnd,
        sizePublicationOwners, pageState, rangeClass, fileSizeSnapshot,
        entryDataEpoch, bufferEpochs, vectorIndex, attemptId, effectToken,
        directPart, pendingBios, completedBios, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* A zero-copy fault, or a positive Uninit-page fault with no earlier dirty
\* page, leaves no retained prefix.  Rollback also removes a prefix wholly
\* beyond the old EOF.
\* kernel/core/src/vm/page_cache/vmo/mod.rs:727-746,1019-1052
VmoWritePagesWithBackendFaultDiscard(t) ==
    /\ pc[t] = "BackendFinish"
    /\ IsWrite(opKind[t])
    /\ backendMode[t] = Ext2Buffered
    /\ dataOwner = t
    /\ copyFault[t]
    /\ (committed[t] = Zero
        \/ (rangeClass[t] = Extending /\ ioOffset[t] >= oldFileSize[t]))
    \* The fault branch keeps its Uninit page uninitialized, but earlier dirty
    \* pages are tracked independently.  rollback_write removes an extending
    \* prefix that begins wholly beyond the old EOF.
    \* kernel/core/src/vm/page_cache/vmo/mod.rs:724-750
    \* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:204-219,262-265
    \* kernel/core/src/vm/page_cache/mod.rs:246-280
    /\ committed' = [committed EXCEPT ![t] = Zero]
    /\ reported' = [reported EXCEPT ![t] = Zero]
    /\ entryResult' = [entryResult EXCEPT ![t] = EntryFault]
    /\ pc' = [pc EXCEPT ![t] = "ReleaseData"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, copiedTotal, committedTotal,
        visibleTotal, reportedTotal, result, copyFault, ofdOffset,
        expectedOffset, offsetOwner, dataOwner, ioOffset, explicitOffset,
        appendMode, fileSize, expectedFileSize, oldFileSize, plannedEnd,
        sizePublicationOwners, pageState, rangeClass, fileSizeSnapshot,
        dataEpoch, entryDataEpoch, bufferEpochs, vectorIndex,
        vectorIntervened, attemptId, effectToken, directPart, pendingBios,
        completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* ramfs anonymous-page writes and the reference interruptible backend retain
\* every copied prefix.  A successful ramfs call accounts for metadata size
\* published before copy; the reference backend keeps plannedEnd unchanged.
\* kernel/core/src/fs/fs_impls/ramfs/fs.rs:727-756
\* kernel/core/src/vm/page_cache/vmo/mod.rs:667-700
\* kernel/core/src/tla_trace.rs:762-830
VmoWriteAnonymousPagesFinishSuccess(t) ==
    /\ pc[t] = "BackendFinish"
    /\ IsWrite(opKind[t])
    /\ (backendMode[t] = Ramfs \/ interruptibleBackend[t])
    /\ dataOwner = t
    /\ ~copyFault[t]
    \* Anonymous pages already contain the copied bytes when write returns.
    \* kernel/core/src/vm/page_cache/vmo/mod.rs:681-699
    /\ committed' = [committed EXCEPT ![t] = copied[t]]
    /\ dataEpoch' =
        IF ProgressUnits(copied[t]) > 0 THEN dataEpoch + 1 ELSE dataEpoch
    /\ commitCount' =
        IF ProgressUnits(copied[t]) > 0
        THEN [commitCount EXCEPT ![EffectKey(t, CurrentPart(t))] = @ + 1]
        ELSE commitCount
    /\ vectorIntervened' =
        IF ProgressUnits(copied[t]) > 0
        THEN MarkVectorIntervened(t)
        ELSE vectorIntervened
    \* Successful write_len accounts for the pre-published end, including a
    \* zero-length request only when it does not expand the Linux contract.
    \* kernel/core/src/fs/fs_impls/ramfs/fs.rs:733-756
    /\ expectedFileSize' =
        IF ProgressUnits(copied[t]) > 0
        THEN Max(expectedFileSize, plannedEnd[t])
        ELSE expectedFileSize
    /\ sizePublicationOwners' = sizePublicationOwners \ {t}
    /\ reported' = [reported EXCEPT ![t] = copied[t]]
    /\ entryResult' = [entryResult EXCEPT ![t] = EntryOk]
    /\ pc' = [pc EXCEPT ![t] = "ReleaseData"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, copiedTotal, committedTotal,
        visibleTotal, reportedTotal, result, copyFault, ofdOffset,
        expectedOffset, offsetOwner, dataOwner, ioOffset, explicitOffset,
        appendMode, fileSize, oldFileSize, plannedEnd, pageState, rangeClass,
        fileSizeSnapshot, entryDataEpoch, bufferEpochs, vectorIndex,
        attemptId, effectToken, directPart, pendingBios, completedBios,
        saRestart, restartPending, interruptibleBackend, positionalOFDExpected
        >>

\* ramfs has no rollback after page-cache copy failure: size stays published,
\* and a positive anonymous-page prefix stays in data.
\* kernel/core/src/fs/fs_impls/ramfs/fs.rs:731-750
\* kernel/core/src/vm/page_cache/vmo/mod.rs:681-699
VmoWriteAnonymousPagesFinishFault(t) ==
    /\ pc[t] = "BackendFinish"
    /\ IsWrite(opKind[t])
    /\ backendMode[t] = Ramfs
    /\ dataOwner = t
    /\ copyFault[t]
    \* The fallible copy already advanced the anonymous page for a positive
    \* prefix; no dirty-state gate discards it.
    \* kernel/core/src/vm/page_cache/vmo/mod.rs:689-691
    /\ committed' = [committed EXCEPT ![t] = copied[t]]
    /\ dataEpoch' =
        IF ProgressUnits(copied[t]) > 0 THEN dataEpoch + 1 ELSE dataEpoch
    /\ commitCount' =
        IF ProgressUnits(copied[t]) > 0
        THEN [commitCount EXCEPT ![EffectKey(t, CurrentPart(t))] = @ + 1]
        ELSE commitCount
    /\ vectorIntervened' =
        IF ProgressUnits(copied[t]) > 0
        THEN MarkVectorIntervened(t)
        ELSE vectorIntervened
    \* `?` returns EFAULT without reverting inode_meta.size.
    \* kernel/core/src/fs/fs_impls/ramfs/fs.rs:741-750
    /\ sizePublicationOwners' = sizePublicationOwners \ {t}
    /\ reported' = [reported EXCEPT ![t] = Zero]
    /\ entryResult' = [entryResult EXCEPT ![t] = EntryFault]
    /\ pc' = [pc EXCEPT ![t] = "ReleaseData"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, copiedTotal, committedTotal,
        visibleTotal, reportedTotal, result, copyFault, ofdOffset,
        expectedOffset, offsetOwner, dataOwner, ioOffset, explicitOffset,
        appendMode, fileSize, expectedFileSize, oldFileSize, plannedEnd,
        pageState, rangeClass, fileSizeSnapshot, entryDataEpoch, bufferEpochs,
        vectorIndex, attemptId, effectToken, directPart, pendingBios,
        completedBios, saRestart, restartPending, interruptibleBackend,
        positionalOFDExpected
        >>

\* Bio::submit publishes Submit status, enqueues the request, and records its
\* completion in the caller's IoBatch.
\* kernel/core/comps/block/src/bio.rs:100-150
\* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:383-391
BioSubmit(t) ==
    /\ pc[t] = "DirectSubmit"
    /\ IsWrite(opKind[t])
    /\ backendMode[t] = Ext2Direct
    /\ dataOwner = t
    /\ BioKey(t, directPart[t]) \notin pendingBios \cup completedBios
    \* Successful enqueue transfers ownership and appends the completion
    \* record.  Submission is separate from device completion.
    \* kernel/core/comps/block/src/bio.rs:121-150
    /\ pendingBios' = pendingBios \cup {BioKey(t, directPart[t])}
    \* The range loop copies/submits the next mapping before wait_all.  After
    \* the second modeled range it waits for every submitted completion.
    \* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:383-405
    /\ pc' = [pc EXCEPT ![t] =
        IF directPart[t] = 1 THEN "DirectCopy" ELSE "DirectWait"]
    /\ directPart' = [directPart EXCEPT ![t] =
        IF directPart[t] = 1 THEN 2 ELSE directPart[t]]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, reported,
        copiedTotal, committedTotal, visibleTotal, reportedTotal, result,
        entryResult, copyFault, ofdOffset, expectedOffset, offsetOwner,
        dataOwner, ioOffset, explicitOffset, appendMode, fileSize,
        expectedFileSize, oldFileSize, plannedEnd, sizePublicationOwners,
        pageState, rangeClass, fileSizeSnapshot, dataEpoch, entryDataEpoch,
        bufferEpochs, vectorIndex, vectorIntervened, attemptId, effectToken,
        completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* Device completion publishes the data effect and final BIO status
\* independently of whether the submitting syscall is still waiting.
\* kernel/core/comps/block/src/bio.rs:239-270
SubmittedBioComplete(bio) ==
    /\ bio \in pendingBios
    \* Completion removes the outstanding record only after the device effect
    \* and callback have completed.
    \* kernel/core/comps/block/src/bio.rs:255-269
    /\ pendingBios' = pendingBios \ {bio}
    /\ completedBios' = completedBios \cup {bio}
    /\ dataEpoch' = dataEpoch + 1
    /\ commitCount' =
        [commitCount EXCEPT ![BioEffect(bio)] = @ + 1]
    /\ vectorIntervened' = MarkVectorWriteEffect(bio)
    \* If this is still the owner's current attempt, expose the positive/full
    \* completed class in that attempt's progress ledger.
    \* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:383-405
    /\ LET currentAttempt ==
                attemptId[bio[1]] = bio[2] /\ effectToken[bio[1]] = bio[3]
           allSegmentsComplete ==
                \A segment \in 1..VectorLength :
                    BioAtSegment(bio, segment) \in completedBios \cup {bio}
       IN committed' = [committed EXCEPT ![bio[1]] =
            IF currentAttempt
            THEN IF allSegmentsComplete THEN Complete ELSE Positive
            ELSE @]
    /\ UNCHANGED <<
        pc, opKind, backendMode, requested, copied, reported, copiedTotal,
        committedTotal, visibleTotal, reportedTotal, result, entryResult,
        copyFault, ofdOffset, expectedOffset, offsetOwner, dataOwner, ioOffset,
        explicitOffset, appendMode, fileSize, expectedFileSize, oldFileSize,
        plannedEnd, sizePublicationOwners, pageState, rangeClass,
        fileSizeSnapshot, entryDataEpoch, bufferEpochs, vectorIndex,
        attemptId, effectToken, directPart, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* write_direct_blocks waits for all submissions only after the range loop
\* finishes; every completion is waited even after an earlier error.
\* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:383-406
\* kernel/libs/io-util/src/batch.rs:147-164
IoBatchWaitAll(t) ==
    /\ pc[t] = "DirectWait"
    /\ backendMode[t] = Ext2Direct
    /\ dataOwner = t
    /\ AttemptBios(t) = {}
    \* With the modeled successful device completions drained, control returns
    \* to write_direct_at's metadata commit.
    \* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:405-406,319-328
    /\ pc' = [pc EXCEPT ![t] = "DirectMetadata"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, reported,
        copiedTotal, committedTotal, visibleTotal, reportedTotal, result,
        entryResult, copyFault, ofdOffset, expectedOffset, offsetOwner,
        dataOwner, ioOffset, explicitOffset, appendMode, fileSize,
        expectedFileSize, oldFileSize, plannedEnd, sizePublicationOwners,
        pageState, rangeClass, fileSizeSnapshot, dataEpoch, entryDataEpoch,
        bufferEpochs, vectorIndex, vectorIntervened, attemptId, effectToken,
        directPart, pendingBios, completedBios, commitCount, saRestart,
        restartPending, interruptibleBackend, positionalOFDExpected
        >>

\* A successful direct write updates timestamps/size only after wait_all.
\* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:319-328
InodeInnerWriteDirectAtCommit(t) ==
    /\ pc[t] = "DirectMetadata"
    /\ backendMode[t] = Ext2Direct
    /\ dataOwner = t
    \* Both abstract ranges completed before write_len is returned.
    \* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:324-328
    /\ committed' = [committed EXCEPT ![t] = Complete]
    /\ fileSize' = Max(fileSize, plannedEnd[t])
    /\ expectedFileSize' = Max(expectedFileSize, plannedEnd[t])
    /\ reported' = [reported EXCEPT ![t] = Complete]
    /\ entryResult' = [entryResult EXCEPT ![t] = EntryOk]
    /\ pc' = [pc EXCEPT ![t] = "ReleaseData"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, copiedTotal, committedTotal,
        visibleTotal, reportedTotal, result, copyFault, ofdOffset,
        expectedOffset, offsetOwner, dataOwner, ioOffset, explicitOffset,
        appendMode, oldFileSize, plannedEnd, sizePublicationOwners, pageState,
        rangeClass, fileSizeSnapshot, dataEpoch, entryDataEpoch, bufferEpochs,
        vectorIndex, vectorIntervened, attemptId, effectToken, directPart,
        pendingBios, completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* A direct-copy fault invokes rollback_write and returns immediately; it does
\* not call wait_all or cancel an earlier submitted range.
\* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:204-219,319-321,383-405
InodeInnerWriteDirectAtRollback(t) ==
    /\ pc[t] = "DirectRollback"
    /\ backendMode[t] = Ext2Direct
    /\ dataOwner = t
    /\ copyFault[t]
    \* Extension metadata/block preparation is rolled back, while any pending
    \* or already completed BIO remains as modeled global state.
    \* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:204-219,319-321
    /\ reported' = [reported EXCEPT ![t] = Zero]
    /\ entryResult' = [entryResult EXCEPT ![t] = EntryFault]
    /\ pc' = [pc EXCEPT ![t] = "ReleaseData"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, copiedTotal,
        committedTotal, visibleTotal, reportedTotal, result, copyFault,
        ofdOffset, expectedOffset, offsetOwner, dataOwner, ioOffset,
        explicitOffset, appendMode, fileSize, expectedFileSize, oldFileSize,
        plannedEnd, sizePublicationOwners, pageState, rangeClass,
        fileSizeSnapshot, dataEpoch, entryDataEpoch, bufferEpochs,
        vectorIndex, vectorIntervened, attemptId, effectToken, directPart,
        pendingBios, completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* Returning from the backend method drops its inode/page-cache guard before
\* InodeHandle consumes the Result and publishes a shared offset update.
\* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:31-35,49-52,69-74,93-96
\* kernel/core/src/fs/fs_impls/ramfs/fs.rs:701-710,727-756
FileOpsReleaseData(t) ==
    /\ pc[t] = "ReleaseData"
    /\ dataOwner = t
    \* The backend guard is out of scope while a shared caller still holds its
    \* distinct InodeHandle::offset guard.
    \* kernel/core/src/fs/file/inode_handle.rs:285-290,308-320
    /\ dataOwner' = NoThread
    /\ pc' = [pc EXCEPT ![t] = "InodeReturn"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, reported,
        copiedTotal, committedTotal, visibleTotal, reportedTotal, result,
        entryResult, copyFault, ofdOffset, expectedOffset, offsetOwner,
        ioOffset, explicitOffset, appendMode, fileSize, expectedFileSize,
        oldFileSize, plannedEnd, sizePublicationOwners, pageState, rangeClass,
        fileSizeSnapshot, dataEpoch, entryDataEpoch, bufferEpochs, vectorIndex,
        vectorIntervened, attemptId, effectToken, directPart, pendingBios,
        completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* Successful InodeHandle::read publishes the returned length to the shared
\* offset only for nonpositional operations after the backend guard has gone.
\* kernel/core/src/fs/file/inode_handle.rs:273-290,323-332
InodeHandleReadReturnOk(t) ==
    /\ pc[t] = "InodeReturn"
    /\ IsRead(opKind[t])
    /\ entryResult[t] = EntryOk
    /\ dataOwner # t
    /\ (IsPositional(opKind[t]) \/ offsetOwner = t)
    \* `?` succeeded, so shared read adds len; read_at never touches f_pos.
    \* kernel/core/src/fs/file/inode_handle.rs:285-290,323-332
    /\ ofdOffset' =
        IF IsShared(opKind[t])
        THEN ofdOffset + ProgressUnits(reported[t])
        ELSE ofdOffset
    /\ expectedOffset' =
        IF IsShared(opKind[t])
        THEN expectedOffset + ProgressUnits(reported[t])
        ELSE expectedOffset
    /\ positionalOFDExpected' =
        IF IsShared(opKind[t])
        THEN TrackPositionalOFD(ofdOffset + ProgressUnits(reported[t]))
        ELSE positionalOFDExpected
    \* The shared OFD guard is released before a vector loop decides whether to
    \* dispatch another entry; FileOpsReleaseData already dropped the backend
    \* guard in the preceding action.
    \* kernel/core/src/syscall/preadv.rs:165-174
    /\ offsetOwner' = IF IsShared(opKind[t]) THEN NoThread ELSE offsetOwner
    /\ pc' = [pc EXCEPT ![t] =
        IF opKind[t] = VectorRead THEN "VectorDispatch"
        ELSE "SyscallDispatch"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, reported,
        copiedTotal, committedTotal, visibleTotal, reportedTotal, result,
        entryResult, copyFault, dataOwner, ioOffset, explicitOffset, appendMode, fileSize,
        expectedFileSize, oldFileSize, plannedEnd, sizePublicationOwners,
        pageState, rangeClass, fileSizeSnapshot, dataEpoch, entryDataEpoch,
        bufferEpochs, vectorIndex, vectorIntervened, attemptId, effectToken,
        directPart, pendingBios, completedBios, commitCount, saRestart,
        restartPending, interruptibleBackend
        >>

\* On backend error, InodeHandle's `?` skips offset addition.  Positional reads
\* also remain offset-neutral.
\* kernel/core/src/fs/file/inode_handle.rs:285-290,323-332
InodeHandleReadReturnError(t) ==
    /\ pc[t] = "InodeReturn"
    /\ IsRead(opKind[t])
    /\ entryResult[t] \in {EntryFault, EntryEintr}
    /\ dataOwner # t
    /\ (IsPositional(opKind[t]) \/ offsetOwner = t)
    \* FileOpsReleaseData already dropped the backend guard.  Error unwinding
    \* now releases only the OFD guard without `*offset += len`.
    \* kernel/core/src/fs/file/inode_handle.rs:285-290
    /\ offsetOwner' = IF IsShared(opKind[t]) THEN NoThread ELSE offsetOwner
    /\ pc' = [pc EXCEPT ![t] =
        IF opKind[t] = VectorRead THEN "VectorDispatch"
        ELSE "SyscallDispatch"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, reported,
        copiedTotal, committedTotal, visibleTotal, reportedTotal, result,
        entryResult, copyFault, ofdOffset, expectedOffset, dataOwner, ioOffset,
        explicitOffset, appendMode, fileSize, expectedFileSize, oldFileSize,
        plannedEnd, sizePublicationOwners, pageState, rangeClass,
        fileSizeSnapshot, dataEpoch, entryDataEpoch, bufferEpochs,
        vectorIndex, vectorIntervened, attemptId, effectToken, directPart,
        pendingBios, completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* Successful InodeHandle::write publishes len to f_pos after the backend
\* returns.  O_APPEND's contract base becomes the selected EOF only here.
\* kernel/core/src/fs/file/inode_handle.rs:293-320,334-353
InodeHandleWriteReturnOk(t) ==
    /\ pc[t] = "InodeReturn"
    /\ IsWrite(opKind[t])
    /\ entryResult[t] = EntryOk
    /\ dataOwner # t
    /\ (IsPositional(opKind[t]) \/ offsetOwner = t)
    \* Actual shared state adds the backend len to either prior f_pos or the
    \* already selected append EOF; positional writes leave it unchanged.
    \* kernel/core/src/fs/file/inode_handle.rs:308-320,334-353
    /\ ofdOffset' =
        IF IsShared(opKind[t])
        THEN ofdOffset + ProgressUnits(reported[t])
        ELSE ofdOffset
    /\ expectedOffset' =
        IF IsShared(opKind[t])
        THEN IF appendMode[t]
             THEN ioOffset[t] + ProgressUnits(reported[t])
             ELSE expectedOffset + ProgressUnits(reported[t])
        ELSE expectedOffset
    /\ positionalOFDExpected' =
        IF IsShared(opKind[t])
        THEN TrackPositionalOFD(ofdOffset + ProgressUnits(reported[t]))
        ELSE positionalOFDExpected
    \* Release the OFD section before vector dispatch.  The backend guard was
    \* released separately by FileOpsReleaseData.
    \* kernel/core/src/syscall/pwritev.rs:161-170
    /\ offsetOwner' = IF IsShared(opKind[t]) THEN NoThread ELSE offsetOwner
    /\ pc' = [pc EXCEPT ![t] =
        IF opKind[t] = VectorWrite THEN "VectorDispatch"
        ELSE "SyscallDispatch"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, reported,
        copiedTotal, committedTotal, visibleTotal, reportedTotal, result,
        entryResult, copyFault, dataOwner, ioOffset, explicitOffset, appendMode, fileSize,
        expectedFileSize, oldFileSize, plannedEnd, sizePublicationOwners,
        pageState, rangeClass, fileSizeSnapshot, dataEpoch, entryDataEpoch,
        bufferEpochs, vectorIndex, vectorIntervened, attemptId, effectToken,
        directPart, pendingBios, completedBios, commitCount, saRestart,
        restartPending, interruptibleBackend
        >>

\* On write error, the post-call `+= len` is skipped.  An earlier O_APPEND
\* assignment is not rolled back.
\* kernel/core/src/fs/file/inode_handle.rs:308-320,334-353
InodeHandleWriteReturnError(t) ==
    /\ pc[t] = "InodeReturn"
    /\ IsWrite(opKind[t])
    /\ entryResult[t] \in {EntryFault, EntryEintr}
    /\ dataOwner # t
    /\ (IsPositional(opKind[t]) \/ offsetOwner = t)
    \* The backend guard is already gone; error unwinding releases the OFD guard
    \* without changing f_pos here.
    \* kernel/core/src/fs/file/inode_handle.rs:317-320
    /\ offsetOwner' = IF IsShared(opKind[t]) THEN NoThread ELSE offsetOwner
    /\ pc' = [pc EXCEPT ![t] =
        IF opKind[t] = VectorWrite THEN "VectorDispatch"
        ELSE "SyscallDispatch"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, reported,
        copiedTotal, committedTotal, visibleTotal, reportedTotal, result,
        entryResult, copyFault, ofdOffset, expectedOffset, dataOwner, ioOffset,
        explicitOffset, appendMode, fileSize, expectedFileSize, oldFileSize,
        plannedEnd, sizePublicationOwners, pageState, rangeClass,
        fileSizeSnapshot, dataEpoch, entryDataEpoch, bufferEpochs,
        vectorIndex, vectorIntervened, attemptId, effectToken, directPart,
        pendingBios, completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* do_sys_readv adds one successful scalar result, observes whether the
\* VmWriter still has space, and only then starts the next entry.
\* kernel/core/src/syscall/preadv.rs:152-174
DoSysReadvEntryOkContinue(t) ==
    /\ pc[t] = "VectorDispatch"
    /\ opKind[t] = VectorRead
    /\ entryResult[t] = EntryOk
    /\ vectorIndex[t] < VectorLength
    /\ ProgressUnits(reported[t]) = ProgressUnits(requested[t])
    \* total_len accumulates the scalar return; copied visibility is tracked
    \* separately because a ramfs read may have copied beyond read_len.
    \* kernel/core/src/syscall/preadv.rs:165-170
    /\ copiedTotal' =
        [copiedTotal EXCEPT ![t] = @ + ProgressUnits(copied[t])]
    /\ visibleTotal' =
        [visibleTotal EXCEPT ![t] = @ + ProgressUnits(copied[t])]
    /\ committedTotal' =
        [committedTotal EXCEPT ![t] = @ + ProgressUnits(committed[t])]
    /\ reportedTotal' =
        [reportedTotal EXCEPT ![t] = @ + ProgressUnits(reported[t])]
    /\ bufferEpochs' =
        [bufferEpochs EXCEPT ![t] = Append(@, entryDataEpoch[t])]
    \* writer.has_avail() is false, so the loop releases all scalar state and
    \* acquires the OFD mutex again for the next iovec.
    \* kernel/core/src/syscall/preadv.rs:156-174
    /\ vectorIndex' = [vectorIndex EXCEPT ![t] = @ + 1]
    /\ copied' = [copied EXCEPT ![t] = Zero]
    /\ committed' = [committed EXCEPT ![t] = Zero]
    /\ reported' = [reported EXCEPT ![t] = Zero]
    /\ entryResult' = [entryResult EXCEPT ![t] = NoEntryResult]
    /\ copyFault' = [copyFault EXCEPT ![t] = FALSE]
    /\ entryDataEpoch' = [entryDataEpoch EXCEPT ![t] = dataEpoch]
    /\ directPart' = [directPart EXCEPT ![t] = 1]
    /\ pc' = [pc EXCEPT ![t] = "AcquireOffset"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, result, ofdOffset, expectedOffset,
        offsetOwner, dataOwner, ioOffset, explicitOffset, appendMode,
        fileSize, expectedFileSize, oldFileSize, plannedEnd,
        sizePublicationOwners, pageState, rangeClass, fileSizeSnapshot,
        dataEpoch, vectorIntervened, attemptId, effectToken,
        pendingBios, completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* EOF/partial success or the final readv entry returns the accumulated total.
\* kernel/core/src/syscall/preadv.rs:165-180
DoSysReadvEntryOkReturn(t) ==
    /\ pc[t] = "VectorDispatch"
    /\ opKind[t] = VectorRead
    /\ entryResult[t] = EntryOk
    /\ (vectorIndex[t] = VectorLength
        \/ ProgressUnits(reported[t]) < ProgressUnits(requested[t]))
    \* Persist the final copied/report totals and generation sequence.
    \* kernel/core/src/syscall/preadv.rs:165-180
    /\ LET finalCopied == copiedTotal[t] + ProgressUnits(copied[t])
           finalReported == reportedTotal[t] + ProgressUnits(reported[t])
       IN /\ copiedTotal' = [copiedTotal EXCEPT ![t] = finalCopied]
          /\ visibleTotal' = [visibleTotal EXCEPT ![t] = finalCopied]
          /\ committedTotal' =
                [committedTotal EXCEPT ![t] = @ + ProgressUnits(committed[t])]
          /\ reportedTotal' = [reportedTotal EXCEPT ![t] = finalReported]
          /\ result' = [result EXCEPT ![t] =
                IF finalReported = VectorLength * ProgressUnits(Complete)
                THEN Success ELSE ShortSuccess]
    /\ bufferEpochs' =
        [bufferEpochs EXCEPT ![t] = Append(@, entryDataEpoch[t])]
    /\ pc' = [pc EXCEPT ![t] = "Idle"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, reported,
        entryResult, copyFault, ofdOffset, expectedOffset, offsetOwner,
        dataOwner, ioOffset, explicitOffset, appendMode, fileSize,
        expectedFileSize, oldFileSize, plannedEnd, sizePublicationOwners,
        pageState, rangeClass, fileSizeSnapshot, dataEpoch, entryDataEpoch,
        vectorIndex, vectorIntervened, attemptId, effectToken, directPart,
        pendingBios, completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* A faulting readv entry is suppressed only when an earlier entry contributed
\* total_len.  The faulting entry's positive copied prefix is not added to the
\* returned total.
\* kernel/core/src/syscall/preadv.rs:165-180
DoSysReadvEntryFaultReturn(t) ==
    /\ pc[t] = "VectorDispatch"
    /\ opKind[t] = VectorRead
    /\ entryResult[t] = EntryFault
    \* Preserve copied visibility from the faulting entry while leaving
    \* reportedTotal unchanged, matching the erased tuple count.
    \* kernel/core/src/syscall/preadv.rs:165-169
    /\ copiedTotal' =
        [copiedTotal EXCEPT ![t] = @ + ProgressUnits(copied[t])]
    /\ visibleTotal' =
        [visibleTotal EXCEPT ![t] = @ + ProgressUnits(copied[t])]
    /\ committedTotal' =
        [committedTotal EXCEPT ![t] = @ + ProgressUnits(committed[t])]
    /\ result' = [result EXCEPT ![t] =
        IF reportedTotal[t] > 0 THEN ShortSuccess ELSE Fault]
    /\ bufferEpochs' =
        [bufferEpochs EXCEPT ![t] = Append(@, entryDataEpoch[t])]
    /\ pc' = [pc EXCEPT ![t] = "Idle"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, reported,
        reportedTotal, entryResult, copyFault, ofdOffset, expectedOffset,
        offsetOwner, dataOwner, ioOffset, explicitOffset, appendMode,
        fileSize, expectedFileSize, oldFileSize, plannedEnd,
        sizePublicationOwners, pageState, rangeClass, fileSizeSnapshot,
        dataEpoch, entryDataEpoch, vectorIndex, vectorIntervened, attemptId,
        effectToken, directPart, pendingBios, completedBios, commitCount,
        saRestart, restartPending, interruptibleBackend, positionalOFDExpected
        >>

\* do_sys_writev adds one successful scalar result and starts the next entry
\* only when the VmReader was fully consumed.
\* kernel/core/src/syscall/pwritev.rs:148-170
DoSysWritevEntryOkContinue(t) ==
    /\ pc[t] = "VectorDispatch"
    /\ opKind[t] = VectorWrite
    /\ entryResult[t] = EntryOk
    /\ vectorIndex[t] < VectorLength
    /\ ProgressUnits(reported[t]) = ProgressUnits(requested[t])
    \* Track physical copy/commit separately from the accumulated syscall len.
    \* kernel/core/src/syscall/pwritev.rs:161-166
    /\ copiedTotal' =
        [copiedTotal EXCEPT ![t] = @ + ProgressUnits(copied[t])]
    /\ committedTotal' =
        [committedTotal EXCEPT ![t] = @ + ProgressUnits(committed[t])]
    /\ reportedTotal' =
        [reportedTotal EXCEPT ![t] = @ + ProgressUnits(reported[t])]
    \* reader.has_remain() is false; the next iteration reacquires both locks.
    \* kernel/core/src/syscall/pwritev.rs:152-170
    /\ vectorIndex' = [vectorIndex EXCEPT ![t] = @ + 1]
    /\ copied' = [copied EXCEPT ![t] = Zero]
    /\ committed' = [committed EXCEPT ![t] = Zero]
    /\ reported' = [reported EXCEPT ![t] = Zero]
    /\ entryResult' = [entryResult EXCEPT ![t] = NoEntryResult]
    /\ copyFault' = [copyFault EXCEPT ![t] = FALSE]
    /\ entryDataEpoch' = [entryDataEpoch EXCEPT ![t] = dataEpoch]
    /\ directPart' = [directPart EXCEPT ![t] = 1]
    /\ pc' = [pc EXCEPT ![t] = "AcquireOffset"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, visibleTotal, result, ofdOffset,
        expectedOffset, offsetOwner, dataOwner, ioOffset, explicitOffset,
        appendMode, fileSize, expectedFileSize, oldFileSize, plannedEnd,
        sizePublicationOwners, pageState, rangeClass, fileSizeSnapshot,
        dataEpoch, bufferEpochs, vectorIntervened, attemptId, effectToken,
        pendingBios, completedBios, commitCount, saRestart,
        restartPending, interruptibleBackend, positionalOFDExpected
        >>

\* Partial success or the final writev entry returns total_len.
\* kernel/core/src/syscall/pwritev.rs:161-175
DoSysWritevEntryOkReturn(t) ==
    /\ pc[t] = "VectorDispatch"
    /\ opKind[t] = VectorWrite
    /\ entryResult[t] = EntryOk
    /\ (vectorIndex[t] = VectorLength
        \/ ProgressUnits(reported[t]) < ProgressUnits(requested[t]))
    \* Persist final copy, commit, and report totals.
    \* kernel/core/src/syscall/pwritev.rs:161-175
    /\ LET finalReported == reportedTotal[t] + ProgressUnits(reported[t])
       IN /\ copiedTotal' =
                [copiedTotal EXCEPT ![t] = @ + ProgressUnits(copied[t])]
          /\ committedTotal' =
                [committedTotal EXCEPT ![t] = @ + ProgressUnits(committed[t])]
          /\ reportedTotal' = [reportedTotal EXCEPT ![t] = finalReported]
          /\ result' = [result EXCEPT ![t] =
                IF finalReported = VectorLength * ProgressUnits(Complete)
                THEN Success ELSE ShortSuccess]
    /\ pc' = [pc EXCEPT ![t] = "Idle"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, reported,
        visibleTotal, entryResult, copyFault, ofdOffset, expectedOffset,
        offsetOwner, dataOwner, ioOffset, explicitOffset, appendMode,
        fileSize, expectedFileSize, oldFileSize, plannedEnd,
        sizePublicationOwners, pageState, rangeClass, fileSizeSnapshot,
        dataEpoch, entryDataEpoch, bufferEpochs, vectorIndex,
        vectorIntervened, attemptId, effectToken, directPart, pendingBios,
        completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* A faulting writev entry is suppressed after earlier reported progress, but
\* its retained backend prefix is not added to total_len.
\* kernel/core/src/syscall/pwritev.rs:161-175
DoSysWritevEntryFaultReturn(t) ==
    /\ pc[t] = "VectorDispatch"
    /\ opKind[t] = VectorWrite
    /\ entryResult[t] = EntryFault
    \* Accumulate copied/committed physical progress only; the error branch
    \* leaves reportedTotal unchanged.
    \* kernel/core/src/syscall/pwritev.rs:161-165
    /\ copiedTotal' =
        [copiedTotal EXCEPT ![t] = @ + ProgressUnits(copied[t])]
    /\ committedTotal' =
        [committedTotal EXCEPT ![t] = @ + ProgressUnits(committed[t])]
    /\ result' = [result EXCEPT ![t] =
        IF reportedTotal[t] > 0 THEN ShortSuccess ELSE Fault]
    /\ pc' = [pc EXCEPT ![t] = "Idle"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, reported,
        visibleTotal, reportedTotal, entryResult, copyFault, ofdOffset,
        expectedOffset, offsetOwner, dataOwner, ioOffset, explicitOffset,
        appendMode, fileSize, expectedFileSize, oldFileSize, plannedEnd,
        sizePublicationOwners, pageState, rangeClass, fileSizeSnapshot,
        dataEpoch, entryDataEpoch, bufferEpochs, vectorIndex,
        vectorIntervened, attemptId, effectToken, directPart, pendingBios,
        completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* sys_read returns the scalar backend result after EINTR mapping.  This action
\* handles the non-EINTR success/EFAULT paths.
\* kernel/core/src/syscall/read.rs:27-44
SysReadReturn(t) ==
    /\ pc[t] = "SyscallDispatch"
    /\ opKind[t] = SharedRead
    /\ entryResult[t] \in {EntryOk, EntryFault}
    \* The syscall's visible result uses only the scalar Result<usize>; copied
    \* prefix state is carried separately for the invariant.
    \* kernel/core/src/syscall/read.rs:27-44
    /\ copiedTotal' = [copiedTotal EXCEPT ![t] = ProgressUnits(copied[t])]
    /\ visibleTotal' = [visibleTotal EXCEPT ![t] = ProgressUnits(copied[t])]
    /\ committedTotal' =
        [committedTotal EXCEPT ![t] = ProgressUnits(committed[t])]
    /\ reportedTotal' =
        [reportedTotal EXCEPT ![t] = ProgressUnits(reported[t])]
    /\ result' = [result EXCEPT ![t] =
        IF entryResult[t] = EntryOk THEN Success ELSE Fault]
    /\ pc' = [pc EXCEPT ![t] = "Idle"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, reported,
        entryResult, copyFault, ofdOffset, expectedOffset, offsetOwner,
        dataOwner, ioOffset, explicitOffset, appendMode, fileSize,
        expectedFileSize, oldFileSize, plannedEnd, sizePublicationOwners,
        pageState, rangeClass, fileSizeSnapshot, dataEpoch, entryDataEpoch,
        bufferEpochs, vectorIndex, vectorIntervened, attemptId, effectToken,
        directPart, pendingBios, completedBios, commitCount, saRestart,
        restartPending, interruptibleBackend, positionalOFDExpected
        >>

\* sys_write returns the scalar Result<usize> after EINTR mapping.
\* kernel/core/src/syscall/write.rs:27-44
SysWriteReturn(t) ==
    /\ pc[t] = "SyscallDispatch"
    /\ opKind[t] = SharedWrite
    /\ entryResult[t] \in {EntryOk, EntryFault}
    \* A scalar error reports zero even when the backend retained copied data.
    \* kernel/core/src/syscall/write.rs:27-44
    /\ copiedTotal' = [copiedTotal EXCEPT ![t] = ProgressUnits(copied[t])]
    /\ committedTotal' =
        [committedTotal EXCEPT ![t] = ProgressUnits(committed[t])]
    /\ reportedTotal' =
        [reportedTotal EXCEPT ![t] = ProgressUnits(reported[t])]
    /\ result' = [result EXCEPT ![t] =
        IF entryResult[t] = EntryOk THEN Success ELSE Fault]
    /\ pc' = [pc EXCEPT ![t] = "Idle"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, reported,
        visibleTotal, entryResult, copyFault, ofdOffset, expectedOffset,
        offsetOwner, dataOwner, ioOffset, explicitOffset, appendMode,
        fileSize, expectedFileSize, oldFileSize, plannedEnd,
        sizePublicationOwners, pageState, rangeClass, fileSizeSnapshot,
        dataEpoch, entryDataEpoch, bufferEpochs, vectorIndex,
        vectorIntervened, attemptId, effectToken, directPart, pendingBios,
        completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* sys_pread64 uses the same scalar result but never publishes a shared offset.
\* kernel/core/src/syscall/pread64.rs:22-43
SysPread64Return(t) ==
    /\ pc[t] = "SyscallDispatch"
    /\ opKind[t] = PositionalRead
    /\ entryResult[t] \in {EntryOk, EntryFault}
    \* Return the backend read_len/error and preserve the copied-prefix ledger.
    \* kernel/core/src/syscall/pread64.rs:33-43
    /\ copiedTotal' = [copiedTotal EXCEPT ![t] = ProgressUnits(copied[t])]
    /\ visibleTotal' = [visibleTotal EXCEPT ![t] = ProgressUnits(copied[t])]
    /\ committedTotal' =
        [committedTotal EXCEPT ![t] = ProgressUnits(committed[t])]
    /\ reportedTotal' =
        [reportedTotal EXCEPT ![t] = ProgressUnits(reported[t])]
    /\ result' = [result EXCEPT ![t] =
        IF entryResult[t] = EntryOk THEN Success ELSE Fault]
    /\ pc' = [pc EXCEPT ![t] = "Idle"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, reported,
        entryResult, copyFault, ofdOffset, expectedOffset, offsetOwner,
        dataOwner, ioOffset, explicitOffset, appendMode, fileSize,
        expectedFileSize, oldFileSize, plannedEnd, sizePublicationOwners,
        pageState, rangeClass, fileSizeSnapshot, dataEpoch, entryDataEpoch,
        bufferEpochs, vectorIndex, vectorIntervened, attemptId, effectToken,
        directPart, pendingBios, completedBios, commitCount, saRestart,
        restartPending, interruptibleBackend, positionalOFDExpected
        >>

\* sys_pwrite64 returns a local-position write result and leaves f_pos alone.
\* kernel/core/src/syscall/pwrite64.rs:22-41
SysPwrite64Return(t) ==
    /\ pc[t] = "SyscallDispatch"
    /\ opKind[t] = PositionalWrite
    /\ entryResult[t] \in {EntryOk, EntryFault}
    \* Preserve physical copied/committed state beside the scalar result.
    \* kernel/core/src/syscall/pwrite64.rs:33-41
    /\ copiedTotal' = [copiedTotal EXCEPT ![t] = ProgressUnits(copied[t])]
    /\ committedTotal' =
        [committedTotal EXCEPT ![t] = ProgressUnits(committed[t])]
    /\ reportedTotal' =
        [reportedTotal EXCEPT ![t] = ProgressUnits(reported[t])]
    /\ result' = [result EXCEPT ![t] =
        IF entryResult[t] = EntryOk THEN Success ELSE Fault]
    /\ pc' = [pc EXCEPT ![t] = "Idle"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, reported,
        visibleTotal, entryResult, copyFault, ofdOffset, expectedOffset,
        offsetOwner, dataOwner, ioOffset, explicitOffset, appendMode,
        fileSize, expectedFileSize, oldFileSize, plannedEnd,
        sizePublicationOwners, pageState, rangeClass, fileSizeSnapshot,
        dataEpoch, entryDataEpoch, bufferEpochs, vectorIndex,
        vectorIntervened, attemptId, effectToken, directPart, pendingBios,
        completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* sys_read translates a backend EINTR into the internal ERESTARTSYS errno.
\* kernel/core/src/syscall/read.rs:27-39
SysReadTranslateEintr(t) ==
    /\ pc[t] = "SyscallDispatch"
    /\ opKind[t] = SharedRead
    /\ entryResult[t] = EntryEintr
    \* The mapping carries no copied/committed provenance.
    \* kernel/core/src/syscall/read.rs:36-39
    /\ entryResult' = [entryResult EXCEPT ![t] = EntryRestartSys]
    /\ pc' = [pc EXCEPT ![t] = "SignalClassify"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, reported,
        copiedTotal, committedTotal, visibleTotal, reportedTotal, result,
        copyFault, ofdOffset, expectedOffset, offsetOwner, dataOwner, ioOffset,
        explicitOffset, appendMode, fileSize, expectedFileSize, oldFileSize,
        plannedEnd, sizePublicationOwners, pageState, rangeClass,
        fileSizeSnapshot, dataEpoch, entryDataEpoch, bufferEpochs,
        vectorIndex, vectorIntervened, attemptId, effectToken, directPart,
        pendingBios, completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* sys_write performs the same EINTR-to-ERESTARTSYS translation.
\* kernel/core/src/syscall/write.rs:27-39
SysWriteTranslateEintr(t) ==
    /\ pc[t] = "SyscallDispatch"
    /\ opKind[t] = SharedWrite
    /\ entryResult[t] = EntryEintr
    \* The mapping carries no copied/committed provenance.
    \* kernel/core/src/syscall/write.rs:36-39
    /\ entryResult' = [entryResult EXCEPT ![t] = EntryRestartSys]
    /\ pc' = [pc EXCEPT ![t] = "SignalClassify"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, reported,
        copiedTotal, committedTotal, visibleTotal, reportedTotal, result,
        copyFault, ofdOffset, expectedOffset, offsetOwner, dataOwner, ioOffset,
        explicitOffset, appendMode, fileSize, expectedFileSize, oldFileSize,
        plannedEnd, sizePublicationOwners, pageState, rangeClass,
        fileSizeSnapshot, dataEpoch, entryDataEpoch, bufferEpochs,
        vectorIndex, vectorIntervened, attemptId, effectToken, directPart,
        pendingBios, completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* Signal handling first converts the internal restart errno to userspace
\* EINTR while retaining the original syscall return value.
\* kernel/core/src/process/signal/mod.rs:48-62
HandlePendingSignalClassify(t) ==
    /\ pc[t] = "SignalClassify"
    /\ entryResult[t] = EntryRestartSys
    \* ERESTARTSYS is never exposed directly to userspace.
    \* kernel/core/src/process/signal/mod.rs:54-62
    /\ result' = [result EXCEPT ![t] = Interrupted]
    /\ pc' = [pc EXCEPT ![t] = "SignalDeliver"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, reported,
        copiedTotal, committedTotal, visibleTotal, reportedTotal, entryResult,
        copyFault, ofdOffset, expectedOffset, offsetOwner, dataOwner, ioOffset,
        explicitOffset, appendMode, fileSize, expectedFileSize, oldFileSize,
        plannedEnd, sizePublicationOwners, pageState, rangeClass,
        fileSizeSnapshot, dataEpoch, entryDataEpoch, bufferEpochs,
        vectorIndex, vectorIntervened, attemptId, effectToken, directPart,
        pendingBios, completedBios, commitCount, saRestart, restartPending,
        interruptibleBackend, positionalOFDExpected
        >>

\* A user handler with SA_RESTART restores the original arguments/return and
\* rewinds the instruction pointer to the syscall instruction.
\* kernel/core/src/process/signal/mod.rs:145-158
HandlePendingSignalRestart(t) ==
    /\ pc[t] = "SignalDeliver"
    /\ saRestart[t]
    \* Signal delivery consults only ERESTARTSYS and SA_RESTART.  It does not
    \* inspect copied or committed progress before rewinding the syscall.
    \* kernel/core/src/process/signal/mod.rs:145-158
    /\ restartPending' = [restartPending EXCEPT ![t] = TRUE]
    /\ result' = [result EXCEPT ![t] = Restarted]
    /\ pc' = [pc EXCEPT ![t] = "RestartReady"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, reported,
        copiedTotal, committedTotal, visibleTotal, reportedTotal, entryResult,
        copyFault, ofdOffset, expectedOffset, offsetOwner, dataOwner, ioOffset,
        explicitOffset, appendMode, fileSize, expectedFileSize, oldFileSize,
        plannedEnd, sizePublicationOwners, pageState, rangeClass,
        fileSizeSnapshot, dataEpoch, entryDataEpoch, bufferEpochs,
        vectorIndex, vectorIntervened, attemptId, effectToken, directPart,
        pendingBios, completedBios, commitCount, saRestart,
        interruptibleBackend, positionalOFDExpected
        >>

\* Without SA_RESTART, signal delivery leaves EINTR as the completed result.
\* kernel/core/src/process/signal/mod.rs:145-158
HandlePendingSignalNoRestart(t) ==
    /\ pc[t] = "SignalDeliver"
    /\ ~saRestart[t]
    \* No instruction-pointer rewind occurs.  Publish the final physical ledger
    \* so a positive copy/commit followed by EINTR cannot disappear merely
    \* because the signal disposition omitted SA_RESTART.
    \* kernel/core/src/syscall/read.rs:27-39
    \* kernel/core/src/syscall/write.rs:27-39
    /\ copiedTotal' = [copiedTotal EXCEPT ![t] = ProgressUnits(copied[t])]
    /\ visibleTotal' = [visibleTotal EXCEPT ![t] =
        IF IsRead(opKind[t]) THEN ProgressUnits(copied[t]) ELSE 0]
    /\ committedTotal' = [committedTotal EXCEPT ![t] =
        IF IsWrite(opKind[t]) THEN ProgressUnits(committed[t]) ELSE 0]
    /\ reportedTotal' = [reportedTotal EXCEPT ![t] = 0]
    \* No instruction-pointer rewind occurs.
    \* kernel/core/src/process/signal/mod.rs:145-158
    /\ pc' = [pc EXCEPT ![t] = "Idle"]
    /\ UNCHANGED <<
        opKind, backendMode, requested, copied, committed, reported,
        result, entryResult, copyFault, ofdOffset, expectedOffset, offsetOwner,
        dataOwner, ioOffset, explicitOffset, appendMode, fileSize,
        expectedFileSize, oldFileSize, plannedEnd, sizePublicationOwners,
        pageState, rangeClass, fileSizeSnapshot, dataEpoch, entryDataEpoch,
        bufferEpochs, vectorIndex, vectorIntervened, attemptId, effectToken,
        directPart, pendingBios, completedBios, commitCount, saRestart,
        restartPending, interruptibleBackend, positionalOFDExpected
        >>

\* After IP rewind, the task re-enters the same scalar syscall with a new
\* attempt id but the same logical effect token.
\* kernel/core/src/thread/task.rs:83-105
TaskRestartSyscall(t) ==
    /\ pc[t] = "RestartReady"
    /\ restartPending[t]
    /\ attemptId[t] < MaxAttempts
    \* Re-entry is not gated on unrelated threads' OFD/backend guards.  The
    \* restarted wrapper may enter and subsequently block on its own lock path.
    \* kernel/core/src/thread/task.rs:83-105
    \* Re-execution is a new attempt of the same logical effect identity.
    \* kernel/core/src/process/signal/mod.rs:155-157
    /\ attemptId' = [attemptId EXCEPT ![t] = @ + 1]
    /\ restartPending' = [restartPending EXCEPT ![t] = FALSE]
    /\ result' = [result EXCEPT ![t] = Pending]
    /\ entryResult' = [entryResult EXCEPT ![t] = NoEntryResult]
    /\ pc' = [pc EXCEPT ![t] = "AcquireOffset"]
    \* Reset per-attempt progress; effectToken deliberately remains unchanged
    \* so a replay would increment the same commitCount key.
    \* kernel/core/src/thread/task.rs:83-105
    /\ copied' = [copied EXCEPT ![t] = Zero]
    /\ committed' = [committed EXCEPT ![t] = Zero]
    /\ reported' = [reported EXCEPT ![t] = Zero]
    /\ copiedTotal' = [copiedTotal EXCEPT ![t] = 0]
    /\ committedTotal' = [committedTotal EXCEPT ![t] = 0]
    /\ visibleTotal' = [visibleTotal EXCEPT ![t] = 0]
    /\ reportedTotal' = [reportedTotal EXCEPT ![t] = 0]
    /\ copyFault' = [copyFault EXCEPT ![t] = FALSE]
    /\ ioOffset' = [ioOffset EXCEPT ![t] = 0]
    /\ oldFileSize' = [oldFileSize EXCEPT ![t] = fileSize]
    /\ plannedEnd' = [plannedEnd EXCEPT ![t] = fileSize]
    /\ fileSizeSnapshot' = [fileSizeSnapshot EXCEPT ![t] = fileSize]
    /\ entryDataEpoch' = [entryDataEpoch EXCEPT ![t] = dataEpoch]
    /\ bufferEpochs' = [bufferEpochs EXCEPT ![t] = <<>>]
    /\ vectorIndex' = [vectorIndex EXCEPT ![t] = 1]
    /\ vectorIntervened' = [vectorIntervened EXCEPT ![t] = FALSE]
    /\ directPart' = [directPart EXCEPT ![t] = 1]
    /\ UNCHANGED <<
        opKind, backendMode, requested, explicitOffset, appendMode, pageState,
        rangeClass, effectToken, saRestart, interruptibleBackend, ofdOffset,
        expectedOffset, offsetOwner, dataOwner, fileSize, expectedFileSize,
        sizePublicationOwners, dataEpoch, pendingBios, completedBios,
        commitCount, positionalOFDExpected
        >>

Next ==
    \* In-scope syscall invocations and their user-controlled parameters.
    \* kernel/core/src/syscall/read.rs:10-44
    \* kernel/core/src/syscall/write.rs:10-44
    \* kernel/core/src/syscall/pread64.rs:10-43
    \* kernel/core/src/syscall/pwrite64.rs:10-41
    \* kernel/core/src/syscall/preadv.rs:11-18,134-180
    \* kernel/core/src/syscall/pwritev.rs:11-18,134-175
    \/ \E t \in Threads, backend \in BackendModes,
          restartable \in BOOLEAN :
        SysReadStart(t, backend, restartable)
    \/ \E t \in Threads, backend \in BackendModes,
          req \in {Zero, Complete}, isAppend \in BOOLEAN,
          restartable \in BOOLEAN, initialPage \in PageStates :
        SysWriteStart(t, backend, req, isAppend, restartable, initialPage)
    \/ \E t \in Threads, backend \in BackendModes, pos \in 0..MaxOffset :
        SysPread64Start(t, backend, pos)
    \/ \E t \in Threads, backend \in BackendModes,
          req \in {Zero, Complete}, pos \in 0..MaxOffset,
          initialPage \in PageStates :
        SysPwrite64Start(t, backend, req, pos, initialPage)
    \/ \E t \in Threads, backend \in BackendModes :
        DoSysReadvStart(t, backend)
    \/ \E t \in Threads, backend \in BackendModes,
          initialPage \in PageStates :
        DoSysWritevStart(t, backend, initialPage)

    \* Scalar OFD and backend critical-section boundaries.
    \* kernel/core/src/fs/file/inode_handle.rs:273-353
    \* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:20-96
    \* kernel/core/src/fs/fs_impls/ramfs/fs.rs:694-756
    \/ \E t \in Threads : InodeHandleReadAcquireOffset(t)
    \/ \E t \in Threads : InodeHandleWriteAcquireOffset(t)
    \/ \E t \in Threads : InodeHandleReadAtBegin(t)
    \/ \E t \in Threads : InodeHandleWriteAtBegin(t)
    \/ \E t \in Threads : InodeHandleWriteChooseAppendStart(t)
    \/ \E t \in Threads : RamInodeReadAtSnapshotSize(t)
    \/ \E t \in Threads : Ext2InodeWriteAtZeroLengthReturn(t)
    \/ \E t \in Threads : FileOpsAcquireData(t)
    \/ \E t \in Threads : InodeInnerPrepareWrite(t)
    \/ \E t \in Threads : RamInodeWriteAtPublishMetadata(t)

    \* Aggregate scalar copy outcomes; complete paths are reactive, while the
    \* two fault classes are bounded in MC.tla.  Internal page/range loops do
    \* not release the modeled data guard.
    \* ostd/src/mm/io/mod.rs:271-292,332-385
    \* kernel/core/src/vm/page_cache/vmo/mod.rs:533-759
    \/ \E t \in Threads : FileOpsReadAtCopyComplete(t)
    \/ \E t \in Threads : FileOpsReadAtCopyFaultZero(t)
    \/ \E t \in Threads : FileOpsReadAtCopyFaultPositive(t)
    \/ \E t \in Threads : FileOpsWriteAtCopyComplete(t)
    \/ \E t \in Threads, faultPage \in PageStates :
        FileOpsWriteAtCopyFaultZero(t, faultPage)
    \/ \E t \in Threads, faultPage \in PageStates,
          retainedPrefix \in {Zero, Positive} :
        FileOpsWriteAtCopyFaultPositive(t, faultPage, retainedPrefix)
    \/ \E t \in Threads : BioSegmentWriteFallibleComplete(t)
    \/ \E t \in Threads : BioSegmentWriteFallibleFaultZero(t)
    \/ \E t \in Threads : BioSegmentWriteFallibleFaultPositive(t)
    \/ \E t \in Threads : InterruptibleBackendReturnEintr(t)

    \* Backend disposition/publication and direct-I/O completion windows.
    \* kernel/core/src/vm/page_cache/vmo/mod.rs:533-759
    \* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:245-406
    \* kernel/core/src/fs/fs_impls/ramfs/fs.rs:694-756
    \/ \E t \in Threads : FileOpsReadAtFinish(t)
    \/ \E t \in Threads : InodeInnerReadDirectAtFinish(t)
    \/ \E t \in Threads : VmoWritePagesWithBackendFinishSuccess(t)
    \/ \E t \in Threads : VmoWritePagesWithBackendFaultRetain(t)
    \/ \E t \in Threads : VmoWritePagesWithBackendFaultDiscard(t)
    \/ \E t \in Threads : VmoWriteAnonymousPagesFinishSuccess(t)
    \/ \E t \in Threads : VmoWriteAnonymousPagesFinishFault(t)
    \/ \E t \in Threads : BioSubmit(t)
    \/ \E bio \in pendingBios : SubmittedBioComplete(bio)
    \/ \E t \in Threads : IoBatchWaitAll(t)
    \/ \E t \in Threads : InodeInnerWriteDirectAtCommit(t)
    \/ \E t \in Threads : InodeInnerWriteDirectAtRollback(t)
    \/ \E t \in Threads : FileOpsReleaseData(t)

    \* Nested return, per-iovec dispatch, and syscall result publication.
    \* kernel/core/src/fs/file/inode_handle.rs:273-353
    \* kernel/core/src/syscall/preadv.rs:134-180
    \* kernel/core/src/syscall/pwritev.rs:134-175
    \/ \E t \in Threads : InodeHandleReadReturnOk(t)
    \/ \E t \in Threads : InodeHandleReadReturnError(t)
    \/ \E t \in Threads : InodeHandleWriteReturnOk(t)
    \/ \E t \in Threads : InodeHandleWriteReturnError(t)
    \/ \E t \in Threads : DoSysReadvEntryOkContinue(t)
    \/ \E t \in Threads : DoSysReadvEntryOkReturn(t)
    \/ \E t \in Threads : DoSysReadvEntryFaultReturn(t)
    \/ \E t \in Threads : DoSysWritevEntryOkContinue(t)
    \/ \E t \in Threads : DoSysWritevEntryOkReturn(t)
    \/ \E t \in Threads : DoSysWritevEntryFaultReturn(t)
    \/ \E t \in Threads : SysReadReturn(t)
    \/ \E t \in Threads : SysWriteReturn(t)
    \/ \E t \in Threads : SysPread64Return(t)
    \/ \E t \in Threads : SysPwrite64Return(t)

    \* EINTR translation, signal classification, and SA_RESTART rewind.
    \* kernel/core/src/syscall/read.rs:27-39
    \* kernel/core/src/syscall/write.rs:27-39
    \* kernel/core/src/process/signal/mod.rs:48-62,145-158
    \* kernel/core/src/thread/task.rs:83-105
    \/ \E t \in Threads : SysReadTranslateEintr(t)
    \/ \E t \in Threads : SysWriteTranslateEintr(t)
    \/ \E t \in Threads : HandlePendingSignalClassify(t)
    \/ \E t \in Threads : HandlePendingSignalRestart(t)
    \/ \E t \in Threads : HandlePendingSignalNoRestart(t)
    \/ \E t \in Threads : TaskRestartSyscall(t)

Spec == Init /\ [][Next]_vars

=============================================================================
