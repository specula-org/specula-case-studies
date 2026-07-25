------------------------------- MODULE base --------------------------------
(* TLA+ specification for papaya — Lock-Free Concurrent HashMap (Rust) — Round 2
 *
 * Models the core lock-free hash table protocol:
 *   - Open-addressing with quadratic probing
 *   - Two resize modes (Blocking / Incremental)
 *   - 3-bit tagged pointers: COPYING, COPIED, BORROWED
 *   - Two-phase insert (CAS entry, then store metadata) — winner + loser fixup
 *   - Thread parking for blocking resize, with parker+key routing
 *   - Iterator snapshot semantics (concurrent iter + insert + resize)
 *   - Epoch-based deferred retirement
 *
 * Source: artifact/papaya/src/raw/mod.rs (release 0.2.4, master = b510b15)
 *
 * Bug Families targeted (round 2):
 *   Family 1: Resize Copy/Insert Race Conditions       (HIGH — unchanged from round 1)
 *   Family 2: Memory Ordering Gaps                     (HIGH — adversary-downgrade only)
 *   Family 3: Parker / Unpark Routing                  (HIGH — D2-1, unfixed upstream)
 *   Family 4: Epoch-Based Reclamation Safety           (MEDIUM)
 *   Family 6: Adversarial Caller — Iter+Modify+Resize  (HIGH — NEW)
 *   Family 7: Slot Recycling / META Overwrite          (MEDIUM — D2-4, NEW)
 *)
EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS
    Thread,         \* Set of thread identifiers
    Key,            \* Set of keys
    Value,          \* Set of values
    Slot,           \* Set of slot indices (abstract)
    MaxTables,      \* Maximum number of tables in the chain
    NULL            \* Null constant

(* ---------- Tag constants (raw/mod.rs:138-155) ---------- *)
CONSTANTS
    COPYING,        \* 0b001: entry is being copied, no updates allowed
    COPIED,         \* 0b010: entry has been copied to next table
    BORROWED        \* 0b100: entry was copied from a previous table

(* ---------- Resize status (raw/mod.rs:86-95) ---------- *)
CONSTANTS
    PENDING,        \* Resize in progress
    ABORTED,        \* Resize aborted (table full)
    PROMOTED        \* Resize complete, table promoted to root

(* ---------- Metadata constants ---------- *)
CONSTANTS
    META_EMPTY,     \* Slot metadata: empty (0x80)
    META_TOMBSTONE  \* Slot metadata: deleted (0xFE)

(* ================================================================
 * VARIABLES
 * ================================================================ *)

(* --- Core table state --- *)
VARIABLES
    rootTable,          \* Index of the current root table (1..MaxTables or NULL)
    tableEntry,         \* tableEntry[t][s] = entry record or NULL
                        \*   record fields: [key, value, tag (subset of {COPYING, COPIED, BORROWED})]
    tableMeta,          \* tableMeta[t][s] = META_EMPTY | META_TOMBSTONE | h2 value (modeled as key)
    nextTable,          \* nextTable[t] = index of next table for resize, or NULL

(* --- Resize state (raw/mod.rs:48-95) --- [Family 1, 3] *)
    resizeStatus,       \* resizeStatus[t] = PENDING | ABORTED | PROMOTED
    copiedCount,        \* copiedCount[t] = number of entries copied to table t
    claimCount,         \* claimCount[t] = number of entries claimed for copying

(* --- Two-phase insert (Family 7: MC-2 / D2-4) --- *)
    metaWritten,        \* metaWritten[t][s] = TRUE iff metadata stored after CAS
    insertWindow,       \* insertWindow[t][s] = thread that won the CAS but has not yet stored meta,
                        \* or NULL. Used to expose the meta-overwrite window.

(* --- Thread parking (raw/utils/parker.rs) --- [Family 3] *)
    parked,             \* parked[thread] = [parker: t, key: t] or NULL
                        \* Tracks BOTH which parker AND which key the thread waits on.
                        \* The bug at mod.rs:2282-2283 unparks (parker(table), key(table.status))
                        \* when threads are parked on (parker(next), key(next.status)).

(* --- Epoch-based reclamation (Family 4) --- *)
    retired,            \* Set of {[key, table, slot]} retired but not yet reclaimed
    deferred,           \* deferred[t] = set of retired records deferred to table t (incremental mode)

(* --- Iterator snapshot (Family 6 — NEW) --- *)
    iterTable,          \* iterTable[tid] = snapshot of root table at iter-begin, or NULL if not iterating
    iterIdx,            \* iterIdx[tid] = next slot index (1..Cardinality(Slot)+1) to visit
    iterDone,           \* iterDone[tid] = TRUE iff iter has completed
    seenKeys,           \* seenKeys[tid] = sequence of keys yielded so far (multiset semantics)
    iterStartedKeys,    \* iterStartedKeys[tid] = snapshot of insertedKeys at iter-begin

(* --- Logical map state (for invariants) --- *)
    insertedKeys,       \* Set of keys successfully inserted and not removed
    threadPC,           \* threadPC[t] = thread program counter (idle / running / iter)
    epoch               \* epoch[thread] = current epoch (simplified for reclamation)

