---- MODULE base ----
(***************************************************************************)
(* TLA+ specification of `scc` (scalable-concurrent-containers, Rust).     *)
(*                                                                         *)
(* Category B (concurrent / lock-free). Models the HashIndex/HashMap       *)
(* migration and iteration sub-system, where bucket arrays are replaced    *)
(* via per-entry tombstoning (HashIndex) and bucket-batch relocation       *)
(* (HashMap), and lock-free / async readers and iterators race the writers *)
(* doing migration.                                                        *)
(*                                                                         *)
(* Slot indexing: <<aid, bidx, key>>. Real BUCKET_LEN=32; the spec models  *)
(* up to one slot per (bucket, key) — i.e., each key has its own logical   *)
(* slot inside a bucket. This faithfully models the case where two keys    *)
(* land in the same real bucket without colliding on a single spec slot.   *)
(*                                                                         *)
(* Source files modeled (artifact/scc/src):                                *)
(*   hash_table.rs          (peek_entry, reader_async, writer_async,       *)
(*                           optional_writer_async, for_each_*_async,      *)
(*                           dedup_bucket_async, relocate_bucket_async,    *)
(*                           incremental_rehash_async, try_resize)         *)
(*   hash_table/bucket.rs   (mark_removed, extract_from, insert_entry,     *)
(*                           drop_unreachable_entries)                     *)
(*   hash_index.rs          (Iter::next, dealloc_garbage, defer_reclaim)   *)
(*   async_helper.rs        (AsyncGuard.check_ref, .reset)                 *)
(*                                                                         *)
(* Bug families (modeling-brief.md):                                       *)
(*   F1 — Iterator/scan vs. concurrent insert/remove/resize (caller-misuse)*)
(*   F2 — Per-entry migration (publish-new vs clear-old window) HashIndex  *)
(*   F3 — Async reference invalidation across `.await` (check_ref)         *)
(*   F4 — EBR reclamation under per-entry tombstone                        *)
(*   F5 — Latent locked-bucket leak in relocate_bucket_async early return  *)
(***************************************************************************)

EXTENDS Integers, Sequences, FiniteSets, TLC

\* ========================================================================
\* Constants
\* ========================================================================

CONSTANTS
    Thread,         \* Set of worker thread IDs
    Key,            \* Set of keys (small for state-space)
    Value,          \* Set of values
    BucketCount,    \* # of buckets per array  (each array has same count for simplicity)
    MaxArrays,      \* upper bound on # of distinct bucket array allocations
    MaxEpoch        \* Max global epoch — F4 state-space cap on EBR generation count

ASSUME Cardinality(Thread) >= 1
ASSUME BucketCount \in Nat \ {0}
ASSUME MaxArrays \in Nat \ {0}
ASSUME MaxEpoch \in Nat \ {0}

\* Sentinels.  TLC strict-typing forbids equality on heterogeneous values
\* (string "none" vs integer ArrayId).  We therefore use distinct sentinels:
\*   NONE   — string "none" — used for record-/string-typed fields
\*            (pc.kind, pc.step, pc.key, pc.val, pc.migrating)
\*   NoId   — integer 0 — used for ArrayId-/Nat-typed fields where the
\*            value would otherwise collide with a real ArrayId
\*            (linkedOf, currentArray sentinel, garbageHead, pc.cachedArray,
\*             pc.pinnedEpoch).  Note 0 \notin ArrayId = 1..MaxArrays.
NONE == "none"
NoId == 0

\* Possible array IDs
ArrayId == 1..MaxArrays
BucketIdx == 0..(BucketCount - 1)

\* Slot index = <<aid, bidx, key>>: each bucket has at most one slot per key.
\* Real BUCKET_LEN=32; the spec abstracts to "one slot per key per bucket"
\* which is sound as long as |Key| ≤ 32.
SlotIdx == ArrayId \X BucketIdx \X Key

\* ========================================================================
\* Variables
\* ========================================================================

\* --- Bucket-array chain ---
VARIABLES
    arrayState,         \* [ArrayId -> {"unalloc","live","linked","garbage","freed"}]
    currentArray,       \* ArrayId of the current live array
    linkedOf,           \* [ArrayId -> ArrayId | NONE]
    garbageHead,        \* head of garbage chain (ArrayId | NONE)
    garbageEpoch        \* hash_index.garbage_epoch (0 iff chain empty)

bucketArrayVars == <<arrayState, currentArray, linkedOf, garbageHead, garbageEpoch>>

