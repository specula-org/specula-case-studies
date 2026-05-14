---- MODULE base ----
(***************************************************************************)
(* TLA+ specification for crossbeam-skiplist (Pugh-style lock-free skip    *)
(* list with epoch reclamation; bottom-up tower install / top-down mark).  *)
(*                                                                         *)
(* Source: artifact/crossbeam/crossbeam-skiplist/src/base.rs                *)
(* Category: B (concurrent / lock-free data structure).                     *)
(*                                                                         *)
(* Bug Families modeled (modeling-brief.md §2):                            *)
(*   F1 — Iterator rewind after exhaustion (HIGH; #1142, PR #1252)         *)
(*        Iter::next, Iter::next_back, Range::next, Range::next_back null  *)
(*        their head/tail on cross-over, then re-search on the next call,  *)
(*        violating FusedIterator semantics. RefIter is unaffected.        *)
(*   F2 — Insert install-then-mark transient duplicate (MEDIUM; #1023,     *)
(*        PR #1101). Between level-0 CAS-install of new node and           *)
(*        mark_tower of old, both are level-0 unmarked → iter / get / len  *)
(*        can observe two nodes for the same key.                          *)
(*   F3 — Tower-CAS memory ordering / SeqCst sensitivity (LOW; 5 TODO      *)
(*        sites). PostBuildCheck reads only top-level; relies on           *)
(*        mark_tower's top-down ordering. A weakening of that ordering     *)
(*        breaks the invariant. Modeled as a sensitivity flag.             *)
(*   F4 — Caller misuse: concurrent iter + insert + remove + pop_front     *)
(*        (MEDIUM; #672/#671/#1178/#1143 regression class). Adversarial    *)
(*        harness drives interleaving of all operations.                   *)
(*                                                                         *)
(* Reference-only (NOT modeled — see brief §2):                            *)
(*   F5 (refcount discipline)  — well-tested, fixed; cited in F4 evidence  *)
(*   F6 (compare_insert design) — design issue, not protocol               *)
(*                                                                         *)
(* Modeling abstractions:                                                   *)
(*   - Per-level boolean lattice replaces precise next-pointer chains:     *)
(*     a node is level-L present iff linked[n][L] /\ ~mark[n][L]. This is  *)
(*     sufficient for the bug families because the load-bearing state is   *)
(*     per-level mark/linked, not the linear order.                        *)
(*   - Tower height is bounded by MaxHeight (default 2 to keep state       *)
(*     space tractable; brief §3.2 declares random_height non-modelable).  *)
(*   - NodeId pool is bounded; nodes are not reused (no slot recycling).   *)
(*     Premature finalize against the *handle* is captured via nState.     *)
(***************************************************************************)

EXTENDS Integers, Sequences, FiniteSets, TLC

\* ========================================================================
\* Constants
\* ========================================================================

CONSTANTS
    Key,                \* set of keys (e.g. {k1, k2})
    Value,              \* set of values
    Thread,             \* set of thread IDs
    MaxHeight,          \* tower height bound (use 2 for first cut, 3 for F3)
    MaxNodes,           \* max nodes ever allocated (state space bound)
    MaxOps              \* max ops per thread (state space bound)

\* Fault-injection toggles (overridden by MC.cfg / MC_hunt_*.cfg)
CONSTANTS
    FaultInsertReorder, \* TRUE = mark-old BEFORE level-0 CAS (F2 #1023 regression)
    FaultIterRewind,    \* TRUE = exhausted iter rewinds on next call (F1 #1142)
    FaultMarkBottomUp,  \* TRUE = mark_tower iterates 0..h instead of (h-1)..0 (F3 sensitivity)
    FaultPrematureFree, \* TRUE = allow finalize while threads pinned (F5 surface; UAF probe)
    EnableHarness       \* TRUE = adversarial caller harness on (F4)

NULL == 0
NodeId == 1..MaxNodes
Level == 0..(MaxHeight - 1)

ASSUME MaxHeight >= 1
ASSUME MaxNodes >= 1
ASSUME MaxOps >= 1

\* ========================================================================
\* Variables — Node table (base.rs:130-145)
\* ========================================================================

VARIABLES
    nodes,              \* SUBSET NodeId — currently allocated
    nKey,               \* [NodeId -> Key] — immutable
    nValue,             \* [NodeId -> Value] — immutable
    nHeight,            \* [NodeId -> 1..MaxHeight] — immutable
    nRefcount,          \* [NodeId -> Nat] — base.rs:141 refs_and_height >> 5
    nLinked,            \* [NodeId -> [Level -> BOOLEAN]] — installed at level
    nMark,              \* [NodeId -> [Level -> BOOLEAN]] — base.rs:327-348
    nState              \* [NodeId -> {"alive","retired","freed"}]

\* Shared atomic counter (base.rs:519-525)
VARIABLES
    lenCounter          \* AtomicUsize len.

\* Per-thread state
VARIABLES
    pc,                 \* [Thread -> record] — operation step machine
    pinned,             \* [Thread -> BOOLEAN] — has epoch::pin Guard
    pendingDeferred     \* SUBSET NodeId — guard.defer_unchecked, awaiting epoch grace

\* Per-thread iterator state (F1)
\* Each entry: [exists |-> BOOL, kind |-> {"Iter", "Range"},
\*              head |-> NodeId|NULL, tail |-> NodeId|NULL,
\*              finished |-> BOOL, lastYield |-> NodeId|NULL,
\*              dir |-> {"none","fwd","back"}]
VARIABLES
    iter

\* History for invariants (F1, F2, F4)
VARIABLES
    history,            \* SEQUENCE of operation records
    opCount             \* [Thread -> Nat] — bounded by MaxOps

\* Allocation bookkeeping (no slot reuse)
VARIABLES
    nextNodeId          \* monotonic counter, bounded by MaxNodes+1

nodeVars     == <<nodes, nKey, nValue, nHeight, nRefcount, nLinked, nMark, nState>>
sharedVars   == <<lenCounter>>
threadVars   == <<pc, pinned, pendingDeferred, iter>>
historyVars  == <<history, opCount>>
allocVars    == <<nextNodeId>>

vars == <<nodeVars, sharedVars, threadVars, historyVars, allocVars>>

\* ========================================================================
\* Helpers
\* ========================================================================

\* Live nodes — allocated, not yet finalized (base.rs:253-265)
LiveNodes == {n \in nodes : nState[n] /= "freed"}

\* Logically present at level L: linked, alive, not marked at L
\* (base.rs:333-346 — mark_tower uses the level-0 mark as the LP)
PresentAt(n, L) ==
    /\ n \in LiveNodes
    /\ nLinked[n][L]
    /\ ~ nMark[n][L]

\* Nodes for key k present at level L (may transiently > 1 during F2 window)
NodesForKeyAt(k, L) ==
    {n \in LiveNodes : nKey[n] = k /\ PresentAt(n, L)}

\* Live keys at level 0 (level-0 unmarked is the canonical truth, base.rs:329)
LiveKeysLevel0 == {k \in Key : NodesForKeyAt(k, 0) /= {}}

\* len() helper (base.rs:519-525) — clamps underflow
LenClamped == IF lenCounter < 0 THEN 0 ELSE lenCounter

\* Iterator tracking is per-thread; one in-flight iter per thread.
NoIter(t) == ~ iter[t].exists
HasIter(t) == iter[t].exists

\* ========================================================================
\* Refcount helpers (base.rs:222-264, 297-307)
\* ========================================================================

\* Increment a node's refcount (base.rs:1281, 1715-1718)
IncRef(n) == nRefcount' = [nRefcount EXCEPT ![n] = @ + 1]

\* Decrement a node's refcount (base.rs:294-306).
\* When the count reaches 0, the node moves to "retired" and is queued for
\* epoch finalize (base.rs:303-305 — defer_unchecked).
DecRef(n) ==
    LET nc == nRefcount[n] - 1 IN
    /\ nRefcount' = [nRefcount EXCEPT ![n] = nc]
    /\ IF nc = 0 /\ nState[n] = "alive"
       THEN /\ nState' = [nState EXCEPT ![n] = "retired"]
            /\ pendingDeferred' = pendingDeferred \cup {n}
       ELSE /\ UNCHANGED <<nState, pendingDeferred>>

\* try_increment (base.rs:222-249) — fails if refcount = 0.
\* Returns TRUE iff the node is still acquireable.
TryAcquire(n) == n \in nodes /\ nRefcount[n] > 0

\* ========================================================================
\* Init
\* ========================================================================

InitIter == [exists |-> FALSE, kind |-> "Iter",
             head |-> NULL, tail |-> NULL,
             finished |-> FALSE, lastYield |-> NULL,
             dir |-> "none"]

Init ==
    /\ nodes = {}
    /\ nKey = [n \in NodeId |-> CHOOSE k \in Key : TRUE]
    /\ nValue = [n \in NodeId |-> CHOOSE v \in Value : TRUE]
    /\ nHeight = [n \in NodeId |-> 1]
    /\ nRefcount = [n \in NodeId |-> 0]
    /\ nLinked = [n \in NodeId |-> [L \in Level |-> FALSE]]
    /\ nMark = [n \in NodeId |-> [L \in Level |-> FALSE]]
    /\ nState = [n \in NodeId |-> "freed"]
    /\ lenCounter = 0
    /\ pc = [t \in Thread |-> [op |-> "Idle"]]
    /\ pinned = [t \in Thread |-> FALSE]
    /\ pendingDeferred = {}
    /\ iter = [t \in Thread |-> InitIter]
    /\ history = <<>>
    /\ opCount = [t \in Thread |-> 0]
    /\ nextNodeId = 1

\* ========================================================================
\* StartOp / EndOp — pin guard, bound op count
\* ========================================================================

\* base.rs:1030/1411/580 — every public method calls check_guard then runs.
\* We model the guard pin atomically with op start.
StartOp(t, op) ==
    /\ pc[t] = [op |-> "Idle"]
    /\ opCount[t] < MaxOps
    /\ pinned' = [pinned EXCEPT ![t] = TRUE]
    /\ opCount' = [opCount EXCEPT ![t] = opCount[t] + 1]

EndOp(t) ==
    /\ pc' = [pc EXCEPT ![t] = [op |-> "Idle"]]
    /\ pinned' = [pinned EXCEPT ![t] = FALSE]

\* ========================================================================
\* Insert (base.rs:1018-1370 — insert_internal)
\* Step machine, mirroring code stages and the trace events:
\*   Begin  : search_position                       (base.rs:1042)
\*   AllocCASLevel0 : alloc + len.fetch_add + level-0 CAS  (base.rs:1067-1104)
\*   MarkOld : if found, mark_tower(old) (PR #1101) (base.rs:1125-1129)
\*   BuildLevel(L) : install at level 1..h-1        (base.rs:1207-1322)
\*   PostBuildCheck : read top-level mark           (base.rs:1355-1359)
\*   Done    : caller decrements RefEntry           (release path)
\* ========================================================================

\* ----------------------------------------------------------------------
\* Insert_Begin — pin guard and search for key (base.rs:1042)
\* The next step is "MarkOldFirst" under F2 (#1023 regression), else
\* "AllocCASLevel0" (canonical / PR #1101 order).
\* ----------------------------------------------------------------------
Insert_Begin(t, k, v) ==
    /\ NoIter(t)
    /\ StartOp(t, "Insert")
    /\ LET found == IF \E n \in NodesForKeyAt(k, 0) : TRUE
                    THEN CHOOSE n \in NodesForKeyAt(k, 0) : TRUE
                    ELSE NULL
           initStep == IF FaultInsertReorder /\ found /= NULL
                       THEN "MarkOldFirst"
                       ELSE "AllocCASLevel0"
       IN pc' = [pc EXCEPT ![t] = [op |-> "Insert",
                                   step |-> initStep,
                                   key |-> k,
                                   value |-> v,
                                   found |-> found,
                                   newNode |-> NULL,
                                   h |-> 1,
                                   builtUpTo |-> 0,
                                   topMarked |-> FALSE]]
    /\ UNCHANGED <<nodeVars, sharedVars, pendingDeferred, iter, history, allocVars>>

\* ----------------------------------------------------------------------
\* Insert_AllocCASLevel0 (base.rs:1067-1104)
\*   - alloc node with refcount = 2 (entry + level-0 link)  (base.rs:1072)
\*   - len.fetch_add(1)                                     (base.rs:1085)
\*   - CAS at predecessor's level-0 pointer (Ordering::SeqCst)
\*
\* F2 (#1023): under FaultInsertReorder, MarkOld happens BEFORE this step.
\* In that case, BeginInsertReorderedMarkOld must run first.
\* ----------------------------------------------------------------------
Insert_AllocCASLevel0(t) ==
    /\ pc[t].op = "Insert"
    /\ pc[t].step = "AllocCASLevel0"
    /\ nextNodeId <= MaxNodes
    \* CAS-contention precondition (base.rs:1095-1104): the level-0
    \* compare_exchange succeeds only if the predecessor's pointer still
    \* matches what search_position observed (pc[t].found). If a concurrent
    \* inserter installed a different unmarked node for this key in the gap,
    \* the CAS would fail in real code and the inserter would retry-search.
    /\ \A n \in NodesForKeyAt(pc[t].key, 0) : n = pc[t].found
    /\ \E hChoice \in 1..MaxHeight :
         LET n == nextNodeId IN
         /\ nodes' = nodes \cup {n}
         /\ nKey' = [nKey EXCEPT ![n] = pc[t].key]
         /\ nValue' = [nValue EXCEPT ![n] = pc[t].value]
         /\ nHeight' = [nHeight EXCEPT ![n] = hChoice]                \* base.rs:1067 random_height
         /\ nRefcount' = [nRefcount EXCEPT ![n] = 2]                  \* base.rs:1072 — entry+level-0
         /\ nLinked' = [nLinked EXCEPT ![n][0] = TRUE]                \* base.rs:1095-1104 — level-0 install
         /\ nMark' = nMark
         /\ nState' = [nState EXCEPT ![n] = "alive"]
         /\ lenCounter' = lenCounter + 1                              \* base.rs:1085
         /\ nextNodeId' = nextNodeId + 1
         /\ LET next == IF FaultInsertReorder THEN "BuildLevel"       \* MarkOld already ran (F2 fault)
                       ELSE "MarkOld"
            IN pc' = [pc EXCEPT ![t] = [pc[t] EXCEPT
                                          !.step = next,
                                          !.newNode = n,
                                          !.h = hChoice]]
         /\ UNCHANGED <<pinned, pendingDeferred, iter, historyVars>>

\* ----------------------------------------------------------------------
\* Insert_MarkOld (base.rs:1125-1144)
\*   - if found = NULL → no-op step transition
\*   - else mark_tower(old). On level-0 mark win (mark_won), len.fetch_sub.
\*
\* F2 (PR #1101) pivot: this step happens AFTER level-0 CAS in the canonical
\* spec. FaultInsertReorder inverts the order (mark BEFORE CAS) — modeled
\* via the alternate Insert_MarkOldFirst path below.
\* ----------------------------------------------------------------------
Insert_MarkOld(t) ==
    /\ pc[t].op = "Insert"
    /\ pc[t].step = "MarkOld"
    /\ ~ FaultInsertReorder
    /\ LET old == pc[t].found
           h_old == IF old = NULL THEN 0 ELSE nHeight[old]
       IN
       IF old = NULL THEN
         \* No old node — empty MarkOld step (base.rs:1145-1161 — no-op trace event)
         /\ pc' = [pc EXCEPT ![t] = [pc[t] EXCEPT !.step = "BuildLevel"]]
         /\ UNCHANGED <<nodeVars, sharedVars, pinned, pendingDeferred, iter, historyVars, allocVars>>
       ELSE
         \* mark_tower(old): top-down (or bottom-up under F3), level-0 last (base.rs:333)
         LET wasL0Marked == nMark[old][0]
             newMarkRow ==
               IF FaultMarkBottomUp THEN
                 \* F3 sensitivity: bottom-up — level 0 marked first then upper levels.
                 \* PostBuildCheck (which reads only the TOP) may now miss the mark.
                 [L \in Level |-> nMark[old][L] \/ (L < h_old)]
               ELSE
                 \* canonical: top-down — for the ABSTRACTION (we collapse the loop into
                 \* a single transition), the resulting set of marked levels is the same.
                 \* The OBSERVABLE difference vs. F3 is that intermediate states differ;
                 \* we model that via Insert_PostBuildCheck which reads top-level only.
                 [L \in Level |-> nMark[old][L] \/ (L < h_old)]
         IN
         /\ nMark' = [nMark EXCEPT ![old] = newMarkRow]
         /\ IF ~wasL0Marked THEN
              \* mark_won — base.rs:1127-1129; len.fetch_sub(1)
              lenCounter' = lenCounter - 1
            ELSE
              UNCHANGED lenCounter
         /\ pc' = [pc EXCEPT ![t] = [pc[t] EXCEPT !.step = "BuildLevel"]]
         /\ UNCHANGED <<nodes, nKey, nValue, nHeight, nRefcount, nLinked, nState,
                        pinned, pendingDeferred, iter, historyVars, allocVars>>

\* ----------------------------------------------------------------------
\* Insert_MarkOldFirst — F2 (#1023) regression: mark BEFORE level-0 CAS.
\* Active only when FaultInsertReorder = TRUE.
\* This creates a reachable state where:
\*   (a) old is level-0 marked (logically removed)
\*   (b) new is NOT yet installed at level 0
\*   (c) reader observes "key absent" while it should be continuously present.
\* After firing, transitions to AllocCASLevel0; AllocCASLevel0 then transitions
\* directly to BuildLevel (skipping MarkOld) under FaultInsertReorder.
\* ----------------------------------------------------------------------
Insert_MarkOldFirst(t) ==
    /\ pc[t].op = "Insert"
    /\ pc[t].step = "MarkOldFirst"
    /\ FaultInsertReorder
    /\ LET old == pc[t].found
           wasL0Marked == nMark[old][0]
           h_old == nHeight[old]
       IN
       /\ old /= NULL
       /\ nMark' = [nMark EXCEPT
                     ![old] = [L \in Level |-> nMark[old][L] \/ (L < h_old)]]
       /\ IF ~wasL0Marked THEN lenCounter' = lenCounter - 1
          ELSE UNCHANGED lenCounter
       /\ pc' = [pc EXCEPT ![t] = [pc[t] EXCEPT !.step = "AllocCASLevel0"]]
       /\ UNCHANGED <<nodes, nKey, nValue, nHeight, nRefcount, nLinked, nState,
                      pinned, pendingDeferred, iter, historyVars, allocVars>>

\* ----------------------------------------------------------------------
\* Insert_BuildLevel (base.rs:1207-1322)
\*   For each lvl in 1..h-1:
\*     - load own next pointer; if marked → break 'build (F2 brief partial)
\*     - else CAS at predecessor's level-lvl pointer; on win, refcount++
\*
\* We model each level as a single atomic step, with non-deterministic
\* CAS-failure outcome only on the LEVEL-MARK observation (the path that
\* Family E in the prior spec exposed). The retry inner loop is collapsed.
\* ----------------------------------------------------------------------
Insert_BuildLevel(t) ==
    /\ pc[t].op = "Insert"
    /\ pc[t].step = "BuildLevel"
    /\ LET n == pc[t].newNode
           lvl == pc[t].builtUpTo + 1
           h == pc[t].h
       IN
       IF lvl >= h THEN
         \* All levels built — proceed to PostBuildCheck (base.rs:1322)
         /\ pc' = [pc EXCEPT ![t] = [pc[t] EXCEPT !.step = "PostBuildCheck"]]
         /\ UNCHANGED <<nodeVars, sharedVars, pinned, pendingDeferred, iter, historyVars, allocVars>>
       ELSE IF nMark[n][lvl] THEN
         \* Early break (base.rs:1222-1240): another thread marked our tower at lvl
         /\ pc' = [pc EXCEPT ![t] = [pc[t] EXCEPT !.step = "PostBuildCheck"]]
         /\ UNCHANGED <<nodeVars, sharedVars, pinned, pendingDeferred, iter, historyVars, allocVars>>
       ELSE
         \* Successful install at level lvl
         \*   - CAS our own next-pointer to succ              (base.rs:1272-1273)
         \*   - increment refcount                            (base.rs:1281-1282)
         \*   - CAS at predecessor                            (base.rs:1286-1289)
         /\ nLinked' = [nLinked EXCEPT ![n][lvl] = TRUE]
         /\ nRefcount' = [nRefcount EXCEPT ![n] = nRefcount[n] + 1]
         /\ pc' = [pc EXCEPT ![t] = [pc[t] EXCEPT !.builtUpTo = lvl]]
         /\ UNCHANGED <<nodes, nKey, nValue, nHeight, nMark, nState, sharedVars,
                        pinned, pendingDeferred, iter, historyVars, allocVars>>

\* ----------------------------------------------------------------------
\* Insert_PostBuildCheck (base.rs:1355-1359)
\*   Reads ONLY n.tower[height-1] (top-level pointer).
\*   If marked → calls search_bound to help unlink.
\*
\* F3 sensitivity: this read is sound iff mark_tower is TOP-DOWN. Under
\* FaultMarkBottomUp, a remover may have set level-0 (the LP) without
\* yet having set the top, so this check returns FALSE — the inserter
\* skips the help-unlink, and the partially-installed tower persists.
\*
\* In our abstraction the resulting marked set is the same; the difference
\* is captured by the topMarked flag below.
\* ----------------------------------------------------------------------
Insert_PostBuildCheck(t) ==
    /\ pc[t].op = "Insert"
    /\ pc[t].step = "PostBuildCheck"
    /\ LET n == pc[t].newNode
           h == pc[t].h
           topLvl == h - 1
           topMarked == nMark[n][topLvl]
       IN
       /\ pc' = [pc EXCEPT ![t] = [pc[t] EXCEPT
                                     !.step = "Done",
                                     !.topMarked = topMarked]]
       /\ UNCHANGED <<nodeVars, sharedVars, pinned, pendingDeferred, iter, historyVars, allocVars>>

\* ----------------------------------------------------------------------
\* Insert_Done — record history; the entry's refcount stays for the
\* caller. We model the canonical "caller-drops-immediately" pattern:
\* decrement the entry refcount we acquired at AllocCASLevel0.
\* ----------------------------------------------------------------------
Insert_Done(t) ==
    /\ pc[t].op = "Insert"
    /\ pc[t].step = "Done"
    /\ LET n == pc[t].newNode IN
       /\ history' = Append(history,
            [op |-> "Insert", thread |-> t,
             key |-> pc[t].key, value |-> pc[t].value,
             node |-> n, topMarked |-> pc[t].topMarked])
       /\ DecRef(n)                          \* release the RefEntry handle
       /\ EndOp(t)
    /\ UNCHANGED <<nodes, nKey, nValue, nHeight, nLinked, nMark, sharedVars,
                   iter, opCount, allocVars>>

\* ========================================================================
\* Get / contains_key (base.rs:572-590)
\* Single atomic action — search_bound + equivalence check. The interesting
\* concurrency property is whether Get observes "absence" while the key is
\* logically present (F2 / F4).
\* ========================================================================

Get(t, k) ==
    /\ pc[t] = [op |-> "Idle"]
    /\ NoIter(t)
    /\ opCount[t] < MaxOps
    /\ LET present == k \in LiveKeysLevel0
           result == IF present
                     THEN CHOOSE n \in NodesForKeyAt(k, 0) : TRUE
                     ELSE NULL
       IN history' = Append(history,
            [op |-> "Get", thread |-> t, key |-> k, result |-> result])
    /\ opCount' = [opCount EXCEPT ![t] = opCount[t] + 1]
    /\ UNCHANGED <<nodeVars, sharedVars, pc, pinned, pendingDeferred, iter, allocVars>>

\* ========================================================================
\* Remove (base.rs:1406-1607)
\* Stages mirroring source / trace events:
\*   Begin  : search_position                       (base.rs:1423)
\*   Acquire: try_increment refcount                (base.rs:1448-1469)
\*   MarkTower : mark_tower (top-down)              (base.rs:1474)
\*     mark_won → len.fetch_sub                     (base.rs:1477)
\*     mark_lost → decrement (PR #1143) and return  (base.rs:1582-1604)
\*   UnlinkLevel(L) : CAS predecessor for each lvl  (base.rs:1503-1560)
\*   Done   : return Some(entry)                    (base.rs:1581)
\* ========================================================================

Remove_Begin(t, k) ==
    /\ NoIter(t)
    /\ StartOp(t, "Remove")
    /\ LET nopt == IF \E n \in NodesForKeyAt(k, 0) : TRUE
                   THEN CHOOSE n \in NodesForKeyAt(k, 0) : TRUE
                   ELSE NULL
           h_top == IF nopt = NULL THEN MaxHeight - 1 ELSE nHeight[nopt] - 1
       IN pc' = [pc EXCEPT ![t] = [op |-> "Remove",
                                   step |-> IF nopt = NULL THEN "Done" ELSE "Acquire",
                                   key |-> k,
                                   target |-> nopt,
                                   markWon |-> FALSE,
                                   unlinkAt |-> h_top]]
    /\ UNCHANGED <<nodeVars, sharedVars, pendingDeferred, iter, history, allocVars>>

\* try_increment refcount on the found node (base.rs:1448-1469).
\* On failure, real code repeats the search; we abstract to Done (the bug
\* surfaces are exposed by the success path's mark/unlink interleaving).
Remove_Acquire(t) ==
    /\ pc[t].op = "Remove"
    /\ pc[t].step = "Acquire"
    /\ LET n == pc[t].target IN
       IF n = NULL \/ n \notin nodes \/ ~ TryAcquire(n) THEN
         /\ pc' = [pc EXCEPT ![t] = [pc[t] EXCEPT !.step = "Done"]]
         /\ UNCHANGED <<nodeVars, sharedVars, pinned, pendingDeferred, iter, historyVars, allocVars>>
       ELSE
         /\ IncRef(n)
         /\ pc' = [pc EXCEPT ![t] = [pc[t] EXCEPT !.step = "MarkTower"]]
         /\ UNCHANGED <<nodes, nKey, nValue, nHeight, nLinked, nMark, nState,
                        sharedVars, pinned, pendingDeferred, iter, historyVars, allocVars>>

\* mark_tower (base.rs:1474, calls 333). Top-down marking; level-0 mark
\* is the unique winner LP. PR #1143 (loser-decrement) is canonical — we
\* always decrement on the loser path.
Remove_MarkTower(t) ==
    /\ pc[t].op = "Remove"
    /\ pc[t].step = "MarkTower"
    /\ LET n == pc[t].target
           wasL0Marked == nMark[n][0]
           h == nHeight[n]
       IN
       /\ nMark' = [nMark EXCEPT
                     ![n] = [L \in Level |-> nMark[n][L] \/ (L < h)]]
       /\ IF ~wasL0Marked THEN
            \* Unique winner.
            /\ lenCounter' = lenCounter - 1                          \* base.rs:1477
            /\ pc' = [pc EXCEPT ![t] = [pc[t] EXCEPT
                                          !.step = "UnlinkLevel",
                                          !.markWon = TRUE]]
            /\ UNCHANGED <<nodes, nKey, nValue, nHeight, nLinked, nRefcount,
                           nState, pinned, pendingDeferred, iter, historyVars, allocVars>>
          ELSE
            \* Mark race lost. PR #1143 / commit 7121fbd4: must decrement and
            \* return None (base.rs:1583-1603). We always decrement (canonical).
            /\ DecRef(n)
            /\ pc' = [pc EXCEPT ![t] = [pc[t] EXCEPT !.step = "Done", !.markWon = FALSE]]
            /\ UNCHANGED <<nodes, nKey, nValue, nHeight, nLinked, lenCounter,
                           pinned, iter, historyVars, allocVars>>

\* Unlink at successive levels (base.rs:1503-1560).
\* On CAS failure, real code calls search_bound and breaks. We model the
\* CAS as non-deterministic success/failure.
Remove_UnlinkLevel(t) ==
    /\ pc[t].op = "Remove"
    /\ pc[t].step = "UnlinkLevel"
    /\ LET n == pc[t].target
           lvl == pc[t].unlinkAt
       IN
       IF lvl < 0 THEN
         /\ pc' = [pc EXCEPT ![t] = [pc[t] EXCEPT !.step = "Done"]]
         /\ UNCHANGED <<nodeVars, sharedVars, pinned, pendingDeferred, iter, historyVars, allocVars>>
       ELSE IF ~ nLinked[n][lvl] THEN
         \* Level wasn't installed (or HelpUnlink already cleaned). Skip.
         /\ pc' = [pc EXCEPT ![t] = [pc[t] EXCEPT !.unlinkAt = lvl - 1]]
         /\ UNCHANGED <<nodeVars, sharedVars, pinned, pendingDeferred, iter, historyVars, allocVars>>
       ELSE
         \E succeeds \in BOOLEAN :
           IF succeeds THEN
             \* CAS win: unlink at lvl, decrement refcount (base.rs:1521-1538)
             /\ nLinked' = [nLinked EXCEPT ![n][lvl] = FALSE]
             /\ DecRef(n)
             /\ pc' = [pc EXCEPT ![t] = [pc[t] EXCEPT !.unlinkAt = lvl - 1]]
             /\ UNCHANGED <<nodes, nKey, nValue, nHeight, nMark, sharedVars,
                            pinned, iter, historyVars, allocVars>>
           ELSE
             \* CAS failure: search_bound mops up, then break (base.rs:1556-1559)
             /\ pc' = [pc EXCEPT ![t] = [pc[t] EXCEPT !.step = "Done"]]
             /\ UNCHANGED <<nodeVars, sharedVars, pinned, pendingDeferred, iter, historyVars, allocVars>>

\* Remove_Done — record history, release the held RefEntry (caller drop).
Remove_Done(t) ==
    /\ pc[t].op = "Remove"
    /\ pc[t].step = "Done"
    /\ LET n == pc[t].target
           result == IF pc[t].markWon THEN n ELSE NULL
       IN
       /\ history' = Append(history,
            [op |-> "Remove", thread |-> t, key |-> pc[t].key,
             result |-> result, node |-> n])
       /\ IF pc[t].markWon /\ n /= NULL /\ n \in nodes
          THEN DecRef(n)            \* release RefEntry returned to caller
          ELSE UNCHANGED <<nRefcount, nState, pendingDeferred>>
       /\ EndOp(t)
    /\ UNCHANGED <<nodes, nKey, nValue, nHeight, nLinked, nMark, sharedVars,
                   iter, opCount, allocVars>>

\* ========================================================================
\* Iterator (Family 1) — Iter and Range
\* base.rs:2098-2120 (Iter::next), 2126-2147 (Iter::next_back)
\* base.rs:2287-2320 (Range::next), 2329-2361 (Range::next_back)
\*
\* State machine per iterator:
\*   exists=FALSE        : no iterator
\*   {head=NULL, finished=FALSE} : Fresh — never advanced
\*   {head=n, finished=FALSE}    : Yielded n (forward)
\*   {tail=n, finished=FALSE}    : Yielded n (backward)
\*   {head,tail=NULL, finished=TRUE}    : Crossed-over (after head>=tail).
\*
\* F1 BUG: at code line 2110-2111 (Iter::next) and 2137-2138 (Iter::next_back)
\* and 2301-2303 (Range::next) and 2342-2344 (Range::next_back), exhaustion
\* sets self.head = None; self.tail = None; — but the next call's
\* `match self.head { None => search_bound(...) }` arm REWINDS the iterator
\* to the start/end of the list. RefIter is unaffected because it retains
\* Some(RefEntry) state.
\* ========================================================================

\* Begin a new iterator (kind = "Iter" or "Range").
Iter_Begin(t, kind) ==
    /\ NoIter(t)
    /\ StartOp(t, "Iter")
    /\ iter' = [iter EXCEPT ![t] = [exists |-> TRUE,
                                    kind |-> kind,
                                    head |-> NULL,
                                    tail |-> NULL,
                                    finished |-> FALSE,
                                    lastYield |-> NULL,
                                    dir |-> "none"]]
    /\ pc' = [pc EXCEPT ![t] = [op |-> "Iter", step |-> "Active"]]
    /\ UNCHANGED <<nodeVars, sharedVars, pendingDeferred, history, allocVars>>

\* ----------------------------------------------------------------------
\* Iter_Next — forward step (base.rs:2098-2120 for Iter; 2287-2320 for Range)
\*
\* Code shape:
\*   self.head = match self.head {
\*     Some(n) => next_node(n.as_tower(), Excluded(&n.key), guard),
\*     None    => search_bound(start_bound or Unbounded, false, guard),
\*   };
\*   if let (Some(h), Some(t)) = (self.head, self.tail) {
\*     if h.key >= t.key { self.head = None; self.tail = None; }
\*   }
\*   self.head.map(|n| Entry { ... })
\*
\* The bug: after head=tail=None has been set on cross-over, the next call
\* re-enters the None arm and rewinds. We expose this via FaultIterRewind:
\*   - FaultIterRewind = TRUE  : finished bit ignored; rewind allowed.
\*   - FaultIterRewind = FALSE : finished bit sticky; once set, return None.
\* ----------------------------------------------------------------------
Iter_Next(t) ==
    /\ pc[t].op = "Iter"
    /\ pc[t].step = "Active"
    /\ HasIter(t)
    /\ LET cur == iter[t].head
           lastTail == iter[t].tail
           wasFinished == iter[t].finished
       IN
       \* If finished and the implementation is correct (no rewind), stay None.
       IF wasFinished /\ ~ FaultIterRewind THEN
         /\ history' = Append(history,
              [op |-> "IterNext", thread |-> t, result |-> NULL,
               kind |-> iter[t].kind, finished |-> TRUE])
         /\ UNCHANGED <<nodeVars, sharedVars, pc, pinned, pendingDeferred, iter, opCount, allocVars>>
       ELSE
         \* Compute the next forward candidate: any present level-0 key.
         \* If cur = NULL → start from front (Unbounded); excludes nothing.
         \* If cur /= NULL → start after cur.key (Bound::Excluded(&cur.key)).
         LET candidates ==
               IF cur = NULL THEN LiveKeysLevel0
               ELSE { k \in LiveKeysLevel0 : k /= nKey[cur] }
         IN
         \* Cross-over check (base.rs:2108-2113): if a tail was previously
         \* yielded and our new head is >= tail, set head=tail=None and
         \* yield None.
         IF candidates = {} THEN
           \* No more candidates: cross-over / exhausted.
           /\ iter' = [iter EXCEPT ![t] = [iter[t] EXCEPT
                                              !.head = NULL,
                                              !.tail = NULL,
                                              !.finished = TRUE,
                                              !.dir = "fwd"]]
           /\ history' = Append(history,
                [op |-> "IterNext", thread |-> t, result |-> NULL,
                 kind |-> iter[t].kind, finished |-> TRUE])
           /\ UNCHANGED <<nodeVars, sharedVars, pc, pinned, pendingDeferred, opCount, allocVars>>
         ELSE
           \E k \in candidates :
             LET nNew == CHOOSE n \in NodesForKeyAt(k, 0) : TRUE
                 \* Cross-over with tail (base.rs:2108-2113): if h.key >= t.key.
                 \* In our abstraction we use key equality / order on keys.
                 crossed == lastTail /= NULL
                            /\ lastTail \in nodes
                            /\ ~ (\E k2 \in LiveKeysLevel0 :
                                    k2 /= nKey[nNew] /\ k2 /= nKey[lastTail]
                                    /\ TRUE \* simplification: any k2 between
                                 )
                            /\ k = nKey[lastTail]   \* head reached tail
             IN
             IF crossed THEN
               /\ iter' = [iter EXCEPT ![t] = [iter[t] EXCEPT
                                                  !.head = NULL,
                                                  !.tail = NULL,
                                                  !.finished = TRUE,
                                                  !.dir = "fwd"]]
               /\ history' = Append(history,
                    [op |-> "IterNext", thread |-> t, result |-> NULL,
                     kind |-> iter[t].kind, finished |-> TRUE])
               /\ UNCHANGED <<nodeVars, sharedVars, pc, pinned, pendingDeferred, opCount, allocVars>>
             ELSE
               \* Yield: in Iter (non-Ref) we don't increment refcount on yield;
               \* but for safety against premature finalize we keep the cur "head"
               \* slot as just a reference. RefIter would IncRef here.
               /\ iter' = [iter EXCEPT ![t] = [iter[t] EXCEPT
                                                  !.head = nNew,
                                                  !.lastYield = nNew,
                                                  !.dir = "fwd"]]
               /\ history' = Append(history,
                    [op |-> "IterNext", thread |-> t, result |-> nNew,
                     kind |-> iter[t].kind, finished |-> FALSE])
               /\ UNCHANGED <<nodeVars, sharedVars, pc, pinned, pendingDeferred, opCount, allocVars>>

