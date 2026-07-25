---- MODULE base ----
(***************************************************************************)
(* TLA+ specification of jonhoo/left-right — Two-copy read-write           *)
(* separation concurrency primitive with epoch-based reader quiescence.    *)
(*                                                                         *)
(* Source: left-right/src/                                                 *)
(*   write.rs      — WriteHandle: publish, wait, swap, try_publish         *)
(*   read.rs       — ReadHandle: enter protocol, epoch tracking            *)
(*   read/guard.rs — ReadGuard: RAII epoch restore                         *)
(*   lib.rs        — Absorb trait, new/new_from_empty constructors         *)
(*   sync.rs       — loom compatibility, fence abstraction                 *)
(*                                                                         *)
(* Bug Families:                                                           *)
(*   F1 — Memory ordering protocol (SeqCst fence correctness)             *)
(*   F2 — Oplog dual-apply determinism                                     *)
(*   F3 — Reader lifecycle / epoch management (deadlock)                   *)
(*   F4 — Publish path variants (publish, try_publish, take_inner)         *)
(***************************************************************************)

EXTENDS Integers, FiniteSets, TLC

\* ========================================================================
\* Constants
\* ========================================================================

CONSTANTS
    Reader,     \* Set of reader thread IDs
    MaxOps      \* Max number of operations (bounds state space)

ASSUME MaxOps \in Nat \ {0}

\* ========================================================================
\* Variables
\* ========================================================================

\* --- Core protocol (AtomicPtr + epoch tracking) ---
VARIABLES
    pointer,        \* AtomicPtr<T>: "L" | "R" | "null" (read.rs:41, write.rs:170)
    writerCopy,     \* Which copy writer owns: "L" | "R" (write.rs:31)
    epoch,          \* [Reader -> Nat] per-reader epoch counter (read.rs:43)
    lastEpochs,     \* [Reader -> Nat] writer's snapshot after last swap (write.rs:35)
    enters          \* [Reader -> Nat] per-reader guard nesting count (read.rs:45)

\* --- Reader enter state machine (Family 1: multi-step enter) ---
VARIABLES
    rPC,            \* [Reader -> {"Idle","EpochBumped","Reading","CloningBlocked"}]
    rCopyRef        \* [Reader -> {"L","R","none"}] which copy reader loaded

\* --- Writer publish state machine (Family 1, 4) ---
VARIABLES
    wPC             \* Writer program counter (see TypeOK for domain)

\* --- Data model (Family 2: dual-apply determinism) ---
VARIABLES
    copyData,       \* [{"L","R"} -> Nat] abstract data counter per copy
    totalOps        \* Nat — total operations created

\* --- First-publish optimization (Family 4: first/second/sync_with) ---
VARIABLES
    first,          \* Boolean — no publish yet (write.rs:41, init true)
    second          \* Boolean — copies not yet sync'd (write.rs:43, init true)

\* --- Reader lifecycle / mutex (Family 3: deadlock) ---
VARIABLES
    registered,     \* [Reader -> BOOLEAN] reader registered in epoch slab
    mutexHolder,    \* "none" | "writer" | Reader — who holds epochs mutex
    taken           \* Boolean — take_inner has been called (write.rs:45)

\* --- Family 1: memory ordering fault injection ---
VARIABLES
    readerFenceSkipped,     \* [Reader -> BOOLEAN] reader's SeqCst fence disabled
    writerFenceSkipped      \* BOOLEAN — writer's SeqCst fence disabled

\* --- Family 2: non-deterministic absorb fault injection ---
VARIABLES
    nondetAbsorbActive      \* BOOLEAN — divergent absorb enabled

\* ========================================================================
\* Variable groups
\* ========================================================================

vars == <<pointer, writerCopy, epoch, lastEpochs, enters,
          rPC, rCopyRef, wPC, copyData, totalOps,
          first, second, registered, mutexHolder, taken,
          readerFenceSkipped, writerFenceSkipped, nondetAbsorbActive>>

\* ========================================================================
\* Helpers
\* ========================================================================

OtherCopy(c) == IF c = "L" THEN "R" ELSE "L"

\* Writer can proceed past wait when all registered readers have departed.
\* A reader has "departed" if its last-snapshotted epoch was even (idle)
\* or its current epoch differs from the snapshot (has moved on).
\* (write.rs:248-288)
AllReadersQuiesced ==
    \A r \in Reader :
        registered[r] =>
            \/ lastEpochs[r] % 2 = 0           \* was idle (write.rs:261)
            \/ epoch[r] /= lastEpochs[r]        \* has changed (write.rs:266)