\* --- Slot occupancy (Family 1, 2) — indexed by (aid, bidx, key) ---
\*    occBit:    occupied_bitmap & 1 (Release on INDEX writes)
\*    remBit:    removed_bitmap & 1   (Release on mark_removed)
\*    slotVal:   payload value (the key is the slot index)
\*    slotPubEpoch: epoch byte stored at mark_removed time
VARIABLES
    occBit,             \* [SlotIdx -> BOOLEAN]
    remBit,             \* [SlotIdx -> BOOLEAN]    (only INDEX)
    slotVal,            \* [SlotIdx -> Value | NONE]
    slotPubEpoch        \* [SlotIdx -> Nat]

slotVars == <<occBit, remBit, slotVal, slotPubEpoch>>

\* --- Bucket lock (writer / reader via saa::Lock) ---
VARIABLES
    bucketLock          \* [ArrayId × BucketIdx -> {"unlocked","writer","killed"}]

\* --- Per-thread state machine ---
VARIABLES
    pc

\* --- EBR (Family 4) ---
VARIABLES
    globalEpoch,
    deferReclaim

ebrVars == <<globalEpoch, deferReclaim>>

\* --- History / correctness ---
VARIABLES
    inserted,
    removedHistory,
    iterCompleted,
    iterStartLive,
    iterEndAlsoLive,
    \* Set of (k,v) entries that were observed to undergo a remove event
    \* DURING this iter's lifetime.  scc does not guarantee linearizable
    \* iteration in the presence of concurrent removes; the iter may legitimately
    \* skip such keys.  Used by NoLiveKeyMissedByCompletedIter.
    iterSeenRemove

historyVars == <<inserted, removedHistory, iterCompleted, iterStartLive, iterEndAlsoLive,
                 iterSeenRemove>>

\* --- F3 fault-injection adversary control vars ---
VARIABLES
    skipCheckRef        \* [Thread -> BOOLEAN]

allVars ==
    <<bucketArrayVars, slotVars, bucketLock, pc, ebrVars, historyVars,
      skipCheckRef>>

\* ========================================================================
\* Helpers
\* ========================================================================

IdleRec ==
    [kind |-> "idle",
     step |-> "idle",
     cachedArray |-> NoId,
     bucketIdx |-> NONE,
     key |-> NONE,
     val |-> NONE,
     visited |-> {},
     pinnedEpoch |-> NoId,
     migrating |-> NONE]

\* Live (key, val) set in a given array (occupied AND not removed)
LiveInArray(a) ==
    LET LiveBK ==
        { bk \in BucketIdx \X Key :
            /\ occBit[<<a, bk[1], bk[2]>>]
            /\ ~remBit[<<a, bk[1], bk[2]>>] }
    IN { <<bk[2], slotVal[<<a, bk[1], bk[2]>>]>> : bk \in LiveBK }

\* Total live set across the live + linked arrays (the "logical" map state)
LiveKeys ==
    LET live_a == { LiveInArray(a) : a \in { x \in ArrayId : arrayState[x] = "live" } }
        linked_a == { LiveInArray(a) : a \in { x \in ArrayId : arrayState[x] = "linked" } }
    IN UNION (live_a \cup linked_a)

ArrayAlive(a) == arrayState[a] \in {"live", "linked", "garbage"}

\* A reader pinned at epoch p protects all objects reachable at epoch p,
\* so an object retired at epoch e cannot be reclaimed while any reader
\* has p <= e.  This matches sdd's `Epoch::in_same_generation` gate.
\* (The original "= e" predicate was too weak: it allowed reclaim when
\* a reader was pinned at an *earlier* epoch, leading to use-after-free.)
EpochPinned(e) ==
    \E t \in Thread :
        /\ pc[t].pinnedEpoch # NoId
        /\ pc[t].pinnedEpoch <= e

ReachableFromCurrent(a) ==
    \/ a = currentArray
    \/ linkedOf[currentArray] = a

\* ========================================================================
\* Init
\* ========================================================================

InitArrayId == 1

Init ==
    /\ arrayState = [a \in ArrayId |-> IF a = InitArrayId THEN "live" ELSE "unalloc"]
    /\ currentArray = InitArrayId
    /\ linkedOf = [a \in ArrayId |-> NoId]
    /\ garbageHead = NoId
    /\ garbageEpoch = 0

    /\ occBit       = [s \in SlotIdx |-> FALSE]
    /\ remBit       = [s \in SlotIdx |-> FALSE]
    /\ slotVal      = [s \in SlotIdx |-> NONE]
    /\ slotPubEpoch = [s \in SlotIdx |-> 0]

    /\ bucketLock = [p \in ArrayId \X BucketIdx |-> "unlocked"]

    /\ pc = [t \in Thread |-> IdleRec]

    /\ globalEpoch = 1
    /\ deferReclaim = {}

    /\ inserted = {}
    /\ removedHistory = {}
    /\ iterCompleted = [t \in Thread |-> FALSE]
    /\ iterStartLive = [t \in Thread |-> {}]
    /\ iterEndAlsoLive = [t \in Thread |-> {}]
    /\ iterSeenRemove = [t \in Thread |-> {}]

    /\ skipCheckRef = [t \in Thread |-> FALSE]

