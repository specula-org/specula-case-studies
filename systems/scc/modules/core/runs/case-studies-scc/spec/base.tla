--------------------------- MODULE base ---------------------------
(*
 * TLA+ specification for scc (scalable-concurrent-containers) HashMap
 * Models: HashMap resize + concurrent read/write + EBR interaction
 *
 * Source: https://github.com/wvwwvwwv/scalable-concurrent-containers
 * Key files:
 *   - artifact/scc/src/hash_table.rs (resize protocol, read/write paths)
 *   - artifact/scc/src/hash_table/bucket.rs (bucket locking, entry storage)
 *   - artifact/scc/src/hash_table/bucket_array.rs (array chain)
 *   - artifact/scc/src/hash_index.rs (lock-free reads, garbage chain)
 *
 * Bug Families modeled:
 *   F1: Guard/Lock Lifetime vs Data Access Window (CRITICAL)
 *   F2: Async Reference Invalidation / ABA (HIGH)
 *   F3: Incremental Resize Protocol Correctness (HIGH)
 *   F5: EBR Epoch Advancement + Garbage Reclamation Timing (MEDIUM)
 *)
EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS
    Thread,          \* Set of threads
    Key,             \* Set of keys (abstract)
    Bucket,          \* Set of bucket indices
    MaxArrays        \* Max number of bucket arrays that can exist

CONSTANTS
    NullArray,       \* Sentinel: no array
    NullKey          \* Sentinel: no key

\* ---------------------------------------------------------------
\* Variables
\* ---------------------------------------------------------------

\* --- Core hash table state ---
VARIABLES
    currentArray,       \* Current (newest) bucket array ID ∈ ArrayId ∪ {NullArray}
    linkedArray,        \* linkedArray[a] = old array linked from a, or NullArray
                        \* (hash_table/bucket_array.rs:20 linked_array field)
    entryLocation,      \* entryLocation[k] ⊆ ArrayId — which arrays contain key k
                        \* (models entry being in old, new, or both arrays during resize)
    bucketState,        \* bucketState[a][b] ∈ {"active", "locked", "killed"}
                        \* (bucket.rs:740-842 Writer lock / kill)
    inserted            \* inserted ⊆ Key — keys that have been inserted and not removed

VARIABLES
    rehashProgress,     \* rehashProgress[a] ∈ Nat — next bucket to rehash in array a
                        \* (hash_table.rs:1098 num_cleared_buckets upper bits)
    rehashActive        \* rehashActive[a] ∈ Nat — ref count of threads rehashing array a
                        \* (hash_table.rs:1098 num_cleared_buckets lower bits)

\* --- Extension: Guard/Lock Lifetime (F1) ---
VARIABLES
    guardActive,        \* guardActive[t] ∈ BOOLEAN — thread t holds an EBR guard
                        \* (collector.rs:126 new_guard / :193 end_guard)
    lockHeld,           \* lockHeld[t] ∈ {NoLock} ∪ (ArrayId × Bucket)
                        \* — which (array, bucket) thread t holds a lock on
                        \* (bucket.rs:758 lock_sync / :870 share_sync)
    accessingData       \* accessingData[t] ∈ BOOLEAN — thread t is inside user callback
                        \* (hash_table.rs:306 reader_sync callback scope)

\* --- Extension: Async Reference Invalidation (F2) ---
VARIABLES
    asyncStep,          \* asyncStep[t] ∈ {"idle", "loaded_ref", "awaiting", "ref_checked", "operating"}
                        \* Models async operation phases with interleaving
                        \* (hash_table.rs:266-301 reader_async control flow)
    seenArray           \* seenArray[t] ∈ ArrayId ∪ {NullArray}
                        \* The array reference thread t loaded before await
                        \* (async_helper.rs:62 load_unchecked)

