------------------------------- MODULE base --------------------------------
(* TLA+ specification for papaya — Lock-Free Concurrent HashMap (Rust)
 *
 * Models the core lock-free hash table protocol:
 *   - Open-addressing with quadratic probing
 *   - Two resize modes: Blocking and Incremental
 *   - 3-bit tagged pointers: COPYING, COPIED, BORROWED
 *   - Two-phase insert (CAS entry, then store metadata)
 *   - Epoch-based deferred retirement
 *   - Thread parking for blocking resize
 *
 * Source: artifact/papaya/src/raw/mod.rs
 *
 * Bug Families targeted:
 *   Family 1: Resize Copy/Insert Race Conditions (HIGH)
 *   Family 2: Memory Ordering Gaps (HIGH)
 *   Family 3: Parker/Synchronization Deadlocks (MEDIUM)
 *   Family 4: Epoch-Based Reclamation Safety (MEDIUM)
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
    META_EMPTY,     \* Slot metadata: empty
    META_TOMBSTONE  \* Slot metadata: deleted entry

(* ================================================================
 * VARIABLES
 * ================================================================ *)

(* --- Core table state --- *)
VARIABLES
    rootTable,          \* Index of the current root table (Nat or NULL)
    tableEntry,         \* tableEntry[t][s] = record of entry at slot s of table t
                        \*   [key: Key, value: Value, tag: subset of {COPYING, COPIED, BORROWED}]
                        \*   or NULL (empty/tombstone)
    tableMeta,          \* tableMeta[t][s] = metadata byte: META_EMPTY | META_TOMBSTONE | h2 value
    nextTable,          \* nextTable[t] = index of next table for resize, or NULL

(* --- Resize state (raw/mod.rs:48-70) --- [Family 1, 3] *)
    resizeStatus,       \* resizeStatus[t] = PENDING | ABORTED | PROMOTED
    copiedCount,        \* copiedCount[t] = number of entries copied to table t
    claimCount,         \* claimCount[t] = number of entries claimed for copying

(* --- Two-phase insert (Family 1: MC-2) --- *)
    metaWritten,        \* metaWritten[t][s] = TRUE iff metadata has been stored after CAS

(* --- Thread parking (raw/utils/parker.rs) --- [Family 3] *)
    parked,             \* parked[thread] = record [table: t, key: k] or NULL
                        \* Tracks which parker and key a thread is parked on

(* --- Epoch-based reclamation (Family 4) --- *)
    retired,            \* Set of {[key: k, table: t, slot: s]} retired but not yet reclaimed
    reachable,          \* reachable[t][s] = TRUE iff entry at slot is reachable from table chain

(* --- Logical map state (for invariants) --- *)
    insertedKeys,       \* Set of keys successfully inserted and not removed
    threadPC,           \* threadPC[t] = thread program counter / operation state
    epoch               \* epoch[thread] = current epoch for the thread (simplified)

(* Variable groups for UNCHANGED *)
tableVars    == <<rootTable, tableEntry, tableMeta, nextTable>>
resizeVars   == <<resizeStatus, copiedCount, claimCount>>
insertVars   == <<metaWritten>>
parkerVars   == <<parked>>
reclaimVars  == <<retired, reachable>>
logicalVars  == <<insertedKeys, threadPC, epoch>>

vars == <<tableVars, resizeVars, insertVars, parkerVars, reclaimVars, logicalVars>>

(* ================================================================
 * HELPERS
 * ================================================================ *)

\* Set of all allocated table indices
Tables == {t \in 1..MaxTables : rootTable /= NULL}

\* Whether a table has a valid next table
HasNextTable(t) == nextTable[t] /= NULL

\* Whether an entry is null/tombstone
IsNull(entry) == entry = NULL

\* Whether an entry has a specific tag bit set
HasTag(entry, tag) ==
    /\ entry /= NULL
    /\ tag \in entry.tag

\* The set of tag bits on an entry
TagOf(entry) == IF entry = NULL THEN {} ELSE entry.tag

\* Create an entry record
MkEntry(k, v, tags) == [key |-> k, value |-> v, tag |-> tags]

\* The chain of tables from root to end
RECURSIVE TableChain(_)
TableChain(t) ==
    IF t = NULL THEN {}
    ELSE {t} \cup TableChain(nextTable[t])

\* Whether a key exists in a specific table (ignoring tags)
KeyInTable(k, t) ==
    \E s \in Slot :
        /\ tableEntry[t][s] /= NULL
        /\ tableEntry[t][s].key = k
        /\ ~ HasTag(tableEntry[t][s], COPIED)  \* COPIED entries are logically in next table

\* Find the slot of a key in a table (or NULL)
SlotOfKey(k, t) ==
    CHOOSE s \in Slot :
        /\ tableEntry[t][s] /= NULL
        /\ tableEntry[t][s].key = k

\* Whether a key is findable via get() from the root
\* Follows the same logic as get() in raw/mod.rs:315-396
KeyFindable(k) ==
    IF rootTable = NULL THEN FALSE
    ELSE \E t \in TableChain(rootTable) :
        \E s \in Slot :
            /\ tableEntry[t][s] /= NULL
            /\ tableEntry[t][s].key = k
            /\ tableMeta[t][s] /= META_EMPTY
            /\ tableMeta[t][s] /= META_TOMBSTONE
            /\ ~ HasTag(tableEntry[t][s], COPIED)
            /\ metaWritten[t][s] = TRUE  \* Family 1 MC-2: meta must be written

\* Number of entries in a table (for copy completion check)
TableLen(t) == Cardinality(Slot)

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
    /\ parked = [t \in Thread |-> NULL]
    /\ retired = {}
    /\ reachable = [t \in 1..MaxTables |-> [s \in Slot |-> FALSE]]
    /\ insertedKeys = {}
    /\ threadPC = [t \in Thread |-> "idle"]
    /\ epoch = [t \in Thread |-> 0]

(* ================================================================
 * ACTIONS
 * ================================================================ *)

(* ---- InitTable: Lazy table initialization (raw/mod.rs:1859-1885) ---- *)
(* Allocates the first table when it doesn't exist yet *)
InitTable(tid) ==
    /\ rootTable = NULL
    /\ \E t \in 1..MaxTables :
        /\ tableEntry[t] = [s \in Slot |-> NULL]  \* fresh table
        /\ rootTable' = t
        /\ resizeStatus' = [resizeStatus EXCEPT ![t] = PROMOTED]
        /\ UNCHANGED <<tableEntry, tableMeta, nextTable, copiedCount, claimCount,
                        insertVars, parkerVars, reclaimVars, logicalVars>>

(* ---- AllocNextTable: Allocate next table for resize (raw/mod.rs:1890-1985) ---- *)
(* Only one thread wins the allocation lock *)
AllocNextTable(tid, t) ==
    /\ rootTable /= NULL
    /\ t \in TableChain(rootTable)
    /\ nextTable[t] = NULL
    /\ \E nt \in 1..MaxTables :
        /\ tableEntry[nt] = [s \in Slot |-> NULL]  \* fresh table
        /\ nt /= t
        /\ nt \notin TableChain(rootTable)  \* prevent cycles in table chain
        /\ nextTable[nt] = NULL              \* no lingering links from prior use
        /\ nextTable' = [nextTable EXCEPT ![t] = nt]
        /\ resizeStatus' = [resizeStatus EXCEPT ![nt] = PENDING]
        /\ copiedCount' = [copiedCount EXCEPT ![nt] = 0]
        /\ claimCount' = [claimCount EXCEPT ![nt] = 0]
        /\ UNCHANGED <<rootTable, tableEntry, tableMeta, insertVars,
                        parkerVars, reclaimVars, logicalVars>>

(* ================================================================
 * INSERT ACTIONS (raw/mod.rs:442-582)
 * Split into two phases for Family 1 MC-2:
 *   Phase 1: CAS entry pointer (insert_at, raw/mod.rs:881-939)
 *   Phase 2: Store metadata byte (insert_at, raw/mod.rs:903-904)
 * ================================================================ *)

(* ---- InsertCASEntry: Phase 1 of two-phase insert (raw/mod.rs:893-907) ---- *)
(* CAS null -> new_entry at an empty slot. Metadata NOT yet written. *)
InsertCASEntry(tid, k, v, t, s) ==
    /\ rootTable /= NULL
    /\ t \in TableChain(rootTable)
    /\ resizeStatus[t] /= ABORTED
    (* Slot must be empty: raw/mod.rs:482 meta == meta::EMPTY *)
    /\ tableMeta[t][s] = META_EMPTY
    /\ tableEntry[t][s] = NULL
    (* Probe chain guarantees key not already in any table: raw/mod.rs:472-582
     * insert_inner traverses the table chain; if key exists anywhere, it updates
     * rather than inserting. CAS at occupied slots reveals existing entries. *)
    /\ ~ \E t2 \in TableChain(rootTable), s2 \in Slot :
        /\ tableEntry[t2][s2] /= NULL
        /\ tableEntry[t2][s2].key = k
    (* CAS null -> entry: raw/mod.rs:894-900 *)
    /\ tableEntry' = [tableEntry EXCEPT ![t][s] = MkEntry(k, v, {})]
    (* Metadata NOT yet written — this is the two-phase gap: raw/mod.rs:903-904 *)
    /\ metaWritten' = [metaWritten EXCEPT ![t][s] = FALSE]
    /\ insertedKeys' = insertedKeys \cup {k}
    /\ UNCHANGED <<rootTable, tableMeta, nextTable, resizeVars,
                    parkerVars, reclaimVars, threadPC, epoch>>

(* ---- InsertStoreMeta: Phase 2 of two-phase insert (raw/mod.rs:903-904) ---- *)
(* Store metadata after entry CAS. Until this completes, get() may miss the entry.
 * No COPYING check: meta store operates on separate atomic (meta byte), not entry pointer.
 * The thread that did insert_cas always completes its meta store. *)
InsertStoreMeta(tid, t, s) ==
    /\ tableEntry[t][s] /= NULL
    /\ metaWritten[t][s] = FALSE
    (* Store h2 metadata: raw/mod.rs:904 meta_entry.store(meta, Ordering::Release) *)
    /\ tableMeta' = [tableMeta EXCEPT ![t][s] = tableEntry[t][s].key]  \* h2 abstracted as key
    /\ metaWritten' = [metaWritten EXCEPT ![t][s] = TRUE]
    /\ UNCHANGED <<rootTable, tableEntry, nextTable, resizeVars,
                    parkerVars, reclaimVars, logicalVars>>

(* ---- InsertUpdate: Replace existing entry value (raw/mod.rs:593-615, 952-985) ---- *)
(* CAS old_entry -> new_entry at a slot that already has the same key *)
InsertUpdate(tid, k, v, t, s) ==
    /\ rootTable /= NULL
    /\ t \in TableChain(rootTable)
    /\ tableEntry[t][s] /= NULL
    /\ tableEntry[t][s].key = k
    (* Entry must not be copying: raw/mod.rs:540-541 *)
    /\ ~ HasTag(tableEntry[t][s], COPYING)
    (* CAS current -> new: raw/mod.rs:964-970 *)
    /\ LET oldEntry == tableEntry[t][s]
           newEntry == MkEntry(k, v, oldEntry.tag)
       IN
        /\ tableEntry' = [tableEntry EXCEPT ![t][s] = newEntry]
        (* Old entry pointer retired: raw/mod.rs:976 defer_retire
         * Not tracked in retired set: key-level model can't distinguish old/new
         * pointer — the key remains live at the same slot. *)
    /\ UNCHANGED <<rootTable, tableMeta, nextTable, resizeVars, insertVars,
                    parkerVars, retired, reachable, logicalVars>>

(* ================================================================
 * REMOVE ACTION (raw/mod.rs:680-818)
 * ================================================================ *)

(* ---- Remove: CAS entry -> TOMBSTONE (raw/mod.rs:769-792) ---- *)
Remove(tid, k, t, s) ==
    /\ rootTable /= NULL
    /\ t \in TableChain(rootTable)
    /\ tableEntry[t][s] /= NULL
    /\ tableEntry[t][s].key = k
    (* Entry must not be copying: raw/mod.rs:753 *)
    /\ ~ HasTag(tableEntry[t][s], COPYING)
    (* CAS entry -> TOMBSTONE: raw/mod.rs:769-770 *)
    /\ LET oldEntry == tableEntry[t][s] IN
        /\ tableEntry' = [tableEntry EXCEPT ![t][s] = NULL]
        (* Store tombstone meta: raw/mod.rs:782-786 *)
        /\ tableMeta' = [tableMeta EXCEPT ![t][s] = META_TOMBSTONE]
        /\ metaWritten' = [metaWritten EXCEPT ![t][s] = TRUE]
        /\ insertedKeys' = insertedKeys \ {k}
        (* Retire old entry: raw/mod.rs:788-789 defer_retire *)
        /\ retired' = retired \cup {[key |-> k, table |-> t, slot |-> s]}
    /\ UNCHANGED <<rootTable, nextTable, resizeVars, parkerVars, reachable,
                    threadPC, epoch>>

(* ================================================================
 * COPY ACTIONS — BLOCKING MODE (raw/mod.rs:2148-2190)
 * Split into: MarkCopying, InsertCopy, MarkCopied
 * Family 1: Resize Copy/Insert Race Conditions
 * ================================================================ *)

(* ---- CopyMarkCopying: Set COPYING tag on source entry (raw/mod.rs:2162-2164) ---- *)
(* fetch_or(Entry::COPYING, AcqRel) — atomically marks entry as being copied *)
CopyMarkCopying(tid, srcT, s) ==
    /\ nextTable[srcT] /= NULL
    /\ resizeStatus[nextTable[srcT]] /= ABORTED
    /\ tableEntry[srcT][s] /= NULL
    /\ ~ HasTag(tableEntry[srcT][s], COPYING)
    (* fetch_or COPYING: raw/mod.rs:2162-2163 *)
    /\ tableEntry' = [tableEntry EXCEPT ![srcT][s] =
        [tableEntry[srcT][s] EXCEPT !.tag = tableEntry[srcT][s].tag \cup {COPYING}]]
    /\ claimCount' = [claimCount EXCEPT ![nextTable[srcT]] = claimCount[nextTable[srcT]] + 1]
    /\ UNCHANGED <<rootTable, tableMeta, nextTable, resizeStatus, copiedCount,
                    insertVars, parkerVars, reclaimVars, logicalVars>>

(* ---- CopyMarkCopyingNull: Mark null/tombstone slot as copying (raw/mod.rs:2166-2178) ---- *)
(* Tombstone or null entries: nothing to copy, mark meta as tombstone *)
CopyMarkCopyingNull(tid, srcT, s) ==
    /\ nextTable[srcT] /= NULL
    /\ resizeStatus[nextTable[srcT]] /= ABORTED
    /\ tableEntry[srcT][s] = NULL
    /\ tableMeta[srcT][s] /= META_TOMBSTONE  \* not already handled
    (* Mark meta tombstone: raw/mod.rs:2176 *)
    /\ tableMeta' = [tableMeta EXCEPT ![srcT][s] = META_TOMBSTONE]
    /\ claimCount' = [claimCount EXCEPT ![nextTable[srcT]] = claimCount[nextTable[srcT]] + 1]
    /\ copiedCount' = [copiedCount EXCEPT ![nextTable[srcT]] = copiedCount[nextTable[srcT]] + 1]
    /\ UNCHANGED <<rootTable, tableEntry, nextTable, resizeStatus,
                    insertVars, parkerVars, reclaimVars, logicalVars>>

(* ---- CopyInsertToNext: Insert copied entry into next table (raw/mod.rs:2186-2189, 2365-2444) ---- *)
(* After marking COPYING, insert into next table at an empty slot *)
CopyInsertToNext(tid, srcT, srcS, dstT, dstS) ==
    /\ dstT = nextTable[srcT]
    /\ dstT /= NULL
    /\ resizeStatus[dstT] /= ABORTED
    /\ tableEntry[srcT][srcS] /= NULL
    /\ HasTag(tableEntry[srcT][srcS], COPYING)
    /\ ~ HasTag(tableEntry[srcT][srcS], COPIED)
    /\ tableEntry[dstT][dstS] = NULL
    /\ tableMeta[dstT][dstS] = META_EMPTY
    (* Only first CAS wins: raw/mod.rs:2396 insert_copy uses CAS, so if key
     * already exists in dst table (from another thread's copy), skip *)
    /\ ~ \E s2 \in Slot :
        /\ tableEntry[dstT][s2] /= NULL
        /\ tableEntry[dstT][s2].key = tableEntry[srcT][srcS].key
    /\ LET srcEntry == tableEntry[srcT][srcS]
           \* In incremental mode, add BORROWED tag: raw/mod.rs:2328
           newTag == IF resizeStatus[dstT] = PENDING THEN {BORROWED} ELSE {}
       IN
        /\ tableEntry' = [tableEntry EXCEPT ![dstT][dstS] =
            MkEntry(srcEntry.key, srcEntry.value, newTag)]
        /\ tableMeta' = [tableMeta EXCEPT ![dstT][dstS] = srcEntry.key]  \* h2 abstracted as key
        /\ metaWritten' = [metaWritten EXCEPT ![dstT][dstS] = TRUE]
    /\ UNCHANGED <<rootTable, nextTable, resizeVars, parkerVars, reclaimVars, logicalVars>>

(* ---- CopyMarkCopied: Set COPIED tag on source (raw/mod.rs:2341-2351) ---- *)
(* After inserting to next, mark source as COPYING|COPIED *)
CopyMarkCopied(tid, srcT, srcS) ==
    /\ tableEntry[srcT][srcS] /= NULL
    /\ HasTag(tableEntry[srcT][srcS], COPYING)
    /\ ~ HasTag(tableEntry[srcT][srcS], COPIED)
    /\ nextTable[srcT] /= NULL
    \* Verify the entry exists in next table (copy completed)
    /\ \E dstS \in Slot :
        /\ tableEntry[nextTable[srcT]][dstS] /= NULL
        /\ tableEntry[nextTable[srcT]][dstS].key = tableEntry[srcT][srcS].key
    (* Store COPYING|COPIED: raw/mod.rs:2342-2351 SeqCst *)
    /\ tableEntry' = [tableEntry EXCEPT ![srcT][srcS] =
        [tableEntry[srcT][srcS] EXCEPT !.tag = tableEntry[srcT][srcS].tag \cup {COPIED}]]
    /\ copiedCount' = [copiedCount EXCEPT ![nextTable[srcT]] = copiedCount[nextTable[srcT]] + 1]
    /\ UNCHANGED <<rootTable, tableMeta, nextTable, resizeStatus, claimCount,
                    insertVars, parkerVars, reclaimVars, logicalVars>>

(* ================================================================
 * PROMOTION (raw/mod.rs:2449-2508)
 * Family 1: PromotionSafety — only promote when all entries copied
 * ================================================================ *)

(* ---- TryPromote: CAS root pointer to next table (raw/mod.rs:2449-2508) ---- *)
TryPromote(tid, t) ==
    /\ t = rootTable
    /\ nextTable[t] /= NULL
    /\ LET nt == nextTable[t] IN
        (* All entries must be copied: raw/mod.rs:2466 copied == table.len() *)
        /\ copiedCount[nt] = TableLen(t)
        (* CAS root: raw/mod.rs:2475-2478 *)
        /\ rootTable' = nt
        (* Store PROMOTED: raw/mod.rs:2484 SeqCst *)
        /\ resizeStatus' = [resizeStatus EXCEPT ![nt] = PROMOTED]
        (* Retire old table: raw/mod.rs:2491-2497 *)
        (* Table retirement tracked implicitly — table no longer in chain *)
        /\ UNCHANGED retired
        (* Unpark waiters: raw/mod.rs:2501 *)
        /\ parked' = [th \in Thread |->
            IF parked[th] /= NULL /\ parked[th].table = nt
            THEN NULL
            ELSE parked[th]]
    /\ UNCHANGED <<tableEntry, tableMeta, nextTable, copiedCount, claimCount,
                    insertVars, reachable, logicalVars>>