\* Set of readers currently holding a reference to copy c.
\* Includes "CloningBlocked" because the guard is still held.
ReadersOnCopy(c) ==
    { r \in Reader : rPC[r] \in {"Reading", "CloningBlocked"} /\ rCopyRef[r] = c }

\* ========================================================================
\* Init
\* ========================================================================

Init ==
    \* Core: r_handle = "L", writer owns "R" (lib.rs:271-280)
    /\ pointer = "L"
    /\ writerCopy = "R"
    /\ epoch = [r \in Reader |-> 0]             \* (read.rs:89: AtomicUsize::new(0))
    /\ lastEpochs = [r \in Reader |-> 0]        \* (write.rs:225: Vec::new())
    /\ enters = [r \in Reader |-> 0]            \* (read.rs:97: Cell::new(0))
    \* Reader state
    /\ rPC = [r \in Reader |-> "Idle"]
    /\ rCopyRef = [r \in Reader |-> "none"]
    \* Writer state
    /\ wPC = "Idle"
    \* Data: both copies start identical (lib.rs:277: t.clone())
    /\ copyData = [c \in {"L", "R"} |-> 0]
    /\ totalOps = 0
    \* First-publish flags (write.rs:230-231)
    /\ first = TRUE
    /\ second = TRUE
    \* Lifecycle: all readers registered (lib.rs:277-278: ReadHandle::new)
    /\ registered = [r \in Reader |-> TRUE]
    /\ mutexHolder = "none"
    /\ taken = FALSE
    \* Fault injection: all disabled
    /\ readerFenceSkipped = [r \in Reader |-> FALSE]
    /\ writerFenceSkipped = FALSE
    /\ nondetAbsorbActive = FALSE

\* ========================================================================
\* Reader Actions
\* ========================================================================

\* --- ReaderBumpEpoch: first step of enter() protocol ---
\* Bumps epoch to odd (marks "reading"). (read.rs:168-169)
\* Precondition: reader is idle, registered, pointer not null.
ReaderBumpEpoch(r) ==
    /\ registered[r]
    /\ rPC[r] = "Idle"
    /\ enters[r] = 0                                   \* not nested (read.rs:122)
    /\ pointer /= "null"                                \* writer not taken (read.rs:180)
    /\ epoch' = [epoch EXCEPT ![r] = epoch[r] + 1]     \* now odd (read.rs:169)
    /\ rPC' = [rPC EXCEPT ![r] = "EpochBumped"]
    /\ UNCHANGED <<pointer, writerCopy, lastEpochs, enters,
                   rCopyRef, wPC, copyData, totalOps, first, second,
                   registered, mutexHolder, taken,
                   readerFenceSkipped, writerFenceSkipped, nondetAbsorbActive>>

\* --- ReaderLoadPointer: second step — fence(SeqCst) + load pointer ---
\* With fence: sees current pointer. Without fence (Family 1): may see stale.
\* (read.rs:172: fence(Ordering::SeqCst))
\* (read.rs:175: self.inner.load(Ordering::Acquire))
ReaderLoadPointer(r) ==
    /\ rPC[r] = "EpochBumped"
    /\ pointer /= "null"
    /\ IF ~readerFenceSkipped[r]
       THEN \* Fence intact: reader sees current pointer (read.rs:172-175)
            rCopyRef' = [rCopyRef EXCEPT ![r] = pointer]
       ELSE \* Family 1 fault: fence skipped, may see any copy
            \* (sync.rs:6-17 — loom downgrades SeqCst to Acquire)
            \E c \in {"L", "R"} :
                rCopyRef' = [rCopyRef EXCEPT ![r] = c]
    /\ enters' = [enters EXCEPT ![r] = 1]              \* (read.rs:182-183)
    /\ rPC' = [rPC EXCEPT ![r] = "Reading"]
    /\ UNCHANGED <<pointer, writerCopy, epoch, lastEpochs,
                   wPC, copyData, totalOps, first, second,
                   registered, mutexHolder, taken,
                   readerFenceSkipped, writerFenceSkipped, nondetAbsorbActive>>