\* --- Extension: EBR Reclamation (F5) ---
VARIABLES
    globalEpoch,        \* globalEpoch ∈ 0..3 — global epoch counter (4 generations)
                        \* (epoch.rs:56 Epoch type, 2-bit generation)
    threadEpoch,        \* threadEpoch[t] ∈ 0..3 — epoch announced by thread t
                        \* (collector.rs:126 new_guard announces epoch)
    retiredAt,          \* retiredAt[a] ∈ 0..3 ∪ {-1} — epoch when array a was retired
                        \* (-1 means not retired)
                        \* (hash_index.rs:1378 garbage_epoch)
    reclaimed           \* reclaimed ⊆ ArrayId — arrays that have been deallocated
                        \* (hash_index.rs:1191-1218 dealloc_garbage)

\* --- Auxiliary ---
VARIABLES
    nextArrayId,        \* Counter for allocating new array IDs
    pc                  \* pc[t] — thread program counter for multi-step operations

\* Variable groups for UNCHANGED
coreVars    == <<currentArray, linkedArray, entryLocation, bucketState, inserted>>
resizeVars  == <<rehashProgress, rehashActive>>
guardVars   == <<guardActive, lockHeld, accessingData>>
asyncVars   == <<asyncStep, seenArray>>
ebrVars     == <<globalEpoch, threadEpoch, retiredAt, reclaimed>>
auxVars     == <<nextArrayId, pc>>

vars == <<coreVars, resizeVars, guardVars, asyncVars, ebrVars, auxVars>>

\* ---------------------------------------------------------------
\* Type definitions
\* ---------------------------------------------------------------
ArrayId == 1..MaxArrays

PCStates == {"idle", "reading", "writing", "rehashing", "async_read",
             "dedup", "resize_trigger", "resize_finalize"}

\* Sentinel for "no lock held" — must be a tuple to match lock values
NoLock == <<0, 0>>

\* ---------------------------------------------------------------
\* Helpers
\* ---------------------------------------------------------------

\* Hash function: maps key to bucket (abstract — just picks a bucket)
Hash(k, arraySize) == (k % arraySize) + 1

\* Whether array a is live (not reclaimed)
IsLive(a) == a \notin reclaimed /\ a /= NullArray

\* Whether a key is findable by at least one reader path
\* (hash_table.rs:224 peek_entry searches current then linked)
IsFindable(k) ==
    \/ k \notin inserted
    \/ \E a \in entryLocation[k] : IsLive(a)

\* Whether two epochs are in the same generation
\* (epoch.rs:56 in_same_generation — within 2 epochs)
InSameGeneration(e1, e2) ==
    LET diff == (e2 - e1 + 4) % 4
    IN diff <= 1 \/ diff >= 3   \* i.e., diff ∈ {0, 1, 3} (mod 4)

\* ---------------------------------------------------------------
\* Init
\* ---------------------------------------------------------------
Init ==
    \* Core: one initial array, all buckets active, no entries
    /\ currentArray = 1
    /\ linkedArray = [a \in ArrayId |-> NullArray]
    /\ entryLocation = [k \in Key |-> {}]
    /\ bucketState = [a \in ArrayId |-> [b \in Bucket |-> "active"]]
    /\ inserted = {}
    \* Resize: no rehash in progress
    /\ rehashProgress = [a \in ArrayId |-> 0]
    /\ rehashActive = [a \in ArrayId |-> 0]
    \* Guard/Lock (F1): all idle
    /\ guardActive = [t \in Thread |-> FALSE]
    /\ lockHeld = [t \in Thread |-> NoLock]
    /\ accessingData = [t \in Thread |-> FALSE]
    \* Async (F2): all idle
    /\ asyncStep = [t \in Thread |-> "idle"]
    /\ seenArray = [t \in Thread |-> NullArray]
    \* EBR (F5): epoch 0, nothing retired
    /\ globalEpoch = 0
    /\ threadEpoch = [t \in Thread |-> 0]
    /\ retiredAt = [a \in ArrayId |-> -1]
    /\ reclaimed = {}
    \* Aux
    /\ nextArrayId = 2   \* array 1 already allocated
    /\ pc = [t \in Thread |-> "idle"]

\* ---------------------------------------------------------------
\* Actions: EBR Guard Management (F1, F5)
\* ---------------------------------------------------------------