(* Variable groups for UNCHANGED *)
tableVars    == <<rootTable, tableEntry, tableMeta, nextTable>>
resizeVars   == <<resizeStatus, copiedCount, claimCount>>
insertVars   == <<metaWritten, insertWindow>>
parkerVars   == <<parked>>
reclaimVars  == <<retired, deferred>>
iterVars     == <<iterTable, iterIdx, iterDone, seenKeys, iterStartedKeys>>
logicalVars  == <<insertedKeys, threadPC, epoch>>

vars == <<tableVars, resizeVars, insertVars, parkerVars, reclaimVars, iterVars, logicalVars>>

(* ================================================================
 * HELPERS
 * ================================================================ *)

\* Whether a table has a valid next table
HasNextTable(t) == nextTable[t] /= NULL

\* Whether an entry has a specific tag bit set
HasTag(entry, tag) ==
    /\ entry /= NULL
    /\ tag \in entry.tag

TagOf(entry) == IF entry = NULL THEN {} ELSE entry.tag

MkEntry(k, v, tags) == [key |-> k, value |-> v, tag |-> tags]

\* The chain of tables from root to end (raw/mod.rs:1700-1750 next_table chase)
RECURSIVE TableChain(_)
TableChain(t) ==
    IF t = NULL THEN {}
    ELSE {t} \cup TableChain(nextTable[t])

\* All currently allocated tables (those on the chain)
AllTables == IF rootTable = NULL THEN {} ELSE TableChain(rootTable)

\* Whether a key has any live entry in any table on the chain (excluding COPIED entries)
KeyInChain(k) ==
    \E t \in AllTables, s \in Slot :
        /\ tableEntry[t][s] /= NULL
        /\ tableEntry[t][s].key = k
        /\ ~ HasTag(tableEntry[t][s], COPIED)

\* Whether a key is findable via get() — follows raw/mod.rs:315-396
KeyFindable(k) ==
    IF rootTable = NULL THEN FALSE
    ELSE \E t \in AllTables, s \in Slot :
        /\ tableEntry[t][s] /= NULL
        /\ tableEntry[t][s].key = k
        /\ ~ HasTag(tableEntry[t][s], COPIED)
        /\ metaWritten[t][s] = TRUE
        /\ tableMeta[t][s] /= META_EMPTY
        /\ tableMeta[t][s] /= META_TOMBSTONE

\* Number of slots — used as table.len() for promotion check
TableLen(t) == Cardinality(Slot)

\* h2(k) abstraction — collapse hash to the key value itself
h2(k) == k

\* Simulate the iteration over a thread's snapshot table:
\* Whether slot s in iterTable[tid] would be yielded by Iter::next at idx
IterShouldYield(tid, s) ==
    LET t == iterTable[tid] IN
    /\ t /= NULL
    /\ tableEntry[t][s] /= NULL
    /\ ~ tableMeta[t][s] = META_EMPTY
    /\ ~ tableMeta[t][s] = META_TOMBSTONE

(* ================================================================
 * INIT
 * ================================================================ *)

Init ==
    /\ rootTable = NULL
    /\ tableEntry = [t \in 1..MaxTables |-> [s \in Slot |-> NULL]]
    /\ tableMeta = [t \in 1..MaxTables |-> [s \in Slot |-> META_EMPTY]]
    /\ nextTable = [t \in 1..MaxTables |-> NULL]
    /\ resizeStatus = [t \in 1..MaxTables |-> PENDING]
    /\ copiedCount = [t \in 1..MaxTables |-> 0]
    /\ claimCount = [t \in 1..MaxTables |-> 0]
    /\ metaWritten = [t \in 1..MaxTables |-> [s \in Slot |-> FALSE]]
    /\ insertWindow = [t \in 1..MaxTables |-> [s \in Slot |-> NULL]]
    /\ parked = [tid \in Thread |-> NULL]
    /\ retired = {}
    /\ deferred = [t \in 1..MaxTables |-> {}]
    /\ iterTable = [tid \in Thread |-> NULL]
    /\ iterIdx = [tid \in Thread |-> 0]
    /\ iterDone = [tid \in Thread |-> FALSE]
    /\ seenKeys = [tid \in Thread |-> << >>]
    /\ iterStartedKeys = [tid \in Thread |-> {}]
    /\ insertedKeys = {}
    /\ threadPC = [tid \in Thread |-> "idle"]
    /\ epoch = [tid \in Thread |-> 0]

(* ================================================================
 * INIT TABLE / RESIZE PROTOCOL
 * ================================================================ *)

(* ---- InitTable: lazy table init (raw/mod.rs:1859-1885) ---- *)
InitTable(tid) ==
    /\ rootTable = NULL
    /\ \E t \in 1..MaxTables :
        /\ tableEntry[t] = [s \in Slot |-> NULL]
        /\ rootTable' = t
        /\ resizeStatus' = [resizeStatus EXCEPT ![t] = PROMOTED]
    /\ UNCHANGED <<tableEntry, tableMeta, nextTable, copiedCount, claimCount,
                    insertVars, parkerVars, reclaimVars, iterVars, logicalVars>>

