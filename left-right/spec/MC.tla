---- MODULE MC ----
(***************************************************************************)
(* Model checking wrapper for left-right specification.                    *)
(* Counter-bounds fault-injection actions (fence skip, non-det absorb).    *)
(* Reactive actions (reader enter/exit, writer wait/apply/swap) are NOT    *)
(* bounded — they react to existing state.                                 *)
(***************************************************************************)

EXTENDS base

\* ========================================================================
\* Constants (counter limits)
\* ========================================================================

CONSTANTS
    MaxReaderFenceSkips,    \* Max reader fence skip events (Family 1)
    MaxWriterFenceSkips,    \* Max writer fence skip events (Family 1)
    MaxNonDetAbsorbs,       \* Max non-det absorb enablements (Family 2)
    MaxClones,              \* Max clone attempts (Family 3)
    MaxRegistrations,       \* Max register/deregister cycles (Family 3)
    MaxTakeInner,           \* Max take_inner attempts (Family 4)
    MaxTryPublish           \* Max try_publish attempts (Family 4)

\* ========================================================================
\* Counter variables
\* ========================================================================

VARIABLES
    readerFenceSkipCount,
    writerFenceSkipCount,
    nondetAbsorbCount,
    cloneCount,
    registrationCount,
    takeInnerCount,
    tryPublishCount

mcVars == <<readerFenceSkipCount, writerFenceSkipCount, nondetAbsorbCount,
            cloneCount, registrationCount, takeInnerCount, tryPublishCount>>

\* ========================================================================
\* Counter-bounded fault injection
\* ========================================================================

\* --- Family 1: bounded reader fence skip ---
MCSkipReaderFence(r) ==
    /\ readerFenceSkipCount < MaxReaderFenceSkips
    /\ SkipReaderFence(r)
    /\ readerFenceSkipCount' = readerFenceSkipCount + 1
    /\ UNCHANGED <<writerFenceSkipCount, nondetAbsorbCount,
                   cloneCount, registrationCount, takeInnerCount, tryPublishCount>>

\* --- Family 1: bounded writer fence skip ---
MCSkipWriterFence ==
    /\ writerFenceSkipCount < MaxWriterFenceSkips
    /\ SkipWriterFence
    /\ writerFenceSkipCount' = writerFenceSkipCount + 1
    /\ UNCHANGED <<readerFenceSkipCount, nondetAbsorbCount,
                   cloneCount, registrationCount, takeInnerCount, tryPublishCount>>

\* --- Family 2: bounded non-deterministic absorb ---
MCEnableNonDetAbsorb ==
    /\ nondetAbsorbCount < MaxNonDetAbsorbs
    /\ EnableNonDetAbsorb
    /\ nondetAbsorbCount' = nondetAbsorbCount + 1
    /\ UNCHANGED <<readerFenceSkipCount, writerFenceSkipCount,
                   cloneCount, registrationCount, takeInnerCount, tryPublishCount>>

\* --- Family 3: bounded clone ---
MCReaderStartClone(r) ==
    /\ cloneCount < MaxClones
    /\ ReaderStartClone(r)
    /\ cloneCount' = cloneCount + 1
    /\ UNCHANGED <<readerFenceSkipCount, writerFenceSkipCount, nondetAbsorbCount,
                   registrationCount, takeInnerCount, tryPublishCount>>

\* --- Family 3: bounded register/deregister ---
MCReaderRegister(r) ==
    /\ registrationCount < MaxRegistrations
    /\ ReaderRegister(r)
    /\ registrationCount' = registrationCount + 1
    /\ UNCHANGED <<readerFenceSkipCount, writerFenceSkipCount, nondetAbsorbCount,
                   cloneCount, takeInnerCount, tryPublishCount>>

MCReaderDeregister(r) ==
    /\ registrationCount < MaxRegistrations
    /\ ReaderDeregister(r)
    /\ registrationCount' = registrationCount + 1
    /\ UNCHANGED <<readerFenceSkipCount, writerFenceSkipCount, nondetAbsorbCount,
                   cloneCount, takeInnerCount, tryPublishCount>>

\* --- Family 4: bounded take_inner ---
MCWriterStartTakeInner ==
    /\ takeInnerCount < MaxTakeInner
    /\ WriterStartTakeInner
    /\ takeInnerCount' = takeInnerCount + 1
    /\ UNCHANGED <<readerFenceSkipCount, writerFenceSkipCount, nondetAbsorbCount,
                   cloneCount, registrationCount, tryPublishCount>>

\* --- Family 4: bounded try_publish ---
MCWriterStartTryPublish ==
    /\ tryPublishCount < MaxTryPublish
    /\ WriterStartTryPublish
    /\ tryPublishCount' = tryPublishCount + 1
    /\ UNCHANGED <<readerFenceSkipCount, writerFenceSkipCount, nondetAbsorbCount,
                   cloneCount, registrationCount, takeInnerCount>>

