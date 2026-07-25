---- MODULE base ----
(***************************************************************************)
(* TLA+ specification of flurry — Rust port of Java ConcurrentHashMap.    *)
(*                                                                         *)
(* Source: jonhoo/flurry                                                   *)
(*   map.rs   — core hashmap (put, transfer, add_count, treeify_bin)       *)
(*   node.rs  — tree bins, TreeBin R/W lock protocol                       *)
(*   raw/mod.rs — Table structure, bin CAS/store                           *)
(*                                                                         *)
(* Bug Families:                                                           *)
(*   F1 — Resize/Transfer coordination (off-by-one, size_ctl signaling)    *)
(*   F2 — Memory reclamation safety (use-after-free via epoch guards)      *)
(*   F3 — TreeBin read-write lock protocol (waiter lifecycle)              *)
(*   F4 — Bin lock + treeify race window (post-lock treeification)         *)
(***************************************************************************)

EXTENDS Integers, Sequences, FiniteSets, TLC

\* ========================================================================
\* Constants
\* ========================================================================

CONSTANTS
    Thread,             \* Set of thread IDs
    NumBins,            \* Number of bins in initial table (power of 2)
    MaxKey,             \* Maximum key value (keys are 0..MaxKey-1)
    MaxTableMultiplier  \* Max table size = NumBins * MaxTableMultiplier

ASSUME NumBins \in {2, 4, 8, 16}
ASSUME MaxKey \in Nat \ {0}
ASSUME MaxTableMultiplier \in Nat \ {0}

\* Derived constants
TREEIFY_THRESHOLD == 3  \* Reduced for model checking (real: 8)
MIN_TREEIFY_CAPACITY == 16  \* Min table size for treeification (real: 64)
                            \* Below this, try_presize is called instead (map.rs:2740)

\* Bin types
BinEmpty    == "Empty"
BinNode     == "Node"
BinTree     == "Tree"
BinMoved    == "Moved"

\* Thread states for resize (Family 1)
Idle          == "Idle"
Transferring  == "Transferring"
Finishing     == "Finishing"

\* TreeBin lock constants (Family 3: node.rs:213-215)
WRITER == 1
WAITER == 2
READER == 4

\* ========================================================================
\* Variables
\* ========================================================================

\* --- Core table state (map.rs:84-103) ---
VARIABLES
    table,          \* [0..NumBins*2-1 -> BinState] — bin contents
                    \* BinState = [type: BinType, keys: SET(Key), locked: Thread \cup {null}]
    tableSize,      \* Current table size (power of 2)
    nextTableSize,  \* Size of next table during resize (0 if not resizing)
    sizeCtl,        \* Table init/resize control (map.rs:98-103)
    transferIndex,  \* Next bin index to claim for transfer (map.rs:93)
    count           \* Element count (AtomicIsize, map.rs:95)

\* --- Per-thread state ---
VARIABLES
    threadState,    \* [Thread -> Idle | Transferring | Finishing]
    threadBound,    \* [Thread -> Int] — lower bound of claimed range
    threadI,        \* [Thread -> Int] — current bin index being transferred
    threadPC        \* [Thread -> String] — program counter for multi-step ops

\* --- Resize coordination (Family 1: map.rs:651-1213) ---
VARIABLES
    binTransferred  \* [0..NumBins*2-1 -> BOOLEAN] — whether bin has been moved

\* --- Memory reclamation (Family 2: epoch-based GC) ---
VARIABLES
    retired,        \* SET of retired pointers (ptr = <<key, version>>)
    freed,          \* SET of freed pointers
    activeGuards,   \* [Thread -> BOOLEAN] — whether thread holds a guard
    guardEpoch,     \* [Thread -> Nat] — epoch when guard was acquired
    currentEpoch,   \* Global epoch counter
    reachable       \* [Thread -> SET(Ptr)] — pointers reachable through guard

\* --- TreeBin R/W lock (Family 3: node.rs:213-407) ---
VARIABLES
    lockState,      \* [BinIdx -> Int] — per-bin lock_state (bits: WRITER|WAITER|READER*n)
    waiter,         \* [BinIdx -> Thread \cup {"null"}] — stored waiter handle
    parked          \* SET(Thread) — threads currently parked

\* --- Post-lock treeify tracking (Family 4: map.rs:1854-1943) ---
VARIABLES
    pendingTreeify  \* [Thread -> BinIdx \cup {-1}] — bin index pending treeification

\* Variable groups for UNCHANGED
coreVars     == <<table, tableSize, nextTableSize, sizeCtl, transferIndex, count>>
threadVars   == <<threadState, threadBound, threadI, threadPC>>
resizeVars   == <<binTransferred>>
reclaimVars  == <<retired, freed, activeGuards, guardEpoch, currentEpoch, reachable>>
treeLockVars == <<lockState, waiter, parked>>
treeifyVars  == <<pendingTreeify>>

vars == <<coreVars, threadVars, resizeVars, reclaimVars, treeLockVars, treeifyVars>>

\* ========================================================================
\* Helpers
\* ========================================================================

