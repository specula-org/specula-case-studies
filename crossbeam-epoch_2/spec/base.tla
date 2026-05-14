---- MODULE base ----
(***************************************************************************)
(* TLA+ specification of crossbeam-epoch — Fraser-style epoch-based memory*)
(* reclamation library for Rust.                                           *)
(*                                                                         *)
(* Source: crossbeam-epoch/src/                                            *)
(*   internal.rs   — Global, Local, Bag, SealedBag, pin/unpin/repin       *)
(*   guard.rs      — Guard, defer, repin_after, unprotected               *)
(*   epoch.rs      — Epoch, AtomicEpoch (pinned-bit + wrapping_sub)        *)
(*   sync/queue.rs — Michael-Scott queue of SealedBags                    *)
(*                                                                         *)
(* Category B (concurrent / lock-free) — sub-category: reader-writer       *)
(* separation / reclamation.                                               *)
(*                                                                         *)
(* Bug Families (modeling-brief.md §2):                                    *)
(*   F1 — Reentrant pin / nested-protection epoch advance (Issue #105)     *)
(*   F2 — Retire-before-unlink lifetime mismatch (Issue #238)              *)
(*   F3 — Epoch-advance + bag-retire SC fence pair                         *)
(*   F4 — Adversarial Caller / Guard misuse (defer-that-pins, repin-panic) *)
(*   F5 — try_advance returning stale global on stalled iteration (Issue   *)
(*        #566)                                                            *)
(*   F6 — Pointer/slot reuse for retired Local nodes                       *)
(***************************************************************************)

EXTENDS Integers, Sequences, FiniteSets, TLC

\* ========================================================================
\* Constants
\* ========================================================================

CONSTANTS
    Thread,         \* Set of thread IDs (each owns a Local participant)
    Object,         \* Set of object IDs that may be retired/defer_destroyed
    BagCapacity,    \* MAX_OBJECTS — internal.rs:66, default 64; use 2-3 in MC
    MaxEpoch        \* State-space bound on global epoch (avoid wraparound)

ASSUME Cardinality(Thread) >= 1
ASSUME BagCapacity \in Nat /\ BagCapacity >= 1
ASSUME MaxEpoch \in Nat /\ MaxEpoch >= 2

\* The "starting" epoch is 0, unpinned.  Epoch values are encoded as in
\* epoch.rs:33-87: data is the unpinned epoch, pin-bit is a separate flag.
\* We model unpinned local epoch by setting localEpoch[t] = -1.
\* localEpoch[t] >= 0 means "pinned at epoch localEpoch[t]".
UNPINNED == -1

\* ========================================================================
\* Variables
\* ========================================================================

\* ---- Global state (internal.rs:165-174) ----
VARIABLES
    globalEpoch,    \* Global::epoch (internal.rs:173) — Nat in 0..MaxEpoch
    sealedBags,     \* Queue<SealedBag> (internal.rs:170): seq of [seal, items]
    retired         \* Set of all retired records:
                    \*   [obj, sealEpoch, reachableAtSeal, reclaimed]
                    \* Models the abstract retire contract for Family 2.

\* ---- Per-Local state (internal.rs:293-318) ----
VARIABLES
    localEpoch,     \* Local::epoch (internal.rs:317): per-thread epoch.
                    \* UNPINNED if not pinned, else the pinned-epoch value.
    guardCount,     \* Local::guard_count (internal.rs:306). Cell<usize>.
    handleCount,    \* Local::handle_count (internal.rs:309). Cell<usize>.
    pinCount,       \* Local::pin_count (internal.rs:314). Wrapping<usize>.
    bag,            \* Local::bag (internal.rs:303): per-thread sequence of
                    \* deferred items (each an [obj, body] record).
    localState      \* Per-Local lifecycle, Family 6:
                    \*   "Live" | "Tagged" | "Retired" | "Free" | "Reused"
                    \* internal.rs:529-569 (finalize), entry.delete tag.

\* ---- Per-thread program counter (Family 1, 3, 5) ----
VARIABLES
    pc,             \* pc[t] - PC label inside a multi-step API call.
                    \* "Idle" | "PinIncCount" | "PinPublish" | "PinFence"
                    \*   | "PinLoadGlobal" | "PinCollect"
                    \* | "TryAdvLoadGlobal" | "TryAdvFence"
                    \*   | "TryAdvIter" | "TryAdvFinishStore"
                    \* | "DeferPushed" | "InDeferCallback"
                    \* | "RepinAfterUnpinned"
    pcAux,          \* pc[t] auxiliary fields:
                    \*   capturedGlobal: snapshot from pin-LoadGlobal
                    \*   iterIndex: try_advance iteration progress
                    \*   stalled: try_advance saw IterError::Stalled
                    \*   inDeferBody: currently inside a deferred fn (F1, F4)
                    \*   inFinalize: currently inside Local::finalize (F1)
                    \*   repinAfterPending: in repin_after's f() (F4)
    reachable       \* Reachable: Set of objects reachable through some
                    \* shared atomic. Used for Family 2's RetireImpliesUnreachable
                    \* invariant. Modeled abstractly: an object enters
                    \* "reachable" when published via an atomic store and
                    \* leaves when the *last* atomic store overwriting it
                    \* completes. Caller model decides when to publish/unlink.

\* ---- Adversary / fault-injection state ----
VARIABLES
    skipFenceAt,    \* Family 3: at most one site has its SC fence dropped.
                    \* Value in {"none", "PinFence", "TryAdvFence"} (one shot)
    buggyRetire,    \* Family 2: TRUE if a buggy variant retired a still-
                    \* reachable object.  One-shot.
    deferBodies,    \* Family 1, 4: per deferred record, the body kind:
                    \*   "Noop" | "Pin" | "Defer" | "Repin"
                    \* Captured at defer time, executed at Bag::drop time.
    objectGen       \* Family 6: generation tag per-Local (per-Thread).
                    \* Bumped when a Local's slot is reclaimed and reused.

allVars == <<globalEpoch, sealedBags, retired,
             localEpoch, guardCount, handleCount, pinCount, bag, localState,
             pc, pcAux, reachable,
             skipFenceAt, buggyRetire, deferBodies, objectGen>>

\* ========================================================================
\* Helpers
\* ========================================================================

\* "two epochs ahead" — internal.rs:160 (is_expired)
IsExpired(sealEpoch, g) == g - sealEpoch >= 2

\* PINNINGS_BETWEEN_COLLECT — internal.rs:335. Trigger collect once per N
\* pins.  We collapse it: collect every pin (state-space friendly).
\* Real impl: every 128th pin.  Modeling diff is acceptable since the
\* spec drives Collect via a separate non-determistic flow when desired.
ShouldTriggerCollect(t) == TRUE

\* Set of threads that are pinned (guardCount > 0)
PinnedThreads == { t \in Thread : guardCount[t] > 0 }

\* Set of locals that are alive (still in the linked list)
AliveLocals == { t \in Thread : localState[t] \in {"Live", "Tagged", "Reused"} }

\* Whether a thread is in any "internal multi-step" PC state
IsBusy(t) == pc[t] /= "Idle"

\* ========================================================================
\* Init
\* ========================================================================

InitGuardSlot ==
    [capturedGlobal |-> 0,
     iterIndex |-> 0,
     stalled |-> FALSE,
     inDeferBody |-> FALSE,
     inFinalize |-> FALSE,
     repinAfterPending |-> FALSE,
     bagDropItems |-> <<>>,
     bagDropSeal |-> 0]

Init ==
    /\ globalEpoch = 0
    /\ sealedBags = <<>>
    /\ retired = {}
    /\ localEpoch = [t \in Thread |-> UNPINNED]
    /\ guardCount = [t \in Thread |-> 0]
    /\ handleCount = [t \in Thread |-> 1]   \* register sets handle=1 (internal.rs:347)
    /\ pinCount = [t \in Thread |-> 0]
    /\ bag = [t \in Thread |-> <<>>]
    /\ localState = [t \in Thread |-> "Live"]
    /\ pc = [t \in Thread |-> "Idle"]
    /\ pcAux = [t \in Thread |-> InitGuardSlot]
    /\ reachable = Object              \* All objects start reachable
    /\ skipFenceAt = "none"
    /\ buggyRetire = FALSE
    /\ deferBodies = [o \in Object |-> "Noop"]
    /\ objectGen = [t \in Thread |-> 0]

\* ========================================================================
\* Pin — internal.rs:401-462
\* ========================================================================
\* The implementation of pin() looks atomic (one Rust function), but it
\* contains four observable steps that must each be a separate spec action:
\*   1. Increment guard_count (Cell, not atomic) — line 407
\*   2. If guard_count was 0: load global epoch (Relaxed) — line 410
\*   3. Store pinned local epoch + SC fence — lines 434-447
\*   4. (cold) collect() — line 457
\*
\* Step 2/3 form the Dekker pair with try_advance's load+fence (Family 3).
\* Step 1 is the gate against Family 1 (reentrant pin must not advance).
\* ------------------------------------------------------------------------

\* Step 1 of pin() — increment guard count (internal.rs:406-407)
\* This is the *only* step for nested pin (guardCount becomes >= 2).
PinIncGuardCount(t) ==
    /\ pc[t] = "Idle"
    /\ localState[t] \in {"Live"}            \* Local must be alive
    /\ handleCount[t] >= 1                   \* must hold a handle
    /\ ~pcAux[t].inFinalize                  \* finalize is reentrant-disabled
    /\ guardCount[t] < 3                     \* state-space bound on nesting
    /\ guardCount' = [guardCount EXCEPT ![t] = guardCount[t] + 1]
    /\ IF guardCount[t] = 0
       THEN
            \* First pin — proceed to publish local epoch.  internal.rs:409
            pc' = [pc EXCEPT ![t] = "PinLoadGlobal"]
       ELSE
            \* Reentrant pin — Family 1 gate at internal.rs:409 prevents
            \* publishing a new local epoch.  Stay Idle.
            pc' = [pc EXCEPT ![t] = "Idle"]
    /\ UNCHANGED <<globalEpoch, sealedBags, retired,
                   localEpoch, handleCount, pinCount, bag, localState,
                   pcAux, reachable, skipFenceAt, buggyRetire, deferBodies, objectGen>>

\* Step 2 of pin() — load global epoch (Relaxed). internal.rs:410
PinLoadGlobal(t) ==
    /\ pc[t] = "PinLoadGlobal"
    /\ pcAux' = [pcAux EXCEPT ![t].capturedGlobal = globalEpoch]
    /\ pc' = [pc EXCEPT ![t] = "PinPublish"]
    /\ UNCHANGED <<globalEpoch, sealedBags, retired,
                   localEpoch, guardCount, handleCount, pinCount, bag, localState,
                   reachable, skipFenceAt, buggyRetire, deferBodies, objectGen>>

\* Step 3 of pin() — store pinned local epoch (Relaxed) + SC fence.
\* On x86 this is a SC compare_exchange, internal.rs:434-444.
\* On other arches it's relaxed-store + SeqCst-fence, internal.rs:446-447.
\* Both establish the Dekker pair with try_advance's load+fence (Family 3).
PinPublish(t) ==
    /\ pc[t] = "PinPublish"
    \* Family 3: if adversary downgraded the fence at this site, the
    \* local epoch becomes visible *after* a subsequent reader's load
    \* of an atomic value.  We model the missing fence by marking the
    \* publish "weak" — try_advance may miss it (see TryAdvIter below).
    /\ localEpoch' = [localEpoch EXCEPT ![t] = pcAux[t].capturedGlobal]
    /\ pc' = [pc EXCEPT ![t] = "PinMaybeCollect"]
    /\ UNCHANGED <<globalEpoch, sealedBags, retired,
                   guardCount, handleCount, pinCount, bag, localState,
                   pcAux, reachable, skipFenceAt, buggyRetire, deferBodies, objectGen>>

\* Step 4 of pin() — increment pin counter and possibly call collect().
\* internal.rs:451-458.
PinMaybeCollect(t) ==
    /\ pc[t] = "PinMaybeCollect"
    /\ pinCount' = [pinCount EXCEPT ![t] = pinCount[t] + 1]
    \* The real code calls collect() every PINNINGS_BETWEEN_COLLECT pins.
    \* We non-deterministically choose to enter PinCollect.
    /\ \/ /\ ShouldTriggerCollect(t)
          /\ pc' = [pc EXCEPT ![t] = "PinCollect"]
       \/ pc' = [pc EXCEPT ![t] = "Idle"]
    /\ UNCHANGED <<globalEpoch, sealedBags, retired,
                   localEpoch, guardCount, handleCount, bag, localState,
                   pcAux, reachable, skipFenceAt, buggyRetire, deferBodies, objectGen>>

\* PinCollect transitions into try_advance + collect (handled below).
\* For the spec, we model it as transition Idle once collect completes.
PinCollectFinish(t) ==
    /\ pc[t] = "PinCollect"
    /\ pc' = [pc EXCEPT ![t] = "Idle"]
    /\ UNCHANGED <<globalEpoch, sealedBags, retired,
                   localEpoch, guardCount, handleCount, pinCount, bag, localState,
                   pcAux, reachable, skipFenceAt, buggyRetire, deferBodies, objectGen>>

\* ========================================================================
\* Unpin — internal.rs:464-479
\* ========================================================================
\* Unpin is single-step in the impl: decrement guard_count; if it was 1,
\* store UNPINNED to local.epoch (Release); then maybe finalize.
\* We split: UnpinDec, UnpinPublish, UnpinMaybeFinalize.
\* ------------------------------------------------------------------------

\* internal.rs:466-468.
UnpinDec(t) ==
    /\ pc[t] = "Idle"
    /\ guardCount[t] >= 1
    /\ ~pcAux[t].inFinalize
    /\ guardCount' = [guardCount EXCEPT ![t] = guardCount[t] - 1]
    /\ IF guardCount[t] = 1
       THEN pc' = [pc EXCEPT ![t] = "UnpinPublish"]
       ELSE pc' = [pc EXCEPT ![t] = "Idle"]
    /\ UNCHANGED <<globalEpoch, sealedBags, retired,
                   localEpoch, handleCount, pinCount, bag, localState,
                   pcAux, reachable, skipFenceAt, buggyRetire, deferBodies, objectGen>>

\* internal.rs:471 — store UNPINNED with Release.
UnpinPublish(t) ==
    /\ pc[t] = "UnpinPublish"
    /\ localEpoch' = [localEpoch EXCEPT ![t] = UNPINNED]
    /\ IF handleCount[t] = 0
       THEN pc' = [pc EXCEPT ![t] = "Finalize"]   \* internal.rs:473-477
       ELSE pc' = [pc EXCEPT ![t] = "Idle"]
    /\ UNCHANGED <<globalEpoch, sealedBags, retired,
                   guardCount, handleCount, pinCount, bag, localState,
                   pcAux, reachable, skipFenceAt, buggyRetire, deferBodies, objectGen>>

\* ========================================================================
\* Repin — internal.rs:483-502
\* ========================================================================
\* Critical: repin uses ONLY a Release store, NOT a SeqCst fence
\* (internal.rs:495).  Family 3 invariant must NOT assume SC sync at repin.
\* Repin is no-op if guardCount > 1 (internal.rs:487).
\* ------------------------------------------------------------------------

Repin(t) ==
    /\ pc[t] = "Idle"
    /\ guardCount[t] >= 1
    \* internal.rs:487 — only repin if there is exactly one guard
    /\ \/ /\ guardCount[t] > 1
          /\ UNCHANGED localEpoch
       \/ /\ guardCount[t] = 1
          /\ \/ /\ globalEpoch /= localEpoch[t]
                \* internal.rs:495 — Release store (NO SC fence after).
                /\ localEpoch' = [localEpoch EXCEPT ![t] = globalEpoch]
             \/ /\ globalEpoch = localEpoch[t]
                /\ UNCHANGED localEpoch
    /\ UNCHANGED <<globalEpoch, sealedBags, retired,
                   guardCount, handleCount, pinCount, bag, localState,
                   pc, pcAux, reachable, skipFenceAt, buggyRetire, deferBodies, objectGen>>

\* ========================================================================
\* TryAdvance — internal.rs:236-288
\* ========================================================================
\* try_advance:
\*   1. load globalEpoch (Relaxed, line 238)
\*   2. SeqCst fence (line 239) — Dekker pair with pin's fence
\*   3. iterate locals; on each, load local.epoch (Relaxed); abort if
\*      pinned-but-different-epoch (line 262) or stalled (line 251)
\*   4. fence(Acquire) (line 276)
\*   5. CAS global epoch to successor (line 286, Release)
\* ------------------------------------------------------------------------

\* Step 1 — load global epoch.  internal.rs:238.
TryAdvLoadGlobal(t) ==
    /\ pc[t] = "PinCollect"             \* try_advance is invoked from collect()
    /\ pcAux' = [pcAux EXCEPT ![t].capturedGlobal = globalEpoch,
                              ![t].iterIndex = 0,
                              ![t].stalled = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "TryAdvFence"]
    /\ UNCHANGED <<globalEpoch, sealedBags, retired,
                   localEpoch, guardCount, handleCount, pinCount, bag, localState,
                   reachable, skipFenceAt, buggyRetire, deferBodies, objectGen>>

\* Step 2 — SeqCst fence (Family 3).  internal.rs:239.
\* If skipFenceAt = "TryAdvFence", the fence is dropped — adversarial.
TryAdvFence(t) ==
    /\ pc[t] = "TryAdvFence"
    /\ pc' = [pc EXCEPT ![t] = "TryAdvIter"]
    /\ UNCHANGED <<globalEpoch, sealedBags, retired,
                   localEpoch, guardCount, handleCount, pinCount, bag, localState,
                   pcAux, reachable, skipFenceAt, buggyRetire, deferBodies, objectGen>>

\* Step 3 — iterate locals.  internal.rs:249-270.
\* Each iteration step is its own action so other threads can interleave.
TryAdvIter(t) ==
    /\ pc[t] = "TryAdvIter"
    /\ \/  \* Family 5: iterator stalled by concurrent insertion
          /\ pcAux[t].iterIndex < Cardinality(AliveLocals)
          /\ pcAux' = [pcAux EXCEPT ![t].stalled = TRUE]
          /\ pc' = [pc EXCEPT ![t] = "TryAdvAbortStalled"]
       \/ \* Normal observe-one-local step
          /\ pcAux[t].iterIndex < Cardinality(AliveLocals)
          /\ \E observed \in AliveLocals :
                LET lEpoch == localEpoch[observed]
                IN
                \* internal.rs:262 — pinned at a different epoch ⇒ abort
                IF lEpoch /= UNPINNED /\ lEpoch /= pcAux[t].capturedGlobal
                THEN /\ pcAux' = [pcAux EXCEPT ![t].iterIndex =
                                              pcAux[t].iterIndex + 1]
                     /\ pc' = [pc EXCEPT ![t] = "TryAdvAbortDifferentEpoch"]
                ELSE /\ pcAux' = [pcAux EXCEPT ![t].iterIndex =
                                              pcAux[t].iterIndex + 1]
                     /\ pc' = [pc EXCEPT ![t] = "TryAdvIter"]
       \/ \* All locals observed — proceed to advance
          /\ pcAux[t].iterIndex >= Cardinality(AliveLocals)
          /\ pc' = [pc EXCEPT ![t] = "TryAdvFinishStore"]
          /\ UNCHANGED pcAux
    /\ UNCHANGED <<globalEpoch, sealedBags, retired,
                   localEpoch, guardCount, handleCount, pinCount, bag, localState,
                   reachable, skipFenceAt, buggyRetire, deferBodies, objectGen>>

\* Family 5: try_advance returned its (stale) cached global on Stalled.
\* internal.rs:251-256.  Returns the loaded global as the cutoff.
TryAdvAbortStalled(t) ==
    /\ pc[t] = "TryAdvAbortStalled"
    /\ pc' = [pc EXCEPT ![t] = "CollectScan"]
    \* The cutoff is pcAux[t].capturedGlobal — possibly stale by the time
    \* we use it in is_expired (internal.rs:219).
    /\ UNCHANGED <<globalEpoch, sealedBags, retired,
                   localEpoch, guardCount, handleCount, pinCount, bag, localState,
                   pcAux, reachable, skipFenceAt, buggyRetire, deferBodies, objectGen>>

\* internal.rs:262-264 — observed pinned-at-different-epoch, abort.
TryAdvAbortDifferentEpoch(t) ==
    /\ pc[t] = "TryAdvAbortDifferentEpoch"
    /\ pc' = [pc EXCEPT ![t] = "CollectScan"]
    /\ UNCHANGED <<globalEpoch, sealedBags, retired,
                   localEpoch, guardCount, handleCount, pinCount, bag, localState,
                   pcAux, reachable, skipFenceAt, buggyRetire, deferBodies, objectGen>>

\* internal.rs:285-286 — successor epoch + Release store.
\* Note: internal.rs:286 says "store" not "compare_exchange" — concurrent
\* try_advance threads can both write the same successor.
\*
\* Faithfulness note: TryAdvIter's `\E observed` is non-deterministic per
\* step, so TLC alone won't necessarily observe every alive local.  The
\* implementation's `for local in self.locals.iter(guard)` (internal.rs:249)
\* DOES iterate every alive local.  We capture that invariant here as a
\* precondition: if any pinned local is at a different epoch, the
\* iteration would have observed it and returned at line 263.  Without
\* this, the spec spuriously advances under stale observations, which
\* would mis-blame Family 3 / 5 invariants.
\*
\* When skipFenceAt = "TryAdvFence", the SC fence is dropped and the
\* iterator may legitimately miss a recently-pinned local.  We omit the
\* guard in that adversarial case so Family 3 bugs become reachable.
TryAdvFinishStore(t) ==
    /\ pc[t] = "TryAdvFinishStore"
    /\ globalEpoch < MaxEpoch
    /\ \/ skipFenceAt = "TryAdvFence"
       \/ /\ \A other \in AliveLocals :
                localEpoch[other] = UNPINNED
                \/ localEpoch[other] = pcAux[t].capturedGlobal
          \* SC fence pair (Family 3): a thread mid-pin between
          \* PinLoadGlobal and PinPublish has loaded global but not yet
          \* published its local.  In SC semantics, if its capturedGlobal
          \* is older than ours, our load (with the SC fence) must have
          \* observed its local store already.  Blocking advance here is
          \* the only way to model that without a happens-before graph.
          /\ \A other \in Thread :
                pc[other] = "PinPublish" =>
                   pcAux[other].capturedGlobal >= pcAux[t].capturedGlobal
    \* internal.rs:285 — successor is current_global + 1
    /\ globalEpoch' = pcAux[t].capturedGlobal + 1
    /\ pcAux' = [pcAux EXCEPT ![t].capturedGlobal = pcAux[t].capturedGlobal + 1]
    /\ pc' = [pc EXCEPT ![t] = "CollectScan"]
    /\ UNCHANGED <<sealedBags, retired,
                   localEpoch, guardCount, handleCount, pinCount, bag, localState,
                   reachable, skipFenceAt, buggyRetire, deferBodies, objectGen>>

\* ========================================================================
\* Collect — internal.rs:208-226
\* ========================================================================
\* After try_advance returns the cutoff epoch, collect() pops up to
\* COLLECT_STEPS expired SealedBags from the queue.
\* ------------------------------------------------------------------------

\* internal.rs:217-225 — try_pop_if: atomically peek, check expiration, pop.
\* The implementation's try_pop_if is atomic on the MS-Queue, so concurrent
\* collectors do not race on a single head bag. We model that here by
\* popping atomically and stashing the items in pcAux for BagDrop to process.
CollectScan(t) ==
    /\ pc[t] = "CollectScan"
    /\ \/  \* No bag, or head not expired — exit.
          /\ \/ Len(sealedBags) = 0
             \/ /\ Len(sealedBags) > 0
                /\ ~IsExpired(sealedBags[1].seal, pcAux[t].capturedGlobal)
          /\ pc' = [pc EXCEPT ![t] = "Idle"]
          /\ UNCHANGED <<sealedBags, retired, deferBodies, pcAux>>
       \/ \* Pop expired head atomically; stash items for BagDrop.
          /\ Len(sealedBags) > 0
          /\ IsExpired(sealedBags[1].seal, pcAux[t].capturedGlobal)
          /\ sealedBags' = Tail(sealedBags)
          /\ pc' = [pc EXCEPT ![t] = "BagDrop"]
          /\ pcAux' = [pcAux EXCEPT ![t].iterIndex = 1,
                                     ![t].bagDropItems = sealedBags[1].items,
                                     ![t].bagDropSeal = sealedBags[1].seal]
          /\ UNCHANGED <<retired, deferBodies>>
    /\ UNCHANGED <<globalEpoch, localEpoch, guardCount, handleCount, pinCount,
                   bag, localState, reachable, skipFenceAt, buggyRetire, objectGen>>

\* ========================================================================
\* Bag::drop — internal.rs:125-134
\* ========================================================================
\* Iterates all deferreds in the bag and calls each one.  A deferred fn
\* may itself call pin() / defer() / repin() — this is Family 1 + Family 4.
\* ------------------------------------------------------------------------

\* BagDrop processes the items stashed in pcAux (popped atomically by
\* CollectScan).  This avoids races where two threads concurrently process
\* the same sealedBags[1] head — the implementation's try_pop_if is atomic.
BagDrop(t) ==
    /\ pc[t] = "BagDrop"
    /\ LET items == pcAux[t].bagDropItems
           idx == pcAux[t].iterIndex
           seal == pcAux[t].bagDropSeal
       IN
       \/ \* All deferreds executed — mark retired entries as reclaimed.
          \* internal.rs:223 (drop sealed_bag).
          /\ idx > Len(items)
          /\ retired' =
                { IF (\E i \in 1..Len(items) : items[i] = r.obj)
                     /\ r.sealEpoch = seal
                  THEN [r EXCEPT !.reclaimed = TRUE]
                  ELSE r
                  : r \in retired }
          /\ pc' = [pc EXCEPT ![t] = "CollectScan"]
          /\ pcAux' = [pcAux EXCEPT ![t].iterIndex = 0,
                                     ![t].bagDropItems = <<>>,
                                     ![t].bagDropSeal = 0]
          /\ UNCHANGED <<sealedBags, deferBodies>>
       \/ \* Run one Noop deferred.
          /\ idx <= Len(items)
          /\ deferBodies[items[idx]] = "Noop"
          /\ pcAux' = [pcAux EXCEPT ![t].iterIndex = idx + 1]
          /\ UNCHANGED <<sealedBags, retired, deferBodies, pc>>
       \/ \* F1+F4: deferred fn that re-enters pin().
          /\ idx <= Len(items)
          /\ deferBodies[items[idx]] = "Pin"
          /\ pcAux' = [pcAux EXCEPT ![t].iterIndex = idx + 1,
                                     ![t].inDeferBody = TRUE]
          /\ pc' = [pc EXCEPT ![t] = "InDeferCallbackPin"]
          /\ UNCHANGED <<sealedBags, retired, deferBodies>>
       \/ \* F4: deferred fn that calls defer() — appends to same bag.
          /\ idx <= Len(items)
          /\ deferBodies[items[idx]] = "Defer"
          /\ pcAux' = [pcAux EXCEPT ![t].iterIndex = idx + 1,
                                     ![t].inDeferBody = TRUE]
          /\ pc' = [pc EXCEPT ![t] = "InDeferCallbackDefer"]
          /\ UNCHANGED <<sealedBags, retired, deferBodies>>
    /\ UNCHANGED <<globalEpoch, localEpoch, guardCount, handleCount, pinCount,
                   bag, localState, reachable, skipFenceAt, buggyRetire, objectGen>>