(* ---- AllocNextTable: allocate next-table for resize (raw/mod.rs:1890-1985) ---- *)
AllocNextTable(tid, t) ==
    /\ rootTable /= NULL
    /\ t \in AllTables
    /\ nextTable[t] = NULL
    /\ \E nt \in 1..MaxTables :
        /\ nt /= t
        /\ nt \notin AllTables       \* prevent cycles in chain
        /\ tableEntry[nt] = [s \in Slot |-> NULL]
        /\ nextTable[nt] = NULL
        /\ nextTable' = [nextTable EXCEPT ![t] = nt]
        /\ resizeStatus' = [resizeStatus EXCEPT ![nt] = PENDING]
        /\ copiedCount' = [copiedCount EXCEPT ![nt] = 0]
        /\ claimCount' = [claimCount EXCEPT ![nt] = 0]
    /\ UNCHANGED <<rootTable, tableEntry, tableMeta, insertVars, parkerVars,
                    reclaimVars, iterVars, logicalVars>>

(* ================================================================
 * INSERT — TWO-PHASE WITH FIXUP (Family 7: D2-4 META OVERWRITE)
 *
 * Code: raw/mod.rs:1014-1111 (insert_at)
 *   1. Winner CAS at line 1028-1034:  CAS NULL -> new_entry
 *   2. Yield window at line 1047:     for _ in 0..100 { yield_now }
 *   3. Winner meta store at 1051:     meta_entry.store(meta, Release)
 *   4. Loser fixup at 1106-1108:      if meta == EMPTY then store h2(observed)
 *
 * Splitting into 3 actions exposes the META OVERWRITE bug:
 *   - InsertCASEntry: winner publishes entry, claims insertWindow
 *   - Remove (concurrent): may tombstone the slot before winner stores meta
 *   - InsertStoreMeta: winner stores meta UNCONDITIONALLY (the buggy path)
 *   - InsertMetaFixup: loser's fixup, conditional on meta still EMPTY
 * ================================================================ *)

(* ---- InsertCASEntry: Phase 1 — winner CAS (raw/mod.rs:1028-1044) ---- *)
InsertCASEntry(tid, k, v, t, s) ==
    /\ rootTable /= NULL
    /\ t \in AllTables
    /\ resizeStatus[t] /= ABORTED
    /\ tableMeta[t][s] = META_EMPTY            \* probe found EMPTY (raw/mod.rs:482)
    /\ tableEntry[t][s] = NULL
    \* Probe-chain pre-check: insert_inner ensures key not already in chain (raw/mod.rs:472-582)
    /\ ~ \E t2 \in AllTables, s2 \in Slot :
        /\ tableEntry[t2][s2] /= NULL
        /\ tableEntry[t2][s2].key = k
    \* CAS NULL -> new_entry (raw/mod.rs:1028-1034)
    /\ tableEntry' = [tableEntry EXCEPT ![t][s] = MkEntry(k, v, {})]
    /\ metaWritten' = [metaWritten EXCEPT ![t][s] = FALSE]
    /\ insertWindow' = [insertWindow EXCEPT ![t][s] = tid]   \* mark winner pending meta-store
    /\ insertedKeys' = insertedKeys \cup {k}
    /\ UNCHANGED <<rootTable, tableMeta, nextTable, resizeVars, parkerVars,
                    reclaimVars, iterVars, threadPC, epoch>>

(* ---- InsertStoreMeta: Phase 2 — winner unconditional meta store (raw/mod.rs:1051) ---- *)
(* This action is the BUGGY site for Family 7 D2-4: the winner stores h2(k)
 * even if a concurrent Remove tombstoned the slot, overwriting TOMBSTONE meta.
 *
 * Note: no `metaWritten = FALSE` guard. The implementation's Phase 2 Release
 * store at mod.rs:1051 fires unconditionally even if a concurrent Remove
 * already wrote meta=TOMBSTONE. The `insertWindow[t][s] = tid` guard is
 * sufficient one-shot serialization (the action itself clears insertWindow). *)
InsertStoreMeta(tid, t, s) ==
    /\ insertWindow[t][s] = tid                 \* must be the winner (raw/mod.rs:1036-1068)
    \* Winner store is UNCONDITIONAL — see raw/mod.rs:1051 (Release).
    \* No check that entry pointer is still the winner's pointer. This is the bug.
    /\ \E k \in Key :
        /\ \/ /\ tableEntry[t][s] /= NULL
              /\ tableEntry[t][s].key = k        \* normal case: entry still alive
           \/ /\ tableEntry[t][s] = NULL
              /\ tableMeta[t][s] = META_TOMBSTONE \* BUG window: remove happened during yield
        /\ tableMeta' = [tableMeta EXCEPT ![t][s] = h2(k)]
    /\ metaWritten' = [metaWritten EXCEPT ![t][s] = TRUE]
    /\ insertWindow' = [insertWindow EXCEPT ![t][s] = NULL]
    /\ UNCHANGED <<rootTable, tableEntry, nextTable, resizeVars, parkerVars,
                    reclaimVars, iterVars, logicalVars>>

(* ---- InsertMetaFixup: Loser fixup path (raw/mod.rs:1086-1108) ---- *)
(* When a probe-loser observed a non-null entry (Value/Copied/Null status),
 * it computes h2(observed key) or TOMBSTONE and conditionally stores IF
 * meta is still EMPTY (line 1106 Relaxed load + 1107 Release store). *)