\* Thread creates an EBR guard
\* (collector.rs:126 new_guard — announces current epoch)
CreateGuard(t) ==
    /\ pc[t] = "idle"
    /\ ~guardActive[t]
    /\ guardActive' = [guardActive EXCEPT ![t] = TRUE]
    /\ threadEpoch' = [threadEpoch EXCEPT ![t] = globalEpoch]
    /\ UNCHANGED <<coreVars, resizeVars, lockHeld, accessingData,
                    asyncVars, globalEpoch, retiredAt, reclaimed, auxVars>>

\* Thread drops its EBR guard
\* (collector.rs:193 end_guard)
DropGuard(t) ==
    /\ guardActive[t]
    /\ ~accessingData[t]     \* F1: must not be accessing data
    /\ lockHeld[t] = NoLock  \* must not hold any lock
    /\ asyncStep[t] = "idle"
    /\ guardActive' = [guardActive EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<coreVars, resizeVars, lockHeld, accessingData,
                    asyncVars, globalEpoch, threadEpoch, retiredAt, reclaimed, auxVars>>

\* ---------------------------------------------------------------
\* Actions: Synchronous Read (F1, F3)
\* ---------------------------------------------------------------

\* Begin a sync read: acquire guard, load array, acquire reader lock
\* (hash_table.rs:306-328 reader_sync)
BeginSyncRead(t, k, b) ==
    /\ pc[t] = "idle"
    /\ guardActive[t]
    /\ k \in Key
    /\ b \in Bucket
    /\ IsLive(currentArray)
    \* If linked array exists, we model dedup having happened
    \* (hash_table.rs:311-315 dedup_bucket_sync call)
    /\ bucketState[currentArray][b] = "active"
    /\ lockHeld[t] = NoLock
    /\ pc' = [pc EXCEPT ![t] = "reading"]
    /\ lockHeld' = [lockHeld EXCEPT ![t] = <<currentArray, b>>]
    /\ UNCHANGED <<coreVars, resizeVars, guardActive, accessingData,
                    asyncVars, ebrVars, nextArrayId>>

\* Access data while holding reader lock — the callback
\* (hash_table.rs:320-326 search + callback invocation)
AccessDataSync(t, k) ==
    /\ pc[t] = "reading"
    /\ lockHeld[t] /= NoLock
    /\ accessingData' = [accessingData EXCEPT ![t] = TRUE]
    /\ UNCHANGED <<coreVars, resizeVars, guardActive, lockHeld,
                    asyncVars, ebrVars, auxVars>>

\* End sync read: finish callback, release lock
\* (hash_table.rs:326 Reader dropped after callback returns)
EndSyncRead(t) ==
    /\ pc[t] = "reading"
    /\ accessingData[t]
    /\ accessingData' = [accessingData EXCEPT ![t] = FALSE]
    /\ lockHeld' = [lockHeld EXCEPT ![t] = NoLock]
    /\ pc' = [pc EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<coreVars, resizeVars, guardActive,
                    asyncVars, ebrVars, nextArrayId>>

