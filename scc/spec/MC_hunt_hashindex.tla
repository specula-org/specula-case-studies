------------------------------ MODULE MC_hunt_hashindex ------------------------------
(*
 * Focused model for HashIndex lock-free read + per-entry resize migration.
 *
 * Key differences from base spec:
 *   1. RelocateBucket is split into per-entry ExtractEntry actions
 *   2. LockFreeRead action doesn't require a lock (models HashIndex peek_entry)
 *   3. OOM can occur during entry migration (allocation failure)
 *   4. EntryRemoval + epoch-based garbage collection of individual entries
 *
 * Bug hypotheses:
 *   MC-6: Lock-free read misses entry during partial migration
 *   TV-1: OOM during resize causes duplicate or lost entry
 *   MC-8: Garbage chain race (memory leak)
 *)
EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS
    Thread,          \* Set of threads
    Key,             \* Set of keys
    MaxArrays        \* Max bucket arrays

CONSTANTS
    NullArray,
    MaxResizes,
    MaxEpochAdvances,
    MaxRemoves,
    MaxOOMFaults

\* ---------------------------------------------------------------
\* Variables
\* ---------------------------------------------------------------

\* Core hash table state
VARIABLES
    currentArray,       \* Current (newest) bucket array
    linkedArray,        \* linkedArray[a] = old array linked from a
    entryLoc,           \* entryLoc[k] \subseteq ArrayId — where key k physically resides
    inserted,           \* Keys currently logically inserted
    bucketKilled        \* bucketKilled[a] \in BOOLEAN — old array bucket killed

\* Per-entry migration state
VARIABLES
    migrating,          \* migrating[a] \in BOOLEAN — migration in progress for array a
    migrateProgress,    \* migrateProgress[a] \subseteq Key — entries already migrated from a
    migrateThread       \* migrateThread[a] — which thread is migrating array a (or 0)

\* Lock-free reader state (HashIndex peek_entry)
VARIABLES
    rPC,                \* rPC[t] \in {"idle", "search_old", "search_new", "found", "not_found"}
    rSearchKey,         \* rSearchKey[t] — which key the reader is searching for
    rSearchArray,       \* rSearchArray[t] — which array the reader loaded as current
    rLinkedArray,       \* rLinkedArray[t] — which old array the reader loaded as linked
    rFoundIn            \* rFoundIn[t] — where the reader found the entry (or NullArray)