\* --- ReaderLoadNull: pointer became null after epoch bump ---
\* Reader bumps epoch back to even and returns None. (read.rs:188-193)
ReaderLoadNull(r) ==
    /\ rPC[r] = "EpochBumped"
    /\ pointer = "null"
    /\ epoch' = [epoch EXCEPT ![r] = epoch[r] + 1]     \* restore even (read.rs:191)
    /\ rPC' = [rPC EXCEPT ![r] = "Idle"]
    /\ UNCHANGED <<pointer, writerCopy, lastEpochs, enters,
                   rCopyRef, wPC, copyData, totalOps, first, second,
                   registered, mutexHolder, taken,
                   readerFenceSkipped, writerFenceSkipped, nondetAbsorbActive>>

\* --- ReaderNestedEnter: already holds guard, just increment enters ---
\* (read.rs:121-139: enters != 0 branch)
ReaderNestedEnter(r) ==
    /\ rPC[r] = "Reading"
    /\ enters[r] > 0
    /\ enters' = [enters EXCEPT ![r] = enters[r] + 1]  \* (read.rs:131)
    /\ UNCHANGED <<pointer, writerCopy, epoch, lastEpochs,
                   rPC, rCopyRef, wPC, copyData, totalOps, first, second,
                   registered, mutexHolder, taken,
                   readerFenceSkipped, writerFenceSkipped, nondetAbsorbActive>>

\* --- ReaderExit: drop one ReadGuard ---
\* Decrements enters. On last guard: bumps epoch to even. (guard.rs:118-125)
ReaderExit(r) ==
    /\ rPC[r] = "Reading"
    /\ enters[r] > 0
    /\ enters' = [enters EXCEPT ![r] = enters[r] - 1]
    /\ IF enters[r] - 1 = 0
       THEN \* Last guard dropped — bump epoch (even). (guard.rs:123)
            /\ epoch' = [epoch EXCEPT ![r] = epoch[r] + 1]
            /\ rPC' = [rPC EXCEPT ![r] = "Idle"]
            /\ rCopyRef' = [rCopyRef EXCEPT ![r] = "none"]
       ELSE
            UNCHANGED <<epoch, rPC, rCopyRef>>
    /\ UNCHANGED <<pointer, writerCopy, lastEpochs,
                   wPC, copyData, totalOps, first, second,
                   registered, mutexHolder, taken,
                   readerFenceSkipped, writerFenceSkipped, nondetAbsorbActive>>

\* --- ReaderRegister: create a new ReadHandle ---
\* Acquires mutex, inserts epoch into slab, releases mutex. (read.rs:87-101)
\* Modeled as atomic since no interesting interleaving.
ReaderRegister(r) ==
    /\ ~registered[r]
    /\ mutexHolder = "none"                             \* mutex free (read.rs:91)
    /\ pointer /= "null"                                \* can't register after take
    /\ registered' = [registered EXCEPT ![r] = TRUE]
    /\ epoch' = [epoch EXCEPT ![r] = 0]                \* new epoch starts at 0
    /\ enters' = [enters EXCEPT ![r] = 0]
    /\ rPC' = [rPC EXCEPT ![r] = "Idle"]
    /\ rCopyRef' = [rCopyRef EXCEPT ![r] = "none"]
    /\ UNCHANGED <<pointer, writerCopy, lastEpochs,
                   wPC, copyData, totalOps, first, second,
                   mutexHolder, taken,
                   readerFenceSkipped, writerFenceSkipped, nondetAbsorbActive>>

\* --- ReaderDeregister: drop ReadHandle ---
\* Acquires mutex, removes epoch from slab, releases. (read.rs:55-63)
\* Modeled as atomic (reader is idle, no deadlock risk).
ReaderDeregister(r) ==
    /\ registered[r]
    /\ rPC[r] = "Idle"
    /\ enters[r] = 0                                   \* (read.rs:61: assert)
    /\ mutexHolder = "none"                             \* mutex free (read.rs:59)
    /\ registered' = [registered EXCEPT ![r] = FALSE]
    /\ UNCHANGED <<pointer, writerCopy, epoch, lastEpochs, enters,
                   rPC, rCopyRef, wPC, copyData, totalOps, first, second,
                   mutexHolder, taken,
                   readerFenceSkipped, writerFenceSkipped, nondetAbsorbActive>>