\* ---------------------------------------------------------------
\* BUG VARIANT: Premature lock release (F1 — MC-5)
\* Models the yanked version 2.0-2.3 bug where Reader lock is
\* dropped BEFORE user callback finishes accessing data.
\* (Issue #176: HashMap::read dropped Reader before callback)
\*
\* Split into a separate action so the UAF window is observable:
\*   AccessDataSync → BuggyReleaseLockEarly → EndSyncRead
\* Between BuggyReleaseLockEarly and EndSyncRead, the invariant
\* F1_BugDetector will fire because accessingData=TRUE with lockHeld=NoLock.
\* ---------------------------------------------------------------
BuggyReleaseLockEarly(t) ==
    /\ pc[t] = "reading"
    /\ accessingData[t]
    /\ lockHeld[t] /= NoLock
    \* Bug: release lock while callback still accessing data
    /\ lockHeld' = [lockHeld EXCEPT ![t] = NoLock]
    \* accessingData stays TRUE — callback still running (UAF window)
    /\ UNCHANGED <<coreVars, resizeVars, guardActive, accessingData,
                    asyncVars, ebrVars, auxVars>>

\* ---------------------------------------------------------------
\* Actions: Synchronous Write (F3)
\* ---------------------------------------------------------------

\* Insert a key (simplified: acquire guard + lock, insert, release)
\* (hash_map.rs insert → hash_table.rs:335 writer_sync)
InsertSync(t, k, b) ==
    /\ pc[t] = "idle"
    /\ guardActive[t]
    /\ k \in Key
    /\ b \in Bucket
    /\ k \notin inserted
    /\ IsLive(currentArray)
    /\ bucketState[currentArray][b] = "active"
    /\ inserted' = inserted \cup {k}
    /\ entryLocation' = [entryLocation EXCEPT ![k] = {currentArray}]
    /\ UNCHANGED <<currentArray, linkedArray, bucketState, resizeVars,
                    guardVars, asyncVars, ebrVars, auxVars>>

\* Remove a key
\* (hash_map.rs remove → hash_table.rs writer path)
RemoveSync(t, k) ==
    /\ pc[t] = "idle"
    /\ guardActive[t]
    /\ k \in inserted
    /\ inserted' = inserted \ {k}
    /\ entryLocation' = [entryLocation EXCEPT ![k] = {}]
    /\ UNCHANGED <<currentArray, linkedArray, bucketState, resizeVars,
                    guardVars, asyncVars, ebrVars, auxVars>>

\* ---------------------------------------------------------------
\* Actions: Resize Protocol (F3)
\* ---------------------------------------------------------------

\* Trigger resize: allocate new array, link old as linked
\* (hash_table.rs:1307-1449 try_resize — CAS on minimum_capacity,
\*  allocate new BucketArray, swap into bucket_array_var)
TriggerResize(t) ==
    /\ pc[t] = "idle"
    /\ guardActive[t]
    /\ nextArrayId <= MaxArrays
    /\ linkedArray[currentArray] = NullArray  \* No resize already in progress
    /\ LET newArray == nextArrayId
       IN /\ currentArray' = newArray
          /\ linkedArray' = [linkedArray EXCEPT ![newArray] = currentArray]
          /\ bucketState' = [bucketState EXCEPT ![newArray] =
                              [b \in Bucket |-> "active"]]
          /\ rehashProgress' = [rehashProgress EXCEPT ![currentArray] = 1]
          /\ rehashActive' = [rehashActive EXCEPT ![currentArray] = 0]
          /\ nextArrayId' = nextArrayId + 1
          /\ UNCHANGED <<entryLocation, inserted, guardVars, asyncVars,
                          ebrVars, pc>>

\* Claim a bucket range for rehashing
\* (hash_table.rs:1098-1123 start_incremental_rehash)
\* Thread atomically claims the next bucket to rehash and increments ref count
ClaimRehashRange(t, oldArray) ==
    /\ pc[t] = "idle"
    /\ guardActive[t]
    /\ oldArray \in ArrayId
    /\ IsLive(oldArray)
    /\ \E a \in ArrayId : linkedArray[a] = oldArray  \* oldArray is linked from some current
    /\ rehashProgress[oldArray] \in Bucket  \* Still buckets to rehash
    /\ pc' = [pc EXCEPT ![t] = "rehashing"]
    /\ rehashActive' = [rehashActive EXCEPT ![oldArray] = @ + 1]
    /\ UNCHANGED <<coreVars, rehashProgress, guardVars, asyncVars, ebrVars, nextArrayId>>

\* Relocate entries from one old bucket to new array
\* (hash_table.rs:1003-1094 relocate_bucket)
\* Steps: lock old bucket → lock target bucket(s) in new → move entries → kill old
RelocateBucket(t, oldArray, b) ==
    /\ pc[t] = "rehashing"
    /\ oldArray \in ArrayId
    /\ b \in Bucket
    /\ b = rehashProgress[oldArray]  \* Must relocate current bucket in sequence
    /\ IsLive(oldArray)
    /\ bucketState[oldArray][b] = "active"
    \* Find the new array that links to oldArray
    /\ \E newArray \in ArrayId :
        /\ linkedArray[newArray] = oldArray
        /\ IsLive(newArray)
        \* Lock old bucket (hash_table.rs:948-950 Writer::lock on old bucket)
        \* Lock target buckets in new array (hash_table.rs:955-970)
        \* Move entries from old[b] to new array
        /\ entryLocation' = [k \in Key |->
            IF k \in inserted /\ oldArray \in entryLocation[k]
            THEN (entryLocation[k] \ {oldArray}) \cup {newArray}
            ELSE entryLocation[k]]
        \* Kill old bucket (hash_table.rs:993 kill())
        /\ bucketState' = [bucketState EXCEPT ![oldArray][b] = "killed"]
    \* Advance rehash progress after relocating
    /\ rehashProgress' = [rehashProgress EXCEPT ![oldArray] = @ + 1]
    /\ UNCHANGED <<currentArray, linkedArray, inserted,
                    rehashActive, guardVars, asyncVars, ebrVars, auxVars>>