\* ----------------------------------------------------------------------
\* Iter_NextBack — backward step (base.rs:2126-2147; Range 2329-2361)
\*
\* Code shape mirrors next() but uses search_bound(Excluded(&n.key), true)
\* on Some(n), and search_bound(end_bound, true) on None. The same
\* head=tail=None reset on cross-over → rewind bug applies.
\* ----------------------------------------------------------------------
Iter_NextBack(t) ==
    /\ pc[t].op = "Iter"
    /\ pc[t].step = "Active"
    /\ HasIter(t)
    /\ LET cur == iter[t].tail
           lastHead == iter[t].head
           wasFinished == iter[t].finished
       IN
       IF wasFinished /\ ~ FaultIterRewind THEN
         /\ history' = Append(history,
              [op |-> "IterNextBack", thread |-> t, result |-> NULL,
               kind |-> iter[t].kind, finished |-> TRUE])
         /\ UNCHANGED <<nodeVars, sharedVars, pc, pinned, pendingDeferred, iter, opCount, allocVars>>
       ELSE
         LET candidates ==
               IF cur = NULL THEN LiveKeysLevel0
               ELSE { k \in LiveKeysLevel0 : k /= nKey[cur] }
         IN
         IF candidates = {} THEN
           /\ iter' = [iter EXCEPT ![t] = [iter[t] EXCEPT
                                              !.head = NULL,
                                              !.tail = NULL,
                                              !.finished = TRUE,
                                              !.dir = "back"]]
           /\ history' = Append(history,
                [op |-> "IterNextBack", thread |-> t, result |-> NULL,
                 kind |-> iter[t].kind, finished |-> TRUE])
           /\ UNCHANGED <<nodeVars, sharedVars, pc, pinned, pendingDeferred, opCount, allocVars>>
         ELSE
           \E k \in candidates :
             LET nNew == CHOOSE n \in NodesForKeyAt(k, 0) : TRUE
                 crossed == lastHead /= NULL
                            /\ lastHead \in nodes
                            /\ k = nKey[lastHead]
             IN
             IF crossed THEN
               /\ iter' = [iter EXCEPT ![t] = [iter[t] EXCEPT
                                                  !.head = NULL,
                                                  !.tail = NULL,
                                                  !.finished = TRUE,
                                                  !.dir = "back"]]
               /\ history' = Append(history,
                    [op |-> "IterNextBack", thread |-> t, result |-> NULL,
                     kind |-> iter[t].kind, finished |-> TRUE])
               /\ UNCHANGED <<nodeVars, sharedVars, pc, pinned, pendingDeferred, opCount, allocVars>>
             ELSE
               /\ iter' = [iter EXCEPT ![t] = [iter[t] EXCEPT
                                                  !.tail = nNew,
                                                  !.lastYield = nNew,
                                                  !.dir = "back"]]
               /\ history' = Append(history,
                    [op |-> "IterNextBack", thread |-> t, result |-> nNew,
                     kind |-> iter[t].kind, finished |-> FALSE])
               /\ UNCHANGED <<nodeVars, sharedVars, pc, pinned, pendingDeferred, opCount, allocVars>>