(* ================================================================
 * ABORT RESIZE (raw/mod.rs:2060-2078)
 * Family 3: MC-1 — unpark targets wrong parker
 * ================================================================ *)

(* ---- AbortResize: Table full during copy, abort and allocate new (raw/mod.rs:2067-2078) ---- *)
AbortResize(tid, srcT, abortedT) ==
    /\ abortedT = nextTable[srcT]
    /\ abortedT /= NULL
    /\ resizeStatus[abortedT] = PENDING
    (* Store ABORTED: raw/mod.rs:2067 SeqCst *)
    /\ resizeStatus' = [resizeStatus EXCEPT ![abortedT] = ABORTED]
    (* BUG MC-1: raw/mod.rs:2073-2074 unparks table.state().parker with &table.state().status
     * but threads are parked on next.state().parker with &next.state().status (line 2134-2136).
     * We model the BUGGY behavior: unpark on srcT's parker, not abortedT's parker *)
    /\ parked' = [th \in Thread |->
        IF parked[th] /= NULL /\ parked[th].table = srcT  \* BUG: should be abortedT
        THEN NULL
        ELSE parked[th]]
    /\ UNCHANGED <<rootTable, tableEntry, tableMeta, nextTable, copiedCount, claimCount,
                    insertVars, reclaimVars, logicalVars>>