\* ========================================================================
\* Section A — Writer path
\* ========================================================================

WriterStart(t, k, v) ==
    /\ pc[t].kind = "idle"
    /\ k \in Key /\ v \in Value
    /\ pc' = [pc EXCEPT ![t] = [@ EXCEPT
            !.kind = "writer",
            !.step = "loaded_array",
            !.cachedArray = currentArray,
            !.key = k,
            !.val = v ]]
    /\ UNCHANGED <<bucketArrayVars, slotVars, bucketLock, ebrVars,
                   historyVars, skipCheckRef>>

WriterMaybeRehashOK(t) ==
    /\ pc[t].kind = "writer"
    /\ pc[t].step = "loaded_array"
    /\ pc' = [pc EXCEPT ![t] = [@ EXCEPT !.step = "post_rehash"]]
    /\ UNCHANGED <<bucketArrayVars, slotVars, bucketLock, ebrVars,
                   historyVars, skipCheckRef>>

WriterMaybeRehashRetry(t) ==
    /\ pc[t].kind = "writer"
    /\ pc[t].step = "loaded_array"
    /\ linkedOf[currentArray] # NoId
    /\ pc' = [pc EXCEPT ![t] = [@ EXCEPT
            !.step = "loaded_array",
            !.cachedArray = currentArray ]]
    /\ UNCHANGED <<bucketArrayVars, slotVars, bucketLock, ebrVars,
                   historyVars, skipCheckRef>>

WriterAcquireLock(t) ==
    /\ pc[t].kind = "writer"
    /\ pc[t].step = "post_rehash"
    /\ LET aid == pc[t].cachedArray
       IN
        /\ aid \in ArrayId
        /\ arrayState[aid] \in {"live", "linked"}
        /\ \E b \in BucketIdx :
              /\ bucketLock[<<aid, b>>] = "unlocked"
              /\ bucketLock' = [bucketLock EXCEPT ![<<aid, b>>] = "writer"]
              /\ pc' = [pc EXCEPT ![t] = [@ EXCEPT
                    !.step = "locked",
                    !.bucketIdx = b ]]
    /\ UNCHANGED <<bucketArrayVars, slotVars, ebrVars, historyVars,
                   skipCheckRef>>

\* For HashIndex INDEX type, insert sets occBit on the (aid, bidx, key) slot.
WriterCommitInsert(t) ==
    /\ pc[t].kind = "writer"
    /\ pc[t].step = "locked"
    /\ LET aid == pc[t].cachedArray
           b == pc[t].bucketIdx
           k == pc[t].key
           s == <<aid, b, k>>
       IN
        /\ ~occBit[s]
        /\ occBit'  = [occBit EXCEPT ![s] = TRUE]
        /\ slotVal' = [slotVal EXCEPT ![s] = pc[t].val]
        /\ inserted' = inserted \cup {<<pc[t].key, pc[t].val>>}
        \* Notify any in-flight iter that a write touched this (k,v).
        \* (scc does not promise iter linearizability in the presence of
        \* concurrent inserts either; iter may not yet have reached this
        \* slot, or may have already passed its target bucket.)
        /\ iterSeenRemove' = [u \in Thread |->
                IF pc[u].kind = "iter"
                THEN iterSeenRemove[u] \cup {<<pc[t].key, pc[t].val>>}
                ELSE iterSeenRemove[u]]
    /\ pc' = [pc EXCEPT ![t] = [@ EXCEPT !.step = "committed"]]
    /\ UNCHANGED <<remBit, slotPubEpoch>>
    /\ UNCHANGED <<bucketArrayVars, bucketLock, ebrVars,
                   removedHistory, iterCompleted, iterStartLive,
                   iterEndAlsoLive, skipCheckRef>>

\* bucket.rs:220-249 — mark_removed for INDEX:
\*   1. write partial_hash_array[i] = u8::from(guard.epoch())  (non-atomic)
\*   2. removed_bitmap |= (1<<i), Release.
WriterCommitMarkRemoved(t) ==
    /\ pc[t].kind = "writer"
    /\ pc[t].step = "locked"
    /\ LET aid == pc[t].cachedArray
           b == pc[t].bucketIdx
           k == pc[t].key
           s == <<aid, b, k>>
           kv == <<k, slotVal[s]>>
       IN
        /\ occBit[s] /\ ~remBit[s]
        /\ slotPubEpoch' = [slotPubEpoch EXCEPT ![s] = globalEpoch]
        /\ remBit' = [remBit EXCEPT ![s] = TRUE]
        /\ removedHistory' = removedHistory \cup {kv}
        \* Notify any in-flight iter that this (k,v) was concurrently removed.
        /\ iterSeenRemove' = [u \in Thread |->
                IF pc[u].kind = "iter"
                THEN iterSeenRemove[u] \cup {kv}
                ELSE iterSeenRemove[u]]
    /\ pc' = [pc EXCEPT ![t] = [@ EXCEPT !.step = "committed"]]
    /\ UNCHANGED <<occBit, slotVal>>
    /\ UNCHANGED <<bucketArrayVars, bucketLock, ebrVars,
                   inserted, iterCompleted, iterStartLive,
                   iterEndAlsoLive, skipCheckRef>>

