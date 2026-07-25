---- MODULE base ----
(***************************************************************************)
(* TLA+ specification of jonhoo/left-right (Round 2 — caller misuse and    *)
(* action-granularity gap).                                                *)
(*                                                                         *)
(* Source files (artifact/left-right/src/):                                *)
(*   write.rs      — WriteHandle: publish, try_publish, take_inner,        *)
(*                   wait, update_and_swap                                 *)
(*   read.rs       — ReadHandle: enter (fresh + nested), Drop, factory     *)
(*   read/guard.rs — ReadGuard: epoch restore on drop                      *)
(*   lib.rs        — Absorb trait, new / new_from_empty constructors       *)
(*                                                                         *)
(* Bug families (per .specula-output/modeling-brief.md):                   *)
(*   F1 — take_inner stale-snapshot UAF (PR #144 OPEN; HIGH)               *)
(*   F2 — Reentrant enter() panics on NULL pointer (read.rs:146; MEDIUM)   *)
(*   F3 — Long-held guard blocks publish (liveness; MEDIUM)                *)
(*   F4 — Per-reader snapshot in update_and_swap (granularity; MEDIUM)     *)
(*                                                                         *)
(* Out of scope (per brief §3.2):                                          *)
(*   - SeqCst fence skipping (prior round modeled `MCSkipReaderFence` /    *)
(*     `MCSkipWriterFence`; 0 bugs found).                                 *)
(*   - Aliased<T,D> internals; Send/Sync; cache padding; ReadGuard::map.   *)
(*   - User-supplied Absorb determinism / oplog determinism.               *)
(***************************************************************************)

EXTENDS Integers, FiniteSets, TLC

CONSTANTS
    Reader,             \* set of reader thread IDs
    MaxOps,             \* bound on totalOps (state-space bound)
    ApplyPR144Fix       \* BOOLEAN — when TRUE, refresh lastEpochs after
                        \* the take_inner NULL swap (proposed PR #144 fix).

ASSUME MaxOps \in Nat \ {0}
ASSUME ApplyPR144Fix \in BOOLEAN

\* ========================================================================
\* Variables
\* ========================================================================

VARIABLES
\* Buffer / pointer state ---------------------------------------------------
    inner_ptr,          \* AtomicPtr<T> at read.rs:41; "L" | "R" | "null"
    writerCopy,         \* {"L","R"}; w_handle (write.rs:31)
    copyAlive,          \* [{"L","R"} -> BOOLEAN]; FALSE after drop_first /
                        \* Taken::drop calls drop_second (write.rs:135, 190)
    synced,             \* [{"L","R"} -> BOOLEAN]; sync_with applied
                        \* (write.rs:415-418)
    copyData,           \* [{"L","R"} -> Nat]; abstract apply count

\* Reader / epoch state -----------------------------------------------------
    epoch,              \* [Reader -> Nat]; per-reader CachePadded<AtomicUsize>
                        \* (read.rs:43)
    lastEpochs,         \* [Reader -> Nat]; PERSISTENT writer snapshot
                        \* (write.rs:35; resized at write.rs:256, 327;
                        \* updated only by snap actions).  F1 hinges on
                        \* this remaining stale across calls.
    enters,             \* [Reader -> Nat]; Cell<usize> (read.rs:45)
    readerHolding,      \* [Reader -> {"L","R","none"}]; copy snapshotted at
                        \* enter() time, distinct from `inner_ptr` (the live
                        \* atomic).  Models the &T inside ReadGuard.
    releasedCopy,       \* {"L","R","none"}; pre-NULL pointer captured at
                        \* take_inner NULL-swap (write.rs:175).  This is the
                        \* r_handle the returned `Taken` wraps and that
                        \* `drop_second` frees on Drop (write.rs:135).

\* Program counters ---------------------------------------------------------
    rPC,                \* [Reader -> ReaderState]
    wPC,                \* WriterState
    panicked,           \* [Reader -> BOOLEAN]; F2 unreachable!() witness
                        \* at read.rs:146.

\* Oplog -------------------------------------------------------------------
    totalOps,           \* Nat
    oplogLen,           \* Nat; oplog VecDeque length (write.rs:32)
    swapIndex,          \* Nat; write.rs:33
    first,              \* BOOLEAN; write.rs:41
    second,             \* BOOLEAN; write.rs:43

\* Mutex / registration / taken --------------------------------------------
    registered,         \* [Reader -> BOOLEAN]; reader present in slab
    mutexHolder,        \* "none" | "writer" | Reader
    taken,              \* BOOLEAN (write.rs:45)

\* F4 — per-reader snapshot loop -------------------------------------------
    snapPending,        \* SUBSET Reader; readers not yet snapshotted in the
                        \* current update_and_swap snap loop (write.rs:464-466)

\* F3 — long-held guard adversary -------------------------------------------
    clientHolding       \* [Reader -> BOOLEAN]; when TRUE, ReaderExit is
                        \* disabled, modeling reader holding the guard
                        \* across yield/await/long user code.

coreVars  == <<inner_ptr, writerCopy, copyAlive, synced, copyData>>
readerVars == <<epoch, lastEpochs, enters, readerHolding, releasedCopy>>
pcVars    == <<rPC, wPC, panicked>>
oplogVars == <<totalOps, oplogLen, swapIndex, first, second>>
sysVars   == <<registered, mutexHolder, taken>>
faultVars == <<snapPending, clientHolding>>

vars == <<coreVars, readerVars, pcVars, oplogVars, sysVars, faultVars>>

\* ========================================================================
\* Helpers
\* ========================================================================

OtherCopy(c) == IF c = "L" THEN "R" ELSE "L"

\* The wait() skip rule from write.rs:272-274 / 277-300:
\*   for each registered reader ri:
\*     if last_epochs[ri] % 2 == 0 -> continue (assumed quiesced)
\*     else load epoch[ri]; if epoch[ri] != last_epochs[ri] -> assumed
\*          quiesced (advanced past); otherwise spin.
\* Returns TRUE iff every reader is "quiesced" by this rule.
AllReadersQuiescedByLastEpochs ==
    \A r \in Reader :
        registered[r] =>
            \/ lastEpochs[r] % 2 = 0           \* (write.rs:272)
            \/ epoch[r] /= lastEpochs[r]       \* (write.rs:277)

\* Readers currently inside an enter() critical section, holding copy c.
ReadersOnCopy(c) ==
    { r \in Reader :
        rPC[r] = "Reading" /\ readerHolding[r] = c }

\* ========================================================================
\* Init
\* ========================================================================

Init ==
    \* lib.rs:295-303 — new() initializes pointer to "L", w_handle to "R".
    /\ inner_ptr = "L"
    /\ writerCopy = "R"
    /\ copyAlive = [c \in {"L","R"} |-> TRUE]
    /\ synced = [c \in {"L","R"} |-> FALSE]
    /\ copyData = [c \in {"L","R"} |-> 0]
    /\ epoch = [r \in Reader |-> 0]            \* (read.rs:89)
    /\ lastEpochs = [r \in Reader |-> 0]       \* (write.rs:236)
    /\ enters = [r \in Reader |-> 0]           \* (read.rs:97)
    /\ readerHolding = [r \in Reader |-> "none"]
    /\ releasedCopy = "none"
    /\ rPC = [r \in Reader |-> "Idle"]
    /\ wPC = "Idle"
    /\ panicked = [r \in Reader |-> FALSE]
    /\ totalOps = 0
    /\ oplogLen = 0
    /\ swapIndex = 0
    /\ first = TRUE                            \* (write.rs:241)
    /\ second = TRUE                           \* (write.rs:242)
    /\ registered = [r \in Reader |-> TRUE]    \* (lib.rs:280-282)
    /\ mutexHolder = "none"
    /\ taken = FALSE
    /\ snapPending = {}
    /\ clientHolding = [r \in Reader |-> FALSE]

\* ========================================================================
\* Reader actions — read.rs / guard.rs
\* ========================================================================

\* ReaderEnterFreshBumpEpoch — read.rs:180 fetch_add(1, AcqRel).
\* Enabled only when enters[r] = 0 (the non-reentrant branch).
ReaderEnterFreshBumpEpoch(r) ==
    /\ registered[r]
    /\ rPC[r] = "Idle"
    /\ enters[r] = 0                                \* (read.rs:121-122)
    /\ epoch' = [epoch EXCEPT ![r] = epoch[r] + 1]
    /\ rPC' = [rPC EXCEPT ![r] = "EpochBumped"]
    /\ UNCHANGED <<coreVars,
                   lastEpochs, enters, readerHolding, releasedCopy,
                   wPC, panicked, oplogVars, sysVars, faultVars>>

\* ReaderEnterFreshLoad — read.rs:183 fence(SeqCst); read.rs:186 load;
\*                        read.rs:192-214 if-let-Some / else.
\* The else branch (pointer = NULL) is the *graceful* return path that
\* contrasts with F2 (the nested branch panics instead at read.rs:146).
ReaderEnterFreshLoad(r) ==
    /\ rPC[r] = "EpochBumped"
    /\ \/ \* (read.rs:192-205) pointer non-null -> mint guard
          /\ inner_ptr /= "null"
          /\ readerHolding' = [readerHolding EXCEPT ![r] = inner_ptr]
          /\ enters' = [enters EXCEPT ![r] = 1]              \* (read.rs:194-195)
          /\ rPC' = [rPC EXCEPT ![r] = "Reading"]
          /\ UNCHANGED epoch
       \/ \* (read.rs:206-213) pointer = null -> graceful return
          /\ inner_ptr = "null"
          /\ epoch' = [epoch EXCEPT ![r] = epoch[r] + 1]     \* (read.rs:209)
          /\ rPC' = [rPC EXCEPT ![r] = "Idle"]
          /\ UNCHANGED <<readerHolding, enters>>
    /\ UNCHANGED <<coreVars, lastEpochs, releasedCopy,
                   wPC, panicked, oplogVars, sysVars, faultVars>>

\* ReaderEnterNestedLoad — read.rs:120-148 reentrant branch.
\* Bug F2: when inner_ptr = NULL, the `unreachable!()` at read.rs:146 fires,
\* causing a PANIC.  We model this by setting panicked[r] := TRUE, which
\* the NoUnreachablePanic invariant flags as a violation.
ReaderEnterNestedLoad(r) ==
    /\ rPC[r] = "Reading"
    /\ enters[r] > 0                                       \* (read.rs:122)
    /\ ~panicked[r]
    /\ \/ \* (read.rs:130-144) pointer non-null -> mint nested guard
          /\ inner_ptr /= "null"
          /\ enters' = [enters EXCEPT ![r] = enters[r] + 1]  \* (read.rs:133-134)
          /\ readerHolding' = [readerHolding EXCEPT ![r] = inner_ptr]
                                  \* read.rs:126 reload may observe a different
                                  \* copy than the outer guard's; this models
                                  \* re-aliasing.
          /\ UNCHANGED panicked
       \/ \* (read.rs:146) pointer = null -> unreachable!() PANIC
          /\ inner_ptr = "null"
          /\ panicked' = [panicked EXCEPT ![r] = TRUE]
          /\ UNCHANGED <<enters, readerHolding>>
    /\ UNCHANGED <<coreVars, epoch, lastEpochs, releasedCopy,
                   rPC, wPC, oplogVars, sysVars, faultVars>>

\* ReaderExit — guard.rs:117-130 (ReadGuard::Drop).
\* F3: clientHolding[r] disables exit, modeling a reader holding the guard
\* across an `await` or arbitrary user code.
ReaderExit(r) ==
    /\ rPC[r] = "Reading"
    /\ enters[r] > 0
    /\ ~clientHolding[r]                              \* F3 adversary gate
    /\ enters' = [enters EXCEPT ![r] = enters[r] - 1] \* (guard.rs:120-121)
    /\ IF enters[r] - 1 = 0
       THEN /\ epoch' = [epoch EXCEPT ![r] = epoch[r] + 1]   \* (guard.rs:124)
            /\ rPC' = [rPC EXCEPT ![r] = "Idle"]
            /\ readerHolding' = [readerHolding EXCEPT ![r] = "none"]
       ELSE UNCHANGED <<epoch, rPC, readerHolding>>
    /\ UNCHANGED <<coreVars, lastEpochs, releasedCopy,
                   wPC, panicked, oplogVars, sysVars, faultVars>>

\* ========================================================================
\* Caller-misuse adversary (F3) — long-held guard.
\* ========================================================================
\* These actions model a reader pinning the guard while doing arbitrary
\* user-side work; they have no effect on the protocol state other than
\* gating ReaderExit.  Without ClientHoldGuardRelease eventually firing,
\* a writer waiting on this reader's epoch spins forever.

ClientHoldGuardSet(r) ==
    /\ rPC[r] = "Reading"
    /\ enters[r] > 0
    /\ ~clientHolding[r]
    /\ clientHolding' = [clientHolding EXCEPT ![r] = TRUE]
    /\ UNCHANGED <<coreVars, readerVars, pcVars,
                   oplogVars, sysVars, snapPending>>

ClientHoldGuardRelease(r) ==
    /\ clientHolding[r]
    /\ clientHolding' = [clientHolding EXCEPT ![r] = FALSE]
    /\ UNCHANGED <<coreVars, readerVars, pcVars,
                   oplogVars, sysVars, snapPending>>

\* ========================================================================
\* Writer — append (write.rs:497-506 -> 560-578)
\* ========================================================================

\* WriterAppend — single-op append.  In first-mode (no publish yet) writes
\* go directly to writerCopy via absorb_second (write.rs:564-574).  After
\* the first publish, writes accumulate in oplog (write.rs:575-577).
WriterAppend ==
    /\ wPC = "Idle"
    /\ ~taken
    /\ totalOps < MaxOps
    /\ totalOps' = totalOps + 1
    /\ IF first
       THEN /\ copyData' = [copyData EXCEPT ![writerCopy] =
                                copyData[writerCopy] + 1]
            /\ UNCHANGED oplogLen
       ELSE /\ oplogLen' = oplogLen + 1
            /\ UNCHANGED copyData
    /\ UNCHANGED <<inner_ptr, writerCopy, copyAlive, synced,
                   readerVars, rPC, wPC, panicked,
                   swapIndex, first, second,
                   sysVars, faultVars>>

\* ========================================================================
\* Writer — publish() — write.rs:370-391
\*   1. lock mutex
\*   2. wait()                    (write.rs:382)
\*   3. update_and_swap(...)      (write.rs:384) — split per F4
\*       3a. apply oplog (absorb)
\*       3b. atomic swap pointer  (write.rs:455)
\*       3c. SeqCst fence         (write.rs:462)
\*       3d. PER-READER snapshot loop (write.rs:464-466)
\*   4. release mutex (RAII)
\* ========================================================================

\* WriterStartPublish — write.rs:379-381 lock acquisition.
WriterStartPublish ==
    /\ wPC = "Idle"
    /\ ~taken
    /\ mutexHolder = "none"
    /\ wPC' = "PubLocked"
    /\ mutexHolder' = "writer"
    /\ UNCHANGED <<coreVars, readerVars,
                   rPC, panicked, oplogVars,
                   registered, taken, faultVars>>

\* WriterWait — write.rs:382 -> 247-307.  Spins on the skip rule using
\* PERSISTENT lastEpochs.  Enabled when all readers are quiesced.
WriterWait ==
    /\ wPC = "PubLocked"
    /\ AllReadersQuiescedByLastEpochs
    /\ wPC' = "PubWaited"
    /\ UNCHANGED <<coreVars, readerVars,
                   rPC, panicked, oplogVars, sysVars, faultVars>>

\* WriterPubApply — write.rs:401-441.  After wait() succeeds and before the
\* swap, apply oplog ops to writerCopy (or set first=false on first
\* publish).  No reader can be on writerCopy here (wait just returned).
WriterPubApply ==
    /\ wPC = "PubWaited"
    /\ \/ /\ first
          \* (write.rs:439-441) first publish: just clear the flag.
          /\ first' = FALSE
          /\ UNCHANGED <<copyData, second, synced, oplogLen, swapIndex>>
       \/ /\ ~first
          \* (write.rs:415-418) sync_with on second publish.
          /\ IF second
             THEN /\ second' = FALSE
                  /\ synced' = [synced EXCEPT ![writerCopy] = TRUE]
             ELSE UNCHANGED <<second, synced>>
          \* (write.rs:422-434) drain oplog into writerCopy.  We model
          \* "fully drained" with copyData' := totalOps; the F4 split
          \* doesn't depend on oplog interleaving.
          /\ copyData' = [copyData EXCEPT ![writerCopy] = totalOps]
          /\ swapIndex' = oplogLen
          /\ UNCHANGED <<oplogLen, first>>
    /\ wPC' = "PubApplied"
    /\ UNCHANGED <<inner_ptr, writerCopy, copyAlive,
                   readerVars, rPC, panicked, totalOps,
                   sysVars, faultVars>>

\* WriterPubSwap — write.rs:452-459 atomic swap inner_ptr ↔ writerCopy.
\* This is the linearization point: before this, readers see the old
\* pointer; after, they see the new pointer.
WriterPubSwap ==
    /\ wPC = "PubApplied"
    /\ inner_ptr' = writerCopy
    /\ writerCopy' = OtherCopy(writerCopy)
    /\ wPC' = "PubSwapped"
    /\ UNCHANGED <<copyAlive, synced, copyData,
                   readerVars, rPC, panicked, oplogVars,
                   sysVars, faultVars>>

\* WriterPubFence — write.rs:462 fence(SeqCst).  Models the visibility
\* boundary between the swap and the snapshot loop; modeled atomically.
WriterPubFence ==
    /\ wPC = "PubSwapped"
    /\ wPC' = "PubFenced"
    /\ UNCHANGED <<coreVars, readerVars,
                   rPC, panicked, oplogVars, sysVars, faultVars>>

\* WriterPubBeginSnap (F4) — write.rs:464 enters `for (ri, epoch) in
\* epochs.iter()`.  Initializes snapPending to all registered readers.
\* Critical: each reader is snapped ATOMICALLY but the LOOP is not — see
\* WriterPubSnapReader below.
WriterPubBeginSnap ==
    /\ wPC = "PubFenced"
    /\ snapPending' = { r \in Reader : registered[r] }
    /\ wPC' = "PubSnapping"
    /\ UNCHANGED <<coreVars, readerVars,
                   rPC, panicked, oplogVars, sysVars, clientHolding>>

\* WriterPubSnapReader (F4) — write.rs:465 epoch.load(Acquire) for one
\* reader.  Splits the loop body per-reader so other readers' epoch
\* changes can interleave between iterations.
WriterPubSnapReader(r) ==
    /\ wPC = "PubSnapping"
    /\ r \in snapPending
    /\ lastEpochs' = [lastEpochs EXCEPT ![r] = epoch[r]]
    /\ snapPending' = snapPending \ {r}
    /\ UNCHANGED <<coreVars,
                   epoch, enters, readerHolding, releasedCopy,
                   rPC, wPC, panicked, oplogVars, sysVars, clientHolding>>

\* WriterPubFinishSnap — write.rs:464-466 loop exit + mutex release at
\* end of update_and_swap (Drop of the lock guard).
WriterPubFinishSnap ==
    /\ wPC = "PubSnapping"
    /\ snapPending = {}
    /\ wPC' = "Idle"
    /\ mutexHolder' = "none"
    /\ UNCHANGED <<coreVars, readerVars,
                   rPC, panicked, oplogVars,
                   registered, taken, faultVars>>

\* ========================================================================
\* try_publish — write.rs:320-362
\* ========================================================================

\* WriterStartTryPublish — write.rs:322-323 lock; then non-blocking check.
WriterStartTryPublish ==
    /\ wPC = "Idle"
    /\ ~taken
    /\ mutexHolder = "none"
    /\ wPC' = "TryLocked"
    /\ mutexHolder' = "writer"
    /\ UNCHANGED <<coreVars, readerVars,
                   rPC, panicked, oplogVars,
                   registered, taken, faultVars>>

\* WriterTryPublishSucceed — write.rs:329-341 all readers advanced; then
\* call update_and_swap (write.rs:354) — re-uses publish path.
WriterTryPublishSucceed ==
    /\ wPC = "TryLocked"
    /\ AllReadersQuiescedByLastEpochs
    /\ wPC' = "PubWaited"            \* re-enter publish path at apply
    /\ UNCHANGED <<coreVars, readerVars,
                   rPC, panicked, oplogVars, sysVars, faultVars>>

\* WriterTryPublishFail — write.rs:337-349 reader not advanced; release
\* mutex without publishing.
WriterTryPublishFail ==
    /\ wPC = "TryLocked"
    /\ ~AllReadersQuiescedByLastEpochs
    /\ wPC' = "Idle"
    /\ mutexHolder' = "none"
    /\ UNCHANGED <<coreVars, readerVars,
                   rPC, panicked, oplogVars,
                   registered, taken, faultVars>>

\* ========================================================================
\* take_inner — write.rs:149-210.  HEADLINE F1 path.
\* Sequence:
\*   1. Set taken := TRUE                     (write.rs:162)
\*   2. publish() if first || !oplog.empty    (write.rs:166-167)  [up to 2x]
\*   3. NULL-swap inner_ptr (Release)         (write.rs:175)  *** GAP ***
\*   4. Acquire mutex                         (write.rs:178-179)
\*  [4.5. Re-snapshot lastEpochs — proposed PR #144 fix]
\*   5. wait() using STALE lastEpochs         (write.rs:180)  *** F1 BUG ***
\*   6. SeqCst fence                          (write.rs:183)
\*   7. drop_first(writerCopy)                (write.rs:190)
\*   8. drop_second(releasedCopy) on Taken    (write.rs:135)
\*
\* The bug: between step 2's snapshot and step 3, a reader can enter,
\* observe the post-step-2 pointer (= releasedCopy after step 3), and
\* end up in lastEpochs[r] = even (idle at snap time).  Step 5's skip
\* rule then misses them; step 7-8 frees buffers they still alias.
\* ========================================================================

\* WriterStartTakeInner — write.rs:152-162.  Sets taken; suppresses
\* further public publishes.
WriterStartTakeInner ==
    /\ wPC = "Idle"
    /\ ~taken
    /\ mutexHolder = "none"
    /\ taken' = TRUE
    /\ wPC' = "TIMaybePub"
    /\ UNCHANGED <<coreVars, readerVars,
                   rPC, panicked, oplogVars,
                   registered, mutexHolder, faultVars>>

\* (write.rs:166) first || !oplog.empty -> publish().  Re-uses publish path
\* by transitioning to "TIPubLocked" then through the same per-stage
\* sequence as a regular publish.
WriterTakeInnerMaybePublishGo ==
    /\ wPC = "TIMaybePub"
    /\ (first \/ oplogLen > 0)
    /\ wPC' = "TIPubLocked"
    /\ mutexHolder' = "writer"
    /\ UNCHANGED <<coreVars, readerVars,
                   rPC, panicked, oplogVars,
                   registered, taken, faultVars>>

\* (write.rs:166) Skip the publish path entirely when first=FALSE and
\* oplog is empty.  THIS IS THE F1 BUG-PROVOKING PATH: lastEpochs is
\* NOT refreshed and we go straight to the NULL swap.
WriterTakeInnerMaybePublishSkip ==
    /\ wPC = "TIMaybePub"
    /\ ~first
    /\ oplogLen = 0
    /\ wPC' = "TINullReady"
    /\ UNCHANGED <<coreVars, readerVars,
                   rPC, panicked, oplogVars, sysVars, faultVars>>

\* Inner publish stages (mirrors WriterWait/Apply/Swap/Fence/SnapBegin/
\* SnapReader/SnapFinish, but with TIPubX state names so we know we're
\* inside take_inner).
WriterTakeInnerPubWait ==
    /\ wPC = "TIPubLocked"
    /\ AllReadersQuiescedByLastEpochs
    /\ wPC' = "TIPubWaited"
    /\ UNCHANGED <<coreVars, readerVars,
                   rPC, panicked, oplogVars, sysVars, faultVars>>

WriterTakeInnerPubApply ==
    /\ wPC = "TIPubWaited"
    /\ \/ /\ first
          /\ first' = FALSE
          /\ UNCHANGED <<copyData, second, synced, oplogLen, swapIndex>>
       \/ /\ ~first
          /\ IF second
             THEN /\ second' = FALSE
                  /\ synced' = [synced EXCEPT ![writerCopy] = TRUE]
             ELSE UNCHANGED <<second, synced>>
          /\ copyData' = [copyData EXCEPT ![writerCopy] = totalOps]
          /\ swapIndex' = oplogLen
          /\ UNCHANGED <<oplogLen, first>>
    /\ wPC' = "TIPubApplied"
    /\ UNCHANGED <<inner_ptr, writerCopy, copyAlive,
                   readerVars, rPC, panicked, totalOps,
                   sysVars, faultVars>>

WriterTakeInnerPubSwap ==
    /\ wPC = "TIPubApplied"
    /\ inner_ptr' = writerCopy
    /\ writerCopy' = OtherCopy(writerCopy)
    /\ wPC' = "TIPubSwapped"
    /\ UNCHANGED <<copyAlive, synced, copyData,
                   readerVars, rPC, panicked, oplogVars,
                   sysVars, faultVars>>

WriterTakeInnerPubFence ==
    /\ wPC = "TIPubSwapped"
    /\ wPC' = "TIPubFenced"
    /\ UNCHANGED <<coreVars, readerVars,
                   rPC, panicked, oplogVars, sysVars, faultVars>>

WriterTakeInnerPubBeginSnap ==
    /\ wPC = "TIPubFenced"
    /\ snapPending' = { r \in Reader : registered[r] }
    /\ wPC' = "TIPubSnapping"
    /\ UNCHANGED <<coreVars, readerVars,
                   rPC, panicked, oplogVars, sysVars, clientHolding>>

WriterTakeInnerPubSnapReader(r) ==
    /\ wPC = "TIPubSnapping"
    /\ r \in snapPending
    /\ lastEpochs' = [lastEpochs EXCEPT ![r] = epoch[r]]
    /\ snapPending' = snapPending \ {r}
    /\ UNCHANGED <<coreVars,
                   epoch, enters, readerHolding, releasedCopy,
                   rPC, wPC, panicked, oplogVars, sysVars, clientHolding>>

WriterTakeInnerPubFinishSnap ==
    /\ wPC = "TIPubSnapping"
    /\ snapPending = {}
    \* (write.rs:166) After this publish, oplog is drained.  If still
    \* non-empty, take_inner would call publish() again (write.rs:169);
    \* in our model this is gated by oplogLen which we set to swapIndex
    \* in Apply.  After two publishes oplog is empty, so go to NULL-ready.
    /\ wPC' = "TINullReady"
    /\ mutexHolder' = "none"
    /\ UNCHANGED <<coreVars, readerVars,
                   rPC, panicked, oplogVars,
                   registered, taken, faultVars>>

\* WriterTakeInnerNullSwap — write.rs:175 atomic swap NULL, Release.
\* Captures the to-be-released pointer in releasedCopy and *does not*
\* update lastEpochs.  This is exactly the gap that opens F1.
WriterTakeInnerNullSwap ==
    /\ wPC = "TINullReady"
    /\ releasedCopy' = inner_ptr
    /\ inner_ptr' = "null"
    /\ wPC' = "TINulled"
    /\ UNCHANGED <<writerCopy, copyAlive, synced, copyData,
                   epoch, lastEpochs, enters, readerHolding,
                   rPC, panicked, oplogVars, sysVars, faultVars>>

\* WriterTakeInnerLock — write.rs:178-179 mutex acquire.
WriterTakeInnerLock ==
    /\ wPC = "TINulled"
    /\ mutexHolder = "none"
    /\ mutexHolder' = "writer"
    /\ wPC' = "TILocked"
    /\ UNCHANGED <<coreVars, readerVars,
                   rPC, panicked, oplogVars,
                   registered, taken, faultVars>>

\* WriterTakeInnerResnapshot — proposed PR #144 fix: refresh lastEpochs
\* AFTER the NULL swap so that any reader who entered between the prior
\* publish's snap and the NULL swap is now visible in lastEpochs.
\* Gated by ApplyPR144Fix.
\*
\* In the actual PR #144 patch, this is itself a per-reader loop with
\* SeqCst fence; we abstract it to one bulk refresh because (a) the loop
\* runs while the mutex is held — registered set is fixed — and (b) the
\* invariant check fires at the next state, so individual interleavings
\* inside this re-snap don't change the proof obligation.
WriterTakeInnerResnapshot ==
    /\ ApplyPR144Fix
    /\ wPC = "TILocked"
    /\ lastEpochs' = [r \in Reader |-> epoch[r]]
    /\ wPC' = "TIResnapped"
    /\ UNCHANGED <<coreVars,
                   epoch, enters, readerHolding, releasedCopy,
                   rPC, panicked, oplogVars, sysVars, faultVars>>

\* WriterTakeInnerWait — write.rs:180.  Reads lastEpochs and applies the
\* skip rule.  Enabled either from TILocked (no fix; skip rule sees stale
\* values) or TIResnapped (fix applied; skip rule sees current values).
WriterTakeInnerWait ==
    /\ \/ /\ wPC = "TILocked"
          /\ ~ApplyPR144Fix
       \/ wPC = "TIResnapped"
    /\ AllReadersQuiescedByLastEpochs
    /\ wPC' = "TIWaited"
    /\ UNCHANGED <<coreVars, readerVars,
                   rPC, panicked, oplogVars, sysVars, faultVars>>

\* WriterTakeInnerFence — write.rs:183 fence(SeqCst).  Models the
\* visibility ordering before drops; abstract single step.
WriterTakeInnerFence ==
    /\ wPC = "TIWaited"
    /\ wPC' = "TIFenced"
    /\ UNCHANGED <<coreVars, readerVars,
                   rPC, panicked, oplogVars, sysVars, faultVars>>

\* WriterTakeInnerDropFirst — write.rs:190 Box::from_raw(self.w_handle) +
\* Absorb::drop_first.  Drops writerCopy and releases the mutex.
\* SAFETY OBLIGATION: no reader on writerCopy.
WriterTakeInnerDropFirst ==
    /\ wPC = "TIFenced"
    /\ copyAlive' = [copyAlive EXCEPT ![writerCopy] = FALSE]
    /\ wPC' = "TIDropFirst"
    /\ mutexHolder' = "none"
    /\ UNCHANGED <<inner_ptr, writerCopy, synced, copyData,
                   readerVars, rPC, panicked, oplogVars,
                   registered, taken, faultVars>>

\* WriterTakeInnerDropSecond — Taken<T,O>::Drop (write.rs:135) inside
\* WriteHandle::drop (write.rs:217-221).  Drops releasedCopy.
\* SAFETY OBLIGATION: no reader on releasedCopy — THIS IS WHERE F1 FIRES.
WriterTakeInnerDropSecond ==
    /\ wPC = "TIDropFirst"
    /\ releasedCopy /= "none"
    /\ copyAlive' = [copyAlive EXCEPT ![releasedCopy] = FALSE]
    /\ wPC' = "TIDone"
    /\ UNCHANGED <<inner_ptr, writerCopy, synced, copyData,
                   readerVars, rPC, panicked, oplogVars,
                   sysVars, faultVars>>

\* ========================================================================
\* Next + Spec
\* ========================================================================

Next ==
    \/ \E r \in Reader :
        \/ ReaderEnterFreshBumpEpoch(r)
        \/ ReaderEnterFreshLoad(r)
        \/ ReaderEnterNestedLoad(r)
        \/ ReaderExit(r)
        \/ ClientHoldGuardSet(r)
        \/ ClientHoldGuardRelease(r)
        \/ WriterPubSnapReader(r)
        \/ WriterTakeInnerPubSnapReader(r)
    \/ WriterAppend
    \/ WriterStartPublish
    \/ WriterWait
    \/ WriterPubApply
    \/ WriterPubSwap
    \/ WriterPubFence
    \/ WriterPubBeginSnap
    \/ WriterPubFinishSnap
    \/ WriterStartTryPublish
    \/ WriterTryPublishSucceed
    \/ WriterTryPublishFail
    \/ WriterStartTakeInner
    \/ WriterTakeInnerMaybePublishGo
    \/ WriterTakeInnerMaybePublishSkip
    \/ WriterTakeInnerPubWait
    \/ WriterTakeInnerPubApply
    \/ WriterTakeInnerPubSwap
    \/ WriterTakeInnerPubFence
    \/ WriterTakeInnerPubBeginSnap
    \/ WriterTakeInnerPubFinishSnap
    \/ WriterTakeInnerNullSwap
    \/ WriterTakeInnerLock
    \/ WriterTakeInnerResnapshot
    \/ WriterTakeInnerWait
    \/ WriterTakeInnerFence
    \/ WriterTakeInnerDropFirst
    \/ WriterTakeInnerDropSecond

Spec == Init /\ [][Next]_vars

\* ========================================================================
\* Type / structural invariants
\* ========================================================================

ReaderStates == {"Idle", "EpochBumped", "Reading"}

WriterStates ==
    {"Idle",
     "PubLocked", "PubWaited", "PubApplied", "PubSwapped", "PubFenced",
     "PubSnapping",
     "TryLocked",
     "TIMaybePub",
     "TIPubLocked", "TIPubWaited", "TIPubApplied", "TIPubSwapped",
     "TIPubFenced", "TIPubSnapping",
     "TINullReady", "TINulled",
     "TILocked", "TIResnapped", "TIWaited", "TIFenced",
     "TIDropFirst", "TIDone"}

TypeOK ==
    /\ inner_ptr \in {"L","R","null"}
    /\ writerCopy \in {"L","R"}
    /\ \A c \in {"L","R"} : copyAlive[c] \in BOOLEAN
    /\ \A c \in {"L","R"} : synced[c] \in BOOLEAN
    /\ \A c \in {"L","R"} : copyData[c] \in Nat
    /\ \A r \in Reader : epoch[r] \in Nat
    /\ \A r \in Reader : lastEpochs[r] \in Nat
    /\ \A r \in Reader : enters[r] \in Nat
    /\ \A r \in Reader : readerHolding[r] \in {"L","R","none"}
    /\ releasedCopy \in {"L","R","none"}
    /\ \A r \in Reader : rPC[r] \in ReaderStates
    /\ wPC \in WriterStates
    /\ \A r \in Reader : panicked[r] \in BOOLEAN
    /\ totalOps \in Nat
    /\ oplogLen \in Nat
    /\ swapIndex \in Nat
    /\ first \in BOOLEAN
    /\ second \in BOOLEAN
    /\ \A r \in Reader : registered[r] \in BOOLEAN
    /\ mutexHolder \in ({"none","writer"} \cup Reader)
    /\ taken \in BOOLEAN
    /\ snapPending \subseteq Reader
    /\ \A r \in Reader : clientHolding[r] \in BOOLEAN

\* Reader epoch parity matches their PC: idle = even, reading = odd.
\* Note: EpochBumped is the in-flight transition; epoch is odd there too.
EpochParity ==
    \A r \in Reader :
        registered[r] =>
            /\ (rPC[r] = "Idle" => epoch[r] % 2 = 0)
            /\ (rPC[r] \in {"EpochBumped","Reading"} => epoch[r] % 2 = 1)

\* The active read pointer and the writer's working copy are never the
\* same buffer (unless the pointer is NULL).
PointerCopyDisjoint ==
    inner_ptr \in {"L","R"} => inner_ptr /= writerCopy

\* ========================================================================
\* Bug-family safety invariants
\* ========================================================================

\* F1 / general: writer never mutates a copy a reader currently holds.
\* The mutating sites are: PubApplied (after wait, applies oplog) and
\* TIPubApplied (same in take_inner's internal publish).
NoWriteWhileRead ==
    wPC \in {"PubApplied","TIPubApplied"} => ReadersOnCopy(writerCopy) = {}

\* F1 — HEADLINE: a copy is dropped only if no reader currently aliases
\* it.  Violation = use-after-free.  Fires at TIDropFirst/TIDropSecond.
NoDropWhileRead ==
    \A c \in {"L","R"} :
        ~copyAlive[c] => ReadersOnCopy(c) = {}

\* F1 — soundness of the wait skip rule.  At the moment WriterWait
\* succeeds (transitions out of *Locked into *Waited), every reader
\* still on writerCopy must have lastEpochs[r] odd AND epoch[r] !=
\* lastEpochs[r] — i.e., the skip rule did NOT mistakenly skip them.
\* For the normal publish path the skip is sound.  For the take_inner
\* path under the buggy build (no PR #144), this can fail.
StaleSnapshotIsCaught ==
    (wPC = "TIWaited") =>
        \A r \in Reader :
            (registered[r] /\ readerHolding[r] = releasedCopy) =>
                \* This reader still holds the about-to-be-released copy.
                \* The skip rule must NOT have classified them as quiesced
                \* with stale data, i.e., lastEpochs[r] must be odd.
                lastEpochs[r] % 2 = 1

\* F2 — read.rs:146 unreachable!() never fires.
NoUnreachablePanic ==
    \A r \in Reader : ~panicked[r]

\* F4 — per-reader snapshot consistency: once a reader r has been
\* snapped in the current loop, lastEpochs[r] is at least the epoch they
\* had at snap time.  This holds by construction (each WriterPub*SnapReader
\* assigns lastEpochs[r] := epoch[r] atomically); the invariant checks
\* there's no PC state where the assignment was skipped.
\* Stated as: no reader is "removed from snapPending" without an
\* accompanying lastEpochs update.  We approximate via "if snap loop has
\* finished, every registered reader has lastEpochs[r] = a value the
\* snap loop could have read".
PerReaderSnapshotConsistency ==
    \* A registered reader that is NOT in snapPending while we are inside
    \* a snap loop must have lastEpochs[r] in the legal range (some
    \* value ≤ epoch[r] read during this loop).  We use the weaker but
    \* checkable invariant: lastEpochs[r] ≤ epoch[r] (epoch is monotonic
    \* per reader within a loop iteration since the loop holds the mutex
    \* and readers only INCREMENT epoch).
    \A r \in Reader :
        (registered[r] /\ wPC \in {"PubSnapping","TIPubSnapping"}
            /\ r \notin snapPending) =>
            lastEpochs[r] \in 0..epoch[r]

====