(* ================================================================
 * PARKING (raw/utils/parker.rs, raw/mod.rs:2134-2136)
 * Family 3: Deadlock detection
 * ================================================================ *)

(* ---- ParkThread: Thread parks waiting for resize (raw/mod.rs:2134-2136) ---- *)
(* Threads park on next.state().parker with &next.state().status as key *)
ParkThread(tid, t) ==
    /\ parked[tid] = NULL
    /\ nextTable[t] /= NULL
    /\ LET nt == nextTable[t] IN
        /\ resizeStatus[nt] = PENDING  \* park condition: raw/mod.rs:2136 status == PENDING
        /\ parked' = [parked EXCEPT ![tid] = [table |-> nt, key |-> "status"]]
    /\ UNCHANGED <<tableVars, resizeVars, insertVars, reclaimVars, logicalVars>>

(* ---- UnparkOnPromote: Wake threads when table is promoted (raw/mod.rs:2501) ---- *)
(* This happens inside TryPromote — modeled there *)

(* ================================================================
 * MEMORY ORDERING — FAULT INJECTION (Family 2)
 * Models stale reads due to insufficient memory ordering
 * ================================================================ *)

(* ---- StallBetweenCASandMeta: Delay metadata store (Family 1, MC-2) ---- *)
(* Already modeled by the two-phase split: InsertCASEntry + InsertStoreMeta *)
(* The gap between them is where get() can miss an entry *)