\* Key-to-bin mapping (raw/mod.rs:294-296)
BinIndex(key, size) == IF size = 0 THEN 0 ELSE key % size

\* Number of keys currently in a bin
BinCount(b) == Cardinality(table[b].keys)

\* Is the table currently resizing?
IsResizing == nextTableSize > 0

\* Resize stamp computation (map.rs:404-406)
\* Simplified: just encodes the table size
ResizeStamp(n) == n

\* Max number of bins (configurable: supports log2(MaxTableMultiplier) resizes)
MaxBinIdx == NumBins * MaxTableMultiplier - 1

\* Bins in current table
CurrentBins == 0..tableSize-1

\* Bins in next table (during resize)
NextBins == 0..nextTableSize-1

\* ========================================================================
\* Init
\* ========================================================================

Init ==
    \* Core state: table initialized with NumBins empty bins
    /\ table = [b \in 0..MaxBinIdx |-> [type |-> BinEmpty, keys |-> {}, locked |-> "null"]]
    /\ tableSize = NumBins
    /\ nextTableSize = 0
    /\ sizeCtl = (NumBins - (NumBins \div 4))  \* load_factor!(NumBins) — map.rs:472
    /\ transferIndex = 0
    /\ count = 0
    \* Thread state
    /\ threadState = [t \in Thread |-> Idle]
    /\ threadBound = [t \in Thread |-> 0]
    /\ threadI = [t \in Thread |-> 0]
    /\ threadPC = [t \in Thread |-> "idle"]
    \* Resize tracking (Family 1)
    /\ binTransferred = [b \in 0..MaxBinIdx |-> FALSE]
    \* Reclamation (Family 2)
    /\ retired = {}
    /\ freed = {}
    /\ activeGuards = [t \in Thread |-> FALSE]
    /\ guardEpoch = [t \in Thread |-> 0]
    /\ currentEpoch = 0
    /\ reachable = [t \in Thread |-> {}]
    \* TreeBin lock (Family 3)
    /\ lockState = [b \in 0..MaxBinIdx |-> 0]
    /\ waiter = [b \in 0..MaxBinIdx |-> "null"]
    /\ parked = {}
    \* Treeify (Family 4)
    /\ pendingTreeify = [t \in Thread |-> -1]

\* ========================================================================
\* Actions: Put (map.rs:1665-1969)
\* ========================================================================

\* Put into empty bin via CAS (map.rs:1704-1729)
PutEmptyBin(t, key) ==
    LET b == BinIndex(key, tableSize) IN
    \* Precondition: guard is active (Family 2)
    /\ activeGuards[t] = TRUE
    /\ threadPC[t] = "idle"
    /\ table[b].type = BinEmpty                     \* map.rs:1704
    /\ key \notin table[b].keys
    \* CAS bin from null to new Node (map.rs:1708)
    /\ table' = [table EXCEPT ![b] = [type |-> BinNode,
                                        keys |-> {key},
                                        locked |-> "null"]]
    /\ count' = count + 1                           \* map.rs:1710: add_count(1, ...)
    /\ pendingTreeify' = [pendingTreeify EXCEPT ![t] = -1]
    /\ UNCHANGED <<tableSize, nextTableSize, sizeCtl, transferIndex,
                   threadVars, resizeVars, reclaimVars, treeLockVars>>

\* Put into non-empty Node bin under lock (map.rs:1768-1854)
PutNodeBin(t, key) ==
    LET b == BinIndex(key, tableSize) IN
    /\ activeGuards[t] = TRUE
    /\ threadPC[t] = "idle"
    /\ table[b].type = BinNode                      \* map.rs:1768
    /\ table[b].locked = "null"                     \* Acquire bin lock (map.rs:1770)
    \* Insert key (map.rs:1841-1848) or update existing
    /\ IF key \in table[b].keys
       THEN \* Key exists — update value (map.rs:1812)
            /\ UNCHANGED <<table, count>>
            /\ pendingTreeify' = [pendingTreeify EXCEPT ![t] = -1]
       ELSE \* Key does not exist — append node (map.rs:1843-1847)
            LET newKeys == table[b].keys \cup {key}
                bc == Cardinality(newKeys)
            IN
            /\ table' = [table EXCEPT ![b] = [type |-> BinNode,
                                                keys |-> newKeys,
                                                locked |-> "null"]]
            /\ count' = count + 1                   \* map.rs:1960
            \* Check treeify threshold (map.rs:1942-1943)
            /\ pendingTreeify' = [pendingTreeify EXCEPT
                    ![t] = IF bc >= TREEIFY_THRESHOLD THEN b ELSE -1]
    /\ UNCHANGED <<tableSize, nextTableSize, sizeCtl, transferIndex,
                   threadVars, resizeVars, reclaimVars, treeLockVars>>

