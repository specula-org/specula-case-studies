---- MODULE base ----
\* Epoch-Based Memory Reclamation (crossbeam-epoch)
\* Models the epoch protocol, MSQueue interaction, thread lifecycle, and GC timing.
\*
\* Source: crossbeam-rs/crossbeam, crossbeam-epoch subcrate
\* Key files: internal.rs, guard.rs, epoch.rs, sync/queue.rs
\*
\* Bug Families:
\*   Family 1: Epoch Advancement Protocol Races (HIGH)
\*   Family 2: Data Structure / EBR Interaction (HIGH)
\*   Family 3: Finalization and Thread Lifecycle (MEDIUM)
\*   Family 4: Garbage Collection Timing & Liveness (MEDIUM)
\*
\* Hunt Extensions (v2):
\*   H1: Non-atomic scan in try_advance (per-thread iteration)
\*   H2: Repin modeling (safe + unsafe variants)
\*   H3: Stale epoch in PushLocalBag (weak memory model)
\*   H4: Non-atomic finalize (transient pin during finalization)

EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS
    Thread,     \* Set of thread IDs
    Node,       \* Set of queue node IDs (objects managed by EBR)
    Nil,        \* Null value
    Sentinel    \* Initial sentinel node in the queue

ASSUME Sentinel \in Node
ASSUME Nil \notin Thread /\ Nil \notin Node

\* ============================================================================
\* Variables
\* ============================================================================

VARIABLES
    \* --- Epoch Protocol (Family 1: Epoch Advancement Protocol Races) ---
    \* internal.rs:165-174 — Global struct
    globalEpoch,    \* Nat — the global epoch (internal.rs:173, Global.epoch)
    \* internal.rs:293-318 — Local struct
    localEpoch,     \* [Thread -> Nat] — local epoch value (internal.rs:317, Local.epoch)
    pinned,         \* [Thread -> BOOLEAN] — whether thread is pinned

    \* Extension: Split pin for TOCTOU window (Family 1, MC-1)
    pinPhase,       \* [Thread -> {"idle", "readEpoch", "repinRead"}] — pin/repin phase
    readEpoch,      \* [Thread -> Nat] — epoch read in step 1 (internal.rs:410)

    \* Extension: Split TryAdvance for store-not-CAS concern (Family 1, MC-2)
    advancePhase,   \* [Thread -> {"idle", "scanning", "scanned"}] — try_advance phase
    advanceEpoch,   \* [Thread -> Nat] — epoch read during scan (internal.rs:238)

    \* --- Garbage Collection (Family 1, Family 4) ---
    sealedBags,     \* Set of [epoch |-> Nat, node |-> Node] — sealed bag entries
    localBag,       \* [Thread -> SUBSET Node] — thread's local bag
    collected,      \* SUBSET Node — nodes whose destructors have been called

    \* --- MSQueue / Shared Data Structure (Family 2) ---
    qHead,          \* Node — queue head pointer (queue.rs:25)
    qTail,          \* Node — queue tail pointer (queue.rs:26)
    qNext,          \* [Node -> Node \cup {Nil}] — next pointers (queue.rs:38)

    \* --- Thread Lifecycle (Family 3) ---
    guardCount,     \* [Thread -> Nat] — number of active guards
    handleCount,    \* [Thread -> Nat] — number of active handles
    threadState,    \* [Thread -> {"active", "deleted"}] — lifecycle state

    \* --- Ghost/Verification Variables ---
    accessed,       \* [Thread -> SUBSET Node] — nodes accessed by pinned thread

    \* --- Hunt Extension Variables (v2) ---
    \* H1: Non-atomic scan — tracks which threads have been checked
    scanSet,        \* [Thread -> SUBSET Thread] — threads scanned so far
    \* H4: Non-atomic finalize — tracks finalize progress
    finalizePhase   \* [Thread -> {"idle", "pinned", "pushed"}] — finalize step

\* Variable groups for UNCHANGED
epochVars == <<globalEpoch, localEpoch, pinned, pinPhase, readEpoch,
               advancePhase, advanceEpoch>>