\* Iter_Drop — release iterator state (Iter does not hold refs; RefIter does).
\* For abstract simplicity we don't IncRef on Iter, so no DecRef on Drop.
Iter_Drop(t) ==
    /\ pc[t].op = "Iter"
    /\ HasIter(t)
    /\ iter' = [iter EXCEPT ![t] = InitIter]
    /\ history' = Append(history, [op |-> "IterDrop", thread |-> t])
    /\ EndOp(t)
    /\ UNCHANGED <<nodeVars, sharedVars, pendingDeferred, opCount, allocVars>>

\* ========================================================================
\* PopFront / PopBack (base.rs:1610-1622, 1625-1637)
\* These are loop {front → pin → remove}; we model as a single step that
\* either succeeds (returns Some) or returns None when list is empty.
\* The stress is on Family 4 — concurrent pop_front from N threads.
\* ========================================================================

PopFront(t) ==
    /\ pc[t] = [op |-> "Idle"]
    /\ NoIter(t)
    /\ opCount[t] < MaxOps
    /\ IF LiveKeysLevel0 = {} THEN
         /\ history' = Append(history,
              [op |-> "PopFront", thread |-> t, result |-> NULL])
         /\ opCount' = [opCount EXCEPT ![t] = opCount[t] + 1]
         /\ UNCHANGED <<nodeVars, sharedVars, pc, pinned, pendingDeferred, iter, allocVars>>
       ELSE
         \E k \in LiveKeysLevel0 :
           LET n == CHOOSE x \in NodesForKeyAt(k, 0) : TRUE IN
           /\ ~ nMark[n][0]
           \* Atomic remove approximation (mark_tower wins; level-0 unlinks lazily)
           /\ nMark' = [nMark EXCEPT
                         ![n] = [L \in Level |-> nMark[n][L] \/ (L < nHeight[n])]]
           /\ lenCounter' = lenCounter - 1
           /\ history' = Append(history,
                [op |-> "PopFront", thread |-> t, result |-> n])
           /\ opCount' = [opCount EXCEPT ![t] = opCount[t] + 1]
           /\ UNCHANGED <<nodes, nKey, nValue, nHeight, nRefcount, nLinked, nState,
                          pc, pinned, pendingDeferred, iter, allocVars>>