WriterRelease(t) ==
    /\ pc[t].kind = "writer"
    /\ pc[t].step = "committed"
    /\ LET aid == pc[t].cachedArray
           b == pc[t].bucketIdx
       IN
        /\ bucketLock[<<aid, b>>] = "writer"
        /\ bucketLock' = [bucketLock EXCEPT ![<<aid, b>>] = "unlocked"]
    /\ pc' = [pc EXCEPT ![t] = IdleRec]
    /\ UNCHANGED <<bucketArrayVars, slotVars, ebrVars, historyVars,
                   skipCheckRef>>

\* ========================================================================
\* Section B — Iterator path (Family 1)
\* ========================================================================

IterStart(t) ==
    /\ pc[t].kind = "idle"
    /\ LET cur == currentArray
           old == linkedOf[cur]
           start == IF old # NoId THEN old ELSE cur
       IN
       /\ pc' = [pc EXCEPT ![t] = [@ EXCEPT
            !.kind = "iter",
            !.step = "scanning",
            !.cachedArray = start,
            !.bucketIdx = 0,
            !.visited = {},
            !.pinnedEpoch = globalEpoch ]]
       /\ iterStartLive' = [iterStartLive EXCEPT ![t] = LiveKeys]
       \* Reset prior-iter completion state — the invariant must only
       \* speak about the iter currently in flight.
       /\ iterCompleted' = [iterCompleted EXCEPT ![t] = FALSE]
       /\ iterEndAlsoLive' = [iterEndAlsoLive EXCEPT ![t] = {}]
       /\ iterSeenRemove' = [iterSeenRemove EXCEPT ![t] = {}]
    /\ UNCHANGED <<bucketArrayVars, slotVars, bucketLock, ebrVars,
                   inserted, removedHistory,
                   skipCheckRef>>

\* hash_index.rs:2117-2123 — within-bucket entry advance + return Some((k,v)).
\* The reader observes some live (key, val) in the current bucket.
IterReadOccupied(t) ==
    /\ pc[t].kind = "iter"
    /\ pc[t].step = "scanning"
    /\ LET aid == pc[t].cachedArray
           b == pc[t].bucketIdx
       IN
        /\ aid \in ArrayId
        /\ arrayState[aid] # "freed"
        /\ b \in BucketIdx
        /\ \E k \in Key :
              /\ occBit[<<aid, b, k>>]
              /\ ~remBit[<<aid, b, k>>]
              /\ pc' = [pc EXCEPT ![t] = [@ EXCEPT
                        !.visited = @ \cup { <<k, slotVal[<<aid, b, k>>]>> } ]]
    /\ UNCHANGED <<bucketArrayVars, slotVars, bucketLock, ebrVars,
                   historyVars, skipCheckRef>>

\* Bucket has no live entry; skip-without-yield.
IterReadEmpty(t) ==
    /\ pc[t].kind = "iter"
    /\ pc[t].step = "scanning"
    /\ LET aid == pc[t].cachedArray
           b == pc[t].bucketIdx
       IN
        /\ aid \in ArrayId /\ arrayState[aid] # "freed"
        /\ \A k \in Key :
              \/ ~occBit[<<aid, b, k>>]
              \/ remBit[<<aid, b, k>>]
    /\ UNCHANGED <<bucketArrayVars, slotVars, bucketLock, pc, ebrVars,
                   historyVars, skipCheckRef>>