\* --- ReaderStartClone: commit to cloning while holding guard ---
\* Transitions to CloningBlocked: reader can't exit guard until mutex acquired.
\* This models the deadlock scenario (Family 3, commit 02eb63b).
\* (read.rs:74-78 → read.rs:91: epochs.lock())
ReaderStartClone(r) ==
    /\ rPC[r] = "Reading"
    /\ enters[r] > 0                                   \* must hold guard
    /\ rPC' = [rPC EXCEPT ![r] = "CloningBlocked"]
    /\ UNCHANGED <<pointer, writerCopy, epoch, lastEpochs, enters,
                   rCopyRef, wPC, copyData, totalOps, first, second,
                   registered, mutexHolder, taken,
                   readerFenceSkipped, writerFenceSkipped, nondetAbsorbActive>>

\* --- ReaderCloneComplete: finish clone (acquire mutex, create epoch, release) ---
\* Only enabled when mutex is free. (read.rs:91)
ReaderCloneComplete(r) ==
    /\ rPC[r] = "CloningBlocked"
    /\ mutexHolder = "none"                             \* mutex available
    \* Atomic: acquire mutex, insert new epoch, release.
    \* In our fixed-Reader-set model, clone doesn't create a new reader.
    /\ rPC' = [rPC EXCEPT ![r] = "Reading"]
    /\ UNCHANGED <<pointer, writerCopy, epoch, lastEpochs, enters,
                   rCopyRef, wPC, copyData, totalOps, first, second,
                   registered, mutexHolder, taken,
                   readerFenceSkipped, writerFenceSkipped, nondetAbsorbActive>>

\* ========================================================================
\* Writer Actions
\* ========================================================================

\* --- WriterAppend: add operation to oplog (or direct-apply if first) ---
\* (write.rs:463-465: append; write.rs:515-533: extend with first optimization)
WriterAppend ==
    /\ wPC = "Idle"
    /\ ~taken
    /\ totalOps < MaxOps
    /\ totalOps' = totalOps + 1
    /\ IF first
       THEN \* Direct apply to writerCopy (write.rs:519-529: absorb_second)
            copyData' = [copyData EXCEPT ![writerCopy] = copyData[writerCopy] + 1]
       ELSE \* Goes to oplog (write.rs:531)
            UNCHANGED copyData
    /\ UNCHANGED <<pointer, writerCopy, epoch, lastEpochs, enters,
                   rPC, rCopyRef, wPC, first, second,
                   registered, mutexHolder, taken,
                   readerFenceSkipped, writerFenceSkipped, nondetAbsorbActive>>

\* --- WriterStartPublish: begin publish(), acquire mutex ---
\* (write.rs:343-352)
WriterStartPublish ==
    /\ wPC = "Idle"
    /\ ~taken
    /\ mutexHolder = "none"
    /\ wPC' = "PubLocked"
    /\ mutexHolder' = "writer"
    /\ UNCHANGED <<pointer, writerCopy, epoch, lastEpochs, enters,
                   rPC, rCopyRef, copyData, totalOps, first, second,
                   registered, taken,
                   readerFenceSkipped, writerFenceSkipped, nondetAbsorbActive>>

\* --- WriterWait: spin-wait for all readers to depart ---
\* Guard: enabled only when all registered readers have quiesced.
\* (write.rs:236-296)
WriterWait ==
    /\ wPC = "PubLocked"
    /\ AllReadersQuiesced
    /\ wPC' = "PubWaited"
    /\ UNCHANGED <<pointer, writerCopy, epoch, lastEpochs, enters,
                   rPC, rCopyRef, copyData, totalOps, first, second,
                   registered, mutexHolder, taken,
                   readerFenceSkipped, writerFenceSkipped, nondetAbsorbActive>>