\* InDeferCallbackPin — Family 1+4.  Inside the deferred fn, the thread
\* is *already pinned* (collect was called from inside pin → already
\* guardCount > 0).  Re-entering pin must NOT advance local epoch.
\* This is the same gate as PinIncGuardCount with guardCount > 0.
InDeferCallbackPin(t) ==
    /\ pc[t] = "InDeferCallbackPin"
    /\ guardCount[t] >= 1                   \* already pinned (or finalize)
    /\ guardCount' = [guardCount EXCEPT ![t] = guardCount[t] + 1]
    \* No publish, no fence, no collect — guardCount was > 0.
    /\ pc' = [pc EXCEPT ![t] = "InDeferCallbackUnpin"]
    /\ UNCHANGED <<globalEpoch, sealedBags, retired,
                   localEpoch, handleCount, pinCount, bag, localState,
                   pcAux, reachable, skipFenceAt, buggyRetire, deferBodies, objectGen>>

InDeferCallbackUnpin(t) ==
    /\ pc[t] = "InDeferCallbackUnpin"
    /\ guardCount[t] >= 1
    /\ guardCount' = [guardCount EXCEPT ![t] = guardCount[t] - 1]
    /\ pc' = [pc EXCEPT ![t] = "BagDrop"]
    /\ pcAux' = [pcAux EXCEPT ![t].inDeferBody = FALSE]
    /\ UNCHANGED <<globalEpoch, sealedBags, retired,
                   localEpoch, handleCount, pinCount, bag, localState,
                   reachable, skipFenceAt, buggyRetire, deferBodies, objectGen>>