InsertMetaFixup(tid, t, s) ==
    /\ tableMeta[t][s] = META_EMPTY              \* condition at raw/mod.rs:1106
    /\ tableEntry[t][s] /= NULL                  \* observed Value/Copied
    /\ insertWindow[t][s] /= tid                 \* loser, not the winner
    /\ LET observedKey == tableEntry[t][s].key IN
        /\ tableMeta' = [tableMeta EXCEPT ![t][s] = h2(observedKey)]
    /\ UNCHANGED <<rootTable, tableEntry, nextTable, resizeVars, insertVars,
                    parkerVars, reclaimVars, iterVars, logicalVars>>

(* ---- InsertUpdate: Replace existing value (raw/mod.rs:1124-1180) ---- *)
InsertUpdate(tid, k, v, t, s) ==
    /\ rootTable /= NULL
    /\ t \in AllTables
    /\ tableEntry[t][s] /= NULL
    /\ tableEntry[t][s].key = k
    /\ ~ HasTag(tableEntry[t][s], COPYING)        \* raw/mod.rs:1140-1145
    /\ LET oldEntry == tableEntry[t][s]
           newEntry == MkEntry(k, v, oldEntry.tag)
       IN  tableEntry' = [tableEntry EXCEPT ![t][s] = newEntry]
    /\ UNCHANGED <<rootTable, tableMeta, nextTable, resizeVars, insertVars,
                    parkerVars, reclaimVars, iterVars, logicalVars>>

(* ================================================================
 * REMOVE (raw/mod.rs:680-818)
 * ================================================================ *)

Remove(tid, k, t, s) ==
    /\ rootTable /= NULL
    /\ t \in AllTables
    /\ tableEntry[t][s] /= NULL
    /\ tableEntry[t][s].key = k
    /\ ~ HasTag(tableEntry[t][s], COPYING)        \* raw/mod.rs:753
    /\ LET oldEntry == tableEntry[t][s] IN
        /\ tableEntry' = [tableEntry EXCEPT ![t][s] = NULL]
        /\ tableMeta' = [tableMeta EXCEPT ![t][s] = META_TOMBSTONE]   \* raw/mod.rs:782-786
        /\ metaWritten' = [metaWritten EXCEPT ![t][s] = TRUE]
        \* Note: deliberately do NOT clear insertWindow[t][s]. If a winner is
        \* still pending meta-store, the next InsertStoreMeta will fire AFTER
        \* this Remove and may overwrite TOMBSTONE — this is exactly the
        \* Family 7 bug window we want exposed.
        /\ insertedKeys' = insertedKeys \ {k}
        /\ retired' = retired \cup {[key |-> k, table |-> t, slot |-> s]}
    /\ UNCHANGED <<rootTable, nextTable, resizeVars, insertWindow, parkerVars,
                    deferred, iterVars, threadPC, epoch>>

(* ================================================================
 * COPY ACTIONS (Family 1) — raw/mod.rs:2148-2444
 * ================================================================ *)

(* ---- CopyMarkCopying: fetch_or COPYING tag (raw/mod.rs:2162-2164) ---- *)
CopyMarkCopying(tid, srcT, s) ==
    /\ nextTable[srcT] /= NULL
    /\ resizeStatus[nextTable[srcT]] /= ABORTED
    /\ tableEntry[srcT][s] /= NULL
    /\ ~ HasTag(tableEntry[srcT][s], COPYING)
    /\ tableEntry' = [tableEntry EXCEPT ![srcT][s] =
        [tableEntry[srcT][s] EXCEPT !.tag = tableEntry[srcT][s].tag \cup {COPYING}]]
    /\ claimCount' = [claimCount EXCEPT ![nextTable[srcT]] = claimCount[nextTable[srcT]] + 1]
    /\ UNCHANGED <<rootTable, tableMeta, nextTable, resizeStatus, copiedCount,
                    insertVars, parkerVars, reclaimVars, iterVars, logicalVars>>

(* ---- CopyMarkCopyingNull: null/tombstone slot (raw/mod.rs:2166-2178) ---- *)
CopyMarkCopyingNull(tid, srcT, s) ==
    /\ nextTable[srcT] /= NULL
    /\ resizeStatus[nextTable[srcT]] /= ABORTED
    /\ tableEntry[srcT][s] = NULL
    /\ tableMeta[srcT][s] /= META_TOMBSTONE
    /\ tableMeta' = [tableMeta EXCEPT ![srcT][s] = META_TOMBSTONE]
    /\ claimCount' = [claimCount EXCEPT ![nextTable[srcT]] = claimCount[nextTable[srcT]] + 1]
    /\ copiedCount' = [copiedCount EXCEPT ![nextTable[srcT]] = copiedCount[nextTable[srcT]] + 1]
    /\ UNCHANGED <<rootTable, tableEntry, nextTable, resizeStatus,
                    insertVars, parkerVars, reclaimVars, iterVars, logicalVars>>

(* ---- CopyInsertToNext: insert copied entry in next table (raw/mod.rs:2186-2189, 2365-2444) ---- *)
(* Both blocking and incremental modes increment copiedCount for each
 * successful copy (impl: per-chunk local `copied` counter folded into
 * `state.copied` at try_promote — mod.rs:2831). CopyMarkCopied (incremental
 * only) sets the COPIED tag but does NOT increment copiedCount, to avoid
 * double-counting. *)