\* Put into Tree bin under lock (map.rs:1858-1931)
PutTreeBin(t, key) ==
    LET b == BinIndex(key, tableSize) IN
    /\ activeGuards[t] = TRUE
    /\ threadPC[t] = "idle"
    /\ table[b].type = BinTree                      \* map.rs:1858
    /\ table[b].locked = "null"                     \* Acquire TreeBin lock (map.rs:1860)
    /\ IF key \in table[b].keys
       THEN \* Key exists — update value (map.rs:1903-1928)
            /\ UNCHANGED <<table, count>>
       ELSE \* Insert into tree (map.rs:1875-1880)
            /\ table' = [table EXCEPT ![b].keys = table[b].keys \cup {key}]
            /\ count' = count + 1
    /\ UNCHANGED <<tableSize, nextTableSize, sizeCtl, transferIndex,
                   threadVars, resizeVars, reclaimVars, treeLockVars, treeifyVars>>

\* Put encounters Moved bin — help transfer (map.rs:1750-1752)
PutHelpTransfer(t, key) ==
    LET b == BinIndex(key, tableSize) IN
    /\ activeGuards[t] = TRUE
    /\ threadPC[t] = "idle"
    /\ table[b].type = BinMoved                     \* map.rs:1750
    /\ IsResizing
    \* Thread joins resize (simplified: sets state to Transferring)
    /\ threadState' = [threadState EXCEPT ![t] = Transferring]
    /\ threadPC' = [threadPC EXCEPT ![t] = "help_transfer"]
    /\ UNCHANGED <<coreVars, threadBound, threadI,
                   resizeVars, reclaimVars, treeLockVars, treeifyVars>>

\* ========================================================================
\* Actions: Treeify (Family 4 — map.rs:2724-2855)
\* ========================================================================

\* Treeify bin AFTER lock release (map.rs:1942-1943, 2724-2855)
\* Race window: between head_lock drop (1854) and treeify_bin (1943),
\* another thread can transfer or treeify the bin.
TreeifyBin(t) ==
    LET b == pendingTreeify[t] IN
    /\ b >= 0                                        \* Has pending treeify
    /\ b < tableSize                                 \* Bin is in current table
    /\ activeGuards[t] = TRUE
    \* Re-acquire lock and check bin type (map.rs:2737-2741)
    /\ \/ /\ table[b].type = BinNode                 \* Still a Node bin
          /\ table[b].locked = "null"                \* Can acquire lock
          /\ Cardinality(table[b].keys) >= TREEIFY_THRESHOLD
          /\ tableSize >= MIN_TREEIFY_CAPACITY        \* Table large enough (map.rs:2740)
          \* Convert to tree (map.rs:2787-2788)
          /\ table' = [table EXCEPT ![b].type = BinTree]
          /\ UNCHANGED <<treeLockVars>>
       \/ /\ table[b].type = BinNode                 \* Node bin, but table too small
          /\ tableSize < MIN_TREEIFY_CAPACITY         \* try_presize instead (map.rs:2740)
          /\ UNCHANGED <<table, treeLockVars>>        \* Skip treeify
       \/ /\ table[b].type = BinNode                 \* Node bin, but count dropped below threshold
          /\ Cardinality(table[b].keys) < TREEIFY_THRESHOLD  \* (e.g., after resize split)
          /\ UNCHANGED <<table, treeLockVars>>        \* Skip treeify
       \/ /\ table[b].type = BinEmpty                \* Bin became empty (all keys went to high half)
          /\ UNCHANGED <<table, treeLockVars>>        \* Do nothing — benign
       \/ /\ table[b].type = BinMoved                \* Bin was moved (map.rs:2813)
          /\ UNCHANGED <<table, treeLockVars>>        \* Do nothing — benign
       \/ /\ table[b].type = BinTree                 \* Already treeified (map.rs:2834)
          /\ UNCHANGED <<table, treeLockVars>>        \* Do nothing — benign
    /\ pendingTreeify' = [pendingTreeify EXCEPT ![t] = -1]
    /\ UNCHANGED <<tableSize, nextTableSize, sizeCtl, transferIndex, count,
                   threadVars, resizeVars, reclaimVars>>

\* ========================================================================
\* Actions: Resize Initiation (Family 1 — map.rs:1134-1213)
\* ========================================================================

\* add_count triggers resize (map.rs:1199-1207)
InitResize(t) ==
    LET rs == ResizeStamp(tableSize) IN
    /\ activeGuards[t] = TRUE
    /\ threadPC[t] = "idle"
    /\ ~IsResizing                                   \* No ongoing resize
    /\ count >= sizeCtl                              \* Load exceeds threshold (map.rs:1155)
    /\ sizeCtl >= 0                                  \* Not already resizing (map.rs:1178)
    /\ tableSize * 2 <= MaxBinIdx + 1                 \* Can still double
    \* CAS size_ctl to rs+2 (map.rs:1201: rs + 2 = "1 initiator thread")
    /\ sizeCtl' = -(rs + 2)                         \* Negative = resizing
    /\ nextTableSize' = tableSize * 2               \* Double the table (map.rs:669)
    /\ transferIndex' = tableSize                    \* Start from top (map.rs:672)
    \* Initialize next table bins
    /\ table' = [b \in 0..MaxBinIdx |->
                    IF b < tableSize THEN table[b]   \* Current bins unchanged
                    ELSE [type |-> BinEmpty, keys |-> {}, locked |-> "null"]]
    /\ binTransferred' = [b \in 0..MaxBinIdx |-> FALSE]
    /\ threadState' = [threadState EXCEPT ![t] = Transferring]
    /\ threadPC' = [threadPC EXCEPT ![t] = "transfer_claim"]
    /\ threadI' = [threadI EXCEPT ![t] = tableSize]  \* i = n (map.rs:710)
    /\ threadBound' = [threadBound EXCEPT ![t] = 0]
    /\ UNCHANGED <<tableSize, count, reclaimVars, treeLockVars, treeifyVars>>