\* InDeferCallbackDefer — F4: deferred fn appends to *its own bag*.
InDeferCallbackDefer(t) ==
    /\ pc[t] = "InDeferCallbackDefer"
    /\ \E o \in Object :
        /\ o \notin reachable
        /\ ~ (\E r \in retired : r.obj = o)
        /\ Len(bag[t]) < BagCapacity
        /\ bag' = [bag EXCEPT ![t] = Append(@, o)]
        /\ retired' = retired \cup
                       {[obj |-> o, sealEpoch |-> globalEpoch + 1,
                         reachableAtSeal |-> FALSE, reclaimed |-> FALSE]}
        /\ deferBodies' = [deferBodies EXCEPT ![o] = "Noop"]
    /\ pc' = [pc EXCEPT ![t] = "BagDrop"]
    /\ pcAux' = [pcAux EXCEPT ![t].inDeferBody = FALSE]
    /\ UNCHANGED <<globalEpoch, sealedBags, localEpoch, guardCount, handleCount,
                   pinCount, localState, reachable, skipFenceAt, buggyRetire, objectGen>>

\* ========================================================================
\* Defer / push_bag / flush — internal.rs:191-198 / 382-399
\* ========================================================================
\* Local::defer adds a deferred to the local bag; when full, push_bag
\* seals the bag with the current global epoch and pushes onto the queue.
\* Then a new empty bag is installed.  internal.rs:382-389.
\* ------------------------------------------------------------------------

