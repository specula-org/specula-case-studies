---- MODULE base ----
(***************************************************************************)
(* TLA+ specification of crossbeam-deque — Chase-Lev work-stealing deque  *)
(* with FIFO/LIFO pop modes and batch steal.                              *)
(*                                                                        *)
(* Source: crossbeam-deque/src/deque.rs                                    *)
(*                                                                        *)
(* Bug Families:                                                          *)
(*   F1 — Steal-Resize Buffer Race (CVE-2021-32810, missing re-check)     *)
(*   F3 — Epoch-Deque Lifecycle Coupling (premature buffer reclamation)   *)
(*   F4 — FIFO Pop Rollback Atomicity (transient front over-advance)     *)
(***************************************************************************)

EXTENDS Integers, Sequences, FiniteSets, TLC

\* ========================================================================
\* Constants
\* ========================================================================

CONSTANTS
    Stealer,        \* Set of stealer thread IDs
    MaxVal,         \* Maximum number of values to push (bounds state space)
    BufferCap,      \* Buffer capacity (power of 2; deque.rs:18)
    MaxBatch,       \* Maximum batch steal size (deque.rs:20)
    MaxResize       \* Maximum number of resizes (bounds buffer ID growth)

Worker == "worker"
Thread == Stealer \cup {Worker}
Val == 1..MaxVal
NullVal == 0

ASSUME BufferCap >= 2
ASSUME MaxBatch >= 1
ASSUME MaxVal >= 1
ASSUME MaxResize >= 0

\* ========================================================================
\* Variables
\* ========================================================================

\* --- Core deque state (deque.rs:114-123) ---
VARIABLES
    front,          \* Front index (AtomicIsize, deque.rs:116)
    back,           \* Back index (AtomicIsize, deque.rs:119)
    bufferID        \* Current buffer identity (Nat), incremented on resize (F1)

\* --- Per-buffer contents (F1, F3: stale/freed buffer reads) ---
\* bufContent[id] = [1..BufferCap -> Val \cup {NullVal}]
\* Old buffers frozen after resize; freed buffers return garbage.
VARIABLES
    bufContent

\* --- Per-stealer state ---
VARIABLES
    sPC,            \* sPC[s] \in {"Idle", "ReadTask", "PreCAS"}
    sCachedFront,   \* Front value read at start of steal
    sCachedBuf,     \* Buffer ID captured at start of steal (F1)
    sReadVal,       \* Value speculatively read from buffer
    sStolenCount,   \* Items to steal (1=single, >1=batch)
    sStealSite      \* Which CAS site: "single", "batchFIFO", "batchLIFOFirst"

\* --- Worker state ---
VARIABLES
    wPC,            \* "Idle" or "FIFORollback"
    nextPush,       \* Next value to push (monotonic)
    flavor          \* "FIFO" or "LIFO" (set at init, deque.rs:148-155)

\* --- Epoch / buffer lifecycle (F3) ---
VARIABLES
    pinned,         \* pinned[s] \in BOOLEAN: stealer has epoch guard
    retired,        \* Set of buffer IDs deferred for reclamation
    freed           \* Set of buffer IDs actually deallocated

\* --- Fault injection ---
VARIABLES
    skipRecheck,    \* [site -> BOOLEAN]: omit buffer re-check (F1)
    prematureReclaim \* BOOLEAN: reclaim pinned buffers (F3)

\* --- History tracking ---
VARIABLES
    pushed,         \* Sequence of all pushed values (in push order)
    consumed,       \* Set of consumed values
    consumeCount    \* Number of consume operations (for double-pop detection)

\* Variable groups for UNCHANGED
coreVars     == <<front, back, bufferID>>
bufVars      == <<bufContent>>
stealerVars  == <<sPC, sCachedFront, sCachedBuf, sReadVal, sStolenCount, sStealSite>>
workerVars   == <<wPC, nextPush, flavor>>
epochVars    == <<pinned, retired, freed>>
faultVars    == <<skipRecheck, prematureReclaim>>
historyVars  == <<pushed, consumed, consumeCount>>

vars == <<coreVars, bufVars, stealerVars, workerVars, epochVars,
          faultVars, historyVars>>

