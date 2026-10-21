---- MODULE MC ----
(***************************************************************************)
(* Exhaustive model-checking wrapper for base.tla.                         *)
(*                                                                         *)
(* Bounded nondeterminism: syscall admission, fallible-copy outcomes, and  *)
(* whole-syscall restart. All implementation reactions and lock/PC steps   *)
(* remain unbounded so TLC can explore their interleavings.                *)
(***************************************************************************)

EXTENDS base

Base == INSTANCE base

CONSTANTS
    BeginLimit,
    CopyFaultLimit,
    RestartLimit,
    HistoryLimit,
    PositionLimit,
    AllowedFaultIovs,
    AllowedFaultProgress

ASSUME /\ BeginLimit \in Nat
       /\ CopyFaultLimit \in Nat
       /\ RestartLimit \in Nat
       /\ HistoryLimit \in Nat
       /\ PositionLimit \in Nat
       /\ AllowedFaultIovs \subseteq 1..IovCount
       /\ AllowedFaultProgress \subseteq {ZeroProgress, PrefixProgress}

VARIABLES
    beginCount,
    copyFaultCount,
    restartCount

mcVars == <<beginCount, copyFaultCount, restartCount>>

(***************************************************************************)
(* Bounded operation admission                                              *)
(***************************************************************************)

MCSysReadBegin(t, sig, restart) ==
    /\ beginCount < BeginLimit
    /\ Base!SysReadBegin(t, sig, restart)
    /\ beginCount' = beginCount + 1
    /\ UNCHANGED <<copyFaultCount, restartCount>>

MCSysWriteBegin(t, sig, restart) ==
    /\ beginCount < BeginLimit
    /\ Base!SysWriteBegin(t, sig, restart)
    /\ beginCount' = beginCount + 1
    /\ UNCHANGED <<copyFaultCount, restartCount>>

MCSysPread64Begin(t, explicit, sig, restart) ==
    /\ beginCount < BeginLimit
    /\ Base!SysPread64Begin(t, explicit, sig, restart)
    /\ beginCount' = beginCount + 1
    /\ UNCHANGED <<copyFaultCount, restartCount>>

MCSysPwrite64Begin(t, explicit, sig, restart) ==
    /\ beginCount < BeginLimit
    /\ Base!SysPwrite64Begin(t, explicit, sig, restart)
    /\ beginCount' = beginCount + 1
    /\ UNCHANGED <<copyFaultCount, restartCount>>

MCDoSysReadvBegin(t, sig, restart) ==
    /\ beginCount < BeginLimit
    /\ Base!DoSysReadvBegin(t, sig, restart)
    /\ beginCount' = beginCount + 1
    /\ UNCHANGED <<copyFaultCount, restartCount>>

MCDoSysWritevBegin(t, sig, restart) ==
    /\ beginCount < BeginLimit
    /\ Base!DoSysWritevBegin(t, sig, restart)
    /\ beginCount' = beginCount + 1
    /\ UNCHANGED <<copyFaultCount, restartCount>>

(***************************************************************************)
(* Bounded fallible-copy outcomes                                           *)
(***************************************************************************)

IsInjectedCopyFault(t, progress) ==
    Units(progress) < Units(opState[t].copyLimit)

CopyOutcomeAllowed(t, progress) ==
    IF IsInjectedCopyFault(t, progress)
    THEN /\ copyFaultCount < CopyFaultLimit
         /\ opState[t].iovIndex \in AllowedFaultIovs
         /\ progress \in AllowedFaultProgress
    ELSE TRUE

MCVmoRead(t, progress) ==
    /\ CopyOutcomeAllowed(t, progress)
    /\ Base!VmoRead(t, progress)
    /\ copyFaultCount' = copyFaultCount
                          + IF IsInjectedCopyFault(t, progress) THEN 1 ELSE 0
    /\ UNCHANGED <<beginCount, restartCount>>