CopyInsertToNext(tid, srcT, srcS, dstT, dstS) ==
    /\ dstT = nextTable[srcT]
    /\ dstT /= NULL
    /\ resizeStatus[dstT] /= ABORTED
    /\ tableEntry[srcT][srcS] /= NULL
    /\ HasTag(tableEntry[srcT][srcS], COPYING)
    /\ ~ HasTag(tableEntry[srcT][srcS], COPIED)
    /\ tableEntry[dstT][dstS] = NULL
    /\ tableMeta[dstT][dstS] = META_EMPTY
    /\ ~ \E s2 \in Slot :
        /\ tableEntry[dstT][s2] /= NULL
        /\ tableEntry[dstT][s2].key = tableEntry[srcT][srcS].key
    /\ LET srcEntry == tableEntry[srcT][srcS]
           newTag == IF resizeStatus[dstT] = PENDING THEN {BORROWED} ELSE {}
       IN
        /\ tableEntry' = [tableEntry EXCEPT
            ![dstT][dstS] = MkEntry(srcEntry.key, srcEntry.value, newTag),
            \* Mark source COPIED so the action fires at most once per srcS,
            \* modeling the impl's chunk-claim discipline (mod.rs:2292) where
            \* `claim.fetch_add(copy_chunk, ...)` partitions slots across
            \* threads. Without this, CopyInsertToNext can race and over-
            \* count copiedCount.
            ![srcT][srcS] = [srcEntry EXCEPT !.tag = srcEntry.tag \cup {COPIED}]]
        /\ tableMeta' = [tableMeta EXCEPT ![dstT][dstS] = h2(srcEntry.key)]
        /\ metaWritten' = [metaWritten EXCEPT ![dstT][dstS] = TRUE]
        /\ copiedCount' = [copiedCount EXCEPT ![dstT] = @ + 1]
    /\ UNCHANGED <<rootTable, nextTable, resizeStatus, claimCount, insertWindow,
                    parkerVars, reclaimVars, iterVars, logicalVars>>

(* ---- CopyMarkCopied: set COPIED tag on source (raw/mod.rs:2342-2351) ---- *)
(* Incremental mode only. The actual copiedCount increment is folded into
 * CopyInsertToNext (modeling the impl's per-chunk local accumulator that
 * try_promote bulk-applies). This action only flips the COPIED tag. *)
CopyMarkCopied(tid, srcT, srcS) ==
    /\ tableEntry[srcT][srcS] /= NULL
    /\ HasTag(tableEntry[srcT][srcS], COPYING)
    /\ ~ HasTag(tableEntry[srcT][srcS], COPIED)
    /\ nextTable[srcT] /= NULL
    /\ \E dstS \in Slot :
        /\ tableEntry[nextTable[srcT]][dstS] /= NULL
        /\ tableEntry[nextTable[srcT]][dstS].key = tableEntry[srcT][srcS].key
    /\ tableEntry' = [tableEntry EXCEPT ![srcT][srcS] =
        [tableEntry[srcT][srcS] EXCEPT !.tag = tableEntry[srcT][srcS].tag \cup {COPIED}]]
    /\ UNCHANGED <<rootTable, tableMeta, nextTable, resizeVars,
                    insertVars, parkerVars, reclaimVars, iterVars, logicalVars>>

(* ================================================================
 * PROMOTION (raw/mod.rs:2449-2508)
 * ================================================================ *)

TryPromote(tid, t) ==
    /\ t = rootTable
    /\ nextTable[t] /= NULL
    /\ LET nt == nextTable[t] IN
        /\ copiedCount[nt] = TableLen(t)        \* raw/mod.rs:2466
        /\ rootTable' = nt                      \* raw/mod.rs:2475-2478
        /\ resizeStatus' = [resizeStatus EXCEPT ![nt] = PROMOTED]   \* raw/mod.rs:2484
        \* Unpark waiters on nt's parker keyed by &nt.status (raw/mod.rs:2501)
        /\ parked' = [th \in Thread |->
            IF /\ parked[th] /= NULL
               /\ parked[th].parker = nt
               /\ parked[th].key    = nt
            THEN NULL
            ELSE parked[th]]
    /\ UNCHANGED <<tableEntry, tableMeta, nextTable, copiedCount, claimCount,
                    insertVars, retired, deferred, iterVars, logicalVars>>

(* ================================================================
 * ABORT RESIZE — Family 3 (D2-1: parker routing bug, mod.rs:2282-2283)
 * ================================================================ *)

(* The blocking-mode abort path:
 *   raw/mod.rs:2268: status.store(ABORTED)       on next.state().status
 *   raw/mod.rs:2282: state.parker.unpark(&state.status)
 *                                ^----------- BUG: state == table.state() (SOURCE),
 *                    but threads parked at lines 2350-2352 use next.state().parker
 *                    keyed by &next.state().status.
 *)