\* Entry removal (mark_removed + clear_unreachable)
VARIABLES
    removed,            \* removed \subseteq Key — keys marked removed (not yet GC'd)
    removedEpoch        \* removedEpoch[k] \in 0..3 — epoch when key was removed

\* EBR state
VARIABLES
    globalEpoch,
    threadEpoch,        \* threadEpoch[t] — epoch announced by thread t's guard
    guardActive,        \* guardActive[t] \in BOOLEAN
    retiredAt,          \* retiredAt[a] \in 0..3 \cup {-1}
    reclaimed           \* reclaimed \subseteq ArrayId

\* Counters
VARIABLES
    nextArrayId,
    resizeCount,
    epochAdvanceCount,
    removeCount,
    oomFaultCount

\* ---------------------------------------------------------------
\* Helpers
\* ---------------------------------------------------------------
ArrayId == 1..MaxArrays
IsLive(a) == a /= NullArray /\ a \notin reclaimed

InSameGeneration(e1, e2) ==
    LET diff == (e2 - e1 + 4) % 4
    IN diff <= 1 \/ diff >= 3

\* An entry is "visible" to a lock-free reader in array a
\* if the entry is physically in a AND a is live AND entry is not removed
IsVisibleIn(k, a) ==
    /\ a \in entryLoc[k]
    /\ IsLive(a)
    /\ k \notin removed

\* An entry is findable by at least one reader path
\* peek_entry searches: old (linked) array FIRST, then current array
\* Also handles retry if currentArray changed
IsFindable(k) ==
    \/ k \notin inserted
    \/ \E a \in entryLoc[k] : IsLive(a) /\ k \notin removed

\* ---------------------------------------------------------------
\* Variable groups
\* ---------------------------------------------------------------
coreVars == <<currentArray, linkedArray, entryLoc, inserted, bucketKilled>>
migrateVars == <<migrating, migrateProgress, migrateThread>>
readerVars == <<rPC, rSearchKey, rSearchArray, rLinkedArray, rFoundIn>>
removeVars == <<removed, removedEpoch>>
ebrVars == <<globalEpoch, threadEpoch, guardActive, retiredAt, reclaimed>>
counterVars == <<nextArrayId, resizeCount, epochAdvanceCount, removeCount, oomFaultCount>>

vars == <<coreVars, migrateVars, readerVars, removeVars, ebrVars, counterVars>>

\* ---------------------------------------------------------------
\* Init
\* ---------------------------------------------------------------
Init ==
    /\ currentArray = 1
    /\ linkedArray = [a \in ArrayId |-> NullArray]
    /\ entryLoc = [k \in Key |-> {}]
    /\ inserted = {}
    /\ bucketKilled = [a \in ArrayId |-> FALSE]
    /\ migrating = [a \in ArrayId |-> FALSE]
    /\ migrateProgress = [a \in ArrayId |-> {}]
    /\ migrateThread = [a \in ArrayId |-> 0]
    /\ rPC = [t \in Thread |-> "idle"]
    /\ rSearchKey = [t \in Thread |-> CHOOSE k \in Key : TRUE]
    /\ rSearchArray = [t \in Thread |-> NullArray]
    /\ rLinkedArray = [t \in Thread |-> NullArray]
    /\ rFoundIn = [t \in Thread |-> NullArray]
    /\ removed = {}
    /\ removedEpoch = [k \in Key |-> 0]
    /\ globalEpoch = 0
    /\ threadEpoch = [t \in Thread |-> 0]
    /\ guardActive = [t \in Thread |-> FALSE]
    /\ retiredAt = [a \in ArrayId |-> -1]
    /\ reclaimed = {}
    /\ nextArrayId = 2
    /\ resizeCount = 0
    /\ epochAdvanceCount = 0
    /\ removeCount = 0
    /\ oomFaultCount = 0

\* ---------------------------------------------------------------
\* Actions: Guard Management
\* ---------------------------------------------------------------
CreateGuard(t) ==
    /\ rPC[t] = "idle"
    /\ ~guardActive[t]
    /\ guardActive' = [guardActive EXCEPT ![t] = TRUE]
    /\ threadEpoch' = [threadEpoch EXCEPT ![t] = globalEpoch]
    /\ UNCHANGED <<coreVars, migrateVars, readerVars, removeVars,
                    globalEpoch, retiredAt, reclaimed, counterVars>>

DropGuard(t) ==
    /\ guardActive[t]
    /\ rPC[t] = "idle"
    /\ guardActive' = [guardActive EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<coreVars, migrateVars, readerVars, removeVars,
                    globalEpoch, threadEpoch, retiredAt, reclaimed, counterVars>>

\* ---------------------------------------------------------------
\* Actions: Insert / Remove
\* ---------------------------------------------------------------
InsertKey(t, k) ==
    /\ rPC[t] = "idle"
    /\ guardActive[t]
    /\ k \notin inserted
    /\ IsLive(currentArray)
    /\ inserted' = inserted \cup {k}
    /\ entryLoc' = [entryLoc EXCEPT ![k] = {currentArray}]
    /\ UNCHANGED <<currentArray, linkedArray, bucketKilled, migrateVars,
                    readerVars, removeVars, ebrVars, counterVars>>

RemoveKey(t, k) ==
    /\ rPC[t] = "idle"
    /\ guardActive[t]
    /\ k \in inserted
    /\ k \notin removed
    /\ removeCount < MaxRemoves
    \* mark_removed: set removed_bitmap, store epoch in partial_hash_array
    /\ removed' = removed \cup {k}
    /\ removedEpoch' = [removedEpoch EXCEPT ![k] = globalEpoch]
    /\ removeCount' = removeCount + 1
    \* Key stays in inserted and entryLoc (data not dropped yet)
    /\ UNCHANGED <<coreVars, migrateVars, readerVars,
                    ebrVars, nextArrayId, resizeCount, epochAdvanceCount, oomFaultCount>>

\* GC removed entries: clear_unreachable_entries
\* Only if entry's removal epoch is not in same generation as current
GarbageCollectEntry(t, k) ==
    /\ rPC[t] = "idle"
    /\ guardActive[t]
    /\ k \in removed
    /\ ~InSameGeneration(removedEpoch[k], globalEpoch)
    \* Drop the entry: clear from inserted and entryLoc
    /\ inserted' = inserted \ {k}
    /\ entryLoc' = [entryLoc EXCEPT ![k] = {}]
    /\ removed' = removed \ {k}
    /\ UNCHANGED <<currentArray, linkedArray, bucketKilled, migrateVars,
                    readerVars, removedEpoch, ebrVars, counterVars>>

\* ---------------------------------------------------------------
\* Actions: Resize + Per-Entry Migration
\* ---------------------------------------------------------------

\* Trigger resize: allocate new array, link old
TriggerResize(t) ==
    /\ rPC[t] = "idle"
    /\ guardActive[t]
    /\ resizeCount < MaxResizes
    /\ nextArrayId <= MaxArrays
    /\ linkedArray[currentArray] = NullArray
    /\ ~migrating[currentArray]
    /\ LET newArray == nextArrayId
       IN /\ currentArray' = newArray
          /\ linkedArray' = [linkedArray EXCEPT ![newArray] = currentArray]
          /\ bucketKilled' = [bucketKilled EXCEPT ![currentArray] = FALSE]
          /\ migrating' = [migrating EXCEPT ![currentArray] = TRUE]
          /\ migrateProgress' = [migrateProgress EXCEPT ![currentArray] = {}]
          /\ migrateThread' = [migrateThread EXCEPT ![currentArray] = t]
          /\ nextArrayId' = nextArrayId + 1
          /\ resizeCount' = resizeCount + 1
    /\ UNCHANGED <<entryLoc, inserted, readerVars, removeVars, ebrVars,
                    epochAdvanceCount, removeCount, oomFaultCount>>

\* Extract a single entry from old array to new array
\* (hash_table.rs relocate_bucket → bucket.rs extract_from)
\* Order in code: insert_new → clear_old_occupied
ExtractEntry(t, k, oldArray) ==
    /\ rPC[t] = "idle"
    /\ guardActive[t]
    /\ migrating[oldArray]
    /\ k \in inserted
    /\ k \notin removed
    /\ oldArray \in entryLoc[k]
    /\ k \notin migrateProgress[oldArray]
    \* Find the new array that links to oldArray
    /\ \E newArray \in ArrayId :
        /\ linkedArray[newArray] = oldArray
        /\ IsLive(newArray)
        \* Step 1+2: copy to new, clear from old (modeled as atomic pair)
        \* In code: self.insert() then from_writer.occupied_bitmap.store()
        /\ entryLoc' = [entryLoc EXCEPT ![k] =
            (entryLoc[k] \ {oldArray}) \cup {newArray}]
    /\ migrateProgress' = [migrateProgress EXCEPT ![oldArray] =
        migrateProgress[oldArray] \cup {k}]
    /\ UNCHANGED <<currentArray, linkedArray, inserted, bucketKilled,
                    migrating, migrateThread, readerVars, removeVars,
                    ebrVars, counterVars>>