(* ---- StaleRead: Thread reads stale entry/meta (Family 2) ---- *)
(* Modeled implicitly: actions that read tableEntry/tableMeta may see any
 * previously-written value. TLC's interleaving semantics naturally captures
 * this for sequentially-consistent executions. For weaker orderings,
 * we use fault injection in MC spec. *)

(* ================================================================
 * DEFERRED RETIREMENT (raw/mod.rs:2571-2625)
 * Family 4: Epoch-based reclamation safety
 * ================================================================ *)

(* ---- RetireEntry: Entry removed, deferred for reclamation (raw/mod.rs:2571-2625) ---- *)
(* Already modeled in Remove and InsertUpdate via retired set *)

(* ---- ReclaimEntry: Epoch advances, entry reclaimed (simplified) ---- *)
ReclaimEntry(entry) ==
    /\ entry \in retired
    (* Safety check: the specific slot where entry was retired is no longer live *)
    /\ LET e == tableEntry[entry.table][entry.slot] IN
       IF e = NULL THEN TRUE
       ELSE e.key /= entry.key \/ HasTag(e, COPIED)
    /\ retired' = retired \ {entry}
    /\ UNCHANGED <<tableVars, resizeVars, insertVars, parkerVars, reachable, logicalVars>>

(* ---- AdvanceEpoch: Thread advances its epoch (simplified) ---- *)
AdvanceEpoch(tid) ==
    /\ epoch' = [epoch EXCEPT ![tid] = epoch[tid] + 1]
    /\ UNCHANGED <<tableVars, resizeVars, insertVars, parkerVars, retired, reachable,
                    insertedKeys, threadPC>>