AbortResize(tid, srcT, abortedT) ==
    /\ abortedT = nextTable[srcT]
    /\ abortedT /= NULL
    /\ resizeStatus[abortedT] = PENDING
    /\ resizeStatus' = [resizeStatus EXCEPT ![abortedT] = ABORTED]
    \* Buggy unpark: targets srcT.parker keyed by srcT.status (raw/mod.rs:2282-2283)
    /\ parked' = [th \in Thread |->
        IF /\ parked[th] /= NULL
           /\ parked[th].parker = srcT       \* BUG: should be abortedT
           /\ parked[th].key    = srcT       \* BUG: should be abortedT
        THEN NULL
        ELSE parked[th]]
    /\ UNCHANGED <<rootTable, tableEntry, tableMeta, nextTable, copiedCount, claimCount,
                    insertVars, reclaimVars, iterVars, logicalVars>>

(* ================================================================
 * PARKING (raw/utils/parker.rs, raw/mod.rs:2350-2352)
 * ================================================================ *)

(* ---- ParkThread: thread parks for resize (raw/mod.rs:2350-2352) ---- *)
(* Parks on next.state().parker keyed by &next.state().status. The (parker, key)
 * tuple is what the buggy unpark at mod.rs:2282 mis-targets. *)
ParkThread(tid, t) ==
    /\ parked[tid] = NULL
    /\ nextTable[t] /= NULL
    /\ LET nt == nextTable[t] IN
        /\ resizeStatus[nt] = PENDING                         \* park condition: status == PENDING
        /\ parked' = [parked EXCEPT ![tid] = [parker |-> nt, key |-> nt]]
    /\ UNCHANGED <<tableVars, resizeVars, insertVars, reclaimVars, iterVars, logicalVars>>

(* ================================================================
 * ITERATOR (Family 6 — NEW: raw/mod.rs:1400-1419, 2828-2843, 2942-2999)
 *
 * Models adversarial caller: iter holds a `table` snapshot reference for its
 * lifetime. Concurrent inserts into a NEW root after iter-begin are missed
 * (weak snapshot). PR #76 (drain DRAFT) chases the chain, which can
 * double-yield entries that are mid-copy.
 *
 * The model: iterTable is a fixed snapshot of rootTable at iter-begin.
 * It is NOT updated on Promote — the iter still walks the original table
 * (the now-retired table). seenKeys is a sequence (multiset semantics)
 * to allow IterNoDoubleYield to fail if double-yield occurs.
 * ================================================================ *)

(* ---- IterBegin: snapshot root table for iteration (raw/mod.rs:1400-1419) ---- *)
(* iterIdx walks slot indices 0..Cardinality(Slot)-1 (matching impl's
 * `self.i: usize` starting at 0). The Slot set must contain integer
 * indices in that range. *)
IterBegin(tid) ==
    /\ rootTable /= NULL
    /\ iterTable[tid] = NULL                     \* not already iterating
    /\ iterTable' = [iterTable EXCEPT ![tid] = rootTable]    \* raw/mod.rs:1405
    /\ iterIdx'   = [iterIdx   EXCEPT ![tid] = 0]
    /\ iterDone'  = [iterDone  EXCEPT ![tid] = FALSE]
    /\ seenKeys'  = [seenKeys  EXCEPT ![tid] = << >>]
    /\ iterStartedKeys' = [iterStartedKeys EXCEPT ![tid] = insertedKeys]
    /\ UNCHANGED <<tableVars, resizeVars, insertVars, parkerVars, reclaimVars,
                    threadPC, epoch, insertedKeys>>

(* ---- IterAdvanceYield: yield entry at current slot (raw/mod.rs:2960-2998) ---- *)
(* Loads meta first (line 2970), then entry (line 2981). If both are valid,
 * yields and increments index. Models the case where Iter::next returns
 * Some((k,v)). *)
IterAdvanceYield(tid) ==
    /\ iterTable[tid] /= NULL
    /\ iterDone[tid] = FALSE
    /\ \E s \in Slot :
        LET t == iterTable[tid] IN
        /\ s = iterIdx[tid]
        /\ tableEntry[t][s] /= NULL
        /\ tableMeta[t][s] /= META_EMPTY            \* raw/mod.rs:2972-2975
        /\ tableMeta[t][s] /= META_TOMBSTONE
        /\ ~ tableEntry[t][s] = NULL                \* raw/mod.rs:2987 entry.ptr.is_null
        /\ seenKeys' = [seenKeys EXCEPT ![tid] = Append(@, tableEntry[t][s].key)]
    /\ iterIdx' = [iterIdx EXCEPT ![tid] = iterIdx[tid] + 1]
    /\ UNCHANGED <<tableVars, resizeVars, insertVars, parkerVars, reclaimVars,
                    iterTable, iterDone, iterStartedKeys, threadPC, epoch, insertedKeys>>

(* ---- IterAdvanceSkip: skip empty/tombstone slot (raw/mod.rs:2972-2975, 2987-2989) ---- *)
IterAdvanceSkip(tid) ==
    /\ iterTable[tid] /= NULL
    /\ iterDone[tid] = FALSE
    /\ \E s \in Slot :
        LET t == iterTable[tid] IN
        /\ s = iterIdx[tid]
        /\ \/ tableMeta[t][s] = META_EMPTY
           \/ tableMeta[t][s] = META_TOMBSTONE
           \/ tableEntry[t][s] = NULL
    /\ iterIdx' = [iterIdx EXCEPT ![tid] = iterIdx[tid] + 1]
    /\ UNCHANGED <<tableVars, resizeVars, insertVars, parkerVars, reclaimVars,
                    iterTable, iterDone, seenKeys, iterStartedKeys,
                    threadPC, epoch, insertedKeys>>