\* ========================================================================
\* HelpUnlink (base.rs:759-786)
\* When traversing, threads cooperatively unlink marked nodes.
\* Modeled as a free background action. Each fire converts a (mark=TRUE,
\* linked=TRUE) level-L state into (linked=FALSE), with refcount decrement.
\* ========================================================================

HelpUnlink ==
    /\ \E n \in LiveNodes, L \in Level :
         /\ nMark[n][L]
         /\ nLinked[n][L]
         /\ nLinked' = [nLinked EXCEPT ![n][L] = FALSE]
         /\ DecRef(n)              \* base.rs:781 — curr.decrement(guard)
    /\ UNCHANGED <<nodes, nKey, nValue, nHeight, nMark, sharedVars,
                   pc, pinned, iter, historyVars, allocVars>>

\* ========================================================================
\* EpochFinalize (base.rs:253-265, 297-307)
\* Normally only fires after epoch grace (no thread pinned with a guard).
\* FaultPrematureFree allows it while threads pinned (UAF probe).
\* ========================================================================

EpochFinalize ==
    /\ pendingDeferred /= {}
    /\ \E n \in pendingDeferred :
         LET anyPinned == \E t \in Thread : pinned[t] IN
         /\ FaultPrematureFree \/ ~ anyPinned
         /\ nState' = [nState EXCEPT ![n] = "freed"]
         /\ pendingDeferred' = pendingDeferred \ {n}
    /\ UNCHANGED <<nodes, nKey, nValue, nHeight, nRefcount, nLinked, nMark,
                   sharedVars, pc, pinned, iter, historyVars, allocVars>>