\* ========================================================================
\* Actions: Transfer — Claim Range (Family 1 — map.rs:684-714)
\* ========================================================================

\* Thread claims a range of bins to transfer via CAS on transfer_index
ClaimRange(t) ==
    LET stride == 1                                  \* Simplified: 1 bin per claim for MC
        nextIndex == transferIndex
        nextBound == IF nextIndex > stride THEN nextIndex - stride ELSE 0
    IN
    /\ threadState[t] = Transferring
    /\ threadPC[t] = "transfer_claim"
    /\ IsResizing
    /\ transferIndex > 0                             \* map.rs:693
    \* CAS transfer_index (map.rs:704-707)
    /\ transferIndex' = nextBound
    /\ threadBound' = [threadBound EXCEPT ![t] = nextBound]
    \* CRITICAL: map.rs:710 — i = next_index (NOT next_index - 1!)
    \* This is the off-by-one: i points past the claimed range.
    \* On first iteration of outer loop, i >= n triggers finishing check (map.rs:716).
    /\ threadI' = [threadI EXCEPT ![t] = nextIndex]  \* map.rs:710
    \* If i >= tableSize, the outer loop hits the i >= n check before decrementing
    /\ threadPC' = [threadPC EXCEPT ![t] =
            IF nextIndex >= tableSize THEN "transfer_finish_check"
            ELSE "transfer_bin"]
    /\ UNCHANGED <<table, tableSize, nextTableSize, sizeCtl, count,
                   threadState, resizeVars, reclaimVars, treeLockVars, treeifyVars>>

\* No more ranges to claim — thread is done (map.rs:693-696)
ClaimRangeExhausted(t) ==
    /\ threadState[t] = Transferring
    /\ threadPC[t] = "transfer_claim"
    /\ IsResizing
    /\ transferIndex <= 0                            \* map.rs:693
    /\ threadI' = [threadI EXCEPT ![t] = -1]        \* map.rs:694
    /\ threadPC' = [threadPC EXCEPT ![t] = "transfer_finish_check"]
    /\ UNCHANGED <<coreVars, threadState, threadBound,
                   resizeVars, reclaimVars, treeLockVars, treeifyVars>>

\* ========================================================================
\* Actions: Transfer — Process Bin (Family 1 — map.rs:776-1084)
\* ========================================================================

\* Transfer a single bin from old table to new table
TransferBin(t) ==
    LET i == threadI[t]
        iDec == i - 1           \* Decrement i first (map.rs:686)
    IN
    /\ threadState[t] \in {Transferring, Finishing}   \* Finisher also processes bins
    /\ threadPC[t] = "transfer_bin"
    /\ IsResizing
    /\ iDec >= threadBound[t]                        \* Still within claimed range
    /\ iDec >= 0
    /\ iDec < tableSize
    /\ \/ \* Empty bin — CAS to Moved (map.rs:785-794)
          /\ table[iDec].type = BinEmpty
          /\ table' = [table EXCEPT ![iDec] = [type |-> BinMoved,
                                                 keys |-> {},
                                                 locked |-> "null"]]
          /\ binTransferred' = [binTransferred EXCEPT ![iDec] = TRUE]
       \/ \* Already moved — skip (map.rs:816-818)
          /\ table[iDec].type = BinMoved
          /\ UNCHANGED <<table, binTransferred>>
       \/ \* Node bin — lock, split, and move (map.rs:820-934)
          /\ table[iDec].type = BinNode
          /\ table[iDec].locked = "null"             \* Acquire bin lock (map.rs:822)
          /\ LET keys == table[iDec].keys
                 \* Split keys by hash bit (map.rs:836,885: hash & n)
                 lowKeys  == {k \in keys : BinIndex(k, nextTableSize) = iDec}
                 highKeys == {k \in keys : BinIndex(k, nextTableSize) = iDec + tableSize}
                 lowType  == IF lowKeys  = {} THEN BinEmpty ELSE BinNode
                 highType == IF highKeys = {} THEN BinEmpty ELSE BinNode
                 highBin  == iDec + tableSize
             IN
             \* Store low bin at index iDec, high bin at iDec+n (map.rs:906-907)
             \* Mark old bin as Moved (map.rs:908)
             \* Preserve lowKeys in the Moved bin so CompleteResize can reconstruct.
             /\ table' = [b2 \in DOMAIN table |->
                   IF b2 = iDec
                   THEN [type |-> BinMoved, keys |-> lowKeys, locked |-> "null"]
                   ELSE IF b2 = highBin
                   THEN [type |-> highType, keys |-> highKeys, locked |-> "null"]
                   ELSE table[b2]]
             /\ binTransferred' = [binTransferred EXCEPT ![iDec] = TRUE]
       \/ \* Tree bin — lock, split, possibly untreeify (map.rs:936-1079)
          /\ table[iDec].type = BinTree
          /\ table[iDec].locked = "null"
          /\ LET keys == table[iDec].keys
                 lowKeys  == {k \in keys : BinIndex(k, nextTableSize) = iDec}
                 highKeys == {k \in keys : BinIndex(k, nextTableSize) = iDec + tableSize}
                 highBin  == iDec + tableSize
                 lowType  == IF lowKeys  = {} THEN BinEmpty ELSE BinNode
                 highType == IF highKeys = {} THEN BinEmpty ELSE BinNode
             IN
             \* Preserve lowKeys in the Moved bin so CompleteResize can reconstruct.
             /\ table' = [b2 \in DOMAIN table |->
                   IF b2 = iDec
                   THEN [type |-> BinMoved, keys |-> lowKeys, locked |-> "null"]
                   ELSE IF b2 = highBin
                   THEN [type |-> highType, keys |-> highKeys, locked |-> "null"]
                   ELSE table[b2]]
             /\ binTransferred' = [binTransferred EXCEPT ![iDec] = TRUE]
    /\ threadI' = [threadI EXCEPT ![t] = iDec]
    \* Check if we need to process more bins, claim more, or finish
    /\ threadPC' = [threadPC EXCEPT ![t] =
            IF iDec - 1 >= threadBound[t] THEN "transfer_bin"
            ELSE IF threadState[t] = Finishing THEN "transfer_complete"
            ELSE "transfer_claim"]
    /\ UNCHANGED <<tableSize, nextTableSize, sizeCtl, transferIndex, count,
                   threadState, threadBound, reclaimVars, treeLockVars, treeifyVars>>