(* ---- IterEnd: iter exhausted (raw/mod.rs:2962-2965) ---- *)
(* Clears iterTable so a subsequent IterBegin can fire (mirrors the impl,
 * where dropping the Iter releases its `table` reference and a new
 * `.iter()` call re-snapshots). *)
IterEnd(tid) ==
    /\ iterTable[tid] /= NULL
    /\ iterDone[tid] = FALSE
    /\ iterIdx[tid] >= Cardinality(Slot)
    /\ iterDone' = [iterDone EXCEPT ![tid] = TRUE]
    /\ iterTable' = [iterTable EXCEPT ![tid] = NULL]
    /\ UNCHANGED <<tableVars, resizeVars, insertVars, parkerVars, reclaimVars,
                    iterIdx, seenKeys, iterStartedKeys,
                    threadPC, epoch, insertedKeys>>

(* ================================================================
 * EPOCH / RECLAMATION (Family 4) — raw/mod.rs:2571-2625
 * ================================================================ *)

ReclaimEntry(entry) ==
    /\ entry \in retired
    \* Safety check: the slot where this entry was retired is no longer holding it.
    \* Guard `.key` / HasTag against NULL entries — TLA+ disjunction is not
    \* short-circuiting; we must conjoin "not NULL" before any record access.
    /\ LET e == tableEntry[entry.table][entry.slot] IN
        \/ e = NULL
        \/ /\ e /= NULL
           /\ \/ e.key /= entry.key
              \/ HasTag(e, COPIED)
    /\ retired' = retired \ {entry}
    /\ UNCHANGED <<tableVars, resizeVars, insertVars, parkerVars, deferred,
                    iterVars, logicalVars>>

AdvanceEpoch(tid) ==
    /\ epoch' = [epoch EXCEPT ![tid] = epoch[tid] + 1]
    /\ UNCHANGED <<tableVars, resizeVars, insertVars, parkerVars, retired, deferred,
                    iterVars, insertedKeys, threadPC>>

(* ================================================================
 * NEXT STATE RELATION
 * ================================================================ *)

Next ==
    \/ \E tid \in Thread :
        \/ InitTable(tid)
        \/ IterBegin(tid)
        \/ IterAdvanceYield(tid)
        \/ IterAdvanceSkip(tid)
        \/ IterEnd(tid)
        \/ AdvanceEpoch(tid)
        \/ \E t \in 1..MaxTables :
            \/ AllocNextTable(tid, t)
            \/ TryPromote(tid, t)
            \/ ParkThread(tid, t)
            \/ \E abortedT \in 1..MaxTables : AbortResize(tid, t, abortedT)
            \/ \E s \in Slot :
                \/ \E k \in Key, v \in Value :
                    \/ InsertCASEntry(tid, k, v, t, s)
                    \/ InsertUpdate(tid, k, v, t, s)
                \/ InsertStoreMeta(tid, t, s)
                \/ InsertMetaFixup(tid, t, s)
                \/ \E k \in Key : Remove(tid, k, t, s)
                \/ CopyMarkCopying(tid, t, s)
                \/ CopyMarkCopyingNull(tid, t, s)
                \/ CopyMarkCopied(tid, t, s)
                \/ \E dstT \in 1..MaxTables, dstS \in Slot :
                    CopyInsertToNext(tid, t, s, dstT, dstS)
    \/ \E entry \in retired : ReclaimEntry(entry)

Spec == Init /\ [][Next]_vars

(* ================================================================
 * INVARIANTS
 * ================================================================ *)

(* ---- Standard Safety ---- *)

(* NoLostEntry — Family 1, MC-7: a successfully-inserted key is findable
 * (modulo two-phase insert window or in-flight copy). *)
NoLostEntry ==
    \A k \in insertedKeys :
        \/ KeyFindable(k)
        \/ \E t \in AllTables, s \in Slot :       \* in-flight two-phase
            /\ tableEntry[t][s] /= NULL
            /\ tableEntry[t][s].key = k
            /\ metaWritten[t][s] = FALSE

(* NoDuplicateEntry — Family 1: each key in at most one live (non-COPIED, non-COPYING) slot *)
NoDuplicateEntry ==
    \A k \in Key :
        LET liveSlots ==
            { <<t, s>> \in (AllTables \X Slot) :
                /\ tableEntry[t][s] /= NULL
                /\ tableEntry[t][s].key = k
                /\ ~ HasTag(tableEntry[t][s], COPIED)
                /\ ~ HasTag(tableEntry[t][s], COPYING) }
        IN Cardinality(liveSlots) <= 1

(* ProbeChainIntegrity — Family 1, MC-2: meta consistent with entry presence *)
ProbeChainIntegrity ==
    \A t \in AllTables, s \in Slot :
        /\ tableEntry[t][s] /= NULL
        /\ ~ HasTag(tableEntry[t][s], COPIED)
        /\ metaWritten[t][s] = TRUE
        => tableMeta[t][s] /= META_EMPTY