\* Try-lock failure during rehash: entries left in old bucket, advance anyway
\* (hash_table.rs:967-970 try_lock failure path — unlock already-locked targets)
\* In the real code, the loop continues to next bucket even on failure
\* Bug Family F3, MC-1: entry temporarily in both arrays or unfindable
RelocateBucketFail(t, oldArray, b) ==
    /\ pc[t] = "rehashing"
    /\ oldArray \in ArrayId
    /\ b \in Bucket
    /\ b = rehashProgress[oldArray]  \* Must be current bucket in sequence
    /\ IsLive(oldArray)
    /\ bucketState[oldArray][b] = "active"
    \* Try-lock failed — thread gives up on rehash entirely (returns from function)
    \* (hash_table.rs:1233-1234 try_lock path: if lock fails, break loop)
    \* The thread ends its rehash attempt; bucket stays for another thread
    /\ UNCHANGED <<coreVars, resizeVars, guardVars, asyncVars, ebrVars, auxVars>>

\* End rehash: decrement ref count, potentially finalize
\* (hash_table.rs:1127-1154 end_incremental_rehash)
EndRehash(t, oldArray) ==
    /\ pc[t] = "rehashing"
    /\ oldArray \in ArrayId
    /\ rehashActive[oldArray] > 0
    /\ rehashActive' = [rehashActive EXCEPT ![oldArray] = @ - 1]
    /\ pc' = [pc EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<coreVars, rehashProgress, guardVars, asyncVars, ebrVars, nextArrayId>>

\* Finalize resize: unlink old array, defer reclaim
\* (hash_table.rs:1195-1200 swap old array out, defer_reclaim)
FinalizeResize(t, oldArray) ==
    /\ pc[t] = "idle"
    /\ guardActive[t]
    /\ oldArray \in ArrayId
    /\ IsLive(oldArray)
    \* All buckets rehashed, no active rehashers, and all buckets killed
    /\ rehashProgress[oldArray] > Cardinality(Bucket)
    /\ rehashActive[oldArray] = 0
    /\ \A b \in Bucket : bucketState[oldArray][b] = "killed"
    \* Find the new array that links to oldArray
    /\ \E newArray \in ArrayId :
        /\ linkedArray[newArray] = oldArray
        \* Unlink (hash_table.rs:1195 swap with Release)
        /\ linkedArray' = [linkedArray EXCEPT ![newArray] = NullArray]
    \* Retire old array for EBR (hash_index.rs:1378)
    /\ retiredAt' = [retiredAt EXCEPT ![oldArray] = globalEpoch]
    /\ UNCHANGED <<currentArray, entryLocation, bucketState, inserted,
                    rehashProgress, rehashActive, guardVars, asyncVars,
                    globalEpoch, threadEpoch, reclaimed, auxVars>>

\* ---------------------------------------------------------------
\* Actions: Dedup During Read/Write (F3)
\* ---------------------------------------------------------------

\* Dedup: when accessing a bucket in the new array, first migrate
\* relevant entries from the old array's corresponding bucket
\* (hash_table.rs:812-887 dedup_bucket_sync)
DedupBucket(t, b) ==
    /\ pc[t] = "idle"
    /\ guardActive[t]
    /\ b \in Bucket
    /\ IsLive(currentArray)
    /\ linkedArray[currentArray] /= NullArray
    /\ LET oldArray == linkedArray[currentArray]
       IN /\ IsLive(oldArray)
          /\ bucketState[oldArray][b] = "active"
          \* Move entries that hash to bucket b from old to new
          /\ entryLocation' = [k \in Key |->
              IF k \in inserted /\ oldArray \in entryLocation[k]
              THEN (entryLocation[k] \ {oldArray}) \cup {currentArray}
              ELSE entryLocation[k]]
          /\ bucketState' = [bucketState EXCEPT ![oldArray][b] = "killed"]
          /\ UNCHANGED <<currentArray, linkedArray, inserted, resizeVars,
                          guardVars, asyncVars, ebrVars, auxVars>>