\* OOM variant: allocation fails during insert into new bucket
\* Entry stays in old array (not moved)
\* (hash_table.rs relocate_bucket: if reserve_slots fails, entry not moved)
ExtractEntryOOM(t, k, oldArray) ==
    /\ rPC[t] = "idle"
    /\ guardActive[t]
    /\ migrating[oldArray]
    /\ k \in inserted
    /\ k \notin removed
    /\ oldArray \in entryLoc[k]
    /\ k \notin migrateProgress[oldArray]
    /\ oomFaultCount < MaxOOMFaults
    \* OOM: entry stays in old, but marked as "attempted"
    \* In the real code, the entry stays in old bucket
    /\ migrateProgress' = [migrateProgress EXCEPT ![oldArray] =
        migrateProgress[oldArray] \cup {k}]
    /\ oomFaultCount' = oomFaultCount + 1
    \* Entry NOT moved — stays only in old array
    /\ UNCHANGED <<coreVars, migrating, migrateThread, readerVars,
                    removeVars, ebrVars, nextArrayId, resizeCount,
                    epochAdvanceCount, removeCount>>

\* Complete migration: kill old bucket, prepare for finalize
CompleteMigration(t, oldArray) ==
    /\ rPC[t] = "idle"
    /\ guardActive[t]
    /\ migrating[oldArray]
    \* All entries have been processed (moved or OOM-skipped)
    /\ \A k \in Key :
        (k \in inserted /\ k \notin removed /\ oldArray \in entryLoc[k])
        => k \in migrateProgress[oldArray]
    /\ bucketKilled' = [bucketKilled EXCEPT ![oldArray] = TRUE]
    /\ migrating' = [migrating EXCEPT ![oldArray] = FALSE]
    /\ migrateThread' = [migrateThread EXCEPT ![oldArray] = 0]
    /\ UNCHANGED <<currentArray, linkedArray, entryLoc, inserted,
                    migrateProgress, readerVars, removeVars, ebrVars, counterVars>>

