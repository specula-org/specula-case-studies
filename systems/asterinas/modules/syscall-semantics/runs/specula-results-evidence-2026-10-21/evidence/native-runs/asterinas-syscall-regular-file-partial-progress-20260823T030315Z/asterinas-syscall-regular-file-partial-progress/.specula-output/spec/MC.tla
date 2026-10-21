------------------------------- MODULE MC -------------------------------
EXTENDS base

\* Counter limits apply only to environment/fault introduction.  Normal lock,
\* copy completion, backend publication, BIO completion, dispatch, and signal
\* handling actions remain reactive and unbounded.

CONSTANTS
    ReadStartLimit,
    WriteStartLimit,
    PreadStartLimit,
    PwriteStartLimit,
    ReadvStartLimit,
    WritevStartLimit,
    ReadFaultZeroLimit,
    ReadFaultPositiveLimit,
    WriteFaultZeroLimit,
    WriteFaultPositiveLimit,
    DirectFaultZeroLimit,
    DirectFaultPositiveLimit,
    InterruptLimit

ReadStartCounter == "readStart"
WriteStartCounter == "writeStart"
PreadStartCounter == "preadStart"
PwriteStartCounter == "pwriteStart"
ReadvStartCounter == "readvStart"
WritevStartCounter == "writevStart"
ReadFaultZeroCounter == "readFaultZero"
ReadFaultPositiveCounter == "readFaultPositive"
WriteFaultZeroCounter == "writeFaultZero"
WriteFaultPositiveCounter == "writeFaultPositive"
DirectFaultZeroCounter == "directFaultZero"
DirectFaultPositiveCounter == "directFaultPositive"
InterruptCounter == "interrupt"

CounterNames == {
    ReadStartCounter, WriteStartCounter, PreadStartCounter,
    PwriteStartCounter, ReadvStartCounter, WritevStartCounter,
    ReadFaultZeroCounter, ReadFaultPositiveCounter,
    WriteFaultZeroCounter, WriteFaultPositiveCounter,
    DirectFaultZeroCounter, DirectFaultPositiveCounter, InterruptCounter
}

VARIABLE mc

mcVars == <<mc>>
allMCVars == <<vars, mc>>

Bump(counter) == mc' = [mc EXCEPT ![counter] = @ + 1]

\* Client/syscall starts introduce operation kind, backend, buffer shape,
\* append mode, positional offset, and signal disposition choices.
MCSysReadStart(t, backend, restartable) ==
    /\ mc[ReadStartCounter] < ReadStartLimit
    /\ SysReadStart(t, backend, restartable)
    /\ Bump(ReadStartCounter)

MCSysWriteStart(t, backend, req, isAppend, restartable, initialPage) ==
    /\ mc[WriteStartCounter] < WriteStartLimit
    /\ SysWriteStart(t, backend, req, isAppend, restartable, initialPage)
    /\ Bump(WriteStartCounter)

MCSysPread64Start(t, backend, pos) ==
    /\ mc[PreadStartCounter] < PreadStartLimit
    /\ SysPread64Start(t, backend, pos)
    /\ Bump(PreadStartCounter)

MCSysPwrite64Start(t, backend, req, pos, initialPage) ==
    /\ mc[PwriteStartCounter] < PwriteStartLimit
    /\ SysPwrite64Start(t, backend, req, pos, initialPage)
    /\ Bump(PwriteStartCounter)

MCDoSysReadvStart(t, backend) ==
    /\ mc[ReadvStartCounter] < ReadvStartLimit
    /\ DoSysReadvStart(t, backend)
    /\ Bump(ReadvStartCounter)

MCDoSysWritevStart(t, backend, initialPage) ==
    /\ mc[WritevStartCounter] < WritevStartLimit
    /\ DoSysWritevStart(t, backend, initialPage)
    /\ Bump(WritevStartCounter)