\* ========================================================================
\* Unconstrained reactive actions (pass-through with UNCHANGED mcVars)
\* ========================================================================

MCReaderBumpEpoch(r)     == ReaderBumpEpoch(r)     /\ UNCHANGED mcVars
MCReaderLoadPointer(r)   == ReaderLoadPointer(r)   /\ UNCHANGED mcVars
MCReaderLoadNull(r)      == ReaderLoadNull(r)      /\ UNCHANGED mcVars
MCReaderNestedEnter(r)   == ReaderNestedEnter(r)   /\ UNCHANGED mcVars
MCReaderExit(r)          == ReaderExit(r)          /\ UNCHANGED mcVars
MCReaderCloneComplete(r) == ReaderCloneComplete(r) /\ UNCHANGED mcVars

MCWriterAppend           == WriterAppend           /\ UNCHANGED mcVars
MCWriterStartPublish     == WriterStartPublish     /\ UNCHANGED mcVars
MCWriterWait             == WriterWait             /\ UNCHANGED mcVars
MCWriterApplyAndSwap     == WriterApplyAndSwap     /\ UNCHANGED mcVars
MCWriterDoFence          == WriterDoFence          /\ UNCHANGED mcVars
MCWriterSnapshotEpochs   == WriterSnapshotEpochs   /\ UNCHANGED mcVars
MCWriterTryPublishSucceed == WriterTryPublishSucceed /\ UNCHANGED mcVars
MCWriterTryPublishFail   == WriterTryPublishFail   /\ UNCHANGED mcVars
MCWriterTakeInnerLock    == WriterTakeInnerLock    /\ UNCHANGED mcVars
MCWriterTakeInnerWait    == WriterTakeInnerWait    /\ UNCHANGED mcVars
MCWriterTakeInnerComplete == WriterTakeInnerComplete /\ UNCHANGED mcVars

\* ========================================================================
\* Init and Next
\* ========================================================================

MCInit ==
    /\ Init
    /\ readerFenceSkipCount = 0
    /\ writerFenceSkipCount = 0
    /\ nondetAbsorbCount = 0
    /\ cloneCount = 0
    /\ registrationCount = 0
    /\ takeInnerCount = 0
    /\ tryPublishCount = 0

MCNext ==
    \/ \E r \in Reader :
        \/ MCReaderBumpEpoch(r)
        \/ MCReaderLoadPointer(r)
        \/ MCReaderLoadNull(r)
        \/ MCReaderNestedEnter(r)
        \/ MCReaderExit(r)
        \/ MCReaderRegister(r)
        \/ MCReaderDeregister(r)
        \/ MCReaderStartClone(r)
        \/ MCReaderCloneComplete(r)
        \/ MCSkipReaderFence(r)
    \/ MCWriterAppend
    \/ MCWriterStartPublish
    \/ MCWriterWait
    \/ MCWriterApplyAndSwap
    \/ MCWriterDoFence
    \/ MCWriterSnapshotEpochs
    \/ MCWriterStartTryPublish
    \/ MCWriterTryPublishSucceed
    \/ MCWriterTryPublishFail
    \/ MCWriterStartTakeInner
    \/ MCWriterTakeInnerLock
    \/ MCWriterTakeInnerWait
    \/ MCWriterTakeInnerComplete
    \/ MCSkipWriterFence
    \/ MCEnableNonDetAbsorb

MCSpec == MCInit /\ [][MCNext]_<<vars, mcVars>>

\* ========================================================================
\* State constraint (prune state space)
\* ========================================================================

MCStateConstraint ==
    /\ totalOps <= MaxOps
    /\ \A r \in Reader : epoch[r] <= 2 * MaxOps + 6
    /\ \A r \in Reader : enters[r] <= 3

\* ========================================================================
\* Symmetry
\* ========================================================================

MCSymmetry == Permutations(Reader)

\* ========================================================================
\* Structural invariants (always checked)
\* ========================================================================

MCTypeOK          == TypeOK
MCEpochParity     == EpochParity
MCPointerDisjoint == PointerCopyDisjoint

\* ========================================================================
\* Safety invariants (always checked, no faults needed)
\* ========================================================================

MCNoWriteWhileRead  == NoWriteWhileRead
MCApplyCorrectness  == ApplyCorrectness
MCVariantSafety     == VariantSafety

\* ========================================================================
\* Extension invariants (bug-family specific, commented out in MC.cfg)
\* ========================================================================

MCOrderingNoWriteWhileRead == OrderingNoWriteWhileRead
MCAbsorbApplyCorrectness   == AbsorbApplyCorrectness

====