\* Finalize resize: unlink old array, defer reclaim
FinalizeResize(t, oldArray) ==
    /\ rPC[t] = "idle"
    /\ guardActive[t]
    /\ bucketKilled[oldArray]
    /\ ~migrating[oldArray]
    /\ \E newArray \in ArrayId :
        /\ linkedArray[newArray] = oldArray
        /\ linkedArray' = [linkedArray EXCEPT ![newArray] = NullArray]
    /\ retiredAt' = [retiredAt EXCEPT ![oldArray] = globalEpoch]
    /\ UNCHANGED <<currentArray, entryLoc, inserted, bucketKilled,
                    migrateVars, readerVars, removeVars,
                    globalEpoch, threadEpoch, guardActive, reclaimed, counterVars>>

\* ---------------------------------------------------------------
\* Actions: HashIndex Lock-Free Read (peek_entry)
\* No lock required! This is the key difference from HashMap.
\* Search order: old (linked) array FIRST, then current array.
\* Retry if currentArray changed.
\* (hash_table.rs:224-261 peek_entry)
\* ---------------------------------------------------------------

\* Begin lock-free read: load currentArray and linkedArray
BeginLockFreeRead(t, k) ==
    /\ rPC[t] = "idle"
    /\ guardActive[t]
    /\ k \in inserted
    /\ k \notin removed
    /\ IsLive(currentArray)
    /\ rPC' = [rPC EXCEPT ![t] =
        IF linkedArray[currentArray] /= NullArray
        THEN "search_old"
        ELSE "search_new"]
    /\ rSearchKey' = [rSearchKey EXCEPT ![t] = k]
    /\ rSearchArray' = [rSearchArray EXCEPT ![t] = currentArray]
    /\ rLinkedArray' = [rLinkedArray EXCEPT ![t] = linkedArray[currentArray]]
    /\ rFoundIn' = [rFoundIn EXCEPT ![t] = NullArray]
    /\ UNCHANGED <<coreVars, migrateVars, removeVars, ebrVars, counterVars>>

\* Search old (linked) array — lock-free bitmap check
\* (bucket.rs:694-696 search_data_block for INDEX type)
SearchOldArray(t) ==
    /\ rPC[t] = "search_old"
    /\ LET k == rSearchKey[t]
           oldArr == rLinkedArray[t]
       IN IF /\ oldArr /= NullArray
             /\ IsLive(oldArr)
             /\ k \in inserted
             /\ k \notin removed
             /\ oldArr \in entryLoc[k]
          THEN \* Found in old array
               /\ rPC' = [rPC EXCEPT ![t] = "found"]
               /\ rFoundIn' = [rFoundIn EXCEPT ![t] = oldArr]
          ELSE \* Not found in old, proceed to search new
               /\ rPC' = [rPC EXCEPT ![t] = "search_new"]
               /\ rFoundIn' = rFoundIn
    /\ UNCHANGED <<coreVars, migrateVars, rSearchKey, rSearchArray, rLinkedArray,
                    removeVars, ebrVars, counterVars>>

\* Search current (new) array — lock-free bitmap check
SearchNewArray(t) ==
    /\ rPC[t] = "search_new"
    /\ LET k == rSearchKey[t]
           curArr == rSearchArray[t]
           foundHere == /\ IsLive(curArr)
                        /\ k \in inserted
                        /\ k \notin removed
                        /\ curArr \in entryLoc[k]
       IN IF foundHere
          THEN \* Found in current array
               /\ rPC' = [rPC EXCEPT ![t] = "found"]
               /\ rFoundIn' = [rFoundIn EXCEPT ![t] = curArr]
               /\ UNCHANGED <<rSearchArray, rLinkedArray>>
          ELSE \* Not found — check if currentArray changed (retry)
               IF currentArray /= curArr
               THEN \* Array changed during search, retry
                    /\ rPC' = [rPC EXCEPT ![t] =
                        IF linkedArray[currentArray] /= NullArray
                        THEN "search_old"
                        ELSE "search_new"]
                    /\ rSearchArray' = [rSearchArray EXCEPT ![t] = currentArray]
                    /\ rLinkedArray' = [rLinkedArray EXCEPT ![t] = linkedArray[currentArray]]
                    /\ rFoundIn' = rFoundIn
               ELSE \* Array didn't change, truly not found
                    /\ rPC' = [rPC EXCEPT ![t] = "not_found"]
                    /\ rFoundIn' = rFoundIn
                    /\ UNCHANGED <<rSearchArray, rLinkedArray>>
    /\ UNCHANGED <<coreVars, migrateVars, rSearchKey, removeVars, ebrVars, counterVars>>