\* --- WriterApplyAndSwap: apply oplog to writerCopy, then swap pointer ---
\* Combines apply + swap as one atomic step (writer holds mutex, no reader
\* on writerCopy). (write.rs:363-425: update_and_swap)
WriterApplyAndSwap ==
    /\ wPC = "PubWaited"
    \* Apply oplog to writerCopy (write.rs:367-407)
    /\ \/ /\ first
          \* First publish: skip apply (write.rs:405-407)
          /\ first' = FALSE
          /\ UNCHANGED <<copyData, second>>
       \/ /\ ~first
          \* sync_with if needed (write.rs:381-384)
          /\ IF second THEN second' = FALSE ELSE UNCHANGED second
          \* Apply ops: writerCopy catches up to totalOps
          \* (write.rs:388-400: absorb_second for drain + absorb_first for remaining)
          /\ IF nondetAbsorbActive
             THEN \* Family 2 fault: non-deterministic absorb — wrong total
                  copyData' = [copyData EXCEPT ![writerCopy] = totalOps + 1]
             ELSE \* Deterministic: correct total
                  copyData' = [copyData EXCEPT ![writerCopy] = totalOps]
          /\ UNCHANGED first
    \* Swap pointer: writerCopy becomes new r_handle (write.rs:418-425)
    /\ pointer' = writerCopy
    /\ writerCopy' = OtherCopy(writerCopy)
    /\ wPC' = "PubSwapped"
    /\ UNCHANGED <<epoch, lastEpochs, enters,
                   rPC, rCopyRef, totalOps,
                   registered, mutexHolder, taken,
                   readerFenceSkipped, writerFenceSkipped, nondetAbsorbActive>>

\* --- WriterDoFence: SeqCst fence after swap ---
\* Ensures subsequent epoch reads are ordered after the swap.
\* (write.rs:428: fence(Ordering::SeqCst))
WriterDoFence ==
    /\ wPC = "PubSwapped"
    /\ wPC' = "PubFenced"
    /\ UNCHANGED <<pointer, writerCopy, epoch, lastEpochs, enters,
                   rPC, rCopyRef, copyData, totalOps, first, second,
                   registered, mutexHolder, taken,
                   readerFenceSkipped, writerFenceSkipped, nondetAbsorbActive>>

\* --- WriterSnapshotEpochs: read all epochs + release mutex ---
\* With fence: sees current epochs. Without fence (Family 1): stale values.
\* (write.rs:430-432)
WriterSnapshotEpochs ==
    /\ wPC = "PubFenced"
    /\ IF ~writerFenceSkipped
       THEN \* Fresh read after fence (write.rs:431)
            lastEpochs' = [r \in Reader |-> epoch[r]]
       ELSE \* Family 1 fault: reads pre-swap values (stale)
            UNCHANGED lastEpochs
    /\ wPC' = "Idle"
    /\ mutexHolder' = "none"                            \* release mutex
    /\ UNCHANGED <<pointer, writerCopy, epoch, enters,
                   rPC, rCopyRef, copyData, totalOps, first, second,
                   registered, taken,
                   readerFenceSkipped, writerFenceSkipped, nondetAbsorbActive>>

\* --- WriterStartTryPublish: begin try_publish(), acquire mutex ---
\* (write.rs:309-311)
WriterStartTryPublish ==
    /\ wPC = "Idle"
    /\ ~taken
    /\ mutexHolder = "none"
    /\ wPC' = "TryLocked"
    /\ mutexHolder' = "writer"
    /\ UNCHANGED <<pointer, writerCopy, epoch, lastEpochs, enters,
                   rPC, rCopyRef, copyData, totalOps, first, second,
                   registered, taken,
                   readerFenceSkipped, writerFenceSkipped, nondetAbsorbActive>>

\* --- WriterTryPublishSucceed: all readers departed, proceed to apply+swap ---
\* (write.rs:316-327: single-pass epoch check passes)
WriterTryPublishSucceed ==
    /\ wPC = "TryLocked"
    /\ AllReadersQuiesced
    /\ wPC' = "PubWaited"                              \* reuse publish path
    /\ UNCHANGED <<pointer, writerCopy, epoch, lastEpochs, enters,
                   rPC, rCopyRef, copyData, totalOps, first, second,
                   registered, mutexHolder, taken,
                   readerFenceSkipped, writerFenceSkipped, nondetAbsorbActive>>

\* --- WriterTryPublishFail: reader hasn't advanced, abort ---
\* (write.rs:324-325: return false)
WriterTryPublishFail ==
    /\ wPC = "TryLocked"
    /\ ~AllReadersQuiesced
    /\ wPC' = "Idle"
    /\ mutexHolder' = "none"                            \* release mutex
    /\ UNCHANGED <<pointer, writerCopy, epoch, lastEpochs, enters,
                   rPC, rCopyRef, copyData, totalOps, first, second,
                   registered, taken,
                   readerFenceSkipped, writerFenceSkipped, nondetAbsorbActive>>