\* ========================================================================
\* Helpers
\* ========================================================================

\* Circular buffer slot index: position mod capacity, 1-based (deque.rs:69)
SlotIdx(pos) == (pos % BufferCap) + 1

\* Read from a buffer by ID
ReadBuf(id, pos) ==
    IF id \in DOMAIN bufContent /\ id \notin freed
    THEN bufContent[id][SlotIdx(pos)]
    ELSE NullVal    \* F3: freed buffer returns garbage

\* Read from current buffer
ReadCurrent(pos) == ReadBuf(bufferID, pos)

\* Write to a buffer by ID
WriteBuf(id, pos, val) ==
    [bufContent EXCEPT ![id][SlotIdx(pos)] = val]

\* Empty buffer
EmptyBuf == [i \in 1..BufferCap |-> NullVal]

\* Queue length
QLen == back - front

\* Consume a value: add to consumed set and increment counter
Consume(val) ==
    /\ consumed' = consumed \cup {val}
    /\ consumeCount' = consumeCount + 1

\* Consume a set of values
ConsumeSet(vals) ==
    /\ consumed' = consumed \cup vals
    /\ consumeCount' = consumeCount + Cardinality(vals)

\* ========================================================================
\* Init
\* ========================================================================

Init ==
    \* Core deque (deque.rs:226-240)
    /\ front = 0
    /\ back = 0
    /\ bufferID = 1
    /\ bufContent = (1 :> EmptyBuf)
    \* Stealers idle
    /\ sPC = [s \in Stealer |-> "Idle"]
    /\ sCachedFront = [s \in Stealer |-> 0]
    /\ sCachedBuf = [s \in Stealer |-> 0]
    /\ sReadVal = [s \in Stealer |-> NullVal]
    /\ sStolenCount = [s \in Stealer |-> 0]
    /\ sStealSite = [s \in Stealer |-> "single"]
    \* Worker
    /\ wPC = "Idle"
    /\ nextPush = 1
    /\ flavor \in {"FIFO", "LIFO"}
    \* Epoch (F3)
    /\ pinned = [s \in Stealer |-> FALSE]
    /\ retired = {}
    /\ freed = {}
    \* Fault injection:
    \* skipRecheck: TRUE = re-check is skipped at this CAS site
    \*   "single" / "batchFIFO": FALSE = re-check active (matches code)
    \*   "batchLIFOFirst": TRUE = re-check absent (matches code, MC-1 finding)
    /\ skipRecheck = [site \in {"single", "batchFIFO"} |-> FALSE]
                     @@ ("batchLIFOFirst" :> TRUE)
    /\ prematureReclaim = FALSE
    \* History
    /\ pushed = <<>>
    /\ consumed = {}
    /\ consumeCount = 0

\* ========================================================================
\* Worker Actions
\* ========================================================================

\* ------------------------------------------------------------------------
\* Push (deque.rs:399-433)
\* Worker pushes a new task onto the back of the deque.
\* ------------------------------------------------------------------------
Push ==
    /\ wPC = "Idle"
    /\ nextPush <= MaxVal
    /\ QLen < BufferCap                          \* deque.rs:409
    /\ LET b == back
           val == nextPush
       IN
       /\ bufContent' = WriteBuf(bufferID, b, val) \* deque.rs:418-419
       /\ back' = b + 1                           \* deque.rs:432
       /\ nextPush' = nextPush + 1
       /\ pushed' = Append(pushed, val)
    /\ UNCHANGED <<front, bufferID, stealerVars, wPC, flavor,
                   epochVars, faultVars, consumed, consumeCount>>