gcVars == <<sealedBags, localBag, collected>>
queueVars == <<qHead, qTail, qNext>>
lifecycleVars == <<guardCount, handleCount, threadState>>
ghostVars == <<accessed>>
huntVars == <<scanSet, finalizePhase>>

allVars == <<epochVars, gcVars, queueVars, lifecycleVars, ghostVars, huntVars>>

\* ============================================================================
\* Helpers
\* ============================================================================

\* Whether a sealed bag entry is expired (safe to collect)
\* internal.rs:157-161 — SealedBag::is_expired
IsExpired(entry) == globalEpoch - entry.epoch >= 2

\* Whether thread t is active and can perform operations
IsActive(t) == threadState[t] = "active"

\* The set of all deferred (not yet collected) nodes
DeferredNodes ==
    {entry.node : entry \in sealedBags} \cup UNION {localBag[t] : t \in Thread}

\* ============================================================================
\* Type Invariant
\* ============================================================================

TypeOK ==
    /\ globalEpoch \in Nat
    /\ localEpoch \in [Thread -> Nat]
    /\ pinned \in [Thread -> BOOLEAN]
    /\ pinPhase \in [Thread -> {"idle", "readEpoch", "repinRead"}]
    /\ readEpoch \in [Thread -> Nat]
    /\ advancePhase \in [Thread -> {"idle", "scanning", "scanned"}]
    /\ advanceEpoch \in [Thread -> Nat]
    /\ sealedBags \subseteq [epoch: Nat, node: Node]
    /\ localBag \in [Thread -> SUBSET Node]
    /\ collected \subseteq Node
    /\ qHead \in Node
    /\ qTail \in Node
    /\ qNext \in [Node -> Node \cup {Nil}]
    /\ guardCount \in [Thread -> Nat]
    /\ handleCount \in [Thread -> Nat]
    /\ threadState \in [Thread -> {"active", "deleted"}]
    /\ accessed \in [Thread -> SUBSET Node]
    /\ scanSet \in [Thread -> SUBSET Thread]
    /\ finalizePhase \in [Thread -> {"idle", "pinned", "pushed"}]

\* ============================================================================
\* Initial State
\* ============================================================================

Init ==
    /\ globalEpoch = 0
    /\ localEpoch = [t \in Thread |-> 0]
    /\ pinned = [t \in Thread |-> FALSE]
    /\ pinPhase = [t \in Thread |-> "idle"]
    /\ readEpoch = [t \in Thread |-> 0]
    /\ advancePhase = [t \in Thread |-> "idle"]
    /\ advanceEpoch = [t \in Thread |-> 0]
    /\ sealedBags = {}
    /\ localBag = [t \in Thread |-> {}]
    /\ collected = {}
    /\ qHead = Sentinel
    /\ qTail = Sentinel
    /\ qNext = [n \in Node |-> Nil]
    /\ guardCount = [t \in Thread |-> 0]
    /\ handleCount = [t \in Thread |-> 1]
    /\ threadState = [t \in Thread |-> "active"]
    /\ accessed = [t \in Thread |-> {}]
    \* Hunt extensions
    /\ scanSet = [t \in Thread |-> {}]
    /\ finalizePhase = [t \in Thread |-> "idle"]

\* ============================================================================
\* Actions: Epoch Protocol — Pin/Unpin (Family 1)
\* ============================================================================

\* --- ReadGlobalForPin(t) ---
\* First step of split pin: read global epoch into readEpoch[t]
\* Models internal.rs:410 — let global_epoch = self.global().epoch.load(Relaxed)
ReadGlobalForPin(t) ==
    /\ IsActive(t)
    /\ pinPhase[t] = "idle"
    /\ guardCount[t] = 0
    /\ finalizePhase[t] = "idle"            \* Not mid-finalize
    /\ readEpoch' = [readEpoch EXCEPT ![t] = globalEpoch]
    /\ pinPhase' = [pinPhase EXCEPT ![t] = "readEpoch"]
    /\ UNCHANGED <<globalEpoch, localEpoch, pinned, advancePhase, advanceEpoch>>
    /\ UNCHANGED <<gcVars, queueVars, lifecycleVars, ghostVars, huntVars>>