\* --- WriterStartTakeInner: swap pointer to null ---
\* Precondition: at least one publish done (first=false).
\* (write.rs:149-170)
WriterStartTakeInner ==
    /\ wPC = "Idle"
    /\ ~taken
    /\ ~first                                           \* (write.rs:161-166)
    /\ taken' = TRUE                                    \* (write.rs:157)
    /\ pointer' = "null"                                \* (write.rs:170: swap null, Release)
    /\ wPC' = "TakeNulled"
    /\ UNCHANGED <<writerCopy, epoch, lastEpochs, enters,
                   rPC, rCopyRef, copyData, totalOps, first, second,
                   registered, mutexHolder,
                   readerFenceSkipped, writerFenceSkipped, nondetAbsorbActive>>

\* --- WriterTakeInnerLock: acquire mutex for wait ---
\* (write.rs:173-174)
WriterTakeInnerLock ==
    /\ wPC = "TakeNulled"
    /\ mutexHolder = "none"
    /\ wPC' = "TakeLocked"
    /\ mutexHolder' = "writer"
    /\ UNCHANGED <<pointer, writerCopy, epoch, lastEpochs, enters,
                   rPC, rCopyRef, copyData, totalOps, first, second,
                   registered, taken,
                   readerFenceSkipped, writerFenceSkipped, nondetAbsorbActive>>

\* --- WriterTakeInnerWait: wait for all readers to depart ---
\* (write.rs:175)
WriterTakeInnerWait ==
    /\ wPC = "TakeLocked"
    /\ AllReadersQuiesced
    /\ wPC' = "TakeWaited"
    /\ UNCHANGED <<pointer, writerCopy, epoch, lastEpochs, enters,
                   rPC, rCopyRef, copyData, totalOps, first, second,
                   registered, mutexHolder, taken,
                   readerFenceSkipped, writerFenceSkipped, nondetAbsorbActive>>

\* --- WriterTakeInnerComplete: fence + done ---
\* (write.rs:178: fence(SeqCst); write.rs:185-198: drop + return)
WriterTakeInnerComplete ==
    /\ wPC = "TakeWaited"
    /\ wPC' = "Done"
    /\ mutexHolder' = "none"                            \* release mutex
    /\ UNCHANGED <<pointer, writerCopy, epoch, lastEpochs, enters,
                   rPC, rCopyRef, copyData, totalOps, first, second,
                   registered, taken,
                   readerFenceSkipped, writerFenceSkipped, nondetAbsorbActive>>

\* ========================================================================
\* Fault Injection Actions
\* ========================================================================

\* --- SkipReaderFence: permanently disable reader's SeqCst fence ---
\* Models sync.rs:6-17 (loom downgrades SeqCst to Acquire). (Family 1)
SkipReaderFence(r) ==
    /\ ~readerFenceSkipped[r]
    /\ rPC[r] = "Idle"                                  \* set before entering
    /\ readerFenceSkipped' = [readerFenceSkipped EXCEPT ![r] = TRUE]
    /\ UNCHANGED <<pointer, writerCopy, epoch, lastEpochs, enters,
                   rPC, rCopyRef, wPC, copyData, totalOps, first, second,
                   registered, mutexHolder, taken,
                   writerFenceSkipped, nondetAbsorbActive>>

\* --- SkipWriterFence: permanently disable writer's SeqCst fence ---
\* (Family 1)
SkipWriterFence ==
    /\ ~writerFenceSkipped
    /\ wPC = "Idle"                                     \* set before publish
    /\ writerFenceSkipped' = TRUE
    /\ UNCHANGED <<pointer, writerCopy, epoch, lastEpochs, enters,
                   rPC, rCopyRef, wPC, copyData, totalOps, first, second,
                   registered, mutexHolder, taken,
                   readerFenceSkipped, nondetAbsorbActive>>

\* --- EnableNonDetAbsorb: activate non-deterministic absorb ---
\* Models non-deterministic Hash/Eq causing divergent apply. (Family 2)
EnableNonDetAbsorb ==
    /\ ~nondetAbsorbActive
    /\ nondetAbsorbActive' = TRUE
    /\ UNCHANGED <<pointer, writerCopy, epoch, lastEpochs, enters,
                   rPC, rCopyRef, wPC, copyData, totalOps, first, second,
                   registered, mutexHolder, taken,
                   readerFenceSkipped, writerFenceSkipped>>