(* ================================================================
 * NEXT STATE RELATION
 * ================================================================ *)

Next ==
    \/ \E tid \in Thread :
        \/ InitTable(tid)
        \/ \E t \in 1..MaxTables :
            \/ AllocNextTable(tid, t)
            \/ \E s \in Slot :
                \/ \E k \in Key, v \in Value :
                    \/ InsertCASEntry(tid, k, v, t, s)
                    \/ InsertUpdate(tid, k, v, t, s)
                \/ InsertStoreMeta(tid, t, s)
                \/ \E k \in Key : Remove(tid, k, t, s)
                \/ CopyMarkCopying(tid, t, s)
                \/ CopyMarkCopyingNull(tid, t, s)
                \/ CopyMarkCopied(tid, t, s)
                \/ \E dstT \in 1..MaxTables, dstS \in Slot :
                    CopyInsertToNext(tid, t, s, dstT, dstS)
            \/ TryPromote(tid, t)
            \/ ParkThread(tid, t)
            \/ \E abortedT \in 1..MaxTables :
                AbortResize(tid, t, abortedT)
    \/ \E entry \in retired : ReclaimEntry(entry)
    \/ \E tid \in Thread : AdvanceEpoch(tid)

Spec == Init /\ [][Next]_vars

(* ================================================================
 * INVARIANTS
 * ================================================================ *)