\* --- CompletePin(t) ---
\* Second step of split pin: store local epoch, set pinned flag
\* Models internal.rs:411-448 — store new_epoch (SeqCst CAS / Relaxed+fence)
CompletePin(t) ==
    /\ IsActive(t)
    /\ pinPhase[t] = "readEpoch"
    /\ localEpoch' = [localEpoch EXCEPT ![t] = readEpoch[t]]
    /\ pinned' = [pinned EXCEPT ![t] = TRUE]
    /\ pinPhase' = [pinPhase EXCEPT ![t] = "idle"]
    /\ guardCount' = [guardCount EXCEPT ![t] = 1]
    /\ UNCHANGED <<globalEpoch, readEpoch, advancePhase, advanceEpoch>>
    /\ UNCHANGED <<gcVars, queueVars, handleCount, threadState, ghostVars, huntVars>>

\* --- NestedPin(t) ---
\* Nested (reentrant) pin: just increment guard count, don't update epoch
\* Models internal.rs:406-408 — guard_count > 0 branch
NestedPin(t) ==
    /\ IsActive(t)
    /\ pinned[t]
    /\ guardCount[t] >= 1
    /\ pinPhase[t] = "idle"                 \* Not mid-repin
    /\ guardCount' = [guardCount EXCEPT ![t] = @ + 1]
    /\ UNCHANGED <<epochVars, gcVars, queueVars, handleCount, threadState, ghostVars, huntVars>>

\* --- Unpin(t) ---
\* Decrement guard count; if last guard, clear pinned state
\* Models internal.rs:466-479 — Local::unpin()
Unpin(t) ==
    /\ IsActive(t)
    /\ pinned[t]
    /\ guardCount[t] >= 1
    /\ advancePhase[t] = "idle"
    /\ pinPhase[t] = "idle"                 \* Not mid-repin
    /\ guardCount' = [guardCount EXCEPT ![t] = @ - 1]
    /\ IF guardCount[t] = 1
       THEN /\ pinned' = [pinned EXCEPT ![t] = FALSE]
            /\ localEpoch' = [localEpoch EXCEPT ![t] = 0]
            /\ accessed' = [accessed EXCEPT ![t] = {}]
       ELSE /\ UNCHANGED <<pinned, localEpoch, accessed>>
    /\ UNCHANGED <<globalEpoch, pinPhase, readEpoch, advancePhase, advanceEpoch>>
    /\ UNCHANGED <<gcVars, queueVars, handleCount, threadState, huntVars>>

\* ============================================================================
\* Actions: Epoch Advancement (Family 1, MC-2)
\* ============================================================================

\* --- ScanForAdvance(t) --- [ATOMIC variant]
\* Atomically check all locals — the original model
\* Models internal.rs:237-270 — read global_epoch, SeqCst fence, scan locals
ScanForAdvance(t) ==
    /\ IsActive(t)
    /\ pinned[t]
    /\ advancePhase[t] = "idle"
    /\ LET ge == globalEpoch
       IN
       /\ \A t2 \in Thread :
            \/ ~pinned[t2]
            \/ localEpoch[t2] = ge
       /\ advanceEpoch' = [advanceEpoch EXCEPT ![t] = ge]
       /\ advancePhase' = [advancePhase EXCEPT ![t] = "scanned"]
    /\ UNCHANGED <<globalEpoch, localEpoch, pinned, pinPhase, readEpoch>>
    /\ UNCHANGED <<gcVars, queueVars, lifecycleVars, ghostVars, huntVars>>

\* --- StoreAdvancedEpoch(t) ---
\* Store successor epoch (STORE not CAS!)
\* Models internal.rs:285-286
StoreAdvancedEpoch(t) ==
    /\ IsActive(t)
    /\ pinned[t]
    /\ advancePhase[t] = "scanned"
    /\ globalEpoch' = advanceEpoch[t] + 1
    /\ advancePhase' = [advancePhase EXCEPT ![t] = "idle"]
    \* Clear scanSet (cleanup after non-atomic scan, no-op for atomic)
    /\ scanSet' = [scanSet EXCEPT ![t] = {}]
    /\ UNCHANGED <<localEpoch, pinned, pinPhase, readEpoch, advanceEpoch>>
    /\ UNCHANGED <<gcVars, queueVars, lifecycleVars, ghostVars, finalizePhase>>