\* Precondition models the impl: `Iter::next` only advances the bucket
\* index AFTER `move_to_next` returns false on the current bucket — i.e.,
\* every entry slot in the current bucket is empty or tombstoned (from
\* the iterator's perspective).  A writer that races in *after* the
\* advance is then missed by this iterator (the F1 race surface).
IterBucketExhausted(t) ==
    LET aid == pc[t].cachedArray
        b == pc[t].bucketIdx
    IN \A k \in Key : ~occBit[<<aid, b, k>>] \/ remBit[<<aid, b, k>>]

IterAdvanceWithinBucket(t) ==
    /\ pc[t].kind = "iter"
    /\ pc[t].step = "scanning"
    /\ pc[t].bucketIdx + 1 < BucketCount
    /\ IterBucketExhausted(t)
    /\ pc' = [pc EXCEPT ![t] = [@ EXCEPT !.bucketIdx = @ + 1]]
    /\ UNCHANGED <<bucketArrayVars, slotVars, bucketLock, ebrVars,
                   historyVars, skipCheckRef>>

IterCrossArray(t) ==
    /\ pc[t].kind = "iter"
    /\ pc[t].step = "scanning"
    /\ pc[t].bucketIdx + 1 = BucketCount
    /\ IterBucketExhausted(t)
    /\ LET cached == pc[t].cachedArray
           cur == currentArray
       IN
        \/ /\ cur = cached
           /\ pc' = [pc EXCEPT ![t] = [@ EXCEPT !.step = "done"]]
        \/ /\ linkedOf[cur] = cached
           /\ pc' = [pc EXCEPT ![t] = [@ EXCEPT
                     !.cachedArray = cur,
                     !.bucketIdx = 0 ]]
        \/ /\ cached # cur
           /\ linkedOf[cur] # cached
           /\ linkedOf[cur] # NoId
           /\ pc' = [pc EXCEPT ![t] = [@ EXCEPT
                     !.cachedArray = linkedOf[cur],
                     !.bucketIdx = 0 ]]
    /\ UNCHANGED <<bucketArrayVars, slotVars, bucketLock, ebrVars,
                   historyVars, skipCheckRef>>

\* IterFinish: terminate the iterator. The implementation's `Iter::next`
\* combines the "current == cached → break" decision and the `None` return
\* into a single `next()` invocation, so the harness emits just one event
\* (`IterFinish`) for that transition. We accept either:
\*   - step = "done" (preceded by an explicit IterCrossArray-to-done)
\*   - step = "scanning" at the last bucket with cur == cached (the
\*     collapsed done case).
IterFinish(t) ==
    /\ pc[t].kind = "iter"
    /\ \/ pc[t].step = "done"
       \/ \* The implementation collapses "current==cached → break + None"
          \* into a single Iter::next() invocation, so the harness emits
          \* IterFinish with no separate IterCrossArray for the done branch.
          \* This still requires the iterator to be at the LAST bucket of
          \* its current array, that bucket exhausted, and current == cached.
          /\ pc[t].step = "scanning"
          /\ pc[t].bucketIdx + 1 = BucketCount
          /\ pc[t].cachedArray = currentArray
          /\ IterBucketExhausted(t)
    /\ iterCompleted' = [iterCompleted EXCEPT ![t] = TRUE]
    /\ iterEndAlsoLive' = [iterEndAlsoLive EXCEPT ![t] = LiveKeys]
    /\ pc' = [pc EXCEPT ![t] = IdleRec]
    /\ UNCHANGED <<bucketArrayVars, slotVars, bucketLock, ebrVars,
                   inserted, removedHistory, iterStartLive, iterSeenRemove,
                   skipCheckRef>>

\* ========================================================================
\* Section C — Resize / Migration (Families 1, 2, 5)
\* ========================================================================

TryResize(t) ==
    /\ pc[t].kind = "idle"
    /\ linkedOf[currentArray] = NoId
    /\ \E newId \in ArrayId :
        /\ arrayState[newId] = "unalloc"
        /\ newId # currentArray
        /\ arrayState' = [arrayState EXCEPT
                ![newId] = "live",
                ![currentArray] = "linked" ]
        /\ linkedOf'    = [linkedOf EXCEPT ![newId] = currentArray]
        /\ currentArray' = newId
    /\ UNCHANGED <<garbageHead, garbageEpoch, slotVars, bucketLock, pc,
                   ebrVars, historyVars, skipCheckRef>>

MigrateLockOldBucket(t) ==
    /\ pc[t].kind = "idle"
    /\ currentArray \in ArrayId
    /\ \E oldA \in ArrayId :
        /\ linkedOf[currentArray] = oldA
        /\ arrayState[oldA] = "linked"
        /\ \E oldB \in BucketIdx :
            /\ bucketLock[<<oldA, oldB>>] = "unlocked"
            /\ bucketLock' = [bucketLock EXCEPT
                              ![<<oldA, oldB>>] = "writer"]
            /\ pc' = [pc EXCEPT ![t] = [@ EXCEPT
                  !.kind = "rehasher",
                  !.step = "old_locked",
                  !.cachedArray = currentArray,
                  !.bucketIdx = oldB,
                  !.migrating = [old_aid |-> oldA,
                                 target_aid |-> currentArray,
                                 bidx |-> oldB,
                                 key |-> NONE] ]]
    /\ UNCHANGED <<bucketArrayVars, slotVars, ebrVars, historyVars,
                   skipCheckRef>>