\* User-copy outcomes introduce the faulting zero/positive-prefix choice.
MCFileOpsReadAtCopyFaultZero(t) ==
    /\ mc[ReadFaultZeroCounter] < ReadFaultZeroLimit
    /\ FileOpsReadAtCopyFaultZero(t)
    /\ Bump(ReadFaultZeroCounter)

MCFileOpsReadAtCopyFaultPositive(t) ==
    /\ mc[ReadFaultPositiveCounter] < ReadFaultPositiveLimit
    /\ FileOpsReadAtCopyFaultPositive(t)
    /\ Bump(ReadFaultPositiveCounter)

MCFileOpsWriteAtCopyFaultZero(t, faultPage) ==
    /\ mc[WriteFaultZeroCounter] < WriteFaultZeroLimit
    /\ FileOpsWriteAtCopyFaultZero(t, faultPage)
    /\ Bump(WriteFaultZeroCounter)

MCFileOpsWriteAtCopyFaultPositive(t, faultPage, retainedPrefix) ==
    /\ mc[WriteFaultPositiveCounter] < WriteFaultPositiveLimit
    /\ FileOpsWriteAtCopyFaultPositive(t, faultPage, retainedPrefix)
    /\ Bump(WriteFaultPositiveCounter)

MCBioSegmentWriteFallibleFaultZero(t) ==
    /\ mc[DirectFaultZeroCounter] < DirectFaultZeroLimit
    /\ BioSegmentWriteFallibleFaultZero(t)
    /\ Bump(DirectFaultZeroCounter)

MCBioSegmentWriteFallibleFaultPositive(t) ==
    /\ mc[DirectFaultPositiveCounter] < DirectFaultPositiveLimit
    /\ BioSegmentWriteFallibleFaultPositive(t)
    /\ Bump(DirectFaultPositiveCounter)

MCInterruptibleBackendReturnEintr(t) ==
    /\ mc[InterruptCounter] < InterruptLimit
    /\ InterruptibleBackendReturnEintr(t)
    /\ Bump(InterruptCounter)

\* Deterministic/reactive steps pass through without consuming a counter.
MCReactiveNext ==
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
    \/ \E t \in Threads : FileOpsReadAtCopyComplete(t)
    \/ \E t \in Threads : FileOpsWriteAtCopyComplete(t)
    \/ \E t \in Threads : BioSegmentWriteFallibleComplete(t)
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
    \/ \E t \in Threads : SysReadTranslateEintr(t)
    \/ \E t \in Threads : SysWriteTranslateEintr(t)
    \/ \E t \in Threads : HandlePendingSignalClassify(t)
    \/ \E t \in Threads : HandlePendingSignalRestart(t)
    \/ \E t \in Threads : HandlePendingSignalNoRestart(t)
    \/ \E t \in Threads : TaskRestartSyscall(t)

MCInit ==
    /\ Init
    /\ mc = [counter \in CounterNames |-> 0]