\* ============================================================================
\* Actions: Non-Atomic Scan (Hunt H1)
\* ============================================================================
\* Models try_advance iterating the Locals linked list one-by-one.
\* Between checking each thread, other threads can pin/unpin/repin,
\* changing their epochs. This captures races that the atomic scan misses.

\* --- StartScan(t) ---
\* Begin non-atomic scan: read global epoch, initialize scan set
\* Models the start of try_advance's list iteration (internal.rs:266)
StartScan(t) ==
    /\ IsActive(t)
    /\ pinned[t]
    /\ advancePhase[t] = "idle"
    /\ advanceEpoch' = [advanceEpoch EXCEPT ![t] = globalEpoch]
    /\ advancePhase' = [advancePhase EXCEPT ![t] = "scanning"]
    /\ scanSet' = [scanSet EXCEPT ![t] = {}]
    /\ UNCHANGED <<globalEpoch, localEpoch, pinned, pinPhase, readEpoch>>
    /\ UNCHANGED <<gcVars, queueVars, lifecycleVars, ghostVars, finalizePhase>>

\* --- ScanOneThread(t, t2) ---
\* Check one thread's epoch during non-atomic scan.
\* Between checks, other threads can pin/unpin/repin — the key concern.
\* Models one iteration of the for-loop in try_advance (internal.rs:266-287)
ScanOneThread(t, t2) ==
    /\ IsActive(t)
    /\ pinned[t]
    /\ advancePhase[t] = "scanning"
    /\ t2 \notin scanSet[t]
    \* Check t2's epoch at THIS moment (snapshot, not atomic with others)
    /\ \/ ~pinned[t2]
       \/ localEpoch[t2] = advanceEpoch[t]
    /\ scanSet' = [scanSet EXCEPT ![t] = @ \cup {t2}]
    /\ UNCHANGED <<globalEpoch, localEpoch, pinned, pinPhase, readEpoch,
                   advancePhase, advanceEpoch>>
    /\ UNCHANGED <<gcVars, queueVars, lifecycleVars, ghostVars, finalizePhase>>

\* --- CompleteScan(t) ---
\* All threads scanned — transition to "scanned" for StoreAdvancedEpoch
CompleteScan(t) ==
    /\ IsActive(t)
    /\ pinned[t]
    /\ advancePhase[t] = "scanning"
    /\ scanSet[t] = Thread
    /\ advancePhase' = [advancePhase EXCEPT ![t] = "scanned"]
    /\ UNCHANGED <<globalEpoch, localEpoch, pinned, pinPhase, readEpoch, advanceEpoch>>
    /\ UNCHANGED <<gcVars, queueVars, lifecycleVars, ghostVars, huntVars>>

\* --- AbortScan(t) ---
\* Abort scan due to stall (IterError::Stalled) or epoch mismatch.
\* Models try_advance returning early (internal.rs:268-272, 279-280)
AbortScan(t) ==
    /\ IsActive(t)
    /\ pinned[t]
    /\ advancePhase[t] = "scanning"
    /\ advancePhase' = [advancePhase EXCEPT ![t] = "idle"]
    /\ scanSet' = [scanSet EXCEPT ![t] = {}]
    /\ UNCHANGED <<globalEpoch, localEpoch, pinned, pinPhase, readEpoch, advanceEpoch>>
    /\ UNCHANGED <<gcVars, queueVars, lifecycleVars, ghostVars, finalizePhase>>

\* ============================================================================
\* Actions: Garbage Collection (Family 1, Family 4)
\* ============================================================================