\* End lock-free read (found or not found)
EndLockFreeRead(t) ==
    /\ rPC[t] \in {"found", "not_found"}
    /\ rPC' = [rPC EXCEPT ![t] = "idle"]
    /\ rSearchArray' = [rSearchArray EXCEPT ![t] = NullArray]
    /\ rLinkedArray' = [rLinkedArray EXCEPT ![t] = NullArray]
    /\ rFoundIn' = [rFoundIn EXCEPT ![t] = NullArray]
    /\ UNCHANGED <<rSearchKey, coreVars, migrateVars, removeVars, ebrVars, counterVars>>

\* ---------------------------------------------------------------
\* Actions: EBR
\* ---------------------------------------------------------------
AdvanceEpoch ==
    /\ epochAdvanceCount < MaxEpochAdvances
    /\ \A t \in Thread : guardActive[t] => threadEpoch[t] = globalEpoch
    /\ globalEpoch' = (globalEpoch + 1) % 4
    /\ epochAdvanceCount' = epochAdvanceCount + 1
    /\ UNCHANGED <<coreVars, migrateVars, readerVars, removeVars,
                    threadEpoch, guardActive, retiredAt, reclaimed,
                    nextArrayId, resizeCount, removeCount, oomFaultCount>>

ReclaimArray(a) ==
    /\ a \in ArrayId
    /\ retiredAt[a] >= 0
    /\ a \notin reclaimed
    /\ ~InSameGeneration(retiredAt[a], globalEpoch)
    /\ reclaimed' = reclaimed \cup {a}
    /\ UNCHANGED <<coreVars, migrateVars, readerVars, removeVars,
                    globalEpoch, threadEpoch, guardActive, retiredAt, counterVars>>

\* ---------------------------------------------------------------
\* Next-state relation
\* ---------------------------------------------------------------
Next ==
    \/ \E t \in Thread :
        \/ CreateGuard(t)
        \/ DropGuard(t)
        \/ \E k \in Key :
            \/ InsertKey(t, k)
            \/ RemoveKey(t, k)
            \/ GarbageCollectEntry(t, k)
            \/ BeginLockFreeRead(t, k)
            \/ \E a \in ArrayId :
                \/ ExtractEntry(t, k, a)
                \/ ExtractEntryOOM(t, k, a)
        \/ SearchOldArray(t)
        \/ SearchNewArray(t)
        \/ EndLockFreeRead(t)
        \/ TriggerResize(t)
        \/ \E a \in ArrayId :
            \/ CompleteMigration(t, a)
            \/ FinalizeResize(t, a)
    \/ AdvanceEpoch
    \/ \E a \in ArrayId : ReclaimArray(a)

Spec == Init /\ [][Next]_vars

\* ---------------------------------------------------------------
\* Invariants
\* ---------------------------------------------------------------

\* CRITICAL: Every inserted, non-removed key must be findable
\* by the lock-free read protocol (search old then new)
EntryReachability ==
    \A k \in inserted :
        k \notin removed => \E a \in entryLoc[k] : IsLive(a)

\* Lock-free reader must not report "found" for a removed entry
NoRemovedVisible ==
    \A t \in Thread :
        rPC[t] = "found" => rFoundIn[t] \notin reclaimed

\* Lock-free reader must not report "not_found" for an
\* inserted, non-removed key
\* THIS IS THE KEY INVARIANT: can migration cause a lock-free
\* reader to miss an entry?
LockFreeReadCompleteness ==
    \A t \in Thread :
        LET k == rSearchKey[t] IN
        (rPC[t] = "not_found" /\ k \in inserted /\ k \notin removed)
        => ~(\E a \in entryLoc[k] : IsLive(a))

\* After OOM, entry must still be reachable in old array
OOMSafety ==
    \A k \in inserted :
        k \notin removed => \E a \in entryLoc[k] : IsLive(a)

\* No non-removed entry in a reclaimed array
NoEntryInReclaimed ==
    \A k \in inserted :
        k \notin removed =>
            \A a \in reclaimed : a \notin entryLoc[k]

\* Current array is always live
CurrentArrayLive == IsLive(currentArray)

\* EBR safety: no thread is actively reading a reclaimed array
EBRSafety ==
    \A a \in reclaimed :
        \A t \in Thread :
            /\ rSearchArray[t] /= a
            /\ rLinkedArray[t] /= a
            /\ rFoundIn[t] /= a

\* ---------------------------------------------------------------
\* Symmetry
\* ---------------------------------------------------------------
Symmetry == Permutations(Thread) \union Permutations(Key)

=============================================================================