MCNext ==
    \* Counter-bounded syscall starts.
    \/ \E t \in Threads, backend \in BackendModes,
          restartable \in BOOLEAN :
        MCSysReadStart(t, backend, restartable)
    \/ \E t \in Threads, backend \in BackendModes,
          req \in {Zero, Complete}, isAppend \in BOOLEAN,
          restartable \in BOOLEAN, initialPage \in PageStates :
        MCSysWriteStart(t, backend, req, isAppend, restartable, initialPage)
    \/ \E t \in Threads, backend \in BackendModes, pos \in 0..MaxOffset :
        MCSysPread64Start(t, backend, pos)
    \/ \E t \in Threads, backend \in BackendModes,
          req \in {Zero, Complete}, pos \in 0..MaxOffset,
          initialPage \in PageStates :
        MCSysPwrite64Start(t, backend, req, pos, initialPage)
    \/ \E t \in Threads, backend \in BackendModes :
        MCDoSysReadvStart(t, backend)
    \/ \E t \in Threads, backend \in BackendModes,
          initialPage \in PageStates :
        MCDoSysWritevStart(t, backend, initialPage)
    \* Counter-bounded fault/capability choices.
    \/ \E t \in Threads : MCFileOpsReadAtCopyFaultZero(t)
    \/ \E t \in Threads : MCFileOpsReadAtCopyFaultPositive(t)
    \/ \E t \in Threads, faultPage \in PageStates :
        MCFileOpsWriteAtCopyFaultZero(t, faultPage)
    \/ \E t \in Threads, faultPage \in PageStates,
          retainedPrefix \in {Zero, Positive} :
        MCFileOpsWriteAtCopyFaultPositive(t, faultPage, retainedPrefix)
    \/ \E t \in Threads : MCBioSegmentWriteFallibleFaultZero(t)
    \/ \E t \in Threads : MCBioSegmentWriteFallibleFaultPositive(t)
    \/ \E t \in Threads : MCInterruptibleBackendReturnEintr(t)
    \* All normal advancement remains unbounded.
    \/ /\ MCReactiveNext
       /\ UNCHANGED mc

MCSpec ==
    /\ MCInit
    /\ [][MCNext]_allMCVars
    /\ WF_allMCVars(MCNext)

ThreadSymmetry == Permutations(Threads)
MCView == vars

MaxModelUnits == MaxTrackedUnits

StateConstraint ==
    /\ ofdOffset <= MaxModelUnits
    /\ expectedOffset <= MaxModelUnits
    /\ fileSize <= MaxModelUnits
    /\ expectedFileSize <= MaxModelUnits
    \* A direct vector attempt can complete VectorLength BIO segments for each
    \* of VectorLength entries; completion order is unconstrained.
    \* kernel/core/src/fs/fs_impls/ext2/inode/file.rs:383-405
    /\ dataEpoch <=
        VectorLength * VectorLength * MaxAttempts * Cardinality(Threads)
    /\ \A t \in Threads : Len(bufferEpochs[t]) <= VectorLength

MCTypeOK == TypeOK /\ mc \in [CounterNames -> Nat]
MCStructuralOK == StructuralOK

MCProgressBounded ==
    \A t \in Threads :
        /\ copiedTotal[t] <= VectorLength * ProgressUnits(Complete)
        /\ committedTotal[t] <= VectorLength * ProgressUnits(Complete)
        /\ visibleTotal[t] <= VectorLength * ProgressUnits(Complete)
        /\ reportedTotal[t] <= VectorLength * ProgressUnits(Complete)

MCBioLifecycle == pendingBios \cap completedBios = {}

\* Scenario invariants.  MC.cfg lists these commented out; each is enabled by
\* at least one MC_hunt_scenario_*.cfg.
MCReportedCoversVisibleCopy == ReportedCoversVisibleCopy
MCReportedCoversCommittedWrite == ReportedCoversCommittedWrite
MCMixedPageRetainedPrefixReported == MixedPageRetainedPrefixReported
MCSharedOffsetMatchesReported == SharedOffsetMatchesReported
MCFileSizeMatchesProgress == FileSizeMatchesProgress
MCVectorCallLinearizable == VectorCallLinearizable
MCLaterIovecFaultLinearizable == LaterIovecFaultLinearizable
MCAppendFailureVectorLinearizable == AppendFailureVectorLinearizable
MCPositionalOffsetStable == PositionalOffsetStable
MCNoUnaccountedPendingEffect == NoUnaccountedPendingEffect
MCRestartRequiresZeroProgress == RestartRequiresZeroProgress
MCNoEffectReplay == NoEffectReplay

\* With finite start/fault counters and weak fairness, nested OFD/backend locks
\* cannot remain held forever.
MCNoPermanentLocks == []<>(offsetOwner = NoThread /\ dataOwner = NoThread)

=============================================================================