\* ========================================================================
\* Actions: Transfer — Finish Check (Family 1 — map.rs:716-775)
\* ========================================================================

\* Thread's claimed range is exhausted or i < 0; check if resize is done
TransferFinishCheck(t) ==
    LET sc == sizeCtl
        rs == ResizeStamp(tableSize)
    IN
    /\ threadState[t] = Transferring
    /\ threadPC[t] = "transfer_finish_check"
    /\ IsResizing
    \* CAS size_ctl - 1 (map.rs:755-758: decrement helper count)
    /\ sizeCtl' = sc + 1                            \* sc - 1 but sc is negative, so +1 toward 0
    /\ IF (sc + 1) = -(rs + 1)                      \* map.rs:760: (sc - 2) != rs << SHIFT
       THEN \* We are the last thread — become finisher (map.rs:765)
            \* finishing=true, advance=true, i=n — re-enter bin loop (map.rs:771)
            /\ threadState' = [threadState EXCEPT ![t] = Finishing]
            /\ threadPC' = [threadPC EXCEPT ![t] = "transfer_bin"]
            /\ threadI' = [threadI EXCEPT ![t] = tableSize]  \* i = n (map.rs:771)
            /\ threadBound' = [threadBound EXCEPT ![t] = 0]  \* Finisher sweeps ALL bins
       ELSE \* Not the last thread — just return (map.rs:761)
            /\ threadState' = [threadState EXCEPT ![t] = Idle]
            /\ threadPC' = [threadPC EXCEPT ![t] = "idle"]
            /\ UNCHANGED <<threadI, threadBound>>
    /\ UNCHANGED <<table, tableSize, nextTableSize, transferIndex, count,
                   resizeVars, reclaimVars, treeLockVars, treeifyVars>>

\* ========================================================================
\* Actions: Transfer — Finishing Sweep (Family 1 — map.rs:719-751)
\* ========================================================================

\* The finishing thread re-checks all bins (map.rs:771: "recheck before commit")
FinishingSweep(t) ==
    LET i == threadI[t]
        iDec == i - 1
    IN
    /\ threadState[t] = Finishing
    /\ threadPC[t] = "transfer_sweep"
    /\ i > 0
    \* Check if bin needs transfer (map.rs:785-818 revisited)
    /\ IF table[iDec].type /= BinMoved /\ iDec < tableSize
       THEN \* Bin was missed — mark as Moved, preserve keys for CompleteResize
            /\ table' = [table EXCEPT ![iDec] = [type |-> BinMoved,
                                                   keys |-> table[iDec].keys,
                                                   locked |-> "null"]]
            /\ binTransferred' = [binTransferred EXCEPT ![iDec] = TRUE]
       ELSE UNCHANGED <<table, binTransferred>>
    /\ threadI' = [threadI EXCEPT ![t] = iDec]
    /\ IF iDec = 0
       THEN threadPC' = [threadPC EXCEPT ![t] = "transfer_complete"]
       ELSE UNCHANGED threadPC
    /\ UNCHANGED <<tableSize, nextTableSize, sizeCtl, transferIndex, count,
                   threadState, threadBound, reclaimVars, treeLockVars, treeifyVars>>