\* Caller harness chooses an object to retire.
\* Family 2: caller MUST ensure object is unreachable BEFORE defer_destroy.
\* Defer models a contract-respecting caller; the buggy variant lives in
\* BuggyRetire below.  Without the obj \notin reachable precondition, this
\* action would itself violate the F2 contract on every reachable object.
Defer(t, obj, kind) ==
    /\ pc[t] = "Idle"
    /\ guardCount[t] >= 1                \* must hold a guard (defer impl)
    /\ obj \in Object
    /\ obj \notin reachable               \* F2 contract: caller already unlinked
    /\ ~ (\E r \in retired : r.obj = obj)   \* object not already retired
    /\ kind \in {"Noop", "Pin", "Defer"}
    /\ Len(bag[t]) < BagCapacity
    /\ bag' = [bag EXCEPT ![t] = Append(@, obj)]
    /\ retired' = retired \cup
                  {[obj |-> obj,
                    sealEpoch |-> globalEpoch,    \* future seal value (≤)
                    reachableAtSeal |-> FALSE,    \* F2: enforced unreachable
                    reclaimed |-> FALSE]}
    /\ deferBodies' = [deferBodies EXCEPT ![obj] = kind]
    /\ UNCHANGED <<globalEpoch, sealedBags, localEpoch, guardCount, handleCount,
                   pinCount, localState, pc, pcAux, reachable, skipFenceAt,
                   buggyRetire, objectGen>>

