---- MODULE Trace ----
(***************************************************************************)
(* Trace Validation Spec for flurry ConcurrentHashMap                      *)
(*                                                                         *)
(* Category B (concurrent/lock-free): Uses per-thread timebox traces       *)
(* with ViablePIDs partial ordering.                                       *)
(*                                                                         *)
(* Replays implementation traces against the base spec to verify that      *)
(* recorded state transitions are consistent with the specification.       *)
(***************************************************************************)

EXTENDS base, TLCExt, IOUtils, Json, Sequences, Naturals, FiniteSets

\* ========================================================================
\* Trace Loading
\* ========================================================================

\* Trace file location (override via IOEnv.JSON for per-run selection)
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.json"

\* Load preprocessed JSON: { "t1": [...], "t2": [...], ... }
\* Each entry: { "event": "...", "start": N, "end": N, "state": {...}, ... }
RawTraceData == JsonDeserialize(JsonFile)

\* Per-thread trace arrays
traces == [t \in Thread |->
    IF t \in DOMAIN RawTraceData THEN RawTraceData[t]
    ELSE <<>>]

\* ========================================================================
\* Trace Cursor (Per-Thread)
\* ========================================================================

VARIABLES pc   \* Per-thread cursor: [Thread -> Nat]

traceVars == <<pc>>
allVars == <<vars, pc>>

\* ========================================================================
\* Timebox Helpers
\* ========================================================================

\* Threads that still have unconsumed events
ThreadsWithEvents ==
    {tid \in Thread : pc[tid] <= Len(traces[tid])}

\* Viable PIDs: partial order constraint
\* Thread A must go before B if A's pending event ENDED before B's next event STARTED
ViablePIDs ==
    {tid \in ThreadsWithEvents :
        ~\E tid2 \in ThreadsWithEvents :
            /\ tid2 /= tid
            /\ traces[tid2][pc[tid2]].end < traces[tid][pc[tid]].start}

\* Current logline for a thread
Logline(tid) == traces[tid][pc[tid]]

\* Advance a single thread's cursor
AdvancePC(tid) == pc' = [pc EXCEPT ![tid] = pc[tid] + 1]

\* ========================================================================
\* Post-State Validation
\* ========================================================================

\* Strong validation: check bin state and count
ValidatePostState(tid) ==
    LET ll == Logline(tid) IN
    /\ "state" \in DOMAIN ll =>
        /\ "count" \in DOMAIN ll.state => count' = ll.state.count

\* Weak validation: only check thread state
ValidatePostStateWeak(tid) ==
    TRUE  \* Accept any post-state (for actions with limited observability)

\* ========================================================================
\* Event Matching
\* ========================================================================