\* Finalize resize: swap table, update size_ctl (map.rs:720-751)
CompleteResize(t) ==
    /\ threadState[t] = Finishing
    /\ threadPC[t] = "transfer_complete"
    \* Swap table pointer (map.rs:722)
    /\ tableSize' = nextTableSize
    /\ nextTableSize' = 0
    \* Old table is retired (map.rs:748)
    \* Update size_ctl to new load factor (map.rs:749-750)
    /\ sizeCtl' = (nextTableSize - (nextTableSize \div 4))
    /\ transferIndex' = 0
    /\ threadState' = [threadState EXCEPT ![t] = Idle]
    /\ threadPC' = [threadPC EXCEPT ![t] = "idle"]
    \* Reconstruct table: convert Moved bins (holding lowKeys) back to Node/Empty.
    \* Bins beyond nextTableSize are cleared. This models the table pointer swap.
    /\ table' = [b \in 0..MaxBinIdx |->
        IF b < nextTableSize THEN
            IF table[b].type = BinMoved THEN
                \* Moved bins hold lowKeys preserved during transfer
                IF table[b].keys = {} THEN [type |-> BinEmpty, keys |-> {}, locked |-> "null"]
                ELSE [type |-> BinNode, keys |-> table[b].keys, locked |-> "null"]
            ELSE table[b]  \* High-half bins already have correct state
        ELSE [type |-> BinEmpty, keys |-> {}, locked |-> "null"]]
    /\ binTransferred' = [b \in 0..MaxBinIdx |-> FALSE]
    /\ UNCHANGED <<count, threadBound, threadI,
                   reclaimVars, treeLockVars, treeifyVars>>

\* ========================================================================
\* Actions: Help Transfer (Family 1 — map.rs:1088-1132)
\* ========================================================================

\* Thread sees Moved during put and joins resize (map.rs:1122-1128)
\* Guard: map.rs:1099-1109 checks sc != rs+1 (no active threads),
\* transferIndex > 0 (bins remain), and next_table non-null.
HelpTransfer(t) ==
    LET rs == ResizeStamp(tableSize) IN
    /\ threadPC[t] = "help_transfer"
    /\ IsResizing
    /\ sizeCtl /= -(rs + 1)                         \* map.rs:1105: sc == rs+1 → break
    /\ transferIndex > 0                             \* map.rs:1107: transferIndex <= 0 → break
    \* CAS size_ctl + 1 (map.rs:1124: increment helper count)
    /\ sizeCtl' = sizeCtl - 1                       \* More negative = more helpers
    /\ threadPC' = [threadPC EXCEPT ![t] = "transfer_claim"]
    /\ UNCHANGED <<table, tableSize, nextTableSize, transferIndex, count,
                   threadState, threadBound, threadI,
                   resizeVars, reclaimVars, treeLockVars, treeifyVars>>

\* Thread can't join resize — guard conditions fail, return to idle (map.rs:1099-1109 break)
HelpTransferBail(t) ==
    LET rs == ResizeStamp(tableSize) IN
    /\ threadPC[t] = "help_transfer"
    /\ \/ ~IsResizing                                \* Resize already completed
       \/ sizeCtl = -(rs + 1)                        \* No active threads (finisher done)
       \/ transferIndex <= 0                          \* All bins claimed
    /\ threadState' = [threadState EXCEPT ![t] = Idle]
    /\ threadPC' = [threadPC EXCEPT ![t] = "idle"]
    /\ UNCHANGED <<coreVars, threadBound, threadI,
                   resizeVars, reclaimVars, treeLockVars, treeifyVars>>

\* ========================================================================
\* Actions: Guard Lifecycle (Family 2 — epoch-based reclamation)
\* ========================================================================

\* Thread enters a guard / pins the collector (map.rs:various — guard usage)
EnterGuard(t) ==
    /\ activeGuards[t] = FALSE
    /\ activeGuards' = [activeGuards EXCEPT ![t] = TRUE]
    /\ guardEpoch' = [guardEpoch EXCEPT ![t] = currentEpoch]
    /\ reachable' = [reachable EXCEPT ![t] = {}]
    /\ UNCHANGED <<coreVars, threadVars, resizeVars,
                   retired, freed, currentEpoch,
                   treeLockVars, treeifyVars>>

\* Thread exits guard / drops the pin
ExitGuard(t) ==
    /\ activeGuards[t] = TRUE
    /\ threadPC[t] = "idle"                          \* No operation in progress
    /\ pendingTreeify[t] = -1                        \* No pending treeify
    /\ activeGuards' = [activeGuards EXCEPT ![t] = FALSE]
    /\ reachable' = [reachable EXCEPT ![t] = {}]
    /\ UNCHANGED <<coreVars, threadVars, resizeVars,
                   retired, freed, guardEpoch, currentEpoch,
                   treeLockVars, treeifyVars>>

\* Retire a pointer (map.rs:various — guard.retire_shared calls)
RetirePtr(t, ptr) ==
    /\ activeGuards[t] = TRUE
    /\ ptr \notin retired
    /\ ptr \notin freed
    /\ retired' = retired \cup {ptr}
    /\ UNCHANGED <<coreVars, threadVars, resizeVars,
                   freed, activeGuards, guardEpoch, currentEpoch, reachable,
                   treeLockVars, treeifyVars>>