\* --- PushLocalBag(t) ---
\* Seal local bag with current epoch and push to global queue
\* Models internal.rs:191-198 — Global::push_bag()
PushLocalBag(t) ==
    /\ IsActive(t)
    /\ pinned[t]
    /\ localBag[t] /= {}
    /\ LET epoch == globalEpoch
           bag == localBag[t]
       IN
       /\ sealedBags' = sealedBags \cup {[epoch |-> epoch, node |-> n] : n \in bag}
       /\ localBag' = [localBag EXCEPT ![t] = {}]
    /\ UNCHANGED <<epochVars, collected, queueVars, lifecycleVars, ghostVars, huntVars>>

\* --- CollectExpiredBag(t) ---
\* Pop one expired bag entry from the global queue and destroy it
\* Models internal.rs:208-226 — Global::collect()
CollectExpiredBag(t) ==
    /\ IsActive(t)
    /\ pinned[t]
    /\ \E entry \in sealedBags :
        /\ IsExpired(entry)
        /\ sealedBags' = sealedBags \ {entry}
        /\ collected' = collected \cup {entry.node}
    /\ UNCHANGED <<epochVars, localBag, queueVars, lifecycleVars, ghostVars, huntVars>>

\* ============================================================================
\* Actions: Stale Bag Sealing (Hunt H3)
\* ============================================================================
\* Models weak memory allowing push_bag's Relaxed load to see stale value
\* despite the SeqCst fence (internal.rs:194-196).
\* If the fence is insufficient, the bag could be sealed at globalEpoch-1,
\* causing it to expire one epoch sooner — potentially premature collection.

\* --- PushLocalBagStale(t) ---
\* BUGGY variant: seal bag with 1-behind epoch
PushLocalBagStale(t) ==
    /\ IsActive(t)
    /\ pinned[t]
    /\ localBag[t] /= {}
    /\ globalEpoch > 0                      \* Need room for stale read
    /\ LET staleEpoch == globalEpoch - 1
           bag == localBag[t]
       IN
       /\ sealedBags' = sealedBags \cup {[epoch |-> staleEpoch, node |-> n] : n \in bag}
       /\ localBag' = [localBag EXCEPT ![t] = {}]
    /\ UNCHANGED <<epochVars, collected, queueVars, lifecycleVars, ghostVars, huntVars>>

\* ============================================================================
\* Actions: MSQueue Operations (Family 2)
\* ============================================================================

\* --- QueueLink(t, n) ---
\* Link a new node into the queue (first CAS of push)
\* Models queue.rs:84-88
QueueLink(t, n) ==
    /\ IsActive(t)
    /\ pinned[t]
    /\ n /= Sentinel
    /\ n \notin collected
    /\ n \notin DeferredNodes
    /\ qNext[n] = Nil
    /\ n /= qHead /\ n /= qTail
    /\ \A m \in Node : qNext[m] /= n
    /\ \/ /\ qNext[qTail] = Nil
          /\ qNext' = [qNext EXCEPT ![qTail] = n]
       \/ /\ qNext[qTail] /= Nil
          /\ qNext[qNext[qTail]] = Nil
          /\ qNext' = [qNext EXCEPT ![qNext[qTail]] = n]
    /\ UNCHANGED <<qHead, qTail>>
    /\ UNCHANGED <<epochVars, gcVars, lifecycleVars, ghostVars, huntVars>>

\* --- QueueAdvanceTail(t) ---
\* Advance a lagging tail pointer
\* Models queue.rs:79-81 and queue.rs:91-93
QueueAdvanceTail(t) ==
    /\ IsActive(t)
    /\ pinned[t]
    /\ qNext[qTail] /= Nil
    /\ qTail' = qNext[qTail]
    /\ UNCHANGED <<qHead, qNext>>
    /\ UNCHANGED <<epochVars, gcVars, lifecycleVars, ghostVars, huntVars>>

\* --- QueuePop(t) ---
\* Pop from queue head with tail advancement fix
\* Models queue.rs:120-143 — includes fix for Issue #238
QueuePop(t) ==
    /\ IsActive(t)
    /\ pinned[t]
    /\ LET head == qHead
           next == qNext[head]
       IN
       /\ next /= Nil
       /\ qHead' = next
       /\ qTail' = IF head = qTail THEN next ELSE qTail
       /\ localBag' = [localBag EXCEPT ![t] = @ \cup {head}]
       /\ UNCHANGED qNext
    /\ UNCHANGED <<epochVars, sealedBags, collected, lifecycleVars, ghostVars, huntVars>>