\* Map implementation event names to spec actions
MatchEvent(tid, logline) ==
    LET event == logline.event IN

    \* --- Put events (map.rs) ---
    \* Use real keys from trace: preserves hash-based bin assignment across table sizes
    \* (abstract keys 0..MaxKey-1 don't preserve k%8 vs k%16 split behavior)
    \/ /\ event = "put_empty_bin"
       /\ "key" \in DOMAIN logline
       /\ PutEmptyBin(tid, logline.key)
       /\ ValidatePostState(tid)

    \/ /\ event = "put_node_bin"
       /\ "key" \in DOMAIN logline
       /\ PutNodeBin(tid, logline.key)
       /\ ValidatePostState(tid)

    \/ /\ event = "put_tree_bin"
       /\ "key" \in DOMAIN logline
       /\ PutTreeBin(tid, logline.key)
       /\ ValidatePostStateWeak(tid)

    \/ /\ event = "put_help_transfer"
       /\ "key" \in DOMAIN logline
       /\ PutHelpTransfer(tid, logline.key)
       /\ ValidatePostStateWeak(tid)

    \* --- Treeify events (Family 4) ---
    \/ /\ event = "treeify_bin"
       /\ TreeifyBin(tid)
       /\ ValidatePostStateWeak(tid)

    \* --- Resize events (Family 1) ---
    \* init_resize: inline InitResize with count sync.
    \* Wide-timebox puts may have incremented count (via atomic add_count)
    \* before init_resize checked count >= sizeCtl, but their trace events
    \* are emitted later. Sync count from the trace's observed state.
    \/ /\ event = "init_resize"
       /\ "state" \in DOMAIN logline
       /\ "count" \in DOMAIN logline.state
       /\ LET traceCount == logline.state.count
              rs == ResizeStamp(tableSize)
          IN
          /\ activeGuards[tid] = TRUE
          /\ threadPC[tid] = "idle"
          /\ ~IsResizing
          /\ traceCount >= sizeCtl              \* Use trace's observed count
          /\ sizeCtl >= 0
          /\ tableSize * 2 <= MaxBinIdx + 1
          /\ sizeCtl' = -(rs + 2)
          /\ nextTableSize' = tableSize * 2
          /\ transferIndex' = tableSize
          /\ table' = [b \in 0..MaxBinIdx |->
                      IF b < tableSize THEN table[b]
                      ELSE [type |-> BinEmpty, keys |-> {}, locked |-> "null"]]
          /\ binTransferred' = [b \in 0..MaxBinIdx |-> FALSE]
          /\ threadState' = [threadState EXCEPT ![tid] = Transferring]
          /\ threadPC' = [threadPC EXCEPT ![tid] = "transfer_claim"]
          /\ threadI' = [threadI EXCEPT ![tid] = tableSize]
          /\ threadBound' = [threadBound EXCEPT ![tid] = 0]
          /\ count' = traceCount                \* Sync count from trace
          /\ UNCHANGED <<tableSize, reclaimVars, treeLockVars, treeifyVars>>

    \/ /\ event = "claim_range"
       /\ "bound" \in DOMAIN logline
       \* Override base spec's stride: use trace's bound directly
       /\ threadState[tid] = Transferring
       /\ threadPC[tid] = "transfer_claim"
       /\ IsResizing
       /\ transferIndex > 0
       /\ LET nextBound == logline.bound
              nextIndex == transferIndex
          IN
          /\ transferIndex' = nextBound
          /\ threadBound' = [threadBound EXCEPT ![tid] = nextBound]
          /\ threadI' = [threadI EXCEPT ![tid] = nextIndex]
          /\ threadPC' = [threadPC EXCEPT ![tid] =
                  IF nextIndex >= tableSize THEN "transfer_finish_check"
                  ELSE "transfer_bin"]
          /\ UNCHANGED <<table, tableSize, nextTableSize, sizeCtl, count,
                         threadState, resizeVars, reclaimVars, treeLockVars, treeifyVars>>
       /\ ValidatePostStateWeak(tid)

    \/ /\ event = "claim_range_exhausted"
       /\ ClaimRangeExhausted(tid)
       /\ ValidatePostStateWeak(tid)

    \/ /\ event = "transfer_bin"
       /\ TransferBin(tid)
       /\ ValidatePostStateWeak(tid)

    \/ /\ event = "transfer_finish_check"
       /\ TransferFinishCheck(tid)
       /\ ValidatePostStateWeak(tid)

    \/ /\ event = "finishing_sweep"
       /\ FinishingSweep(tid)
       /\ ValidatePostStateWeak(tid)

    \/ /\ event = "complete_resize"
       /\ CompleteResize(tid)
       /\ ValidatePostState(tid)

    \/ /\ event = "help_transfer"
       /\ HelpTransfer(tid)
       /\ ValidatePostStateWeak(tid)

    \* --- Guard events (Family 2) ---
    \/ /\ event = "enter_guard"
       /\ EnterGuard(tid)
       /\ ValidatePostStateWeak(tid)

    \/ /\ event = "exit_guard"
       /\ ExitGuard(tid)
       /\ ValidatePostStateWeak(tid)

    \* --- TreeBin lock events (Family 3) ---
    \/ /\ event = "reader_acquire"
       /\ "bin" \in DOMAIN logline
       /\ ReaderAcquire(tid, logline.bin)
       /\ ValidatePostStateWeak(tid)

    \/ /\ event = "reader_release"
       /\ "bin" \in DOMAIN logline
       /\ ReaderRelease(tid, logline.bin)
       /\ ValidatePostStateWeak(tid)

    \/ /\ event = "writer_acquire_fast"
       /\ "bin" \in DOMAIN logline
       /\ WriterAcquireFast(tid, logline.bin)
       /\ ValidatePostStateWeak(tid)

    \/ /\ event = "writer_set_waiter"
       /\ "bin" \in DOMAIN logline
       /\ WriterSetWaiter(tid, logline.bin)
       /\ ValidatePostStateWeak(tid)

    \/ /\ event = "writer_acquire_contended"
       /\ "bin" \in DOMAIN logline
       /\ WriterAcquireContended(tid, logline.bin)
       /\ ValidatePostStateWeak(tid)

    \/ /\ event = "writer_release"
       /\ "bin" \in DOMAIN logline
       /\ WriterRelease(tid, logline.bin)
       /\ ValidatePostStateWeak(tid)