\* bucket.rs:329-346 — extract_from. Pick a key in old bucket and publish to
\* new bucket. (publish-new half of Family 2)
MigratePublishNew(t) ==
    /\ pc[t].kind = "rehasher"
    /\ pc[t].step = "old_locked"
    /\ LET m == pc[t].migrating
           newA == m.target_aid
       IN
        /\ \E k \in Key :
              /\ occBit[<<m.old_aid, m.bidx, k>>]
              /\ ~remBit[<<m.old_aid, m.bidx, k>>]
              /\ \E newB \in BucketIdx :
                    /\ ~occBit[<<newA, newB, k>>]
                    /\ occBit'  = [occBit  EXCEPT ![<<newA, newB, k>>] = TRUE]
                    /\ slotVal' = [slotVal EXCEPT ![<<newA, newB, k>>] =
                                                  slotVal[<<m.old_aid, m.bidx, k>>]]
                    /\ pc' = [pc EXCEPT ![t] = [@ EXCEPT
                          !.step = "published",
                          !.migrating = [m EXCEPT !.key = k] ]]
    /\ UNCHANGED <<bucketArrayVars, remBit, slotPubEpoch, bucketLock,
                   ebrVars, historyVars, skipCheckRef>>

\* bucket.rs:348-364 — clear-old.
MigrateClearOld(t) ==
    /\ pc[t].kind = "rehasher"
    /\ pc[t].step = "published"
    /\ LET m == pc[t].migrating
           oldS == <<m.old_aid, m.bidx, m.key>>
       IN
        /\ occBit'  = [occBit  EXCEPT ![oldS] = FALSE]
        /\ slotVal' = [slotVal EXCEPT ![oldS] = NONE]
        /\ pc' = [pc EXCEPT ![t] = [@ EXCEPT !.step = "cleared"]]
    /\ UNCHANGED <<bucketArrayVars, remBit, slotPubEpoch, bucketLock,
                   ebrVars, historyVars, skipCheckRef>>

\* No-op migrate: bucket has no live keys (nothing to relocate).
MigrateEmpty(t) ==
    /\ pc[t].kind = "rehasher"
    /\ pc[t].step = "old_locked"
    /\ LET m == pc[t].migrating
       IN
        /\ \A k \in Key :
              \/ ~occBit[<<m.old_aid, m.bidx, k>>]
              \/ remBit[<<m.old_aid, m.bidx, k>>]
        /\ pc' = [pc EXCEPT ![t] = [@ EXCEPT !.step = "cleared"]]
    /\ UNCHANGED <<bucketArrayVars, slotVars, bucketLock, ebrVars,
                   historyVars, skipCheckRef>>

MigrateKillOldBucket(t) ==
    /\ pc[t].kind = "rehasher"
    /\ pc[t].step = "cleared"
    /\ LET m == pc[t].migrating
           oldP == <<m.old_aid, m.bidx>>
       IN
        /\ bucketLock[oldP] = "writer"
        /\ bucketLock' = [bucketLock EXCEPT ![oldP] = "killed"]
    /\ pc' = [pc EXCEPT ![t] = IdleRec]
    /\ UNCHANGED <<bucketArrayVars, slotVars, ebrVars, historyVars,
                   skipCheckRef>>

EndIncrementalRehash(t) ==
    /\ pc[t].kind = "idle"
    /\ \E oldA \in ArrayId :
        /\ linkedOf[currentArray] = oldA
        /\ arrayState[oldA] = "linked"
        /\ \A b \in BucketIdx : bucketLock[<<oldA, b>>] = "killed"
        \* All buckets cleared (no live data left in old array)
        /\ \A b \in BucketIdx, k \in Key : ~occBit[<<oldA, b, k>>]
        /\ linkedOf'    = [linkedOf EXCEPT ![currentArray] = NoId]
        /\ arrayState'  = [arrayState EXCEPT ![oldA] = "garbage"]
        /\ garbageHead' = oldA
        /\ garbageEpoch' = globalEpoch
        /\ deferReclaim' = deferReclaim \cup {oldA}
    /\ UNCHANGED <<currentArray, slotVars, bucketLock, pc,
                   globalEpoch,
                   inserted, removedHistory, iterCompleted, iterStartLive,
                   iterEndAlsoLive, iterSeenRemove, skipCheckRef>>

DeallocGarbage(t) ==
    /\ pc[t].kind = "idle"
    /\ garbageHead # NoId
    /\ LET gh == garbageHead
       IN
       /\ ~ EpochPinned(garbageEpoch)
       /\ arrayState' = [arrayState EXCEPT ![gh] = "freed"]
       /\ garbageHead' = NoId
       /\ garbageEpoch' = 0
       /\ deferReclaim' = deferReclaim \ {gh}
    /\ UNCHANGED <<currentArray, linkedOf, slotVars, bucketLock, pc,
                   globalEpoch,
                   inserted, removedHistory, iterCompleted, iterStartLive,
                   iterEndAlsoLive, iterSeenRemove, skipCheckRef>>