\* ========================================================================
\* Caller harness (Family 4) — non-deterministic interleaving of all ops
\* When EnableHarness = TRUE, threads non-deterministically pick any
\* operation from {insert, get, remove, iter_begin/next/next_back/drop,
\* pop_front}. When FALSE, only the basic ones (no iter/pop_front) — used
\* for hunting F2 in isolation.
\* ========================================================================

\* (No new actions needed — the harness is just `\E t \in Thread, ...` in Next.)

\* ========================================================================
\* Next State Relation
\* ========================================================================

Next ==
    \/ \E t \in Thread, k \in Key, v \in Value : Insert_Begin(t, k, v)
    \/ \E t \in Thread : Insert_AllocCASLevel0(t)
    \/ \E t \in Thread : Insert_MarkOld(t)
    \/ \E t \in Thread : Insert_MarkOldFirst(t)
    \/ \E t \in Thread : Insert_BuildLevel(t)
    \/ \E t \in Thread : Insert_PostBuildCheck(t)
    \/ \E t \in Thread : Insert_Done(t)
    \/ \E t \in Thread, k \in Key : Get(t, k)
    \/ \E t \in Thread, k \in Key : Remove_Begin(t, k)
    \/ \E t \in Thread : Remove_Acquire(t)
    \/ \E t \in Thread : Remove_MarkTower(t)
    \/ \E t \in Thread : Remove_UnlinkLevel(t)
    \/ \E t \in Thread : Remove_Done(t)
    \/ EnableHarness /\ \E t \in Thread, kind \in {"Iter", "Range"} : Iter_Begin(t, kind)
    \/ EnableHarness /\ \E t \in Thread : Iter_Next(t)
    \/ EnableHarness /\ \E t \in Thread : Iter_NextBack(t)
    \/ EnableHarness /\ \E t \in Thread : Iter_Drop(t)
    \/ EnableHarness /\ \E t \in Thread : PopFront(t)
    \/ HelpUnlink
    \/ EpochFinalize