\* ------------------------------------------------------------------------
\* ResizeGrow (deque.rs:291-322)
\* Worker doubles buffer. Copies elements, swaps pointer, retires old.
\* F1: buffer identity changes → stale pointers diverge after new pushes.
\* F3: old buffer deferred for epoch reclamation.
\* ------------------------------------------------------------------------
ResizeGrow ==
    /\ wPC = "Idle"
    /\ QLen > 0
    /\ bufferID - 1 < MaxResize     \* Bound number of resizes
    /\ LET oldBuf == bufferID
           newBuf == bufferID + 1
           b == back
           f == front
           \* deque.rs:298-303: copy data from old to new buffer
           copiedContent == [i \in 1..BufferCap |->
               IF \E pos \in f..(b-1) : SlotIdx(pos) = i
               THEN bufContent[oldBuf][i]
               ELSE NullVal]
       IN
       /\ bufferID' = newBuf                      \* deque.rs:308,311-312
       /\ bufContent' = (newBuf :> copiedContent) @@ bufContent
       /\ retired' = retired \cup {oldBuf}         \* deque.rs:315
    /\ UNCHANGED <<front, back, stealerVars, workerVars,
                   pinned, freed, faultVars, historyVars>>

\* ------------------------------------------------------------------------
\* LIFOPop (deque.rs:490-544)
\* Worker pops from the back. Classic Chase-Lev three-case pop.
\* ------------------------------------------------------------------------
LIFOPop ==
    /\ wPC = "Idle"
    /\ flavor = "LIFO"
    /\ QLen > 0
    /\ LET b == back - 1                          \* deque.rs:492
           f == front                              \* deque.rs:498
           len == b - f
       IN
       IF len < 0 THEN
         \* deque.rs:503-506: empty after decrement, restore back
         /\ back' = b + 1
         /\ UNCHANGED <<front, bufContent, consumed, consumeCount>>
       ELSE IF len = 0 THEN
         \* deque.rs:512-531: last element, CAS contention with stealers
         LET val == ReadCurrent(b) IN
         \* CAS front: f -> f+1 (deque.rs:515-524, SeqCst)
         \/ /\ front' = f + 1                     \* CAS succeeds
            /\ back' = b + 1                       \* deque.rs:531
            /\ Consume(val)
            /\ UNCHANGED bufContent
         \/ /\ back' = b + 1                       \* CAS fails
            /\ UNCHANGED <<front, bufContent, consumed, consumeCount>>
       ELSE
         \* deque.rs:507-510: multiple elements, safe pop
         LET val == ReadCurrent(b) IN
         /\ back' = b
         /\ Consume(val)
         /\ UNCHANGED <<front, bufContent>>
    /\ UNCHANGED <<bufferID, stealerVars, workerVars,
                   epochVars, faultVars, pushed>>

\* ------------------------------------------------------------------------
\* FIFOPopAttempt (deque.rs:465-486, F4)
\* Worker pops from front. fetch_add then conditional rollback.
\* ------------------------------------------------------------------------
FIFOPopAttempt ==
    /\ wPC = "Idle"
    /\ flavor = "FIFO"
    /\ QLen > 0
    /\ LET f == front
           b == back
       IN
       \* deque.rs:467: fetch_add(1, SeqCst)
       /\ front' = f + 1
       /\ IF b - (f + 1) < 0 THEN
            \* deque.rs:470-472: actually empty, need rollback
            /\ wPC' = "FIFORollback"
            /\ UNCHANGED <<bufContent, consumed, consumeCount>>
          ELSE
            \* deque.rs:475-478: read and return
            LET val == ReadCurrent(f) IN
            /\ Consume(val)
            /\ UNCHANGED <<wPC, bufContent>>
    /\ UNCHANGED <<back, bufferID, stealerVars, nextPush, flavor,
                   epochVars, faultVars, pushed>>

\* ------------------------------------------------------------------------
\* FIFOPopRollback (deque.rs:471, F4)
\* Restore front after false over-advance. During the window, stealers
\* see front > back and return Empty (false negative).
\* ------------------------------------------------------------------------
FIFOPopRollback ==
    /\ wPC = "FIFORollback"
    /\ front' = front - 1                         \* deque.rs:471
    /\ wPC' = "Idle"
    /\ UNCHANGED <<back, bufferID, bufVars, stealerVars, nextPush, flavor,
                   epochVars, faultVars, historyVars>>

\* ========================================================================
\* Stealer Actions
\* ========================================================================
\*
\* Split into phases modeling the TOCTOU window (F1):
\*   1. Begin: load front, pin epoch, load back, load buffer pointer
\*   2. ReadTask: speculatively read task from cached buffer
\*   3. Commit: buffer re-check (maybe) + CAS on front
\*
\* Three commit variants correspond to three CAS sites:
\*   - "single":          deque.rs:670-679   (re-check PRESENT)
\*   - "batchFIFO":       deque.rs:816-829   (re-check PRESENT)
\*   - "batchLIFOFirst":  deque.rs:1083-1087 (re-check ABSENT — MC-1)