\* ========================================================================
\* Section D — Family 2 adversary: legacy Relaxed clear-old ordering
\* ========================================================================
\* Pre-9573fa1 ordering: clear-old happened BEFORE publish-new.
MigrateClearOldRelaxedLegacy(t) ==
    /\ pc[t].kind = "rehasher"
    /\ pc[t].step = "old_locked"
    /\ LET m == pc[t].migrating
       IN
        /\ \E k \in Key :
              /\ occBit[<<m.old_aid, m.bidx, k>>]
              /\ ~remBit[<<m.old_aid, m.bidx, k>>]
              \* legacy: clear old first (before publish-new), Relaxed
              /\ occBit'  = [occBit  EXCEPT ![<<m.old_aid, m.bidx, k>>] = FALSE]
              /\ slotVal' = [slotVal EXCEPT ![<<m.old_aid, m.bidx, k>>] = NONE]
              /\ pc' = [pc EXCEPT ![t] = [@ EXCEPT
                        !.step = "legacy_cleared",
                        !.migrating = [m EXCEPT !.key = k],
                        !.key = k,
                        !.val = slotVal[<<m.old_aid, m.bidx, k>>] ]]
    /\ UNCHANGED <<bucketArrayVars, remBit, slotPubEpoch, bucketLock,
                   ebrVars, historyVars, skipCheckRef>>

MigratePublishNewLegacy(t) ==
    /\ pc[t].kind = "rehasher"
    /\ pc[t].step = "legacy_cleared"
    /\ LET m == pc[t].migrating
           newA == m.target_aid
           k == m.key
       IN
        /\ \E newB \in BucketIdx :
              /\ ~occBit[<<newA, newB, k>>]
              /\ occBit'  = [occBit  EXCEPT ![<<newA, newB, k>>] = TRUE]
              /\ slotVal' = [slotVal EXCEPT ![<<newA, newB, k>>] = pc[t].val]
              /\ pc' = [pc EXCEPT ![t] = [@ EXCEPT !.step = "cleared"]]
    /\ UNCHANGED <<bucketArrayVars, remBit, slotPubEpoch, bucketLock,
                   ebrVars, historyVars, skipCheckRef>>

\* ========================================================================
\* Section E — Family 3 adversary: BucketArray swap during await
\* ========================================================================

ForcedSkipCheckRef(t) ==
    /\ pc[t].kind \in {"writer", "reader"}
    /\ pc[t].step = "loaded_array"
    /\ skipCheckRef' = [skipCheckRef EXCEPT ![t] = TRUE]
    /\ UNCHANGED <<bucketArrayVars, slotVars, bucketLock, pc, ebrVars,
                   historyVars>>

CheckRefMismatchAndBail(t) ==
    /\ pc[t].kind \in {"writer", "reader"}
    /\ pc[t].step = "loaded_array"
    /\ pc[t].cachedArray # currentArray
    /\ pc' = [pc EXCEPT ![t] = IdleRec]
    /\ UNCHANGED <<bucketArrayVars, slotVars, bucketLock, ebrVars,
                   historyVars, skipCheckRef>>

\* ========================================================================
\* Section F — EBR epoch advancement (Family 4)
\* ========================================================================

AdvanceGlobalEpoch ==
    /\ globalEpoch < MaxEpoch
    /\ globalEpoch' = globalEpoch + 1
    /\ UNCHANGED <<bucketArrayVars, slotVars, bucketLock, pc,
                   deferReclaim, historyVars, skipCheckRef>>

\* ========================================================================
\* Next
\* ========================================================================

Next ==
    \E t \in Thread :
        \/ \E k \in Key, v \in Value : WriterStart(t, k, v)
        \/ WriterMaybeRehashOK(t)
        \/ WriterMaybeRehashRetry(t)
        \/ WriterAcquireLock(t)
        \/ WriterCommitInsert(t)
        \/ WriterCommitMarkRemoved(t)
        \/ WriterRelease(t)
        \/ IterStart(t)
        \/ IterReadOccupied(t)
        \/ IterReadEmpty(t)
        \/ IterAdvanceWithinBucket(t)
        \/ IterCrossArray(t)
        \/ IterFinish(t)
        \/ TryResize(t)
        \/ MigrateLockOldBucket(t)
        \/ MigratePublishNew(t)
        \/ MigrateClearOld(t)
        \/ MigrateEmpty(t)
        \/ MigrateKillOldBucket(t)
        \/ EndIncrementalRehash(t)
        \/ DeallocGarbage(t)
        \/ MigrateClearOldRelaxedLegacy(t)
        \/ MigratePublishNewLegacy(t)
        \/ ForcedSkipCheckRef(t)
        \/ CheckRefMismatchAndBail(t)
    \/ AdvanceGlobalEpoch