(* ---- Standard Safety ---- *)

(* NoLostEntry: A key that was inserted and not removed is findable via get()
 * Family 1: Core safety property *)
NoLostEntry ==
    \A k \in insertedKeys :
        \/ KeyFindable(k)
        \* Allow transient invisibility during two-phase insert
        \/ \E t \in TableChain(rootTable), s \in Slot :
            /\ tableEntry[t][s] /= NULL
            /\ tableEntry[t][s].key = k
            /\ metaWritten[t][s] = FALSE

(* NoDuplicateEntry: Each key exists in at most one non-transitioning slot
 * Family 1: No duplicate entries across tables
 * Excludes COPIED (logically in next table) and COPYING (being copied) entries *)
NoDuplicateEntry ==
    \A k \in Key :
        LET liveSlots == {<<t, s>> \in (TableChain(rootTable) \X Slot) :
            /\ tableEntry[t][s] /= NULL
            /\ tableEntry[t][s].key = k
            /\ ~ HasTag(tableEntry[t][s], COPIED)
            /\ ~ HasTag(tableEntry[t][s], COPYING)}
        IN Cardinality(liveSlots) <= 1

(* ---- Extension Invariants (Bug Family targeted) ---- *)

(* CopyCompleteness: After promotion, all non-tombstone entries from old table
 * that are still live (in insertedKeys) exist in new table.
 * Post-promotion removes are legitimate — don't require removed keys.
 * Family 1: MC-3, MC-6 *)