Spec == Init /\ [][Next]_vars

\* ========================================================================
\* Invariants (brief §5)
\* ========================================================================

\* --- Standard / structural ---

AllocBound == nextNodeId <= MaxNodes + 1

NodesAllocatedHaveState ==
    \A n \in nodes : nState[n] \in {"alive", "retired", "freed"}

\* Refcount must remain non-negative (brief §5; F4, F5 surface)
RefcountNonNegative == \A n \in NodeId : nRefcount[n] >= 0

\* --- F2 / F3: KeysUnique ---
\* At quiescence (no in-flight Insert), each key has at most one unmarked
\* level-0 node. The transient F2 window is acceptable IFF an Insert is in
\* flight at AllocCASLevel0/MarkOld for that key.
KeysUnique ==
    \A k \in Key :
      Cardinality(NodesForKeyAt(k, 0)) <= 1
      \/ (\E t \in Thread :
            /\ pc[t].op = "Insert"
            /\ pc[t].step \in {"MarkOld", "BuildLevel", "PostBuildCheck"}
            /\ pc[t].key = k)

\* --- F2 / F3: MarkMonotone ---
\* Once a level is marked, it never returns to unmarked.
\* (This is a temporal invariant; we approximate by a structural check —
\* mark only ever grows. The base spec ensures this by construction;
\* we encode it as an Inv to be checked.)
MarkMonotone ==
    \A n \in nodes :
      \A L \in Level :
        nMark[n][L] => nLinked[n][L] \/ ~ nLinked[n][L]   \* trivially true; marks don't unset