\* ========================================================================
\* Next and Spec
\* ========================================================================

Next ==
    \/ \E r \in Reader :
        \/ ReaderBumpEpoch(r)
        \/ ReaderLoadPointer(r)
        \/ ReaderLoadNull(r)
        \/ ReaderNestedEnter(r)
        \/ ReaderExit(r)
        \/ ReaderRegister(r)
        \/ ReaderDeregister(r)
        \/ ReaderStartClone(r)
        \/ ReaderCloneComplete(r)
        \/ SkipReaderFence(r)
    \/ WriterAppend
    \/ WriterStartPublish
    \/ WriterWait
    \/ WriterApplyAndSwap
    \/ WriterDoFence
    \/ WriterSnapshotEpochs
    \/ WriterStartTryPublish
    \/ WriterTryPublishSucceed
    \/ WriterTryPublishFail
    \/ WriterStartTakeInner
    \/ WriterTakeInnerLock
    \/ WriterTakeInnerWait
    \/ WriterTakeInnerComplete
    \/ SkipWriterFence
    \/ EnableNonDetAbsorb

Spec == Init /\ [][Next]_vars

\* ========================================================================
\* Invariants
\* ========================================================================

\* --- Structural invariants (always checked) ---

TypeOK ==
    /\ pointer \in {"L", "R", "null"}
    /\ writerCopy \in {"L", "R"}
    /\ \A r \in Reader : epoch[r] \in Nat
    /\ \A r \in Reader : lastEpochs[r] \in Nat
    /\ \A r \in Reader : enters[r] \in Nat
    /\ \A r \in Reader : rPC[r] \in {"Idle", "EpochBumped", "Reading", "CloningBlocked"}
    /\ \A r \in Reader : rCopyRef[r] \in {"L", "R", "none"}
    /\ wPC \in {"Idle", "PubLocked", "PubWaited", "PubSwapped", "PubFenced",
                "TryLocked", "TakeNulled", "TakeLocked", "TakeWaited", "Done"}
    /\ \A c \in {"L", "R"} : copyData[c] \in Nat
    /\ totalOps \in Nat
    /\ first \in BOOLEAN
    /\ second \in BOOLEAN
    /\ \A r \in Reader : registered[r] \in BOOLEAN
    /\ mutexHolder \in ({"none", "writer"} \cup Reader)
    /\ taken \in BOOLEAN

\* Idle reader has even epoch; reading reader has odd epoch.
EpochParity ==
    \A r \in Reader :
        registered[r] =>
            /\ (rPC[r] = "Idle" => epoch[r] % 2 = 0)
            /\ (rPC[r] \in {"Reading", "CloningBlocked"} => epoch[r] % 2 = 1)

\* Pointer and writerCopy are always different copies (when pointer is valid).
PointerCopyDisjoint ==
    pointer \in {"L", "R"} => pointer /= writerCopy

\* --- Safety invariants ---

\* Writer never modifies a copy that any reader is referencing.
\* Checked when writer is about to apply (PubWaited) or take_inner waited.
\* Families 1, 4.
NoWriteWhileRead ==
    wPC \in {"PubWaited", "TakeWaited"} => ReadersOnCopy(writerCopy) = {}

\* After deterministic apply, the freshly-swapped pointer copy has correct data.
\* Family 2.
ApplyCorrectness ==
    (wPC = "PubSwapped" /\ ~first /\ ~nondetAbsorbActive) =>
    copyData[pointer] = totalOps

\* --- Extension invariants (bug-family specific) ---
\* Used in MC_hunt_*.cfg files for targeted bug detection.

\* Family 1: same as NoWriteWhileRead but expected to FAIL with fence faults.
OrderingNoWriteWhileRead ==
    wPC \in {"PubWaited", "TakeWaited"} => ReadersOnCopy(writerCopy) = {}

\* Family 2: same as ApplyCorrectness but drops the ~nondetAbsorbActive guard.
\* Expected to FAIL when non-deterministic absorb is active.
AbsorbApplyCorrectness ==
    (wPC = "PubSwapped" /\ ~first) => copyData[pointer] = totalOps

\* Family 4: pointer and writerCopy stay consistent through all publish variants.
VariantSafety ==
    /\ (pointer \in {"L", "R"} => pointer /= writerCopy)
    /\ (wPC = "Done" => pointer = "null")

====