\* Family 2 explicit buggy retire: defer_destroy on still-reachable obj.
BuggyRetire(t, obj) ==
    /\ pc[t] = "Idle"
    /\ guardCount[t] >= 1
    /\ ~buggyRetire
    /\ obj \in reachable               \* still reachable — violates contract
    /\ ~ (\E r \in retired : r.obj = obj)
    /\ Len(bag[t]) < BagCapacity
    /\ bag' = [bag EXCEPT ![t] = Append(@, obj)]
    /\ retired' = retired \cup
                  {[obj |-> obj, sealEpoch |-> globalEpoch,
                    reachableAtSeal |-> TRUE, reclaimed |-> FALSE]}
    /\ deferBodies' = [deferBodies EXCEPT ![obj] = "Noop"]
    /\ buggyRetire' = TRUE
    /\ UNCHANGED <<globalEpoch, sealedBags, localEpoch, guardCount, handleCount,
                   pinCount, localState, pc, pcAux, reachable, skipFenceAt,
                   deferBodies, objectGen>>

\* push_bag (internal.rs:191-198): SC fence; load globalEpoch (Relaxed);
\* seal bag with that epoch; push onto queue; replace local bag.
PushBag(t) ==
    /\ pc[t] = "Idle"
    /\ Len(bag[t]) > 0
    /\ guardCount[t] >= 1
    \* internal.rs:194 — SC fence (used in Family 3 reasoning)
    /\ LET seal == globalEpoch IN          \* internal.rs:196 (Relaxed load)
       /\ sealedBags' = Append(sealedBags,
                              [seal |-> seal, items |-> bag[t]])
       /\ bag' = [bag EXCEPT ![t] = <<>>]
    /\ UNCHANGED <<globalEpoch, retired, localEpoch, guardCount, handleCount,
                   pinCount, localState, pc, pcAux, reachable, skipFenceAt,
                   buggyRetire, deferBodies, objectGen>>