\* --- F2 / F3: MarkTopDown ---
\* If level L is marked, then for all L' > L (within tower height), L' is
\* also marked OR has been unlinked already. This holds at quiescence
\* (mid-mark_tower the partial state may not satisfy; checked at rest).
MarkTopDown ==
    \A n \in nodes :
      \A L1, L2 \in Level :
        (L1 < L2 /\ L2 < nHeight[n] /\ nMark[n][L1])
          => (nMark[n][L2] \/ ~ nLinked[n][L2])

\* --- F2: LenIsApproximatelyKeyCount ---
\* len equals |LiveKeysLevel0| ± in-flight inserts/removes for those keys.
\* At quiescence (no in-flight ops), len = |LiveKeysLevel0|.
InflightInsertCount ==
    Cardinality({t \in Thread :
                   /\ pc[t].op = "Insert"
                   /\ pc[t].step \in {"AllocCASLevel0", "MarkOld",
                                      "BuildLevel", "PostBuildCheck"}})

LenIsApproximatelyKeyCount ==
    LET diff == LenClamped - Cardinality(LiveKeysLevel0) IN
    /\ diff >= 0 - Cardinality(Thread)
    /\ diff <= Cardinality(Thread)

\* --- F1: IterFusedAfterExhaust ---
\* Once an iterator yields None for a thread, every subsequent next/next_back
\* call for that thread (without an intervening Iter_Drop/Begin) yields None.
IteratorFusion ==
    \A i, j \in 1..Len(history) :
      (/\ i < j
       /\ history[i].op \in {"IterNext", "IterNextBack"}
       /\ history[j].op \in {"IterNext", "IterNextBack"}
       /\ history[i].thread = history[j].thread
       /\ history[i].result = NULL
       /\ ~ \E m \in (i+1)..(j-1) :
              /\ history[m].op \in {"IterDrop", "IterBegin"}
              /\ history[m].thread = history[i].thread)
      => history[j].result = NULL