MCVmoWrite(t, progress) ==
    /\ CopyOutcomeAllowed(t, progress)
    /\ Base!VmoWrite(t, progress)
    /\ copyFaultCount' = copyFaultCount
                          + IF IsInjectedCopyFault(t, progress) THEN 1 ELSE 0
    /\ UNCHANGED <<beginCount, restartCount>>

(***************************************************************************)
(* Bounded restart; the ERESTARTSYS gate itself remains implementation-led. *)
(***************************************************************************)

MCRestartSyscall(t) ==
    /\ restartCount < RestartLimit
    /\ Base!RestartSyscall(t)
    /\ restartCount' = restartCount + 1
    /\ UNCHANGED <<beginCount, copyFaultCount>>

(***************************************************************************)
(* Init and Next                                                            *)
(***************************************************************************)

MCInit ==
    /\ Base!Init
    /\ beginCount = 0
    /\ copyFaultCount = 0
    /\ restartCount = 0

MCNext ==
    \* Operation admission introduces a fresh operation/profile choice.
    \/ \E t \in Thread, sig \in BOOLEAN, restart \in BOOLEAN :
        MCSysReadBegin(t, sig, restart)
    \/ \E t \in Thread, sig \in BOOLEAN, restart \in BOOLEAN :
        MCSysWriteBegin(t, sig, restart)
    \/ \E t \in Thread, e \in ExplicitOffsets,
          sig \in BOOLEAN, restart \in BOOLEAN :
        MCSysPread64Begin(t, e, sig, restart)
    \/ \E t \in Thread, e \in ExplicitOffsets,
          sig \in BOOLEAN, restart \in BOOLEAN :
        MCSysPwrite64Begin(t, e, sig, restart)
    \/ \E t \in Thread, sig \in BOOLEAN, restart \in BOOLEAN :
        MCDoSysReadvBegin(t, sig, restart)
    \/ \E t \in Thread, sig \in BOOLEAN, restart \in BOOLEAN :
        MCDoSysWritevBegin(t, sig, restart)

    \* VM copy is reactive once an entry is prepared; only faulting outcomes
    \* consume CopyFaultLimit.
    \/ \E t \in Thread, p \in ProgressClasses : MCVmoRead(t, p)
    \/ \E t \in Thread, p \in ProgressClasses : MCVmoWrite(t, p)

    \* Restart is bounded independently from signal delivery.
    \/ \E t \in Thread : MCRestartSyscall(t)

    \* Deterministic/reactive implementation actions are never counter-bound.
    \/ \E t \in Thread :
        /\ Base!InodeHandleReadAcquireOffset(t)
        /\ UNCHANGED mcVars
    \/ \E t \in Thread :
        /\ Base!InodeHandleWriteAcquireOffset(t)
        /\ UNCHANGED mcVars
    \/ \E t \in Thread :
        /\ Base!InodeHandleReadAtStart(t)
        /\ UNCHANGED mcVars
    \/ \E t \in Thread :
        /\ Base!InodeHandleWriteAtStart(t)
        /\ UNCHANGED mcVars
    \/ \E t \in Thread :
        /\ Base!Ext2VirtioFsReadComputeLimit(t)
        /\ UNCHANGED mcVars
    \/ \E t \in Thread :
        /\ Base!RamFsExfatReadComputeLimit(t)
        /\ UNCHANGED mcVars
    \/ \E t \in Thread :
        /\ Base!RamFsWritePublishRequestedEnd(t)
        /\ UNCHANGED mcVars
    \/ \E t \in Thread :
        /\ Base!DeferredWritePrepare(t)
        /\ UNCHANGED mcVars
    \/ \E t \in Thread :
        /\ Base!ErrorFromTuple(t)
        /\ UNCHANGED mcVars
    \/ \E t \in Thread :
        /\ Base!FileOpsReadReturn(t)
        /\ UNCHANGED mcVars
    \/ \E t \in Thread :
        /\ Base!FileOpsWriteReturn(t)
        /\ UNCHANGED mcVars
    \/ \E t \in Thread :
        /\ Base!InodeHandleCommitOffset(t)
        /\ UNCHANGED mcVars
    \/ \E t \in Thread :
        /\ Base!InodeHandlePropagateError(t)
        /\ UNCHANGED mcVars
    \/ \E t \in Thread :
        /\ Base!InodeHandlePositionalReturn(t)
        /\ UNCHANGED mcVars
    \/ \E t \in Thread :
        /\ Base!InodeHandleReleaseOffset(t)
        /\ UNCHANGED mcVars
    \/ \E t \in Thread :
        /\ Base!DoSysReadvHandleEntry(t)
        /\ UNCHANGED mcVars
    \/ \E t \in Thread :
        /\ Base!DoSysWritevHandleEntry(t)
        /\ UNCHANGED mcVars
    \/ \E t \in Thread :
        /\ Base!SysReadFinish(t)
        /\ UNCHANGED mcVars
    \/ \E t \in Thread :
        /\ Base!SysWriteFinish(t)
        /\ UNCHANGED mcVars
    \/ \E t \in Thread :
        /\ Base!SysPread64Finish(t)
        /\ UNCHANGED mcVars
    \/ \E t \in Thread :
        /\ Base!SysPwrite64Finish(t)
        /\ UNCHANGED mcVars
    \/ \E t \in Thread :
        /\ Base!SysReadvFinish(t)
        /\ UNCHANGED mcVars
    \/ \E t \in Thread :
        /\ Base!SysWritevFinish(t)
        /\ UNCHANGED mcVars
    \/ \E t \in Thread :
        /\ Base!HandlePendingSignal(t)
        /\ UNCHANGED mcVars