\* ---------------------------------------------------------------
\* Actions: Async Read (F2)
\* ---------------------------------------------------------------

\* Begin async read: load array reference
\* (hash_table.rs:270 async_guard.load_unchecked(bucket_array))
BeginAsyncRead(t) ==
    /\ pc[t] = "idle"
    /\ guardActive[t]
    /\ asyncStep[t] = "idle"
    /\ IsLive(currentArray)
    /\ asyncStep' = [asyncStep EXCEPT ![t] = "loaded_ref"]
    /\ seenArray' = [seenArray EXCEPT ![t] = currentArray]
    /\ pc' = [pc EXCEPT ![t] = "async_read"]
    /\ UNCHANGED <<coreVars, resizeVars, guardActive, lockHeld, accessingData,
                    ebrVars, nextArrayId>>

\* Await point: thread suspends, guard is reset
\* (async_helper.rs:53 reset() — drops guard before suspension)
\* Another thread may resize the array during this window
AsyncAwait(t) ==
    /\ pc[t] = "async_read"
    /\ asyncStep[t] = "loaded_ref"
    /\ asyncStep' = [asyncStep EXCEPT ![t] = "awaiting"]
    \* Guard is reset (dropped and will be re-acquired)
    /\ guardActive' = [guardActive EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<coreVars, resizeVars, lockHeld, accessingData,
                    seenArray, ebrVars, auxVars>>

\* Re-acquire guard after await
AsyncReacquireGuard(t) ==
    /\ pc[t] = "async_read"
    /\ asyncStep[t] = "awaiting"
    /\ ~guardActive[t]
    /\ guardActive' = [guardActive EXCEPT ![t] = TRUE]
    /\ threadEpoch' = [threadEpoch EXCEPT ![t] = globalEpoch]
    /\ UNCHANGED <<coreVars, resizeVars, lockHeld, accessingData,
                    asyncStep, seenArray, globalEpoch, retiredAt, reclaimed, auxVars>>