\* ------------------------------------------------------------------------
\* StealBegin (deque.rs:641-665)
\* Single steal entry: load front, pin, load back, load buffer.
\* ------------------------------------------------------------------------
StealBegin(s) ==
    /\ sPC[s] = "Idle"
    /\ LET f == front                              \* deque.rs:643
           b == back                               \* deque.rs:657
       IN
       IF b - f <= 0 THEN
         \* deque.rs:660-662: empty
         /\ UNCHANGED <<stealerVars, epochVars>>
       ELSE
         /\ sPC' = [sPC EXCEPT ![s] = "ReadTask"]
         /\ sCachedFront' = [sCachedFront EXCEPT ![s] = f]
         /\ sCachedBuf' = [sCachedBuf EXCEPT ![s] = bufferID] \* deque.rs:665
         /\ sStolenCount' = [sStolenCount EXCEPT ![s] = 1]
         /\ sStealSite' = [sStealSite EXCEPT ![s] = "single"]
         /\ pinned' = [pinned EXCEPT ![s] = TRUE]  \* deque.rs:654
         /\ UNCHANGED <<sReadVal, retired, freed>>
    /\ UNCHANGED <<coreVars, bufVars, workerVars, faultVars, historyVars>>

\* ------------------------------------------------------------------------
\* BatchStealBeginFIFO (deque.rs:746-789)
\* FIFO batch steal entry: compute batch_size, all-or-nothing semantics.
\* ------------------------------------------------------------------------
BatchStealBeginFIFO(s) ==
    /\ sPC[s] = "Idle"
    /\ flavor = "FIFO"
    /\ LET f == front                              \* deque.rs:757
           b == back                               \* deque.rs:771
           len == b - f
       IN
       IF len <= 0 THEN
         /\ UNCHANGED <<stealerVars, epochVars>>
       ELSE
         /\ LET half == (len + 1) \div 2           \* deque.rs:780
                bsz == IF half > MaxBatch THEN MaxBatch ELSE half
            IN
            /\ sPC' = [sPC EXCEPT ![s] = "ReadTask"]
            /\ sCachedFront' = [sCachedFront EXCEPT ![s] = f]
            /\ sCachedBuf' = [sCachedBuf EXCEPT ![s] = bufferID]
            /\ sStolenCount' = [sStolenCount EXCEPT ![s] = bsz]
            /\ sStealSite' = [sStealSite EXCEPT ![s] = "batchFIFO"]
            /\ pinned' = [pinned EXCEPT ![s] = TRUE]
            /\ UNCHANGED <<sReadVal, retired, freed>>
    /\ UNCHANGED <<coreVars, bufVars, workerVars, faultVars, historyVars>>

\* ------------------------------------------------------------------------
\* BatchStealBeginLIFO (deque.rs:989-1034)
\* LIFO batch steal entry: first element uses a CAS WITHOUT re-check.
\* MC-1 finding: deque.rs:1083-1087 is the only CAS site missing re-check.
\* ------------------------------------------------------------------------
BatchStealBeginLIFO(s) ==
    /\ sPC[s] = "Idle"
    /\ flavor = "LIFO"
    /\ LET f == front                              \* deque.rs:999
           b == back                               \* deque.rs:1013
           len == b - f
       IN
       IF len <= 0 THEN
         /\ UNCHANGED <<stealerVars, epochVars>>
       ELSE
         \* deque.rs:1022: batch_size = min((len-1)/2, limit-1)
         /\ LET bsz == IF ((len - 1) \div 2) > (MaxBatch - 1)
                        THEN MaxBatch
                        ELSE ((len - 1) \div 2) + 1
            IN
            /\ sPC' = [sPC EXCEPT ![s] = "ReadTask"]
            /\ sCachedFront' = [sCachedFront EXCEPT ![s] = f]
            /\ sCachedBuf' = [sCachedBuf EXCEPT ![s] = bufferID] \* deque.rs:1031
            /\ sStolenCount' = [sStolenCount EXCEPT ![s] = 1]   \* First: steal 1
            /\ sStealSite' = [sStealSite EXCEPT ![s] = "batchLIFOFirst"]
            /\ pinned' = [pinned EXCEPT ![s] = TRUE]
            /\ UNCHANGED <<sReadVal, retired, freed>>
    /\ UNCHANGED <<coreVars, bufVars, workerVars, faultVars, historyVars>>