CopyCompleteness ==
    \A t \in TableChain(rootTable) :
        /\ nextTable[t] /= NULL
        /\ resizeStatus[nextTable[t]] = PROMOTED
        =>
        \A s \in Slot :
            /\ tableEntry[t][s] /= NULL
            /\ tableEntry[t][s].key \in insertedKeys  \* only check live keys
            =>
            \E ds \in Slot :
                /\ tableEntry[nextTable[t]][ds] /= NULL
                /\ tableEntry[nextTable[t]][ds].key = tableEntry[t][s].key

(* ProbeChainIntegrity: If an entry exists, its metadata allows finding it
 * Family 1: MC-2 *)
ProbeChainIntegrity ==
    \A t \in TableChain(rootTable) :
        \A s \in Slot :
            /\ tableEntry[t][s] /= NULL
            /\ ~ HasTag(tableEntry[t][s], COPIED)
            /\ metaWritten[t][s] = TRUE
            =>
            tableMeta[t][s] /= META_EMPTY

(* PromotionSafety: Root CAS only when all entries copied
 * Family 1 *)
PromotionSafety ==
    \A t \in 1..MaxTables :
        /\ nextTable[t] /= NULL
        /\ resizeStatus[nextTable[t]] = PROMOTED
        =>
        copiedCount[nextTable[t]] >= TableLen(t)