\* ========================================================================
\* Silent Actions
\* ========================================================================

\* Silent guard entry: thread may enter guard before any traced event
\* Only for threads whose next event is NOT enter_guard (those have explicit events)
SilentEnterGuard ==
    /\ ThreadsWithEvents /= {}
    /\ \E t \in Thread :
        /\ activeGuards[t] = FALSE
        /\ IF t \in ThreadsWithEvents
           THEN Logline(t).event /= "enter_guard"
           ELSE TRUE
        /\ EnterGuard(t)
    /\ UNCHANGED pc

\* Silent epoch advance: GC may advance between events
SilentAdvanceEpoch ==
    /\ ThreadsWithEvents /= {}
    /\ retired /= {}                                \* Only if something to free
    /\ AdvanceEpoch
    /\ UNCHANGED pc

\* Silent treeify skip: when table is too small, treeify becomes try_presize
\* The trace won't have a treeify_bin event, so clear pendingTreeify silently.
\* Only fire when the thread's next event is NOT treeify_bin (preserve it for explicit match).
SilentTreeifySkip ==
    /\ \E t \in Thread :
        /\ pendingTreeify[t] >= 0
        /\ IF t \in ThreadsWithEvents
           THEN Logline(t).event /= "treeify_bin"
           ELSE TRUE
        /\ TreeifyBin(t)  \* Base spec handles the skip-path when tableSize < MIN_TREEIFY_CAPACITY
    /\ UNCHANGED pc

\* Silent help transfer bail: thread at help_transfer PC but can't join (resize done, etc.)
SilentHelpTransferBail ==
    /\ ThreadsWithEvents /= {}
    /\ \E t \in Thread :
        /\ HelpTransferBail(t)
    /\ UNCHANGED pc

\* All silent actions (tightly constrained)
SilentActions ==
    \/ SilentEnterGuard
    \/ SilentAdvanceEpoch
    \/ SilentTreeifySkip
    \/ SilentHelpTransferBail

\* ========================================================================
\* Trace Init and Next
\* ========================================================================

TraceInit ==
    /\ Init
    /\ pc = [t \in Thread |-> 1]

TraceNext ==
    \* Normal: match a trace event from a viable thread
    \/ /\ ThreadsWithEvents /= {}
       /\ \E tid \in ViablePIDs :
            LET logline == Logline(tid) IN
            /\ MatchEvent(tid, logline)
            /\ AdvancePC(tid)
    \* Silent: fire spec actions without consuming events
    \/ /\ ThreadsWithEvents /= {}
       /\ SilentActions
       /\ UNCHANGED pc
    \* Stuttering: all events consumed
    \/ /\ ThreadsWithEvents = {}
       /\ UNCHANGED allVars

TraceSpec == TraceInit /\ [][TraceNext]_allVars

\* ========================================================================
\* Completion Property
\* ========================================================================

\* Temporal: all trace events were successfully consumed
TraceFullyConsumed == <>(ThreadsWithEvents = {})

\* ========================================================================
\* Invariants for Trace Validation
\* ========================================================================

\* Include safety and structural invariants (not fault-injection ones)
\* ResizeCoordination, BinTypeConsistency, CountNonNeg
\* EmptyBinNoKeys, MovedBinNoKeys, LockStateNonNeg
\* ReaderWriterMutex (should hold on every real execution)

====