\* Check reference validity after await
\* (async_helper.rs:72 check_ref — validates array hasn't changed)
AsyncCheckRef(t) ==
    /\ pc[t] = "async_read"
    /\ asyncStep[t] = "awaiting"
    /\ guardActive[t]
    /\ IF seenArray[t] = currentArray
       THEN \* Ref still valid — proceed to operate
            /\ asyncStep' = [asyncStep EXCEPT ![t] = "ref_checked"]
            /\ seenArray' = seenArray
            /\ pc' = pc
       ELSE \* Ref invalid — must restart (retry outer loop)
            /\ asyncStep' = [asyncStep EXCEPT ![t] = "idle"]
            /\ seenArray' = [seenArray EXCEPT ![t] = NullArray]
            /\ pc' = [pc EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<coreVars, resizeVars, guardVars, ebrVars, nextArrayId>>

\* Operate on data after ref check passes
AsyncOperate(t, k) ==
    /\ pc[t] = "async_read"
    /\ asyncStep[t] = "ref_checked"
    /\ guardActive[t]
    /\ k \in Key
    /\ accessingData' = [accessingData EXCEPT ![t] = TRUE]
    /\ asyncStep' = [asyncStep EXCEPT ![t] = "operating"]
    /\ UNCHANGED <<coreVars, resizeVars, guardActive, lockHeld,
                    seenArray, ebrVars, auxVars>>

\* Complete async read
EndAsyncRead(t) ==
    /\ pc[t] = "async_read"
    /\ asyncStep[t] = "operating"
    /\ accessingData' = [accessingData EXCEPT ![t] = FALSE]
    /\ asyncStep' = [asyncStep EXCEPT ![t] = "idle"]
    /\ seenArray' = [seenArray EXCEPT ![t] = NullArray]
    /\ pc' = [pc EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<coreVars, resizeVars, guardActive, lockHeld,
                    ebrVars, nextArrayId>>

\* BUG VARIANT: Skip check_ref after await (F2 — MC-3)
\* Models missing check_ref() — operate on stale array reference
BuggyAsyncSkipCheckRef(t, k) ==
    /\ pc[t] = "async_read"
    /\ asyncStep[t] = "awaiting"
    /\ guardActive[t]
    \* Bug: skip check_ref, directly access data using stale seenArray
    /\ accessingData' = [accessingData EXCEPT ![t] = TRUE]
    /\ asyncStep' = [asyncStep EXCEPT ![t] = "operating"]
    /\ UNCHANGED <<coreVars, resizeVars, guardActive, lockHeld,
                    seenArray, ebrVars, auxVars>>

\* ---------------------------------------------------------------
\* Actions: EBR Epoch Advancement and Reclamation (F5)
\* ---------------------------------------------------------------

\* Advance global epoch
\* (collector.rs:410 scan — advances only if all active threads are in same epoch)
AdvanceEpoch ==
    \* All threads with active guards are in the current epoch
    /\ \A t \in Thread : guardActive[t] => threadEpoch[t] = globalEpoch
    /\ globalEpoch' = (globalEpoch + 1) % 4
    /\ UNCHANGED <<coreVars, resizeVars, guardVars, asyncVars,
                    threadEpoch, retiredAt, reclaimed, auxVars>>

\* Reclaim a retired array
\* (hash_index.rs:1191-1218 dealloc_garbage)
\* Safe only if retired epoch is NOT in same generation as current
ReclaimArray(a) ==
    /\ a \in ArrayId
    /\ retiredAt[a] >= 0
    /\ a \notin reclaimed
    /\ ~InSameGeneration(retiredAt[a], globalEpoch)
    /\ reclaimed' = reclaimed \cup {a}
    /\ UNCHANGED <<coreVars, resizeVars, guardVars, asyncVars,
                    globalEpoch, threadEpoch, retiredAt, auxVars>>

\* BUG VARIANT: Premature reclaim (F5 — MC-7)
\* Reclaim without checking generation — models aggressive epoch acceleration
BuggyReclaimArray(a) ==
    /\ a \in ArrayId
    /\ retiredAt[a] >= 0
    /\ a \notin reclaimed
    \* Bug: skip generation check
    /\ reclaimed' = reclaimed \cup {a}
    /\ UNCHANGED <<coreVars, resizeVars, guardVars, asyncVars,
                    globalEpoch, threadEpoch, retiredAt, auxVars>>

\* ---------------------------------------------------------------
\* Next-state relation
\* ---------------------------------------------------------------
Next ==
    \/ \E t \in Thread :
        \/ CreateGuard(t)
        \/ DropGuard(t)
        \/ \E k \in Key, b \in Bucket :
            \/ BeginSyncRead(t, k, b)
            \/ InsertSync(t, k, b)
        \/ \E k \in Key :
            \/ AccessDataSync(t, k)
            \/ RemoveSync(t, k)
            \/ AsyncOperate(t, k)
        \/ EndSyncRead(t)
        \/ TriggerResize(t)
        \/ \E a \in ArrayId :
            \/ ClaimRehashRange(t, a)
            \/ EndRehash(t, a)
            \/ FinalizeResize(t, a)
            \/ \E b \in Bucket :
                \/ RelocateBucket(t, a, b)
                \/ RelocateBucketFail(t, a, b)
        \/ \E b \in Bucket : DedupBucket(t, b)
        \/ BeginAsyncRead(t)
        \/ AsyncAwait(t)
        \/ AsyncReacquireGuard(t)
        \/ AsyncCheckRef(t)
        \/ EndAsyncRead(t)
    \/ AdvanceEpoch
    \/ \E a \in ArrayId : ReclaimArray(a)

\* ---------------------------------------------------------------
\* Specification
\* ---------------------------------------------------------------
Spec == Init /\ [][Next]_vars

\* ---------------------------------------------------------------
\* Invariants
\* ---------------------------------------------------------------

\* --- Standard Safety ---

\* Every inserted key is findable by at least one reader (F3)
\* (hash_table.rs:224 peek_entry must find key in current or linked array)
EntryReachability ==
    \A k \in inserted : \E a \in entryLocation[k] : IsLive(a)

\* No key appears with duplicate entries (F3)
\* Each key is in at most the arrays where it's being migrated
EntryUniqueness ==
    \A k \in Key : Cardinality(entryLocation[k]) <= 2

\* No lost entry during resize: if key was in old array and old bucket
\* is killed, key must be in new array (F3 — MC-1)
NoLostEntryDuringResize ==
    \A k \in inserted :
    \A a \in ArrayId :
        (a \in entryLocation[k] /\ \A b \in Bucket : bucketState[a][b] = "killed")
        => \E a2 \in entryLocation[k] : a2 /= a /\ IsLive(a2)

\* --- Extension: Guard/Lock Lifetime (F1) ---

\* Data access must be bracketed by guard AND lock
\* (F1 — the yanked-version invariant)
GuardBracketsAccess ==
    \A t \in Thread :
        accessingData[t] => guardActive[t]

\* Lock must be held while accessing data
LockBracketsAccess ==
    \A t \in Thread :
        (accessingData[t] /\ pc[t] = "reading")
        => lockHeld[t] /= NoLock

\* Combined: access requires both guard and lock for sync reads
\* For async reads, guard must be active
NoUseAfterFree ==
    \A t \in Thread :
        accessingData[t] =>
            /\ guardActive[t]
            /\ (pc[t] = "reading" => lockHeld[t] /= NoLock)

\* --- Extension: Async Reference Validity (F2) ---

\* When operating on data, the seen array must still be current
\* (async_helper.rs:72 check_ref must have passed)
AsyncRefValidity ==
    \A t \in Thread :
        (asyncStep[t] = "operating" /\ accessingData[t])
        => seenArray[t] = currentArray

\* --- Extension: EBR Safety (F5) ---

\* Retired arrays must have valid retired epoch
EpochSafety ==
    \A a \in ArrayId :
        a \in reclaimed => retiredAt[a] >= 0

\* No thread accesses a reclaimed array
\* No thread actively accesses (lock held or operating on) a reclaimed array
\* Note: seenArray may hold a stale ref during await — that's fine because
\* the thread isn't accessing it and will check_ref after reacquire
NoAccessToReclaimed ==
    \A t \in Thread :
        /\ \A a \in reclaimed : \A b \in Bucket :
            lockHeld[t] /= <<a, b>>
        /\ (asyncStep[t] \in {"ref_checked", "operating"} =>
            seenArray[t] \notin reclaimed)

\* --- Structural Invariants ---

\* Current array is never NullArray (after init)
CurrentArrayExists == currentArray /= NullArray

\* No circular linked array chains
NoCircularChain ==
    \A a \in ArrayId : linkedArray[a] /= a

\* Killed buckets are never re-activated
KilledBucketsStayKilled ==
    \A a \in ArrayId : \A b \in Bucket :
        bucketState[a][b] = "killed" =>
            bucketState'[a][b] = "killed"

\* A reclaimed array is never un-reclaimed
ReclaimedIsMonotonic ==
    \A a \in reclaimed : a \in reclaimed'

\* ---------------------------------------------------------------
\* Bug-hunting invariants (used in MC_hunt configs)
\* ---------------------------------------------------------------

\* F1 bug detection: finds states where data is accessed without lock
F1_BugDetector ==
    \A t \in Thread :
        accessingData[t] => lockHeld[t] /= NoLock

\* F2 bug detection: finds states where stale array ref is used
F2_BugDetector ==
    \A t \in Thread :
        (asyncStep[t] = "operating") =>
            (seenArray[t] \notin reclaimed /\ IsLive(seenArray[t]))

\* F3 bug detection: finds states where entry is unreachable
F3_BugDetector == EntryReachability

\* F5 bug detection: finds premature reclamation
F5_BugDetector ==
    \A a \in reclaimed :
        \A t \in Thread :
            guardActive[t] => ~InSameGeneration(retiredAt[a], threadEpoch[t])

=============================================================================