MCSpec == MCInit /\ [][MCNext]_<<vars, mcVars>>

(***************************************************************************)
(* State-space controls                                                     *)
(***************************************************************************)

Symmetry == Permutations(Thread)

\* Fault counters are deliberately excluded from the view.
MCView == vars

MCStateConstraint ==
    /\ beginCount <= BeginLimit
    /\ copyFaultCount <= CopyFaultLimit
    /\ restartCount <= RestartLimit
    /\ Len(effectLog) <= HistoryLimit
    /\ Len(commitLog) <= HistoryLimit
    /\ sharedOffset <= PositionLimit
    /\ fileSize <= PositionLimit
    /\ cacheCapacity <= PositionLimit
    /\ \A t \in Thread :
        /\ opState[t].entryStart <= PositionLimit
        /\ opState[t].explicitOffset <= PositionLimit

(***************************************************************************)
(* Core/structural invariant aliases                                        *)
(***************************************************************************)

MCTypeOK                  == TypeOK
MCOffsetOwnerWellFormed   == OffsetOwnerWellFormed
MCProgressWithinRequest   == ProgressWithinRequest
MCCacheCoversFile         == CacheCoversFile
MCCommitLogWellFormed     == CommitLogWellFormed

(***************************************************************************)
(* Scenario invariant aliases                                               *)
(***************************************************************************)

MCReadReturnCoversCopies    == ReadReturnCoversCopies
MCWriteReturnCoversCommit   == WriteReturnCoversCommit
MCNoReadPastEOF             == NoReadPastEOF
MCNoNominalEOFOnFault       == NoNominalEOFOnFault
MCSharedOffsetTracksReport  == SharedOffsetTracksReport
MCVectorSingleLinearization == VectorSingleLinearization
MCPositionalOffsetIsolation == PositionalOffsetIsolation
MCRestartNoReplay           == RestartNoReplay

(***************************************************************************)
(* Temporal diagnostic                                                      *)
(***************************************************************************)

AllOperationsQuiescent ==
    /\ offsetOwner = NoThread
    /\ \A t \in Thread : opState[t].phase \in {"Idle", "Done"}

\* The brief contains safety questions only. This diagnostic is defined for
\* fairness experiments but is not enabled in the standard safety config.
MCEventuallyQuiescent == <>(AllOperationsQuiescent)

====