\* Epoch advances and frees retired pointers not reachable by any active guard
AdvanceEpoch ==
    LET protectedPtrs == UNION {reachable[t] : t \in {t2 \in Thread : activeGuards[t2]}}
        toFree == retired \ protectedPtrs
    IN
    /\ currentEpoch' = currentEpoch + 1
    \* Free all retired pointers that no active guard can reach
    /\ freed' = freed \cup toFree
    /\ retired' = retired \ toFree
    /\ UNCHANGED <<coreVars, threadVars, resizeVars,
                   activeGuards, guardEpoch, reachable,
                   treeLockVars, treeifyVars>>

\* Thread loads a pointer, making it reachable through its guard
LoadPtr(t, ptr) ==
    /\ activeGuards[t] = TRUE
    /\ reachable' = [reachable EXCEPT ![t] = reachable[t] \cup {ptr}]
    /\ UNCHANGED <<coreVars, threadVars, resizeVars,
                   retired, freed, activeGuards, guardEpoch, currentEpoch,
                   treeLockVars, treeifyVars>>

\* ========================================================================
\* Actions: TreeBin R/W Lock (Family 3 — node.rs:335-491)
\* ========================================================================

\* Reader acquires read lock via CAS (node.rs:460-463)
ReaderAcquire(t, b) ==
    LET s == lockState[b] IN
    /\ activeGuards[t] = TRUE
    /\ b \in CurrentBins
    /\ table[b].type = BinTree
    /\ s >= 0                                        \* No WAITER or WRITER bits
    /\ (s \div WAITER) % 2 = 0                      \* WAITER bit not set
    /\ (s % 2) = 0                                   \* WRITER bit not set
    \* CAS(s, s + READER) — node.rs:462
    /\ lockState' = [lockState EXCEPT ![b] = s + READER]
    /\ UNCHANGED <<coreVars, threadVars, resizeVars, reclaimVars,
                   waiter, parked, treeifyVars>>

\* Reader releases read lock (node.rs:473)
ReaderRelease(t, b) ==
    LET s == lockState[b] IN
    /\ activeGuards[t] = TRUE
    /\ b \in CurrentBins
    /\ table[b].type = BinTree
    /\ s >= READER                                   \* At least one reader
    /\ lockState' = [lockState EXCEPT ![b] = s - READER]
    \* If we were the last reader and a writer is waiting, unpark (node.rs:473-484)
    /\ IF s = (READER + WAITER)                      \* READER|WAITER → unpark writer
       THEN /\ waiter[b] /= "null"
            /\ parked' = parked \ {waiter[b]}        \* Unpark the writer
       ELSE UNCHANGED parked
    /\ UNCHANGED <<coreVars, threadVars, resizeVars, reclaimVars,
                   waiter, treeifyVars>>

\* Writer acquires write lock — fast path (node.rs:336-344)
WriterAcquireFast(t, b) ==
    /\ activeGuards[t] = TRUE
    /\ b \in CurrentBins
    /\ table[b].type = BinTree
    /\ lockState[b] = 0                              \* Uncontended (node.rs:337)
    \* CAS(0, WRITER) — node.rs:338
    /\ lockState' = [lockState EXCEPT ![b] = WRITER]
    /\ UNCHANGED <<coreVars, threadVars, resizeVars, reclaimVars,
                   waiter, parked, treeifyVars>>

\* Writer sets WAITER bit and parks (node.rs:390-404)
WriterSetWaiter(t, b) ==
    LET s == lockState[b] IN
    /\ activeGuards[t] = TRUE
    /\ b \in CurrentBins
    /\ table[b].type = BinTree
    /\ s % 2 = 0                                    \* WRITER not set
    /\ (s \div 2) % 2 = 0                           \* WAITER not set
    /\ s > 0                                         \* Readers present
    \* CAS(s, s | WAITER) — node.rs:394-395
    /\ lockState' = [lockState EXCEPT ![b] = s + WAITER]
    /\ waiter' = [waiter EXCEPT ![b] = t]           \* Store thread handle (node.rs:399-400)
    /\ parked' = parked \cup {t}                     \* Park self (node.rs:404)
    /\ UNCHANGED <<coreVars, threadVars, resizeVars, reclaimVars, treeifyVars>>

\* Writer acquires lock after being unparked (node.rs:356-388)
WriterAcquireContended(t, b) ==
    LET s == lockState[b] IN
    /\ activeGuards[t] = TRUE
    /\ b \in CurrentBins
    /\ table[b].type = BinTree
    /\ t \notin parked                               \* Has been unparked
    /\ (s % 2) = 0                                   \* No active WRITER
    /\ (s \div READER) = 0                           \* No active READERs (only WAITER bit maybe)
    \* CAS(s, WRITER) — node.rs:361
    /\ lockState' = [lockState EXCEPT ![b] = WRITER]
    \* Swap waiter to null, retire handle (node.rs:366-386)
    /\ waiter' = [waiter EXCEPT ![b] = "null"]
    /\ UNCHANGED <<coreVars, threadVars, resizeVars, reclaimVars,
                   parked, treeifyVars>>