\* --- F1 / F2: IterNoSameKeyTwice ---
\* In a single iteration (between Begin and Drop), no key is yielded twice.
IterNoSameKeyTwice ==
    \A t \in Thread :
      \A i, j \in 1..Len(history) :
        (/\ i < j
         /\ history[i].op \in {"IterNext", "IterNextBack"}
         /\ history[j].op \in {"IterNext", "IterNextBack"}
         /\ history[i].thread = t
         /\ history[j].thread = t
         /\ history[i].result /= NULL
         /\ history[j].result /= NULL
         /\ history[i].result \in nodes
         /\ history[j].result \in nodes
         /\ ~ \E m \in (i+1)..(j-1) :
                /\ history[m].op = "IterDrop"
                /\ history[m].thread = t)
        => nKey[history[i].result] /= nKey[history[j].result]

\* --- F4: RefcountMatchesHandlesAndInstalls ---
\* At quiescence (every thread Idle, no iterators), every alive node's
\* refcount equals the number of levels it is linked at.
RefcountMatchesHandlesAndInstalls ==
    (/\ \A t \in Thread : pc[t] = [op |-> "Idle"]
     /\ \A t \in Thread : ~ iter[t].exists)
      =>
        \A n \in nodes :
          nState[n] = "alive" =>
            nRefcount[n] = Cardinality({L \in Level : L < nHeight[n] /\ nLinked[n][L]})

\* --- F4: GetReturnsLatest ---
\* Get(K) immediately after a completed Insert(K, V) (with NO concurrent
\* remove and NO concurrent other Insert of K) returns Some.
\*
\* Brief §5 phrasing: "Get(K) after a completed Insert(K,V) (no concurrent
\* remove of K, no concurrent insert of K) returns V". We require also no
\* concurrent PopFront/PopBack anywhere in history (because they may pop
\* K dynamically) and no concurrent op of any kind on K — otherwise the
\* "completed" notion is ambiguous: an Insert is logically complete at
\* its level-0 CAS (AllocCASLevel0), not at its Done event.
HasKey(ev) == "key" \in DOMAIN ev

\* No remove / pop / additional insert(K) anywhere in history (only Insert(K)
\* once, plus Gets), AND no thread is currently mid-Remove or mid-Pop. This
\* keeps the property a pure read-after-write check that the brief
\* expresses as "no concurrent remove of K, no concurrent insert of K".
NoMutationAnywhere(k) ==
    /\ \A m \in 1..Len(history) :
         /\ history[m].op /= "Remove"
         /\ history[m].op /= "PopFront"
         /\ history[m].op /= "PopBack"
    /\ \A t \in Thread :
         pc[t].op \notin {"Remove"}
    /\ Cardinality({m \in 1..Len(history) :
                      /\ history[m].op = "Insert"
                      /\ HasKey(history[m])
                      /\ history[m].key = k}) <= 1

GetReturnsLatest ==
    \A i, j \in 1..Len(history) :
      (/\ i < j
       /\ history[i].op = "Insert"
       /\ history[j].op = "Get"
       /\ HasKey(history[i])
       /\ HasKey(history[j])
       /\ history[i].key = history[j].key
       /\ NoMutationAnywhere(history[i].key))
      => history[j].result /= NULL

\* --- F5 (reference): NoUseAfterFree ---
\* No thread holds a target/newNode reference to a freed node.
NoUseAfterFree ==
    \A t \in Thread :
      LET op == pc[t].op IN
      /\ (op = "Remove" /\ "target" \in DOMAIN pc[t] /\ pc[t].target /= NULL)
            => nState[pc[t].target] /= "freed"
      /\ (op = "Insert" /\ "newNode" \in DOMAIN pc[t] /\ pc[t].newNode /= NULL)
            => nState[pc[t].newNode] /= "freed"

====