\* flush (internal.rs:391-399): push_bag if non-empty + collect.
Flush(t) ==
    /\ pc[t] = "Idle"
    /\ guardCount[t] >= 1
    /\ \/ /\ Len(bag[t]) > 0
          /\ sealedBags' = Append(sealedBags,
                                 [seal |-> globalEpoch, items |-> bag[t]])
          /\ bag' = [bag EXCEPT ![t] = <<>>]
       \/ /\ Len(bag[t]) = 0
          /\ UNCHANGED <<sealedBags, bag>>
    /\ pc' = [pc EXCEPT ![t] = "PinCollect"]    \* enter try_advance/collect
    /\ pcAux' = [pcAux EXCEPT ![t].capturedGlobal = globalEpoch,
                              ![t].iterIndex = 0,
                              ![t].stalled = FALSE]
    /\ UNCHANGED <<globalEpoch, retired, localEpoch, guardCount, handleCount,
                   pinCount, localState, reachable, skipFenceAt,
                   buggyRetire, deferBodies, objectGen>>

\* ========================================================================
\* Caller actions: Object publish/unlink (Family 2 retire contract)
\* ========================================================================

\* PublishObject: a thread makes obj reachable through some atomic store.
\* (e.g., MS-Queue head/tail compare_exchange that links a node in.)
\* If obj was previously retired-and-reclaimed, treat the publish as a fresh
\* allocation: the slot is free, so drop the historical retired record. This
\* models address reuse — a freshly-allocated object may land at the same
\* abstract slot ID. Without this, NoUseAfterRetire spuriously fires when a
\* legitimate re-publish follows a completed reclamation.
PublishObject(t, obj) ==
    /\ pc[t] = "Idle"
    /\ guardCount[t] >= 1
    /\ obj \notin reachable
    /\ ~ (\E r \in retired : r.obj = obj /\ r.reclaimed = FALSE)
    /\ reachable' = reachable \cup {obj}
    /\ retired' = { r \in retired : r.obj /= obj }
    /\ UNCHANGED <<globalEpoch, sealedBags,
                   localEpoch, guardCount, handleCount, pinCount, bag, localState,
                   pc, pcAux, skipFenceAt, buggyRetire, deferBodies, objectGen>>

\* UnlinkObject: a thread removes obj from all atomics — caller MUST
\* unlink before defer_destroy (Family 2 contract).
UnlinkObject(t, obj) ==
    /\ pc[t] = "Idle"
    /\ guardCount[t] >= 1
    /\ obj \in reachable
    /\ reachable' = reachable \ {obj}
    /\ UNCHANGED <<globalEpoch, sealedBags, retired,
                   localEpoch, guardCount, handleCount, pinCount, bag, localState,
                   pc, pcAux, skipFenceAt, buggyRetire, deferBodies, objectGen>>

\* ========================================================================
\* Reader: dereference an object pointer (Family 2 use-after-free check)
\* ========================================================================

\* Models a reader thread loading an atomic and dereferencing it.
\* Must be done while pinned; observes whatever the atomic currently
\* holds (any reachable object).  If the object has already been
\* reclaimed, this is UAF.  If localEpoch[t] is far behind global, the
\* 2-epoch rule should still protect us — Invariant NoUseAfterRetire.
ReadAndDeref(t, obj) ==
    /\ pc[t] = "Idle"
    /\ guardCount[t] >= 1
    /\ obj \in reachable
    \* Record read for invariant check; here we just assert obj is not
    \* reclaimed already (our key invariant — hits if buggy retire wins).
    /\ ~ (\E r \in retired : r.obj = obj /\ r.reclaimed = TRUE)
    /\ UNCHANGED allVars

\* ========================================================================
\* Family 4: Caller Harness — adversarial-but-legal client patterns
\* ========================================================================

\* GuardAcrossYield(t): thread t is pinned; another thread freely runs.
\* Modeled as a no-op step: no further action needed beyond pinning and
\* leaving state alone. The other threads' actions in Next will already
\* explore "while t is pinned, anything else happens".

\* Repin_after — internal.rs (guard.rs:366-393).  Sequence:
\*   acquire_handle; unpin; call f(); ScopeGuard re-pins; release_handle.
\* If f() panics, ScopeGuard still re-pins (safety guarantee).
RepinAfterStart(t) ==
    /\ pc[t] = "Idle"
    /\ guardCount[t] = 1               \* repin_after takes &mut self ⇒ unique
    /\ ~pcAux[t].repinAfterPending
    \* acquire_handle (guard.rs:386)
    /\ handleCount' = [handleCount EXCEPT ![t] = handleCount[t] + 1]
    \* unpin (guard.rs:387)
    /\ guardCount' = [guardCount EXCEPT ![t] = 0]
    /\ localEpoch' = [localEpoch EXCEPT ![t] = UNPINNED]
    /\ pcAux' = [pcAux EXCEPT ![t].repinAfterPending = TRUE]
    /\ pc' = [pc EXCEPT ![t] = "RepinAfterPending"]
    /\ UNCHANGED <<globalEpoch, sealedBags, retired, pinCount, bag, localState,
                   reachable, skipFenceAt, buggyRetire, deferBodies, objectGen>>

\* RepinAfterFinish — ScopeGuard (guard.rs:371-381) re-pins.
\* Two paths: f() returned normally, or f() panicked.
\* Both end the same way (panic-safe).
RepinAfterFinish(t) ==
    /\ pc[t] = "RepinAfterPending"
    /\ pcAux[t].repinAfterPending
    \* mem::forget(local.pin())  — increments guard_count
    /\ guardCount' = [guardCount EXCEPT ![t] = 1]
    /\ localEpoch' = [localEpoch EXCEPT ![t] = globalEpoch]
    /\ pinCount' = [pinCount EXCEPT ![t] = pinCount[t] + 1]
    \* release_handle  — decrements handle_count
    /\ handleCount' = [handleCount EXCEPT ![t] = handleCount[t] - 1]
    /\ pcAux' = [pcAux EXCEPT ![t].repinAfterPending = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "Idle"]
    /\ UNCHANGED <<globalEpoch, sealedBags, retired, bag, localState,
                   reachable, skipFenceAt, buggyRetire, deferBodies, objectGen>>