\* --- QueuePopBuggy(t) ---
\* BUGGY variant: pop WITHOUT tail advancement (pre-fix for Issue #238)
QueuePopBuggy(t) ==
    /\ IsActive(t)
    /\ pinned[t]
    /\ LET head == qHead
           next == qNext[head]
       IN
       /\ next /= Nil
       /\ qHead' = next
       /\ UNCHANGED qTail
       /\ localBag' = [localBag EXCEPT ![t] = @ \cup {head}]
       /\ UNCHANGED qNext
    /\ UNCHANGED <<epochVars, sealedBags, collected, lifecycleVars, ghostVars, huntVars>>

\* --- AccessNode(t, n) ---
\* Ghost action: tracks references for SafeReclamation verification
AccessNode(t, n) ==
    /\ IsActive(t)
    /\ pinned[t]
    /\ n \notin collected
    /\ \/ n = qHead
       \/ n = qTail
       \/ \E m \in accessed[t] : qNext[m] = n
    /\ accessed' = [accessed EXCEPT ![t] = @ \cup {n}]
    /\ UNCHANGED <<epochVars, gcVars, queueVars, lifecycleVars, huntVars>>

\* ============================================================================
\* Actions: Repin (Hunt H2)
\* ============================================================================
\* Models internal.rs:574-593 — Local::repin()
\* Repin updates local epoch WITHOUT SeqCst fence (only Release ordering).
\* In safe Rust, repin(&mut self) invalidates all Shared<'g> references.
\* In unsafe code, raw pointers may survive across repin.

\* --- Repin(t) --- [SAFE variant]
\* Update local epoch and clear references (models safe Rust semantics)
Repin(t) ==
    /\ IsActive(t)
    /\ pinned[t]
    /\ guardCount[t] = 1                    \* Only with single guard (internal.rs:578)
    /\ pinPhase[t] = "idle"
    /\ advancePhase[t] = "idle"
    /\ localEpoch' = [localEpoch EXCEPT ![t] = globalEpoch]
    /\ accessed' = [accessed EXCEPT ![t] = {}]
    /\ UNCHANGED <<globalEpoch, pinned, pinPhase, readEpoch, advancePhase, advanceEpoch>>
    /\ UNCHANGED <<gcVars, queueVars, lifecycleVars, huntVars>>

\* --- RepinUnsafe(t) --- [UNSAFE variant]
\* Update local epoch WITHOUT clearing references.
\* Models unsafe code that holds raw pointers across repin.
\* Expected to VIOLATE SafeReclamation — confirms type system reliance.
RepinUnsafe(t) ==
    /\ IsActive(t)
    /\ pinned[t]
    /\ guardCount[t] = 1
    /\ pinPhase[t] = "idle"
    /\ advancePhase[t] = "idle"
    /\ localEpoch' = [localEpoch EXCEPT ![t] = globalEpoch]
    /\ UNCHANGED <<globalEpoch, pinned, pinPhase, readEpoch, advancePhase, advanceEpoch>>
    /\ UNCHANGED <<gcVars, queueVars, lifecycleVars, ghostVars, huntVars>>

\* ============================================================================
\* Actions: Thread Lifecycle (Family 3)
\* ============================================================================

\* --- ReleaseHandle(t) ---
\* Drop a handle, decrement handle count
\* Models internal.rs:514-527
ReleaseHandle(t) ==
    /\ IsActive(t)
    /\ handleCount[t] >= 1
    /\ handleCount' = [handleCount EXCEPT ![t] = @ - 1]
    /\ UNCHANGED <<epochVars, gcVars, queueVars, guardCount, threadState, ghostVars, huntVars>>

\* --- Finalize(t) --- [ATOMIC variant]
\* Finalize a Local: flush bag to global queue, mark as deleted
\* Models internal.rs:531-569 — single atomic action
Finalize(t) ==
    /\ IsActive(t)
    /\ guardCount[t] = 0
    /\ handleCount[t] = 0
    /\ pinPhase[t] = "idle"
    /\ advancePhase[t] = "idle"
    /\ finalizePhase[t] = "idle"            \* Not mid-non-atomic-finalize
    /\ LET bag == localBag[t]
           epoch == globalEpoch
       IN
       /\ sealedBags' = sealedBags \cup {[epoch |-> epoch, node |-> n] : n \in bag}
       /\ localBag' = [localBag EXCEPT ![t] = {}]
    /\ threadState' = [threadState EXCEPT ![t] = "deleted"]
    /\ UNCHANGED <<epochVars, collected, queueVars, guardCount, handleCount, ghostVars, huntVars>>

\* ============================================================================
\* Actions: Non-Atomic Finalize (Hunt H4)
\* ============================================================================
\* Models the three-step finalize sequence in internal.rs:632-686:
\*   1. Temporarily pin (handle_count=1, pin()) — thread visible to scans
\*   2. Push bag, unpin — thread back to unpinned
\*   3. Mark as deleted — entry.delete()
\* Between steps, other threads' try_advance can observe transient states.

\* --- FinalizeStart(t) ---
\* Step 1: temporarily bump handle_count and pin
\* Models internal.rs:646-654
FinalizeStart(t) ==
    /\ IsActive(t)
    /\ guardCount[t] = 0
    /\ handleCount[t] = 0
    /\ pinPhase[t] = "idle"
    /\ advancePhase[t] = "idle"
    /\ finalizePhase[t] = "idle"
    \* Temporarily pin at current epoch
    /\ pinned' = [pinned EXCEPT ![t] = TRUE]
    /\ localEpoch' = [localEpoch EXCEPT ![t] = globalEpoch]
    /\ guardCount' = [guardCount EXCEPT ![t] = 1]
    /\ handleCount' = [handleCount EXCEPT ![t] = 1]
    /\ finalizePhase' = [finalizePhase EXCEPT ![t] = "pinned"]
    /\ UNCHANGED <<globalEpoch, pinPhase, readEpoch, advancePhase, advanceEpoch>>
    /\ UNCHANGED <<gcVars, queueVars, threadState, ghostVars, scanSet>>

\* --- FinalizePushAndUnpin(t) ---
\* Step 2: push bag to global queue, then unpin and reset counts
\* Models internal.rs:652-659 — push_bag(), guard drop, handle_count=0
FinalizePushAndUnpin(t) ==
    /\ IsActive(t)
    /\ finalizePhase[t] = "pinned"
    /\ advancePhase[t] = "idle"             \* Not mid-scan during temp pin
    /\ LET bag == localBag[t]
           epoch == globalEpoch
       IN
       /\ sealedBags' = sealedBags \cup {[epoch |-> epoch, node |-> n] : n \in bag}
       /\ localBag' = [localBag EXCEPT ![t] = {}]
    \* Unpin and reset counts (clear accessed — references lost on unpin)
    /\ pinned' = [pinned EXCEPT ![t] = FALSE]
    /\ localEpoch' = [localEpoch EXCEPT ![t] = 0]
    /\ guardCount' = [guardCount EXCEPT ![t] = 0]
    /\ handleCount' = [handleCount EXCEPT ![t] = 0]
    /\ accessed' = [accessed EXCEPT ![t] = {}]
    /\ finalizePhase' = [finalizePhase EXCEPT ![t] = "pushed"]
    /\ UNCHANGED <<globalEpoch, pinPhase, readEpoch, advancePhase, advanceEpoch>>
    /\ UNCHANGED <<collected, queueVars, threadState, scanSet>>

\* --- FinalizeComplete(t) ---
\* Step 3: mark as deleted (entry.delete)
\* Models internal.rs:665-672 — ptr::read(collector), entry.delete()
FinalizeComplete(t) ==
    /\ IsActive(t)
    /\ finalizePhase[t] = "pushed"
    /\ threadState' = [threadState EXCEPT ![t] = "deleted"]
    /\ finalizePhase' = [finalizePhase EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<epochVars, gcVars, queueVars, guardCount, handleCount, ghostVars, scanSet>>

\* ============================================================================
\* Buggy Actions (for bug hunting — disabled by default)
\* ============================================================================

\* --- NestedPinCollect(t) ---
\* BUG (Issue #105): collect/advance during nested pin with local epoch update
NestedPinCollect(t) ==
    /\ IsActive(t)
    /\ pinned[t]
    /\ guardCount[t] > 1
    /\ \A t2 \in Thread :
        \/ ~pinned[t2]
        \/ localEpoch[t2] = globalEpoch
    /\ globalEpoch' = globalEpoch + 1
    /\ localEpoch' = [localEpoch EXCEPT ![t] = globalEpoch + 1]
    /\ UNCHANGED <<pinned, pinPhase, readEpoch, advancePhase, advanceEpoch>>
    /\ UNCHANGED <<gcVars, queueVars, lifecycleVars, ghostVars, huntVars>>

\* ============================================================================
\* Specification
\* ============================================================================

\* Normal operations (correct implementation)
\* Hunt extensions are NOT included here — they are added via MC.tla
Next ==
    \E t \in Thread :
        \* --- Pin/Unpin ---
        \/ ReadGlobalForPin(t)
        \/ CompletePin(t)
        \/ NestedPin(t)
        \/ Unpin(t)
        \* --- Epoch Advancement ---
        \/ ScanForAdvance(t)
        \/ StoreAdvancedEpoch(t)
        \* --- Garbage Collection ---
        \/ PushLocalBag(t)
        \/ CollectExpiredBag(t)
        \* --- MSQueue ---
        \/ QueuePop(t)
        \/ \E n \in Node \ {Sentinel} : QueueLink(t, n)
        \/ QueueAdvanceTail(t)
        \/ \E n \in Node : AccessNode(t, n)
        \* --- Thread Lifecycle ---
        \/ ReleaseHandle(t)
        \/ Finalize(t)

Spec == Init /\ [][Next]_allVars

\* ============================================================================
\* Invariants
\* ============================================================================

\* --- Standard Safety ---

\* SafeReclamation (Family 1, Family 2)
\* THE critical safety property: no collected node is accessed by a pinned thread.
SafeReclamation ==
    \A t \in Thread :
        pinned[t] => accessed[t] \cap collected = {}

\* --- Extension Invariants ---

\* EpochMonotonicity (Family 1, MC-2, PR #755)
EpochMonotonicity ==
    \A t \in Thread :
        advancePhase[t] = "scanned" =>
            advanceEpoch[t] + 1 >= globalEpoch

\* TailReachability (Family 2, MC-3)
TailReachability == qTail \notin collected

\* NoDoubleFree (Family 2, RUSTSEC-2018-0009)
NoDoubleFree ==
    /\ \A t \in Thread : localBag[t] \cap collected = {}
    /\ \A entry \in sealedBags : entry.node \notin collected

\* FinalizeOnce (Family 3, MC-5)
FinalizeOnce ==
    \A t \in Thread :
        threadState[t] = "deleted" =>
            /\ localBag[t] = {}
            /\ guardCount[t] = 0
            /\ pinned[t] = FALSE

\* --- Structural Invariants ---

PinnedConsistency ==
    \A t \in Thread :
        pinned[t] = (guardCount[t] > 0)

QueueStructure ==
    /\ qHead \notin collected
    /\ qTail \notin collected

AccessRequiresPin ==
    \A t \in Thread :
        ~pinned[t] => accessed[t] = {}

NoOrphanedBags ==
    \A t \in Thread : localBag[t] \cap collected = {}

DeletedInactive ==
    \A t \in Thread :
        threadState[t] = "deleted" =>
            /\ ~pinned[t]
            /\ guardCount[t] = 0
            /\ pinPhase[t] = "idle"
            /\ advancePhase[t] = "idle"
            /\ finalizePhase[t] = "idle"

\* ============================================================================
\* Temporal Properties (Family 4: GC Timing & Liveness)
\* ============================================================================

EpochProgress ==
    \A e \in Nat : globalEpoch = e ~> globalEpoch > e

NoLeak ==
    \A n \in Node :
        n \in DeferredNodes ~> n \in collected

====