Spec == Init /\ [][Next]_allVars

\* ========================================================================
\* Invariants
\* ========================================================================

TypeOK ==
    /\ currentArray \in ArrayId
    /\ globalEpoch \in 1..MaxEpoch
    /\ \A a \in ArrayId : arrayState[a] \in {"unalloc","live","linked","garbage","freed"}
    /\ \A s \in SlotIdx : occBit[s] \in BOOLEAN
    /\ \A s \in SlotIdx : remBit[s] \in BOOLEAN
    /\ \A p \in ArrayId \X BucketIdx :
        bucketLock[p] \in {"unlocked","writer","killed"}
    /\ \A a \in ArrayId : linkedOf[a] \in {NoId} \cup ArrayId
    /\ garbageHead \in {NoId} \cup ArrayId

AtMostOneLive ==
    Cardinality({a \in ArrayId : arrayState[a] = "live"}) <= 1

AtMostOneLinked ==
    Cardinality({a \in ArrayId : arrayState[a] = "linked"}) <= 1

CurrentLive ==
    arrayState[currentArray] = "live"

\* When an array is "live" and its linkedOf is set (not NoId), the target
\* must currently be in "linked" state.  All operands are integer-typed
\* (NoId = 0; ArrayId = 1..MaxArrays; both subsets of Int).
LinkedConsistent ==
    \A a \in ArrayId :
        (arrayState[a] = "live" /\ linkedOf[a] # NoId) =>
            arrayState[linkedOf[a]] = "linked"

\* --- Family 1 invariants ---

\* A key (k,v) that was live at iterStart AND at iterFinish, AND was not
\* concurrently removed during the iter, MUST have been visited (or remain
\* live somewhere in a non-freed array).  Concurrent removes are excluded
\* because scc explicitly does not promise iterator linearizability under
\* concurrent removal — re-inserts after a remove are a different "instance".
NoLiveKeyMissedByCompletedIter ==
    \A t \in Thread :
        iterCompleted[t] =>
            \A kv \in (iterStartLive[t] \cap iterEndAlsoLive[t]) \ iterSeenRemove[t] :
                \/ kv \in pc[t].visited
                \/ \E s \in SlotIdx :
                       /\ arrayState[s[1]] # "freed"
                       /\ occBit[s]
                       /\ ~remBit[s]
                       /\ s[3] = kv[1]
                       /\ slotVal[s] = kv[2]

\* --- Family 2 invariants ---

\* MigrationVisibleEverywhere: in the legacy_cleared state, the entry must
\* still be occupied SOMEWHERE (old or new array).
MigrationVisibleEverywhere ==
    \A t \in Thread :
        (pc[t].kind = "rehasher" /\ pc[t].step = "legacy_cleared") =>
            \E s \in SlotIdx :
                /\ occBit[s]
                /\ s[3] = pc[t].key

\* NoDuplicatePublication: a key is occupied in at most 2 array slots at any
\* moment — between PublishNew and ClearOld it's in both old and new.
NoDuplicatePublication ==
    \A k \in Key :
        Cardinality({ s \in SlotIdx :
                      /\ occBit[s]
                      /\ ~remBit[s]
                      /\ s[3] = k }) <= 2

\* --- Family 3 invariants ---

NoOrphanedLockedBucket ==
    \A t \in Thread :
        (pc[t].kind \in {"writer", "rehasher"} /\ pc[t].step = "locked"
         /\ pc[t].cachedArray # NoId) =>
            \/ ReachableFromCurrent(pc[t].cachedArray)
            \/ pc[t].cachedArray = currentArray

\* --- Family 4 invariants ---

NoUseAfterFree ==
    \A t \in Thread :
        (pc[t].kind = "iter" /\ pc[t].step \in {"scanning", "done"}
         /\ pc[t].cachedArray # NoId) =>
            arrayState[pc[t].cachedArray] # "freed"

\* --- F5 invariant ---

NoLeakedBucketLock ==
    (\A t \in Thread : pc[t].kind \notin {"rehasher","writer"}) =>
       \A p \in ArrayId \X BucketIdx : bucketLock[p] # "writer"

\* --- Sanity ---

InsertedConsistency ==
    \A kv \in inserted :
        \/ kv \in removedHistory
        \/ \E s \in SlotIdx :
              /\ occBit[s]
              /\ s[3] = kv[1]
              /\ slotVal[s] = kv[2]
              /\ arrayState[s[1]] # "freed"

====