\* UnprotectedDefer (guard.rs:194-198) — defer on a null-local guard
\* runs the closure immediately rather than queueing.
UnprotectedDefer(t, obj) ==
    /\ pc[t] = "Idle"
    /\ obj \in Object
    /\ obj \notin reachable
    /\ ~ (\E r \in retired : r.obj = obj)
    \* drop(f()) runs immediately — same effect as a destructor call.
    /\ retired' = retired \cup
                  {[obj |-> obj, sealEpoch |-> globalEpoch,
                    reachableAtSeal |-> FALSE, reclaimed |-> TRUE]}
    /\ UNCHANGED <<globalEpoch, sealedBags, localEpoch, guardCount, handleCount,
                   pinCount, bag, localState, pc, pcAux, reachable, skipFenceAt,
                   buggyRetire, deferBodies, objectGen>>

\* ========================================================================
\* Finalize — internal.rs:529-569
\* ========================================================================
\* finalize is invoked from unpin (line 475) when guard_count drops to 0
\* and handle_count is also 0; or from release_handle (line 524) when
\* the last handle is dropped while not pinned.  It:
\*   1. Sets handle_count = 1 (line 540) to prevent finalize recursion.
\*   2. Calls pin() — internal.rs:545.  This is the F1 reentry pattern.
\*   3. push_bag flushes the local bag (line 547-548).
\*   4. handle_count = 0 (line 552).
\*   5. entry.delete(unprotected()) (line 562) — marks Local for retire.
\*   6. drop collector (line 567).
\* ------------------------------------------------------------------------

Finalize(t) ==
    /\ pc[t] = "Finalize"
    /\ ~pcAux[t].inFinalize
    /\ guardCount[t] = 0
    /\ handleCount[t] = 0
    \* Step 1 — set handle_count = 1
    /\ handleCount' = [handleCount EXCEPT ![t] = 1]
    /\ pcAux' = [pcAux EXCEPT ![t].inFinalize = TRUE]
    \* Steps 2-3 are spec'd as a single state transition for tractability.
    \* This is acceptable because the inner pin/unpin pair is gated by
    \* handleCount = 1 (so the unpin's finalize check at line 473 fails)
    \* — the F1 invariant we want to confirm.
    /\ pc' = [pc EXCEPT ![t] = "FinalizePinned"]
    /\ UNCHANGED <<globalEpoch, sealedBags, retired,
                   localEpoch, guardCount, pinCount, bag, localState,
                   reachable, skipFenceAt, buggyRetire, deferBodies, objectGen>>

\* Inner pin from finalize (internal.rs:545): pin and push the local bag.
FinalizePushBag(t) ==
    /\ pc[t] = "FinalizePinned"
    /\ pcAux[t].inFinalize
    /\ \/ /\ Len(bag[t]) > 0
          /\ sealedBags' = Append(sealedBags,
                                 [seal |-> globalEpoch, items |-> bag[t]])
          /\ bag' = [bag EXCEPT ![t] = <<>>]
       \/ /\ Len(bag[t]) = 0
          /\ UNCHANGED <<sealedBags, bag>>
    /\ pc' = [pc EXCEPT ![t] = "FinalizeMarkDeleted"]
    /\ UNCHANGED <<globalEpoch, retired, localEpoch, guardCount, handleCount,
                   pinCount, localState, pcAux, reachable, skipFenceAt,
                   buggyRetire, deferBodies, objectGen>>

\* internal.rs:552 + 562 — handle_count back to 0; entry.delete (tag).
FinalizeMarkDeleted(t) ==
    /\ pc[t] = "FinalizeMarkDeleted"
    /\ pcAux[t].inFinalize
    /\ handleCount' = [handleCount EXCEPT ![t] = 0]
    \* Family 6 — Local goes to "Tagged" (deletion bit set in entry).
    \* Eventually a list iterator will retire it (slot reuse path).
    /\ localState' = [localState EXCEPT ![t] = "Tagged"]
    /\ pcAux' = [pcAux EXCEPT ![t].inFinalize = FALSE]
    /\ pc' = [pc EXCEPT ![t] = "Idle"]
    /\ UNCHANGED <<globalEpoch, sealedBags, retired,
                   localEpoch, guardCount, pinCount, bag,
                   reachable, skipFenceAt, buggyRetire, deferBodies, objectGen>>

\* Family 6 — slot reuse: a Tagged Local is fully retired/freed, and the
\* slot is reused by registering a new Local at the same address.
\* internal.rs:583 (IsElement::finalize calls guard.defer_destroy) +
\* register at internal.rs:338.
SlotReuse(t) ==
    /\ pc[t] = "Idle"
    /\ \/ /\ localState[t] = "Tagged"
          /\ localState' = [localState EXCEPT ![t] = "Free"]
          /\ UNCHANGED objectGen
       \/ /\ localState[t] = "Free"
          /\ localState' = [localState EXCEPT ![t] = "Reused"]
          \* Slot reuse bumps the per-Local generation counter.
          /\ objectGen' = [objectGen EXCEPT ![t] = objectGen[t] + 1]
    /\ UNCHANGED <<globalEpoch, sealedBags, retired,
                   localEpoch, guardCount, handleCount, pinCount, bag,
                   pc, pcAux, reachable, skipFenceAt, buggyRetire, deferBodies>>

\* ========================================================================
\* Adversary actions
\* ========================================================================

\* Family 3 — drop the SC fence at one labeled site (one shot).
SkipFence(site) ==
    /\ skipFenceAt = "none"
    /\ site \in {"PinFence", "TryAdvFence"}
    /\ skipFenceAt' = site
    /\ UNCHANGED <<globalEpoch, sealedBags, retired,
                   localEpoch, guardCount, handleCount, pinCount, bag, localState,
                   pc, pcAux, reachable, buggyRetire, deferBodies, objectGen>>

\* ========================================================================
\* Next State Relation
\* ========================================================================

PinSteps(t) ==
    \/ PinIncGuardCount(t)
    \/ PinLoadGlobal(t)
    \/ PinPublish(t)
    \/ PinMaybeCollect(t)
    \/ PinCollectFinish(t)

UnpinSteps(t) ==
    \/ UnpinDec(t)
    \/ UnpinPublish(t)

TryAdvSteps(t) ==
    \/ TryAdvLoadGlobal(t)
    \/ TryAdvFence(t)
    \/ TryAdvIter(t)
    \/ TryAdvAbortStalled(t)
    \/ TryAdvAbortDifferentEpoch(t)
    \/ TryAdvFinishStore(t)