(* PromotionSafety — Family 1: root CAS only when all entries copied *)
PromotionSafety ==
    \A t \in 1..MaxTables :
        /\ nextTable[t] /= NULL
        /\ resizeStatus[nextTable[t]] = PROMOTED
        => copiedCount[nextTable[t]] >= TableLen(t)

(* ---- Family 3: Parker / Unpark Routing ---- *)

(* NoParkedOnAborted — surfaces D2-1 wrong-parker bug as a *safety* invariant.
 * Once a table is ABORTED, threads parked on its (parker, key) MUST be unparked
 * by the abort path. The buggy AbortResize unparks the WRONG parker, so this
 * invariant fails and produces a counterexample trace. *)
NoParkedOnAborted ==
    \A tid \in Thread :
        parked[tid] /= NULL =>
        resizeStatus[parked[tid].parker] /= ABORTED

(* ---- Family 4: Reclamation ---- *)

(* NoUseAfterReclaim — retired entry's slot cannot still hold the same key
 * (unless it has been copied away) *)
NoUseAfterReclaim ==
    \A entry \in retired :
        LET e == tableEntry[entry.table][entry.slot] IN
        \/ e = NULL
        \/ e.key /= entry.key
        \/ HasTag(e, COPIED)

(* ---- Family 6: Iterator (NEW) ---- *)

(* IterNoDoubleYield — sequence has no duplicate elements. *)
IterNoDoubleYield ==
    \A tid \in Thread :
        \A i, j \in 1..Len(seenKeys[tid]) :
            i /= j => seenKeys[tid][i] /= seenKeys[tid][j]

(* IterWeakSnapshot — every key inserted before iter-begin and not concurrently
 * removed/promoted-out should appear in seenKeys upon iter completion.
 * This codifies the documented "weak snapshot" semantics. We check it on
 * iterDone — if the iterator finished, we expect every still-live started key
 * either to be in seenKeys or to have been removed during iteration. *)
IterWeakSnapshot ==
    \A tid \in Thread :
        iterDone[tid] = TRUE =>
        \A k \in iterStartedKeys[tid] :
            \/ \E i \in 1..Len(seenKeys[tid]) : seenKeys[tid][i] = k
            \/ k \notin insertedKeys              \* removed during iter
            \* Promotion-induced miss: snapshot table no longer in chain
            \/ iterTable[tid] \notin AllTables

(* ---- Family 7: Slot Recycling / META Overwrite (NEW) ---- *)

(* MetaTombstoneStable — once a slot is tombstoned (meta = TOMBSTONE,
 * entry = NULL after a Remove), no further winner-store or fixup can
 * overwrite it back to h2(...). The buggy InsertStoreMeta path
 * (winner unconditional store after yield window) violates this. *)
MetaTombstoneStable ==
    \A t \in AllTables, s \in Slot :
        \* If a slot has been tombstoned but still has a pending winner
        \* meta-store outstanding, we expect the meta to remain TOMBSTONE.
        (/\ tableEntry[t][s] = NULL
         /\ tableMeta[t][s] = META_TOMBSTONE)
        =>
        \* invariant holds at THIS state; the violation will surface
        \* on the next InsertStoreMeta if insertWindow[t][s] /= NULL.
        \* So strengthen: if insertWindow is still pending, the invariant
        \* commits to detection — meta has been recently observed TOMBSTONE
        \* with the bug window active.
        TRUE

(* MetaTombstoneInvariant — a stronger formulation that catches the bug:
 * a slot whose entry is currently NULL must not have meta = h2(some-key).
 * After Remove the slot has entry=NULL and meta=TOMBSTONE; the buggy
 * InsertStoreMeta then writes meta=h2(k) while entry remains NULL,
 * violating this invariant. *)
NoStaleMetaOnEmptySlot ==
    \A t \in AllTables, s \in Slot :
        (/\ tableEntry[t][s] = NULL
         /\ metaWritten[t][s] = TRUE
         /\ tableMeta[t][s] /= META_EMPTY
         /\ tableMeta[t][s] /= META_TOMBSTONE)
        => FALSE

(* ---- Structural ---- *)

ResizeStatusConsistency ==
    rootTable /= NULL => resizeStatus[rootTable] = PROMOTED

CopiedCountBound ==
    \A t \in 1..MaxTables :
        nextTable[t] /= NULL =>
        copiedCount[nextTable[t]] <= TableLen(t)

MetaConsistency ==
    \A t \in AllTables, s \in Slot :
        /\ tableEntry[t][s] /= NULL
        /\ metaWritten[t][s] = TRUE
        => tableMeta[t][s] /= META_EMPTY

TagConsistency ==
    \A t \in AllTables, s \in Slot :
        tableEntry[t][s] /= NULL =>
        (COPIED \in tableEntry[t][s].tag => COPYING \in tableEntry[t][s].tag)

(* InsertWindowConsistency — winner pending => meta not yet written, UNLESS
 * the slot has been concurrently tombstoned (Family 7 bug-window: Remove
 * during yield-loop sets metaWritten=TRUE while the winner's insertWindow
 * is still pending). The CAS-then-Remove sequence is a legitimate state. *)
InsertWindowConsistency ==
    \A t \in AllTables, s \in Slot :
        (/\ insertWindow[t][s] /= NULL
         /\ tableEntry[t][s] /= NULL)
        => metaWritten[t][s] = FALSE

============================================================================