(* NoUseAfterReclaim: A retired entry's specific slot must not still hold that key
 * (unless it was re-inserted at a different slot, which is fine).
 * Family 4: MC-5 *)
NoUseAfterReclaim ==
    \A entry \in retired :
        \* The specific slot where the entry was retired must no longer hold it
        LET e == tableEntry[entry.table][entry.slot] IN
        IF e = NULL THEN TRUE
        ELSE e.key /= entry.key \/ HasTag(e, COPIED)

(* NoDeadlock: No thread is permanently parked (liveness, checked as safety approximation)
 * Family 3: MC-1 *)
NoParkedOnAborted ==
    \A tid \in Thread :
        parked[tid] /= NULL =>
        resizeStatus[parked[tid].table] /= ABORTED

(* ---- Structural Invariants ---- *)

(* ResizeStatusConsistency: Current root must be PROMOTED *)
ResizeStatusConsistency ==
    rootTable /= NULL => resizeStatus[rootTable] = PROMOTED

(* CopiedCountBound: copiedCount never exceeds source table size *)
CopiedCountBound ==
    \A t \in 1..MaxTables :
        nextTable[t] /= NULL =>
        copiedCount[nextTable[t]] <= TableLen(t)

(* MetaConsistency: Non-empty entry has non-EMPTY metadata after write *)
MetaConsistency ==
    \A t \in 1..MaxTables, s \in Slot :
        /\ tableEntry[t][s] /= NULL
        /\ metaWritten[t][s] = TRUE
        => tableMeta[t][s] /= META_EMPTY

(* TagConsistency: COPIED implies COPYING *)
TagConsistency ==
    \A t \in 1..MaxTables, s \in Slot :
        tableEntry[t][s] /= NULL =>
        (COPIED \in tableEntry[t][s].tag => COPYING \in tableEntry[t][s].tag)

============================================================================