\* Writer releases write lock (node.rs:347-349)
WriterRelease(t, b) ==
    /\ activeGuards[t] = TRUE
    /\ b \in CurrentBins
    /\ lockState[b] = WRITER
    \* store(0) — node.rs:348
    /\ lockState' = [lockState EXCEPT ![b] = 0]
    /\ UNCHANGED <<coreVars, threadVars, resizeVars, reclaimVars,
                   waiter, parked, treeifyVars>>

\* ========================================================================
\* Invariants
\* ========================================================================

\* --- Standard Safety ---

\* All bins in old table are Moved after resize completes (Family 1)
AllBinsTransferred ==
    ~IsResizing =>
        \A b \in 0..tableSize-1 :
            \/ binTransferred[b]
            \/ table[b].type /= BinMoved  \* If not resizing, bins shouldn't be Moved

\* --- Extension Invariants (Bug Families) ---

\* F1: No bin is skipped during resize
NoSkippedBins ==
    \* When finishing thread sweeps, every bin in [0, tableSize) should be Moved
    \A t \in Thread :
        (threadState[t] = Finishing /\ threadPC[t] = "transfer_complete") =>
            \A b \in 0..tableSize-1 : binTransferred[b]

\* F1: Resize stamp/sizeCtl coordination
ResizeCoordination ==
    \* If sizeCtl is negative (resizing), nextTableSize must be > 0
    sizeCtl < 0 => nextTableSize > 0

\* F2: No use-after-free — no thread accesses a freed pointer
NoUseAfterFree ==
    \A t \in Thread :
        activeGuards[t] => (reachable[t] \cap freed) = {}

\* F3: Reader-Writer mutual exclusion (node.rs:213-215)
ReaderWriterMutex ==
    \A b \in CurrentBins :
        table[b].type = BinTree =>
            ~(lockState[b] % 2 = 1 /\ lockState[b] >= READER + WRITER)
            \* WRITER bit set implies no READER bits

\* F3: Waiter safety — waiter handle not freed while referenced
WaiterSafety ==
    \A b \in CurrentBins :
        (waiter[b] /= "null") =>
            waiter[b] \notin freed  \* Simplified: waiter handle not in freed set

\* F4: Bin type consistency — Moved bins only exist during resize
\* (They may hold lowKeys temporarily for CompleteResize reconstruction)
BinTypeConsistency ==
    \A b \in CurrentBins :
        table[b].type = BinMoved => IsResizing

\* F4: Treeify handles all bin types without panic
TreeifyNoPanic ==
    \A t \in Thread :
        pendingTreeify[t] >= 0 =>
            table[pendingTreeify[t]].type \in {BinNode, BinTree, BinMoved}

\* --- Structural Invariants ---

\* Bin key count is non-negative
BinKeysNonNeg ==
    \A b \in 0..MaxBinIdx : Cardinality(table[b].keys) >= 0

\* Count is non-negative (may be temporarily negative in impl, but model tracks accurately)
CountNonNeg == count >= 0

\* Empty bins have no keys
EmptyBinNoKeys ==
    \A b \in 0..MaxBinIdx :
        table[b].type = BinEmpty => table[b].keys = {}

\* Moved bins: during resize they hold lowKeys (for CompleteResize reconstruction);
\* after resize completes there should be no Moved bins at all.
MovedBinNoKeys ==
    \A b \in 0..MaxBinIdx :
        table[b].type = BinMoved => IsResizing

\* Lock state is non-negative
LockStateNonNeg ==
    \A b \in 0..MaxBinIdx : lockState[b] >= 0

\* ========================================================================
\* Next State
\* ========================================================================

Next ==
    \* --- Put operations ---
    \/ \E t \in Thread, k \in 0..MaxKey-1 :
        \/ PutEmptyBin(t, k)
        \/ PutNodeBin(t, k)
        \/ PutTreeBin(t, k)
        \/ PutHelpTransfer(t, k)
    \* --- Treeify (Family 4) ---
    \/ \E t \in Thread : TreeifyBin(t)
    \* --- Resize initiation (Family 1) ---
    \/ \E t \in Thread : InitResize(t)
    \* --- Transfer coordination (Family 1) ---
    \/ \E t \in Thread :
        \/ ClaimRange(t)
        \/ ClaimRangeExhausted(t)
        \/ TransferBin(t)
        \/ TransferFinishCheck(t)
        \/ FinishingSweep(t)
        \/ CompleteResize(t)
        \/ HelpTransfer(t)
        \/ HelpTransferBail(t)
    \* --- Guard lifecycle (Family 2) ---
    \/ \E t \in Thread :
        \/ EnterGuard(t)
        \/ ExitGuard(t)
    \/ AdvanceEpoch
    \* --- TreeBin R/W lock (Family 3) ---
    \/ \E t \in Thread, b \in CurrentBins :
        \/ ReaderAcquire(t, b)
        \/ ReaderRelease(t, b)
        \/ WriterAcquireFast(t, b)
        \/ WriterSetWaiter(t, b)
        \/ WriterAcquireContended(t, b)
        \/ WriterRelease(t, b)

Spec == Init /\ [][Next]_vars

====