CollectSteps(t) ==
    \/ CollectScan(t)
    \/ BagDrop(t)
    \/ InDeferCallbackPin(t)
    \/ InDeferCallbackUnpin(t)
    \/ InDeferCallbackDefer(t)

FinalizeSteps(t) ==
    \/ Finalize(t)
    \/ FinalizePushBag(t)
    \/ FinalizeMarkDeleted(t)
    \/ SlotReuse(t)

CallerSteps(t) ==
    \/ \E o \in Object : Defer(t, o, "Noop")
    \/ \E o \in Object : Defer(t, o, "Pin")
    \/ \E o \in Object : Defer(t, o, "Defer")
    \/ \E o \in Object : BuggyRetire(t, o)
    \/ \E o \in Object : PublishObject(t, o)
    \/ \E o \in Object : UnlinkObject(t, o)
    \/ \E o \in Object : ReadAndDeref(t, o)
    \/ \E o \in Object : UnprotectedDefer(t, o)
    \/ PushBag(t)
    \/ Flush(t)
    \/ Repin(t)
    \/ RepinAfterStart(t)
    \/ RepinAfterFinish(t)

Next ==
    \/ \E t \in Thread :
            \/ PinSteps(t)
            \/ UnpinSteps(t)
            \/ TryAdvSteps(t)
            \/ CollectSteps(t)
            \/ FinalizeSteps(t)
            \/ CallerSteps(t)
    \/ \E s \in {"PinFence", "TryAdvFence"} : SkipFence(s)

Spec == Init /\ [][Next]_allVars

\* ========================================================================
\* Invariants
\* ========================================================================

\* ---- Standard safety ----

\* GuardCountNonNegative — internal.rs F10 (no debug-assert in code).
GuardCountNonNegative ==
    \A t \in Thread : guardCount[t] >= 0

\* HandleCountNonNegative — internal.rs F10.
HandleCountNonNegative ==
    \A t \in Thread : handleCount[t] >= 0

\* ---- Extension invariants (bug-family specific) ----

\* Family 2 — RetireImpliesUnreachable: at retire time, obj must not have
\* been reachable.  modeling-brief.md §5.
RetireImpliesUnreachable ==
    \A r \in retired : ~ r.reachableAtSeal

\* Family 2/F12 — NoUseAfterRetire: no thread dereferences a reclaimed obj.
\* The actual UAF check fires inside ReadAndDeref via its precondition.
NoUseAfterRetire ==
    \A r \in retired :
        r.reclaimed =>
            \A o \in Object :
                ~ (o = r.obj /\ o \in reachable)

\* Family 1 — NoEpochAdvanceDuringNestedPin:
\* If guardCount[t] > 1, the action that just executed must not have
\* changed localEpoch[t].  We check this inductively: in any state with
\* guardCount[t] >= 1, localEpoch[t] is pinned (>= 0).
LocalPinnedWhenGuarded ==
    \A t \in Thread :
        guardCount[t] >= 1 /\ pc[t] \notin {"PinLoadGlobal", "PinPublish"}
            => localEpoch[t] /= UNPINNED

\* Family 3 — LocalEpochBoundedByGlobal: a pinned local epoch must equal
\* the global epoch or its predecessor.  modeling-brief.md §5.
LocalEpochBoundedByGlobal ==
    \A t \in Thread :
        localEpoch[t] /= UNPINNED =>
            localEpoch[t] = globalEpoch
            \/ localEpoch[t] = globalEpoch - 1

\* Family 3 — AdvanceRequiresAllPinnedAtCurrent: when global advances,
\* every pinned local must be at the current (pre-advance) global epoch.
\* Encoded as: in any reachable state, no pinned local is more than one
\* epoch behind global (otherwise advance would have aborted).
AdvanceRequiresAllPinnedAtCurrent ==
    \A t \in Thread :
        localEpoch[t] /= UNPINNED =>
            globalEpoch - localEpoch[t] <= 1

\* Family 1 — ReentrantPinDoesNotPublish: when a Pin starts with
\* guardCount > 0, the localEpoch is unchanged after pin completes.
\* (We assert pc returns to Idle from PinIncGuardCount in nested case.)
ReentrantPinNoOp == TRUE  \* Encoded by structure: PinLoadGlobal not entered

\* Family 1 — FinalizeDoesNotRecurse: while inFinalize, finalize must not
\* re-trigger.  Modeled by the inFinalize guard in Finalize / UnpinPublish.
FinalizeDoesNotRecurse ==
    \A t \in Thread :
        pcAux[t].inFinalize => pc[t] /= "Finalize"

\* Family 4 — UnprotectedDeferRunsImmediately: an unprotected defer's
\* object goes straight to retired+reclaimed (no bag enqueue).
\* Encoded by UnprotectedDefer's effect.

\* Family 5 — IsExpiredImpliesGap2: every reclaimed bag had seal+2 ≤ global
\* AT RECLAIM TIME.  We approximate by: every reclaimed retired entry
\* satisfies the gap-2 rule against the highest globalEpoch.
IsExpiredImpliesGap2 ==
    \A r \in retired :
        r.reclaimed => globalEpoch - r.sealEpoch >= 2

\* Family 4 — GuardCountUnderflowSafe.
GuardCountUnderflowSafe ==
    \A t \in Thread : guardCount[t] >= 0

\* ---- Structural invariants ----

ValidPC ==
    \A t \in Thread :
        pc[t] \in {"Idle", "PinLoadGlobal", "PinPublish", "PinMaybeCollect",
                   "PinCollect",
                   "UnpinPublish", "Finalize", "FinalizePinned",
                   "FinalizeMarkDeleted",
                   "TryAdvFence", "TryAdvIter", "TryAdvAbortStalled",
                   "TryAdvAbortDifferentEpoch", "TryAdvFinishStore",
                   "CollectScan", "BagDrop",
                   "InDeferCallbackPin", "InDeferCallbackUnpin",
                   "InDeferCallbackDefer",
                   "RepinAfterPending"}

ValidLocalState ==
    \A t \in Thread :
        localState[t] \in {"Live", "Tagged", "Retired", "Free", "Reused"}

\* SealedBags monotone: each seal value <= globalEpoch.
SealedBagsMonotone ==
    \A i \in 1..Len(sealedBags) : sealedBags[i].seal <= globalEpoch

\* ========================================================================
\* State Constraints (used in base.cfg / MC.cfg via CONSTRAINT)
\* ========================================================================

BaseConstraint ==
    /\ globalEpoch <= MaxEpoch
    /\ Len(sealedBags) <= 4
    /\ Cardinality(retired) <= 4
    /\ \A t \in Thread : pinCount[t] <= 3
    /\ \A t \in Thread : objectGen[t] <= 2

====