\* ------------------------------------------------------------------------
\* StealReadTask (deque.rs:666 / 799 / 859 / 1034)
\* Speculatively read task from cached buffer.
\* F1: reads from cached buffer, which may be stale after resize.
\* F3: if cached buffer freed, this is UAF (returns garbage).
\* ------------------------------------------------------------------------
StealReadTask(s) ==
    /\ sPC[s] = "ReadTask"
    /\ LET cachedBuf == sCachedBuf[s]
           f == sCachedFront[s]
       IN
       \* deque.rs:666: buffer.deref().read(f)
       /\ sReadVal' = [sReadVal EXCEPT ![s] = ReadBuf(cachedBuf, f)]
       /\ sPC' = [sPC EXCEPT ![s] = "PreCAS"]
    /\ UNCHANGED <<coreVars, bufVars, sCachedFront, sCachedBuf, sStolenCount,
                   sStealSite, workerVars, epochVars, faultVars, historyVars>>

\* ------------------------------------------------------------------------
\* StealCommit (deque.rs:670-679 / 816-829 / 1083-1091)
\* Generic commit: buffer re-check (unless site skips it) + CAS on front.
\*
\* Re-check behavior per site:
\*   "single"          — re-check present in code (deque.rs:670)
\*   "batchFIFO"       — re-check present in code (deque.rs:816)
\*   "batchLIFOFirst"  — re-check ABSENT in code (deque.rs:1083) ← MC-1
\*
\* skipRecheck overrides: TRUE = skip re-check (reproduce CVE for any site).
\* For "batchLIFOFirst", the code already lacks re-check, so this site
\* naturally skips it unless we model a fix (skipRecheck = FALSE forces
\* the re-check, modeling the hypothetical fix).
\* ------------------------------------------------------------------------
StealCommit(s) ==
    /\ sPC[s] = "PreCAS"
    /\ LET site == sStealSite[s]
           f == sCachedFront[s]
           n == sStolenCount[s]
           cachedBuf == sCachedBuf[s]
           bufChanged == (cachedBuf # bufferID)
           \* Re-check logic:
           \* skipRecheck[site] = TRUE  → re-check skipped (CVE or MC-1)
           \* skipRecheck[site] = FALSE → re-check active (normal or fix)
           \* Default: TRUE for "batchLIFOFirst" (code lacks re-check),
           \*          FALSE for "single"/"batchFIFO" (code has re-check)
           recheckDetects == bufChanged /\ ~skipRecheck[site]
       IN
       IF recheckDetects THEN
         \* Buffer swapped, re-check catches it → retry
         /\ sPC' = [sPC EXCEPT ![s] = "Idle"]
         /\ pinned' = [pinned EXCEPT ![s] = FALSE]
         /\ UNCHANGED <<coreVars, bufVars, sCachedFront, sCachedBuf,
                        sReadVal, sStolenCount, sStealSite, workerVars,
                        retired, freed, faultVars, historyVars>>
       ELSE
         \* CAS front from f to f+n (SeqCst)
         IF front = f THEN
           \* CAS succeeds
           /\ front' = f + n
           \* Consume: for single steal or batchLIFOFirst, just sReadVal
           \* For batchFIFO, consume all n items from the cached buffer
           /\ IF n = 1 THEN
                Consume(sReadVal[s])
              ELSE
                \* Batch: all items from f to f+n-1
                ConsumeSet({ReadBuf(cachedBuf, f + i) : i \in 0..(n-1)})
           /\ sPC' = [sPC EXCEPT ![s] = "Idle"]
           /\ pinned' = [pinned EXCEPT ![s] = FALSE]
           /\ UNCHANGED <<back, bufferID, bufVars, sCachedFront, sCachedBuf,
                          sReadVal, sStolenCount, sStealSite, workerVars,
                          retired, freed, faultVars, pushed>>
         ELSE
           \* CAS fails
           /\ sPC' = [sPC EXCEPT ![s] = "Idle"]
           /\ pinned' = [pinned EXCEPT ![s] = FALSE]
           /\ UNCHANGED <<coreVars, bufVars, sCachedFront, sCachedBuf,
                          sReadVal, sStolenCount, sStealSite, workerVars,
                          retired, freed, faultVars, historyVars>>

\* ========================================================================
\* Epoch Actions (Family 3)
\* ========================================================================

\* ------------------------------------------------------------------------
\* EpochReclaim (deque.rs:315 + crossbeam-epoch)
\* Epoch advances and reclaims retired buffers.
\* Normal: only reclaims when no stealer is pinned.
\* Fault: prematureReclaim allows reclaiming while stealers pinned.
\* ------------------------------------------------------------------------
EpochReclaim ==
    /\ retired # {}
    /\ \E buf \in retired :
         LET anyPinned == \E s \in Stealer : pinned[s] IN
         /\ prematureReclaim \/ ~anyPinned
         /\ freed' = freed \cup {buf}
         /\ retired' = retired \ {buf}
    /\ UNCHANGED <<coreVars, bufVars, stealerVars, workerVars,
                   pinned, faultVars, historyVars>>

\* ========================================================================
\* Next State Relation
\* ========================================================================

WorkerAction ==
    \/ Push
    \/ ResizeGrow
    \/ LIFOPop
    \/ FIFOPopAttempt
    \/ FIFOPopRollback

StealerAction(s) ==
    \/ StealBegin(s)
    \/ BatchStealBeginFIFO(s)
    \/ BatchStealBeginLIFO(s)
    \/ StealReadTask(s)
    \/ StealCommit(s)

Next ==
    \/ WorkerAction
    \/ \E s \in Stealer : StealerAction(s)
    \/ EpochReclaim

Spec == Init /\ [][Next]_vars

\* ========================================================================
\* Invariants
\* ========================================================================

PushedSet == {pushed[i] : i \in 1..Len(pushed)}

\* --- Standard Safety ---

\* Every consumed value was actually pushed
ConsumedWasPushed ==
    consumed \subseteq PushedSet

\* No value consumed more than once.
\* consumed is a set (collapses duplicates), so double-pop is detected
\* when consumeCount exceeds Cardinality(consumed).
NoDoublePop ==
    consumeCount = Cardinality(consumed)

\* --- F1: Steal-Resize Buffer Race ---

\* A successful steal returns a value that was actually pushed
\* (not garbage from stale/freed buffer). Violated when skipRecheck
\* allows commit with a stale buffer read.
StealReturnsValid ==
    \A s \in Stealer :
        (sPC[s] = "PreCAS" /\ sCachedBuf[s] = bufferID) =>
            sReadVal[s] \in PushedSet \/ sReadVal[s] = NullVal

\* --- F3: Epoch Lifecycle ---

\* No stealer reads from a freed buffer (UAF)
NoUseAfterFree ==
    \A s \in Stealer :
        sPC[s] \in {"ReadTask", "PreCAS"} =>
            sCachedBuf[s] \notin freed

\* --- F4: FIFO Rollback ---

\* When not in rollback, deque is consistent: front <= back
DequeConsistency ==
    wPC # "FIFORollback" => front <= back

\* --- Structural ---

\* Pushed values are all distinct
PushedDistinct ==
    \A i, j \in 1..Len(pushed) : i # j => pushed[i] # pushed[j]

\* nextPush tracks push count
PushCountConsistency ==
    nextPush = Len(pushed) + 1

\* Current buffer is never freed
CurrentBufferAlive ==
    bufferID \notin freed

\* No element loss: every pushed value is either consumed or still in deque
NoElementLoss ==
    wPC = "Idle" =>
    \A i \in 1..Len(pushed) :
        LET v == pushed[i] IN
        v \in consumed \/
        \E pos \in front..(back - 1) : ReadCurrent(pos) = v

====
